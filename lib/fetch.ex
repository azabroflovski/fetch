defmodule Fetch do
  @moduledoc """
  A small just-for-fun HTTP/1.1 client written in plain Elixir/OTP.

      {:ok, response} = Fetch.get("https://example.com")
      response.status
      #=> 200

  Every call opens a new connection, sends one request with
  `connection: close`, reads the response and closes the connection:

      URL → DNS → TCP → (TLS) → request → response head → body → close

  To send several requests over one connection (keep-alive), use
  `Fetch.Conn`.

  ## Options

    * `:headers` — list of `{name, value}` tuples. Default `[]`.
    * `:body` — request body as iodata. Default `nil`.
    * `:connect_timeout` — ms, applied to each of DNS lookup, TCP connect and
      TLS handshake. Default `5_000`.
    * `:receive_timeout` — ms, the longest the server may stay silent while we
      wait for bytes (and while a send is blocked). Default `15_000`.
    * `:max_body_size` — bytes. Larger responses fail with
      `{:recv, :body_too_large}`. Default 16 MiB.
    * `:ssl` — extra `:ssl` client options merged over the secure defaults,
      e.g. `cacerts: [der]` for a private CA.
    * `:follow_redirects` — follow 301, 302, 303, 307 and 308 responses, see
      `Fetch.Redirect`. Default `true`.
    * `:max_redirects` — redirects to follow before failing with
      `{:redirect, :too_many_redirects}`. Default `10`.

  ## Errors

  All errors are `{:error, {stage, reason}}`, where stage is one of `:url`,
  `:request`, `:dns`, `:connect`, `:tls`, `:send`, `:recv`, `:parse`,
  `:redirect`. Timeouts are `{stage, :timeout}`.

  Invalid options or an unsupported method raise `ArgumentError`: those are
  bugs in the calling code, not runtime conditions.
  """

  alias Fetch.{Conn, Redirect, Request, Response, URL}

  # Passed on to `Fetch.Conn.new/2`, which validates them and owns the defaults.
  @connection_options [:connect_timeout, :receive_timeout, :max_body_size, :ssl]

  @default_options [headers: [], body: nil, follow_redirects: true, max_redirects: 10]

  @type error_stage ::
          :url | :request | :dns | :connect | :tls | :send | :recv | :parse | :redirect
  @type error :: {:error, {error_stage(), term()}}

  @doc "Sends a GET request. See `request/3`."
  @spec get(String.t(), keyword()) :: {:ok, Response.t()} | error()
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc "Sends a HEAD request. The response body is always empty. See `request/3`."
  @spec head(String.t(), keyword()) :: {:ok, Response.t()} | error()
  def head(url, opts \\ []), do: request(:head, url, opts)

  @doc "Sends a POST request. See `request/3`."
  @spec post(String.t(), keyword()) :: {:ok, Response.t()} | error()
  def post(url, opts \\ []), do: request(:post, url, opts)

  @doc "Sends a PUT request. See `request/3`."
  @spec put(String.t(), keyword()) :: {:ok, Response.t()} | error()
  def put(url, opts \\ []), do: request(:put, url, opts)

  @doc "Sends a PATCH request. See `request/3`."
  @spec patch(String.t(), keyword()) :: {:ok, Response.t()} | error()
  def patch(url, opts \\ []), do: request(:patch, url, opts)

  @doc "Sends a DELETE request. See `request/3`."
  @spec delete(String.t(), keyword()) :: {:ok, Response.t()} | error()
  def delete(url, opts \\ []), do: request(:delete, url, opts)

  @doc """
  Sends a request and returns the whole response.

      Fetch.request(:post, "http://localhost:4000/users",
        headers: [{"content-type", "application/json"}],
        body: ~s({"name":"Jon Snow"})
      )

  Any HTTP status is `{:ok, response}` — a 404 is a valid response, not an
  error. Redirects are followed unless `follow_redirects: false`; the
  response is the one from the last request. See the module docs for options
  and errors.
  """
  @spec request(Request.method(), String.t(), keyword()) :: {:ok, Response.t()} | error()
  def request(method, url, opts \\ []) do
    Request.check_method!(method)
    {conn_opts, opts} = Keyword.split(opts, @connection_options)
    opts = Keyword.validate!(opts, @default_options)

    with {:ok, url} <- URL.parse(url) do
      request = %{method: method, url: url, headers: opts[:headers], body: opts[:body]}
      run(request, conn_opts, opts, opts[:max_redirects])
    end
  end

  # Every redirect is a new request on a new connection.
  defp run(request, conn_opts, opts, redirects_left) do
    with {:ok, response} <- send_once(request, conn_opts) do
      next = if opts[:follow_redirects], do: Redirect.next_request(request, response), else: :none

      case next do
        :none -> {:ok, response}
        {:ok, _next} when redirects_left < 1 -> {:error, {:redirect, :too_many_redirects}}
        {:ok, next} -> run(next, conn_opts, opts, redirects_left - 1)
        {:error, _} = error -> error
      end
    end
  end

  # One request on a fresh connection; `keep_alive: false` closes it afterwards.
  defp send_once(request, conn_opts) do
    {:ok, conn} = Conn.new(request.url, conn_opts)

    case Conn.request(conn, request.method, request.url.target,
           headers: request.headers,
           body: request.body,
           keep_alive: false
         ) do
      {:ok, _closed_conn, response} -> {:ok, response}
      {:error, _closed_conn, reason} -> {:error, reason}
    end
  end
end

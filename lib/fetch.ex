defmodule Fetch do
  @moduledoc """
  A small just-for-fun HTTP/1.1 client written in plain Elixir/OTP.

      {:ok, response} = Fetch.get("https://example.com")
      response.status
      #=> 200

  Every request opens a new connection, sends one request with
  `connection: close`, reads the response and closes the connection:

      URL → DNS → TCP → (TLS) → request → response head → body → close

  ## Options

    * `:headers` — list of `{name, value}` tuples. Default `[]`.
    * `:body` — request body as iodata. Default `nil`.
    * `:connect_timeout` — ms, applied to each of DNS lookup, TCP connect and
      TLS handshake. Default `#{5_000}`.
    * `:receive_timeout` — ms, the longest the server may stay silent while we
      wait for bytes (and while a send is blocked). Default `#{15_000}`.
    * `:max_body_size` — bytes. Larger responses fail with
      `{:recv, :body_too_large}`. Default 16 MiB.
    * `:ssl` — extra `:ssl` client options merged over the secure defaults,
      e.g. `cacerts: [der]` for a private CA.

  ## Errors

  All errors are `{:error, {stage, reason}}`, where stage is one of `:url`,
  `:request`, `:dns`, `:connect`, `:tls`, `:send`, `:recv`, `:parse`.
  Timeouts are `{stage, :timeout}`.

  Invalid options or an unsupported method raise `ArgumentError`: those are
  bugs in the calling code, not runtime conditions.
  """

  alias Fetch.{Parser, Request, Response, Transport, URL}

  @methods [:get, :head, :post, :put, :patch, :delete, :options]

  @default_options [
    headers: [],
    body: nil,
    connect_timeout: 5_000,
    receive_timeout: 15_000,
    max_body_size: 16 * 1024 * 1024,
    ssl: []
  ]

  # A head bigger than this is not a normal response.
  @max_head_size 64 * 1024

  # Longest chunk size line (hex size + extensions) we wait for.
  @max_chunk_line 4 * 1024

  @type error_stage :: :url | :request | :dns | :connect | :tls | :send | :recv | :parse
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
  error. See the module docs for options and errors.
  """
  @spec request(Request.method(), String.t(), keyword()) :: {:ok, Response.t()} | error()
  def request(method, url, opts \\ []) do
    if method not in @methods do
      raise ArgumentError,
            "unsupported method #{inspect(method)}, expected one of #{inspect(@methods)}"
    end

    opts = Keyword.validate!(opts, @default_options)

    with {:ok, url} <- URL.parse(url),
         {:ok, data} <- Request.encode(method, url, opts[:headers], opts[:body]),
         {:ok, transport} <- Transport.connect(url, opts) do
      try do
        with :ok <- Transport.send(transport, data) do
          read_response(transport, "", method, opts)
        end
      after
        Transport.close(transport)
      end
    end
  end

  defp read_response(transport, buffer, method, opts) do
    with {:ok, head, rest} <- read_head(transport, buffer, opts[:receive_timeout]),
         {:ok, %{status: status, headers: headers}} <- Parser.parse_head(head) do
      if status in 100..199 do
        # Interim response (e.g. 100 Continue): the real one follows.
        read_response(transport, rest, method, opts)
      else
        with {:ok, framing} <- Parser.body_framing(method, status, headers),
             {:ok, body} <- read_body(transport, framing, rest, opts) do
          {:ok, %Response{status: status, headers: headers, body: body}}
        end
      end
    end
  end

  # TCP is a byte stream: one recv may return half a header line or the head
  # together with part of the body. Accumulate until the empty line shows up.
  defp read_head(transport, buffer, timeout) do
    case Parser.split_head(buffer) do
      {:ok, head, _rest} when byte_size(head) > @max_head_size ->
        {:error, {:recv, :head_too_large}}

      {:ok, head, rest} ->
        {:ok, head, rest}

      :more when byte_size(buffer) > @max_head_size ->
        {:error, {:recv, :head_too_large}}

      :more ->
        with {:ok, data} <- Transport.recv(transport, timeout) do
          read_head(transport, buffer <> data, timeout)
        end
    end
  end

  defp read_body(_transport, :none, _buffer, _opts), do: {:ok, ""}

  defp read_body(transport, {:content_length, length}, buffer, opts) do
    # Known upfront: refuse before reading a single body byte.
    if length > opts[:max_body_size] do
      {:error, {:recv, :body_too_large}}
    else
      # Anything after `length` bytes is not part of this response. With
      # `connection: close` there is nothing valid it could be, so it is dropped.
      with {:ok, body, _rest} <- read_exactly(transport, length, buffer, opts[:receive_timeout]),
           do: {:ok, body}
    end
  end

  defp read_body(transport, :chunked, buffer, opts),
    do: read_chunks(transport, buffer, "", opts)

  defp read_body(transport, :until_close, buffer, opts),
    do: read_until_close(transport, buffer, opts[:max_body_size], opts[:receive_timeout])

  # Returns exactly `length` bytes and whatever was received after them.
  defp read_exactly(_transport, length, buffer, _timeout) when byte_size(buffer) >= length do
    <<bytes::binary-size(length), rest::binary>> = buffer
    {:ok, bytes, rest}
  end

  defp read_exactly(transport, length, buffer, timeout) do
    with {:ok, data} <- Transport.recv(transport, timeout) do
      read_exactly(transport, length, buffer <> data, timeout)
    end
  end

  # A chunked body is a sequence of sized chunks, ended by a zero-size chunk
  # and a (usually empty) trailer section:
  #
  #     5\r\nhello\r\n 6\r\n world\r\n 0\r\n \r\n
  #
  # The size comes before the data, so the body limit is checked before the
  # data is read. Data is read by size, never by lines: it may contain CRLF.
  defp read_chunks(transport, buffer, body, opts) do
    case Parser.parse_chunk_size(buffer) do
      {:ok, 0, rest} ->
        read_trailers(transport, rest, body, opts[:receive_timeout])

      {:ok, size, rest} ->
        if byte_size(body) + size > opts[:max_body_size],
          do: {:error, {:recv, :body_too_large}},
          else: read_chunk(transport, size, rest, body, opts)

      :more when byte_size(buffer) > @max_chunk_line ->
        {:error, {:recv, :chunk_line_too_long}}

      :more ->
        with {:ok, data} <- Transport.recv(transport, opts[:receive_timeout]) do
          read_chunks(transport, buffer <> data, body, opts)
        end

      {:error, _} = error ->
        error
    end
  end

  defp read_chunk(transport, size, buffer, body, opts) do
    case read_exactly(transport, size + 2, buffer, opts[:receive_timeout]) do
      {:ok, <<data::binary-size(size), "\r\n">>, rest} ->
        read_chunks(transport, rest, body <> data, opts)

      {:ok, _data_without_crlf, _rest} ->
        {:error, {:parse, :invalid_chunk}}

      {:error, _} = error ->
        error
    end
  end

  defp read_trailers(transport, buffer, body, timeout) do
    case Parser.parse_trailers(buffer) do
      # Trailers are validated, then dropped: merging them into the headers is
      # only safe for fields known to allow it (RFC 9110 §6.5.1).
      {:ok, _trailers, _rest} ->
        {:ok, body}

      :more when byte_size(buffer) > @max_head_size ->
        {:error, {:recv, :trailers_too_large}}

      :more ->
        case Transport.recv(transport, timeout) do
          {:ok, data} -> read_trailers(transport, buffer <> data, body, timeout)
          # Some servers close right after `0\r\n` without the final CRLF.
          # The body is complete at that point, so accept it.
          {:error, {:recv, :closed}} when buffer == "" -> {:ok, body}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp read_until_close(_transport, buffer, max_size, _timeout)
       when byte_size(buffer) > max_size,
       do: {:error, {:recv, :body_too_large}}

  defp read_until_close(transport, buffer, max_size, timeout) do
    case Transport.recv(transport, timeout) do
      {:ok, data} -> read_until_close(transport, buffer <> data, max_size, timeout)
      {:error, {:recv, :closed}} -> {:ok, buffer}
      {:error, _} = error -> error
    end
  end
end

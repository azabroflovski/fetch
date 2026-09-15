defmodule Fetch.Request do
  @moduledoc """
  Encodes an HTTP/1.1 request into bytes.

      POST /users HTTP/1.1\\r\\n
      host: example.com\\r\\n
      user-agent: fetch/0.1.0\\r\\n
      content-type: application/json\\r\\n
      content-length: 19\\r\\n
      connection: close\\r\\n
      \\r\\n
      {"name":"Jon Snow"}

  Header names are case-insensitive in HTTP, so the headers generated here are
  lowercase. User headers are sent as given.

  Some headers describe how the message itself is framed on the connection.
  They are *managed* by the client and cannot be set by the user, because a
  wrong value would desynchronize client and server:

    * `host` — derived from the URL
    * `content-length` — computed from the body
    * `transfer-encoding` — not supported for requests
    * `connection` — `close` when the connection will not be reused; absent
      otherwise, because HTTP/1.1 connections are persistent by default

  Every header name and value is validated. A value containing `\\r\\n` could
  otherwise inject extra headers or a whole second request.
  """

  alias Fetch.Parser

  @type method :: :get | :head | :post | :put | :patch | :delete | :options
  @type headers :: [{String.t(), String.t()}]

  @methods [:get, :head, :post, :put, :patch, :delete, :options]

  @managed_headers ["host", "content-length", "transfer-encoding", "connection"]

  # RFC 9110 §9.3: these methods define a meaning for request content, so a
  # client should say "no content" explicitly with content-length: 0.
  @methods_with_body [:post, :put, :patch]

  @user_agent "fetch/#{Mix.Project.config()[:version]}"

  @doc "Raises `ArgumentError` unless `method` is one the client supports."
  @spec check_method!(atom()) :: :ok
  def check_method!(method) when method in @methods, do: :ok

  def check_method!(method) do
    raise ArgumentError,
          "unsupported method #{inspect(method)}, expected one of #{inspect(@methods)}"
  end

  @doc """
  Encodes a request. `keep_alive: false` adds `connection: close`, telling the
  server the connection ends after this response.
  """
  @spec encode(method(), Fetch.URL.t(), headers(), iodata() | nil, boolean()) ::
          {:ok, iodata()} | {:error, {:request, term()}}
  def encode(method, url, headers, body, keep_alive) do
    with :ok <- validate_headers(headers) do
      {:ok,
       [
         method |> Atom.to_string() |> String.upcase(),
         " ",
         url.target,
         " HTTP/1.1\r\n",
         "host: ",
         url.authority,
         "\r\n",
         default_user_agent(headers),
         Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
         content_length(method, body),
         if(keep_alive, do: [], else: "connection: close\r\n"),
         "\r\n",
         body || ""
       ]}
    end
  end

  defp validate_headers(headers) do
    Enum.find_value(headers, :ok, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        cond do
          not Parser.token?(name) -> {:error, {:request, {:invalid_header_name, name}}}
          not Parser.field_value?(value) -> {:error, {:request, {:invalid_header_value, name}}}
          managed?(name) -> {:error, {:request, {:managed_header, String.downcase(name, :ascii)}}}
          true -> nil
        end

      other ->
        {:error, {:request, {:invalid_header, other}}}
    end)
  end

  defp managed?(name), do: String.downcase(name, :ascii) in @managed_headers

  defp default_user_agent(headers) do
    if Enum.any?(headers, fn {name, _} -> String.downcase(name, :ascii) == "user-agent" end),
      do: [],
      else: ["user-agent: ", @user_agent, "\r\n"]
  end

  defp content_length(method, nil) when method in @methods_with_body,
    do: "content-length: 0\r\n"

  defp content_length(_method, nil), do: []

  defp content_length(_method, body),
    do: ["content-length: ", Integer.to_string(IO.iodata_length(body)), "\r\n"]
end

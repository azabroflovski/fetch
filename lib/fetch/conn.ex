defmodule Fetch.Conn do
  @moduledoc """
  One HTTP/1.1 connection to one origin, reused for many requests
  (keep-alive).

      {:ok, conn} = Fetch.Conn.new("https://example.com")
      {:ok, conn, first} = Fetch.Conn.request(conn, :get, "/")
      {:ok, conn, second} = Fetch.Conn.request(conn, :get, "/other")
      conn = Fetch.Conn.close(conn)

  A connection is a value, not a process. Every request returns the updated
  connection, because a request can change it: the server may ask to close
  it, or a failure may leave it unusable. Always continue with the returned
  one.

  ## Lifecycle

      new ──► request ──► request ──► ... ──► close
                 │
                 ├─ not connected, or the idle socket was closed by the server
                 │    → connect: DNS → TCP → TLS
                 ├─ send the request, read the response
                 └─ keep the socket if the response allows it, close it otherwise

  An HTTP/1.1 connection stays open after a response unless (RFC 9112 §9.3):

    * the response says `connection: close`
    * the response is HTTP/1.0
    * the body was delimited by closing the connection
    * the server sent more bytes than the response contains
    * anything went wrong while sending or receiving

  Servers close idle connections whenever they like. Before reusing one, the
  client checks, without waiting, whether the server closed it (or sent
  something on its own, like `408 Request Timeout`) and reconnects if so. That
  is safe because nothing has been sent yet. A connection that breaks *after*
  the request was sent is an error, not a retry: the server may already have
  acted on the request.

  The socket belongs to the process that connected it and is closed when that
  process exits. Use a connection from one process.

  ## Options

  `new/2` takes the connection options of `Fetch`: `:connect_timeout`,
  `:receive_timeout`, `:max_body_size` and `:ssl`.

  `request/4` takes:

    * `:headers` — list of `{name, value}` tuples. Default `[]`.
    * `:body` — request body as iodata. Default `nil`.
    * `:keep_alive` — `false` sends `connection: close` and closes the
      connection after the response. Default `true`.

  Redirects are not followed: a connection belongs to one origin.
  """

  alias Fetch.{Parser, Request, Response, Transport, URL}

  @enforce_keys [:url, :opts]
  defstruct url: nil, opts: [], transport: nil

  @type t :: %__MODULE__{url: URL.t(), opts: keyword(), transport: Transport.t() | nil}

  @default_options [
    connect_timeout: 5_000,
    receive_timeout: 15_000,
    max_body_size: 16 * 1024 * 1024,
    ssl: []
  ]

  # A head bigger than this is not a normal response.
  @max_head_size 64 * 1024

  # Longest chunk size line (hex size + extensions) we wait for.
  @max_chunk_line 4 * 1024

  @doc """
  Creates a connection to the origin (scheme, host, port) of `url`; the path is
  ignored. Nothing happens on the network until the first request.
  """
  @spec new(String.t() | URL.t(), keyword()) :: {:ok, t()} | {:error, {:url, term()}}
  def new(url, opts \\ [])

  def new(url, opts) when is_binary(url) do
    with {:ok, url} <- URL.parse(url), do: new(url, opts)
  end

  def new(%{scheme: _, host: _, port: _} = url, opts) do
    {:ok, %__MODULE__{url: url, opts: Keyword.validate!(opts, @default_options)}}
  end

  @doc """
  Sends a request for `path` (like `"/users?page=2"`) and reads the response.

  Returns the connection to use next together with the response or the error.
  Errors are the same `{stage, reason}` as in `Fetch`, plus
  `{:url, {:invalid_path, path}}`.
  """
  @spec request(t(), Request.method(), String.t(), keyword()) ::
          {:ok, t(), Response.t()} | {:error, t(), {atom(), term()}}
  def request(%__MODULE__{} = conn, method, path, opts \\ []) do
    Request.check_method!(method)
    opts = Keyword.validate!(opts, headers: [], body: nil, keep_alive: true)
    keep_alive = opts[:keep_alive]

    with {:ok, target} <- URL.parse_target(path),
         url = %{conn.url | target: target},
         {:ok, data} <- Request.encode(method, url, opts[:headers], opts[:body], keep_alive) do
      with {:ok, conn} <- ensure_connected(conn) do
        exchange(conn, method, data, keep_alive)
      end
    else
      {:error, reason} -> {:error, conn, reason}
    end
  end

  @doc "Closes the socket, if any. The connection can still be used: the next request reconnects."
  @spec close(t()) :: t()
  def close(%__MODULE__{transport: nil} = conn), do: conn

  def close(%__MODULE__{transport: transport} = conn) do
    Transport.close(transport)
    %{conn | transport: nil}
  end

  defp ensure_connected(%{transport: nil} = conn) do
    case Transport.connect(conn.url, conn.opts) do
      {:ok, transport} -> {:ok, %{conn | transport: transport}}
      {:error, reason} -> {:error, conn, reason}
    end
  end

  # Reusing a socket: make sure the server has not closed it while it was idle.
  defp ensure_connected(conn) do
    if Transport.idle?(conn.transport),
      do: {:ok, conn},
      else: conn |> close() |> ensure_connected()
  end

  defp exchange(conn, method, data, keep_alive) do
    result =
      with :ok <- Transport.send(conn.transport, data) do
        read_response(conn.transport, "", method, conn.opts)
      end

    case result do
      {:ok, response, true} when keep_alive -> {:ok, conn, response}
      {:ok, response, _reusable} -> {:ok, close(conn), response}
      {:error, reason} -> {:error, close(conn), reason}
    end
  end

  # Returns the response and whether the connection can carry another request.
  defp read_response(transport, buffer, method, opts) do
    with {:ok, head, rest} <- read_head(transport, buffer, opts[:receive_timeout]),
         {:ok, %{version: version, status: status, headers: headers}} <- Parser.parse_head(head) do
      if status in 100..199 do
        # Interim response (e.g. 100 Continue): the real one follows.
        read_response(transport, rest, method, opts)
      else
        with {:ok, framing} <- Parser.body_framing(method, status, headers),
             {:ok, body, rest} <- read_body(transport, framing, rest, opts) do
          # Leftover bytes mean client and server disagree on where this
          # response ended; the connection cannot be trusted after that.
          reusable =
            Parser.keep_alive?(version, headers) and framing != :until_close and rest == ""

          {:ok, %Response{status: status, headers: headers, body: body}, reusable}
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

  # Every clause returns the body and the bytes received after it.
  defp read_body(_transport, :none, buffer, _opts), do: {:ok, "", buffer}

  defp read_body(transport, {:content_length, length}, buffer, opts) do
    # Known upfront: refuse before reading a single body byte.
    if length > opts[:max_body_size],
      do: {:error, {:recv, :body_too_large}},
      else: read_exactly(transport, length, buffer, opts[:receive_timeout])
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
      {:ok, _trailers, rest} ->
        {:ok, body, rest}

      :more when byte_size(buffer) > @max_head_size ->
        {:error, {:recv, :trailers_too_large}}

      :more ->
        case Transport.recv(transport, timeout) do
          {:ok, data} ->
            read_trailers(transport, buffer <> data, body, timeout)

          # Some servers close right after `0\r\n` without the final CRLF.
          # The body is complete, so accept it, but the connection is gone.
          {:error, {:recv, :closed}} when buffer == "" ->
            {:ok, body, :closed}

          {:error, _} = error ->
            error
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
      {:error, {:recv, :closed}} -> {:ok, buffer, ""}
      {:error, _} = error -> error
    end
  end
end

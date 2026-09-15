defmodule Fetch.TestServer do
  @moduledoc false
  # A deliberately dumb local server for tests. It does not speak HTTP: the
  # handler writes whatever bytes the test wants, including broken ones.

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @localhost {127, 0, 0, 1}

  @doc """
  Starts a TCP server on 127.0.0.1 and returns its port. Connections are handled
  one at a time by `handler.({:gen_tcp, socket})`; the socket is closed after.
  The server is stopped when the test ends.
  """
  def start(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: @localhost])

    {:ok, port} = :inet.port(listen)
    supervise(fn -> tcp_loop(listen, handler) end)
    port
  end

  @doc "Same as `start/1`, but over TLS with the given `certs_keys` entry."
  def start_tls(handler, cert_key) do
    {:ok, listen} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: @localhost,
        certs_keys: [cert_key]
      ])

    {:ok, {_ip, port}} = :ssl.sockname(listen)
    supervise(fn -> tls_loop(listen, handler) end)
    port
  end

  @doc """
  Generates a CA and a server certificate valid for `names` (DNS names or IP
  tuples). Returns `%{cert_key: %{cert: der, key: key}, cacerts: [der]}`.
  """
  def certificates(names \\ ["localhost", @localhost]) do
    san =
      Enum.map(names, fn
        name when is_binary(name) -> {:dNSName, String.to_charlist(name)}
        {a, b, c, d} -> {:iPAddress, <<a, b, c, d>>}
      end)

    key = [key: {:rsa, 2048, 65537}, digest: :sha256]
    extensions = [extensions: [{:Extension, {2, 5, 29, 17}, false, san}]]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key ++ extensions},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    server = data[:server_config]

    %{
      cert_key: %{cert: server[:cert], key: server[:key]},
      cacerts: data[:client_config][:cacerts]
    }
  end

  @doc """
  Reads a request: the head and a content-length body. Returns `:closed` if
  the client closes the connection (or stays silent) first. Test-only, naive.
  """
  def read_request({module, socket}), do: read_request(module, socket, "")

  defp read_request(module, socket, buffer) do
    with [head, body] <- :binary.split(buffer, "\r\n\r\n"),
         length = content_length(head),
         true <- byte_size(body) >= length do
      buffer
    else
      _ ->
        case module.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(module, socket, buffer <> data)
          {:error, _closed_or_timeout} -> :closed
        end
    end
  end

  defp content_length(head) do
    case Regex.run(~r/\r\ncontent-length: (\d+)/i, head) do
      [_, length] -> String.to_integer(length)
      nil -> 0
    end
  end

  defp supervise(fun) do
    start_supervised!(Supervisor.child_spec({Task, fun}, id: make_ref()))
  end

  defp tcp_loop(listen, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    handler.({:gen_tcp, socket})
    :gen_tcp.close(socket)
    tcp_loop(listen, handler)
  end

  defp tls_loop(listen, handler) do
    {:ok, socket} = :ssl.transport_accept(listen)

    # The client may legitimately refuse our certificate; keep serving.
    with {:ok, socket} <- :ssl.handshake(socket, 5_000) do
      handler.({:ssl, socket})
      :ssl.close(socket)
    end

    tls_loop(listen, handler)
  end
end

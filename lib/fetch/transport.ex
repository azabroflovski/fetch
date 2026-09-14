defmodule Fetch.Transport do
  @moduledoc """
  Moves bytes between us and the server: DNS, TCP and TLS.

  A connected transport is a tuple `{module, socket}` where `module` is
  `:gen_tcp` or `:ssl`. Both modules have the same `send/2`, `recv/3` and
  `close/1`, so the rest of the client does not care which one it talks to.

      connect/2
        ├─ DNS   :inet.getaddrs/3        "example.com" → [{93, 184, 215, 14}]
        ├─ TCP   :gen_tcp.connect/4      try each address in order
        └─ TLS   :ssl.connect/3          upgrade the TCP socket (https only)

  Sockets are in passive mode (`active: false`): data waits in the socket
  until `recv/2` asks for it, so no process messages are involved.
  """

  @type t :: {:gen_tcp, :gen_tcp.socket()} | {:ssl, :ssl.sslsocket()}

  @spec connect(Fetch.URL.t(), keyword()) ::
          {:ok, t()} | {:error, {:dns | :connect | :tls, term()}}
  def connect(%{scheme: scheme, host: host, port: port}, opts) do
    timeout = Keyword.fetch!(opts, :connect_timeout)

    with {:ok, addresses} <- resolve(host, timeout),
         {:ok, socket} <- connect_tcp(addresses, port, timeout, opts) do
      case scheme do
        :http -> {:ok, {:gen_tcp, socket}}
        :https -> connect_tls(socket, host, timeout, Keyword.fetch!(opts, :ssl))
      end
    end
  end

  @spec send(t(), iodata()) :: :ok | {:error, {:send, term()}}
  def send({module, socket}, data) do
    case module.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send, reason}}
    end
  end

  @doc """
  Returns whatever bytes are available, waiting at most `timeout` ms for them.
  `{:error, {:recv, :closed}}` means the server closed the connection.
  """
  @spec recv(t(), timeout()) :: {:ok, binary()} | {:error, {:recv, term()}}
  def recv({module, socket}, timeout) do
    case module.recv(socket, 0, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:recv, reason}}
    end
  end

  @spec close(t()) :: :ok
  def close({module, socket}) do
    module.close(socket)
    :ok
  end

  # An IP literal needs no lookup. Otherwise ask for IPv4 addresses first and
  # fall back to IPv6. (Racing both is "happy eyeballs", a non-goal.)
  defp resolve(host, timeout) do
    host = String.to_charlist(host)

    with {:error, :einval} <- :inet.parse_address(host),
         {:error, _} <- :inet.getaddrs(host, :inet, timeout),
         {:error, reason} <- :inet.getaddrs(host, :inet6, timeout) do
      {:error, {:dns, reason}}
    else
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      {:ok, address} -> {:ok, [address]}
    end
  end

  defp connect_tcp(addresses, port, timeout, opts) do
    Enum.reduce_while(addresses, nil, fn address, _last_error ->
      tcp_opts = [
        family(address),
        :binary,
        active: false,
        # We read raw bytes and parse HTTP ourselves. `packet: :http_bin`
        # would make the VM parse the head for us.
        packet: :raw,
        # gen_tcp waits forever on a blocked send by default.
        send_timeout: Keyword.fetch!(opts, :receive_timeout),
        send_timeout_close: true
      ]

      case :gen_tcp.connect(address, port, tcp_opts, timeout) do
        {:ok, socket} -> {:halt, {:ok, socket}}
        {:error, reason} -> {:cont, {:error, {:connect, reason}}}
      end
    end)
  end

  defp family(address) when tuple_size(address) == 8, do: :inet6
  defp family(_address), do: :inet

  defp connect_tls(tcp_socket, host, timeout, user_opts) do
    case :ssl.connect(tcp_socket, tls_options(host, user_opts), timeout) do
      {:ok, socket} ->
        {:ok, {:ssl, socket}}

      {:error, reason} ->
        :gen_tcp.close(tcp_socket)
        {:error, {:tls, reason}}
    end
  end

  # An upgraded socket has no host name attached, so `server_name_indication`
  # is both the SNI sent to the server and the name the certificate is checked
  # against. Setting it to `:disable` would silently skip hostname verification.
  defp tls_options(host, user_opts) do
    defaults = [
      verify: :verify_peer,
      server_name_indication: String.to_charlist(host),
      # Default hostname matching does not accept wildcard certificates
      # (*.example.com); the :https match fun does, following RFC 6125.
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    # `cacerts` overrides `cacertfile` in :ssl, so the OS store is only added
    # when the user brings no trust store of their own.
    defaults =
      if Keyword.has_key?(user_opts, :cacerts) or Keyword.has_key?(user_opts, :cacertfile),
        do: defaults,
        else: [{:cacerts, :public_key.cacerts_get()} | defaults]

    Keyword.merge(defaults, user_opts)
  end
end

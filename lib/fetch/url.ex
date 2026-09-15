defmodule Fetch.URL do
  @moduledoc """
  Turns a URL string into the pieces an HTTP/1.1 request needs.

  URI syntax is tokenized by `URI.new/1` from the standard library. This
  module adds the HTTP-specific part:

    * only `http` and `https` schemes
    * a host is required
    * default ports: 80 for http, 443 for https
    * the *request target* (`/path?query`) — the fragment is never sent,
      it only exists on the client side
    * the *authority* for the `host` header — the port is omitted when it is
      the default one, IPv6 literals are put back into brackets
    * `user:pass@host` is rejected: silently dropping credentials or sending
      them is a decision we do not make implicitly
  """

  @type t :: %{
          scheme: :http | :https,
          host: String.t(),
          port: :inet.port_number(),
          authority: String.t(),
          target: String.t()
        }

  @default_ports %{http: 80, https: 443}

  @spec parse(String.t()) :: {:ok, t()} | {:error, {:url, term()}}
  def parse(url) when is_binary(url) do
    with {:ok, uri} <- new_uri(url),
         {:ok, scheme} <- scheme(uri.scheme),
         :ok <- check_host(uri.host),
         :ok <- check_userinfo(uri.userinfo) do
      port = uri.port || @default_ports[scheme]

      {:ok,
       %{
         scheme: scheme,
         host: uri.host,
         port: port,
         authority: authority(uri.host, port, scheme),
         target: target(uri.path, uri.query)
       }}
    end
  end

  @doc """
  Validates a request path such as `/users?page=2` for a connection that
  already knows its origin. The fragment is dropped.
  """
  @spec parse_target(String.t()) :: {:ok, String.t()} | {:error, {:url, term()}}
  def parse_target("/" <> _ = path) do
    # Parsed behind a placeholder origin: on its own, "//double/slash" would be
    # read as a host name.
    case URI.new("http://localhost" <> path) do
      {:ok, uri} -> {:ok, target(uri.path, uri.query)}
      {:error, _part} -> {:error, {:url, {:invalid_path, path}}}
    end
  end

  def parse_target(path), do: {:error, {:url, {:invalid_path, path}}}

  defp new_uri(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, {:url, :invalid_url}}
    end
  end

  defp scheme("http"), do: {:ok, :http}
  defp scheme("https"), do: {:ok, :https}
  defp scheme(nil), do: {:error, {:url, :missing_scheme}}
  defp scheme(other), do: {:error, {:url, {:unsupported_scheme, other}}}

  defp check_host(host) when host in [nil, ""], do: {:error, {:url, :missing_host}}
  defp check_host(_host), do: :ok

  defp check_userinfo(nil), do: :ok
  defp check_userinfo(_userinfo), do: {:error, {:url, :userinfo_not_supported}}

  defp authority(host, port, scheme) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    if port == @default_ports[scheme], do: host, else: "#{host}:#{port}"
  end

  defp target(path, query) do
    path = if path in [nil, ""], do: "/", else: path

    if query, do: path <> "?" <> query, else: path
  end
end

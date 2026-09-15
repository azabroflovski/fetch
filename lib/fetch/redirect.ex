defmodule Fetch.Redirect do
  @moduledoc """
  Decides whether a response is a redirect and builds the next request.

  Only these statuses are followed (RFC 9110 §15.4):

  | status | next request |
  | --- | --- |
  | 301 Moved Permanently, 302 Found | POST becomes GET, other methods are kept |
  | 303 See Other | anything but HEAD becomes GET |
  | 307 Temporary Redirect, 308 Permanent Redirect | same method and body |

  301 and 302 were meant to keep the method, but browsers turned POST into GET
  and the RFC now allows it. 307 and 308 were added to say "really keep it".
  Other 3xx codes (300 Multiple Choices, 304 Not Modified) are responses, not
  instructions to follow.

  When the method becomes GET, the body and the headers describing it are
  dropped. When the redirect leaves the origin (scheme, host or port),
  credentials are dropped, so a redirect cannot leak them to another server.
  """

  alias Fetch.{Response, URL}

  @type request :: %{
          method: Fetch.Request.method(),
          url: URL.t(),
          headers: Fetch.Request.headers(),
          body: iodata() | nil
        }

  @redirect_statuses [301, 302, 303, 307, 308]

  # Headers that only make sense together with the body (Fetch Standard,
  # "request-body-header name").
  @body_headers ["content-type", "content-encoding", "content-language", "content-location"]

  @credential_headers ["authorization", "proxy-authorization", "cookie"]

  @doc """
  Returns the request to send after `response`, `:none` when the response is
  not a redirect to follow, or an error when the redirect is broken.
  """
  @spec next_request(request(), Response.t()) ::
          {:ok, request()} | :none | {:error, {:redirect, term()}}
  def next_request(request, %Response{status: status} = response)
      when status in @redirect_statuses do
    case Response.get_header(response, "location") do
      [] ->
        :none

      [location] ->
        with {:ok, url} <- resolve(request.url, location) do
          {:ok, request |> change_method(status) |> change_url(url)}
        end

      _locations ->
        {:error, {:redirect, :multiple_locations}}
    end
  end

  def next_request(_request, _response), do: :none

  # `location` may be relative ("/login", "../next", "//cdn.test/file"). It is
  # resolved against the URL that was requested (RFC 9110 §10.2.2, RFC 3986 §5).
  defp resolve(base, location) do
    base = "#{base.scheme}://#{base.authority}#{base.target}"

    case base |> URI.merge(location) |> URI.to_string() |> URL.parse() do
      {:ok, url} -> {:ok, url}
      {:error, _} -> {:error, {:redirect, {:invalid_location, location}}}
    end
  end

  defp change_method(%{method: method} = request, status)
       when (status in [301, 302] and method == :post) or
              (status == 303 and method not in [:get, :head]) do
    %{request | method: :get, body: nil, headers: drop(request.headers, @body_headers)}
  end

  defp change_method(request, _status), do: request

  defp change_url(request, url) do
    headers =
      if same_origin?(request.url, url),
        do: request.headers,
        else: drop(request.headers, @credential_headers)

    %{request | url: url, headers: headers}
  end

  defp same_origin?(a, b) do
    a.scheme == b.scheme and a.port == b.port and
      String.downcase(a.host, :ascii) == String.downcase(b.host, :ascii)
  end

  defp drop(headers, names) do
    Enum.reject(headers, fn {name, _value} -> String.downcase(name, :ascii) in names end)
  end
end

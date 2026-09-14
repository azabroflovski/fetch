defmodule Fetch.URLTest do
  use ExUnit.Case, async: true

  alias Fetch.URL

  test "http with defaults" do
    assert URL.parse("http://example.com") ==
             {:ok,
              %{
                scheme: :http,
                host: "example.com",
                port: 80,
                authority: "example.com",
                target: "/"
              }}
  end

  test "https with default port" do
    assert {:ok, %{scheme: :https, port: 443, authority: "example.com"}} =
             URL.parse("https://example.com/")
  end

  test "explicit port, path and query" do
    assert {:ok, url} = URL.parse("https://example.com:8443/api/users?id=123")
    assert url.port == 8443
    assert url.authority == "example.com:8443"
    assert url.target == "/api/users?id=123"
  end

  test "an explicit default port is omitted from the authority" do
    assert {:ok, %{authority: "example.com"}} = URL.parse("http://example.com:80/")
  end

  test "the fragment is never part of the request target" do
    assert {:ok, %{target: "/docs?x=1"}} = URL.parse("http://example.com/docs?x=1#section")
  end

  test "empty query is kept" do
    assert {:ok, %{target: "/?"}} = URL.parse("http://example.com/?")
  end

  test "IPv6 literal is bracketed in the authority" do
    assert {:ok, %{host: "::1", authority: "[::1]:8080"}} = URL.parse("http://[::1]:8080/")
  end

  test "errors" do
    assert URL.parse("example.com") == {:error, {:url, :missing_scheme}}
    assert URL.parse("ftp://example.com") == {:error, {:url, {:unsupported_scheme, "ftp"}}}
    assert URL.parse("http://") == {:error, {:url, :missing_host}}
    assert URL.parse("http:///path") == {:error, {:url, :missing_host}}
    assert URL.parse("http://user:pass@example.com") == {:error, {:url, :userinfo_not_supported}}
    assert URL.parse("http://exa mple.com/") == {:error, {:url, :invalid_url}}
    assert URL.parse("http://example.com/a b") == {:error, {:url, :invalid_url}}
    assert URL.parse("http://example.com/\r\nx") == {:error, {:url, :invalid_url}}
  end
end

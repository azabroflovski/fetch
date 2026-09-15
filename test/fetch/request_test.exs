defmodule Fetch.RequestTest do
  use ExUnit.Case, async: true

  alias Fetch.Request

  @ua "user-agent: fetch/#{Mix.Project.config()[:version]}\r\n"

  defp encode(method, url, headers \\ [], body \\ nil) do
    {:ok, url} = Fetch.URL.parse(url)

    with {:ok, iodata} <- Request.encode(method, url, headers, body, false) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  test "GET" do
    assert encode(:get, "http://example.com") ==
             {:ok,
              "GET / HTTP/1.1\r\n" <>
                "host: example.com\r\n" <>
                @ua <>
                "connection: close\r\n" <>
                "\r\n"}
  end

  test "keep-alive requests send no connection header" do
    {:ok, url} = Fetch.URL.parse("http://example.com")
    assert {:ok, iodata} = Request.encode(:get, url, [], nil, true)

    assert IO.iodata_to_binary(iodata) ==
             "GET / HTTP/1.1\r\nhost: example.com\r\n" <> @ua <> "\r\n"
  end

  test "check_method!/1" do
    for method <- [:get, :head, :post, :put, :patch, :delete, :options] do
      assert Request.check_method!(method) == :ok
    end

    assert_raise ArgumentError, ~r/unsupported method :trace/, fn ->
      Request.check_method!(:trace)
    end
  end

  test "POST with headers and body" do
    assert encode(:post, "http://example.com/users", [{"Content-Type", "application/json"}], [
             "{\"name\":",
             "\"Jon Snow\"}"
           ]) ==
             {:ok,
              "POST /users HTTP/1.1\r\n" <>
                "host: example.com\r\n" <>
                @ua <>
                "Content-Type: application/json\r\n" <>
                "content-length: 19\r\n" <>
                "connection: close\r\n" <>
                "\r\n" <>
                "{\"name\":\"Jon Snow\"}"}
  end

  test "POST, PUT and PATCH without body send content-length: 0" do
    for method <- [:post, :put, :patch] do
      assert {:ok, request} = encode(method, "http://example.com")
      assert request =~ "\r\ncontent-length: 0\r\n"
    end

    for method <- [:get, :head, :delete, :options] do
      assert {:ok, request} = encode(method, "http://example.com")
      refute request =~ "content-length"
    end
  end

  test "content-length counts bytes, not characters" do
    assert {:ok, request} = encode(:put, "http://example.com", [], "привет")
    assert request =~ "content-length: 12\r\n"
  end

  test "non-default port and query go to host and target" do
    assert {:ok, "DELETE /users/1?force=true HTTP/1.1\r\nhost: localhost:4000\r\n" <> _} =
             encode(:delete, "http://localhost:4000/users/1?force=true")
  end

  test "user-agent can be overridden" do
    assert {:ok, request} = encode(:get, "http://example.com", [{"User-Agent", "test"}])
    refute request =~ "fetch/"
    assert request =~ "\r\nUser-Agent: test\r\n"
  end

  test "duplicate user headers are sent as given" do
    assert {:ok, request} = encode(:get, "http://example.com", [{"accept", "a"}, {"accept", "b"}])
    assert request =~ "\r\naccept: a\r\naccept: b\r\n"
  end

  test "header injection is rejected" do
    assert encode(:get, "http://example.com", [{"x-a", "1\r\nx-injected: 1"}]) ==
             {:error, {:request, {:invalid_header_value, "x-a"}}}

    assert encode(:get, "http://example.com", [{"x-a", "1\nx"}]) ==
             {:error, {:request, {:invalid_header_value, "x-a"}}}

    assert encode(:get, "http://example.com", [{"x-a", <<?a, 0>>}]) ==
             {:error, {:request, {:invalid_header_value, "x-a"}}}

    assert encode(:get, "http://example.com", [{"x-a\r\nx-b", "1"}]) ==
             {:error, {:request, {:invalid_header_name, "x-a\r\nx-b"}}}
  end

  test "invalid header names" do
    for name <- ["", "x a", "x:a", "x-a ", "é"] do
      assert encode(:get, "http://example.com", [{name, "1"}]) ==
               {:error, {:request, {:invalid_header_name, name}}}
    end

    assert encode(:get, "http://example.com", [{:accept, "1"}]) ==
             {:error, {:request, {:invalid_header, {:accept, "1"}}}}
  end

  test "managed headers cannot be set" do
    for name <- ["Host", "content-length", "Transfer-Encoding", "CONNECTION"] do
      assert encode(:get, "http://example.com", [{name, "x"}]) ==
               {:error, {:request, {:managed_header, String.downcase(name)}}}
    end
  end
end

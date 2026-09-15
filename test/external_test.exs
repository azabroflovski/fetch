defmodule Fetch.ExternalTest do
  # Real internet. Excluded by default: mix test --include external
  use ExUnit.Case, async: true

  @moduletag :external

  test "HTTPS GET with content-length body" do
    assert {:ok, response} = Fetch.get("https://www.erlang.org/")
    assert response.status == 200
    [length] = Fetch.Response.get_header(response, "content-length")
    assert byte_size(response.body) == String.to_integer(length)
  end

  test "HTTPS GET to example.com (chunked at the time of writing)" do
    assert {:ok, response} = Fetch.get("https://example.com")
    assert response.status == 200
    assert response.body =~ "Example Domain"
  end

  test "follows an http → https redirect" do
    assert {:ok, %Fetch.Response{status: 200}} = Fetch.get("http://www.erlang.org/")
  end

  test "keep-alive over HTTPS reuses the connection" do
    {:ok, conn} = Fetch.Conn.new("https://www.erlang.org")

    assert {:ok, conn, %Fetch.Response{status: 200}} = Fetch.Conn.request(conn, :get, "/")
    socket = conn.transport
    assert socket != nil

    assert {:ok, conn, %Fetch.Response{status: 200}} = Fetch.Conn.request(conn, :get, "/")
    assert conn.transport == socket

    Fetch.Conn.close(conn)
  end

  test "HTTPS HEAD to example.com" do
    assert {:ok, %Fetch.Response{status: 200, body: ""}} = Fetch.head("https://example.com")
  end
end

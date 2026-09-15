defmodule Fetch.ConnTest do
  use ExUnit.Case, async: true

  alias Fetch.{Conn, Response, TestServer}

  # Failed TLS handshakes and closed sockets are logged by :ssl.
  @moduletag :capture_log

  @ok "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"

  # A server that keeps every connection open and answers requests on it until
  # the client closes it or a reply says `connection: close`. Each accepted
  # connection and each request is reported to the test process. `reply` is a
  # response binary or a function from the request to one.
  defp serve(reply, start \\ &TestServer.start/1) do
    test = self()

    start.(fn conn ->
      send(test, :connected)
      serve_requests(conn, reply, test)
    end)
  end

  defp serve_requests({module, socket} = conn, reply, test) do
    with request when is_binary(request) <- TestServer.read_request(conn) do
      send(test, {:request, request})
      response = if is_function(reply), do: reply.(request), else: reply
      module.send(socket, response)

      if not String.match?(response, ~r/\r\nconnection: close\r\n/i) do
        serve_requests(conn, reply, test)
      end
    end
  end

  defp url(port), do: "http://localhost:#{port}"

  test "sequential requests share one connection" do
    port =
      serve(fn
        "GET /1 " <> _ ->
          "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none"

        "POST /2 " <> _ ->
          "HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ntwo\r\n0\r\n\r\n"

        "HEAD /3 " <> _ ->
          "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"

        "GET /4 " <> _ ->
          "HTTP/1.1 204 No Content\r\n\r\n"
      end)

    {:ok, conn} = Conn.new(url(port))

    assert {:ok, conn, %Response{status: 200, body: "one"}} = Conn.request(conn, :get, "/1")

    assert {:ok, conn, %Response{status: 201, body: "two"}} =
             Conn.request(conn, :post, "/2", body: ~s({"name":"Jon Snow"}))

    assert {:ok, conn, %Response{status: 200, body: ""}} = Conn.request(conn, :head, "/3")
    assert {:ok, conn, %Response{status: 204}} = Conn.request(conn, :get, "/4")
    assert %Conn{transport: nil} = Conn.close(conn)

    assert_received :connected
    refute_received :connected

    assert_received {:request, "GET /1 HTTP/1.1\r\n" <> first}
    refute first =~ "connection"
    assert_received {:request, "POST /2 HTTP/1.1\r\n" <> _}
    assert_received {:request, "HEAD /3 HTTP/1.1\r\n" <> _}
    assert_received {:request, "GET /4 HTTP/1.1\r\n" <> _}
  end

  test "new/2 does not connect" do
    port = serve(@ok)
    {:ok, conn} = Conn.new(url(port))

    assert conn.transport == nil
    refute_received :connected
  end

  test "connection: close from the server ends the connection; the next request reconnects" do
    port =
      serve(fn
        "GET /bye " <> _ -> "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nbye"
        "GET /hello " <> _ -> @ok
      end)

    {:ok, conn} = Conn.new(url(port))

    assert {:ok, conn, %Response{body: "bye"}} = Conn.request(conn, :get, "/bye")
    assert conn.transport == nil

    assert {:ok, conn, %Response{body: "ok"}} = Conn.request(conn, :get, "/hello")
    assert conn.transport != nil
    Conn.close(conn)

    assert_received :connected
    assert_received :connected
  end

  test "responses that do not allow reuse close the connection" do
    for response <- [
          "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok",
          "HTTP/1.1 200 OK\r\nConnection: keep-alive, close\r\nContent-Length: 2\r\n\r\nok",
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXTRA"
        ] do
      port = serve(response)
      {:ok, conn} = Conn.new(url(port))

      assert {:ok, %Conn{transport: nil}, %Response{body: "ok"}} = Conn.request(conn, :get, "/")
    end
  end

  test "a body delimited by close ends the connection" do
    port =
      TestServer.start(fn {module, socket} = conn ->
        TestServer.read_request(conn)
        module.send(socket, "HTTP/1.1 200 OK\r\n\r\nuntil close")
      end)

    {:ok, conn} = Conn.new(url(port))

    assert {:ok, %Conn{transport: nil}, %Response{body: "until close"}} =
             Conn.request(conn, :get, "/")
  end

  test "keep_alive: false asks the server to close and closes" do
    port = serve(@ok)
    {:ok, conn} = Conn.new(url(port))

    assert {:ok, %Conn{transport: nil}, %Response{body: "ok"}} =
             Conn.request(conn, :get, "/", keep_alive: false)

    assert_received {:request, request}
    assert request =~ "\r\nconnection: close\r\n"
  end

  describe "idle connections" do
    test "closed by the server are replaced before sending" do
      test = self()

      # Answers one request per connection, then closes without saying so.
      port =
        TestServer.start(fn {module, socket} = conn ->
          send(test, :connected)
          TestServer.read_request(conn)
          module.send(socket, @ok)
        end)

      {:ok, conn} = Conn.new(url(port))

      assert {:ok, conn, %Response{body: "ok"}} = Conn.request(conn, :get, "/1")
      assert conn.transport != nil

      # Give the server's FIN time to arrive.
      Process.sleep(50)

      assert {:ok, conn, %Response{body: "ok"}} = Conn.request(conn, :get, "/2")
      Conn.close(conn)

      assert_received :connected
      assert_received :connected
    end

    test "with unsolicited bytes are replaced before sending" do
      test = self()

      port =
        TestServer.start(fn {module, socket} = conn ->
          send(test, :connected)
          TestServer.read_request(conn)
          module.send(socket, @ok)
          Process.sleep(10)
          module.send(socket, "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\n\r\n")
          Process.sleep(100)
        end)

      {:ok, conn} = Conn.new(url(port))

      assert {:ok, conn, %Response{status: 200}} = Conn.request(conn, :get, "/1")
      Process.sleep(50)
      assert {:ok, conn, %Response{status: 200}} = Conn.request(conn, :get, "/2")
      Conn.close(conn)

      assert_received :connected
      assert_received :connected
    end
  end

  describe "errors" do
    test "a failed request closes the connection; the next one reconnects" do
      port =
        serve(fn
          "GET /broken " <> _ -> "HTTP/1.1 200 OK\r\nContent-Length : 2\r\n\r\nok"
          "GET /fine " <> _ -> @ok
        end)

      {:ok, conn} = Conn.new(url(port))

      assert {:error, conn, {:parse, {:invalid_header, "Content-Length : 2"}}} =
               Conn.request(conn, :get, "/broken")

      assert conn.transport == nil
      assert {:ok, conn, %Response{body: "ok"}} = Conn.request(conn, :get, "/fine")
      Conn.close(conn)

      assert_received :connected
      assert_received :connected
    end

    test "a server that closes after receiving the request is an error, not a retry" do
      test = self()

      port =
        TestServer.start(fn conn ->
          send(test, :connected)
          TestServer.read_request(conn)
        end)

      {:ok, conn} = Conn.new(url(port))

      assert {:error, %Conn{transport: nil}, {:recv, :closed}} = Conn.request(conn, :post, "/")
      assert_received :connected
      refute_received :connected
    end

    test "invalid paths and headers fail without connecting" do
      {:ok, conn} = Conn.new("http://localhost:1")

      assert Conn.request(conn, :get, "users") ==
               {:error, conn, {:url, {:invalid_path, "users"}}}

      assert Conn.request(conn, :get, "http://other.test/") ==
               {:error, conn, {:url, {:invalid_path, "http://other.test/"}}}

      assert Conn.request(conn, :get, "/", headers: [{"x", "a\r\nb"}]) ==
               {:error, conn, {:request, {:invalid_header_value, "x"}}}
    end

    test "connection errors come from the request" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      {:ok, conn} = Conn.new("http://127.0.0.1:#{port}")

      assert {:error, %Conn{transport: nil}, {:connect, :econnrefused}} =
               Conn.request(conn, :get, "/")
    end

    test "new/2 validates the URL and options" do
      assert Conn.new("ftp://files.test") == {:error, {:url, {:unsupported_scheme, "ftp"}}}

      assert_raise ArgumentError, ~r/unknown keys \[:follow_redirects\]/, fn ->
        Conn.new("http://a.test", follow_redirects: false)
      end

      {:ok, conn} = Conn.new("http://a.test")

      assert_raise ArgumentError, ~r/unsupported method :trace/, fn ->
        Conn.request(conn, :trace, "/")
      end
    end
  end

  test "close/1 can be called on a closed connection" do
    {:ok, conn} = Conn.new("http://a.test")
    assert conn |> Conn.close() |> Conn.close() == conn
  end

  test "an HTTPS connection is reused" do
    certs = TestServer.certificates()
    port = serve(@ok, &TestServer.start_tls(&1, certs.cert_key))

    {:ok, conn} = Conn.new("https://localhost:#{port}", ssl: [cacerts: certs.cacerts])

    assert {:ok, conn, %Response{body: "ok"}} = Conn.request(conn, :get, "/1")
    assert {:ok, conn, %Response{body: "ok"}} = Conn.request(conn, :get, "/2")
    Conn.close(conn)

    assert_received :connected
    refute_received :connected
  end
end

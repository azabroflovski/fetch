defmodule FetchTest do
  use ExUnit.Case, async: true

  alias Fetch.{Response, TestServer}

  doctest Fetch.Response

  # Starts a server that captures the request, sends it to the test process and
  # replies with `response` (a binary, or a list of chunks sent separately).
  defp serve(response) do
    test = self()

    port =
      TestServer.start(fn {mod, socket} = conn ->
        send(test, {:request, TestServer.read_request(conn)})

        # The client may close early (e.g. on a size limit), so sends may fail.
        for chunk <- List.wrap(response) do
          mod.send(socket, chunk)
          Process.sleep(1)
        end
      end)

    "http://localhost:#{port}"
  end

  describe "request and response" do
    test "GET sends a well-formed request and parses the response" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello")

      assert {:ok, response} = Fetch.get(url <> "/path?x=1", headers: [{"accept", "text/plain"}])

      assert response == %Response{
               status: 200,
               headers: [{"content-type", "text/plain"}, {"content-length", "5"}],
               body: "hello"
             }

      assert_received {:request, request}
      "http://" <> authority = url

      assert request ==
               "GET /path?x=1 HTTP/1.1\r\n" <>
                 "host: #{authority}\r\n" <>
                 "user-agent: fetch/#{Mix.Project.config()[:version]}\r\n" <>
                 "accept: text/plain\r\n" <>
                 "connection: close\r\n\r\n"
    end

    test "POST sends the body" do
      url = serve("HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")

      assert {:ok, %Response{status: 201, body: ""}} =
               Fetch.post(url <> "/users",
                 headers: [{"content-type", "application/json"}],
                 body: ~s({"name":"Jon Snow"})
               )

      assert_received {:request, request}
      assert request =~ "POST /users HTTP/1.1\r\n"
      assert request =~ "\r\ncontent-length: 19\r\n"
      assert String.ends_with?(request, "\r\n\r\n{\"name\":\"Jon Snow\"}")
    end

    test "all helpers use their method" do
      for {fun, name} <- [put: "PUT", patch: "PATCH", delete: "DELETE", head: "HEAD"] do
        url = serve("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        assert {:ok, %Response{status: 200}} = apply(Fetch, fun, [url])
        assert_received {:request, request}
        assert String.starts_with?(request, name <> " / HTTP/1.1\r\n")
      end

      url = serve("HTTP/1.1 204 No Content\r\n\r\n")
      assert {:ok, %Response{status: 204}} = Fetch.request(:options, url)
      assert_received {:request, "OPTIONS / HTTP/1.1\r\n" <> _}
    end

    test "HTTP error statuses are responses, not errors" do
      url = serve("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found")
      assert {:ok, %Response{status: 404, body: "not found"}} = Fetch.get(url)
    end

    test "duplicate headers are preserved" do
      url =
        serve(
          "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nContent-Length: 0\r\nset-cookie: b=2\r\n\r\n"
        )

      assert {:ok, response} = Fetch.get(url)
      assert Response.get_header(response, "set-cookie") == ["a=1", "b=2"]
      assert Response.get_header(response, "x-missing") == []
    end

    test "binary body" do
      body = for byte <- 0..255, into: "", do: <<byte>>
      url = serve(["HTTP/1.1 200 OK\r\nContent-Length: 256\r\n\r\n", body])

      assert {:ok, %Response{body: ^body}} = Fetch.get(url)
    end

    test "bytes after content-length are ignored" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXTRA")
      assert {:ok, %Response{body: "ok"}} = Fetch.get(url)
    end

    test "body delimited by connection close" do
      url = serve(["HTTP/1.1 200 OK\r\n\r\n", "part 1, ", "part 2"])
      assert {:ok, %Response{status: 200, body: "part 1, part 2"}} = Fetch.get(url)
    end

    test "HEAD response has no body even with content-length" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n")
      assert {:ok, %Response{status: 200, body: ""}} = Fetch.head(url, receive_timeout: 1_000)
    end

    test "204 and 304 have no body" do
      url = serve("HTTP/1.1 304 Not Modified\r\nContent-Length: 10\r\n\r\n")
      assert {:ok, %Response{status: 304, body: ""}} = Fetch.get(url, receive_timeout: 1_000)
    end

    test "interim 1xx responses are skipped" do
      url =
        serve(
          "HTTP/1.1 100 Continue\r\n\r\n" <>
            "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\n" <>
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        )

      assert {:ok, %Response{status: 200, headers: [{"content-length", "2"}], body: "ok"}} =
               Fetch.get(url)
    end

    test "response split into tiny TCP chunks" do
      response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world"
      chunks = for <<byte <- response>>, do: <<byte>>
      url = serve(chunks)

      assert {:ok, %Response{status: 200, body: "hello world"}} = Fetch.get(url)
    end
  end

  describe "malformed responses" do
    test "invalid status line" do
      url = serve("HTTP/1.1 OK\r\n\r\n")
      assert Fetch.get(url) == {:error, {:parse, {:invalid_status_line, "HTTP/1.1 OK"}}}
    end

    test "not HTTP at all" do
      url = serve("SSH-2.0-OpenSSH_9.0\r\n\r\n")
      assert {:error, {:parse, {:invalid_status_line, _}}} = Fetch.get(url)
    end

    test "invalid header" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length : 5\r\n\r\nhello")
      assert Fetch.get(url) == {:error, {:parse, {:invalid_header, "Content-Length : 5"}}}
    end

    test "conflicting content-length" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 50\r\n\r\nhello")
      assert Fetch.get(url) == {:error, {:parse, {:invalid_content_length, "5, 50"}}}
    end

    test "chunked is not supported yet" do
      url = serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
      assert Fetch.get(url) == {:error, {:parse, {:unsupported_transfer_encoding, "chunked"}}}
    end

    test "connection closed before the head is complete" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Len")
      assert Fetch.get(url) == {:error, {:recv, :closed}}
    end

    test "connection closed without any response" do
      url = serve("")
      assert Fetch.get(url) == {:error, {:recv, :closed}}
    end

    test "connection closed before content-length bytes arrived" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\ntoo short")
      assert Fetch.get(url) == {:error, {:recv, :closed}}
    end
  end

  describe "limits and timeouts" do
    test "receive timeout" do
      port = TestServer.start(fn _conn -> Process.sleep(500) end)

      assert Fetch.get("http://localhost:#{port}", receive_timeout: 50) ==
               {:error, {:recv, :timeout}}
    end

    test "receive timeout while the body is being sent" do
      port =
        TestServer.start(fn {mod, socket} = conn ->
          TestServer.read_request(conn)
          mod.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhel")
          Process.sleep(500)
        end)

      assert Fetch.get("http://localhost:#{port}", receive_timeout: 50) ==
               {:error, {:recv, :timeout}}
    end

    test "content-length larger than max_body_size is refused before reading" do
      url = serve("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
      assert Fetch.get(url, max_body_size: 10) == {:error, {:recv, :body_too_large}}
    end

    test "close-delimited body larger than max_body_size" do
      url = serve(["HTTP/1.1 200 OK\r\n\r\n", String.duplicate("a", 100)])
      assert Fetch.get(url, max_body_size: 10) == {:error, {:recv, :body_too_large}}
    end

    test "huge response head" do
      url = serve("HTTP/1.1 200 OK\r\nX-Big: #{String.duplicate("a", 70_000)}\r\n\r\n")
      assert Fetch.get(url) == {:error, {:recv, :head_too_large}}
    end
  end

  describe "errors before the network" do
    test "invalid URL" do
      assert Fetch.get("not a url") == {:error, {:url, :invalid_url}}
      assert Fetch.get("ftp://example.com") == {:error, {:url, {:unsupported_scheme, "ftp"}}}
    end

    test "header injection" do
      assert Fetch.get("http://localhost:1", headers: [{"x", "a\r\nhost: evil"}]) ==
               {:error, {:request, {:invalid_header_value, "x"}}}
    end

    test "programmer errors raise" do
      assert_raise ArgumentError, ~r/unknown keys \[:recieve_timeout\]/, fn ->
        Fetch.get("http://localhost:1", recieve_timeout: 1)
      end

      assert_raise ArgumentError, ~r/unsupported method :trace/, fn ->
        Fetch.request(:trace, "http://localhost:1")
      end
    end
  end
end

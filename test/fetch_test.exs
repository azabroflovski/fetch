defmodule FetchTest do
  use ExUnit.Case, async: true

  alias Fetch.{Response, TestServer}

  doctest Fetch.Response

  # Starts a server that captures each request, sends it to the test process
  # and replies with `response`: a binary, a list of chunks sent separately, or
  # a function from the request to one of those.
  defp serve(response) do
    test = self()

    port =
      TestServer.start(fn {mod, socket} = conn ->
        request = TestServer.read_request(conn)
        send(test, {:request, request})
        response = if is_function(response), do: response.(request), else: response

        # The client may close early (e.g. on a size limit), so sends may fail.
        for chunk <- List.wrap(response) do
          mod.send(socket, chunk)
          Process.sleep(1)
        end
      end)

    "http://localhost:#{port}"
  end

  defp redirect_to(location, status \\ 302),
    do: "HTTP/1.1 #{status} Redirect\r\nLocation: #{location}\r\nContent-Length: 0\r\n\r\n"

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

  describe "chunked transfer encoding" do
    @chunked "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"

    test "decodes chunks" do
      url = serve(@chunked <> "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")

      assert {:ok, %Response{status: 200, headers: [{"transfer-encoding", "chunked"}]} = response} =
               Fetch.get(url)

      assert response.body == "hello world"
    end

    test "empty body" do
      url = serve(@chunked <> "0\r\n\r\n")
      assert {:ok, %Response{body: ""}} = Fetch.get(url)
    end

    test "chunk data is binary and may contain CRLF" do
      data = "a\r\n0\r\n\r\nb" <> <<0, 255>>
      size = Integer.to_string(byte_size(data), 16)
      url = serve(@chunked <> size <> "\r\n" <> data <> "\r\n0\r\n\r\n")

      assert {:ok, %Response{body: ^data}} = Fetch.get(url)
    end

    test "chunk extensions and trailers are ignored" do
      url =
        serve(
          @chunked <> "5;name=value\r\nhello\r\n0\r\nExpires: never\r\nX-Checksum: abc\r\n\r\n"
        )

      assert {:ok, %Response{body: "hello", headers: [{"transfer-encoding", "chunked"}]}} =
               Fetch.get(url)
    end

    test "response split into tiny TCP chunks" do
      response = @chunked <> "3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nX-T: 1\r\n\r\n"
      url = serve(for <<byte <- response>>, do: <<byte>>)

      assert {:ok, %Response{body: "abcde"}} = Fetch.get(url)
    end

    test "large chunk across many reads" do
      data = :crypto.strong_rand_bytes(300_000)
      size = Integer.to_string(byte_size(data), 16)
      url = serve([@chunked <> size <> "\r\n", data, "\r\n1\r\n!\r\n0\r\n\r\n"])

      assert {:ok, %Response{body: body}} = Fetch.get(url)
      assert body == data <> "!"
    end

    test "connection closed right after the last chunk is accepted" do
      url = serve(@chunked <> "5\r\nhello\r\n0\r\n")
      assert {:ok, %Response{body: "hello"}} = Fetch.get(url)
    end

    test "connection closed in the middle of a chunk" do
      url = serve(@chunked <> "A\r\nhello")
      assert Fetch.get(url) == {:error, {:recv, :closed}}
    end

    test "connection closed before the last chunk" do
      url = serve(@chunked <> "5\r\nhello\r\n")
      assert Fetch.get(url) == {:error, {:recv, :closed}}
    end

    test "invalid chunk size" do
      url = serve(@chunked <> "zz\r\nhello\r\n0\r\n\r\n")
      assert Fetch.get(url) == {:error, {:parse, {:invalid_chunk_size, "zz"}}}
    end

    test "chunk data longer than its declared size" do
      url = serve(@chunked <> "3\r\nhello\r\n0\r\n\r\n")
      assert Fetch.get(url) == {:error, {:parse, :invalid_chunk}}
    end

    test "malformed trailer" do
      url = serve(@chunked <> "0\r\nbad trailer\r\n\r\n")
      assert Fetch.get(url) == {:error, {:parse, {:invalid_header, "bad trailer"}}}
    end

    test "declared chunk size above max_body_size is refused before reading" do
      url = serve(@chunked <> "FFFFFFFF\r\n")
      assert Fetch.get(url, max_body_size: 1_000) == {:error, {:recv, :body_too_large}}
    end

    test "sum of chunks above max_body_size" do
      url = serve(@chunked <> "6\r\n123456\r\n6\r\n789012\r\n0\r\n\r\n")
      assert Fetch.get(url, max_body_size: 10) == {:error, {:recv, :body_too_large}}
    end

    test "endless chunk size line" do
      url = serve(@chunked <> String.duplicate("1", 5_000))
      assert Fetch.get(url) == {:error, {:recv, :chunk_line_too_long}}
    end

    test "receive timeout between chunks" do
      port =
        TestServer.start(fn {mod, socket} = conn ->
          TestServer.read_request(conn)
          mod.send(socket, @chunked <> "5\r\nhello\r\n")
          Process.sleep(500)
        end)

      assert Fetch.get("http://localhost:#{port}", receive_timeout: 50) ==
               {:error, {:recv, :timeout}}
    end
  end

  describe "redirects" do
    test "follows a relative redirect" do
      url =
        serve(fn
          "GET /start " <> _ -> redirect_to("/end")
          "GET /end " <> _ -> "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone"
        end)

      assert {:ok, %Response{status: 200, body: "done"}} = Fetch.get(url <> "/start")
      assert_received {:request, "GET /start HTTP/1.1\r\n" <> _}
      assert_received {:request, "GET /end HTTP/1.1\r\n" <> _}
    end

    test "a chain of redirects" do
      url =
        serve(fn
          "GET /1 " <> _ -> redirect_to("/2", 301)
          "GET /2 " <> _ -> redirect_to("/3", 308)
          "GET /3 " <> _ -> "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone"
        end)

      assert {:ok, %Response{status: 200, body: "done"}} = Fetch.get(url <> "/1")
    end

    test "POST after 303 becomes GET without body" do
      url =
        serve(fn
          "POST /form " <> _ -> redirect_to("/result", 303)
          "GET /result " <> _ -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        end)

      assert {:ok, %Response{status: 200, body: "ok"}} =
               Fetch.post(url <> "/form",
                 headers: [{"content-type", "application/json"}],
                 body: ~s({"name":"Jon Snow"})
               )

      assert_received {:request, "POST /form HTTP/1.1\r\n" <> _}
      assert_received {:request, "GET /result HTTP/1.1\r\n" <> request}
      refute request =~ "content-type"
      refute request =~ "content-length"
      assert String.ends_with?(request, "connection: close\r\n\r\n")
    end

    test "307 repeats the method and the body" do
      url =
        serve(fn
          "PUT /old " <> _ -> redirect_to("/new", 307)
          "PUT /new " <> _ -> "HTTP/1.1 204 No Content\r\n\r\n"
        end)

      assert {:ok, %Response{status: 204}} = Fetch.put(url <> "/old", body: "data")
      assert_received {:request, "PUT /old HTTP/1.1\r\n" <> _}
      assert_received {:request, "PUT /new HTTP/1.1\r\n" <> request}
      assert String.ends_with?(request, "content-length: 4\r\nconnection: close\r\n\r\ndata")
    end

    test "follow_redirects: false returns the redirect response" do
      url = serve(redirect_to("/elsewhere", 301))

      assert {:ok, %Response{status: 301} = response} = Fetch.get(url, follow_redirects: false)
      assert Response.get_header(response, "location") == ["/elsewhere"]
    end

    test "a redirect status without location is returned as is" do
      url = serve("HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n")
      assert {:ok, %Response{status: 302}} = Fetch.get(url)
    end

    test "a redirect loop stops after max_redirects" do
      url = serve(redirect_to("/again"))

      assert Fetch.get(url, max_redirects: 3) == {:error, {:redirect, :too_many_redirects}}

      for _ <- 1..4, do: assert_received({:request, _})
      refute_received {:request, _}
    end

    test "max_redirects: 0 fails on the first redirect" do
      url = serve(redirect_to("/again"))

      assert Fetch.get(url, max_redirects: 0) == {:error, {:redirect, :too_many_redirects}}
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "credentials are not sent to another origin" do
      other = serve("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nother")

      url =
        serve(fn
          "GET /same " <> _ -> redirect_to("/cross")
          "GET /cross " <> _ -> redirect_to(other <> "/landing")
        end)

      headers = [{"authorization", "Bearer secret"}, {"cookie", "a=1"}, {"x-custom", "kept"}]
      assert {:ok, %Response{body: "other"}} = Fetch.get(url <> "/same", headers: headers)

      assert_received {:request, "GET /same " <> first}
      assert_received {:request, "GET /cross " <> second}
      assert_received {:request, "GET /landing " <> third}

      for request <- [first, second] do
        assert request =~ "\r\nauthorization: Bearer secret\r\n"
        assert request =~ "\r\ncookie: a=1\r\n"
      end

      refute third =~ "authorization"
      refute third =~ "cookie"
      assert third =~ "\r\nx-custom: kept\r\n"
    end

    test "redirect to an unsupported scheme" do
      url = serve(redirect_to("ftp://files.test/x"))

      assert Fetch.get(url) ==
               {:error, {:redirect, {:invalid_location, "ftp://files.test/x"}}}
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

    test "transfer codings other than chunked are not supported" do
      url = serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n")

      assert Fetch.get(url) ==
               {:error, {:parse, {:unsupported_transfer_encoding, "gzip, chunked"}}}
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

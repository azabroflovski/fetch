defmodule Fetch.ParserTest do
  use ExUnit.Case, async: true

  alias Fetch.Parser

  # Fixtures are inline binaries with explicit \r\n: files on disk would depend
  # on editor and git line-ending settings.

  describe "split_head/1" do
    test "splits at the first empty line" do
      assert Parser.split_head("HTTP/1.1 200 OK\r\na: b\r\n\r\nbody\r\n\r\nmore") ==
               {:ok, "HTTP/1.1 200 OK\r\na: b", "body\r\n\r\nmore"}
    end

    test "incomplete head" do
      assert Parser.split_head("") == :more
      assert Parser.split_head("HTTP/1.1 200 OK\r\na: b\r\n") == :more
      assert Parser.split_head("HTTP/1.1 200 OK\r\na: b\r\n\r") == :more
    end

    test "bare LF does not terminate the head" do
      assert Parser.split_head("HTTP/1.1 200 OK\n\nbody") == :more
    end
  end

  describe "parse_status_line/1" do
    test "valid" do
      assert Parser.parse_status_line("HTTP/1.1 200 OK") ==
               {:ok, %{version: "HTTP/1.1", status: 200, reason: "OK"}}

      assert Parser.parse_status_line("HTTP/1.0 404 Not Found") ==
               {:ok, %{version: "HTTP/1.0", status: 404, reason: "Not Found"}}
    end

    test "reason phrase may be empty or missing" do
      assert {:ok, %{status: 204, reason: ""}} = Parser.parse_status_line("HTTP/1.1 204 ")
      assert {:ok, %{status: 204, reason: ""}} = Parser.parse_status_line("HTTP/1.1 204")
    end

    test "reason phrase may contain spaces and arbitrary bytes" do
      assert {:ok, %{reason: "Très  bien"}} = Parser.parse_status_line("HTTP/1.1 200 Très  bien")
    end

    test "invalid" do
      for line <- [
            "",
            "HTTP/1.1",
            "HTTP/1.1 ",
            "HTTP/1.1 20 OK",
            "HTTP/1.1 2000 OK",
            "HTTP/1.1 abc OK",
            "HTTP/1.1 099 Low",
            "HTTP/1.1 600 High",
            "HTTP/1.1  200 OK",
            "HTTP/1.1 200OK",
            "http/1.1 200 OK",
            "HTTP/1.x 200 OK",
            "ICY 200 OK",
            "HTTP/1.1 200 O\0K"
          ] do
        assert Parser.parse_status_line(line) == {:error, {:parse, {:invalid_status_line, line}}}
      end
    end

    test "other HTTP versions" do
      assert Parser.parse_status_line("HTTP/2.0 200 OK") ==
               {:error, {:parse, {:unsupported_version, "HTTP/2.0"}}}
    end
  end

  describe "parse_header/1" do
    test "lowercases the name and trims optional whitespace" do
      assert Parser.parse_header("Content-Type: application/json") ==
               {:ok, {"content-type", "application/json"}}

      assert Parser.parse_header("X-A:\t  spaced value \t ") == {:ok, {"x-a", "spaced value"}}
      assert Parser.parse_header("X-A:nospace") == {:ok, {"x-a", "nospace"}}
    end

    test "empty value" do
      assert Parser.parse_header("X-Empty:") == {:ok, {"x-empty", ""}}
      assert Parser.parse_header("X-Empty:   ") == {:ok, {"x-empty", ""}}
    end

    test "only the first colon separates name and value" do
      assert Parser.parse_header("Location: http://a.b:8080/x") ==
               {:ok, {"location", "http://a.b:8080/x"}}
    end

    test "invalid lines" do
      for line <- [
            "",
            "no colon",
            ": no name",
            "Content-Length : 5",
            "Bad Name: x",
            "X-A: a\nX-B: b",
            "X-A: a\rb",
            "X-A: a\0b",
            "Ünicode: x"
          ] do
        assert Parser.parse_header(line) == {:error, {:parse, {:invalid_header, line}}}
      end
    end

    test "obsolete line folding is rejected" do
      assert Parser.parse_header(" continued") ==
               {:error, {:parse, {:obsolete_line_folding, " continued"}}}

      assert Parser.parse_header("\tcontinued") ==
               {:error, {:parse, {:obsolete_line_folding, "\tcontinued"}}}
    end
  end

  describe "parse_head/1" do
    test "status line and headers, duplicates kept in order" do
      head =
        "HTTP/1.1 200 OK\r\n" <>
          "Content-Type: text/plain\r\n" <>
          "Set-Cookie: a=1\r\n" <>
          "Content-Length: 5\r\n" <>
          "set-cookie: b=2"

      assert Parser.parse_head(head) ==
               {:ok,
                %{
                  version: "HTTP/1.1",
                  status: 200,
                  reason: "OK",
                  headers: [
                    {"content-type", "text/plain"},
                    {"set-cookie", "a=1"},
                    {"content-length", "5"},
                    {"set-cookie", "b=2"}
                  ]
                }}
    end

    test "no headers" do
      assert {:ok, %{status: 200, headers: []}} = Parser.parse_head("HTTP/1.1 200 OK")
    end

    test "the first malformed header fails the whole head" do
      assert Parser.parse_head("HTTP/1.1 200 OK\r\nA: 1\r\nbroken\r\nB: 2") ==
               {:error, {:parse, {:invalid_header, "broken"}}}
    end

    test "an empty line inside the head is a malformed header" do
      assert Parser.parse_head("HTTP/1.1 200 OK\r\n\r\nA: 1") ==
               {:error, {:parse, {:invalid_header, ""}}}
    end

    test "malformed status line" do
      assert Parser.parse_head("garbage\r\nA: 1") ==
               {:error, {:parse, {:invalid_status_line, "garbage"}}}
    end
  end

  describe "body_framing/3" do
    test "no body for HEAD, 1xx, 204, 304" do
      cl = [{"content-length", "10"}]

      assert Parser.body_framing(:head, 200, cl) == {:ok, :none}
      assert Parser.body_framing(:get, 100, cl) == {:ok, :none}
      assert Parser.body_framing(:get, 204, cl) == {:ok, :none}
      assert Parser.body_framing(:get, 304, cl) == {:ok, :none}
    end

    test "content-length" do
      assert Parser.body_framing(:get, 200, [{"content-length", "0"}]) ==
               {:ok, {:content_length, 0}}

      assert Parser.body_framing(:get, 200, [{"content-length", "123"}]) ==
               {:ok, {:content_length, 123}}
    end

    test "repeated content-length is fine only when all values agree" do
      assert Parser.body_framing(:get, 200, [{"content-length", "5"}, {"content-length", "5"}]) ==
               {:ok, {:content_length, 5}}

      assert Parser.body_framing(:get, 200, [{"content-length", "5, 5"}]) ==
               {:ok, {:content_length, 5}}

      assert Parser.body_framing(:get, 200, [{"content-length", "5"}, {"content-length", "6"}]) ==
               {:error, {:parse, {:invalid_content_length, "5, 6"}}}

      assert Parser.body_framing(:get, 200, [{"content-length", "5,6"}]) ==
               {:error, {:parse, {:invalid_content_length, "5, 6"}}}
    end

    test "invalid content-length" do
      for value <- ["", "-1", "+5", "1.5", "0x10", "abc", "5 5"] do
        assert Parser.body_framing(:get, 200, [{"content-length", value}]) ==
                 {:error, {:parse, {:invalid_content_length, value}}}
      end
    end

    test "transfer-encoding is not supported yet and wins over content-length" do
      headers = [{"content-length", "5"}, {"transfer-encoding", "chunked"}]

      assert Parser.body_framing(:get, 200, headers) ==
               {:error, {:parse, {:unsupported_transfer_encoding, "chunked"}}}
    end

    test "without length the body is delimited by connection close" do
      assert Parser.body_framing(:get, 200, [{"content-type", "text/plain"}]) ==
               {:ok, :until_close}
    end
  end

  test "token?/1 and field_value?/1" do
    assert Parser.token?("x-custom_header.1")
    assert Parser.token?("!#$%&'*+-.^_`|~")
    refute Parser.token?("")
    refute Parser.token?("a b")
    refute Parser.token?("a(b)")

    assert Parser.field_value?("")
    assert Parser.field_value?("text/html; charset=utf-8")
    assert Parser.field_value?("tab\tinside")
    refute Parser.field_value?("a\r\nb")
    refute Parser.field_value?(<<0>>)
  end
end

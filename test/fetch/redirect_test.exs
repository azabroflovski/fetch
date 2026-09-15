defmodule Fetch.RedirectTest do
  use ExUnit.Case, async: true

  alias Fetch.{Redirect, Response, URL}

  defp request(method, url, headers \\ [], body \\ nil) do
    {:ok, url} = URL.parse(url)
    %{method: method, url: url, headers: headers, body: body}
  end

  defp redirect(status, location),
    do: %Response{status: status, headers: [{"location", location}]}

  # Flattens the next request into {method, url, headers, body}.
  defp next(request, response) do
    case Redirect.next_request(request, response) do
      {:ok, %{url: url} = next} ->
        {next.method, "#{url.scheme}://#{url.authority}#{url.target}", next.headers, next.body}

      other ->
        other
    end
  end

  test "only 301, 302, 303, 307 and 308 are followed" do
    request = request(:get, "http://a.test/")

    for status <- [200, 204, 300, 304, 305, 306, 404, 500] do
      assert Redirect.next_request(request, redirect(status, "/b")) == :none
    end

    for status <- [301, 302, 303, 307, 308] do
      assert {:get, "http://a.test/b", [], nil} = next(request, redirect(status, "/b"))
    end
  end

  test "a redirect status without location is a normal response" do
    request = request(:get, "http://a.test/")
    assert Redirect.next_request(request, %Response{status: 302}) == :none
  end

  test "more than one location" do
    response = %Response{status: 302, headers: [{"location", "/a"}, {"location", "/b"}]}

    assert Redirect.next_request(request(:get, "http://a.test/"), response) ==
             {:error, {:redirect, :multiple_locations}}
  end

  test "relative locations are resolved against the requested URL" do
    request = request(:get, "http://a.test:8080/docs/guide/intro?x=1")

    for {location, expected} <- [
          {"/login", "http://a.test:8080/login"},
          {"next", "http://a.test:8080/docs/guide/next"},
          {"../api?v=2", "http://a.test:8080/docs/api?v=2"},
          {"?page=2", "http://a.test:8080/docs/guide/intro?page=2"},
          {"//cdn.test/file", "http://cdn.test/file"},
          {"https://b.test/", "https://b.test/"},
          {"/path#section", "http://a.test:8080/path"}
        ] do
      assert {:get, ^expected, [], nil} = next(request, redirect(302, location))
    end
  end

  test "invalid locations" do
    request = request(:get, "http://a.test/")

    for location <- [
          "ftp://files.test/file",
          "mailto:jon@snow.test",
          "http://",
          "http://exa mple.test/"
        ] do
      assert Redirect.next_request(request, redirect(302, location)) ==
               {:error, {:redirect, {:invalid_location, location}}}
    end
  end

  describe "method" do
    test "301 and 302 turn POST into GET and drop the body" do
      headers = [{"Content-Type", "application/json"}, {"accept", "*/*"}]

      for status <- [301, 302] do
        request = request(:post, "http://a.test/", headers, ~s({"name":"Jon Snow"}))
        assert {:get, _, [{"accept", "*/*"}], nil} = next(request, redirect(status, "/b"))
      end
    end

    test "301 and 302 keep other methods" do
      headers = [{"content-type", "text/plain"}]

      for status <- [301, 302], method <- [:put, :patch, :delete, :options] do
        request = request(method, "http://a.test/", headers, "data")
        assert {^method, _, ^headers, "data"} = next(request, redirect(status, "/b"))
      end

      for status <- [301, 302], method <- [:get, :head] do
        assert {^method, _, [], nil} =
                 next(request(method, "http://a.test/"), redirect(status, "/b"))
      end
    end

    test "303 turns everything but HEAD into GET without body" do
      headers = [{"content-type", "text/plain"}, {"Content-Language", "en"}, {"x-a", "1"}]

      for method <- [:post, :put, :patch, :delete, :options] do
        request = request(method, "http://a.test/", headers, "data")
        assert {:get, _, [{"x-a", "1"}], nil} = next(request, redirect(303, "/b"))
      end

      assert {:get, _, [], nil} = next(request(:get, "http://a.test/"), redirect(303, "/b"))
      assert {:head, _, [], nil} = next(request(:head, "http://a.test/"), redirect(303, "/b"))
    end

    test "307 and 308 keep method, headers and body" do
      headers = [{"content-type", "application/json"}]
      body = ~s({"name":"Jon Snow"})

      for status <- [307, 308], method <- [:get, :post, :put, :patch, :delete] do
        request = request(method, "http://a.test/", headers, body)

        assert {^method, "http://a.test/b", ^headers, ^body} =
                 next(request, redirect(status, "/b"))
      end
    end
  end

  describe "credentials" do
    @headers [
      {"Authorization", "Bearer secret"},
      {"cookie", "session=1"},
      {"proxy-authorization", "Basic x"},
      {"x-custom", "kept"}
    ]

    test "are kept on the same origin" do
      request = request(:get, "http://a.test/", @headers)

      for location <- ["/other", "http://A.TEST:80/other"] do
        assert {:get, _, @headers, nil} = next(request, redirect(302, location))
      end
    end

    test "are dropped when scheme, host or port changes" do
      request = request(:get, "http://a.test/", @headers)

      for location <- ["https://a.test/", "http://b.test/", "http://a.test:8080/", "//b.test/"] do
        assert {:get, _, [{"x-custom", "kept"}], nil} = next(request, redirect(307, location))
      end
    end
  end
end

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

  test "HTTPS HEAD to example.com" do
    # GET example.com is chunked, which arrives in Phase 3.
    assert {:ok, %Fetch.Response{status: 200, body: ""}} = Fetch.head("https://example.com")
  end
end

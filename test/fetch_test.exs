defmodule FetchTest do
  use ExUnit.Case
  doctest Fetch

  test "greets the world" do
    assert Fetch.hello() == :world
  end
end

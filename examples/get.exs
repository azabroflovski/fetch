# Manual check against a real server:
#
#     mix run examples/get.exs
#     mix run examples/get.exs http://localhost:4000/
#
url = List.first(System.argv()) || "https://example.com"

case Fetch.get(url) do
  {:ok, response} ->
    IO.puts("status: #{response.status}\n")
    IO.puts("headers:")
    for {name, value} <- response.headers, do: IO.puts("  #{name}: #{value}")
    IO.puts("\nbody (#{byte_size(response.body)} bytes, first 500 shown):\n")
    IO.puts(binary_slice(response.body, 0, 500))

  {:error, {stage, reason}} ->
    IO.puts(:stderr, "#{stage} error: #{inspect(reason)}")
    System.halt(1)
end

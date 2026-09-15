# Sends the same GET several times: once with a new connection per request,
# once over a single kept-alive connection.
#
#     mix run examples/keep_alive.exs
#     mix run examples/keep_alive.exs https://hex.pm/ 10
#
{url, count} =
  case System.argv() do
    [] -> {"https://www.erlang.org/", 5}
    [url] -> {url, 5}
    [url, count | _] -> {url, String.to_integer(count)}
  end

uri = URI.parse(url)
path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

{one_shot, _} =
  :timer.tc(fn ->
    for _ <- 1..count, do: {:ok, _response} = Fetch.get(url, follow_redirects: false)
  end)

{:ok, conn} = Fetch.Conn.new(url)

{keep_alive, {conn, connects}} =
  :timer.tc(fn ->
    Enum.reduce(1..count, {conn, 0}, fn _, {conn, connects} ->
      # No socket before the request means this request will connect.
      connects = if conn.transport, do: connects, else: connects + 1
      {:ok, conn, _response} = Fetch.Conn.request(conn, :get, path)
      {conn, connects}
    end)
  end)

Fetch.Conn.close(conn)

IO.puts("#{count} × GET #{url}")
IO.puts("  new connection per request: #{div(one_shot, 1000)} ms")
IO.puts("  one kept-alive connection:  #{div(keep_alive, 1000)} ms, #{connects} connect(s)")

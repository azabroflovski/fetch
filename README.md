# Fetch

A small HTTP/1.1 client written in plain Elixir/OTP.

## Why it exists

I've always wanted to write my own HTTP client, so here it is. This is purely
for fun: I want to walk the whole path myself and understand every step.

```text
URL → DNS → TCP → TLS → HTTP/1.1 request → HTTP/1.1 response → parser → response
```

It's not trying to replace Req, Finch or Mint. If I have the time, it may grow
into a proper client someday. For now it's a hobby project.

The request encoding, the response parser and body framing are written by
hand. Sockets and TLS come from OTP (`:gen_tcp`, `:ssl`). No runtime
dependencies.

Design notes, rules and roadmap live in [AGENTS.md](https://github.com/azabroflovski/fetch/blob/master/AGENTS.md).

## Installation

```elixir
def deps do
  [
    {:fetch, "~> 0.1"}
  ]
end
```

Requires Elixir 1.15+ and OTP 25+.

## Basic usage

```elixir
{:ok, response} = Fetch.get("https://www.erlang.org/")

response.status
#=> 200
```

## Request

```elixir
Fetch.request(:get, "http://localhost:4000/users?page=2",
  headers: [{"accept", "application/json"}]
)

Fetch.post("http://localhost:4000/users",
  headers: [{"content-type", "application/json"}],
  body: ~s({"name":"Jon Snow"})
)
```

Helpers: `get/2`, `head/2`, `post/2`, `put/2`, `patch/2`, `delete/2`.
`request/3` also accepts `:options`.

Bytes sent for the POST above:

```text
POST /users HTTP/1.1
host: localhost:4000
user-agent: fetch/0.1.0
content-type: application/json
content-length: 19
connection: close

{"name":"Jon Snow"}
```

`host`, `content-length`, `transfer-encoding` and `connection` are managed by
the client. Header names and values are validated, so a value with `\r\n`
returns `{:error, {:request, {:invalid_header_value, name}}}` instead of
injecting headers.

## Response

```elixir
%Fetch.Response{
  status: 200,
  headers: [{"content-type", "text/html"}, {"set-cookie", "a=1"}, {"set-cookie", "b=2"}],
  body: "<!doctype html>..."
}

Fetch.Response.get_header(response, "Set-Cookie")
#=> ["a=1", "b=2"]
```

Header names are lowercased; order and duplicates are kept. Any status code,
including 4xx and 5xx, is `{:ok, response}`.

The body is read whole, whether it is framed by `content-length`,
`transfer-encoding: chunked` or by the server closing the connection.

## Errors

```elixir
{:error, {:url, {:unsupported_scheme, "ftp"}}}
{:error, {:dns, :nxdomain}}
{:error, {:connect, :econnrefused}}
{:error, {:tls, {:tls_alert, {:unknown_ca, _}}}}
{:error, {:recv, :timeout}}
{:error, {:parse, {:invalid_header, "Content-Length : 5"}}}
{:error, {:redirect, :too_many_redirects}}
```

Stages: `:url`, `:request`, `:dns`, `:connect`, `:tls`, `:send`, `:recv`,
`:parse`, `:redirect`. Unknown options and unsupported methods raise
`ArgumentError`.

## HTTPS

TLS is OTP `:ssl` on top of the connected TCP socket, with:

- `verify: :verify_peer` against the OS trust store (`:public_key.cacerts_get/0`)
- SNI and hostname verification (wildcard certificates supported)

Extra `:ssl` options are merged over these defaults, e.g. a private CA:

```elixir
Fetch.get("https://internal.test/", ssl: [cacertfile: "priv/ca.pem"])
```

## Redirects

301, 302, 303, 307 and 308 are followed by default, at most 10 times:

```elixir
Fetch.get("http://www.erlang.org/")          # 301 → https://www.erlang.org/
Fetch.get(url, follow_redirects: false)      # returns the 3xx response itself
Fetch.get(url, max_redirects: 3)             # {:error, {:redirect, :too_many_redirects}}
```

| status | next request |
| --- | --- |
| 301, 302 | POST becomes GET without body, other methods are kept |
| 303 | GET without body (HEAD stays HEAD) |
| 307, 308 | same method, headers and body |

A relative `location` is resolved against the current URL. When a redirect
goes to another origin (scheme, host or port), `authorization`,
`proxy-authorization` and `cookie` headers are not sent there.

## Keep-alive

`Fetch.get/2` and friends use a new connection for every request.
`Fetch.Conn` keeps one connection open and sends requests over it one after
another:

```elixir
{:ok, conn} = Fetch.Conn.new("http://localhost:4000")

{:ok, conn, users} = Fetch.Conn.request(conn, :get, "/users")
{:ok, conn, created} = Fetch.Conn.request(conn, :post, "/users", body: ~s({"name":"Jon Snow"}))

Fetch.Conn.close(conn)
```

A connection is a value, not a process: every request returns the updated
connection, keep using that one. Errors are `{:error, conn, {stage, reason}}`.

- `new/2` does no IO; the first request connects.
- The connection is closed after a response with `connection: close`, an
  HTTP/1.0 response, a body delimited by close, or any error. The next request
  connects again.
- If the server closed the idle connection, the next request notices before
  sending anything and reconnects.
- If the connection breaks after a request was sent, you get the error. There
  is no automatic retry: the server may already have handled the request.
- `keep_alive: false` sends `connection: close` for the last request.
- No redirects, no pooling, no pipelining. Use a connection from the process
  that created it.

## Timeouts

| option | default | |
| --- | --- | --- |
| `:connect_timeout` | `5_000` | each of DNS lookup, TCP connect, TLS handshake |
| `:receive_timeout` | `15_000` | max silence while waiting for bytes |
| `:max_body_size` | 16 MiB | larger bodies fail with `{:recv, :body_too_large}` |

There is no total request deadline: a server that keeps sending a byte now and
then is not stopped by `:receive_timeout`.

## Limitations

- `Fetch.get/2` and friends open a new connection per request; reuse needs
  `Fetch.Conn`. No pooling, no pipelining, no retries.
- The whole body is kept in memory. No streaming.
- `chunked` is the only transfer coding. `gzip, chunked` and friends return
  `{:error, {:parse, {:unsupported_transfer_encoding, value}}}`.
- Trailer fields of chunked responses are validated and dropped.
- No compression, cookies, proxies, retries.
- Every redirect opens a new connection. The response does not say which URL
  it finally came from.
- HTTP/1.1 only.

## Roadmap

1. Streaming responses
2. Optional: gzip/deflate, benchmarks

## Why not Req/Finch?

For real work, use them. [Req](https://hex.pm/packages/req) is the high-level
client, [Finch](https://hex.pm/packages/finch) adds pooling, and
[Mint](https://hex.pm/packages/mint) is the process-less protocol layer they
are built on. Fetch exists to learn what those libraries do and why.

## Try it

```bash
mix run examples/get.exs https://www.erlang.org/
mix run examples/keep_alive.exs https://www.erlang.org/ 10
mix test                      # local servers only
mix test --include external   # also talks to the internet
```

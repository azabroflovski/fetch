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

## Errors

```elixir
{:error, {:url, {:unsupported_scheme, "ftp"}}}
{:error, {:dns, :nxdomain}}
{:error, {:connect, :econnrefused}}
{:error, {:tls, {:tls_alert, {:unknown_ca, _}}}}
{:error, {:recv, :timeout}}
{:error, {:parse, {:invalid_header, "Content-Length : 5"}}}
```

Stages: `:url`, `:request`, `:dns`, `:connect`, `:tls`, `:send`, `:recv`,
`:parse`. Unknown options and unsupported methods raise `ArgumentError`.

## HTTPS

TLS is OTP `:ssl` on top of the connected TCP socket, with:

- `verify: :verify_peer` against the OS trust store (`:public_key.cacerts_get/0`)
- SNI and hostname verification (wildcard certificates supported)

Extra `:ssl` options are merged over these defaults, e.g. a private CA:

```elixir
Fetch.get("https://internal.test/", ssl: [cacertfile: "priv/ca.pem"])
```

## Timeouts

| option | default | |
| --- | --- | --- |
| `:connect_timeout` | `5_000` | each of DNS lookup, TCP connect, TLS handshake |
| `:receive_timeout` | `15_000` | max silence while waiting for bytes |
| `:max_body_size` | 16 MiB | larger bodies fail with `{:recv, :body_too_large}` |

There is no total request deadline: a server that keeps sending a byte now and
then is not stopped by `:receive_timeout`.

## Limitations

- New connection for every request, no keep-alive, no pooling.
- The whole body is kept in memory. No streaming.
- `Transfer-Encoding: chunked` is not supported yet
  (`{:error, {:parse, {:unsupported_transfer_encoding, "chunked"}}}`).
  Many servers use it, including `https://example.com`.
- No redirects, compression, cookies, proxies, retries.
- HTTP/1.1 only.

## Roadmap

1. Chunked transfer encoding, redirects
2. Keep-alive on a single connection
3. Streaming responses
4. Optional: gzip/deflate, benchmarks

## Why not Req/Finch?

For real work, use them. [Req](https://hex.pm/packages/req) is the high-level
client, [Finch](https://hex.pm/packages/finch) adds pooling, and
[Mint](https://hex.pm/packages/mint) is the process-less protocol layer they
are built on. Fetch exists to learn what those libraries do and why.

## Try it

```bash
mix run examples/get.exs https://www.erlang.org/
mix test                      # local servers only
mix test --include external   # also talks to the internet
```

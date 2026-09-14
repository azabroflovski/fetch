# AGENTS.md — Fetch

This is the main technical document of the project. Read it fully before
changing anything. If code and this document disagree, fix one of them in the
same change.

## 1. Goal

`Fetch` is a small HTTP/1.1 client written in plain Elixir/OTP.

The goal is **understanding**, not competing with Req or Finch:

> A small HTTP/1.1 client on pure Elixir/OTP where every step from the socket
> to the parsed response is written by hand and understood.

```text
URL → DNS → TCP → TLS → HTTP/1.1 request → bytes → parser → response
```

The guiding question is not "how do we build a production-grade HTTP client?"
but "how do we write a minimal one ourselves and understand every part of it?"

If a mature library solves something in one line, first understand **why that
line exists**, then decide whether we need it.

## 2. Prior art — what problems production clients solve

Studied for understanding only. We do not copy their API or architecture.

| Library | Shape | Problems it solves that we care about |
| --- | --- | --- |
| **Mint** | Process-less. A connection is an immutable struct; the socket belongs to the caller process. Caller feeds socket messages into `Mint.HTTP.stream/2` and gets `{:status, ...}`, `{:headers, ...}`, `{:data, ...}`, `{:done, ...}`. HTTP/1 + HTTP/2. Status line and headers are decoded with `:erlang.decode_packet/3`. | Separation of protocol state from processes; streaming responses; active-mode sockets; the same API for HTTP/1 and HTTP/2. |
| **Finch** | Connection pools on top of Mint. HTTP/1 pools use NimblePool (one checkout = one connection), HTTP/2 uses a `gen_statem` per connection. Pools are keyed by `{scheme, host, port}` and live under a supervisor + Registry. | Connection reuse, pooling, concurrency limits, telemetry. |
| **Req** | High-level client on top of Finch. A request passes through lists of request/response/error *steps*. | Redirects, decompression, retries, JSON, auth, caching — "batteries". |
| **:httpc** | Part of `inets`. A manager `gen_server` per profile plus a handler process per connection; ETS session table. | Persistent connections, pipelining, a profile-wide configuration. Historically insecure TLS defaults — a reminder that defaults matter. |

What this teaches us:

1. Most complexity in production clients comes from **connection reuse**
   (pools, ownership, reconnects) and **features** (redirects, retries,
   compression) — not from HTTP/1.1 itself.
2. Processes appear when state must outlive a single function call (a pooled
   connection). A one-shot request does not need a process.
3. The protocol core can be pure functions over binaries.

## 3. Architecture

### 3.1 Options considered

**A. One function call = one connection, synchronous, passive socket.**
`request/3` resolves, connects, sends, receives with `recv/3` in passive mode,
closes. No processes. Pure parser functions + a thin transport.

**B. Mint-style functional connection.** A `%Conn{}` struct, active-mode
socket, the caller routes messages into `stream/2`. Great for streaming and
keep-alive, but the caller must own a receive loop and the API is harder to use
and to learn from on day one.

**C. Process per connection (GenServer), optional pool.** Like `:httpc` /
Finch. Needed for shared long-lived connections. Brings ownership, timeouts
across process boundaries, supervision and failure semantics before we have any
of the problems that justify them.

**Chosen: A.** It is the smallest design that walks the whole path
`URL → response`, it is trivially testable, and nothing in it has to be undone
to move towards B or C later.

Trade-offs of A that we accept for now:

- A new TCP (and TLS) connection per request — slow for many requests.
- The whole body is buffered in memory (bounded by `:max_body_size`).
- The calling process blocks for the duration of the request.
- `:receive_timeout` is an *idle* timeout per `recv`, not a total deadline; a
  server that drips one byte per second is not stopped by it.

These are exactly the problems that later phases (keep-alive, streaming) will
solve, and we want to feel them first.

### 3.2 Request lifecycle

```text
Fetch.request(method, url, opts)
  │
  ├─ Fetch.URL.parse/1           "https://h:8443/a?b" → %{scheme, host, port, authority, target}
  ├─ Fetch.Request.encode/4      method + url + headers + body → iodata (validated)
  ├─ Fetch.Transport.connect/2   DNS (:inet) → TCP (:gen_tcp) → TLS (:ssl, https only)
  ├─ Fetch.Transport.send/2
  ├─ receive loop (in Fetch)
  │    ├─ recv until "\r\n\r\n"           (bounded head size)
  │    ├─ Fetch.Parser.parse_head/1       status line + headers
  │    ├─ skip 1xx interim responses
  │    ├─ Fetch.Parser.body_framing/3     :none | {:content_length, n} | :until_close
  │    └─ recv body                        (bounded body size)
  ├─ Fetch.Transport.close/1              always, success or error
  └─ {:ok, %Fetch.Response{}} | {:error, {stage, reason}}
```

### 3.3 Modules

| Module | Kind | Responsibility |
| --- | --- | --- |
| `Fetch` | IO | Public API, option validation, the request lifecycle and the receive loop. |
| `Fetch.URL` | pure | Validate a URL for HTTP use on top of `URI.new/1`. |
| `Fetch.Request` | pure | Encode a request to iodata; reject header injection. |
| `Fetch.Parser` | pure | Parse status line and headers; decide body framing. |
| `Fetch.Response` | data | `%Fetch.Response{status, headers, body}` + `get_header/2`. |
| `Fetch.Transport` | IO | DNS, TCP, TLS; `send/recv/close` over `{:gen_tcp, socket} \| {:ssl, socket}`. |

Transport "polymorphism" is a tuple `{module, socket}` where module is
`:gen_tcp` or `:ssl` — both expose `send/2`, `recv/3`, `close/1`. No behaviour,
no protocol. Add a module only when an existing one gets hard to read.

### 3.4 Data

- **Headers** (request and response) are lists of `{name, value}` binaries.
  Order and duplicates are preserved. Response header names are lowercased
  (HTTP field names are case-insensitive). `Fetch.Response.get_header/2`
  returns *all* values for a name.
- **Body** of a request is `iodata` or `nil`. Response body is a binary.

### 3.5 Errors

Every error that leaves any module is `{:error, {stage, reason}}`:

| stage | examples |
| --- | --- |
| `:url` | `:invalid_url`, `{:unsupported_scheme, "ftp"}`, `:missing_host`, `:userinfo_not_supported` |
| `:request` | `{:invalid_header_name, name}`, `{:invalid_header_value, name}`, `{:managed_header, "host"}` |
| `:dns` | `:nxdomain`, `:timeout` |
| `:connect` | `:econnrefused`, `:timeout` |
| `:tls` | `{:tls_alert, ...}`, `:timeout` |
| `:send` | `:closed`, `:timeout` |
| `:recv` | `:closed`, `:timeout`, `:head_too_large`, `:body_too_large` |
| `:parse` | `{:invalid_status_line, line}`, `{:invalid_header, line}`, `{:invalid_content_length, value}`, `{:unsupported_transfer_encoding, value}` |

A timeout is always `{stage, :timeout}`, so `{:error, {_, :timeout}}` matches
any of them.

Exceptions are only for **programmer errors**: unknown options, unsupported
method atom, wrong argument types. Anything that depends on data or the network
returns an error tuple. No exception hierarchy.

### 3.6 Timeouts

No infinite defaults.

| option | default | meaning |
| --- | --- | --- |
| `:connect_timeout` | 5_000 | Applied separately to DNS lookup, TCP connect and TLS handshake. |
| `:receive_timeout` | 15_000 | Max idle time for each `recv`. Also used as the socket `send_timeout`. |

Sockets are in **passive mode** (`active: false`): bytes stay in the kernel /
port buffer until we call `recv(socket, 0, timeout)`, which returns whatever is
available or `{:error, :timeout}`. No mailbox messages, no receive loops.

### 3.7 HTTP/1.1 rules implemented

Request:

- Request line `METHOD target HTTP/1.1`; target = path (default `/`) + `?query`.
  Fragment is never sent.
- Managed headers (users may not set them): `host`, `content-length`,
  `transfer-encoding`, `connection`.
- `host` = host, plus `:port` if non-default; IPv6 in brackets.
- `content-length` when a body is given, and `0` for POST/PUT/PATCH without
  body.
- `connection: close` (until keep-alive is implemented).
- `user-agent: fetch/<version>` unless the user sets `user-agent`.
- Header names must be RFC 9110 tokens; values must not contain CR, LF or NUL
  (header/request splitting protection).

Response head:

- Lines are separated by CRLF only. A bare LF inside a line makes it invalid.
- Status line `HTTP/1.x SP 3DIGIT [SP reason]`, status in 100..599. A missing
  reason (`HTTP/1.1 200`) is tolerated.
- Header line `token ":" OWS value OWS`. Whitespace before the colon is invalid.
  Obsolete line folding (a line starting with SP/HTAB) is rejected.
- Values containing NUL or CR are rejected. Empty values are allowed.
- Head size limit: 64 KiB.
- 1xx responses are skipped (we never send `Expect` or `Upgrade`).

Body framing (RFC 9112 §6.3), in order:

1. HEAD request, 1xx, 204, 304 → no body.
2. `transfer-encoding` present → Phase 1/2: error `unsupported_transfer_encoding`.
3. `content-length` → exactly N bytes. Multiple or comma-separated values are
   accepted only when all equal (response smuggling protection). Bytes after N
   are discarded.
4. Otherwise → read until the server closes the connection.

**Forbidden shortcuts:** `packet: :http`, `packet: :http_bin`,
`:erlang.decode_packet/3` and any other ready-made HTTP parser. They are exactly
the part of the project we want to write ourselves.

### 3.8 TLS

TLS is done by OTP `:ssl` by upgrading the already connected TCP socket
(`:ssl.connect(tcp_socket, opts, timeout)`), so each step (DNS → TCP → TLS) is
visible and has its own error stage.

Defaults:

```elixir
[
  verify: :verify_peer,
  cacerts: :public_key.cacerts_get(),               # OS trust store (OTP 25+)
  server_name_indication: ~c"example.com",          # SNI + name used for hostname check
  customize_hostname_check: [
    match_fun: :public_key.pkix_verify_hostname_match_fun(:https)  # wildcard certs
  ]
]
```

User options from `ssl: [...]` are merged over the defaults (e.g. `cacerts` for
a private CA). If the user passes `cacerts` or `cacertfile`, the OS store is
not added.

Pitfall found while researching: when upgrading a socket, `:ssl` only knows the
host through `server_name_indication`. `server_name_indication: :disable`
**silently skips hostname verification**. Never use it. For IP literals the IP
string is passed and verified against `iPAddress` SANs.

Never disable verification in tests. Tests use a local CA generated with
`:public_key.pkix_test_data/1`.

## 4. Scope

MVP (Phases 1–2):

- URL parsing (`http`, `https`, host, port, path, query; fragment dropped)
- GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS
- request headers and body
- response status, headers, body
- `Content-Length` bodies, close-delimited bodies
- HTTPS via `:ssl` with verification
- error tuples per stage, connect/receive timeouts, size limits
- local test servers (TCP and TLS)

## 5. Non-goals

- Competing with Req/Finch/Mint on features or performance.
- HTTP/2 (possible separate project stage later), HTTP/3/QUIC (never).
- Connection pools (unless a real need appears after keep-alive).
- Cookie jar, caching, retries, auth helpers, JSON encoding/decoding,
  multipart, proxies, a middleware/plugin/step system, a DSL.
- Exotic URI forms, IDN, happy eyeballs.
- A total request deadline (known limitation, see 3.1).

## 6. Roadmap

| Phase | Content | Status |
| --- | --- | --- |
| 0 | Research, design, this document | done |
| 1 | URL, TCP, request encoding, response parsing, Content-Length | done |
| 2 | HTTPS, errors, timeouts, tests | done |
| 3 | `Transfer-Encoding: chunked`; redirects (301/302/303/307/308, `follow_redirects`, `max_redirects`) | next |
| 4 | Keep-alive on a single connection (connect → req → resp → req → resp → close) | |
| 5 | Streaming responses | |
| 6 | Optional: gzip/deflate, benchmarks vs other clients (as an experiment) | |

Note for Phase 3: `https://example.com` currently answers HTTP/1.1 requests with
`Transfer-Encoding: chunked` (Cloudflare), so chunked decoding is needed for it
to return a body.

After every phase: tests → review → simplify → remove unnecessary abstractions →
update this file and `CHANGELOG.md`.

## 7. Educational vs production-oriented parts

- **Educational (written by hand, clarity over speed):** request encoding,
  status line / header parsing, body framing, the receive loop, later chunked
  decoding and keep-alive.
- **Production-oriented (must be correct and safe, never "simplified away"):**
  TLS verification and hostname checks, header injection protection,
  Content-Length conflict handling, size limits, timeouts, always closing
  sockets.

## 8. Dependency policy

- Zero runtime dependencies. Only Elixir stdlib and OTP (`:gen_tcp`, `:inet`,
  `:ssl`, `:public_key`).
- Dev-only exception: `ex_doc` (`only: :dev, runtime: false`) to build HexDocs.
  It is never compiled into the library and cannot be replaced by the stdlib.
- `URI.new/1` is used for URI syntax; HTTP-specific validation is ours.
- Forbidden inside the implementation: Req, Finch, Tesla, HTTPoison, Mint,
  `:httpc`, hackney, gun, any HTTP parser, `decode_packet`-based parsing.
- Before adding any dependency (including dev/test-only) explain: what problem
  it solves, why stdlib/OTP cannot solve it, how much complexity it adds. Then
  wait for approval.

## 9. Coding style

- Idiomatic Elixir: pattern matching, `with`, small private functions, binaries.
- Functions first. No behaviours, protocols, GenServers or processes until a
  concrete problem requires them. Keep-alive may justify a process; a one-shot
  request does not.
- No OOP-style layering, no "service/manager/adapter" modules, no patterns for
  their own sake.
- `@spec` on public functions. `@moduledoc`/`@doc` explain the HTTP concept, not
  just the function.
- Comments explain *why* (RFC rule, security reason), not *what*.
- Size limits and defaults are module attributes, visible at the top of a
  module.

## 10. Testing strategy

- `test/fetch/url_test.exs`, `request_test.exs`, `parser_test.exs` — pure
  functions, exact binaries. Parser fixtures are inline binaries with explicit
  `\r\n` (files would be at the mercy of editors and git line-ending settings).
- `test/fetch_test.exs` — end-to-end against a local raw TCP server
  (`test/support/test_server.ex`) that sends arbitrary bytes, including
  malformed, fragmented and slow responses.
- `test/fetch/transport_test.exs` — DNS/connect errors and TLS against a local
  `:ssl` server with a generated CA: success, unknown CA, hostname mismatch,
  handshake timeout.
- Tests that touch the internet are tagged `@tag :external` and excluded by
  default: `mix test --include external`.
- Every bug fix comes with a test that reproduces it.

Before finishing any change:

```bash
mix format
mix test
mix compile --warnings-as-errors
```

Credo/Dialyzer are not used until they prove useful.

## 11. Rules for AI agents

- **Do not add a feature only because it exists in Req/Finch/etc.**
- **Do not introduce an abstraction until the concrete problem exists.**
- Work in small iterations; do not jump ahead in the roadmap.
- Do not use ready-made HTTP clients or parsers (see 3.7, 8).
- Never weaken TLS verification, including in tests.
- Never use infinite timeouts or unbounded buffers.
- Keep the error shape `{:error, {stage, reason}}`.
- Update `CHANGELOG.md` (`Unreleased`) for every user-visible change.
- Update this file when architecture, scope or rules change.
- **Never run `git commit`, `git push`, `mix hex.publish` or other
  outward-facing commands.** The maintainer runs them by hand; propose the
  commands instead.
- Do not add dependencies or tooling without the explanation from section 8.

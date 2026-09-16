# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-17

### Added

- `Fetch.request/3` and `get/2`, `head/2`, `post/2`, `put/2`, `patch/2`,
  `delete/2` helpers. One connection per request, `connection: close`.
- `%Fetch.Response{status, headers, body}` and `Fetch.Response.get_header/2`.
- URL handling for `http` and `https` on top of `URI.new/1`.
- Hand-written HTTP/1.1 request encoding with header name/value validation
  (header injection protection) and managed `host`, `content-length`,
  `connection` headers.
- Hand-written HTTP/1.1 response parser: status line, headers (case-insensitive
  names, duplicates preserved), `Content-Length` and close-delimited bodies,
  1xx interim responses skipped, conflicting `Content-Length` rejected.
- Transport over `:gen_tcp` and `:ssl` with an explicit DNS step and certificate
  plus hostname verification by default (OS trust store).
- `{:error, {stage, reason}}` errors for `:url`, `:request`, `:dns`,
  `:connect`, `:tls`, `:send`, `:recv`, `:parse`.
- `:connect_timeout`, `:receive_timeout`, `:max_body_size` and `:ssl` options;
  64 KiB response head limit.
- `Transfer-Encoding: chunked` response bodies: chunk extensions ignored,
  trailers validated and dropped, `:max_body_size` checked against declared
  chunk sizes before reading, 4 KiB chunk size line limit. Other transfer
  codings return `{:parse, {:unsupported_transfer_encoding, value}}`.
- Redirects: 301, 302, 303, 307 and 308 are followed by default
  (`:follow_redirects`, `:max_redirects` options, default 10). POST becomes GET
  on 301/302, everything but HEAD becomes GET on 303, 307/308 keep method and
  body. Relative `location` is resolved against the requested URL.
  `authorization`, `proxy-authorization` and `cookie` are not sent to another
  origin. New error stage `:redirect`.
- `Fetch.Conn`: keep-alive on a single connection with `new/2`, `request/4`
  (returns the updated connection) and `close/1`. The socket is reused
  according to RFC 9112 §9.3; an idle connection closed by the server is
  detected before sending and replaced. Requests already sent are never
  retried. `Fetch.request/3` is built on it and still uses one connection per
  request with `connection: close`.

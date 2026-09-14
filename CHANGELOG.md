# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

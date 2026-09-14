defmodule Fetch.Parser do
  @moduledoc """
  Pure functions that parse an HTTP/1.1 response head and decide how the body
  is framed.

  A response on the wire looks like this:

      HTTP/1.1 200 OK\\r\\n                  <- status line
      Content-Type: text/plain\\r\\n         <- header lines
      Content-Length: 5\\r\\n
      \\r\\n                                 <- empty line ends the head
      hello                                <- body

  The *head* passed to `parse_head/1` is everything before the first
  `\\r\\n\\r\\n`. How many body bytes follow is decided by `body_framing/3`.

  The parser is strict where leniency is dangerous (header syntax,
  conflicting Content-Length) and tolerant only where it is harmless
  (a missing reason phrase).
  """

  @type status_line :: %{version: String.t(), status: 100..599, reason: String.t()}
  @type headers :: [{String.t(), String.t()}]
  @type head :: %{
          version: String.t(),
          status: 100..599,
          reason: String.t(),
          headers: headers()
        }
  @type framing :: :none | {:content_length, non_neg_integer()} | :chunked | :until_close

  # 16 hex digits already mean 2^64 - 1 bytes; longer sizes are nonsense.
  @max_chunk_size_digits 16

  @doc """
  Splits a buffer at the end of the head.

  Returns `{:ok, head, rest}` where `rest` is the beginning of the body, or
  `:more` when the terminating empty line has not arrived yet.
  """
  @spec split_head(binary()) :: {:ok, binary(), binary()} | :more
  def split_head(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] -> {:ok, head, rest}
      [_incomplete] -> :more
    end
  end

  @doc """
  Parses a response head: a status line followed by header lines, separated
  by CRLF.
  """
  @spec parse_head(binary()) :: {:ok, head()} | {:error, {:parse, term()}}
  def parse_head(head) do
    [status_line | header_lines] = :binary.split(head, "\r\n", [:global])

    with {:ok, parsed_status_line} <- parse_status_line(status_line),
         {:ok, headers} <- parse_headers(header_lines) do
      {:ok, Map.put(parsed_status_line, :headers, headers)}
    end
  end

  @doc """
  Parses `HTTP/1.1 200 OK` into `%{version: "HTTP/1.1", status: 200, reason: "OK"}`.

  RFC 9112 §4: `HTTP-version SP 3DIGIT SP [reason-phrase]`. The reason phrase
  carries no meaning, so it may be empty; a missing space before it is
  tolerated because real servers send `HTTP/1.1 200`.
  """
  @spec parse_status_line(binary()) :: {:ok, status_line()} | {:error, {:parse, term()}}
  def parse_status_line(<<"HTTP/1.", minor, " ", code::binary-size(3), rest::binary>> = line)
      when minor in ?0..?9 do
    with {:ok, status} <- status_code(code),
         {:ok, reason} <- reason_phrase(rest) do
      {:ok, %{version: "HTTP/1." <> <<minor>>, status: status, reason: reason}}
    else
      :error -> {:error, {:parse, {:invalid_status_line, line}}}
    end
  end

  def parse_status_line(<<"HTTP/", _::binary>> = line) do
    case :binary.split(line, " ") do
      [<<"HTTP/", major, ".", minor>> = version, _]
      when major in ?0..?9 and major != ?1 and minor in ?0..?9 ->
        {:error, {:parse, {:unsupported_version, version}}}

      _ ->
        {:error, {:parse, {:invalid_status_line, line}}}
    end
  end

  def parse_status_line(line), do: {:error, {:parse, {:invalid_status_line, line}}}

  defp status_code(<<a, b, c>> = code) when a in ?1..?5 and b in ?0..?9 and c in ?0..?9,
    do: {:ok, String.to_integer(code)}

  defp status_code(_code), do: :error

  defp reason_phrase(""), do: {:ok, ""}

  defp reason_phrase(<<" ", reason::binary>>) do
    if field_value?(reason), do: {:ok, reason}, else: :error
  end

  defp reason_phrase(_rest), do: :error

  @doc """
  Parses header lines into `{lowercase_name, value}` tuples, keeping order
  and duplicates.
  """
  @spec parse_headers([binary()]) :: {:ok, headers()} | {:error, {:parse, term()}}
  def parse_headers(lines) do
    lines
    |> Enum.reduce_while([], fn line, acc ->
      case parse_header(line) do
        {:ok, header} -> {:cont, [header | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      headers -> {:ok, Enum.reverse(headers)}
    end
  end

  @doc """
  Parses one header line: `field-name ":" OWS field-value OWS` (RFC 9112 §5).

    * the name is case-insensitive, so it is lowercased
    * whitespace between name and colon is invalid (RFC 9112 §5.1) — it was
      used for request smuggling
    * a line starting with space/tab is obsolete line folding (RFC 9112 §5.2),
      rejected here
    * optional whitespace (SP / HTAB) around the value is removed
  """
  @spec parse_header(binary()) :: {:ok, {String.t(), String.t()}} | {:error, {:parse, term()}}
  def parse_header(<<c, _::binary>> = line) when c in [?\s, ?\t],
    do: {:error, {:parse, {:obsolete_line_folding, line}}}

  def parse_header(line) do
    with [name, value] <- :binary.split(line, ":"),
         true <- token?(name),
         value = trim_ows(value),
         true <- field_value?(value) do
      {:ok, {String.downcase(name, :ascii), value}}
    else
      _ -> {:error, {:parse, {:invalid_header, line}}}
    end
  end

  @doc """
  Decides how the response body is delimited (RFC 9112 §6.3).

    1. responses to HEAD, and 1xx/204/304 responses have no body
    2. `transfer-encoding` wins over `content-length`; only plain `chunked`
       is supported
    3. `content-length` gives the exact size
    4. otherwise the body lasts until the server closes the connection
  """
  @spec body_framing(atom(), 100..599, headers()) :: {:ok, framing()} | {:error, {:parse, term()}}
  def body_framing(method, status, headers) do
    cond do
      method == :head or status in 100..199 or status in [204, 304] ->
        {:ok, :none}

      (codings = header_values(headers, "transfer-encoding")) != [] ->
        transfer_encoding(codings)

      (lengths = header_values(headers, "content-length")) != [] ->
        content_length(lengths)

      true ->
        {:ok, :until_close}
    end
  end

  # Transfer codings are applied in order and `chunked` must be the last one.
  # Anything but `chunked` alone (e.g. `gzip, chunked`) needs decompression,
  # which does not exist yet.
  defp transfer_encoding(values) do
    codings =
      values
      |> split_list()
      |> Enum.map(&String.downcase(&1, :ascii))
      |> Enum.reject(&(&1 == ""))

    if codings == ["chunked"],
      do: {:ok, :chunked},
      else: {:error, {:parse, {:unsupported_transfer_encoding, Enum.join(values, ", ")}}}
  end

  # `Content-Length: 5, 5` or two `Content-Length: 5` headers are allowed only
  # if all values agree. Different values mean client and server may disagree on
  # where the body ends — the basis of response smuggling (RFC 9112 §6.3).
  defp content_length(values) do
    case values |> split_list() |> Enum.uniq() do
      [value] ->
        if digits?(value),
          do: {:ok, {:content_length, String.to_integer(value)}},
          else: {:error, {:parse, {:invalid_content_length, value}}}

      values ->
        {:error, {:parse, {:invalid_content_length, Enum.join(values, ", ")}}}
    end
  end

  # A header may carry a comma-separated list, and repeating the header is the
  # same as joining its values with commas (RFC 9110 §5.3).
  defp split_list(values) do
    values
    |> Enum.flat_map(&:binary.split(&1, ",", [:global]))
    |> Enum.map(&trim_ows/1)
  end

  @doc """
  Parses the size line at the start of a chunk (RFC 9112 §7.1):

      chunk-size [ chunk-ext ] CRLF      <- this line
      chunk-data CRLF

  The size is hexadecimal. Chunk extensions (`;name=value`) have no meaning
  for us and are skipped. Returns the size and the bytes after the line.
  A size of 0 marks the last chunk, followed by the trailer section.
  """
  @spec parse_chunk_size(binary()) ::
          {:ok, non_neg_integer(), binary()} | :more | {:error, {:parse, term()}}
  def parse_chunk_size(buffer) do
    with [line, rest] <- :binary.split(buffer, "\r\n") do
      digits = hex_digits(line, 0)
      <<hex::binary-size(digits), extensions::binary>> = line

      if digits in 1..@max_chunk_size_digits and chunk_extensions?(trim_leading(extensions)),
        do: {:ok, String.to_integer(hex, 16), rest},
        else: {:error, {:parse, {:invalid_chunk_size, line}}}
    else
      [_incomplete] -> :more
    end
  end

  defp hex_digits(<<c, rest::binary>>, count) when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
    do: hex_digits(rest, count + 1)

  defp hex_digits(_line, count), do: count

  defp chunk_extensions?(""), do: true
  defp chunk_extensions?(<<";", extensions::binary>>), do: field_value?(extensions)
  defp chunk_extensions?(_other), do: false

  @doc """
  Parses the trailer section after the last chunk: header lines followed by
  an empty line. Usually there are no trailers and the section is just CRLF.
  """
  @spec parse_trailers(binary()) ::
          {:ok, headers(), binary()} | :more | {:error, {:parse, term()}}
  def parse_trailers(<<"\r\n", rest::binary>>), do: {:ok, [], rest}

  def parse_trailers(buffer) do
    with {:ok, section, rest} <- split_head(buffer),
         {:ok, trailers} <- parse_headers(:binary.split(section, "\r\n", [:global])) do
      {:ok, trailers, rest}
    end
  end

  defp header_values(headers, name), do: for({^name, value} <- headers, do: value)

  @doc """
  Returns true if `name` is an RFC 9110 token — the allowed syntax for header
  names: one or more of ``!#$%&'*+-.^_`|~``, digits and ASCII letters.
  """
  @spec token?(binary()) :: boolean()
  def token?(""), do: false
  def token?(name), do: token_chars?(name)

  defp token_chars?(<<>>), do: true

  defp token_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"!#$%&'*+-.^_`|~",
       do: token_chars?(rest)

  defp token_chars?(_), do: false

  @doc """
  Returns true if `value` can be a header value: it must not contain CR, LF or
  NUL (RFC 9110 §5.5). Those bytes are how header injection works.
  """
  @spec field_value?(binary()) :: boolean()
  def field_value?(value), do: not String.contains?(value, ["\r", "\n", <<0>>])

  defp digits?(""), do: false
  defp digits?(value), do: for(<<c <- value>>, reduce: true, do: (acc -> acc and c in ?0..?9))

  defp trim_ows(value), do: value |> trim_leading() |> trim_trailing()

  defp trim_leading(<<c, rest::binary>>) when c in [?\s, ?\t], do: trim_leading(rest)
  defp trim_leading(value), do: value

  defp trim_trailing(value) do
    size = byte_size(value) - 1

    case value do
      <<rest::binary-size(size), c>> when c in [?\s, ?\t] -> trim_trailing(rest)
      _ -> value
    end
  end
end

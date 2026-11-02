defmodule BarkparkWeb.JsTokens do
  @moduledoc """
  JavaScript source as tokens, enough to read call sites: strings (escapes
  decoded), template literals (each `${…}` as its own tree), identifiers,
  punctuation, numbers and regex literals; comments dropped. `tree/1` nests
  brackets as `{:group, open, children, line}`.
  """

  @regex_after ~w(return typeof case do else in of new delete void throw instanceof yield await)
  @puncts ~w(>>>= ... === !== **= <<= >>= >>> ??= ||= &&= => == != <= >= && || ?? ?. ++ -- += -= *= /= %= &= |= ^= ** << >>)

  def lex(source), do: source |> lex(1, [], nil, nil) |> elem(0)

  defp lex(<<>>, line, acc, _prev, _depth), do: {Enum.reverse(acc), <<>>, line}

  defp lex("}" <> rest, line, acc, _prev, 0), do: {Enum.reverse(acc), rest, line}

  defp lex("\n" <> rest, line, acc, prev, depth), do: lex(rest, line + 1, acc, prev, depth)

  defp lex(<<c, rest::binary>>, line, acc, prev, depth) when c in [?\s, ?\t, ?\r],
    do: lex(rest, line, acc, prev, depth)

  defp lex("//" <> rest, line, acc, prev, depth) do
    rest = rest |> String.split("\n", parts: 2) |> Enum.at(1, "")
    lex(rest, line + 1, acc, prev, depth)
  end

  defp lex("/*" <> rest, line, acc, prev, depth) do
    [comment, rest] = String.split(rest, "*/", parts: 2)
    lex(rest, line + newlines(comment), acc, prev, depth)
  end

  defp lex("/" <> rest, line, acc, prev, depth) do
    if regex_start?(prev) do
      rest = skip_regex(rest, false)
      tok = {:re, nil, line}
      lex(rest, line, [tok | acc], tok, depth)
    else
      punct("/" <> rest, line, acc, depth)
    end
  end

  defp lex(<<q, rest::binary>>, line, acc, _prev, depth) when q in [?", ?'] do
    {value, rest, lines} = string(rest, q, [], 0)
    tok = {:str, value, line}
    lex(rest, line + lines, [tok | acc], tok, depth)
  end

  defp lex("`" <> rest, line, acc, _prev, depth) do
    {parts, rest, end_line} = template(rest, line, [], [])
    tok = {:tpl, parts, line}
    lex(rest, end_line, [tok | acc], tok, depth)
  end

  defp lex(<<c::utf8, _::binary>> = source, line, acc, _prev, depth)
       when c in ?a..?z or c in ?A..?Z or c in [?_, ?$] or c > 127 do
    [{0, size}] = Regex.run(~r/^[\p{L}\p{N}_$]+/u, source, return: :index)
    <<name::binary-size(size), rest::binary>> = source
    tok = {:id, name, line}
    lex(rest, line, [tok | acc], tok, depth)
  end

  defp lex(<<c, _::binary>> = source, line, acc, _prev, depth) when c in ?0..?9 do
    [{0, size}] = Regex.run(~r/^[0-9A-Za-z_.]+/, source, return: :index)
    <<_::binary-size(size), rest::binary>> = source
    tok = {:num, nil, line}
    lex(rest, line, [tok | acc], tok, depth)
  end

  defp lex(source, line, acc, _prev, depth), do: punct(source, line, acc, depth)

  defp punct(source, line, acc, depth) do
    op = Enum.find(@puncts, &String.starts_with?(source, &1)) || String.first(source)
    rest = binary_part(source, byte_size(op), byte_size(source) - byte_size(op))
    tok = {:p, op, line}

    depth =
      case {op, depth} do
        {_, nil} -> nil
        {"{", d} -> d + 1
        {"}", d} -> d - 1
        {_, d} -> d
      end

    lex(rest, line, [tok | acc], tok, depth)
  end

  defp regex_start?(nil), do: true
  defp regex_start?({:p, op, _}), do: op not in [")", "]", "}"]
  defp regex_start?({:id, name, _}), do: name in @regex_after
  defp regex_start?(_), do: false

  defp skip_regex("\\" <> <<_::utf8, rest::binary>>, class), do: skip_regex(rest, class)
  defp skip_regex("[" <> rest, _class), do: skip_regex(rest, true)
  defp skip_regex("]" <> rest, true), do: skip_regex(rest, false)
  defp skip_regex("/" <> rest, false), do: String.replace(rest, ~r/^[a-z]*/, "")
  defp skip_regex(<<_::utf8, rest::binary>>, class), do: skip_regex(rest, class)

  defp string(<<q, rest::binary>>, q, acc, lines),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, lines}

  defp string("\\" <> rest, q, acc, lines) do
    {char, rest, more} = escape(rest)
    string(rest, q, [char | acc], lines + more)
  end

  defp string(<<c::utf8, rest::binary>>, q, acc, lines),
    do: string(rest, q, [<<c::utf8>> | acc], lines)

  defp template("`" <> rest, line, chunk, parts),
    do: {Enum.reverse(text_part(chunk, parts)), rest, line}

  defp template("\\" <> rest, line, chunk, parts) do
    {char, rest, more} = escape(rest)
    template(rest, line + more, [char | chunk], parts)
  end

  defp template("${" <> rest, line, chunk, parts) do
    {tokens, rest, line} = lex(rest, line, [], nil, 0)
    template(rest, line, [], [{:expr, tree(tokens)} | text_part(chunk, parts)])
  end

  defp template("\n" <> rest, line, chunk, parts),
    do: template(rest, line + 1, ["\n" | chunk], parts)

  defp template(<<c::utf8, rest::binary>>, line, chunk, parts),
    do: template(rest, line, [<<c::utf8>> | chunk], parts)

  defp text_part([], parts), do: parts
  defp text_part(chunk, parts), do: [chunk |> Enum.reverse() |> IO.iodata_to_binary() | parts]

  defp escape("n" <> rest), do: {"\n", rest, 0}
  defp escape("t" <> rest), do: {"\t", rest, 0}
  defp escape("r" <> rest), do: {"\r", rest, 0}
  defp escape("\n" <> rest), do: {"", rest, 1}
  defp escape("u{" <> rest), do: rest |> String.split("}", parts: 2) |> codepoint()
  defp escape(<<"u", hex::binary-size(4), rest::binary>>), do: codepoint([hex, rest])
  defp escape(<<"x", hex::binary-size(2), rest::binary>>), do: codepoint([hex, rest])
  defp escape(<<c::utf8, rest::binary>>), do: {<<c::utf8>>, rest, 0}

  defp codepoint([hex, rest]), do: {<<String.to_integer(hex, 16)::utf8>>, rest, 0}

  defp newlines(text), do: text |> String.graphemes() |> Enum.count(&(&1 in ["\n", "\r\n"]))

  # ── tree: brackets become {:group, open, children, line} ──────────────────────

  def tree(tokens), do: tokens |> group(nil) |> elem(0)

  defp group([], _close), do: {[], []}

  defp group([{:p, close, _} | rest], close), do: {[], rest}

  defp group([{:p, open, line} | rest], close) when open in ["(", "[", "{"] do
    {children, rest} = group(rest, %{"(" => ")", "[" => "]", "{" => "}"}[open])
    {siblings, rest} = group(rest, close)
    {[{:group, open, children, line} | siblings], rest}
  end

  defp group([tok | rest], close) do
    {siblings, rest} = group(rest, close)
    {[tok | siblings], rest}
  end
end

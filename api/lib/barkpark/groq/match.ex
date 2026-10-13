defmodule Barkpark.Groq.Match do
  @moduledoc """
  The GROQ `match` operator and its `score()` weight, ported from groq-js
  `shared/matching.ts` and `evaluator/scoring.ts`.

  Text is split into tokens on punctuation and whitespace; each pattern term is
  a case-insensitive whole-token match where `*` is a wildcard. Every pattern
  term must match some token.
  """

  # Characters that separate tokens. `*` is a separator in text but a wildcard
  # in patterns. Whitespace follows JavaScript's `\s`, which includes the
  # Unicode space separators.
  @spaces "\\s\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
  @token Regex.compile!("[^!@#$%^&*(),\\\\/?\";:{}|\\[\\]+<>#{@spaces}-]+", "u")
  @pattern_term Regex.compile!("[^!@#$%^&(),\\\\/?\";:{}|\\[\\]+<>#{@spaces}-]+", "u")
  # A run of dots at a word boundary (JavaScript `\b` is ASCII-only).
  @edge_dots Regex.compile!("(?<=[A-Za-z0-9_])\\.+|\\.+(?=[A-Za-z0-9_])", "u")
  @max_term 1024
  @bm25_k 1.2

  @spec match?(term(), term()) :: boolean()
  def match?(text, pattern) do
    {tokens, _} = gather(text, &tokenize/1)
    {patterns, ok?} = gather(pattern, &pattern_regexes/1)

    cond do
      not ok? -> false
      tokens == [] or patterns == [] -> false
      true -> Enum.all?(patterns, fn re -> Enum.any?(tokens, &Regex.match?(re, &1)) end)
    end
  end

  @spec score(term(), term()) :: number()
  def score(text, pattern) do
    {tokens, _} = gather(text, &tokenize/1)
    {terms, ok?} = gather(pattern, &pattern_regexes/1)

    if not ok? or tokens == [] or terms == [] do
      0
    else
      Enum.reduce(terms, 0.0, fn re, acc ->
        freq = Enum.count(tokens, &Regex.match?(re, &1))
        acc + freq * (@bm25_k + 1) / (freq + @bm25_k)
      end)
    end
  end

  defp gather(s, fun) when is_binary(s), do: {fun.(s), true}

  defp gather(list, fun) when is_list(list) do
    Enum.reduce(list, {[], true}, fn
      s, {acc, ok?} when is_binary(s) -> {acc ++ fun.(s), ok?}
      _, {acc, _} -> {acc, false}
    end)
  end

  defp gather(_, _fun), do: {[], false}

  defp tokenize(text) do
    text
    |> strip_edges()
    |> then(&Regex.scan(@token, &1))
    |> Enum.map(&hd/1)
  end

  defp pattern_regexes(text) do
    text
    |> strip_edges()
    |> then(&Regex.scan(@pattern_term, &1))
    |> Enum.flat_map(fn [term] ->
      term = term |> String.slice(0, @max_term) |> String.replace("*", ".*")

      # groq-js builds the regex from the raw term, so a `.` in a term matches
      # any character. Keep that, but never let an odd term crash the query.
      case Regex.compile("^" <> term <> "$", "iu") do
        {:ok, re} -> [re]
        {:error, _} -> []
      end
    end)
  end

  defp strip_edges(text), do: Regex.replace(@edge_dots, text, "")
end

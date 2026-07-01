defmodule Barkpark.Search.QueryParser do
  @moduledoc """
  Parses search query strings: quoted phrases, `-exclude` tokens, trailing `*` prefix.
  """

  @type parsed :: %{
          raw: String.t(),
          terms: [String.t()],
          phrases: [String.t()],
          excludes: [String.t()],
          prefixes: [String.t()]
        }

  @spec parse(String.t() | nil) :: parsed()
  def parse(nil), do: empty("")
  def parse(""), do: empty("")

  def parse(query) when is_binary(query) do
    raw = String.trim(query)
    {phrases, rest} = extract_phrases(raw)
    tokens = tokenize(rest)

    {excludes, includes} =
      Enum.split_with(tokens, fn
        "-" <> _ -> true
        _ -> false
      end)

    excludes =
      Enum.map(excludes, fn "-" <> t -> String.trim(t) end)
      |> Enum.reject(&(&1 == ""))

    {prefixes, terms} =
      Enum.map(includes, &String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.split_with(&String.ends_with?(&1, "*"))

    prefixes =
      prefixes
      |> Enum.map(&String.trim_trailing(&1, "*"))
      |> Enum.reject(&(&1 == ""))

    %{
      raw: raw,
      terms: terms,
      phrases: phrases,
      excludes: excludes,
      prefixes: prefixes
    }
  end

  def to_map(parsed) when is_map(parsed) do
    %{
      terms: Map.get(parsed, :terms, []),
      phrases: Map.get(parsed, :phrases, []),
      excludes: Map.get(parsed, :excludes, []),
      prefixes: Map.get(parsed, :prefixes, [])
    }
  end

  defp empty(raw) do
    %{raw: raw, terms: [], phrases: [], excludes: [], prefixes: []}
  end

  defp extract_phrases(query) do
    regex = ~r/"([^"]*)"/

    phrases =
      Regex.scan(regex, query)
      |> Enum.map(fn [_, phrase] -> String.trim(phrase) end)
      |> Enum.reject(&(&1 == ""))

    rest =
      Regex.replace(regex, query, " ")
      |> String.trim()

    {phrases, rest}
  end

  defp tokenize(rest) do
    rest
    |> String.split(~r/\s+/, trim: true)
  end
end

defmodule Barkpark.Search.Sanitizer do
  @moduledoc """
  Core quality gate for search intelligence — normalize good queries, reject bad data.

  Used by all surfaces (media DAM, future document search, etc.). Rejected queries
  are never stored verbatim.
  """

  @max_length 200
  @min_length 2
  @min_suggest_length 4

  @spam_patterns [
    ~r/(.)\1{6,}/,
    ~r/(?:select|insert|update|delete|drop|union)\s+/i
  ]

  @spec sanitize(String.t() | nil) :: {:ok, String.t()} | {:reject, atom()}
  @spec sanitize(String.t() | nil, keyword()) :: {:ok, String.t()} | {:reject, atom()}
  def sanitize(query, opts \\ [])

  def sanitize(nil, _opts), do: {:reject, :empty}

  def sanitize(query, opts) when is_binary(query) do
    trimmed = query |> String.trim() |> collapse_ws()
    min_len = Keyword.get(opts, :min_length, @min_length)

    cond do
      trimmed == "" -> {:reject, :empty}
      String.length(trimmed) < min_len -> {:reject, :too_short}
      String.length(trimmed) > @max_length -> {:reject, :too_long}
      excluded?(trimmed) -> {:reject, :excluded}
      profanity?(trimmed) -> {:reject, :profanity}
      spam?(trimmed) -> {:reject, :spam}
      true -> {:ok, normalize(trimmed)}
    end
  end

  @doc "Stricter gate for autocomplete prefix filtering (min #{@min_suggest_length} letters)."
  @spec suggest_sanitize(String.t() | nil) :: {:ok, String.t()} | {:reject, atom()}
  def suggest_sanitize(query), do: sanitize(query, min_length: @min_suggest_length)

  @doc false
  def min_suggest_length, do: @min_suggest_length

  @spec normalize(String.t()) :: String.t()
  def normalize(query) when is_binary(query) do
    query |> String.trim() |> collapse_ws() |> String.downcase()
  end

  defp collapse_ws(text), do: Regex.replace(~r/\s+/u, text, " ")

  defp profanity?(text) do
    normalized = normalize(text)
    words = String.split(normalized, ~r/[^a-z0-9]+/u, trim: true)
    block = MapSet.new(blocklist())
    Enum.any?(words, &MapSet.member?(block, &1))
  end

  defp spam?(text) do
    Enum.any?(@spam_patterns, &Regex.match?(&1, text)) or
      punctuation_only?(text) or control_chars?(text)
  end

  defp punctuation_only?(text) do
    Regex.replace(~r/[a-zA-Z0-9]+/u, text, "") == text and text != ""
  end

  defp control_chars?(text) do
    Enum.any?(String.to_charlist(text), fn
      c when c < 32 and c not in [?\t, ?\n, ?\r] -> true
      _ -> false
    end)
  end

  defp blocklist do
    Application.get_env(:barkpark, :search_query_blocklist, default_blocklist())
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_blocklist, do: ~w(fuck shit asshole bitch cunt)

  defp excluded?(text) do
    Enum.any?(exclude_patterns(), &Regex.match?(&1, text))
  end

  defp exclude_patterns do
    Application.get_env(:barkpark, :search_query_exclude_patterns, [])
    |> List.wrap()
    |> Enum.map(&compile_pattern/1)
    |> Enum.reject(&is_nil/1)
  end

  defp compile_pattern(%Regex{} = pattern), do: pattern

  defp compile_pattern(pattern) when is_binary(pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> regex
      _ -> nil
    end
  end

  defp compile_pattern(_), do: nil
end

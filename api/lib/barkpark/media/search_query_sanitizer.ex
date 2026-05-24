defmodule Barkpark.Media.SearchQuerySanitizer do
  @moduledoc """
  Quality gate for search analytics — normalize good queries, reject bad data.

  Rejected queries are never stored verbatim (especially profanity). Aggregates
  only use `query_normalized` from accepted events.
  """

  @max_length 200
  @min_length 2

  @spam_patterns [
    ~r/(.)\1{6,}/,
    ~r/(?:select|insert|update|delete|drop|union)\s+/i
  ]

  @doc """
  Sanitize a raw query for analytics storage.

  Returns `{:ok, normalized}` or `{:reject, reason}` where reason is an atom
  (`:empty`, `:too_short`, `:too_long`, `:profanity`, `:spam`, `:invalid`).
  """
  @spec sanitize(String.t() | nil) :: {:ok, String.t()} | {:reject, atom()}
  def sanitize(nil), do: {:reject, :empty}

  def sanitize(query) when is_binary(query) do
    trimmed = query |> String.trim() |> collapse_ws()

    cond do
      trimmed == "" ->
        {:reject, :empty}

      String.length(trimmed) < @min_length ->
        {:reject, :too_short}

      String.length(trimmed) > @max_length ->
        {:reject, :too_long}

      profanity?(trimmed) ->
        {:reject, :profanity}

      spam?(trimmed) ->
        {:reject, :spam}

      true ->
        {:ok, normalize(trimmed)}
    end
  end

  @doc "Normalize for aggregation (lowercase, collapsed whitespace)."
  @spec normalize(String.t()) :: String.t()
  def normalize(query) when is_binary(query) do
    query
    |> String.trim()
    |> collapse_ws()
    |> String.downcase()
  end

  defp collapse_ws(text) do
    Regex.replace(~r/\s+/u, text, " ")
  end

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
    alnum = Regex.replace(~r/[a-zA-Z0-9]+/u, text, "")
    alnum == text and text != ""
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

  defp default_blocklist do
    [
      "fuck",
      "shit",
      "asshole",
      "bitch",
      "cunt"
    ]
  end
end

defmodule Barkpark.Content.LocalizedText do
  @moduledoc """
  Localized-text fallback resolver for v2 `localizedText` fields
  (masterplan-20260425-085425, Phase 0 line 58, Decision 15).

  Walks a per-field `fallback_chain` (e.g. `["nob", "eng", "first-non-empty"]`)
  against a `%{language => text}` value map and picks the first language whose
  value is a non-empty string.

  The `"first-non-empty"` sentinel scans the value map in iteration order and
  returns the first non-empty entry found — used as a final safety net when
  none of the explicitly listed languages have a value (e.g. a German-only
  document with a `["nob", "eng", "first-non-empty"]` chain).

  ## Returns

    * `{:ok, language, text}` — winning language + text
    * `{:error, :no_value}` — every entry in the value map was empty
  """

  @first_non_empty "first-non-empty"

  @type value_map :: %{optional(String.t()) => String.t() | nil}
  @type chain :: [String.t()]
  @type result :: {:ok, String.t(), String.t()} | {:error, :no_value}

  @doc """
  Resolve a localized-text value map against a fallback chain.
  """
  @spec resolve(value_map, chain) :: result
  def resolve(value_map, chain) when is_map(value_map) and is_list(chain) do
    do_resolve(value_map, chain)
  end

  def resolve(_, _), do: {:error, :no_value}

  @doc """
  The first explicit language in the fallback chain (i.e. the "primary
  translation"), excluding the `"first-non-empty"` sentinel. Returns `nil`
  if the chain is empty or only contains the sentinel.
  """
  @spec primary_language(chain) :: String.t() | nil
  def primary_language(chain) when is_list(chain) do
    Enum.find(chain, &(&1 != @first_non_empty))
  end

  def primary_language(_), do: nil

  @doc """
  True iff `text` is a non-empty string after trimming whitespace.
  """
  @spec non_empty?(any()) :: boolean()
  def non_empty?(text) when is_binary(text), do: String.trim(text) != ""
  def non_empty?(_), do: false

  # ─── private ────────────────────────────────────────────────────────────────

  defp do_resolve(_value_map, []), do: {:error, :no_value}

  defp do_resolve(value_map, [@first_non_empty | rest]) do
    case Enum.find(value_map, fn {_lang, text} -> non_empty?(text) end) do
      {lang, text} -> {:ok, lang, text}
      nil -> do_resolve(value_map, rest)
    end
  end

  defp do_resolve(value_map, [lang | rest]) do
    case Map.get(value_map, lang) do
      text when is_binary(text) ->
        if non_empty?(text), do: {:ok, lang, text}, else: do_resolve(value_map, rest)

      _ ->
        do_resolve(value_map, rest)
    end
  end
end

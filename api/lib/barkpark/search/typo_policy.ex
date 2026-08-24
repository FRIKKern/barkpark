defmodule Barkpark.Search.TypoPolicy do
  @moduledoc """
  The `typo_policy` block of a search surface config — ONE reader for both
  surfaces.

  `Barkpark.Search.SurfaceConfigs` ships a `typo_policy` map in the defaults for
  BOTH surfaces (`@default_documents` / `@default_media`), the admin
  GET/PUT config endpoints echo it back verbatim, and each retriever used to dig
  the keys out of the map itself. That duplication is how the surfaces drifted:
  `min_len_1typo` was honoured by the documents retriever and ignored by the
  media one, and `enabled` was honoured by NEITHER — an admin could turn typo
  tolerance off, get a 200, re-read the config and see `"enabled" => false`
  stored, and every fuzzy `similarity()` arm kept firing.

  Every consumer of the block goes through this module so a knob can only be
  half-honoured by deleting a call, never by forgetting a surface.

  ## Keys

    * `enabled` — master switch for typo tolerance. `false` (or `"false"`)
      suppresses the pg_trgm `similarity()` arms on both surfaces AND the
      `typo_widen` recovery pass. Any other value (including absent) leaves
      typo tolerance on, which is the shipped default; the PUT boundary is
      where a malformed value is refused, not here.
    * `min_len_1typo` — minimum token length before a term is allowed into the
      fuzzy arm at all. Shorter tokens still match via tsvector/ilike; they are
      kept OUT of the trigram arm because a 2-3 character token is similar to
      almost anything above the threshold.
    * `similarity_threshold` / `similarity_threshold_relaxed` — the pg_trgm
      floor for the strict pass and for the widened recovery pass.

  `drop_tokens` recovery is deliberately NOT gated by `enabled`: dropping the
  last token of a multi-term query is not typo tolerance.
  """

  @default_min_len 4
  @default_threshold 0.25
  @default_threshold_relaxed 0.15

  @doc """
  Whether typo tolerance is on for this surface config.

  Only an explicit `false` / `"false"` turns it off. An absent key means on
  (the shipped default), and a malformed value is left to the config PUT to
  refuse rather than being silently read as "off" — a knob that disables search
  behaviour on a typo of its own value would be the same silent failure one
  layer out.
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(config) do
    config
    |> policy()
    |> Map.get("enabled", true)
    |> then(&(&1 not in [false, "false"]))
  end

  @doc """
  Minimum token length admitted to the fuzzy arm (`min_len_1typo`, default
  #{@default_min_len}). A non-positive-integer value falls back to the default.
  """
  @spec min_token_len(map()) :: pos_integer()
  def min_token_len(config) do
    case config |> policy() |> Map.get("min_len_1typo", @default_min_len) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_min_len
    end
  end

  @doc """
  Whether `term` may enter the fuzzy arm at all: typo tolerance on AND the
  token long enough. The single predicate both retrievers ask.
  """
  @spec fuzzy_term?(map(), String.t()) :: boolean()
  def fuzzy_term?(config, term) when is_binary(term) do
    enabled?(config) and String.length(term) >= min_token_len(config)
  end

  @doc """
  The pg_trgm similarity floor — `similarity_threshold_relaxed` on the widened
  recovery pass, `similarity_threshold` otherwise.
  """
  @spec threshold(map(), boolean()) :: float()
  def threshold(config, true),
    do: get_threshold(config, "similarity_threshold_relaxed", @default_threshold_relaxed)

  def threshold(config, _), do: get_threshold(config, "similarity_threshold", @default_threshold)

  defp get_threshold(config, key, default) do
    case config |> policy() |> Map.get(key, default) do
      n when is_number(n) -> n
      _ -> default
    end
  end

  defp policy(config) when is_map(config) do
    case Map.get(config, "typo_policy", %{}) do
      %{} = policy -> policy
      _ -> %{}
    end
  end

  defp policy(_), do: %{}
end

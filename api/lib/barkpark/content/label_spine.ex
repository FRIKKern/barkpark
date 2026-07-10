defmodule Barkpark.Content.LabelSpine do
  @moduledoc """
  The weighted-label spine validator — the cross-member label rules that the
  field DSL structurally cannot express (authoring-excellence D2).

  `validate/1` is a **pure** function: given a document's `content` map it
  returns `:ok` or `{:error, {:label_spine, details}}`. It is deliberately
  **unmounted** this slice — nothing in the publish path calls it yet (the mount
  is `ae-w1-publish-wall-mount`, S2). Adding it is a pure, behaviour-neutral
  addition.

  ## Why a dedicated module and not the field DSL

  Two classes of rule live here because the schema/`validations:` DSL cannot
  express them:

    * **Array-length bounds.** `arrayOf` carries no `min`/`max` length check —
      `content/validation.ex`'s `arrayOf` branch walks members but never counts
      them (a PROVEN silent no-op). The 1–12 count wall is written here by hand.
    * **Cross-member rules.** "all strengths distinct", "no duplicate tag", and
      the derived "main tag = unique maximum" compare members *against each
      other*. The DSL validates each leaf in isolation; the `validations:` slot
      that would host cross-field rules is Phase-0 inert. So they live here.

  Per-leaf shape (a tag is `^[a-z0-9-]+$`, strength is 1–100, rationale present)
  is *also* declared on the schema (paper.json / tasks/schema.ex) so Studio and
  the recursive validator reject malformed leaves early — but this module
  re-checks every leaf too, so the wall is correct even for a content map that
  never passed through schema validation (task edits, internal projections).

  ## The label model (charter §Label model)

      tags: [%{"tag" => "obsidian", "strength" => 80, "rationale" => "…20+ chars…"}, …]

    * `1..12` tags (hard bounds; the advisory 2–4 norm is S2's warnings channel,
      never enforced here).
    * each entry carries `tag`, `strength`, `rationale`, all required.
    * `strength` is an integer `1..100`.
    * all strengths are **distinct** — which makes the maximum unique, so the
      **main tag** (`main_tag/1`, the argmax) is always well-defined and derived,
      never a stored flag.
    * no duplicate `tag`.
    * `description` present and non-trivial (drafts stay free; publish is the
      wall).

  ## Error shape

  `{:error, {:label_spine, details}}` where `details` reads like documentation —
  it names the offending `field`, states the `rule` that was broken, and gives a
  machine/agent-actionable `fix`. Where a specific entry is at fault it also
  carries the offending entry `index`. The validator returns the FIRST broken
  rule (fail-closed: one clear reason to fix, then retry).
  """

  @min_description 20
  @min_tags 1
  @max_tags 12
  @min_strength 1
  @max_strength 100
  @min_rationale 20

  @type details :: %{
          required(:field) => String.t(),
          required(:rule) => String.t(),
          required(:fix) => String.t(),
          optional(:index) => non_neg_integer()
        }

  @doc """
  Validate a document's `content` map against the label spine.

  Returns `:ok` when the document is well-labelled, or
  `{:error, {:label_spine, details}}` naming the first broken rule.
  """
  @spec validate(map()) :: :ok | {:error, {:label_spine, details()}}
  def validate(content) when is_map(content) do
    with :ok <- check_description(content),
         {:ok, tags} <- check_tags_shape(content),
         :ok <- check_tag_count(tags),
         :ok <- check_entries(tags),
         :ok <- check_distinct_strengths(tags),
         :ok <- check_no_duplicate_tags(tags) do
      :ok
    end
  end

  def validate(_other) do
    fail("content", "Content must be a map.", "Publish a document with a content object.")
  end

  @doc """
  Derives the **main tag** — the tag with the maximum strength.

  Returns `{:ok, tag}` when the tags pass `validate/1`'s distinctness rule (so
  the argmax is unique), or `:error` when there are no valid tags or the maximum
  is not unique. Never a stored flag — always derived from `strength`.
  """
  @spec main_tag(map()) :: {:ok, String.t()} | :error
  def main_tag(content) when is_map(content) do
    with {:ok, tags} <- check_tags_shape(content),
         :ok <- check_entries(tags),
         :ok <- check_distinct_strengths(tags),
         [%{} = top | _] <-
           Enum.sort_by(tags, &get(&1, "strength"), :desc) do
      {:ok, get(top, "tag")}
    else
      _ -> :error
    end
  end

  def main_tag(_), do: :error

  # ── description ───────────────────────────────────────────────────────────

  defp check_description(content) do
    case get(content, "description") do
      value when is_binary(value) ->
        if String.length(String.trim(value)) >= @min_description do
          :ok
        else
          fail(
            "description",
            "A description must be non-trivial (at least #{@min_description} characters).",
            "Write a description that summarizes the document in a sentence or two."
          )
        end

      _ ->
        fail(
          "description",
          "A published document requires a description.",
          "Add a `description` string of at least #{@min_description} characters."
        )
    end
  end

  # ── tags: presence + shape ────────────────────────────────────────────────

  defp check_tags_shape(content) do
    case get(content, "tags") do
      tags when is_list(tags) ->
        {:ok, tags}

      nil ->
        fail(
          "tags",
          "A published document requires a `tags` array.",
          "Add #{@min_tags}–#{@max_tags} weighted tags: [{tag, strength, rationale}]."
        )

      _ ->
        fail(
          "tags",
          "`tags` must be an array of {tag, strength, rationale} objects.",
          "Provide tags as a JSON array of objects, not a scalar."
        )
    end
  end

  defp check_tag_count(tags) do
    count = length(tags)

    cond do
      count < @min_tags ->
        fail(
          "tags",
          "A published document needs at least #{@min_tags} tag.",
          "Add at least #{@min_tags} weighted tag before publishing."
        )

      count > @max_tags ->
        fail(
          "tags",
          "A document may carry at most #{@max_tags} tags (got #{count}).",
          "Keep the #{@max_tags} strongest tags; drop the rest."
        )

      true ->
        :ok
    end
  end

  # ── per-entry: tag / strength / rationale ─────────────────────────────────

  defp check_entries(tags) do
    tags
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, idx}, :ok ->
      case check_entry(entry, idx) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_entry(entry, idx) when is_map(entry) do
    with :ok <- check_tag(entry, idx),
         :ok <- check_strength(entry, idx) do
      check_rationale(entry, idx)
    end
  end

  defp check_entry(_entry, idx) do
    fail(
      "tags",
      "Each tag must be a {tag, strength, rationale} object.",
      "Replace entry ##{idx} with an object carrying tag, strength and rationale.",
      idx
    )
  end

  defp check_tag(entry, idx) do
    case get(entry, "tag") do
      tag when is_binary(tag) ->
        if Regex.match?(~r/^[a-z0-9-]+$/, tag) do
          :ok
        else
          fail(
            "tag",
            "A tag must match ^[a-z0-9-]+$ (lowercase letters, digits, hyphens).",
            "Rewrite tag ##{idx} #{inspect(tag)} using only a-z, 0-9 and hyphens.",
            idx
          )
        end

      _ ->
        fail(
          "tag",
          "Each tag entry requires a `tag` string.",
          "Add a `tag` string to entry ##{idx}.",
          idx
        )
    end
  end

  defp check_strength(entry, idx) do
    case get(entry, "strength") do
      strength
      when is_integer(strength) and strength >= @min_strength and strength <= @max_strength ->
        :ok

      strength when is_integer(strength) ->
        fail(
          "strength",
          "Strength must be an integer #{@min_strength}–#{@max_strength} (got #{strength}).",
          "Set entry ##{idx} strength within #{@min_strength}–#{@max_strength}.",
          idx
        )

      _ ->
        fail(
          "strength",
          "Strength must be an integer #{@min_strength}–#{@max_strength}.",
          "Set entry ##{idx} strength to a whole number between #{@min_strength} and #{@max_strength}.",
          idx
        )
    end
  end

  defp check_rationale(entry, idx) do
    case get(entry, "rationale") do
      rationale when is_binary(rationale) ->
        if String.length(String.trim(rationale)) >= @min_rationale do
          :ok
        else
          fail(
            "rationale",
            "A rationale must be at least #{@min_rationale} characters — it calibrates the strength.",
            "Explain in entry ##{idx} why this tag earns its strength (≥#{@min_rationale} chars).",
            idx
          )
        end

      _ ->
        fail(
          "rationale",
          "Each tag entry requires a `rationale` string.",
          "Add a `rationale` (≥#{@min_rationale} chars) to entry ##{idx}.",
          idx
        )
    end
  end

  # ── cross-member: distinct strengths (⟹ unique main tag) ──────────────────

  defp check_distinct_strengths(tags) do
    strengths = Enum.map(tags, &get(&1, "strength"))

    if length(strengths) == length(Enum.uniq(strengths)) do
      :ok
    else
      fail(
        "strength",
        "Every tag must carry a distinct strength (ties are ambiguous — the main tag is the unique maximum).",
        "Nudge tied strengths apart so each tag has its own weight and one tag is clearly primary."
      )
    end
  end

  # ── cross-member: no duplicate tag ────────────────────────────────────────

  defp check_no_duplicate_tags(tags) do
    names = Enum.map(tags, &get(&1, "tag"))

    if length(names) == length(Enum.uniq(names)) do
      :ok
    else
      fail(
        "tag",
        "A document may not carry the same tag twice.",
        "Remove the duplicate tag; keep the single entry with the strength you mean."
      )
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # String-key first (stored content is JSON), atom-key fallback for callers
  # that build content with atom keys in tests.
  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp get(_, _), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp fail(field, rule, fix, index) do
    {:error, {:label_spine, %{field: field, rule: rule, fix: fix, index: index}}}
  end

  defp fail(field, rule, fix) do
    {:error, {:label_spine, %{field: field, rule: rule, fix: fix}}}
  end
end

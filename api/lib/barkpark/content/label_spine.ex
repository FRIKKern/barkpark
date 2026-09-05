defmodule Barkpark.Content.LabelSpine do
  @moduledoc """
  The weighted-label spine validator — the cross-member label rules that the
  field DSL structurally cannot express (authoring-excellence D2).

  `validate/1` is a **pure** function: given a document's `content` map it
  returns `:ok` or `{:error, {:label_spine, details}}`. It is mounted at the
  publish wall (`Content.AuthoringWall.enforce/5`, the `label_gate`).

  `validate_shape/1` is the **CREATE-time** half of the same rules — see the
  next section.

  ## Two mounts: shape at CREATE, the full spine at PUBLISH

  The full `validate/1` runs at publish only. Drafts stay free: an unfinished
  draft may legitimately carry no `description` and no `tags` at all, and the
  wall is the point at which the document claims to be finished.

  But a *malformed* spine is not an unfinished one, and refusing it only at
  publish made the wall a **PARTIAL WRITE** (task-e89f4a9ed2f5ce0b, reproduced
  2026-09-01): `bp task create --publish` committed the create half, then the
  publish half 422'd `label_spine`, leaving an orphan `drafts.<id>` that no
  published-first reader (`bp task ready`, the board, the epic roster) can see.
  rc and a printed receipt both read as success, so an agent files a phantom and
  moves on — the same `drafts.*` population a 2026-09-04 census counted.

  So `validate_shape/1` runs on the CREATE path (`Content.Writer.
  create_document/4`, the one chokepoint all four create-family verbs funnel
  through) for `type:task`, BEFORE any row is persisted. It is the subset of
  `validate/1` that can be judged on a document that is not claiming to be
  finished:

    * `tags` absent, or `[]` → `:ok`. Nothing has been asserted yet.
    * `tags` present but not a list → refuse (a scalar is malformed, not
      unfinished).
    * every entry must be a `{tag, strength, rationale}` object with a legal
      tag / strength / rationale; strengths distinct; no duplicate tag; at most 12
      entries.
    * `description` and the **minimum** tag count are NOT checked — those are
      completeness rules, and enforcing them at birth would ban filing a draft.

  ## RULING — the registry (`unknown_tag`) half stays PUBLISH-TIME

  The second refusal the reproduction hit is `unknown_tag`
  (`Content.TagRegistry.validate_publish/3`, E3): every `tags[].tag` must
  resolve to a *published* `type:tag` document. It is deliberately NOT moved to
  the create path, for three reasons:

    1. **It is a judgement about mutable external state, not about the
       document.** Shape is a static structural property of the content map —
       true or false forever, and knowable with zero I/O. Registration is a
       property of the *dataset's* vocabulary at an instant; a tag that is
       unregistered when the row is filed may be registered before it is
       published. Refusing the birth would ban the legitimate "file the row now,
       curate the vocabulary later" order that `TagRegistry.seed_legacy_drafts/2`
       exists to serve.
    2. **It needs a database read, on a path whose failure mode is a 503.**
       `registered_subset/3` issues `Repo.all/1` and `nearest_registered/2` runs
       a `SET LOCAL` trgm probe inside its own transaction. There is no
       `{:error, _}` arm — an unreadable registry RAISES
       `DBConnection.ConnectionError`, which on the create path is caught by
       `Writer.do_create_document/5`'s rescue and rendered 503
       `storage_unavailable`. Mounting it pre-create therefore makes an
       unreadable registry an availability cliff on *every task filing*
       (fail-closed by construction, with no fail-open option that would not be
       a silent bypass of E3 — which D25 says is NEVER exempted). The publish
       path already tolerates that cost, because a publish is one deliberate act
       rather than every birth.
    3. **It does not manufacture the phantom.** The partial write this row is
       about is created by the SHAPE refusal — that is the one the reproduction
       hit first, and the one that fires on a create the caller believed was
       well-formed. An `unknown_tag` refusal at publish leaves a draft whose
       content is *correct*; the author's remedy is to register the tag and
       publish the SAME draft, so that draft is not an orphan, it is work in
       progress.

  Fail-closed vs fail-open on an unreadable registry, stated: it stays
  **fail-closed at publish** (the raise propagates; nothing swallows it into an
  `:ok`) and is **not consulted at create** at all. The publish refusal's body
  already names the exact unregistered tag(s) — `%{unknown: [name], suggestions:
  %{name => [nearest]}}` — so the retry is exact.

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
  The SHAPE half of the spine — the CREATE-time gate (task-e89f4a9ed2f5ce0b).

  Same rules, same `{:error, {:label_spine, details}}` tuple, same 422 through
  `Content.Errors.build/1` — but only the subset that is judgeable on a document
  that is not yet claiming to be finished. `description` and the MINIMUM tag
  count are omitted on purpose: a draft with neither is unfinished, not
  malformed, and drafts stay free. Absent or empty `tags` is `:ok` for the same
  reason.

  Pure: no I/O, no registry read (see the moduledoc's RULING on `unknown_tag`).
  """
  @spec validate_shape(map()) :: :ok | {:error, {:label_spine, details()}}
  def validate_shape(content) when is_map(content) do
    case get(content, "tags") do
      nil ->
        :ok

      [] ->
        :ok

      tags when is_list(tags) ->
        with :ok <- check_tag_max(tags),
             :ok <- check_entries(tags),
             :ok <- check_distinct_strengths(tags) do
          check_no_duplicate_tags(tags)
        end

      _ ->
        fail(
          "tags",
          "`tags` must be an array of {tag, strength, rationale} objects.",
          "Provide tags as a JSON array of objects, not a scalar."
        )
    end
  end

  def validate_shape(_other), do: :ok

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
    if length(tags) < @min_tags do
      fail(
        "tags",
        "A published document needs at least #{@min_tags} tag.",
        "Add at least #{@min_tags} weighted tag before publishing."
      )
    else
      check_tag_max(tags)
    end
  end

  # The MAXIMUM alone — the half `validate_shape/1` can enforce at birth. Too
  # many tags is malformed at any stage; too few is merely unfinished.
  defp check_tag_max(tags) do
    count = length(tags)

    if count > @max_tags do
      fail(
        "tags",
        "A document may carry at most #{@max_tags} tags (got #{count}).",
        "Keep the #{@max_tags} strongest tags; drop the rest."
      )
    else
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

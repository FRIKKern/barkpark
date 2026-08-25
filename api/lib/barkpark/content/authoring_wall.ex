defmodule Barkpark.Content.AuthoringWall do
  @moduledoc """
  THE publish wall (authoring-excellence D1/D6/D26) — the one shared
  enforcement chain every route that births or republishes walled content runs
  through:

      exemption read ONCE → label spine (E1/E2) → canonical Epic Paper quality →
      tag registry (E3) → dedup wall (E4) →
      clear-exemption-on-FULL-pass → main_tag stamp

  Extracted from `Barkpark.Content.Lifecycle`'s inline chain (charter D26) so
  the second producer of published walled documents —
  `Barkpark.Content.Papers.BlockOps.upsert_paper/2`, which births PUBLISHED
  papers via direct Repo writes and structurally cannot route through
  `publish_document/4` — enforces the SAME wall with the SAME tuples instead
  of forking it. `Lifecycle.publish_document/4` delegates here with
  byte-identical error tuples and side effects (pinned by the existing wall
  tests); `upsert_paper` calls it on a synthesized in-memory ref BEFORE its
  Repo write.

  ## Gates, in charter order

    1. **Label spine** (E1/E2, `@walled_types` only) — `LabelSpine.validate/1`
       → 422 `{:error, {:label_spine, details}}`. A grandfathered doc
       (exemption-ledger member, read ONCE at wall entry) passes a spine
       failure unchanged (D6 — "grandfathered republishes pass unchanged").
    2. **Canonical Epic Paper quality** — exact-tag-scoped and paper-only.
       `EpicQuality.validate/1` rejects malformed openings, outlines,
       first-pass overload, empty layout scaffolds, and failed declared reader
       checks. Tasks carrying the same taxonomy tag remain outside this gate.
    3. **Tag registry** (E3) — `TagRegistry.validate_publish/3`, NEVER
       exempted (D25): it self-scopes to weighted entries, so flat/tagless
       grandfathered docs skip it, but a grandfathered doc ADOPTING an
       unregistered weighted tag 422s regardless of exemption.
       → 422 `{:error, {:unknown_tag, payload}}`.
    4. **Dedup wall** (E4, `@walled_types` only) — refuse → 409
       `{:error, {:duplicate_of, payload}}`; the advise band rides the
       warnings channel and never blocks. A grandfathered doc skips E4
       entirely (the legacy corpus holds legitimately similar titles), and
       the ref's own published id is excluded so a republish never
       near-duplicates itself.

  ## Ratchet honesty (D28 — the fixed semantics this extraction carries)

    * `Exemptions.clear/2` fires only when the FULL wall passed — label spine
      AND E3 AND E4. A failed weighted adoption (spine passes, E3 422s) may
      never cost a doc its grandfathering for a publish that FAILED.
    * `stamp_main_tag/2` is recompute-else-drop for walled types: a content
      map whose tags no longer derive a main tag has any stale `main_tag`
      key DELETED, never republished. Non-walled types keep the historical
      passthrough — `main_tag` is not a reserved key outside the walled pair,
      so the wall must not eat a user field of the same name.

  The tag-count norm advisory (D5) is emitted at spine-pass, BEFORE the later
  gates can still fail. That is deliberate and safe: `Warnings` is a
  request-scoped process-dict queue — on a failed publish the controller
  drops it, so an advisory for a write that never happened is never surfaced.

  An error tuple is returned RAW — never flattened into the plugin
  `{:halted, _}` shape (D1/D27): the four codes map to distinct
  status codes (422/422/422/409) and flattening would mis-route them.
  """

  require Logger

  alias Barkpark.Content.{DedupWall, Document, Exemptions, LabelSpine, TagRegistry, Warnings}
  alias Barkpark.Content.Papers.EpicQuality

  # The publish wall enforces the label spine on Barkpark's own knowledge
  # types — the corpus the epic exists to keep findable. Deliberately a module
  # attribute, not schema-sniffing: widening the wall to a new type must be a
  # reviewed one-line decision, never an accident of registering a schema.
  # User content types (posts, products, …) publish exactly as before.
  @walled_types ~w(paper task)

  # The 2–4 tag-count norm (advisory FROM BIRTH, never promoted — charter D5).
  @tag_count_norm 2..4

  @doc "The wall's type scope, exposed so callers/tests share one source of truth."
  @spec walled_types() :: [String.t()]
  def walled_types, do: @walled_types

  @doc """
  Run the full wall over `ref` — a `%Document{}` (Lifecycle's draft) or an
  in-memory synthesized one (`upsert_paper`'s pre-write ref: `doc_id` = the
  paper slug, plus `title`/`content`/`dataset` and the tenancy scope).

  `pid` is the PUBLISHED doc id the exemption ledger and the E4
  self-exclusion key on (Lifecycle passes the `drafts.`-stripped id;
  `upsert_paper` passes the slug — papers key `(slug, dataset)`, no `drafts.`
  prefix). `opts` carries the caller's scope/context (`:workspace_id` /
  `:project_id` reach the E3 registry read).

  Returns `{:ok, content}` — the ref's content with the `main_tag` stamp
  applied (put on derivation, DROPPED when stale, passthrough for non-walled
  types) — or one of the four raw wall error tuples.
  """
  @spec enforce(Document.t() | map(), String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map() | nil}
          | {:error,
             {:label_spine | :unknown_tag | :duplicate_of | :invalid_epic_paper_quality, term()}}
  def enforce(ref, type, pid, dataset, opts \\ []) do
    # Exemption is read ONCE at wall entry: a grandfathered (pre-wall) doc
    # passes the WHOLE wall unchanged (D6), including E4. The ledger only
    # ever holds deploy-snapshot rows, so a FRESH doc (ingest-born paper,
    # new task) is never exempt — the wall is unconditional for births.
    exempt? = type in @walled_types and is_binary(pid) and Exemptions.member?(pid, dataset)

    with {:ok, spine_passed?} <- label_gate(ref, type, pid, exempt?),
         :ok <- epic_quality_gate(ref, type),
         :ok <- TagRegistry.validate_publish(ref, dataset, opts),
         :ok <- dedup_gate(ref, type, dataset, opts, exempt?) do
      # The ratchet shrink fires ONLY on a FULL wall pass (D28): a doc whose
      # spine passed but whose weighted adoption then 422d at E3 (or 409d at
      # E4) keeps its grandfathering — the publish FAILED, so charging the
      # exemption for it would strand the legacy doc behind a rejected write.
      if exempt? and spine_passed?, do: Exemptions.clear(pid, dataset)
      {:ok, stamp_main_tag(content_of(ref), type)}
    else
      # The wall's FIRST observability (charter D28), CARRIED across the
      # extraction seam: today a label_spine 422 is indistinguishable from any
      # other 422 in prod logs (proven: a 3h live window carried 32 anonymous
      # "Sent 422" lines, none attributable). Each of the four rejection
      # shapes emits a telemetry event + Logger.warning here — the ONE seam
      # every gate failure funnels through, shared now by BOTH producers
      # (Lifecycle.publish_document and BlockOps.upsert_paper) — then returns
      # the tuple UNCHANGED: the exact shape the controllers map to 422
      # (label_spine/unknown_tag/Epic quality) or 409 (duplicate_of), RAW
      # (never flattened into {:halted, _}, which would mis-route the 422s to
      # the 409 head).
      {:error, {:label_spine, _}} = error ->
        emit_wall_rejection(:label_spine, type, dataset)
        error

      {:error, {:unknown_tag, _}} = error ->
        emit_wall_rejection(:unknown_tag, type, dataset)
        error

      {:error, {:duplicate_of, _}} = error ->
        emit_wall_rejection(:duplicate_of, type, dataset)
        error

      # E4 could not RUN (its bounded scan timed out / the pool died). A
      # DIFFERENT rejection code from :duplicate_of on purpose: this one is
      # TRANSIENT and countable as an outage, not as a policy refusal — and it
      # must reach the caller, because swallowing it here is exactly the silent
      # fail-open the DedupWall rewrite killed.
      {:error, {:dedup_unavailable, _}} = error ->
        emit_wall_rejection(:dedup_unavailable, type, dataset)
        error

      {:error, {:invalid_epic_paper_quality, _}} = error ->
        emit_wall_rejection(:invalid_epic_paper_quality, type, dataset)
        error
    end
  end

  @doc """
  Dry-run the whole wall and return EVERY failing gate at once (BPML
  masterplan W0's validate-all): where `enforce/5` is a `with` chain that
  stops at the first refusal — correct for a real write — this runs each gate
  independently and collects the raw error tuples, so a producer learns all
  its violations in ONE round trip instead of one 4xx at a time.

  Deliberately side-effect-free: no exemption ratchet (a dry-run must never
  spend a grandfathering), no rejection telemetry (dashboards count real
  refusals, not rehearsals), nothing persisted. Returns `[]` on a clean pass.
  """
  @spec validate_all(Document.t() | map(), String.t(), String.t() | nil, String.t(), keyword()) ::
          [{atom(), term()}]
  def validate_all(ref, type, pid, dataset, opts \\ []) do
    exempt? = type in @walled_types and is_binary(pid) and Exemptions.member?(pid, dataset)

    [
      case label_gate(ref, type, pid, exempt?) do
        {:ok, _spine_passed?} -> nil
        {:error, tuple} -> tuple
      end,
      case epic_quality_gate(ref, type) do
        :ok -> nil
        {:error, tuple} -> tuple
      end,
      case TagRegistry.validate_publish(ref, dataset, opts) do
        :ok -> nil
        {:error, tuple} -> tuple
      end,
      case dedup_gate(ref, type, dataset, opts, exempt?) do
        :ok -> nil
        {:error, tuple} -> tuple
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The wall's first observability (charter D28): a structured telemetry event
  # + a Logger.warning at every publish-wall rejection, so a label_spine 422 is
  # attributable in prod logs and countable on a dashboard (BarkparkWeb.Telemetry
  # can subscribe a counter tagged by :code/:type/:dataset). `code` is the
  # rejection atom (`:label_spine` | `:unknown_tag` | `:invalid_epic_paper_quality`
  # | `:duplicate_of` | `:dedup_unavailable`).
  defp emit_wall_rejection(code, type, dataset) do
    :telemetry.execute(
      [:barkpark, :authoring, :wall_rejection],
      %{count: 1},
      %{code: code, type: type, dataset: dataset}
    )

    Logger.warning("authoring wall rejected a #{type} publish in dataset #{dataset}: #{code}")

    :ok
  end

  defp epic_quality_gate(ref, "paper"), do: EpicQuality.validate(content_of(ref))
  defp epic_quality_gate(_ref, _type), do: :ok

  # ── E1/E2 — the label spine ─────────────────────────────────────────────────
  #
  # Gate semantics (charter D6, amended by D28):
  #
  #   * `LabelSpine.validate` PASSES → `{:ok, true}` (spine proven; the
  #     exemption clear is DEFERRED to the full-pass tail in `enforce/5`),
  #     plus the 2–4 tag-count norm advisory on the warnings channel when the
  #     count is legal but outside the norm.
  #   * validate FAILS → grandfathered publishes pass unchanged (`{:ok,
  #     false}` — spine NOT proven, so the ratchet never fires); everything
  #     else is the fail-closed 422 (`{:error, {:label_spine, details}}`).
  #
  # Drafts stay free by construction — this runs only at publish/birth time.
  defp label_gate(ref, type, pid, exempt?) when type in @walled_types do
    case LabelSpine.validate(content_of(ref)) do
      :ok ->
        emit_tag_norm_advisory(ref, pid)
        emit_spacing_norm_advisory(ref, pid, type)
        {:ok, true}

      {:error, {:label_spine, _details}} = error ->
        if exempt?, do: {:ok, false}, else: error
    end
  end

  # Catch-all (D28): a non-walled type never proves the spine.
  defp label_gate(_ref, _type, _pid, _exempt?), do: {:ok, false}

  # ── E4 — the dedup wall ─────────────────────────────────────────────────────
  #
  # Scoped to the same @walled_types pair as the label spine (an unscoped
  # mount would 409 unrelated user content types on title similarity).
  # Refuse → {:error, {:duplicate_of, payload}} (409 with the incumbent
  # published id); the advise band NEVER blocks — its entries ride the mutate
  # success envelope via the warnings channel (D5), each keeping the severity
  # DedupWall stamped ("warning" — sharper than the tag-count norm's
  # "advisory"). A grandfathered doc (exempt at wall entry) skips E4 entirely.
  defp dedup_gate(_ref, _type, _dataset, _opts, true), do: :ok

  defp dedup_gate(ref, type, dataset, opts, _exempt?) when type in @walled_types do
    case DedupWall.check(ref, type, dataset, opts) do
      :ok ->
        :ok

      {:ok, warnings} when is_list(warnings) ->
        Enum.each(warnings, &Warnings.put(&1.code, &1.message, &1.severity))
        :ok

      {:error, {:duplicate_of, _payload}} = error ->
        error

      # The wall could not RUN (bounded scan timed out / pool death). Forward it
      # — swallowing it here would restore the exact silent fail-open the
      # DedupWall rewrite killed, with publish answering 200 on a duplicate
      # check that never happened. `content.dedup_bypass: true` is the escape.
      {:error, {:dedup_unavailable, _message}} = error ->
        error
    end
  end

  defp dedup_gate(_ref, _type, _dataset, _opts, _exempt?), do: :ok

  # ── main_tag stamp (D7/D20/D28) ─────────────────────────────────────────────

  @doc """
  Denormalize the derived main tag (the strength argmax) onto `content` at the
  write chokepoint, so `filter[main_tag]` is an indexed `->>` equality (btree
  expression index, migration 20260712121000) instead of a seq-scanning jsonb
  argmax predicate. `LabelSpine.main_tag/1` is the single derivation — the
  backfill migration reuses it, so backfilled and freshly written rows can
  never disagree.

  Recompute-else-drop for walled types (D28): when the tags no longer derive
  a main tag (legacy flat strings under the ratchet, tags stripped under
  exemption), any carried `main_tag` key is DELETED — a republish may never
  re-persist a stale stamp. Non-walled types keep the historical passthrough:
  `main_tag` is only a reserved derived key on the walled pair, and eating a
  same-named user field elsewhere would be a silent data loss. Never a nil
  key, never a raise.
  """
  @spec stamp_main_tag(map() | nil, String.t()) :: map() | nil
  def stamp_main_tag(%{} = content, type) do
    case LabelSpine.main_tag(content) do
      {:ok, tag} -> Map.put(content, "main_tag", tag)
      :error when type in @walled_types -> Map.delete(content, "main_tag")
      :error -> content
    end
  end

  def stamp_main_tag(content, _type), do: content

  # Advisory, never blocking (charter D5): a legal tag count (1–12) outside
  # the 2–4 norm rides the mutate success envelope as a warning. Emitted only
  # AFTER a validate pass, so the count is known-legal here. Deliberately at
  # spine-pass rather than full-pass (D28): the queue is request-scoped and
  # dropped on error responses, so an entry queued before a later gate fails
  # is discarded with the failed write, never surfaced.
  defp emit_tag_norm_advisory(ref, pid) do
    count = ref |> content_of() |> Kernel.||(%{}) |> Map.get("tags", []) |> length()

    unless count in @tag_count_norm do
      Warnings.put(
        "label_norm",
        "#{pid}: #{count} tag(s) — the norm is 2–4. " <>
          "Every extra label dilutes the strong ones; weak entries are pruning candidates."
      )
    end
  end

  # Advisory, never blocking: an empty paragraph is an editor scaffold, not
  # published layout. Reader-owned section tokens provide cross-surface rhythm;
  # persisting spacer content creates empty HTML, terminal rows, accessibility
  # nodes, and noisy outlines. Papers only: task briefs ride a different
  # envelope.
  # Emitted at spine-pass for the same reason as the tag-count norm — the
  # request-scoped queue is dropped with a failed write, never surfaced.
  defp emit_spacing_norm_advisory(ref, pid, "paper") do
    content = content_of(ref) || %{}
    blocks = List.wrap(content["blocks"])

    spacer_count = count_spacer_paragraphs(blocks)

    if content["style"] in ["article", "article-wide"] and spacer_count > 0 do
      Warnings.put(
        "spacing_norm",
        "#{pid}: article paper contains #{spacer_count} empty paragraph block(s) used as " <>
          "layout — remove them from published composition; reader tokens own section rhythm " <>
          "while the editor may retain an unpublished scaffold."
      )
    end

    :ok
  end

  defp emit_spacing_norm_advisory(_ref, _pid, _type), do: :ok

  # The advisory's counter mirrors the tagged HARD gate's semantics by CALLING
  # it: `EpicQuality.empty_paragraph?/1` is the single owner of "is this
  # paragraph a spacer", and `EpicQuality.nested_keys/0` the single owner of
  # "which containers does the walk descend", so the advisory warns exactly
  # where the tagged gate would refuse instead of passing an author it later
  # 422s. A re-derived predicate here diverged twice already: the review of
  # #11616 caught a two-key walk missing spacers inside
  # columns/steps/panels/tabs/sections/content/items/rows, and the copy that
  # replaced it still read key SHAPE rather than flattened text, so it both
  # missed value-keyed prose and stopped at a paragraph without descending the
  # paragraph's OWN `content` — where the live nested leaves actually sit, and
  # which the hard gate's `walk_maps/1` does descend.
  defp count_spacer_paragraphs(blocks) when is_list(blocks),
    do: blocks |> Enum.map(&spacer_paragraphs_in/1) |> Enum.sum()

  defp count_spacer_paragraphs(_), do: 0

  defp spacer_paragraphs_in(%{"type" => "paragraph"} = block) do
    own = if EpicQuality.empty_paragraph?(block), do: 1, else: 0
    own + nested_spacer_paragraphs(block)
  end

  defp spacer_paragraphs_in(%{} = block), do: nested_spacer_paragraphs(block)

  defp spacer_paragraphs_in(_), do: 0

  defp nested_spacer_paragraphs(%{} = block) do
    Enum.reduce(EpicQuality.nested_keys(), 0, fn key, acc ->
      case Map.get(block, key) do
        children when is_list(children) -> acc + count_spacer_paragraphs(children)
        _ -> acc
      end
    end)
  end

  defp content_of(%Document{content: content}), do: content
  defp content_of(%{content: content}), do: content
  defp content_of(_), do: nil
end

defmodule Barkpark.Content.Related do
  @moduledoc """
  Tag-weighted related documents fused with backlinks — the weighted-tag READ
  payoff (authoring-excellence D68–D71).

  Two legs, one list:

    * **Tag leg (pure SQL, D69)** — candidates sharing ≥1 tag NAME
      (case-insensitive) with the source. Credit per shared name is
      `LEAST(src_strength, cand_strength) / 100.0`, summed over shared names;
      each side is deduped to MAX strength PER TAG NAME before summing (2 docs
      corpus-wide carry duplicate tag names — the double-credit guard). A
      candidate whose `main_tag` is one of the shared names earns a flat
      `+0.5` bonus. The read touches ONLY the `documents.tags_meta` GENERATED
      column — never `content->'tags'` (the #4178 detoast law) — with the same
      shape guards as `Search.DocumentsRetriever.tag_boost_key/1`
      (`jsonb_typeof(e) = 'object'` + the strength digits regex). Titles
      project the `documents.title` COLUMN — `content->>'title'` is EMPTY for
      2117/2132 weighted docs (proven prod trap).
    * **Reference leg (D70)** — `Content.Graph.reverse_referencers/2`, the
      SOLE owner of the inbound-edge read. Its fail-closed tenancy hydration
      is reused as-is, NEVER re-implemented in SQL, and edges are NEVER ranked
      by `edge.weight` (the graph.ex law). Each inbound edge contributes
      `@ref_bonus_per` to the candidate's score, saturating at
      `@ref_bonus_cap` (pinned by an ordering test) so a heavily-referenced
      doc can nudge past a tag-tie but never drown a strong tag match.

  Fusion happens IN ELIXIR by doc identity: an entry carries `doc_id`, `type`,
  `title`, `score`, `sources` (`[:tags]` / `[:references]` / both) and the
  `shared_tags` detail (`[%{tag, src_strength, cand_strength}]`) so surfaces
  can render WHY. A source with zero weighted tags degrades honestly to
  backlink-only related (the ~35% untagged corpus) — never empty-by-crash.

  Scope mirrors the graph reads (MEDIUM-5 posture — this emits title + type +
  existence only): tenancy via `Scope.scope_to_workspace_or_global/3`,
  ownership via `Scope.scope_to_owner/2` (nil caller fails closed to
  unowned-only), grant narrowing via `Scope.maybe_scope_to_grants/2`, dataset
  via the resolved-`dataset_id`-else-string discriminator, published
  perspective only, self excluded, and (tag leg only — task-b69106868a235768)
  the schema-visibility clamp (`Schema.bypasses_visibility_gate?/1` +
  `Schema.public_type_names/2`, the same pair `Query.restrict_to_visible_types/3`
  applies) so a private-visibility candidate type never surfaces to a caller
  who hasn't earned the unclamped view. The reference leg stays on
  `Graph.reverse_referencers/2`'s own clamp — out of scope here, tracked as
  backlog `wb-bl-graph-scope-query-visibility-clamp`.

  Prod cost reference (D69, EXPLAIN on guerrilla): 54.5ms @ 242-candidate
  fan-out, 106ms @ 1004, all buffer-cache hits — shipped index-free.
  """

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, Graph, Schema, Scope, WriteScope}
  alias Barkpark.Repo

  @default_limit 10
  @max_limit 50

  # D70 inbound-reference bonus: per-edge credit and its saturation cap. The
  # cap (0.6 = three edges) is a RANKING CONTRACT pinned by an ordering test —
  # raising it lets reference-heavy docs drown strong tag matches; change it
  # only with the test.
  @ref_bonus_per 0.2
  @ref_bonus_cap 0.6

  # The tag-scoring lateral (D69). One row per candidate, always (aggregate
  # over zero join rows yields NULL tag_score — filtered in the outer WHERE).
  #
  #   * `st` — the SOURCE's tags, passed ONCE as a single jsonb param (the
  #     source row is read once in Elixir, never re-joined per candidate).
  #   * `ct` — the CANDIDATE's `tags_meta` GENERATED column (#4178 law).
  #   * both sides: object/digits guards copied from
  #     `documents_retriever.ex` `tag_boost_key/1`, then MAX-per-lower(name)
  #     dedupe BEFORE the join so duplicate tag names can never double-credit.
  #   * `main_tag_hit` — the candidate's `content->>'main_tag'` equals a
  #     SHARED name. This is the one candidate-`content` detoast in the read:
  #     acceptable today because the seq-scan already reads full rows; the
  #     escape hatch when an index lands is deriving main_tag from `tags_meta`
  #     (argmax, 2109/2110 corpus-consistent) or a second generated column —
  #     see backlog `ae-related-read-index-tuning`.
  @tag_leg_sql """
  (SELECT
     SUM(LEAST(st.strength, ct.strength))::float / 100.0 AS tag_score,
     COALESCE(bool_or(st.tag = lower(?->>'main_tag')), false) AS main_tag_hit,
     jsonb_agg(jsonb_build_object(
       'tag', st.tag, 'src_strength', st.strength, 'cand_strength', ct.strength
     ) ORDER BY st.tag) AS shared_tags
   FROM (
     SELECT lower(e->>'tag') AS tag, MAX((e->>'strength')::int) AS strength
     FROM jsonb_array_elements(?::jsonb) AS e
     WHERE jsonb_typeof(e) = 'object'
       AND e->>'strength' ~ '^[0-9]+$'
       AND e->>'tag' IS NOT NULL
     GROUP BY lower(e->>'tag')
   ) AS st
   JOIN (
     SELECT lower(e->>'tag') AS tag, MAX((e->>'strength')::int) AS strength
     FROM jsonb_array_elements(?.tags_meta) AS e
     WHERE jsonb_typeof(e) = 'object'
       AND e->>'strength' ~ '^[0-9]+$'
       AND e->>'tag' IS NOT NULL
     GROUP BY lower(e->>'tag')
   ) AS ct ON ct.tag = st.tag)
  """

  @typedoc "One related entry — provenance-carrying, surface-renderable."
  @type entry :: %{
          doc_id: String.t(),
          type: String.t(),
          title: String.t() | nil,
          score: float(),
          sources: [:tags | :references],
          shared_tags: [%{tag: String.t(), src_strength: integer(), cand_strength: integer()}]
        }

  @doc "The pinned reference-bonus cap — exposed so tests assert the contract."
  @spec ref_bonus_cap() :: float()
  def ref_bonus_cap, do: @ref_bonus_cap

  @doc """
  Related documents for `id_or_slug` within `dataset`, best first.

  Options: `:limit` (default #{@default_limit}, clamped 1..#{@max_limit}),
  plus the standard scope opts (`:workspace_id`, `:project_id`,
  `:caller_context`, `:grant_scoped`) a route caller threads via
  `scope_opts/1`. Returns `[]` for an unresolvable id — existence-hiding,
  same posture as `Graph.reverse_referencers/2`.
  """
  @spec related_documents(String.t(), String.t(), keyword()) :: [entry()]
  def related_documents(id_or_slug, dataset, opts \\ []) when is_binary(id_or_slug) do
    case Graph.resolve_doc(id_or_slug, dataset, opts) do
      nil ->
        []

      %Document{} = source ->
        limit = clamp_limit(Keyword.get(opts, :limit, @default_limit))

        # Over-fetch the tag leg (~2N) so the Elixir fusion can still fill N
        # slots after reference bonuses reshuffle the tail.
        tag_hits = tag_candidates(source, dataset, opts, limit * 2)
        ref_hits = Graph.reverse_referencers(id_or_slug, [dataset: dataset] ++ opts)

        fuse(tag_hits, ref_hits, Content.published_id(source.doc_id), limit)
    end
  end

  # ── Tag leg ────────────────────────────────────────────────────────────────

  defp tag_candidates(%Document{} = source, dataset, opts, cap) do
    case source_tags(source.id) do
      nil ->
        # Zero weighted tags → the tag leg contributes nothing; the caller
        # degrades to backlink-only related (D70 honesty clause).
        []

      src_tags ->
        workspace_id = Keyword.get(opts, :workspace_id)
        project_id = Keyword.get(opts, :project_id)
        prefix = DraftId.drafts_prefix() <> "%"

        Document
        |> join(
          :inner_lateral,
          [d],
          sc in fragment(@tag_leg_sql, d.content, ^src_tags, d),
          on: true,
          as: :score
        )
        # The lateral aggregate always yields one row; NULL tag_score means
        # zero shared tag names — not a candidate.
        |> where([score: sc], not is_nil(sc.tag_score))
        # Published perspective only (the maybe_published_only idiom: status
        # AND the drafts.-prefix conjunct, belt-and-braces).
        |> where([d], d.status == "published" and not like(d.doc_id, ^prefix))
        |> where([d], d.id != ^source.id)
        |> scope_to_dataset(dataset, opts)
        # global-read: related-read mirrors docs_with_tag/backlinks — route callers always thread a real workspace via scope_opts; nil workspace is the documented single-tenant/direct-caller bridge.
        |> Scope.scope_to_workspace_or_global(workspace_id, project_id)
        |> Scope.scope_to_owner(Keyword.get(opts, :caller_context))
        |> Scope.maybe_scope_to_grants(opts)
        |> restrict_to_visible_types(dataset, opts)
        |> order_by([d, score: sc],
          desc:
            fragment(
              "? + CASE WHEN ? THEN 0.5 ELSE 0.0 END",
              sc.tag_score,
              sc.main_tag_hit
            ),
          asc: d.doc_id
        )
        |> limit(^cap)
        |> select([d, score: sc], %{
          doc_id: d.doc_id,
          type: d.type,
          # The title COLUMN — content->>'title' is empty for 2117/2132
          # weighted docs (D69 proven trap).
          title: d.title,
          score:
            fragment(
              "? + CASE WHEN ? THEN 0.5 ELSE 0.0 END",
              sc.tag_score,
              sc.main_tag_hit
            ),
          shared_tags: sc.shared_tags
        })
        |> Repo.all()
        |> Enum.map(&normalize_tag_hit/1)
    end
  end

  # The source's tags, fetched ONCE and passed as one jsonb param (D69).
  # Reads `tags_meta` (the GENERATED column — its generation expression already
  # folds a non-array `content->'tags'` to '[]'), then requires at least one
  # VALID weighted entry (object shape + digit strength, mirroring the SQL
  # guards) — a legacy flat-string-tagged or untagged source yields nil.
  #
  # Returned as the RAW Elixir list, never a pre-encoded JSON string: the
  # `?::jsonb` cast in @tag_leg_sql makes Postgres infer the param as jsonb,
  # so Postgrex must do the encoding — a Jason-encoded string would arrive as
  # a jsonb SCALAR ("[…]" the string), and `jsonb_array_elements` errors with
  # `cannot extract elements from a scalar` (run-proven).
  defp source_tags(pk) do
    tags_meta =
      Document
      |> where([d], d.id == ^pk)
      |> select([d], fragment("?.tags_meta", d))
      |> Repo.one()

    case tags_meta do
      tags when is_list(tags) ->
        if Enum.any?(tags, &weighted_entry?/1), do: tags, else: nil

      _ ->
        nil
    end
  end

  defp weighted_entry?(%{"tag" => tag, "strength" => strength}) when is_binary(tag) do
    is_integer(strength) or (is_binary(strength) and Regex.match?(~r/^[0-9]+$/, strength))
  end

  defp weighted_entry?(_), do: false

  defp normalize_tag_hit(hit) do
    shared =
      Enum.map(hit.shared_tags || [], fn s ->
        %{
          tag: s["tag"],
          src_strength: s["src_strength"],
          cand_strength: s["cand_strength"]
        }
      end)

    hit
    |> Map.put(:shared_tags, shared)
    |> Map.put(:sources, [:tags])
  end

  # ── Fusion (D70 — Elixir, by doc identity) ─────────────────────────────────

  defp fuse(tag_hits, ref_hits, source_pub_id, limit) do
    ref_counts =
      ref_hits
      # A self-edge must never relate a doc to itself.
      |> Enum.reject(&(&1.from_doc_id == source_pub_id))
      |> Enum.group_by(& &1.from_doc_id)

    base = Map.new(tag_hits, &{&1.doc_id, &1})

    ref_counts
    |> Enum.reduce(base, fn {doc_id, refs}, acc ->
      bonus = min(length(refs) * @ref_bonus_per, @ref_bonus_cap)

      case Map.fetch(acc, doc_id) do
        {:ok, entry} ->
          Map.put(acc, doc_id, %{
            entry
            | score: entry.score + bonus,
              sources: [:tags, :references]
          })

        :error ->
          # Backlink-only candidate — hydrated (title/type) by
          # reverse_referencers' fail-closed read; zero shared tags.
          [ref | _] = refs

          Map.put(acc, doc_id, %{
            doc_id: doc_id,
            type: ref.type,
            title: ref.title,
            score: bonus,
            sources: [:references],
            shared_tags: []
          })
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{-&1.score, &1.doc_id})
    |> Enum.take(limit)
  end

  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)
  defp clamp_limit(_), do: @default_limit

  # The read-time schema-visibility clamp for the tag leg (task-b69106868a235768).
  # ONE PREDICATE, not a third copy: the tier test is
  # `Schema.bypasses_visibility_gate?/1` and the allowlist is
  # `Schema.public_type_names/2` — the exact pair `Content.Query`'s
  # `restrict_to_visible_types/3` applies (query.ex:1719-1726, the canonical
  # shape). Copied locally rather than called cross-module: that function is
  # private to Query and query.ex is owned by another task this cycle.
  #
  # A caller `bypasses_visibility_gate?/1` accepts (Studio/authoring tier) pays
  # no schema read at all — inert for every route caller today, since
  # `QueryController.related/2` only ever reaches here through `authed?/1`,
  # which excludes the public-read tier but admits any other real token. The
  # reference leg (`Graph.reverse_referencers/2`, fused in at
  # `related_documents/3` above) is NOT clamped here — see the moduledoc.
  defp restrict_to_visible_types(query, dataset, opts) do
    cond do
      Schema.bypasses_visibility_gate?(Keyword.get(opts, :caller_context)) ->
        query

      is_binary(dataset) ->
        where(query, [d], d.type in ^Schema.public_type_names(dataset, tenancy_opts(opts)))

      true ->
        where(query, [d], d.type in ^[])
    end
  end

  defp tenancy_opts(opts), do: Keyword.take(opts, [:workspace_id, :project_id])

  # Mirrors `Content.Query`'s private dataset scope (the docs_with_tag
  # precedent): prefer the resolved `dataset_id`, fall back to the legacy
  # `dataset` STRING filter.
  defp scope_to_dataset(query, dataset, opts) do
    case WriteScope.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end

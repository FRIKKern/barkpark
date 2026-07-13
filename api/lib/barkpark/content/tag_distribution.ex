defmodule Barkpark.Content.TagDistribution do
  @moduledoc """
  Per-type tag-count distribution over DOCUMENT CONTENT (authoring-excellence
  D45, split from `ae-curator-feed`).

  This is a legibility read over the published corpus's `content->tags`: for a
  type (or set of types) it answers "which tags are used, on how many published
  documents, per type?" — the raw material a curator surfacing (or a human
  auditing the tag registry) needs to see whether the label vocabulary is
  healthy or fragmenting.

  ## NOT a Crystallizer change

  `Barkpark.Search.Crystallizer` rolls up raw SEARCH EVENTS (the `search_intel_*`
  tables keyed by surface + scope). It has zero awareness of document content
  and cannot see a document's tags at all. Tag-count distribution is a wholly
  different corpus (published documents, not query events), so it lives here as
  an independent pure query rather than as a Crystallizer surface.

  ## Both tag shapes are counted

  A document's `content["tags"]` is a JSON array whose elements are EITHER the
  wave-2 weighted object `{"tag": name, "strength": n, "rationale": …}` OR a
  legacy flat string `"name"`. The `COALESCE(e->>'tag', e #>> '{}')` flatten —
  the exact idiom `Query.search_tags_for_type/5` uses — materialises the tag
  NAME from either shape (`->>'tag'` returns NULL on a scalar; `#>>'{}'` reads
  the scalar itself), so a corpus mid-migration is counted correctly and a flat
  string and its weighted twin collapse onto the same tag name.

  ## Published only, by design

  Draft and published copies of a document are SEPARATE rows (the `drafts.`
  prefix). Counting both would double-count every document that has an open
  draft twin, inflating the distribution. The distribution is over the
  published library — the corpus the wall governs — so it filters
  `status = "published"`. A tag that only ever appears on drafts is invisible
  here (correct: it is not yet part of the published vocabulary).

  Derivable and stateless: no new table, no persisted artifact (anti-inventory —
  the daily `Barkpark.Workers.TagDistribution` gives it a heartbeat via
  `Logger`, nothing more).
  """

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  alias Barkpark.Content.{Document, WriteScope}
  alias Barkpark.Repo

  @type row :: %{type: String.t(), tag: String.t(), count: non_neg_integer()}

  @doc """
  Count published-document tag usage grouped by `{type, tag}` for one type or a
  list of types within `dataset`, ordered by count descending (ties broken by
  type then tag name for a stable result).

  `opts` carries the same tenant scope as every other content read
  (`:workspace_id` / `:project_id`); omit them for the flat/global corpus. Both
  weighted-object and legacy flat-string tag shapes contribute; documents whose
  `tags` is absent or not an array contribute zero rows (the LATERAL join drops
  them). A NULL-named element (a JSON `null` in the array) is filtered out so it
  can never form a phantom tag group.

  Returns `[]` for an empty type list or an empty corpus.
  """
  @spec per_type(String.t() | [String.t()], String.t(), keyword()) :: [row()]
  def per_type(type_or_types, dataset, opts \\ [])

  def per_type(type, dataset, opts) when is_binary(type),
    do: per_type([type], dataset, opts)

  def per_type([], _dataset, _opts), do: []

  def per_type(types, dataset, opts) when is_list(types) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.type in ^types)
    |> where([d], d.status == "published")
    |> scope_to_dataset(dataset, opts)
    # global-read: D45 tag-count distribution is deliberate instance-wide admin telemetry — the daily TagDistribution worker reads across all tenants (workspace_id nil → global); fail-open by design, NOT a per-request tenant read. (marker MUST stay the line directly above the call — tenant-scope-check.sh only reads the immediately-preceding line.)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    # A set-returning function is illegal in WHERE, so the per-document tag
    # unnest is an inner LATERAL join. The COALESCE materialises the tag NAME
    # from either the weighted-object or the flat-string shape; the CASE guards
    # a non-array / absent `tags` into zero rows. Same idiom as
    # `Query.search_tags_for_type/5` (query.ex), addressed by the named binding
    # `:tag_elem` so scope helpers may grow joins of their own.
    |> join(
      :inner_lateral,
      [d],
      e in fragment(
        "(SELECT COALESCE(e->>'tag', e #>> '{}') AS tag FROM jsonb_array_elements(CASE WHEN jsonb_typeof(?->'tags') = 'array' THEN ?->'tags' ELSE '[]'::jsonb END) AS e)",
        d.content,
        d.content
      ),
      on: true,
      as: :tag_elem
    )
    |> where([tag_elem: e], not is_nil(e.tag))
    |> group_by([d, tag_elem: e], [d.type, e.tag])
    |> select([d, tag_elem: e], %{type: d.type, tag: e.tag, count: count(d.doc_id)})
    |> order_by([d, tag_elem: e], desc: count(d.doc_id), asc: d.type, asc: e.tag)
    |> Repo.all()
  end

  # Mirrors `Barkpark.Content.Query`'s private dataset scope: prefer the
  # resolved `dataset_id` (a workspace may hold two same-named dataset strings),
  # falling back to the legacy `dataset` STRING filter when no dataset row
  # resolves (a read against a never-written dataset returns no rows either way).
  defp scope_to_dataset(query, dataset, opts) do
    case WriteScope.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end

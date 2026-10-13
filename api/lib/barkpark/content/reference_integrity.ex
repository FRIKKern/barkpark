defmodule Barkpark.Content.ReferenceIntegrity do
  @moduledoc """
  Which documents still point at a document — the check a `delete` runs before
  it removes one (task-c8c22ee8076535fe).

  Sanity refuses to delete a document that another document references with a
  strong reference, and so does Barkpark's `/mutate` door now. A referrer is
  any other document in the same dataset and tenant whose content holds:

    * a reference object `{"_ref": "<id>"}` anywhere — top level, nested in an
      object, or inside an array — unless it is marked `"_weak": true`; or
    * a bare-id value in a field the schema declares as `reference` (the older
      shape `Content.find_referencing_docs/3` already reads).

  It reads live document content, not the `content_edges` table: edges are
  projected by a background job and can lag a write, which would let a delete
  through right after a reference was added.

  Both spellings of the target (`<id>` and `drafts.<id>`) are excluded, so a
  document never blocks its own delete.
  """

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.Repo

  import Barkpark.Content.Scope, only: [scope_to_workspace: 3]

  # Every reference object to $id at any depth, skipping `_weak: true`. Bound
  # as a parameter: Ecto reads each `?` in a fragment as a placeholder, and
  # jsonpath filters are written with `?`.
  @strong_ref_path "$.** ? (@._ref == $id && !exists(@._weak ? (@ == true)))"

  @default_limit 50

  @doc """
  Documents that hold a strong reference to `doc_id`, as
  `[%{id: doc_id, type: type}]`, at most `:limit` (default #{@default_limit}).
  `opts` carries the request scope (`:workspace_id`, `:project_id`).
  """
  @spec referrers(String.t(), String.t(), keyword()) :: [%{id: String.t(), type: String.t()}]
  def referrers(doc_id, dataset, opts \\ []) when is_binary(doc_id) do
    # Fail CLOSED on tenancy (task-f758cabf3a936e5e): a caller with no
    # workspace reads no referrers at all, rather than every tenant's. Both
    # halves below take the same scope, so they can never disagree about
    # whose documents count. The /mutate door always resolves a workspace.
    if is_nil(Keyword.get(opts, :workspace_id)),
      do: [],
      else: scoped_referrers(doc_id, dataset, opts)
  end

  defp scoped_referrers(doc_id, dataset, opts) do
    pub_id = DraftId.published_id(doc_id)
    self_ids = [pub_id, DraftId.draft_id(pub_id)]
    limit = Keyword.get(opts, :limit, @default_limit)

    ref_objects =
      from(d in Document,
        where: d.dataset == ^dataset and d.doc_id not in ^self_ids,
        where:
          fragment(
            "jsonb_path_exists(?, (?::text)::jsonpath, jsonb_build_object('id', ?::text))",
            d.content,
            ^@strong_ref_path,
            ^pub_id
          ),
        order_by: [asc: d.doc_id],
        limit: ^limit,
        select: %{id: d.doc_id, type: d.type}
      )
      |> scope_to_workspace(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )
      |> Repo.all()

    bare_ids =
      pub_id
      |> Content.find_referencing_docs(dataset, opts)
      |> Enum.reject(&(&1.doc_id in self_ids))
      |> Enum.map(&%{id: &1.doc_id, type: &1.type})

    (ref_objects ++ bare_ids)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
    |> Enum.take(limit)
  end

  @doc """
  Batched sibling of `referrers/3` (task-6b5e4b3e572d38c9): referrers for the
  WHOLE `doc_ids` set in one pass, bounded query count independent of
  `length(doc_ids)`, instead of `length(doc_ids)` × this module's own query
  count. `Content.Mutations`'s delete batching is the one caller; see its
  moduledoc for why one-call-per-id turned a batch of N deletes into
  O(N × reference fields) queries inside one transaction.

  Returns `%{published_id => [%{id:, type:}]}`.

  THE ONE DELIBERATE BEHAVIOUR DIFFERENCE from calling `referrers/3` once per
  id: every id in `doc_ids` is excluded from EVERY OTHER id's referrer set,
  not only its own. Two documents in the SAME batch that reference each
  other no longer block one another -- the whole batch is one transaction,
  so both vanish together regardless of processing order. The single-id
  path is order-dependent for exactly this case (a referencer already
  deleted earlier in the SAME transaction is invisible to a later
  `referrers/3` call; one that comes LATER in the mutation list still blocks
  the earlier delete) -- this is a tested, intentional refinement, not an
  accident. `Content.Mutations` only reaches for this function on a RUN of
  2+ consecutive delete mutations, so a lone delete inside a mixed batch
  keeps the exact single-id semantics unchanged.
  """
  @spec referrers_for_ids([String.t()], String.t(), keyword()) :: %{
          optional(String.t()) => [%{id: String.t(), type: String.t()}]
        }
  def referrers_for_ids(doc_ids, dataset, opts \\ []) when is_list(doc_ids) do
    pub_ids = doc_ids |> Enum.map(&DraftId.published_id/1) |> Enum.uniq()

    if is_nil(Keyword.get(opts, :workspace_id)) do
      for id <- pub_ids, into: %{}, do: {id, []}
    else
      scoped_referrers_for_ids(pub_ids, dataset, opts)
    end
  end

  defp scoped_referrers_for_ids(pub_ids, dataset, opts) do
    excluded_all = pub_ids |> Enum.flat_map(&[&1, DraftId.draft_id(&1)]) |> Enum.uniq()
    limit = Keyword.get(opts, :limit, @default_limit)

    ref_objects_by_target = ref_objects_for_ids(pub_ids, excluded_all, dataset, opts)
    bare_by_target = Content.Edges.find_referencing_docs_for_ids(pub_ids, dataset, opts)

    for pub_id <- pub_ids, into: %{} do
      bare =
        bare_by_target
        |> Map.get(pub_id, [])
        |> Enum.reject(&(&1.doc_id in excluded_all))
        |> Enum.map(&%{id: &1.doc_id, type: &1.type})

      merged =
        (Map.get(ref_objects_by_target, pub_id, []) ++ bare)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.id)
        |> Enum.take(limit)

      {pub_id, merged}
    end
  end

  # The `$.**` structural-reference arm, batched: ONE query whose WHERE is an
  # OR across every target id (one database round trip regardless of batch
  # size), then — because that WHERE only proves "matches AT LEAST ONE id",
  # never which — each candidate row's own `content` (already fetched) is
  # walked in Elixir to attribute it to the right target(s). The candidate
  # set is already narrowed by the SQL OR, so this walk runs over the (small)
  # match set, never the whole corpus.
  defp ref_objects_for_ids(pub_ids, excluded_all, dataset, opts) do
    conditions =
      Enum.reduce(pub_ids, dynamic(false), fn id, acc ->
        dynamic(
          [d],
          ^acc or
            fragment(
              "jsonb_path_exists(?, (?::text)::jsonpath, jsonb_build_object('id', ?::text))",
              d.content,
              ^@strong_ref_path,
              ^id
            )
        )
      end)

    from(d in Document,
      where: d.dataset == ^dataset and d.doc_id not in ^excluded_all,
      where: ^conditions,
      select: %{id: d.doc_id, type: d.type, content: d.content}
    )
    |> scope_to_workspace(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      matches = Enum.filter(pub_ids, &strong_ref?(row.content, &1))

      Enum.reduce(matches, acc, fn target, acc2 ->
        Map.update(
          acc2,
          target,
          [%{id: row.id, type: row.type}],
          &[%{id: row.id, type: row.type} | &1]
        )
      end)
    end)
  end

  # Elixir-side mirror of `@strong_ref_path`'s jsonpath: visit every node
  # (`$.**`), matching `{"_ref" => id}` unless that SAME node also carries
  # `"_weak" => true`.
  defp strong_ref?(value, id) when is_map(value) do
    (Map.get(value, "_ref") == id and Map.get(value, "_weak") != true) or
      Enum.any?(Map.values(value), &strong_ref?(&1, id))
  end

  defp strong_ref?(value, id) when is_list(value), do: Enum.any?(value, &strong_ref?(&1, id))
  defp strong_ref?(_value, _id), do: false
end

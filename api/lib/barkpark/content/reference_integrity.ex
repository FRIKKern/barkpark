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
end

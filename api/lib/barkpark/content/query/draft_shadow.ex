defmodule Barkpark.Content.Query.DraftShadow do
  @moduledoc """
  In the `:drafts` perspective a document is its draft when it has one, else
  its published row. A filter must be judged on that document
  (task-85c4dccf2382c55b).

  `Content.Query` filters stored rows and then keeps one row per document. So
  when a draft no longer matched a filter but its published row still did, the
  draft was filtered away and the published row came back as the hit: a
  filtered Studio list showed a document under a value its draft no longer has.

  `filter/4` drops a published row that a draft shadows, in the same WHERE as
  the filter, so the list, its count, its facets, `collapse` and every page
  read the same set. The draft is looked up among `visible`: the rows of the
  same type the caller may read (dataset, workspace, project, owner, grants,
  pinned ids), with no filter. A draft the caller may not read shadows nothing
  for them.

  Nothing is added unless the perspective is `:drafts` and there is a filter:
  `:published` and `:raw` reads, and unfiltered `:drafts` lists, run the SQL
  they ran before. A draft row passes as is, since `drafts.drafts.<id>` is
  never stored, so the clause is a plain anti-join and the lookup uses the
  `(doc_id, type, dataset_id)` unique index.
  """

  import Ecto.Query

  @doc """
  `visible` narrowed by `apply_filter.(visible, filter_map)`, and, when
  `opts[:perspective]` is `:drafts` and `filter_map` holds a filter, without
  the published rows that a draft in `visible` shadows.
  """
  @spec filter(Ecto.Query.t(), map(), keyword(), (Ecto.Query.t(), map() -> Ecto.Query.t())) ::
          Ecto.Query.t()
  def filter(visible, filter_map, opts, apply_filter) do
    filtered = apply_filter.(visible, filter_map)

    if Keyword.get(opts, :perspective) == :drafts and map_size(filter_map) > 0 do
      twin =
        from(t in visible,
          where: t.doc_id == fragment("'drafts.' || ?", parent_as(:shadowed).doc_id),
          select: 1
        )

      from(d in filtered, as: :shadowed, where: not exists(twin))
    else
      filtered
    end
  end
end

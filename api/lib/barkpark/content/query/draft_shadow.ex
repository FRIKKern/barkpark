defmodule Barkpark.Content.Query.DraftShadow do
  @moduledoc """
  In the `:drafts` perspective a document is its draft when it has one, else
  its published row. A filter on the document's content must be judged on
  that document (task-85c4dccf2382c55b).

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

  ## Row fields

  `_id`, `doc_id` and `status` are facts about a stored row: its id, `drafts.`
  prefix and all, and its lifecycle status, which is never `published` on a
  draft. A draft cannot answer for them, so they are never asked of it. The
  default desk's "Published" and "Archived" lists (`status=<option>`), the Go
  TUI's same lists and the JS client's `getDocuments` (`_id in ids`) read the
  rows they read before.

  | Filter under `:drafts` | A published row that has a draft is a hit when |
  |---|---|
  | none | never: the merge shows the draft |
  | row fields only (`_id in ids`, `status=published`) | the row matches, as before |
  | content only (`author=ada`) | never: the draft is the hit when it matches |
  | row fields and content (`_id in ids` + `author=ada`) | the row matches, and its draft matches the content part |
  | `$or` | each branch reads the same way: a branch of row fields only makes the whole `$or` a row filter |

  `:published` and `:raw` reads, unfiltered `:drafts` lists and row-field
  filters run the SQL they ran before. For a content-only filter the clause is
  a plain anti-join (a draft row passes as is, since `drafts.drafts.<id>` is
  never stored) and the lookup uses the `(doc_id, type, dataset_id)` unique
  index.
  """

  import Ecto.Query

  @row_fields ~w(_id doc_id status)

  @doc """
  `visible` narrowed by `apply_filter.(visible, filter_map)`, and, when
  `opts[:perspective]` is `:drafts`, without the published rows whose draft in
  `visible` does not match the content part of `filter_map`.
  """
  @spec filter(Ecto.Query.t(), map(), keyword(), (Ecto.Query.t(), map() -> Ecto.Query.t())) ::
          Ecto.Query.t()
  def filter(visible, filter_map, opts, apply_filter) do
    filtered = apply_filter.(visible, filter_map)
    on_content = content_part(filter_map)

    cond do
      Keyword.get(opts, :perspective) != :drafts or map_size(on_content) == 0 ->
        filtered

      # No row field anywhere: the draft, when it matches, is in `filtered`
      # too and wins the merge, so the published row is never needed.
      on_content == filter_map ->
        from(d in filtered, as: :shadowed, where: not exists(twin(visible)))

      true ->
        matching = twin(apply_filter.(visible, on_content))

        from(d in filtered,
          as: :shadowed,
          where: not exists(twin(visible)) or exists(matching)
        )
    end
  end

  @doc """
  The part of `filter_map` a draft is asked: the map without its row fields.
  An `$or` with a branch of row fields only is dropped whole, since that
  branch can match the published row whatever the draft holds.
  """
  @spec content_part(map()) :: map()
  def content_part(filter_map) do
    {groups, fields} = filter_map |> Map.drop(@row_fields) |> Map.pop("$or")
    branches = groups |> List.wrap() |> Enum.map(&branch_part/1)

    if branches == [] or Enum.any?(branches, &(&1 == %{})),
      do: fields,
      else: Map.put(fields, "$or", branches)
  end

  defp branch_part(%{} = branch), do: content_part(branch)
  defp branch_part(_malformed), do: %{}

  # The draft of the outer row, among `rows`.
  defp twin(rows) do
    from(t in rows,
      where: t.doc_id == fragment("'drafts.' || ?", parent_as(:shadowed).doc_id),
      select: 1
    )
  end
end

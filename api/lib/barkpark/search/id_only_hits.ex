defmodule Barkpark.Search.IdOnlyHits do
  @moduledoc """
  Whether the words step of a search found its hits through the document-id
  arm alone (task-5985afa7b6e7454f).

  The words step matches the text OR a document whose id is one of the query's
  words. A full task title holding "SDK" found no document by its words (a path
  such as "/v1/data/search" is indexed as one token) and tag `sdk` by its id.
  That one hit kept the pipeline's zero-hit recovery from running, so the task
  looked missing. The id arm stays: "task-abc123 fix" still answers the
  document `task-abc123` next to the one holding both words. Only when the text
  arm alone finds nothing does the pipeline treat the search as empty and run
  the any-word recovery; the id hits stay when the recovery finds nothing.
  """

  # Each word stands for at most these many ids: itself, its published id and
  # its draft id (`DocumentsRetriever.id_forms/1`).
  @id_forms_per_word 3

  @doc """
  True when a multi-word, every-word search counted `count` hits and none of
  them holds the words: `text_query` is the words step without the id arm, and
  is read only when the id arm could have supplied every hit.

  Always false for a suggestion (`suggest?`): the type-ahead runs no recovery,
  so it never pays for this read.

  Known limit: the bound counts #{@id_forms_per_word} ids per word, but a
  document id is unique per (doc_id, type, dataset), so one id held by more
  types than that can exceed it. The check is then skipped and the search
  answers as before this module.
  """
  @spec ids_only?(non_neg_integer(), [map()], :all | :any, boolean(), (-> Ecto.Queryable.t())) ::
          boolean()
  def ids_only?(count, [_, _ | _] = groups, :all, false, text_query) when count > 0 do
    members = Enum.flat_map(groups, & &1.members)

    # A word with a dot also matches ids that start with it, so no count rules
    # it out. Otherwise more hits than the ids can reach means the text found some.
    reachable? =
      Enum.any?(members, &String.contains?(&1, ".")) or
        count <= @id_forms_per_word * length(members)

    reachable? and not Barkpark.Repo.exists?(text_query.())
  end

  def ids_only?(_count, _groups, _match, _suggest?, _text_query), do: false
end

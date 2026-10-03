defmodule Barkpark.Search.PublicIndex do
  @moduledoc """
  The public full-text index (owner ruling #20, task-3c68de39a19285c4).

  `documents.public_search_vector` is the search vector over a document's
  content with every field its schema restricts (`private`, `visibility:
  private | owner_only`, a non-empty `readable_by`, at any declared depth)
  removed. It is NULL when nothing was removed. The search retriever reads
  `coalesce(public_search_vector, search_vector)` for every caller that is not
  an admin, so a word that occurs only in a hidden field neither matches nor
  moves the hit count.

  Two triggers keep it current (migration 20261003200000): one on every
  document write, one that recomputes a type's documents when its schema's
  field declarations change. `census/1` and `reindex/1` are the re-runnable
  check and repair behind `mix barkpark.search.reindex_public` — for a box
  restored from a dump taken before the migration, or rows written with
  triggers disabled.
  """

  alias Barkpark.Repo

  # Static SQL only: `$1` is the optional type (NULL = every type).
  @census_sql """
  SELECT d.type, count(*)
  FROM documents d
  WHERE ($1::text IS NULL OR d.type = $1)
    AND d.public_search_vector IS DISTINCT FROM
      bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
  GROUP BY d.type
  ORDER BY d.type
  """

  @reindex_sql """
  UPDATE documents d
  SET public_search_vector =
    bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
  WHERE ($1::text IS NULL OR d.type = $1)
    AND d.public_search_vector IS DISTINCT FROM
      bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
  """

  @doc """
  Count documents whose stored public vector differs from what the trigger
  would compute now, grouped by type. Read-only.
  """
  @spec census(keyword()) :: [%{type: String.t(), stale: non_neg_integer()}]
  def census(opts \\ []) do
    %{rows: rows} = Repo.query!(@census_sql, [type_param(opts)], timeout: :infinity)
    Enum.map(rows, fn [type, n] -> %{type: type, stale: n} end)
  end

  @doc """
  Recompute the public vector of every stale document (optionally one type).
  Returns the number of rows updated. Writes only `public_search_vector`.
  """
  @spec reindex(keyword()) :: non_neg_integer()
  def reindex(opts \\ []) do
    %{num_rows: n} = Repo.query!(@reindex_sql, [type_param(opts)], timeout: :infinity)
    n
  end

  defp type_param(opts) do
    case Keyword.get(opts, :type) do
      t when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end
end

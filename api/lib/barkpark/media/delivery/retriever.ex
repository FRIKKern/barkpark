defmodule Barkpark.Media.Delivery.Retriever do
  @moduledoc false

  import Ecto.Query
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Search.Synonyms
  alias Barkpark.Search.TypoPolicy

  @asset_type "mediaAsset"

  @spec build_text_filter(String.t(), map(), map(), keyword()) :: Ecto.Query.t() | nil
  def build_text_filter(dataset, parsed, config, opts \\ []) do
    relaxed = Keyword.get(opts, :relaxed, false)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    terms = expanded_terms(dataset, parsed, workspace_id)

    if terms == [] and Map.get(parsed, :excludes, []) == [] do
      nil
    else
      include_dyn = include_dynamic(terms, config, relaxed)
      exclude_dyn = exclude_dynamic(Map.get(parsed, :excludes, []), relaxed)

      base =
        MediaFile
        |> from(as: :media)
        |> join(
          :left,
          [m],
          d in ^asset_doc_join_query(dataset, workspace_id, project_id),
          as: :asset,
          on: fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
        )

      base =
        if include_dyn,
          do: where(base, ^include_dyn),
          else: base

      if exclude_dyn do
        where(base, ^dynamic([m, d], not (^exclude_dyn)))
      else
        base
      end
    end
  end

  @spec apply_to_query(Ecto.Query.t(), String.t(), map(), map(), keyword()) :: Ecto.Query.t()
  def apply_to_query(query, dataset, parsed, config, opts \\ []) do
    case build_text_filter(dataset, parsed, config, opts) do
      nil ->
        query

      filter_query ->
        ids_subquery =
          filter_query
          |> exclude(:order_by)
          |> select([m], m.id)

        where(query, [m], m.id in subquery(ids_subquery))
    end
  end

  # Pre-scoped Document subquery the text-match LEFT-JOIN binds against. Mirrors
  # Barkpark.Media.Delivery.Search.asset_doc_join_query/4: type + NULL-tolerant dataset
  # (dataset_id authoritative, string fallback) + NULL-tolerant workspace
  # envelope. Closes the search arm of the cross-workspace metadata leak — the
  # `ilike(d.title, …)` / tag match can no longer attach another workspace's
  # asset doc to this workspace's blob (barkpark-vmv1). A nil workspace_id
  # (unscoped path) leaves the workspace filter off (deliberate global read);
  # the `:shared_only` sentinel does NOT — see `join_scope_workspace/3`.
  defp asset_doc_join_query(dataset, workspace_id, project_id) do
    dataset_id = Barkpark.Content.resolve_read_dataset_id(dataset, project_id: project_id)

    Document
    |> where([d], d.type == ^@asset_type)
    |> join_scope_dataset(dataset, dataset_id)
    |> join_scope_workspace(workspace_id, project_id)
  end

  defp join_scope_dataset(query, dataset, dataset_id) when is_binary(dataset_id) do
    where(
      query,
      [d],
      d.dataset_id == ^dataset_id or (is_nil(d.dataset_id) and d.dataset == ^dataset)
    )
  end

  defp join_scope_dataset(query, dataset, _dataset_id) do
    where(query, [d], d.dataset == ^dataset)
  end

  defp join_scope_workspace(query, nil, _project_id), do: query

  # `:shared_only` — the request-side empty-scope sentinel
  # (task-3e2a70930c6df723), forwarded here VERBATIM: `Search.maybe_filter_text/3`
  # rebuilds `retriever_opts` as `workspace_id: Keyword.get(opts, :workspace_id)`,
  # so whatever `ScopeHelpers.scope_opts/1` put on the conn arrives unchanged.
  #
  # The sibling this module's own header says it MIRRORS
  # (`Search.join_scope_workspace/3`) was given this arm and this one was not,
  # which is the whole shape: an atom matches neither the `nil` clause nor the
  # two `is_binary/1` clauses, so a media search with a `q` from a request that
  # resolved no workspace raised FunctionClauseError — a 500 on the live
  # `/v1/media/:dataset/search` door.
  #
  # `is_nil(d.workspace_id)` and NOT a collapse to `nil`: the nil clause above
  # returns the query UNTOUCHED (the deliberate global read), so "fixing" the
  # crash by mapping the sentinel to nil would turn a 500 into the
  # cross-workspace metadata leak this join was added to close.
  defp join_scope_workspace(query, :shared_only, _project_id),
    do: where(query, [d], is_nil(d.workspace_id))

  defp join_scope_workspace(query, workspace_id, nil) when is_binary(workspace_id) do
    where(query, [d], d.workspace_id == ^workspace_id or is_nil(d.workspace_id))
  end

  defp join_scope_workspace(query, workspace_id, project_id)
       when is_binary(workspace_id) and is_binary(project_id) do
    where(
      query,
      [d],
      is_nil(d.workspace_id) or
        (d.workspace_id == ^workspace_id and
           (is_nil(d.project_id) or d.project_id == ^project_id))
    )
  end

  defp expanded_terms(dataset, parsed, workspace_id) do
    raw = Map.get(parsed, :raw, "")

    synonym_terms =
      if raw != "" do
        Synonyms.search_terms("media", dataset, raw, workspace_id)
      else
        []
      end

    local =
      (Map.get(parsed, :terms, []) ++
         Map.get(parsed, :phrases, []) ++ Map.get(parsed, :prefixes, []))
      |> Enum.reject(&(&1 == ""))

    (synonym_terms ++ local)
    |> Enum.uniq()
  end

  defp include_dynamic(terms, config, relaxed) do
    threshold = TypoPolicy.threshold(config, relaxed)

    Enum.reduce(terms, nil, fn term, dyn ->
      pattern = like_pattern(term)
      # Documents-surface parity (the gap this closes): `typo_policy.enabled`
      # and `min_len_1typo` live in the SAME config object media reads for its
      # thresholds, and media used to apply `similarity()` to every term
      # regardless — so an admin who turned typo tolerance off, or raised the
      # minimum token length, changed document results and nothing at all here.
      fuzzy? = TypoPolicy.fuzzy_term?(config, term)

      # WHY-LEFT (authoring-excellence D49 — do NOT `%`-rewrite these
      # `similarity()` arms or add a media-files trgm index expecting a win).
      # This clause is a CROSS-TABLE OR spanning `media_files` (m.*) UNION
      # `documents` (d.*, reached via the LEFT JOIN in build_text_filter/4). A
      # BitmapOr can only be built from branches over ONE relation; because the
      # disjunction also references d.title / d.content (the joined table), the
      # planner must materialize the join first and evaluate the OR as a filter —
      # a trgm index on m.original_name is unreachable. PROVEN live: rewriting to
      # `%` AND adding a real `gin(original_name gin_trgm_ops)` index yields a
      # BYTE-IDENTICAL plan (the new index never appears; under enable_seqscan=off
      # it falls to a pkey scan, 3032 buffers vs 122). The inverse guard in
      # test/barkpark/media/delivery/similarity_not_indexable_test.exs pins this
      # (red-if-someone-adds-a-real-index). Reaching the index needs a pre-join
      # EXISTS/UNION restructure so media_files is trgm-scanned BEFORE the join
      # (backlog ae-search-or-arm-restructure). See D49(e).
      clause =
        dynamic(
          [m, d],
          ilike(m.original_name, ^pattern) or ilike(m.filename, ^pattern) or
            ilike(d.title, ^pattern) or
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?)",
              d.content,
              ^pattern
            )
        )

      clause =
        if fuzzy? do
          dynamic(
            [m, d],
            ^clause or
              fragment("similarity(?, ?) > ?", m.original_name, ^term, ^threshold) or
              fragment("similarity(?, ?) > ?", m.filename, ^term, ^threshold)
          )
        else
          clause
        end

      if dyn, do: dynamic([m, d], ^dyn or ^clause), else: clause
    end)
  end

  defp exclude_dynamic(excludes, relaxed) do
    # Config-blind by construction, exactly as before — see the documents
    # retriever's exclude arm for the same note; routed through the shared
    # reader so the two surfaces' defaults cannot drift apart again.
    threshold = TypoPolicy.threshold(%{}, relaxed)

    Enum.reduce(excludes, nil, fn term, dyn ->
      pattern = like_pattern(term)

      # WHY-LEFT (authoring-excellence D49 — do NOT `%`-rewrite this arm). Two
      # compounding disqualifiers: (1) it is the SAME cross-table OR over
      # media_files ∪ documents as include_dynamic/3 above (join defeats the
      # trgm index), and (2) the whole clause is NEGATED at build_text_filter/4
      # via `not(^exclude_dyn)` — a trgm GIN lists MATCHES, never the
      # complement. A `%` rewrite plans byte-identically to a Seq/pkey scan
      # either way. See D49(b)/(e).
      clause =
        dynamic(
          [m, d],
          ilike(m.original_name, ^pattern) or ilike(m.filename, ^pattern) or
            ilike(d.title, ^pattern) or
            fragment("similarity(?, ?) > ?", m.original_name, ^term, ^threshold) or
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?)",
              d.content,
              ^pattern
            )
        )

      if dyn, do: dynamic([m, d], ^dyn or ^clause), else: clause
    end)
  end

  def like_pattern(term) do
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end
end

defmodule Barkpark.Media.DatasetIdBackfill do
  @moduledoc """
  Stamp `media_files.dataset_id` on the legacy rows that carry only the
  `dataset` string (task-fa5ccc714ad4a939). PREPARATION, run by the owner:

      bin/barkpark eval 'Barkpark.Release.backfill_media_dataset_id()'                     # census, writes nothing
      bin/barkpark eval 'Barkpark.Release.backfill_media_dataset_id(apply: true, journal: "/var/tmp/media-ds.json")'
      bin/barkpark eval 'Barkpark.Release.undo_media_dataset_id_backfill("/var/tmp/media-ds.json")'

  ## Why the rows exist

  `Media.put_scope_attrs/2` stamps `dataset_id` only when a project resolved.
  Until #16677 it did not for a token-bound non-Default workspace, so every blob
  uploaded into one carries `dataset_id IS NULL`. The read tolerates that
  (`Search.scope_media_to_dataset/3`'s second disjunct), but the
  `(dataset_id, inserted_at DESC, id DESC)` cursor index cannot seek for them.

  ## The target, and why no row changes visibility

  A row is stamped with the dataset its readers ALREADY resolve:
  `Tenancy.get_or_create_dataset(project, row.dataset)` where `project` is
  `Tenancy.scope_project_id(project_id: row.project_id, workspace_id:
  row.workspace_id)` — the row's own project, else its workspace's default
  project, else the instance default project. That is the same function
  `Search.resolve_dataset_id/2` calls for the scope those readers search in,
  so the resolved disjunct (`m.dataset_id == ^id`) takes over from the
  NULL-tolerant one for the same set of searches. `workspace_id` and
  `project_id` are never written. A `dataset` string that is not a valid
  dataset slug is reported and left unstamped.

  ## Split readers: left unstamped, reported

  A row filed under a project that is NOT its workspace's default project is
  read by two scopes that resolve two DIFFERENT dataset ids: a project-scoped
  read of its own project (`id(project, X)`) and a project-less workspace read
  (`id(workspace default, X)`), which today matches it only through the
  NULL-tolerant disjunct. No single stamp keeps it visible to both: stamping it
  into its own project removes it from the workspace read (a freshly uploaded
  row there is not in that read either). Such groups are reported as
  `split_readers` and never stamped, so no row changes visibility; whether to
  stamp them anyway is a ruling, not a default.

  Creating a Dataset row is a write to the tenancy tables, so the census lists
  every one it would create, and `apply` records them.

  ## The seek needs the read to change too

  Stamping alone does not make the cursor page seek. Measured on 200k
  previously-unstamped rows, one tenant, cursor mid-corpus (the
  20260907090000 bench shape): before the backfill a Parallel Seq Scan + top-N
  Sort, 7,224 buffers, 34.4 ms; after it, with today's NULL-tolerant read
  (`dataset_id = $1 OR (dataset_id IS NULL AND dataset = $2)`), STILL a
  Parallel Seq Scan + Sort, 11,187 buffers, 29.4 ms. The same page with the
  NULL disjunct removed is an Index Scan on
  `media_files_ds_inserted_at_id_index`, 9 buffers, 0.06 ms. Dropping the
  disjunct is safe only where no unstamped rows remain, and split-reader rows
  (above) stay unstamped by design, so that is a separate, ruled change.

  ## Reversible

  `apply` requires a `:journal` path and writes, before returning, every Dataset
  it created and every `{media id, dataset_id}` it stamped. `undo/1` sets those
  rows back to NULL (only where the stamp is still the journalled one) and
  deletes a created Dataset only when nothing references it any more.
  """

  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @doc """
  Measure the population (criterion 1). Writes nothing.

  Returns `%{null_rows, groups, to_create, unresolvable, control}` where each
  group is `%{workspace_id, project_id, dataset, rows, target_project_id,
  dataset_id, create?}` and `control` is one real unstamped row (id, dataset,
  workspace_id) — the positive control: a census that finds rows can print one.
  """
  def census(repo \\ Repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT workspace_id::text, project_id::text, dataset, count(*)::int, min(id::text)
        FROM media_files WHERE dataset_id IS NULL
        GROUP BY workspace_id, project_id, dataset
        ORDER BY count(*) DESC
        """,
        []
      )

    groups =
      Enum.map(rows, fn [ws, proj, dataset, n, sample] ->
        target = Tenancy.scope_project_id(project_id: proj, workspace_id: ws)
        existing = target && is_binary(dataset) && Tenancy.get_dataset(target, dataset)
        # The project a project-LESS read in this workspace resolves its dataset
        # in. A row filed under any OTHER project is read by two scopes that
        # resolve two different dataset ids; see "Split readers" in the moduledoc.
        split? = is_binary(proj) and proj != Tenancy.scope_project_id(workspace_id: ws)

        %{
          workspace_id: ws,
          project_id: proj,
          dataset: dataset,
          rows: n,
          sample_id: sample,
          target_project_id: target,
          dataset_id: existing && existing.id,
          split_readers?: split?,
          create?: not split? and is_binary(target) and is_binary(dataset) and is_nil(existing)
        }
      end)

    %{
      null_rows: Enum.sum(Enum.map(groups, & &1.rows)),
      groups: groups,
      to_create: Enum.filter(groups, & &1.create?),
      unresolvable: Enum.filter(groups, &is_nil(&1.target_project_id)),
      split_readers: Enum.filter(groups, & &1.split_readers?),
      control: control(repo)
    }
  end

  defp control(repo) do
    case repo.query!(
           "SELECT id::text, dataset, workspace_id::text FROM media_files WHERE dataset_id IS NULL ORDER BY inserted_at, id LIMIT 1",
           []
         ) do
      %{rows: [[id, dataset, ws]]} -> %{id: id, dataset: dataset, workspace_id: ws}
      _ -> nil
    end
  end

  @doc """
  Census, then (only with `apply: true` and a `:journal` path) stamp every
  resolvable group. Returns the census plus `%{stamped, created, skipped}`.
  """
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    plan = census(repo)

    if Keyword.get(opts, :apply, false) do
      journal = Keyword.fetch!(opts, :journal)

      if File.exists?(journal),
        do: raise(ArgumentError, "journal #{journal} exists; refusing to overwrite it")

      apply_plan(plan, repo, journal)
    else
      Map.merge(plan, %{stamped: 0, created: 0, skipped: []})
    end
  end

  # The journal path is the operator's own `bin/barkpark eval` argument, never
  # request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp apply_plan(plan, repo, journal) do
    {stamped, created, skipped} =
      Enum.reduce(plan.groups, {[], [], []}, fn group, {stamped, created, skipped} ->
        case dataset_for(group) do
          {:ok, dataset_id, new?} ->
            ids = stamp(repo, group, dataset_id)
            created = if new?, do: [dataset_id | created], else: created
            {Enum.map(ids, &[&1, dataset_id]) ++ stamped, created, skipped}

          {:error, reason} ->
            {stamped, created, [Map.put(group, :reason, reason) | skipped]}
        end
      end)

    File.write!(
      journal,
      Jason.encode!(%{version: 1, created_datasets: created, stamped: stamped})
    )

    Map.merge(plan, %{
      stamped: length(stamped),
      created: length(created),
      skipped: skipped,
      journal: journal
    })
  end

  defp dataset_for(%{split_readers?: true}), do: {:error, :split_readers}
  defp dataset_for(%{target_project_id: nil}), do: {:error, :no_project}
  defp dataset_for(%{dataset: d}) when not is_binary(d), do: {:error, :no_dataset_string}
  defp dataset_for(%{dataset_id: id}) when is_binary(id), do: {:ok, id, false}

  defp dataset_for(%{target_project_id: project, dataset: dataset}) do
    case Tenancy.get_or_create_dataset(project, dataset) do
      {:ok, %Tenancy.Dataset{id: id}} -> {:ok, id, true}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_dataset_slug}
      {:error, reason} -> {:error, reason}
    end
  end

  # Re-filters on `dataset_id IS NULL`, so a row stamped since the census (a new
  # upload, a concurrent run) is never overwritten.
  defp stamp(repo, group, dataset_id) do
    %{rows: rows} =
      repo.query!(
        """
        UPDATE media_files SET dataset_id = $1::text::uuid
        WHERE dataset_id IS NULL
          AND workspace_id IS NOT DISTINCT FROM $2::text::uuid
          AND project_id IS NOT DISTINCT FROM $3::text::uuid
          AND dataset = $4
        RETURNING id::text
        """,
        [dataset_id, group.workspace_id, group.project_id, group.dataset]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  @doc """
  Reverse an `apply` from its journal: unstamp each journalled row whose
  `dataset_id` is still the journalled one, then delete each created Dataset
  that no row in any `dataset_id` FK table references. Returns
  `%{unstamped, deleted_datasets, kept_datasets}`.
  """
  # The journal path is the operator's own `bin/barkpark eval` argument, never
  # request input.
  # sobelow_skip ["Traversal.FileModule"]
  def undo(journal, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    %{"stamped" => stamped, "created_datasets" => created} =
      journal |> File.read!() |> Jason.decode!()

    unstamped =
      stamped
      |> Enum.group_by(fn [_id, ds] -> ds end, fn [id, _ds] -> id end)
      |> Enum.reduce(0, fn {ds, ids}, acc ->
        %{num_rows: n} =
          repo.query!(
            "UPDATE media_files SET dataset_id = NULL WHERE dataset_id = $1::text::uuid AND id::text = ANY($2)",
            [ds, ids]
          )

        acc + n
      end)

    {deleted, kept} = Enum.split_with(created, &(not referenced?(repo, &1)))
    Enum.each(deleted, &repo.query!("DELETE FROM datasets WHERE id = $1::text::uuid", [&1]))

    %{unstamped: unstamped, deleted_datasets: deleted, kept_datasets: kept}
  end

  # Every table carrying a `dataset_id` FK (migration
  # 20260527131000_add_dataset_id_columns). The FK is `on_delete: :nilify_all`,
  # so deleting a Dataset that ANY of them has started to use would silently
  # unscope those rows. A created Dataset is deleted only when all are empty.
  @dataset_fk_tables ~w(documents revisions mutation_events media_files schema_definitions
                        search_intel_events search_intel_crystals search_intel_merge_patterns
                        search_synonyms webhooks api_tokens paper_events)

  # One static statement over all of them, built at compile time from the
  # fixed list above (no runtime interpolation).
  @referenced_sql "SELECT " <>
                    Enum.map_join(
                      @dataset_fk_tables,
                      " OR ",
                      &"EXISTS (SELECT 1 FROM #{&1} WHERE dataset_id = $1::text::uuid)"
                    )

  defp referenced?(repo, dataset_id) do
    %{rows: [[found]]} = repo.query!(@referenced_sql, [dataset_id])
    found
  end
end

defmodule Barkpark.Tenancy.DatasetDelete do
  @moduledoc """
  Permanently delete one dataset and everything stored under it
  (task-a944250b938671bd). Reached through `Barkpark.Tenancy.delete_dataset/1`.

  Every table with a `dataset_id` column is in exactly one class below, and
  every table naming a dataset by string is swept or retained. The tripwires in
  `dataset_delete_test.exs` red when a new table is neither.

  | Class | Tables | How they go |
  |---|---|---|
  | walked | `media_files`, `documents` | One by one through `Media.delete_file/2` (blob, CDN, renditions, hooks) and `Content.delete_document/4` (delete hooks, `mutation_events`, broadcast). |
  | cascade + string | `webhooks`, `schema_definitions`, `mutation_events`, `search_*` | Their writers do not always stamp `dataset_id` (webhooks never do), so the rows are deleted by workspace + project + slug, and the FK cascade takes the stamped rest. |
  | cascade | `revisions`, `paper_events`, `document_view_days`, `document_popularity` | `Repo.delete(dataset)`: the FKs are `ON DELETE CASCADE`. Revisions can only leave this way; their trigger refuses a direct delete. |
  | string only | `@swept` below | An explicit delete keyed on workspace + project + slug. No FK reaches them. |

  Another workspace's rows are never deleted. Search rows used to be stamped
  with the Default project's dataset of the same slug whatever their
  workspace, so before the cascade any row of another workspace that points at
  this dataset has its `dataset_id` set NULL (`detached` in the receipt).

  `@retained` tables name the dataset but stay: access trails and credential
  ledgers are evidence, not content. `api_tokens.dataset_id` is set NULL by its
  FK and the token keeps its `dataset` string binding. `@not_tenant` tables
  carry a `dataset_id` that is not a tenant row: a backup and a refresh queue
  that drains itself.

  A table without a `project_id` value is keyed on workspace + slug, and is
  swept only when no other project in the workspace has a dataset with the same
  slug. Otherwise its rows stay: an orphan is recoverable, deleting a sibling
  dataset's rows is not.

  The `production` dataset is refused (`{:error, :production_dataset}`): every
  workspace is created with it and the flat routes fall back to it, so it is
  never a throwaway. Deleting all of a workspace is `delete_workspace/1`.

  The delete appends a `content_mutation` / `dataset_deleted` row to the
  workspace's audit chain. Everything runs in one transaction. Media blob
  removal and webhook dispatch are deferred until it commits, the same way
  `delete_workspace/1` does it.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Audit
  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Content.Document
  alias Barkpark.Content.WriteScope
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.OwnedTables
  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Dataset, Project, Workspace}

  @protected_slug "production"

  @project_keyed ~w(access_grants preview_links scheduled_publishes share_links)
  @workspace_keyed ~w(github_sync_conflicts sync_cursors sync_dead_letters
                      sync_push_conflicts sync_push_cursors sync_push_doc_revs user_prefs)
  @scope_keyed %{"data_keys" => "dataset:", "search_surface_config" => ""}

  @swept @project_keyed ++
           @workspace_keyed ++ Map.keys(@scope_keyed) ++ ~w(shares authoring_exemptions)
  @retained ~w(paper_access_log preview_token_jti api_tokens audit_events)
  @not_tenant ~w(paper_events_dataset_rescope_backup search_refresh_pending)

  @walked ~w(documents media_files)
  @cascade_and_string %{
    "webhooks" => :dataset,
    "schema_definitions" => :dataset,
    "mutation_events" => :dataset,
    "search_synonyms" => :scope,
    "search_intel_crystals" => :scope,
    "search_intel_events" => :scope,
    "search_intel_merge_patterns" => :scope
  }
  @cascade ~w(revisions paper_events document_view_days document_popularity)
  @append_only ~w(revisions)

  @detachable (@walked ++ Map.keys(@cascade_and_string) ++ @cascade) -- @append_only

  @doc "Tables this delete sweeps by their `dataset` / `scope` string alone."
  def swept_tables, do: Enum.sort(@swept)

  @doc "Tables that name a dataset but keep their rows when it is deleted."
  def retained_tables, do: Enum.sort(@retained)

  @doc "Every table with a `dataset_id` column, by how its rows leave."
  def dataset_id_tables do
    %{
      walked: Enum.sort(@walked),
      cascade_and_string: @cascade_and_string |> Map.keys() |> Enum.sort(),
      cascade: Enum.sort(@cascade),
      retained: ["api_tokens"],
      not_tenant: Enum.sort(@not_tenant)
    }
  end

  @doc "Tables whose writer may leave `dataset_id` NULL and that cannot be swept by string."
  def append_only_tables, do: @append_only

  @spec delete(Dataset.t()) ::
          {:ok,
           %{
             dataset: Dataset.t(),
             documents: non_neg_integer(),
             media_files: non_neg_integer(),
             swept: %{String.t() => pos_integer()},
             detached: %{String.t() => pos_integer()}
           }}
          | {:error, :production_dataset | :not_found | term()}
  def delete(dataset, opts \\ [])

  def delete(%Dataset{slug: @protected_slug}, _opts), do: {:error, :production_dataset}

  def delete(%Dataset{} = dataset, opts) do
    with %Project{} = project <- Repo.get(Project, dataset.project_id),
         %Workspace{} = workspace <- Repo.get(Workspace, project.workspace_id) do
      run(%{dataset: dataset, project: project, workspace: workspace, actor: opts})
    else
      nil -> {:error, :not_found}
    end
  end

  defp run(target) do
    Media.clear_deferred_media_effects()

    result =
      Broadcast.with_deferred_queue(fn ->
        Repo.transaction(fn ->
          case teardown(target) do
            {:ok, receipt} -> receipt
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, _} -> Media.flush_deferred_media_effects()
      _ -> Media.clear_deferred_media_effects()
    end

    WriteScope.reset_request_memo()
    result
  rescue
    e ->
      Media.clear_deferred_media_effects()
      reraise(e, __STACKTRACE__)
  end

  defp teardown(%{dataset: dataset} = target) do
    exclusive? = slug_exclusive_in_workspace?(target)
    detached = detach_foreign(target)
    exemptions = sweep_authoring_exemptions(dataset)

    with {:ok, media} <- delete_media(target),
         {:ok, documents} <- delete_documents(target),
         swept =
           target |> sweep_strings(exclusive?) |> Map.merge(sweep_fk_strings(target, exclusive?)),
         {:ok, deleted} <- Repo.delete(dataset, stale_error_field: :id),
         receipt = %{
           dataset: deleted,
           documents: documents,
           media_files: media,
           swept: drop_zero(Map.put(swept, "authoring_exemptions", exemptions)),
           detached: drop_zero(detached)
         },
         {:ok, _event} <- audit(target, receipt) do
      {:ok, receipt}
    else
      {:error, %Ecto.Changeset{data: %Dataset{}}} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp detach_foreign(%{dataset: ds, workspace: ws}) do
    for table <- OwnedTables.present(@detachable), workspace_column?(table), into: %{} do
      {n, _} =
        Repo.update_all(
          from(t in table,
            where:
              t.dataset_id == type(^ds.id, Ecto.UUID) and not is_nil(t.workspace_id) and
                t.workspace_id != type(^ws.id, Ecto.UUID)
          ),
          set: [dataset_id: nil]
        )

      {table, n}
    end
  end

  defp workspace_column?(table), do: table not in ~w(document_view_days document_popularity)

  defp sweep_fk_strings(%{dataset: ds, project: p, workspace: ws}, exclusive?) do
    for {table, column} <- @cascade_and_string, OwnedTables.present?(table), into: %{} do
      {table,
       delete_count(
         from(t in table,
           where:
             t.workspace_id == type(^ws.id, Ecto.UUID) and field(t, ^column) == ^ds.slug and
               (t.project_id == type(^p.id, Ecto.UUID) or (is_nil(t.project_id) and ^exclusive?))
         )
       )}
    end
  end

  defp audit(%{dataset: ds, project: p, workspace: ws, actor: actor}, receipt) do
    Audit.emit(%{
      category: "content_mutation",
      action: "dataset_deleted",
      subject: ds.id,
      actor_type: Keyword.get(actor, :actor_type),
      actor_id: Keyword.get(actor, :actor_id),
      workspace_id: ws.id,
      project_id: p.id,
      metadata: %{
        "dataset" => ds.slug,
        "project" => p.slug,
        "workspace" => ws.slug,
        "documents" => receipt.documents,
        "media_files" => receipt.media_files,
        "swept" => receipt.swept,
        "detached" => receipt.detached
      }
    })
  end

  defp slug_exclusive_in_workspace?(%{dataset: ds, workspace: ws}) do
    not Repo.exists?(
      from d in Dataset,
        join: p in Project,
        on: p.id == d.project_id,
        where: p.workspace_id == ^ws.id and d.slug == ^ds.slug and d.id != ^ds.id
    )
  end

  defp in_dataset(query, %{dataset: ds, project: p, workspace: ws}) do
    where(
      query,
      [x],
      x.dataset_id == ^ds.id or
        (is_nil(x.dataset_id) and x.dataset == ^ds.slug and x.workspace_id == ^ws.id and
           x.project_id == ^p.id)
    )
  end

  defp delete_media(%{workspace: ws} = target) do
    MediaFile
    |> in_dataset(target)
    |> select([m], m.id)
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn id, {:ok, n} ->
      case Media.delete_file(id, workspace_id: ws.id, where_used: :cascade) do
        {:ok, _} -> {:cont, {:ok, n + 1}}
        {:error, :not_found} -> {:cont, {:ok, n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp delete_documents(%{dataset: ds, project: p, workspace: ws} = target) do
    opts = [workspace_id: ws.id, project_id: p.id]

    Document
    |> in_dataset(target)
    |> select([d], {d.doc_id, d.type})
    |> Repo.all()
    |> Enum.map(fn {doc_id, type} -> {Content.published_id(doc_id), type} end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, 0}, fn {doc_id, type}, {:ok, n} ->
      case Content.delete_document(doc_id, type, ds.slug, opts) do
        {:ok, _} -> {:cont, {:ok, n + 1}}
        {:error, :not_found} -> {:cont, {:ok, n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp sweep_authoring_exemptions(%Dataset{id: id, slug: slug}) do
    if OwnedTables.present?("authoring_exemptions") do
      {n, _} =
        Repo.delete_all(
          from t in "authoring_exemptions",
            where:
              t.dataset == ^slug and
                fragment(
                  "EXISTS (SELECT 1 FROM documents d WHERE d.doc_id = ? AND d.dataset = ? AND d.dataset_id = ?)",
                  t.doc_id,
                  t.dataset,
                  type(^id, Ecto.UUID)
                ) and
                fragment(
                  "NOT EXISTS (SELECT 1 FROM documents d WHERE d.doc_id = ? AND d.dataset = ? AND d.dataset_id IS DISTINCT FROM ?)",
                  t.doc_id,
                  t.dataset,
                  type(^id, Ecto.UUID)
                )
        )

      n
    else
      0
    end
  end

  defp sweep_strings(%{dataset: ds, project: p, workspace: ws}, exclusive?) do
    project_keyed =
      for table <- OwnedTables.present(@project_keyed), into: %{} do
        {table,
         delete_count(
           from(t in table,
             where:
               t.workspace_id == type(^ws.id, Ecto.UUID) and t.dataset == ^ds.slug and
                 (t.project_id == type(^p.id, Ecto.UUID) or (is_nil(t.project_id) and ^exclusive?))
           )
         )}
      end

    workspace_keyed =
      for table <- OwnedTables.present(@workspace_keyed), exclusive?, into: %{} do
        {table,
         delete_count(
           from(t in table,
             where: t.workspace_id == type(^ws.id, Ecto.UUID) and t.dataset == ^ds.slug
           )
         )}
      end

    scope_keyed =
      for {table, prefix} <- @scope_keyed, OwnedTables.present?(table), exclusive?, into: %{} do
        scope = prefix <> ds.slug

        {table,
         delete_count(
           from(t in table,
             where: t.workspace_id == type(^ws.id, Ecto.UUID) and t.scope == ^scope
           )
         )}
      end

    shares =
      if OwnedTables.present?("shares") do
        %{
          "shares" =>
            delete_count(
              from(t in "shares",
                where:
                  t.workspace_slug == ^ws.slug and t.project_slug == ^p.slug and
                    t.dataset == ^ds.slug
              )
            )
        }
      else
        %{}
      end

    project_keyed |> Map.merge(workspace_keyed) |> Map.merge(scope_keyed) |> Map.merge(shares)
  end

  defp delete_count(query) do
    {n, _} = Repo.delete_all(query)
    n
  end

  defp drop_zero(counts), do: for({k, n} <- counts, n > 0, into: %{}, do: {k, n})
end

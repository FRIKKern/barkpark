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

  Another workspace's rows are never deleted. Workspace search rows used to be
  stamped with the Default project's dataset of the same slug, so before the
  cascade any row of another workspace that points at this dataset has its
  `dataset_id` set NULL (`detached` in the receipt).

  `@retained` tables name the dataset but stay: access trails and credential
  ledgers are evidence, not content. `api_tokens.dataset_id` is set NULL by its
  FK and the token keeps its `dataset` string binding. `@not_tenant` tables
  carry a `dataset_id` that is not a tenant row: a backup and a refresh queue
  that drains itself.

  A table without a `project_id` value is keyed on workspace + slug, and is
  swept only when no other project in the workspace has a dataset with the same
  slug. Otherwise its rows stay: an orphan is recoverable, deleting a sibling
  dataset's rows is not.

  Two refusals keep the delete from reaching past the dataset. A global
  (no-workspace) synonym, crystal, merge pattern or intel event is stamped with
  the Default project's dataset of its scope, and that stamp is what dedupes the
  shared layer (`*_null_ws_unique_idx`), so a dataset holding one is refused
  (`{:shared_search, counts}`) rather than cascading or unkeying it. Media that a
  document outside the dataset embeds by URL is refused
  (`{:media_referenced, files}`), the census `Media.WhereUsed` gives the media
  doors.

  Tokens bound to the dataset's slug are revoked when no other dataset of that
  slug is left in a workspace they reach, so a recreated name does not wake
  them (`tokens_revoked`).

  The `production` dataset is refused (`{:error, :production_dataset}`): every
  workspace is created with it and the flat routes fall back to it, so it is
  never a throwaway. Deleting all of a workspace is `delete_workspace/1`.

  The delete appends a `content_mutation` / `dataset_deleted` row to the
  workspace's audit chain, naming the revoked token ids; each revoke has its
  own `token_revoked` row on the same chain with the same actor. `opts[:actor]`
  is the `%ApiToken{}` that asked. Everything runs in one transaction. Media
  blob removal, webhook dispatch and the revoked tokens' socket teardown wait
  until it commits, the same way `delete_workspace/1` does it.

  The audit rows (one per document, the revokes, `dataset_deleted`) are
  buffered and appended as the transaction's last statement
  (`Audit.defer_emits/0`), so the workspace's audit-chain lock is held for that
  append and the commit. Emitted one by one, the first document's row took the
  lock and every write in the workspace waited for the whole delete
  (task-10608b4831a0e9b8). The transaction may run 30 minutes
  (`:dataset_delete_timeout_ms`); a timeout or database error rolls it back and
  answers `{:error, {:delete_failed, :timeout | :database}}`. The HTTP door runs
  it off the request: `Tenancy.DatasetDelete.Runs`.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Audit
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Content.Document
  alias Barkpark.Content.WriteScope
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.WhereUsed
  alias Barkpark.OwnedTables
  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Dataset, Membership, Project, Workspace}

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

  @shared_search ~w(search_synonyms search_intel_crystals search_intel_events
                     search_intel_merge_patterns)

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
             detached: %{String.t() => pos_integer()},
             tokens_revoked: non_neg_integer(),
             revoked_tokens: [ApiToken.t()]
           }}
          | {:error,
             :production_dataset
             | :not_found
             | {:shared_search, %{String.t() => pos_integer()}}
             | {:media_referenced, [map()]}
             | {:delete_failed, :timeout | :database}
             | term()}
  def delete(dataset, opts \\ [])

  def delete(%Dataset{slug: @protected_slug}, _opts), do: {:error, :production_dataset}

  def delete(%Dataset{} = dataset, opts) do
    with %Project{} = project <- Repo.get(Project, dataset.project_id),
         %Workspace{} = workspace <- Repo.get(Workspace, project.workspace_id) do
      run(%{
        dataset: dataset,
        project: project,
        workspace: workspace,
        actor: Keyword.get(opts, :actor)
      })
    else
      nil -> {:error, :not_found}
    end
  end

  defp run(target) do
    Media.clear_deferred_media_effects()
    audit_owner? = Audit.defer_emits() == :owner
    started = System.monotonic_time(:millisecond)

    try do
      result =
        Broadcast.with_deferred_queue(fn ->
          Repo.transaction(
            fn ->
              case teardown(target) do
                {:ok, receipt} ->
                  if audit_owner?, do: Audit.flush_deferred!()
                  receipt

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end,
            timeout: timeout_ms()
          )
        end)

      case result do
        {:ok, receipt} ->
          if audit_owner?, do: Audit.finish_deferred(:committed)
          Media.flush_deferred_media_effects()
          Enum.each(receipt.revoked_tokens, &Auth.broadcast_socket_teardown/1)

        _ ->
          Media.clear_deferred_media_effects()
      end

      result
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        Media.clear_deferred_media_effects()
        {:error, {:delete_failed, failure(e, System.monotonic_time(:millisecond) - started)}}

      e ->
        Media.clear_deferred_media_effects()
        reraise(e, __STACKTRACE__)
    after
      if audit_owner?, do: Audit.finish_deferred(:rolled_back)
      WriteScope.reset_request_memo()
    end
  end

  defp timeout_ms,
    do: Application.get_env(:barkpark, :dataset_delete_timeout_ms, :timer.minutes(30))

  defp failure(%Postgrex.Error{postgres: %{code: :query_canceled}}, _ms), do: :timeout
  defp failure(%DBConnection.ConnectionError{reason: :queue_timeout}, _ms), do: :timeout
  defp failure(_e, ms), do: if(ms >= timeout_ms(), do: :timeout, else: :database)

  defp teardown(%{dataset: dataset} = target) do
    exclusive? = slug_exclusive_in_workspace?(target)

    with :ok <- refuse_shared_search(target),
         :ok <- refuse_referenced_media(target),
         detached = detach_foreign(target),
         exemptions = sweep_authoring_exemptions(dataset),
         {:ok, media} <- delete_media(target),
         {:ok, documents} <- delete_documents(target),
         swept =
           target |> sweep_strings(exclusive?) |> Map.merge(sweep_fk_strings(target, exclusive?)),
         {:ok, revoked} <- revoke_bound_tokens(target),
         {:ok, deleted} <- Repo.delete(dataset, stale_error_field: :id),
         receipt = %{
           dataset: deleted,
           documents: documents,
           media_files: media,
           swept: drop_zero(Map.put(swept, "authoring_exemptions", exemptions)),
           detached: drop_zero(detached),
           tokens_revoked: length(revoked),
           revoked_tokens: revoked
         },
         {:ok, _event} <- audit(target, receipt) do
      {:ok, receipt}
    else
      {:error, %Ecto.Changeset{data: %Dataset{}}} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp refuse_shared_search(%{dataset: ds}) do
    held =
      for table <- OwnedTables.present(@shared_search), into: %{} do
        {table,
         Repo.aggregate(
           from(t in table,
             where: t.dataset_id == type(^ds.id, Ecto.UUID) and is_nil(t.workspace_id)
           ),
           :count
         )}
      end
      |> drop_zero()

    if held == %{}, do: :ok, else: {:error, {:shared_search, held}}
  end

  defp refuse_referenced_media(target) do
    leaving = Document |> in_dataset(target) |> select([d], d.id)

    referenced =
      MediaFile
      |> in_dataset(target)
      |> Repo.all()
      |> Enum.flat_map(fn file ->
        case WhereUsed.referrers_outside(file, leaving) do
          %{count: 0} ->
            []

          census ->
            [%{media_id: file.id, path: file.path, count: census.count, sample: census.sample}]
        end
      end)

    if referenced == [], do: :ok, else: {:error, {:media_referenced, referenced}}
  end

  defp revoke_bound_tokens(%{dataset: ds, workspace: ws, actor: actor}) do
    seated =
      from m in Membership,
        where: m.workspace_id == ^ws.id and m.principal_type == "api_token",
        select: m.principal_id

    from(t in ApiToken,
      where:
        t.dataset_bound and is_nil(t.revoked_at) and t.dataset == ^ds.slug and
          (t.dataset_id == ^ds.id or t.workspace_id == ^ws.id or t.id in subquery(seated))
    )
    |> Repo.all()
    |> Enum.reject(&slug_still_reachable?(&1, ds))
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, revoked} ->
      context = %{
        workspace_id: ws.id,
        metadata: %{"dataset_deleted" => ds.id, "dataset" => ds.slug},
        after_commit: true
      }

      case Auth.revoke_token(token, actor, context) do
        {:ok, token} -> {:cont, {:ok, [token | revoked]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp slug_still_reachable?(%ApiToken{} = token, %Dataset{} = ds) do
    seats =
      Repo.all(
        from m in Membership,
          where: m.principal_type == "api_token" and m.principal_id == ^token.id,
          select: m.workspace_id
      )

    workspaces = Enum.reject([token.workspace_id | seats], &is_nil/1)

    Repo.exists?(
      from d in Dataset,
        join: p in Project,
        on: p.id == d.project_id,
        where: d.slug == ^ds.slug and d.id != ^ds.id and p.workspace_id in ^workspaces
    )
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
      actor_type: if(actor, do: "api_token", else: "system"),
      actor_id: actor && to_string(actor.id),
      workspace_id: ws.id,
      project_id: p.id,
      metadata: %{
        "dataset" => ds.slug,
        "project" => p.slug,
        "workspace" => ws.slug,
        "documents" => receipt.documents,
        "media_files" => receipt.media_files,
        "swept" => receipt.swept,
        "detached" => receipt.detached,
        "tokens_revoked" => Enum.map(receipt.revoked_tokens, & &1.id)
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

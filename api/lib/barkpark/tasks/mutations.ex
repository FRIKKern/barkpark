defmodule Barkpark.Tasks.Mutations do
  @moduledoc false
  # Single-task content mutations that ride the same advisory-lock + CAS-on-rev
  # pattern: `labels` (relabel), `papers` and `sessions` (ref-list mutations).
  # Extracted from the `Barkpark.Tasks` facade, which delegates to these.
  # `update_paper_refs_by_id/4` and `update_session_refs_by_id/4` are thin
  # wrappers over the shared `update_ref_list_by_id/5` core — twins,
  # differing only in the content key + event kind.

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_relabeled "task.relabeled"
  @event_task_referenced "task.referenced"

  @doc """
  tt5: add/remove `content.labels` entries on a single task, advisory-lock +
  CAS-on-rev guarded, emitting a `task.relabeled` mutation_event. Union add
  (dedup-preserving) minus the remove set; idempotent. Returns `{:ok, doc}`,
  `{:error, :not_found}`, or `{:error, :stale_claim}`.
  """
  @spec relabel_by_id(binary(), [binary()], [binary()], binary() | nil) ::
          {:ok, Document.t()} | {:error, term()}
  def relabel_by_id(task_id, add, remove, caller_token_id \\ nil)
      when is_binary(task_id) and is_list(add) and is_list(remove) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = labels_of(doc.content)
            add = Enum.filter(add, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove, &is_binary/1))

            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "labels", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}

                ev =
                  insert_mutation_event!(
                    updated,
                    @event_task_relabeled,
                    observed_rev,
                    "api",
                    caller_stamp(caller_token_id)
                  )

                {:ok, updated, [task_broadcast(updated, @event_task_relabeled, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Phase A: add/remove `content.papers` entries (paper slugs) on a single task.
  Thin wrapper over `update_ref_list_by_id/5` — see its doc for the shared
  advisory-lock + CAS-on-rev + `task.referenced` mutation_event contract.
  """
  @spec update_paper_refs_by_id(binary(), [binary()], [binary()], binary() | nil) ::
          {:ok, Document.t()} | {:error, term()}
  def update_paper_refs_by_id(task_id, add_slugs, remove_slugs, caller_token_id \\ nil),
    do: update_ref_list_by_id(task_id, "papers", add_slugs, remove_slugs, caller_token_id)

  @doc """
  Task 5 (session-handoff): add/remove `content.sessions` entries (session
  doc-ids) on a single task. Thin wrapper over `update_ref_list_by_id/5` — see
  its doc for the shared advisory-lock + CAS-on-rev + `task.referenced`
  mutation_event contract. Sessions are referenced by slug string only; no FK.
  """
  @spec update_session_refs_by_id(binary(), [binary()], [binary()], binary() | nil) ::
          {:ok, Document.t()} | {:error, term()}
  def update_session_refs_by_id(task_id, add_ids, remove_ids, caller_token_id \\ nil),
    do: update_ref_list_by_id(task_id, "sessions", add_ids, remove_ids, caller_token_id)

  # Shared core for `update_paper_refs_by_id/4` and `update_session_refs_by_id/4`
  # (and any future ref-list field): add/remove entries in `content[field]` on a
  # single task, advisory-lock + CAS-on-rev guarded, emitting a
  # `task.referenced` mutation_event. Mirrors `relabel_by_id/3` — the only
  # difference is the content key (parameterized here as `field`) and the event
  # kind (`task.referenced` for every ref-list field, vs `task.relabeled` for
  # labels). Returns `{:ok, doc}`, `{:error, :not_found}`, or
  # `{:error, :stale_claim}`.
  @spec update_ref_list_by_id(binary(), binary(), [binary()], [binary()], binary() | nil) ::
          {:ok, Document.t()} | {:error, term()}
  defp update_ref_list_by_id(task_id, field, add_ids, remove_ids, caller_token_id)
       when is_binary(task_id) and is_binary(field) and is_list(add_ids) and
              is_list(remove_ids) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = refs_of(doc.content, field)
            add = Enum.filter(add_ids, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove_ids, &is_binary/1))

            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, field, next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}

                ev =
                  insert_mutation_event!(
                    updated,
                    @event_task_referenced,
                    observed_rev,
                    "api",
                    caller_stamp(caller_token_id)
                  )

                {:ok, updated,
                 [task_broadcast(updated, @event_task_referenced, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # content.labels is a free-form JSON array; content.papers / content.sessions
  # are slug/doc-id arrays. Defensive: coerce non-list / missing to [].
  defp labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  defp labels_of(_), do: []

  defp refs_of(content, field) do
    case Map.get(content, field) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end

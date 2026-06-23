defmodule Barkpark.Tasks.Close do
  @moduledoc false
  # Task close + the blocked→open cascade. Extracted from the Barkpark.Tasks
  # facade (which defdelegates close/3 here). Fencing-epoch CAS, the
  # already-terminal guard, and the dependent-unblock walk all live together so
  # the close contract is one cohesive unit.

  import Ecto.Query, only: [from: 2]
  import Barkpark.Tasks.Internal,
    only: [generate_rev: 0, insert_mutation_event!: 3, task_broadcast: 4, emit_broadcasts: 1]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edges

  @closed_lifecycle_statuses ~w(done cancelled blocked)
  @event_task_closed "task.closed"
  @event_task_mutated "task.mutated"

  def close(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    new_status = Keyword.get(opts, :lifecycle_status, "done")
    observed_rev_opt = Keyword.get(opts, :observed_rev)
    reason = Keyword.get(opts, :reason)

    cond do
      new_status not in @closed_lifecycle_statuses ->
        {:error, {:invalid_lifecycle, new_status}}

      true ->
        do_close_txn(task_id, worker_id, observed_epoch, observed_rev_opt, new_status, reason)
    end
  end

  defp do_close_txn(task_id, worker_id, observed_epoch, observed_rev_opt, new_status, reason) do
    result =
      Repo.transaction(fn ->
        # 1. Advisory lock — per-task. hashtext('task:' || doc_id) gives a
        #    deterministic int4 key; pg_advisory_xact_lock takes an int4 or
        #    bigint and auto-releases at COMMIT/ROLLBACK.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = observed_rev_opt || doc.rev

            # Already-terminal guard. Under the advisory lock, a serialized
            # 2nd+ caller reads the row AFTER the winner committed → sees
            # `lifecycle_status` already in a terminal state. Without this
            # the default-observed-rev path would let every caller "succeed"
            # in turn (CAS passes against the just-read rev). Treat the
            # already-terminal row as a lost race; the explicit-rev CAS
            # path below still wins/loses on rev when callers pass their
            # own observation.
            cond do
              observed_rev_opt == nil and
                  Map.get(doc.content, "lifecycle_status") in @closed_lifecycle_statuses ->
                {:error, :stale_claim}

              true ->
                with :ok <- check_fencing(doc, observed_epoch),
                     {:ok, updated} <-
                       apply_close_update(doc, worker_id, observed_rev, new_status, reason) do
                  ev = insert_mutation_event!(updated, @event_task_closed, observed_rev)
                  unblocked = cascade_unblock_dependents!(updated)

                  {:ok, updated,
                   [task_broadcast(updated, @event_task_closed, ev, observed_rev) | unblocked]}
                end
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

  # Fencing applies only to tasks that carry a claim lease. A task with NO claim
  # record has no lease to fence against, so it closes gracefully (`:ok`) — what
  # lets a never-claimed root/container task close via this same path. A task
  # WITH a claim ALWAYS requires the epoch to match (the dead-worker guard).
  defp check_fencing(%Document{content: content}, observed_epoch) do
    case content do
      %{"claim" => %{"epoch" => row_epoch}} when row_epoch == observed_epoch -> :ok
      %{"claim" => %{"epoch" => _}} -> {:error, :fenced_off}
      # No claim lease — nothing to fence against, close cleanly.
      _ -> :ok
    end
  end

  defp apply_close_update(%Document{} = doc, worker_id, observed_rev, new_status, reason) do
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    # Stamp close metadata into the claim lease when one exists (work-tasks).
    # A never-claimed root/container task has no claim — close it without
    # inventing one; we only flip lifecycle_status.
    new_content =
      case doc.content do
        %{"claim" => claim} when is_map(claim) ->
          updated_claim =
            claim
            |> Map.put("closed_by", worker_id)
            |> Map.put("closed_at", ts_iso)

          doc.content
          |> Map.put("lifecycle_status", new_status)
          |> Map.put("claim", updated_claim)

        _ ->
          Map.put(doc.content, "lifecycle_status", new_status)
      end

    # Dossier close rationale: one scalar write riding the close call. Blank
    # reasons never overwrite an existing value.
    new_content =
      case reason do
        r when is_binary(r) and r != "" -> Map.put(new_content, "close_reason", r)
        _ -> new_content
      end

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 -> {:ok, %{doc | content: new_content, rev: new_rev}}
      0 -> {:error, :stale_claim}
    end
  end

  # After a task flips to `done`, walk every inbound `blocks` edge and flip the
  # dependent's lifecycle_status "blocked"→"open" IFF every one of ITS blockers
  # is now `done`. Same advisory-lock-guarded transaction so two concurrent
  # closes can't double-flip the same dependent. Returns one broadcast bundle
  # per flipped dependent for the caller to announce after commit.
  defp cascade_unblock_dependents!(%Document{content: %{"lifecycle_status" => "done"}} = parent) do
    parent
    |> Map.fetch!(:id)
    |> Edges.dependents(kind: :blocks)
    |> Enum.flat_map(fn %Document{} = dep ->
      if all_blockers_done?(dep) and Map.get(dep.content, "lifecycle_status") == "blocked" do
        new_rev = generate_rev()
        new_content = Map.put(dep.content, "lifecycle_status", "open")

        {1, _} =
          from(d in Document, where: d.id == ^dep.id and d.rev == ^dep.rev)
          |> Repo.update_all(
            set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
          )

        unblocked = %{dep | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(unblocked, @event_task_mutated, dep.rev)
        [task_broadcast(unblocked, @event_task_mutated, ev, dep.rev)]
      else
        []
      end
    end)
  end

  defp cascade_unblock_dependents!(_non_done_parent), do: []

  defp all_blockers_done?(%Document{} = dep) do
    dep.id
    |> Edges.dependencies(kind: :blocks)
    |> Enum.all?(fn %Document{content: c} ->
      Map.get(c, "lifecycle_status") == "done"
    end)
  end
end

defmodule Barkpark.Tasks.Fence do
  @moduledoc false
  # rail-l4 — allow-and-fence. Mutating the WORLD of an `in_progress` task (a
  # blocker edge lands on it, it gets re-parented) must force its holder through
  # a resync WITHOUT ever blocking the mutating agent. The mutator is NEVER
  # rejected; instead the claimed task's `content.claim.epoch` is bumped by 1 in
  # the same transaction, so the holder's next epoch-carrying write (its
  # `close`) is `fenced_off` and it must re-sync (a same-worker re-claim =
  # RENEWAL — see `Barkpark.Tasks.Claim`).
  #
  # This is DELIBERATELY not "reject the mutator": a second agent filing a
  # blocker should never be blocked by whoever happens to hold the dependent.
  # Allow the write, fence the holder.
  #
  # This module owns the EDGE-ADD fence (`add_dep/3`, which `Tasks.add_dep/3`
  # now routes through). The MOVE fence is folded into `Tasks.Move`'s reparent
  # CAS write directly (one UPDATE, not a second one).

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      current_epoch: 1,
      insert_mutation_event!: 5,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edges

  @event_task_mutated "task.mutated"

  @doc """
  Add a `blocks` (or other) dependency edge `child → parent` AND, when the
  DEPENDENT (`child_uuid`) task is `in_progress`, fence its holder by bumping
  `content.claim.epoch` — all in one transaction. The edge-adder is never
  rejected: a failed fence (CAS lost, no live claim) just adds the edge.

  This is the fencing wrapper `Tasks.add_dep/3` delegates to; it preserves the
  `{:ok, %Edge{}}` / `{:error, %Ecto.Changeset{}}` contract of the bare
  `Edges.add_dep/3` so every existing caller is untouched.
  """
  @spec add_dep(binary(), binary(), atom() | String.t()) ::
          {:ok, Barkpark.Tasks.Edge.t()} | {:error, Ecto.Changeset.t()}
  def add_dep(child_uuid, parent_uuid, kind \\ :blocks) do
    result =
      Repo.transaction(fn ->
        # Advisory lock on the DEPENDENT — the task we may fence. Same key
        # (`task:<uuid>`) claim/close/sweep use, so the epoch bump serializes
        # with them per-task; edges on OTHER tasks pass through unimpeded.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{child_uuid}"])

        case Edges.add_dep(child_uuid, parent_uuid, kind) do
          {:ok, edge} ->
            bundle =
              fence_in_progress(child_uuid, %{
                "fenced" => "edge_added",
                "edge" => %{"from" => edge.from_id, "to" => edge.to_id}
              })

            {:ok, edge, bundle}

          {:error, %Ecto.Changeset{} = cs} ->
            # A failed INSERT (e.g. FK violation on a ghost id) leaves the
            # transaction aborted — returning the changeset as a plain value
            # would surface as {:error, :rollback} to the caller. Repo.rollback
            # carries it out explicitly, preserving the bare Edges.add_dep
            # contract ({:error, %Ecto.Changeset{}}).
            Repo.rollback(cs)
        end
      end)

    case result do
      {:ok, {:ok, edge, bundle}} ->
        :ok = emit_broadcasts(List.wrap(bundle))
        {:ok, edge}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  # Bump the epoch of an `in_progress` task (the fencing kick) under the caller's
  # already-held advisory lock + transaction. Returns a broadcast bundle to emit
  # AFTER commit, or `nil` when there was nothing to fence (not in_progress / no
  # claim lease) or the CAS lost. Only `content.claim.epoch` moves — the
  # work_digest, worker, ts_iso, resources are all left exactly as the holder
  # stamped them (a fence is not a re-claim; the brief the holder read is
  # unchanged, so its work_digest close-fence must still fire against a real
  # foreign brief edit, never against this bump).
  defp fence_in_progress(doc_uuid, fence_payload) do
    case Repo.get(Document, doc_uuid) do
      %Document{content: %{"lifecycle_status" => "in_progress", "claim" => claim} = content} = doc
      when is_map(claim) ->
        observed_rev = doc.rev
        new_rev = generate_rev()
        new_claim = Map.put(claim, "epoch", current_epoch(doc) + 1)
        new_content = Map.put(content, "claim", new_claim)

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
                @event_task_mutated,
                observed_rev,
                "api",
                fence_payload
              )

            task_broadcast(updated, @event_task_mutated, ev, observed_rev)

          0 ->
            nil
        end

      _ ->
        nil
    end
  end
end

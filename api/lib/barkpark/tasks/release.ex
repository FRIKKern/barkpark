defmodule Barkpark.Tasks.Release do
  @moduledoc false
  # Voluntary unclaim — the ON-DEMAND twin of `TtlSweeper`'s reap (which is
  # the timeout path; default lease TTL is 45 minutes — far too long to wait
  # when a holder simply wants to walk away). Same advisory-lock + CAS-on-rev
  # + durable mutation_event + post-commit broadcast shape as `Tasks.Close`.
  #
  # Semantics (mirrors the sweeper's write, with one deliberate divergence):
  #
  #   * HOLDER-ONLY: unlike `close/3` (which fences on epoch alone — the
  #     board guards holder identity in `restage_plan/4`), release checks the
  #     holder IN the primitive: a voluntary walk-away by anyone but the
  #     lease holder is `{:error, :not_holder}`, so the fence can never be
  #     epoch-guessed by a bystander.
  #   * epoch fence: `observed_epoch` must match `claim.epoch` or
  #     `{:error, :fenced_off}` — the same dead-lease guard close uses.
  #   * lifecycle flips `in_progress → "open"` (never "blocked" — the ready
  #     overlay re-derives from the real edges; a releasable task goes back
  #     to being claimable).
  #   * `claim.worker` clears, `claim.epoch` bumps by 1 (monotonic across
  #     release-then-reclaim, exactly like reap-then-reclaim), and the map
  #     gains `released_by`/`released_at` stamps for the dossier.
  #   * DIVERGENCE from the reap: `content.assignee` is CLEARED. A TTL reap
  #     severs only the lease (the assignment survives a crash); a VOLUNTARY
  #     release is the holder saying "not mine" — leaving the assignee would
  #     keep painting their name on the board card.
  #
  # Emits a `task.released` mutation_events row (previous_worker + epochs in
  # the document payload) and mirrors the PubSub broadcast post-commit.

  import Ecto.Query

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      insert_mutation_event!: 5,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_released "task.released"

  def release(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)

    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            with :ok <- check_in_progress(doc),
                 :ok <- check_holder(doc, worker_id),
                 :ok <- check_fencing(doc, observed_epoch),
                 {:ok, updated} <- apply_release_update(doc, worker_id) do
              ev =
                insert_mutation_event!(
                  updated,
                  @event_task_released,
                  doc.rev,
                  "api",
                  %{
                    "released" => %{
                      "previous_worker" => worker_id,
                      "released_epoch" => observed_epoch,
                      "new_epoch" => observed_epoch + 1
                    }
                  }
                )

              {:ok, updated, [task_broadcast(updated, @event_task_released, ev, doc.rev)]}
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

  # Only an in-flight task has a lease to release. An open/ready task is a
  # no-op target; a done/cancelled/blocked one must reopen through its own
  # (future) primitive, never through a lease walk-away.
  defp check_in_progress(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      "in_progress" -> :ok
      other -> {:error, {:not_in_progress, other}}
    end
  end

  defp check_holder(%Document{content: content}, worker_id) do
    case get_in(content, ["claim", "worker"]) do
      ^worker_id -> :ok
      _ -> {:error, :not_holder}
    end
  end

  defp check_fencing(%Document{content: content}, observed_epoch) do
    case content do
      %{"claim" => %{"epoch" => row_epoch}} when row_epoch == observed_epoch -> :ok
      _ -> {:error, :fenced_off}
    end
  end

  defp apply_release_update(%Document{} = doc, worker_id) do
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    claim = Map.get(doc.content, "claim") || %{}

    released_claim =
      claim
      |> Map.put("worker", nil)
      |> Map.put("epoch", (Map.get(claim, "epoch") || 0) + 1)
      |> Map.put("released_by", worker_id)
      |> Map.put("released_at", ts_iso)

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "open")
      |> Map.put("claim", released_claim)
      |> Map.delete("assignee")

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 -> {:ok, %Document{doc | content: new_content, rev: new_rev}}
      _ -> {:error, :stale_claim}
    end
  end
end

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

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 5,
      check_holder: 2,
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

  # check_holder/2 → Tasks.Internal (D7 extraction, expressive-agent-loops):
  # one holder-check definition shared with `Tasks.Stamp` (and future
  # holder-gated verbs). Semantics unchanged — imported above.

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
      # SAME ruling the TTL reap already applies (`TtlSweeper.apply_reap/1`):
      # the walked-away worker's resource fences die with the lease. The
      # overlap scan in `Tasks.Claim.check_resources_free/4` was never fooled
      # — it filters `lifecycle_status = 'in_progress'`, and this row is now
      # "open" — but LEAVING the key painted a stale "holds lib/x.ex" on an
      # OPEN, unowned task in every reader that renders the claim map (Studio's
      # claim panel, the TUI claim JSON, `bp task get -o json`). Release is the
      # on-demand twin of the reap; the twins must represent a dead fence the
      # same way, or `bp task get` disagrees with itself depending on WHICH
      # verb freed the lease.
      |> Map.delete("resources")

    # RULING (task-lifecycle-visibility wave, 2026-07-21): release ALWAYS
    # lands "open" — deliberately NOT a restore of the pre-claim status.
    # `claim.ex` snapshots no pre-claim lifecycle (a "blocked" label is
    # already gone the moment the task is claimed), and the TtlSweeper reap
    # twin makes the same unconditional landing. A true restore would
    # entangle both twins for a board column that was lost at claim time;
    # a released task goes back to being claimable, and claimable means
    # "open". Protected by "a blocked-born task … releases to open" in
    # release_test.exs — do not make this conditional.
    new_content =
      doc.content
      |> Map.put("lifecycle_status", "open")
      |> Map.put("claim", released_claim)
      |> Map.delete("assignee")

    # PDS-D451: the receipt is the STORED row. Measured before this change —
    # the reconstruction shipped the CLAIM's `updated_at`, byte-exact.
    case fenced_content_write(doc, doc.rev, new_content, new_rev) do
      {:ok, updated} -> {:ok, updated}
      :stale -> {:error, :stale_claim}
    end
  end
end

defmodule Barkpark.Tasks.Release do
  @moduledoc false
  # Voluntary unclaim — the ON-DEMAND twin of `TtlSweeper`'s reap (which is
  # the timeout path; default lease TTL is 45 minutes — far too long to wait
  # when a holder simply wants to walk away). Same advisory-lock + CAS-on-rev
  # + durable mutation_event + post-commit broadcast shape as `Tasks.Close`.
  #
  # Semantics (mirrors the sweeper's write, with one deliberate divergence):
  #
  #   * HOLDER-ONLY on a LIVE lease: unlike `close/3` (which fences on epoch
  #     alone — the board guards holder identity in `restage_plan/4`), release
  #     checks the holder IN the primitive: a voluntary walk-away by anyone but
  #     the lease holder is `{:error, :not_holder}`, so the fence can never be
  #     epoch-guessed by a bystander. The ONE exception is a STRANDED row
  #     (lifecycle `open` while `claim.worker` is still set — see
  #     `check_releasable/1`): there is no live lease to guard, so any caller
  #     may free it and `released_by` names the ACTOR.
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

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_released "task.released"

  def release(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)

    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_id)])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            with {:ok, mode} <- check_releasable(doc),
                 :ok <- check_holder_for_mode(mode, doc, worker_id),
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
                      # The STORED holder, not the actor. For a live lease the
                      # two are identical (holder-only). For a STRANDED row they
                      # differ, and that difference is the whole point: the
                      # ledger now records who was freed AND who freed them.
                      "previous_worker" => holder_of(doc) || worker_id,
                      "released_by" => worker_id,
                      "stranded_open" => mode == :stranded,
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

  # TWO releasable shapes (ledger/claim-deadlock, task-f07ead0c1f8025bb —
  # REMEDY (A) of the three the row named):
  #
  #   `:live`      — the classic in-flight lease. HOLDER-ONLY, unchanged.
  #   `:stranded`  — lifecycle `open` while `claim.worker` is still SET. This
  #                  state is REACHABLE and legal to produce: `Tasks.Stage`
  #                  legally moves `in_progress → open` (Transitions D7) and
  #                  DELIBERATELY never touches `content.claim` (stage.ex:
  #                  "do_stage never touches content.claim", which the
  #                  false-done reopen recipe depends on). Before this change
  #                  the resulting row was a DEADLOCK: `claim` refused it
  #                  `:not_ready` (foreign_claimed), `stamp` refused it
  #                  `not_in_progress:open`, and `release` refused it here with
  #                  the same token — three verbs, no exit. The only escape was
  #                  to re-claim under the DEAD holder's worker id, which made
  #                  `released_by` name them instead of the actor.
  #
  # WHY (A) AND NOT (B) "make the state unreachable": the ONLY known path to it
  # is `stage`, and stage's claim-blindness is a protected invariant, not a bug
  # (see the acceptance criterion "bp task stage must still leave content.claim
  # untouched"). Closing that door would trade this deadlock for a regression in
  # the reopen recipe. (C) — a real `expired_at` on every claim — stays
  # complementary and unshipped here: a lease TTL would eventually reap a LIVE
  # claim, not this one, because a stranded row is no longer `in_progress` and
  # the TtlSweeper only reaps `in_progress`.
  #
  # A stranded row is NOT holder-gated: nobody legitimately holds a lease on a
  # row the board already calls `open`, and requiring the dead holder's identity
  # is exactly the impersonation this fix exists to remove. The epoch fence
  # (`check_fencing/2`) still applies, so the caller must have READ the row.
  #
  # Everything else is unchanged: an `open` row with NO holder is still
  # `{:not_in_progress, "open"}` (a no-op target), and done/cancelled/blocked
  # still reopen through their own verbs, never through a lease walk-away.
  defp check_releasable(%Document{content: content}) do
    c = content || %{}

    case Map.get(c, "lifecycle_status") do
      "in_progress" ->
        {:ok, :live}

      "open" = other ->
        if holder_present?(c), do: {:ok, :stranded}, else: {:error, {:not_in_progress, other}}

      other ->
        {:error, {:not_in_progress, other}}
    end
  end

  defp check_holder_for_mode(:live, %Document{} = doc, worker_id),
    do: check_holder(doc, worker_id)

  defp check_holder_for_mode(:stranded, _doc, _worker_id), do: :ok

  defp holder_present?(content), do: not is_nil(holder_in(content))

  defp holder_of(%Document{content: content}), do: holder_in(content || %{})

  defp holder_in(content) do
    case get_in(content, ["claim", "worker"]) do
      worker when is_binary(worker) -> if String.trim(worker) == "", do: nil, else: worker
      _ -> nil
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

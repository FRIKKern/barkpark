defmodule Barkpark.Tasks.TtlSweeper do
  @moduledoc """
  W7a step 5 — Oban worker that reaps crashed-agent claims.

  This is THE consumer of the W7-04 fencing primitive: when a worker
  crashes mid-task (process dies, container OOMs, host vanishes) its
  claim sits on the row with `lifecycle_status = "in_progress"` and an
  ever-staler `content.claim.ts_iso`. Without this sweeper the task is
  **unreapable** — the ready-queue skips `in_progress` rows so no other
  worker ever sees it. This worker:

    1. SELECTs every `type='task'` document whose
       `content->>'lifecycle_status' = 'in_progress'` AND
       `(content->'claim'->>'ts_iso')::timestamptz < now() - <ttl>`.

       NULL-tolerance: missing `claim.ts_iso` is ALSO a candidate. An
       `in_progress` task without a `claim.ts_iso` is malformed — it
       should not exist (every `claim/2` stamps the field). Treating
       NULL as expired is the safe choice: a healthy worker re-stamps
       ts_iso, an absent ts_iso means nobody owns the lock anymore.

    2. For each candidate, in a dedicated `Repo.transaction` guarded by
       `pg_advisory_xact_lock(hashtext('task:' || doc_id))` (the SAME
       key `Tasks.close/3` uses, so a sweep and a close cannot
       interleave on the same task):

         a. Re-read the row inside the lock — the row's state under the
            lock is ground truth, the outer SELECT was advisory. If the
            row is no longer `in_progress` (a `close/3` won the race),
            or the ts_iso has been refreshed since (a healthy worker
            heartbeat), we skip (counts toward `skipped`).
         b. Bump `content.claim.epoch` by 1 — THIS IS THE FENCING KICK.
            Any subsequent write by the (presumed-dead) previous worker
            carries the old epoch and is rejected by
            `Tasks.close/3`'s `check_fencing/2` as `{:error, :fenced_off}`.
         c. Flip `lifecycle_status` back to `"open"` (NOT `"blocked"` —
            unblocking is a separate signal carried by inbound `blocks`
            edges; the row was previously claimable so it is claimable
            again).
         d. Clear `content.claim.worker` (set to nil) but KEEP the
            bumped epoch on the map. A worker re-claim via `claim/2`
            will read this as the existing-epoch baseline and bump it
            further — guaranteeing monotonicity across reap-then-reclaim
            (claimed epoch=N → sweep → epoch=N+1, worker nil → reclaim
            → epoch=N+2).
         e. CAS-guarded `Repo.update_all` on `rev` (matches the W7-04
            mutation pattern). On CAS failure, count toward `skipped`.

    3. Emit a `task.lease_expired` `mutation_events` row with the full
       reap payload (previous_rev, rev, previous_worker, expired_epoch,
       new_epoch). Same durable-then-ack pattern as `task.claimed` /
       `task.closed`.

    4. Return `{:ok, %{swept: N, skipped: M}}` from `perform/1`.
       Empty-DB sweep returns `{:ok, %{swept: 0, skipped: 0}}` — never
       raises on "nothing to do."

  ## Why the SELECT-then-lock pattern, not a single SELECT FOR UPDATE

  The naive approach is `SELECT … FOR UPDATE SKIP LOCKED` and then
  reap each locked row. We deliberately don't:

    * A single big txn holding row-locks on N expired tasks holds Repo
      pool resources for as long as the slowest emit-event takes —
      back-pressure on every other Tasks caller. The per-task txn
      releases its lock + connection in O(ms) per row.
    * The advisory key `hashtext('task:' || doc_id)` is the SAME key
      `Tasks.close/3` uses. Using SELECT FOR UPDATE on the row would
      mean a sweep and a close fight on the row-lock alone — fine in
      isolation, but if a future writer adds row-level operations on
      the same doc (workspace hooks, validation rules) they'd also
      contend. The advisory-lock key keeps "task lifecycle" a
      first-class serialization domain.

  ## Concurrency invariants (proven in TtlSweeperTest)

    * **Sweep vs close on the same task** — exactly one wins. If close
      wins, the sweep sees `lifecycle_status != "in_progress"` inside
      its lock and skips. If sweep wins, the close sees its epoch is
      stale and returns `{:error, :fenced_off}` (or `:stale_claim` if
      it lost the CAS race after the sweep's epoch+rev bump).
    * **Sweep vs sweep on the same task** — the second sweeper enters
      the advisory-lock queue, finds the row no longer expired, skips.
    * **`done` / `cancelled` tasks are never swept** — the SELECT
      filters `lifecycle_status = 'in_progress'`.

  Configuration: `Application.get_env(:barkpark, :task_lease_ttl_seconds, 300)`.
  Tests override this to make the sweep deterministic at zero-time.
  """

  use Oban.Worker, queue: :tasks_ttl, max_attempts: 3

  import Ecto.Query

  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Repo

  # The mutation_events.mutation kind for a TTL-expired claim. Routed
  # through the existing `mutation` text column — same channel as
  # task.claimed / task.closed / task.mutated, so the spine, webhooks,
  # and listen endpoint surface lease expiries with zero schema work.
  @event_task_lease_expired "task.lease_expired"

  @default_ttl_seconds 300

  @doc "The mutation_events kind this worker emits."
  @spec event_kind() :: String.t()
  def event_kind, do: @event_task_lease_expired

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job) do
    ttl_seconds = Application.get_env(:barkpark, :task_lease_ttl_seconds, @default_ttl_seconds)

    {:ok, sweep(ttl_seconds)}
  end

  @doc """
  Pure entry point — bypasses Oban.Job wrapping. Tests use this to
  drive the sweep deterministically (perform/1 with a synthetic
  `%Oban.Job{}` works too, but this is one fewer layer of indirection
  when asserting `%{swept: N, skipped: M}`).
  """
  @spec sweep(non_neg_integer()) :: %{swept: non_neg_integer(), skipped: non_neg_integer()}
  def sweep(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl_seconds, :second)

    candidates = expired_candidates(cutoff)

    Enum.reduce(candidates, %{swept: 0, skipped: 0}, fn %Document{id: doc_id}, acc ->
      case reap_one(doc_id, cutoff) do
        :swept -> %{acc | swept: acc.swept + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  # ─── Candidate selection ──────────────────────────────────────────────────

  # SELECT every task that LOOKS expired from the outside. The per-row
  # reap path re-validates under the advisory lock — the candidate set
  # is intentionally generous (a healthy worker might refresh ts_iso
  # in the millisecond between SELECT and lock acquisition; we'd skip
  # it then, no harm done).
  #
  # NULL-tolerance: `(content->'claim'->>'ts_iso')::timestamptz` returns
  # NULL when either key is absent. Using `IS NULL OR < cutoff` covers
  # both the malformed-row case (no claim map / no ts_iso) and the
  # normal expired case.
  defp expired_candidates(%DateTime{} = cutoff) do
    from(d in Document,
      where: d.type == "task",
      where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
      where:
        fragment(
          "((?->'claim'->>'ts_iso')::timestamptz IS NULL OR (?->'claim'->>'ts_iso')::timestamptz < ?)",
          d.content,
          d.content,
          ^cutoff
        ),
      select: %Document{id: d.id}
    )
    |> Repo.all()
  end

  # ─── Per-task reap (the locked, idempotent unit) ──────────────────────────

  defp reap_one(doc_id, %DateTime{} = cutoff) do
    result =
      Repo.transaction(fn ->
        # Per-task advisory lock — same key Tasks.close/3 uses. Auto-
        # releases at COMMIT/ROLLBACK. A concurrent close on the same
        # task waits here; a concurrent sweep on the same task waits
        # here; closes on DIFFERENT tasks pass through unimpeded.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{doc_id}"])

        case Repo.get(Document, doc_id) do
          nil ->
            # Row was deleted between SELECT and lock acquisition. Not
            # an error — count as skipped.
            :skipped

          %Document{} = doc ->
            cond do
              not still_expired?(doc, cutoff) ->
                # Another caller (a healthy worker heartbeat, a close
                # that committed, an earlier sweep in this same run)
                # changed the row out from under us. Skip.
                :skipped

              true ->
                apply_reap(doc)
            end
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, _} -> :skipped
    end
  end

  # Recheck under the lock: lifecycle_status must STILL be "in_progress"
  # AND ts_iso must STILL be < cutoff (or missing). This is the only
  # place that authoritatively decides "this claim is dead."
  defp still_expired?(%Document{content: content}, %DateTime{} = cutoff) do
    case Map.get(content, "lifecycle_status") do
      "in_progress" ->
        case get_in(content, ["claim", "ts_iso"]) do
          nil ->
            true

          iso when is_binary(iso) ->
            case DateTime.from_iso8601(iso) do
              {:ok, dt, _offset} -> DateTime.compare(dt, cutoff) == :lt
              _ -> true
            end

          _ ->
            true
        end

      _ ->
        false
    end
  end

  defp apply_reap(%Document{} = doc) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    old_claim = Map.get(doc.content, "claim") || %{}
    expired_epoch = current_epoch(doc)
    new_epoch = expired_epoch + 1
    previous_worker = Map.get(old_claim, "worker")
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    # Keep the claim map for audit (closed_by/closed_at history if it
    # was set), but bump epoch, clear worker, and stamp the reap time.
    new_claim =
      old_claim
      |> Map.put("worker", nil)
      |> Map.put("epoch", new_epoch)
      |> Map.put("ts_iso", ts_iso)
      |> Map.put("expired_at", ts_iso)
      |> Map.put("previous_worker", previous_worker)

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "open")
      |> Map.put("claim", new_claim)
      # Clear assignee — the row is claimable by anyone again. Matches
      # `Tasks.claim/2` which stamps `assignee` on claim; the inverse
      # on reap.
      |> Map.put("assignee", nil)

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 ->
        updated = %{doc | content: new_content, rev: new_rev}

        _ =
          insert_lease_expired_event!(
            updated,
            observed_rev,
            expired_epoch,
            new_epoch,
            previous_worker
          )

        :swept

      0 ->
        # CAS failed — extremely rare under the advisory lock (we held
        # the lock through the read + the write), but covered: another
        # caller updated the row through a non-task-lifecycle path
        # (workspace move? schema migration?). Skip — the sweep will
        # come back next minute.
        :skipped
    end
  end

  # ─── Event emission ───────────────────────────────────────────────────────

  defp insert_lease_expired_event!(
         %Document{} = doc,
         previous_rev,
         expired_epoch,
         new_epoch,
         previous_worker
       ) do
    payload = %{
      "previous_rev" => previous_rev,
      "rev" => doc.rev,
      "previous_worker" => previous_worker,
      "expired_epoch" => expired_epoch,
      "new_epoch" => new_epoch
    }

    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: @event_task_lease_expired,
      rev: doc.rev,
      previous_rev: previous_rev,
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev,
        "lease_expired" => payload
      },
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # ─── Local helpers (mirror Tasks module — kept private here to keep ───────
  # ─── TtlSweeper a single-file module the operator can audit in one read) ──

  defp current_epoch(%Document{content: %{"claim" => %{"epoch" => e}}}) when is_integer(e), do: e
  defp current_epoch(_), do: 0

  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

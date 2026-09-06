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
       `pg_advisory_xact_lock(hashtext('task:' || uuid))` —
       `Barkpark.Tasks.LockKey.task/1` on the candidate's UUID PRIMARY
       KEY, which is the SAME key `Tasks.close/3` uses, so a sweep and a
       close cannot interleave on the same task:

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
    * The advisory key `hashtext('task:' || uuid)` (`LockKey.task/1`) is
      the SAME key `Tasks.close/3` uses. The candidate queries select
      `%Document{id: …}`, so the value threaded into `reap_one/3` and
      `lapse_one/2` is the uuid PRIMARY KEY — it was once named `doc_id`
      in those clauses, which read as the SLUG family and was wrong. Using SELECT FOR UPDATE on the row would
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

  Configuration: `Application.get_env(:barkpark, :task_lease_ttl_seconds, 2700)`
  (config.exs default 2700 s / 45 min; runtime override via
  `BARKPARK_TASK_LEASE_TTL_SECONDS`). Tests override this to make the
  sweep deterministic at zero-time.

  ## Second sweep — engagement honesty (tlv-s6, charter D4)

  `perform/1` also runs `sweep_engagement/1`: the honesty lease for the
  THOUGHT states (`considering` / `researching`, TLV charter D1). A task
  stuck in `researching` because its cycle crashed is a lie — nothing
  else ever moves it. Same advisory-lock family (`task:<uuid>`), same
  select-candidates → recheck-under-lock → CAS-rev `update_all` pattern,
  and deliberately NO claim-epoch machinery: thought is not contended
  work, so there is nothing to fence.

  Lapse rules (the sweep never cancels — kills are a deliberate verb):

    * `researching` with a stale/absent `engagement.ts` → `considering`,
      engagement cleared. (Researching WITHOUT an engagement map is
      malformed — the stage verb always stamps one — and lapses too.)
    * `considering` with an engagement map whose ts is stale/absent →
      engagement cleared, stays `considering`. Unowned considering is
      the legible resting state, so a considering row with NO engagement
      map is NOT a candidate (otherwise the sweep would re-lapse it
      every minute forever).

  ### What the lapse may and may not eat (PDS wave 23)

  The lapse deletes EXACTLY ONE key by name — `content.engagement` — and that
  map is an EPHEMERAL ownership lease. A durable adjudication reason ("parked
  because X") belongs on `content.disposition_reason`, which no sweeper owns;
  `Tasks.Stage` routes `--note` there for exactly this reason. Measured on
  guerrilla before the split: a row staged at 20:02:00.455593 lost its
  `engagement.note` at 20:17:01.430503 (15m00.97 s) while the lifecycle flip it
  accompanied survived — a durable claim on a field with a 15-minute half-life.

  Rows written BEFORE the split still carry `engagement.note`, so `apply_lapse`
  PROMOTES a non-blank legacy note into `disposition_reason` on the way out
  (never overwriting a reason already there). After the promotion the lapse
  clears the lease as always.

  Each lapse emits an additive `task.engagement_lapsed` mutation event
  (payload mirrors `task.lease_expired` MINUS the epoch fields:
  previous_rev, rev, previous_holder, from_status, to_status, plus the
  cleared engagement object) and then the same post-commit PubSub
  broadcast as the reap.

  Configuration: `Application.get_env(:barkpark, :task_engagement_ttl_seconds, 900)`
  (config.exs default 900 s / 15 min — thought idles faster than the
  45-min work lease; runtime override via
  `BARKPARK_TASK_ENGAGEMENT_TTL_SECONDS`).

  ## PR lease extension — the one thing that stays a reap's hand

  MEASURED 2026-09-02: the 45-minute lease is SHORTER than the CI queue was
  (60-90 min, 390 runs queued at 04:15Z), so a PR that waited out the queue met
  the required `PR references an active task` gate with its own claim already
  reaped. The gate stays strict (ruled); the LEASE learned to be extendable.

  `Barkpark.Tasks.Renew` (`POST /v1/tasks/:doc_id/renew`) stamps
  `content.claim.lease_extension.until` — a bounded, self-expiring grace window
  a CI job buys on behalf of an OPEN pull request, WITHOUT touching the epoch,
  the worker, or `ts_iso`. This sweeper honours it in both places it decides
  anything: the candidate SELECT skips a row whose window is still open, and
  `lease_extended?/2` re-checks under the advisory lock, where the row is
  ground truth. An extended row counts as `skipped`, exactly like a healthy
  heartbeat — it is not a reap and not an error.

  **The window is the safety property, not the flag.** Nothing here asks
  GitHub anything. When the PR closes, merges, or is abandoned, nothing renews,
  `until` slides into the past, and the very next sweep reaps on the normal
  schedule. A merge/close may also clear the record outright for promptness,
  but the design does not depend on that message ever arriving — and
  `Tasks.Renew`'s cap means an unbroken chain of renewals still ends. See that
  module's moduledoc for the full decision and the rejected alternative.
  """

  use Oban.Worker, queue: :tasks_ttl, max_attempts: 3

  import Ecto.Query

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Internal

  # The mutation_events.mutation kind for a TTL-expired claim. Routed
  # through the existing `mutation` text column — same channel as
  # task.claimed / task.closed / task.mutated, so the spine, webhooks,
  # and listen endpoint surface lease expiries with zero schema work.
  @event_task_lease_expired "task.lease_expired"

  # tlv-s6 (charter D4): the additive event kind the engagement sweep emits.
  # Same mutation channel as task.lease_expired — spine/webhooks/listen get
  # it with zero schema work.
  @event_task_engagement_lapsed "task.engagement_lapsed"

  @default_ttl_seconds 2700
  @default_engagement_ttl_seconds 900

  # The two thought states the engagement sweep owns (TLV charter D1).
  @thought_states ~w(considering researching)

  @doc "The mutation_events kind the lease sweep emits."
  @spec event_kind() :: String.t()
  def event_kind, do: @event_task_lease_expired

  @doc "The mutation_events kind the engagement sweep emits."
  @spec engagement_event_kind() :: String.t()
  def engagement_event_kind, do: @event_task_engagement_lapsed

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job) do
    ttl_seconds = Application.get_env(:barkpark, :task_lease_ttl_seconds, @default_ttl_seconds)

    engagement_ttl_seconds =
      Application.get_env(
        :barkpark,
        :task_engagement_ttl_seconds,
        @default_engagement_ttl_seconds
      )

    # Both sweeps in the one per-minute job: the lease reap first (contended
    # work), then the engagement honesty lease (thought states). The result
    # map keeps the historical top-level {swept, skipped} for the lease sweep
    # and nests the second sweep under :engagement.
    {:ok, Map.put(sweep(ttl_seconds), :engagement, sweep_engagement(engagement_ttl_seconds))}
  end

  @doc """
  Pure entry point — bypasses Oban.Job wrapping. Tests use this to
  drive the sweep deterministically (perform/1 with a synthetic
  `%Oban.Job{}` works too, but this is one fewer layer of indirection
  when asserting `%{swept: N, skipped: M}`).
  """
  @spec sweep(non_neg_integer()) :: %{swept: non_neg_integer(), skipped: non_neg_integer()}
  def sweep(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    # ONE `now` for the whole sweep: the lease cutoff is `now - ttl`, but the
    # PR lease-extension window (see the section above) is compared against
    # `now` itself. Deriving both from the same instant keeps a sweep's two
    # questions answered on one clock.
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -ttl_seconds, :second)

    candidates = expired_candidates(cutoff, now)

    Enum.reduce(candidates, %{swept: 0, skipped: 0}, fn %Document{id: task_uuid}, acc ->
      case reap_one(task_uuid, cutoff, now) do
        :swept -> %{acc | swept: acc.swept + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  @doc """
  The engagement honesty sweep (tlv-s6, charter D4) — lapses THOUGHT
  states whose `engagement.ts` went stale. Pure entry point, same shape
  as `sweep/1`; `perform/1` runs both.
  """
  @spec sweep_engagement(non_neg_integer()) :: %{
          swept: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def sweep_engagement(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl_seconds, :second)

    candidates = engagement_candidates(cutoff)

    Enum.reduce(candidates, %{swept: 0, skipped: 0}, fn %Document{id: task_uuid}, acc ->
      case lapse_one(task_uuid, cutoff) do
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
  defp expired_candidates(%DateTime{} = cutoff, %DateTime{} = now) do
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
      # LEASE-EXTENSION-SQL — the PR grace window, pushed into the candidate
      # SELECT so an extended row is not even considered (still_expired?/3 is
      # the authority, this is the cheap arm). Absent key → NULL → a candidate,
      # exactly like the NULL-tolerance above: no extension means no grace.
      where:
        fragment(
          "((?->'claim'->'lease_extension'->>'until')::timestamptz IS NULL OR (?->'claim'->'lease_extension'->>'until')::timestamptz <= ?)",
          d.content,
          d.content,
          ^now
        ),
      select: %Document{id: d.id}
    )
    |> Repo.all()
  end

  # SELECT every thought-state task that LOOKS lapsed from the outside; the
  # per-row lapse path re-validates under the advisory lock (same generous-
  # candidate philosophy as expired_candidates/1).
  #
  # Asymmetry by design: `researching` is a candidate even WITHOUT an
  # engagement map (researching must carry its object — a bare row is
  # malformed and lapses to considering), while `considering` requires the
  # `engagement` key to be present — unowned considering is the legible
  # resting state, and re-lapsing it every minute would spam events forever.
  defp engagement_candidates(%DateTime{} = cutoff) do
    from(d in Document,
      where: d.type == "task",
      where: fragment("?->>'lifecycle_status'", d.content) in ^@thought_states,
      where:
        fragment("?->>'lifecycle_status'", d.content) == "researching" or
          fragment("? \\? 'engagement'", d.content),
      where:
        fragment(
          "((?->'engagement'->>'ts')::timestamptz IS NULL OR (?->'engagement'->>'ts')::timestamptz < ?)",
          d.content,
          d.content,
          ^cutoff
        ),
      select: %Document{id: d.id}
    )
    |> Repo.all()
  end

  # ─── Per-task reap (the locked, idempotent unit) ──────────────────────────

  defp reap_one(task_uuid, %DateTime{} = cutoff, %DateTime{} = now) do
    result =
      Repo.transaction(fn ->
        # Per-task advisory lock — same key Tasks.close/3 uses. Auto-
        # releases at COMMIT/ROLLBACK. A concurrent close on the same
        # task waits here; a concurrent sweep on the same task waits
        # here; closes on DIFFERENT tasks pass through unimpeded.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_uuid)])

        # global-read: in-lock by-PK re-read of a candidate row the sweeper's own cross-tenant scan selected — internal Oban worker, tenancy resolved by the candidate query, same posture as the lapse re-read below.
        case Repo.get(Document, task_uuid) do
          nil ->
            # Row was deleted between SELECT and lock acquisition. Not
            # an error — count as skipped.
            :skipped

          %Document{} = doc ->
            cond do
              lease_extended?(doc, now) ->
                # An OPEN pull request bought this claim grace (see the
                # "PR lease extension" section of the moduledoc). Not a reap,
                # not an error — the same `skipped` a healthy heartbeat earns.
                :skipped

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
      {:ok, {:swept, doc, event_id, previous_rev}} ->
        # Post-commit PubSub — same canonical topics/shape every document
        # write broadcasts (SSE listen endpoint + StudioLive parity). Fired
        # AFTER the reap transaction commits, never inside it.
        Barkpark.Content.broadcast_document_mutation(doc, @event_task_lease_expired,
          event_id: event_id,
          previous_rev: previous_rev
        )

        :swept

      {:ok, outcome} ->
        outcome

      {:error, _} ->
        :skipped
    end
  end

  # Recheck under the lock: lifecycle_status must STILL be "in_progress"
  # AND ts_iso must STILL be < cutoff (or missing). This is the only
  # place that authoritatively decides "this claim is dead."
  # LEASE-EXTENSION-GUARD — the authoritative, in-lock half of the PR grace
  # window. `until` in the FUTURE means an open PR is still paying for this
  # claim; anything else (absent, unparseable, elapsed) means no grace, so the
  # normal lease decides. Deliberately NOT keyed on the pr number or on any
  # GitHub state: the ledger cannot poll GitHub, and a window that must be
  # RE-BOUGHT is the only shape whose failure mode is "the row is released".
  defp lease_extended?(%Document{content: content}, %DateTime{} = now) do
    case get_in(content || %{}, ["claim", "lease_extension", "until"]) do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> DateTime.compare(dt, now) == :gt
          _ -> false
        end

      _ ->
        false
    end
  end

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
      # The dead worker's resource fences die with the lease: leaving them
      # on the map showed a stale "holds lib/x.ex" on an OPEN task (Studio's
      # claim panel, the TUI's claim JSON). Conflict scans were never
      # affected — they filter lifecycle in_progress — representation only.
      |> Map.delete("resources")

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "open")
      |> Map.put("claim", new_claim)

    # NOTE: `content.assignee` is deliberately PRESERVED. A TTL reap
    # releases the LEASE (the right to hold the row in_progress), not
    # the ASSIGNMENT (who this task belongs to). Clearing assignee on
    # reap wiped the board's ownership column every time an honest,
    # slow-running worker's lease lapsed — the task read as unowned
    # while work continued. The lease is `claim.worker` (now nil) +
    # `claim.epoch` (bumped, the fencing kick); assignment survives so
    # the same worker's re-claim lands back on its own task and the
    # board keeps showing who is on it.

    # PDS-D451 — the receipt is the STORED row. `updated` is broadcast by
    # `reap_one/2` post-commit, and `Content.Broadcast` copies `doc.updated_at`
    # into BOTH `doc.updated_at` AND `document._updatedAt` of the same message;
    # a `%{doc | …}` merge omitted `updated_at` and leaked the PREVIOUS write's
    # timestamp twice.
    case Internal.fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_lease_expired_event!(
            updated,
            observed_rev,
            expired_epoch,
            new_epoch,
            previous_worker
          )

        # Bundle for the post-commit broadcast in reap_one/2 — the event id
        # is required by the SSE listen controller's forward gate.
        {:swept, updated, ev.id, observed_rev}

      :stale ->
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

  # ─── Per-task engagement lapse (tlv-s6 — the locked, idempotent unit) ─────

  defp lapse_one(task_uuid, %DateTime{} = cutoff) do
    result =
      Repo.transaction(fn ->
        # Same advisory-lock family as the reap and Tasks.close/3 — a lapse
        # can never interleave with a close/claim/reap on the same task.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_uuid)])

        # global-read: in-lock by-PK re-read of a candidate row the sweeper's own cross-tenant scan selected — internal Oban worker, tenancy resolved by the candidate query, same posture as the reap re-read above.
        case Repo.get(Document, task_uuid) do
          nil ->
            :skipped

          %Document{} = doc ->
            if engagement_lapsed?(doc, cutoff), do: apply_lapse(doc), else: :skipped
        end
      end)

    case result do
      {:ok, {:swept, doc, event_id, previous_rev}} ->
        # Post-commit PubSub — exactly like the reap path.
        Barkpark.Content.broadcast_document_mutation(doc, @event_task_engagement_lapsed,
          event_id: event_id,
          previous_rev: previous_rev
        )

        :swept

      {:ok, outcome} ->
        outcome

      {:error, _} ->
        :skipped
    end
  end

  # Recheck under the lock: still a thought state, and (per the candidate
  # asymmetry) a considering row must still CARRY an engagement map to lapse.
  defp engagement_lapsed?(%Document{content: content}, %DateTime{} = cutoff) do
    status = Map.get(content, "lifecycle_status")
    engagement = Map.get(content, "engagement")

    cond do
      status not in @thought_states -> false
      status == "considering" and not is_map(engagement) -> false
      true -> stale_engagement_ts?(engagement, cutoff)
    end
  end

  # A missing map / missing ts / unparseable ts is stale (NULL-tolerance,
  # mirroring still_expired?/2): a healthy holder re-stamps ts, an absent ts
  # means nobody owns the thought anymore.
  defp stale_engagement_ts?(%{"ts" => iso}, %DateTime{} = cutoff) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.compare(dt, cutoff) == :lt
      _ -> true
    end
  end

  defp stale_engagement_ts?(_, _cutoff), do: true

  defp apply_lapse(%Document{} = doc) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    engagement = Map.get(doc.content, "engagement")
    from_status = Map.get(doc.content, "lifecycle_status")
    to_status = "considering"
    previous_holder = if is_map(engagement), do: Map.get(engagement, "holder")

    # Both rules land on the same write: lifecycle collapses to considering
    # (a no-op key-wise when it already was) and the engagement map is
    # CLEARED — deleted, not blanked, so the brief card's omit-when-absent
    # law reads the row as unowned. NO claim/epoch fields are touched.
    #
    # …but a legacy `engagement.note` (written before the durable/ephemeral
    # split) is PROMOTED to the durable key first, so the lapse releases the
    # lease without eating the adjudication that rode on it.
    new_content =
      doc.content
      |> promote_legacy_note(engagement)
      |> Map.put("lifecycle_status", to_status)
      |> Map.delete("engagement")

    # PDS-D451 — the receipt is the STORED row (see the reap arm above): the
    # lapse broadcast leaks the pre-write timestamp in BOTH `doc.updated_at`
    # and `document._updatedAt` when the struct is reconstructed.
    case Internal.fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_engagement_lapsed_event!(
            updated,
            observed_rev,
            previous_holder,
            from_status,
            to_status,
            engagement
          )

        {:swept, updated, ev.id, observed_rev}

      :stale ->
        # CAS failed under the lock — a non-task-lifecycle writer moved the
        # row. Skip; next minute's sweep re-evaluates.
        :skipped
    end
  end

  # Move a pre-split `engagement.note` onto the durable key the stage verb now
  # writes (`Tasks.Stage.durable_reason_key/0`). Deliberately conservative: only
  # a non-blank legacy note, and only when the row carries no durable reason
  # yet — a reason already adjudicated outranks a lease's leftover text.
  defp promote_legacy_note(content, engagement) when is_map(engagement) do
    key = Barkpark.Tasks.Stage.durable_reason_key()

    with note when is_binary(note) <- Map.get(engagement, "note"),
         false <- String.trim(note) == "",
         true <- blank_reason?(Map.get(content, key)) do
      Map.put(content, key, note)
    else
      _ -> content
    end
  end

  defp promote_legacy_note(content, _engagement), do: content

  defp blank_reason?(nil), do: true
  defp blank_reason?(reason) when is_binary(reason), do: String.trim(reason) == ""
  defp blank_reason?(_), do: false

  # Mirror of insert_lease_expired_event! MINUS the epoch fields (charter D4:
  # thought is not contended work — there is no fence to record).
  defp insert_engagement_lapsed_event!(
         %Document{} = doc,
         previous_rev,
         previous_holder,
         from_status,
         to_status,
         engagement
       ) do
    payload = %{
      "previous_rev" => previous_rev,
      "rev" => doc.rev,
      "previous_holder" => previous_holder,
      "from_status" => from_status,
      "to_status" => to_status,
      "engagement" => engagement
    }

    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: @event_task_engagement_lapsed,
      rev: doc.rev,
      previous_rev: previous_rev,
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev,
        "engagement_lapsed" => payload
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

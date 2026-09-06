defmodule Barkpark.Tasks.Pulse do
  @moduledoc false
  # `bp task pulse` — the now-line heartbeat that RENEWS the lease.
  #
  # Writes `content.claim.now = %{"text", "ts", "criterion"?}` (what the worker
  # is doing right now) AND renews the claim lease — epoch bump + `ts_iso`
  # refresh — in ONE atomic `Repo.update_all`. Never two writes: a board
  # reading between them would render a fresh now-line on a dead lease (or a
  # stale now-line on a fresh lease). Boards render staleness/decay from
  # `claim.now.ts` vs the lease TTL — a pulse past TTL must READ stale, never
  # lie fresh, which is why `ts` is stamped server-side, same instant as the
  # lease's `ts_iso`.
  #
  # Naming disambiguation — three "pulses" live in this repo, this is ONE:
  #   * bare `Barkpark.Pulse` is Shared Storm's presence substrate — NOT this;
  #   * the Go taskboard's `pulseMsg` is an SSE-keepalive tick — NOT this;
  #   * THIS module is the task-lease heartbeat behind
  #     `POST /v1/tasks/:doc_id/pulse` (`bp task pulse`).
  #
  # Write-path law (expressive-agent-loops charter D7): pulse is its OWN write
  # path — a `Claim.do_renew` sibling — NEVER a thin `claim_by_id` call.
  # `claim_by_id`'s fall-through silently RE-CLAIMS with a fresh `work_digest`
  # when the lease has lapsed (proven hazard): a crashed-and-reaped worker's
  # pulse would steal the row back and swallow any brief edit. A lost lease
  # (reaped / released / closed) must REFUSE with `{:error, :not_holder}`.
  #
  # Gates (charter D7): holder-gated via `Tasks.Internal.check_holder/2`, but
  # NO epoch fence — pulse IS the renewal, so it survives L4 fence bumps
  # exactly like `Claim.do_renew` (a pulse after a blocker edge landed still
  # renews; the fence's job is refusing the CLOSE, not the heartbeat).
  # `work_digest` + `work_field_digests` stay untouched so the L2 close-fence
  # still catches a brief edited under the claim.
  #
  # Lock family: advisory key `task:<uuid>` via `LockKey.task/1` — the
  # converged key. It was `task:<doc_id>` STRING until
  # task-eal-bl-lock-key-convergence, which meant a pulse and a close did NOT
  # exclude each other. Historical note (charter D6) — the
  # renewal family (claim / ttl_sweeper / compactor) — so a pulse serializes
  # with the TTL sweeper's reap of the same row. The key is the ROW's doc_id
  # (read before locking, re-read after), matching the sweeper's key exactly.
  #
  # Emits a `task.pulse` mutation_event in the SAME transaction (charter D8 —
  # the `/v1/tasks/events` feed projects it) and mirrors the PubSub broadcast
  # post-commit so live boards tick without polling.

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      current_epoch: 1,
      check_holder: 2,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_pulse "task.pulse"

  @doc "The mutation_events kind a pulse emits."
  def event_kind, do: @event_task_pulse

  @doc """
  Pulse the task's now-line + renew its lease, in one atomic write.

  `task_id` is the `documents.id` uuid (the controller resolves `doc_id` →
  row, same as close/release/move). Opts:

    * `:text` (required) — the now-line, e.g. `"warm-up pinned, rerunning"`.
    * `:criterion` — optional non-negative integer index into
      `acceptance_criteria`, naming which lock the worker is on.
    * `:caller_token_id` — audit stamp for the mutation_event.

  No `:observed_epoch` — pulse deliberately has no epoch fence (see moduledoc).

  Returns `{:ok, doc}`, or
  `{:error, :not_found | {:not_in_progress, status} | :not_holder | :stale_claim}`.
  `{:not_in_progress, status}` is every lost-lease shape that moved the ROW —
  reaped, released, closed, staged back to open — and it names the state it
  found. `:not_holder` is reserved for the HOLDER fault: a live `in_progress`
  claim owned by someone else.
  """
  def pulse(task_id, worker_id, opts \\ []) when is_binary(task_id) and is_binary(worker_id) do
    text = Keyword.fetch!(opts, :text)
    criterion = Keyword.get(opts, :criterion)
    caller_token_id = Keyword.get(opts, :caller_token_id)

    result =
      Repo.transaction(fn ->
        # Lock FIRST, then read. `task_id` IS the document's uuid PRIMARY KEY,
        # so the converged `task:<uuid>` key is available with no pre-lock
        # read at all — the read-for-the-key/re-read dance this used to do
        # existed only because the key was built from the `doc_id` SLUG, which
        # is a DIFFERENT lock from the one close/release/stage/sweeper take
        # (task-eal-bl-lock-key-convergence). The row state gated on below is
        # read under the lock, so a reap cannot commit between the read and
        # the write. Tenancy was resolved at the controller (doc_id ->
        # task.id); the holder check binds the caller to this exact row (same
        # accepted posture as Claim.do_renew and Close's re-read).
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_id)])

        # global-read: in-lock by-PK read — tenancy resolved at the controller (doc_id -> task.id), holder check below binds the caller to this row.
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            with :ok <- check_live(doc),
                 :ok <- check_holder(doc, worker_id) do
              apply_pulse(doc, worker_id, text, criterion, caller_token_id)
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

  # A pulse needs a LIVE lease. Anything not in_progress is a lost lease, and
  # the refusal NAMES the state it found: `{:error, {:not_in_progress, status}}`
  # (wire token `not_in_progress:<status>`, the shape `stamp` has always used).
  #
  # WHY IT IS NO LONGER THE BARE `:not_holder` (task-b6fcc8e2f57e1cd5). Charter
  # D7 pinned ONE token for every lost-lease shape, and that collapse is what
  # made a keep-alive loop unreadable: `:not_holder` is ALSO what a thief gets,
  # so the token could not tell the departed holder (whose remedy is
  # `bp task claim`) from an intruder (whose remedy is to back off). Measured
  # 2026-09-06: task-ee33b6f088b35bdb and task-8f9d3ea8926f387f both read
  # `lifecycle_status: "open"` with `claim.worker` STILL SET — the shape
  # `Tasks.Stage.do_stage/8` leaves behind, because stage writes
  # lifecycle_status + the engagement lease + the adjudication triple and never
  # `content.claim` (the TtlSweeper reap and `release` are the OTHER shape:
  # both clear `claim.worker` to nil). The state is the one fact the caller
  # cannot derive from a refusal, so the refusal carries it.
  #
  # The stale claim itself is NOT fixed here, deliberately. `stage` leaving
  # `content.claim` untouched is a documented property of that verb (the
  # false-done reopen recipe reopens a done row and KEEPS its claim on purpose),
  # and cross-reference pds-bl-null-expiry-claims-repo-wide: 6,850 of 8,617 open
  # rows already carry a claim object, median age 27 days. `claim.worker` is
  # therefore a RECEIPT, not a lease, repo-wide — so the honest remedy is to
  # stop letting the pulse's success signal imply the lease, which is what this
  # refusal does, rather than to chase every writer that leaves the receipt.
  #
  # The HOLDER fault keeps `:not_holder` (see `check_holder/2` below): a live
  # in_progress claim held by someone else is not a state problem, and the two
  # must stay distinguishable — that is the whole point of this split.
  defp check_live(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      "in_progress" -> :ok
      status -> {:error, {:not_in_progress, status || "unknown"}}
    end
  end

  # The one atomic write — mirrors `Claim.do_renew` (epoch bump + ts_iso
  # refresh, work_digest DELIBERATELY untouched) plus the now-line. `ts` on
  # the now-line is the SAME instant as the lease's `ts_iso`, so decay
  # rendering needs no clock reconciliation.
  defp apply_pulse(%Document{content: content} = doc, worker_id, text, criterion, caller_token_id) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    claim = Map.get(content, "claim") || %{}
    next_epoch = current_epoch(doc) + 1
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    now =
      %{"text" => text, "ts" => ts_iso}
      |> then(fn m ->
        if is_integer(criterion), do: Map.put(m, "criterion", criterion), else: m
      end)

    new_claim =
      claim
      |> Map.put("epoch", next_epoch)
      |> Map.put("ts_iso", ts_iso)
      |> Map.put("now", now)

    new_content = Map.put(content, "claim", new_claim)

    # PDS-D451: the receipt is the STORED row, not a reconstruction of intent.
    case fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_mutation_event!(
            updated,
            @event_task_pulse,
            observed_rev,
            "api",
            Map.merge(
              %{"pulse" => Map.merge(now, %{"worker" => worker_id, "epoch" => next_epoch})},
              caller_stamp(caller_token_id)
            )
          )

        {:ok, updated, [task_broadcast(updated, @event_task_pulse, ev, observed_rev)]}

      :stale ->
        {:error, :stale_claim}
    end
  end
end

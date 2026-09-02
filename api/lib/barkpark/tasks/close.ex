defmodule Barkpark.Tasks.Close do
  @moduledoc false
  # Task close + the blocked→open cascade. Extracted from the Barkpark.Tasks
  # facade (which defdelegates close/3 here). Fencing-epoch CAS, the
  # already-terminal guard, and the dependent-unblock walk all live together so
  # the close contract is one cohesive unit.
  #
  # THE CLOSE HONESTY GATES (PDS-D288/D289/D290) — READ THIS BEFORE CHANGING THEM.
  # Three checks ride the same in-lock `with` chain as the epoch fence:
  #
  #   * HOLDER — the closer must be (or have been) the lease holder. A foreign
  #     close is not refused outright forever: it is refused UNTIL the caller
  #     passes `:holder_override` with a reason, which is written into the doc as
  #     `close_override.holder` (actor + held_by + reason + ts). That shape is
  #     deliberate: 76 of 2,064 recorded closes are foreign and EVERY foreign
  #     closer is a LEAD sealing a merge-gated task, so a hard refusal would
  #     break the epic-cycle seal ritual. What changes is that the deliberate
  #     ones are now LOUD and the accidental ones stop.
  #   * CRITERIA — a `done` close over unmet acceptance criteria needs
  #     `:criteria_override` with a reason, recorded as `close_override.criteria`
  #     (actor + the unmet rows + reason + ts). `cancelled` and `blocked` are
  #     EXEMPT BY NAME — abandoning criteria is the point of cancelling. There is
  #     no third criterion state: this is accept-unmet-with-a-recorded-reason.
  #   * WORKER ID — sentinel ids (`""`, `None`, `null`, `nil`, `-`) are refused.
  #   * ACKNOWLEDGEMENT — a `done` or `cancelled` close of a row BORN from an
  #     outsider's GitHub issue (`gh-<num>`, see `Github.Acknowledgement`) needs
  #     its `ack_gate` criterion stamped met, or `:ack_override` with a reason,
  #     recorded as `close_override.acknowledgement`. Measured 2026-08-24: of the
  #     11 intaken issues, 8 carried no non-bot comment at all — the bridge's own
  #     birth backlink, up to 29 days old, was the only thing ever said to those
  #     reporters, while their bugs were fixed in this repo. The row that closed
  #     `done` over it (`gh-11555`) carried ZERO criteria, so the CRITERIA gate
  #     above was vacuously satisfied and could not see it.
  #     `blocked` is exempt BY NAME; `cancelled` deliberately is NOT — see
  #     `check_acknowledgement/3`.
  #   * CLOSE ARTIFACT (PDS-D291) — a `done` close of a `kind: "task"` row that
  #     carries ZERO acceptance criteria needs an ARTIFACT in its close_reason:
  #     a PR number (`#123`) together with a 7-40 hex sha, or a pasted run
  #     (a ``` fence, or a line starting with `$ `). Otherwise `:close_reason_override`
  #     with a reason, recorded as `close_override.close_reason`. This is the
  #     complement of the CRITERIA gate, not a duplicate of it: D289 measures
  #     criteria that EXIST, so on a row with none it is vacuously satisfied and
  #     a bare prose reason closed `done` unchallenged (LEAD3-jsweb measured 14
  #     of 15 closes in one lane on exactly that shape). Container rows are
  #     exempt BY NAME — `kind != "task"`, a `decision`/`goal` label segment, or
  #     a row that HAS children (TASK-SYSTEM.md §5 "Decisions and goals may omit
  #     them"; schema.ex: "a goal is a root task, a phase is a task with
  #     children") — as are `cancelled` and `blocked` closes.
  #
  # NONE OF THIS IS AUTHORIZATION. `worker_id` arrives as a client-supplied body
  # param (`tasks_controller.ex` close/2), never from the api_token, so a caller
  # who wants to close someone else's task can simply claim to be them. These
  # gates stop ACCIDENTS and make deliberate foreign/unproven closes AUDITABLE
  # for the first time; they are not an access-control boundary and must never
  # be described as one.

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 3,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      merge_criteria: 2,
      task_broadcast: 4,
      emit_broadcasts: 1,
      close_holder: 2,
      unmet_criteria: 1,
      check_worker_id: 1
    ]

  alias Barkpark.Content.{Document, DraftId, Scope}
  alias Barkpark.Plugins.Github.Acknowledgement
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edges
  alias Barkpark.Tasks.WorkDigest

  @closed_lifecycle_statuses ~w(done cancelled blocked)
  @event_task_closed "task.closed"
  # Merge-event reconcile emits a criterion-level event (same kind Stamp emits),
  # so the reconciliation shows up in the events feed without a lifecycle flip.
  @event_task_criterion "task.criterion"
  @event_task_mutated "task.mutated"
  # Advisory cross-task notice (task-obsession layer 4): a task closed with a
  # land digest whose files overlap another in-progress task's claimed scope.
  @event_landed_under_you "task.landed_under_you"

  def close(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    new_status = Keyword.get(opts, :lifecycle_status, "done")
    observed_rev_opt = Keyword.get(opts, :observed_rev)
    reason = Keyword.get(opts, :reason)
    criteria = Keyword.get(opts, :criteria, [])
    # Land digest (task-obsession layer 3): what this task actually changed —
    # `%{"prs" => [...], "files" => [...], "capability_slugs" => [...]}`. Written
    # to content.landed atomically with the close, so closed tasks become a
    # queryable ledger of touched surfaces (the CI re-land check reads it).
    landed = Keyword.get(opts, :landed)
    # Audit stamp: the api_token id that drove this close (nil for internal
    # callers), threaded into the task.closed mutation_event's document map.
    caller_token_id = Keyword.get(opts, :caller_token_id)
    # The two LOUD overrides (PDS-D288/D289). Each is a non-empty reason string;
    # absent (or blank) means "no override", and the corresponding gate refuses.
    overrides = %{
      holder: override_reason(Keyword.get(opts, :holder_override)),
      criteria: override_reason(Keyword.get(opts, :criteria_override)),
      # DELIBERATELY ITS OWN KEY. `criteria_override` must not discharge the
      # acknowledgement gate: those are two different admissions ("this work is
      # done though a criterion is unproven" vs "I am closing an outsider's bug
      # report without telling them"), and folding them would let the first
      # silently buy the second — which is how a reporter gets orphaned by a
      # close that looked fully accounted for.
      acknowledgement: override_reason(Keyword.get(opts, :ack_override)),
      # ALSO ITS OWN KEY, for the same reason `acknowledgement` is. The admission
      # here is "this row named no criteria AND I am naming no artifact, and it is
      # done anyway" — a different sentence from D289's "a criterion I can name is
      # unproven". Folding it into `criteria_override` would let the override that
      # gets reached for routinely buy the one that must not be routine, and on a
      # ZERO-criteria row `criteria_override` is a no-op today, so reusing it would
      # give an existing flag a second meaning that only bites where it currently
      # means nothing — the worst place to hide a new refusal.
      close_reason: override_reason(Keyword.get(opts, :close_reason_override))
    }

    cond do
      new_status not in @closed_lifecycle_statuses ->
        {:error, {:invalid_lifecycle, new_status}}

      # Sentinel worker ids die before the DB — a close attributed to "None" is
      # a missing value wearing a worker's clothes (PDS-D290).
      match?({:error, _}, check_worker_id(worker_id)) ->
        check_worker_id(worker_id)

      true ->
        do_close_txn(
          task_id,
          worker_id,
          observed_epoch,
          observed_rev_opt,
          new_status,
          reason,
          criteria,
          landed,
          caller_token_id,
          overrides
        )
    end
  end

  # A reason only overrides when it has words. `nil`, `""`, whitespace and
  # non-strings are NOT an override — an unexplained override is exactly the
  # silent foreign close this gate exists to end.
  defp override_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp override_reason(_), do: nil

  @doc """
  Merge-event bridge (ledger-merge-criterion-autostamp): auto-stamp a task's
  explicit `"merge_gate" => true` acceptance criterion when its PR merges, WITHOUT
  a human issuing the landed close. This is the initiator PR #3039 left missing —
  #3039 shipped the safe close-time autostamp seam (`autostamp_merge_gate/6`) but
  nothing fired it on a GitHub merge. This reuses the SAME marker semantics + the
  SAME `merge_criteria` rev-CAS write, so it is not a second mutation path.

  `task_id` is `documents.id` (a resolved UUID — the caller maps the PR's
  `Task: <doc_id>` trailer through `Content.get_document/4` first). `landed` names
  the merge artifact, `%{"prs" => [<number>], "commit" => <merge_sha>}`.

  Deliberately STAMP-ONLY — it never flips `lifecycle_status`. A close hides
  every other unmet criterion under a terminal lifecycle and (unlike a stamp)
  is fenced to the live claim epoch the merge event does not hold; leaving the
  lifecycle untouched preserves partial acceptance truth (a half-proven task
  reads as merge-gate-met but still `in_progress`, never fully done) and lets the
  lead keep close/3's judgment + claim/epoch semantics. The `merge_gate` marker
  itself is the authorization — the write can touch NOTHING else.

  Idempotent, named outcomes (never a silent no-op or double evidence):

    * `{:ok, :stamped, [index]}`   — one or more merge-gate criteria flipped met,
      evidence naming the PR, merge commit, and trigger source.
    * `{:ok, :already_stamped}`    — every merge-gate criterion is already met
      (a replayed/duplicate merge event, or a lead already closed). No write.
    * `{:ok, :no_marker}`          — the task carries NO `merge_gate:true`
      criterion. The absence is NAMED (loud), never a text/position fallback, so
      an unmarked legacy gate is detectable rather than silently guessed.
    * `{:ok, :no_guardable_marker}`— an unmet merge-gate criterion exists but has
      no wording to CAS against (D56). Left for a human, close is never faked.
    * `{:error, :unknown_task}`    — no document at `task_id`.
    * `{:error, :stale_rev}`       — lost a concurrent rev-CAS race; the caller
      may retry (the merge event is replay-safe via `:already_stamped`).
  """
  @spec reconcile_merge_gate(String.t(), map(), keyword()) ::
          {:ok, :stamped, [non_neg_integer()]}
          | {:ok, :already_stamped | :no_marker | :no_guardable_marker}
          | {:error, :unknown_task | :stale_rev | term()}
  def reconcile_merge_gate(task_id, landed, opts \\ [])
      when is_binary(task_id) and is_map(landed) do
    worker_id = Keyword.get(opts, :worker_id, "github-merge")
    ts_iso = Keyword.get(opts, :ts_iso) || DateTime.to_iso8601(DateTime.utc_now())

    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        # global-read: task-close by-PK — task_id IS the Document PK; tenancy is resolved by the caller's CAS claim (worker+epoch) inside this per-task advisory-locked txn, not a workspace_id thread (internal-worker posture).
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :unknown_task}

          %Document{} = doc ->
            reconcile_locked(doc, worker_id, landed, ts_iso)
        end
      end)

    case result do
      {:ok, {:ok, :stamped, indices, _updated, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, :stamped, indices}

      {:ok, other} ->
        other

      {:error, reason} ->
        {:error, reason}
    end
  end

  # In-lock reconciliation over the freshly-read doc. Classifies the merge-gate
  # criteria BEFORE writing so `:no_marker` (never marked) is distinguishable
  # from `:already_stamped` (marked + met) — criterion-4 named idempotency.
  defp reconcile_locked(%Document{} = doc, worker_id, landed, ts_iso) do
    gates =
      doc.content
      |> merge_gate_criteria_list()
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _i} -> is_map(entry) and Map.get(entry, "merge_gate") == true end)

    cond do
      gates == [] ->
        {:ok, :no_marker}

      Enum.all?(gates, fn {entry, _i} -> Map.get(entry, "met") == true end) ->
        {:ok, :already_stamped}

      true ->
        evidence = compose_reconcile_evidence(worker_id, landed, ts_iso)
        synthetic = merge_gate_synthetics(doc.content, evidence, MapSet.new())

        if synthetic == [] do
          # Unmet merge-gate criteria exist but none carry guardable text — the
          # D56 fail-closed guard has nothing to CAS against, so a human must
          # stamp them. Never faked through the hole.
          {:ok, :no_guardable_marker}
        else
          write_reconcile(doc, synthetic, worker_id, landed, ts_iso)
        end
    end
  end

  # The stamp write: fold the synthetic met-flips through the SHARED
  # `merge_criteria` rev-CAS (the same D56-guarded merge close uses) and update
  # ONLY the criteria + rev + the autostamp provenance record —
  # `lifecycle_status` is deliberately never touched. A durable `task.criterion`
  # mutation_event records the reconciliation.
  #
  # The provenance record rides this write for the SAME reason it rides the
  # close write (see `@autostamp_key`): a reader must be able to tell an
  # autostamped criterion from a hand-proven one WITHOUT parsing evidence prose.
  # This is the VERIFIED half — a real merge event was observed — so it lands
  # under "merge_event" with `verified: true`, next to (never on top of) any
  # earlier unverified close-time assertion.
  defp write_reconcile(%Document{} = doc, synthetic, worker_id, landed, ts_iso) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    indices = Enum.map(synthetic, &Map.get(&1, "index"))

    with {:ok, new_content} <- merge_criteria(doc.content, synthetic) do
      new_content =
        merge_autostamp_record(new_content, "merge_event", %{
          "verified" => true,
          "source" => "github_merge_event",
          "indices" => indices,
          "asserted_worker" => worker_id,
          "landed" => landed_summary(landed),
          "ts" => ts_iso
        })

      case fenced_content_write(doc, observed_rev, new_content, new_rev) do
        {:ok, updated} ->
          ev =
            insert_mutation_event!(
              updated,
              @event_task_criterion,
              observed_rev,
              "github-merge",
              %{"merge_reconcile" => %{"indices" => indices, "worker" => worker_id}}
            )

          {:ok, :stamped, indices, updated,
           [task_broadcast(updated, @event_task_criterion, ev, observed_rev)]}

        :stale ->
          {:error, :stale_rev}
      end
    end
  end

  # Reconcile evidence names the PR, the merge commit, and the trigger source
  # (`worker_id`, e.g. "github-merge") — no live claim, so no epoch to cite.
  defp compose_reconcile_evidence(worker_id, landed, ts_iso) do
    "auto: merge-reconciled by #{worker_id} — landed #{landed_summary(landed)} at #{ts_iso}"
  end

  # Repo.get/2 with the binary_id cast taken FIRST: a non-UUID task_id is a miss,
  # never a raise. See the cast-guard note in do_close_txn.
  #
  # THE JUSTIFICATION TRAVELS WITH THE READ, not with its old address. Extracting
  # this helper moved the `Repo.get` out from under the `# global-read:` comment
  # that licensed it and left the comment behind on the call site — the read did
  # not change, but its licence stopped covering it, and tenant-scope-check named
  # exactly that. A justification anchored to a LOCATION rather than to the
  # statement it justifies is one refactor away from being false.
  defp fetch_task(task_id) when is_binary(task_id) do
    case Ecto.UUID.cast(task_id) do
      # global-read: task-close by-PK — task_id IS the Document PK; tenancy is resolved by the caller's CAS claim (worker+epoch) inside the per-task advisory-locked txn in do_close_txn, not a workspace_id thread (internal-worker posture).
      {:ok, uuid} -> Repo.get(Document, uuid)
      :error -> nil
    end
  end

  defp fetch_task(_), do: nil

  defp do_close_txn(
         task_id,
         worker_id,
         observed_epoch,
         observed_rev_opt,
         new_status,
         reason,
         criteria,
         landed,
         caller_token_id,
         overrides
       ) do
    result =
      Repo.transaction(fn ->
        # 1. Advisory lock — per-task. hashtext('task:' || doc_id) gives a
        #    deterministic int4 key; pg_advisory_xact_lock takes an int4 or
        #    bigint and auto-releases at COMMIT/ROLLBACK.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        # global-read: task-close by-PK — task_id IS the Document PK; tenancy is resolved by the caller's CAS claim (worker+epoch) inside this per-task advisory-locked txn, not a workspace_id thread (internal-worker posture).
        #
        # THE CAST GUARD (cch-w39-bl). `Document`'s PK is a `:binary_id`, so a
        # task_id that is not a UUID does not MISS — it raises
        # `Ecto.Query.CastError` from inside the transaction, which surfaces as a
        # 500 rather than a refusal. A cancel aimed at an id that cannot exist
        # must FAIL LOUDLY AND LEGIBLY, and "loudly" means the caller is told
        # `not_found`, not handed a stacktrace: an operator reading a 500 goes
        # looking for an outage, while `not_found` sends them to re-read the id
        # they typed. Same shape as `Repo`'s uuid-guarded fetch elsewhere in this
        # tree. A malformed id and an absent id are the SAME fact here — there is
        # no document — and both must reach the same refusal.
        case fetch_task(task_id) do
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
                # The honesty gates sit HERE, on the `doc` read at the top of
                # this txn under the per-task advisory lock — the only place
                # where the PRE-close state is visible, the read is serialized,
                # and a refusal aborts before any content is written. Anywhere
                # downstream of `merge_criteria` (which runs inside
                # `apply_close_update`'s single rev-CAS write) is decorative by
                # construction: a closer that flips its own criteria in the
                # closing command would gate against its own claim.
                with :ok <- check_fencing(doc, observed_epoch),
                     {:ok, holder_record} <- check_close_holder(doc, worker_id, overrides.holder),
                     # The work-digest fence stays AHEAD of the criteria gate:
                     # if the brief itself moved under the claim, "your criteria
                     # are unmet" is the wrong thing to say — re-read first.
                     :ok <- check_work_digest(doc, observed_rev_opt),
                     :ok <- check_criteria_payload(doc, criteria),
                     # AHEAD of the criteria gate, and a test caught why. The
                     # acknowledgement criterion IS an acceptance criterion, so
                     # with the order reversed D289 fires first and the caller
                     # hears `criteria_unmet: [0]` — a message that says nothing
                     # about a waiting reporter and points at
                     # `criteria_override`, the ONE override that must never
                     # discharge this. The refusal a caller actually sees has to
                     # be the one that teaches; running first is what makes it so.
                     {:ok, ack_record} <-
                       check_acknowledgement(doc, new_status, overrides.acknowledgement),
                     {:ok, criteria_record} <-
                       check_criteria_proven(
                         doc,
                         new_status,
                         landed,
                         overrides.criteria,
                         overrides.acknowledgement
                       ),
                     # LAST of the honesty gates on purpose. It fires ONLY on a
                     # row D289 cannot see (zero criteria), so its order relative
                     # to D289 is immaterial for correctness — but a caller whose
                     # row DOES carry criteria must hear the specific
                     # `criteria_unmet` refusal, never this one, and running last
                     # makes that true by construction.
                     {:ok, artifact_record} <-
                       check_close_artifact(
                         doc,
                         new_status,
                         reason,
                         landed,
                         overrides.close_reason
                       ),
                     {:ok, updated} <-
                       apply_close_update(
                         doc,
                         worker_id,
                         observed_rev,
                         new_status,
                         reason,
                         criteria,
                         landed,
                         compose_override_record(
                           holder_record,
                           criteria_record,
                           ack_record,
                           artifact_record,
                           worker_id
                         ),
                         caller_token_id
                       ) do
                  ev =
                    insert_mutation_event!(
                      updated,
                      @event_task_closed,
                      observed_rev,
                      "api",
                      caller_stamp(caller_token_id)
                    )

                  unblocked = cascade_unblock_dependents!(updated)
                  landed = notify_landed_under_you!(updated, worker_id)

                  {:ok, updated,
                   [
                     task_broadcast(updated, @event_task_closed, ev, observed_rev)
                     | unblocked ++ landed
                   ]}
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

  # HOLDER GATE (PDS-D288). `check_fencing/2` above proves the caller observed
  # the CURRENT epoch; it never once compares WHO is closing, so worker-B closing
  # worker-A's task on A's epoch has always been `{:ok, doc}` with
  # `claim.worker = "worker-A", claim.closed_by = "worker-B"` — a ledger row that
  # reads like A finished the work. `Internal.close_holder/2` carries the three
  # allow-arms (unclaimed / holder / self-resume). A foreign close is refused
  # UNLESS the caller passes an explicit reason, in which case it succeeds and
  # the reason + both identities are written into the close. Refusal is the
  # DEFAULT, the override is the escape hatch — never the other way round.
  defp check_close_holder(%Document{} = doc, worker_id, override_reason) do
    case close_holder(doc, worker_id) do
      {:ok, _arm} ->
        {:ok, nil}

      {:error, {:not_holder, held}} when is_nil(override_reason) ->
        {:error, {:not_holder, held}}

      {:error, {:not_holder, held}} ->
        {:ok, %{"held_by" => held, "reason" => override_reason}}
    end
  end

  # A malformed criteria payload keeps its OWN error, ahead of the unmet gate.
  # `merge_criteria/2` is pure over the content map, so running it here as a
  # dry-run costs one map walk and buys precedence: a caller whose index is out
  # of range, whose text guard is stale, or whose met-flip carries no text hears
  # about THAT (`:criteria_index_out_of_range` / `:criteria_mismatch` /
  # `:criterion_text_required`) rather than a confusing "criteria unmet". The
  # real write still runs the same merge inside `apply_close_update/8` — this
  # discards its result and only propagates the error.
  defp check_criteria_payload(_doc, []), do: :ok

  defp check_criteria_payload(%Document{content: content}, criteria) do
    case merge_criteria(content, criteria) do
      {:ok, _dry_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # CRITERIA GATE (PDS-D289). Scoped to `done` ONLY: `cancelled` and `blocked`
  # are exempt BY NAME below — abandoning acceptance criteria is precisely what
  # cancelling a task MEANS, and a blocked close is an honest partial. Unmet is
  # measured on the doc AS READ, so the closing command's own criteria payload
  # cannot satisfy the gate it is being measured against.
  #
  # ONE deduction: criteria the merge-gate auto-stamp is about to prove ON ITS
  # OWN AUTHORITY (an explicit `"merge_gate" => true` marker plus a land digest
  # riding this close — `autostamp_merge_gate/6`) are not counted. Those are not
  # a closer asserting its own proof; the marker + the merge artifact ARE the
  # proof, and counting them would refuse every lead seal close and re-break the
  # exact ritual D288 protects.
  defp check_criteria_proven(%Document{} = doc, "done", landed, override_reason, ack_override) do
    case unmet_after_autostamp(doc, landed, ack_override) do
      [] ->
        {:ok, nil}

      unmet when is_nil(override_reason) ->
        {:error, {:criteria_unmet, Enum.map(unmet, &Map.get(&1, "index"))}}

      unmet ->
        {:ok, %{"unmet" => unmet, "reason" => override_reason}}
    end
  end

  # Exempt BY NAME — not by falling through a catch-all.
  defp check_criteria_proven(%Document{}, status, _landed, _override, _ack_override)
       when status in ~w(cancelled blocked),
       do: {:ok, nil}

  # ACKNOWLEDGEMENT GATE — the reporter loop.
  #
  # A `gh-<num>` row is not an internal task. It exists because somebody OUTSIDE
  # this ledger filed a bug, and the only surface they can see is their GitHub
  # issue, where the bridge's birth backlink promised them updates. Closing that
  # row is the moment the promise comes due.
  #
  # MEASURED 2026-08-24, which is why this refuses rather than warns: 11 issues
  # had been intaken; 8 carried no non-bot comment at all, and 5 of those were
  # still OPEN — the bridge's own backlink, oldest 29 days old, was everything
  # those reporters ever heard, while the defects they reported had been fixed
  # here. The platform's existing answer to the shape of that gap is
  # `Plugins.Tasks.warn_if_create_zero/1`, a soft `Logger.warning` on a
  # zero-criteria task; it fired on 9 of those 11 births and changed nothing,
  # because its only reader is the server journal. A second warning would have
  # been the same instrument aimed at the same blind spot. So this REFUSES — in the exact
  # PDS-D288/D289 idiom, which means "refuse UNLESS you say why on the record",
  # not a wall: `--set ack_override="<reason>"` always lands.
  #
  # `blocked` is exempt BY NAME (the same honest-partial reasoning as the criteria
  # gate: work continues, so the reporter's answer is not yet due).
  # `cancelled` is deliberately NOT exempt, and that DIVERGES from the criteria
  # gate above on purpose: abandoning acceptance criteria is what cancelling
  # MEANS, but "we are not going to do this" is the single message an outsider
  # most needs and is least likely to ever receive. A cancel is the case where
  # silence is worst, so it is the last place to hand out an exemption.
  #
  # THIS IS NOT AUTHORIZATION, and it is not proof the comment was posted — the
  # stamp is a self-report like every other criterion. It makes the obligation
  # impossible to close over UNKNOWINGLY, and every deliberate skip auditable.
  defp check_acknowledgement(%Document{} = doc, status, override_reason)
       when status in ~w(done cancelled) do
    content = doc.content || %{}

    cond do
      not Acknowledgement.intake_born?(doc.doc_id, content) ->
        {:ok, nil}

      Acknowledgement.acknowledged?(content) ->
        {:ok, nil}

      is_nil(override_reason) ->
        {:error, {:acknowledgement_unposted, Acknowledgement.issue_number(content)}}

      true ->
        {:ok,
         %{
           "issue" => Acknowledgement.issue_number(content),
           "had_criterion" => Acknowledgement.has_criterion?(content),
           "reason" => override_reason
         }}
    end
  end

  # `blocked` — exempt BY NAME, like the criteria gate. Every other lifecycle is
  # unreachable here (`close/3` refuses anything outside the three terminal
  # statuses before the txn opens), so this clause is the blocked arm and not a
  # catch-all standing in for one.
  defp check_acknowledgement(%Document{}, _status, _override), do: {:ok, nil}

  # ─── CLOSE ARTIFACT GATE (PDS-D291) — the hole D289 cannot see ───────────
  #
  # D289 above measures the criteria a row HAS. On a row with NONE it is
  # vacuously satisfied: `unmet_criteria/1` returns `[]`, the gate answers
  # `{:ok, nil}`, and a `done` close lands on whatever prose the closer typed.
  # That is not a corner: LEAD3-jsweb measured 14 of 15 closes in one lane
  # sitting on zero-criteria rows, and the `gh-11555` close the acknowledgement
  # gate above was built for went through the same hole ("carried ZERO criteria,
  # so the CRITERIA gate was vacuously satisfied and could not see it").
  #
  # Main's ruling on task-ce0c0ffff6edde23 (2026-09-02) is the law this
  # implements, verbatim: "a row with ZERO acceptance criteria may close done
  # only when its close_reason names the merged PR number + sha (or the run
  # output) that discharged its title; if no such artifact exists it is NOT
  # done — add criteria or cancel with the reason. A merge condition written
  # only in prose does not bind."
  #
  # WHAT COUNTS AS AN ARTIFACT (`close_artifact?/2`): a PR number (`#123`) AND a
  # 7-40 hex sha, in either order, anywhere in the reason; or a pasted run — a
  # ``` fence or a line beginning `$ `. Both name something a reader can go
  # LOOK AT. A `landed` digest that carries both a PR and a commit counts too:
  # it is the STRUCTURED form of the very same two facts, and refusing it would
  # force the lead seal ritual to retype machine-readable values into prose.
  #
  # EXEMPT BY NAME, never by falling through:
  #   * `cancelled` / `blocked` — same reasoning as D289; abandoning the work is
  #     what cancelling MEANS, and the ruling itself offers "cancel with the
  #     reason" as the honest exit.
  #   * `kind != "task"` — the ruling is scoped to task rows.
  #   * a `decision` or `goal` label segment — TASK-SYSTEM.md §5: "Real work
  #     tasks carry acceptance_criteria … Decisions and goals may omit them."
  #   * a row that HAS children. This is NOT an invented rule: the board decides
  #     goal-ness by `parent_id` (Board.facets/1 reads `card.parent_id`; the
  #     `:goal` swimlane groups on it), and `Tasks.Schema`'s own sentence is "a
  #     goal is a root task, a phase is a task with children". A row somebody
  #     else names as parent is a container in exactly that vocabulary, and its
  #     artifacts live on its children, not in its own close_reason.
  #
  # Like every gate above this is REFUSE-UNLESS-YOU-SAY-WHY, not a wall:
  # `--set close_reason_override="<why>"` always lands, on the record.
  defp check_close_artifact(%Document{} = doc, "done", reason, landed, override_reason) do
    cond do
      close_artifact_exempt?(doc) -> {:ok, nil}
      close_artifact?(reason, landed) -> {:ok, nil}
      is_nil(override_reason) -> {:error, :close_reason_needs_artifact}
      true -> {:ok, %{"reason" => override_reason, "close_reason" => reason}}
    end
  end

  # Exempt BY NAME — `cancelled` and `blocked`, the same two D289 exempts.
  defp check_close_artifact(%Document{}, status, _reason, _landed, _override)
       when status in ~w(cancelled blocked),
       do: {:ok, nil}

  # The container exemptions, plus the precondition: a row that HAS acceptance
  # criteria is D289's business, never this gate's.
  defp close_artifact_exempt?(%Document{content: content} = doc) do
    content = content || %{}

    has_criteria?(content) or not task_kind?(content) or container_label?(content) or
      has_children?(doc)
  end

  defp has_criteria?(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) -> list != []
      _ -> false
    end
  end

  # `Validation.kinds/0` is `~w(task)` — "task" is the ONLY kind a validated row
  # can carry, so an ABSENT `kind` is a task ("Everything is a task", schema.ex),
  # not an exemption. Reading a missing key as exempt would make this gate
  # vacuous over every legacy row, which is the population it exists for.
  defp task_kind?(content) do
    case Map.get(content, "kind") do
      nil -> true
      kind when is_binary(kind) -> String.downcase(String.trim(kind)) == "task"
      _ -> false
    end
  end

  # Label matching is SEGMENT-wise on `:`, not substring. TASK-SYSTEM.md §5's own
  # vocabulary is `phase:<goal|design|decision|build|verify>` plus the bare
  # `decision` gate label, so `decision`, `phase:goal` and `kind:decision` all
  # exempt — while `proj:goalkeeper-rewrite` does NOT. A substring rule would
  # hand that row a SILENT permit, and a silent permit is the failure mode this
  # whole family of gates exists to end; a false refusal is loud and recoverable.
  defp container_label?(content) do
    content
    |> Map.get("labels")
    |> List.wrap()
    |> Enum.any?(fn
      label when is_binary(label) ->
        label
        |> String.split(":")
        |> Enum.any?(&(String.downcase(String.trim(&1)) in ~w(decision goal)))

      _ ->
        false
    end)
  end

  # Does anybody name this row as their parent? Same prefix-agnostic predicate
  # `Params.maybe_filter_parent_id/2` and `batch_child_counts/2` match on
  # (`regexp_replace(…, '^drafts\.', '')`), so this agrees with the `child_count`
  # a reader sees on `bp task get <id>`. Scoped to the ROW'S OWN
  # workspace/project/dataset — an unscoped existence check would let another
  # tenant's child hand this row an exemption it did not earn.
  #
  # Deliberately the LAST predicate in `close_artifact_exempt?/1`: it is the only
  # one that touches the DB, and `or` short-circuits, so a row with criteria, a
  # non-task kind, or a container label never pays for it.
  defp has_children?(%Document{doc_id: doc_id} = doc) when is_binary(doc_id) do
    key = DraftId.published_id(doc_id)

    from(d in Document,
      where: d.type == "task",
      where: d.dataset == ^doc.dataset,
      where: fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) == ^key
    )
    |> scope_children(doc)
    |> Repo.exists?()
  end

  defp has_children?(_doc), do: false

  defp scope_children(query, %Document{workspace_id: nil, project_id: nil}), do: query

  defp scope_children(query, %Document{workspace_id: ws, project_id: nil}),
    do: from(d in query, where: d.workspace_id == ^ws)

  defp scope_children(query, %Document{workspace_id: nil, project_id: pr}),
    do: from(d in query, where: d.project_id == ^pr)

  defp scope_children(query, %Document{workspace_id: ws, project_id: pr}),
    do: from(d in query, where: d.workspace_id == ^ws and d.project_id == ^pr)

  # ── What counts as an artifact ───────────────────────────────────────────
  #
  # `#\d+` AND a 7-40 hex sha, in either order and anywhere in the text; OR a
  # pasted run. The sha floor of 7 is what keeps a PR number from doubling as
  # its own sha — a 4-5 digit `#14383` cannot satisfy `[0-9a-f]{7,40}`.
  @pr_number ~r/#\d+/
  @hex_sha ~r/\b[0-9a-f]{7,40}\b/i
  # A pasted run: a ``` fence, or a line whose first non-space characters are
  # `$ ` (the shell-prompt convention every close packet in this repo uses).
  @run_block ~r/```|(?:^|\n)[ \t]*\$ \S/

  defp close_artifact?(reason, landed) do
    landed_artifact?(landed) or
      (is_binary(reason) and
         (Regex.match?(@run_block, reason) or
            (Regex.match?(@pr_number, reason) and Regex.match?(@hex_sha, reason))))
  end

  # The structured twin of the prose form: a land digest that names BOTH a PR and
  # a commit. `%{"prs" => [...], "commit" => <sha>}` is written by the lead seal
  # and by the merge-event bridge; demanding those same two facts be retyped into
  # prose would break the ritual D288's comment above spells out, for no gain.
  #
  # It reads the SAME key vocabulary `landed_summary/1` reads — `prs` and
  # `commit` OR `commits`, string or atom key, list or scalar. Accepting a
  # narrower vocabulary HERE than the function that RENDERS the digest would
  # refuse a close whose own receipt line names the merge: the merge-event
  # bridge writes `commits`, the lead seal writes `commit`, and a gate that knew
  # only one of them would refuse half the sealed closes in the repo.
  defp landed_artifact?(landed) when is_map(landed) do
    raw_prs = Map.get(landed, "prs") || Map.get(landed, safe_atom("prs"))

    raw_commits =
      Map.get(landed, "commit") || Map.get(landed, "commits") ||
        Map.get(landed, safe_atom("commit")) || Map.get(landed, safe_atom("commits"))

    prs = raw_prs |> normalize_landed_list() |> Enum.reject(&(&1 in [nil, ""]))
    commits = normalize_landed_list(raw_commits)

    prs != [] and Enum.any?(commits, &(is_binary(&1) and Regex.match?(@hex_sha, &1)))
  end

  defp landed_artifact?(_landed), do: false

  defp unmet_after_autostamp(%Document{content: content}, landed, ack_override) do
    autostamped =
      if is_map(landed) and map_size(landed) > 0 do
        content
        |> merge_gate_synthetics("", MapSet.new())
        |> MapSet.new(&Map.get(&1, "index"))
      else
        MapSet.new()
      end

    # A SECOND deduction, in the same spirit as the merge-gate one above and
    # bounded just as narrowly. An acknowledgement criterion is itself an
    # acceptance criterion, so a close that already answered it with a recorded
    # `ack_override` would otherwise be refused AGAIN by this gate, for the same
    # single fact, and the only way through would be to pass `criteria_override`
    # as well. That is the reflexive-override habit the D56 hints exist to
    # prevent: make people pass `criteria_override` routinely and it stops
    # meaning anything. So the ack rows — AND ONLY the ack rows, addressed by
    # `Acknowledgement.criterion_indices/1` — drop out when this close carries
    # an ack override. The reverse never holds: `criteria_override` cannot
    # discharge the acknowledgement gate, which runs BEFORE this one and reads
    # `ack_override` alone.
    acknowledged =
      if is_nil(ack_override) do
        MapSet.new()
      else
        MapSet.new(Acknowledgement.criterion_indices(content))
      end

    content
    |> unmet_criteria()
    |> Enum.reject(&MapSet.member?(autostamped, Map.get(&1, "index")))
    |> Enum.reject(&MapSet.member?(acknowledged, Map.get(&1, "index")))
  end

  # The durable override record, or nil when neither gate was overridden. ONE
  # `close_override` map so a re-read of the closed doc answers "was this close
  # honest?" in a single key — `actor` is who closed, `held_by` is who the ledger
  # thought held the lease, `reason` is why they overrode it anyway.
  defp compose_override_record(nil, nil, nil, nil, _worker_id), do: nil

  defp compose_override_record(
         holder_record,
         criteria_record,
         ack_record,
         artifact_record,
         worker_id
       ) do
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    %{}
    |> maybe_put_override("holder", holder_record, worker_id, ts_iso)
    |> maybe_put_override("criteria", criteria_record, worker_id, ts_iso)
    |> maybe_put_override("acknowledgement", ack_record, worker_id, ts_iso)
    |> maybe_put_override("close_reason", artifact_record, worker_id, ts_iso)
  end

  defp maybe_put_override(acc, _key, nil, _worker_id, _ts_iso), do: acc

  defp maybe_put_override(acc, key, record, worker_id, ts_iso) do
    Map.put(acc, key, Map.merge(record, %{"actor" => worker_id, "ts" => ts_iso}))
  end

  # "Edited-under-you becomes a 409, never a silent close." When the caller did
  # NOT pin an explicit observed_rev AND the claim carries a work_digest, the
  # doc's current work-defining fields (title/brief/description/acceptance_criteria —
  # for criteria, only each entry's `criterion` TEXT is work-defining; the
  # met/evidence/attempts progress subfields a mid-claim `stamp` writes are
  # excluded by WorkDigest D5, so a worker's own stamps never fence its close)
  # are re-digested inside this close txn and compared to the claim-time stamp.
  # Drift → {:error, {:doc_changed_since_claim, current_rev, changed_fields}} so
  # the worker re-reads the changed brief before closing against stale
  # assumptions. Three deliberate escape hatches keep this narrow:
  #   * an explicit observed_rev bypasses the digest check (the caller opted
  #     into today's strict full-rev CAS instead — see do_close_txn),
  #   * a claim WITHOUT a work_digest (pre-existing/legacy leases) closes
  #     exactly as before (back-compat), and
  #   * self-edits to code_refs/labels/last_worked_at never trip it — those
  #     fields are outside the digest by design (WorkDigest).
  defp check_work_digest(_doc, observed_rev_opt) when observed_rev_opt != nil, do: :ok

  defp check_work_digest(%Document{content: content} = doc, _no_observed_rev) do
    case content do
      %{"claim" => %{"work_digest" => stored} = claim} when is_binary(stored) ->
        field_digests = Map.get(claim, "work_field_digests", %{})
        current = WorkDigest.combined(WorkDigest.field_digests(doc.title, content))

        if current == stored do
          :ok
        else
          changed = WorkDigest.changed_fields(field_digests, doc.title, content)
          {:error, {:doc_changed_since_claim, doc.rev, changed}}
        end

      _ ->
        :ok
    end
  end

  defp apply_close_update(
         %Document{} = doc,
         worker_id,
         observed_rev,
         new_status,
         reason,
         criteria,
         landed,
         override_record,
         caller_token_id
       ) do
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

    # Land digest rides the same close CAS as close_reason. Only a non-empty map
    # writes; a blank/absent digest never clobbers an existing one (a re-close or
    # a CI backfill can add it later without erasing a prior write).
    new_content = merge_landed(new_content, landed)

    # The loud override record rides the SAME rev-CAS write as the lifecycle
    # flip — an overridden close and its confession land together or not at all.
    new_content = merge_override_record(new_content, override_record)

    # Expectation close-out (living-values §8/§9 — "task proves paper"):
    # acceptance-criteria met/evidence updates ride the SAME rev-CAS write as
    # the lifecycle flip, following the close_reason precedent above. A
    # separate content mutation would race this CAS (close/3 otherwise writes
    # only lifecycle_status/claim/close_reason); folding it into the one
    # UPDATE makes close-and-evidence atomic — both land or neither does.
    # Merge is index-targeted and NEVER rewrites criterion text (the paper's
    # claim citation): only `met` + `evidence` flip. A conflicting update
    # (index out of range, or a `criterion` text guard that no longer
    # matches) aborts the whole close with a CAS-flavoured error so the
    # caller re-reads and retries — deliberate race handling, not silent
    # partial state.
    #
    # Merge-gate auto-stamp (Felix wave-9): the LEAD's merge close synthesizes
    # a met=true update for any acceptance criterion carrying an explicit
    # "merge_gate":true marker so no reviewer hand-patches it. See
    # `autostamp_merge_gate/6` for the conservative guards — it only fires on a
    # terminal `done` close that carries a land digest, and never touches an
    # index the caller already targeted, so a builder's pre-merge close (no
    # landed) is untouched. Runs through the SAME merge_criteria rev-CAS write.
    #
    # NOTHING HERE OBSERVES A MERGE (cch-w66-s2). The whole trigger is the
    # caller's own `landed` bytes, so the synthetics are computed ONCE and used
    # twice: once as criteria updates, and once as the provenance record that
    # names them as caller-asserted rather than verified. Both ride this single
    # rev-CAS write, so an autostamp and its confession land together or not at
    # all — the same discipline `close_override` already follows.
    autostamps = autostamp_merge_gate(doc, criteria, worker_id, new_status, landed, ts_iso)
    criteria = if is_list(criteria), do: criteria ++ autostamps, else: criteria

    new_content =
      merge_autostamp_record(
        new_content,
        "close",
        close_autostamp_record(autostamps, worker_id, caller_token_id, landed, ts_iso)
      )

    with {:ok, new_content} <- merge_criteria(new_content, criteria) do
      case fenced_content_write(doc, observed_rev, new_content, new_rev) do
        {:ok, updated} -> {:ok, updated}
        :stale -> {:error, :stale_claim}
      end
    end
  end

  # merge_criteria/2 (the `[%{"index" => i, "met" => bool, "evidence" => str,
  # "criterion" => guard}]` close-out merge) moved to `Tasks.Internal` — ONE
  # definition shared with `Tasks.Stamp`, so mid-claim stamps and close-time
  # flips cannot drift. Imported above.

  # Land digest merge. UNION into any existing digest so a re-close or a CI
  # backfill accumulates rather than clobbers. A nil/empty/malformed payload
  # leaves content untouched (never erases a prior digest).
  @landed_keys ~w(prs files capability_slugs)
  defp merge_landed(content, landed) when is_map(landed) and map_size(landed) > 0 do
    existing =
      case Map.get(content, "landed") do
        m when is_map(m) -> m
        _ -> %{}
      end

    merged =
      Enum.reduce(@landed_keys, existing, fn key, acc ->
        case normalize_landed_list(Map.get(landed, key) || Map.get(landed, safe_atom(key))) do
          [] -> acc
          incoming -> Map.put(acc, key, Enum.uniq((Map.get(acc, key) || []) ++ incoming))
        end
      end)

    if map_size(merged) == 0, do: content, else: Map.put(content, "landed", merged)
  end

  defp merge_landed(content, _), do: content

  # A close that overrode nothing writes nothing (no empty `close_override` key
  # to make an honest close look confessed). A prior override on a re-closed
  # task is merged over, never erased.
  defp merge_override_record(content, record) when is_map(record) and map_size(record) > 0 do
    existing =
      case Map.get(content, "close_override") do
        m when is_map(m) -> m
        _ -> %{}
      end

    Map.put(content, "close_override", Map.merge(existing, record))
  end

  defp merge_override_record(content, _record), do: content

  # Merge-gate auto-stamp (Felix wave-9). Kills the recurring ledger toil where
  # the final "PR merged"/LEAD-CLOSED acceptance criterion is left met=false at
  # builder-close time and a reviewer hand-patches it every wave. When the LEAD
  # closes on merge, synthesize a met=true criteria update for any criterion the
  # AUTHOR explicitly marked with `"merge_gate" => true`.
  #
  # CONSERVATIVE by design — the union of ALL these must hold or nothing is
  # stamped (a builder's honest pre-merge close is never touched):
  #   * new_status is the terminal `done` (a cancelled/blocked close is not a merge),
  #   * a non-empty `landed` digest rides the close (the LEAD merge close carries
  #     one; a builder pre-merge close does not — this is what prevents recreating
  #     the Mode-A false-true bug),
  #   * the criterion carries the EXPLICIT `"merge_gate" => true` marker — never a
  #     text / last-entry / index heuristic (only 14/34 Felix children carry the
  #     'MERGE GATE' text convention, so a heuristic would both miss and misfire),
  #   * it is still `met` != true (idempotent — an already-stamped gate is left alone),
  #   * the caller's `criteria` payload did NOT already target that index (an
  #     explicit caller update always wins; we never overwrite it),
  #   * the criterion carries a non-empty `criterion` TEXT — see below.
  # The synthetic update rides the SAME merge_criteria + rev-CAS write as every
  # other close-time criteria flip, so it lands atomically with the close or not
  # at all.
  #
  # D56 (wave 5): merge_criteria now FAILS CLOSED on any met-flip that carries no
  # `"criterion"` text guard. This autostamp used to be the one blessed index-only
  # met-flip in the codebase — the exact hole that let a wrong index fabricate a
  # done — so it now threads the STORED text of the very row it is stamping into
  # the update. The guard is trivially satisfiable here (the index and the text
  # are read from the same in-lock list, so they cannot disagree), and threading
  # it keeps ONE rule with ZERO internal exemptions. A merge_gate criterion with
  # no text is UNGUARDABLE, so it is skipped rather than stamped through a hole —
  # authoring a merge-gate criterion with no wording is degenerate, and the close
  # still succeeds (that criterion is simply left for a human to stamp).
  #
  # cch-w66-s2: it returns the SYNTHETICS ONLY (the caller appends them), because
  # the same list is also what the provenance record names. Two readers, one
  # computation — a second traversal could disagree with the one that wrote.
  defp autostamp_merge_gate(%Document{} = doc, criteria, worker_id, "done", landed, ts_iso)
       when is_map(landed) and map_size(landed) > 0 and is_list(criteria) do
    targeted = MapSet.new(criteria, &Map.get(&1, "index"))
    evidence = compose_merge_gate_evidence(doc, worker_id, landed, ts_iso)
    merge_gate_synthetics(doc.content, evidence, targeted)
  end

  defp autostamp_merge_gate(_doc, _criteria, _worker, _status, _landed, _ts_iso), do: []

  # THE TRACE (cch-w66-s2). An autostamped criterion used to be indistinguishable
  # from a hand-proven one: `unmet_after_autostamp/2` deducts the gate from the
  # D289 unmet set, so `check_criteria_proven/4` returns `{:ok, nil}` and NO
  # `close_override` is minted — the deduction erased itself. This key is that
  # deduction's receipt, in `close_override`'s shape and by its precedent: ONE
  # content key a re-read answers "was this criterion PROVEN, or merely asserted?"
  # from, without parsing evidence prose.
  #
  # Two sub-keys, never overwriting each other, because they are two different
  # claims about the world:
  #   * "close"       — a close carried a `landed` map. NOTHING was observed;
  #     `verified: false`. The actor is recorded twice on purpose:
  #     `asserted_worker` is the client-supplied `worker_id` (see the
  #     "NONE OF THIS IS AUTHORIZATION" note in this module's header — not
  #     authorization, a caller can claim to be anyone) and
  #     `authenticated_token_id` is the api_token the server actually
  #     authenticated (nil for internal callers). A record that named only the
  #     first would carry the fabricator's chosen name and nothing else.
  #   * "merge_event" — `reconcile_merge_gate/3` saw a real merge webhook;
  #     `verified: true`.
  @autostamp_key "merge_gate_autostamp"

  defp close_autostamp_record([], _worker_id, _caller_token_id, _landed, _ts_iso), do: nil

  defp close_autostamp_record(autostamps, worker_id, caller_token_id, landed, ts_iso) do
    %{
      "verified" => false,
      "source" => "close_landed_digest",
      "indices" => Enum.map(autostamps, &Map.get(&1, "index")),
      "asserted_worker" => worker_id,
      "authenticated_token_id" => caller_token_id,
      "landed" => landed_summary(landed),
      "ts" => ts_iso
    }
  end

  # A close that autostamped nothing writes nothing (mirrors
  # `merge_override_record/2`: an honest close leaves no receipt to explain
  # away). A prior record is merged over per sub-key, never erased — an
  # unverified close-time assertion stays readable after a later merge event
  # verifies the same criterion.
  defp merge_autostamp_record(content, _key, nil), do: content

  defp merge_autostamp_record(content, key, record) when is_map(record) do
    existing =
      case Map.get(content, @autostamp_key) do
        m when is_map(m) -> m
        _ -> %{}
      end

    Map.put(content, @autostamp_key, Map.put(existing, key, record))
  end

  # Shared merge-gate synthetic builder (used by the lead-close autostamp above
  # AND by `reconcile_merge_gate/3`, the merge-event bridge). Given the stored
  # criteria list, the composed `evidence`, and the set of indices the caller
  # ALREADY targets (an explicit caller update always wins), it returns synthetic
  # `%{"index","met","evidence","criterion"}` updates for every criterion that is
  # ALL of: an explicit `"merge_gate" => true` marker, not already `met`, not
  # caller-targeted, and carrying non-empty guardable text (the D56 fail-closed
  # guard has nothing to CAS against otherwise, so it is skipped — never stamped
  # through a hole). ONE definition keeps both writers on the exact same marker
  # semantics: no text/position/index heuristic, no drift.
  defp merge_gate_synthetics(content, evidence, %MapSet{} = targeted) do
    content
    |> merge_gate_criteria_list()
    |> Enum.with_index()
    |> Enum.filter(fn {entry, i} ->
      is_map(entry) and Map.get(entry, "merge_gate") == true and
        Map.get(entry, "met") != true and not MapSet.member?(targeted, i) and
        guardable_text(entry) != nil
    end)
    |> Enum.map(fn {entry, i} ->
      %{
        "index" => i,
        "met" => true,
        "evidence" => evidence,
        "criterion" => guardable_text(entry)
      }
    end)
  end

  # The stored criterion wording, or nil when there is nothing to CAS against.
  defp guardable_text(%{"criterion" => text}) when is_binary(text) and text != "", do: text
  defp guardable_text(_entry), do: nil

  defp merge_gate_criteria_list(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # The close-time autostamp's evidence sentence (cch-w66-s2).
  #
  # It used to read "auto: lead-closed on merge by <worker> (epoch <n>) — landed
  # <what>", which asserted TWO things nothing on this path observed: that the
  # closer is a LEAD (`worker_id` is a client-supplied body param — see the
  # "NONE OF THIS IS AUTHORIZATION" note in this module's header)
  # and that a MERGE happened (no GitHub call runs here, and none may: this
  # executes under `pg_advisory_xact_lock`, where a network round-trip converts a
  # fabrication bug into an availability bug). A scratch worker paid a gate citing
  # a foreign epic's PR and the ledger recorded it as a lead-closed merge.
  #
  # So the sentence now names exactly what was supplied — a caller-asserted land
  # digest, by a claimed worker, at a time — and says plainly that no merge was
  # observed. It must stay DISTINGUISHABLE from `compose_reconcile_evidence/3`,
  # which is written only after a real merge webhook:
  #
  #   this   : "auto: UNVERIFIED merge-gate autostamp — no merge observed; caller-asserted land digest from worker "lead-w" (epoch 5) naming PR #456 at <ts>"
  #   webhook: "auto: merge-reconciled by github-merge — landed PR #456 (commit abc123) at <ts>"
  #
  # The claim epoch is read from the doc's own claim lease (nil for an unclaimed
  # container close → rendered "?"); the landed summary prefers PR numbers, then a
  # commit sha, then file paths, so the evidence names the artifact it was HANDED.
  defp compose_merge_gate_evidence(%Document{content: content}, worker_id, landed, ts_iso) do
    epoch =
      case get_in(content, ["claim", "epoch"]) do
        nil -> "?"
        e -> to_string(e)
      end

    "auto: UNVERIFIED merge-gate autostamp — no merge observed; caller-asserted land digest " <>
      "from worker #{inspect(worker_id)} (epoch #{epoch}) naming #{landed_summary(landed)} at #{ts_iso}"
  end

  defp landed_summary(landed) do
    prs = normalize_landed_list(Map.get(landed, "prs") || Map.get(landed, safe_atom("prs")))
    commit = Map.get(landed, "commit") || Map.get(landed, "commits")
    files = normalize_landed_list(Map.get(landed, "files") || Map.get(landed, safe_atom("files")))

    cond do
      # Merge-event reconcile carries BOTH a PR number and the merge commit sha —
      # name both so the evidence points at the exact merge artifact (criterion 1).
      prs != [] and is_binary(commit) and commit != "" ->
        "PR " <> Enum.map_join(prs, ", ", &"##{&1}") <> " (commit #{commit})"

      prs != [] ->
        "PR " <> Enum.map_join(prs, ", ", &"##{&1}")

      is_binary(commit) and commit != "" ->
        "commit #{commit}"

      files != [] ->
        Enum.join(files, ", ")

      true ->
        "merge"
    end
  end

  defp normalize_landed_list(nil), do: []
  defp normalize_landed_list(list) when is_list(list), do: Enum.reject(list, &is_nil/1)
  defp normalize_landed_list(scalar), do: [scalar]

  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__missing__
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

        # The stored row, not a reconstruction: this receipt is BROADCAST —
        # `Content.Broadcast` copies `doc.updated_at` onto three PubSub topics —
        # so a struct-merge here ships a stale timestamp to every LiveView and
        # SSE consumer. The hard match on `{:ok, _}` preserves the previous
        # `{1, _} =` assertion: under the per-task advisory lock a lost fence
        # here is a bug, not a race to swallow.
        {:ok, unblocked} = fenced_content_write(dep, dep.rev, new_content, new_rev)

        ev = insert_mutation_event!(unblocked, @event_task_mutated, dep.rev)
        [task_broadcast(unblocked, @event_task_mutated, ev, dep.rev)]
      else
        []
      end
    end)
  end

  defp cascade_unblock_dependents!(_non_done_parent), do: []

  # Land-under-you notice (task-obsession layer 4, the genuinely-new half — the
  # rest of "scope overlap" is already the claim.resources / resource_conflict
  # machinery). When a task closes carrying a land digest, any IN-PROGRESS task
  # whose claimed scope (content.claim.resources) intersects the landed files
  # gets a `task.landed_under_you` mutation event so its worker knows to rebase.
  #
  # PURE NOTIFICATION — never mutates the affected task; it rides the existing
  # mutation-event/broadcast channel (same as the unblock cascade). ADVISORY —
  # emitted after the close has already committed. Tenant-scoped and fail-closed:
  # an unscoped closer (nil workspace) emits nothing rather than blasting every
  # tenant.
  defp notify_landed_under_you!(%Document{content: content} = closed, by_worker) do
    files =
      content
      |> get_in(["landed", "files"])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    ws = Map.get(closed, :workspace_id)

    if files == [] or is_nil(ws) do
      []
    else
      do_notify_landed(closed, files, ws, by_worker)
    end
  end

  defp do_notify_landed(%Document{} = closed, files, ws, by_worker) do
    project_id = Map.get(closed, :project_id)

    from(d in Document,
      where: d.type == "task",
      where: fragment("?->>'kind'", d.content) == "task",
      where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
      # SQL-side overlap: the claim holds at least one of the landed files.
      where: fragment("jsonb_exists_any(?->'claim'->'resources', ?)", d.content, ^files),
      where: d.id != ^closed.id,
      where: d.dataset == ^closed.dataset
    )
    |> Scope.scope_to_workspace(ws, project_id)
    |> Repo.all()
    |> Enum.map(fn %Document{} = affected ->
      meta = %{
        "landed_under_you" => %{
          "landed_task" => closed.doc_id,
          "files" => resource_overlap(affected, files),
          "by_worker" => by_worker
        }
      }

      ev =
        insert_mutation_event!(affected, @event_landed_under_you, affected.rev, "api", meta)

      task_broadcast(affected, @event_landed_under_you, ev, affected.rev)
    end)
  end

  defp resource_overlap(%Document{content: content}, files) do
    held =
      content
      |> get_in(["claim", "resources"])
      |> List.wrap()

    Enum.filter(files, &(&1 in held))
  end

  defp all_blockers_done?(%Document{} = dep) do
    dep.id
    |> Edges.dependencies(kind: :blocks)
    |> Enum.all?(fn %Document{content: c} ->
      Map.get(c, "lifecycle_status") == "done"
    end)
  end
end

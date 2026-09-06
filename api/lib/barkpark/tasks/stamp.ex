defmodule Barkpark.Tasks.Stamp do
  @moduledoc false
  # Criterion-level MID-CLAIM evidence (expressive-agent-loops D3/D6/D7/D8) —
  # stamp ONE acceptance criterion while the claim is live instead of only at
  # close. Stamp is progress, close is the seal: close still validates the
  # full set; a stamped criterion just makes the ledger narrate the run live.
  #
  # Two outcomes, evidence or nothing (D3):
  #
  #   * `{:met, evidence}` — flips the criterion's `met` to true and writes the
  #     (REQUIRED, non-empty) evidence. A met without evidence is rejected
  #     before any DB work — a lock never flips on an empty claim. It ALSO
  #     requires `:criterion_text` (D56): the index alone is not enough to
  #     identify a criterion, and an unguarded index-only met-flip is the
  #     proven false-done vector (`:criterion_text_required`).
  #   * `{:miss, note}` — records the honest attempt WITHOUT flipping: appends
  #     `%{"note","ts","worker"}` to the criterion's `attempts` list (bounded
  #     to the 5 most recent, app-enforced) and PINS `met` explicitly to its
  #     current value. The merge default met→true is never inherited (D8's
  #     proven lock-flipping footgun).
  #   * `{:withdraw, note}` — THE WITHDRAWAL (D745). Review found the stamped
  #     proof false: lower `met` to false, leave the original `evidence`
  #     untouched, and append a `withdrawals` record naming who/why/when plus
  #     the evidence it supersedes. See THE WITHDRAWAL below.
  #
  # Stamp joins the CLOSE lock family (D6): the controller resolves doc_id →
  # `documents.id` and this module locks `task:<uuid>` — it must serialize
  # with close over the same criteria list. Same advisory-lock + in-lock
  # re-read + CAS-on-rev + durable mutation_event + post-commit broadcast
  # shape as `Tasks.Close` / `Tasks.Release`.
  #
  # Auth = holder + epoch (D7): the caller must BE the lease holder
  # (`Internal.check_holder/2`, shared with Release) AND pass close's exact
  # epoch fence — a lapsed/fenced claim cannot stamp; renew (same-worker
  # re-claim) then restamp. Only an `in_progress` task has a live claim to
  # stamp under; anything else is `{:not_in_progress, status}`.
  #
  # The claim-time work_digest is NOT checked here (stamp is progress, not the
  # seal) and — by WorkDigest's D5 narrowing — the stamp's own writes never
  # trip the digest fence on the later default-path close.
  #
  # Emits a `task.criterion` mutation_events row in the SAME transaction (D8,
  # one event funnel), its document map carrying a `"criterion_stamp"` payload
  # (`index`, `result` "met"|"miss"|"withdrawn", `worker`) so the events feed
  # and every board can render the stamp without diffing content. A withdrawal
  # additionally carries `"withdrawn" => true` on that payload, so a feed
  # consumer can select corrections without string-matching the result.
  #
  # THE WITHDRAWAL (D745, wave 62). Before this verb existed, a reviewer who
  # refuted a stamped proof had no write that could lower the lock — `--met`
  # only raises and `--miss` pins — so the correction went into the criterion's
  # own evidence prose and every board kept reading MET. Twelve criteria across
  # two rows carry exactly that today. `--withdraw` is the missing verb, and it
  # is deliberately NOT a permission to un-flip silently: it lowers the lock,
  # keeps the superseded evidence readable, and signs the correction.
  #
  # AUTHORITY, and why it differs from `--met` (this is the load-bearing part).
  # A stamp proves work in flight, so it is holder-only, epoch-fenced and
  # `in_progress`-only. A withdrawal is the OPPOSITE animal: reviews land AFTER
  # the close, which is precisely when the false flag starts lying to boards.
  # Both real instances of the class are sealed rows — one `done`, one
  # `cancelled` — so an in_progress-only withdrawal could not correct a single
  # live instance of the defect it was built for. The fence is therefore chosen
  # from the STORED row:
  #
  #   * an `in_progress` row fences exactly like a stamp — holder-only plus the
  #     same epoch CAS. Nothing changes for work in flight.
  #   * any other row (done, cancelled, blocked, open) has no LIVE lease to
  #     fence against, so the caller must instead pin `:observed_rev` to the rev
  #     it read. That is the same read-before-write proof close offers as
  #     `--set observed_rev=…`: you cannot correct a row you did not read.
  #     Missing → `:observed_rev_required`; stale → `:stale_claim`.
  #
  # LIVENESS, NOT PRESENCE, picks the arm. A closed row KEEPS its claim as a
  # receipt — close stamps `closed_at`/`closed_by` onto it instead of deleting
  # it — so branching on "has a claim" would force a reviewer to type the
  # departed holder's worker id and its final epoch, impersonating the worker
  # whose proof they are refuting. Both live instances of this defect are
  # exactly that shape: cch-w58-s2 carries worker "lead-loop" epoch 10 with
  # closed_at 2026-08-19, and arpss-share-link-object-authz-close carries
  # worker "decide-arpss-w8-sharelink" epoch 7.
  #
  # This never lets a withdrawal fabricate anything: it only ever LOWERS a
  # lock, appends a signed record, and leaves the seal, the close_reason and
  # the original evidence exactly as they were.

  # THE POST-CLOSE ATTEMPT (task-d68754135a6a9f66). `--miss` on a TERMINAL row
  # (`done` / `cancelled`) is admitted on the same fence as a withdrawal, and
  # for the same measured reason. A closer who has legitimately verified
  # something about a sealed row had NO sanctioned per-criterion write — every
  # stamp came back `not_in_progress:done` — so they reached for a raw
  # `/v1/data/mutate` that pastes ONE evidence string across every remaining
  # criterion. That substitution is measurable: roughly 43-57 tasks and 95-130
  # criteria carry it, and one row confesses it verbatim in its own evidence
  # ("stamp failed on already-closed task, criteria corrected via mutate").
  #
  # ONLY the attempt shape is admitted. `{:met, _}` on a terminal row is still
  # `{:not_in_progress, status}` — a met-flip after close rewrites the very
  # verdict the close sealed, and it OVERWRITES `evidence`, which is precisely
  # what makes the met path unsafe behind the seal. An attempt overwrites
  # nothing: `Internal.apply_entry_update`'s attempt clause PINS `met` to its
  # stored value and touches neither `evidence` nor the criterion text, so a
  # post-close miss is append-only by construction rather than by convention.
  #
  # `cancelled` is NOT distinguished from `done`. Both are terminal, both keep
  # their claim as a receipt, and the harm the seal guards against — a rewritten
  # verdict — is identical under either label; a rule that split them would only
  # invite the raw mutate back on whichever side it refused.
  #
  # OPEN and BLOCKED rows are deliberately NOT admitted. They keep
  # `{:not_in_progress, status}`: those rows can still be CLAIMED and stamped
  # under a live lease, so the instrument is not missing there, and this change
  # stays as narrow as the defect it cures.
  #
  # The attempts bound stays SHARED at 5 (`Internal.@attempts_bound`) rather
  # than getting a separate post-close bucket. A second list is a second thing
  # every board, renderer and reader must know about, and the eviction it would
  # buy is theoretical: a post-close annotator writes ONE attempt per criterion,
  # so evicting a builder's five mid-claim attempts takes five separate sweeps
  # over the same criterion. If that ever happens, a separate bound is a purely
  # additive change with no migration.
  #
  # The `task.criterion` event carries `"post_close" => true` when the STORED
  # row was terminal at stamp time, so a board can select post-close annotation
  # out of live progress on a boolean instead of joining against lifecycle.

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      check_holder: 2,
      merge_criteria: 2,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Criteria
  alias Barkpark.Tasks.EvidenceDurability

  @event_task_criterion "task.criterion"

  # The TERMINAL lifecycles — sealed by close, and the only statuses on which
  # a post-close `--miss` attempt is admitted. `open` / `blocked` stay refused:
  # they can still be claimed, so the per-criterion instrument is not missing
  # there. Kept as a literal list because it is used in a guard.
  @terminal_statuses ~w(done cancelled)

  @doc """
  Stamp one acceptance criterion on a claimed task.

  ## Arguments
    * `task_id` — `documents.id` (uuid) of the task (the controller resolves
      the wire `doc_id`, close's `find_task_by_doc_id` pattern).
    * `worker_id` — must equal the lease holder (`content.claim.worker`).
    * `opts`
      * `:observed_epoch` (required integer) — close's exact epoch fence.
      * `:criterion` (required integer ≥ 0) — index into
        `content.acceptance_criteria`.
      * `:outcome` (required) — `{:met, evidence}` | `{:miss, note}` |
        `{:withdraw, note}`.
      * `:criterion_text` — the criterion's EXPECTED stored text, threaded into
        the merge as the `"criterion"` CAS key. **REQUIRED for `{:met, _}`**
        (D56): without it the merge fails closed with
        `:criterion_text_required`, because an index-only met-flip silently
        lands on whatever row the index hits (the 1-based-habit off-by-one that
        fabricated a done in Wave 4). With it, a mis-based index whose text does
        not match the row is REJECTED (`:criteria_mismatch`) instead of flipping
        the neighbour. OPTIONAL for `{:miss, _}` — a miss flips nothing.
      * `:observed_rev` (optional string) — REQUIRED for `{:withdraw, _}` on a
        row that carries no claim (a sealed / released row) AND for
        `{:miss, _}` on a TERMINAL row (`done` / `cancelled`): the `rev` the
        caller read. It is CAS'd against the stored rev inside the lock. Unused
        on any row stamped under a live claim, where the epoch fence applies
        instead.
      * `:merge_gated` (optional boolean, default `false`) — the LEAD-ONLY
        override that releases the MERGE-GATE refusal below. Without it a
        `{:met, _}` on a merge-gated row fails with `:merge_gated_criterion`.
      * `:caller_token_id` (optional) — audit stamp on the event row.

  THE MERGE-GATE REFUSAL. A criterion the LEAD closes on merge is not the
  builder's to flip — flipping it fabricates a done before the PR exists (the
  live footgun that fabricated a done in wave 4). `Criteria.merge_gated?/1`
  decides, reading the STORED row inside the close-family lock: the structural
  `merge_gate` flag when the author set one, the wide prose convention
  otherwise. The check lives HERE, not in the CLI, for two reasons that the
  CLI-side version could not satisfy: only the server can see the stored
  `merge_gate` flag (the CLI has nothing but the `--criterion-text` the caller
  typed), and a CLI-only guard is bypassed entirely by a direct POST to this
  endpoint.

  Errors: `:not_found`, `{:not_in_progress, status}`, `:not_holder`,
  `:fenced_off`, `:stale_claim`, `:criteria_index_out_of_range`,
  `:criteria_mismatch`, `:criterion_text_required`, `:evidence_required`,
  `:note_required`, `:invalid_criteria`, `:merge_gated_criterion`,
  `:branch_only_evidence`,
  `:observed_rev_required`, `:criterion_not_met`.
  """
  def stamp(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    index = Keyword.fetch!(opts, :criterion)
    outcome = Keyword.fetch!(opts, :outcome)
    criterion_text = Keyword.get(opts, :criterion_text)
    caller_token_id = Keyword.get(opts, :caller_token_id)
    merge_gated = Keyword.get(opts, :merge_gated, false) == true
    observed_rev = Keyword.get(opts, :observed_rev)

    with {:ok, update, result_tag} <- build_update(index, outcome, worker_id, criterion_text) do
      do_stamp_txn(
        task_id,
        worker_id,
        observed_epoch,
        update,
        result_tag,
        caller_token_id,
        merge_gated,
        observed_rev
      )
    end
  end

  # Build the merge_criteria update for the outcome — the ONLY place a stamp
  # payload is shaped, so `met` is always explicit and a miss always carries
  # its attempt. Validation is here (not just the controller) so internal
  # callers get the same evidence-or-nothing contract.
  #
  # `criterion_text` is the criteria-grain CAS: `put_guard` sets the `"criterion"`
  # key on the update map ONLY when a non-empty string is given, so
  # `Internal.merge_criteria` rejects a mis-based / off-by-one index
  # (`:criteria_mismatch`) whose text does not match the stored row. A blank / nil
  # guard leaves the update unguarded — which merge_criteria now REFUSES on a
  # met-flip (`:criterion_text_required`, D56). The refusal lives in
  # merge_criteria, not here, so EVERY write path (stamp AND close) fails closed
  # from one definition; a miss carries no lock to flip and stays permissive.
  defp build_update(index, _outcome, _worker, _text)
       when not (is_integer(index) and index >= 0),
       do: {:error, :invalid_criteria}

  # THE DURABILITY CHECK sits here, on the ONE clause that writes a met
  # criterion's evidence, so every caller of every stamp surface meets it. It
  # runs BEFORE the transaction: a refusal costs the stamper one line while the
  # missing sha is still in their hands, which is the whole economics of
  # task-f6fba9a87369ce8e. Six weeks later no audit can recover it.
  defp build_update(index, {:met, evidence}, _worker, text)
       when is_binary(evidence) and evidence != "" do
    case EvidenceDurability.check(evidence) do
      :ok ->
        {:ok, put_guard(%{"index" => index, "met" => true, "evidence" => evidence}, text), "met"}

      {:error, :branch_only_evidence} = err ->
        err
    end
  end

  defp build_update(_index, {:met, _no_evidence}, _worker, _text),
    do: {:error, :evidence_required}

  defp build_update(index, {:miss, note}, worker, text) when is_binary(note) and note != "" do
    attempt = %{
      "note" => note,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "worker" => worker
    }

    {:ok, put_guard(%{"index" => index, "attempt" => attempt}, text), "miss"}
  end

  defp build_update(_index, {:miss, _no_note}, _worker, _text), do: {:error, :note_required}

  # The withdrawal update. `met` is written EXPLICITLY false (never inferred),
  # and the record carries the signature — who, why, when — that the prose
  # convention it replaces could only assert. `merge_criteria` snapshots the
  # superseded evidence onto the record, because only it can see the stored row.
  defp build_update(index, {:withdraw, note}, worker, text)
       when is_binary(note) and note != "" do
    record = %{
      "note" => note,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "worker" => worker
    }

    {:ok, put_guard(%{"index" => index, "met" => false, "withdrawal" => record}, text),
     "withdrawn"}
  end

  defp build_update(_index, {:withdraw, _no_note}, _worker, _text), do: {:error, :note_required}
  defp build_update(_index, _outcome, _worker, _text), do: {:error, :invalid_criteria}

  # Thread the expected criterion text into the merge as the CAS `"criterion"`
  # key — only when it is a real, non-empty string (nil/"" stay permissive).
  defp put_guard(update, text) when is_binary(text) and text != "",
    do: Map.put(update, "criterion", text)

  defp put_guard(update, _text), do: update

  defp do_stamp_txn(
         task_id,
         worker_id,
         observed_epoch,
         update,
         result_tag,
         caller_token_id,
         merge_gated,
         observed_rev
       ) do
    result =
      Repo.transaction(fn ->
        # Close-family advisory lock (D6): serialize with close/release/move
        # over the same task row + criteria list.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_id)])

        # Tenancy was resolved and authorized at the controller (doc_id →
        # task.id), and the holder + epoch-CAS checks below bind the caller to
        # this exact row. Same accepted posture as Close/Release's re-read.
        # global-read: by-PK re-read inside the close-family advisory lock
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            with :ok <- authorize(doc, worker_id, observed_epoch, observed_rev, result_tag),
                 :ok <- check_merge_gate(doc, update, result_tag, merge_gated),
                 {:ok, updated} <- apply_stamp_update(doc, update) do
              ev =
                insert_mutation_event!(
                  updated,
                  @event_task_criterion,
                  doc.rev,
                  "api",
                  Map.merge(
                    %{
                      "criterion_stamp" =>
                        %{
                          "index" => update["index"],
                          "result" => result_tag,
                          "worker" => worker_id
                        }
                        |> then(fn p ->
                          if result_tag == "withdrawn",
                            do: Map.put(p, "withdrawn", true),
                            else: p
                        end)
                        |> then(fn p ->
                          # (d) of task-d68754135a6a9f66: a board must be able
                          # to tell an annotation of a SEALED row from live
                          # progress, on a boolean, without joining lifecycle
                          # or string-matching. Read from the STORED row as it
                          # was inside the lock — `doc`, not `updated`.
                          if terminal?(doc), do: Map.put(p, "post_close", true), else: p
                        end)
                    },
                    caller_stamp(caller_token_id)
                  )
                )

              {:ok, updated, [task_broadcast(updated, @event_task_criterion, ev, doc.rev)]}
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

  # THE AUTHORITY SPLIT (D745). A stamp proves work in flight; a withdrawal
  # corrects a proof that review refuted, which happens after the close. The
  # two therefore cannot share one fence — see the moduledoc for why an
  # in_progress-and-holder-only withdrawal could not reach either live instance
  # of the defect.
  #
  # `--met` / `--miss` keep their contract EXACTLY: in_progress, holder-only,
  # epoch-fenced.
  # THE POST-CLOSE ATTEMPT (task-d68754135a6a9f66). A `--miss` on a TERMINAL
  # row is fenced exactly like a withdrawal on one: there is no live lease, so
  # the rev the caller READ is the fence. This clause sits ahead of the shared
  # met/miss clause below, so ONLY the attempt shape reaches it — a `{:met, _}`
  # on the same row falls to that clause and is refused
  # `{:not_in_progress, status}`, which is the whole safety property.
  #
  # The worker id is still recorded (it signs the attempt) but it is NOT
  # checked: a closed row keeps its claim as a RECEIPT, so a holder test would
  # force an annotator to type the departed closer's worker id — impersonating
  # them to record an observation about their row. Liveness, not presence, picks
  # the arm, exactly as D745 decided for the withdrawal.
  defp authorize(
         %Document{content: %{"lifecycle_status" => status}} = doc,
         _worker_id,
         _observed_epoch,
         observed_rev,
         "miss"
       )
       when status in @terminal_statuses do
    check_observed_rev(doc, observed_rev)
  end

  defp authorize(doc, worker_id, observed_epoch, _observed_rev, tag)
       when tag in ["met", "miss"] do
    with :ok <- check_in_progress(doc),
         :ok <- check_holder(doc, worker_id) do
      check_fencing(doc, observed_epoch)
    end
  end

  # A withdrawal on a row that is STILL IN FLIGHT is fenced identically to a
  # stamp — a live lease has a holder, and the holder answers for it.
  defp authorize(
         %Document{content: %{"lifecycle_status" => "in_progress"}} = doc,
         worker_id,
         observed_epoch,
         _observed_rev,
         "withdrawn"
       ) do
    with :ok <- check_holder(doc, worker_id) do
      check_fencing(doc, observed_epoch)
    end
  end

  # A withdrawal on any other row — closed, cancelled, blocked, open, released
  # — has no LIVE lease to fence against, so the rev the caller READ is the
  # fence instead. Close already spells that proof `--set observed_rev=<rev>`;
  # same idea, same CAS.
  #
  # Liveness, not presence, is what is tested. A closed row KEEPS its claim as
  # a receipt (close stamps `closed_at`/`closed_by` onto it rather than
  # deleting it), so a presence test would demand that a reviewer type the
  # long-departed holder's worker id and its final epoch — impersonating the
  # very worker whose proof they are refuting. The holder gate exists to stop
  # exactly that, so it is not repurposed to require it.
  defp authorize(%Document{} = doc, _worker_id, _observed_epoch, observed_rev, "withdrawn") do
    check_observed_rev(doc, observed_rev)
  end

  # THE READ-BEFORE-WRITE FENCE, shared by the sealed-row withdrawal (D745) and
  # the post-close attempt (task-d68754135a6a9f66): you cannot annotate a row
  # you did not read. Same CAS close already spells `--set observed_rev=...`.
  defp check_observed_rev(%Document{} = doc, observed_rev) do
    cond do
      not (is_binary(observed_rev) and observed_rev != "") -> {:error, :observed_rev_required}
      observed_rev != doc.rev -> {:error, :stale_claim}
      true -> :ok
    end
  end

  # Only an in-flight task has a live claim to stamp under. Mirrors
  # Release.check_in_progress — a done/cancelled task's ledger is sealed by
  # close; RAISING a lock there would rewrite history behind the seal. Two
  # append-only verbs are exempt on a terminal row (see authorize/5), and
  # `{:met, _}` is deliberately not one of them:
  #
  #   * a WITHDRAWAL never raises a lock, never touches the seal or the
  #     close_reason, and only appends a signed correction;
  #   * a post-close `--miss` ATTEMPT pins `met` to its stored value and writes
  #     neither `evidence` nor any criterion text.
  #
  # Both then answer to the observed_rev CAS instead of holder + epoch.
  defp check_in_progress(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      "in_progress" -> :ok
      other -> {:error, {:not_in_progress, other}}
    end
  end

  defp terminal?(%Document{content: content}),
    do: Map.get(content || %{}, "lifecycle_status") in @terminal_statuses

  # EXACTLY Close.check_fencing (D7): epoch must match a present claim; a
  # missing claim would pass here but is unreachable — check_holder already
  # rejected it (`nil` ≠ worker_id).
  defp check_fencing(%Document{content: content}, observed_epoch) do
    case content do
      %{"claim" => %{"epoch" => row_epoch}} when row_epoch == observed_epoch -> :ok
      %{"claim" => %{"epoch" => _}} -> {:error, :fenced_off}
      _ -> :ok
    end
  end

  # THE MERGE-GATE REFUSAL (cch-w49). Refuse a builder's met-flip on a row the
  # LEAD closes on merge, unless the caller passed the explicit `--merge-gated`
  # override. Read the STORED criterion at the index — never the caller's
  # `--criterion-text` — so the verdict comes from what the ledger holds rather
  # than from what the caller chose to type; the criterion-text CAS in
  # `merge_criteria` already refuses a text that disagrees with the row, but
  # this guard must not DEPEND on that ordering to be sound.
  #
  # A miss flips no lock and is never refused. An index that does not resolve
  # to a stored map falls through to `merge_criteria`, which owns the
  # out-of-range / mismatch taxonomy — this guard never invents those errors.
  defp check_merge_gate(_doc, _update, "miss", _merge_gated), do: :ok

  # A withdrawal LOWERS a lock, so it cannot fabricate a done before the PR
  # exists — the exact harm the merge gate exists to prevent. A reviewer who
  # refutes a merge gate's proof must be able to say so without a lead-only
  # override, so this is never refused.
  defp check_merge_gate(_doc, _update, "withdrawn", _merge_gated), do: :ok
  defp check_merge_gate(_doc, _update, _tag, true), do: :ok

  defp check_merge_gate(%Document{content: content}, update, _tag, false) do
    entry =
      (content || %{})
      |> Map.get("acceptance_criteria")
      |> Criteria.at(Map.get(update, "index"))

    if Criteria.merge_gated?(entry) do
      {:error, :merge_gated_criterion}
    else
      :ok
    end
  end

  # In-lock re-read is `doc`; the final write is rev-CAS'd against that read
  # (defense in depth under the advisory lock, same as apply_close_update).
  defp apply_stamp_update(%Document{} = doc, update) do
    with {:ok, new_content} <- merge_criteria(doc.content, [update]) do
      new_rev = generate_rev()

      case fenced_content_write(doc, doc.rev, new_content, new_rev) do
        {:ok, updated} -> {:ok, updated}
        :stale -> {:error, :stale_claim}
      end
    end
  end
end

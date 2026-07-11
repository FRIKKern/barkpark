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
  #     before any DB work — a lock never flips on an empty claim.
  #   * `{:miss, note}` — records the honest attempt WITHOUT flipping: appends
  #     `%{"note","ts","worker"}` to the criterion's `attempts` list (bounded
  #     to the 5 most recent, app-enforced) and PINS `met` explicitly to its
  #     current value. The merge default met→true is never inherited (D8's
  #     proven lock-flipping footgun).
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
  # (`index`, `result` "met"|"miss", `worker`) so the events feed and every
  # board can render the stamp without diffing content.

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      check_holder: 2,
      merge_criteria: 2,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_criterion "task.criterion"

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
      * `:outcome` (required) — `{:met, evidence}` | `{:miss, note}`.
      * `:caller_token_id` (optional) — audit stamp on the event row.

  Errors: `:not_found`, `{:not_in_progress, status}`, `:not_holder`,
  `:fenced_off`, `:stale_claim`, `:criteria_index_out_of_range`,
  `:evidence_required`, `:note_required`, `:invalid_criteria`.
  """
  def stamp(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    index = Keyword.fetch!(opts, :criterion)
    outcome = Keyword.fetch!(opts, :outcome)
    caller_token_id = Keyword.get(opts, :caller_token_id)

    with {:ok, update, result_tag} <- build_update(index, outcome, worker_id) do
      do_stamp_txn(task_id, worker_id, observed_epoch, update, result_tag, caller_token_id)
    end
  end

  # Build the merge_criteria update for the outcome — the ONLY place a stamp
  # payload is shaped, so `met` is always explicit and a miss always carries
  # its attempt. Validation is here (not just the controller) so internal
  # callers get the same evidence-or-nothing contract.
  defp build_update(index, _outcome, _worker) when not (is_integer(index) and index >= 0),
    do: {:error, :invalid_criteria}

  defp build_update(index, {:met, evidence}, _worker)
       when is_binary(evidence) and evidence != "" do
    {:ok, %{"index" => index, "met" => true, "evidence" => evidence}, "met"}
  end

  defp build_update(_index, {:met, _no_evidence}, _worker), do: {:error, :evidence_required}

  defp build_update(index, {:miss, note}, worker) when is_binary(note) and note != "" do
    attempt = %{
      "note" => note,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "worker" => worker
    }

    {:ok, %{"index" => index, "attempt" => attempt}, "miss"}
  end

  defp build_update(_index, {:miss, _no_note}, _worker), do: {:error, :note_required}
  defp build_update(_index, _outcome, _worker), do: {:error, :invalid_criteria}

  defp do_stamp_txn(task_id, worker_id, observed_epoch, update, result_tag, caller_token_id) do
    result =
      Repo.transaction(fn ->
        # Close-family advisory lock (D6): serialize with close/release/move
        # over the same task row + criteria list.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            with :ok <- check_in_progress(doc),
                 :ok <- check_holder(doc, worker_id),
                 :ok <- check_fencing(doc, observed_epoch),
                 {:ok, updated} <- apply_stamp_update(doc, update) do
              ev =
                insert_mutation_event!(
                  updated,
                  @event_task_criterion,
                  doc.rev,
                  "api",
                  Map.merge(
                    %{
                      "criterion_stamp" => %{
                        "index" => update["index"],
                        "result" => result_tag,
                        "worker" => worker_id
                      }
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

  # Only an in-flight task has a live claim to stamp under. Mirrors
  # Release.check_in_progress — a done/cancelled task's ledger is sealed by
  # close; stamping it would rewrite history behind the seal.
  defp check_in_progress(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      "in_progress" -> :ok
      other -> {:error, {:not_in_progress, other}}
    end
  end

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

  # In-lock re-read is `doc`; the final write is rev-CAS'd against that read
  # (defense in depth under the advisory lock, same as apply_close_update).
  defp apply_stamp_update(%Document{} = doc, update) do
    with {:ok, new_content} <- merge_criteria(doc.content, [update]) do
      new_rev = generate_rev()

      {rows, _} =
        from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
        |> Repo.update_all(
          set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
        )

      case rows do
        1 -> {:ok, %{doc | content: new_content, rev: new_rev}}
        0 -> {:error, :stale_claim}
      end
    end
  end
end

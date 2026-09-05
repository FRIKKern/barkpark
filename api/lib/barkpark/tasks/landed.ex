defmodule Barkpark.Tasks.Landed do
  @moduledoc false
  # THE NON-HOLDER LANDING MARK — `POST /v1/tasks/:doc_id/landed`.
  #
  # WHY IT EXISTS (measured by gates-w16 on 2026-09-02, PR #14993). A
  # push-to-main workflow knows exactly one thing worth recording — this task's
  # PR merged, here is the commit — and today it cannot record it:
  #
  #   * `POST /v1/tasks/:id/stamp` runs `check_holder` then `check_fencing`, so
  #     CI (which holds no claim and knows no epoch) gets 409 `not_holder`.
  #     `holder_override` exists only on close, which CI must not call.
  #   * `POST /v1/data/mutate` patch on a task resolves its base through the
  #     DRAFT spelling, so a 200 lands on `drafts.task-…` and the task API
  #     never reads it — a write that looks like it worked and is invisible.
  #
  # So the only thing CI could actually leave was a LABEL. This verb is the
  # narrow door that lets it leave a SENTENCE instead.
  #
  # THE FENCE, STATED AS WHAT IS DELIBERATELY ABSENT. There is no `worker_id`,
  # no `observed_epoch`, no holder check, no lifecycle check — on purpose:
  # every one of those is exactly the thing CI cannot satisfy, and requiring
  # them is what made `stamp` unusable. What is NOT relaxed is the blast
  # radius. This verb can write EXACTLY two things:
  #
  #   1. `content.landed` — union-merged through
  #      `Tasks.Internal.merge_landed/2`, the SAME merge `Tasks.Close` uses, so
  #      a landing mark and a close's land digest accumulate under one rule and
  #      neither can clobber the other.
  #   2. ONE acceptance criterion's `met`/`evidence`, and ONLY when that
  #      criterion is MERGE-SHAPED and not already met (see `merge_shaped?/1`).
  #
  # It cannot touch lifecycle_status, the claim, disposition, labels, or any
  # other criterion. A caller who wants more still has to be the holder.
  #
  # MERGE-SHAPED IS A PERMIT, SO IT IS NARROWER THAN `stamp`'S REFUSAL.
  # `Criteria.merge_gated?/1` is deliberately WIDE because there it gates a
  # REFUSAL — a false positive is a loud, overridable 409. Here the same
  # predicate gates a PERMIT: a false positive is a SILENT met=true on a
  # criterion nobody proved. The two error directions invert, so this module
  # inverts one arm with them — an explicit `merge_gate: false` VETOES, and no
  # prose match can override an author who wrote it. The union the row asked
  # for (`merge_gated?/1` OR the merged-to-main wording) applies only where the
  # author declared nothing.
  #
  # Write shape is `Tasks.Mutations.relabel_by_id/4`'s, not `Tasks.Stamp`'s:
  # per-task advisory lock, in-lock re-read of the PUBLISHED row the controller
  # resolved, CAS-on-rev, durable `task.landed` mutation_event carrying the
  # caller token id, post-commit broadcast.

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      merge_criteria: 2,
      merge_landed: 2,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Criteria

  @event_task_landed "task.landed"

  # The landing WORDING arm, verbatim from the request (task-59fe7b40b719b379):
  # the three spellings a merge-gated final criterion is actually written in
  # that `Criteria.merge_gated?/1`'s MERGE-GATE(D) marker regex does not catch.
  # A SUPPLEMENT to that predicate, never a replacement — and, like it, only
  # consulted when the author declared no explicit `merge_gate` flag.
  @landing_worded ~r/pr\s+merged|merged\s+to\s+main|merged\s+into\s+main/i

  @doc """
  Record a landing on a task WITHOUT holding its claim.

  ## Arguments
    * `task_id` — `documents.id` (uuid); the controller resolves the wire
      `doc_id` through `find_task_by_doc_id/2`, which reads the PUBLISHED
      spelling first and only falls back to `drafts.<id>`. That resolution is
      the whole point — it is the step `/v1/data/mutate` skips.
    * `opts`
      * `:commit` / `:pr` / `:note` — the landing sentence. At least one must
        be a non-empty string, or `:empty_landing` (a no-op write would still
        burn a rev and emit an event that says nothing).
      * `:criterion` — optional non-negative index to flip.
      * `:caller_token_id` — audit stamp on the event row.

  Errors: `:not_found`, `:empty_landing`, `:invalid_criteria`, `:note_required`,
  `:criteria_index_out_of_range`, `:criterion_already_met`,
  `:criterion_not_merge_shaped`, `:criterion_text_required`, `:stale_claim`.
  """
  @spec record(binary(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def record(task_id, opts \\ []) when is_binary(task_id) do
    commit = trimmed(Keyword.get(opts, :commit))
    pr = trimmed(Keyword.get(opts, :pr))
    note = trimmed(Keyword.get(opts, :note))
    index = Keyword.get(opts, :criterion)
    caller_token_id = Keyword.get(opts, :caller_token_id)

    digest = digest(commit, pr, note)

    cond do
      map_size(digest) == 0 ->
        {:error, :empty_landing}

      not (is_nil(index) or (is_integer(index) and index >= 0)) ->
        {:error, :invalid_criteria}

      not is_nil(index) and is_nil(note) ->
        # The note IS the evidence a flip writes. A flip with nothing to say
        # would stamp `met: true` with an empty proof — the exact shape
        # `Tasks.Stamp` refuses as `:evidence_required`.
        {:error, :note_required}

      true ->
        do_record(task_id, digest, index, note, caller_token_id)
    end
  end

  defp do_record(task_id, digest, index, note, caller_token_id) do
    result =
      Repo.transaction(fn ->
        # Close-family advisory lock: serialize with close/stamp/release over
        # the same criteria list, so a landing mark and a close cannot
        # interleave halfway through the criteria merge.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        # global-read: by-PK re-read inside the close-family advisory lock — tenancy was resolved and authorized at the controller (doc_id → task.id), the Close/Stamp posture. (ONE LINE, directly above the read: tenant-scope-check.sh reads only the immediately-preceding line, so a wrapped justification reads as UNJUSTIFIED.)
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev

            with {:ok, updates} <- criterion_update(doc, index, note),
                 merged = merge_landed(doc.content || %{}, digest),
                 {:ok, new_content} <- merge_criteria(merged, updates),
                 {:ok, updated} <-
                   write(doc, observed_rev, new_content) do
              ev =
                insert_mutation_event!(
                  updated,
                  @event_task_landed,
                  observed_rev,
                  "api",
                  Map.merge(
                    %{
                      "landed_mark" => %{
                        "landed" => digest,
                        "criterion" => index,
                        "flipped" => updates != []
                      }
                    },
                    caller_stamp(caller_token_id)
                  )
                )

              {:ok, updated, [task_broadcast(updated, @event_task_landed, ev, observed_rev)]}
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

  defp write(%Document{} = doc, observed_rev, new_content) do
    case fenced_content_write(doc, observed_rev, new_content, generate_rev()) do
      {:ok, updated} -> {:ok, updated}
      :stale -> {:error, :stale_claim}
    end
  end

  # ─── The criterion arm ────────────────────────────────────────────────────
  #
  # No `:criterion` means no criteria update at all — the landing sentence is
  # recorded and nothing is flipped. That is the default shape.
  defp criterion_update(_doc, nil, _note), do: {:ok, []}

  defp criterion_update(%Document{content: content}, index, note) do
    entry =
      (content || %{})
      |> Map.get("acceptance_criteria")
      |> Criteria.at(index)

    cond do
      is_nil(entry) ->
        {:error, :criteria_index_out_of_range}

      # NEVER OVERWRITE A PROVEN CRITERION. A criterion that already says met
      # carries someone's evidence; a landing mark replacing it would erase the
      # proof and substitute a merge notice for it.
      Map.get(entry, "met") == true or Map.get(entry, :met) == true ->
        {:error, :criterion_already_met}

      not merge_shaped?(entry) ->
        {:error, :criterion_not_merge_shaped}

      true ->
        # The `"criterion"` guard is the STORED text, read off the row inside
        # this lock — never a caller-supplied string. That is what lets a
        # tokenless CI flip satisfy `merge_criteria`'s D56 fail-closed rule
        # (`:criterion_text_required`) honestly: the CAS still fires if the row
        # moved between the read and the write, and CI never had to be trusted
        # with the text. A criterion row carrying no text at all cannot be
        # flipped by anyone — merge_criteria refuses it, and so it should.
        {:ok,
         [
           %{
             "index" => index,
             "met" => true,
             "evidence" => note,
             "criterion" => criterion_text(entry)
           }
         ]}
    end
  end

  # See the moduledoc: this is a PERMIT predicate, so the explicit author
  # declaration wins in BOTH directions and prose decides only its absence.
  defp merge_shaped?(entry) do
    case explicit_flag(entry) do
      true -> true
      false -> false
      _ -> Criteria.merge_gated?(entry) or landing_worded?(criterion_text(entry))
    end
  end

  defp explicit_flag(entry) do
    case Map.fetch(entry, "merge_gate") do
      {:ok, v} -> v
      :error -> Map.get(entry, :merge_gate)
    end
  end

  defp landing_worded?(text) when is_binary(text), do: Regex.match?(@landing_worded, text)
  defp landing_worded?(_), do: false

  defp criterion_text(entry) do
    case Map.get(entry, "criterion") || Map.get(entry, :criterion) do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  # ─── The landing sentence ─────────────────────────────────────────────────
  #
  # Three scalars in, a `merge_landed`-shaped digest out. The plural keys are
  # deliberate: `content.landed` is a UNION of lists, so a second landing mark
  # on the same row accumulates a second commit rather than replacing the
  # first.
  defp digest(commit, pr, note) do
    %{}
    |> put_present("commits", commit)
    |> put_present("prs", pr)
    |> put_present("notes", note)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, [value])

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(value) when is_integer(value), do: Integer.to_string(value)
  defp trimmed(_), do: nil
end

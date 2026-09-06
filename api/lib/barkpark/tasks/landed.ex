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
  # ONE BOOLEAN WAS CARRYING TWO MEANINGS (task-48ff3f84e68aecbb). Being
  # merge-SHAPED is still not the same question as being merge-DISCHARGED, and
  # until this module asked the second question it answered the first and acted
  # on the answer. `merge_gate: true` means, everywhere it is read —
  # `Tasks.Stamp`'s builder refusal and `Tasks.Close.autostamp_merge_gate/6` —
  # "THE LEAD CLOSES THIS ROW, NOT THE BUILDER". Leads set it on criteria that
  # demand far more than a merge, because that sentence is true of those rows
  # too. The live example the defect was found from (task-6d80c6cc7d97b1d1
  # criterion 6) is worded "MERGE-GATED -- THE LEAD CLOSES THIS, AND ONLY ON
  # THE DEMO. An editor completes the full round trip ... with the run shown."
  # It is merge-SHAPED twice over (flag and prose) and a merge cannot discharge
  # a syllable of it — yet a tokenless CI landing notice could flip it, and the
  # `--note` it flipped it with became the criterion's evidence.
  #
  # SO THE SECOND MEANING GETS ITS OWN SIGNAL, READ ONLY HERE:
  #
  #   * `merge_discharges: true|false` — the explicit author declaration that
  #     a MERGE, by itself, does or does not discharge this criterion. It
  #     decides ALONE, in both directions, exactly as `merge_gate` does for the
  #     shape question. This is the key an author writes when the two answers
  #     differ: `merge_gate: true, merge_discharges: false` is the shape the
  #     live example wanted and could not spell — the lead still closes it, the
  #     builder is still refused, and no landing notice can seal it.
  #   * key absent → merge-shaped AND NOT `@demonstration_worded` permits. The
  #     prose veto is read off the STORED criterion text, never off anything
  #     the caller typed, and it only ever REMOVES a permit.
  #
  # WHY A PROSE VETO AND NOT A CORPUS REINTERPRETATION. Thousands of live rows
  # carry `merge_gate: true` with both meanings mixed together; deciding which
  # is which for all of them is a data migration, not a permit fix. Nothing
  # here changes what `merge_gate` MEANS or what any other reader does with it,
  # so no existing row is reinterpreted and the lead's close-time autostamp
  # still flips every genuine gate it flipped yesterday. What changes is only
  # which of those rows a CLAIMLESS caller may flip.
  #
  # AND THE VETO'S ERROR DIRECTIONS RUN THE SAME WAY THE MODULE ALREADY
  # ARGUES. A false veto is a LOUD refusal, naming the phrase it matched, and
  # the author clears it permanently with `merge_discharges: true`. A false
  # permit is a silent fabricated done nobody ever objects to. So the veto is
  # allowed to be a little eager and the permit is not — which is also why the
  # veto may NEVER be the only thing standing between a caller and a flip that
  # `merge_shaped?/1` would already have refused: it subtracts from that set,
  # it never adds to it.
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

  alias Barkpark.Tasks.LockKey
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
  `:criterion_not_merge_shaped`, `:criterion_demands_demonstration`,
  `:criterion_text_required`, `:stale_claim`.
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
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_id)])

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

      # MERGE-SHAPED, BUT A MERGE CANNOT DISCHARGE IT. The shape question is
      # answered; this is the second one, and it is the only guard between a
      # claimless caller and a criterion whose own text says a merge is not
      # what proves it.
      not merge_discharges?(entry) ->
        {:error, :criterion_demands_demonstration}

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
  #
  # SHAPE ONLY. "Is this the lead's row rather than the builder's?" — the same
  # question `Tasks.Stamp` and `Tasks.Close.autostamp_merge_gate/6` ask, read
  # off the same field, unchanged. `merge_discharges?/1` asks the other one.
  defp merge_shaped?(entry) do
    case explicit_key(entry, "merge_gate", :merge_gate) do
      true -> true
      false -> false
      _ -> Criteria.merge_gated?(entry) or landing_worded?(criterion_text(entry))
    end
  end

  @doc """
  Reports whether a MERGE, BY ITSELF, discharges this acceptance criterion —
  the question `merge_gate` was never asking and was answering anyway.

  Public so the CLI-facing contract and its tests can name one predicate
  instead of re-deriving the vocabulary; `Tasks.Landed` is its only caller in
  the write path, and NOTHING outside this verb consults it. It cannot widen
  `merge_shaped?/1`: it is ANDed with it, so it only ever removes permits.

    * `merge_discharges: true`  → yes, decided by the author, prose ignored.
      The permanent, per-row clearing of a false veto.
    * `merge_discharges: false` → no, decided by the author. The row a lead
      wants: `merge_gate: true` (the lead still closes it, the builder is
      still refused) plus this, so no landing notice can seal it.
    * key absent → the criterion's own STORED text decides, and only against
      itself: text that demands a demonstration, a live read, or an operator
      action says a merge did not produce the thing it asks for.
  """
  @spec merge_discharges?(term()) :: boolean()
  def merge_discharges?(%{} = entry) do
    case explicit_key(entry, "merge_discharges", :merge_discharges) do
      true -> true
      false -> false
      _ -> not demonstration_worded?(criterion_text(entry))
    end
  end

  def merge_discharges?(_), do: false

  # THE DEMONSTRATION VOCABULARY — deliberately NARROW, unlike
  # `Criteria.merge_gated?/1`'s wide prose arm, because that one gates a
  # refusal and this one subtracts from a permit... but subtracting is the SAFE
  # direction here, so it is narrow for a different reason: every phrase in it
  # has to name something a merge DEMONSTRABLY does not produce, or the veto
  # stops meaning anything and authors learn to reach for the override reflex.
  # Each alternative below is present because a criterion that says it is
  # asking for a human to have watched something happen:
  #
  #   * demo / demonstrat… — the live example's own word ("ONLY ON THE DEMO").
  #   * the run shown / with the run / run it live — a merge shows no run.
  #   * screenshot / recording / walkthrough — artifacts of a person looking.
  #   * live read / live run / in production / on the box / against prod —
  #     a state read a merge cannot perform on its own behalf.
  #   * an operator / by hand / manually / a human — an act with an actor.
  #
  # NOT INCLUDED, and deliberately: "verified", "proved", "tested", "green",
  # "CI". Those are the words a genuinely merge-discharged criterion is
  # written in, and vetoing them would be the "refuses everything" failure —
  # a permit that never permits is the same defect wearing the other sign.
  @demonstration_worded ~r/
      \bdemo(?:s|ed|nstrat\w*)?\b
    | \bthe\s+run\s+(?:shown|is\s+shown)\b
    | \bwith\s+the\s+run\b
    | \brun\s+it\s+live\b
    | \bscreen\s?shots?\b
    | \brecordings?\b
    | \bwalk\s?through\b
    | \blive\s+(?:read|run|session)\b
    | \bin\s+production\b
    | \bon\s+the\s+box\b
    | \bagainst\s+prod(?:uction)?\b
    | \ban?\s+operator\b
    | \bby\s+hand\b
    | \bmanually\b
    | \ba\s+human\b
  /xi

  defp demonstration_worded?(text) when is_binary(text),
    do: Regex.match?(@demonstration_worded, text)

  defp demonstration_worded?(_), do: false

  # String key first (the persisted shape), atom fallback — via Map.fetch so a
  # present-but-false value is not masked; a missing key returns `nil`, which
  # both callers read as "the author declared nothing".
  defp explicit_key(entry, string_key, atom_key) do
    case Map.fetch(entry, string_key) do
      {:ok, v} -> v
      :error -> Map.get(entry, atom_key)
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

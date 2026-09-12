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

  # How many changed paths a landing stores VERBATIM before the digest replaces
  # them with a count and the sorted top-level dirs. 40 is the size at which a
  # human stops reading the list and starts reading the shape.
  @files_verbatim_limit 40

  @files_message ~s|files must be a LIST OF STRINGS — the paths this landing changed, e.g. | <>
                   ~s|"files": ["api/lib/barkpark/tasks/landed.ex", "api/test/barkpark/tasks/landed_test.exs"]. | <>
                   ~s|It was not, so NOTHING was recorded: a files value this verb cannot store is refused HERE | <>
                   ~s|rather than dropped with a 2xx that says the paths landed. Send a JSON array, or repeat the | <>
                   ~s|bracketed query key (files[]=a/b.ex&files[]=c/d.ex). Omit it entirely to record the landing | <>
                   ~s|sentence without paths.|

  # A path-shaped token inside a row's own prose: two or more slash-joined
  # segments (`api/lib/barkpark/tasks/landed.ex`, `internal/cli`, `docs/ops/`).
  # Deliberately NOT bare words — "tasks" or "api" written in a sentence names
  # a subject, not a fence, and treating it as one would make every row overlap
  # everything.
  @path_token ~r{[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.*-]+)+}

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

    case check_files(Keyword.get(opts, :files)) do
      # A `files` value this verb cannot store is REFUSED, never dropped. The
      # controller turns the same check into a 400 naming the field; this arm is
      # what makes a direct `Tasks.record_landing(id, files: 5)` refuse too.
      {:error, _message} ->
        {:error, :invalid_files}

      {:ok, files} ->
        digest = digest(commit, pr, note, files)

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
            do_record(task_id, digest, index, note, files, pr, caller_token_id)
        end
    end
  end

  defp do_record(task_id, digest, index, note, files, pr, caller_token_id) do
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

            with {:ok, updates} <- criterion_update(doc, index, note, files, pr),
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
  defp criterion_update(_doc, nil, _note, _files, _pr), do: {:ok, []}

  defp criterion_update(%Document{content: content} = doc, index, note, files, pr) do
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

      # THE PATHS THIS LANDING TOUCHED ARE NOT THIS ROW'S (task-726717ba693eb424).
      # Merge-shaped and merge-discharged say the row is sealed BY A MERGE; they
      # never asked WHICH merge. A PR that changed only `cloud/` can carry a
      # perfectly true landing sentence and flip a row whose every named path is
      # under `api/lib/barkpark/tasks/` — and nothing in the sentence is false,
      # which is exactly why no reader catches it. So the last guard compares
      # what the PR CHANGED against what the ROW NAMES, and refuses the flip
      # when the two share nothing. It can only fire when the caller SENT files:
      # a fileless landing is unmeasurable, not suspect, so it keeps the
      # behaviour it has always had (see `overlap_report/3`, which says so in
      # the response instead of leaving the caller to guess).
      true ->
        # The `"criterion"` guard is the STORED text, read off the row inside
        # this lock — never a caller-supplied string. That is what lets a
        # tokenless CI flip satisfy `merge_criteria`'s D56 fail-closed rule
        # (`:criterion_text_required`) honestly: the CAS still fires if the row
        # moved between the read and the write, and CI never had to be trusted
        # with the text. A criterion row carrying no text at all cannot be
        # flipped by anyone — merge_criteria refuses it, and so it should.
        with :ok <- files_overlap(doc, files, pr) do
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

  # ─── THE OVERLAP GUARD ────────────────────────────────────────────────────
  #
  # A merge-shaped criterion says "a merge seals this row". It never said WHICH
  # merge, and until this guard nothing asked. So a landing mark carrying a PR
  # that changed only `cloud/` could flip a criterion whose every named path is
  # under `api/lib/barkpark/tasks/`, with a landing sentence in which every
  # single word is TRUE — the PR did merge, that is its sha — which is precisely
  # why no reader downstream ever catches it. The row ends up sealed by work
  # that was not its work.
  #
  # THE COMPARISON IS COARSE ON PURPOSE. A false refusal is a loud wall in front
  # of a legitimate merge; a false permit is a silent fabricated done. So the
  # test is TOP-LEVEL AREAS, not exact paths: the landing overlaps the row if any
  # changed path shares a top-level segment with a path the row's own text names,
  # or is a segment-prefix of one (either direction), or if its basename appears
  # verbatim in that text. Anything narrower would red on a row that names
  # `api/lib/x.ex` when the PR also had to touch `api/test/x_test.exs`.
  #
  # AND IT IS UNMEASURABLE IN TWO DIRECTIONS, BOTH OF WHICH PERMIT.
  #   * The landing carried NO files — nothing to compare. That is today's
  #     behaviour, unchanged, and `overlap_report/3` says so in the response
  #     rather than letting a caller read the silence as a passed check.
  #   * The ROW names no path-shaped token anywhere in its title, description or
  #     criteria. Then the row states no fence and the guard has no opinion; a
  #     refusal here would be the guard asserting a mismatch it never measured.
  @spec files_overlap(Document.t(), [String.t()] | nil, String.t() | nil) ::
          :ok | {:error, {:landing_files_outside_row, String.t()}}
  def files_overlap(_doc, nil, _pr), do: :ok

  def files_overlap(%Document{} = doc, files, pr) when is_list(files) do
    text = row_text(doc)
    named = row_paths(text)

    cond do
      named == [] -> :ok
      Enum.any?(files, &overlaps?(&1, named, text)) -> :ok
      true -> {:error, {:landing_files_outside_row, refusal(doc, files, named, pr)}}
    end
  end

  @doc """
  What the overlap guard DID, in the shape the `landed` response carries.

  A guard that silently does nothing on a fileless landing is indistinguishable
  from a guard that ran and passed, so the response says which of the two
  happened every time a criterion flip is asked for. Returns `%{}` when no flip
  was requested — there is nothing to report about a landing sentence.
  """
  @spec overlap_report(Document.t(), [String.t()] | nil, non_neg_integer() | nil) :: map()
  def overlap_report(_doc, _files, nil), do: %{}

  def overlap_report(%Document{} = doc, files, _criterion) do
    text = row_text(doc)
    named = row_paths(text)

    cond do
      is_nil(files) or files == [] ->
        %{
          overlap: %{
            checked: false,
            reason:
              "this landing carried no files, so no path-overlap check ran — a criterion flip on a " <>
                "fileless landing keeps exactly the behaviour it has always had. Pass files:[...] (the " <>
                "paths the PR changed) and the flip is checked against the paths this row names."
          }
        }

      named == [] ->
        %{
          overlap: %{
            checked: false,
            files: files,
            reason:
              "this row's title, description and criteria name no path-shaped token, so there was " <>
                "nothing to compare the landing's files against — the guard has no opinion on a row " <>
                "that states no fence, and permits rather than asserting a mismatch it never measured."
          }
        }

      true ->
        %{overlap: %{checked: true, files: files, row_paths: named}}
    end
  end

  # Title + description + every criterion's wording: the three places a row is
  # allowed to say what it is about.
  defp row_text(%Document{title: title, content: content}) do
    content = content || %{}

    criteria =
      case Map.get(content, "acceptance_criteria") do
        list when is_list(list) -> Enum.map(list, &(criterion_text(&1) || ""))
        _ -> []
      end

    [title || "", Map.get(content, "description") || "" | criteria]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp row_paths(text) do
    @path_token
    |> Regex.scan(text)
    |> Enum.map(fn [match | _] -> String.trim_trailing(match, "/") end)
    # A version ("1.2"), a bare host or an "and/or" are slash-joined tokens that
    # name no directory. A path token has to start with a segment that could BE
    # one, so drop the ones whose first segment has a dot in it.
    |> Enum.reject(&(&1 == "" or String.contains?(top_level(&1), ".")))
    |> Enum.uniq()
  end

  defp overlaps?(file, named, text) do
    fsegs = String.split(file, "/")

    Enum.any?(named, fn path ->
      psegs = String.split(path, "/")

      hd(fsegs) == hd(psegs) or List.starts_with?(fsegs, psegs) or
        List.starts_with?(psegs, fsegs)
    end) or String.contains?(text, Path.basename(file))
  end

  # NAMES THE ROW, THE PR AND BOTH SIDES OF THE COMPARISON — because the caller
  # cannot re-derive any of the three from a token, and the honest recovery
  # ("record the sentence, flip nothing") has to be one flag away.
  defp refusal(%Document{doc_id: doc_id, title: title}, files, named, pr) do
    ~s|the files this landing changed overlap nothing task row #{doc_id} ("#{title}") names, so the | <>
      ~s|--criterion flip is refused and NOTHING was written (the flip and the landing sentence ride one CAS). | <>
      ~s|#{pr_phrase(pr)} changed: #{listing(files)}. The row's title, description and criteria name: | <>
      ~s|#{listing(named)}. A merge-shaped criterion says a MERGE seals this row; it never said which merge, | <>
      ~s|and a landing sentence in which every word is true can still seal a row the PR never served. | <>
      ~s|Re-run without --criterion to record the landing sentence alone, or flip the row this PR actually did | <>
      ~s|the work for. If the row really is discharged by paths it never names, say so on the criterion — the | <>
      ~s|paths belong in its wording.|
  end

  defp pr_phrase(nil), do: "This landing (no PR given)"
  defp pr_phrase(pr), do: "PR #{pr}"

  # Bounded the same way the stored digest is: past the verbatim limit a reader
  # wants the shape, not 600 paths inside an error message.
  defp listing(paths) when length(paths) <= @files_verbatim_limit, do: Enum.join(paths, ", ")

  defp listing(paths),
    do: "#{length(paths)} paths across #{Enum.join(top_level_dirs(paths), ", ")}"

  # ─── The landing sentence ─────────────────────────────────────────────────
  #
  # Three scalars in, a `merge_landed`-shaped digest out. The plural keys are
  # deliberate: `content.landed` is a UNION of lists, so a second landing mark
  # on the same row accumulates a second commit rather than replacing the
  # first.
  # `landings` is the PAIRED entry, and it is written ONLY when this one call
  # knew BOTH halves (cch-w63). `prs` and `commits` are parallel lists that
  # accumulate across calls, so on a row with four landings they say WHICH four
  # PRs and WHICH four shas and never which sha paid which PR — the join lived
  # only in the `notes` sentence, which is prose. Here both scalars are in hand
  # at once, so the association is recorded where it was observed instead of
  # being re-derived downstream from a sentence.
  #
  # A call carrying only one half writes only that half's scalar list and NO
  # pair. Emitting `%{"pr" => n}` with no commit would be a pair asserting an
  # association this caller never had, which is the absent-vs-empty collapse
  # this tree refuses everywhere else.
  defp digest(commit, pr, note, files) do
    %{}
    |> put_present("commits", commit)
    |> put_present("prs", pr)
    |> put_present("notes", note)
    |> put_files(files)
    |> put_landing(pr, commit)
  end

  # THE CHANGED PATHS, STORED AS PATHS (task-726717ba693eb424). `@landed_keys`
  # has accepted a `files` key since the close family shared this merge, and
  # this verb never wrote one — so a caller who sent `files: [...]` got a 2xx and
  # a ledger row where the paths existed only inside the `notes` SENTENCE, which
  # is prose no reader can query. Same defect the `landings` pair fixed, one key
  # over.
  #
  # BOUNDED, BECAUSE A LEDGER ROW IS NOT A DIFF. Up to
  # `@files_verbatim_limit` paths are stored VERBATIM and read back verbatim —
  # the shape a reader wants for the landings that actually name a fence. Past
  # it, storing 600 paths would make `content.landed` the largest thing on the
  # row and say less than three lines would, so the digest replaces them: the
  # COUNT plus the SORTED top-level dirs, under a DIFFERENT key
  # (`file_digests`), so "verbatim" and "summarised" are told apart by which key
  # is present and never by inspecting a list's elements.
  defp put_files(map, nil), do: map

  defp put_files(map, files) when length(files) <= @files_verbatim_limit,
    do: Map.put(map, "files", files)

  defp put_files(map, files),
    do:
      Map.put(map, "file_digests", [
        %{"count" => length(files), "dirs" => top_level_dirs(files)}
      ])

  @doc """
  The SHAPE check on a landing's `files`, returning the message the HTTP door
  renders as a 400.

  Public because the refusal has to happen at BOTH doors and say the same thing
  at each: the controller needs the sentence, and `record/2` needs the verdict
  so a direct call cannot post a `files` value the store would silently drop.

    * absent / `nil` → `{:ok, nil}` (record the landing without paths)
    * a list of strings → `{:ok, cleaned}`; blanks are dropped, order and
      duplicates are collapsed by `Enum.uniq/1`, and a list that cleans down to
      nothing is the same as absent
    * anything else → `{:error, message}`, and NOTHING is written
  """
  @spec check_files(term()) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  def check_files(nil), do: {:ok, nil}

  def check_files(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      case list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() do
        [] -> {:ok, nil}
        cleaned -> {:ok, cleaned}
      end
    else
      {:error, @files_message}
    end
  end

  def check_files(_), do: {:error, @files_message}

  # ─── The LAND DIGEST shape check (task-4ab4a5b58bce97a6) ──────────────────
  #
  # `content.landed` has TWO writers — this verb and `Tasks.Close` — and until
  # now only one of them checked what it was handed. `/landed` runs
  # `check_files/1` at the door; `close` piped `params["landed"]` straight into
  # `Tasks.Internal.merge_landed/2`, which normalises whatever it finds and
  # SILENTLY DROPS the rest. So a close could post `{"files": 3}` or
  # `{"pr": 17}` (a key the union has never merged) and get a 2xx asserting a
  # landing the ledger does not hold.
  #
  # This is that check, and it lives HERE — beside `check_files/1`, in the
  # module that owns the stored shape — precisely so the close door cannot grow
  # an UNLOCKED MIRROR of it. `files` is not re-implemented: the arm below CALLS
  # `check_files/1`, so the two doors cannot drift into disagreeing about what a
  # storable path list is.
  #
  # The key vocabulary is `merge_landed/2`'s `@landed_keys` plus `commit`, the
  # singular `Close.landed_summary/1` reads for its evidence sentence. An
  # UNKNOWN key is NAMED and refused rather than ignored, because "ignored" is
  # exactly how a typo (`"pr"` for `"prs"`) became a 2xx that recorded nothing.
  @digest_keys ~w(prs commits commit files file_digests capability_slugs notes landings)

  @digest_message ~s|landed must be a MAP of land-digest keys — | <>
                    ~s|{"prs": ["17070"], "commit": "f7610ed6a", "files": ["api/lib/x.ex"]}. |

  @doc """
  The SHAPE check on a close's `landed` digest, returning the message the HTTP
  door renders as a NAMED 4xx.

  Public for the same reason `check_files/1` is: the refusal has to happen at
  the door AND the store has to hold the verdict, so a direct
  `Tasks.Close.close_with_receipt/3` cannot write a digest the door would have
  refused.

    * absent / `nil` → `{:ok, nil}` (close without a landing digest)
    * a map of known keys whose values are scalars or lists of scalars →
      `{:ok, cleaned}`; blanks are dropped and a map that cleans down to
      nothing is the same as absent
    * anything else → `{:error, message}`, and NOTHING is written
  """
  @spec check_digest(term()) :: {:ok, map() | nil} | {:error, String.t()}
  def check_digest(nil), do: {:ok, nil}

  def check_digest(digest) when is_map(digest) do
    with :ok <- check_digest_keys(digest),
         {:ok, cleaned} <- clean_digest(digest) do
      if map_size(cleaned) == 0, do: {:ok, nil}, else: {:ok, cleaned}
    end
  end

  def check_digest(_),
    do: {:error, @digest_message <> "It was not a map, so NOTHING was recorded."}

  defp check_digest_keys(digest) do
    case digest |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in @digest_keys)) do
      [] ->
        :ok

      unknown ->
        {:error,
         @digest_message <>
           "These keys are not land-digest keys and would have been SILENTLY DROPPED: " <>
           Enum.map_join(Enum.sort(unknown), ", ", &inspect/1) <>
           ". The storable keys are " <>
           Enum.join(@digest_keys, ", ") <> "."}
    end
  end

  defp clean_digest(digest) do
    Enum.reduce_while(@digest_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case check_digest_value(key, Map.get(digest, key)) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp check_digest_value(_key, nil), do: {:ok, nil}

  # `files` is NOT re-implemented here — one checker, two doors, and the raw
  # value goes STRAIGHT in: wrapping a bare string into a one-element list would
  # make this door ACCEPT the exact shape `/landed` refuses, which is the drift
  # sharing the checker exists to prevent.
  defp check_digest_value("files", raw), do: check_files(raw)

  # `commit` is the SINGULAR the evidence sentence reads, so it stays a scalar.
  defp check_digest_value("commit", raw) do
    case scalar_token(raw) do
      nil -> {:error, digest_key_message("commit", "a non-empty string (a commit sha)")}
      token -> {:ok, token}
    end
  end

  # The two MAP-valued keys: `landings` pairs a pr with its commit,
  # `file_digests` is the bounded spelling of `files`. Both are lists of maps.
  defp check_digest_value(key, raw) when key in ["landings", "file_digests"] do
    entries = List.wrap(raw)

    if entries != [] and Enum.all?(entries, &is_map/1) do
      {:ok, entries}
    else
      {:error, digest_key_message(key, "a list of MAPS")}
    end
  end

  # Everything else is a scalar or a list of scalars (strings or integers).
  defp check_digest_value(key, raw) do
    entries = List.wrap(raw)

    cond do
      Enum.any?(entries, &(not is_binary(&1) and not is_integer(&1))) ->
        {:error, digest_key_message(key, "a string/number or a list of them")}

      true ->
        case entries |> Enum.map(&scalar_token/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
          [] -> {:ok, nil}
          cleaned -> {:ok, cleaned}
        end
    end
  end

  defp digest_key_message(key, expected) do
    @digest_message <>
      "#{inspect(key)} must be #{expected}; it was not, so NOTHING was recorded — " <>
      "a landed value this close cannot store is refused HERE rather than dropped " <>
      "with a 2xx that says the landing was recorded."
  end

  defp scalar_token(value) when is_integer(value), do: Integer.to_string(value)

  defp scalar_token(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp scalar_token(_), do: nil

  defp top_level_dirs(files) do
    files
    |> Enum.map(&top_level/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A path at the repo root has no dir; it gets "." so a caller reading `dirs`
  # never has to guess whether an empty string meant "root" or "we lost it".
  defp top_level(path) do
    case String.split(path, "/", parts: 2) do
      [first, _rest] when first != "" -> first
      _ -> "."
    end
  end

  defp put_landing(map, pr, commit) when is_binary(pr) and is_binary(commit),
    do: Map.put(map, "landings", [%{"pr" => pr, "commit" => commit}])

  defp put_landing(map, _pr, _commit), do: map

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

defmodule Barkpark.Tasks.StampTest do
  @moduledoc """
  Unit + integration tests for `Barkpark.Tasks.Stamp` (expressive-agent-loops
  D3/D6/D7/D8 — criterion-level mid-claim evidence).

  Covers:
    1. `--met` lands evidence atomically; other entries + the claim untouched.
    1b. D56 FAIL-CLOSED: a `--met` stamp with NO criterion text is REJECTED
       (`:criterion_text_required`) — the index alone can silently flip a
       neighbour, and it did (five of eight Wave-4 builders). A text that does
       not match the row at N is `:criteria_mismatch`, and neither writes.
    2. Evidence or nothing: a met without non-empty evidence never reaches the DB.
    3. `--miss` appends {note,ts,worker} WITHOUT flipping met — met pinned
       explicitly (never the parse default), attempts bounded to the 5 most recent.
    4. Auth: wrong worker → :not_holder; wrong epoch → :fenced_off (close's
       fence); no live claim → {:not_in_progress, status}; unknown id → :not_found.
    5. D5 integration: stamp-then-DEFAULT-path-close succeeds with identical
       evidence at close; a criterion-TEXT edit still 409s doc_changed_since_claim.
    6. A `task.criterion` mutation_event is emitted on BOTH paths in the same
       transaction, carrying the criterion_stamp payload.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Close, Criteria, Internal, Stamp}

  import Ecto.Query, only: [from: 2]

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp default_criteria do
    [
      %{"criterion" => "gate passes", "met" => false, "evidence" => ""},
      %{"criterion" => "docs updated", "met" => false, "evidence" => ""}
    ]
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => default_criteria()
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Claim through the real primitive so the lease carries a work_digest —
  # the D5 integration tests depend on the genuine claim-time stamp.
  defp claim!(doc_id, worker, scope) do
    {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    {claimed, claimed.content["claim"]["epoch"]}
  end

  defp criterion_events(doc_id) do
    from(e in MutationEvent,
      where: e.doc_id == ^doc_id and e.mutation == "task.criterion",
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  # ─── (1) --met lands evidence atomically ───────────────────────────────────

  describe "stamp/3 — met with evidence" do
    test "flips met + writes evidence on the targeted row only; claim untouched", %{scope: scope} do
      doc_id = uniq("stamp-met")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:met, "42 tests green: stamp_test.exs"}
               )

      [first, second] = stamped.content["acceptance_criteria"]
      assert first["met"] == true
      assert first["evidence"] == "42 tests green: stamp_test.exs"
      assert first["criterion"] == "gate passes", "criterion text never rewritten"
      assert second == %{"criterion" => "docs updated", "met" => false, "evidence" => ""}

      # Progress, not the seal: still in_progress, lease + epoch untouched.
      assert stamped.content["lifecycle_status"] == "in_progress"
      assert stamped.content["claim"]["worker"] == "w"
      assert stamped.content["claim"]["epoch"] == epoch
    end

    test "index out of range refuses without partial state", %{scope: scope} do
      doc_id = uniq("stamp-range")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :criteria_index_out_of_range} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 9,
                 criterion_text: "gate passes",
                 outcome: {:met, "phantom"}
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == default_criteria()
      assert criterion_events(task.doc_id) == [], "no event for a refused stamp"
    end

    # The out-of-range guard fires BEFORE the text guard can (there is no row to
    # CAS against), so an index-only out-of-range stamp still reports the honest
    # range error rather than the (also true) missing-text one.
    test "an out-of-range index with no text still reports the range error", %{scope: scope} do
      doc_id = uniq("stamp-range-notext")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :criteria_index_out_of_range} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 9,
                 outcome: {:met, "phantom"}
               )
    end
  end

  # ─── (1b) In-range wrong-index guard — FAIL CLOSED (D56) ───────────────────
  #
  # The out-of-range guard above (:criteria_index_out_of_range) only catches an
  # index PAST the end. The scar this block owns is a 1-based value passed into
  # the 0-based tool: a wrong index that IS in range used to silently flip the
  # NEIGHBOUR criterion with no error, because the criterion-TEXT CAS was
  # OPTIONAL and nothing forced it. In the wild the guard therefore never fired:
  # five of eight Wave-4 builders shifted their evidence, one of them fabricating
  # a met=true on a merge-gated criterion it could not have proven.
  #
  # So the guard now FAILS CLOSED: a met-flip with NO text is REJECTED
  # (:criterion_text_required) and a met-flip whose text does not match the row
  # at N is REJECTED (:criteria_mismatch). Neither writes anything. A miss stays
  # permissive — it flips no lock, so there is nothing to fabricate.

  defp three_criteria do
    [
      %{"criterion" => "criterion A: gate passes", "met" => false, "evidence" => ""},
      %{"criterion" => "criterion B: docs updated", "met" => false, "evidence" => ""},
      %{"criterion" => "criterion C: PR merged", "met" => false, "evidence" => ""}
    ]
  end

  describe "stamp/3 — in-range wrong-index (0-based/1-based off-by-one)" do
    # THE FIX, fail-before: the exact false-done vector — an index-only --met —
    # is now REJECTED. Before D56 this returned {:ok, …} with the NEIGHBOUR
    # flipped (the assertion below on the untouched list is what used to fail).
    test "no text guard → an in-range wrong index is REJECTED, nothing flips",
         %{scope: scope} do
      doc_id = uniq("stamp-inrange-noguard")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => three_criteria()})
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      # Intent was criterion B (index 1); a 1-based "2" lands on index 2.
      assert {:error, :criterion_text_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 2,
                 outcome: {:met, "proof for crit B"}
               )

      reloaded = Repo.get!(Document, task.id)

      assert reloaded.content["acceptance_criteria"] == three_criteria(),
             "an unguarded met-flip writes NOTHING — no neighbour is flipped"

      assert criterion_events(task.doc_id) == [], "no event for a refused stamp"
    end

    # The same refusal applies to the RIGHT index: the rule is not "guess whether
    # the index looks wrong" (unknowable), it is "a met-flip must name its
    # criterion". Otherwise the guard would still be optional in practice.
    test "no text guard → even the CORRECT index is REJECTED (the rule has no hole)",
         %{scope: scope} do
      doc_id = uniq("stamp-inrange-right-noguard")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => three_criteria()})
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :criterion_text_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:met, "proof for crit B"}
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == three_criteria()
    end

    # An off-by-one stamp that carries the INTENDED criterion's stored text is
    # REJECTED with :criteria_mismatch and writes nothing.
    test "text guard at the wrong index → :criteria_mismatch, no write", %{scope: scope} do
      doc_id = uniq("stamp-inrange-guard")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => three_criteria()})
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      # Off-by-one index 2, but the caller names criterion B (the intended one).
      assert {:error, :criteria_mismatch} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 2,
                 criterion_text: "criterion B: docs updated",
                 outcome: {:met, "proof for crit B"}
               )

      reloaded = Repo.get!(Document, task.id)

      assert reloaded.content["acceptance_criteria"] == three_criteria(),
             "a mismatched guard aborts the whole write — no partial flip"

      assert criterion_events(task.doc_id) == [], "no event for a rejected stamp"
    end

    # The text guard at the RIGHT index still succeeds — the CAS is exact-match,
    # not a blanket block.
    test "text guard at the right index → succeeds and flips it", %{scope: scope} do
      doc_id = uniq("stamp-inrange-ok")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => three_criteria()})
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: "criterion B: docs updated",
                 outcome: {:met, "proof for crit B"}
               )

      [_a, b, _c] = stamped.content["acceptance_criteria"]
      assert b["met"] == true
      assert b["evidence"] == "proof for crit B"
    end

    # A blank text guard is NOT a guard — it must not buy a free flip (the
    # trivial bypass: pass --criterion-text "" and the old code waved it through).
    test "a blank text guard is REJECTED on a met (no trivial bypass)", %{scope: scope} do
      doc_id = uniq("stamp-inrange-blank")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => three_criteria()})
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :criterion_text_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: "",
                 outcome: {:met, "proof"}
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == three_criteria()
    end

    # …and a MISS with no text still records. The guard only defends the LOCK;
    # an honest attempt has nothing to fabricate, so it must stay frictionless
    # (a miss that 409s would push agents back to batching honesty to the end).
    test "a miss with no text still records the attempt (permissive, flips nothing)",
         %{scope: scope} do
      doc_id = uniq("stamp-inrange-miss-notext")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => three_criteria()})
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "adapter smoke still red — retrying"}
               )

      [a, b, c] = stamped.content["acceptance_criteria"]
      assert b["met"] == false, "a miss never flips the lock"
      assert [%{"note" => "adapter smoke still red — retrying"}] = b["attempts"]
      assert a["met"] == false and c["met"] == false, "neighbours untouched"
    end
  end

  # ─── (2) Evidence or nothing ───────────────────────────────────────────────

  describe "stamp/3 — met REQUIRES non-empty evidence" do
    test "empty / missing / non-string evidence is rejected before any write", %{scope: scope} do
      doc_id = uniq("stamp-noev")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      for bad <- ["", nil, 42] do
        assert {:error, :evidence_required} =
                 Stamp.stamp(task.id, "w",
                   observed_epoch: epoch,
                   criterion: 0,
                   outcome: {:met, bad}
                 )
      end

      reloaded = Repo.get!(Document, task.id)
      assert [%{"met" => false} | _] = reloaded.content["acceptance_criteria"]
      assert criterion_events(task.doc_id) == []
    end

    test "a miss without a note is likewise rejected", %{scope: scope} do
      doc_id = uniq("stamp-nonote")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :note_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, ""}
               )
    end
  end

  # ─── (3) --miss: honest attempts, met never flips ──────────────────────────

  describe "stamp/3 — miss records the attempt without flipping" do
    test "appends {note,ts,worker} and PINS met explicitly to false when unset", %{scope: scope} do
      doc_id = uniq("stamp-miss")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, "sandbox flake — retrying with shared mode"}
               )

      [first | _] = stamped.content["acceptance_criteria"]

      # The proven footgun: parse/merge defaults met→true when absent. The miss
      # path must write met EXPLICITLY — assert the key is present AND false.
      assert Map.fetch!(first, "met") == false

      assert [attempt] = first["attempts"]
      assert attempt["note"] == "sandbox flake — retrying with shared mode"
      assert attempt["worker"] == "w"
      assert {:ok, _, _} = DateTime.from_iso8601(attempt["ts"])
    end

    test "a miss AFTER a met keeps the lock flipped (met stays true)", %{scope: scope} do
      doc_id = uniq("stamp-miss-after-met")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:met, "proved once"}
               )

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, "regression probe failed — investigating"}
               )

      [first | _] = stamped.content["acceptance_criteria"]
      assert first["met"] == true, "a miss never UNflips either — it only records"
      assert length(first["attempts"]) == 1
    end

    test "attempts are bounded to the 5 most recent", %{scope: scope} do
      doc_id = uniq("stamp-bound")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      for n <- 1..7 do
        assert {:ok, _} =
                 Stamp.stamp(task.id, "w",
                   observed_epoch: epoch,
                   criterion: 0,
                   outcome: {:miss, "attempt #{n}"}
                 )
      end

      [first | _] = Repo.get!(Document, task.id).content["acceptance_criteria"]
      notes = Enum.map(first["attempts"], & &1["note"])
      assert notes == ["attempt 3", "attempt 4", "attempt 5", "attempt 6", "attempt 7"]
    end
  end

  # ─── (4) Auth: holder + epoch fence ────────────────────────────────────────

  describe "stamp/3 — holder + fencing" do
    test "a non-holder cannot stamp", %{scope: scope} do
      doc_id = uniq("stamp-holder")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :not_holder} =
               Stamp.stamp(task.id, "intruder",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:met, "not mine to prove"}
               )
    end

    test "a stale epoch is fenced off exactly like close", %{scope: scope} do
      doc_id = uniq("stamp-fence")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :fenced_off} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch + 1,
                 criterion: 0,
                 outcome: {:met, "late write"}
               )

      # Recovery is close's documented path: same-worker re-claim (renewal,
      # epoch bumps) then restamp with the fresh epoch.
      {:ok, renewed} = Tasks.claim_by_id(doc_id, "w", scope)
      fresh_epoch = renewed.content["claim"]["epoch"]

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: fresh_epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:met, "restamped after renewal"}
               )
    end

    test "a task without a live claim is not stampable", %{scope: scope} do
      doc_id = uniq("stamp-unclaimed")
      task = mk_task!(doc_id, scope)

      assert {:error, {:not_in_progress, "open"}} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: 1,
                 criterion: 0,
                 outcome: {:met, "no claim yet"}
               )
    end

    test "unknown task id → :not_found" do
      assert {:error, :not_found} =
               Stamp.stamp("00000000-0000-0000-0000-000000000099", "w",
                 observed_epoch: 1,
                 criterion: 0,
                 outcome: {:met, "ghost"}
               )
    end
  end

  # ─── (5) D5 integration: stamp never fences the worker's own close ────────

  describe "stamp/3 — D5 work-digest narrowing (the close handshake)" do
    test "mid-claim stamps then the DEFAULT-path close succeeds, evidence identical at close",
         %{scope: scope} do
      doc_id = uniq("stamp-then-close")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:met, "gate output: 12 tests, 0 failures"}
               )

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "docs pending review"}
               )

      # DEFAULT path — no observed_rev. Before D5 this 409'd
      # doc_changed_since_claim on ["acceptance_criteria"] by construction.
      # Criterion 1 is an honest MISS, so the D289 criteria gate makes this
      # done-close name why it is closing over it (accept-unmet-with-a-reason).
      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: epoch,
                 lifecycle_status: "done",
                 criteria_override: "criterion 1 is an honest miss: docs pending review"
               )

      assert closed.content["lifecycle_status"] == "done"

      # No divergence: what was stamped mid-claim is EXACTLY what close sealed.
      [first, second] = closed.content["acceptance_criteria"]
      assert first["met"] == true
      assert first["evidence"] == "gate output: 12 tests, 0 failures"
      assert second["met"] == false
      assert [%{"note" => "docs pending review"}] = second["attempts"]
    end

    test "a foreign criterion-TEXT edit still trips doc_changed_since_claim", %{scope: scope} do
      doc_id = uniq("stamp-text-fence")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      # Someone rewrites a criterion's TEXT under the claim (raw CAS write that
      # preserves the claim, mirroring close_test's foreign_patch_content!).
      doc = Repo.get!(Document, task.id)

      rewritten =
        List.update_at(doc.content["acceptance_criteria"], 0, fn entry ->
          Map.put(entry, "criterion", "gate passes ON ARM64 TOO")
        end)

      new_content = Map.put(doc.content, "acceptance_criteria", rewritten)

      {1, _} =
        from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
        |> Repo.update_all(set: [content: new_content, rev: Internal.generate_rev()])

      assert {:error, {:doc_changed_since_claim, _rev, ["acceptance_criteria"]}} =
               Close.close(task.id, "w", observed_epoch: epoch, lifecycle_status: "done")
    end
  end

  # ─── (6) task.criterion mutation_event, same transaction ─────────────────

  describe "stamp/3 — task.criterion event" do
    test "both paths emit the event with the criterion_stamp payload", %{scope: scope} do
      doc_id = uniq("stamp-event")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, met_doc} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:met, "proof attached"}
               )

      assert {:ok, miss_doc} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "second lock still resists"}
               )

      assert [met_ev, miss_ev] = criterion_events(met_doc.doc_id)
      assert met_ev.mutation == Tasks.event_kinds().criterion

      assert met_ev.document["criterion_stamp"] ==
               %{"index" => 0, "result" => "met", "worker" => "w"}

      assert miss_ev.document["criterion_stamp"] ==
               %{"index" => 1, "result" => "miss", "worker" => "w"}

      # Durable-then-ack: each event row pins the post-stamp rev + previous rev,
      # written in the SAME transaction as the criteria write.
      assert met_ev.rev == met_doc.rev
      assert miss_ev.rev == miss_doc.rev
      assert miss_ev.previous_rev == met_doc.rev
    end
  end

  # ─── (7) THE MERGE-GATE REFUSAL (cch-w49) ──────────────────────────────────
  #
  # THE POINT OF THIS BLOCK IS THAT THE GUARD CAN LOSE IN BOTH DIRECTIONS.
  # It is easy to "fix" the reported false positive by weakening the guard
  # until nothing trips it, and a suite that only asserted the mention stamps
  # clean would go green on exactly that. So every permit test below is paired
  # with a refusal test over the SAME machinery, and the refusal arm asserts
  # that NOTHING was written — a guard that refuses but writes anyway is not a
  # guard.

  defp merge_gate_criteria do
    [
      %{
        "criterion" => "the mobile gate is green on the PR head",
        "met" => false,
        "evidence" => ""
      },
      # A GENUINE gate, wired by the prose convention (the shape ~1839 live
      # rows use — no flag, marker in the text).
      %{
        "criterion" => "[MERGE-GATED — the lead closes this] PR merged to main",
        "met" => false,
        "evidence" => ""
      },
      # A MENTION: prose ABOUT merge-gating, exempted structurally. This is
      # cch-w49's own criterion 0, verbatim.
      %{
        "criterion" =>
          "A criterion whose text merely MENTIONS a merge-gated row stamps met WITHOUT --merge-gated. Evidence: the stamp command and its rc.",
        "met" => false,
        "evidence" => "",
        "merge_gate" => false
      },
      # A gate carrying the FLAG but no marker wording — invisible to any
      # text-only guard (14 such rows live on the corpus).
      %{
        "criterion" => "PR merged to main with the required gates green",
        "met" => false,
        "evidence" => "",
        "merge_gate" => true
      }
    ]
  end

  defp mg_task!(scope) do
    doc_id = uniq("stamp-mg")
    task = mk_task!(doc_id, scope, %{"acceptance_criteria" => merge_gate_criteria()})
    {_claimed, epoch} = claim!(doc_id, "builder", scope)
    {task, epoch}
  end

  defp criteria_of(task_id) do
    Repo.get!(Document, task_id).content["acceptance_criteria"]
  end

  describe "stamp/3 — MERGE-GATE refusal: the guard REFUSES (cch-w49 c1)" do
    test "a genuine prose-marked gate is refused a builder --met, and NOTHING is written",
         %{scope: scope} do
      {task, epoch} = mg_task!(scope)
      text = "[MERGE-GATED — the lead closes this] PR merged to main"

      assert {:error, :merge_gated_criterion} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: text,
                 outcome: {:met, "PR #123 merged"}
               )

      row = Enum.at(criteria_of(task.id), 1)
      assert row["met"] == false, "a refused stamp must not flip the lock"
      assert row["evidence"] == "", "a refused stamp must not write evidence"
    end

    test "a FLAGGED gate whose prose never says 'merge-gated' is refused too", %{scope: scope} do
      # The arm a text-only guard silently permits. If merge_gated?/1 stopped
      # reading the flag, this reds — and only this.
      {task, epoch} = mg_task!(scope)

      assert {:error, :merge_gated_criterion} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 3,
                 criterion_text: "PR merged to main with the required gates green",
                 outcome: {:met, "merged"}
               )

      assert Enum.at(criteria_of(task.id), 3)["met"] == false
    end

    test "the LEAD override releases it and the stamp lands", %{scope: scope} do
      {task, epoch} = mg_task!(scope)
      text = "[MERGE-GATED — the lead closes this] PR merged to main"

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: text,
                 outcome: {:met, "PR #123 merged, sha an ancestor of origin/main"},
                 merge_gated: true
               )

      row = Enum.at(stamped.content["acceptance_criteria"], 1)
      assert row["met"] == true
      assert row["evidence"] =~ "#123"
    end

    test "a --miss on a gate is never refused — it flips no lock", %{scope: scope} do
      {task, epoch} = mg_task!(scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "PR not open yet"}
               )

      assert Enum.at(stamped.content["acceptance_criteria"], 1)["met"] == false
    end
  end

  describe "stamp/3 — MERGE-GATE refusal: a MENTION stamps clean (cch-w49 c0)" do
    test "a criterion that merely MENTIONS merge-gating stamps met WITHOUT --merge-gated",
         %{scope: scope} do
      {task, epoch} = mg_task!(scope)

      text =
        "A criterion whose text merely MENTIONS a merge-gated row stamps met WITHOUT --merge-gated. Evidence: the stamp command and its rc."

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 2,
                 criterion_text: text,
                 outcome: {:met, "this very test"}
               )

      row = Enum.at(stamped.content["acceptance_criteria"], 2)
      assert row["met"] == true
      assert row["evidence"] == "this very test"
    end

    test "an ordinary criterion is untouched by the guard", %{scope: scope} do
      {task, epoch} = mg_task!(scope)

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "the mobile gate is green on the PR head",
                 outcome: {:met, "gate output"}
               )
    end

    test "the guard does not pre-empt the out-of-range / mismatch taxonomy", %{scope: scope} do
      # The merge-gate check must never invent an error that belongs to
      # merge_criteria — a wrong index still reports what it always reported.
      {task, epoch} = mg_task!(scope)

      assert {:error, :criteria_index_out_of_range} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 99,
                 criterion_text: "whatever",
                 outcome: {:met, "e"}
               )

      assert {:error, :criteria_mismatch} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "not the stored wording",
                 outcome: {:met, "e"}
               )
    end
  end

  # ─── (7) THE WITHDRAWAL (D745, wave 62) ──────────────────────────────────
  #
  # The scar: a met flag that review later refutes had NO verb. `--met` only
  # raises and `--miss` only pins, so a reviewer who found a stamped proof false
  # wrote the correction into the criterion's own evidence prose —
  # "[WITHDRAWN BY WAVE REVIEW … the ledger refuses a met:true -> met:false
  # patch, so read this evidence, not the flag]" — and every board went on
  # counting the criterion MET. Twelve criteria across two live rows carry
  # exactly that today.
  #
  # These tests pin the verb AND its refusals, and each one can lose:
  #   * clear the evidence on withdrawal and the append-only test reds;
  #   * skip the withdrawals record and the signature test reds;
  #   * drop the criterion-text CAS on the lowering direction and the
  #     fail-closed test reds;
  #   * make --withdraw in_progress-only and the sealed-row test reds — which
  #     is the case that matters, because BOTH real instances are sealed rows.

  defp withdrawal_of(task_id, index) do
    task_id |> criteria_of() |> Enum.at(index) |> Map.get("withdrawals")
  end

  # A row whose criterion 0 is already stamped MET with real evidence — the
  # state every withdrawal starts from.
  defp stamped_task!(scope, worker \\ "w") do
    doc_id = uniq("stamp-withdraw")
    task = mk_task!(doc_id, scope)
    {_claimed, epoch} = claim!(doc_id, worker, scope)

    {:ok, _} =
      Stamp.stamp(task.id, worker,
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: "gate passes",
        outcome: {:met, "42 tests green: stamp_test.exs"}
      )

    {task, epoch}
  end

  describe "stamp/3 — --withdraw lowers the lock and signs the correction" do
    test "met drops to false, criteria_progress drops, and the record names who/why/when",
         %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      # THE PRE-WITHDRAWAL READ (criterion 1 of the filing: quote both).
      before = Enum.at(criteria_of(task.id), 0)
      assert before["met"] == true
      assert before["evidence"] == "42 tests green: stamp_test.exs"
      assert Map.get(before, "withdrawals") == nil

      assert Criteria.progress(%{"acceptance_criteria" => criteria_of(task.id)}) ==
               %{met: 1, total: 2}

      assert {:ok, withdrawn} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:withdraw, "review: the gate ran on the wrong branch"}
               )

      # THE POST-WITHDRAWAL READ.
      after_row = Enum.at(withdrawn.content["acceptance_criteria"], 0)
      assert after_row["met"] == false, "the lock is LOWERED — this is the whole point"

      # THE APPEND-ONLY GUARANTEE: the original stamp is still exactly where it
      # was written, still readable. A withdrawal ADDS; it never clears.
      assert after_row["evidence"] == "42 tests green: stamp_test.exs"
      assert after_row["criterion"] == "gate passes"

      assert [record] = after_row["withdrawals"]
      assert record["worker"] == "w"
      assert record["note"] == "review: the gate ran on the wrong branch"
      assert {:ok, _, _} = DateTime.from_iso8601(record["ts"])

      # The superseded proof is snapshotted ON the record too, so it stays
      # legible even if the criterion is later re-stamped over.
      assert record["superseded_evidence"] == "42 tests green: stamp_test.exs"

      # Progress DROPPED — the board stops lying without anybody reading prose.
      assert Criteria.progress(%{"acceptance_criteria" => criteria_of(task.id)}) ==
               %{met: 0, total: 2}

      # Neighbours and the claim are untouched.
      assert Enum.at(withdrawn.content["acceptance_criteria"], 1) ==
               %{"criterion" => "docs updated", "met" => false, "evidence" => ""}

      assert withdrawn.content["claim"]["epoch"] == epoch
    end

    test "a re-stamp after a withdrawal keeps the withdrawal readable, and a second withdrawal appends",
         %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      {:ok, _} =
        Stamp.stamp(task.id, "w",
          observed_epoch: epoch,
          criterion: 0,
          criterion_text: "gate passes",
          outcome: {:withdraw, "first: wrong branch"}
        )

      {:ok, _} =
        Stamp.stamp(task.id, "w",
          observed_epoch: epoch,
          criterion: 0,
          criterion_text: "gate passes",
          outcome: {:met, "re-run on the right branch: 42 green"}
        )

      {:ok, _} =
        Stamp.stamp(task.id, "w",
          observed_epoch: epoch,
          criterion: 0,
          criterion_text: "gate passes",
          outcome: {:withdraw, "second: the re-run was vacuous"}
        )

      # UNBOUNDED and ORDERED. `attempts` is capped at 5 because it is chatter;
      # a withdrawal is a correction, and silently dropping a correction is the
      # defect this verb exists to end.
      assert [first, second] = withdrawal_of(task.id, 0)
      assert first["note"] == "first: wrong branch"
      assert second["note"] == "second: the re-run was vacuous"

      # Each record snapshots the evidence IT superseded — not the latest one.
      assert first["superseded_evidence"] == "42 tests green: stamp_test.exs"
      assert second["superseded_evidence"] == "re-run on the right branch: 42 green"
      assert Enum.at(criteria_of(task.id), 0)["met"] == false
    end

    test "the event is emitted with result=withdrawn and a withdrawn marker", %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      {:ok, _} =
        Stamp.stamp(task.id, "w",
          observed_epoch: epoch,
          criterion: 0,
          criterion_text: "gate passes",
          outcome: {:withdraw, "review refuted it"}
        )

      payload =
        task.doc_id
        |> criterion_events()
        |> List.last()
        |> Map.get(:document)
        |> Map.get("criterion_stamp")

      assert payload["result"] == "withdrawn"
      assert payload["withdrawn"] == true
      assert payload["index"] == 0
      assert payload["worker"] == "w"
    end
  end

  describe "stamp/3 — --withdraw refusals (each one writes NOTHING)" do
    test "no criterion text → :criterion_text_required, exactly as a met-flip",
         %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      assert {:error, :criterion_text_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:withdraw, "no text passed"}
               )

      # Lowering the WRONG neighbour is as much a lie as raising it, so the
      # guard is symmetric — and nothing moved.
      assert Enum.at(criteria_of(task.id), 0)["met"] == true
      assert withdrawal_of(task.id, 0) == nil
    end

    test "a text that does not match the row at N → :criteria_mismatch", %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      assert {:error, :criteria_mismatch} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "docs updated",
                 outcome: {:withdraw, "wrong index"}
               )

      assert Enum.at(criteria_of(task.id), 0)["met"] == true
    end

    test "an empty note → :note_required (a withdrawal without a why is a silent un-flip)",
         %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      assert {:error, :note_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:withdraw, ""}
               )

      assert Enum.at(criteria_of(task.id), 0)["met"] == true
    end

    test "withdrawing an already-unmet criterion → :criterion_not_met", %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      assert {:error, :criterion_not_met} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: "docs updated",
                 outcome: {:withdraw, "there is nothing here to withdraw"}
               )

      assert withdrawal_of(task.id, 1) == nil,
             "a retraction of nothing would only mislead the next reader"
    end

    test "a live claim still fences a withdrawal: wrong worker and wrong epoch both refuse",
         %{scope: scope} do
      {task, epoch} = stamped_task!(scope)

      assert {:error, :not_holder} =
               Stamp.stamp(task.id, "someone-else",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:withdraw, "not mine to withdraw"}
               )

      assert {:error, :fenced_off} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch + 7,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:withdraw, "stale epoch"}
               )

      assert Enum.at(criteria_of(task.id), 0)["met"] == true
    end
  end

  # ─── (7b) THE SEALED ROW — the case the whole verb exists for ────────────
  #
  # Both live instances of the class are CLOSED rows: cch-w58-s2 (done) and
  # arpss-share-link-object-authz-close (cancelled). A withdrawal that
  # inherited stamp's `in_progress`-and-holder-only fence could not correct a
  # single one of them, so off the in_progress arm the fence is the rev the
  # caller read instead. These tests red if that path is removed.

  describe "stamp/3 — --withdraw on a SEALED row (no claim to fence against)" do
    defp sealed_task!(scope) do
      {task, epoch} = stamped_task!(scope)

      {:ok, closed} =
        Close.close(task.id, "w",
          observed_epoch: epoch,
          lifecycle_status: "done",
          criteria_override: "closing with criterion 1 unmet on purpose"
        )

      # THE PREMISE these tests rest on, asserted rather than assumed: a closed
      # row still CARRIES its claim, but as a RECEIPT (`closed_at` stamped on
      # it), not as a live lease. So "does a claim exist" is the wrong question
      # — branching on it would make a reviewer impersonate the departed holder
      # to withdraw that holder's own refuted proof. Liveness is the question,
      # and the lifecycle answers it.
      assert closed.content["claim"]["closed_at"] != nil
      assert closed.content["claim"]["worker"] == "w"
      assert closed.content["lifecycle_status"] == "done"
      {task, closed}
    end

    test "without --observed-rev it is refused, naming the read it needs", %{scope: scope} do
      {task, _closed} = sealed_task!(scope)

      assert {:error, :observed_rev_required} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:withdraw, "review refuted the proof"}
               )

      assert Enum.at(criteria_of(task.id), 0)["met"] == true
    end

    test "a stale rev is refused — you cannot correct a row you did not read", %{scope: scope} do
      {task, _closed} = sealed_task!(scope)

      assert {:error, :stale_claim} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: "gate passes",
                 observed_rev: "not-the-rev-you-read",
                 outcome: {:withdraw, "review refuted the proof"}
               )

      assert Enum.at(criteria_of(task.id), 0)["met"] == true
    end

    test "with the rev it read, the withdrawal lands and the SEAL is untouched",
         %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      # Bound, then asserted on a BOOLEAN: `assert pattern = expr, msg` raises
      # MatchError inside the match before assert/2 ever sees the message, so
      # the message would be dead code (scripts/unreachable-assert-message-check).
      raise_on_sealed_row =
        Stamp.stamp(task.id, "reviewer",
          observed_epoch: 0,
          criterion: 1,
          criterion_text: "docs updated",
          outcome: {:met, "a --met on a sealed row is still refused"}
        )

      assert raise_on_sealed_row == {:error, {:not_in_progress, "done"}},
             "the seal still refuses a RAISE — only the lowering verb is exempt"

      assert {:ok, doc} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: "gate passes",
                 observed_rev: closed.rev,
                 outcome: {:withdraw, "WITHDRAWN BY REVIEW: the gate ran on the wrong branch"}
               )

      row = Enum.at(doc.content["acceptance_criteria"], 0)
      assert row["met"] == false
      assert row["evidence"] == "42 tests green: stamp_test.exs", "append-only, still"
      assert [%{"worker" => "reviewer"} = rec] = row["withdrawals"]
      assert rec["note"] =~ "WITHDRAWN BY REVIEW"

      # And note WHO: "reviewer", not the holder "w" whose proof this refutes.
      # A correction is signed by the person making it.
      assert closed.content["claim"]["worker"] == "w"

      # The seal itself is NOT rewritten: lifecycle, close_reason and the
      # closed-ness of the row all survive a post-hoc correction.
      assert doc.content["lifecycle_status"] == "done"
      assert doc.content["close_reason"] == closed.content["close_reason"]

      assert doc.content["claim"] == closed.content["claim"],
             "the close receipt is not rewritten by a later correction"
    end
  end

  # ─── (7c) A MERGE GATE can be withdrawn without the lead-only override ────

  describe "stamp/3 — --withdraw and the merge gate" do
    test "a merge-gated criterion is withdrawable with no --merge-gated", %{scope: scope} do
      {task, epoch} = mg_task!(scope)
      text = "[MERGE-GATED — the lead closes this] PR merged to main"

      # Raise it as the lead would, then let a reviewer refute it.
      {:ok, _} =
        Stamp.stamp(task.id, "builder",
          observed_epoch: epoch,
          criterion: 1,
          criterion_text: text,
          merge_gated: true,
          outcome: {:met, "PR #123 merged"}
        )

      assert {:ok, doc} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: text,
                 outcome: {:withdraw, "the PR was closed, not merged"}
               )

      row = Enum.at(doc.content["acceptance_criteria"], 1)
      assert row["met"] == false
      assert [%{"note" => "the PR was closed, not merged"}] = row["withdrawals"]
    end
  end

  # ─── (7d) THE SILENT UN-FLIP IS STILL REFUSED ────────────────────────────
  #
  # The withdrawal is NOT a licence to un-flip. The write surface still offers
  # no way to send a bare met:true -> met:false patch: `parse_stamp` accepts
  # exactly one of --met / --miss / --withdraw, and a body carrying met=false
  # names no verb at all. This test is what keeps the fix from becoming the
  # hole it was built to close.

  describe "the wire surface still refuses a bare met:true -> met:false patch" do
    alias BarkparkWeb.TasksController.Params

    test "a body with met=false names no verb and is a 400, not an un-flip" do
      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{"criterion" => "0", "met" => "false"})

      assert msg =~ "--withdraw"
      assert msg =~ "met:true -> met:false"
    end

    test "met=false with evidence is still refused — evidence does not buy a lower" do
      assert {:error, :invalid_stamp, _} =
               Params.parse_stamp(%{
                 "criterion" => "0",
                 "met" => false,
                 "evidence" => "[WITHDRAWN BY WAVE REVIEW]"
               })
    end

    test "--withdraw parses to the withdraw outcome and requires a note" do
      assert {:ok, 0, {:withdraw, "why"}, "the text"} =
               Params.parse_stamp(%{
                 "criterion" => "0",
                 "withdraw" => "true",
                 "note" => "why",
                 "criterion-text" => "the text"
               })

      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{"criterion" => "0", "withdraw" => "true"})

      assert msg =~ "--withdraw requires non-empty --note"
    end

    test "two verbs at once are refused" do
      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{
                 "criterion" => "0",
                 "met" => "true",
                 "withdraw" => "true",
                 "evidence" => "e",
                 "note" => "n"
               })

      assert msg =~ "not two"
    end
  end

  # ─── (8) THE POST-CLOSE ATTEMPT — task-d68754135a6a9f66 ──────────────────
  #
  # THE MEASURED DEFECT. A closer who has legitimately verified something about
  # a SEALED row had no sanctioned per-criterion write: every stamp came back
  # `not_in_progress:done`, so they reached for a raw /v1/data/mutate that
  # pastes ONE evidence string across every remaining criterion. Roughly 43-57
  # tasks and 95-130 criteria carry that shape, and one row confesses it in its
  # own evidence blob ("stamp failed on already-closed task, criteria corrected
  # via mutate").
  #
  # THE CURE, AND ITS EXACT BOUNDARY. `--miss` — and ONLY `--miss` — is admitted
  # on a terminal row, on the withdrawal's observed_rev fence. Each of these
  # tests can lose:
  #   * delete the terminal-miss authorize clause and the landing test reds;
  #   * widen the exemption to `--met` and the refusal test reds;
  #   * remove the met-pinning line in Internal.apply_entry_update and the
  #     malformed-met test reds;
  #   * let the attempt path write evidence and the byte-identity test reds;
  #   * drop the observed_rev CAS and both refusal tests red.

  alias Barkpark.Tasks.WorkDigest

  # A task closed into `status`, with whatever criteria the case needs. Returns
  # {task, closed_doc} — the closed doc carries the rev an annotator must pin.
  defp closed_task!(scope, criteria, status \\ "done") do
    doc_id = uniq("stamp-postclose")
    task = mk_task!(doc_id, scope, %{"acceptance_criteria" => criteria})
    {_claimed, epoch} = claim!(doc_id, "closer", scope)

    {:ok, closed} =
      Close.close(task.id, "closer",
        observed_epoch: epoch,
        lifecycle_status: status,
        criteria_override: "closing with criteria unproven on purpose",
        # A `cancelled` close needs a reason (task-650d7844d8fe7199) — on a
        # cancel every other close gate is exempt by name, so the reason is the
        # entire record. `done` ignores it here; passing it unconditionally
        # keeps this fixture one shape rather than two.
        reason: "closed by the stamp test fixture, in state #{status}"
      )

    assert closed.content["lifecycle_status"] == status
    {task, closed}
  end

  defp attempts_of(task_id, index) do
    task_id |> criteria_of() |> Enum.at(index) |> Map.get("attempts")
  end

  describe "stamp/3 — --miss on a DONE row (the sanctioned post-close instrument)" do
    test "the attempt lands with the rev the caller read, and --met on the SAME row is still refused",
         %{scope: scope} do
      {task, closed} = closed_task!(scope, default_criteria())

      # THE REFUSAL FIRST — bound then asserted on a boolean, because
      # `assert pattern = expr, msg` would raise MatchError before assert/2
      # ever sees the message (scripts/unreachable-assert-message-check).
      met_on_sealed =
        Stamp.stamp(task.id, "reconciler",
          observed_epoch: 0,
          criterion: 0,
          criterion_text: "gate passes",
          observed_rev: closed.rev,
          outcome: {:met, "verified CI-green + merged after the close"}
        )

      assert met_on_sealed == {:error, {:not_in_progress, "done"}},
             "the seal still refuses a RAISE even WITH the rev — only the attempt shape is exempt"

      assert {:ok, doc} =
               Stamp.stamp(task.id, "reconciler",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 outcome: {:miss, "post-close read: the gate log is gone, this stays unproven"}
               )

      row = Enum.at(doc.content["acceptance_criteria"], 0)
      assert [attempt] = row["attempts"]
      assert attempt["note"] == "post-close read: the gate log is gone, this stays unproven"
      assert attempt["worker"] == "reconciler"
      assert {:ok, _, _} = DateTime.from_iso8601(attempt["ts"])

      # The seal itself is untouched: still done, same close_reason, same claim
      # receipt. An attempt records an observation ABOUT the verdict, never the
      # verdict.
      assert doc.content["lifecycle_status"] == "done"
      assert doc.content["close_reason"] == closed.content["close_reason"]
      assert doc.content["claim"] == closed.content["claim"]
    end

    test "a CANCELLED row behaves exactly like a done one — the label does not change the harm",
         %{scope: scope} do
      {task, closed} = closed_task!(scope, default_criteria(), "cancelled")

      assert {:ok, _} =
               Stamp.stamp(task.id, "reconciler",
                 observed_epoch: 0,
                 criterion: 1,
                 observed_rev: closed.rev,
                 outcome: {:miss, "cancelled before this was attempted"}
               )

      assert [%{"note" => "cancelled before this was attempted"}] = attempts_of(task.id, 1)

      met_on_cancelled =
        Stamp.stamp(task.id, "reconciler",
          observed_epoch: 0,
          criterion: 1,
          criterion_text: "docs updated",
          observed_rev: closed.rev,
          outcome: {:met, "no"}
        )

      assert met_on_cancelled == {:error, {:not_in_progress, "cancelled"}}
    end

    test "an OPEN row is NOT admitted — it can still be claimed, so nothing is missing there",
         %{scope: scope} do
      doc_id = uniq("stamp-postclose-open")
      task = mk_task!(doc_id, scope)
      open_doc = Repo.get!(Document, task.id)

      miss_on_open =
        Stamp.stamp(task.id, "reconciler",
          observed_epoch: 0,
          criterion: 0,
          observed_rev: open_doc.rev,
          outcome: {:miss, "not sealed, so claim it"}
        )

      assert miss_on_open == {:error, {:not_in_progress, "open"}},
             "the exemption is TERMINAL-only; widening it to open would skip the claim entirely"

      assert attempts_of(task.id, 0) == nil
    end
  end

  describe "stamp/3 — the post-close attempt CANNOT flip a lock (criterion 2 of the row)" do
    test "a stored met=TRUE stays true", %{scope: scope} do
      criteria = [
        %{"criterion" => "gate passes", "met" => true, "evidence" => "42 green on abc123"},
        %{"criterion" => "docs updated", "met" => false, "evidence" => ""}
      ]

      {task, closed} = closed_task!(scope, criteria)

      assert {:ok, doc} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 outcome: {:miss, "re-read post-close; the run link 404s now"}
               )

      row = Enum.at(doc.content["acceptance_criteria"], 0)

      assert row["met"] == true,
             "an attempt PINS met to its stored value — it may not LOWER a sealed verdict either"

      assert length(row["attempts"]) == 1
    end

    test "a stored met=FALSE stays false", %{scope: scope} do
      {task, closed} = closed_task!(scope, default_criteria())

      assert {:ok, doc} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 1,
                 observed_rev: closed.rev,
                 outcome: {:miss, "still unproven after the close"}
               )

      row = Enum.at(doc.content["acceptance_criteria"], 1)

      assert row["met"] == false,
             "the merge default met->true is never inherited (D8's proven lock-flipping footgun)"
    end

    test "an ABSENT/malformed met normalises to FALSE, never to true", %{scope: scope} do
      # The case that makes the pinning line load-bearing: with the line
      # removed, a stored met=true and a stored met=false both survive
      # untouched, and only THIS row can tell you the guard is gone.
      criteria = [
        %{"criterion" => "no met key at all", "evidence" => "prose only"},
        %{"criterion" => "met is a string", "met" => "true", "evidence" => ""}
      ]

      {task, closed} = closed_task!(scope, criteria)

      assert {:ok, doc} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 outcome: {:miss, "absent met"}
               )

      assert Enum.at(doc.content["acceptance_criteria"], 0)["met"] == false,
             "an absent met normalises to FALSE — a post-close attempt may not manufacture a done"

      fresh = Repo.get!(Document, task.id)

      assert {:ok, doc2} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 1,
                 observed_rev: fresh.rev,
                 outcome: {:miss, "string met"}
               )

      assert Enum.at(doc2.content["acceptance_criteria"], 1)["met"] == false,
             ~s|a stored "true" STRING is not a met — only the boolean true is|
    end
  end

  describe "stamp/3 — a post-close attempt leaves evidence and criterion text BYTE-unchanged" do
    test "every criterion's evidence and text survive the attempt byte for byte", %{scope: scope} do
      criteria = [
        %{"criterion" => "gate passes", "met" => true, "evidence" => "42 green on abc123"},
        %{"criterion" => "docs updated", "met" => false, "evidence" => "half-written note"},
        # This row used to read "  spacing  and  ünicode  ", with padding spaces.
        # `Tasks.Validation` now refuses a criterion that begins or ends with
        # whitespace (pds-bl-stamp-trailing-newline-deadend: that wording is the
        # CAS key a met-flip is guarded by, and the shells that carry it strip
        # trailing whitespace, so it could be refused but never stamped), which
        # made this fixture uncreatable. The PADDING was never what this test is
        # about — INTERIOR double spaces and a non-ASCII byte still carry the
        # whole byte-preservation payload, and the evidence string keeps its own
        # leading ellipsis. Only the outer padding is gone.
        %{"criterion" => "spacing  and  ünicode", "met" => false, "evidence" => "…ok"}
      ]

      {task, closed} = closed_task!(scope, criteria)
      before_rows = criteria_of(task.id)

      assert {:ok, _} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 outcome:
                   {:miss, "an attempt writes NO evidence — that is the whole safety argument"}
               )

      after_rows = criteria_of(task.id)

      # BYTE identity, asserted directly and per field. Evidence overwriting on
      # the met path is exactly what makes the met path unsafe after close, so
      # the attempt path is held to the opposite standard explicitly rather
      # than by reading apply_entry_update.
      assert Enum.map(before_rows, & &1["evidence"]) == Enum.map(after_rows, & &1["evidence"])
      assert Enum.map(before_rows, & &1["criterion"]) == Enum.map(after_rows, & &1["criterion"])

      # And the untouched neighbours are whole-map identical — no key gained,
      # no key lost, only index 0 grew an attempts list.
      assert Enum.at(before_rows, 1) == Enum.at(after_rows, 1)
      assert Enum.at(before_rows, 2) == Enum.at(after_rows, 2)

      assert Map.delete(Enum.at(after_rows, 0), "attempts") == Enum.at(before_rows, 0)
    end

    test "(c) close's work-digest fence is UNAFFECTED — asserted, not assumed", %{scope: scope} do
      {task, closed} = closed_task!(scope, default_criteria())
      before_doc = Repo.get!(Document, task.id)
      before_digests = WorkDigest.field_digests(before_doc.title, before_doc.content)

      assert {:ok, _} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 outcome: {:miss, "post-close annotation"}
               )

      after_doc = Repo.get!(Document, task.id)

      # D5 already reduces acceptance_criteria to its criterion TEXTS before
      # hashing, so an appended attempt is invisible to the digest. That is a
      # PROPERTY, so it is tested rather than inherited from a comment.
      assert WorkDigest.field_digests(after_doc.title, after_doc.content) == before_digests

      assert WorkDigest.changed_fields(before_digests, after_doc.title, after_doc.content) == [],
             "a post-close attempt is not a work-definition edit and must not read as one"
    end
  end

  describe "stamp/3 — the post-close attempt's fence and its event" do
    test "no --observed-rev → :observed_rev_required, and nothing is written", %{scope: scope} do
      {task, _closed} = closed_task!(scope, default_criteria())

      assert {:error, :observed_rev_required} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 0,
                 outcome: {:miss, "no rev pinned"}
               )

      assert attempts_of(task.id, 0) == nil
    end

    test "a stale --observed-rev → :stale_claim: you cannot annotate a row you did not read",
         %{scope: scope} do
      {task, _closed} = closed_task!(scope, default_criteria())

      assert {:error, :stale_claim} =
               Stamp.stamp(task.id, "sweeper",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: "not-the-rev-you-read",
                 outcome: {:miss, "stale"}
               )

      assert attempts_of(task.id, 0) == nil
    end

    test "the worker id is NOT checked against the closed row's claim receipt", %{scope: scope} do
      {task, closed} = closed_task!(scope, default_criteria())

      # The row's receipt names "closer". A holder test here would force the
      # annotator to type that id — impersonating them to record an observation
      # about their row. Liveness picks the arm, exactly as D745 decided.
      assert closed.content["claim"]["worker"] == "closer"

      assert {:ok, _} =
               Stamp.stamp(task.id, "somebody-entirely-else",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 outcome: {:miss, "signed by whoever actually looked"}
               )

      assert [%{"worker" => "somebody-entirely-else"}] = attempts_of(task.id, 0)
    end

    test "(d) the event carries post_close=true so boards do not render it as live progress",
         %{scope: scope} do
      {task, closed} = closed_task!(scope, default_criteria())

      {:ok, _} =
        Stamp.stamp(task.id, "sweeper",
          observed_epoch: 0,
          criterion: 0,
          observed_rev: closed.rev,
          outcome: {:miss, "annotated after close"}
        )

      payload =
        task.doc_id
        |> criterion_events()
        |> List.last()
        |> Map.get(:document)
        |> Map.get("criterion_stamp")

      assert payload["result"] == "miss"
      assert payload["post_close"] == true
      assert payload["worker"] == "sweeper"
      assert payload["index"] == 0
    end

    test "a MID-CLAIM miss carries NO post_close marker — the flag discriminates", %{scope: scope} do
      doc_id = uniq("stamp-midclaim-marker")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      {:ok, _} =
        Stamp.stamp(task.id, "w",
          observed_epoch: epoch,
          criterion: 0,
          outcome: {:miss, "live progress"}
        )

      payload =
        task.doc_id
        |> criterion_events()
        |> List.last()
        |> Map.get(:document)
        |> Map.get("criterion_stamp")

      assert payload["result"] == "miss"

      assert Map.get(payload, "post_close") == nil,
             "a marker present on BOTH shapes would discriminate nothing"
    end

    test "(b) the attempts bound stays SHARED at 5 across mid-claim and post-close attempts",
         %{scope: scope} do
      doc_id = uniq("stamp-bound")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      for n <- 1..4 do
        {:ok, _} =
          Stamp.stamp(task.id, "w",
            observed_epoch: epoch,
            criterion: 0,
            outcome: {:miss, "mid-claim #{n}"}
          )
      end

      {:ok, closed} =
        Close.close(task.id, "w",
          observed_epoch: epoch,
          lifecycle_status: "done",
          criteria_override: "closing unproven"
        )

      {:ok, _} =
        Stamp.stamp(task.id, "sweeper",
          observed_epoch: 0,
          criterion: 0,
          observed_rev: closed.rev,
          outcome: {:miss, "post-close 5"}
        )

      notes = task.id |> attempts_of(0) |> Enum.map(& &1["note"])
      assert notes == ["mid-claim 1", "mid-claim 2", "mid-claim 3", "mid-claim 4", "post-close 5"]

      # The 6th evicts the OLDEST — one shared FIFO of 5, deliberately: a
      # separate post-close bucket is a second list every board must learn, and
      # evicting a builder's five real attempts would take five separate
      # post-close sweeps over this one criterion.
      fresh = Repo.get!(Document, task.id)

      {:ok, _} =
        Stamp.stamp(task.id, "sweeper",
          observed_epoch: 0,
          criterion: 0,
          observed_rev: fresh.rev,
          outcome: {:miss, "post-close 6"}
        )

      assert task.id |> attempts_of(0) |> Enum.map(& &1["note"]) ==
               ["mid-claim 2", "mid-claim 3", "mid-claim 4", "post-close 5", "post-close 6"]
    end
  end
end

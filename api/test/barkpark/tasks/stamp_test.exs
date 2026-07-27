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
  alias Barkpark.Tasks.{Close, Internal, Stamp}

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
end

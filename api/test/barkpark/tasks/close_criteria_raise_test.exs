defmodule Barkpark.Tasks.CloseCriteriaRaiseTest do
  @moduledoc """
  A CANCEL MAY ABANDON ACCEPTANCE CRITERIA. IT MAY NEVER ASSERT THEM.
  (task-8ca0bd7a8ed50f14 — main's ruling, verbatim.)

  Every honesty gate on the close path exempts `cancelled` and `blocked` BY
  NAME. That is correct for the REQUIRING half: abandoning acceptance criteria
  is what cancelling MEANS. It was silently also true of the WRITING half — the
  same command that abandons a row could flip a criterion to met on its way out,
  and the exemption removed the only thing that was stopping it.

  MEASURED ON THE LIVE SERVER, 2026-09-08, three runs on three disposable rows,
  each carrying one `"merge_gate" => true` criterion and no carrier PR:

    * `close … done      --set criteria:=[{index:0,met:true,…}]` → EXIT 5, but
      refused only INCIDENTALLY, by the D289 gate counting unmet criteria
      ("criteria flipped in this very close command do not count — that would be
      the closer grading its own homework"). Nothing on that path knew the
      criterion was a gate.
    * `close … cancelled --set criteria:=[…]` → EXIT 0. Read back: met=true,
      merge_gate=true, lifecycle cancelled, no override and no autostamp trace
      of any kind (row task-64774d99b1ebd6b5).
    * `close … blocked   --set criteria:=[…]` → EXIT 0. Identical (row
      task-da353d0802b19ad7). TWO lifecycles, ONE code path, so ONE predicate.

  THE CONTRAST THAT MAKES IT A DEFECT AND NOT A DESIGN: on the SAME declared
  gate with the SAME absent carrier PR, `bp task stamp --met` refuses at exit 5
  and names its own detector, while the cancel flipped the IDENTICAL BIT at exit
  0 and said nothing. One door guarded and loud, the other unguarded and silent,
  both writing the same field.

  WHAT THIS FILE PINS, and the second half is the half that can rot:

    1. the raise is REFUSED on both abandon lifecycles, by name, ahead of the
       write, with nothing written; and
    2. NOTHING ELSE ABOUT CANCELLING GOT HARDER. A cancel over UNMET criteria
       still lands (D289 exemption intact). A cancel that LOWERS met, CLEARS
       evidence or EDITS criterion text still lands. A cancel that names an
       ALREADY-met criterion still lands, because re-asserting a stored true is
       not a raise. A patch that reds any of those is the wrong fix, and the
       row's own criterion 2 says so.

  THE RAISE GATE IS NOT SCOPED TO MERGE GATES. The criterion that made this
  measurable was one, but the principle is about the LIFECYCLE: a cancelled row
  asserting ANY criterion it never proved is the same lie in a smaller font.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Close

  @dataset "production"
  @receipt_key "merge_gate_autostamp"

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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @plain_text "unit tests green"
  @gate_text "MERGE GATE: PR merged to origin/main"
  @evidence "PR #14383 merged, sha 63b89bef30 an ancestor of origin/main"

  defp criteria do
    [
      %{"criterion" => @plain_text, "met" => false, "evidence" => "", "merge_gate" => false},
      %{"criterion" => @gate_text, "met" => false, "evidence" => "", "merge_gate" => true}
    ]
  end

  defp claimed!(prefix, scope, overrides \\ []) do
    doc_id = uniq(prefix)

    rows = Keyword.get(overrides, :criteria, criteria())

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => rows
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc_id, "builder", scope)
    {doc, claimed.content["claim"]["epoch"]}
  end

  defp stored(task_id), do: Repo.get!(Document, task_id).content
  defp met_at(content, i), do: Enum.at(content["acceptance_criteria"], i)["met"]

  # ─── THE REFUSAL, ON BOTH ABANDON LIFECYCLES ───────────────────────────────
  #
  # THE NEGATIVE ARM the row demands, and it is mutation-proved rather than
  # asserted: with `check_criteria_raise/3` removed from the `with` chain in
  # `Tasks.Close`, every `assert {:error, ...}` here reds with
  # `right: {:ok, %Document{}}` and the paired `stored/1` reads flip to
  # met=true on a terminal row — which IS the measured pre-fix behaviour quoted
  # in the moduledoc, reproduced in-process.

  describe "a close that ABANDONS the work may not assert its criteria" do
    for status <- ~w(cancelled blocked) do
      @status status

      test "a #{status} close that RAISES a declared merge gate is refused, and writes nothing",
           %{scope: scope} do
        {task, epoch} = claimed!("raise-gate-#{@status}", scope)

        assert {:error, {:criteria_raised_on_abandon, [1]}} =
                 Close.close(task.id, "builder",
                   observed_epoch: epoch,
                   lifecycle_status: @status,
                   reason: "abandoning this row",
                   criteria: [
                     %{
                       "index" => 1,
                       "met" => true,
                       "evidence" => @evidence,
                       "criterion" => @gate_text
                     }
                   ]
                 )

        content = stored(task.id)

        # The refusal is upstream of the SINGLE rev-CAS write, so a refused
        # close leaves the row exactly as it was — not half-closed with the
        # criterion flipped, which would be strictly worse than the bug.
        assert content["lifecycle_status"] == "in_progress",
               "a refused close must not have moved the lifecycle"

        assert met_at(content, 1) == false,
               "the criterion this close tried to assert must still read unmet"

        refute Map.has_key?(content, @receipt_key)
      end

      test "a #{status} close that raises a PLAIN criterion is refused too — the gate keys on the lifecycle, not the marker",
           %{scope: scope} do
        {task, epoch} = claimed!("raise-plain-#{@status}", scope)

        assert {:error, {:criteria_raised_on_abandon, [0]}} =
                 Close.close(task.id, "builder",
                   observed_epoch: epoch,
                   lifecycle_status: @status,
                   reason: "abandoning this row",
                   criteria: [
                     %{
                       "index" => 0,
                       "met" => true,
                       "evidence" => "42 tests green",
                       "criterion" => @plain_text
                     }
                   ]
                 )

        assert met_at(stored(task.id), 0) == false
      end

      test "a #{status} close naming EVERY index reports every raised index, not just the first",
           %{scope: scope} do
        {task, epoch} = claimed!("raise-many-#{@status}", scope)

        assert {:error, {:criteria_raised_on_abandon, [0, 1]}} =
                 Close.close(task.id, "builder",
                   observed_epoch: epoch,
                   lifecycle_status: @status,
                   reason: "abandoning this row",
                   criteria: [
                     %{
                       "index" => 0,
                       "met" => true,
                       "evidence" => "42 tests green",
                       "criterion" => @plain_text
                     },
                     %{
                       "index" => 1,
                       "met" => true,
                       "evidence" => @evidence,
                       "criterion" => @gate_text
                     }
                   ]
                 )
      end
    end

    # A TEXT-KEYED ENTRY IS THE SAME WRITE. The predicate is a met-bit DIFF over
    # the merged result, not a scan of the payload's shape, so dropping the
    # index and keying by wording — the authoring rubric shape `merge_criteria/2`
    # also accepts — cannot route around it. A shape-keyed guard would have
    # missed this one and looked identical in review.
    test "a text-keyed raise is refused, exactly as the indexed one is", %{scope: scope} do
      {task, epoch} = claimed!("raise-textkeyed", scope)

      assert {:error, {:criteria_raised_on_abandon, [1]}} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "abandoning this row",
                 criteria: [
                   %{"criterion" => @gate_text, "met" => true, "evidence" => @evidence}
                 ]
               )

      assert met_at(stored(task.id), 1) == false
    end

    # THE MALFORMED PAYLOAD KEEPS ITS OWN ERROR. `check_criteria_payload/2` runs
    # FIRST on purpose: a caller whose index is out of range must hear about the
    # index, never "you tried to assert on a cancel" — a refusal that names the
    # wrong cause is the defect this whole row is about, one layer up.
    test "an out-of-range index still reports the INDEX, not the raise", %{scope: scope} do
      {task, epoch} = claimed!("raise-precedence", scope)

      assert {:error, :criteria_index_out_of_range} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "abandoning this row",
                 criteria: [
                   %{"index" => 9, "met" => true, "evidence" => @evidence, "criterion" => "x"}
                 ]
               )
    end
  end

  # ─── NOTHING ELSE ABOUT CANCELLING GOT HARDER ──────────────────────────────
  #
  # The row's criterion 2, as tests. Each of these PASSED before the gate and
  # must still pass after it; together they are the evidence that the fix is
  # scoped to RAISING and did not quietly tighten the exemptions.

  describe "every existing exemption survives" do
    for status <- ~w(cancelled blocked) do
      @status status

      test "a #{status} close over wholly UNMET criteria still lands (the D289 exemption)",
           %{scope: scope} do
        {task, epoch} = claimed!("exempt-unmet-#{@status}", scope)

        assert {:ok, _} =
                 Close.close(task.id, "builder",
                   observed_epoch: epoch,
                   lifecycle_status: @status,
                   reason: "superseded — nothing here was proven and that is the point"
                 )

        content = stored(task.id)
        assert content["lifecycle_status"] == @status
        assert met_at(content, 0) == false
        assert met_at(content, 1) == false
      end
    end

    test "a cancelled close that LOWERS a met criterion still lands", %{scope: scope} do
      lowered =
        List.update_at(criteria(), 0, &Map.merge(&1, %{"met" => true, "evidence" => "green"}))

      {task, epoch} = claimed!("exempt-lower", scope, criteria: lowered)

      assert {:ok, _} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "withdrawing a claim I could not stand behind",
                 criteria: [
                   %{"index" => 0, "met" => false, "evidence" => "", "criterion" => @plain_text}
                 ]
               )

      content = stored(task.id)
      assert content["lifecycle_status"] == "cancelled"
      assert met_at(content, 0) == false
    end

    test "a cancelled close that CLEARS evidence while leaving met alone still lands",
         %{scope: scope} do
      kept =
        List.update_at(criteria(), 0, &Map.merge(&1, %{"met" => true, "evidence" => "green"}))

      {task, epoch} = claimed!("exempt-clear-evidence", scope, criteria: kept)

      assert {:ok, _} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "the evidence pointed at a branch that no longer exists",
                 criteria: [
                   %{"index" => 0, "met" => false, "evidence" => "", "criterion" => @plain_text}
                 ]
               )

      assert stored(task.id)["acceptance_criteria"] |> Enum.at(0) |> Map.get("evidence") == ""
    end

    # RE-ASSERTING A STORED TRUE IS NOT A RAISE. Without this arm the gate would
    # punish an idempotent retry — the caller re-sends the identical close after
    # a timeout and gets refused for a bit that was already set. The predicate
    # keys on the TRANSITION, exactly as the close-time autostamp does.
    test "a cancelled close naming an ALREADY-met criterion still lands", %{scope: scope} do
      already =
        List.update_at(criteria(), 1, &Map.merge(&1, %{"met" => true, "evidence" => @evidence}))

      {task, epoch} = claimed!("exempt-already-met", scope, criteria: already)

      assert {:ok, _} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "abandoning the rest of this row",
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => @evidence,
                     "criterion" => @gate_text
                   }
                 ]
               )

      content = stored(task.id)
      assert content["lifecycle_status"] == "cancelled"
      assert met_at(content, 1) == true
    end

    # THE OTHER DIRECTION OF THE SCOPE. `done` is untouched: D289 still owns it,
    # and it still refuses a self-graded raise with ITS name, not this gate's.
    # If this ever reds with `criteria_raised_on_abandon`, the gate leaked onto
    # a lifecycle that is not an abandonment.
    test "a done close that raises is still refused by D289, under D289's name",
         %{scope: scope} do
      {task, epoch} = claimed!("done-untouched", scope)

      assert {:error, {:criteria_unmet, _}} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "done",
                 reason: "shipped in PR #16853, sha 81c1ef118b",
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => @evidence,
                     "criterion" => @gate_text
                   }
                 ]
               )
    end
  end
end

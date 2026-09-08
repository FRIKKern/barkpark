defmodule Barkpark.Tasks.MergeGateOverrideReceiptTest do
  @moduledoc """
  THE OVERRIDE THAT LEFT NO TRACE (cch-w56-bl).

  `Tasks.Stamp` refuses a builder's met-flip on a merge-gated criterion and says
  so loudly — the refusal names its detector and cannot be talked out of. The
  escape hatch beside it, `merge_gated: true`, was neither loud nor recorded:
  the stored criterion produced by an OVERRIDDEN stamp was byte-identical to the
  one produced by an ordinary stamp. Same key set, same `met`, and the only
  differing field (`merge_gate`) describes the criterion's TYPE, not that an
  override was used. Measured on the live server before this change: the closed
  document carried no top-level trace of any kind.

  The refusal is deliberately WIDE because "a false refusal is loud and
  recoverable while a false permit is silent". An override that is itself silent
  makes that reasoning self-defeating, so the fix is a RECEIPT, in the shape the
  close path already mints: `content.merge_gate_autostamp` (see
  `Close.close_autostamp_record/6` and `Close.merge_autostamp_record/3`), whose
  own comment states the property this file pins — a re-read must answer "was
  this criterion PROVEN, or merely asserted?" without parsing evidence prose.

  THE SECOND DOOR, and it is the sharper one. `close --set criteria:=[…]` flips
  the identical `met` bit through `merge_criteria/2`, and nothing on that path
  ever asked whether the criterion was a gate. A `done` close is stopped only
  INCIDENTALLY, by the D289 gate counting unmet criteria; a `cancelled` close is
  exempt from every honesty gate BY NAME and flipped a declared gate at exit
  zero with no flag, no marker check and no trace. Both doors write the same
  field, so both mint the same receipt.

  SUPERSEDED IN PART (task-8ca0bd7a8ed50f14). The `cancelled`/`blocked` half of
  that second door is now REFUSED outright rather than recorded — a cancel may
  abandon acceptance criteria, it may never assert them — so those two arms
  below assert the refusal and prove nothing was written. The receipt itself is
  untouched and still fires wherever a raise remains legal: a `done` close that
  raises on the record, which is the arm that keeps `close_autostamp_record/6`
  from going dead.

  NOT A REFUSAL. A close that legitimately flips a merge gate on a genuinely
  merged carrier still succeeds — the arrears sweep is not stranded. What
  changes is that the ledger can now name it.

  THE NON-REGRESSION IS HALF THE POINT: an honest stamp and an honest close mint
  NOTHING, mirroring `merge_autostamp_record(content, _key, nil)`. A receipt on
  every write would be a different and worse change.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, Stamp}

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

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @plain_text "unit tests green"
  @gate_text "MERGE GATE: PR merged to origin/main"
  @second_gate_text "MERGE GATE: the release tag is cut"

  defp criteria do
    [
      %{"criterion" => @plain_text, "met" => false, "evidence" => "", "merge_gate" => false},
      %{"criterion" => @gate_text, "met" => false, "evidence" => "", "merge_gate" => true},
      %{"criterion" => @second_gate_text, "met" => false, "evidence" => "", "merge_gate" => true}
    ]
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => criteria()
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

  defp claimed_task!(prefix, scope, worker) do
    doc_id = uniq(prefix)
    task = mk_task!(doc_id, scope)
    {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    {task, claimed.content["claim"]["epoch"]}
  end

  defp stored(task_id), do: Repo.get!(Document, task_id).content

  defp receipt(content, key), do: get_in(content, [@receipt_key, key])

  # A real merge sentence: `EvidenceDurability.check/1` refuses evidence that
  # names only a branch, and this file is not testing that gate.
  @evidence "PR #14383 merged, sha 63b89bef30 an ancestor of origin/main"

  # ─── THE STAMP DOOR ────────────────────────────────────────────────────────

  describe "stamp --merge-gated mints a receipt" do
    # THE NEGATIVE ARM. Before the fix this failed on the `stamp_overrides`
    # assertion with `nil` — the flip landed, `met` read true, and the whole
    # document held nothing that said an override had happened.
    test "the overridden stamp is distinguishable from an honest one by the stored row alone",
         %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-stamp", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence},
                 merge_gated: true,
                 caller_token_id: "tok-abc"
               )

      content = stored(task.id)

      assert Enum.at(content["acceptance_criteria"], 1)["met"] == true,
             "the override must still release the refusal — this is a receipt, not a refusal"

      # Bound first, then asserted on a boolean: `assert pattern = expr, "msg"`
      # raises MatchError before assert/2 ever sees the message, so the sentence
      # naming what is missing would never print — and this is the arm that has
      # to explain itself when it reds.
      records = receipt(content, "stamp_overrides")

      assert is_list(records) and length(records) == 1,
             "an override that lifted the merge-gate refusal must leave exactly one record, " <>
               "got: #{inspect(records)}"

      [record] = records

      assert record["verified"] == false
      assert record["source"] == "stamp_merge_gated_override"
      assert record["indices"] == [1]
      assert record["asserted_worker"] == "builder"
      assert record["authenticated_token_id"] == "tok-abc"
      assert record["criterion"] == @gate_text
      assert record["asserted_evidence"] == @evidence
      assert is_binary(record["ts"]) and record["ts"] != ""
    end

    test "a second override APPENDS — the first is never erased", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-twice", scope, "builder")

      for {index, text} <- [{1, @gate_text}, {2, @second_gate_text}] do
        assert {:ok, _} =
                 Stamp.stamp(task.id, "builder",
                   observed_epoch: epoch,
                   criterion: index,
                   criterion_text: text,
                   outcome: {:met, @evidence},
                   merge_gated: true
                 )
      end

      records = receipt(stored(task.id), "stamp_overrides")
      assert length(records) == 2
      assert Enum.map(records, & &1["indices"]) == [[1], [2]]
    end

    test "the mutation event says so too, on a boolean", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-event", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence},
                 merge_gated: true
               )

      event =
        Barkpark.Content.MutationEvent
        |> Repo.all()
        |> Enum.filter(&(&1.mutation == "task.criterion"))
        |> List.last()

      assert event.document["criterion_stamp"]["merge_gated_override"] == true
    end
  end

  describe "stamp — an honest write mints NOTHING" do
    test "an ordinary --met on a non-gated criterion leaves no receipt key", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-honest", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: @plain_text,
                 outcome: {:met, "42 tests green"}
               )

      content = stored(task.id)
      assert Enum.at(content["acceptance_criteria"], 0)["met"] == true

      refute Map.has_key?(content, @receipt_key),
             "an honest stamp must leave no receipt to explain away"
    end

    # The flag lifted nothing here, so it records nothing. Otherwise a caller
    # who passes the flag habitually would smear override records over rows
    # that were never gated, and the receipt would stop discriminating.
    test "the flag on a NON-gated criterion mints nothing", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-noop-flag", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: @plain_text,
                 outcome: {:met, "42 tests green"},
                 merge_gated: true
               )

      refute Map.has_key?(stored(task.id), @receipt_key)
    end

    test "a --miss on a gate mints nothing", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-miss", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "PR not open yet"}
               )

      refute Map.has_key?(stored(task.id), @receipt_key)
    end

    test "a REFUSED stamp mints nothing either", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-refused", scope, "builder")

      assert {:error, :merge_gated_criterion} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence}
               )

      refute Map.has_key?(stored(task.id), @receipt_key)
    end
  end

  # ─── THE CLOSE DOOR ────────────────────────────────────────────────────────

  describe "close --set criteria:= mints a receipt for a gate it flips" do
    # SUPERSEDED BY THE RAISE GATE (task-8ca0bd7a8ed50f14), AND LEFT HERE ON
    # PURPOSE. When this file was written, a `cancelled` close raising a declared
    # gate SUCCEEDED and the receipt was the whole remedy: the flip landed, and
    # the ledger could at least NAME it. Main then ruled the stronger thing — A
    # CANCEL MAY ABANDON ACCEPTANCE CRITERIA, IT MAY NEVER ASSERT THEM — so the
    # raise is now REFUSED upstream of the receipt and this door mints nothing
    # because it never opens. The arm keeps its subject and changes its verdict
    # rather than being deleted, so the next reader can see that the receipt was
    # not wrong, it was superseded.
    test "a CANCELLED close that would flip a declared gate is REFUSED, and writes nothing",
         %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-cancel", scope, "builder")

      assert {:error, {:criteria_raised_on_abandon, [1]}} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "superseded by another row",
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => @evidence,
                     "criterion" => @gate_text
                   }
                 ],
                 caller_token_id: "tok-xyz"
               )

      content = stored(task.id)

      # NOTHING WAS WRITTEN — the refusal sits ahead of the single rev-CAS write,
      # so the close did not half-land: the row is still claimed, the criterion
      # is still unmet, and there is no receipt to explain away.
      assert content["lifecycle_status"] == "in_progress"
      assert Enum.at(content["acceptance_criteria"], 1)["met"] == false
      refute Map.has_key?(content, @receipt_key)
    end

    # `blocked` IS THE SECOND EXEMPT LIFECYCLE, AND IT IS THE WHOLE POINT OF THE
    # PAIR. Every honesty gate on this path exempts `cancelled` AND `blocked` by
    # name, so a receipt proved on only one of them leaves the next reader no
    # arm saying the other matters. Measured on the live server before this
    # fix: a blocked close raised a declared gate at exit 0 with no trace,
    # identical to the cancelled door — one code path, one predicate.
    test "a BLOCKED close that would flip a declared gate is REFUSED too", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-blocked", scope, "builder")

      assert {:error, {:criteria_raised_on_abandon, [1]}} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "blocked",
                 reason: "waiting on an upstream decision",
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => @evidence,
                     "criterion" => @gate_text
                   }
                 ],
                 caller_token_id: "tok-xyz"
               )

      content = stored(task.id)
      assert content["lifecycle_status"] == "in_progress"
      assert Enum.at(content["acceptance_criteria"], 1)["met"] == false
      refute Map.has_key?(content, @receipt_key)
    end

    # THE RECEIPT IS STILL REACHABLE, and this arm is what keeps the code above
    # from going dead. The raise gate closes the ABANDON lifecycles only; a `done`
    # close that raises a declared gate on the record — D289 answered with
    # `criteria_override` — still flips the bit and must still mint the receipt.
    # Without this arm the two rewritten arms above would leave
    # `close_autostamp_record/6` untested and nothing would notice if it stopped
    # firing.
    test "a DONE close that raises a declared gate on the record still records it",
         %{scope: scope} do
      {task, epoch} = claimed_task!("mg-receipt-done-override", scope, "builder")

      assert {:ok, _} =
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
                 ],
                 criteria_override: "closing over the rest on the record",
                 caller_token_id: "tok-xyz"
               )

      content = stored(task.id)
      assert content["lifecycle_status"] == "done"
      assert Enum.at(content["acceptance_criteria"], 1)["met"] == true

      record = receipt(content, "close_body_flips")

      assert is_map(record),
             "a close body that flipped a declared merge gate must leave a record, " <>
               "got: #{inspect(record)}"

      assert record["verified"] == false
      assert record["source"] == "close_body_criteria"
      assert record["indices"] == [1]
      assert record["asserted_worker"] == "builder"
      assert record["authenticated_token_id"] == "tok-xyz"
      assert record["lifecycle_status"] == "done"
      assert is_binary(record["ts"]) and record["ts"] != ""
    end

    # LOWERING IS NOT ASSERTING, and a cancel that only lowers must still land —
    # the raise gate is scoped to the DIRECTION, not to the payload's presence.
    test "a CANCELLED close that only LOWERS a met criterion still lands, and mints nothing",
         %{scope: scope} do
      doc_id = uniq("mg-receipt-close-honest")

      already =
        List.update_at(criteria(), 0, fn c ->
          Map.merge(c, %{"met" => true, "evidence" => "42 tests green"})
        end)

      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => already})
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "builder", scope)
      epoch = claimed.content["claim"]["epoch"]

      assert {:ok, _} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "superseded by another row",
                 criteria: [
                   %{
                     "index" => 0,
                     "met" => false,
                     "evidence" => "",
                     "criterion" => @plain_text
                   }
                 ]
               )

      content = stored(task.id)
      assert content["lifecycle_status"] == "cancelled"
      assert Enum.at(content["acceptance_criteria"], 0)["met"] == false

      refute Map.has_key?(content, @receipt_key),
             "an honest close leaves no receipt to explain away"
    end

    # An already-met gate is not re-flipped by naming it, so naming it is not an
    # assertion — the receipt keys on the TRANSITION, exactly as the close-time
    # autostamp skips a criterion that is already met.
    test "naming an ALREADY-met gate mints nothing", %{scope: scope} do
      doc_id = uniq("mg-receipt-already-met")

      already =
        List.update_at(criteria(), 1, fn c ->
          Map.merge(c, %{"met" => true, "evidence" => @evidence})
        end)

      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => already})
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "builder", scope)
      epoch = claimed.content["claim"]["epoch"]

      assert {:ok, _} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "cancelled",
                 reason: "superseded by another row",
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => @evidence,
                     "criterion" => @gate_text
                   }
                 ]
               )

      refute Map.has_key?(stored(task.id), @receipt_key)
    end
  end
end

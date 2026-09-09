defmodule Barkpark.Tasks.MergeGateOverrideReasonTest do
  @moduledoc """
  THE OVERRIDE THAT COST ONE WORD (pds-bl-merge-gated-override-carries-no-reason).

  `--merge-gated` is the ONE escape from the merge-gate refusal. Until this
  change it was a BARE BOOLEAN: no argument, no reason, nothing on the record
  saying whether the person who typed it had read the refusal or was typing it
  by habit. The receipt minted beside it (cch-w56-bl,
  `merge_gate_override_receipt_test.exs`) said WHO asserted and WHEN — and never
  WHY, so a reflex override and a deliberate one produced identical documents.
  The lead who filed this row had typed the flag three times in one day.

  WHAT CHANGES: the override carries a REASON and the reason is PERSISTED on the
  same rev-CAS write as the flip, in the field name the close path already uses
  (`close_override.*`'s `reason`, `Close.maybe_put_override/5`).

  WHAT DOES NOT CHANGE, AND THIS FILE PROVES IT: coverage. The refusal SET is
  decided by `Criteria.merge_gated?/1` alone and that predicate is untouched —
  the corpus arm below freezes its verdict over every marker-bearing criterion
  in the sampled live corpus. Only the ESCAPE gained a cost, so the change can
  refuse MORE (a reason-less override now fails) and can never permit less. This
  was the whole reason the row was separable from its parent, whose proposed
  predicate narrowing was refuted by that same census.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Criteria, Stamp}
  alias BarkparkWeb.TasksController.Params

  @dataset "production"
  @receipt_key "merge_gate_autostamp"
  @fixture Path.join(__DIR__, "../../support/fixtures/merge_gate_wording.json")

  @gate_text "MERGE GATE: PR merged to origin/main"
  @plain_text "unit tests green"
  @evidence "PR #14383 merged, sha 63b89bef30 an ancestor of origin/main"
  @reason "PR #14383 merged to main as 63b89bef30; I am the lead closing the gate"

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

  # ─── COVERAGE IS PROVEN UNCHANGED ──────────────────────────────────────────

  describe "the refusal set is untouched by the reason requirement" do
    # THE POPULATION IS THE CENSUS'S OWN. `merge_gate_wording.json` was
    # generated from the live corpus by the PDS merge-gate audit and carries
    # both halves of the marker-bearing population: the sampled LEADING form and
    # EVERY non-leading marker-bearing criterion, genuine gates and prose-only
    # mentions alike. `Criteria.merge_gated?/1` is the sole author of the
    # refusal set, so freezing its verdict over that corpus freezes coverage.
    #
    # A mutation that narrowed the predicate — the fix this row was split off
    # from, refuted by census because 51 of the non-leading rows are GENUINE
    # gates — reds here with the exact rows it unblocked.
    test "every marker-bearing criterion in the live-corpus sample is still a gate" do
      corpus = fixture()["must_warn"] ++ fixture()["must_stay_silent"]

      refute corpus == [], "the corpus fixture is empty — this arm would be vacuous"

      not_gated =
        corpus
        |> Enum.reject(&Criteria.merge_gated?(%{"criterion" => &1["criterion"]}))
        |> Enum.map(& &1["criterion"])

      assert not_gated == [],
             "#{length(not_gated)} of #{length(corpus)} marker-bearing criteria stopped being " <>
               "gates — coverage MOVED: #{inspect(Enum.take(not_gated, 5))}"
    end

    # THE CONTROL. The corpus arm above proves nothing on its own unless the
    # predicate is capable of saying NO — a predicate stuck at `true` would pass
    # it while blocking the entire ledger. These rows must stay stampable.
    test "criteria that were never gates are still not gates" do
      for text <- [
            @plain_text,
            "CGO_ENABLED=0 go test ./internal/cli/... green, counts quoted.",
            "the reason is persisted on the row beside the stamp"
          ] do
        refute Criteria.merge_gated?(%{"criterion" => text}),
               "#{inspect(text)} became a gate — the refusal set WIDENED"
      end

      # And the structural exit still wins over the prose, in both directions.
      assert Criteria.merge_gated?(%{"criterion" => @plain_text, "merge_gate" => true})
      refute Criteria.merge_gated?(%{"criterion" => @gate_text, "merge_gate" => false})
    end
  end

  # ─── THE REASON IS REQUIRED ────────────────────────────────────────────────

  describe "a reason-less override releases nothing" do
    # THE MUTATION-PROOF for the requirement (criterion 3). Restore the old
    # boolean contract — make `true` release the gate again — and this reds:
    # the stamp lands where it must be refused.
    test "merge_gated: true is refused exactly as an unflagged stamp is", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-reason-bool", scope, "builder")

      assert {:error, :merge_gated_criterion} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence},
                 merge_gated: true
               )

      # The unflagged stamp is the reference: the two must be indistinguishable.
      assert {:error, :merge_gated_criterion} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence}
               )

      content = stored(task.id)
      assert Enum.at(content["acceptance_criteria"], 1)["met"] == false
      refute Map.has_key?(content, @receipt_key)
    end

    test "a blank or whitespace reason releases nothing", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-reason-blank", scope, "builder")

      for blank <- ["", "   ", "\n\t"] do
        assert {:error, :merge_gated_criterion} =
                 Stamp.stamp(task.id, "builder",
                   observed_epoch: epoch,
                   criterion: 1,
                   criterion_text: @gate_text,
                   outcome: {:met, @evidence},
                   merge_gated: blank
                 ),
               "#{inspect(blank)} is not a reason"
      end
    end
  end

  # ─── THE REASON IS PERSISTED ───────────────────────────────────────────────

  describe "the reason lands on the row" do
    # THE PERSISTENCE MUTATION-PROOF (criteria 1 and 3). Delete
    # `"reason" => reason` from `Stamp.override_record/5` and the read-back
    # assertion below is the line that fails: everything else about the record
    # survives a reason-less override, which is exactly why the receipt could
    # not tell a reflex from a decision.
    test "a signed override releases the gate AND records why, on the stored row",
         %{scope: scope} do
      {task, epoch} = claimed_task!("mg-reason-lands", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence},
                 merge_gated: @reason,
                 caller_token_id: "tok-abc"
               )

      # Read back FROM THE STORE, never from the envelope the writer was handed
      # — the same discipline the stamp verb's own read-back enforces. The
      # PUBLISHED-perspective read (GET /v1/tasks/:id after the stamp) is
      # asserted end-to-end in tasks_controller_test.exs, "merge-gated=<reason>
      # releases the gate on the wire, and the reason is persisted".
      content = stored(task.id)

      assert Enum.at(content["acceptance_criteria"], 1)["met"] == true

      [record] = content[@receipt_key]["stamp_overrides"]

      assert record["reason"] == @reason
      # The reason sits BESIDE the actor and the ts, `close_override.*`'s shape.
      assert record["asserted_worker"] == "builder"
      assert record["authenticated_token_id"] == "tok-abc"
      assert record["verified"] == false
      assert is_binary(record["ts"]) and record["ts"] != ""
    end

    test "the reason is trimmed, never stored with the caller's stray whitespace",
         %{scope: scope} do
      {task, epoch} = claimed_task!("mg-reason-trim", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 1,
                 criterion_text: @gate_text,
                 outcome: {:met, @evidence},
                 merge_gated: "  #{@reason}\n"
               )

      [record] = stored(task.id)[@receipt_key]["stamp_overrides"]
      assert record["reason"] == @reason
    end

    # THE NON-REGRESSION. The flag on a row that is NOT a gate lifted nothing
    # before and lifts nothing now, so it still records nothing — a reason on
    # every honest write would make the receipt stop discriminating.
    test "a reason on a NON-gated criterion mints nothing", %{scope: scope} do
      {task, epoch} = claimed_task!("mg-reason-noop", scope, "builder")

      assert {:ok, _} =
               Stamp.stamp(task.id, "builder",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: @plain_text,
                 outcome: {:met, "42 tests green"},
                 merge_gated: @reason
               )

      refute Map.has_key?(stored(task.id), @receipt_key)
    end
  end

  # ─── THE WIRE READS A REASON, NOT A BOOLEAN ────────────────────────────────

  describe "Params.stamp_merge_gated/1" do
    test "a non-blank string is the reason" do
      assert {:ok, @reason} = Params.stamp_merge_gated(%{"merge-gated" => @reason})
      assert {:ok, @reason} = Params.stamp_merge_gated(%{"merge_gated" => @reason})
      assert {:ok, @reason} = Params.stamp_merge_gated(%{"merge-gated" => "  #{@reason} "})
    end

    test "absent, blank and falsy read as NOT ASKED FOR" do
      for params <- [
            %{},
            %{"merge-gated" => ""},
            %{"merge-gated" => "   "},
            %{"merge-gated" => false},
            %{"merge-gated" => "false"},
            %{"merge-gated" => 0}
          ] do
        assert {:ok, nil} = Params.stamp_merge_gated(params), "#{inspect(params)}"
      end
    end

    # THE LEGACY SPELLING IS REFUSED, NOT SILENTLY HONOURED. Accepting `true`
    # as a reason-less override would keep the free escape open for every direct
    # POST and every unupgraded client — and a CLI-only requirement is bypassed
    # by exactly that POST, the same argument that moved the merge-gate verdict
    # itself onto the server.
    test "the bare truthy spellings are a 400 naming what to supply" do
      for v <- [true, 1, "true", "1", "yes", "on"] do
        assert {:error, :invalid_stamp, msg} = Params.stamp_merge_gated(%{"merge-gated" => v}),
               "#{inspect(v)} must be refused"

        assert msg =~ "REASON"
        assert msg =~ "stamp_overrides"
      end
    end
  end

  # ─── helpers ───────────────────────────────────────────────────────────────

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp criteria do
    [
      %{"criterion" => @plain_text, "met" => false, "evidence" => "", "merge_gate" => false},
      %{"criterion" => @gate_text, "met" => false, "evidence" => "", "merge_gate" => true}
    ]
  end

  defp claimed_task!(prefix, scope, worker) do
    doc_id = uniq(prefix)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => criteria()
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    {doc, claimed.content["claim"]["epoch"]}
  end

  defp stored(task_id), do: Repo.get!(Document, task_id).content
end

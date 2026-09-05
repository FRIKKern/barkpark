defmodule Barkpark.Tasks.ReconcileMergeGateTest do
  @moduledoc """
  Unit tests for `Barkpark.Tasks.Close.reconcile_merge_gate/3` — the merge-event
  bridge that auto-stamps a task's explicit `merge_gate:true` acceptance criterion
  when its PR merges, WITHOUT a manual lead close (ledger-merge-criterion-autostamp).

  These are the mutation-proof: the marker match, the STAMP-ONLY guarantee (no
  lifecycle flip → partial truth preserved), and named idempotent outcomes.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Content.{Document, MutationEvent}

  @dataset "production"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
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

  defp mk_task!(doc_id, scope, content_extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  @gate_text "MERGE GATE: PR merged to origin/main"

  # A built (met) non-gate criterion + an unmet, explicitly-marked merge gate.
  @criteria [
    %{"criterion" => "feature built + tests green", "met" => true, "evidence" => "PR #1"},
    %{"criterion" => @gate_text, "met" => false, "merge_gate" => true}
  ]

  @landed %{"prs" => [4621], "commit" => "abc1234def"}

  test "stamps ONLY the merge-gate criterion; evidence names PR + commit + trigger; lifecycle untouched",
       %{scope: scope} do
    task = mk_task!(uniq("rmg-happy"), scope, %{"acceptance_criteria" => @criteria})

    assert {:ok, :stamped, [1]} =
             Tasks.reconcile_merge_gate(task.id, @landed, worker_id: "github-merge")

    reloaded = Repo.get!(Document, task.id)
    [built, gate] = reloaded.content["acceptance_criteria"]

    # The gate flipped met with composed evidence.
    assert gate["met"] == true
    # Criterion text (the paper-claim citation) is NEVER rewritten.
    assert gate["criterion"] == @gate_text
    assert gate["evidence"] =~ "auto: merge-reconciled by github-merge"
    assert gate["evidence"] =~ "PR #4621"
    assert gate["evidence"] =~ "commit abc1234def"

    # The non-gate criterion is untouched.
    assert built["met"] == true
    assert built["evidence"] == "PR #1"

    # STAMP-ONLY: the lifecycle is NEVER flipped — the lead keeps the close.
    assert reloaded.content["lifecycle_status"] == "open"
  end

  test "criterion 3: a task with ANOTHER unmet criterion cannot be made to read fully done",
       %{scope: scope} do
    partial = [
      %{"criterion" => "docs written", "met" => false},
      %{"criterion" => @gate_text, "met" => false, "merge_gate" => true}
    ]

    task = mk_task!(uniq("rmg-partial"), scope, %{"acceptance_criteria" => partial})

    assert {:ok, :stamped, [1]} = Tasks.reconcile_merge_gate(task.id, @landed)

    reloaded = Repo.get!(Document, task.id)
    [docs, gate] = reloaded.content["acceptance_criteria"]

    assert gate["met"] == true, "the merge gate is stamped"
    assert docs["met"] == false, "the OTHER unmet criterion stays visibly partial"
    assert reloaded.content["lifecycle_status"] == "open", "never terminal on a partial task"
  end

  test "criterion 2: a 'MERGE GATE' text criterion WITHOUT the marker is NOT stamped, and is NAMED",
       %{scope: scope} do
    # Same wording, but no `merge_gate:true` — a text heuristic would misfire.
    unmarked = [
      %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
      %{"criterion" => @gate_text, "met" => false}
    ]

    task = mk_task!(uniq("rmg-unmarked"), scope, %{"acceptance_criteria" => unmarked})

    # CONTRACT CHANGE (task-d1654bf0d20d5009), and only to the TAG: every
    # substantive assertion below is unchanged and still holds — nothing is
    # stamped, nothing is written, the rev does not move. What changed is that
    # `:no_marker` was true but useless here. It says "this row carries no gate",
    # while the row plainly carries something that READS as one; the criterion
    # was then invisible to the autostamp AND refused to the builder by
    # stamp.ex's prose arm, so it could only ever be stamped by a lead who
    # noticed it by hand. The receipt now names the indices instead, which is the
    # whole remedy: the strand becomes a sentence somebody can act on.
    #
    # The flag deliberately remains the permit — widening it would fabricate
    # dones on the 74 ledger criteria that merely discuss gating. See
    # `reconcile_locked/4`.
    assert {:ok, :unflagged_merge_gates, [1]} = Tasks.reconcile_merge_gate(task.id, @landed)

    reloaded = Repo.get!(Document, task.id)
    assert Enum.at(reloaded.content["acceptance_criteria"], 1)["met"] == false
    assert reloaded.rev == task.rev, "no write on a task with no marker"
  end

  test "idempotent replay: an already-met merge gate is {:ok, :already_stamped} with no re-write",
       %{scope: scope} do
    already = [
      %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
      %{
        "criterion" => @gate_text,
        "met" => true,
        "merge_gate" => true,
        "evidence" => "auto: merge-reconciled by github-merge — landed PR #4621 at t0"
      }
    ]

    task = mk_task!(uniq("rmg-replay"), scope, %{"acceptance_criteria" => already})
    before = Repo.get!(Document, task.id)

    assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, @landed)

    reloaded = Repo.get!(Document, task.id)
    assert reloaded.rev == before.rev, "no CAS write on replay"
    # Evidence is not doubled — the original stamp text is preserved verbatim.
    assert Enum.at(reloaded.content["acceptance_criteria"], 1)["evidence"] ==
             "auto: merge-reconciled by github-merge — landed PR #4621 at t0"
  end

  test "an unmet merge gate with NO wording is {:ok, :no_guardable_marker}, never faked",
       %{scope: scope} do
    textless = [
      %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
      %{"criterion" => "", "met" => false, "merge_gate" => true}
    ]

    task = mk_task!(uniq("rmg-textless"), scope, %{"acceptance_criteria" => textless})

    assert {:ok, :no_guardable_marker} = Tasks.reconcile_merge_gate(task.id, @landed)

    reloaded = Repo.get!(Document, task.id)
    assert Enum.at(reloaded.content["acceptance_criteria"], 1)["met"] == false
    assert reloaded.rev == task.rev
  end

  test "an unknown task id is {:error, :unknown_task}" do
    assert {:error, :unknown_task} =
             Tasks.reconcile_merge_gate(Ecto.UUID.generate(), @landed)
  end

  test "the reconciliation emits a durable task.criterion mutation_event", %{scope: scope} do
    task = mk_task!(uniq("rmg-event"), scope, %{"acceptance_criteria" => @criteria})

    assert {:ok, :stamped, [1]} = Tasks.reconcile_merge_gate(task.id, @landed)

    events =
      Repo.all(
        from(e in MutationEvent,
          where: e.doc_id == ^task.doc_id and e.mutation == "task.criterion"
        )
      )

    assert length(events) == 1
    [ev] = events
    assert ev.source == "github-merge"
    assert get_in(ev.document, ["merge_reconcile", "indices"]) == [1]
  end
end

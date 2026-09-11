defmodule Barkpark.Tasks.MergeGateDiscrepancyTest do
  @moduledoc """
  task-4ab4a5b58bce97a6, criterion 2 — THE SECOND LOOK.

  `content.merge_gate_autostamp.close` records that a close-time merge-gate
  autostamp rested on the CALLER'S assertion (`verified: false`). It was a
  receipt and nothing more: nothing ever went back and asked whether the
  assertion turned out to be true, so a close citing a foreign epic's PR was
  auditable only by a human who happened to read the record and then go and
  check GitHub by hand.

  The merge webhook is the server's OWN observation and it arrives LATER, which
  is why the reconciliation lives in `Close.reconcile_merge_gate/3` and not in
  the close: the close runs under `pg_advisory_xact_lock` where a GitHub
  round-trip would trade a fabrication bug for an availability bug, and at close
  time there is nothing new to learn anyway.

  When the webhook contradicts the close's assertion, a NAMED record lands at
  `content.merge_gate_autostamp.discrepancy` — which PRs were asserted, which
  the server has actually observed on this task, and which asserted ones remain
  unwitnessed. It does not un-stamp or refuse anything: 76/2064 closes are
  foreign lead seals (D288/D289) and a hard refusal breaks the seal ritual. It
  makes the false assertion LEGIBLE, which is the half that was missing.

  MUTATION PROOF: make `Close.build_discrepancy/4` return `nil` unconditionally
  and every discrepancy arm reds while all four controls stay green.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Internal

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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # `gate_met?` is the axis that picks which `reconcile_locked/4` arm runs:
  # `true` → `:already_stamped` (the close got there first — the case that
  # matters most), `false` → the stamping arm.
  defp mk_task!(scope, gate_met?, autostamp) do
    doc_id = uniq("mg-discrepancy")

    content =
      %{
        "kind" => "task",
        "lifecycle_status" => if(gate_met?, do: "done", else: "open"),
        "acceptance_criteria" => [
          %{"criterion" => "feature built", "met" => true, "evidence" => "local run"},
          %{
            "criterion" => "MERGE GATE: PR merged to origin/main",
            "met" => gate_met?,
            "merge_gate" => true,
            "evidence" => if(gate_met?, do: "auto: lead-closed on merge", else: "")
          }
        ]
      }
      |> maybe_put_autostamp(autostamp)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp maybe_put_autostamp(content, nil), do: content
  defp maybe_put_autostamp(content, record), do: Map.put(content, "merge_gate_autostamp", record)

  # The shape `Close.close_autostamp_record/6` persists: NO `prs` key — the PR
  # numbers live only inside the prose summary, which is exactly why the
  # reconciliation has to read a record back the same way `observed_prs/1` does.
  defp close_record(summary) do
    %{
      "close" => %{
        "verified" => false,
        "source" => "close_landed_digest",
        "indices" => [1],
        "asserted_worker" => "scratch-worker",
        "authenticated_token_id" => "tok-9",
        "landed" => summary,
        "witnessed_prs" => [],
        "ts" => "2026-09-10T00:00:00Z"
      }
    }
  end

  defp discrepancy(task_id) do
    Repo.get!(Document, task_id).content["merge_gate_autostamp"]["discrepancy"]
  end

  describe "a merge event that contradicts the close's asserted PR" do
    test "names the discrepancy on the ALREADY-STAMPED row the close sealed", %{scope: scope} do
      task = mk_task!(scope, true, close_record("PR #99999"))

      # The real merge, on this task's own trailer, naming a DIFFERENT PR.
      assert {:ok, :already_stamped} =
               Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

      record = discrepancy(task.id)

      assert record["kind"] == "asserted_pr_not_merged_for_this_task"
      assert record["source"] == "merge_event_reconcile"
      assert record["verified"] == true
      assert record["asserted_prs"] == ["99999"]
      assert record["unwitnessed_prs"] == ["99999"]
      assert record["observed_prs"] == ["17070"]
      # The actor is carried through from the close record — BOTH halves, the
      # client-supplied worker and the token the server actually authenticated.
      assert record["asserted_worker"] == "scratch-worker"
      assert record["authenticated_token_id"] == "tok-9"
      assert record["close_indices"] == [1]

      assert record["message"] =~ "the close asserted PR #99999"
      assert record["message"] =~ "has since observed PR #17070 merge for this task"
      assert record["message"] =~ "never observed #99999 here"

      # NOT a withdrawal: the gate the close stamped is still met.
      criteria = Repo.get!(Document, task.id).content["acceptance_criteria"]
      assert Enum.at(criteria, 1)["met"] == true
    end

    test "rides the SAME write as a real stamp when the gate was still unmet", %{scope: scope} do
      task = mk_task!(scope, false, close_record("PR #99999"))

      assert {:ok, :stamped, [1]} =
               Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

      content = Repo.get!(Document, task.id).content

      assert content["merge_gate_autostamp"]["discrepancy"]["unwitnessed_prs"] == ["99999"]
      # Both sub-keys coexist: the verified merge event never overwrites the
      # record of what the close leaned on.
      assert content["merge_gate_autostamp"]["merge_event"]["verified"] == true
      assert content["merge_gate_autostamp"]["close"]["verified"] == false
    end

    test "a REPLAYED delivery does not restate the discrepancy or burn a rev", %{scope: scope} do
      task = mk_task!(scope, true, close_record("PR #99999"))
      landed = %{"prs" => [17_070], "commit" => "f7610ed6a"}

      assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, landed)
      after_first = Repo.get!(Document, task.id)

      assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, landed)
      after_second = Repo.get!(Document, task.id)

      assert after_second.rev == after_first.rev
      assert after_second.content == after_first.content
    end
  end

  describe "controls" do
    test "an asserted PR the merge event CONFIRMS writes no discrepancy", %{scope: scope} do
      task = mk_task!(scope, true, close_record("PR #17070 (commit f7610ed6a)"))

      assert {:ok, :already_stamped} =
               Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

      assert discrepancy(task.id) == nil
    end

    test "a PR already WITNESSED by an earlier merge event writes no discrepancy",
         %{scope: scope} do
      autostamp =
        Map.merge(close_record("PR #4242"), %{
          "merge_event" => %{
            "verified" => true,
            "source" => "github_merge_event",
            "prs" => ["4242"],
            "landed" => "PR #4242 (commit deadbee)",
            "ts" => "2026-09-09T00:00:00Z"
          }
        })

      task = mk_task!(scope, true, autostamp)

      # A SECOND merge on the same task. The close's #4242 was observed long
      # ago, so nothing is contradicted.
      assert {:ok, :already_stamped} =
               Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

      assert discrepancy(task.id) == nil
    end

    test "a row with NO close-time autostamp record writes no discrepancy", %{scope: scope} do
      task = mk_task!(scope, false, nil)

      assert {:ok, :stamped, [1]} =
               Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

      assert discrepancy(task.id) == nil
    end

    test "a row with no merge-gate marker at all is still `:no_marker` and is not written",
         %{scope: scope} do
      doc_id = uniq("mg-discrepancy-nomarker")

      {:ok, task} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "done",
              "acceptance_criteria" => [%{"criterion" => "built", "met" => true}]
            }
          },
          @dataset,
          scope
        )

      before_rev = Repo.get!(Document, task.id).rev

      assert {:ok, :no_marker} =
               Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

      assert Repo.get!(Document, task.id).rev == before_rev
    end
  end

  # A guard on the fixture itself: `Internal.generate_rev/0` is what the write
  # path bumps, so a test that asserts "rev unchanged" is only meaningful while
  # a write really does change it.
  test "CONTROL ON THE CONTROL: a write DOES move the rev", %{scope: scope} do
    task = mk_task!(scope, true, close_record("PR #99999"))
    before_rev = Repo.get!(Document, task.id).rev

    assert {:ok, :already_stamped} =
             Tasks.reconcile_merge_gate(task.id, %{"prs" => [17_070], "commit" => "f7610ed6a"})

    assert Repo.get!(Document, task.id).rev != before_rev
    assert is_binary(Internal.generate_rev())
  end
end

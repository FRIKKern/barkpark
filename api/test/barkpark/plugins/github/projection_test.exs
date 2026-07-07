defmodule Barkpark.Plugins.Github.ProjectionTest do
  @moduledoc """
  The pure task → issue projection (charter Wave 1, D3/D11): exhaustive lifecycle
  → state_reason table, idempotent blocks-marker rewrite that preserves human
  prose, and the always-present `Task:` trailer that keeps `pr-task-gate` alive.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github.Projection

  defp task(content, extra \\ %{}) do
    Map.merge(%{"doc_id" => "task-abc", "content" => content}, extra)
  end

  # True when the issue body carries no acceptance fence.
  defp refute_fence(issue), do: not (issue.body =~ "barkpark:acceptance")

  # True when the body carries no parent fence.
  defp refute_parent(body), do: not (body =~ "barkpark:parent")

  describe "state_for/1 — exhaustive lifecycle → {state, state_reason}" do
    test "done closes as completed" do
      assert Projection.state_for("done") == {"closed", "completed"}
    end

    test "cancelled closes as not_planned" do
      assert Projection.state_for("cancelled") == {"closed", "not_planned"}
    end

    test "open / in_progress / blocked (and reopen) are open with nil reason" do
      for status <- ["open", "in_progress", "blocked"] do
        assert Projection.state_for(status) == {"open", nil}
      end
    end

    test "nil and unknown statuses degrade to open (total, never crashes)" do
      assert Projection.state_for(nil) == {"open", nil}
      assert Projection.state_for("garbage") == {"open", nil}
    end

    test "every declared lifecycle_status maps to a defined pair" do
      # The tasks plugin's five statuses — the table must cover all of them.
      for status <- ["open", "in_progress", "blocked", "done", "cancelled"] do
        {state, reason} = Projection.state_for(status)
        assert state in ["open", "closed"]
        assert reason in [nil, "completed", "not_planned"]
      end
    end
  end

  describe "task_to_issue/1 — state projection" do
    test "done task projects closed/completed" do
      issue = Projection.task_to_issue(task(%{"lifecycle_status" => "done"}))
      assert issue.state == "closed"
      assert issue.state_reason == "completed"
    end

    test "cancelled task projects closed/not_planned" do
      issue = Projection.task_to_issue(task(%{"lifecycle_status" => "cancelled"}))
      assert issue.state == "closed"
      assert issue.state_reason == "not_planned"
    end

    test "in-progress task projects open/nil (reopen when GitHub had it closed)" do
      issue = Projection.task_to_issue(task(%{"lifecycle_status" => "in_progress"}))
      assert issue.state == "open"
      assert issue.state_reason == nil
    end
  end

  describe "task_to_issue/1 — title" do
    test "uses the task title" do
      issue = Projection.task_to_issue(task(%{"title" => "Fix the sync loop"}))
      assert issue.title == "Fix the sync loop"
    end

    test "falls back to the doc_id (never fabricated prose) when title absent" do
      issue = Projection.task_to_issue(task(%{}))
      assert issue.title == "Task task-abc"
    end
  end

  describe "task_to_issue/1 — Task: trailer (D11, keeps pr-task-gate working)" do
    test "the trailer is present and carries the doc_id" do
      issue = Projection.task_to_issue(task(%{"description" => "Some brief."}))
      assert issue.body =~ "Task: task-abc"
    end

    test "the trailer is present even with an empty brief" do
      issue = Projection.task_to_issue(task(%{}))
      assert issue.body =~ "Task: task-abc"
    end

    test "re-projecting the same task yields an identical body (idempotent)" do
      doc = task(%{"description" => "Brief.", "lifecycle_status" => "open"})
      once = Projection.task_to_issue(doc)
      twice = Projection.task_to_issue(doc)
      assert once.body == twice.body
      # And no duplicated trailer.
      assert length(String.split(once.body, "Task: task-abc")) == 2
    end
  end

  describe "task_to_issue/1 — labels from priority/status/worker/goal" do
    test "emits sorted labels for every present field" do
      doc =
        task(%{
          "priority" => 0,
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => "fable-7"},
          "parent_id" => "goal-xyz"
        })

      issue = Projection.task_to_issue(doc)

      assert issue.labels == [
               "goal:goal-xyz",
               "priority:p0",
               "status:in_progress",
               "worker:fable-7"
             ]
    end

    test "absent fields yield no label (never a fabricated placeholder)" do
      issue = Projection.task_to_issue(task(%{"lifecycle_status" => "open"}))
      assert issue.labels == ["status:open"]
    end

    test "out-of-range priority is dropped, not clamped" do
      issue = Projection.task_to_issue(task(%{"priority" => 9}))
      refute Enum.any?(issue.labels, &String.starts_with?(&1, "priority:"))
    end
  end

  describe "upsert_blocks_marker/2 — idempotent, prose-preserving" do
    test "applying twice equals applying once (idempotent)" do
      body = "Human context here."
      once = Projection.upsert_blocks_marker(body, [12, 34])
      twice = Projection.upsert_blocks_marker(once, [12, 34])
      assert once == twice
    end

    test "preserves human prose above the fence, rewrites only inside" do
      body = "Original human note.\n\n" <> Projection.upsert_blocks_marker("", [12])
      updated = Projection.upsert_blocks_marker(body, [99])

      assert updated =~ "Original human note."
      assert updated =~ "#99"
      refute updated =~ "#12"
      # Exactly one fence — no accumulation.
      assert length(String.split(updated, "<!-- barkpark:blocks:start -->")) == 2
    end

    test "empty refs strip the fence entirely (no blockers → no marker)" do
      fenced = Projection.upsert_blocks_marker("Prose.", [12])
      assert fenced =~ "barkpark:blocks"

      stripped = Projection.upsert_blocks_marker(fenced, [])
      refute stripped =~ "barkpark:blocks"
      assert stripped =~ "Prose."
    end

    test "empty refs on empty body stays empty (idempotent no-op)" do
      assert Projection.upsert_blocks_marker("", []) == ""
    end

    test "string refs are normalized to issue anchors" do
      body = Projection.upsert_blocks_marker("", ["12", "#34"])
      assert body =~ "#12"
      assert body =~ "#34"
    end
  end

  describe "task_to_issue/1 — blocks marker end to end" do
    test "hydrated blocker_issue_refs render inside the fence, before the trailer" do
      doc =
        task(%{"description" => "Brief."}, %{"blocker_issue_refs" => [7, 8]})

      issue = Projection.task_to_issue(doc)

      assert issue.body =~ "<!-- barkpark:blocks:start -->"
      assert issue.body =~ "Blocked by: #7, #8"
      assert issue.body =~ "Task: task-abc"
      # Prose first, then fence, then trailer.
      assert issue.body =~ ~r/Brief\..*barkpark:blocks:start.*Task: task-abc/s
    end

    test "no blocker refs → no marker block" do
      issue = Projection.task_to_issue(task(%{"description" => "Brief."}))
      refute issue.body =~ "barkpark:blocks"
    end
  end

  describe "task_to_issue/1 — acceptance criteria checkboxes (flagship liveness signal)" do
    test "renders a GitHub task list with met/unmet boxes, before the trailer" do
      doc =
        task(%{
          "description" => "Brief.",
          "acceptance_criteria" => [
            %{"criterion" => "Loop is broken", "met" => true},
            %{"criterion" => "Cursor advances", "met" => false}
          ]
        })

      issue = Projection.task_to_issue(doc)

      assert issue.body =~ "<!-- barkpark:acceptance:start -->"
      assert issue.body =~ "### Acceptance criteria"
      assert issue.body =~ "- [x] Loop is broken"
      assert issue.body =~ "- [ ] Cursor advances"
      assert issue.body =~ "<!-- barkpark:acceptance:end -->"
      # Ordering: brief, then acceptance, then trailer.
      assert issue.body =~ ~r/Brief\..*barkpark:acceptance:start.*Task: task-abc/s
    end

    test "a non-true met value is unchecked (only literal true checks the box)" do
      doc =
        task(%{
          "acceptance_criteria" => [
            %{"criterion" => "stringy met", "met" => "true"},
            %{"criterion" => "missing met"}
          ]
        })

      issue = Projection.task_to_issue(doc)
      assert issue.body =~ "- [ ] stringy met"
      assert issue.body =~ "- [ ] missing met"
      refute issue.body =~ "- [x]"
    end

    test "tolerates bare-string criteria and skips blank/typeless rows" do
      doc =
        task(%{
          "acceptance_criteria" => ["plain criterion", "", %{"criterion" => ""}, 42]
        })

      issue = Projection.task_to_issue(doc)
      assert issue.body =~ "- [ ] plain criterion"
      # Exactly one checklist item survived.
      assert length(String.split(issue.body, "- [ ]")) == 2
    end

    test "empty or absent acceptance_criteria emits no acceptance fence" do
      assert refute_fence(Projection.task_to_issue(task(%{"acceptance_criteria" => []})))
      assert refute_fence(Projection.task_to_issue(task(%{})))
    end

    test "re-projecting a task with criteria is idempotent (one fence, stable body)" do
      doc =
        task(%{
          "description" => "Brief.",
          "acceptance_criteria" => [%{"criterion" => "c1", "met" => true}]
        })

      once = Projection.task_to_issue(doc)
      twice = Projection.task_to_issue(doc)
      assert once.body == twice.body
      assert length(String.split(once.body, "<!-- barkpark:acceptance:start -->")) == 2
    end

    test "a multi-line criterion collapses to a single well-formed list line" do
      doc = task(%{"acceptance_criteria" => [%{"criterion" => "line one\nline two"}]})
      issue = Projection.task_to_issue(doc)
      assert issue.body =~ "- [ ] line one line two"
      refute issue.body =~ "line one\nline two"
    end

    test "acceptance and blocks fences coexist in reading order" do
      doc =
        task(
          %{
            "description" => "Brief.",
            "acceptance_criteria" => [%{"criterion" => "c1"}]
          },
          %{"blocker_issue_refs" => [7]}
        )

      issue = Projection.task_to_issue(doc)

      assert issue.body =~
               ~r/Brief\..*barkpark:acceptance:start.*barkpark:blocks:start.*Task: task-abc/s
    end
  end

  describe "sentinel safety — forged barkpark comments in human text are scrubbed" do
    test "a forged acceptance sentinel in the brief is stripped (no fence hijack)" do
      forged =
        "Real note. <!-- barkpark:acceptance:start -->### Injected\n- [x] pwned<!-- barkpark:acceptance:end -->"

      doc =
        task(%{
          "description" => forged,
          "acceptance_criteria" => [%{"criterion" => "genuine", "met" => false}]
        })

      issue = Projection.task_to_issue(doc)

      # The human prose survives. The forged SENTINELS are gone, so Wave 2's
      # fence-upsert regex can never mistake the outsider's text for a real
      # fence — that's the security boundary. (The inert markdown BETWEEN the
      # forged sentinels is just the human brief's own content; we don't police
      # arbitrary prose, only sentinel forgery.)
      assert issue.body =~ "Real note."
      # Exactly ONE acceptance fence — the projection's own — with a matching
      # start/end pair and no forged sentinel surviving anywhere.
      assert length(String.split(issue.body, "<!-- barkpark:acceptance:start -->")) == 2
      assert length(String.split(issue.body, "<!-- barkpark:acceptance:end -->")) == 2
      assert issue.body =~ "- [ ] genuine"
    end

    test "a lone forged opener (no closer) in the brief is also removed" do
      doc = task(%{"description" => "Note. <!-- barkpark:blocks:start --> tail"})
      issue = Projection.task_to_issue(doc)
      refute issue.body =~ "barkpark:blocks:start"
      assert issue.body =~ "Note."
    end
  end

  describe "Task: trailer — line-exact, not substring (doc_id prefix trap)" do
    test "a brief mentioning a longer sibling trailer does not suppress this trailer" do
      # doc_id "gh-1"; the brief references sibling "Task: gh-12" as prose.
      doc = %{
        "doc_id" => "gh-1",
        "content" => %{"description" => "See also Task: gh-12 for context."}
      }

      issue = Projection.task_to_issue(doc)
      # The real trailer for gh-1 must be present on its own line.
      assert issue.body |> String.split("\n") |> Enum.any?(&(&1 == "Task: gh-1"))
    end

    test "an exact existing trailer line is not duplicated" do
      doc = %{
        "doc_id" => "gh-1",
        "content" => %{"description" => "Body.\n\nTask: gh-1"}
      }

      issue = Projection.task_to_issue(doc)
      assert length(String.split(issue.body, "Task: gh-1")) == 2
    end
  end

  describe "upsert_acceptance_marker/2 — idempotent, prose-preserving" do
    test "applying twice equals applying once" do
      crit = [%{"criterion" => "c1", "met" => true}]
      once = Projection.upsert_acceptance_marker("Human.", crit)
      twice = Projection.upsert_acceptance_marker(once, crit)
      assert once == twice
    end

    test "empty criteria strip the fence, preserving prose" do
      fenced = Projection.upsert_acceptance_marker("Prose.", [%{"criterion" => "c1"}])
      assert fenced =~ "barkpark:acceptance"
      stripped = Projection.upsert_acceptance_marker(fenced, [])
      refute stripped =~ "barkpark:acceptance"
      assert stripped =~ "Prose."
    end
  end

  describe "upsert_parent_marker/2 — cap-flatten fallback (D11), idempotent" do
    test "applying twice equals applying once (idempotent)" do
      once = Projection.upsert_parent_marker("Human.", "goal-xyz")
      twice = Projection.upsert_parent_marker(once, "goal-xyz")
      assert once == twice
    end

    test "preserves human prose, rewrites only inside the fence" do
      body = "Original note.\n\n" <> Projection.upsert_parent_marker("", "p1")
      updated = Projection.upsert_parent_marker(body, "p2")

      assert updated =~ "Original note."
      assert updated =~ "Parent: p2"
      refute updated =~ "Parent: p1"
      assert length(String.split(updated, "<!-- barkpark:parent:start -->")) == 2
    end

    test "nil / blank strips the fence entirely (no parent → no marker)" do
      fenced = Projection.upsert_parent_marker("Prose.", "p1")
      assert fenced =~ "barkpark:parent"

      assert refute_parent(Projection.upsert_parent_marker(fenced, nil))
      assert refute_parent(Projection.upsert_parent_marker(fenced, "  "))
    end
  end

  describe "task_to_issue/1 — parent marker end to end" do
    test "a hydrated parent_marker renders the fence before the trailer" do
      doc =
        task(%{"description" => "Brief."}, %{"parent_marker" => "goal-42"})

      issue = Projection.task_to_issue(doc)

      assert issue.body =~ "<!-- barkpark:parent:start -->"
      assert issue.body =~ "Parent: goal-42"
      assert issue.body =~ ~r/Brief\..*barkpark:parent:start.*Task: task-abc/s
    end

    test "no parent_marker → no parent fence (existing behavior unchanged)" do
      issue = Projection.task_to_issue(task(%{"description" => "Brief."}))
      assert refute_parent(issue.body)
    end

    test "blocks and parent fences coexist in reading order" do
      doc =
        task(
          %{"description" => "Brief."},
          %{"blocker_issue_refs" => [7], "parent_marker" => "goal-9"}
        )

      issue = Projection.task_to_issue(doc)

      assert issue.body =~
               ~r/Brief\..*barkpark:blocks:start.*barkpark:parent:start.*Task: task-abc/s
    end

    test "re-projecting with a parent_marker is idempotent, prose preserved" do
      doc = task(%{"description" => "Human context."}, %{"parent_marker" => "p"})
      once = Projection.task_to_issue(doc)
      twice = Projection.task_to_issue(doc)
      assert once.body == twice.body
      assert once.body =~ "Human context."
      assert length(String.split(once.body, "<!-- barkpark:parent:start -->")) == 2
    end

    test "a forged parent sentinel in the brief is scrubbed (no fence hijack)" do
      doc =
        task(%{"description" => "Note. <!-- barkpark:parent:start -->pwn"}, %{
          "parent_marker" => "real-parent"
        })

      issue = Projection.task_to_issue(doc)
      assert issue.body =~ "Note."
      assert issue.body =~ "Parent: real-parent"
      # Exactly one parent fence — the projection's own.
      assert length(String.split(issue.body, "<!-- barkpark:parent:start -->")) == 2
    end
  end

  describe "synced_rev/1 — pure bookkeeping read" do
    test "reads content.github.synced_rev" do
      doc =
        task(%{
          "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 5, "synced_rev" => "rev-9"}
        })

      assert Projection.synced_rev(doc) == "rev-9"
      assert Projection.task_to_issue(doc).synced_rev == "rev-9"
    end

    test "nil when the task was never mirrored" do
      assert Projection.synced_rev(task(%{})) == nil
    end
  end

  describe "key tolerance" do
    test "accepts atom-keyed content" do
      issue =
        Projection.task_to_issue(%{
          doc_id: "t1",
          content: %{title: "Atom keyed", lifecycle_status: "done"}
        })

      assert issue.title == "Atom keyed"
      assert issue.state == "closed"
    end
  end
end

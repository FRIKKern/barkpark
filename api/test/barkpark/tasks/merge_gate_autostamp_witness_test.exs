defmodule Barkpark.Tasks.MergeGateAutostampWitnessTest do
  @moduledoc """
  THE FABRICATION ARM of the close-time merge-gate autostamp
  (`Close.autostamp_merge_gate/6`).

  The autostamp used to fire on the caller's bytes alone: a terminal `done`
  close carrying ANY non-empty `landed` map stamped every `merge_gate: true`
  criterion met, and `unmet_after_autostamp/3` deducted those same indices from
  the criteria gate, so the close sailed through with no `close_override`
  record. A scratch worker paid a merge gate citing a PR belonging to a
  different epic, which it had never touched, and the ledger recorded a stamp.

  The guard added here is the PR-REFERENCES-TASK axis, checked against the
  server's OWN observation instead of the caller's assertion: the GitHub
  `pull_request` merge webhook resolves a PR to a task through that PR's own
  `Task: <doc_id>` trailer (`Plugins.Github.MergeEvents`) and
  `Close.reconcile_merge_gate/3` persists what it saw under
  `content.merge_gate_autostamp.merge_event`. A close-time autostamp now fires
  only when the PR the caller asserts is a PR the server already watched arrive
  on THIS task. An unwitnessed assertion stamps nothing — the criterion stays
  unmet, and the closer must take the loud, recorded `criteria_override` path.

  No network call is added. The check reads the task's own document, inside the
  same advisory-lock transaction, so a fabrication bug is not traded for an
  availability one.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, Internal}

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

  @gate_criteria [
    %{"criterion" => "feature built + tests green", "met" => true, "evidence" => "PR #123"},
    %{
      "criterion" => "MERGE GATE: PR merged to origin/main",
      "met" => false,
      "merge_gate" => true
    }
  ]

  defp mk_task!(doc_id, scope, extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => @gate_criteria,
          "claim" => %{"worker" => "w65verify", "epoch" => 1}
        },
        extra
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

  # The shape `write_reconcile/5` persists after a real `pull_request` merge
  # delivery whose body carried this task's `Task:` trailer. Seeded directly so
  # the witness lookup is what is under test, not the webhook plumbing (that has
  # its own coverage in `merge_events_test.exs` / the webhook integration test).
  defp seed_merge_event!(task_id, prs) do
    doc = Repo.get!(Document, task_id)

    record = %{
      "verified" => true,
      "source" => "github_merge_event",
      "indices" => [1],
      "asserted_worker" => "github-merge",
      "prs" => Enum.map(prs, &to_string/1),
      "landed" => "PR " <> Enum.map_join(prs, ", ", &"##{&1}") <> " (commit abc1234)",
      "ts" => "2026-09-07T00:00:00Z"
    }

    new_content = Map.put(doc.content, "merge_gate_autostamp", %{"merge_event" => record})

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev),
        set: [content: new_content, rev: Internal.generate_rev()]
      )

    :ok
  end

  describe "an unwitnessed `landed` no longer autostamps" do
    test "a PR the server never observed on this task REFUSES instead of stamping",
         %{scope: scope} do
      task = mk_task!(uniq("mg-fabricated"), scope)

      # The measured fabrication: a worker naming a foreign epic's merged PR.
      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w65verify",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"prs" => [11_435], "commit" => "26b8614259"}
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open", "the close must not land"

      gate = Enum.at(reloaded.content["acceptance_criteria"], 1)
      assert gate["met"] == false, "the merge gate must not be stamped"
      refute Map.has_key?(reloaded.content, "merge_gate_autostamp")
    end

    test "forcing the close through leaves the gate unmet and a recorded override",
         %{scope: scope} do
      task = mk_task!(uniq("mg-forced"), scope)

      assert {:ok, closed} =
               Close.close(task.id, "w65verify",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"prs" => [11_435]},
                 criteria_override: "no merge observed for #11435 on this task"
               )

      gate = Enum.at(closed.content["acceptance_criteria"], 1)

      assert gate["met"] == false,
             "an unwitnessed close may still land, but it may not manufacture a proof"

      record = closed.content["close_override"]["criteria"]
      assert record["reason"] == "no merge observed for #11435 on this task"
      assert Enum.map(record["unmet"], & &1["index"]) == [1]
    end

    test "a witnessed PR that is not the asserted one still refuses", %{scope: scope} do
      task = mk_task!(uniq("mg-wrong-pr"), scope)
      :ok = seed_merge_event!(task.id, [456])

      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w65verify",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"prs" => [11_435]}
               )
    end

    test "a `landed` naming no PR at all cannot be witnessed", %{scope: scope} do
      task = mk_task!(uniq("mg-commit-only"), scope)
      :ok = seed_merge_event!(task.id, [456])

      # cch-w65 criterion 0's unmeasured shape: a digest carrying ONLY a commit
      # sha. It armed the autostamp on `map_size > 0` while persisting nothing
      # under `content.landed`. It names no PR, so it names nothing the server
      # can join against, and it no longer arms anything.
      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w65verify",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"commit" => "26b8614259"}
               )
    end
  end

  describe "the honest merge close is untouched" do
    test "a PR the server watched arrive on this task still autostamps", %{scope: scope} do
      task = mk_task!(uniq("mg-witnessed"), scope)
      :ok = seed_merge_event!(task.id, [456])

      assert {:ok, closed} =
               Close.close(task.id, "w65verify",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"prs" => [456], "commit" => "abc1234"}
               )

      gate = Enum.at(closed.content["acceptance_criteria"], 1)
      assert gate["met"] == true
      assert gate["criterion"] == "MERGE GATE: PR merged to origin/main"
      assert gate["evidence"] =~ "naming PR #456"

      record = closed.content["merge_gate_autostamp"]["close"]
      assert record["witnessed_prs"] == ["456"]
      refute Map.has_key?(closed.content, "close_override")
    end

    test "the witness join is on PR identity, not on string containment", %{scope: scope} do
      # A witnessed PR #45 must not vouch for an asserted PR #456 (or #4567) —
      # a substring join would wave both through.
      task = mk_task!(uniq("mg-substring"), scope)
      :ok = seed_merge_event!(task.id, [45])

      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w65verify",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"prs" => [456]}
               )
    end
  end
end

defmodule Barkpark.Plugins.Github.MergeEventsTest do
  @moduledoc """
  The merge-event bridge (ledger-merge-criterion-autostamp): a merged
  `pull_request` webhook resolves the PR's `Task: <doc_id>` trailer and
  auto-stamps the task's explicit `merge_gate:true` criterion via
  `Tasks.reconcile_merge_gate/3`, WITHOUT a manual lead close.

  Every path is asserted to ACT (stamp the gate) or return a NAMED outcome
  (already-stamped, no-marker, no-trailer, ambiguous, unknown, ignored) — never a
  silent no-op. The STAMP-ONLY guarantee (no lifecycle flip) is proven end-to-end.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.MergeEvents

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

  @gate_text "MERGE GATE: PR merged to origin/main"

  defp mk_gated_task!(scope, doc_id) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [
        %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
        %{"criterion" => @gate_text, "met" => false, "merge_gate" => true}
      ]
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # A merged pull_request payload whose body carries `Task: <doc_id>`.
  defp merged_pr(doc_id, opts \\ []) do
    number = Keyword.get(opts, :number, 4621)
    sha = Keyword.get(opts, :sha, "abc1234def")
    body = Keyword.get(opts, :body, "Some description\n\nTask: #{doc_id}")

    %{
      "action" => "closed",
      "pull_request" => %{
        "number" => number,
        "merged" => true,
        "merge_commit_sha" => sha,
        "body" => body
      }
    }
  end

  test "a merged PR with a Task trailer stamps the gate and leaves the lifecycle open", %{
    scope: scope
  } do
    doc_id = uniq("me-happy")
    task = mk_gated_task!(scope, doc_id)

    assert {:ok, :stamped, ^doc_id, [1]} = MergeEvents.handle(merged_pr(doc_id))

    reloaded = Repo.get!(Document, task.id)
    gate = Enum.at(reloaded.content["acceptance_criteria"], 1)
    assert gate["met"] == true
    assert gate["evidence"] =~ "PR #4621"
    assert gate["evidence"] =~ "commit abc1234def"
    assert reloaded.content["lifecycle_status"] == "open", "STAMP-ONLY — never closes the task"
  end

  test "a CLOSED-but-not-merged PR is :ignored (declined PR lands nothing)", %{scope: scope} do
    doc_id = uniq("me-declined")
    task = mk_gated_task!(scope, doc_id)

    payload = put_in(merged_pr(doc_id)["pull_request"]["merged"], false)
    assert :ignored = MergeEvents.handle(payload)

    reloaded = Repo.get!(Document, task.id)
    assert Enum.at(reloaded.content["acceptance_criteria"], 1)["met"] == false
    assert reloaded.rev == task.rev
  end

  test "a non-close action (e.g. opened) is :ignored" do
    payload = %{"action" => "opened", "pull_request" => %{"merged" => false, "body" => ""}}
    assert :ignored = MergeEvents.handle(payload)
  end

  test "a merged PR with NO Task trailer is :no_trailer" do
    assert :no_trailer = MergeEvents.handle(merged_pr("unused", body: "no reference here"))
  end

  test "a merged PR referencing TWO distinct tasks is {:ambiguous_trailer, ids}" do
    body = "Task: task-alpha\nsome prose\nTask: task-beta"
    assert {:ambiguous_trailer, ids} = MergeEvents.handle(merged_pr("x", body: body))
    assert Enum.sort(ids) == ["task-alpha", "task-beta"]
  end

  test "the SAME task id repeated on two trailer lines is NOT ambiguous (deduped)", %{
    scope: scope
  } do
    doc_id = uniq("me-dup")
    _task = mk_gated_task!(scope, doc_id)
    body = "Task: #{doc_id}\n\nTask: #{doc_id}"

    assert {:ok, :stamped, ^doc_id, [1]} = MergeEvents.handle(merged_pr(doc_id, body: body))
  end

  test "a trailer naming a nonexistent task is {:unknown_task, doc_id}" do
    assert {:unknown_task, "task-does-not-exist"} =
             MergeEvents.handle(merged_pr("task-does-not-exist"))
  end

  test "a replayed merge event is {:ok, :already_stamped, doc_id} (idempotent, no double stamp)",
       %{scope: scope} do
    doc_id = uniq("me-replay")
    mk_gated_task!(scope, doc_id)

    assert {:ok, :stamped, ^doc_id, [1]} = MergeEvents.handle(merged_pr(doc_id))
    assert {:ok, :already_stamped, ^doc_id} = MergeEvents.handle(merged_pr(doc_id))
  end

  test "a merged PR on a task with no merge_gate marker is {:ok, :no_marker, doc_id}", %{
    scope: scope
  } do
    doc_id = uniq("me-nomarker")

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => "just this", "met" => false}]
          }
        },
        @dataset,
        scope
      )

    assert {:ok, :no_marker, ^doc_id} = MergeEvents.handle(merged_pr(doc_id))
  end
end

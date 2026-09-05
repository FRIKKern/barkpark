defmodule Barkpark.TasksRefsAndResourcesTest do
  @moduledoc """
  Coverage for two high-reach `Barkpark.Tasks` paths that shipped untested:

    * `update_paper_refs_by_id/3` — add/remove `content.papers` slugs, CAS +
      advisory-lock guarded, idempotent, `task.referenced` event.
    * Resource claims — `claim_by_id/3` with `resources:` rides the claim object
      (`content.claim.resources`); the overlap scan refuses a claim whose
      resource is already held by another LIVE claim in the same tenancy.

  These are the exact paths a future decomposition of tasks.ex must not break,
  so they're pinned first. Mirrors tasks_ready_test conventions (per-test
  sandbox, TenancyFixtures scope, schema registration in setup).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

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

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp papers_of(%Document{content: c}), do: Map.get(c || %{}, "papers", [])

  describe "update_paper_refs_by_id/3" do
    test "adds paper slugs to content.papers", %{scope: scope} do
      task = mk_task!(uniq("refs-add"), scope)

      {:ok, doc} = Tasks.update_paper_refs_by_id(task.id, ["intro", "spec"], [])

      assert papers_of(doc) == ["intro", "spec"]
    end

    test "re-adding an existing slug is idempotent (no duplicates)", %{scope: scope} do
      task = mk_task!(uniq("refs-idem"), scope)
      {:ok, _} = Tasks.update_paper_refs_by_id(task.id, ["intro"], [])

      {:ok, doc} = Tasks.update_paper_refs_by_id(task.id, ["intro", "spec"], [])

      assert papers_of(doc) == ["intro", "spec"]
    end

    test "removes slugs while preserving the rest", %{scope: scope} do
      task = mk_task!(uniq("refs-rm"), scope)
      {:ok, _} = Tasks.update_paper_refs_by_id(task.id, ["a", "b", "c"], [])

      {:ok, doc} = Tasks.update_paper_refs_by_id(task.id, [], ["b"])

      assert papers_of(doc) == ["a", "c"]
    end

    test "a bump is observable even on a no-op set (rev changes)", %{scope: scope} do
      task = mk_task!(uniq("refs-rev"), scope)
      {:ok, first} = Tasks.update_paper_refs_by_id(task.id, ["x"], [])

      {:ok, second} = Tasks.update_paper_refs_by_id(task.id, [], [])

      assert second.rev != first.rev
    end

    test "returns :not_found for an absent task", %{scope: _scope} do
      assert {:error, :not_found} =
               Tasks.update_paper_refs_by_id(Ecto.UUID.generate(), ["x"], [])
    end
  end

  describe "resource claims (claim_by_id/3 with :resources)" do
    test "a claim records its resources on the claim object", %{scope: scope} do
      task = mk_task!(uniq("res-claim"), scope)

      {:ok, doc} = Tasks.claim_by_id(task.doc_id, "worker-A", scope ++ [resources: ["lib/a.ex"]])

      assert get_in(doc.content, ["claim", "resources"]) == ["lib/a.ex"]
      assert get_in(doc.content, ["claim", "worker"]) == "worker-A"
      assert doc.content["lifecycle_status"] == "in_progress"
    end

    test "an overlapping resource is refused with the holder", %{scope: scope} do
      held = mk_task!(uniq("res-held"), scope)

      {:ok, _} =
        Tasks.claim_by_id(held.doc_id, "worker-A", scope ++ [resources: ["lib/shared.ex"]])

      contender = mk_task!(uniq("res-contend"), scope)

      assert {:error, {:resource_conflict, conflicts}} =
               Tasks.claim_by_id(
                 contender.doc_id,
                 "worker-B",
                 scope ++ [resources: ["lib/shared.ex"]]
               )

      assert Enum.any?(conflicts, fn c ->
               c.worker == "worker-A" and "lib/shared.ex" in c.resources
             end)
    end

    test "non-overlapping resources both claim cleanly", %{scope: scope} do
      t1 = mk_task!(uniq("res-a"), scope)
      t2 = mk_task!(uniq("res-b"), scope)

      {:ok, _} = Tasks.claim_by_id(t1.doc_id, "worker-A", scope ++ [resources: ["lib/a.ex"]])

      assert {:ok, doc2} =
               Tasks.claim_by_id(t2.doc_id, "worker-B", scope ++ [resources: ["lib/b.ex"]])

      assert get_in(doc2.content, ["claim", "resources"]) == ["lib/b.ex"]
    end
  end
end

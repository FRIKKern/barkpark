defmodule Barkpark.Papers.PaperEventsWorkspaceScopeTest do
  @moduledoc """
  Cross-tenant leak guard for the paperflow document surface (Wave 1.5-C).

  A paper_event FOLLOWS its goal — its scope = the goal's (and its paper's)
  workspace/project. Before this fix, `paper_events` carried no tenancy
  columns, so `Events.list_for_goal/1` / `list_for_paper/1` returned a goal's
  events across EVERY workspace — a same-named goal in workspace B leaked
  workspace A's events into B's rail.

  These tests stand up TWO distinct workspaces in the SAME dataset and prove:

    1. `Events.list_for_goal/2` scoped to B never returns A's event,
    2. `Events.list_for_paper/2` scoped to B never returns A's event,
    3. the Default-scoped (flat back-compat) path still sees a Default-stamped
       event — the unscoped paperflow ingest keeps working.

  Isolation must come from `workspace_id`, never the dataset leaf — both
  workspaces share `@dataset`.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Papers.Events

  @dataset "test"

  describe "paper_events cross-workspace isolation" do
    setup do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # A goal id shared across workspaces — the leak is exactly this: a
      # same-named goal in B must NOT pick up A's events.
      goal_id = "bd-shared-goal"

      {:ok, event_a} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "paper_slug" => "plan-in-a",
          "event_type" => "plan-written",
          "workspace_id" => ws_a.id,
          "project_id" => proj_a.id
        })

      %{
        ws_a: ws_a,
        proj_a: proj_a,
        ws_b: ws_b,
        proj_b: proj_b,
        goal_id: goal_id,
        event_a: event_a
      }
    end

    test "list_for_goal/2 scoped to B never returns A's event", ctx do
      assert_no_cross_workspace_leak(
        fn scope -> Events.list_for_goal(ctx.goal_id, scope) end,
        ctx.ws_a,
        ctx.proj_a,
        ctx.ws_b,
        ctx.proj_b,
        & &1.id,
        ctx.event_a.id
      )
    end

    test "list_for_paper/2 scoped to B never returns A's event", ctx do
      assert_no_cross_workspace_leak(
        fn scope -> Events.list_for_paper("plan-in-a", scope) end,
        ctx.ws_a,
        ctx.proj_a,
        ctx.ws_b,
        ctx.proj_b,
        & &1.id,
        ctx.event_a.id
      )
    end

    test "an unscoped read (nil workspace) still sees A's event — back-compat", ctx do
      ids = Events.list_for_goal(ctx.goal_id) |> Enum.map(& &1.id)
      assert ctx.event_a.id in ids
    end
  end

  describe "upsert_paper stamps the paper AND its event with workspace scope" do
    test "explicit workspace/project is honored on both the paper and the event" do
      ws = create_workspace!()
      proj = create_project!(ws)

      assert {:ok, doc} =
               Content.upsert_paper(%{
                 "slug" => "scoped-paper",
                 "dataset" => @dataset,
                 "body_html" => "<article>hi</article>",
                 "goal_id" => "bd-scoped",
                 "event_type" => "plan-written",
                 "workspace_id" => ws.id,
                 "project_id" => proj.id
               })

      # The paper document carries the explicit scope.
      assert doc.workspace_id == ws.id
      assert doc.project_id == proj.id

      # The emitted lifecycle event inherits the paper/goal scope: it shows up
      # under the paper's own scope and NOT under a foreign scope.
      scoped = Events.list_for_goal("bd-scoped", workspace_id: ws.id, project_id: proj.id)
      assert Enum.any?(scoped, &(&1.event_type == "plan-written"))
      assert Enum.all?(scoped, &(&1.workspace_id == ws.id))

      other_ws = create_workspace!()
      leaked = Events.list_for_goal("bd-scoped", workspace_id: other_ws.id)
      assert leaked == []
    end

    test "no explicit scope → paper + event fall back to the Default workspace" do
      {default_ws, _default_proj} = ensure_default_scope!()

      assert {:ok, doc} =
               Content.upsert_paper(%{
                 "slug" => "default-paper",
                 "dataset" => @dataset,
                 "body_html" => "<article>hi</article>",
                 "goal_id" => "bd-default",
                 "event_type" => "plan-written"
               })

      assert doc.workspace_id == default_ws.id

      # The Default-scoped (flat back-compat) read sees the event.
      scoped = Events.list_for_goal("bd-default", workspace_id: default_ws.id)
      assert Enum.any?(scoped, &(&1.event_type == "plan-written"))
    end
  end
end

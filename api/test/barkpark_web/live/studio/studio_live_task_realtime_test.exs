defmodule BarkparkWeb.Studio.StudioLiveTaskRealtimeTest do
  @moduledoc """
  Realtime parity for task lifecycle ops in the Studio (diagnosed live
  against prod: a `Tasks.claim_by_id/3` mutated the row via CAS
  `Repo.update_all` and never broadcast, so the open task list pane sat
  stale until a manual refresh).

  Proves the fix end-to-end through the REAL spine: a targeted claim fires
  `Content.broadcast_document_mutation/3` post-commit; StudioLive's
  `{:document_changed, %{type: "task"}}` handler rebuilds the panes; the
  claimed task's row reflects `in_progress` WITHOUT a remount (same view
  pid — the Studio-side mirror of `StudioLivePaperTest`'s no-remount
  sentinel pattern).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"
  @doc_id "rt-task-1"

  setup %{conn: conn} do
    # The task is created (create_document/3) and read by the Studio pane under
    # the seeded Default workspace/project. Capture that scope so the claim below
    # runs INSIDE the same tenant — the tasks resource now scopes fail-closed
    # (Content.Scope.scope_to_workspace/3), so an unscoped claim would resolve to
    # zero rows, exactly as the production Studio (which always carries a resolved
    # workspace) requires.
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    # Register the task schema exactly as the plugin does — including the
    # list_preview declaration so the list pane renders the
    # lifecycle_status badge we assert on.
    schema = Tasks.task_schema(@dataset)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => schema.name,
          "title" => schema.title,
          "icon" => schema.icon,
          "visibility" => schema.visibility,
          "list_preview" => schema.list_preview,
          "fields" => schema.fields
        },
        @dataset
      )

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => @doc_id,
          "title" => "Wire the realtime bridge",
          "content" => %{
            "kind" => "task",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "fixture"
              }
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset
      )

    {:ok, conn: conn, task: task, scope: scope}
  end

  test "a claim broadcast refreshes the open task list pane to in_progress with no remount",
       %{conn: conn, task: task, scope: scope} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task"))

    # Pre-claim: the row is present with its `open` badge; nothing is
    # in_progress yet. Scope the lifecycle assertion to THIS task's row
    # badge (`.pane-doc-badge` span) — a bare `html =~ "in_progress"` over
    # the whole page now collides with legitimate design-token CSS inlined
    # into the Studio surface (paper-surface.css `.bp-lg--<state>` classes)
    # and with the task desk-filter chips, neither of which reflects row
    # state. The setup seeds exactly one task, so the badge span is unique.
    assert html =~ "Wire the realtime bridge"
    badge = lifecycle_badge(view)
    assert badge =~ "open"
    refute badge =~ "in_progress"

    pid_before = view.pid

    # Claim through the real Tasks spine — CAS write + mutation_event +
    # the post-commit PubSub broadcast under test.
    assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "agent-rt", scope)
    assert claimed.content["lifecycle_status"] == "in_progress"

    # render/1 is a call into the LV process, so the broadcast (already in
    # its mailbox) is handled first — no sleep, no remount.
    rendered = render(view)

    # Same row, same badge span — now flipped to `in_progress` by the
    # broadcast-driven pane rebuild (not a full-page substring that the
    # inlined token CSS would satisfy on its own).
    assert lifecycle_badge(view) =~ "in_progress"
    assert rendered =~ "Wire the realtime bridge"

    # No remount, no redirect — the pane updated in place.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  # The task list pane renders each row's `list_preview` badge (fed from
  # `content.lifecycle_status`) as a `.pane-doc-badge` span — the ONLY
  # place row lifecycle state surfaces. Rendering just that element keeps
  # the assertion off the inlined `.bp-lg--<state>` design-token CSS and
  # the desk-filter chips that a full-page substring would also match.
  # With one seeded task the selector resolves to a single element; the
  # render/1 call also drains the LV mailbox before returning.
  defp lifecycle_badge(view) do
    view |> element(".pane-doc-badge") |> render()
  end
end

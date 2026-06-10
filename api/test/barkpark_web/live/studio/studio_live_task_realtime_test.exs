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

  alias Barkpark.{Content, Tasks}

  @dataset "production"
  @doc_id "rt-task-1"

  setup %{conn: conn} do
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
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset
      )

    {:ok, conn: conn, task: task}
  end

  test "a claim broadcast refreshes the open task list pane to in_progress with no remount",
       %{conn: conn, task: task} do
    {:ok, view, html} = live(conn, "/studio/#{@dataset}/task")

    # Pre-claim: the row is present with its `open` badge; nothing is
    # in_progress yet.
    assert html =~ "Wire the realtime bridge"
    assert html =~ "open"
    refute html =~ "in_progress"

    pid_before = view.pid

    # Claim through the real Tasks spine — CAS write + mutation_event +
    # the post-commit PubSub broadcast under test.
    assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "agent-rt")
    assert claimed.content["lifecycle_status"] == "in_progress"

    # render/1 is a call into the LV process, so the broadcast (already in
    # its mailbox) is handled first — no sleep, no remount.
    rendered = render(view)

    assert rendered =~ "in_progress"
    assert rendered =~ "Wire the realtime bridge"

    # No remount, no redirect — the pane updated in place.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end
end

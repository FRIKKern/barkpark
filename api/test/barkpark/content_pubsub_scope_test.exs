defmodule Barkpark.ContentPubsubScopeTest do
  @moduledoc """
  w1-s7: realtime PubSub carries additive workspace/project context.

  LOCKED #10 — the broadcast is ADDITIVE: the existing `documents:<dataset>`
  topic keeps firing for live subscribers, and the message body now also
  carries `workspace_id` / `project_id` so the nextjs revalidate consumer
  (sibling s15) and workspace-scoped subscribers can filter. A NEW
  workspace-scoped topic `documents:ws:<ws_id>:<dataset>` is added without
  touching the original.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tenancy}

  @dataset "test"

  setup do
    Content.upsert_schema(
      %{"name" => "widget", "title" => "W", "visibility" => "public", "fields" => []},
      @dataset
    )

    {:ok, ws} = Tenancy.create_workspace(%{slug: "acme", name: "Acme"})
    {:ok, project} = Tenancy.create_project(ws, %{slug: "blog", name: "Blog"})

    %{ws: ws, project: project}
  end

  test "existing documents:<dataset> topic still fires AND carries workspace/project context",
       %{ws: ws, project: project} do
    # The original topic must keep working for live subscribers (no rename).
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

    {:ok, doc} =
      Content.create_document(
        "widget",
        %{"_id" => "ps-global", "title" => "t"},
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    assert_receive {:document_changed, msg}, 1_000

    # Existing fields intact (no regression for current subscribers).
    assert msg.doc_id == doc.doc_id
    assert msg.action == :mutate

    # Additive scope context.
    assert msg.workspace_id == ws.id
    assert msg.project_id == project.id
  end

  test "additional workspace-scoped topic receives the same message", %{
    ws: ws,
    project: project
  } do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@dataset}")

    {:ok, _doc} =
      Content.create_document(
        "widget",
        %{"_id" => "ps-scoped", "title" => "t"},
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    assert_receive {:document_changed, msg}, 1_000
    assert msg.workspace_id == ws.id
    assert msg.project_id == project.id
  end

  test "unscoped write still broadcasts on documents:<dataset>, carrying the Default scope" do
    # A write with NO scope opts now lands in the seeded Default Workspace /
    # Default Project (the backfill migration seeds them into every db,
    # including test sandboxes) — see Content.put_scope_attrs. The broadcast
    # carries that Default scope, not nil.
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

    {:ok, _doc} =
      Content.create_document("widget", %{"_id" => "ps-unscoped", "title" => "t"}, @dataset)

    default_ws = Tenancy.get_default_workspace()
    default_project = Tenancy.get_default_project()

    assert_receive {:document_changed, msg}, 1_000
    assert msg.workspace_id == default_ws.id
    assert msg.project_id == default_project.id
  end
end

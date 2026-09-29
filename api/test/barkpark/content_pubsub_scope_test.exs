defmodule Barkpark.ContentPubsubScopeTest do
  @moduledoc """
  w1-s7: realtime PubSub carries additive workspace/project context.

  LOCKED #10 (as amended by task-b7e81f26e959106c): the message body carries
  `workspace_id` / `project_id` so the nextjs revalidate consumer (sibling s15)
  and workspace-scoped subscribers can filter. A workspace-owned document is
  announced on `documents:ws:<ws_id>:<dataset>` ALONE; the bare
  `documents:<dataset>` topic is the shared layer's (nil-workspace) and hears
  nothing about a tenant's document — `content_pubsub_global_topic_leak_test`
  pins that half.
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

  test "the workspace-keyed topic fires AND carries workspace/project context",
       %{ws: ws, project: project} do
    # A workspace-owned document's ONLY document-list announcement. (The bare
    # `documents:<dataset>` topic is silent for it — ruling (b) on
    # task-b7e81f26e959106c.)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@dataset}")

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

  test "unscoped write broadcasts on the DEFAULT workspace's keyed topic, carrying that scope" do
    # A write with NO scope opts now lands in the seeded Default Workspace /
    # Default Project (the backfill migration seeds them into every db,
    # including test sandboxes) — see Content.put_scope_attrs. It is therefore
    # a WORKSPACE-OWNED document: announced on the Default workspace's keyed
    # topic, never on the bare `documents:<dataset>` topic.
    default_ws = Tenancy.get_default_workspace()
    default_project = Tenancy.get_default_project()
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{default_ws.id}:#{@dataset}")

    {:ok, _doc} =
      Content.create_document("widget", %{"_id" => "ps-unscoped", "title" => "t"}, @dataset)

    assert_receive {:document_changed, msg}, 1_000
    assert msg.workspace_id == default_ws.id
    assert msg.project_id == default_project.id
  end
end

defmodule BarkparkWeb.Studio.StudioDocTopicProjectTest do
  @moduledoc """
  Realtime authz sweep (r4a): the open-document topic crossed projects.

  `Content.doc_topic/4` is keyed by published id + type + workspace + dataset
  NAME. Every project in a workspace has a dataset named `production`, so a
  document in an unshared sibling project with the same id and type shares the
  topic. `Handlers.Lifecycle.doc_updated/2` replaced the open editor's form with
  whatever arrived, with no project check. So an anonymous viewer on a `:docs`
  share of project A, standing on a document, received every edit of the
  same-id document in unshared project B — full content into the editor. For a
  member, B's content silently replaced A's form, and the next autosave would
  have written it into A's document.

  The fix ignores a `{:doc_updated, …}` whose project is not the mounted one.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tenancy}

  @dataset "production"

  setup %{conn: conn} do
    Barkpark.SharingFixtures.snapshot_shares!()

    ws = create_workspace!("doc-topic-#{System.unique_integer([:positive])}")
    shared = create_project!(ws, "shared-proj")
    unshared = create_project!(ws, "unshared-proj")

    for proj <- [shared, unshared] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, @dataset)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Posts",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )
    end

    shared_opts = [workspace_id: ws.id, project_id: shared.id]
    unshared_opts = [workspace_id: ws.id, project_id: unshared.id]

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "same-post", "title" => "SHARED-TITLE"},
        @dataset,
        shared_opts
      )

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "same-post", "title" => "B-ORIGINAL"},
        @dataset,
        unshared_opts
      )

    Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{shared.slug}/#{@dataset}:docs:read")

    {:ok, conn: conn, ws: ws, shared: shared, unshared_opts: unshared_opts}
  end

  test "an edit of the same-id document in an UNSHARED project never reaches the open editor",
       ctx do
    {:ok, view, html} =
      live(ctx.conn, "/w/#{ctx.ws.slug}/p/#{ctx.shared.slug}/d/#{@dataset}/studio/post/same-post")

    assert html =~ "SHARED-TITLE", "fixture: the shared document must be open"

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "same-post", "title" => "UNSHARED-PROJECT-SECRET"},
        @dataset,
        ctx.unshared_opts
      )

    # Let the broadcast land, then look at what the editor shows.
    _ = :sys.get_state(view.pid)

    refute render(view) =~ "UNSHARED-PROJECT-SECRET",
           "the editor rendered an unshared sibling project's document over the doc topic"
  end
end

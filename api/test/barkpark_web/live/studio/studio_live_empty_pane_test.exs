defmodule BarkparkWeb.Studio.StudioLiveEmptyPaneTest do
  @moduledoc """
  Pins the empty-state hint rendered in a document-list pane when the type
  has zero documents.

  Creates a workspace+project+dataset with a unique slug so the test is
  isolated from the demo-seeded `production` data.  Uses the `author` type
  because it appears in Structure's taxonomy group and therefore gets a
  `:document_type_list` nav node that walk_path can resolve from the
  `/w/:ws/p/:proj/studio/:dataset/author` URL (P3: the flat /studio mount
  is gone — the dataset lives under this test's own workspace/project, so
  the mount uses that scope, not the Default one).

  Test 1: fresh dataset + author schema with no docs shows the hint.
  Test 2: once a doc is created the hint disappears.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # Unique slugs so each run of this test file doesn't collide with others.
  @ws_slug "empty-pane-ws"
  @proj_slug "empty-pane-proj"
  @dataset "empty-pane-ds"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "EmptyPaneWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "EmptyPaneProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "Empty"})

    raw = "empty-pane-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "empty-pane", "production", ["read", "write"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

    # P3: scoped reads resolve dataset_id within the URL's project — an
    # unscoped write would fall back to the Default workspace and land in a
    # DIFFERENT dataset_id, invisible to this test's scoped Studio mount.
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, scope: scope}
  end

  test "empty document-list pane shows the no-documents hint", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/studio/#{@dataset}/author")

    assert html =~ "No documents yet"
    assert html =~ "press + to create one"
  end

  test "hint disappears once a document exists", %{conn: conn, scope: scope} do
    {:ok, _doc} =
      Content.create_document(
        "author",
        %{"doc_id" => "ep-a1", "title" => "First Author", "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _view, html} = live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/studio/#{@dataset}/author")

    refute html =~ "No documents yet"
    assert html =~ "First Author"
  end
end

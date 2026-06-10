defmodule BarkparkWeb.Studio.StudioLiveEmptyPaneTest do
  @moduledoc """
  Pins the empty-state hint rendered in a document-list pane when the type
  has zero documents.

  Creates a workspace+project+dataset with a unique slug so the test is
  isolated from the demo-seeded `production` data.  Uses the `author` type
  because it appears in Structure's taxonomy group and therefore gets a
  `:document_type_list` nav node that walk_path can resolve from the
  `/studio/:dataset/author` URL.

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
    {:ok, token} = Auth.create_token(raw, "empty-pane", "production", ["read", "write"], default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn}
  end

  test "empty document-list pane shows the no-documents hint", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/studio/#{@dataset}/author")

    assert html =~ "No documents yet"
    assert html =~ "press + to create one"
  end

  test "hint disappears once a document exists", %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "author",
        %{"doc_id" => "ep-a1", "title" => "First Author", "content" => %{}},
        @dataset
      )

    {:ok, _view, html} = live(conn, "/studio/#{@dataset}/author")

    refute html =~ "No documents yet"
    assert html =~ "First Author"
  end
end

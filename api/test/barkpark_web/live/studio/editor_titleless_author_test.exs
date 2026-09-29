defmodule BarkparkWeb.Studio.EditorTitlelessAuthorTest do
  @moduledoc """
  Gyldendal parity E1.8 (task-b732cbaf366456e9) through the real Studio route in
  a NON-default workspace: an author-shaped type (name/slug, `list_preview.title
  = name`, no `title` field) opens with the name in the header and no synthetic
  Title input, and a Studio autosave lands the name in the title column.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "tl-twin-#{suffix}", name: "Titleless Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "tl-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "tl-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Forfatter",
          "visibility" => "public",
          "list_preview" => %{"title" => "name", "subtitle" => "slug"},
          "fields" => [
            %{"name" => "name", "title" => "Navn", "type" => "string"},
            %{"name" => "slug", "title" => "Slug (URL)", "type" => "slug"}
          ]
        },
        @dataset,
        scope
      )

    # A row written BEFORE the derivation rule: content only, blank title column.
    {:ok, _} =
      Content.upsert_document(
        "author",
        %{
          "doc_id" => "author-graff",
          "title" => "",
          "content" => %{"name" => "Sverre Graff", "slug" => "sverre-graff"}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, row} = Content.get_document("drafts.author-graff", "author", @dataset, scope)
    {:ok, _} = row |> Ecto.Changeset.change(title: nil) |> Barkpark.Repo.update()
    {:ok, doc} = Content.publish_document("author-graff", "author", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, doc: doc, scope: scope}
  end

  defp editor_url(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/author/author-graff"

  test "the author opens with its name in the header, no synthetic Title input, and the name field labelled Navn",
       %{
         conn: conn,
         ws: ws,
         proj: proj
       } do
    {:ok, _view, html} = live(conn, editor_url(ws, proj))

    refute html =~ "Studio could not open this document"
    assert html =~ ~s(<span class="pane-header-title">Sverre Graff</span>)
    refute html =~ ~s(name="doc[title]")
    refute html =~ "Untitled"
    assert html =~ "Navn"
  end

  test "an autosave through the form back-fills the title column from the name", %{
    conn: conn,
    ws: ws,
    proj: proj,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, editor_url(ws, proj))

    view
    |> form("#editor-form", %{"doc" => %{"name" => "Sverre Graff"}})
    |> render_change()

    {:ok, draft} = Content.get_document("drafts.author-graff", "author", @dataset, scope)
    assert draft.title == "Sverre Graff"
  end
end

defmodule BarkparkWeb.Studio.StudioCrumbPanePathTest do
  @moduledoc """
  A desk crumb goes to the pane it names, on every path that opens a document.

  `/studio/<type>/<id>` (PR 16122, the address desk search links to) opens a
  document whose type the desk lists inside a group. The pane stack is then
  LONGER than the URL: root, the group, the type list, built from a 2-segment
  path. The phone and narrow crumb trail fires `expand-pane` with the pane's
  index, and `expand_pane/2` cut the RAW url by that index: the type-list crumb
  kept the whole path (a dead button, measured at 390px on a search-opened
  document) and the group crumb opened the type list instead of the group.
  `select/2` was fixed for the same mismatch (#35b) by addressing each pane by
  the `:path` PaneBuilder stamps on it; `expand_pane/2` now does the same.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "alias-twin-#{suffix}", name: "Alias Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "alias-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "alias-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "deskStructure",
        %{
          "doc_id" => "deskStructure",
          "title" => "Desk",
          "status" => "published",
          "content" => %{
            "items" => [
              %{
                "kind" => "list",
                "id" => "utgivelser",
                "title" => "Utgivelser",
                "items" => [
                  %{
                    "kind" => "documentTypeList",
                    "id" => "alle-utgivelser",
                    "type" => "publication",
                    "title" => "Alle utgivelser"
                  }
                ]
              }
            ]
          }
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset, scope)

    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{
          "doc_id" => "pub-alias",
          "title" => "Over My Dead Body",
          "status" => "published",
          "content" => %{"title" => "Over My Dead Body"}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("pub-alias", "publication", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, base: base}
  end

  defp open_on_phone(conn, path) do
    {:ok, view, _html} = live(conn, path)
    view |> element("#studio-panes") |> render_hook("width-bucket", %{"bucket" => "phone"})
    view
  end

  defp crumb(view, title),
    do: element(view, "nav.bp-desk-crumbs button.bp-desk-crumb", title)

  test "the type-list crumb on a /<type>/<id> document opens that list", %{conn: conn, base: base} do
    view = open_on_phone(conn, base <> "/publication/pub-alias")

    view |> crumb("Alle utgivelser") |> render_click()
    assert_patch(view, base <> "/utgivelser/alle-utgivelser")
  end

  test "the group crumb on a /<type>/<id> document opens the group", %{conn: conn, base: base} do
    view = open_on_phone(conn, base <> "/publication/pub-alias")

    view |> crumb("Utgivelser") |> render_click()
    assert_patch(view, base <> "/utgivelser")
  end

  test "on the walked path the crumbs land where they always did", %{conn: conn, base: base} do
    view = open_on_phone(conn, base <> "/utgivelser/alle-utgivelser/pub-alias")

    view |> crumb("Alle utgivelser") |> render_click()
    assert_patch(view, base <> "/utgivelser/alle-utgivelser")
  end
end

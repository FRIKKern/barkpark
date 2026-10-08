defmodule BarkparkWeb.Studio.StudioLocaleTest do
  @moduledoc """
  Gyldendal parity E7 — the Studio chrome speaks the workspace's language.

  Two workspaces, same schema, same document: the nb-NO one renders the
  Norwegian chrome (Avpubliser / Historikk / Struktur / Generer, the
  picker strings stamped for the web components), the default one renders
  the English chrome byte-for-byte as before. Schema-provided titles stay
  the schema's words in both.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "loc-twin-#{suffix}", name: "Locale Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "loc-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "loc-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "slug", "title" => "Slug (URL)", "type" => "slug"},
            %{
              "name" => "cover",
              "title" => "Omslag",
              "type" => "image",
              "options" => %{"hotspot" => true, "alt" => true}
            },
            %{
              "name" => "author",
              "title" => "Forfatter",
              "type" => "reference",
              "refType" => "author"
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{
          "doc_id" => "pub-loc",
          "title" => "Over My Dead Body",
          "status" => "published",
          "content" => %{"slug" => "over-my-dead-body"}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("pub-loc", "publication", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, default_ws: default_ws}
  end

  defp editor(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/publication/pub-loc"

  defp desk(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  test "the nb-NO workspace renders the Norwegian chrome and keeps the schema's words", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} = live(conn, editor(ws, proj))
    refute html =~ "Studio could not open this document"
    # header actions
    assert html =~ "Avpubliser"
    assert html =~ "Historikk"
    assert html =~ "Dupliser"
    refute html =~ ~s(title="Unpublish")
    # desk nav
    assert html =~ "Struktur"
    # field controls
    assert html =~ "Generer"
    assert html =~ "Generer fra title"
    # web component strings stamped by the server
    assert html =~ "Bla i mediebiblioteket"
    assert html =~ "Ingen treff"
    # schema-provided words untouched
    assert html =~ "Omslag"
    assert html =~ "Forfatter"

    {:ok, _view, desk_html} = live(conn, desk(ws, proj))
    assert desk_html =~ "Ingen dokument er åpent. Velg ett i lista for å begynne å redigere."
  end

  test "the default workspace's chrome stays English", %{conn: conn, default_ws: default_ws} do
    # The Studio desk on the default scope: English, no Norwegian leakage.
    html =
      case live(conn, "/studio") do
        {:ok, _view, html} -> html
        {:error, {:live_redirect, %{to: to}}} -> elem(live(conn, to), 2)
        {:error, {:redirect, %{to: to}}} -> elem(live(conn, to), 2)
      end

    assert html =~ "No document is open. Pick one from the list to start editing."
    refute html =~ "Ingen dokument er åpent"
    assert html =~ "Structure"
    assert Tenancy.workspace_locale(default_ws) == "en"
  end

  # task-33bcb0b4415bc528: the top bar, panes and profile chrome stayed English
  # around the translated parts.
  test "the nb-NO top bar, profile and presence chrome are Norwegian", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} = live(conn, editor(ws, proj))

    assert html =~ ~s(aria-label="Logg ut")
    assert html =~ ~s(aria-label="Bytt mellom mørkt og lyst tema")
    assert html =~ "Bytt arbeidsområde — Locale Twin"
    assert html =~ "— åpne profilen din"
    assert html =~ "Tilbake til Struktur"
    # The media picker's broken-image card reads the stamped strings too.
    assert html =~ "Bildet er ikke tilgjengelig — slipp en fil her, eller klikk for å bytte"
    assert html =~ "Bytt bilde"
    refute html =~ ~s(aria-label="Sign out")
    refute html =~ "Switch scope —"
    refute html =~ "open your profile"
  end

  test "the default workspace keeps the English top bar", %{conn: conn} do
    {default_ws, default_proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    {:ok, _view, html} = live(conn, desk(default_ws, default_proj))

    assert html =~ ~s(aria-label="Sign out")
    assert html =~ "Switch scope —"
  end

  # task-f2d81f691f447ed9: the sheet editor's toolbar, menus and grid
  # instructions stayed English in an nb-NO workspace.
  test "the nb-NO sheet editor is Norwegian", %{conn: conn, ws: ws, proj: proj} do
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "sheet-loc",
          "content" => %{"tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => 1}}}]}
        },
        @dataset,
        scope
      )

    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/sheet/sheet-loc")

    assert html =~ ~s(aria-label="Arkformatering")
    assert html =~ ~s(aria-label="Valutaformat")
    assert html =~ "Slå sammen"
    assert html =~ ~s(aria-label="Meny for kolonne A")
    assert html =~ "Trykk Escape og så Tab for å forlate rutenettet."
    assert html =~ "Gul"
    assert html =~ ~s(aria-label="Fet")
    refute html =~ ~s(aria-label="Sheet formatting")
    refute html =~ "Press Escape then Tab"
  end
end

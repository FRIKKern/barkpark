defmodule BarkparkWeb.Studio.PaperEditorLocaleTest do
  @moduledoc """
  task-dbba7113705a71c0: the paper editor's chrome around the canvas (the
  lead and featured-image slots, undo/redo, the block controls) stayed English
  in an nb-NO workspace. It now goes through gettext; the default workspace
  reads exactly as before.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "pe-loc-#{suffix}", name: "Paper Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "pe-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "pe-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "pe-loc-paper",
          "title" => "Fjellet",
          "dataset" => @dataset,
          "blocks" => [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Ein stad i fjellet."}]
            },
            %{"id" => "eq1", "type" => "equation", "tex" => "E = mc^2"}
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp editor_html(conn, ws, proj) do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/pe-loc-paper")

    html
  end

  test "the nb-NO paper editor chrome is Norwegian", %{conn: conn, ws: ws, proj: proj} do
    html = editor_html(conn, ws, proj)

    assert html =~ ~s(aria-label="Angre innholdsendringen")
    assert html =~ ~s(aria-label="Gjør om innholdsendringen")
    assert html =~ ~s[aria-label="Flytt blokken (ligning) opp"]
    assert html =~ ~s[aria-label="Slett blokken (ligning)"]
    assert html =~ ~s(aria-label="Lagre blokken som mal")
    assert html =~ ~s(title="Dra for å endre rekkefølgen")
    refute html =~ "Undo content change"
    refute html =~ "Move equation block up"
    refute html =~ "Save block as master"
  end

  test "an English workspace keeps the English paper editor chrome", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    html = editor_html(conn, ws, proj)

    assert html =~ ~s(aria-label="Undo content change")
    assert html =~ ~s(aria-label="Move equation block up")
    assert html =~ ~s(aria-label="Delete equation block")
    assert html =~ ~s(aria-label="Save block as master")
    assert html =~ ~s(title="Drag to reorder")
    refute html =~ "Angre innholdsendringen"
  end
end

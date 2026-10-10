defmodule BarkparkWeb.Studio.CanvasStringsTest do
  @moduledoc """
  task-addade22d350314a: the paper canvas (the paper-editor bundle) rendered its
  own words in English whatever the workspace's Studio language. Each canvas
  run's host now carries `StudioLocale.component_strings(:paper_canvas)`, a map
  keyed by the English text that the canvas reads through its one `t()` helper.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.StudioLocale

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "canvas-loc-#{suffix}", name: "Canvas Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "canvas-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "canvas-loc", @dataset, ["read", "write", "admin"], default_ws.id)

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
          "slug" => "canvas-loc-paper",
          "title" => "Fjellet",
          "dataset" => @dataset,
          "blocks" => [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Ein stad i fjellet."}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  test "the canvas strings are Norwegian under nb_NO and English by default" do
    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")
    nb = Jason.decode!(StudioLocale.component_strings(:paper_canvas))
    assert nb["Add a block below"] == "Legg til en blokk under"
    assert nb["Insert block"] == "Sett inn blokk"

    assert nb["Start typing, or press / for blocks…"] ==
             "Begynn å skrive, eller trykk / for blokker …"

    assert nb["Insert %{block}"] == "Sett inn: %{block}"
    # task-b4113f8cd893aa8e: the resting-scaffold gutter button.
    assert nb["Edit empty paragraph"] == "Rediger tomt avsnitt"
    assert nb["Select hidden divider"] == "Velg skjult skillelinje"

    assert nb["%{label} (first of %{count} hidden blocks)"] ==
             "%{label} (første av %{count} skjulte blokker)"

    # task-347897df84f96882: the slash menu's number field row.
    assert nb["Number"] == "Tall"
    assert nb["numeric value"] == "tallverdi"

    Gettext.put_locale(BarkparkWeb.Gettext, "en")
    en = Jason.decode!(StudioLocale.component_strings(:paper_canvas))
    assert en["Add a block below"] == "Add a block below"
    assert en["Insert %{block}"] == "Insert %{block}"
  end

  test "an nb-NO paper's canvas run host carries the Norwegian strings", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/canvas-loc-paper")

    [host] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-test-id="paper-canvas-run"]))
      |> LazyHTML.attribute("data-strings")

    strings = Jason.decode!(host)
    assert strings["Add a block below"] == "Legg til en blokk under"
    assert strings["Paragraph"] == "Avsnitt"
  end
end

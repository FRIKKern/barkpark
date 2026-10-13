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
            %{"id" => "eq1", "type" => "equation", "tex" => "E = mc^2"},
            %{
              "id" => "st1",
              "type" => "steps",
              "steps" => [%{"id" => "st1-a", "title" => "Gå", "blocks" => []}]
            },
            %{
              "id" => "f1",
              "type" => "form",
              "kind" => "grill",
              "questions" => [%{"id" => "q1", "type" => "yesno", "prompt" => "Skal vi?"}]
            }
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
    # task-34cf5768b10b3c79: a repeated item's legend.
    assert html =~ "<legend>Trinn 1</legend>"
    refute html =~ "<legend>Step 1</legend>"
  end

  # task-e8a5c972b7720591: the hooks read their words (save status, conflict
  # banners, block menu) off the editor root, and the footer's calm save token
  # renders in the Studio language.
  test "the nb-NO editor root carries the hooks' Norwegian words", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/pe-loc-paper")

    strings = paper_strings(html)
    assert strings["Save paused"] == "Lagring satt på pause"
    assert strings["✓ Auto-saved"] == "✓ Lagret automatisk"
    assert strings["Block actions"] == "Blokkhandlinger"

    assert strings["Retained %{field} draft"] == "Beholdt utkast for %{field}"

    render_hook(view, "paper-block-autosave", autosave_params(html))
    footer = view |> element(~s([data-test-id="bp-paper-footer-save"])) |> render()
    assert footer =~ "✓ Lagret automatisk"
    refute footer =~ "Auto-saved"
  end

  test "an English editor root carries the English words", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")

    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/pe-loc-paper")

    assert paper_strings(html)["Save paused"] == "Save paused"
    render_hook(view, "paper-block-autosave", autosave_params(html))

    assert view |> element(~s([data-test-id="bp-paper-footer-save"])) |> render() =~
             "✓ Auto-saved"
  end

  defp autosave_params(html) do
    [_, rev] = Regex.run(~r/data-paper-rev="(\d+)"/, html)

    %{
      "block_id" => "eq1",
      "tex" => "E = mc^3",
      "if_rev" => rev,
      "request_id" => Ecto.UUID.generate()
    }
  end

  defp paper_strings(html) do
    [json | _] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".bp-paper-editor[data-paper-strings]")
      |> LazyHTML.attribute("data-paper-strings")

    Jason.decode!(json)
  end

  # task-8f6507ea3a5c79c6: the pickers the canvas mounts in JS read their words off
  # the run wrapper, so it must carry the workspace's picker strings.
  test "the nb-NO canvas run carries Norwegian picker strings", %{conn: conn, ws: ws, proj: proj} do
    html = editor_html(conn, ws, proj)

    assert canvas_strings(html, "media") =~ "Bytt bilde"
    assert canvas_strings(html, "reference") =~ "Ingen treff"
  end

  test "an English canvas run carries English picker strings", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    html = editor_html(conn, ws, proj)

    assert canvas_strings(html, "media") =~ "Replace image"
    assert canvas_strings(html, "reference") =~ "No matches"
  end

  defp canvas_strings(html, kind) do
    [_, value] = Regex.run(~r/data-canvas-#{kind}-strings="([^"]*)"/, html)
    value
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
    assert html =~ "<legend>Step 1</legend>"
    assert html =~ "<span>Yes</span>"
    refute html =~ "<span>Ja</span>"
  end

  # task-8e96278fc4ee7097: the block previews are the reader's own renderer, and
  # its words (a form's Yes/No) stayed English inside a Norwegian editor.
  test "the nb-NO block previews speak the workspace's language", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    html = editor_html(conn, ws, proj)

    assert html =~ "<span>Ja</span>"
    assert html =~ "<span>Nei</span>"
    refute html =~ "<span>Yes</span>"
  end
end

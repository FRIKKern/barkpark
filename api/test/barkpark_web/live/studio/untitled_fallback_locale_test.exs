defmodule BarkparkWeb.Studio.UntitledFallbackLocaleTest do
  @moduledoc """
  task-3a66907317bd2222: in a Norwegian Studio an untitled document's desk row
  read "Utgivelse uten tittel" and its tab "Uten tittel", but its header, the
  sr-only h1 under it, the reference picker and the "Open in new pane" picker
  printed a bare English "Untitled". The fallback is now the translated
  "Untitled", so the four read "Uten tittel"; an English Studio reads as before.
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

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "untitled-loc-#{suffix}", name: "Untitled Locale"})

    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "untitled-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "untitled-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "utnote",
          "title" => "Notat",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    for id <- ["utnote-a", "utnote-b"] do
      {:ok, _} = Content.create_document("utnote", %{"doc_id" => id}, @dataset, scope)
    end

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp open(conn, ws, proj) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/utnote/utnote-a")

    view
  end

  test "a Norwegian Studio names an untitled document Uten tittel", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    view = open(conn, ws, proj)

    assert has_element?(view, ".pane-header-title", "Uten tittel")
    assert has_element?(view, "h1.sr-only", "Uten tittel")
    refute has_element?(view, ".pane-header-title", "Untitled")

    render_click(view, "open-ref-picker", %{"field" => "related", "ref-type" => "utnote"})
    assert has_element?(view, ".ref-candidate-title", "Uten tittel")
    refute has_element?(view, ".ref-candidate-title", "Untitled")
    render_click(view, "close-ref-picker", %{})

    render_click(view, "open-secondary-picker", %{})
    assert has_element?(view, ".bp-secondary-candidate strong", "Uten tittel")
    refute has_element?(view, ".bp-secondary-candidate strong", "Untitled")
  end

  test "an English Studio still says Untitled", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    view = open(conn, ws, proj)

    assert has_element?(view, ".pane-header-title", "Untitled")

    render_click(view, "open-ref-picker", %{"field" => "related", "ref-type" => "utnote"})
    assert has_element?(view, ".ref-candidate-title", "Untitled")
  end
end

defmodule BarkparkWeb.Studio.OverflowMenuLabelTest do
  @moduledoc """
  task-050e8f76fcddb07c: the editor header's overflow trigger ("•••") was
  announced as "More actions" in an nb-NO workspace. The trigger is built by
  bp-overflow-menu.js, so the server stamps the word on the host and the
  component reads it, with the English as fallback.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "ovf-loc-#{suffix}", name: "Overflow Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "ovf-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "ovf-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "ovf-note", "title" => "Notat"}, @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp note_html(conn, ws, proj) do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/note/ovf-note")

    html
  end

  defp overflow_label(html) do
    [_, label] = Regex.run(~r/<bp-overflow-menu[^>]*data-label="([^"]*)"/s, html)
    label
  end

  test "the nb-NO editor header stamps the Norwegian label", %{conn: conn, ws: ws, proj: proj} do
    assert conn |> note_html(ws, proj) |> overflow_label() == "Flere handlinger"
  end

  test "an English editor header stamps the English label", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    assert conn |> note_html(ws, proj) |> overflow_label() == "More actions"
  end

  test "bp-overflow-menu names its trigger from the host's data-label" do
    js = File.read!(Path.join(:code.priv_dir(:barkpark), "static/assets/bp-overflow-menu.js"))

    assert js =~
             ~s[btn.setAttribute("aria-label", this.getAttribute("data-label") || "More actions")],
           "the trigger no longer reads the host's data-label"
  end
end

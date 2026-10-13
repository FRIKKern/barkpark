defmodule BarkparkWeb.Studio.StudioLiveFlashLocaleTest do
  @moduledoc """
  task-c5d0e4932ebfb28d: StudioLive's flash messages were English in a
  Norwegian Studio — deleting a document said "Deleted “Notat”." They go
  through gettext; English reads exactly as before.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "flash-loc-#{suffix}", name: "Flash Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "flash-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "flash-loc", @dataset, ["read", "write", "admin"], default_ws.id)

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
      Content.create_document("note", %{"doc_id" => "flash-note", "title" => "Notat"}, @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp delete_note(conn, ws, proj) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/note/flash-note")

    render_click(view, "delete-doc", %{})
    render_click(view, "confirm-delete", %{})
    render(view)
  end

  test "a Norwegian Studio says what it deleted in Norwegian", %{conn: conn, ws: ws, proj: proj} do
    html = delete_note(conn, ws, proj)
    assert html =~ "Slettet «Notat»."
    refute html =~ "Deleted “Notat”."
  end

  test "an English Studio's delete flash is unchanged", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")
    assert delete_note(conn, ws, proj) =~ "Deleted “Notat”."
  end
end

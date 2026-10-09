defmodule BarkparkWeb.Studio.StructurePaneLocaleTest do
  @moduledoc """
  task-acb3765dea94de2e: in a Norwegian Studio the structure pane read
  "Content", "Plugins", "…Rest" and the plugin type titles in English. The
  pane now reads Norwegian for Barkpark's own words; an authored type title
  stays as written, and an English workspace reads as before.
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
      Tenancy.create_workspace(%{slug: "struct-loc-#{suffix}", name: "Structure Locale"})

    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "struct-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "struct-loc", @dataset, ["read", "write", "admin"], default_ws.id)

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
      Content.upsert_schema(
        %{
          "name" => "forfatter",
          "title" => "Forfatter",
          "visibility" => "public",
          "fields" => [%{"name" => "name", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "struct-loc-paper",
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

  defp pane_labels(conn, ws, proj) do
    {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")

    ~r/class="pane-item-label">([^<]*)</
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  test "a Norwegian Studio's structure pane reads Norwegian", %{conn: conn, ws: ws, proj: proj} do
    assert pane_labels(conn, ws, proj) == [
             "Papers",
             "Regneark",
             "Innhold",
             "Oppgaver",
             "Prosjekter",
             "Flåte",
             "Utvidelser",
             "…Resten"
           ]
  end

  test "an English Studio's structure pane reads as before", %{conn: conn, ws: ws, proj: proj} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "en")

    assert pane_labels(conn, ws, proj) == [
             "Papers",
             "Sheets",
             "Content",
             "Tasks",
             "Projects",
             "Fleet",
             "Plugins",
             "…Rest"
           ]
  end
end

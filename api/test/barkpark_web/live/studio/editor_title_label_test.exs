defmodule BarkparkWeb.Studio.EditorTitleLabelTest do
  @moduledoc """
  Gyldendal parity E7 follow-up: the synthetic Title input backs the schema's
  OWN `title` field when there is one, so its label is that field's declared
  title («Tittel» on the twin's publication), not a hard-coded «Title».
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
    {:ok, ws} = Tenancy.create_workspace(%{slug: "tl-#{suffix}", name: "Title Label"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    raw = "tl-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "tl", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "title",
              "title" => "Tittel",
              "type" => "string",
              "validation" => %{"required" => true}
            },
            %{"name" => "year", "title" => "Utgivelsesår", "type" => "number"}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{
          "doc_id" => "pub-1",
          "title" => "Snow Angels",
          "status" => "published",
          "content" => %{"year" => 2024}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  test "the title input wears the schema's title-field title, not a hard-coded Title", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/publication/pub-1")

    assert html =~ ~s(name="doc[title]")
    assert html =~ ~r/<label class="editor-field-label">\s*Tittel/, "the label should read Tittel"

    refute html =~ ~r/<label class="editor-field-label">\s*Title\b/,
           "the hard-coded Title label survived"
  end
end

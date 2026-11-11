defmodule BarkparkWeb.Studio.EditorFieldClassTest do
  @moduledoc """
  The specs find a form field by its wrapper, `.field`, the class Sanity's
  Studio uses. The Studio's field wrapper (`editor-field`) now also carries
  `field`. A class name only: no element, label, id or behaviour changes (the
  inputs keep their `doc-field-<doc>-<path>` ids).
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
    {:ok, ws} = Tenancy.create_workspace(%{slug: "fc-#{suffix}", name: "Field Class"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    raw = "fc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "fc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "fc_post",
          "title" => "Posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "year", "title" => "Year", "type" => "number"},
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "arrayOf",
              "of" => [%{"type" => "string"}]
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "fc_post",
        %{"doc_id" => "fc-1", "title" => "One", "content" => %{"year" => 2024}},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/fc_post/fc-1"}
  end

  test "each field's input sits inside a .field wrapper", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)

    for path <- ~w(title year) do
      assert has_element?(view, ~s(.editor-field.field [id="doc-field-fc-1-#{path}"])),
             "no .field wraps the #{path} input"
    end
  end

  test "a self-titled field's wrapper is a .field too", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, ".editor-field.editor-field-self-titled.field")
  end
end

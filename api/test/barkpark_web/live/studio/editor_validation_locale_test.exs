defmodule BarkparkWeb.Studio.EditorValidationLocaleTest do
  @moduledoc """
  Gyldendal parity E7 follow-up (friction #87): in an nb-NO workspace the
  validation findings speak Norwegian everywhere the Studio renders them —
  under a top-level field, under an array row's subfield — and so does the
  publish refusal. The schema's own `message` stays the schema's words.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "vloc-twin-#{suffix}", name: "Vloc Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "vloc-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "vloc-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "frontpage",
          "title" => "Forside",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "ingress",
              "title" => "Ingress",
              "type" => "text",
              "validation" => %{"min" => 3}
            },
            %{
              "name" => "banners",
              "title" => "Toppbannere",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => %{
                "type" => "composite",
                "title" => "Feature-kort",
                "fields" => [
                  %{
                    "name" => "title",
                    "title" => "Tittel",
                    "type" => "string",
                    "validation" => %{"required" => true}
                  }
                ]
              }
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "frontpage",
        %{
          "doc_id" => "frontpage-1",
          "title" => "Forside",
          "status" => "published",
          "content" => %{
            "ingress" => "Velkommen",
            "banners" => [%{"title" => "Crime from the North"}]
          }
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, doc} = Content.publish_document("frontpage-1", "frontpage", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, doc: doc}
  end

  test "an nb-NO workspace renders Norwegian findings under the field and the row, and refuses in Norwegian",
       %{conn: conn, ws: ws, proj: proj, doc: doc} do
    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/frontpage/#{doc.doc_id}")

    refute html =~ "Studio could not open this document"

    html =
      view
      |> form("#editor-form", %{"doc[ingress]" => "ab"})
      |> render_change(%{"_target" => ["doc[ingress]"]})

    assert html =~ "Må være minst 3 tegn"
    refute html =~ "Must be at least"

    html =
      view
      |> form("#editor-form", %{"doc[banners][0].title" => ""})
      |> render_change(%{"_target" => ["doc[banners][0].title"]})

    assert html =~ ~r/data-row-index="0".*data-error-for="title"[^>]*>Påkrevd</s
    refute html =~ ">Required<"

    view |> element(~s(button[phx-click="publish"])) |> render_click()
    html = render(view)
    assert html =~ "Rett valideringsfeilene før du publiserer"
    refute html =~ "Fix validation errors before publishing"
  end
end

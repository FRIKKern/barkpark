defmodule BarkparkWeb.Studio.EditorNestedValidationTest do
  @moduledoc """
  Gyldendal parity E1.11 (task-34ea5ee00dfb7a99) through the Studio editor on
  a twin-shaped document in a non-default workspace: a `seo` field from a
  NAMED object type (E3.6) and a `banners` arrayOf composite.

    * `seo.description` over its warning `max` renders the warning under THAT
      textarea and in the publish bar count, and the publish SUCCEEDS;
    * an empty required `title` in a banners row renders the error under that
      row's subfield and the publish is REFUSED;
    * the top-level field never shows the raw JSON-pointer the flat envelope
      carries ("/seo/description: …").
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @long String.duplicate("x", 301)

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "e111-twin-#{suffix}", name: "E111 Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "e111-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "e111-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    # The named object type, applied once per dataset (E3.6).
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "seo",
          "kind" => "object",
          "title" => "SEO og sosiale medier",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "description",
              "title" => "Beskrivelse",
              "type" => "text",
              "validation" => %{
                "max" => 300,
                "level" => "warning",
                "message" => "Beskrivelsen bør være under 300 tegn."
              }
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "frontpage",
          "title" => "Forside",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "seo", "title" => "SEO og sosiale medier", "type" => "seo"},
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
                  },
                  %{"name" => "buttonHref", "title" => "Lenke", "type" => "string"}
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
            "seo" => %{"title" => "Forside", "description" => "kort"},
            "banners" => [%{"title" => "Crime from the North", "buttonHref" => "/books"}]
          }
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, doc} = Content.publish_document("frontpage-1", "frontpage", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, doc: doc, scope: scope}
  end

  defp open!(conn, ws, proj, doc) do
    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/frontpage/#{doc.doc_id}")

    refute html =~ "Studio could not open this document"
    {view, html}
  end

  defp published(scope) do
    {:ok, d} = Content.get_document("frontpage-1", "frontpage", @dataset, scope)
    d
  end

  test "a warning on seo.description renders under that textarea and in the bar, and publish succeeds",
       %{conn: conn, ws: ws, proj: proj, doc: doc, scope: scope} do
    {view, html} = open!(conn, ws, proj, doc)
    assert html =~ ~s(name="doc[seo].description")
    refute html =~ ~s(data-test-id="validation-warnings")

    html =
      view
      |> form("#editor-form", %{"doc[seo].description" => @long})
      |> render_change()

    # Under the subfield, inside the seo composite.
    assert html =~ ~s(data-warning-for="description")
    assert html =~ "Beskrivelsen bør være under 300 tegn."
    # Never the flat envelope's pointer on the top-level field.
    refute html =~ "/seo/description"
    refute html =~ ~s(class="field-warnings")
    refute html =~ ~s(class="field-errors")
    # Counted in the publish bar.
    assert html =~ ~s(data-test-id="validation-warnings")
    assert html =~ "1 warning"

    view |> element(~s(button[phx-click="publish"])) |> render_click()
    html = render(view)
    refute html =~ "Fix validation errors before publishing"
    assert published(scope).content["seo"]["description"] == @long
    assert html =~ ~s(data-test-id="validation-warnings")
  end

  test "a required miss in a banners row renders under that row's subfield and blocks the publish",
       %{conn: conn, ws: ws, proj: proj, doc: doc, scope: scope} do
    {view, html} = open!(conn, ws, proj, doc)
    assert html =~ ~s(name="doc[banners][0].title")

    # A browser's `phx-change` names the input that fired it in `_target`;
    # the Studio folds a cleared dotted value only for that touched input.
    html =
      view
      |> form("#editor-form", %{"doc[banners][0].title" => ""})
      |> render_change(%{"_target" => ["doc[banners][0].title"]})

    assert html =~ ~r/data-row-index="0".*data-error-for="title"[^>]*>Required</s
    refute html =~ "/banners/0/title"
    refute html =~ ~s(class="field-errors")
    refute html =~ ~s(data-test-id="validation-warnings")

    view |> element(~s(button[phx-click="publish"])) |> render_click()
    assert render(view) =~ "Fix validation errors before publishing"
    assert hd(published(scope).content["banners"])["title"] == "Crime from the North"
  end
end

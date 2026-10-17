defmodule BarkparkWeb.Studio.EditorHiddenFieldTest do
  @moduledoc """
  task-7d4c026f3749ebee: a field with `hidden: true` (Sanity's literal `hidden`,
  kept by the gyldendal.no twin's generator on article `publishStatus`,
  `contentType` and `relevance`) is not drawn in the Studio form, and a save of
  another field keeps its stored value.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.FieldVisibility
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "hid-twin-#{suffix}", name: "Hidden Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "hid-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "hid-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Artikkel",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "preamble", "title" => "Ingress", "type" => "text"},
            %{
              "name" => "publishStatus",
              "title" => "Publiseringsstatus",
              "type" => "select",
              "options" => [%{"value" => "draft", "title" => "Utkast"}],
              "hidden" => true
            },
            %{
              "name" => "auditNotes",
              "title" => "Revisjonsnotater",
              "type" => "text",
              "hidden" => true,
              # hidden wins over a predicate that holds
              "visibleWhen" => %{"field" => "title", "operator" => "non_empty"}
            },
            %{
              "name" => "seo",
              "title" => "SEO",
              "type" => "composite",
              "fields" => [
                %{"name" => "metaTitle", "title" => "Metatittel", "type" => "string"},
                %{
                  "name" => "legacyKeywords",
                  "title" => "Gamle nøkkelord",
                  "type" => "string",
                  "hidden" => true
                }
              ]
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "article",
        %{
          "doc_id" => "article-hidden",
          "title" => "Skjulte felt",
          "content" => %{
            "title" => "Skjulte felt",
            "preamble" => "Før",
            "publishStatus" => "draft",
            "auditNotes" => "Sjekket",
            "seo" => %{"metaTitle" => "Meta", "legacyKeywords" => "bok, roman"}
          }
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("article-hidden", "article", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp editor_url(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/article/article-hidden"

  test "the form draws no input for a hidden field, top level or inside an object", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} = live(conn, editor_url(ws, proj))

    assert html =~ ~s(name="doc[preamble]")
    assert html =~ "Metatittel"

    refute html =~ "Publiseringsstatus"
    refute html =~ ~s(name="doc[publishStatus]")
    refute html =~ "Revisjonsnotater"
    refute html =~ "Gamle nøkkelord"
  end

  test "a save of another field keeps the hidden fields' stored values", %{
    conn: conn,
    ws: ws,
    proj: proj,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, editor_url(ws, proj))

    view
    |> form("#editor-form", %{"doc" => %{"preamble" => "Etter"}})
    |> render_submit()

    {:ok, draft} = Content.get_document("drafts.article-hidden", "article", @dataset, scope)
    assert draft.content["preamble"] == "Etter"
    assert draft.content["publishStatus"] == "draft"
    assert draft.content["auditNotes"] == "Sjekket"
    assert draft.content["seo"]["legacyKeywords"] == "bok, roman"
  end

  test "hidden?/1 reads only the literal true" do
    assert FieldVisibility.hidden?(%{"hidden" => true})
    refute FieldVisibility.hidden?(%{"hidden" => "true"})
    refute FieldVisibility.hidden?(%{"hidden" => false})
    refute FieldVisibility.hidden?(%{})
    refute FieldVisibility.visible?(%{"hidden" => true}, %{})
    assert FieldVisibility.visible?(%{"hidden" => false}, %{})
  end
end

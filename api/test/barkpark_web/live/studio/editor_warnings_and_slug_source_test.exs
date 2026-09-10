defmodule BarkparkWeb.Studio.EditorWarningsAndSlugSourceTest do
  @moduledoc """
  Gyldendal parity E1.6 (task-cd8e10ca44ccb932, criteria 2 and 3) through the
  Studio editor on an author-shaped document in a non-default workspace:

    * Generate derives the slug from the field's `options.source` (`name`),
      not from the hard-coded title column;
    * a `"level": "warning"` rule renders inline under the field and as a
      count in the publish bar, and publishing SUCCEEDS;
    * an error-level rule still blocks the publish (the fail-first control).
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "e16-twin-#{suffix}", name: "E16 Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "e16-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "e16-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Forfatter",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "name",
              "title" => "Navn",
              "type" => "string",
              "validation" => %{"required" => true}
            },
            %{
              "name" => "slug",
              "title" => "Slug (URL)",
              "type" => "slug",
              "options" => %{"source" => "name", "maxLength" => 96}
            },
            %{
              "name" => "bio",
              "title" => "Biografi",
              "type" => "text",
              "validation" => %{
                "max" => 12,
                "level" => "warning",
                "message" => "Over 12 tegn blir klippet på kortet."
              }
            },
            %{
              "name" => "isbn",
              "title" => "ISBN",
              "type" => "string",
              "validation" => %{"pattern" => "^[0-9]{13}$"}
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "author",
        %{
          "doc_id" => "author-1",
          "title" => "Forfatter",
          "status" => "published",
          "content" => %{"name" => "Lars Mytting", "slug" => "", "bio" => "short"}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, doc} = Content.publish_document("author-1", "author", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, doc: doc, scope: scope}
  end

  defp editor_url(ws, proj, doc),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/author/#{doc.doc_id}"

  defp open!(conn, ws, proj, doc) do
    {:ok, view, html} = live(conn, editor_url(ws, proj, doc))
    refute html =~ "Studio could not open this document"
    {view, html}
  end

  defp stored(scope) do
    case Content.get_document("drafts.author-1", "author", @dataset, scope) do
      {:ok, d} -> d
      _ -> elem(Content.get_document("author-1", "author", @dataset, scope), 1)
    end
  end

  describe "slug options.source" do
    test "Generate derives the slug from `name`, not from the title column", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc,
      scope: scope
    } do
      {view, html} = open!(conn, ws, proj, doc)
      assert html =~ ~s(data-slug-source="name")

      view
      |> element(~s(button[phx-click="slug-generate"][phx-value-field="slug"]))
      |> render_click()

      expected = Barkpark.Tenancy.slugify("Lars Mytting")
      assert render(view) =~ expected
      assert stored(scope).content["slug"] == expected
      refute expected == Barkpark.Tenancy.slugify("Forfatter")
    end
  end

  describe "warning-level validation" do
    test "a warning renders inline and in the publish bar, and publish still succeeds", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc,
      scope: scope
    } do
      {view, _html} = open!(conn, ws, proj, doc)

      html =
        view
        |> form("#editor-form", %{"doc" => %{"bio" => "far longer than twelve characters"}})
        |> render_change()

      assert html =~ ~s(class="field-warnings")
      assert html =~ "Over 12 tegn blir klippet på kortet."
      assert html =~ ~s(data-test-id="validation-warnings")
      assert html =~ "1 warning"
      refute html =~ ~s(class="field-errors")

      # The draft was saved with the long bio — a warning never blocks a save.
      assert stored(scope).content["bio"] == "far longer than twelve characters"

      view |> element(~s(button[phx-click="publish"])) |> render_click()
      html = render(view)
      refute html =~ "Fix validation errors before publishing"

      {:ok, published} = Content.get_document("author-1", "author", @dataset, scope)
      assert published.content["bio"] == "far longer than twelve characters"
      # The bar keeps nagging after the publish.
      assert html =~ ~s(data-test-id="validation-warnings")
    end

    test "an error-level rule still blocks the publish (control)", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc,
      scope: scope
    } do
      {view, _html} = open!(conn, ws, proj, doc)

      html =
        view
        |> form("#editor-form", %{"doc" => %{"isbn" => "not-an-isbn"}})
        |> render_change()

      assert html =~ ~s(class="field-errors")
      assert html =~ "Does not match required format"

      view |> element(~s(button[phx-click="publish"])) |> render_click()
      assert render(view) =~ "Fix validation errors before publishing"

      {:ok, published} = Content.get_document("author-1", "author", @dataset, scope)
      refute published.content["isbn"] == "not-an-isbn"
    end
  end
end

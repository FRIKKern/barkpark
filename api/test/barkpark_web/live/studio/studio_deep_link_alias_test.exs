defmodule BarkparkWeb.Studio.StudioDeepLinkAliasTest do
  @moduledoc """
  Gyldendal E3.5 (friction 67, task-abaf7e98d15d7ba5) — a deep link keeps
  opening its document when the desk is re-declared.

  On 2026-09-04 the canonical row path was `/studio/content-types/<type>/<id>`
  (the default desk's display group). After the twin published a
  `deskStructure` document that path rendered «This desk has no section named
  content-types» while `/studio/<type>/<id>` kept working. Links in papers,
  notes and bookmarks from before the declaration were dead.

  Contract, on a DECLARED desk in a non-default workspace:

    1. the legacy `content-types/<type>/<id>` path opens the document and the
       address is rewritten to the canonical path the desk uses for that row;
    2. `/studio/<type>/<id>` (PR 16122) still opens it, with no rewrite;
    3. a head that is neither a section nor followed by a listed type still
       gets the error card naming the section.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "alias-twin-#{suffix}", name: "Alias Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "alias-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "alias-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "deskStructure",
        %{
          "doc_id" => "deskStructure",
          "title" => "Desk",
          "status" => "published",
          "content" => %{
            "items" => [
              %{
                "kind" => "list",
                "id" => "utgivelser",
                "title" => "Utgivelser",
                "items" => [
                  %{
                    "kind" => "documentTypeList",
                    "id" => "alle-utgivelser",
                    "type" => "publication",
                    "title" => "Alle utgivelser"
                  }
                ]
              }
            ]
          }
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset, scope)

    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{
          "doc_id" => "pub-alias",
          "title" => "Over My Dead Body",
          "status" => "published",
          "content" => %{"title" => "Over My Dead Body"}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("pub-alias", "publication", @dataset, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, base: base}
  end

  @card "Studio could not open this document"

  test "the legacy content-types path opens the document and lands on the canonical path", %{
    conn: conn,
    base: base
  } do
    canonical = base <> "/utgivelser/alle-utgivelser/pub-alias"

    case live(conn, base <> "/content-types/publication/pub-alias") do
      {:error, {:live_redirect, %{to: to}}} ->
        assert to == canonical, "rewrote to #{to}, expected #{canonical}"
        {:ok, _view, html} = live(conn, to)
        refute html =~ @card
        assert html =~ ~s(value="Over My Dead Body")

      {:ok, view, html} ->
        # A connected mount that patched instead of redirecting: the document
        # is open either way, and the address must have converged.
        refute html =~ @card, "the legacy path rendered the error card"
        assert html =~ ~s(value="Over My Dead Body")
        assert_patch(view, canonical)
    end
  end

  test "/studio/<type>/<id> still opens the document on the declared desk, with no rewrite", %{
    conn: conn,
    base: base
  } do
    {:ok, _view, html} = live(conn, base <> "/publication/pub-alias")
    refute html =~ @card
    assert html =~ ~s(value="Over My Dead Body")
  end

  test "a dead head with an unknown tail still gets the error card naming the section", %{
    conn: conn,
    base: base
  } do
    {:ok, _view, html} = live(conn, base <> "/nope/pub-alias")
    assert html =~ @card
    assert html =~ "This desk has no section named"
  end
end

defmodule BarkparkWeb.Studio.StudioPortableTextNewDocTest do
  @moduledoc """
  A richText field declared Portable Text saves as a Portable Text array from
  the first keystroke, even when it is named `body` (stage S1 of the Portable
  Text plan, task-9296af21cac3f813). Before the declaration a new or empty
  `body` saved the editor's HTML as a string, because the name alone made it
  the PortableDoc body region.

  The schemas, ids and text are made up.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  @schemas [
    %{
      "name" => "ptNote",
      "title" => "Note",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "body", "type" => "richText", "format" => "portableText"}
      ]
    },
    %{
      "name" => "ptAliasNote",
      "title" => "Alias note",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "body", "type" => "portableText"}
      ]
    },
    %{
      "name" => "ptLegacyNote",
      "title" => "Legacy note",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "body", "type" => "richText"}
      ]
    }
  ]

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "ptnew-#{suffix}", name: "PT new docs"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "ptnew-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "ptnew", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    for s <- @schemas, do: {:ok, _} = Content.upsert_schema(s, @dataset, scope)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     ws: ws,
     proj: proj,
     scope: scope}
  end

  defp studio(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  # Studio's "+" births a draft with a generated id; open it and type one
  # paragraph into the body, the way the rich-text editor posts it.
  defp new_doc_with_one_paragraph(conn, ws, proj, scope, type) do
    {:ok, view, _html} = live(conn, studio(ws, proj))
    render_click(view, "new-document", %{"type" => type})

    draft =
      type
      |> Content.list_documents(@dataset, Keyword.put(scope, :perspective, :raw))
      |> Enum.find(&Content.draft?(&1.doc_id))

    assert draft, "new-document should birth a draft"
    id = Content.published_id(draft.doc_id)

    {:ok, view, html} = live(conn, studio(ws, proj) <> "/#{type}/#{id}")
    assert html =~ ~s(name="doc[body]")

    view
    |> form("#editor-form")
    |> render_change(%{"doc[body]" => "<p>One typed paragraph.</p>", "_target" => ["doc[body]"]})

    {:ok, doc} = Content.get_document("drafts." <> id, type, @dataset, scope)
    doc.content["body"]
  end

  test "a new doc's Portable Text body with one typed paragraph stores a one-block array",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    assert [
             %{
               "_type" => "block",
               "_key" => key,
               "style" => "normal",
               "markDefs" => [],
               "children" => [
                 %{
                   "_type" => "span",
                   "_key" => span_key,
                   "text" => "One typed paragraph.",
                   "marks" => []
                 }
               ]
             }
           ] = new_doc_with_one_paragraph(conn, ws, proj, scope, "ptNote")

    assert is_binary(key) and key != ""
    assert is_binary(span_key) and span_key != ""
  end

  test "the `type: portableText` alias saves the same way",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    assert [%{"_type" => "block", "children" => [%{"text" => "One typed paragraph."}]}] =
             new_doc_with_one_paragraph(conn, ws, proj, scope, "ptAliasNote")
  end

  test "a body with no declared format keeps the legacy behaviour (HTML string)",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    assert new_doc_with_one_paragraph(conn, ws, proj, scope, "ptLegacyNote") ==
             "<p>One typed paragraph.</p>"
  end
end

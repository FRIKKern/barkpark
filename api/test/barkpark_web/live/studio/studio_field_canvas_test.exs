defmodule BarkparkWeb.Studio.StudioFieldCanvasTest do
  @moduledoc """
  Gyldendal parity stage E1 — a `richText` field with `"editor": "blocks"`
  opens in the Classic form as a field canvas, and its ops round-trip through
  `field-block-ops` into `content[field]` only, with the echo the canvas needs.
  Fixture: a token owner of a NON-default workspace (the twin's shape).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @vocab %{
    "styles" => ["normal", "h2", "h3", "blockquote"],
    "lists" => ["bullet", "number"],
    "marks" => ["strong", "em"],
    "annotations" => [%{"name" => "link"}],
    "of" => ["image"]
  }

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "e1-twin-#{suffix}", name: "E1 Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    raw = "e1-owner-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "e1-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "description",
              "title" => "Beskrivelse",
              "type" => "richText",
              "editor" => "blocks",
              "blocks" => @vocab
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, doc} =
      Content.create_document(
        "publication",
        %{
          "doc_id" => "pub-e1",
          "title" => "Over My Dead Body",
          "description" => %{
            "blocks" => [
              %{
                "id" => "p1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Seed"}]
              }
            ],
            "html" => "<p>Seed</p>"
          }
        },
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, doc: doc, scope: scope}
  end

  defp studio_url(ws, proj, id),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/publication/#{id}"

  test "the field renders as a canvas seeded with its blocks and vocabulary", %{
    conn: conn,
    ws: ws,
    proj: proj,
    doc: doc
  } do
    id = DraftId.published_id(doc.doc_id)
    {:ok, _view, html} = live(conn, studio_url(ws, proj, id))

    assert html =~ ~s(data-test-id="field-canvas")
    assert html =~ ~s(data-field="description")
    assert html =~ ~r{data-canvas-blocks="[^"]*Seed[^"]*"}
    assert html =~ ~r{data-canvas-vocabulary="[^"]*blockquote[^"]*"}
    refute html =~ "bp-rt-wrap-description"
  end

  test "field-block-ops writes content[field] only and echoes the new blocks to the canvas", %{
    conn: conn,
    ws: ws,
    proj: proj,
    doc: doc,
    scope: scope
  } do
    id = DraftId.published_id(doc.doc_id)
    {:ok, view, _html} = live(conn, studio_url(ws, proj, id))

    render_hook(view, "field-block-ops", %{
      "field" => "description",
      "ops" => [
        %{
          "op" => "append-block",
          "block" => %{"id" => "h2", "type" => "heading", "level" => 2, "text" => "Praise"}
        }
      ]
    })

    assert_push_event(view, "bp:field-canvas-update", %{field: "description", blocks: blocks})
    assert [%{"id" => "p1"}, %{"id" => "h2", "type" => "heading"}] = blocks

    {:ok, saved} = Content.get_document(DraftId.draft_id(id), "publication", @dataset, scope)
    assert [%{"id" => "p1"}, %{"id" => "h2"}] = saved.content["description"]["blocks"]
    assert saved.content["description"]["html"] =~ "Praise"
    refute Map.has_key?(saved.content, "blocks")
  end

  test "an out-of-vocabulary op is refused with a named reason and nothing changes", %{
    conn: conn,
    ws: ws,
    proj: proj,
    doc: doc,
    scope: scope
  } do
    id = DraftId.published_id(doc.doc_id)
    {:ok, view, _html} = live(conn, studio_url(ws, proj, id))

    html =
      render_hook(view, "field-block-ops", %{
        "field" => "description",
        "ops" => [
          %{"op" => "append-block", "block" => %{"id" => "c", "type" => "code", "value" => "x"}}
        ]
      })

    assert html =~ "Not allowed in this field"
    assert html =~ "block type code"
    refute_push_event(view, "bp:field-canvas-update", %{field: "description"})

    {:ok, saved} = Content.get_document(DraftId.draft_id(id), "publication", @dataset, scope)
    assert [%{"id" => "p1"}] = saved.content["description"]["blocks"]
  end
end

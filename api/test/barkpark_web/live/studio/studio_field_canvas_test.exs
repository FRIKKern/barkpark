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
  alias BarkparkWeb.Studio.StudioLive

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
    {:ok, view, html} = live(conn, studio_url(ws, proj, id))
    opened_doc = :sys.get_state(view.pid).socket.assigns.editor_doc

    assert html =~ ~s(data-test-id="field-canvas")
    assert html =~ ~s(data-field="description")
    assert html =~ ~s(data-paper-doc-key="#{@dataset}:#{opened_doc.type}:#{opened_doc.doc_id}")
    assert html =~ ~s(data-document-rev="#{opened_doc.rev}")
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
      "request_id" => "field-canvas-save",
      "if_rev" => current_document_rev(view),
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
        "request_id" => "field-canvas-refused",
        "if_rev" => current_document_rev(view),
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

  test "a stale field canvas receives the current opaque revision and does not overwrite", %{
    conn: conn,
    ws: ws,
    proj: proj,
    doc: doc,
    scope: scope
  } do
    id = DraftId.published_id(doc.doc_id)
    {:ok, view, _html} = live(conn, studio_url(ws, proj, id))
    stale_socket = :sys.get_state(view.pid).socket
    initial_rev = stale_socket.assigns.editor_doc.rev

    params = %{
      "field" => "description",
      "request_id" => "field-first",
      "if_rev" => initial_rev,
      "ops" => [
        %{
          "op" => "append-block",
          "block" => %{"id" => "h-first", "type" => "heading", "level" => 2, "text" => "First"}
        }
      ]
    }

    assert {:reply, %{saved: true, rev: committed_rev}, _socket} =
             StudioLive.handle_event("field-block-ops", params, stale_socket)

    stale_params = %{
      params
      | "request_id" => "field-stale",
        "ops" => [
          %{
            "op" => "append-block",
            "block" => %{"id" => "h-stale", "type" => "heading", "level" => 2, "text" => "Stale"}
          }
        ]
    }

    assert {:reply,
            %{
              saved: false,
              request_id: "field-stale",
              conflict: true,
              current_rev: ^committed_rev
            }, _socket} = StudioLive.handle_event("field-block-ops", stale_params, stale_socket)

    {:ok, saved} = Content.get_document(DraftId.draft_id(id), "publication", @dataset, scope)
    ids = Enum.map(saved.content["description"]["blocks"], & &1["id"])
    assert "h-first" in ids
    refute "h-stale" in ids
  end

  defp current_document_rev(view), do: :sys.get_state(view.pid).socket.assigns.editor_doc.rev
end

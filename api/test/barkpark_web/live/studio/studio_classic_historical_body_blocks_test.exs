defmodule BarkparkWeb.Studio.StudioClassicHistoricalBodyBlocksTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "production"
  @doc_type "classic_historical_body_blocks"
  @doc_id "classic-historical-card-body"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Classic historical body blocks",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "subtitle", "title" => "Subtitle", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    blocks = [bound_subtitle(), section_with_card()]

    body = %{
      "blocks" => blocks,
      "html" => "<p>stale fixture derivative</p>",
      "unknownBodyMetadata" => %{"keep" => [1, 2, 3]}
    }

    {:ok, doc} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => @doc_id,
          "title" => "Historical Card fixture",
          "content" => %{
            "subtitle" => "Bound subtitle before Beta",
            "body" => body,
            "unknownContent" => true
          }
        },
        @dataset
      )

    %{blocks: blocks, body: body, doc: doc}
  end

  test "malformed top-level authority keeps Beta unavailable and forged ops cannot write", %{
    conn: conn,
    blocks: blocks,
    doc: doc
  } do
    malformed = %{
      "blocks" => %{"invalid" => true},
      "body" => %{
        "blocks" => blocks,
        "html" => "<p>nested must not become fallback authority</p>",
        "unknownBodyMetadata" => %{"keep" => true}
      }
    }

    doc |> Ecto.Changeset.change(content: malformed) |> Repo.update!()

    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}")
    {:ok, view, html} = live(conn, path)
    socket = :sys.get_state(view.pid).socket

    assert socket.assigns.editor_mode == :classic
    assert socket.assigns.editor_blocks == []

    assert socket.assigns.editor_blocks_identity_error ==
             {:malformed_block_authority, "blocks"}

    refute html =~ ~s(data-test-id="editor-mode-beta")
    assert html =~ ~s(data-test-id="studio-beta-identity-error")

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-op", %{
      "op" => "append-block",
      "block" => %{
        "id" => "forged",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Must not overwrite authority"}]
      },
      "request_id" => request_id,
      "if_rev" => socket.assigns.editor_doc.rev
    })

    assert_reply(view, %{saved: false, request_id: ^request_id})

    {:ok, unchanged} =
      Content.get_document(socket.assigns.editor_doc.doc_id, @doc_type, @dataset)

    assert unchanged.content == malformed
    assert unchanged.rev == socket.assigns.editor_doc.rev
  end

  test "a Classic html body wrapper remains editable while Beta explains why it is unavailable",
       %{
         conn: conn,
         doc: doc
       } do
    wrapped = %{
      "body" => %{
        "html" => "<p>Classic wrapper prose</p>",
        "unknownBodyMetadata" => %{"keep" => true}
      }
    }

    doc |> Ecto.Changeset.change(content: wrapped) |> Repo.update!()

    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}")
    {:ok, view, html} = live(conn, path)
    socket = :sys.get_state(view.pid).socket

    assert html =~ ~s(id="editor-form")
    assert has_element?(view, ~s(#bp-rt-hidden-body[value*="Classic wrapper prose"]))
    refute html =~ ~s(data-test-id="editor-mode-beta")

    assert html =~ "stored content cannot be safely edited as blocks"

    assert socket.assigns.editor_blocks_identity_error ==
             {:malformed_block_authority, "body"}

    assert socket.assigns.editor_mode == :classic
  end

  test "Classic mounts a nested-only Card body and autosave preserves its block authority", %{
    conn: conn,
    blocks: blocks,
    body: body
  } do
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}")
    {:ok, view, html} = live(conn, path)

    assert html =~ ~s(id="editor-form")
    assert has_element?(view, ~s(#bp-rt-hidden-body[value*="Card body from nested fixture"]))
    refute has_element?(view, ~s(#bp-rt-hidden-body[value*="stale fixture derivative"]))

    saved_html =
      render_hook(view, "autosave", %{
        "doc" => %{
          "title" => "Historical Card saved in Classic",
          "body" => "<p>raw scalar must not replace blocks</p>",
          "status" => "draft"
        }
      })

    refute saved_html =~ "Save failed"

    {:ok, saved} = Content.get_document("drafts.#{@doc_id}", @doc_type, @dataset)
    assert saved.title == "Historical Card saved in Classic"
    assert saved.content["body"]["blocks"] == blocks
    assert saved.content["body"]["unknownBodyMetadata"] == body["unknownBodyMetadata"]
    assert saved.content["unknownContent"] == true
    refute Map.has_key?(saved.content, "blocks")

    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="paper-card-editor")
    refute beta_html =~ ~s(data-test-id="paper-field-field-text")

    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.editor_blocks == blocks
    assert socket.assigns.editor_blocks_synth? == false

    {:ok, after_toggle} = Content.get_document("drafts.#{@doc_id}", @doc_type, @dataset)
    assert after_toggle.content == saved.content

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "card-one",
      "card-title" => "Card title edited after historical Beta transition",
      "request_id" => request_id,
      "if_rev" => socket.assigns.editor_doc.rev
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^request_id})

    {:ok, beta_saved} = Content.get_document("drafts.#{@doc_id}", @doc_type, @dataset)
    assert beta_saved.content["body"]["unknownBodyMetadata"] == body["unknownBodyMetadata"]
    assert beta_saved.content["unknownContent"] == true

    [saved_bound, saved_section] = beta_saved.content["blocks"]
    [saved_card, saved_sibling] = saved_section["blocks"]
    assert saved_bound == bound_subtitle()
    assert beta_saved.content["subtitle"] == "Bound subtitle before Beta"
    assert beta_saved.content["body"]["blocks"] == [saved_section]
    assert saved_card["unknownCard"] == %{"keep" => true}
    assert saved_card["slots"]["unknownSlot"] == %{"keep" => "opaque"}
    assert saved_sibling == sibling_card()

    assert get_in(saved_card, ["slots", "title", Access.at(0), "text"]) ==
             "Card title edited after historical Beta transition"

    {:ok, _reloaded, reloaded_html} = live(recycle(conn), path)
    assert reloaded_html =~ "Historical Card saved in Classic"
    assert reloaded_html =~ "Card body from nested fixture"
  end

  defp section_with_card do
    %{
      "id" => "section-card-grid",
      "type" => "section",
      "unknownSection" => "keep",
      "blocks" => [
        %{
          "id" => "card-one",
          "type" => "card",
          "unknownCard" => %{"keep" => true},
          "slots" => %{
            "title" => [%{"type" => "heading", "text" => "Historical Card", "level" => 3}],
            "body" => [
              %{
                "id" => "card-body",
                "type" => "paragraph",
                "content" => [
                  %{"type" => "text", "value" => "Card body from nested fixture"}
                ]
              }
            ],
            "unknownSlot" => %{"keep" => "opaque"}
          }
        },
        sibling_card()
      ]
    }
  end

  defp bound_subtitle do
    %{
      "id" => "bound-subtitle",
      "type" => "field-string",
      "fieldName" => "subtitle",
      "value" => "Bound subtitle before Beta",
      "unknownBoundMetadata" => %{"keep" => true}
    }
  end

  defp sibling_card do
    %{
      "id" => "card-sibling",
      "type" => "card",
      "unknownSibling" => %{"keep" => ["exact"]},
      "slots" => %{
        "title" => [%{"type" => "heading", "text" => "Sibling Card", "level" => 4}],
        "body" => [
          %{
            "id" => "card-sibling-body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Sibling body stays exact"}]
          }
        ]
      }
    }
  end
end

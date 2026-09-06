defmodule BarkparkWeb.Studio.StudioBetaStepsFormReplayTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @doc_type "beta_steps_form_replay"
  @doc_id "beta-steps-form-replay-document"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta steps form replay",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    blocks = [
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [
          %{
            "id" => "row",
            "title" => "Before",
            "unknown" => "keep",
            "children" => [
              %{
                "id" => "body",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Existing body"}]
              }
            ]
          }
        ]
      }
    ]

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{
          "doc_id" => @doc_id,
          "title" => "Steps",
          "content" => %{"blocks" => blocks}
        },
        @dataset
      )

    assert doc.content["blocks"] == blocks
    {:ok, doc: doc}
  end

  test "generic Beta step form replays an identical add after remount without duplicating storage",
       %{conn: conn, doc: doc} do
    raw = "beta-steps-form-replay-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta steps form replay", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}")
    {:ok, view, _html} = live(conn, path)

    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="studio-doc-beta-editor")
    assert has_element?(view, "#steps-form-steps")
    assert has_element?(view, "[data-step-row-id='row']")

    socket = socket_of(view)
    assert socket.assigns.editor_view == :form
    assert socket.assigns.editor_mode == :beta
    assert socket.assigns.editor_type == @doc_type
    assert socket.assigns.editor_doc.doc_id == doc.doc_id
    assert socket.assigns.editor_blocks_synth? == false
    assert socket.assigns[:paper_doc] == nil
    assert ["steps"] == Enum.map(socket.assigns.editor_blocks, & &1["id"])

    title_request = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "steps",
      "step-count" => "1",
      "step-0-id" => "row",
      "step-0-title" => "After",
      "if_rev" => socket.assigns.editor_doc.rev,
      "request_id" => title_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^title_request})
    [saved_parent] = stored_blocks(doc.doc_id)
    [saved_row] = saved_parent["steps"]
    assert saved_row["title"] == "After"
    assert saved_row["unknown"] == "keep"
    assert hd(saved_row["children"])["id"] == "body"

    add_request = Ecto.UUID.generate()

    add_params = %{
      "block_id" => "steps",
      "step-count" => "1",
      "step-0-id" => "row",
      "step-0-title" => "After",
      "step-action" => "add",
      "step-new-row-id" => "second-row",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => add_request
    }

    render_hook(view, "paper-edit-block", add_params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^add_request,
      rev: committed_rev
    })

    after_add = stored_blocks(doc.doc_id)
    assert Enum.map(hd(after_add)["steps"], & &1["id"]) == ["row", "second-row"]

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "#steps-form-steps")
    assert has_element?(reloaded, "[data-step-row-id='second-row']")
    assert socket_of(reloaded).assigns[:paper_doc] == nil

    render_hook(reloaded, "paper-edit-block", add_params)

    assert_reply(reloaded, %{
      saved: true,
      replayed: true,
      request_id: ^add_request,
      rev: ^committed_rev
    })

    assert stored_blocks(doc.doc_id) == after_add
  end

  defp stored_blocks(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc.content["blocks"]
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end

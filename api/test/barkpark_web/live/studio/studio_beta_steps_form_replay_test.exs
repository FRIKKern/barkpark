defmodule BarkparkWeb.Studio.StudioBetaStepsFormReplayTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.Document
  alias Barkpark.Repo

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

  test "legacy idless Step rows mount with projected identities and persist them on an exact-replayable form write",
       %{conn: conn} do
    legacy = %{
      "blocks" => [
        %{
          "id" => "legacy-steps",
          "type" => "steps",
          "steps" => [
            %{
              "title" => "Before",
              "unknown" => "keep",
              "children" => [
                %{
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "Legacy body"}]
                }
              ]
            }
          ]
        }
      ]
    }

    doc = legacy_document!("legacy-idless", legacy)
    raw = "beta-steps-legacy-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta legacy Steps", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{Content.published_id(doc.doc_id)}")
    {:ok, view, _html} = live(conn, path)

    socket = socket_of(view)
    [projected_parent] = socket.assigns.editor_blocks
    [projected_row] = projected_parent["steps"]
    [projected_child] = projected_row["children"]
    assert projected_parent["id"] == "legacy-steps"
    assert is_binary(projected_row["id"]) and projected_row["id"] != ""
    assert is_binary(projected_child["id"]) and projected_child["id"] != ""
    assert stored_content(doc.doc_id) == legacy

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(view, "#steps-form-legacy-steps")
    assert has_element?(view, "[data-step-row-id='#{projected_row["id"]}']")
    request_id = Ecto.UUID.generate()

    params = %{
      "block_id" => "legacy-steps",
      "step-count" => "1",
      "step-0-id" => projected_row["id"],
      "step-0-title" => "After",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => request_id
    }

    render_hook(view, "paper-block-autosave", params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^request_id,
      rev: committed_rev
    })

    persisted = stored_blocks(doc.doc_id)
    [persisted_parent] = persisted
    [persisted_row] = persisted_parent["steps"]
    [persisted_child] = persisted_row["children"]
    assert persisted_parent["id"] == "legacy-steps"
    assert persisted_row["id"] == projected_row["id"]
    assert persisted_child["id"] == projected_child["id"]
    assert persisted_row["title"] == "After"
    assert persisted_row["unknown"] == "keep"

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "[data-step-row-id='#{projected_row["id"]}']")
    render_hook(reloaded, "paper-block-autosave", params)

    assert_reply(reloaded, %{
      saved: true,
      replayed: true,
      request_id: ^request_id,
      rev: ^committed_rev
    })

    assert stored_blocks(doc.doc_id) == persisted
  end

  defp stored_blocks(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc.content["blocks"]
  end

  defp stored_content(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc.content
  end

  defp legacy_document!(label, content) do
    id = "beta-steps-#{label}-#{System.unique_integer([:positive])}"
    {:ok, doc} = Content.create_document(@doc_type, %{"doc_id" => id, "title" => label}, @dataset)
    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: content])
    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    stored
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end

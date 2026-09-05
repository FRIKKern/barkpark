defmodule BarkparkWeb.Studio.StudioBetaDocumentReplayTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.Studio.StudioLive

  @dataset "production"
  @doc_type "beta_replay_live_post"
  @doc_id "beta-replay-live-document"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta replay live post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => @doc_id, "title" => "Original title"},
        @dataset
      )

    {:ok, doc: doc}
  end

  test "Beta retries replay once, then fresh token revocation denies the same receipt", %{
    conn: conn,
    doc: doc
  } do
    raw = "beta-document-replay-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "Beta document replay", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}"))

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    socket = :sys.get_state(view.pid).socket
    title = Enum.find(socket.assigns.editor_blocks, &(&1["fieldName"] == "title"))
    request_id = Ecto.UUID.generate()

    params = %{
      "op" => "patch-block",
      "id" => title["id"],
      "patch" => %{"value" => "Saved once"},
      "request_id" => request_id,
      "if_rev" => socket.assigns.editor_doc.rev
    }

    assert {:reply, %{saved: true, request_id: ^request_id, replayed: false, rev: committed_rev},
            committed_socket} = StudioLive.handle_event("paper-op", params, socket)

    assert {:reply, %{saved: true, request_id: ^request_id, replayed: true, rev: ^committed_rev},
            replayed_socket} = StudioLive.handle_event("paper-op", params, committed_socket)

    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert stored.rev == committed_rev
    assert stored.content["title"] == "Saved once"

    {:ok, _revoked} = Auth.revoke_token(token)

    assert {:reply, %{saved: false, request_id: ^request_id}, denied_socket} =
             StudioLive.handle_event("paper-op", params, replayed_socket)

    assert denied_socket.assigns.last_paper_save_ok? == false

    {:ok, unchanged} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert unchanged.rev == committed_rev
    assert unchanged.content["title"] == "Saved once"
  end

  test "published-only first save keeps the Beta editor identity stable for the next save", %{
    conn: conn
  } do
    {:ok, _published} = Content.publish_document(@doc_id, @doc_type, @dataset)

    assert {:error, :not_found} =
             Content.get_document(Content.draft_id(@doc_id), @doc_type, @dataset)

    raw = "beta-document-identity-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta document identity", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}"))

    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    stable_id = ~s(id="paper-editor-#{@doc_id}")
    stable_key = ~s(data-paper-doc-key="#{@dataset}:#{@doc_type}:#{@doc_id}")
    assert beta_html =~ stable_id
    assert beta_html =~ stable_key

    first_socket = :sys.get_state(view.pid).socket
    title = Enum.find(first_socket.assigns.editor_blocks, &(&1["fieldName"] == "title"))

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => title["id"],
      "patch" => %{"value" => "First draft save"},
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => first_socket.assigns.editor_doc.rev
    })

    after_first_html = render(view)
    assert after_first_html =~ stable_id
    assert after_first_html =~ stable_key
    refute after_first_html =~ ~s(id="paper-editor-drafts.#{@doc_id}")

    second_socket = :sys.get_state(view.pid).socket

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => title["id"],
      "patch" => %{"value" => "Second draft save"},
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => second_socket.assigns.editor_doc.rev
    })

    assert render(view) =~ stable_key
    assert {:ok, saved} = Content.get_document("drafts.#{@doc_id}", @doc_type, @dataset)
    assert saved.content["title"] == "Second draft save"
  end
end

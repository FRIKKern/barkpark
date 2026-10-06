defmodule BarkparkWeb.Studio.StudioBetaPublishRevTest do
  # Publishing from Beta's header moves the document to a new revision that no
  # save reply carries. The open editors must hear that revision, or their next
  # edit is sent against the old one and pauses for review
  # (task-904659f0c8145633).
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.Content
  @dataset "production"
  @path "/d/#{@dataset}/studio/betarev/betarev-1"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "betarev",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "body", "title" => "Tekst", "type" => "richText"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "betarev",
        %{"doc_id" => "betarev-1", "title" => "Fjellet", "content" => %{"title" => "Fjellet"}},
        @dataset
      )

    :ok
  end

  defp publish(view) do
    view
    |> element(~s([data-test-id="studio-beta-doc-actions"] [phx-click="publish"]))
    |> render_click()
  end

  defp doc_key(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-paper-doc-key]")
    |> LazyHTML.attribute("data-paper-doc-key")
    |> List.first()
  end

  test "a Beta publish announces the published revision under the editor's key", %{conn: conn} do
    {:ok, view, _} = live(conn, scoped_studio(@path))
    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    key = doc_key(html)
    assert key == "#{@dataset}:betarev:betarev-1"
    {:ok, draft} = Content.get_document("drafts.betarev-1", "betarev", @dataset)

    publish(view)
    {:ok, published} = Content.get_document("betarev-1", "betarev", @dataset)
    published_rev = published.rev
    refute published_rev == draft.rev

    assert_push_event(view, "bp:document-revision", %{rev: ^published_rev, document_key: ^key})
  end

  defp header_actions(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-test-id="studio-beta-doc-actions"] [phx-click]))
    |> LazyHTML.attribute("phx-click")
  end

  test "the first Beta edit of a published doc offers Publish and Discard draft", %{conn: conn} do
    {:ok, _} = Content.publish_document("betarev-1", "betarev", @dataset)
    {:ok, view, _} = live(conn, scoped_studio(@path))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert "unpublish" in header_actions(view)
    refute "publish" in header_actions(view)

    %{"id" => id} =
      Enum.find(
        :sys.get_state(view.pid).socket.assigns.editor_blocks,
        &(&1["fieldName"] == "title")
      )

    {:ok, %{rev: rev}} = Content.get_document("betarev-1", "betarev", @dataset)

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => id,
      "patch" => %{"value" => "Fjellet II"},
      "if_rev" => rev,
      "request_id" => Ecto.UUID.generate()
    })

    assert {:ok, _} = Content.get_document("drafts.betarev-1", "betarev", @dataset)
    actions = header_actions(view)
    assert "publish" in actions
    assert "discard-draft" in actions
    refute "unpublish" in actions
  end

  describe "Paper.push_document_revision/2" do
    alias BarkparkWeb.Studio.StudioLive.Shared.Paper

    defp socket_for(type, rev) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          dataset: @dataset,
          editor_doc: %{doc_id: "drafts.d-1", type: type, rev: rev}
        },
        private: %{live_temp: %{}}
      }
    end

    defp pushed(socket), do: Phoenix.LiveView.Utils.get_push_events(socket)

    test "announces a moved revision under the editor's doc key" do
      assert [["bp:document-revision", %{rev: "r2", document_key: "production:post:d-1"}]] =
               "post" |> socket_for("r2") |> Paper.push_document_revision("r1") |> pushed()
    end

    test "is silent when the revision did not move" do
      assert [] = "post" |> socket_for("r1") |> Paper.push_document_revision("r1") |> pushed()
    end

    test "is silent for a paper: its saves ride paper_rev, which Publish does not move" do
      assert [] = "paper" |> socket_for("r2") |> Paper.push_document_revision("r1") |> pushed()
    end
  end
end

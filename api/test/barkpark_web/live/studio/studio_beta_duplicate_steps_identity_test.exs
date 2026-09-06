defmodule BarkparkWeb.Studio.StudioBetaDuplicateStepsIdentityTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"
  @doc_type "beta_duplicate_steps_identity"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta duplicate Steps identity",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    :ok
  end

  test "duplicate visible and hidden-alias Step identities keep Beta unavailable and reject forged forms",
       %{conn: conn} do
    raw = "beta-duplicate-steps-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(raw, "Beta duplicate Steps identity", @dataset, ["read", "write"])

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    for {label, duplicate, blocks} <- duplicate_fixtures() do
      id = "beta-duplicate-#{label}-#{System.unique_integer([:positive])}"

      {:ok, created} =
        Content.create_document(
          @doc_type,
          %{"doc_id" => id, "title" => label, "content" => %{"blocks" => blocks}},
          @dataset
        )

      assert created.content["blocks"] == blocks
      before = stored_document(created.doc_id)
      path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{id}")
      {:ok, view, html} = live(conn, path)
      socket = socket_of(view)

      assert socket.assigns.editor_mode == :classic
      assert socket.assigns.editor_blocks == []
      assert socket.assigns.editor_blocks_identity_error == {:duplicate_id, duplicate}
      refute html =~ ~s(data-test-id="editor-mode-beta")

      assert view
             |> element(~s([data-test-id="studio-beta-identity-error"]))
             |> render() =~
               "Block editing is unavailable because this document has duplicate block IDs."

      request_id = Ecto.UUID.generate()

      render_hook(view, "paper-edit-block", %{
        "block_id" => "steps",
        "step-count" => "1",
        "step-0-id" => "row",
        "step-0-title" => "Forged",
        "if_rev" => socket.assigns.editor_doc.rev,
        "request_id" => request_id
      })

      assert_reply(view, %{saved: false, request_id: ^request_id})
      assert socket_of(view).assigns.editor_mode == :classic
      assert socket_of(view).assigns.editor_blocks == []
      assert stored_document(created.doc_id) == before
    end
  end

  test "an already-Beta editor refreshes identities and refuses a newly ambiguous document",
       %{conn: conn} do
    raw = "beta-stale-toggle-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta stale toggle", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    id = "beta-stale-toggle-#{System.unique_integer([:positive])}"
    canonical = [steps(%{"id" => "row", "title" => "Before", "children" => []})]

    {:ok, created} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => id, "title" => "Stale toggle", "content" => %{"blocks" => canonical}},
        @dataset
      )

    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{id}")
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, ~s([data-test-id="editor-mode-beta"]))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert socket_of(view).assigns.editor_mode == :beta
    assert has_element?(view, ~s([data-test-id="studio-doc-beta-editor"]))

    duplicate = "late-duplicate"

    ambiguous = [
      paragraph(duplicate, "Outside"),
      steps(%{
        "id" => "row",
        "title" => "Before",
        "children" => [paragraph(duplicate, "Inside")]
      })
    ]

    Repo.update_all(
      from(d in Document, where: d.id == ^created.id),
      set: [content: %{"blocks" => ambiguous}]
    )

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    socket = socket_of(view)
    assert socket.assigns.editor_mode == :classic
    assert socket.assigns.editor_blocks == []
    assert socket.assigns.editor_blocks_identity_error == {:duplicate_id, duplicate}
    assert has_element?(view, ~s([data-test-id="studio-beta-identity-error"]))
    refute has_element?(view, ~s([data-test-id="studio-doc-beta-editor"]))
    assert stored_document(created.doc_id).content == %{"blocks" => ambiguous}
  end

  defp duplicate_fixtures do
    [
      {"visible", "visible-duplicate",
       [
         paragraph("visible-duplicate", "Outside"),
         steps(%{
           "id" => "row",
           "title" => "Before",
           "children" => [paragraph("visible-duplicate", "Inside")]
         })
       ]},
      {"hidden-alias", "alias-duplicate",
       [
         steps(%{
           "id" => "row",
           "title" => "Before",
           "children" => [paragraph("alias-duplicate", "Visible")],
           "blocks" => [paragraph("alias-duplicate", "Hidden compatibility alias")]
         })
       ]}
    ]
  end

  defp steps(row), do: %{"id" => "steps", "type" => "steps", "steps" => [row]}

  defp paragraph(id, text) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }
  end

  defp stored_document(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end

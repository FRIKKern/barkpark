defmodule BarkparkWeb.Studio.StudioBetaDiscardRefreshTest do
  # Discard draft in Beta must put the published version back into the open
  # block editors, which are phx-update="ignore" and keep the discarded text
  # and the draft's revision otherwise (task-a7a40aa124dd3c36).
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.Content
  @dataset "production"
  @path "/d/#{@dataset}/studio/discardrev/discardrev-1"

  defp body(text) do
    %{
      "blocks" => [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      ]
    }
  end

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "discardrev",
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
        "discardrev",
        %{
          "doc_id" => "discardrev-1",
          "content" => %{"title" => "Fjellet", "body" => body("Publisert")}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("discardrev-1", "discardrev", @dataset)

    {:ok, _} =
      Content.create_document(
        "discardrev",
        %{
          "doc_id" => "drafts.discardrev-1",
          "content" => %{"title" => "Fjellet", "body" => body("Utkast")}
        },
        @dataset
      )

    :ok
  end

  defp discard(view) do
    view
    |> element(~s([data-test-id="studio-beta-doc-actions"] [phx-click="discard-draft"]))
    |> render_click()

    view |> element(~s(button[phx-click="confirm-discard"])) |> render_click()
  end

  test "Beta discard pushes the published blocks with the published revision", %{conn: conn} do
    {:ok, view, _} = live(conn, scoped_studio(@path))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    discard(view)

    assert {:error, :not_found} =
             Content.get_document("drafts.discardrev-1", "discardrev", @dataset)

    {:ok, %{rev: rev}} = Content.get_document("discardrev-1", "discardrev", @dataset)

    assert_push_event(view, "bp:block-update", %{
      block_id: "p-1",
      rev: ^rev,
      request_id: nil,
      block: %{"content" => [%{"value" => "Publisert"}]}
    })
  end

  test "Classic discard pushes no block updates", %{conn: conn} do
    {:ok, view, _} = live(conn, scoped_studio(@path))
    view |> element(~s([phx-click="discard-draft"])) |> render_click()
    view |> element(~s(button[phx-click="confirm-discard"])) |> render_click()

    assert {:error, :not_found} =
             Content.get_document("drafts.discardrev-1", "discardrev", @dataset)

    refute_push_event(view, "bp:block-update", %{})
  end
end

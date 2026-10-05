defmodule BarkparkWeb.Studio.DeskRowDraftStateTest do
  @moduledoc """
  The open document's desk row follows its own autosave (task-6a267a15bc929e38).

  Found dogfooding: an edit to a published post wrote `drafts.<id>` and the
  editor header turned to draft, but the desk row kept saying "published,
  Updated 3m ago" until a reload. The row is refreshed from the save itself,
  because our own `document_changed` broadcast is skipped (`sender == self()`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"}
          ]
        },
        @dataset
      )

    for {id, title} <- [{"row-a", "Alpha post"}, {"row-b", "Beta post"}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => title, "content" => %{"excerpt" => "x"}},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "post", @dataset)
    end

    # Age the rows, so "Updated just now" can only come from the save.
    three_hours_ago = DateTime.add(DateTime.utc_now(), -3 * 3_600, :second)

    Barkpark.Repo.query!(
      "UPDATE documents SET updated_at = $1 WHERE doc_id IN ('row-a', 'row-b')",
      [three_hours_ago]
    )

    :ok
  end

  defp row_label(html, id) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(button.bp-doc-row-body[phx-value-id="#{id}"]))
    |> LazyHTML.attribute("aria-label")
  end

  test "an autosave that makes a draft turns the open row to draft, updated just now",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/row-a"))

    assert row_label(html, "row-a") == ["Alpha post, published, Updated 3h ago"]
    order_before = Regex.scan(~r/phx-value-id="(row-[ab])"/, html) |> Enum.map(&List.last/1)

    html =
      view
      |> form("#editor-form", %{"doc" => %{"excerpt" => "edited"}})
      |> render_change()

    assert {:ok, _} = Content.get_document("drafts.row-a", "post", @dataset)
    assert row_label(html, "row-a") == ["Alpha post, draft, Updated just now"]
    # The untouched row is untouched, and nothing moved.
    assert row_label(html, "row-b") == ["Beta post, published, Updated 3h ago"]

    assert Regex.scan(~r/phx-value-id="(row-[ab])"/, html) |> Enum.map(&List.last/1) ==
             order_before
  end
end

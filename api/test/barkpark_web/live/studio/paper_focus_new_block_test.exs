defmodule BarkparkWeb.Studio.PaperFocusNewBlockTest do
  @moduledoc """
  An accepted "+ Add block → Paragraph" or Ingress-ghost write names the new
  block to the canvas (`bp:focus-block`), so the caret lands in it.

  Found live (run-4 lane C dogfood): both writes created an EMPTY paragraph the
  canvas collapses at rest (resting-scaffolds.js hides an empty paragraph unless
  the caret is in it). Focus stayed on the button, nothing appeared, and the
  author's next keystrokes went nowhere. The canvas half (`focusBlock/1`) is
  pinned by `assets/paper-editor/src/canvas/__focus_block.test.mjs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-10-02-focus-new-block-paper"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "tpl-title",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "locked" => true,
              "text" => "A title"
            },
            %{
              "id" => "b-intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Body."}]
            }
          ]
        })
      )

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{paper.doc_id}"))

    {:ok, view: view}
  end

  defp rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp stored_ids do
    %{content: %{"blocks" => blocks}} = Content.get_public_paper(@slug, @dataset)
    Enum.map(blocks, & &1["id"])
  end

  test "Add block → Paragraph asks the canvas to focus the new block", %{view: view} do
    before = stored_ids()
    render_hook(view, "paper-add-block", %{"block-type" => "paragraph", "if_rev" => rev(view)})

    [new_id] = stored_ids() -- before
    assert_push_event(view, "bp:focus-block", %{id: ^new_id})
  end

  test "materializing the Ingress ghost asks the canvas to focus the ingress", %{view: view} do
    before = stored_ids()

    render_hook(view, "paper-materialize-slot", %{
      "kind" => "ingress",
      "after" => "tpl-title",
      "if_rev" => rev(view)
    })

    [new_id] = stored_ids() -- before
    assert_push_event(view, "bp:focus-block", %{id: ^new_id})
  end

  # task-13abe9408c006c96: a field block's control takes the focus in the canvas.
  for type <- ~w(field-string field-select) do
    test "Add block → #{type} asks the canvas to focus the new field block", %{view: view} do
      before = stored_ids()

      render_hook(view, "paper-add-block", %{"block-type" => unquote(type), "if_rev" => rev(view)})

      [new_id] = stored_ids() -- before
      assert_push_event(view, "bp:focus-block", %{id: ^new_id})
    end
  end

  test "a non-paragraph add does not steal focus", %{view: view} do
    render_hook(view, "paper-add-block", %{"block-type" => "divider", "if_rev" => rev(view)})
    refute_push_event(view, "bp:focus-block", %{id: _}, 200)
  end
end

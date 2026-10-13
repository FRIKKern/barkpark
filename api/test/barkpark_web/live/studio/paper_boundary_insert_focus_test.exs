defmodule BarkparkWeb.Studio.PaperBoundaryInsertFocusTest do
  @moduledoc """
  An image or equation picked in the canvas slash menu is built by the server
  and lands in its boundary editor with the caret in it
  (task-f92354b415b486f5).

  Found dogfooding: the canvas inserted them as its own nodes with transient
  controls, and ~500 ms later the save echo re-partitioned the paper and
  re-rendered them as boundary editors outside the canvas. What the author had
  typed was lost (stored `{"type":"equation"}` with no tex) and focus fell to
  BODY. The canvas now routes the pick through `paper-slash-insert` (its half is
  pinned by `canvas/__server_insert_widgets.test.mjs`), and the server names
  the new block on `bp:focus-boundary` (the hook half:
  `src/__boundary_focus.test.mjs`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-10-06-boundary-insert-focus-paper"

  setup %{conn: conn} do
    # The canvas is the default editor; pin it, because a module that sets
    # BARKPARK_PAPER_CANVAS=0 renders the paper without its canvas runs and
    # this file's boundary-editor assertions then see a different page.
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      if prev_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", prev_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

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

  defp blocks do
    %{content: %{"blocks" => blocks}} = Content.get_public_paper(@slug, @dataset)
    blocks
  end

  defp insert!(view, type) do
    before = Enum.map(blocks(), & &1["id"])

    render_hook(view, "paper-slash-insert", %{
      "type" => type,
      "afterId" => "b-intro",
      "if_rev" => rev(view)
    })

    [new] = Enum.reject(blocks(), &(&1["id"] in before))
    new
  end

  test "an equation pick is built by the server, focused, and keeps what is typed next",
       %{view: view} do
    new = insert!(view, "equation")
    id = new["id"]
    assert new["type"] == "equation"
    assert_push_event(view, "bp:focus-boundary", %{id: ^id})

    html = render(view)
    assert html =~ ~s(id="equation-form-#{id}")

    view
    |> form("#equation-form-#{id}", %{"tex" => "E = mc^2"})
    |> render_change(%{"block_id" => id, "if_rev" => rev(view)})

    assert Enum.find(blocks(), &(&1["id"] == id))["tex"] == "E = mc^2"
  end

  test "an image pick is built by the server as an image and focused", %{view: view} do
    new = insert!(view, "image")
    id = new["id"]
    assert %{"type" => "image", "src" => ""} = new
    assert_push_event(view, "bp:focus-boundary", %{id: ^id})
    assert render(view) =~ ~s(id="paper-fld-#{id}")
  end

  test "a paragraph slash insert does not ask for boundary focus", %{view: view} do
    insert!(view, "paragraph")
    refute_push_event(view, "bp:focus-boundary", %{id: _}, 200)
  end
end

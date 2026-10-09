defmodule BarkparkWeb.Studio.StudioLandmarksTest do
  @moduledoc """
  task-50c06dba12b3e908: Studio exposed no landmarks, no headings and no skip
  link — a keyboard or screen-reader user had no way past the ~15-control top
  bar to the document, and nothing to jump to (WCAG 2.4.1, 1.3.1). Studio now
  renders a skip link as its first focusable, a focus anchor before the page
  content, a labelled navigation on the tab row, the desk as `main`, and the
  open document's title as a level-1 heading.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "landmark_note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "landmark_note",
        %{"doc_id" => "lm-1", "title" => "Fjellsanger"},
        @dataset
      )

    {:ok, conn: conn}
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(html, sel), do: html |> doc() |> LazyHTML.query(sel)

  test "the skip link is the first focusable and lands on an anchor before the content", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/landmark_note/lm-1"))

    focusable = q(html, ".studio-shell a[href], .studio-shell button")
    assert [first | _] = LazyHTML.attribute(focusable, "href")
    assert first == "#studio-content"
    assert LazyHTML.attribute(q(html, "a.bp-skip-link"), "href") == ["#studio-content"]

    target = q(html, "#studio-content")
    assert LazyHTML.attribute(target, "tabindex") == ["-1"]
  end

  test "the tab row is a labelled navigation and the open document is the one main", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/landmark_note/lm-1"))

    nav = q(html, ~s(.studio-bar-tabs[role="navigation"]))
    assert Enum.count(nav) == 1
    assert [label] = LazyHTML.attribute(nav, "aria-label")
    assert label != ""

    # task-8e2fa7915ed7faa0: the open document's panel is the main region, not
    # the whole desk (which also holds the navigation columns).
    assert Enum.count(q(html, ~s(#studio-panes[role]))) == 0
    assert Enum.count(q(html, ~s(main, [role="main"]))) == 1
    assert Enum.count(q(html, ~s(.editor-panel[role="main"]))) == 1
  end

  # task-8e2fa7915ed7faa0: with the desk as main, a paper page nested its
  # shell's own labelled <main> inside it. The paper shell is the one main.
  test "a paper page exposes exactly one main, the paper shell", %{conn: conn} do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "lm-paper",
          "style" => "article",
          "body_html" => "<p>Hei.</p>"
        })
      )

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/lm-paper"))

    mains = q(html, ~s(main, [role="main"]))
    assert Enum.count(mains) == 1
    assert LazyHTML.attribute(mains, "data-test-id") == ["studio-paper-shell"]
  end

  test "the open document's title is the page's level-1 heading", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/landmark_note/lm-1"))

    h1 = q(html, ".editor-header h1")
    assert Enum.count(h1) == 1
    assert h1 |> LazyHTML.text() |> String.trim() == "Fjellsanger"
  end
end

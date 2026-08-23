defmodule BarkparkWeb.Studio.StudioFocusAfterSelectTest do
  @moduledoc """
  spd-bl-focus-after-select — activating a document row at narrow or phone
  must not drop focus to <body>.

  THE DECISION (criterion 1, written down before the code):

    * At **wide** and **standard** the clicked row element ITSELF survives the
      patch (it re-renders wearing aria-current), so the browser never moves
      `activeElement` — NOTHING is focused, deliberately, and this file pins
      that nothing changed there.
    * At **narrow** the surviving pane is the 44px strip, and the strip is
      REFUSED as a focus target: its activation fires `expand-pane` with
      `Enum.take(nav_path, num_panes - 1)`, which drops the document segment —
      focusing it would put a "close the document" button under the keyboard
      user's hands.
    * At **phone** `display_state/4` hides every pane — there is no pane
      element on the page at all, so the `focus_pane_idx` idiom is
      structurally unusable.
    * The target at BOTH buckets is therefore the opened document's own
      header (`document_header/1`, `.pane-header.editor-header`): the user's
      action was "open this document", so focus follows the action's outcome,
      and the header is the element that announces the document's title. It
      reuses the pane_column focus idiom byte-for-byte (`tabindex="-1"` +
      `phx-mounted={JS.focus()}`), pinned absent by default so an initial
      load never steals focus.
    * SCOPE, honestly: the mark rides `document_header/1`, which the paper
      pane and the field-form editor render — the two surfaces a Structure
      document row opens. The sheet/graph panes render their own chrome and
      are out of this slice.

  NON-VACUITY: the identical probe counts 1 for the `expand-pane` path (the
  D79 focus-return, pinned here as the contrast control) — so a probe that
  found 0 after a select was measuring a real absence, not a blind selector.
  Re-derived on a tree containing current origin/main: before the fix the
  select arms of this file were red with `found 0 focus-marked elements`.
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
          "title" => "Posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "focus-probe-post", "title" => "Focus Probe", "content" => %{}},
        @dataset
      )

    :ok
  end

  # The probe: every element carrying BOTH halves of the focus idiom. One
  # selector for the whole file so the select arms and the expand-pane
  # contrast arm cannot drift apart.
  defp focus_marks(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([tabindex="-1"][phx-mounted]))
    |> Enum.to_list()
  end

  defp mount_desk(conn) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))
    view
  end

  defp set_bucket(view, bucket) do
    render_hook(view, "width-bucket", %{"bucket" => bucket})
  end

  defp select_doc(view) do
    view
    |> element(~s(button[phx-click="select"][phx-value-id="focus-probe-post"]))
    |> render_click()
  end

  for bucket <- ["narrow", "phone"] do
    test "at #{bucket}, a document select marks exactly one focus target — and never the strip",
         %{conn: conn} do
      bucket = unquote(bucket)
      view = mount_desk(conn)
      set_bucket(view, bucket)

      html = select_doc(view)
      marks = focus_marks(html)

      assert length(marks) == 1,
             """
             After a document select at #{bucket} exactly ONE element must carry
             the focus mark (tabindex="-1" + phx-mounted) — the clicked row is
             destroyed at this bucket, so with no mark the browser drops focus
             to <body> (spd-bl-focus-after-select).

             found #{length(marks)} focus-marked elements
             """

      [mark] = marks
      classes = LazyHTML.attribute(mark, "class") |> List.first() |> to_string()

      assert classes =~ "editor-header",
             "the focus target must be the opened document's own header, got class=#{inspect(classes)}"

      refute classes =~ "pane-column",
             "the strip must NEVER be the focus target — its activation closes the document"
    end
  end

  for bucket <- ["wide", "standard"] do
    test "at #{bucket}, a document select marks NOTHING — the clicked row survives the patch",
         %{conn: conn} do
      bucket = unquote(bucket)
      view = mount_desk(conn)
      set_bucket(view, bucket)

      html = select_doc(view)

      assert focus_marks(html) == [],
             "at #{bucket} the clicked row survives (it re-renders wearing " <>
               "aria-current), so the fix must not steal focus where none was lost"

      # The stronger claim the decision rests on: the row element itself is
      # still in the DOM, now marked current.
      assert html =~ ~s(phx-value-id="focus-probe-post")
    end
  end

  test "contrast control — the expand-pane path still counts exactly 1 (the D79 focus-return)",
       %{conn: conn} do
    view = mount_desk(conn)
    set_bucket(view, "narrow")
    select_doc(view)

    # With the editor open at narrow, the list pane is the collapsed strip;
    # activating it fires expand-pane, which sets focus_pane_idx — the
    # pre-existing pinned idiom this file's probe must be able to see.
    html =
      view
      |> element(~s(button#pane-posts[phx-click="expand-pane"]))
      |> render_click()

    marks = focus_marks(html)

    assert length(marks) == 1,
           "the probe must see the D79 expand-pane focus mark (got #{length(marks)}) — " <>
             "if this arm fails the select arms above prove nothing"

    [mark] = marks
    classes = LazyHTML.attribute(mark, "class") |> List.first() |> to_string()
    assert classes =~ "pane-column"
  end
end

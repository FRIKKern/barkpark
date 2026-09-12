defmodule BarkparkWeb.Studio.RowPressStateCoverageTest do
  @moduledoc """
  THE PRESS STATE'S REACH — the half `row_press_state_guard_test.exs` cannot see
  (spd-w18-desk-click-latency, criterion 2).

  That file proves the row-level pending state EXISTS: the hook stamps
  `aria-busy="true"` on the pressed control inside `_paOnPress`, clears it in
  the single release path `_paRelease`, and `#studio-panes [aria-busy="true"]`
  paints a moving bar. All of it is read out of the layout SHEET.

  What no sheet read can tell you is WHICH CONTROLS THE STATE ACTUALLY REACHES.
  The listener is delegated on `#studio-panes` and the paint is scoped to
  `#studio-panes` descendants, so a control's coverage is a pure DOM-containment
  fact about the RENDERED desk — and containment is exactly what a `grep` over
  a layout cannot answer. Move the pane header actions one level out of that
  container while refactoring and every assertion in the guard file stays green
  while the "+" silently goes back to the wordless `.phx-click-loading` tint.

  So this file asserts containment against the rendered desk, control by
  control, in the LiveView the human actually mounts:

    * the container is there AND still carries the hook that does the stamping,
    * the Structure row (`button.pane-item[phx-click="select"]`) is inside it,
    * the create control (`button.pane-add-btn[phx-click="new-document"]`) is
      inside it — the "+" of spd-w18-plus-creates-without-navigating, whose
      press is the one with a data tail,
    * and NOTHING carries `aria-busy` at rest, which is the other half of
      "a test can assert it": a state that is always on names nothing.

  The last describe is the control: the same containment selector with a wrong
  ancestor, and with a wrong event name, must NOT match — otherwise these
  assertions would pass against a desk that contains neither.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  @container ~s(#studio-panes)
  @row ~s(#studio-panes button.pane-item[phx-click="select"])
  @plus ~s(#studio-panes button.pane-add-btn[phx-click="new-document"])

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))
    {:ok, view: view, html: html}
  end

  describe "the container that owns the state" do
    test "#studio-panes renders and still carries the hook that stamps it", %{view: view} do
      assert has_element?(view, @container),
             "the delegated listener and the busy paint are both scoped to #studio-panes; without it the row state reaches nothing"

      assert has_element?(view, ~s(#studio-panes[phx-hook="WidthBucket"])),
             "WidthBucket is where _paOnPress lives — LiveView reads exactly ONE hook per element, so losing it here loses the press state outright"
    end
  end

  describe "the controls the desk press state must reach" do
    test "a Structure row is inside the container", %{view: view} do
      assert has_element?(view, @row),
             "the Structure row is outside #studio-panes — the press that spd-w18 measured being swallowed would carry no named state at all"
    end

    test "the \"+\" create control is inside the container", %{view: view} do
      assert has_element?(view, @plus),
             "the create control is outside #studio-panes — the one press whose silence leaves an orphan Untitled draft would go back to the grey tint"
    end
  end

  describe "the state is ABSENT at rest" do
    # `has_element?`, never `html =~ "aria-busy"`. The mounted HTML carries the
    # ROOT LAYOUT, and the layout carries the rule
    # `#studio-panes [aria-busy="true"]::after` that paints this very state —
    # so the substring form matches the STYLESHEET on a desk where no element
    # is busy at all, and reds a correct build. (It did, on the first run of
    # this file.) The selector asks the question the criterion asks: does any
    # ELEMENT claim to be busy?
    test "no element on a quiet desk claims to be busy", %{view: view} do
      refute has_element?(view, "[aria-busy]"),
             "a desk nobody has pressed reports work in flight; a state that is always on distinguishes nothing"
    end
  end

  describe "control — the containment selectors are not vacuous" do
    test "a wrong ancestor does not match", %{view: view} do
      refute has_element?(view, ~s(#studio-panes-not-a-container button.pane-item)),
             "these selectors match anything, so their passing says nothing about containment"
    end

    test "a wrong event name does not match", %{view: view} do
      refute has_element?(view, ~s(#studio-panes button.pane-item[phx-click="not-an-event"])),
             "the attribute half of the selector is not being read"
    end
  end
end

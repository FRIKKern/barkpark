defmodule BarkparkWeb.Studio.StudioPresenceDotPointerTest do
  @moduledoc """
  `spd-b35-presence-dot-intercepts-action-bar` — the editor-header presence
  indicator must never be what a click lands on.

  ## The defect, as measured

  A real-mouse Playwright click on `[data-test-id=open-secondary-picker]`
  timed out for 30s against the deployed Studio: the button was visible,
  enabled and stable, and `<div class="presence-dot" title="User 0vs0 is
  editing">` was the element the hit test returned.

  The presence dot is the SYMPTOM, not the cause. `document_header/1` lays
  out two flex children: a title group whose flex base size is its
  max-content width (`.pane-header-title` is `white-space: nowrap`, so the
  span's own `min-width: auto` floor was the whole string), and an actions
  group with `flex-basis: 0`. Once the title alone exceeds the header, free
  space goes negative and the shrink phase distributes by
  `flex-shrink x flex-basis` — the actions' scaled shrink factor is `1 x 0 =
  0`, so the title kept every pixel and the ENTIRE action bar resolved to a
  zero-width box. Its buttons still owned non-empty layout boxes: clipped by
  `bp-overflow-menu`'s `overflow: hidden`, spilled leftwards by its
  `justify-content: flex-end`, and sitting on top of the title and the dots.
  Playwright calls a clipped element visible (non-empty bounding box), then
  hit-tests its centre and finds whatever paints there — the title span, or
  the presence dot.

  `bp-overflow-menu`'s own priority+ collapse could not save it either: in
  LTR, content overflowing towards the START edge does not extend
  `scrollWidth`, so `_reflow()`'s `if (this.scrollWidth <= available)
  return;` guard saw no overflow and never revealed the ••• trigger.

  ## What was measured in a real browser

  The shipped stylesheet plus the shipped `document_header/1` markup plus the
  shipped `bp-overflow-menu.js`, driven in Chrome via `elementFromPoint` at
  each action button's centre, across
  `{short, long} title x {0, 1, 3} dots x {1400, 1280, 760, 520, 360, 260}px`:

    * as shipped ............................................. 22/36 reachable
    * `pointer-events: none` on `.presence-dots` ALONE ........ 22/36 (no change)
    * title group yields, no `safe` keyword ................... 28/36
    * title group yields + `justify-content: safe flex-end` ... 36/36

  The second row is why this file exists as more than a one-line CSS pin: the
  remedy the defect report implies fixes NOTHING. Making the dots inert only
  changes WHICH element swallows the click — `.pane-header-title` takes over.
  Note also the `short/1dot/260px` cell: the dot intercepted a doc action with
  a perfectly ordinary title and only ONE presence on the document, and
  `presences_on_doc/3` does not exclude the viewer themselves, so that one
  presence can be you. The report's "whenever a second viewer is present"
  understates the blast radius.

  ## What a green here proves, and what it does not

  ExUnit has no layout engine. It cannot observe a computed width or run a
  hit test, so this file locks the two source facts that produce the fixed
  geometry (the header's own inline style, and the three stylesheet
  declarations) plus the rendered accessibility contract. The real-mouse half
  is the browser measurement above and the deployed run's job — a green here
  is a tripwire against silent EDITS to the fix, never a pixel.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "b35-post", "title" => "B35 post", "content" => %{}},
        @dataset
      )

    :ok
  end

  # Mount Studio on the document AS a named identity — the same localStorage
  # connect params studio presence reads (see StudioLive.Shared.track_presence/1).
  defp open_as!(user_id, user_name) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_connect_params(%{"user_id" => user_id, "user_name" => user_name})

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/b35-post"))
    view
  end

  # Presence diffs (Phoenix.Tracker) and the LV re-render they trigger are
  # asynchronous — retry rather than sleep a fixed eternity.
  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end

  # The editor header as a queryable fragment. LazyHTML is the LiveViewTest
  # DOM dep in this repo — Floki is NOT a dependency.
  defp header(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(".editor-header")
    |> LazyHTML.to_html()
    |> LazyHTML.from_fragment()
  end

  defp count(hdr, selector), do: hdr |> LazyHTML.query(selector) |> Enum.count()

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  # ── the rendered contract ──────────────────────────────────────────────────

  describe "editor header with co-presence" do
    test "the presence group and the doc-action bar both render, in the same header" do
      _alice = open_as!("b35-alice", "Alice")
      bob = open_as!("b35-bob", "Bob")

      eventually(fn ->
        hdr = header(bob)

        # Two identities on one document: two dots, one group.
        assert count(hdr, ".presence-dots") == 1
        assert count(hdr, ".presence-dot") == 2

        # …and the action the report could not click is in the SAME header.
        assert count(hdr, ~s(button[data-test-id="open-secondary-picker"])) == 1
      end)
    end

    test "the presence group names its editors to non-pointer input, and no dot is a hover target" do
      _alice = open_as!("b35-alice", "Alice")
      bob = open_as!("b35-bob", "Bob")

      eventually(fn ->
        hdr = header(bob)
        group = LazyHTML.query(hdr, ".presence-dots")

        # The name rides an accessible name on the GROUP, which keyboard,
        # touch and screen readers can all reach…
        assert attr(group, "role") == "img"
        label = attr(group, "aria-label")
        assert label =~ "Alice"
        assert label =~ "Bob"

        # …and NOT a per-dot `title=` tooltip, which only a mouse could get at
        # and which the group's `pointer-events: none` now makes unreachable
        # even by one. A `title` left behind is dead markup that reads as a
        # live affordance.
        assert count(hdr, ".presence-dot[title]") == 0
        assert count(hdr, ".presence-dot") == 2
      end)
    end

    test "one presence is enough to render a dot — the viewer counts as their own presence" do
      # `presences_on_doc/3` does not exclude self, so the overlap hazard is
      # NOT gated on a second viewer the way the defect report assumed.
      solo = open_as!("b35-solo", "Solo")

      eventually(fn ->
        assert count(header(solo), ".presence-dot") == 1
      end)
    end
  end

  # ── the geometry contract, pinned at its source ────────────────────────────

  describe "header geometry" do
    test "the title group is capped so the action bar always keeps a real width" do
      solo = open_as!("b35-solo", "Solo")

      eventually(fn ->
        hdr = header(solo)
        # The header's FIRST element child is the title/status/presence group;
        # the second is the actions group.
        style = hdr |> LazyHTML.query(".editor-header > div:first-child") |> attr("style")

        # Both are load-bearing and neither substitutes for the other:
        # `min-width: 0` lets the group shrink past its min-content floor,
        # `max-width` caps its flex BASE SIZE so the leftover space the
        # actions grow into can never be negative.
        assert style =~ "min-width: 0"
        assert style =~ "max-width: 70%"
      end)
    end

    test "the title span can actually shrink, so its ellipsis engages" do
      # `overflow/text-overflow/white-space` were always declared; without
      # `min-width: 0` the span's automatic minimum size is the whole string
      # and the ellipsis never fires.
      assert declarations(".pane-header-title") =~ "min-width: 0"
    end

    test "the presence indicator is pointer-inert and shrink-proof" do
      decls = declarations(".presence-dots")
      assert decls =~ "pointer-events: none"
      assert decls =~ "flex-shrink: 0"
    end

    test "bp-overflow-menu can see its own overflow" do
      # `safe` falls back to start alignment exactly when the content
      # overflows, so the spill goes RIGHT and `scrollWidth` reports it —
      # which is the only reason `_reflow()` ever marks `[data-overflowed]`
      # and reveals the ••• trigger. Plain `flex-end` spills LEFT, which in
      # LTR does not extend `scrollWidth` at all.
      decls = declarations("bp-overflow-menu")
      assert decls =~ "justify-content: safe flex-end"
      # The un-prefixed fallback stays for UAs without `safe`.
      assert decls =~ "justify-content: flex-end"
    end
  end

  # Body of the FIRST rule in root.html.heex whose selector is exactly
  # `selector`, with comments stripped. Deliberately literal and local: a pin
  # that re-derives its expectation from the sheet it guards cannot fail from
  # the only thing it purports to guard.
  defp declarations(selector) do
    sheet = File.read!(@root)

    [_, body | _] =
      Regex.run(
        ~r/(?:^|\})\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/m,
        sheet
      ) || flunk("no rule with selector #{inspect(selector)} in root.html.heex")

    String.replace(body, ~r|/\*.*?\*/|s, "")
  end
end

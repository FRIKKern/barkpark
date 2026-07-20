defmodule BarkparkWeb.Studio.WideGeometryLockTest do
  @moduledoc """
  studio-space-priority-desk `spd-w6-wide-geometry-lock` — the wide bucket's
  FIRST layout lock.

  ## Why this file exists

  Epic criterion 2 reads "Desktop ≥1280 shows no user-visible regression vs
  pre-epic `89f151c21`" and it is the literal gate on sealing this epic. Its
  DOM half has exactly one non-vacuous lock (the 40-cell `display_state/4`
  literal table in `pane_builder_test.exs`). Its LAYOUT half had none, and
  that was proven by deliberate fault injection, not suspected:

    * regressing `.pane-column` `width: 260px` → `180px` — a change that
      visibly narrows every nav column and widens the reading measure at
      viewport 1280 and 1440 — passed **77 tests, 0 failures** across
      `pane_builder_test`, `studio_live_width_bucket_test`,
      `measure_parity_test`, `width_bucket_seam_test` and
      `editor_panel_containment_test` (charter D94).

  Five suites, seventy-seven tests, and not one pixel of wide-bucket layout
  was locked. This file is that lock.

  ## The idiom is LITERAL, deliberately

  The same injection run showed which idiom survives and which is decoration.
  The 40-cell table went red with a readable diff because its expectations are
  hardcoded constants. The test beside it — "wide/standard are bit-identical
  to `collapse?/3`" — computed its expectation FROM the function it guarded,
  so both sides moved together and it stayed green through a real regression.

  So every expectation below is a hardcoded string copied out of the
  stylesheet, never a value re-derived from the stylesheet. A pin that reads
  its own subject cannot fail from the only thing it purports to guard.

  ## What is pinned, and why each one is wide-bucket geometry

    * `.pane-layout` — the desk row itself. `overflow-x: auto` is load-bearing
      and NEW this epic (pre-epic it was `overflow: hidden`): it is what turns
      an over-wide content column into a user-visible horizontal scrollbar
      instead of a silent clip, which is the exact mechanism behind D85's
      measured 12px bind at viewport 1280 under Georgia.
    * `.pane-column` — the nav column. Pre-epic it was rigid
      (`min-width: 200px; flex-shrink: 0`); the epic made it compressible
      (`clamp(...)`, `flex-shrink: 1`) so list panes yield before the content
      pane starves (D5). At any ≥1280 desktop there is no squeeze, flex basis
      wins, and the column must still measure the old 260px. That equality is
      the whole wide-bucket promise, so the basis and the clamp CEILING are
      pinned together — a regression that moves either one moves the desk.
    * `.pane-column--collapsed` — the 44px back strip, rigid by contract. If
      it ever becomes compressible the strip stops being a fixed rail.
    * `.editor-panel` — the content pane. `min-width: 560px` and the
      `container-type`/`container-name` pair are both NEW this epic and both
      are permitted BY NAME by D94's re-authored criterion 2 — which is
      exactly why they need pinning rather than waiving: `container-name:
      content` is the query base every `@container content (...)` floor in
      this sheet resolves against, so losing it silently disables the
      protected measure rather than breaking it loudly.

  ## The second half: the wide bucket must get those rules VERBATIM

  Pinning the base declaration is not enough on its own. A later `@media
  (min-width: 1280px) { .pane-column { width: 180px } }` would leave every pin
  above green and still ship the regression. So this file also takes a
  LITERAL CENSUS of every rule in the sheet that declares a box-geometry
  property on the `.pane-layout` / `.pane-column` / `.editor-panel` families,
  and asserts the census is exactly the set enumerated here — each override
  scoped to a non-wide bucket (`html[data-width-bucket="phone"]`) or to a
  variant class that the wide desk does not carry by default. A new override
  reds this test and its author has to declare which bucket it belongs to.

  ## Why the checks are TEXT-based

  ExUnit has no layout engine — it cannot observe a computed width. It can
  only observe the source facts that produce one. The live-browser counterpart
  is the wave-6 instrument's measured matrix at viewport 1280/1440; this file
  is what keeps those rows from rotting between waves.

  This slice READS `root.html.heex` and never edits it (D16/D92 — `spd-b29`
  is that file's sole owner this round). It is also file-disjoint from
  `measure_parity_test.exs`, which is `spd-s7`-fenced; the small parsing
  helpers below are duplicated on purpose rather than shared, so that this
  lock cannot be weakened by an edit to a file this slice may not touch.
  """
  use ExUnit.Case, async: true

  @moduletag :studio_wide_geometry_lock

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # Box-geometry properties. A change to any of these on the pane families
  # moves the desk; colour, borders and typography deliberately do not.
  @geometry_props ~w(width min-width max-width flex flex-shrink flex-basis
                     container-type container-name overflow overflow-x
                     overflow-y display)

  # THE CENSUS. Every rule in root.html.heex that declares a geometry property
  # on the .pane-layout / .pane-column / .editor-panel families, as
  # {selector, sorted geometry properties it declares}. Hardcoded, not
  # gathered: this is the expected set, and the test compares the sheet
  # against it.
  #
  # Read the non-base entries as the answer to "does the WIDE bucket see this
  # rule?" — every one of them is gated behind a bucket attribute the wide
  # desk never carries, or behind a variant class (`--collapsed`,
  # `.sheet-editor`, `.editor-with-preview`) that is opt-in per surface.
  @geometry_census [
    # --- the wide desk's own boxes: these ARE the wide bucket ---
    {".pane-layout", ~w(display flex overflow-x overflow-y)},
    {".pane-column", ~w(display flex-shrink min-width width)},
    {".pane-column--collapsed", ~w(flex-shrink max-width min-width width)},
    {".editor-panel", ~w(container-name container-type display flex min-width overflow)},

    # --- phone bucket: html[data-width-bucket="phone"], never wide ---
    {~S|html[data-width-bucket="phone"] .pane-layout:has(> .editor-panel) .pane-column|,
     ~w(display)},
    {~S|html[data-width-bucket="phone"] .pane-layout:not(:has(> .editor-panel)) .pane-column:not(.pane-column--last)|,
     ~w(display)},
    {~S|html[data-width-bucket="phone"] .pane-column--last|, ~w(flex)},
    {~S|html[data-width-bucket="phone"] .editor-panel|, ~w(min-width)},

    # --- beta editor focus: opt-in attribute, off by default ---
    {~S|html[data-editor-focus="beta"] .pane-column.bp-doc-list|, ~w(display)},
    {~S|html[data-editor-focus="beta"] .editor-body.editor-panel-main|, ~w(max-width)},

    # --- per-surface variant classes, not the default desk ---
    {".editor-panel.sheet-editor", ~w(container-type)},
    {".editor-with-preview .editor-panel-main", ~w(flex min-width)},
    {".editor-with-preview.has-onix-preview .editor-panel-main", ~w(flex max-width)},

    # --- a different element that merely shares the name prefix ---
    {".pane-column-collapsed-label", ~w(display flex overflow)}
  ]

  describe "the wide desk's box geometry, pinned as literal constants" do
    test ".pane-layout is a flex row that SCROLLS horizontally rather than clipping" do
      block = block!(".pane-layout")

      assert value!(block, ".pane-layout", "display") == "flex"
      assert value!(block, ".pane-layout", "flex") == "1"
      assert value!(block, ".pane-layout", "overflow-y") == "hidden"

      assert value!(block, ".pane-layout", "overflow-x") == "auto",
             """
             `.pane-layout` no longer scrolls horizontally.

             Pre-epic this rule was `overflow: hidden`, and the epic changed it
             to `overflow-x: auto` on purpose (charter D94). That change is what
             makes an over-wide content column a VISIBLE scrollbar instead of a
             silent clip — D85's 12px bind at viewport 1280 under Georgia is
             observable today only because of it. Reverting it does not fix an
             overflow, it hides one.
             """
    end

    test ".pane-column keeps the pre-epic 260px basis and a 260px clamp ceiling" do
      block = block!(".pane-column")

      # The basis. At any >=1280 desktop there is no squeeze, so this is the
      # width the nav column actually measures — the number epic criterion 2
      # is about.
      assert value!(block, ".pane-column", "width") == "260px",
             """
             `.pane-column`'s flex basis moved off 260px.

             At any wide desktop there is no squeeze, flex basis wins, and this
             IS the rendered nav-column width. Moving it visibly narrows or
             widens every nav column at viewport 1280 and 1440 and changes the
             reading measure beside them — the exact regression that passed 77
             tests with 0 failures before this file existed (charter D94).
             """

      # The compressible floor. `clamp`'s CEILING must stay at the same 260px
      # as the basis, or the column silently stops being able to reach its
      # own basis under any squeeze.
      assert value!(block, ".pane-column", "min-width") == "clamp(140px, 18vw, 260px)"

      # Pre-epic this was `flex-shrink: 0`. The epic made list panes yield
      # before the content pane starves (D5); that yielding is the priority
      # squeeze and losing it re-starves the document.
      assert value!(block, ".pane-column", "flex-shrink") == "1"
    end

    test ".pane-column--collapsed stays a RIGID 44px rail" do
      block = block!(".pane-column--collapsed")

      assert value!(block, ".pane-column--collapsed", "width") == "44px"
      assert value!(block, ".pane-column--collapsed", "min-width") == "44px"
      assert value!(block, ".pane-column--collapsed", "max-width") == "44px"

      assert value!(block, ".pane-column--collapsed", "flex-shrink") == "0",
             "the back strip became compressible — it is a fixed rail by contract"
    end

    test ".editor-panel carries its 560px floor and the `content` query base" do
      block = block!(".editor-panel")

      assert value!(block, ".editor-panel", "flex") == "1"
      assert value!(block, ".editor-panel", "overflow") == "hidden"

      assert value!(block, ".editor-panel", "min-width") == "560px",
             "the content pane's own floor moved — the priority squeeze bottoms out elsewhere now"

      # These two are NEW this epic and permitted BY NAME by D94's re-authored
      # criterion 2. Permitted is not the same as unpinned: `container-name:
      # content` is the query base that every `@container content (...)` floor
      # in this sheet resolves against, so losing it disables the protected
      # measure SILENTLY instead of breaking it loudly.
      assert value!(block, ".editor-panel", "container-type") == "inline-size"

      assert value!(block, ".editor-panel", "container-name") == "content",
             """
             `.editor-panel` no longer names the `content` container.

             Every protected-measure floor in this sheet is written
             `@container content (...)`. With no container named `content` the
             query resolves against the nearest ancestor container or against
             nothing at all, and the floor stops applying — with no error, no
             red, and no visible break until someone measures. That failure
             mode is this epic's whole disease (charter D39/D40).
             """
    end
  end

  describe "the wide bucket gets those rules verbatim — no unscoped override" do
    test "the geometry census matches the stylesheet exactly" do
      actual = geometry_census()
      expected = Enum.sort(@geometry_census)

      assert actual == expected,
             """
             The set of rules declaring pane box-geometry has CHANGED.

             Missing from the stylesheet (declared here, not found):
             #{inspect(expected -- actual, pretty: true)}

             New in the stylesheet (found, not declared here):
             #{inspect(actual -- expected, pretty: true)}

             This census exists because pinning the base rules is not enough on
             its own: an `@media (min-width: 1280px) { .pane-column { width:
             180px } }` leaves every literal pin in this file green and still
             ships the regression at viewport 1280. If your new rule is
             correct, add it here AND state which bucket it applies to — a
             rule that reaches the wide desk is an epic-criterion-2 change.
             """
    end

    test "every geometry override outside the four base rules is bucket- or variant-scoped" do
      base = [".pane-layout", ".pane-column", ".pane-column--collapsed", ".editor-panel"]

      for {selector, _props} <- geometry_census(), selector not in base do
        scoped? =
          String.starts_with?(selector, ~S|html[data-width-bucket="phone"] |) or
            String.starts_with?(selector, ~S|html[data-editor-focus="beta"] |) or
            selector in [
              ".editor-panel.sheet-editor",
              ".editor-with-preview .editor-panel-main",
              ".editor-with-preview.has-onix-preview .editor-panel-main",
              ".pane-column-collapsed-label"
            ]

        assert scoped?,
               """
               UNSCOPED PANE GEOMETRY OVERRIDE: `#{selector}`

               This rule declares box geometry on the pane families and is
               neither one of the four base rules nor gated behind a bucket
               attribute the wide desk never carries. It therefore applies at
               viewport 1280 and 1440, which is epic criterion 2's own band.
               """
      end
    end
  end

  describe "negative control — the parser itself" do
    test "a zero-match selector fails LOUDLY, naming the selector" do
      assert_raise ExUnit.AssertionError, ~r/\.pane-column--no-such-rule/, fn ->
        block!(".pane-column--no-such-rule")
      end
    end

    test "a missing property fails LOUDLY rather than comparing nil" do
      block = block!(".pane-layout")

      assert_raise ExUnit.AssertionError, ~r/no longer declares `border-radius`/, fn ->
        value!(block, ".pane-layout", "border-radius")
      end
    end

    test "the census SEES a pane rule hidden in a multi-line selector list" do
      # The escape hatch this parser used to have, exercised directly rather
      # than reasoned about. Written across two lines, `.pane-column` used to
      # be dropped entirely — the rule was keyed by its last line only — so a
      # 180px regression could be smuggled past the census by adding one
      # newline and one comma. The synthetic sheet below is the smallest
      # shape that reproduces it.
      sheet = """
      @media (min-width: 1280px) {
        .pane-column,
        .some-other-thing {
          width: 180px;
        }
      }
      """

      assert geometry_census(sheet) == [{".pane-column, .some-other-thing", ["width"]}],
             """
             A geometry rule on the pane families written as a multi-line
             comma-separated selector list is invisible to the census. Every
             assertion in this file would stay green while a `width` override
             reached the wide desk.
             """
    end

    test "an at-rule header above a rule is NOT swallowed into its selector" do
      # The other half of the walk: it must stop at a line that is not a
      # continuation. If it did not, the census key for every rule nested in
      # a media/container query would carry the query header and match none
      # of the declared entries.
      sheet = """
      @container content (max-width: 860px) {
        .editor-panel {
          min-width: 560px;
        }
      }
      """

      assert geometry_census(sheet) == [{".editor-panel", ["min-width"]}]
    end
  end

  # --- parsing ---------------------------------------------------------

  defp css, do: File.read!(@root)

  # Comments are stripped first: the design prose in this sheet quotes nearly
  # every selector and value below, and a pin that can be satisfied by a
  # comment is not a pin.
  defp decommented(src), do: Regex.replace(~r|/\*.*?\*/|s, src, "")

  # The single declaration block whose selector STARTS A LINE with exactly
  # `selector`. Line-anchored on purpose — it is what keeps `.pane-column`
  # from also matching `html[data-width-bucket="phone"] … .pane-column`, and
  # what keeps a base pin from silently reading a phone override's values.
  #
  # Zero matches raises HERE, naming the selector, rather than returning an
  # empty block that every assertion below would pass against vacuously.
  defp block!(selector) do
    esc = Regex.escape(selector)

    found =
      ~r/^[ \t]*#{esc}[ \t]*\{([^{}]*)\}/m
      |> Regex.scan(decommented(css()), capture: :all_but_first)
      |> List.flatten()

    case found do
      [one] ->
        one

      [] ->
        flunk("""
        SELECTOR MATCHED ZERO RULES: `#{selector}`

        root.html.heex declares no rule whose selector line is exactly that.
        Nothing below this point can be trusted — comparisons against an empty
        block pass vacuously, which is precisely how this epic declared a
        measure criterion met twice on floors that had never once applied
        (charter D39/D40). Either the rule was renamed (repoint this constant
        and say so) or it was deleted, in which case the geometry it carried
        is GONE and that is the bug.
        """)

      many ->
        flunk(
          "`#{selector}` now has #{length(many)} base rules — the winner is " <>
            "source-order dependent; collapse it to one"
        )
    end
  end

  defp value!(block, selector, prop) do
    found =
      ~r/(?:^|;)\s*#{Regex.escape(prop)}\s*:\s*([^;}]+)/
      |> Regex.scan(block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&normalise/1)

    case found do
      [one] ->
        one

      [] ->
        flunk("`#{selector}` no longer declares `#{prop}` — the geometry it carried is gone")

      many ->
        flunk(
          "`#{selector}` declares `#{prop}` #{length(many)} times " <>
            "(#{Enum.join(many, " | ")}) — the winner is source-order dependent"
        )
    end
  end

  # Whitespace inside a value is not semantic (`clamp(140px,18vw,260px)` and
  # `clamp(140px, 18vw, 260px)` are the same declaration), so it is normalised
  # to exactly one space before comparison. Nothing else is normalised — units
  # and function shapes are compared verbatim.
  defp normalise(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s*,\s*/, ", ")
    |> String.replace(~r/\s+/, " ")
  end

  # Every {selector, sorted geometry props} pair in the sheet touching the
  # pane families, at ANY nesting depth — a rule inside `@media` or
  # `@container` is read exactly like a top-level one, which is the point.
  defp geometry_census, do: geometry_census(css())

  defp geometry_census(source) do
    decommented(source)
    |> then(&Regex.scan(~r/([^{}]*)\{([^{}]*)\}/s, &1, capture: :all_but_first))
    |> Enum.map(fn [selector_chunk, body] -> {last_line(selector_chunk), body} end)
    |> Enum.filter(fn {selector, _body} -> pane_family?(selector) end)
    |> Enum.map(fn {selector, body} -> {selector, declared_geometry_props(body)} end)
    |> Enum.reject(fn {_selector, props} -> props == [] end)
    |> Enum.sort()
  end

  # A selector chunk runs from the previous closing brace to this rule's
  # opening brace, so the selector ENDS on the chunk's last non-empty line.
  # It does not necessarily START there: a comma-separated selector list is
  # routinely written one selector per line, and this sheet already contains
  # such rules (the inspector's title/body pair, for one).
  #
  # Taking only the last line would key such a rule by its FINAL selector
  # alone and drop the others — so a rule reading
  #
  #     .pane-column,
  #     .something-else { width: 180px }
  #
  # would be censused as `.something-else` and its effect on `.pane-column`
  # would never be declared. That is a silent hole in a lock whose entire
  # value is having none, so the walk goes BACKWARD from the rule's own line
  # and keeps taking while the line above ends in a comma — which is exactly
  # what continuation means — and stops at anything else: an at-rule header,
  # or plain whitespace. Rules written on one line are unaffected.
  defp last_line(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> selector_lines()
    |> Enum.join(" ")
    |> String.replace(~r/\s+/, " ")
  end

  defp selector_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.reduce_while([], fn line, acc ->
      cond do
        acc == [] -> {:cont, [line]}
        String.ends_with?(line, ",") -> {:cont, [line | acc]}
        true -> {:halt, acc}
      end
    end)
  end

  defp pane_family?(selector) do
    String.contains?(selector, "pane-layout") or
      String.contains?(selector, "pane-column") or
      String.contains?(selector, "editor-panel")
  end

  defp declared_geometry_props(body) do
    body
    |> String.split(";")
    |> Enum.flat_map(fn decl ->
      case String.split(decl, ":", parts: 2) do
        [prop, _value] -> [String.trim(prop)]
        _ -> []
      end
    end)
    |> Enum.filter(&(&1 in @geometry_props))
    |> Enum.uniq()
    |> Enum.sort()
  end
end

defmodule BarkparkWeb.Studio.MeasureParityTest do
  @moduledoc """
  studio-space-priority-desk spd-s7 — the measure-parity pin.

  ## Why this file exists: the guard, not the number

  This epic's headline number ("the document never drops below ~55ch") was
  declared MET twice on measurements that matched nothing — a floor written as
  `.editor-panel .editor-body { min-inline-size: 48ch }` that lost the cascade
  in every real configuration (charter D40), and a `min(100%, 55ch)` that
  silently no-ops. Both read green. Neither existed.

  So the load-bearing part of this file is `blocks!/2`: **every** selector it
  reads is asserted to match at least one rule BEFORE any value is compared,
  and the failure message names the selector that vanished. A vacuous green is
  the failure mode being defended against, and
  `"a zero-match selector fails LOUDLY, naming the selector"` is a permanent
  negative control proving the guard still bites.

  ## The two floors are DIFFERENT floors (charter D39/D40)

  There is no single "editor measure". There are two, on two selectors, with
  two different values and two different gates:

    * **paper** — `.editor-panel .bp-paper-surface`,
      `calc(55ch + 2 * var(--paper-gutter))`, gated behind
      `@container content (min-width: 720px)`. The addend is not decoration:
      `box-sizing: border-box` is global and the surface pads both sides with
      `--paper-gutter`, so a bare `55ch` would floor the BORDER box and
      deliver 55ch − two gutters of text. The container gate is equally
      load-bearing — the floor computes to ~631–688px depending on the serif,
      above `.editor-panel`'s own 560px floor, so an UNGATED raise would
      materialise a horizontal scrollbar at every narrow width.

      Both the token and the gate's query base moved in spd-w5 (charter
      D103/D113/D114) and NEITHER moved a pixel — the token because the gate
      is inert wherever the narrow gutters apply, the query base because it
      only ever mis-measured. `content` now names the reading column's own
      box rather than `.editor-panel`, which is that column PLUS the docked
      300px inspector. WHICH box each `@container` at-rule queries is pinned
      by `wide_geometry_lock_test.exs`, not here.
    * **classic** — `.editor-body.editor-panel-main:not(.bp-paper-body)`,
      a flat `48ch`, no container gate (a ~420px chrome-font measure, safely
      under the 560px panel floor).

  A test written against bare `.editor-body` averages those two and proves
  nothing about either, so this file never uses it — and asserts the averaged
  selector has not come back.

  ## What "parity" means here

  The Studio edit surface and the PUBLIC reader share one `.bp-paper-surface`
  rule: `max-width: 660px; padding: 56px var(--paper-gutter)` → a **580px
  content column** at the base 40px gutter. The Studio-only floor must add
  back exactly the reader's own horizontal padding, or the protected measure
  quietly under-delivers against the column it is supposed to match.

  The column was 720/640 until pe-w1-reader-editorial-typography. That width was
  sized for 16px prose, which is what the reader actually rendered — the 18px in
  `type.reading.body` had no consumer on that surface. Once the surface really
  reads its own token, 640px runs ~75 characters per line; 580px runs 68,
  measured on the rig's 5-paper panel at 1440 (86.7 → 68.1 CPL). The GUTTER did
  not move, so every relation this file pins — two gutters given back, the
  padding consuming the token, each breakpoint redeclaring it — is unchanged.
  What moved is one literal, and it moved on BOTH surfaces together.

  Since spd-w5 both sides read ONE token, the relation is no longer
  something a plain comparison can catch — `2 * gutter` versus `2 * gutter` is true
  whatever the gutter is. What replaced that tautology is the pair of pins the
  token cannot make true by itself:

    * the **multiplier** — the floor gives back exactly TWO gutters, because a
      box has two sides;
    * the **consumption** — the surface's padding really does read the token,
      so the floor is not compensating for a number nothing renders;

  plus a **breakpoint-desync guard**: the padding is viewport-`@media`'d while
  the floor is `@container`-gated, two different axes, so every breakpoint
  that restyles the surface must BOTH redeclare the token AND consume it.
  Charter D103 measured that drift's cost at zero pixels today; the guard is
  what keeps that true rather than lucky.

  ## Blast radius (folds spd-b8)

  `display_state/4` reasons over `data-role`, so every `.editor-panel` root
  must carry the stamp or it drops out of the negotiation invisibly. There are
  SIX roots and all six are stamped — media-explorer included (the survey's
  doubt was refuted). `editor_panel_containment_test.exs` pins their
  IDENTITIES for the containment audit; this file pins the STAMP, and both
  pin the count, from opposite directions.

  ## Why the checks are TEXT-based

  ExUnit has no layout engine — it cannot observe a computed measure. It can
  only observe the source facts that produce one. The live-browser counterpart
  is spd-s9's measured matrix on guerrilla; this file is what keeps that
  measurement from rotting between waves.

  This slice READ `root.html.heex` and did not edit it through round 1. That
  fence LIFTED for spd-w5 (charter D77's ruling, carried by D113): the floor's
  addend and the surface's padding cannot be unified from one side, so the
  brief granted this file explicit edit rights alongside the sheet. It is
  still file-disjoint from every other test that reads the sheet.
  """
  use ExUnit.Case, async: true

  @moduletag :studio_measure_parity

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @lib Path.expand("../../../lib/barkpark_web", __DIR__)

  # The paper floor's gate. Named once, used by every paper-path assertion.
  @paper_gate "content (min-width: 720px)"
  @paper_floor_selector ".editor-panel .bp-paper-surface"
  @classic_floor_selector ".editor-panel .editor-body.editor-panel-main:not(.bp-paper-body)"
  @reader_selector ".bp-paper-surface"
  @phone "html[data-width-bucket=\"phone\"]"

  # THE PUBLIC READER'S OWN SHELL. `@reader_selector` above is a misnomer this
  # file inherited: it names the `.bp-paper-surface` rule in root.html.heex —
  # the STUDIO's copy of the shared surface. The page a reader actually loads is
  # `<main class="bp-paper-shell bp-paper-surface bp-paper-article">` rendered by
  # bulldocs_live.ex, and its column geometry is set by the `.bp-paper-article`
  # rules in bulldocs.html.heex, which nothing in this file used to read.
  #
  # That blind spot had a price. The two shells stepped their gutters on
  # DIFFERENT ladders — 40/24/16 at 767/479 in the Studio, 40 -> 24 at 720 here
  # with a later `padding-inline: 20px` overriding the 24 below 720 — so at a
  # 390px viewport the Studio pane held a 358px column and the reader held 350.
  # Same type scale, same 660px clamp, lines wrapping at different words in View
  # than in Edit. Nothing was red, because nothing was looking.
  @bulldocs Path.expand("../../../lib/barkpark_web/layouts/bulldocs.html.heex", __DIR__)
  @reader_shell_selector ".bp-paper-shell.bp-paper-article"

  # The PUBLIC reader's shell (bulldocs.html.heex) — the rule that paints the
  # page under `.bp-paper-article`. It lives inside the GENERATED marker region
  # (design/emit.mjs bulldocsBlock), so a change to it is made in the emitter and
  # lands here through `node design/emit.mjs --write`.
  @reader_ground_selector "body:has(.bp-paper-article)"
  # The ONE page-ground token. `--paper-bg-deep` is the FILL tone (pre, inline
  # code, .bp-stat, .bp-card, figure); a shell that paints it as the page makes
  # every fill vanish (delta-L 0, measured 2026-09-02 on the live reader).
  @page_ground "var(--paper-bg)"

  # The SIX `.editor-panel` roots, by the file that renders them. Counts, not
  # anchors — identities are pinned by editor_panel_containment_test.exs; what
  # this file cares about is that each rendered root carries `data-role`.
  @expected_root_count 6

  defp css, do: File.read!(@root)

  # Strip CSS comments so the long design prose in this sheet (which quotes
  # nearly every selector below) can never be mistaken for a live rule.
  defp decommented(src), do: Regex.replace(~r|/\*.*?\*/|s, src, "")

  # Every declaration block whose selector STARTS A LINE with exactly
  # `selector`. Line-anchored on purpose: it is what keeps
  # `.editor-panel .bp-paper-surface` from also matching the phone
  # neutraliser `html[…] .editor-panel .bp-paper-surface`.
  #
  # THIS IS THE GUARD. A selector that matches zero rules raises here, naming
  # itself, instead of returning [] and letting an Enum.all?/2 pass vacuously.
  defp blocks!(src, selector) do
    esc = Regex.escape(selector)

    found =
      ~r/^[ \t]*#{esc}[ \t]*\{([^{}]*)\}/m
      |> Regex.scan(decommented(src), capture: :all_but_first)
      |> List.flatten()

    assert found != [],
           """
           SELECTOR MATCHED ZERO RULES: `#{selector}`

           root.html.heex declares no rule whose selector line is exactly that.
           Nothing below this point can be trusted — a comparison against an
           empty match set passes vacuously, which is precisely how this epic's
           measure criterion was declared met twice on floors that had never
           once applied (charter D39/D40).

           Either the rule was renamed (repoint this constant and say so) or it
           was deleted (the protected measure is GONE — that is the bug).
           """

    found
  end

  # Values of `prop` across the given declaration blocks, in source order.
  defp values(blocks, prop) do
    blocks
    |> Enum.flat_map(fn block ->
      ~r/(?:^|;)\s*#{Regex.escape(prop)}\s*:\s*([^;}]+)/
      |> Regex.scan(block, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp value!(blocks, prop, selector) do
    case values(blocks, prop) do
      [one] ->
        one

      [] ->
        flunk("`#{selector}` no longer declares `#{prop}` — the floor it carried is gone")

      many ->
        flunk(
          "`#{selector}` declares `#{prop}` #{length(many)} times (#{Enum.join(many, " | ")}) — " <>
            "the winner is now source-order dependent; collapse it to one"
        )
    end
  end

  # The base `--paper-gutter`, read off the surface rule itself rather than
  # restated here — the whole point of the token is that this number lives in
  # exactly one place.
  defp base_gutter! do
    value =
      css()
      |> blocks!(@reader_selector)
      |> value!("--paper-gutter", @reader_selector)

    case Regex.run(~r/^(\d+)px$/, value) do
      [_, px] ->
        String.to_integer(px)

      nil ->
        flunk(
          "`#{@reader_selector}` declares `--paper-gutter: #{value}`, which is not a px length"
        )
    end
  end

  # Every `@media (<header>) { … .bp-paper-surface { <body> } … }` block that
  # restyles the reader surface, as {header, that rule's body}. Written against
  # the sheet's one-rule-per-media-line shape, which is what the breakpoints
  # actually use.
  defp nested_surface_blocks do
    ~r/@media\s*\(([^)]*)\)\s*\{\s*#{Regex.escape(@reader_selector)}\s*\{([^{}]*)\}/
    |> Regex.scan(decommented(css()), capture: :all_but_first)
    |> Enum.map(fn [header, body] -> {String.trim(header), body} end)
  end

  # ── The gutter LADDER, derived from a sheet rather than restated here ──────
  #
  # A ladder is the base gutter plus every `@media (max-width: N)` step that
  # redeclares it, as `[{:base, 40}, {767, 24}, {479, 16}]`. Both shells are read
  # with the SAME function, and the parity test compares the two results — so the
  # numbers live in the sheets and this file only asserts they agree. Restating
  # "40/24/16 at 767/479" here would make the test pass a sheet that matches the
  # restatement while the OTHER sheet drifted; comparing two derivations cannot.
  defp gutter_ladder!(src, selector, file) do
    # The base rule is the TOP-LEVEL block that declares the token. A surface can
    # own several top-level blocks (root.html.heex splits its paper surface across
    # more than one); picking by position would read whichever came first, so the
    # block is picked by the thing being read, and both "none" and "more than one"
    # are loud — the second is how a source-order-dependent winner gets in.
    base =
      case top_level_blocks(src, selector) do
        [] ->
          flunk(
            "`#{selector}` matches no TOP-LEVEL rule in #{file} — its column geometry is GONE"
          )

        blocks ->
          case Enum.filter(blocks, &(&1 =~ ~r/--paper-gutter\s*:/)) do
            [one] ->
              gutter_px!(one, selector, file)

            [] ->
              flunk(
                "no top-level `#{selector}` rule in #{file} declares `--paper-gutter` " <>
                  "(#{length(blocks)} candidate blocks) — the gutter is a literal again " <>
                  "and the two shells can drift silently"
              )

            many ->
              flunk(
                "#{length(many)} top-level `#{selector}` rules in #{file} declare " <>
                  "`--paper-gutter`; the base gutter is now source-order dependent"
              )
          end
      end

    steps =
      ~r/@media\s*\(\s*max-width:\s*(\d+)px\s*\)\s*\{\s*#{Regex.escape(selector)}\s*\{([^{}]*)\}/
      |> Regex.scan(decommented(src), capture: :all_but_first)
      |> Enum.filter(fn [_bp, body] -> body =~ ~r/--paper-gutter\s*:/ end)
      |> Enum.map(fn [bp, body] ->
        {String.to_integer(bp), gutter_px!(body, selector, file)}
      end)
      |> Enum.sort_by(fn {bp, _} -> -bp end)

    [{:base, base} | steps]
  end

  # Declaration blocks for `selector` at brace depth ZERO — i.e. NOT inside an
  # `@media`/`@container` at-rule.
  #
  # Depth, not a line anchor. `^[ \t]*<selector>[ \t]*\{` reads as "top level"
  # and is not: inside a MULTI-LINE `@media { … }` the nested copy also starts
  # its own line, so on bulldocs.html.heex (whose media blocks are written out
  # over several lines, unlike root.html.heex's one-liners) the line-anchored
  # form returned the base rule AND both ladder steps, and the base gutter
  # became "whichever of the three came first". Counting braces cannot be fooled
  # by how a sheet is formatted.
  defp top_level_blocks(src, selector) do
    src = decommented(src)
    esc = Regex.escape(selector)

    ~r/(?<![-\w.])#{esc}[ \t]*\{([^{}]*)\}/
    |> Regex.scan(src, return: :index)
    |> Enum.filter(fn [{start, _} | _] -> depth_at(src, start) == 0 end)
    |> Enum.map(fn [_whole, {bstart, blen}] -> binary_part(src, bstart, blen) end)
  end

  defp depth_at(src, offset) do
    prefix = binary_part(src, 0, offset)
    length(:binary.matches(prefix, "{")) - length(:binary.matches(prefix, "}"))
  end

  defp gutter_px!(body, selector, file) do
    case Regex.run(~r/--paper-gutter\s*:\s*(\d+)px/, body) do
      [_, px] ->
        String.to_integer(px)

      nil ->
        flunk(
          "`#{selector}` in #{file} declares no `--paper-gutter: <n>px` — the " <>
            "gutter is a literal again and the two shells can drift silently"
        )
    end
  end

  # Every `@media (…) { <selector> { … } }` body for a selector in a sheet.
  defp media_bodies(src, selector) do
    ~r/@media\s*\(([^)]*)\)\s*\{\s*#{Regex.escape(selector)}\s*\{([^{}]*)\}/
    |> Regex.scan(decommented(src), capture: :all_but_first)
    |> Enum.map(fn [header, body] -> {String.trim(header), body} end)
  end

  # The body of an `@container <header> { … }` at-rule, brace-matched.
  defp at_rule_body!(src, header) do
    src = decommented(src)

    case :binary.match(src, "@container " <> header) do
      :nomatch ->
        flunk("""
        THE PAPER FLOOR'S GATE IS GONE: no `@container #{header}` in root.html.heex.

        That gate is not tidiness. The floor computes to ~631px (Iowan) / ~688px
        (Georgia), both ABOVE `.editor-panel`'s 560px floor, so an ungated floor
        newly materialises a horizontal scrollbar at every narrow width (D39).
        """)

      {start, _} ->
        balanced_body(src, start)
    end
  end

  defp balanced_body(src, from) do
    rest = binary_part(src, from, byte_size(src) - from)
    [_head, body_and_tail] = String.split(rest, "{", parts: 2)

    body_and_tail
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn
      "}", {0, acc} -> {:halt, {0, acc}}
      "}", {depth, acc} -> {:cont, {depth - 1, ["}" | acc]}}
      "{", {depth, acc} -> {:cont, {depth + 1, ["{" | acc]}}
      ch, {depth, acc} -> {:cont, {depth, [ch | acc]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  # Every rendered `.editor-panel` root, as {relative_path, line, tag_source}.
  # The tag is reassembled from its opening `<div` through its closing `>` so a
  # multi-line tag (sheet_grid, media explorer) is read whole — `data-role` sits
  # on a different line than `class` in both.
  defp panel_roots do
    for path <- studio_sources(),
        lines = String.split(File.read!(path), "\n"),
        {line, idx} <- Enum.with_index(lines, 1),
        Regex.match?(~r/class=(\{|")[^\n]*\beditor-panel\b(?!-)/, line),
        do: {Path.relative_to(path, @lib), idx, whole_tag(lines, idx)}
  end

  defp whole_tag(lines, idx) do
    open =
      idx..max(idx - 10, 1)//-1
      |> Enum.find(idx, &String.contains?(Enum.at(lines, &1 - 1), "<div"))

    open..min(open + 15, length(lines))
    |> Enum.reduce_while([], fn i, acc ->
      line = Enum.at(lines, i - 1)
      acc = [line | acc]

      if String.ends_with?(String.trim(line), ">"),
        do: {:halt, acc},
        else: {:cont, acc}
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp studio_sources do
    for dir <- ~w(live/studio components), ext <- ~w(ex heex), reduce: [] do
      acc -> acc ++ Path.wildcard(@lib <> "/" <> dir <> "/**/*." <> ext)
    end
  end

  describe "the guard itself" do
    test "a zero-match selector fails LOUDLY, naming the selector" do
      err =
        assert_raise ExUnit.AssertionError, fn ->
          blocks!(css(), ".editor-panel .bp-paper-surfaec")
        end

      message = ExUnit.AssertionError.message(err)

      assert message =~ "SELECTOR MATCHED ZERO RULES",
             "the zero-match guard no longer announces itself"

      assert message =~ ".editor-panel .bp-paper-surfaec",
             "the zero-match failure does not name the selector that vanished — " <>
               "a nameless failure sends the next reader hunting the whole sheet"
    end

    test "the guard does NOT fire on a selector that really is there" do
      assert blocks!(css(), @paper_floor_selector) != []
    end
  end

  describe "the paper floor (D39) — .editor-panel .bp-paper-surface" do
    test "is calc(55ch + 2 * var(--paper-gutter)) and lives INSIDE the 720px gate" do
      gate_body = at_rule_body!(css(), @paper_gate)

      assert gate_body =~ @paper_floor_selector,
             """
             The paper floor escaped its `@container #{@paper_gate}` gate.

             Ungated it applies at panel widths that cannot honour it, and the
             overflow lands on `.editor-body` (which declares only overflow-y,
             so the spec promotes overflow-x to auto and IT becomes the
             scroller — `.editor-panel`'s overflow:hidden is never reached).
             """

      floor =
        value!(
          blocks!(gate_body, @paper_floor_selector),
          "min-inline-size",
          @paper_floor_selector
        )

      assert floor == "calc(55ch + 2 * var(--paper-gutter))",
             """
             The protected paper measure changed: `#{floor}`.

             A bare `55ch` floors the BORDER box (box-sizing: border-box is
             global) and delivers 55ch − 2 gutters of text; `min(100%, 55ch)`
             silently no-ops. Both have shipped here before and both read as
             "criterion met" while the document sat at ~48ch.

             The addend is `2 * var(--paper-gutter)` and not a literal since
             spd-w5: the token is declared and redeclared on `.bp-paper-surface`
             itself, so the floor and the padding it compensates for can no
             longer drift (charter D103). That change closes ZERO pixels at
             ZERO widths — it is coherence, not a measure fix.
             """
    end

    test "the floor adds back exactly TWO of the reader's own gutters" do
      floor =
        css()
        |> at_rule_body!(@paper_gate)
        |> blocks!(@paper_floor_selector)
        |> value!("min-inline-size", @paper_floor_selector)

      # THE MULTIPLIER PIN. The old assertion here compared the floor's literal
      # px addend against the reader's literal side padding. Once both sides
      # read ONE token that comparison goes tautological — `2 * gutter` versus
      # `2 * gutter` is true whatever the gutter is — so what is pinned instead
      # is the only number the token cannot carry: how MANY gutters the border
      # box has to give back. It is two, because a box has two sides.
      [_, ch, multiplier, token] =
        Regex.run(~r/calc\(\s*(\d+)ch\s*\+\s*(\d+)\s*\*\s*var\(\s*(--[\w-]+)\s*\)\s*\)/, floor) ||
          flunk("""
          The paper floor is no longer `calc(<n>ch + <k> * var(--token))`: `#{floor}`.

          spd-w5 made the floor consume the same gutter token the surface pads
          with, so the two cannot drift. A floor that restates a literal px
          addend is the drift this shape exists to prevent (charter D103).
          """)

      assert String.to_integer(multiplier) == 2,
             """
             MEASURE PARITY BROKEN: the floor adds back #{multiplier} gutter(s), not 2.

             `box-sizing: border-box` is global and the surface pads BOTH sides,
             so the floor must give back two gutters or the protected CONTENT
             measure silently under-delivers by the difference.
             """

      assert token == "--paper-gutter",
             "the floor consumes `#{token}`, which is not the token the surface pads with"

      assert String.to_integer(ch) == 55,
             "the epic's protected measure is 55ch; the sheet now says #{ch}ch"
    end

    test "the reader's padding CONSUMES the same token the floor does" do
      # THE CONSUMPTION PIN, the other half of the multiplier. A token that is
      # declared but not consumed leaves the padding stale while the floor
      # tracks a number nothing renders — which reads exactly like parity and
      # is not.
      reader = blocks!(css(), @reader_selector)
      padding = value!(reader, "padding", @reader_selector)

      assert padding =~ ~r/^\d+px\s+var\(\s*--paper-gutter\s*\)$/,
             """
             The public reader column pads `#{padding}`.

             It must read its side padding from `var(--paper-gutter)` — the same
             token the Studio floor adds back. Both surfaces render this one
             rule; the moment the padding restates a literal, the floor is
             compensating for a number the surface no longer uses and the Studio
             wraps a line at a different word than the reader (charter D103).
             """
    end

    test "the reader column the floor is measured against is still 660px wide" do
      reader = blocks!(css(), @reader_selector)
      max_width = value!(reader, "max-width", @reader_selector)
      side = base_gutter!()

      assert max_width == "660px",
             "the public reader column moved to #{max_width}; re-derive the parity story"

      content = 660 - 2 * side

      assert content == 580,
             "the reader's content column is now #{content}px, not the 580px the " <>
               "Studio floor was sized against"
    end

    test "every breakpoint that restyles the surface redeclares AND consumes the gutter" do
      # THE BREAKPOINT-DESYNC GUARD — new with the token, and the reason the
      # token is safe. The surface's padding is viewport-`@media`'d (40 → 24 →
      # 16px) while the floor is `@container`-gated, so the two are keyed off
      # DIFFERENT axes. That is survivable only while every breakpoint keeps
      # both halves in step:
      #
      #   * redeclare but not consume → the padding is stale at that width
      #   * consume but not redeclare → the floor gives back the WIDEST gutter
      #     at a width that no longer has one, over-reserving silently
      #
      # Charter D103 measured the drift's cost at ZERO pixels today (the gate
      # is inert wherever the narrow gutters apply). This guard is what keeps
      # that true rather than lucky.
      nested = nested_surface_blocks()

      assert nested != [],
             "no `@media` block restyles `#{@reader_selector}` any more — if the " <>
               "breakpoints were deleted, the reader's responsive padding is GONE"

      for {header, body} <- nested do
        assert body =~ ~r/--paper-gutter\s*:/,
               """
               `@media #{header}` restyles `#{@reader_selector}` without redeclaring
               `--paper-gutter`.

               Its padding therefore changes while the Studio floor keeps giving
               back the base 40px gutter — over-reserving at exactly the widths
               where the column is tightest.
               """

        assert body =~ ~r/padding\s*:[^;}]*var\(\s*--paper-gutter\s*\)/,
               """
               `@media #{header}` redeclares `--paper-gutter` but pads with a
               literal, so the token it sets is dead and the padding it renders
               is unpinned. Redeclare and consume, or do neither.
               """
      end
    end

    test "relaxes to 0 at phone so the lone surface can never exceed the viewport" do
      relaxed =
        css()
        |> blocks!("#{@phone} #{@paper_floor_selector}")
        |> value!("min-inline-size", "#{@phone} #{@paper_floor_selector}")

      assert relaxed == "0",
             "the paper floor is #{relaxed} at phone — .pane-layout clips with " <>
               "overflow:hidden, so anything above 0 makes content unreachable"
    end
  end

  describe "the classic floor (D40) — .editor-body.editor-panel-main:not(.bp-paper-body)" do
    test "is 48ch on the three-class selector that outranks the flex reset" do
      floor =
        css()
        |> blocks!(@classic_floor_selector)
        |> value!("min-inline-size", @classic_floor_selector)

      assert floor == "48ch",
             "the classic editor measure changed: #{floor}"
    end

    test "the averaged bare `.editor-panel .editor-body` floor has NOT come back" do
      averaged =
        ~r/^[ \t]*\.editor-panel \.editor-body[ \t]*\{([^{}]*)\}/m
        |> Regex.scan(decommented(css()), capture: :all_but_first)
        |> List.flatten()

      assert averaged == [],
             """
             `.editor-panel .editor-body { … }` is back at top level.

             That selector covers BOTH the paper body and the classic body, so a
             floor on it averages two different measures — and at specificity
             (0,2,0) it loses outright to `.editor-with-preview .editor-panel-main
             { min-width: 0 }` further down the sheet, which is why it never once
             applied. Split it: paper floors on `.bp-paper-surface`, classic on
             `#{@classic_floor_selector}`.

             Found: #{inspect(averaged)}
             """
    end

    test "relaxes to 0 at phone at MATCHING specificity" do
      selector = "#{@phone} #{@classic_floor_selector}"

      relaxed =
        css()
        |> blocks!(selector)
        |> value!("min-inline-size", selector)

      assert relaxed == "0",
             """
             The phone neutraliser for the classic floor is `#{relaxed}`.

             It must exist at the classic floor's own specificity (0,4,0): the
             plainer `#{@phone} .editor-panel .editor-body` line is (0,3,0) and
             LOSES, which would keep a 48ch floor alive on a 375px viewport.
             """
    end

    test "the two floors are genuinely different rules with different values" do
      paper =
        css()
        |> at_rule_body!(@paper_gate)
        |> blocks!(@paper_floor_selector)
        |> value!("min-inline-size", @paper_floor_selector)

      classic =
        css()
        |> blocks!(@classic_floor_selector)
        |> value!("min-inline-size", @classic_floor_selector)

      refute paper == classic,
             "both floors now read #{paper} — one selector is being read twice and " <>
               "one of the two measures is unpinned"
    end
  end

  describe "the .editor-panel blast radius (folds spd-b8)" do
    test "every rendered .editor-panel root carries data-role=\"content\"" do
      roots = panel_roots()

      unstamped =
        Enum.reject(roots, fn {_file, _line, tag} -> tag =~ ~s(data-role="content") end)

      assert unstamped == [],
             """
             An `.editor-panel` root renders WITHOUT `data-role="content"`:

               #{Enum.map_join(unstamped, "\n  ", fn {f, l, _} -> "#{f}:#{l}" end)}

             `PaneBuilder.display_state/4` reasons over `data-role` to decide
             :full / :strip / :hidden. An unstamped root is not "unstyled" — it
             drops out of the space negotiation entirely and silently, which is
             the whole failure class this epic exists to end.
             """
    end

    test "there are exactly six roots — a seventh must be stamped before it lands" do
      roots = panel_roots()

      assert length(roots) == @expected_root_count,
             """
             The `.editor-panel` root census moved: #{length(roots)} found,
             #{@expected_root_count} pinned.

               #{Enum.map_join(Enum.sort(roots), "\n  ", fn {f, l, _} -> "#{f}:#{l}" end)}

             A new root needs `data-role` (this file), a containment audit
             (editor_panel_containment_test.exs) and the count bumped in both.
             """
    end

    test "the media explorer is one of the six and IS stamped (the survey's doubt, refuted)" do
      media =
        Enum.filter(panel_roots(), fn {_f, _l, tag} -> tag =~ "media-explorer-panel" end)

      assert length(media) == 1,
             "the media-explorer `.editor-panel` root is no longer identifiable"

      [{_file, _line, tag}] = media

      assert tag =~ ~s(data-role="content"),
             "the media explorer lost its data-role stamp — it is a full panel " <>
               "root, not a chromeless surface, and it negotiates space like the rest"
    end
  end

  describe "BOTH shells step their gutters on ONE ladder (task-414967096bbe011b)" do
    # The criterion this block exists for: "Editor and reader gutters step
    # identically (40/24/16 at 767/479) and measure_parity_test.exs asserts both
    # shells, red when one drifts." Everything below is derived from the two
    # sheets, so the drift of EITHER one reds it.

    test "the reader shell and the Studio surface declare the SAME ladder" do
      studio = gutter_ladder!(css(), @reader_selector, "root.html.heex")
      reader = gutter_ladder!(File.read!(@bulldocs), @reader_shell_selector, "bulldocs.html.heex")

      assert studio == reader,
             """
             THE TWO SHELLS STEP DIFFERENTLY.

               Studio  `#{@reader_selector}` (root.html.heex)       #{inspect(studio)}
               reader  `#{@reader_shell_selector}` (bulldocs.html.heex)  #{inspect(reader)}

             Both surfaces resolve the SAME `.bp-paper-surface` type scale against
             the same 660px clamp, so the only thing that can make a line wrap at a
             different word in View than in Edit is the side padding. A ladder that
             agrees on the values but not the breakpoints is just as broken as one
             that disagrees on the values: between the two breakpoints the surfaces
             hold different columns.

             Move BOTH sheets, or neither.
             """
    end

    test "the ladder is the one the narrow measure was sized against" do
      # Not a restatement of the sheets — a pin on the two numbers the reflow
      # measurement was taken at, so a future edit that keeps the shells in step
      # while walking the ladder somewhere else still has to come back here and
      # say so. 390 - 2*16 = 358px of column = 41.8 characters per line, measured
      # by Range rects on /papers/heggemsnes-act (35.4 at the old 20px gutter).
      ladder = gutter_ladder!(File.read!(@bulldocs), @reader_shell_selector, "bulldocs.html.heex")

      assert {:base, 40} == hd(ladder),
             "the base gutter moved to #{inspect(hd(ladder))}; the 580px reading " <>
               "column every parity number in this file rests on moved with it"

      assert {479, 16} in ladder,
             """
             the 16px phone step is gone (ladder: #{inspect(ladder)}).

             It is what puts the narrow column at 358px and the prose measure at
             41.8 CPL, inside the 40-46 editorial band. At the 20px this reader
             used to render, the column was 350px and the measure 35.4.
             """
    end

    test "no reader breakpoint pads the shell with a gutter LITERAL" do
      # THE ACTUAL BUG, as a permanent tripwire. `padding-inline: 20px` sat in a
      # LATER `@media (max-width: 720px)` block than the ladder, so it won on
      # source order and the reader rendered a gutter that appeared in no ladder
      # at all — while the evidence-band literals two lines above it (`calc(100vw
      # - 32px)`, i.e. 2 x 16) were written for a DIFFERENT gutter again. Three
      # numbers, one edge. A literal here is how that comes back.
      bodies = media_bodies(File.read!(@bulldocs), @reader_shell_selector)

      assert bodies != [],
             "no `@media` block restyles `#{@reader_shell_selector}` any more — " <>
               "the reader's responsive column is GONE"

      for {header, body} <- bodies,
          decl <- Regex.scan(~r/(padding(?:-inline)?)\s*:\s*([^;}]+)/, body) do
        [_, prop, value] = decl

        assert value =~ ~r/var\(\s*--paper-gutter\s*\)/,
               """
               `@media #{header}` sets `#{prop}: #{String.trim(value)}` on
               `#{@reader_shell_selector}` — a side gutter that is not the token.

               Whatever it is, it is not on the ladder the Studio steps, and being
               later in the sheet it wins. That is exactly how the reader came to
               render 20px at a width where the Studio rendered 16.
               """
      end
    end

    test "every reader breakpoint that redeclares the gutter also CONSUMES it" do
      # The mirror of the Studio-side desync guard above, on the other sheet.
      # Redeclare without consuming and the token is dead decoration; the padding
      # that renders is then whatever an earlier block left behind.
      for {header, body} <- media_bodies(File.read!(@bulldocs), @reader_shell_selector),
          body =~ ~r/--paper-gutter\s*:/ do
        assert body =~ ~r/padding\s*:[^;}]*var\(\s*--paper-gutter\s*\)/,
               """
               `@media #{header}` redeclares `--paper-gutter` on
               `#{@reader_shell_selector}` without padding with it. The token it
               sets renders nothing.
               """
      end
    end

    test "the reader's evidence band reads the gutter instead of restating it" do
      # The band's width used to be `calc(100vw - 32px)` — correct for a 16px
      # gutter, in a block whose padding rendered 20. The band edge and the prose
      # edge were 4px apart by construction, at every narrow width.
      bodies = media_bodies(File.read!(@bulldocs), @reader_shell_selector)

      widths =
        for {_h, body} <- bodies,
            [w] <-
              Regex.scan(~r/--bp-evidence-width\s*:\s*([^;}]+)/, body, capture: :all_but_first),
            do: String.trim(w)

      assert widths != [],
             "no narrow `--bp-evidence-width` on the reader shell any more — the " <>
               "band no longer collapses onto the column on a phone"

      for w <- widths do
        assert w =~ ~r/var\(\s*--paper-gutter\s*\)/,
               "the reader's narrow evidence band is `#{w}` — a literal gutter " <>
                 "allowance. It must read `var(--paper-gutter)`, or the band's edge " <>
                 "and the prose's edge drift apart the moment the ladder moves."
      end
    end
  end

  # ── the page ground — View and Edit stand on ONE token (task-ddb1e0ab09a62466) ──
  #
  # The element rules are byte-compared (view_edit_parity_test.exs), but the
  # SHELL under them is not an element rule: Studio paints `.bp-paper-surface`
  # in root.html.heex, the reader paints `body:has(.bp-paper-article)` in
  # bulldocs.html.heex, and nothing compared the two. They drifted — Studio on
  # `--paper-bg`, the reader on `--paper-bg-deep` — so Edit showed every fill
  # that View hid (pre, inline code, stat tiles, cards, figures all paint
  # `--paper-bg-deep`; on a `--paper-bg-deep` page that is delta-L 0). These
  # pins hold the two shells to one var, and that var to the page token.
  describe "the page ground — the Studio surface and the public reader stand on one token" do
    defp studio_ground!,
      do: value!(blocks!(css(), @reader_selector), "background", @reader_selector)

    defp reader_ground! do
      value!(
        blocks!(File.read!(@bulldocs), @reader_ground_selector),
        "background",
        @reader_ground_selector
      )
    end

    test "both shells paint the SAME ground var (View↔Edit ground parity)" do
      studio = studio_ground!()
      reader = reader_ground!()

      assert studio == reader,
             """
             GROUND DRIFT between the two shells:
               Studio  #{@reader_selector} { background: #{studio} }   (root.html.heex)
               Reader  #{@reader_ground_selector} { background: #{reader} }   (bulldocs.html.heex, GENERATED — edit design/emit.mjs)

             Every component fill is --paper-bg-deep. Whichever shell paints the
             page with the fill token shows NO fills — Edit and View then disagree
             on whether a code block, a stat tile or a figure has a surface at all,
             and the element byte-gate cannot see it because this is the shell.
             """
    end

    test "and that var is --paper-bg, leaving --paper-bg-deep to be a FILL" do
      assert studio_ground!() == @page_ground,
             "Studio's #{@reader_selector} ground is #{studio_ground!()}, not #{@page_ground}"

      assert reader_ground!() == @page_ground,
             "the reader's #{@reader_ground_selector} ground is #{reader_ground!()}, not #{@page_ground} " <>
               "— change design/emit.mjs (bulldocsBlock), then `node design/emit.mjs --write`"
    end

    test "the reader ground selector matches EXACTLY one rule (guard non-vacuity)" do
      # blocks!/2 already refuses zero; this pins ONE, so a second `body:has(...)`
      # rule cannot introduce a source-order-dependent winner the pins above miss.
      assert length(blocks!(File.read!(@bulldocs), @reader_ground_selector)) == 1
    end
  end
end

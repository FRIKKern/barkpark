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

    * **paper** — `.editor-panel .bp-paper-surface`, `calc(55ch + 80px)`,
      gated behind `@container content (min-width: 720px)`. The `+ 80px` is
      not decoration: `box-sizing: border-box` is global and the surface
      carries `padding: 56px 40px`, so a bare `55ch` would floor the BORDER
      box and deliver 55ch − 80px of text. The container gate is equally
      load-bearing — `calc(55ch + 80px)` is ~631–688px depending on the serif,
      above `.editor-panel`'s own 560px floor, so an UNGATED raise would
      materialise a horizontal scrollbar at every narrow width.
    * **classic** — `.editor-body.editor-panel-main:not(.bp-paper-body)`,
      a flat `48ch`, no container gate (a ~420px chrome-font measure, safely
      under the 560px panel floor).

  A test written against bare `.editor-body` averages those two and proves
  nothing about either, so this file never uses it — and asserts the averaged
  selector has not come back.

  ## What "parity" means here

  The Studio edit surface and the PUBLIC reader share one `.bp-paper-surface`
  rule: `max-width: 720px; padding: 56px 40px` → a **640px content column**.
  The Studio-only floor must therefore add back exactly the reader's own
  horizontal padding, or the protected measure quietly under-delivers against
  the column it is supposed to match. That relation — floor addend ==
  2 × reader side padding — is derived from the CSS on both sides here, never
  hardcoded twice, so changing the reader's padding reds this test instead of
  silently shrinking the Studio measure.

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

  This slice READS `root.html.heex`; it never edits it (file-disjoint from
  spd-s5, which owns the shell this round).
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

  # The body of an `@container <header> { … }` at-rule, brace-matched.
  defp at_rule_body!(src, header) do
    src = decommented(src)

    case :binary.match(src, "@container " <> header) do
      :nomatch ->
        flunk("""
        THE PAPER FLOOR'S GATE IS GONE: no `@container #{header}` in root.html.heex.

        That gate is not tidiness. calc(55ch + 80px) is ~631px (Iowan) / ~688px
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
    test "is calc(55ch + 80px) and lives INSIDE the 720px container gate" do
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

      assert floor == "calc(55ch + 80px)",
             """
             The protected paper measure changed: `#{floor}`.

             A bare `55ch` floors the BORDER box (box-sizing: border-box is
             global) and delivers 55ch − 80px of text; `min(100%, 55ch)`
             silently no-ops. Both have shipped here before and both read as
             "criterion met" while the document sat at ~48ch.
             """
    end

    test "the floor's px addend is exactly the public reader's horizontal padding" do
      floor =
        css()
        |> at_rule_body!(@paper_gate)
        |> blocks!(@paper_floor_selector)
        |> value!("min-inline-size", @paper_floor_selector)

      [_, ch, addend] = Regex.run(~r/calc\(\s*(\d+)ch\s*\+\s*(\d+)px\s*\)/, floor)
      {ch, addend} = {String.to_integer(ch), String.to_integer(addend)}

      # The PUBLIC reader column — the same rule the reader renders. This is the
      # thing the Studio measure is at parity WITH.
      reader = blocks!(css(), @reader_selector)
      padding = value!(reader, "padding", @reader_selector)
      [_, side] = Regex.run(~r/^\d+px\s+(\d+)px$/, padding)
      side = String.to_integer(side)

      assert addend == 2 * side,
             """
             MEASURE PARITY BROKEN.

             The public reader column is `#{@reader_selector} { padding: #{padding} }`
             → #{side}px of side padding, #{2 * side}px total. The Studio-only floor adds
             back #{addend}px, so the protected CONTENT measure is
             #{ch}ch − #{2 * side - addend}px, not #{ch}ch.

             Both surfaces render the same `.bp-paper-surface`; the Studio floor
             exists only to keep the panel from squeezing that column. Change the
             padding and this addend moves with it, or the Studio quietly wraps a
             line earlier than the reader does.
             """

      assert ch == 55,
             "the epic's protected measure is 55ch; the sheet now says #{ch}ch"
    end

    test "the reader column the floor is measured against is still 720px wide" do
      reader = blocks!(css(), @reader_selector)
      max_width = value!(reader, "max-width", @reader_selector)
      padding = value!(reader, "padding", @reader_selector)
      [_, side] = Regex.run(~r/^\d+px\s+(\d+)px$/, padding)

      assert max_width == "720px",
             "the public reader column moved to #{max_width}; re-derive the parity story"

      content = 720 - 2 * String.to_integer(side)

      assert content == 640,
             "the reader's content column is now #{content}px, not the 640px the " <>
               "Studio floor was sized against"
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
end

defmodule BarkparkWeb.StudioDeskFocusRingGuardTest do
  @moduledoc """
  spd-w18: the desk's three focus rings, pinned so a revert REDS.

  PR #7567 landed four affordances and guarded two of them. Deleting all
  FOUR of `.pane-add-btn:focus-visible`, `.pane-item:focus-visible`,
  `.bp-doc-row-body:focus-visible` (root.html.heex) and the "+" button's
  `aria-label` (studio_live/components.ex) left the EXACT gate #7567 itself
  cited fully green — 1747 tests, 0 failures. So any future edit to
  root.html.heex could silently delete all three desk rings and nothing
  would say so. This file is the tripwire for the three CSS rules;
  `test/barkpark_web/live/studio/studio_desk_add_button_name_test.exs`
  is the tripwire for the accessible name, because that one is only
  observable in a rendered desk.

  ## Why these rules and not the class vocabulary

  `desk_row_ladder_test.exs` asserts class names only (`class="pane-item"`,
  `class="pane-doc-title"`) and stayed GREEN through BOTH landed mutations —
  it would pass if every row were a `<p>`. A ring is a CSS rule, so only a
  test that reads the sheet can see it go missing. Every affordance #7567
  made keyboard-reachable is keyboard-*visible* solely because of one of
  these three rules: a `<button>` you can Tab to but cannot see the focus of
  is the same dead control the owner reported.

  ## Why literal matching, never a regex

  A CSS selector is a regex minefield: during verification an unescaped `.`
  made `.btn:focus-visible` read 4 hits (it matched `-btn:focus-visible`)
  and an unescaped `[...]` made `.pane-column[tabindex="-1"]:focus-visible`
  read 0 (the brackets parsed as a character class) — the OPPOSITE
  conclusion on two selectors. `grep -F` gave 0 and 2. Every check below is
  `String.contains?/2` on a literal, which is `grep -F`.

  ## Deliberately NOT asserted

  `.bp-desk-chip:focus-visible` and `.bp-doc-checkbox:focus-visible` do not
  exist — 0 occurrences on origin/main and 0 in the authenticated deployed
  page. They are `spd-w18-desk-chips-answer`'s job, and that slice must
  EXTEND `@desk_focus_rings` below rather than write its own guard.
  `.pane-column[tabindex="-1"]:focus-visible` already exists twice and is
  out of scope.

  Each assertion carries a SABOTAGE CONTROL: the same predicate is re-run
  against a copy of the sheet with that rule cut out, and must come back
  false. A check whose failure nobody has observed is not a check.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # The desk affordances #7567 made focusable, and the rule that makes that
  # focus VISIBLE. Extend this list when a slice adds a ring; never shrink it.
  @desk_focus_rings [
    {".pane-add-btn:focus-visible", ~s(the "+" / share / access pane-header buttons)},
    {".pane-item:focus-visible", "every structure + plugin-link desk row"},
    {".bp-doc-row-body:focus-visible", "every document row body"},
    # spd-bl-doc-checkbox-is-an-unfocusable-span — the bulk-select control is a
    # real <button role="checkbox"> now; its ring rides the same pinned list.
    {".bp-doc-checkbox:focus-visible", "the bulk-select checkbox on every doc row"},
    # spd-w18-desk-chips-answer — the chips are Tab-reachable anchors and now
    # show it; the ring graduated out of the absent-list below.
    {".bp-desk-chip:focus-visible", "the desk filter chips"},
    # spd-b18-btn-focus-visible-desk-wide — the SHARED button family. Not a
    # desk-only ring: `.btn` reaches ~190 call sites across the Studio, and
    # until this slice it declared only :hover and :disabled, so every one of
    # them fell back to the UA outline. Pinned here rather than in a new file
    # because this module's own docs say a later ring must EXTEND the list.
    # Literal matching is what makes this entry safe: `.btn:focus-visible {`
    # is NOT a substring of `.pane-add-btn:focus-visible {` (that one has
    # `-btn`, not `.btn`), which is exactly the miscount the moduledoc's
    # regex-minefield note describes.
    {".btn:focus-visible", "every control wearing the shared .btn base class"}
  ]

  defp sheet, do: File.read!(@root)

  # Literal (grep -F) presence of the rule's OPENING — selector immediately
  # followed by its brace. Tolerates `sel {` and `sel{`, nothing else: the
  # point is to pin a rule that exists, not to parse CSS.
  defp rule_open(css, selector) do
    Enum.find([selector <> " {", selector <> "{"], &String.contains?(css, &1))
  end

  # The declarations of that rule, up to the first `}`. nil when absent.
  defp rule_body(css, selector) do
    case rule_open(css, selector) do
      nil ->
        nil

      opening ->
        [_, rest] = String.split(css, opening, parts: 2)
        rest |> String.split("}", parts: 2) |> hd()
    end
  end

  # A minimal sheet the checks above must PASS on — the sabotage control's
  # positive arm. Synthetic on purpose: the control proves the predicates can
  # distinguish present from absent whatever the real sheet currently says, so
  # it keeps its meaning while the real assertions are the ones that red.
  defp fixture(selector),
    do: """
    .unrelated { color: red; }
    #{selector} { outline: 2px solid var(--ring); outline-offset: -2px; }
    .also-unrelated { color: blue; }
    """

  # …and the same sheet with that rule cut out: the negative arm.
  defp without_rule(css, selector) do
    opening = rule_open(css, selector)
    [before, rest] = String.split(css, opening, parts: 2)
    [_body, after_body] = String.split(rest, "}", parts: 2)
    before <> after_body
  end

  describe "the desk's focus rings are present in root.html.heex" do
    for {selector, subject} <- @desk_focus_rings do
      test "#{selector} — #{subject}" do
        selector = unquote(selector)
        css = sheet()

        assert rule_open(css, selector),
               """
               `#{selector}` is GONE from root.html.heex.

               #{unquote(subject)} can still be reached by Tab, but the focus
               is now INVISIBLE — which is the dead-looking control the owner
               reported (spd-w18, guarding #7567). Restore the rule, or if the
               ring genuinely moved, move this pin with it.
               """
      end

      test "#{selector} paints an actual ring, not an empty rule" do
        selector = unquote(selector)
        body = rule_body(sheet(), selector) || ""

        assert body =~ "outline:",
               "`#{selector}` declares no `outline` — got: #{inspect(body)}"

        assert body =~ "var(--ring)",
               "`#{selector}` must draw the themed ring token `var(--ring)` " <>
                 "so it survives light/dark — got: #{inspect(body)}"
      end

      test "#{selector} — SABOTAGE CONTROL: the checks pass on a ring and fail without one" do
        selector = unquote(selector)
        present = fixture(selector)
        cut = without_rule(present, selector)

        # positive arm — the predicates recognise a ring…
        assert rule_open(present, selector)
        assert rule_body(present, selector) =~ "outline:"
        assert rule_body(present, selector) =~ "var(--ring)"

        # …negative arm — and they say NO when it is gone. Without this, a
        # predicate that always returned truthy would guard nothing.
        refute rule_open(cut, selector),
               "the presence check cannot fail, so it guards nothing"

        refute rule_body(cut, selector),
               "the declaration check cannot fail, so it guards nothing"
      end
    end
  end

  describe "the shared .btn ring uses the BARE ring token" do
    # design/check.mjs Part E counts colour literals per file against a
    # hand-stamped ledger. `var(--ring, #2c6d5a)` reads as a literal and pushes
    # the root.html.heex row off its baseline — measured this wave at 165 -> 166
    # with the run FAILING. The presence checks above accept any body containing
    # `var(--ring)`, and `var(--ring, #hex)` does NOT contain that literal, so
    # they already discriminate; this test says so out loud and pins the offset
    # so the ring stays INSET (a positive offset on a 32px control clips).
    test ".btn:focus-visible declares no fallback hex and is inset" do
      body = rule_body(sheet(), ".btn:focus-visible")

      assert body, "`.btn:focus-visible` is missing from root.html.heex"

      refute body =~ "var(--ring,",
             "`.btn:focus-visible` must use the BARE token — a `var(--ring, #hex)` " <>
               "fallback is a colour literal and reds design/check.mjs Part E. " <>
               "Got: #{inspect(body)}"

      refute body =~ "#",
             "`.btn:focus-visible` declares a hex literal. Got: #{inspect(body)}"

      assert body =~ "outline-offset: -2px",
             "`.btn:focus-visible` must draw the ring INSIDE the box (the house " <>
               "idiom, 8+ existing uses) so a 28-32px control is not clipped. " <>
               "Got: #{inspect(body)}"
    end

    test "SABOTAGE CONTROL: the bare-token check says NO to a fallback hex" do
      bare = ".btn:focus-visible { outline: 2px solid var(--ring); outline-offset: -2px; }"
      fallback = ".btn:focus-visible { outline: 2px solid var(--ring, #2c6d5a); outline-offset: -2px; }"

      # positive arm — the real idiom passes every predicate…
      assert rule_body(bare, ".btn:focus-visible") =~ "var(--ring)"
      refute rule_body(bare, ".btn:focus-visible") =~ "var(--ring,"
      refute rule_body(bare, ".btn:focus-visible") =~ "#"

      # …negative arm — and a fallback hex fails all three. Without this, a
      # predicate that always returned truthy would guard nothing.
      refute rule_body(fallback, ".btn:focus-visible") =~ "var(--ring)",
             "the bare-token check cannot fail, so it guards nothing"

      assert rule_body(fallback, ".btn:focus-visible") =~ "var(--ring,"
      assert rule_body(fallback, ".btn:focus-visible") =~ "#"
    end
  end

  # The absent-list is retired: every ring it once dated honestly
  # (.bp-doc-checkbox — spd-bl-doc-checkbox-is-an-unfocusable-span, and
  # .bp-desk-chip — spd-w18-desk-chips-answer) has GRADUATED into
  # @desk_focus_rings above, exactly as its assertion message instructed.
end

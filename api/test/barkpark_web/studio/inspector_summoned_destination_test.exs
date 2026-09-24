defmodule BarkparkWeb.Studio.InspectorSummonedDestinationTest do
  @moduledoc """
  studio-space-priority-desk successor `inspector-narrow-destination-surface` —
  the summoned destination, and the RETIREMENT of the scrim that used to sit
  under it.

  ## What was retired

  The Studio inspector overlay scrim is gone. It used to be a five-rule family
  in `root.html.heex`: one generator (`.editor-with-preview:has(...)::after`
  with `content: ""`, inside `@container panel (max-width: 860px)`) and four
  later `content: none` suppressors — the b29 painted-closed guard, D170's
  wide kill switch, the narrow/phone destination pair (D155) and the standard
  compound suppressor (D175/D187). All five were deleted together.

  The measurement behind the deletion: with the whole family present, the
  forced-container control read `none` in 8 of 8 (bucket x user_opened) cells,
  on BOTH sides of the generator's own 860px threshold — 861px and 860px. The
  scrim rendered in no shipped state. D127 ruled that dimming a half-read
  document is a defect, and D170/D155/D175/D187 had already abolished it
  bucket by bucket; what remained was one unreachable generator wearing four
  cancellations. The ruling is now expressed by ABSENCE.

  ## What this file locks

  Two things, and they fail for different reasons.

  The GEOMETRY that survives — the `@container panel (max-width: 860px)`
  overlay box and the narrow/phone `[data-user-opened]` destination rule — is
  pinned literally, the same idiom as `wide_geometry_lock_test.exs`:
  expectations are hardcoded strings, never values re-derived from the sheet.
  A pin that reads its own subject cannot fail from the only thing it purports
  to guard (charter D94).

  The destination's POSITION COUPLING is asserted as an implication over a
  predicate, not as a pin: every rule whose subject is
  `.bp-doc-sidebar.is-open[data-user-opened]` (any bucket) and declares
  `inset` or `width: auto` must declare `position: absolute` in the same rule,
  because on an in-flow box that geometry is inert and the 300px flex basis
  wins. The literal pins cover today's narrow/phone rule; the implication also
  covers a sibling state added later. It has a non-vacuity floor (narrow and
  phone must be in the matched set) and spliced discrimination controls in
  both directions. It is a source-level contract, not a browser measurement.

  The ABOLITION is asserted as a PREDICATE OVER THE WHOLE SHEET, not as a list
  of five deleted selectors. An enumeration is a snapshot; a predicate is a
  rule. A five-name skip list would go green the day someone reintroduces a
  sixth scrim rule under a name nobody wrote down, which is exactly how this
  family grew from one rule to five in the first place. The predicate is: no
  style rule in either inline `<style>` block attaches a generated box to
  `.editor-with-preview` — no selector mentioning `.editor-with-preview`
  together with `::after`/`::before`. The matching set must be empty.

  ## Why an absence needs two more guards

  An absence assertion is the cheapest green there is: a parser that stops
  matching reports zero offenders and the file passes for free. So:

    * a LIVENESS FLOOR — the sheet must parse into a substantial number of
      rules AND a known sentinel selector must still be found. Either failing
      voids the absence verdict rather than confirming it.
    * a DISCRIMINATION CONTROL — the same predicate is re-run against a sheet
      with a synthetic scrim rule spliced in, in both directions (a
      `content: ""` generator and a `content: none` suppressor), and must
      report the offender. A predicate that has never been shown able to fail
      has not been shown to be a predicate.

  This is the ExUnit half of the enforcement. The sibling half is
  `scripts/studio-scrim-abolition-check.mjs`, which runs the same abolition
  predicate outside the Elixir suite.

  This slice OWNS `root.html.heex` this round (D16/D160). It stays
  file-disjoint from `wide_geometry_lock_test.exs` and `measure_parity_test.exs`;
  the small parsing helpers below are duplicated on purpose rather than shared,
  so this lock cannot be weakened by an edit aimed at either of those files.
  """
  use ExUnit.Case, async: true

  @moduletag :studio_summoned_destination

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # The two bucket-scoped selectors this slice added, verbatim.
  @narrow ~S|html[data-width-bucket="narrow"] .bp-doc-sidebar.is-open[data-user-opened]|
  @phone ~S|html[data-width-bucket="phone"] .bp-doc-sidebar.is-open[data-user-opened]|

  # The Tier-3 exit (D167) — the same two buckets, the same `[data-user-opened]`
  # qualifier, applied to the one control that closes the destination.
  @narrow_exit @narrow <> " .bp-doc-sidebar__collapse"
  @phone_exit @phone <> " .bp-doc-sidebar__collapse"

  # Comfortably under the ~1120 rules the sheet parses today. A floor this far
  # below the real count is not measuring drift — it is measuring that the
  # parser is still reading CSS at all.
  @rule_floor 500

  describe "the summoned destination takes the whole content pane" do
    test "narrow and phone are declared together and carry full-pane geometry" do
      block = block!([@narrow, @phone])

      # `absolute` + `inset: 0` against `.editor-panel`'s `position: relative`
      # IS "the full width of the content pane" — the pane is the containing
      # block, so the panel's box is the pane's box.
      assert value!(block, "position") == "absolute"

      assert value!(block, "inset") == "0",
             """
             The summoned inspector no longer fills its containing block.

             `inset: 0` against `.editor-panel`'s `position: relative` is what
             makes this a DESTINATION rather than a wider overlay. The whole
             argument for it (charter D113) is that at these widths there is no
             split of the pane in which the document survives: a 300px dock at
             viewport 800 leaves the reader 376px against the overlay's measured
             396.9px. Partially covering the pane re-opens exactly that.

             It matters more now than it did, not less. With the scrim retired
             there is nothing dimming what the panel fails to cover, so an
             inset that stops short leaves live, undimmed, unreachable prose
             beside the destination.
             """

      assert value!(block, "width") == "auto",
             """
             A width is back on the summoned panel.

             The `@container panel (max-width: 860px)` block sets `width: 300px`
             on `.bp-doc-sidebar.is-open`. This rule must neutralise it, or the
             destination is a 300px overlay again with `inset: 0` fighting it.
             """

      # The overlay block raises this and z-index applies whatever the
      # position, so it is restated rather than inherited by luck.
      assert value!(block, "z-index") == "5"

      # Nothing shows through to cast a shadow onto, and nothing sits beside
      # the border.
      assert value!(block, "box-shadow") == "none"
      assert value!(block, "border-left") == "0"
    end

    test "the overlay tier survives the scrim's retirement" do
      # THE RETIREMENT WAS OF THE SCRIM, NOT OF THE OVERLAY. The generator
      # lived inside `@container panel (max-width: 860px)` beside the rules
      # that lift the inspector out of the layout flow, and a deletion that
      # took the whole block with it would silently return the inspector to a
      # 300px column that steals width from the document instead of covering
      # it. These declarations are the overlay (D12); only the `::after` was
      # ruled a defect (D127).
      block = container_block!(860, ".bp-doc-sidebar.is-open")

      assert value!(block, "position") == "absolute"
      assert value!(block, "width") == "300px"
      assert value!(block, "inset") == "0 0 0 auto"
      assert value!(block, "z-index") == "5"

      # The wrap rule is the other half of "the panel can now sit over
      # arbitrary content" — label/value rows collide without it.
      assert value!(container_block!(860, ".bp-doc-field"), "flex-wrap") == "wrap"
    end

    test "the rule is bucket-scoped: it cannot match at wide or standard" do
      block = block!([@narrow, @phone])
      refute block == nil

      for bucket <- ~w(wide standard) do
        refute String.contains?(@narrow <> @phone, ~s|data-width-bucket="#{bucket}"|),
               """
               The summoned-destination rule names the `#{bucket}` bucket.

               At `wide` the inspector docks and costs the reader nothing — epic
               criterion 2 is measured there and the round-2 floor slice takes
               its input from those rows, so this rule may not move one pixel
               there (charter D92). At `standard` the inspector still docks too,
               so the destination geometry may not reach it either.
               """
      end
    end

    test "the b29/D91 painted-closed default still carves this state out" do
      src = decommented(css())

      # The geometry half of the painted-closed default still exempts the
      # asked-for panel. If it lost its carve-out, the default would start
      # fighting the destination rule instead of yielding to it.
      #
      # This test used to assert a SECOND carve-out, on the b29 scrim guard.
      # That rule is gone with the rest of the scrim family, and an assertion
      # about a deleted rule is the precise defect this rewrite exists to end.
      assert src =~
               ~S|html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened])|,
             "the b29/D91 geometry default lost its `:not([data-user-opened])` carve-out"
    end

    test "the Tier-3 exit is a 44px touch target, scoped so no docked tier can reach it" do
      # The exit earns its own lock because the destination is useless without
      # it: at Tier 3 the panel covers 100% of the content pane, so this button
      # is the ONLY way back to the document. Un-tripwired it regressed to a
      # 16x16 icon box — under every touch-target floor there is — and nothing
      # in this file noticed.
      block = block!([@narrow_exit, @phone_exit])

      assert value!(block, "min-width") == "44px"
      assert value!(block, "min-height") == "44px"

      # Without this the 16px glyph sits at the flex-start edge of its new 44px
      # box and the visual mark is 14px from where the finger is aimed.
      assert value!(block, "justify-content") == "center"

      # DISJOINT FROM THE PAINTED-CLOSED STRIP BY CONSTRUCTION. The strip is
      # `.is-open:not([data-user-opened])`; this rule requires
      # `[data-user-opened]`. No element satisfies both, so the strip's own 16px
      # button — and every docked tier — is structurally unreachable from here.
      # That is what lets a 44px minimum ship without moving a docked pixel.
      for sel <- [@narrow_exit, @phone_exit] do
        assert String.contains?(sel, "[data-user-opened]"),
               "the Tier-3 exit lost its `[data-user-opened]` qualifier — it can now " <>
                 "reach the painted-closed strip, whose 16px button is deliberate"
      end

      # And scoped by ENUMERATION, never negation: `:not([data-width-bucket="wide"])`
      # would also catch `standard`, whose inspector still docks.
      refute String.contains?(block!([@narrow_exit, @phone_exit]), "wide")

      for bucket <- ~w(wide standard) do
        refute String.contains?(@narrow_exit <> @phone_exit, ~s|data-width-bucket="#{bucket}"|),
               "the Tier-3 exit reaches the `#{bucket}` bucket, whose inspector docks"
      end
    end

    test "the crumb trail is VISIBLE at narrow, not merely emitted there (D168)" do
      # THE HALF-SHIPPED FEATURE THIS CATCHES. The markup half of D168 widened
      # `desk_crumbs/1` from phone-only to `in ["narrow","phone"]`, so the desk
      # now EMITS a breadcrumb nav at narrow — and that nav carries the document
      # crumb, which is the trail's way back out of the summoned destination.
      # This sheet's rule was written when the trail was a phone-drill
      # affordance and read `.bp-desk-crumbs { display: none }` with a single
      # phone override, so the narrow markup landed inside a `display: none`.
      #
      # A server emitting an escape route no reader can see is worse than not
      # emitting it: the DOM then asserts an affordance the desk does not
      # offer, and AT announces a link out of a trap that does not exist.
      block =
        block!([
          ~S|html[data-width-bucket="narrow"] .bp-desk-crumbs|,
          ~S|html[data-width-bucket="phone"] .bp-desk-crumbs|
        ])

      assert value!(block, "display") == "flex",
             "the narrow crumb trail is emitted by desk_crumbs/1 but not painted by this sheet"

      # And the base rule still hides it everywhere else — the trail is opt-in
      # per bucket, so `standard` and `wide` (whose inspectors dock beside a
      # document that never leaves the screen) keep their unchanged chrome.
      assert value!(block!([".bp-desk-crumbs"]), "display") == "none"
    end

    test "no motion property is introduced on the summoned panel" do
      block = block!([@narrow, @phone])

      for prop <-
            ~w(transition animation transform filter will-change backdrop-filter perspective) do
        refute Regex.match?(~r/(?:^|;)\s*#{prop}\s*:/, block),
               """
               `#{prop}` landed on the summoned-destination rule.

               A fade spends its whole duration painting a translucent panel
               over live prose — a transient re-run of the dimming charter D127
               ruled a defect and this slice abolished — and `transform` plants
               a containing block for fixed descendants inside the pane whose
               containment hazard has its own tripwire
               (`editor_panel_containment_test.exs`). If motion is wanted here
               later it needs a scoped `@media (prefers-reduced-motion: reduce)`
               block that nulls the TRANSITION property itself, not merely an
               animation.
               """
      end
    end
  end

  describe "the destination's geometry is COUPLED to position: absolute" do
    # The pins above check today's rule property by property. They do not
    # state the reason those properties belong together: `inset` and the
    # `width: auto` neutraliser mean something ONLY on an out-of-flow box. On an
    # in-flow box `inset` goes inert, `width: auto` stops fighting anything, the
    # base `flex: 0 0 300px` basis wins, and the destination is a 300px dock
    # again — the shape D113 measured as WORSE than the overlay at these widths.
    #
    # So the contract is an IMPLICATION, asserted over every rule the PREDICATE
    # selects (the subject compound is `.bp-doc-sidebar.is-open[data-user-opened]`,
    # any bucket), not over a hand-listed pair: a future sibling state added to
    # the same selector family with `inset` but no `position` is caught the day
    # it lands, with no constant in this file to update. This is a source-level
    # contract over the parsed sheet, not a browser layout measurement.
    test "every summoned-destination rule declaring inset or width: auto declares position: absolute" do
      rules = destination_rules(sheet())
      geometry = Enum.filter(rules, &declares_geometry?/1)

      # NON-VACUITY FLOOR. An implication over an empty set is true for free; a
      # predicate that stopped matching would pass this test forever. The two
      # rules known to carry this geometry today must be in the matched set.
      for sel <- [@narrow, @phone] do
        assert Enum.any?(geometry, &(&1.selector == sel)),
               """
               THE IMPLICATION VERDICT BELOW IS VOID.

               The destination predicate did not select `#{sel}` as a rule that
               declares `inset` or `width: auto`. Matched #{length(rules)}
               destination rule(s), #{length(geometry)} with geometry:
               #{format_offenders(geometry)}
               """
      end

      offenders = uncoupled_geometry(sheet())

      assert offenders == [],
             """
             A SUMMONED-DESTINATION RULE DECLARES GEOMETRY WITHOUT `position: absolute`.

             `inset` and `width: auto` only mean "fill the content pane" on an
             out-of-flow box. Without `position: absolute` in the same rule the
             inset is inert, the flex basis wins, and the destination silently
             reverts to a 300px in-flow dock (charter D113).

             Offending rules:
             #{format_offenders(offenders)}
             """
    end

    test "DISCRIMINATION — the implication reports a spliced sibling state missing position" do
      # The literal pins above cannot see this: they read the narrow/phone
      # block by its exact selector list, so a NEW sibling rule is invisible
      # to them. Only a predicate over the whole sheet can report it.
      for {label, sel, decls} <- [
            {"inset, no position",
             ~S|html[data-width-bucket="compact"] .bp-doc-sidebar.is-open[data-user-opened]|,
             "inset: 0; z-index: 5;"},
            {"width: auto under position: relative",
             ~S|html[data-width-bucket="compact"] .bp-doc-sidebar.is-open[data-user-opened]|,
             "position: relative; width: auto;"},
            {"reordered compound",
             ~S|html[data-width-bucket="compact"] .bp-doc-sidebar[data-user-opened].is-open|,
             "inset: 0;"}
          ] do
        # Diffed against the unspliced sheet, so this control measures the
        # PREDICATE and not the current state of the real rules.
        offenders = spliced_offenders("#{sel} { #{decls} }")

        assert Enum.map(offenders, & &1.selector) == [sel],
               """
               The coupling implication did NOT report a spliced sibling rule
               (#{label}) that carries destination geometry without
               `position: absolute`. It reported:
               #{format_offenders(offenders)}

               The implication is inert, so its green against the real sheet
               means nothing.
               """
      end
    end

    test "DISCRIMINATION — a coupled or non-subject rule is NOT reported" do
      # The other direction: an implication that flags everything is as useless
      # as one that flags nothing. A rule that DOES declare `position: absolute`,
      # a rule whose subject is a descendant (the Tier-3 exit button), and the
      # painted-closed `:not([data-user-opened])` state are all outside it.
      for rule <- [
            ~S|html[data-width-bucket="compact"] .bp-doc-sidebar.is-open[data-user-opened] { position: absolute; inset: 0; width: auto; }|,
            ~S|html[data-width-bucket="compact"] .bp-doc-sidebar.is-open[data-user-opened] .bp-doc-sidebar__collapse { inset: 0; }|,
            ~S|html[data-width-bucket="compact"] .bp-doc-sidebar.is-open:not([data-user-opened]) { inset: 0; }|
          ] do
        assert spliced_offenders(rule) == [],
               "the coupling implication falsely reported a rule outside its contract: #{rule}"
      end
    end
  end

  describe "the scrim is ABOLISHED — no generated box attaches to .editor-with-preview" do
    test "the sheet declares no .editor-with-preview ::after/::before rule at all" do
      offenders = scrim_offenders(sheet())

      assert offenders == [],
             """
             A GENERATED BOX IS BACK ON `.editor-with-preview`.

             The inspector overlay scrim was retired outright: one generator
             plus four `content: none` suppressors deleted together, after the
             forced-container control read `none` in 8 of 8
             (bucket x user_opened) cells at both 861px and 860px — the scrim
             painted in no shipped state. Dimming a half-read document is a
             defect (charter D127); D170, D155 and D175/D187 had already
             abolished it bucket by bucket. The ruling is now carried by the
             ABSENCE of any such rule, so any rule matching this predicate
             re-opens it — including a `content: none` one, which is a scrim
             rule wearing a cancellation and the shape the family grew back
             into last time.

             Offending selectors:
             #{format_offenders(offenders)}
             """
    end

    test "LIVENESS FLOOR — a parser that stopped reading voids the verdict above" do
      rules = style_rules(sheet())

      assert length(rules) >= @rule_floor,
             """
             THE ABSENCE VERDICT ABOVE IS VOID.

             Only #{length(rules)} style rule(s) parsed out of the inline
             `<style>` blocks; the floor is #{@rule_floor} and the sheet really
             carries roughly 1120. An absence assertion over a sheet the parser
             has stopped reading reports zero offenders for free. Fix the
             parser — or, if the sheet genuinely shrank by half, re-derive this
             floor and say so — before trusting any green in this file.
             """

      # THE SENTINEL. The floor alone does not prove the parser can still see
      # the selector the predicate keys on: a regex that reads every rule but
      # mangles `.editor-with-preview` would clear the floor and report zero
      # offenders. So the predicate's own subject has to be findable.
      selectors = Enum.map(rules, & &1.selector)

      assert Enum.any?(selectors, &(&1 == ".editor-with-preview")),
             """
             THE ABSENCE VERDICT ABOVE IS VOID.

             The sentinel selector `.editor-with-preview` — the base layout rule
             that has been in this sheet the whole time — was not found, so the
             parser cannot see the element the abolition predicate is about.
             Zero offenders then means "the parser is blind here", not "no scrim
             exists".
             """

      assert Enum.any?(
               selectors,
               &String.contains?(&1, ".editor-with-preview .editor-panel-main")
             ),
             "the second sentinel (`.editor-with-preview .editor-panel-main`) is gone too — " <>
               "the abolition verdict above is void, not confirmed"
    end

    test "DISCRIMINATION — the predicate reports a spliced-in scrim, both directions" do
      # A predicate that can only ever answer "none found" has not been shown
      # able to fail. Both directions matter: the retired family was ONE
      # generator and FOUR suppressors, so a predicate blind to `content: none`
      # would miss four fifths of what came back.
      for {label, decls} <- [
            {"generator", ~s|content: ""; position: absolute; inset: 0;|},
            {"suppressor", "content: none;"}
          ] do
        synthetic =
          ~s|.editor-with-preview:has(.bp-doc-sidebar.is-open)::after { #{decls} }|

        spliced = splice!(sheet(), synthetic)
        offenders = scrim_offenders(spliced)

        assert Enum.any?(
                 offenders,
                 &(&1.selector == ~S|.editor-with-preview:has(.bp-doc-sidebar.is-open)::after|)
               ),
               """
               The abolition predicate did NOT report a #{label} scrim rule
               spliced straight into the sheet.

               It reported #{length(offenders)} offender(s). The predicate is
               inert, so the empty result it returns against the real sheet
               means nothing at all.
               """
      end
    end

    test "DISCRIMINATION — ::before counts too, and so does a bucket-scoped form" do
      # The retired family was written `::after` five times, so a predicate
      # spelled against that one pseudo-element would pass a `::before`
      # rewrite. And every suppressor but one carried an `html[data-width-bucket]`
      # prefix, so the predicate must reach a selector that does not START with
      # `.editor-with-preview`.
      synthetic =
        ~s|html[data-width-bucket="standard"] .editor-with-preview:has(.bp-doc-sidebar.is-open)::before { content: ""; }|

      offenders = scrim_offenders(splice!(sheet(), synthetic))

      assert Enum.any?(offenders, &String.contains?(&1.selector, "::before")),
             "the predicate is `::after`-only — a `::before` scrim would ship past it invisibly"

      assert Enum.any?(
               offenders,
               &String.contains?(&1.selector, ~s|data-width-bucket="standard"|)
             ),
             "the predicate only reaches selectors that START with `.editor-with-preview` — " <>
               "four of the five retired rules were bucket-prefixed"
    end
  end

  describe "negative control — the parsing helpers themselves" do
    test "a zero-match selector fails LOUDLY rather than returning an empty block" do
      assert_raise ExUnit.AssertionError, ~r/no-such-summoned-rule/, fn ->
        block!([".bp-doc-sidebar.no-such-summoned-rule"])
      end
    end

    test "a missing property fails LOUDLY rather than comparing nil" do
      block = block!([@narrow, @phone])

      assert_raise ExUnit.AssertionError, ~r/border-radius/, fn ->
        value!(block, "border-radius")
      end
    end

    test "a zero-match container lookup fails LOUDLY" do
      assert_raise ExUnit.AssertionError, ~r/no-such-container-rule/, fn ->
        container_block!(860, ".no-such-container-rule")
      end
    end

    test "splice! refuses to return an unchanged sheet" do
      # The discrimination controls are worth nothing if the splice quietly
      # no-ops — the predicate would then be re-run against the untouched
      # sheet and report the same empty result it always does.
      assert_raise ExUnit.AssertionError, ~r/splice/i, fn ->
        splice!("body { margin: 0; }", "")
      end
    end
  end

  # --- the abolition predicate -----------------------------------------

  # Every declaration block in the sheet, one entry per comma-separated
  # selector. A comma-separated list is N rules, not one: reading only the
  # first selector is how a scrim rule declared `narrow, phone` hides its
  # second half from a sweep.
  #
  # The regex matches INNERMOST blocks only (`[^{}]*` on both sides), which is
  # what makes it see rules nested inside `@container` / `@media` without ever
  # mistaking an at-rule prelude for a selector. At-rule preludes are dropped
  # explicitly anyway.
  defp style_rules(sheet) do
    ~r/([^{}]*)\{([^{}]*)\}/s
    |> Regex.scan(sheet, capture: :all_but_first)
    |> Enum.flat_map(fn [selector_list, body] ->
      selector_list
      |> String.split(",")
      |> Enum.map(&normalise/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "@")))
      |> Enum.map(&%{selector: &1, body: normalise(body)})
    end)
  end

  # THE PREDICATE, stated as a rule and not as a list of five names: any style
  # rule that attaches a generated box to `.editor-with-preview`. Both
  # pseudo-elements, both spellings (`::after` is correct, `:after` is the
  # legacy form browsers still honour), whatever the selector's prefix.
  defp scrim_offenders(sheet) do
    Enum.filter(style_rules(sheet), fn %{selector: selector} ->
      String.contains?(selector, ".editor-with-preview") and
        Regex.match?(~r/::?(?:after|before)\b/, selector)
    end)
  end

  defp format_offenders([]), do: "(none)"

  defp format_offenders(offenders) do
    Enum.map_join(offenders, "\n", fn %{selector: s, body: b} -> "  #{s} { #{b} }" end)
  end

  # --- the position-coupling implication ------------------------------

  # Every style rule whose SUBJECT is the summoned destination: the last
  # compound of the selector carries `.bp-doc-sidebar`, `.is-open` and
  # `[data-user-opened]` (in any order, at any bucket prefix). `:not(...)`
  # groups are stripped first, so the painted-closed
  # `.is-open:not([data-user-opened])` state is not mistaken for it, and a
  # descendant such as `.bp-doc-sidebar__collapse` is a different subject.
  defp destination_rules(sheet) do
    Enum.filter(style_rules(sheet), fn %{selector: selector} ->
      subject =
        selector
        |> String.split(~r/\s*[>+~]\s*|\s+/)
        |> List.last()
        |> String.replace(~r/:not\([^)]*\)/, "")

      Regex.match?(~r/\.bp-doc-sidebar(?![\w-])/, subject) and
        Regex.match?(~r/\.is-open(?![\w-])/, subject) and
        String.contains?(subject, "[data-user-opened]")
    end)
  end

  # The antecedent: the rule places the box with `inset` (or an `inset-*`
  # longhand) or neutralises the overlay width with `width: auto`.
  defp declares_geometry?(%{body: body}) do
    Regex.match?(~r/(?:^|;)\s*inset(?:-[a-z-]+)?\s*:/, body) or
      Regex.match?(~r/(?:^|;)\s*width\s*:\s*auto\s*(?:!important\s*)?(?:;|$)/, body)
  end

  defp declares_absolute?(%{body: body}),
    do: Regex.match?(~r/(?:^|;)\s*position\s*:\s*absolute\s*(?:!important\s*)?(?:;|$)/, body)

  # The implication's counterexamples: geometry declared, `position: absolute`
  # not declared in the same rule.
  defp uncoupled_geometry(sheet) do
    sheet
    |> destination_rules()
    |> Enum.filter(&(declares_geometry?(&1) and not declares_absolute?(&1)))
  end

  # What a spliced rule ADDS to the implication's counterexamples. The
  # discrimination controls use this rather than the raw result, so they stay
  # a statement about the predicate even while the real sheet is red.
  defp spliced_offenders(rule) do
    uncoupled_geometry(splice!(sheet(), rule)) -- uncoupled_geometry(sheet())
  end

  # --- parsing ---------------------------------------------------------

  defp css, do: File.read!(@root)

  # The inline `<style>` blocks only — this file is a HEEx template, and its
  # markup and its design prose both quote selectors. A predicate that swept
  # the whole file would report an offender that is a COMMENT, and an absence
  # satisfiable by deleting a comment is not an absence.
  defp sheet do
    ~r|<style>(.*?)</style>|s
    |> Regex.scan(css(), capture: :all_but_first)
    |> Enum.map_join("\n", fn [body] -> body end)
    |> decommented()
  end

  # Comments first: this sheet's design prose quotes nearly every selector and
  # value below it, and a pin satisfiable by a comment is not a pin.
  defp decommented(src), do: Regex.replace(~r|/\*.*?\*/|s, src, "")

  # Insert `rule` immediately before the sentinel `.editor-with-preview {`
  # declaration — MID-SHEET, not appended. A control that only ever splices at
  # the tail proves the parser reads the tail.
  defp splice!(sheet, rule) do
    # The anchor must be a LINE-START `.editor-with-preview {`. The sheet also
    # carries `html[data-editor-focus="beta"] .editor-with-preview {`, and
    # splicing in front of THAT would graft its `html[...]` prefix onto the
    # synthetic selector — the control would then fail for a reason that has
    # nothing to do with the predicate it is testing.
    spliced =
      Regex.replace(
        ~r/(\n[ \t]*)(\.editor-with-preview\s*\{)/,
        sheet,
        fn _whole, indent, anchor -> indent <> rule <> indent <> anchor end,
        global: false
      )

    if spliced == sheet or rule == "" do
      flunk("""
      THE SPLICE DID NOTHING.

      The discrimination control below re-runs the abolition predicate against
      a sheet it believes carries a synthetic scrim rule. The line-start
      `.editor-with-preview {` anchor was not found (or the inserted rule was
      empty), so the predicate would be re-run against the UNTOUCHED sheet and
      its "no offenders" answer would be mistaken for a passing control.
      """)
    end

    spliced
  end

  # The one declaration block whose selector list is EXACTLY these selectors,
  # in this order. Zero matches raises here, naming them, rather than returning
  # an empty block that every assertion below passes against vacuously.
  defp block!(selectors) do
    esc = selectors |> Enum.map(&Regex.escape/1) |> Enum.join(~S|,\s*|)

    case Regex.scan(~r/(?:^|\})\s*#{esc}\s*\{([^{}]*)\}/, decommented(css()),
           capture: :all_but_first
         ) do
      [[one]] ->
        one

      [] ->
        flunk("""
        SELECTOR LIST MATCHED ZERO RULES:

        #{Enum.join(selectors, ",\n")}

        root.html.heex declares no rule with that selector list. Nothing below
        can be trusted — comparisons against an empty block pass vacuously,
        which is how this epic declared a measure criterion met twice on floors
        that had never once applied (charter D39/D40). Either the rule was
        renamed (repoint this constant and say so) or it was deleted, in which
        case the geometry it carried is GONE and that is the bug.
        """)

      many ->
        flunk(
          "that selector list now has #{length(many)} rules — the winner is source-order dependent"
        )
    end
  end

  # A rule by selector INSIDE a given `@container panel (max-width: Npx)`
  # block. `block!/1` cannot do this job: `.bp-doc-sidebar.is-open` is declared
  # twice in this sheet — once as the docked column, once as the overlay — and
  # a whole-file lookup would flunk on the ambiguity rather than answer it.
  defp container_block!(max_width, selector) do
    src = decommented(css())

    body =
      case Regex.run(
             ~r/@container\s+panel\s*\(\s*max-width:\s*#{max_width}px\s*\)\s*\{/,
             src,
             return: :index
           ) do
        [{match_start, match_len}] ->
          open_at = match_start + match_len - 1
          close_at = balanced_end(src, open_at + 1, 1)
          binary_part(src, open_at + 1, close_at - open_at - 1)

        _ ->
          flunk(
            "the `@container panel (max-width: #{max_width}px)` block is gone — the overlay " <>
              "tier it carries cannot be checked, and its absence is itself the bug"
          )
      end

    case Regex.scan(~r/(?:^|\})\s*#{Regex.escape(selector)}\s*\{([^{}]*)\}/, body,
           capture: :all_but_first
         ) do
      [[one]] ->
        one

      [] ->
        flunk(
          "`#{selector}` is not declared inside `@container panel (max-width: #{max_width}px)`"
        )

      many ->
        flunk("`#{selector}` is declared #{length(many)} times inside that container block")
    end
  end

  # Byte offset of the `}` that closes the brace opened at `i - 1`. Brace-
  # matched rather than scanned to the first `}`, because the 860px block
  # nests rules and a naive scan would truncate it at the first nested close.
  defp balanced_end(src, i, depth) do
    case :binary.at(src, i) do
      ?{ -> balanced_end(src, i + 1, depth + 1)
      ?} when depth == 1 -> i
      ?} -> balanced_end(src, i + 1, depth - 1)
      _ -> balanced_end(src, i + 1, depth)
    end
  end

  defp value!(block, prop) do
    case Regex.scan(~r/(?:^|;)\s*#{Regex.escape(prop)}\s*:\s*([^;}]+)/, block,
           capture: :all_but_first
         ) do
      [[one]] ->
        normalise(one)

      [] ->
        flunk("the rule no longer declares `#{prop}` — the geometry it carried is gone")

      many ->
        flunk(
          "`#{prop}` is declared #{length(many)} times — the winner is source-order dependent"
        )
    end
  end

  defp normalise(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s*,\s*/, ", ")
    |> String.replace(~r/\s+/, " ")
  end
end

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
      exactly why they need pinning rather than waiving. It names the `panel`
      container: this box is the reading column PLUS the docked inspector, and
      the rules that reason about the pane as a whole query it.
    * `.editor-with-preview .editor-panel-main.bp-paper-body` — the reading
      column, and the `content` container since `spd-w5`. It declares no box
      geometry at all, only which box the protected measure resolves against;
      losing that name sends the floor walking up to `.editor-panel` again,
      which silently reinstates the 300px error rather than breaking loudly.
    * `.bp-doc-sidebar.is-open` — the inspector, added in WAVE 11 and the
      largest hole this file ever had. `.editor-panel` is the reading column
      PLUS this box, so the dock's 300px is the reading measure's other term at
      every wide viewport — and it is one of the two numbers in
      `@container panel (max-width: 860px)` (860 = 560 + 300), which this file
      already pinned while pinning nothing about where the 300 came from.
      `pane_family?/1` matched only `pane-layout` / `pane-column` /
      `editor-panel`, so the whole family was invisible to the census: changing
      the basis `0 0 300px` -> `0 0 200px` — 44px onto the wide reading column
      — passed **16 of 16, before and after**. Both tiers are pinned now, the
      docked flex item and the overlaid `width: 300px` inside the 860px
      at-rule, because once the panel is absolutely positioned the basis stops
      applying to it at all and the two can drift apart.

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

  ## Why the checks are TEXT-based — and what a GREEN here does NOT mean

  ExUnit has no layout engine — it cannot observe a computed width. It can
  only observe the source facts that produce one. The live-browser counterpart
  is the wave-6 instrument's measured matrix at viewport 1280/1440; this file
  is what keeps those rows from rotting between waves.

  Read a green from this file as exactly one claim, and no more:

    * IT PROVES: the sheet's TEXT still declares the pinned box geometry, with
      the same literal values, on the same selectors, and that no rule
      declaring pane-or-inspector box geometry has appeared, vanished or
      changed which properties it declares — every override still gated behind
      a bucket the wide desk never carries or a variant it does not opt into.
    * IT DOES NOT PROVE: any pixel. Cascade order, specificity, inherited
      values, the browser's own flex resolution and every property outside
      `@geometry_props` are all invisible here. `flex: 0 0 300px` being present
      in the source is not the inspector measuring 300px on screen — a
      later-winning rule, a `transform`, or a container query resolving
      against a different box can all leave this file green and the desk
      wrong. That half is the deployed run's job (wave 11's live measurement
      against the production build), not this file's.

  The distinction is not pedantry: this epic has twice declared a measure
  criterion met on a floor that had never once applied (charter D39/D40). A
  text lock is a tripwire against silent EDITS, not a substitute for
  measurement.

  ## The fourth half: THE MEASURE'S OWN CAP — added by `spd-b42` (charter D270)

  This file locked the pane, the column, the rails and the inspector, and then
  watched a 96px change to the wide reading measure land from a DIFFERENT epic
  and pass every one of them.

  `.bp-paper-surface` carries `max-width: 660px`, landed 2026-08-12 by
  `pe-w1-reader-editorial-typography` (#11626, `3968dbc16`) as a deliberate
  editorial measure: 580px of text, ~69 characters per line at 18px on the
  NATIVE face. It is not a pane rule and not an inspector rule, so
  `pane_family?/1` never saw it and the census had nothing to compare — and at
  viewport 1280 it is now the BINDER of the reading measure. The reading column
  there is 676px (pane 976 − a 300px dock); the cap clips the surface to 660px
  before the column is anywhere near exhausted, so `content_px` is 580 rather
  than the 596 charter D120 measured, at 1280, 1024, 900, 800 and 1440 alike.

  That is a criterion-2 change — the wide desk's measure moved 16px at viewport
  1280 — and this file, whose entire purpose is to red on exactly that, was
  green through it. So the cap is pinned here, as a value, for the same reason
  the dock was pinned in wave 11: not because this file owns the number
  (`measure_parity_test.exs` owns the editorial half of it) but because this
  file is what says the WIDE DESK's measure moved.

  ## The third half: WHICH BOX each container query resolves against

  Added by `spd-w5` (charter D114), because the two mechanisms above are both
  blind to it in a way that is structural rather than accidental.

  The census keys every rule by its selector, and `last_line/1` deliberately
  HALTS at at-rule headers — it has its own negative control asserting exactly
  that, because a census key carrying `@container content (max-width: 860px)`
  would match none of the declared entries. So at-rule headers are excluded by
  design, and nothing else in five suites reads them either.

  That blindness has teeth. `.editor-panel` is the reading column PLUS the
  docked 300px Document inspector, and until `spd-w5` it was named `content` —
  so the protected-measure floor asked "is the PANE ≥720px?" and applied the
  answer to a column up to 300px narrower (charter D113). Moving the name onto
  the column is the fix; the hazard is that HALF the move also passes. Renaming
  the container while leaving the 860px inspector gate pointed at `content` was
  deliberately sabotaged and re-run before this pin existed: **73 tests, 0
  failures across five suites**, with the overlay-vs-dock threshold silently
  resolving against a box missing the very 300px its number is built from, at
  every width.

  So `@container_at_rules` pins each at-rule's NAME against the SUBJECT it
  governs, identified by a marker only that rule's body contains. Its own
  sabotage control keeps it honest.

  ## The fence

  Through round 1 this file READ `root.html.heex` and never edited it (D16/D92
  — `spd-b29` owned the sheet that round). `spd-w5` moves the container name
  IN that sheet, so the fence lifted for that slice by name and the sheet and
  this lock now land together. It stays file-disjoint from
  `measure_parity_test.exs`; the small parsing helpers below are duplicated on
  purpose rather than shared, so this lock cannot be weakened by an edit to a
  file aimed at the other one.
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
  #
  # COUNT, wave 11: 15 entries -> 26. The delta is exactly ELEVEN, every one of
  # them a `.bp-doc-sidebar` rule that `pane_family?/1` could not see until
  # this wave: seven declaring the inspector's own tiers (the element, the
  # docked and overlaid `.is-open` rules, `.is-collapsed`, and the three
  # `__head`/`__collapse`/`__body` children that merely share the prefix),
  # three Tier-3 destination rules shipped by #4923, and the Tier-3 exit's
  # 44px `min-width` landed by this wave's sibling CSS slice. Nothing was
  # removed, and no pre-existing entry changed shape — `expected -- actual` is
  # empty in both directions except for the additions.
  #
  # The eleventh arrived at INTEGRATION, not at build time, and that is the
  # census earning its keep rather than a defect: this file taught itself to
  # see the sidebar family in the same wave a sibling slice added a rule to it,
  # so the first thing the new eye saw was the new rule. Review declared it.
  #
  # (The BEFORE count is 15, not 14. Any brief saying 14 predates spd-w5 /
  # charter D114, which added the fifteenth: the
  # `.editor-with-preview .editor-panel-main.bp-paper-body`
  # container-name/container-type pair below.)
  @geometry_census [
    # --- the wide desk's own boxes: these ARE the wide bucket ---
    {".pane-layout", ~w(display flex overflow-x overflow-y)},
    {".pane-column", ~w(display flex-shrink min-width width)},
    {".pane-column--collapsed", ~w(flex-shrink max-width min-width width)},
    {".editor-panel", ~w(container-name container-type display flex min-width overflow)},

    # --- the inspector, wave 11: ALSO the wide bucket ---
    #
    # `.editor-panel` is the reading column plus this box, so every pixel
    # declared here is a pixel the wide reading measure does not get. These
    # are not "phone" rules that happen to mention the sidebar; the docked
    # 300px tier is what viewport 1280 and 1440 actually render.
    {".bp-doc-sidebar", ~w(display overflow)},
    # TWO rules key on this one selector, and both belong here: the top-level
    # docked tier (`flex: 0 0 300px; min-width: 0`) and the overlay tier
    # nested inside `@container panel (max-width: 860px)` (`width: 300px`).
    # The census keys by selector and is blind to at-rule headers by design
    # (see `last_line/1`), so the two arrive indistinguishable — which is why
    # their VALUES are pinned separately and by tier below.
    {".bp-doc-sidebar.is-open", ~w(flex min-width)},
    {".bp-doc-sidebar.is-open", ~w(width)},
    {".bp-doc-sidebar.is-collapsed", ~w(flex)},
    {".bp-doc-sidebar__head", ~w(display)},
    {".bp-doc-sidebar__collapse", ~w(display)},
    {".bp-doc-sidebar__body", ~w(overflow-y)},

    # --- Tier-3, the summoned destination (#4923): explicitly NOT wide ---
    #
    # Every one of these is negatively or positively gated away from the wide
    # bucket — `html:not([data-width-bucket="wide"])` subtracts it by name,
    # and the narrow/phone pair never matches there. That scoping is the whole
    # reason these rules were allowed to move geometry at all (charter D92):
    # epic criterion 2 is measured at 1280/1440 and they may not reach it.
    {~S|html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened])|,
     ~w(flex width)},
    {~S|html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened]) .bp-doc-sidebar__title, html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened]) .bp-doc-sidebar__body|,
     ~w(display)},
    {~S|html[data-width-bucket="narrow"] .bp-doc-sidebar.is-open[data-user-opened], html[data-width-bucket="phone"] .bp-doc-sidebar.is-open[data-user-opened]|,
     ~w(width)},
    # The Tier-3 EXIT's 44px touch target (charter D167), landed by the sibling
    # slice this same wave. It is in the census because `min-width` is a
    # geometry property and the selector is in the sidebar family — this file
    # made itself able to see exactly this rule, and then saw it. The entry is a
    # census REFRESH, not a code fix: Review integrated the two branches, the
    # census reported the rule as "New in the stylesheet (found, not declared
    # here)", and the honest response to a tripwire that fires correctly is to
    # declare what fired it.
    #
    # It is narrow/phone-scoped on BOTH halves of the list, so the wide desk
    # cannot reach it and epic criterion 2's band is untouched — which the
    # `scoped?` test below re-derives per-part rather than taking on trust.
    {~S|html[data-width-bucket="narrow"] .bp-doc-sidebar.is-open[data-user-opened] .bp-doc-sidebar__collapse, html[data-width-bucket="phone"] .bp-doc-sidebar.is-open[data-user-opened] .bp-doc-sidebar__collapse|,
     ~w(min-width)},

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
    # spd-w5: the reading column's own query base. This one DOES apply at
    # 1280/1440 — see the scoped? allowlist below for why that is deliberate.
    {".editor-with-preview .editor-panel-main.bp-paper-body", ~w(container-name container-type)},
    {".editor-with-preview.has-onix-preview .editor-panel-main", ~w(flex max-width)},

    # --- a different element that merely shares the name prefix ---
    {".pane-column-collapsed-label", ~w(display flex overflow)}
  ]

  # THE AT-RULE PIN (spd-w5, charter D114). Every `@container` at-rule in the
  # sheet, as {container name, condition, a marker only THIS rule's body
  # contains, why that name is the right box}.
  #
  # This is the one hazard the geometry census structurally cannot see. The
  # census keys each rule by its selector, and `last_line/1` deliberately halts
  # at at-rule headers (see its own negative control below) — so which box a
  # container query resolves against is read by nothing else in five suites.
  # Mis-point one and the rule keeps applying at a threshold measured against a
  # box up to 300px off, silently.
  @container_at_rules [
    {"content", "min-width: 720px", ".bp-paper-surface",
     """
     The protected measure's subject is the READING COLUMN. It asks whether
     the column can honour a 55ch floor, so it must measure the column — not
     the pane, which also holds the docked 300px inspector. Measuring the pane
     is what let the gate say "yes, 976px" about a 676px column at viewport
     1280 and push the surface into a 12px overflow (charter D85).
     """},
    {"panel", "max-width: 860px", ".bp-doc-sidebar.is-open",
     """
     The overlay-vs-dock threshold's subject is the WHOLE PANE. 860 is
     560 (the content floor) + 300 (the docked inspector) — a sum over the
     pane, deciding whether both terms still fit side by side. Resolving it
     against the reading column would subtract the inspector from the box and
     then ask whether the inspector fits: off by exactly the term the number
     is built from.
     """},
    {"panel", "max-width: 720px", ".editor-with-preview.has-onix-preview",
     """
     The ONIX 60/40 split's subject is the WHOLE PANE. Its two halves are
     siblings inside `.editor-panel`, and the question is how much room the
     two of them have between them — which one half cannot answer about
     itself. The ONIX surface is also not `.bp-paper-body`, so it carries no
     `content` container at all: a `content` query here would resolve against
     the nearest ancestor container, landing on `panel` by luck rather than by
     contract.
     """}
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

    test ".editor-panel carries its 560px floor and the `panel` query base" do
      block = block!(".editor-panel")

      assert value!(block, ".editor-panel", "flex") == "1"
      assert value!(block, ".editor-panel", "overflow") == "hidden"

      assert value!(block, ".editor-panel", "min-width") == "560px",
             "the content pane's own floor moved — the priority squeeze bottoms out elsewhere now"

      # These two are NEW this epic and permitted BY NAME by D94's re-authored
      # criterion 2. Permitted is not the same as unpinned.
      #
      # `container-type` must stay: it is what makes this box a query
      # container at all, AND its layout containment is the subject of
      # `editor_panel_containment_test.exs`'s Blink containing-block guard
      # (charter D114). Only the NAME moved in spd-w5.
      assert value!(block, ".editor-panel", "container-type") == "inline-size"

      assert value!(block, ".editor-panel", "container-name") == "panel",
             """
             `.editor-panel` no longer names the `panel` container.

             This box is the reading column PLUS the docked Document
             inspector, and it is named for what it is. It used to be named
             `content`, which was a lie of 300px: the protected-measure floor
             asked `@container content (min-width: 720px)` and got an answer
             about a box up to 300px wider than the column it protects — at
             viewport 1280, a 976px pane gating a 676px column, which is the
             mechanism behind charter D85's measured 12px overflow. spd-w5
             moved the name `content` onto the reading column's own box
             (`.editor-with-preview .editor-panel-main.bp-paper-body`) and left
             `panel` here for the two rules whose SUBJECT really is the whole
             pane: the inspector's overlay-vs-dock threshold (860 = 560 + 300,
             a sum over the pane) and the ONIX split.

             If this reverted to `content`, both query bases collapse back
             onto one box and the floor silently re-acquires the 300px error —
             no error, no red, nothing visible until someone measures. That
             failure mode is this epic's whole disease (charter D39/D40/D114).
             """
    end

    test "the reading column is its own `content` query base" do
      block = block!(".editor-with-preview .editor-panel-main.bp-paper-body")

      assert value!(
               block,
               ".editor-with-preview .editor-panel-main.bp-paper-body",
               "container-type"
             ) ==
               "inline-size"

      assert value!(
               block,
               ".editor-with-preview .editor-panel-main.bp-paper-body",
               "container-name"
             ) ==
               "content",
             """
             The reading column no longer names the `content` container.

             `.bp-paper-surface` is a descendant of this box, and the protected
             measure floor is written `@container content (min-width: 720px)`.
             With no `content` container on the column, that query walks up to
             the nearest ancestor container — which is `.editor-panel`, i.e.
             exactly the 300px-too-wide box spd-w5 moved it off (charter
             D113/D114). The floor would keep applying and keep being wrong.
             """
    end

    test "the docked inspector is EXACTLY 300px — the reading column's other term" do
      # Two rules key on this selector and the census cannot tell them apart
      # (it is blind to at-rule headers by design), so they are separated here
      # by the tier each one declares: the docked tier is the flex item, the
      # overlay tier is the absolutely-positioned one.
      blocks = blocks!(".bp-doc-sidebar.is-open")

      assert length(blocks) == 2,
             """
             `.bp-doc-sidebar.is-open` now has #{length(blocks)} rules, not 2.

             The inspector has exactly two tiers: docked (a flex item beside
             the reading column) and overlaid (absolute, inside `@container
             panel (max-width: 860px)`). A third rule is a third tier nobody
             declared, and whichever one wins is source-order dependent.
             """

      {docked, overlay} = Enum.split_with(blocks, &String.contains?(&1, "flex:"))
      [docked] = docked
      [overlay] = overlay

      # THE NUMBER. D149 rules the dock stays 300px, and this assertion is the
      # only thing in five suites that says so. `.editor-panel` is the reading
      # column PLUS this box, so at viewport 1280 and 1440 every pixel here is
      # a pixel the reading measure does not get — and the `panel` at-rule's
      # 860px threshold is literally 560 + 300, so moving this desynchronises
      # the overlay decision from the geometry it decides about.
      #
      # Before this pin existed, 300px -> 200px passed 16 of 16.
      assert value!(docked, ".bp-doc-sidebar.is-open (docked)", "flex") == "0 0 300px",
             """
             The docked inspector's flex basis moved off 300px.

             This box sits INSIDE `.editor-panel`, beside the reading column,
             at every wide viewport — so its basis is a term in the wide
             reading measure, and changing it moves epic criterion 2's own
             band without touching any rule this file used to watch. That is
             not hypothetical: `pane_family?/1` was blind to `.bp-doc-sidebar`
             until wave 11, and 300px -> 200px passed 16 of 16 both before and
             after while moving 44px of wide reading column.

             It is also one of the two terms in `@container panel (max-width:
             860px)` — 860 = 560 (the content floor) + 300 (this). Move one
             without the other and the overlay-vs-dock threshold starts
             answering about a layout that no longer exists (charter D149).
             """

      # `min-width: 0` is what lets the basis be the whole story: without it a
      # flex item's automatic minimum is its content, and a long metadata value
      # would push the dock past 300px and eat the column silently.
      assert value!(docked, ".bp-doc-sidebar.is-open (docked)", "min-width") == "0"

      # The overlay tier carries the same 300px as an explicit width, because
      # once it is `position: absolute` it is no longer a flex item and the
      # basis above stops applying to it at all.
      assert value!(overlay, ".bp-doc-sidebar.is-open (overlay)", "width") == "300px",
             "the overlaid inspector's width drifted from the docked tier's 300px"
    end
  end

  describe "the reading measure's own cap — the binder at viewport 1280 (spd-b42)" do
    test ".bp-paper-surface caps the measure at 660px, and the wide desk feels it" do
      # TWO rules share this selector line: the token/colour block and the
      # geometry block. Split by the property that makes one of them geometry,
      # rather than by source order, which a later edit reshuffles silently.
      capped =
        ".bp-paper-surface"
        |> blocks!()
        |> Enum.filter(&(&1 =~ ~r/(?:^|;)\s*max-width\s*:/))

      assert length(capped) == 1,
             """
             #{length(capped)} rules on a bare `.bp-paper-surface` selector line
             declare `max-width`, not 1. Two caps on one box is a source-order
             race for the number that decides the reading measure.
             """

      [cap] = capped

      # THE NUMBER, AND WHAT IT BINDS. Measured on deployed `8a05efce1` with
      # scripts/studio-desk-measure.mjs, bracketed, 54 of 54 rows, positive
      # control fired (charter D270): at viewport 1280 the pane is 976px and
      # the reading column 676px, but the surface resolves to 660px and
      # `content_px` to 580px — the cap binds, not the column, and not the
      # 300px dock the task's arithmetic blamed. 580px is 58.00ch on the
      # native face at 18px and 52.50ch on forced Georgia at 18px, each read
      # by a same-face `width: 1ch` probe (11.0469 px/ch for Georgia) and
      # never by dividing one face's box by another's advance (D83/D86).
      #
      # So this one declaration sets the wide desk's measure at viewport 1280,
      # 1024, 900 and 800, and moving it moves epic criterion 2's own band —
      # which is what this file exists to catch. It moved once already, from
      # an effective 676px to 660px, and every pin in this file stayed green.
      assert value!(cap, ".bp-paper-surface (the measure cap)", "max-width") == "660px",
             """
             The reading measure's cap moved off 660px.

             This is the widest the paper surface may render, so at every
             viewport whose reading column exceeds it — 1440, 1280, 1024, 900
             and 800 on the deployed matrix — it, and not the pane or the
             inspector, is what the reader's line length is. A change here is a
             reading-measure change at the wide desk whatever epic it arrives
             from, and epic criterion 2 is measured on exactly that band.

             If this move is intended: re-measure with
             `node scripts/studio-desk-measure.mjs --sha=<served sha>` and
             update this pin with the new matrix, in the same diff. Do not
             update it from arithmetic — the last three overturns in this epic
             were arithmetic (charter D35/D36/D38/D40/D72/D75).
             """

      # The gutter token is pinned WITH the cap because the reader's measure is
      # the difference between them (660 - 80 = 580) and the protected floor
      # consumes the same token (`calc(55ch + 2 * var(--paper-gutter))`,
      # charter D103). A cap that holds while the token moves is the same
      # measure change wearing a different number.
      assert value!(cap, ".bp-paper-surface (the measure cap)", "--paper-gutter") == "40px",
             "the surface's gutter token moved — the measure is `max-width - 2 x this`"
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

    test "every geometry override outside the base rules is bucket- or variant-scoped" do
      # The boxes that ARE the wide desk. `.bp-doc-sidebar` and its docked
      # `.is-open` tier joined in wave 11 — not as an exemption but as an
      # admission: they render at 1280 and 1440, so their values are pinned as
      # literal constants above rather than waved through here.
      base = [
        ".pane-layout",
        ".pane-column",
        ".pane-column--collapsed",
        ".editor-panel",
        ".bp-doc-sidebar",
        ".bp-doc-sidebar.is-open"
      ]

      # EVERY selector in a comma-separated list is checked, not just the one
      # the census key happens to end on. #4923's Tier-3 rules are written as
      # narrow/phone pairs, and "the first half is scoped" says nothing about
      # the second — a list whose tail reached the wide desk would otherwise
      # ride in on its head's scoping.
      for {key, _props} <- geometry_census(),
          selector <- String.split(key, ", "),
          selector not in base do
        # NEGATIVE scoping, and the strongest form available: the wide
        # bucket is subtracted by name. #4923's summoned-destination rules
        # move real geometry (`flex`, `width`) and are allowed to precisely
        # because `html:not([data-width-bucket="wide"])` cannot match in
        # epic criterion 2's own band (charter D92).
        scoped? =
          String.starts_with?(selector, ~S|html[data-width-bucket="phone"] |) or
            String.starts_with?(selector, ~S|html[data-width-bucket="narrow"] |) or
            String.starts_with?(selector, ~S|html[data-editor-focus="beta"] |) or
            String.starts_with?(selector, ~S|html:not([data-width-bucket="wide"]) |) or
            selector in [
              # Inspector variants and children. `.is-collapsed` is a state the
              # desk carries only when the user has collapsed the panel, and
              # the three `__`-children are inner chrome: they lay out the
              # inspector's own header and scroll body and declare nothing
              # about how much room the inspector takes from the document.
              ".bp-doc-sidebar.is-collapsed",
              ".bp-doc-sidebar__head",
              ".bp-doc-sidebar__collapse",
              ".bp-doc-sidebar__body",
              ".bp-doc-sidebar__title",
              ".editor-panel.sheet-editor",
              ".editor-with-preview .editor-panel-main",
              ".editor-with-preview.has-onix-preview .editor-panel-main",
              ".pane-column-collapsed-label",
              # A REAL WIDENING OF THE PERMITTED SET, not boilerplate (spd-w5,
              # charter D114). Unlike every other entry above, this rule DOES
              # apply at viewport 1280 and 1440 — the paper editor declares a
              # query container on its reading column in every bucket, by
              # design, because the protected measure has to be able to ask
              # about that column at wide widths too (wide is precisely where
              # the docked inspector makes the pane and the column differ by
              # 300px, which is the whole reason the name moved).
              #
              # It is admitted here on the ground that it declares NO box
              # geometry: `container-type`/`container-name` change what a
              # query resolves against, not what any box measures. The census
              # above pins those two property names, so a later edit that adds
              # a real geometry property (a width, a flex, a min-width) to this
              # same rule reds the census and lands back in front of a reader
              # rather than riding in on this allowance.
              ".editor-with-preview .editor-panel-main.bp-paper-body"
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

  describe "every @container at-rule queries the box its SUBJECT lives in" do
    test "each at-rule's container NAME matches the subject it governs" do
      found = container_at_rules()

      for {name, condition, marker, why} <- @container_at_rules do
        matching = Enum.filter(found, fn {_n, _c, body} -> String.contains?(body, marker) end)

        assert length(matching) == 1,
               """
               The subject marker `#{marker}` appears in #{length(matching)} @container
               at-rules, not exactly one.

               This pin identifies each at-rule by something only IT contains,
               so that the name it queries can be checked against the box that
               name has to resolve against. A marker that matches zero rules
               means the rule was deleted or its subject renamed; a marker that
               matches several means the pin has stopped identifying anything
               and every assertion below it is vacuous.
               """

        [{actual_name, actual_condition, _body}] = matching

        assert actual_condition == condition,
               "the at-rule governing `#{marker}` now reads `(#{actual_condition})`, " <>
                 "not `(#{condition})` — its threshold moved"

        assert actual_name == name,
               """
               WRONG QUERY BASE: the at-rule governing `#{marker}` queries
               `#{actual_name}`, but its subject requires `#{name}`.

               #{why}

               THIS IS THE HAZARD THIS TEST EXISTS FOR (charter D114). A
               mis-pointed at-rule is not a broken rule — it is a rule that
               keeps applying, at a threshold measured against the wrong box,
               with no error and no red. The same edit was deliberately
               sabotaged and re-run before this pin existed: 73 tests, 0
               failures, with the inspector's overlay-vs-dock threshold
               silently resolving against a box missing the inspector's own
               300px, at every width.

               The geometry census in this file structurally cannot see this:
               `last_line/1` halts at at-rule headers BY DESIGN (its own
               negative control asserts that), so at-rule headers are excluded
               from the census and nothing else in five suites reads them.
               """
      end
    end

    test "the at-rule census is exactly these three — a new one lands in front of a reader" do
      actual = container_at_rules() |> Enum.map(fn {n, c, _} -> {n, c} end) |> Enum.sort()
      expected = @container_at_rules |> Enum.map(fn {n, c, _, _} -> {n, c} end) |> Enum.sort()

      assert actual == expected,
             """
             The set of `@container` at-rules in root.html.heex has CHANGED.

             Missing (declared here, not found): #{inspect(expected -- actual)}
             New (found, not declared here): #{inspect(actual -- expected)}

             Every container query in this sheet has to declare which box it
             reasons about — `content` (the reading column) or `panel` (the
             column plus the docked inspector). Those two differ by 300px, and
             picking the wrong one is silent. Add your rule here with the
             subject marker that identifies it and a sentence saying why its
             box is the right one.
             """
    end

    # REVIEW FIX (spd-w5 review). The census above enumerates only NAMED
    # container queries, because that is the only shape `container_at_rules/1`
    # can parse. An UNNAMED `@container (max-width: …)` is legal CSS and is the
    # sharpest version of D114's hazard: with no name it resolves against the
    # NEAREST ancestor query container, which is whichever of `content`/`panel`
    # happens to be closer — by proximity rather than by contract, and it would
    # slip past both the census (which never sees it) and the name pin (which
    # has nothing to compare). This counts every `@container` token in the sheet
    # and requires the named parse to account for all of them.
    test "there are no UNNAMED container queries — every one declares its box" do
      src = decommented(css())
      total = length(Regex.scan(~r/@container\b/, src))
      named = length(container_at_rules())

      assert total == named,
             """
             #{total - named} `@container` at-rule(s) in root.html.heex declare NO
             container name.

             An unnamed container query resolves against the nearest ancestor
             query container. This sheet deliberately has two — `content` (the
             reading column) and `panel` (that column PLUS the docked 300px
             inspector) — so "nearest" is an accident of markup, not a decision,
             and the two answers differ by 300px (charter D113/D114).

             Name it, then add it to @container_at_rules with the marker that
             identifies its subject and a sentence saying why that box is right.
             """
    end

    test "the pin RED-tests: a mis-pointed at-rule is caught by name" do
      # The mutation this file was written against, run in-process against a
      # synthetic sheet so the guarantee does not depend on anyone repeating
      # it by hand. `panel` flipped to `content` on the inspector gate.
      sabotaged = """
      @container content (max-width: 860px) {
        .bp-doc-sidebar.is-open { position: absolute; }
      }
      """

      [{name, condition, _body}] = container_at_rules(sabotaged)

      assert {name, condition} == {"content", "max-width: 860px"},
             "the parser cannot read an at-rule's name — the pin above is vacuous"

      # And the pin's own comparison is what rejects it.
      {expected_name, _c, _m, _w} =
        Enum.find(@container_at_rules, fn {_n, _c, marker, _w} ->
          marker == ".bp-doc-sidebar.is-open"
        end)

      refute name == expected_name,
             "the sabotage is indistinguishable from the correct sheet — re-read D114"
    end

    test "the parser reads a name even when the at-rule body nests braces" do
      # The real 860px rule contains a nested `:has()` block, so a naive
      # first-closing-brace scan would truncate its body and lose the marker.
      sheet = """
      @container panel (max-width: 860px) {
        .bp-doc-sidebar.is-open { position: absolute; }
        .editor-with-preview:has(.bp-doc-sidebar.is-open)::after { content: ""; }
        .bp-doc-field { flex-wrap: wrap; }
      }
      """

      assert [{"panel", "max-width: 860px", body}] = container_at_rules(sheet)
      assert body =~ ".bp-doc-field"
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
    case blocks!(selector) do
      [one] ->
        one

      many ->
        flunk(
          "`#{selector}` now has #{length(many)} base rules — the winner is " <>
            "source-order dependent; collapse it to one"
        )
    end
  end

  # Every rule whose selector line is exactly `selector`, for the selectors
  # that legitimately have more than one tier (the inspector's docked and
  # overlaid `.is-open` rules). Zero matches still raises HERE, for the same
  # reason `block!/1` does.
  defp blocks!(selector) do
    esc = Regex.escape(selector)

    found =
      ~r/^[ \t]*#{esc}[ \t]*\{([^{}]*)\}/m
      |> Regex.scan(decommented(css()), capture: :all_but_first)
      |> List.flatten()

    case found do
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
        many
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

  # Every `@container <name> (<condition>) { <body> }` in the sheet, with the
  # body BRACE-MATCHED rather than scanned to the first `}`: the real 860px
  # rule nests a `:has()` block, so a naive scan would truncate its body and
  # lose the very selector that identifies it.
  defp container_at_rules(source \\ nil) do
    src = decommented(source || css())

    ~r/@container\s+([A-Za-z][\w-]*)\s*\(([^)]*)\)\s*\{/
    |> Regex.scan(src, return: :index)
    |> Enum.map(fn [{match_start, match_len}, name_at, condition_at] ->
      {
        slice(src, name_at),
        normalise(slice(src, condition_at)),
        balanced_body(src, match_start + match_len - 1)
      }
    end)
  end

  defp slice(src, {at, len}), do: binary_part(src, at, len)

  # `open_at` is the byte index of the at-rule's own `{`. Bytes are safe to
  # walk here: any multi-byte character's bytes are all >= 0x80, so none of
  # them can be mistaken for a brace.
  defp balanced_body(src, open_at), do: balance(src, open_at + 1, 1, open_at + 1)

  defp balance(src, i, depth, start) do
    case :binary.at(src, i) do
      ?{ -> balance(src, i + 1, depth + 1, start)
      ?} when depth == 1 -> binary_part(src, start, i - start)
      ?} -> balance(src, i + 1, depth - 1, start)
      _ -> balance(src, i + 1, depth, start)
    end
  end

  # The families whose box geometry IS the wide desk.
  #
  # `bp-doc-sidebar` joined this list in wave 11, and it was not an oversight
  # being tidied up — it was a hole proven by mutation. `.editor-panel` is the
  # reading column PLUS the docked inspector, so the inspector's own width is a
  # term in the reading measure at every wide viewport. With the predicate
  # blind to it, changing `.bp-doc-sidebar.is-open`'s basis from `0 0 300px` to
  # `0 0 200px` — 100px off the dock, 44px onto the wide reading column after
  # the pane's own floor takes its share — left this file at 16 of 16 PASSING,
  # before and after. The census never saw the rule, so there was nothing to
  # compare; see the `.bp-doc-sidebar.is-open` literal pin above for the value
  # side of the same fix.
  defp pane_family?(selector) do
    String.contains?(selector, "pane-layout") or
      String.contains?(selector, "pane-column") or
      String.contains?(selector, "editor-panel") or
      String.contains?(selector, "bp-doc-sidebar")
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

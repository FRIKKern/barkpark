# Composition doctrine — close the card loop, dogfood the doctrine (composition-doctrine epic charter)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **self-update W5** at `bp-self-update-w5-charter.md`,
> **gui-premium W5** at `bp-gui-premium-w5-charter.md`, and **p-quality-gate (hollow-paper
> gate)** at `bp-hollow-paper-gate-charter.md` (its wave shipped in #2283 — read the
> preserved file, not this one). This file is now the memory of the **composition-doctrine**
> epic (Element·Widget·Section·Layout·Document ladder — card-loop wave).

Epic anchor: bp task slug **`composition-doctrine`** (published, priority 1, 14 children).
Plan paper: `/papers/composition-doctrine-plan` on guerrilla. Wave paper:
`composition-doctrine-wave-2026-07-10`. Server: guerrilla.

## Vision

An author types `/card`, gets a card whose four regions (media/title/body/action) are all
genuinely editable — media via the real picker, action via the real label/href/priority
editor — drops it into a grid-section-of-cards starter in one action, and the SAME document
renders faithfully on web reader, editor, TUI, and email, with golden parity proof on every
leg including email slot content. And the doctrine eats its own dogfood: the
composition-doctrine-plan paper itself (plus the other real legacy-block papers) runs on
the new editable widgets, migrated by a dry-run-first, byte-parity-proven mix task — real
content on the doctrine, not showcases.

## Non-negotiable operational facts (builders read FIRST)

- .ex/.exs/.heex changes WAIT for the Elixir Test CI gate before merge. Worktrees from
  origin/main after `git fetch`. Claim your bp task BEFORE working. PR body carries
  `Task: <id>`. `cc` is a Claude wrapper — always `CC=/usr/bin/clang`.
- Render-path unification law: reader/editor/email share the compose seam — style-branching
  inside `Compose.compose_block/2,3` is the sanctioned pattern; a parallel render function
  anywhere is a fork and is forbidden.
- Goldens: ONE generator (`mix barkpark.paper_components.gen_golden_parity`), 12 types × 3
  mirrors (api/test/support/fixtures, web/__tests__/fixtures, internal/pdrender/testdata).
  Byte-unchanged except owned regens. PROVEN byte-fresh at HEAD this wave (regen → zero diff).
- The golden gate blocks only at the CI-workflow layer: main has NO GitHub branch
  protection/rulesets (re-verified 2026-07-10) — a red gate is human-mergeable. Reviewer
  discipline is the real net until `cd-gov-required-checks` lands.
- `parity2-bug-card-slot-chrome` (sibling epic paper-edit-parity-endgame) also touches
  card-node.js — check it is not in flight before building cd-9.

## Decisions

- **D-W2-1 — cd-7 stays open, scoped to the email golden twin only.** The render impl is
  merged on both halves (TUI PRs #1302/#1535/#1539; email cards_email.ex via #1904/#1910
  through the shared seam), but email slot CONTENT has ZERO test coverage (all
  cards_email_test.exs card cases are slot-less flat maps that card_email_html ignores) and
  the golden byte gate excludes email entirely — the task's third deliverable (parity twin)
  is unmet. Close-with-evidence was wrong; a ~10-line email realization leg in
  component_golden_parity_test.exs is right. No 4th mirror: email output is themed inline
  bytes, not a portable projection — the twinnable thing is the fixture INPUT.
- **D-W2-2 — cd-8 is ONE slice (insertion + starter), 3 JS registries, no blocks.ex.**
  Card insertion is a test-enforced 2-registry lockstep (CANVAS_SLASH_TYPES+canvasDefaultBlock
  in slash-insert.js; INSERT_META+INSERT_ORDER in command-palette.js; SLASH_ITEMS in
  slash-menu.js) — "automatic lockstep" is false; smoke/autocomplete-slash.mjs enforces
  count parity (pinned 22 → bump to 23). Widgets skip blocks.ex (note/stage precedent
  #1262). The grid-of-cards starter is a NEW compound-insert command (no precedent exists;
  columns' 2-empty-children default is the shape analog; SECTION_OF_CARDS fixture in
  smoke/cards.mjs is the proven target shape). Both halves share the same files, so one
  builder owns them — merged, not sequenced.
- **D-W2-3 — cd-9 is wiring: mount the WC, keep the shape contract.** Reuse the
  buildPickerNodeView MOUNT PATTERN (not the function) to put `<bp-media-picker
  chrome="ghost">` in the card's controls chrome (already fenced: contentEditable=false,
  stopEvent + ignoreMutation cover it); action editing lifts the bpAction pattern. HARD
  shape contract: media=`{type:"image",src,alt?}`, action=`{type:"action",href,label,
  priority?}` present-only. bp-change detail is a STRING — map it, never write the bare
  value. `type:"action"` has NO server-side normalize net (media does) — dropping it
  renders nothing in email while tests stay green. Priority is KEPT (compose.ex:357 +
  walk.ex already render it on both surfaces) but present-only (nil≡secondary zero-op).
- **D-W2-4 — ct-rollout rescoped to the verified corpus truth.** task-list live-data is
  ALREADY applied (8/8 real task-lists carry query; zero legacy ones exist). Dedicated
  nodes for task-detail/board/roadmap are PARKED (they appear ONLY in portabledoc-showcase;
  zero organic usage — speculative). The real debt: legacy cards/notes/pipeline in exactly
  4 real papers — composition-doctrine-plan, parity-state, provider-horizon, wave-deck
  (NOT the digest's 11; portabledoc-showcase is an intentional parity fixture, the wave
  paper is ephemeral). Build a doctrine_backfill.ex-shaped migration (scan → pure plan →
  dry-run default → --apply, additive, idempotent, byte-parity-proven per block or skip+
  report). Crown: composition-doctrine-plan itself migrates.
- **D-W2-5 — email section-grid becomes a DESIGNED degrade (new slice cd-10).** Verified:
  a grid section in :email emits web-only classes + inert custom props with no stylesheet
  in the email document — accidental silent stack, contradicting render.ex's own
  inline-only Outlook contract. Fix inside the shared seam: style-branch the section clause
  for :email to inline-safe stacked emission honoring per-cell order; :article bytes stay
  byte-identical. Also correct the stale compose.ex comments claiming the TUI collapses
  grid→stack (PR #1410 shipped real TUI grid).
- **D-W2-6 — cd-5 ledger honesty: split, don't fake.** cd-5's Constraints half shipped
  (#1244); its Template-generalization half was never built anywhere (template.ex untouched
  since pre-epic). cd-5 stays done for what it did; the owed half is now the honest open
  child `cd-5b-template-generalization` (backlog).
- **D-W2-7 — D1-D3 pins re-verified, zero drift.** Elements-only slots, structured grid,
  constrained-types-first: all enforced + tested at HEAD. No re-litigation.
- **D-W2-8 — web section-grid parity and the section golden layout leg are filed, not
  built.** web/portable-doc.tsx ignores section layout entirely (separate SDK-consumer
  producer by design), and no section golden exists — real gaps, but off the card-loop
  critical path. Backlog: cd-11, cd-12.

## Roadmap

Wave 2 (this wave — 5 slices, integration-ordered):
1. **cd-7-card-surface-parity** (small, opus) — email golden-twin realization leg in
   component_golden_parity_test.exs; test-only, .exs waits Elixir Test.
2. **cd-8-card-authoring** (medium, fable) — /card in slash+palette (3 registries, lockstep
   test) + grid-of-cards compound-insert starter; JS only.
3. **cd-9-card-full-editing** (medium, opus) — bp-media-picker + action editor in
   card-node.js controls, shape contract preserved; JS + smoke.
4. **cd-10-email-section-grid** (small, opus) — designed email degrade for grid sections +
   stale-comment fix; .ex waits Elixir Test.
5. **ct-rollout** (large, fable) — legacy cards/notes/pipeline → widget-composition
   migration mix task (dry-run first), then lead-gated --apply on guerrilla's 4 real
   papers; crown = composition-doctrine-plan on the new widgets.

Backlog (filed, published, not this wave):
- **cd-5b-template-generalization** (p2) — the general Template capability (save any node
  at any tier as reusable master, linked/detached) — plan §4 mechanism #3, cd-5's owed half.
- **cd-11-web-section-grid-parity** (p3) — web portable-doc.tsx renders section
  layout (grid tracks/span/order) or a designed degrade, with tests; coordinate with
  p-web-tsx (sibling epic parity-s7-identical).
- **cd-12-section-golden-layout-leg** (p3) — add a `section` entry + layout projection to
  gen_golden_parity + realization asserts in all 3 owning test files; makes plan step-6's
  literal "layout across surfaces" true.
- **ct-tasknodes-dedicated** (p4) — dedicated editable nodes for task-detail/task-board/
  roadmap; parked until real corpus demand exists (today: showcase-only).
- **cd-gov-required-checks** (p3) — GitHub required_status_checks on main for mix-test (at
  minimum) so the golden/parity gates become mechanically blocking.

## Wave log


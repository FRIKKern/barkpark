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

### Wave 3 decisions (2026-07-13) — finish the two filed section-layout legs

- **D-W3-1 — reconciliation: cd-10 and the cd-5 split are DONE on main; do not re-touch.**
  Verified five ways (survey `cd10-reconcile`: 30 tests pass in section_layout_test.exs;
  the `_layout when style != :article` degrade branch is live at compose.ex:394-395). The
  cd-5 Constraints half shipped (#1244); its owed Template half stays the honest open child
  cd-5b. This wave's genuinely-open, filed-not-built work is exactly cd-11 (web render) +
  cd-12 (section golden leg), plus one concrete bug (media-picker asset-JSON src). The
  wish's framing of cd-10 as unbuilt is wrong.
- **D-W3-2 — the shared layout-projection SHAPE is authored-echo, breakpoints EXCLUDED.**
  Handed identically to cd-11 and cd-12:
  `{"container_role":"section","mode":"grid","tracks":N,"gap":"md","cells":[{"span":S|null,"order":K|null,"type":"<child-type>"}]}`.
  It echoes AUTHORED span/order (the literal integers the author wrote), NOT rendered bytes,
  because the surfaces intentionally diverge on render: Elixir :article emits
  `grid-column:span 3` UNCLAMPED (compose.ex:1540 guards `n>0` only) while Go clamps span to
  `[1,tracks]` (joincols.go:327-329) — PROVEN by running both (`cellSpan(3,tracks:2)=2` vs
  literal `span 3`). A projection built from rendered bytes would bake that difference into
  the gate and red it. Breakpoints are excluded because only Go honors them — Elixir :article
  renders byte-identical HTML with and without an authored breakpoints array
  (`IDENTICAL_BYTES=true`), using one fixed `@media(max-width:720px)` collapse; web honors
  nothing. Breakpoints stay a Go-only superset, out of the shared projection.
- **D-W3-3 — the section fixture authors all spans ≤ tracks (plus an order:-1 child).** At
  span≤tracks, Elixir-unclamped == Go-clamped, so every cross-surface realization assert is
  clean. Order (including negatives) is honored identically on both surfaces, so the fixture
  carries an `order:-1` child to exercise ordering. span>tracks is safe ONLY in a
  projection-only (authored-echo) assert and is NOT used this wave — no cross-surface
  rendered-equality assert may run on a span>tracks child, or the new gate reds on a
  pre-existing intentional difference.
- **D-W3-4 — cd-11 web renders a REAL CSS grid, not a degrade; responsive via the reader's
  exact model.** The Elixir reader and Go TUI both render the real grid; a web degrade would
  be a THIRD behavior and defeat "renders as a REAL CSS grid on the web demo, exactly as it
  already does on the Elixir reader and Go TUI." Mechanism (survey `cd11-web-render`): web
  does NOT import paper-surface.css (layout.tsx imports only globals.css), so cd-11 injects a
  two-rule CSS block —
  `.bp-section__grid{display:grid;grid-template-columns:repeat(var(--bp-tracks,2),minmax(0,1fr));gap:var(--bp-grid-gap,1.6rem)}`
  + `@media(max-width:720px){.bp-section__grid{grid-template-columns:1fr}}` — via the in-file
  React-19 hoisted `<style href precedence="default">` precedent (portable-doc.tsx:741,
  deduped to one head emission). Section renders `className="bp-section__grid"` with inline
  custom props `--bp-tracks:N;--bp-grid-gap:…` (never the grid-template declaration itself,
  so the 720px MQ is free to override → graceful mobile collapse for free), one
  `bp-section__cell` wrapper per child carrying inline `grid-column:span N;order:K`. Span is
  UNCLAMPED to match the reader (CSS clamps at layout time; the golden gate encodes authored
  intent, so unclamped render does not trip it). NOT static `sm:grid-cols-N` (inline
  grid-template would beat the utility class), NOT container-query, NOT JS breakpoint. The web
  `columns` case (portable-doc.tsx:1180-1201) is itself non-responsive inline-grid — cd-11
  must NOT copy that pattern.
- **D-W3-5 — cd-12 is scoped to the CORE gate; the web render-realization leg is split out as
  cd-12b, sequenced last.** cd-12 = add `section` to gen_golden_parity `types/0` +
  `@section_input` + `section_projection/1`, regenerate all 3 mirrors, and land HAND-WRITTEN
  realization asserts on Elixir (via `raw_html/1`, the columns/terminal container precedent —
  `section` is a Compose container → `_raw` html, NOT a `Components.*_html` emitter), Go (via
  `renderComponent`, asserting child prose + ordering only — NOT the authored span integer,
  the span-clamp carve-out analogous to the colour carve-outs at component_golden_test.go
  L494-498), and the web PROJECTOR leg C1 (`sectionProjection` in component-projections.ts
  registered in S2_CASES → `deepEqual` against the golden). cd-12b adds the web
  RENDER-realization leg C2 (drives the real `renderBlock` against section.golden.json) — it
  needs BOTH cd-11's render AND cd-12's fixture merged, and it touches the same
  component-golden-parity.test.ts file as cd-12's C1, so it is sequenced strictly after both.
  This is what makes plan step-6's literal "the parity gate covers layout across surfaces, not
  just content" TRUE for the web surface — the last surface that silently ignores block.layout.
- **D-W3-6 — the media-picker asset-JSON bug (task-dec3959cd2a1cc35) fixes card-node.js
  ONLY.** onMediaChange writes `coercePickerValue(e.detail)` (a pure identity fn) straight
  into `attrs.media.src`; on an asset-library pick the picker emits `JSON.stringify({url,
  assetId})`, so `src` becomes the literal JSON blob → broken `<img>`. Fix: read
  `e.target.meta.url` (the picker's public parsed accessor, bp-media-picker.js:165-167), with
  a JSON-tolerant fallback — the exact precedent root.html.heex:5746-5769 already uses. Do NOT
  touch field-node.js's `coercePickerValue`: the field-image path's identity-coercion is
  correct BY DESIGN (its render path is JSON-tolerant via `media_field_url/1`) and is pinned by
  field-pickers.mjs smoke; the card path is the sole defect because it reused a coercion built
  for a JSON-tolerant destination and pointed it at a JSON-intolerant one. Fail-before test:
  extract a pure `mediaUrlFromValue(raw)` helper, smoke-assert JSON-in → url-out.

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

Wave 3 (this wave — finish the two filed section-layout legs, 4 slices; opus-only, Fable
exhausted). Wave paper: `composition-doctrine-wave-2026-07-13`. Coupling: cd-11 ∥ cd-12
build in parallel (disjoint files); cd-12b sequenced after BOTH; media-picker independent.
1. **cd-11-web-section-grid-parity** (medium, opus) — web portable-doc.tsx `case "section"`
   renders a real CSS grid (custom-prop + 720px MQ per D-W3-4) + a self-contained fail-before
   web test; JS-only, does NOT wait Elixir Test. Parallel.
2. **cd-12-section-golden-layout-leg** (large, opus, capstone) — `section` type +
   authored-echo `section_projection/1` (D-W3-2/3) in gen_golden_parity, regen 3 mirrors,
   Elixir + Go realization asserts + web projector leg C1; .ex/.exs wait Elixir Test. Parallel.
3. **cd-12b-web-section-render-realization** (small, opus) — web RENDER-realization leg C2
   in component-golden-parity.test.ts, driving the real renderBlock against section.golden.json;
   sequenced after cd-11 + cd-12 merge. JS-only.
4. **cd-card-media-picker-asset-json-src** (task-dec3959cd2a1cc35) (small, opus) — parse the
   serialized `{url,assetId}` picker value in card-node.js (D-W3-6); JS + smoke. Independent.

Backlog (filed, published, not this wave):
- **cd-5b-template-generalization** (p2) — the general Template capability (save any node
  at any tier as reusable master, linked/detached) — plan §4 mechanism #3, cd-5's owed half.
- **ct-tasknodes-dedicated** (p4) — dedicated editable nodes for task-detail/task-board/
  roadmap; parked until real corpus demand exists (today: showcase-only).
- **cd-gov-required-checks** (p3) — GitHub required_status_checks on main for mix-test (at
  minimum) so the golden/parity gates become mechanically blocking.

## Wave log

**Wave 3 (2026-07-13) — DECIDED, building.** Finish the two filed section-layout legs +
one bug. Two rounds of ground truth proved the fixture-design pivot: the shared golden
projection MUST echo AUTHORED span/order (Elixir :article emits `grid-column:span 3`
unclamped; Go clamps to tracks — same input, different bytes), and breakpoints stay a
Go-only superset (Elixir renders byte-identical HTML with/without a breakpoints array). Web
does not import paper-surface.css, so cd-11 injects the reader's exact `.bp-section__grid`
rule + 720px collapse MQ via a React-19 hoisted `<style precedence>`; span unclamped to match
the reader. cd-12 is scoped to the core gate (generator + fixture + Elixir/Go realization +
web projector C1); the web render-realization leg is split out as cd-12b, sequenced after
cd-11 + cd-12. Slices: cd-11 ∥ cd-12 (disjoint files) → cd-12b (after both); media-picker
bug independent. All opus (Fable exhausted). cd-10 email degrade + cd-5 split confirmed DONE
on main — not re-touched.


# Epic: studio-ui-premium — Studio UI premium overhaul

> NOTE ON THIS PATH: the former "Barkpark Cloud — Peak Aesthetics, UX and DX" charter that
> lived at this filename was preserved verbatim at
> `.claude/workflows/bp-cloud-peak-aesthetics-charter.md` (and in git history, 75951d8f).
> `bp-cloud-console-charter.md` references its parent by this old path — read the
> preserved copy. This file is now the memory of the **studio-ui-premium** epic.

Epic bp task: `studio-ui-premium` (published; every slice task is its child).
User verdict at kickoff: current Studio UI is 3/10. Bar: the new Claude Code TUI / Linear / Sanity-class tools.

## Vision

Studio reads premium in the first three seconds. A quiet icons-only top bar — every nav
entry a Lucide glyph with tooltip + aria-label — and the workspace scope condensed to one
compact chip driving its existing Miller-columns popover. A desk tree that is instantly
legible because every document type wears its own always-visible icon from ONE resolution
authority. No native browser control anywhere in Studio: every select, checkbox, toggle
and input rides a shared themed control kit, and all text meets WCAG AA against the actual
theme background in all three themes × light/dark. Layout quality is structure, not
decoration — card/panel surfaces with consistent radius+border tokens, 8px spacing rhythm,
weighted section headers, aligned label/control columns. Settings is the flagship rebuild
(it is the 3/10 artifact); every other screen follows on the same kit.

## Decisions

- **D1 — Icons-only top bar rides the existing dormant channel.** Populate `icon:` on all
  host nav entries in `nav.ex` (today all `nil`: lines 424/431/438/459/494/505/523) and teach
  `studio_tabs/1` (nav.ex:315-358) to render `<.icon>` + `title`/`aria-label` instead of the
  text label. No parallel channel, no plugin-registry contract change — `tab.path` is
  pre-built via Paths, so zero studio-link-lint exposure. *Why: exploration proved the field
  exists on the type and the renderer simply ignores it; populating it is the minimal true fix.*
- **D2 — Icon-less plugin entries degrade gracefully.** A plugin `top_menu_entry` with no
  `icon:` (or an unknown name) renders the generic glyph with the label as tooltip +
  aria-label. `icon` stays optional in the plugin contract (plugin.ex:202). *Why: the label
  survives as the accessible name regardless; a contract change buys nothing and risks every plugin.*
- **D3 — Compact scope chip = restyle, not rebuild.** The "Default Workspace · Default
  Project / production" run is ALREADY a chip+popover (`WorkspaceSwitcher.switcher`,
  workspace_switcher.ex:53-66) with full LiveView plumbing (scope-menu-toggle/ws/proj,
  scope-open → push_navigate). The slice condenses the trigger's markup/CSS only and keeps
  every event and the Miller-columns popover intact. The native `<select>` fallback in
  `dataset_switcher.ex:22` gets themed in the same slice. *Why: exploration falsified the
  "plain text run" premise; rebuilding the working switcher is pure regression risk.*
- **D4 — Tree "collapsed by default" is architecturally already satisfied — declared no-op.**
  The desk is a multi-pane drill-down (Sanity-style): sub-lists NEVER render inline, they
  appear only as the next column. `Structure.Node` has no expanded field, nor does the
  `/v1/structure` wire or the Go client. There is nothing to flip. If the user actually wants
  an inline nested tree, that is a pane-model replacement requiring an explicit new decision —
  never file a flag-flip task for this. *Why: explorer verified no expand/collapse state
  exists anywhere in the pipeline.*
- **D5 — Tree icons: emoji stay on the wire; icons.ex is the single resolution authority.**
  Fix = complete `@emoji_map` (📰 📊 🎫 🧩 🗂, remap ✅ → check-square, 📑 → a distinct
  page glyph) and add the missing Lucide paths (~14: newspaper, table, ticket, puzzle,
  folder-tree, columns, kanban, check-square, zap, github, clock, sticky-note…). NO change to
  `structure.ex` icon VALUES. *Why: the Go TUI's `terminalIcon` (structure.go:189-196) keeps
  emoji and DROPS ASCII Lucide names — names on the wire would strip every TUI desk icon.
  Emoji-on-the-wire keeps this a 1-surface Studio slice (au-w5 classification).*
- **D6 — Control kit = wrap the EXISTING CSS primitives into `StudioComponents.Controls`
  function components.** root.html.heex already ships tokenized `.btn` family, `.card`/
  `.card-header`, `.form-input` (incl. themed `select.form-input` with SVG chevron),
  `.form-switch`, `.form-checkbox`. The kit wraps these as `bp_select` / `bp_checkbox` /
  `bp_switch` / `bp_input` / `bp_field_row` / `bp_card` / `bp_section_header`; screens
  consume the components going forward (the classes remain the styling substrate).
  FieldInputs stays editor-form-specific — reference, not the kit. *Why: the visual language
  exists; the 3/10 comes from screens bypassing it. Wrapping once ends per-screen drift.*
- **D7 — Settings is the flagship adoption target and rebuilds FIRST.** settings_live.ex is
  100% native controls + inline-style divs + `ui-sans-serif` font. Rebuild on the kit:
  `var(--font)`, card sections, weighted section headers, aligned label/control rows, zero
  native controls. MUST preserve the freshly-landed scoped route
  (`/w/:ws/p/:proj/studio/settings`), fail-closed write guard, plugin-toggle and
  typeless-feedback logic (#1981/#2038/#1997). *Why: the page the user named, and mostly
  adoption not invention — highest ROI per hour.*
- **D8 — Contrast fixes land in the token manifest, not per-screen.** Verified token defects:
  `--fg-dim` fails AA on `--bg` in ALL six theme×mode combos (2.53–3.90) yet paints settings
  hints and placeholders; evergreen-light `--muted-text` on `--muted-surface` is ~4.39 (<4.5).
  Fix: raise `--fg-dim` L to clear 4.5:1 everywhere (still the dimmest text tier), nudge the
  evergreen-light muted pairing, and add `--surface-raised` + `--border-subtle` semantic
  tokens (dark `--surface` 5.5% L barely separates from `--bg` 3.9% — cards have no visible
  elevation). *Why: the grays are already tokens (studio-literal-check is green); the token
  VALUES are the defect.*
- **D9 — New chrome tokens follow the 3-file lockstep.** `design/tokens.json` (evergreen
  reference values) + `derive.mjs` (`STUDIO_II` anchor + formula) + `emit.mjs`
  (`CHROME_ALIASES`), then `node design/emit.mjs --write`. tokens_gen.ex stays byte-stable
  (chrome vars never enter it). Zero new lit-allows. *Why: skipping derive.mjs breaks the
  derive(evergreen)===tokens byte-identity proof (check.mjs Part F) and reds CI.*
- **D10 — Chat is a layout NO-GO zone this epic.** bp-studio-chat-excellence wave 9 is in
  flight with immovable client contracts (form#chat-composer-form, input#chat-composer) and
  test-pinned selectors. Chat inherits token-value fixes automatically (fully tokenized);
  its native selects/buttons are swept in a LATER wave, coordinated with that epic. Same
  restraint for literal-check-EXEMPT files (modals.ex color picker, paper_editor.ex): their
  native controls are fair game later, their approved hex literals are not.
- **D11 — Evidence = LiveViewTest HTML assertions; screenshots are an authenticated add-on.**
  Every screen has a `live/2` test harness rendering full HTML with no server boot.
  Before/after proof is committed test assertions (`refute html =~ ~s(<select` /
  `assert html =~ "bp-select"` style). guerrilla Studio is login-gated — never write a
  criterion assuming an anonymous screenshot.

### Wave-2 decisions (2026-07-10)

- **D12 — Worktrees branch off `origin/main`, never local HEAD.** The wave-2 exploration
  caught the primary checkout one commit behind origin/main — and that commit WAS the entire
  wave-1 merge (#2067, 3e315eaf): no Controls kit, no new tokens, pre-rebuild settings in the
  local tree. Every builder cuts their worktree from `origin/main` after `git fetch` (or runs
  `make update` first). A builder on local HEAD rebuilds wave 1 by accident. *Why: three of
  four explorers independently hit this trap; it is the single biggest wave-2 failure mode.*
- **D13 — Sweep scope corrected by the control census: FOUR real native-control surfaces,
  not eight.** Genuine targets: `sheet_grid.ex` (~14 controls in LiveView forms),
  `modals.ex` (airdrop radios/checkboxes — verified naked native inputs inside styled
  `.airdrop-chip` labels), `admin/plugin_settings_live.ex` (4 unclassed field renderers),
  `paper_editor.ex` add-block/add-property chrome selects (:353/:939 — the block/property
  VALUE fields with `bp-paper-edit-*` classes are the paper edit design language and stay).
  Confirmed DONE or out: settings_live (wave-1 rebuilt, residual inputs all `type=hidden`),
  dataset/workspace switchers (D3), session_html login pages (already `form-input` +
  `bp-auth-*` — skip this wave), `/activate` (serves the cloud SPA, no HEEx form),
  api_tester + studio_live/components (already `form-input`, cosmetic kit conversion
  deferred to wave 3), `fields/*` + `field_inputs.ex` (editor-form value renderers, D6
  fence holds), media/projects/graph (zero native controls). *Why: the kickoff grep counts
  were taken pre-wave-1 and inflated by comments, hidden inputs, and already-themed sites.*
- **D14 — `bp_radio` is the ONE new kit primitive; visually-hidden swatch radios are
  exempt.** The modals slice builds `bp_radio` (name/value form-submission semantics
  preserved — the airdrop tests drive by form params) and adds it to the styleguide
  `sg-controls` gallery in the same PR, keeping the gallery the living spec. Radios that are
  already visually hidden behind custom swatch UI (sheet CF bg swatches `sr-only`
  sheet_grid:2721, profile color `display:none` modals:730) are documented exemptions — the
  browser never paints them. `bp_file` (one call site) deferred. *Why: census proved
  bp_textarea/bp_checkbox already exist; radio is the only real gap.*
- **D15 — Contrast becomes a MACHINE GATE; residual fixes are pairing-level, not token
  nudges.** New Part in `design/check.mjs`: `import { contrast } from "./derive.mjs"`, run
  `derive()` per committed theme, assert a CURATED table of real DOM fg×surface
  co-occurrences (per-entry `kind`: text ≥4.5, non-text/icon ≥3.0; loud skip if a theme's
  derive throws). NEVER the cartesian product — phantom pairs would false-red the gate.
  D8's "fix in the token manifest" doctrine is hereby BOUNDED: `--bg-accent` (92% L light)
  cannot host any dim tier at AA, and darkening `--fg-dim` further would collapse it into
  `--muted-text` (L47 vs L45). The live sub-AA defects (`.pane-doc-badge` fg-dim on
  bg-muted 4.05–4.27; `.pane-doc-item.selected` inherited fg-dim on bg-accent 3.89–3.94;
  hover rows) are fixed with explicit `color:` at the pairing site. *Why: the gate is this
  epic's version of the unified-aesthetic drift gate — it locks wave-1's wins and red-proofs
  the layout slice's `--surface-raised` adoption (fg-dim on surface-raised = 4.28
  evergreen-dark, a regression waiting to ship).*
- **D16 — Desk boldness lands WITHIN D4 — no pane-model amendment this wave.** The
  drill-down is moderately lackluster, not structurally broken; the #1 "unfinished dev tool"
  tell is the raw mono doc-id under every row title. Fix set (all Studio-side, zero
  /v1/structure wire change, zero Go TUI ripple): (1) row subtitle = existing `:meta`
  (list_preview/manifest description) with humanized `updated_at` fallback (timestamp
  already on every struct — pane_builder just passes it), doc-id demoted to hover `title=`;
  (2) pane-header item count ("Posts · 12", filtered to `:doc` items — the list also holds
  :divider/:header/:plugin_link); (3) doc-list empty branch swaps its inline-styled text for
  the existing iconed `pane_empty`/`.empty-state` component; (4) panes adopt
  `--surface-raised`/`--border-subtle` (defined in all 6 theme×mode combos, consumed by ONE
  rule today — wave-1's elevation promise is unshipped until panes consume them); (5)
  hover-revealed drill chevron on doc rows + 8px padding rhythm. Structure-pane node VALUES
  (icons/titles) untouched (D5). An inline-nested-tree / resizable-columns amendment is
  BANKED for wave 3, only if the desk still reads flat after this. *Why: explorer verdict —
  headers, row anatomy, and empty states buy most of the perceived premium; the pane model
  is not the problem.*
- **D17 — Test-drift is a first-class acceptance criterion on every task.** Each brief names
  the exact pinning tests up front; the builder runs `mix test test/barkpark_web/` in the
  worktree BEFORE handing to review. Known drift set: sheet fmt-select mirror test
  (studio_live_sheet_grid_test.exs:2162-2177 — survives if `data-test-id` + `<option
  selected>` semantics are preserved through the kit's `:global` rest), the paper_editor
  BYTE-IDENTICAL golden `snapshots/paper_editor_flag_off.html` (MUST be re-baselined and the
  diff eyeballed — the single highest-drift artifact), pane markup pins
  (studio_components_pane_test.exs:293-296 `pane-doc-id`+`p1`, panes_test.exs:85,
  studio_live_task_realtime_test.exs:111 `.pane-doc-badge`, resolver_outputs_test.exs:237
  exact `pane-item-label">Plugins</span>`). Chat is a separate blast radius (chat_live
  imports none of the sweep files) — D10 holds. *Why: wave 1 shipped 5 stale-test reds; this
  wave pre-names every one.*
- **D18 — Layout-rhythm targets narrowed to the two real offenders.** org_admin_live.ex is
  the ONE genuinely flat screen (1 CSS class, 13 inline `style=` attrs, hand-rolled buttons,
  ✓/— text glyphs) — it gets the full D7 treatment on the kit. Desk panes get D16. SKIPPED
  as already premium or surface-less: board_live (fully tokenized, inline styles are dynamic
  geometry only — touching it is pure regression risk), media_live (60-line WC host),
  graph_view (canvas host), api_tester (already rides the pane kit + coherent `.api-*`
  system; its inline scenario-row divs ride along with its wave-3 cosmetic conversion).
  *Why: layout audit falsified "give six screens the treatment" — four of six have nothing
  to treat.*

### Wave-3 decisions (2026-07-10 — the closing wave)

- **D19 — The D16-banked pane-model amendment is REJECTED, both variants; D4 is now a
  permanent fence for this epic.** The licensed decision, made on the authenticated pixel
  evidence: the desk STILL reads flat on 5 of 6 theme×mode combos — but the cause is
  measured and token-level, not structural. ΔL(--surface-raised, --bg) dark: evergreen
  0.0695 (visible), ember 0.0157 (invisible), fjord 0.0258 (barely); `--border-subtle`
  INVERTS on ember dark (−0.009 — the hairline is darker than the bg) and vanishes on
  fjord; light mode is near-flat on all three. Meanwhile the w2 row anatomy (header counts,
  status dots, bold title + dim subtitle, demoted doc-id, iconed empty states) reads
  genuinely premium, and org-admin's bp_cards prove elevation-via-`--border` works. So:
  (a) **inline nested tree — rejected**, and on CORRECTED grounds: NOT "it needs a wire
  change" (the /v1/structure wire already serializes the full nested tree recursively via
  node_json; expand state could stay client-side) but because it is a multi-file Studio
  rendering-MODEL rewrite (PaneBuilder.walk_path's Miller-columns list → recursive nested
  rendering across pane_builder.ex, studio_live.ex, components.ex, panes.ex), contradicts
  the drill-down D4 deliberately kept, and diverges the Studio desk from the Go TUI desk
  that renders the SAME structure as drill-down columns (GUI/TUI parity break).
  (b) **resizable pane columns — rejected**: provably cheap (width is a CSS constant,
  root.html.heex `.pane-column` 260px; zero wire, zero TUI; localStorage precedent exists)
  but the build-license condition — "pixels show cramped columns as a real defect" — was
  NOT met; 260px × 3-4 visible columns reads generous. Building it would be treating a
  token symptom with a pane sledgehammer. The desk's premium finish ships as D20 instead.
- **D20 — Elevation becomes bg-RELATIVE in the dark rung (fit-first, evergreen
  byte-identical).** Root cause: STUDIO_II in derive.mjs gives `--surface-raised`/
  `--border-subtle` a FIXED absolute OKLCH L for dark (0.210/0.185) while per-theme dark bg
  L differs (evergreen 0.1405, ember 0.1943, fjord 0.1842) — elevation anchored to an
  absolute, not to the ground it sits on. Fix: the DARK bindings move to
  `L = srgbToOklch(skin.dark.bg).L + ΔL` with ΔL EXACTLY 0.0695 (surface-raised) and
  0.0445 (border-subtle) — these 4-sig-fig constants empirically reproduce evergreen's
  committed bytes ("157.32 13.06% 8.96%" / "157.18 13.11% 6.89%") so Part F stays green
  with zero override-count churn (0.069 and 0.070 both DRIFT the byte and red the gate).
  Light rung stays absolute BY DESIGN (light bg ≈0.99-1.0 everywhere; light elevation
  rides border+shadow — say so in the PR to preempt the reviewer question). SAME-LEVER
  EXTENSION: `--bg-accent`/`--border-muted` carry the identical fixed-absolute-L bug
  (selected rows RECEDE on ember/fjord dark, ΔL −0.028/−0.018) — convert them the same
  way IF evergreen byte-identity is empirically provable; otherwise drop them from the PR
  with a written reason (never pin — no override-count churn). Part H is value-driven
  (re-derives live) so the token nudge needs NO table edit, but the gate must re-run
  green: all 6 surface-raised pairings pre-verified to hold (tightest: ember scope-caret
  nontext 3.969 ≥ 3.0; ember muted-text 5.449 ≥ 4.5).
- **D21 — "api_tester + studio_live/components cosmetic sweep" scope corrected:
  studio_live/components is a NO-OP.** The directory holds ONLY paper_editor.ex; its
  chrome selects were converted in w2 and every remaining native control is a fenced
  `bp-paper-edit-*` VALUE field (D11/D13 — the paper-edit design language). The real
  sweep is api_tester alone: components.ex :85/:99 → bp_input, :93-97 → bp_select
  (value-match selected), :106 → bp_textarea — which requires a small ADDITIVE kit
  extension (bp_textarea gains a `class` passthrough + `spellcheck` in :rest, else the
  `api-body-textarea` sizing and spellcheck=false silently vanish). The scenario-results
  inline styles carry a HIDDEN AA DEFECT: `var(--fg-dim)` on `var(--bg-muted)` inline
  (4.05–4.27, sub-AA) is INVISIBLE to Part H (which parses root.html.heex selectors) —
  extraction to classes escalates the text to `--muted-text` AND adds the new pairings to
  Part H in the same PR (COUPLING LAW). The dynamic verdict-fail row background stays
  dynamic (modifier class/data-attr). api_tester has ZERO markup-pinning tests today, so
  the brief pre-names a NEW protective render test (distrust vacuous green). tmux polish:
  SKIPPED — no form controls at all (xterm host); gold-plating.
- **D22 — Styleguide gallery DOM becomes the spec: render the real kit components.**
  sg-controls swaps raw class primitives for actual `<.bp_input>` / `<.bp_select>`
  (exercising prompt + optgroup so the gallery documents them) / `<.bp_textarea>` /
  `<.bp_checkbox>` / `<.bp_radio>` / `<.bp_switch>`. Known pin drift, pre-named:
  styleguide_live_test.exs :117/:118/:119 BREAK (kit inserts name=/id= attrs) and are
  rewritten to kit attribute order; :122-125 (form-checkbox/switch/track/state) SURVIVE;
  a bp_radio assertion is ADDED (none exists). Kept a SEPARATE slice from api_tester:
  disjoint pin-sets, and isolating the AA-correctness risk (api_tester) from the pure
  mechanical swap lets this land trivially.
- **D23 — The last genuine native control + the exemption register.** Post-#2088 census:
  the ONLY naked, non-exempt, non-chat native control left in Studio is
  `shares_modal`'s `surfaces[]` checkboxes (modals.ex:139-144, class-less labels — the
  airdrop sibling was swept in w2, this one was missed). It converts to bp_checkbox with
  form-param semantics preserved; THIS is the criterion-2 blocker, not api_tester
  (form-input-classed = cosmetic) or the styleguide (spec-fidelity). NEW DOCUMENTED
  EXEMPTION: the airdrop custom-expiry `<input type="datetime-local">` — browsers paint
  native date chrome inside any styled box; a custom JS date component is out of scope
  for a closing wave. It joins the register: chat (D10 NO-GO), sr-only swatch radios
  (D14), `bp-paper-edit-*` value fields (D11), fields/* + field_inputs (D6),
  `type=hidden` inputs, the kit substrate itself. session_html login pages VERIFIED
  at-bar (zero native controls, form-input + bp-auth-* throughout) — no login pass, don't
  gold-plate. The chat control sweep leaves this epic entirely: criterion 2 says "chat
  excluded", the chat epic owns its own sweep.
- **D24 — QA close-out operational definitions (the epic's exit is stamped, not
  vibed).** (a) The native-control census greps for the ABSENCE of the form-*/bp-* class
  family, NEVER tag presence — bp_select itself emits `<select class="form-input">`; a
  tag grep false-reds the kit, fields/*, and the styleguide. (b) Criterion 3's
  operational definition: Part H machine-covers every real fg×surface co-occurrence the
  epic touched (extended in the close-out for anything missed); the residual — text on
  legacy screens the epic never touched — is flagged HONESTLY in the evidence, not
  claimed. (c) Criterion 4 (user re-verdict) is a HUMAN GATE: the close-out produces the
  authenticated pixel pack and surfaces it to the user; it is never agent-stamped.
  (d) graph_view + swatch_live have NO live() harness — documented canvas/tool
  exemptions, not new harnesses in a closing wave. (e) The repeatable pixel-evidence
  harness, now proven agent-drivable: admin bearer from ~/.config/barkpark/config.json →
  `POST /v1/auth/login-tickets` → browse `GET /login/ticket/:t` (session cookie,
  redirects to /studio); both theme axes client-overridable from one session
  (`document.documentElement.dataset.theme` + `dataset.bpTheme`) since all theme CSS
  lives in root.html.heex — all 6 combos from one login. Builders should ALSO set the
  workspace theme server-side once to eyeball the server-stamped path.
- **D17 pin-set corrections (post-#2088; briefs use THESE, not the D17 originals):**
  pane-doc pins moved to studio_components_pane_test.exs :295 (`pane-doc-sub`), :297
  (refute `pane-doc-id`), :299 (`title="p1"`); pane-column markup pins at :36/:53/:56/:69;
  panes_test.exs:85 and studio_live_task_realtime_test.exs:111 unchanged; the
  resolver_outputs pin's REAL path is `api/test/barkpark_web/integration/
  resolver_outputs_test.exs:237` (charter had a wrong path); EXTRA pin not in the D17
  list: studio_live_empty_pane_test.exs (pane_empty no-documents hint).

### Wave-4 decisions (2026-07-10 — desk structure consistency; user directive: "styling is a bit weird — Projects on first pane has more opacity than others")

- **D25 — THE DESK ROW-STATE LADDER (ratified; every pane depth obeys it identically).**
  The user's bug is confirmed in code AND live pixels: `a.pane-item.nav-plugin-entry
  { color: inherit }` (root.html.heex:1005-1010, specificity 0,2,1) beats `.pane-item
  { color: var(--fg-muted) }` (:953, specificity 0,1,0) and resolves up to `body
  { color: var(--fg) }` (:409) — plugin-link rows (Projects) paint at full `--fg` while
  sibling rows sit at `--fg-muted` (measured live on guerrilla: rgb(242,242,242) vs
  rgb(161,161,170) dark; inverted in light). More broadly, THREE base-color mechanisms
  coexist (explicit fg-muted / inherit-to-body / uncolored doc titles). The ladder:
  - **Plain**: row label/title `--fg-muted`, weight 500 (`.pane-doc-title` gains explicit
    `color: var(--fg-muted)` — today it inherits body `--fg`; AA pre-verified 4.57–5.02
    on all grounds). Doc subtitle stays `--fg-muted`. Chevron hidden (opacity 0).
  - **Hover**: `--bg-muted` fill + ONE tier color lift → label/title `--fg` (doc rows
    ADOPT the lift — today fill-only; nav rows already do this). Subtitle stays muted.
    Chevron revealed (opacity 1).
  - **Selected** (leaf AND trail): `--bg-accent` fill + `--primary` border-left bar +
    text `--fg` (subtitle escalates to `--fg` per :1049). **AA FENCE: no muted tier ever
    sits on `--bg-accent`** — measured 4.16 evergreen-light, sub-AA; shipped code already
    obeys, the ladder must never regress it.
  - **Active-trail IS `.selected` on an ancestor pane — same class, same treatment;
    the pane ground (bg-card ancestor vs surface-raised focus pane) is the ONLY
    differentiator, and that is DELIBERATE.** No new trail state/class, no
    `:not(--last)` scoped calmer variant — exploration proved this is already the live
    mechanism and the ground separation reads. Revisiting requires pixel evidence.
  - **Link rows are not a visual state**: `a.pane-item.nav-plugin-entry` gets explicit
    `color: var(--fg-muted)` (the one-rule fix). The `nav-plugin-entry` class STAYS
    (resolver_outputs_test.exs:245 pins its presence). Hover/selected ride `.pane-item`
    rules unchanged.
  - **Chevrons: hover-reveal is the ONE vocabulary (w2/D16)**: `.pane-item-chevron`
    adopts `opacity: 0` → 1 on hover/selected (CSS-only; markup + ordering pins at
    studio_components_pane_test.exs:220-223 preserved). Plugin-link rows GAIN the same
    chevron span in the `:plugin_link` branch (components.ex:655-665) — live pixels
    showed Projects missing the affordance its siblings have.
  - **Padding is a deliberate anatomy difference, not drift**: single-line nav rows
    8px 16px; two-line doc rows 10px 16px (via `.bp-doc-row-body`). The DEAD
    `.pane-doc-item { padding: 10px 14px }` rule (root:1013, overridden by
    `padding: 0` at :2455) is REMOVED.
- **D26 — Wave-4 implementation fence: CSS-rule-level only; class names and pane model
  frozen.** Keep `.pane-item` / `.pane-doc-item` / `.selected` / `.nav-plugin-entry` /
  `.pane-item-chevron` / `.pane-doc-chevron` names and markup order — the component pin
  block studio_components_pane_test.exs:176-238 (incl. :192 exact `class="pane-item
  selected"`) and resolver_outputs_test.exs:237+:245 stay green by construction. NO
  shared-base class rename (an additive shared rule is allowed, replacement is not).
  pane_builder selection computation (`selected: Enum.at(rest, 0)` at :68/:240/:267/:319),
  walk_path, and the single render loop are untouched (D4/D19 permanent). ZERO token
  changes: tokens_gen.ex byte-stable, no lockstep run, no new lit-allows. Part H
  COUPLING LAW rows land in the SAME PR: `a.pane-item.nav-plugin-entry` on both pane
  grounds (gating the fixed color against regression) + `.pane-doc-title` on the same
  ground set as the existing `.pane-doc-sub` rows. NOTE: `--primary`/`--primary-fg`
  TOKEN_SLOT mappings ALREADY EXIST (added by #2138, check.mjs:723) — the selected ▎bar
  is a border, which Part H does not gate; no new slot work.
- **D27 — Wave-4 evidence protocol + D24e harness corrections.** Pinning tests land in
  the ladder PR itself (D17): DOM assertions that the unified state classes/colors hold
  per pane depth (structure pane, type pane, doc pane). BEFORE pixels are already
  captured (wave-4 exploration, scratchpad shots: Projects near-white among gray
  siblings, dark+light). AFTER pixels are a separate post-merge slice on guerrilla via
  the D24e login-ticket harness, verifying by COMPUTED STYLE (not eyeball alone) that
  Projects' color equals its siblings'. D24e corrections learned live: (a) set ONLY
  `document.documentElement.setAttribute('data-theme', 'light'|'dark')` — ALSO setting
  `dataset.bpTheme` leaves the cascade half-applied (body color resolves wrong);
  (b) chrome-devtools `take_screenshot` refuses the /private/tmp scratchpad path —
  save under the repo root, then move (leave the repo clean).
- **D28 — Wave 5 is INTERACTION-POLISH, amended in-place, not forked.** The chrome/token/
  contrast/desk work of D1-D27 is done; the residual premium gap is interaction *quality*
  on the surfaces authors live in. Three net-new, file-disjoint slices (D29-D31) are added
  as Wave 5. **Why amend, not fork:** this file IS the epic's memory (D1-D27 + Waves 1-4);
  writing a rival `bp-studio-premium-charter.md` orphans that memory and re-triggers the
  rotating-charter-slot trap. The Decide phase (resumed after a spend-cap) re-proved on
  origin/main @51576f128 that all three slices are OPEN and outside D1-D27 (grep of this
  charter for aria-live/save-status/paper_canvas/doc_actions = zero hits). Reject cosmetic
  churn per the AI-Score finding (only naming/pointer governance measured positive).
- **D29 — Slice A: a11y live-regions on the save-status echo + the flash sink.** Add
  `role`/`aria-live` to `editor.ex:460` `<span class="save-status">` and to the two
  `studio_flash/1` divs in `nav.ex:28/31` (info → `role="status" aria-live="polite"`,
  error → `role="alert" aria-live="assertive"`), mirroring the already-accessible
  `settings_live.ex:402/405` and `editor.ex` banner pattern (`cross_violations_banner`
  :698, `paper_halt_banner` :769). **Why:** `studio_flash` is the single *layout* flash
  sink (both `app.html.heex` + `studio.html.heex` route through it; :app is the default
  live_view layout), so one ~2-attr change makes every layout-rendered Studio flash
  announce to screen readers — highest leverage, lowest risk. **Correction absorbed:**
  it is the single *layout* sink, NOT the single sink — `settings_live` self-renders its
  own flash and is *already* accessible; do not overclaim "every surface." Every Studio
  `put_flash` is `:info` or `:error` (grep-proven tree-wide: 59×error, 3×info, zero other
  kinds), so no kind bypasses the fix. **Test co-change (mandatory):** the span attr
  change breaks two pre-existing string assertions in `studio_live_save_status_test.exs`
  (`class="save-status">Saved`, `class="save-status"><`) — update them in the same edit;
  add a net-new aria assertion there AND a net-new flash-aria assertion for nav.ex.
- **D30 — Slice B: the paper canvas tells the TRUTH about saving.** `paper_editor.ex:371`
  renders a HARDCODED `✓ Auto-saved` that never reflects the real state — it lies through
  "Save failed" and plugin halts. Thread the socket-owned `save_status`/`paper_halt`
  (already computed in `shared/paper.ex`) through the 3-hop chain
  (`components.ex` `studio_paper_view` → `paper_block_editor`), echo the real `@save_status`
  in the existing footer span, and render the reused `Editor.paper_halt_banner`. **Why:**
  the canvas is the highest-value editing surface and currently misreports persistence —
  this is a correctness/honesty fix, not a cosmetic gap-fill, and it brings the canvas to
  parity with the classic editor (`editor.ex:460`). **Two mandatory builder steps:**
  (a) `save_status` is unassigned on fresh paper open (assigned only in write handlers) —
  guard it at the call site (`save_status={Map.get(assigns, :save_status, "")}`), do NOT
  edit mount.ex; (b) re-baseline the committed byte-snapshot `paper_editor_flag_off.html`
  (delete + re-run, the test prints the recipe). Beta per-doc editor (`components.ex:863`)
  stays on the nil fallback — out of scope (D30-followup backlog).
- **D31 — Slice C: destructive Delete out of the misclick zone.** `default_doc_actions/2`
  emits History → **Delete (destructive red)** → Publish (primary CTA), sandwiching the
  destructive action between a benign one and the CTA. Reorder so Publish/Unpublish leads
  and Delete moves to the tail/separated; update the stale order comment
  (`doc_actions.ex:84-86`). **Why + safety:** proven resolver-safe — the only two
  production resolvers (`onixedit`, `github`) and the macro default are name-keyed with
  ZERO positional access to the list, so no plugin assumes Delete at `base[1]`; a net-new
  order unit test on `default_doc_actions/2` is non-vacuous (fails on the old order).
- **D32 — `sup-w4-pixel-evidence` stays a separate close-out, NOT swept into Wave 5.** Its
  blocker (`sup-w4-row-state-ladder`, #2146) has merged so it is now unblockable, but it is
  orthogonal (guerrilla D24e pixel harness + desk CSS, zero file overlap with the Wave-5
  slices) and needs a live *authenticated guerrilla* harness run, not a code slice. Left
  open with its lapsed claim noted; a re-claim (fresh epoch) is required before anyone runs
  it. It + the user re-verdict remain the epic's only non-Wave-5 debt.

## Roadmap

Wave 1 (this wave — integration order as listed):
1. `sup-w1-icon-authority` — complete the icon resolution authority in icons.ex (emoji map + missing Lucide glyphs); tree types become distinct with zero wire change. **small**
2. `sup-w1-topbar-scope-chip` — icons-only top bar tabs + compact scope chip restyle + themed dataset-switcher fallback. **medium**
3. `sup-w1-tokens-aa` — `--surface-raised`/`--border-subtle` tokens + AA fixes for `--fg-dim` and evergreen-light muted pairing, via the 3-file lockstep. **medium**
4. `sup-w1-controls-settings` — `StudioComponents.Controls` kit + full settings-page rebuild on it. **large**
5. `sup-w1-styleguide-gallery` — extend StyleguideLive with a control-kit gallery section (living spec + evidence surface; CSS-class based so it parallels slice 4). **small**

Wave 2 (this wave — integration order as listed; ALL worktrees cut from origin/main per D12):
1. `sup-w2-contrast-gate` — machine AA gate in design/check.mjs (curated pairing table per
   D15) + pairing-level fixes for the live sub-AA pane defects. **medium**
2. `sup-w2-radio-modals-sweep` — `bp_radio` primitive + styleguide gallery entry + modals
   airdrop radios/checkboxes onto the kit (D14; hex lit-allows untouched per D10). **medium**
3. `sup-w2-sheet-grid-sweep` — sheet_grid's ~14 native form controls onto the kit,
   name/data-test-id-preserving; sr-only swatch radios exempt (D14). **large**
4. `sup-w2-plugin-settings-paper-chrome` — plugin_settings_live's 4 raw field renderers +
   paper_editor add-block/add-property chrome selects onto the kit; golden snapshot
   re-baselined (D17). **medium**
5. `sup-w2-desk-org-admin-rhythm` — desk row anatomy/header counts/empty state/elevation
   adoption per D16 + org_admin D7 rebuild per D18. **large**

Wave 3 (this wave — THE CLOSING WAVE; integration order as listed; ALL worktrees cut
from origin/main (f2df6d76 or later, post-#2088) after `git fetch` per D12 — the local
primary checkout is BEHIND and rebuilds pre-#2088 markup):
1. `sup-w3-token-evenness` — bg-relative dark rung for `--surface-raised`/
   `--border-subtle` (+ `--bg-accent`/`--border-muted` verify-or-drop) per D20;
   evergreen byte-identical, Part F/A/H green. **medium**
2. `sup-w3-api-tester-kit` — api_tester onto the kit (bp_textarea class+spellcheck
   extension), scenario-row inline→class extraction with fg-dim→muted-text AA fix,
   new Part H rows (COUPLING LAW), new protective render test per D21. **medium**
3. `sup-w3-styleguide-kit-dom` — sg-controls renders the real bp_* components; pins
   :117-119 rewritten, bp_radio assertion added per D22. **small**
4. `sup-w3-shares-modal-kit` — shares_modal surfaces[] checkboxes onto bp_checkbox
   (the last criterion-2 blocker); datetime-local exemption recorded per D23. **small**
5. `sup-w3-qa-closeout` — whole-surface QA census (class-absence grep, LiveViewTest
   render census, Part H completeness), authenticated pixel pack via the login-ticket
   harness (incl. sheet popovers + plugin settings, uncaptured so far), epic criteria
   1-3 stamped with real evidence, criterion 4 surfaced to the user per D24. Runs
   AFTER slices 1-4 merge. **large**

Dropped from the old wave-3 sketch, with reasons: chat sweep (leaves the epic — D23),
session_html login pass (at-bar — D23), tmux polish (no controls — D21), pane-model
amendment (REJECTED — D19).

Wave 4 (this wave — desk structure consistency; deliberately SMALL, the epic is at its
finish line awaiting the crit-4 human re-verdict; ALL worktrees cut from origin/main
(4fbce80a / #2138 or later) after `git fetch` per D12 — the local primary checkout is
one commit BEHIND and rebuilds pre-scope-chip-v2 markup):
1. `sup-w4-row-state-ladder` — the D25 ladder applied identically at every pane depth:
   nav-plugin-entry color fix + doc-title/hover unification + hover-reveal chevrons
   everywhere (plugin rows gain the span) + dead-rule removal + Part H coupling rows +
   per-depth DOM pin tests, one PR (D26/D27). **medium**
2. `sup-w4-pixel-evidence` — post-merge before/after authenticated pixel pack on
   guerrilla via the D24e harness (with D27 corrections), computed-style proof that
   Projects matches its siblings in both modes; evidence stamped into the ledger and
   into the crit-4 human-gate pack. Runs AFTER slice 1 merges + guerrilla redeploys.
   **small**

Wave 5 (interaction polish — three file-disjoint slices, all parallel, all opus):

1. `sup-w5-a11y-live-regions` — `role`/`aria-live` on the save-status span
   (`editor.ex:460`) + both `studio_flash/1` divs (`nav.ex:28/31`); update the two
   pre-existing save-status assertions + add aria assertions (save-status test) + a
   net-new flash-aria assertion (nav.ex). Files: `editor.ex`, `nav.ex`,
   `studio_live_save_status_test.exs`. **small** (D29)
2. `sup-w5-paper-canvas-savestate` — replace the hardcoded `✓ Auto-saved` with the honest
   `@save_status` echo + reused `paper_halt_banner`; thread `save_status`/`paper_halt`
   through `studio_paper_view` → `paper_block_editor`; guard the missing assign;
   re-baseline the OFF-path snapshot. Files: `components.ex`, `paper_editor.ex`,
   `paper_canvas_test.exs`, `studio_live_paper_canvas_test.exs`,
   `snapshots/paper_editor_flag_off.html`. **small** (D30)
3. `sup-w5-doc-actions-order` — reorder `default_doc_actions/2` (Publish leads, Delete to
   the tail) + update the order comment + net-new order unit test. Files:
   `doc_actions.ex`, `studio_live_doc_actions_test.exs`. **small** (D31)

## Wave log

### Wave 1 — 2026-07-09/10 (MERGED #2067, 3e315eaf; live on guerrilla)

All five slices landed and their tasks closed 100%: icons-only top bar (aria-label
carries the tab name), compact scope chip (Project · dataset trail), complete icon
authority in icons.ex (every type its own glyph, emoji stay on the wire per D5),
AA-raised `--fg-dim` + new `--surface-raised`/`--border-subtle` tokens via the
3-file lockstep, `StudioComponents.Controls` kit (bp_card/bp_section_header/
bp_field_row/bp_input/bp_textarea/bp_select/bp_switch/bp_checkbox), settings_live
rebuilt on the kit (the D7 flagship), `/studio` styleguide gallery as the living
spec. HARD LESSON: the merge red-flagged 5 stale tests asserting old chrome markup
(trail separator, visible tab text) — the lead fixed trail `' / '` → `' · '`
asserts and nav-sweep label extraction via aria-label; this became D17
(test-drift is a first-class acceptance criterion, every brief pre-names its
pinning tests). Known debts banked: no real-browser pixel eyeball (guerrilla is
login-gated, local boot has known blockers), `--surface-raised` elevation is
theme-uneven (visible on evergreen, near-flat on ember/fjord dark),
`--surface-raised`/`--border-subtle` defined 6× but consumed by ~one rule.

### Wave 2 — 2026-07-10 (MERGED #2088, 871a3dd1, 02:32Z; all five tasks closed done)

**All five slices built green and reviewed; nothing stalled.** Ledger: all five
tasks published `in_progress`, criteria stamped with evidence, only the
merge-gated criterion open (reviewer re-set lifecycle to in_progress after
claim-lease expiry had mechanically flipped them to `open`).

What landed (final branches, in integration order):

1. `sup-w2-contrast-gate` — `loop-epic/contrast-machine-gate-live-sub-aa-pane-f-0`
   (unchanged by review). design/check.mjs Part H: WCAG-AA machine gate over a
   CURATED fg×surface pairing table (fg read LIVE from root.html.heex, per-theme
   derive, text ≥4.5 / nontext ≥3.0), red-proof verified (revert → exit 1 naming
   the pairing). Live sub-AA pane fixes at the pairing site (badge → muted-text,
   hover → muted-text, selected → fg). Lockstep byte-stable.
2. `sup-w2-radio-modals-sweep` — `loop-epic/bp-radio-primitive-modals-control-sweep-1-r`.
   bp_radio primitive + airdrop modal off native radios/checkboxes, styleguide
   entry. REVIEW FIX: `.airdrop-duration`/`.airdrop-caps` got inline-flow CSS —
   the kit's flex labels stacked the 4 duration options vertically in the modal.
3. `sup-w2-sheet-grid-sweep` — `loop-epic/sheet-grid-control-sweep-onto-the-kit-2`
   (unchanged by review). 8 sheet-grid controls onto the kit, names +
   data-test-ids threaded via :rest, compact popover density via specificity
   overrides in the Sheets skip region; sr-only swatch radios exempt (D14);
   cell-editor JS-hook contract untouched (__hook.test.mjs green).
4. `sup-w2-plugin-settings-paper-chrome` —
   `loop-epic/plugin-settings-renderers-paper-editor-a-3-r` (REBASED onto the
   radio -r branch — controls.ex conflict pre-resolved for the merge train).
   Four plugin-settings renderers + two paper-editor add-dropdowns onto the kit;
   bp_select gained additive optgroup + prompt support; golden snapshot
   re-baselined (only diff: `class="form-input"`). REVIEW FIX: bp_switch's
   On/Off state word is now CSS-truthful (both words in the DOM, `:checked`
   picks) — the server-rendered word would lie in submit-only forms (plugin
   settings has no phx-change; the path is latent today since no plugin declares
   a :boolean field, but the kit footgun is closed).
5. `sup-w2-desk-org-admin-rhythm` —
   `loop-epic/desk-row-anatomy-elevation-org-admin-d7--4-r` (REBASED onto the
   contrast-gate branch, integration fixes folded in). Row anatomy (subtitle =
   :meta ∥ humanized updated-at, id → hover title=), filtered header counts,
   iconed pane_empty with a New-document affordance, `--surface-raised` focus
   pane + `--border-subtle` dividers, hover chevron, 8px rhythm; org_admin full
   D7 rebuild on the kit. REVIEW FIXES (the charter-predicted collisions):
   (a) Part H pairing table re-synced to the new anatomy (`.pane-doc-id/meta`
   entries → `.pane-doc-sub` on surface/surface-raised/hover/selected + section
   headers + header count + `.pane-item` on surface-raised — 15 pairings, 90
   checks green); (b) `.pane-doc-item.selected .pane-doc-sub` escalates to
   `--fg` (muted-text on bg-accent = 4.16 evergreen-light, sub-AA); (c)
   `.pane-column--last .pane-section-header` escalates to `--muted-text`
   (fg-dim on surface-raised = 4.28 evergreen-dark — EXACTLY the regression D15
   predicted, and the desk build from origin/main had shipped it); (d) SCIM
   label colon copy fix.

Cross-slice verification: a scratch integration merge of all five final branches
(in the order above) compiled clean and ran the FULL suite green — 3086 tests /
0 failures, design/check.mjs 90 AA checks, studio-literal-check (zero new
lit-allows), studio-link-lint, wave-touched files format-clean. The one
merge conflict (controls.ex, radio × optgroup) is pre-resolved by the plugin
slice's restack. The single full-battery flake seen was the known TOTP
30s-window auth test, green in isolation.

MERGE TRAIN for the lead: gate → radio-r → sheet → plugin-r → desk-r; the lead
closes each task's merge criterion on merge. NOTE: plugin-r contains radio-r's
commits and desk-r contains gate's commit (stacked) — merge in order and the
PR diffs stay slice-shaped.

What wave 3 should take (roadmap ¶ + new findings):
- PAY THE PIXEL DEBT: no wave has eyeballed a real browser. An authenticated
  screenshot pass on guerrilla (all 3 themes × 2 modes: desk, sheet popovers,
  airdrop modal, plugin settings, org admin, styleguide) before any new build.
- `--surface-raised` theme-evenness (near-flat on ember/fjord dark) — the focus
  pane elevation only reads on evergreen; fix in the token manifest per D8.
- Part H COUPLING LAW: the gate curates each pairing's SURFACE token statically —
  any slice that changes an element's background fill must update the table in
  the same PR (this wave proved the failure mode and the fix).
- Chat control sweep coordinated with the studio-chat epic; api_tester +
  studio_live/components cosmetic kit conversion; session_html login pass.
- BANKED D4 amendment (inline nested tree / resizable columns) only if the desk
  still reads flat after D16 lands on real pixels.
- Styleguide gallery still shows class primitives; consider rendering the actual
  kit components (bp_radio/bp_switch) so gallery DOM mirrors component DOM.

### Wave 3 — QA close-out (sup-w3-qa-closeout, 2026-07-10)

The whole-surface QA slice. Runs the epic's exit proofs and stamps the parent
criteria. **Ordering reality:** this slice was executed while the four wave-3
build slices (`sup-w3-token-evenness`, `sup-w3-api-tester-kit`,
`sup-w3-styleguide-kit-dom`, `sup-w3-shares-modal-kit`) were still `in_progress`
in their own worktrees — none merged, guerrilla still served `f2df6d76` (the
wave-2 head, #2088). The census/render/Part-H proofs run on post-#2088 `main`
(what this worktree is cut from per D12); the **authenticated pixel acceptance
re-shoot is gated on those four merges deploying** and is handed to the human
gate (crit 4). Wave-3 decide-phase decisions D19–D24 live in the sibling task
briefs; this log records only what this slice proved.

**Proof 1 — class-aware native-control census (D24a).** Parser (kept at
`scratchpad/census2.py`, method below) over `live/studio/**`,
`components/studio_components/**`, `controllers/session_html/**`: finds raw
`<input|select|textarea>` **inside real `~H"""`/`.heex` template markup only**
(moduledoc/`@doc` prose and `<%!-- --%>` comments stripped — a tag-presence grep
false-flags 14 doc/comment mentions) that **lack the `form-*`/`bp-*` themed-class
family**, keying on class ABSENCE (never tag presence — `bp_select` emits
`<select class="form-input">`). Result: **48 raw hits, 47 documented exemptions,
exactly ONE genuinely-bare control** — `modals.ex:140` shares `surfaces[]`
checkbox, already owned by the in-flight `sup-w3-shares-modal-kit`. Zero
un-owned naked controls. The exemption register:

| # | Exemption class | Decision | Sites |
|---|---|---|---|
| A | Kit substrate + themed-label-wrapped input (label carries `.form-checkbox`/`.form-switch`/`.form-radio`/`.bp-paper-edit-check`; the real input is intentionally class-less behind it) | D6/D14 | `controls.ex` 229/262/294; `styleguide_live.ex` 331/334/342/345/351/356/362; `paper_editor.ex` 1030/1033 |
| B | Chat NO-GO (immovable client contracts; swept later with the chat epic) | D10 | `chat_live.ex` 2321/2364/2386/2414/2506/4130 |
| C | Visually-hidden swatch radio (`sr-only`/`display:none` behind custom swatch UI — the browser never paints the control) | D14 | `modals.ex` 736; `sheet_grid.ex` 2771 |
| D | `type="hidden"` input (no visual control to theme) | — | `session_html` mfa:12,new:22,new:89; `settings_live.ex` 460/553/554/592/624; `sheet_grid.ex` 2715/3057/3318; `paper_editor.ex` 1023/1056/1081/1108/1125/1142/1157/1172 |
| E | Paper-edit / field VALUE renderer (editor-form model, `bp-paper-edit-*`/`bp-paper-composite`; incl. native `type="color"` and `datetime-local`) | D6/D11/D23 | `paper_field_block.ex` 146; `paper_editor.ex` 1212/1241 |
| F | Sheet spreadsheet-chrome input (bespoke themed `sheet-*` class, JS-hook-bound cell/name/bar/find/tab-rename — styled, not naked) | D13/sheets skip-region | `sheet_grid.ex` 2503/2514/2836/3058/3437 |
| G | **Owned-pending** (genuinely bare; the named in-flight slice converts it → zero once merged) | wave-3 | `modals.ex` 140 → `sup-w3-shares-modal-kit` |

**Proof 2 — LiveViewTest render census.** `CC=clang mix test
test/barkpark_web/live/studio/` → **1193 tests, 0 failures** (studio_live,
settings, org_admin, api_tester, sheet_grid, media, styleguide, tmux, chat) +
`plugin_settings/bulldocs/sheets_reader/quiz` harnesses → **83 tests, 0
failures**. `graph_view` + `swatch_live` carry **no LiveViewTest render harness**
(canvas/tool surfaces) — recorded as D24d exemptions; no harness built.

**Proof 3 — Part H completeness + one live fix.** Enumerated every epic-touched
bespoke color rule's fg-tier × surface in `root.html.heex`. All at-risk
(dim/muted-tier on raised/accent/muted) pairings were already curated EXCEPT one:
`.bp-secondary-pane-readonly` (editor detail pane, `editor_fields.ex:112`) paints
`--fg-dim` on its own `--bg-muted` fill = **4.05–4.40 (sub-AA on evergreen
light+dark, ember/fjord light)** — the identical fg-dim-on-bg-muted defect D15
caught for `.pane-doc-badge`. Introduced by `dd830aba` (pre-epic), so the gate
never covered it — the honest legacy residual, now closed: escalated
`--fg-dim`→`--muted-text` (4.57–6.88, AA everywhere) at the site and added the
16th Part H pairing (revert → red, verified). **Judgement call rejected:**
`.org-admin-token` = `--fg` (max text tier) on `--surface-raised` does NOT earn a
row — it cannot fail AA (>10:1 every theme×mode); Part H curates at-risk
co-occurrences, not the cartesian product. `node design/check.mjs` → **PASS, 16
pairings × 3 themes × 2 modes = 96 checks**.

**Proof 4 — authenticated pixel harness (D24e) + human-gate pack.** The
login-ticket harness is PROVEN end-to-end: admin bearer from
`~/.config/barkpark/config.json` → `POST /v1/auth/login-tickets` (201, 60s
ticket) → browser `GET /login/ticket/:t` (302 → session cookie) → `/studio`
authenticated (200, `pane-layout`/`scope-title`/`studio-shell`; theme driven
in-session via `documentElement.dataset.theme`/`dataset.bpTheme`). Demonstrator
captures on the **deployed wave-2 build** (footer `v0.2.25.237 · f2df6d76`):
desk (evergreen-dark) confirms wave-1/2 chrome live (icons-only bar, scope chip,
distinct type icons); Papers focus pane (ember-dark) confirms wave-2 desk anatomy
(row `:meta` subtitle, "Papers 75" count, status dots, ember accent). D20
elevation baseline **quantified**: ember-dark `--bg` 8% L vs `--surface-raised`
9.31% L = **1.31% L separation** (panes `rgb(19,15,11)` vs `rgb(28,23,20)`) —
the near-flat state the unmerged `sup-w3-token-evenness` slice fixes. **The
acceptance re-shoot (all 6 combos × desk/sheet-popovers/plugin-settings/
airdrop+shares-modals/org-admin/styleguide/api-tester, verifying elevation READS
on ember/fjord dark) MUST run after the four siblings merge + guerrilla
redeploys** — surfaced to the human gate; NOT stamped met.

**Epic exit stamp (parent `studio-ui-premium`).** Crit 1 (waves merged): #2067 +
#2088 + the four wave-3 PRs on merge. Crit 2 (zero native controls): the census
above — one owned-pending control, else fully exempt. Crit 3 (AA): Part H is the
operational definition — every epic-touched fg×surface co-occurrence machine-gated
(96 checks); honest residual = legacy text the epic never touched is NOT
machine-covered (this slice closed the one at-risk residual it found,
`.bp-secondary-pane-readonly`). Crit 4 (user re-verdict): HUMAN GATE — pixel pack
surfaced, awaiting user verdict.

The banked D4 pane-model amendment (inline nested tree / resizable columns): the
desk reads premium in pixels (anatomy + chrome + counts + dots all land) — the
"unfinished dev tool" tell D16 named is gone. Elevation is the one open pixel
concern, and it is a token-value fix (`sup-w3-token-evenness`), NOT a pane-model
gap. The amendment decision remains the reviewer's to ratify once elevation lands
on ember/fjord dark; nothing in the QA pixels argues the pane MODEL is the problem.

### Wave 3 — 2026-07-10 (reviewed; ready for the lead's merge train)

**All five slices built green and reviewed; nothing stalled; ZERO review fixes
needed** — the first wave where every slice survived adversarial review
unchanged (D17's pre-named pins and the w2 lessons did their job). Ledger: all
five tasks published `in_progress`, claims held (epoch 1), every criterion
stamped with evidence, only the merge-gated criteria open for the lead.

What landed (final branches, in integration order):

1. `sup-w3-token-evenness` — `loop-epic/token-evenness-dark-mode-elevation-reads-0`.
   `raisedDark(skin, dL, C)` in derive.mjs rebinds ONLY the dark rungs of
   `--surface-raised` (+0.0695 OKLCH L over the theme's own dark bg) and
   `--border-subtle` (+0.0445): elevation is now a CONSTANT step on every theme.
   Evergreen byte-identity holds (Part F 160/160, frozen 82 overrides untouched);
   only ember/fjord dark bytes moved, and both formerly-INVERTED hairlines
   (below their 8% bg) now sit above it. Secondary scope (`--bg-accent`/
   `--border-muted`) dropped with a written reason: they are evergreen PINNED
   overrides — no fit anchor exists; fixing the ember/fjord selected-row
   recession needs a deliberate reference-elevation decision (filed as a
   follow-up candidate below).
2. `sup-w3-api-tester-kit` — `loop-epic/api-tester-onto-the-controls-kit-inline--1`.
   Playground onto bp_input/bp_select/bp_textarea (additive `class` +
   `spellcheck` passthrough on bp_textarea); scenario-results + schema-browser
   inline styles extracted to root.html.heex classes with all three fg-dim
   sites escalated to `--muted-text`; 3 new Part H pairings (COUPLING LAW);
   NEW playground pin test. The brief's "orphaned token-change handler" premise
   was FALSE — the new render test caught the live top-bar Token field wiring
   (layouts/studio.html.heex:61) and the handler is kept + pinned.
3. `sup-w3-styleguide-kit-dom` — `loop-epic/styleguide-gallery-dom-becomes-the-spec--2`.
   sg-controls renders the real kit components (bp_input/bp_select with prompt
   AND optgroup/bp_textarea/bp_checkbox/bp_radio/bp_switch on/off/disabled) —
   gallery DOM IS component DOM (D22); pins rewritten to kit attribute order,
   :122-125 class pins pass unmodified; btn/card/badge/tabs stay class
   primitives (no kit component exists). Does NOT depend on slice 2's
   bp_textarea extension.
4. `sup-w3-shares-modal-kit` — `loop-epic/shares-modal-surfaces-checkboxes-onto-bp-3`.
   The last naked native control falls: shares_modal surfaces[] checkboxes →
   bp_checkbox, name/value/checked byte-preserved; new pin test also re-proves
   the surfaces[] list param through shares-add. `.shares-surfaces` is already
   flex, so the w2 stacking lesson needed no CSS.
5. `sup-w3-qa-closeout` — `loop-epic/whole-surface-qa-close-out-census-authen-4-r`
   (-r carries only this wave-log entry). Census (48 raw hits → 47 exemptions +
   1 owned-pending = the shares control, converging to ZERO when slice 4
   merges), render census 1276 green, Part H completeness sweep found + fixed
   the one legacy at-risk residual (`.bp-secondary-pane-readonly` fg-dim on
   bg-muted 4.05–4.40 → muted-text, 16th pairing, revert→red), login-ticket
   pixel harness proven on guerrilla with the D20 near-flat baseline quantified
   (ember-dark 1.31% L). Epic criteria stamped; crit 4 = human gate.

**DECISION — the D16-banked pane-model amendment is REJECTED.** This wave was
the one licensed pane-model discussion; the evidence says no: the QA pixel pass
on the deployed wave-2 build shows the desk reading premium (pane headers,
row `:meta` subtitles, filtered counts, status dots, iconed empty states — the
"unfinished dev tool" tells are gone), and the single remaining pixel defect
(elevation near-flat on ember/fjord dark) is a token-VALUE bug that slice 1
fixes, not a pane-model gap. Nested-tree exploration / resizable pane columns
would be a rebuild of a working Sanity-style drill-down for no evidenced gain.
D4's fence stays; reopening requires a fresh decide-phase amendment backed by
post-merge pixel evidence.

Cross-slice verification (reviewer): a scratch integration merge of all five
final branches in the order above merged CLEAN (both check.mjs PAIRINGS
additions coexist → 19 pairings × 114 AA checks green; root.html.heex 3-way
merge clean) and ran `test/barkpark_web/live/studio/` +
`test/barkpark_web/components/` = **1425 tests, 0 failures**, plus
studio-literal-check (zero new lit-allows), studio-link-lint, and mix format
clean on every touched file.

MERGE TRAIN for the lead: token-evenness → api-tester → styleguide → shares →
qa-closeout-r; the lead closes each task's merge-gated criterion on merge
(token crit 6, api-tester crit 6, styleguide crit 4, shares crit 4, qa crit 5)
and stamps the epic parent's crit 0–2 `met` once all five are in. KNOWN BENIGN
DRIFT: the census register's styleguide_live.ex line refs snapshot post-#2088
main — slice 3 rewrites those sites onto the kit, so the register's row-A count
only shrinks (never a new naked control).

What comes after (the epic is at its finish line):
- POST-MERGE HUMAN GATE: guerrilla auto-deploys on merge — re-shoot the full
  6-combo pixel pack via the proven login-ticket harness (desk MUST show
  elevation reading on ember/fjord dark, D20 in pixels; sheet popovers, plugin
  settings, airdrop + shares modals, org admin, styleguide, api tester) and
  surface it for the user's re-verdict (epic crit 3).
- Chat control sweep stays deferred until the studio-chat epic clears (D10);
  it inherits token fixes automatically. This is the ONLY remaining code vein.
- Follow-up candidate (small, needs a decide phase): `--bg-accent`/
  `--border-muted` ember/fjord dark recession — requires a reference-elevation
  decision that likely retires two evergreen pinned overrides (out of scope
  for the byte-anchored token slice, documented in its task evidence).
- session_html login + tmux polish were judged already-themed in the w2 census;
  nothing owed unless the pixel pack says otherwise.

### Wave 4 — 2026-07-10 (desk structure consistency; reviewed; ready for the lead)

**1 of 2 slices built green; the second is HONESTLY BLOCKED by design** (it is
a post-merge evidence pack and the ladder has not merged). Ledger: both tasks
published `in_progress`, claims held (epoch 1), evidence stamped, no false
`met` flips anywhere.

1. `sup-w4-row-state-ladder` — final branch
   `loop-epic/desk-rows-speak-one-state-ladder-at-ever-0-r` (review carries ONE
   follow-up commit). The D25 ladder, CSS-rule-level exactly per D26:
   `a.pane-item.nav-plugin-entry` color:inherit → `--fg-muted` (+ a matching
   `:hover → --fg` rule, needed because the entry's 0,2,1 specificity blocks the
   shared `.pane-item:hover` lift — in-spirit, ratified here); `.pane-doc-title`
   gains the explicit `--fg-muted` plain tier + hover lift to `--fg` + a
   selected `--fg` override holding the AA fence; `.pane-item-chevron` adopts
   hover-reveal and the `:plugin_link` branch emits the shared chevron span
   (Projects gains the drill affordance); dead `.pane-doc-item` padding rule
   removed. Part H +6 coupling rows (nav-plugin-entry on both pane grounds,
   doc-title on the doc-sub ground set), revert→red proven by the builder.
   Per-depth DOM pins: new `desk_row_ladder_test.exs` (structure/type/doc) +
   plugin-link label+chevron pin in resolver_outputs_test.exs. REVIEW FIX
   (coupling-law curation): the chevron's old `--surface` Part H row became a
   PHANTOM co-occurrence once the glyph is opacity-0 at rest — replaced with
   its real visible grounds `--bg-muted` (hover fill) / `--bg-accent` (selected
   fill). Final gate state: check.mjs 27 pairings × 162 AA checks, 1439 tests /
   0 failures, literal-check + link-lint green, format clean, tokens_gen.ex
   byte-identical. Adversarial checks that came back CLEAN: plugin-link rows
   can never carry `.selected` (class hardcoded) so the new 0,2,1 rule cannot
   put a muted tier on `--bg-accent`; `pane_item`'s `:trailing` slot is only
   ever the drill chevron (api_tester passes `:badge`), so hover-reveal hides
   no content. origin/main moved to 602eb4a3 (#2145) AFTER the build — verified
   merge-tree CLEAN and zero pane-rule overlap.
2. `sup-w4-pixel-evidence` — NOT RUN, correctly: guerrilla footer still
   `4fbce80a` (pre-ladder). The builder did NOT fabricate an AFTER pack;
   instead it re-proved the D24e harness end-to-end and stamped a quantified
   BEFORE baseline confirming the user's exact bug live (dark: Projects
   rgb(242,242,242) vs sibling rgb(161,161,170); light: rgb(9,9,11) vs
   rgb(110,110,119); no chevron on Projects). All criteria honestly met=false.

MERGE TRAIN for the lead: merge `…-at-ever-0-r` (this branch, carries this log
entry) after the Elixir Test gate; close the ladder task's crit 7 on merge.
Then guerrilla auto-deploys → the pixel-evidence task unblocks: re-run the
D24e harness (data-theme attr ONLY, screenshots via repo root then move),
flip its criteria on the computed-style match, fold the before/after pack
into the epic crit-4 human-gate material. That re-shoot + the user re-verdict
are ALL that remain of this epic — no new code veins were found this wave.

### Wave 5 — 2026-07-14 (interaction polish — IN FLIGHT)

Decide (resumed post spend-cap) cut three net-new, file-disjoint slices after the
verify fleet PROVED each one RED→GREEN in throwaway worktrees off origin/main
@51576f128 (isolated MIX_TEST_PARTITION; shared `barkpark_test` is drifted — never
use it). Wave Paper: `studio-premium-wave-2026-07-14`. Slices, all opus:

- `sup-w5-a11y-live-regions` (D29) — a11y live-regions. Proof: new aria assertion
  RED on unmodified source ("Assertion with =~ failed" on the attributed span),
  GREEN after adding `role`/`aria-live`; `studio_layout_test.exs` 6/6 green (no
  regression). Correction folded: single *layout* sink, `settings_live` self-renders
  and is already accessible.
- `sup-w5-paper-canvas-savestate` (D30) — honest canvas save-state. Proof: reverting
  the footer to the hardcoded string makes the "Save failed echoed" test FAIL; honest
  echo passes (156 tests, 0 failures on both target files after re-baseline).
- `sup-w5-doc-actions-order` (D31) — Publish-leads reorder. Proof: 37 tests 0 failures
  on reorder; the 2 net-new order assertions FAIL on the old order (non-vacuous);
  onixedit/github resolver suites byte-identical either way (name-keyed, no positional
  access).

Builders build in worktrees off origin/main, commit (do NOT push — the steward
pushes+PRs). The lead closes each slice's merge-gated criterion on merge. Review
folds the merged results, the debrief, and the final grade back into this log.
`sup-w4-pixel-evidence` (D32) stays separate; it + the user re-verdict remain the
epic's only non-Wave-5 debt.

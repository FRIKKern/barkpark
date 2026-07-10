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

Wave 3 (planned): chat control sweep coordinated with the studio-chat epic lead
(token-only until then); api_tester + studio_live/components cosmetic kit conversion +
api_tester scenario-row inline-div cleanup; session_html login-page premium-feel pass;
tmux polish; the BANKED D4 pane-model amendment (inline nested tree / resizable columns)
only if the desk still reads flat after D16; final AA audit + close-out evidence.

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

### Wave 2 — 2026-07-10 (reviewed; ready for the lead's merge train)

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

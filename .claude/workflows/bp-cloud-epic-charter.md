# Epic: studio-ui-premium — Studio UI premium overhaul

> NOTE ON THIS PATH: the former "Barkpark Cloud — Peak Aesthetics, UX and DX" charter that
> lived at this filename was preserved verbatim at
> `.claude/workflows/bp-cloud-peak-aesthetics-charter.md` (and in git history, 75951d8f).
> `bp-cloud-console-charter.md`'s parent-epic pointer targets that preserved copy.
> This file is now the memory of the **studio-ui-premium** epic.

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

## Roadmap

Wave 1 (this wave — integration order as listed):
1. `sup-w1-icon-authority` — complete the icon resolution authority in icons.ex (emoji map + missing Lucide glyphs); tree types become distinct with zero wire change. **small**
2. `sup-w1-topbar-scope-chip` — icons-only top bar tabs + compact scope chip restyle + themed dataset-switcher fallback. **medium**
3. `sup-w1-tokens-aa` — `--surface-raised`/`--border-subtle` tokens + AA fixes for `--fg-dim` and evergreen-light muted pairing, via the 3-file lockstep. **medium**
4. `sup-w1-controls-settings` — `StudioComponents.Controls` kit + full settings-page rebuild on it. **large**
5. `sup-w1-styleguide-gallery` — extend StyleguideLive with a control-kit gallery section (living spec + evidence surface; CSS-class based so it parallels slice 4). **small**

Wave 2 (planned): native-control sweep of remaining screens onto the Controls kit —
sheet_grid.ex (7 controls), modals.ex radios/checkboxes, api_tester select, paper_editor
block selects; consume `--surface-raised` for card/panel elevation across desk + editor;
in-browser computed-style contrast verification per theme×mode (confirm the two marginal
cases from D8); layout-rhythm pass (spacing scale, typographic hierarchy) on desk, media,
projects screens.

Wave 3 (planned): chat control sweep coordinated with the studio-chat epic lead
(token-only until then); org_admin/tmux polish; final AA audit + close-out evidence.

## Wave log

### Wave 1 — 2026-07-10 (reviewed)

**All 5 slices green, reviewed, fixed in place, integration-verified.** A scratch merge of all
five `-r` branches was clean (no conflicts) and fully green: 80 Elixir tests, studio-link-lint,
studio-literal-check, design emit --check + check.mjs + derive.test.mjs (48/48). Merge the `-r`
branches, in roadmap order:

1. `sup-w1-icon-authority` → `loop-epic/icon-authority-complete-emoji-map-icons--0-r` — icons.ex
   is the complete authority (5 new emoji mappings, ✅→check-square, 📑→sticky-note, 13 new Lucide
   paths; plugin desk links columns/zap/github/clock now resolve). Wire fence held: emoji
   byte-verified identical across icons.ex ↔ structure.ex ↔ schema JSONs (no variation-selector
   drift). Reviewer fix: mix format.
2. `sup-w1-topbar-scope-chip` → `loop-epic/icons-only-top-bar-with-tooltips-compact-1-r` —
   icons-only tabs (title + aria-label, no visible text), compact scope chip, themed dataset
   fallback; all four scope events intact. Reviewer fix: the chip fill referenced `--bg-subtle`,
   which is **defined nowhere in the repo** (computes to transparent) — now
   `var(--surface-raised, var(--bg-muted))`.
3. `sup-w1-tokens-aa` → `loop-epic/token-manifest-surface-raised-border-sub-2-r` — new chrome
   tokens via the 3-file lockstep; fg-dim + evergreen-light muted-text clear AA in all 6
   theme×mode combos with committed protective node tests; tokens_gen.ex byte-stable (verified
   against BOTH real tokens_gen.ex paths). Reviewer fix: the muted-text ripple broke the pdrender
   golden `TestPdrenderTokensGolden` (chrome-label light #71717a→#6e6e77) — fixture regenerated,
   full `go build ./...` + pdrender/semrole/taskboard tests green. The builder's "only my gate"
   blind spot was real; the Elixir CI gate would NOT have caught it (the Go gate would).
4. `sup-w1-controls-settings` → `loop-epic/studiocomponents-controls-kit-settings-p-3-r` —
   Controls kit (8 components) + Settings rebuilt, zero native controls, 35 tests green, event
   plumbing verified (`:global` passes phx-click/phx-value-*). Reviewer fix: added the missing
   `:disabled` rules (`.btn:disabled`, `.form-input:disabled`,
   `.form-switch:has(input:disabled)`) — Settings ships disabled Save/Reveal/placement controls
   that previously gave zero visual feedback; plus mix format.
5. `sup-w1-styleguide-gallery` → `loop-epic/styleguide-control-kit-gallery-the-livin-4-r` —
   Controls gallery in StyleguideLive. Reviewer fix: disabled specimens now show the REAL
   `:disabled` rules from slice 4 (inline opacity simulation removed — **merge 4 before 5**), and
   `.btn-icon` renders the real `plus` glyph instead of a `＋` text placeholder.

**Lead actions on merge:** close each task's "PR merged" criterion (all 5 tasks honest:
in_progress, evidence stamped, only the merge criterion open); then flip epic criterion 0.
This charter file rides the styleguide `-r` branch; the main checkout holds the strategist's
uncommitted copy WITHOUT this wave log — the branch version supersedes it (reconcile by keeping
the branch version).

**Debt found, deliberately not fixed this wave (wave-2 fodder):**
- `--bg-subtle` is consumed ~21 more places in root.html.heex and **defined nowhere** — every one
  silently paints transparent (shares/attach/actions-bar hover fills). Decide: alias it in the
  manifest or sweep the usages onto real tokens.
- `--surface-raised` dark elevation is theme-uneven: the STUDIO_II anchor is absolute (L 0.210),
  so ember (bg L≈0.194) / fjord (bg L≈0.184) get Δ0.016/0.026 — near-flat. Make the dark formula
  relative to bg (≈ bgL + 0.07) or pin per-theme; extend the elevation test beyond evergreen.
- Nothing consumes `--surface-raised`/`--border-subtle` yet except the reviewer's chip-fill —
  wave 2's card/panel elevation pass is where they land.
- No real-browser pixel eyeball happened anywhere this wave — all evidence is rendered-HTML +
  math. Wave 2 must include an authenticated screenshot pass (guerrilla login) or a booted local
  LiveView eyeball, especially Settings + the icons-only top bar + the styleguide gallery in both
  modes.
- Styleguide gallery is class-based by design; a later wave swaps it onto the Controls components.

**Wave 2 direction:** roadmap as written (native-control sweep of sheet_grid ×7 / modals /
api_tester / paper_editor onto the kit; consume surface-raised for desk+editor elevation;
in-browser computed-style contrast verification; layout-rhythm pass on desk/media/projects) PLUS
resolve the --bg-subtle defect and the surface-raised theme-evenness, and pay the pixel-eyeball
debt first — it gates the user's re-verdict.

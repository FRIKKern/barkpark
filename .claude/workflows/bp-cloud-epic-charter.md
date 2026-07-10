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
### Wave 2026-07-04 resync + wave-4 cut (architect)

A parallel console loop (D45–D66) landed half of the wave-3 cut between charter snapshots: sub-tabs+webhooks, on-demand verify, `__preview__`, DESIGN.md, onboarding narrative, FailureCopy, usage endpoint. Decisions 32–36 recorded; verify SSE clause voided (33 — verify rides instance events + `fleet`); render-rig slice cancelled (satisfied by `__preview__`); dep-pill confirmed still alive → decision-24 sweep scope widened; row-grammar strategist proposal absorbed into the sweep (24); capability freeze re-affirmed against five strategists' expansion pressure (35); log spine acknowledged as the top parity hole and scheduled with its own scrutiny (wave 7). **Wave 4 cut: items 9b, 10, 11, 11b.** app.js contention: item 9b owns the instance region + TYPE_ACTIONS wiring; item 10 owns the site-detail region + a new invite view + routes; both append-only to app.css end / `__app.test.mjs` / `__bpTestHook` exports (textual conflicts, merge sequentially: 11 → 10 → 9b → 11b). Item 11 owns app.css token blocks + index.html + styleguide.html + `__css_check.mjs` and must not edit app.js. Item 11b is Go-only. Every SPA slice adds `__preview__` scenarios for its new states; perfecters attach renders (amendment 2.4).

### Wave 2026-07-04 (wave 4 — keep every promise; become Barkpark)

**Landed (4/4 green, all perfecter-approved "merge the -p branch"):**
- **11 Identity drop** (424913bc + perfecter polish): evergreen/sage mirror-pair primary + amber accent, 149-byte inline-SVG mark, genuinely self-hosted Inter (offline-render proven), dimensional token ladders defined (primitives-only migration per decision 29), E5 WCAG contrast engine (29-pair manifest × 2 themes = 58 checks), E6 raw-literal error + allowlist, E7 no-external-host lint, R4 px backlog report (132 lines), /styleguide.html sign-off page. All 10 gate mutations probed. Perfecter caught a REAL ratification-surface bug (scoped `[data-theme]` var-substitution rendered light colors in the styleguide's dark panes) — fixed + gated as E8.
- **10 Zero broken promises** (58100d00): confirmModal born (pure reducer, mutate + destroy tiers, trapTarget refactor, D25 one-recovery-action contract), Rollback/Redeploy UI on the promote route (Current chip, consequence copy, promoteFailure map), invitation accept flow end-to-end (legacyRoute for the minted shape, token parked in sessionStorage + URL scrubbed, preview banner, designed terminals incl. wrong-account resume). Decision-26 broken promise CLOSED.
- **9b Timeline + verify chips** (7ca5a94a): incident home whole per decision 34 — pure mergeTimeline (order/dedup/403-degrade harness-pinned), inline expansion surviving SSE remounts, verify chips byte-pinned to `__fixtures__/verify_probes.json`, Check-now with honest unreachable rendering, 409/404 each one recovery action. Zero Elixir. Repaired the pre-existing stale `__preview__` 'empty' expectation.
- **11b `bp cloud verify`** : verdict line + probe table through statusRole/joinColsPainted, `-o json` verbatim, exit ladder via useError, fixture tripwire now spanning Go CLI + Go provisioner + Elixir. Dispatch registered in hetzner_cmd.go (runCloud lives there, NOT cloud_cmd.go — FILES list was wrong, builder correct).

**Wave verdict:** the strongest wave yet against the wish — identity (aesthetics), zero-broken-promises + incident home (UX), CLI twin + merge gates (DX). No drift into micro-repair; the freeze held.

**BLOCKING before/at integration:** (1) decision-27 human ratification of /styleguide.html — serve the **-p branch's** page (dark panes differ from the builder's original); nothing merges before it since 11 heads the merge train. (2) Merge order 11 → 10 → 9b → 11b, sequential — known textual conflicts: app.css tail, `__app.test.mjs`, ALLOW_PREFIXES, `__preview__` EXPECTATIONS, runCloud switch/help. (3) Full cloud Elixir suite at integration (builder ran only the touched allowlist test in-worktree). (4) macOS Go gate needs CC=clang (environmental).

**Owed post-merge (file as tasks):** real-browser light/dark eyeball of Timeline/verify-chip/rollback/invite screens (profile lock blocked it two waves running — pixel debt is accumulating); one real `bp cloud verify` + curl smoke on guerrilla (envelope parity rests on handwritten test envelopes); loadInstanceSites re-query race (A's sites can paint into B's slot); invite already-member detection only sees the current team + session not switched after join (server contract question for the wave-7 members panel); first destroy-tier consumer must browser-click the typed-echo input once; consider promoting `__preview__/smoke.mjs` into a gate (it's green and it caught the IA-reshape drift).

**Feeds wave 5:** status hues visibly retinted in BOTH themes (forced by the AA gate) — the decision-22 `design_tokens.json` cross-runtime fixture is now UNBLOCKED and urgent (CLI ANSI must derive from the NEW values, do it early); --dur-3 defined-unconsumed + 132-px R4 backlog are explicit sweep fodder for decision 24 — if the sweep slips, these rot into permanent debt.

### Wave 2026-07-10 (epic staging-barkpark, wave 1 — reviewer log)

*(Filed here because this charter is the file the staging-barkpark workflow reads; the staging epic carries no charter of its own yet — the wave-2 lead should mint one or keep logging here under the slug.)*

**Landed (4/4 code slices green, reviewer-fixed in place — integrate the `-r` branches):**
- **staging-w1-channel-seam** (`loop-epic/instance-deploy-sh-gains-a-fail-closed-d-0-r`, 0b10610c): DEPLOY_REF/DEPLOY_REMOTE channel seam in `deploy/instance-deploy.sh`, fail-closed on the `/opt/barkpark/.staging` marker — prod keeps byte-identical `pull --ff-only origin main` and REFUSES non-main refs (exit 11); staging fetch+hard-resets any branch or `pull/<n>/head`. Reviewer fix: prod also REFUSES a non-origin `DEPLOY_REMOTE` (was silently ignored — safe outcome, wrong intent) + 5 new harness checks incl. staging non-origin-remote fetch. 49/49, both guards mutation-probed.
- **staging-w1-deploy-verb** (`loop-epic/bp-cloud-deploy-one-verb-pushes-any-ref--1-r`, c364bb78): `bp cloud deploy <target> [--branch|--pr|--host|--clean|--dry-run]` — streams the LOCAL instance-deploy.sh over SSH under the exact seam env contract; host precedence --host → fleet row → BARKPARK_STAGING_HOST → clear error; ZERO config writes (byte-asserted); `bp use` refuses a staging default without --force. 13 new tests. Reviewer fix: gofmt only. KNOWN GAP (accepted): RunFeed buffers CombinedOutput, so the deploy log prints after completion, not live — a streaming exec seam in cloud/sshrunner.go is wave-2 fodder.
- **staging-w1-identity-banner** (`loop-epic/studio-wears-its-environment-barkpark-en-2`, 37e4b719, no reviewer changes): `BARKPARK_ENV` → `:instance_env` (runtime.exs prod, identity tag NOT MIX_ENV) → `Nav.studio_env_banner/1` in studio.html.heex — staging strip with disposable-data copy, generic uppercase for unknown tags, nothing for nil/prod/production; warn-token colors verified present in all 8 themes; literal-check green; 51 tests. **Elixir slice — WAIT for the Elixir Test gate before merge.** app.html.heex does NOT carry the banner (Studio-only this wave, by brief).
- **staging-w1-canary-runbook** (`loop-epic/deploy-readme-md-teaches-the-staging-cha-4-r`, 99ce648a): deploy/README.md "Staging channel" section — two-channel table, the verb, the 5-step canary loop, staging-host onboarding. Reviewer fixes against the built code: real host-resolution precedence (BARKPARK_STAGING_HOST has NO default), operator key `~/.ssh/barkpark_indx` not CI's DEPLOY_SSH_KEY, branch/PR refs not raw shas. Doc gates green. Its criterion 1 ("match MERGED implementations, cite PRs") stays open until the lead merges seam+verb and cites the PRs.

**Stalled (honest):** **staging-w1-box-provision** — HUMAN-GATED, all 6 criteria open with a prepared executor runbook stamped as evidence. Hard gates: staging.barkpark.cloud NXDOMAIN (DNS zone is on the SEPARATE Hetzner token — cannot be automated with the present credentials); billable `hcloud server create` forbidden unsupervised; newest warm snapshot is x86 (use cx22/cpx11, NOT cax11 ARM). Also blocked on seam+verb merging first.

**Merge order:** seam-r → verb-r (Go gate; may merge on it) → banner (WAIT for Elixir Test) → runbook-r last (docs-only). No textual conflicts expected — disjoint files. Lead closes each task's "PR merged" criterion on merge (claim epochs: seam/verb/banner/runbook = 1; box-provision = 2 — do NOT patch briefs, the close fence digests them).

**Wave 2 should take:** (1) the human executes box-provision (runbook is in the task evidence; D6 timing measurement rides the first real `bp cloud deploy staging`); (2) `bp cloud deploy staging --reset` (disposable-data verb the runbook already promises); (3) live-stream the deploy log (exec seam in sshrunner); (4) consider the banner on app.html.heex-rendered admin surfaces; (5) a real end-to-end smoke: branch → deploy → three curls → merge, timed against the seconds-to-minutes wish.

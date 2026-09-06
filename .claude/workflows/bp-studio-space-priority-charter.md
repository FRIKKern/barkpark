# Studio Space-Priority Desk (durable epic charter)

> **THIS FILE IS THE CANONICAL CHARTER FOR THIS EPIC.** It is NOT the rotating
> `.claude/workflows/bp-cloud-epic-charter.md` slot — that slot carried D1–D34 through the
> LAND wave and has since been re-occupied by other epics (PDS, then Task Lifecycle
> Visibility). Three separate verifiers this wave burned time discovering that the charter
> path named in their brief did not exist. **D37 settles it: read THIS path.** The rotating
> slot's D1–D34 are preserved verbatim below; nothing is lost by never reading it again.
>
> Epic anchor: bp task **`studio-space-priority-desk`** (published, guerrilla).
> Wave 1 paper: **`studio-responsive-desk-wave-2026-07-19`** (style=article).
> Wave 2 (LAND) paper: **`studio-space-priority-desk-land-2026-07-19`** (style=article).
> Wave 3 (ADVANCE) paper: **`studio-space-priority-desk-advance-2026-07-19`** (style=article).
> Decided 2026-07-19; amended 2026-07-19 (LAND wave, D19–D34; ADVANCE wave, D35–D47).

## Vision

The Studio desk becomes a layout system that visibly REASONS about space instead of crushing the middle pane. The active content pane (paper view / document editor) is the protected winner of every layout negotiation — it never drops below a readable measure (~55–70ch); all squeeze flows outward by explicit priority (list pane compresses first, then rails to 44px strips, then the Document inspector overlays instead of docking); at phone widths the desk becomes a single-pane drill with a breadcrumb. One shared anatomy vocabulary (role × priority × width-bucket) spans server and CSS, and the desk chrome comes up to the unified-aesthetic bar (type-scale tokens, Plex Mono) — while Structure.build's gated-tree contracts (Go-TUI wire shape, owned_schema_types single map, nav-model canonical `studio-nav-model`, reveal-via-ancestors, #1851 never-unreachable) stay untouched underneath.

## Decisions

- **D1 — Hybrid layer split ratified.** CSS owns everything CONTINUOUS (clamp widths, protected measure, container-query overlay); the server owns everything DISCRETE (pane set, roles, strip/hide DOM); a width-bucket seam reconciles them. Why: CSS-only can't take over collapse (strips are server-rendered different DOM); server-per-resize janks — both sides of this split are now mechanically proven (browser harness + LiveView probe).
- **D2 — Client-first bucket stamping.** A plain nonced inline script (theme-toggle pre-paint pattern) stamps `html[data-width-bucket]` before first paint and on resize with hysteresis; CSS keys off it instantly. The LiveView hook only pushes bucket TRANSITIONS to the server after connect. Why: `get_connect_params` is nil on the static render (proven) — first paint can never know a server-side bucket, so CSS must own initial layout; no flash-of-wrong-layout.
- **D3 — Buckets & thresholds.** wide ≥1280 · standard 1024–1279 · narrow 640–1023 · phone <640 (viewport px), ±32px hysteresis dead-band per edge (narrow eagerly, widen reluctantly). Why: 604px fixed chrome + ~680px (66ch) floor = ~1284 break-even, live-measured; hysteresis proved 1 transition vs 10 under boundary jitter (node harness).
- **D4 — Protected measure is a FLAT floor, Studio-scoped.** `.editor-panel .bp-paper-surface { min-inline-size: 55ch }` — never `min(100%, 55ch)` (silently no-ops; harness Bug 1), never on bare `.bp-paper-surface` (shared with public reader, chat bubbles, swatch demo). `.editor-panel` gets `container-type:inline-size; container-name:content` AND `position:relative` (container-type does NOT create a positioning context — the overlay needs it). The same protection extends to `.editor-body` (classic non-paper editor — a DIFFERENT selector with no .bp-paper-surface, verified uncovered) and the ONIX 60/40 split (stacks to column under a 720px container query).
- **D5 — Priority squeeze requires the list pane to yield.** `.pane-column` relaxes from `width:260px; min-width:200px; flex-shrink:0` to `min-width:clamp(140px,18vw,260px); flex-shrink:1` (collapsed strips stay rigid 44px). Inspector-overlay container-query threshold = content floor + inspector width (≈860px), NOT a bare content width (harness Bug 2). At wide bucket the result is byte-identical to today — zero desktop change, measured at 1440/1280.
- **D6 — Anatomy vocabulary lives at TWO sites.** PaneBuilder pane maps gain `role: :nav | :list` + `priority:` (panes[0]=nav/0; intermediate lists priority=idx; last pane :active); the shell stamps `data-role="content"` on `.editor-panel` and `data-role="inspector"` on `.bp-doc-sidebar` from editor assigns. Why: content/inspector are NOT PaneBuilder panes (editor renders from `@editor_doc`, sidebar nests inside it — verified); a builder told to "add an inspector pane" would hunt for something that doesn't exist.
- **D7 — collapse?/3 survives as the wide-bucket reducer.** Display state = f(role, priority, bucket, has_editor); the wide (and standard) pane row is `not collapse?(idx, num_panes, has_editor)` verbatim — reproducing all 9 mapped nav transitions bit-identically. narrow → FULL iff last pane; phone → visible iff (last and no editor), content full-viewport otherwise. Existing pane_builder_test collapse pins are EXTENDED, never superseded.
- **D8 — Wire fence.** Roles/priority decorate PaneBuilder pane maps only — never new Structure.Node types (Go TUI's fromDeskNode drops unknown subtrees) or new serialized fields. Structure.build has exactly 3 callers, all inside barkpark_web (verified repo-wide).
- **D9 — Caps classification is part of the hook's DoD.** `width-bucket` MUST enter `@safe_events` in caps.ex (`:none` tier) or the deny-gate silently halts the event for every non-admin socket AND the comprehensiveness CI test reds — both failure modes reproduced live. The seam is a three-part change: handle_event + hook attr + caps entry.
- **D10 — Beta-focus stays a fenced full-takeover override, not a model input.** `html[data-editor-focus="beta"]` wins over all bucket rules by cascade; it changes zero state collapse?/3 reads (no rebuild_panes on mode flip — proven). The bucket keeps stamping underneath so exiting Beta at any width lands in the correct state.
- **D11 — pane_column's `:flex` attr is retired.** No CSS rule backs `.pane-column--flex`, no caller passes it, and its inline style emits `min-width:0` — the opposite of protection. The content winner is `.editor-panel`, not a revived pane class. The component test pins asserting the dead inline style ("flex: 1.1"/"width: auto") get updated in the same PR.
- **D12 — sidebar_open stays server-default-true; narrow inspector behavior is pure CSS.** Overlay/off-canvas at standard/narrow is a container query on `data-role="inspector"` + `.is-open` — no connect-params seeding (would flash), no server default change. `.bp-doc-field` gains flex-wrap in the same slice (it crowds the moment the sidebar can narrow — verified missing).
- **D13 — Phone drill rides the same model.** phone bucket = single visible surface (content if editor open, else last pane) + a breadcrumb strip INSIDE the pane area — NOT the topbar (avoids nav.ex / open PR #2907 and the nav_parity_sweep DOM-identity fence). Crumbs are `@panes` titles; clicks reuse `expand-pane` nav_path truncation verbatim — zero new server events. Topbar tabs at phone are CSS-hidden only, never server-omitted (the parity sweep locks tab DOM identity across routes).
- **D14 — Restyle = mapping, not authoring.** Consume the already-emitted `var(--text-*)` chrome scale (design/check.mjs Part C gates DECLARATIONS only — consumption is free, verified) and self-host IBM Plex Mono into `api/priv/static/fonts/` + @font-face + `--font-mono` repoint (NOT available to Studio today; cloud's static root is separate — verified). `--cc-*` stays banned in Studio (D25/Part G). Literal-color gates: consume var(--…), update design/exemptions.json atomically if a count changes.
- **D15 — bp-studio-ui-premium D19 is SUPERSEDED, not contradicted.** D19 rejected pane-column work for lack of proven crush; this wave's live measurements (900px viewport → ~21ch; 500px → 0px content pane with NO horizontal scroll — content unreachable) are the new evidence.
- **D16 — root.html.heex is single-owner per round.** One ~5000-line inline style block; two slices touching it never dispatch in the same round. S1 pre-provisions the bucket-attribute CSS AND the breadcrumb CSS contract (`.bp-desk-crumbs` family) so later slices touch only .ex/test files.
- **D17 — task-2532b0a2748e93ba is NOT a false-done baseline.** All 5 desk-structure fixes verified on main (commit 961e76d6f / PR #1186); the anatomy refactor assumes them safely. The unstamped criteria are a bookkeeping chore (backlogged), not missing work.
- **D18 — docs-anchors-check.sh is NOT a local gate.** It hangs 15+ min on this contended checkout (unpruned find over node_modules/.omx — root-caused). CI runs it on clean checkouts; builders prove locally with literal-check + design/check.mjs + targeted mix test. A prune fix is backlogged.

### LAND wave amendments (2026-07-19, D19–D32)

- **D19 — Every builder runs on OPUS.** Fable 5 is spend-limited this session; a fable-assigned slice's builder dies instantly. This OVERRIDES the wave-1 roadmap table's `fable` marks on s1/s3/s4. `builder_model` is not a bp task field — the override is a dispatch-time argument, never a task mutation.
- **D20 — RESCUE, not rebuild.** Round 1 was built and committed but never PR'd (s1 `059421d7e`, s2 `b3d6ac693`, s3 `7eb2e6d8f`). All three rebase onto `origin/main` with ZERO conflicts and pass every blocking gate individually AND stacked (union: 9 files, 554 insertions; 1867 Studio tests + 1096 portable_doc tests, 0 failures; `--warnings-as-errors` exit 0). Why: rebuilding proven, gate-green code is pure waste; from-charter rebuild survives only as a per-slice fallback that the evidence retired.
- **D21 — The cross-epic collision is dead, not live.** #4392 never touched `root.html.heex`; #4393 did (4 `--life-*` token lines inside the GENERATED block) and MERGED mid-survey. No open PR touches `root.html.heex`, `pane_builder.ex`, or `structure.ex`. Why: there is no moving target to race — only a rebase onto a main that already moved.
- **D22 — The true blocking-gate roster for `root.html.heex`.** `web-literal-check.sh` CANNOT see the file (its ROOTS are `web/app` + `web/components`). The real guards are `scripts/studio-literal-check.sh`, `node design/check.mjs` (Part E ratchet — `root.html.heex` pinned at 165, fails on growth AND shrink, and `lit-allow` does NOT exempt it), `scripts/paper-editor-mirror-check.sh` (`.bp-canvas-*` lockstep + generated-token byte compare), `scripts/studio-link-lint.sh` — all in the ONE `doc-gates` job — plus the `elixir` workflow. Why: a wrong roster makes builders prove the wrong things and miss a real gate.
- **D23 — There is no workflow named "Elixir Test".** The workflow is `elixir`; the blocking job is `Test (Elixir 1.18.1 / OTP 27.0)`. `main` has NO branch protection, so "wait for the gate" is discipline, not mechanism. The `Format` job is advisory-by-design and is RED on main — it will be red on every PR of this epic and must never block a merge.
- **D24 — main is GREEN and `434361b79` is NOT a prerequisite.** Its PR #1350 merged 2026-07-08 as `f1c17e8b9` (an ancestor of main); origin/main's test file is byte-identical to the branch's. Cherry-picking it is a no-op or a self-conflict. Why: a phantom prerequisite would serialize the rescue for nothing.
- **D25 — Both bucket globals are canonical.** s1 ships `window.bpWidthBucket` and `window.__bpWidthBucket` as the SAME function `bucket(w, currentName?)`, deliberately aliased. The s1/s4 task-body disagreement is a documentation artifact — s4 may wire to either; do not "fix" it.
- **D26 — D11 is factually false and stands PARTIALLY retired.** `api_tester_live.ex:468/487` are live `:flex` callers. s2 correctly retired only the dead `.pane-column--flex` class join and left its criterion 4 honestly unmet; `spd-bl-api-tester-flex-retire` owns the remainder. Never re-dispatch a builder to force full D11.
- **D27 — The phone breadcrumb renders as a SIBLING before `<.pane_layout>`, never inside it.** `.pane-layout` is a nowrap ROW flex (`root.html.heex:1098`), so a crumbs child renders as a left sliver; its parent `.studio-shell` is a COLUMN flex where the pre-provisioned strip CSS (min-height 36px, border-bottom, overflow-x auto) is correct with zero new CSS. Why: this keeps s6 off `root.html.heex`, honoring D16 and letting Round 3 fan out.
- **D28 — D16 held.** `.bp-desk-crumbs` / `-crumb` / `-sep` / `--current` ship complete in s1 with no server consumer. Round 3 therefore fans out: s5 owns `root.html.heex`, s6 touches only `.ex` + test files.
- **D29 — `data-role="content"` stamps ALL FIVE `.editor-panel` roots.** paper (`components.ex:98`), media explorer (`:797`), beta (`:861`), classic (`editor.ex:367`), graph (`graph_view.ex:113`). Why: s1's CSS keys on the bare `.editor-panel` class, so the CSS authority has ALREADY classified all five — stamping only three creates a silent split where later `[data-role]` rules skip two panes that `.editor-panel` rules still hit. The floors are inert on media/graph (neither contains `.bp-paper-surface` or `.editor-body`), so inclusion costs one extra file and risks nothing.
- **D30 — `data-role` selectors must be SCOPED.** 130 `data-role` values already exist on the Tasks board surface. Always write `.pane-layout > [data-role="…"]` or `html[data-width-bucket="…"] […]`, never a bare attribute selector. Why: bare selectors leak across surfaces the moment another plugin reuses a value.
- **D31 — What lands is a FLAT 55ch floor, not a 55–70ch clamp.** The crush is fixed and measured (596px = 67.6ch at a 900px viewport vs 290px = 32.9ch on main); the upper clamp is UNBUILT and backlogged as `spd-b7-protected-measure-clamp`. Why: the epic's memory must not record a promise the code does not keep.
- **D32 — Builders branch from `origin/main` explicitly, in isolated worktrees.** The primary checkout is routinely commits-behind and dirty with concurrent sessions' work; local `main` is not main. Why: a worktree cut from local main inherits a stale base plus phantom unpushed commits.

### ADVANCE wave amendments (2026-07-19, D35–D47)

- **D35 — `display_state/4`'s narrow rule closes ZERO pixels of the overflow window; `spd-s4` must actually close it.** Two independent proofs: a browser sweep over 384 configurations found the overflow boundaries **bit-identical** under today's `collapse?/3` and under `display_state/4` (n=1 clean from 700px · n=2 from 744 · n=3 from 790 · n=4 from 844), and an Elixir matrix found `narrow-vs-wide diffs with has_editor=TRUE: []`. The reason is structural: `collapse?/3` already sets `keep_full_nav_count = 1` when an editor is open, which is the same predicate as `idx == n - 1`. So the CSS comment now on main at `root.html.heex:1152-1161` ("Rounds 2–3 remove the overflow itself") is a promise `spd-s4` as briefed did NOT keep. **Ruling:** `spd-s4`'s narrow rule becomes *hide every pane except one 44px back-strip when an editor is open* — server-side `:hidden`, the twin of what phone already does. Measured: this closes the entire 640–1023 narrow band. The interim comment is rewritten to describe the rule that actually ships.
- **D36 — `.bp-secondary-pane` is the last unconditional crush and it belongs to `spd-s4`.** It is a DIRECT flex child of `.pane-layout` (`components.ex:921-926` → `editor_fields.ex:84`), styled `flex: 0 0 360px` at `root.html.heex:2931-2932`, with **no responsive rule at any bucket** — the phone rules hide `.pane-column` and relax `.editor-panel`, and never touch it. Measured with a secondary doc open: 1024px viewport → the row overflows by 80px; **600px → editor panel 240px · 500px → 140px · 375px → 15px, with `rowOverflow = 0` in every case** — the D34 scroll valve never fires because there is nothing to scroll. The document is annihilated silently. This is precisely the failure the epic exists to eliminate, still fully alive; it ships in `spd-s4` (bucket-scoped `display:none` at narrow+phone), not in `spd-s5`'s droppable tier.
- **D37 — The charter lives at `.claude/workflows/bp-studio-space-priority-charter.md`.** Four verifiers independently reported `not_found` for the two paths their briefs named. The rotating slot is not a durable address. Every future brief cites THIS path; the rotating slot is never cited again for this epic.
- **D38 — The 55ch floor floors the BORDER box, so it has never delivered 55ch of text, and the epic's own top criterion FAILS on merged code.** `box-sizing: border-box` is global (`:573`) and `.bp-paper-surface` carries `padding: 56px 40px` (`:3212-3217`), so the readable column is `55ch − 80px`. Live browser measurement at a 900px viewport on the merged CSS: **n=2 → 516px = 51.5ch · n=3/4 → 480px = 47.9ch**, against a criterion of ≥55ch. D31's recorded headline "596px = 67.6ch at a 900px viewport" is wrong twice — it measured the border box and divided by an assumed ~8.8px/ch when the real advance is 10.01px (Iowan) / 11.05px (Georgia); 8.8px/ch is the **chrome** font (Inter@14px = 8.75px), so `spd-b7`'s measurement never rendered the paper font. **Ruling:** the floor becomes `calc(55ch + 80px)`, gated behind `@container content (min-width: 720px)`. The gate is load-bearing — an ungated raised floor would exceed the 560px panel and (see D39) newly materialise a horizontal scrollbar at every narrow width.
- **D39 — The failure surface is `.editor-body`, not `.editor-panel`; assertions must target it or they pass vacuously forever.** `.editor-body` declares only `overflow-y: auto` (`:1563`), so the spec promotes `overflow-x` to `auto` and IT becomes the scroll container — `.editor-panel`'s `overflow: hidden` is never reached (measured: `PANEL_scrollW == PANEL_clientW == 560` even while the surface was forced to 773px). Measured `bodyXScroll: true` at 900px under Georgia, `false` under Iowan — **so a builder validating on a Mac will never see the failure.** Every measure assertion in this epic runs against `.editor-body.bp-paper-body`'s `scrollWidth <= clientWidth` and against the surface's *content* box, with a non-Iowan fallback font, or it is vacuous.
- **D40 — The `.editor-body` 48ch floor is DEAD and has never applied on the paper path.** `.editor-panel .editor-body { min-inline-size: 48ch }` (`:1230`, specificity 0,2,0) loses to `.editor-with-preview .editor-panel-main { min-width: 0 }` (`:1624`, equal specificity, later source order) — Chrome computes `min-width: "0px"` on the paper editor body in every configuration, and all three real render sites sit inside `.editor-with-preview`. D4's claim that "the same protection extends to `.editor-body`" is false as shipped. `spd-s4` deletes the dead rule and re-lands it ahead of `:1624` (or at raised specificity) so the classic editor genuinely gets its floor.
- **D41 — D33's mechanism is empirically FALSE in Blink; the carve-out stays anyway, and `spd-b10` becomes a tripwire.** A browser A/B of the pre-s1 and post-s1 `.editor-panel` rules found the fixed modal **byte-identical** in both (`x0 w1440 h900`, backdrop still hit-testable 180px outside the panel, card still centred on the viewport), while two positive controls on the same element in the same run — `contain: layout` and `transform: translateZ(0)` — DID promote it. Chrome deliberately does not treat `container-type`'s layout containment as establishing a containing block for fixed descendants. The digest's "Media Explorer New-folder modal is trapped" finding is **refuted twice over** — that modal does not even exist (`media_live.ex` has no folder affordance and no `position: fixed`). But CSS Contain 2 §layout-containment reads the other way, so WebKit/Gecko may yet do what D33 assumed and no ExUnit test can ever see it. **Ruling:** keep `.editor-panel.sheet-editor { container-type: normal }` as cross-engine insurance; re-scope `spd-b10` from "regression guard" to an **inventory tripwire + a CSS-text tripwire forbidding `contain:` / `transform:` / `filter:` / `will-change:` on `.editor-panel`** — the last is the real hazard, because `spd-s5` adds motion in this very wave and a transform on that element would recreate the bug the same wave proved absent.
- **D42 — There are SIX `.editor-panel` roots, not five; D29's census is corrected.** `sheet_grid.ex:2478` (`class={"editor-panel sheet-editor" …}`) is a content root by every CSS authority (it already inherits `min-width: 560px` and `overflow: hidden`; s1 carved it out of *containment* only). D29's own rationale — stamping a subset creates a silent split — applies verbatim. `spd-s4` stamps all six.
- **D43 — `spd-s5`'s core is ratchet-neutral, PROVEN, and its scope is ORDERED.** A verifier executed the whole core against the live gates step by step: font copy + three `@font-face` blocks → `165/165 Δ0`; `--font-mono` repoint → `Δ0`; **all 175** exact-match `font-size` sites swapped to `var(--text-*)` → `Δ0`; `.text-xs` 11px drift fixed → `Δ0`; final combined diff 199+/177− in one file with all four gates PASS and **`--write` never needed**. Both failure modes were also demonstrated (`GREW 165 → 166` on a hand-written `rgba()`, `SHRANK 165 → 164` on a tokenised hex) and the escape idiom `hsl(var(--bp-shadow-hsl) / α)` — already the file's house style, 102 occurrences — returns the count to 165. **Ruling:** core lands as its own commit; every premium addition (motion, overlay scrim, focus rings) lands as a separately-droppable commit, PR mergeable at any prefix.
- **D44 — Sub-12px chrome sites are NOT remapped this wave.** The `--text-*` scale bottoms out at 12px while 94 desk-chrome sites sit at 11px (72), 10px (19) and 9px (3). Force-mapping them to `var(--text-xs)` is a 1–3px visible density bump across a third of the desk that no gate can see. Only the 175 exact matches (12/13/14/16/20px) and the `.text-xs` utility's own 11-vs-12px drift move; the rest is filed as `spd-b11-subxs-type-scale`. Also: copy the mono stack **verbatim from `design/tokens.json` `font.mono.stack`** — a verifier's improvised stack drifted from it and passed all four gates, because nothing compares them.
- **D45 — Motion is achievable CSS-only, must be authored with a 0.15s literal, and must not ship without a content-pop fix.** Measured: the collapse/expand swap is morph-compatible (`components.ex:576` computes the pane id purely from `pane.title`, so LiveView patches the node rather than replacing it) and a width transition interpolates smoothly at a steady 60fps (31 consecutive rAF deltas 14.9–18.5ms, INP 55ms, CLS 0.0247). But the inner subtree swaps **synchronously in the click tick** — measured `immediateHTML` already collapsed while `immediateWidth` was still 260.2px — so a bare width transition shows a tiny vertical label floating in a nearly-full-width box for ~150ms, which reads as broken, not as reasoning. **Ruling:** ship the width transition PLUS an entry `@keyframes` opacity fade on the strip's own children (the new subtree is freshly inserted, so an entry animation fires naturally where a crossfade cannot), a `@media (prefers-reduced-motion: reduce)` neutraliser, and a **hardcoded 0.15s** — `motion.dur-*` exists in `tokens.json` but is emitted NOWHERE (`grep -rn -- '--dur' api/` returns nothing), and wiring it means editing `emit.mjs`, outside a Studio slice's lane. **Binding on `spd-s4`:** do not make the pane DOM id depend on display state, or this animation is foreclosed.
- **D46 — Collapsed-strip a11y splits across two slices along the D28 file line.** The strip is a plain `<div>` with `phx-click`, no `role`/`tabindex`/`aria-expanded`/focus ring, wearing a chevron-**right** glyph on an action that provably goes **back** (`expand_pane` truncates `nav_path`). This wave PROMOTES it to primary narrow back-nav. A verifier converted it to `<button type="button">` + `aria-expanded` + `aria-label` + mirrored chevron + `aria-hidden` svg and all 26 pane tests, 51 pane/builder tests and the scope-guard test passed unchanged — but a bare `<button>` needs a UA reset (`border/background/font/padding/appearance`) that `.pane-column--collapsed` does not provide, and that CSS lives in `root.html.heex`. **Ruling:** `spd-s5` pre-provisions the reset + `:focus-visible` ring (it owns the file in that round), exactly as s1 pre-provisioned the breadcrumb CSS; `spd-s6` does the markup in `panes.ex`. Neither slice crosses the line.
- **D47 — `spd-s9` gates on a deploy PROOF, not on a merge.** Guerrilla was measured serving **pre-s1 CSS** (`build v0.2.25.1292`, `window.bpWidthBucket` undefined, the old `.pane-layout { overflow: hidden }` rule) more than 70 minutes after Round 1 merged, because push-triggered CI had gone silent repo-wide (`check-runs total_count: 0` on every main commit incl. HEAD). Historical merge-to-live latency, measured from the last successful run, is ~7m27s to restart / ~8m43s to full green. **Ruling:** `spd-s9`'s FIRST acceptance criterion is `ssh … 'cd /opt/barkpark && git log -1'` showing the target commit — a measurement taken without it certifies the bug the wave is fixing. The login path is the D24e ticket flow (proven end-to-end this wave); `resize_page` floors at 500px, so sub-500 widths need `emulate`.

## Roadmap

ROUNDS ARE LAW — a slice never dispatches beside its unmerged dependency, and `root.html.heex`
has exactly ONE owner per round (D16). Round 1 of the ADVANCE wave dispatches immediately;
rounds 2–3 are the lead's post-merge dispatch. Per D19 every model column reads `opus`.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| — | CSS space-priority foundation (the crush fix) | `spd-s1-css-foundation` | **MERGED** `c305c2096` (#4425) | — | opus | large |
| — | Width-bucket server seam, inert | `spd-s2-bucket-server-seam` | **MERGED** `48402968f` (#4426) | — | opus | medium |
| — | Pane anatomy roles + `display_state/4` | `spd-s3-pane-anatomy-roles` | **MERGED** `39ed4ab71` (#4427) | — | opus | medium |
| 4 | Bucket reconciliation — hook live, six `data-role` roots, narrow overflow ACTUALLY closed (D35), secondary pane yields (D36), measure floor corrected (D38/D40) | `spd-s4-bucket-reconciliation` | 1 | — | opus | large |
| 10 | Containment tripwire — fixed-position inventory + a `contain:`/`transform:` ban on `.editor-panel` (D41) | `spd-b10-container-fixed-position-audit` | 1 | — | opus | small |
| L | `api_tester_live.ex` `:flex` residue retired (D26 remainder) | `spd-bl-api-tester-flex-retire` | 1 | — | opus | small |
| 2 | `docs-anchors-check.sh` prune fix (D18) | `spd-b2-docs-anchors-prune-fix` | 1 | — | opus | small |
| 5 | Desk restyle — Plex Mono + `var(--text-*)` + strip a11y CSS pre-provision (D43/D44/D45/D46) | `spd-s5-desk-restyle` | 2 | s4 | opus | large |
| 6 | Phone drill + breadcrumb + strip promoted to a real button (D13/D27/D46) | `spd-s6-phone-drill-breadcrumb` | 2 | s4, bl | opus | medium |
| 7 | Seal — measure-parity pin against the content box (D39), blast-radius acknowledgement, `docs/cards/studio.md` + `docs/ops/merge-gates.md` currency | `spd-s7-parity-guard-card` | 2 | s4 | opus | medium |
| 9 | LIVE PROOF on guerrilla behind a deploy gate (D47) — closes the epic's own 900px criterion | `spd-s9-live-measure-proof` | 3 | s5, s6, s7 | opus | small |

Backlog (published children, future waves): `spd-b1-pane-state-persistence` · `spd-b3-dead-admin-shell-css` · `spd-b4-stamp-2532-criteria` · `spd-b5-navshell-wave2-triage` · `spd-b6-sub500-phone-proof` · `spd-b7-protected-measure-clamp` · `spd-b8-editor-panel-blast-radius` (folded into s7 this wave) · `spd-b9-merge-gates-doc-currency` (folded into s7) · `spd-b11-subxs-type-scale` (D44) · `spd-b12-inspector-overlay-dismiss` (scrim/Esc/aria-modal/focus return — the overlay CSS shipped in s1, the dismissal affordance did not) · `spd-b13-foreign-file-claim-fence` (two ready, unclaimed non-SPD tasks declare `root.html.heex` and `studio_live/components.ex` in their `files` arrays).


## Wave log

- **2026-07-19 — Wave 2 (LAND), Decide.** Ground truth reshaped the wave: the design was already ratified and Round 1 already BUILT on three unmerged branches. Ten verifiers proved all three rebase clean onto `origin/main@567bf6e39`, pass every blocking gate (Part E ratchet unmoved at 165/165), compose when stacked (1867 + 1096 tests, 0 failures), and that the feared tlv `root.html.heex` collision was already merged and harmless. main proven green; `434361b79` proven unnecessary. Decisions D19–D32 ratified. Wave cut: Round 1 = three file-disjoint RESCUE tracks (`spd-s1`/`spd-s2`/`spd-s3` — rebase, gate, PR, merge); Rounds 2–4 (`spd-s4`, then `spd-s5`+`spd-s6`, then `spd-s7`) deferred to the lead's post-merge dispatch. Paper: `studio-space-priority-desk-land-2026-07-19`.

- **2026-07-19 — Wave 2 (LAND), Review. Grade A−.** All three Round-1 rescues landed clean on `origin/main@87463fa3b` with the predicted diffs (s1 one file 171/7; s2 six files 133/2; s3 two files 250/0, additions-only) and each slice gate green. Review found ONE merge-blocking defect that no local gate could see and fixed it in place: **D33 — `container-type` is not free.** `container-type: inline-size` computes to `contain: layout style inline-size`, and LAYOUT containment makes `.editor-panel` a containing block for `position: fixed` descendants, which then also clip inside its `overflow: hidden`. The paper editor's four floating surfaces are SAFE (slash-menu, format-bubble, wikilink-menu and command-palette all `document.body.appendChild`), `.bp-ae-toast` is dead CSS — but `sheet_grid.ex`'s cell context menu is SERVER-rendered inside the panel with viewport coordinates, so it would have opened offset by the panel origin and clipped, at every width. Fix: `.editor-panel.sheet-editor { container-type: normal }` (the sheet surface has no container-queried child, so the carve-out is free). Second review fix: **D34 — the pane row gets a scroll escape valve.** With hard floors on both sides (`.pane-column` clamp + `.editor-panel` 560px) the flex row overflows below ~744px viewport in a drilled-document state, and `overflow: hidden` clipped the TAIL — which is the content pane. `.pane-layout` moves to `overflow-x: auto; overflow-y: hidden`: inert whenever nothing overflows (byte-identical at every ≥1024px desktop), and a scroll rather than a wall in the 640–744px band until `spd-s4`/`spd-s6` remove the overflow itself. Third fix (test-only, s3): pinned `priority == index` for non-`:active` panes, since the `:list` site computes `depth + 1` and nothing guarded the two staying equal. Stacked review-fixed union re-verified: all five CSS gates green (Part E ratchet still 165/165, delta 0) plus **1694 Studio-surface tests, 0 failures**. Ledger audited honest — three slices `in_progress` with per-criterion evidence, merge criteria correctly left for the lead, `spd-s2` criterion 3 an explained miss under D26; new child filed `spd-b10-container-fixed-position-audit`. Final branches: `…-foundat-0-r`, `…-server-seam-l-1` (unchanged), `…-lands-r-2-r`. Next wave: merge Round 1, then `spd-s4`, then `spd-s5`+`spd-s6` in parallel, then `spd-s7`.

- **2026-07-19 — Wave 3 (ADVANCE), Decide.** Movement 1 evaporated before the wave started: `#4425`/`#4426`/`#4427`/`#4428` were all already merged (18:12:03–18:23:13Z, in charter order) with main's own `elixir` workflow green — LAND is a ledger stamp, not work, and the four-round cap gained real slack. Ten verifiers then contradicted the direction on five load-bearing points, and the evidence won every time: `display_state/4`'s narrow rule closes **zero** pixels of the overflow window (D35, proven twice — browser sweep and Elixir matrix); the real remaining crush is `.bp-secondary-pane`, unrestrained at every bucket, which annihilates the document to **15px at 375px** without ever tripping the D34 scroll valve (D36); the 55ch floor floors the **border** box and has therefore never delivered more than ~48ch, failing the epic's own top criterion on merged code, and D31's headline number measured the chrome font (D38); the failure surface is `.editor-body`, not `.editor-panel`, and is invisible on macOS (D39); and the media-modal regression the digest feared does not exist — the modal does not exist, and `container-type` provably does not trap fixed descendants in Blink (D41). Against that, `spd-s5`'s entire core was executed step-by-step against the live gates and proved ratchet-neutral at `165/165 Δ0` throughout (D43), and the collapse morph was measured animating at a steady 60fps (D45). Wave cut: Round 1 = four file-disjoint slices (`spd-s4` widened to actually close the overflow, plus `spd-b10`/`spd-bl`/`spd-b2`); Round 2 = `spd-s5`+`spd-s6`+`spd-s7` after s4 merges; Round 3 = `spd-s9`, the live proof, behind a deploy gate. Paper: `studio-space-priority-desk-advance-2026-07-19`.

### PROVE wave amendments (2026-07-19, D48–D66)

- **D48 — ADVANCE Round 1 is fully LANDED, in the correct order.** `#4470` (spd-s4, the spine), `#4471` (containment tripwire) and `#4473` (docs-anchors prune) merged at 20:24Z (`b2eb77629`); `#4472` (api_tester `:flex` retire) merged at 20:40:43Z (`d2c5900dc`) after its `pr-task-gate` false-done was cleared. `git merge-base --is-ancestor b2eb77629 d2c5900dc` → true, so the stacked-merge hazard did not fire. Residue: `spd-bl`'s merge criterion is still stamped `met:false` — lead bookkeeping, not work.
- **D49 — THE HEADLINE CRITERION IS MET, BY LIVE MEASUREMENT, AND THE "INFERENCE IS ALWAYS WRONG" PRIOR IS RETIRED.** On deployed guerrilla (`/opt/barkpark @ b2eb77629`), authenticated Studio, a real paper document, 900px viewport: `.editor-panel` computes to **exactly 856px** as traced, clears the `@container content (min-width: 720px)` gate, and the surface renders at its own `max-width: 720px` — **content 640px = 63.95ch (native Iowan) / 57.93ch (forced Georgia)**, `selectorMatched:1`, no horizontal overflow (`body_scrollWidth 850 == clientWidth 850`). This is the epic's fifth trace-vs-browser test and the **first the trace won**; the four prior overturns (D35/D36/D38/D40) were all about *which selector, font or box* was measured, not about CSS reasoning being unreliable. **Ruling:** `ch` is font-dependent by ~10% (Iowan 10.008px/ch vs Georgia 11.047px/ch, while `m`-width differs by 0.1%), so **every ch figure in this epic must name its font**, and `spd-s9` publishes both columns. Bare `serif`/`ui-serif` is BANNED as a probe face: it measured *narrower* than both (140.01 vs 158.38 for 10×m) and would inflate `ch`, masking the exact bug D39 exists to catch.
- **D50 — `spd-s5`'s two named CSS targets are STRUCK, not annotated.** `.bp-secondary-pane`: s4 shipped `display:none` at narrow+phone, it renders **zero times in the DOM at every tested width** on a paper document, and the residual standard-bucket `flex: 0 0 360px` is orphaned even from its own gate — no acceptance criterion anywhere names it, and `task-2d359bf4fbe44929` already scopes the remaining server-honesty gap away from s5/s6 in its own words. `.sheet-toolbar`: already carries unconditional `flex-wrap: wrap; row-gap: 4px` under an authored comment reading "Unconditional (NOT media-queried)", and renders zero times on the paper surface. **Ruling: WRAP is the shipped mechanism and the intended one; "scrolls instead of clipping" is struck.** Both sentences are deleted from `spd-s5`'s Purpose block, its definition-of-done list and its description item (f) — a task doc whose four layers disagree makes a correct builder wrong.
- **D51 — The motion cage bites, and its two escape holes are real bugs with green CI.** Proven against `#4471`'s merged test: a `transform:` planted in the bare `.editor-panel { … }` block fails at `editor_panel_containment_test.exs:222` with `` `.editor-panel` declares `transform:` ``; an inner wrapper, a modifier selector and a descendant selector all PASS; **`transition: flex-basis/max-width/opacity` in the bare block PASSES** (`transition` is not in the ban list); **`will-change:` FAILS by property NAME at any value**, even `will-change: flex-basis`. Two holes: (i) `html[data-width-bucket="narrow"] .editor-panel { transform: … }` is invisible to the extractor's `~r/\n\s*\.editor-panel\s*\{/` — and a bucket-prefixed rule is the single most likely shape for this wave's motion; (ii) `Regex.run` takes the FIRST match, so a duplicate bare rule placed *after* the canonical one is never inspected. **Ruling:** the collapse motion goes on `.pane-column` / `.pane-column--collapsed` — a **sibling** of `.editor-panel`, outside the cage entirely and already the element that changes width. No `transform` on `.editor-panel` under any prefix; no `will-change` in the bare block, ever.
- **D52 — The inspector scrim is `position: absolute`, never `fixed`.** A planted `.bp-inspector-scrim { position: fixed; … }` fails a SECOND test in the same file — the hardcoded 13-entry `@fixed_css_inventory` census at `editor_panel_containment_test.exs:313` — which is **not in `spd-s5`'s file lane**, so a builder writing the obvious rule reds a gate it cannot fix. Absolute is also the correct design: the overlay is `position: absolute; inset: 0 0 0 auto` anchored to `.editor-panel`'s `position: relative`, so a `fixed` scrim would cover the viewport rather than the panel. **Ruling:** `position: absolute; inset: 0;` inside the same `@container content (max-width: 860px)` block, `background: hsl(var(--bp-scrim-hsl) / 0.55)`, `z-index` one below the sidebar's 5. `spd-s5` does not edit `editor_panel_containment_test.exs`.
- **D53 — There are TWO colour gates with INVERSE blind spots, and the ratchet fails on SHRINK.** Measured on merged main (`165/165 Δ0` baseline intact post-#4470): `rgba(0, 0, 0, 0.55)` — the natural scrim spelling — **FAILS Part E (165→166) while `studio-literal-check.sh` reports PASS** (it does not scan rgb/rgba values by design); `var(--paper-accent, #1e5347)` fails Part E while literal-check passes (its `--paper-*` allowlist masks the line); `lit-allow` gives Part E **literally zero cover** (`165 → 166`, run FAILED, while literal-check went green on the same byte). Conversely, tokenising an existing literal **SHRANK 165 → 164 and failed just as hard** — an incidental tokenisation must LOWER the baseline in the same diff. The sanctioned escapes, each proven `Δ0`: `outline: 2px solid var(--ring)` (bare, 8 live uses), `hsl(var(--bp-scrim-hsl) / α)`, `hsl(var(--bp-shadow-hsl) / α)`, and any colourless `transition`/`@media (prefers-reduced-motion)`. **Ruling:** every brief touching `root.html.heex` names BOTH commands — `bash scripts/studio-literal-check.sh` AND `node design/check.mjs` — because a green Studio gate is not evidence of a green ratchet.
- **D54 — `spd-b12` is re-scoped by measurement and must NOT be closed by `spd-s5`.** The dismiss affordance **exists**: `<button class="bp-doc-sidebar__collapse" phx-click="sidebar-toggle-panel" aria-label="Collapse document panel">` is live inside the panel. The real gaps are `scrim: 0`, `role: null`, `aria-modal: null`, no Esc, no focus return — and b12's declared file is `studio_live/components.ex`, **`spd-s6`'s lane, not `spd-s5`'s**. **Ruling:** `spd-s5` takes ONLY the scrim + elevation (its own file, D52); "close affordance" is struck from the wave's language as already shipped; `spd-b12` stays OPEN for its `.ex` half and is not named in `spd-s5`'s PR.
- **D55 — The collapsed strip's `class` attribute is FROZEN byte-identical.** A real `<div>`→`<button type="button" … aria-expanded="false">` swap was applied and the suites RUN: **43 tests, 0 failures** — every assertion in the blast radius is a substring or a CSS selector, and `render_click()` works identically on a `<button>`. But adding ONE class fails 2 tests, because `studio_live_width_bucket_test.exs:102` defines `strip_count` as `~r/class="pane-column pane-column--collapsed"/` — an exact match *including the closing quote* — and `pane_count` (`:101`) forbids prepending. **Ruling:** `spd-s6` may add any attributes (`type`, `role`, `tabindex`, `aria-expanded`, `aria-label`), before or after `class`, but must leave `class="pane-column pane-column--collapsed"` byte-identical — no interpolation, no reorder, no new class. **Binding on `spd-s5`:** the UA reset + `:focus-visible` ring must target the EXISTING selector (`.pane-column--collapsed` / `button.pane-column--collapsed`); it cannot expect a hook class from s6, or it ships a ring that selects nothing.
- **D56 — NEW, HIGH: at phone width the desk has NO back-navigation at all, and `spd-s6` is therefore not droppable.** Measured at 500px: `strips: 0`, `crumbs: 0`. The deployed rule `html[data-width-bucket="phone"] .pane-layout:has(> .editor-panel) .pane-column { display: none; }` hides the 44px strip that D35 made the only route back, and `grep 'bp-desk-crumbs|breadcrumb'` over deployed `panes.ex` + `components.ex` returns **nothing** while `.bp-desk-crumbs` CSS sits fully pre-provisioned. Open a document on a phone today and you cannot get out. **Ruling:** `spd-s6` closes a live navigational dead-end, not a polish item; it ships in the minimum mergeable wave.
- **D57 — The inspector overlays the document it annotates, unscrimmed, at three of six widths.** Live: `.bp-doc-sidebar.is-open` is `position: absolute; z-index: 5`, 300px wide, `scrim: 0` at every width, and it starts LEFT of the surface's right edge at 1024px (724 vs 714), 900px (600, ~232px of a 720px surface), 640px (~50%) and 500px (~60%). The ≥55ch figure is a **layout** measurement; the *visible* measure at 900px in the default state is roughly 408px. **Ruling:** this does not invalidate D49 (the criterion is about the box), but `spd-s9`'s matrix must record the inspector's default state and its overlap alongside the layout number, or the matrix reads as spin.
- **D58 — The 640–763px band is a KNOWN, DELIBERATE gap and `spd-s9` pre-declares it.** Gate reachability is panel ≥ 720px ⇒ viewport ≳ 764px. At 640px the panel is 596px, `min-inline-size` computes to `0px`, and the surface fills the panel: **510px = 50.96ch**, below the floor, with no horizontal scroll (deliberate — an ungated floor would materialise a scrollbar). 640px is one of `spd-s9`'s six widths, so its row reads as a regression unless the brief says so in advance. Filed for a future wave as `spd-b15-narrow-band-floor-gap`.
- **D59 — `spd-b14-measure-floor-font-audit` folds into `spd-s9`.** It quantifies a risk that never reached this charter: the `calc(55ch + 80px)` gate was sized from two measured faces only, and any reading face above ~11.6px/ch pushes the floor past 720px, re-materialising the D39 scroll in the thin band just above the gate. **Ruling:** `spd-s9` measures the per-face `ch` advance for Iowan, Georgia AND self-hosted Source Serif 4 (the face most non-macOS users actually get, and the one nobody has ever measured), reports the resulting floor width per face, and the lead retires b14 on s9's close.
- **D60 — Line numbers are BANNED from this epic's briefs.** Every single line-number citation checked this wave was wrong: `--font-mono` is `:113` (docs said `:67`/`:134`), `.text-xs` is `:640` (said `:661`), `.bp-secondary-pane` is `:2995` (said `~2732`), `.pane-column--collapsed` is `:1507-1530` (said `:1443-1466`), the collapsed strip is `panes.ex:106-123` (the wish and the direction both said `:87`), and the bare `.editor-panel` rule is `:1604`. D40's "dead bare rule at `:1230`" exists in **no commit on any branch** — the charter narrated an uncommitted draft as history. **Ruling:** briefs route by pattern/selector only; a line number in a brief is a defect.
- **D61 — The primary checkout is NOT a source of truth for this wave.** It is 47 commits behind `origin/main` with 7 unpushed charter commits and a large dirty diff from a concurrent session, and `api/lib/barkpark_web/components/layouts/root.html.heex` — the path the wish names — **does not exist**; the real path is `api/lib/barkpark_web/layouts/root.html.heex`. Builders cut worktrees from `origin/main` (D32) and never read this working tree. Corollary proven this wave: `mix test` cannot run in a fresh worktree (no `deps/`), but `editor_panel_containment_test.exs` loads nothing from the app and runs standalone in 0.5s via `elixir -e 'ExUnit.start(autorun: false); Code.require_file(hd(System.argv())); ExUnit.run()' <file>`.
- **D62 — The search verb is `bp search query "<text>"`.** Nine surveyors in one round, plus a prior wave five days earlier, recorded `bp search` as having "no working verb". `bp search "<text>"` returns a usage-error JSON **and exits 0**, so scripted callers cannot detect the failure; `barkpark` is an ssh alias on this host, not the CLI. Searching the corpus with the right verb surfaced `spd-b14` — an open task that all sixteen surveyors missed.
- **D63 — Deploy durability is proven and slot colour must be queried, never assumed.** `deploy.yml` anchors its diff base to the last **successful** run, so a failed run self-heals on the next push to a deploy path (verified: a 06:38Z SSH-drop failure was swept up by the 08:09Z success); the manual recovery for "nothing pushed since" is `gh run rerun <run-id> --failed`. Prod deploy is `git fetch` + `git reset --hard FETCH_HEAD`, not `git pull`, so untracked scratch on the box cannot block it. The digest's "only green is loaded" claim is **wrong right now** — `barkpark-slot@blue.service` is active and owns port 4000. **Ruling:** the liveness proof is `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "cd /opt/barkpark && git fetch -q origin main && git merge-base --is-ancestor <SHA> HEAD && echo LIVE || echo STALE"` (ancestor-based, so it stays correct when the box is ahead), and the slot is read live via `systemctl list-units 'barkpark-slot@*' --all --no-legend`.
- **D64 — The claim fence widens from two tasks to four, and none of them are folded in.** `scaffy-backlog-blocks-editable-studio` and `spd-b3-dead-admin-shell-css` declare `root.html.heex`; `sup-w5bk-beta-doc-editor-savestate` declares `studio_live/components.ex`; `spd-b9-merge-gates-doc-currency` declares `docs/ops/merge-gates.md` — all four are open, unclaimed and present in the live `bp task ready` queue, and all four collide with this round's sole-owned files. **Ruling:** the lead fences all four for the duration of the round. `spd-b3` is explicitly NOT folded into `spd-s5`: it is a deletion, and D53 proves a deletion that tokenises or removes a literal reds Part E on SHRINK — a free-looking fold that costs the wave its gate. `spd-b9` is retired as a duplicate once `spd-s7` lands.
- **D65 — The epic's own criteria get owners.** Criterion 1 (≥55ch at 900px) is `spd-s9`'s, already declared. Criterion 3 (Structure wire contract) was **wholly unowned** — no task in any round references `structure_controller_test` or the Go TUI allowlist — and moves to `spd-s7`, which runs both once and stamps evidence (the wire fence is respected structurally; this is a proof, not work). Criterion 2 (desktop ≥1280px unchanged) is jointly evidenced by `spd-s7`'s wide-bucket DOM pin and `spd-s9`'s 1440/1280 rows; the lead closes it. Criterion 0 is lead bookkeeping. Separately: `spd-s1`'s criterion 0 sits `met:true` on the `596px = 67.6ch` figure D38 refuted twice — filed as `spd-b16-s1-criterion-evidence-correction`, because a child ledger that lies is the disease this epic keeps catching.
- **D66 — `spd-s7`'s brief is wrong in both directions and both are corrected.** The claim that `merge-gates.md` "names a workflow called Elixir Test" is FALSE — `grep -c 'Elixir Test'` returns 0; the doc correctly uses `mix-test`. The REAL gap: `doc-gates.yml` runs **17 blocking steps** while the doc describes 2, never mentions `root.html.heex`, and names none of the four scripts that gate it (`studio-literal-check.sh`, `design/check.mjs`, `paper-editor-mirror-check.sh`, `studio-link-lint.sh`); `merge-gates.md` has **no byte cap at all**, so there is room. And the "do NOT run `docs-anchors-check.sh` locally" caution is now stale — `#4473` made it run in **49s clean** on this contended checkout, so criterion 6 is achievable and must be run. `docs/cards/studio.md` has **7 bytes** of headroom (2393/2400, and the 7-card count is unsplittable); the anchor line must read `def build; def display_state` — a comma-joined `def build, display_state/4` silently verifies only `build` AND busts the cap by 1 byte, one defect that reads as two.

## Roadmap — PROVE wave (wave 4)

Round 1 dispatches immediately (four file-disjoint slices). Round 2 is the lead's post-merge
dispatch, behind a deploy proof (D47/D63). Per D19 every model column reads `opus`.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| 5 | Desk restyle — Plex Mono + `var(--text-*)` core, then droppable motion / scrim / rings (D43/D50/D51/D52/D53/D55) | `spd-s5-desk-restyle` | 1 | — | opus | large |
| 6 | Phone drill breadcrumb + the strip becomes a real button — closes a live dead-end (D55/D56) | `spd-s6-phone-drill-breadcrumb` | 1 | — | opus | medium |
| 7 | Seal — measure-parity pin, blast-radius, `studio.md` + `merge-gates.md` currency, epic criterion 3 (D65/D66) | `spd-s7-parity-guard-card` | 1 | — | opus | medium |
| 10f | Containment census extended to `api/assets/paper-editor/src/styles.css` (spd-b10's own declared blind spot) | `spd-b10f-fixed-census-paper-editor-css` | 1 | — | opus | small |
| 9 | LIVE PROOF on guerrilla behind a deploy gate — six widths × two faces, honest either way (D47/D49/D57/D58/D59/D63) | `spd-s9-live-measure-proof` | 2 | s5, s6, s7 | opus | small |

Backlog additions this wave: `spd-b15-narrow-band-floor-gap` (D58) · `spd-b16-s1-criterion-evidence-correction` (D65) · `spd-b17-containment-extractor-escape-holes` (D51) · `spd-b18-btn-focus-visible-desk-wide` (`.btn` has no `:focus-visible` at all; 29 rules exist to copy) · `spd-b19-charter-push-durability` (the durable charter still lives only in unpushed local commits).

## Wave log

- **2026-07-19 — Wave 4 (PROVE), Decide.** The probe the direction wanted to run early ran, and it **won**: on deployed guerrilla at 900px the content measure is **640px = 63.95ch (Iowan) / 57.93ch (Georgia)** — the epic's headline criterion is met by live measurement for the first time, and the "inference has a 100% error rate" prior is retired (D49). The expensive findings were the ones the trace could not see: at phone width there is **no back-navigation at all** (strips 0, crumbs 0 — D56), the inspector overlays up to ~60% of the document unscrimmed at three of six widths (D57), and the strip's chevron points RIGHT on an action whose own title says "Back". That reframes the wave: the premium tier is load-bearing, not decorative. Verification also struck both of `spd-s5`'s named CSS targets as already-shipped or non-existent (D50), proved the motion cage bites with two silent escape holes (D51), proved the scrim must be `absolute` or it reds a census `spd-s5` does not own (D52), proved the two colour gates have **inverse** blind spots and that the ratchet fails on SHRINK (D53), and proved the strip's `class` attribute is frozen byte-identical by an exact-match regex while a `<div>`→`<button>` swap breaks **zero** of 43 tests (D55). `spd-b12` was re-scoped by measurement — the dismiss button already exists (D54). Wave cut: Round 1 = `spd-s5` + `spd-s6` + `spd-s7` + `spd-b10f`, file-disjoint; Round 2 = `spd-s9` behind a deploy proof. Paper: `studio-space-priority-desk-prove-2026-07-19`.

- **2026-07-19 — Wave 4 (PROVE), Review. Grade A.** Round 1's four file-disjoint slices all built green and all four **compose**: merged together onto `origin/main@b7d6ce8ee` the union runs **1709 Studio-surface tests, 0 failures**, with every CSS gate green — `studio-literal-check` PASS, **Part E ratchet 165/165 Δ0**, `paper-editor-mirror` PASS, `studio-link-lint` PASS, `check-doc-budgets` PASS (studio.md 2398/2400, card count 7), `docs-anchors-check` PASS. That is the first wave of this epic where the cross-slice union was proven rather than assumed.

  **What landed.** `spd-s5` — four ordered, independently-droppable commits: IBM Plex Mono copied byte-identical from `cloud/priv/static/fonts/` (three discrete non-variable `@font-face` blocks, `fonts` already in `static_paths/0`), `--font-mono` repointed to `design/tokens.json font.mono.stack` **verbatim** (verified string-equal on both sides), 126 exact-match chrome font-size sites remapped to `var(--text-*)` by MARKER lookup with **zero in-scope residue** and zero edits inside the GENERATED or paper/Sheets fences, the `.text-xs` 11-vs-12px drift resolved to the token; then motion on `.pane-column`/`--collapsed` (outside the D51 cage) with a scoped `prefers-reduced-motion` block that nulls the transition and not merely the animation; then the D52 `position: absolute` scrim with the sidebar shadow raised to the overlay tier; then `:focus-visible` rings and the pre-provisioned `button.pane-column--collapsed` UA reset on the EXISTING frozen selector. `spd-s6` — `desk_crumbs/1` as a SIBLING before `<.pane_layout>` (D27), crumbs reusing the existing `expand-pane` with the same `Enum.take(nav_path, idx)` truncation (zero new server events, zero `caps.ex` entries), and the collapsed strip converted to a real `<button type="button">` with `aria-expanded`/`aria-label`/`aria-hidden` and the chevron mirrored left — `class="pane-column pane-column--collapsed"` verified byte-identical as a diff CONTEXT line (D55 honoured), and `studio_live_width_bucket_test.exs`'s 43 tests untouched and green. `spd-s7` — `measure_parity_test.exs` whose `blocks!/2` asserts **selector-match-count > 0 before any value comparison** and names the vanished selector (proven by a deliberate break producing `SELECTOR MATCHED ZERO RULES`), the two floors discriminated per D39/D40, parity **derived** from the reader's own parsed `padding: 56px 40px` rather than double-hardcoded, the six-root `.editor-panel` blast radius discovered-and-pinned, `studio.md` given the space-priority anatomy at 2398/2400 with the anchor line reading `def build; def display_state`, and `merge-gates.md` corrected with the real 17-step doc-gates roster + D53's inverse blind spot. `spd-b10f` — the containment census extended to `assets/paper-editor/src/styles.css`, its one `position: fixed` selector classified `:body_portal` against the actual `document.body.appendChild`, with a non-vacuity guard proven in BOTH directions by experiment.

- **D67 — the pre-provisioned crumb CSS had two defects that only go live when something renders it.** Review fix on `spd-s5`'s branch (it owns `root.html.heex`): `.bp-desk-crumb` never reset the UA **button font-family**, so the moment `spd-s6` rendered ancestor crumbs as real `<button>`s the phone trail became the one piece of desk chrome not set in `var(--font)` — the UA font-SIZE was overridden, the family was not. And `.bp-desk-crumb--current` is a document TITLE (arbitrary user-authored length) inside `overflow-x: auto; white-space: nowrap` with `flex-shrink: 0` crumbs, so one long title pushes the ancestors you need to tap off the right edge of a 375px phone — recreating the exact dead end D56 exists to close. Bounded to `max-width: 45vw` with an ellipsis; clickable ancestors keep full labels. **Ruling: CSS pre-provisioned for a future slice is UNVERIFIED CSS.** It is written against an element that does not exist, so nothing renders it and no gate can see it — when the slice that renders it lands, its rules must be re-read against the real element, not trusted because they shipped earlier.

- **D68 — the durable charter is restored to a mergeable branch, and `spd-b19` is the standing lesson.** D37 moved the charter to `.claude/workflows/bp-studio-space-priority-charter.md`, but that file has **never existed on `origin/main`**: it lives only in `d9db991fc`, an unpushed commit on the primary checkout's local `main`, which is why `git ls-tree origin/main` finds neither charter path and why four separate agents across two waves reported `not_found` for a path the briefs call canonical. This review restored BOTH files (canonical + the MOVED pointer) onto `spd-s7`'s branch — the wave's docs owner — so the charter merges with the wave instead of waiting on a separate PR. **Ruling: a charter that is not on `origin/main` does not exist for any builder cutting a worktree from `origin/main` (D32/D61). Every wave's review phase pushes the charter or the next wave re-learns this.**

- **The ledger audited HONEST — no fixes needed on this wave's own tasks.** All four builders left `lifecycle: in_progress`, stamped every non-merge criterion with concrete evidence as they worked, and correctly left the "PR merged" criterion `met:false` for the lead. `spd-s9` sits `open` and unclaimed exactly as the sequenced-rounds law requires. Five discovered-but-not-taken items were filed, published and parented to the epic during the run (`spd-b21`, `spd-b22`, `task-a905d8016760e72e`, `spd-b12-merge-gates-byte-cap`, `spd-b18`). The one ledger lie in the epic was inherited, not created: **`spd-s1-css-foundation`'s criterion 0 was still stamped `met:true` on the `596px = 67.6ch` figure D38 refuted twice.** Corrected in place via HTTP mutate + re-publish (the patch needs a `type` key or the endpoint 400s `malformed`) — the evidence now names D38's refutation, carries D49's authoritative `640px = 63.95ch Iowan / 57.93ch Georgia`, credits the floor to `spd-s4` rather than s1, and preserves what was genuinely true (the 700px squeeze proof). `spd-b16` is now bookkeeping the lead can close.

- **Next wave: merge Round 1, then dispatch `spd-s9` alone.** Order: `spd-s5` (`…-core-the-0-r`, carries the review fix) · `spd-s6` (`…-collapsed-str-1`, unchanged) · `spd-s7` (`…-loud-sele-2-r`, carries the charter restore) · `spd-b10f` (`…-fixed-position-ce-3`, unchanged). `.ex`/`.heex` wait for the `elixir` workflow's `Test (Elixir 1.18.1 / OTP 27.0)`; Format is advisory-by-design (D23). THEN, and only after the deploy gate proves guerrilla serves the merge SHA (D47/D63 — `deploy.yml` cancels superseded runs, so verify rather than assume), `spd-s9` measures live and answers the epic's own criterion 1 by measurement. `spd-s9` is the last slice this epic needs to close its headline; everything after it is backlog.

## Wave-5 amendment (BROWSER wave, 2026-07-20) — D69–D83

This wave put a scripted browser on the deployed desk and it overturned the charter in four
places, including one of the charter's own overturns. Decisions D69–D83 are the corrections and
the new law. Where a decision STRIKES a clause of an earlier decision, the earlier decision keeps
its number and its history; the strike is authoritative.

- **D69 — The primary checkout is an ACTIVE source of false negatives; read `origin/main` through `git show`, never grep the working tree.** Three surveyors in one round independently reported the 55ch floor and the `@container content` machinery MISSING from `root.html.heex`. All three had grepped the primary checkout, which is 52 commits behind `origin/main` with 8 unpushed commits. Reproduced: `grep -c 'calc(55ch + 80px)' api/lib/barkpark_web/layouts/root.html.heex` → **0** in the working tree; `git show origin/main:api/lib/barkpark_web/layouts/root.html.heex | grep -c 'calc(55ch + 80px)'` → **1**. That is an overturn manufactured wholly by method. This compounds D61 with its operational consequence: **a stale checkout does not fail loudly, it returns a confident empty grep, and an empty grep is the easiest thing in this epic to mistake for a finding.** **Ruling:** every CSS/Elixir fact in a survey, verify or review report is anchored as `git show origin/main:<path>` (or `git grep <pat> origin/main -- <path>`) after `git fetch -q origin main`, and the report names the ref it read. A `not_found` against an unstated ref is not evidence of absence and may not be cited by any decision. This also applies to GATES: `mix test test/barkpark_web/studio/editor_panel_containment_test.exs` fails in the primary checkout with "did not match any directory/file" — the file exists only on `origin/main`. Gates are dry-run in a worktree cut from `origin/main`, never in the primary checkout.

- **D70 — `640` is two different quantities in this epic and must never appear bare again.** `640px` is both the CONTENT measure at a 900px viewport (D49's headline) and a VIEWPORT width in the matrix (D58's band). A reader one wave out cannot tell them apart. **Ruling:** every number in this epic's decisions, matrices and criteria carries its axis explicitly — `viewport 640px` vs `content 640px` — and the instrument emits them as distinct JSON keys (`viewport_px`, `content_px`), never as prose.

- **D71 — D63's slot snapshot is STRUCK. Record the COMMAND, never the colour.** D63 stated "`barkpark-slot@blue.service` is active and owns port 4000". A live read this wave returns exactly one loaded unit — `barkpark-slot@green.service loaded active running` — and blue is not a loaded unit at all. The charter has now carried two mutually contradicting slot snapshots. **Ruling:** slot colour is deliberately NOT recorded in this charter; it flips on every blue/green deploy, so any snapshot is wrong within one merge. Query it: `systemctl list-units 'barkpark-slot@*' --all --no-legend`. D63's deploy-durability and ancestor-check rulings stand unchanged. Any future decision that states a slot colour as fact is a defect, not an update.

- **D72 — D58's "510px = 50.96ch at viewport 640px" is REFUTED by the browser, and it was the `− 80` bug.** Two independent live probes on deployed guerrilla read `getComputedStyle('.bp-paper-surface').paddingLeft/Right` = **24px / 24px** at viewport 640 (the `@media (max-width: 767px)` rule IS applying), giving a surface border box of 590–596px and a **content measure of 542–548px = 54.2–54.8ch (Iowan) / 49.1–49.6ch (Georgia)**. One probe reproduced D58's exact figures from its own naive path: `surfaceW − 80 = 510`, `510 / 10.0078 = 50.96` — bit-identical. D58 was never a padding-aware measurement; it is D38's failure mode wearing a live-reading label, and it sat on the load-bearing input of the epic's next design decision. **Ruling:** the gutter is READ from the browser, never hardcoded. Anyone computing `content_px = element_width − 80` below viewport 767px is reproducing D38 in the exact rows the band exists to interrogate. D58's structural claim (the band is a deliberate gap; the floor computes `0px` there) stands; its numbers do not.

- **D73 — D60's fabrication clause is STRUCK: D40 was right, line number included. This epic has now overturned one of its own overturns.** D60 stated that D40's "dead bare rule at `:1230`" exists in "no commit on any branch — the charter narrated an uncommitted draft as history". `git show c305c2096:api/lib/barkpark_web/layouts/root.html.heex | sed -n '1230p'` prints exactly `.editor-panel .editor-body { min-inline-size: 48ch; }`, and `c305c2096` is `spd-s1` as merged (#4425). The clause was produced by grepping a tree where `spd-s4` had already replaced the rule. **D40's diagnosis, its citation and its ruling were all correct, and its ruling shipped:** on `origin/main` the floor is re-landed at raised specificity and narrowed to the classic editor — `.editor-panel .editor-body.editor-panel-main:not(.bp-paper-body) { min-inline-size: 48ch }` at (0,4,0), which outranks `.editor-with-preview .editor-panel-main { min-width: 0 }` at (0,2,0) regardless of source order, with a matching (0,5,0) phone neutraliser, both pinned by `measure_parity_test.exs`. A live `48ch` grep hit is the FIX, not the ghost; the D40-vs-D60 contradiction is CLOSED. **D60's policy stands — line numbers remain banned from briefs — but its reason is restated honestly: line numbers ROT across merges; they are not evidence of authorial fiction. And an overturn is itself a claim: a decision that accuses a prior decision of fabrication must carry the exact command whose output proves the absence, run against a named ref.**

- **D74 — D49 splits: the layout claim survives, its overflow detail is withdrawn, and its ledger stamp is still owed.** The 900px reading is re-derived independently this wave — `.editor-panel` 856px, surface at its own `max-width: 720px`, **content 640px = 64.0ch (Iowan) / 57.93ch (Georgia)**, `selectorMatched: 1` — so D49's headline holds. Two corrections. (a) The clause "no horizontal overflow (`body_scrollWidth 850 == clientWidth 850`)" is **withdrawn to unsourced**: `850` and `scrollWidth` appear zero times in the 985-line PROVE-wave paper that produced it, and 850 is unexplained at a 900px viewport. Overflow is measured against `.editor-body.bp-paper-body`'s `scrollWidth` vs `clientWidth` (D39's real scroller), and the live read is **no horizontal scroll at any measured width**. (b) **A decision is not a stamp.** The epic task's criterion 1 has read `met: false, evidence: ""` for the whole time D49 has claimed it met. D49 is worth nothing to the ledger until `spd-s9` writes the number into it.

- **D75 — `calc(55ch + 80px)` IS DEAD CSS AT EVERY REACHABLE VIEWPORT. The floor this epic has litigated for four waves has never once bound.** The floor is gated `@container content (min-width: 720px)`. `.editor-body.bp-paper-body` has `padding: 0`, so available width on the paper path equals `.editor-panel`'s width. The floor resolves to **630.591px (Iowan) / 687.632px (Georgia)** — both BELOW 720. Therefore whenever the gate is ON, available ≥ 720 > floor, and whenever available < 720 the gate is OFF. Measured `floorBinds: false` at **1440 / 1280 / 1024 / 900 / 830 / 790 / 768 / 764 / 700 / 640 / 500 — eleven for eleven.** The surface reaches its own `max-width: 720px` before the floor is ever consulted. This is D40's shape one level up: a rule that reads correct, tests green, and closes zero pixels. **Ruling:** the epic's headline number at 900px is delivered by `max-width: 720px`, not by the protected floor. No decision may credit the floor with a measured pixel until a browser reads `floorBinds: true`.

- **D76 — The gate measures the WRONG BOX, and that is the epic's real, unreported defect: viewport 1280px FAILS the ≥55ch criterion.** The container `content` is declared on `.editor-panel`, which holds BOTH the document column AND the docked inspector. At viewport 1280 (`wide` bucket) the panel is 976px — comfortably past the 720px gate — but the inspector is DOCKED at 300px, so the document column gets **676px** and the content measure is **596px = 59.6ch (Iowan) / 53.95ch (Georgia): below the criterion, at a mainstream desktop width, with no horizontal scroll and no signal of any kind.** The same mechanism is reproducible from the other direction: injecting the real `.bp-secondary-pane` (`flex: 0 0 360px`, live at `wide`/`standard`) at 1280 drops `.editor-panel` 976 → 616, which falls UNDER the gate, so `min-inline-size` computes 630.591px → **`0px` — the floor switches ITSELF off** — and the measure falls to 530px = 52.96ch, silently. **The protection mechanism disables itself under exactly the pressure it exists to resist (D36's signature).** **Ruling:** the floor must be gated on, and applied to, the box that actually holds the reading column, not the pane that holds the column plus its neighbours. This is the epic's endgame slice and it is gated on the wave-5 matrix confirming the 1280 row per face.

- **D77 — M3 (`--paper-gutter` unification) is CONFIRMED as a coherence fix and REFUTED as a rescue; it ships fused with D76 or not at all.** The query-base mismatch is real: the surface's gutter is viewport-`@media`'d (56/40 → 48/24 below 767px → 32/16 below 479px) while the floor is `@container`-gated and hardcodes `80px`. But unifying it moves the floor to `55ch + 48px` ≈ 598.6px, still under the 720px gate, so it changes **zero pixels at zero widths** (D75). It is still worth shipping — as the mechanism that keeps a viewport-scoped gutter and a container-scoped floor in step — but only alongside D76's re-gating, and the brief must NOT promise the 640–763px band. Proven landable: the probe edit breaks exactly **3 of 24** assertions in `measure_parity_test.exs`, two of them as bare `MatchError` crashes (`[_, side] = Regex.run(~r/^\d+px\s+(\d+)px$/, padding)` returns nil against a `var()` value; the `calc\(…(\d+)px\)` addend regex likewise), one as a clean literal-pin failure; the amended file is **25 tests, 0 failures** and is NET STRONGER, because the old `addend == 2 * side` assertion goes tautological once both sides read one token and is replaced by a multiplier pin, a consumption pin, and a NEW breakpoint-desync guard (every `.bp-paper-surface` block nested in a `max-width` at-rule must BOTH redeclare `--paper-gutter` AND consume it). All three protective mutations red correctly. Both colour gates move by **Δ0** (`design/check.mjs` PASS 18 surfaces; `studio-literal-check` PASS 367 files) and `calc(55ch + 2 * var(--paper-gutter))` computes byte-identical to the shipped literal in Blink. **Ruling: `measure_parity_test.exs` is `spd-s7`-owned and its moduledoc declares itself read-only over `root.html.heex`. Any brief that edits the floor MUST grant explicit edit rights to that test file, or the builder lands in a MatchError inside a fenced file.**

- **D78 — `.modal-backdrop` has NO CSS rule anywhere in `api/`, so it is an in-flow flex child of `.pane-layout` and crushes the editor panel to its floor in two clicks.** `editor_fields.ex` emits `class="modal-backdrop"` and `confirm_modal.ex` documents a dependence on it; the only rule that exists is `.bp-ae-modal-backdrop`. Unstyled it computes `position: static; display: block; flex: 0 1 auto`. Live at 1280 on a classic doc, opening "Open another" moved the row from `[strip 44, list 260, editor-panel 976]` to `[strip 44, list 230.4, editor-panel 560, modal-backdrop 445.6]` — the panel pinned to its own 560px floor, `rowOverflow: 0`, no scrollbar, no error. This is user-reachable, affects every `.modal-backdrop` modal in Studio, and **no census covers it**: `spd-b10`/`spd-b10f` inventory `position: fixed` PRESENT, which is the wrong direction to catch a backdrop that has LOST it. **Ruling: the census gains the inverse assertion — every backdrop-shaped class emitted by a Studio component must resolve to an out-of-flow rule.** `.bp-ae-modal-backdrop`'s own `position: absolute; inset: 0; background: hsl(var(--bp-scrim-hsl) / 0.45)` is the sanctioned shape (D53-clean on both colour gates).

- **D79 — The collapsed strip's `aria-expanded` is decorative, and Enter throws keyboard focus to `<body>`.** `spd-s6` shipped a real `<button type="button" class="pane-column pane-column--collapsed" aria-expanded="false">` and the keyboard path works — Tab yields `:focus-visible === true` with the live ring `2px solid rgb(63,207,142)`, offset `-2px`, and Enter activates and navigates. But `aria-expanded` **never flips** (zero elements in the whole document ever carry `aria-expanded="true"`), there is **no `aria-controls`**, so the attribute has no referent, and after activation `document.activeElement` is `BODY` — a keyboard user who tabs to the only route back is thrown to the top of the tab order on using it. That is D54's inspector defect class, now proven on the strip and unowned. **Ruling: an ARIA state attribute that never changes is a lie to assistive technology and is worse than its absence.** The strip is a NAVIGATION control, not a disclosure: drop `aria-expanded`, keep the explicit `aria-label`, and land focus on the newly-expanded pane rather than `<body>`. `class="pane-column pane-column--collapsed"` stays byte-frozen (D55).

- **D80 — The width-bucket sweep must be DESCENDING or reload-per-row; an ascending sweep manufactures its own overturn.** `bucket(w, currentName)` applies the +32px dead-band on the WIDEN side only, and re-anchors it to the bucket currently HELD, so multi-boundary widening must clear every intermediate `edge + 32` in sequence. Live in the real DOM: ascending stamps **viewport 640 → `phone`**, **1024 → `narrow`**, **1280 → `standard`**; descending 1440 → 1280 stamps **`wide`**. Same width, two answers, by path. Three of the matrix's nine widths sit on these edges, and 640-as-`phone` fires `display: none` on `.pane-column` and zeroes all three floors — a completely different layout. Descending ≡ reload ≡ raw band, verified identical at all nine widths. **Ruling: the instrument sweeps descending or reloads per row, and records the sweep direction in every row.**

- **D81 — The cure is an INSTRUMENT, not more prose. It is committed, it is not a CI gate, and every assumption that could rot is READ at runtime and printed.** Four overturns are not bad luck; they are the predictable output of one-shot, hand-driven measurements recorded as English by agents who then evaporated. The harness is proven buildable today: `playwright 1.59.1` resolves from `js/node_modules` with `chromium-1217` already cached and Node 22 present; the D24e login-ticket flow (`POST /v1/auth/login-tickets` with the guerrilla admin token → `GET /login/ticket/<t>`, 60s TTL, single-use, HTTPS hostname required because the session cookie is `Secure`) authenticated end to end and landed on the real scoped Studio, four runs, zero flakes. It is designed so each historical overturn is structurally impossible: it asserts selector match count > 0 before any number is trusted (D31/D39), READS the surface padding instead of hardcoding 80 (D38/D72), converts `ch` via a probe span inserted as a CHILD of `.bp-paper-surface` (D31), tests overflow against `.editor-body.bp-paper-body` (D39), and stamps served SHA, slot, resolved font family and sweep direction into every record. **It claims no gate authority — its only contract is "prints a matrix or fails loudly" — so a rotted run is VISIBLY rotted rather than silently wrong.** Chrome DevTools MCP cannot BE the instrument: MCP calls cannot be packaged as a one-command script, `evaluate_script`'s `args` accept only element uids so literals must be inlined, the shared browser was navigated away mid-probe by a concurrent agent twice, and `emulate` has **no** `prefers-reduced-motion` parameter (it enumerated its full accepted set on rejection) — Playwright's `reducedMotion` context option or raw CDP `Emulation.setEmulatedMedia` is required.

- **D82 — The ledger blocks the epic's own criteria, and every blocker is provable today.** Eleven lifecycle-`done` children carry an unstamped "PR merged" criterion despite provable merges (`spd-s1`→#4425, `s2`→#4426, `s3`→#4427, `s4`→#4470, `s5`→#4566, `s6`→#4567, `s7`→#4568, `b2`→#4473, `bl-api-tester-flex-retire`→#4472, `b10`→#4471, `b10f`→#4569 — all MERGED with `Test (Elixir 1.18.1 / OTP 27.0)` pass). Epic criteria 0 and 3 are provable from evidence already on file (`spd-s7`'s criterion 6 carries `structure_controller_test.exs` 3/0 plus three Go TUI allowlist PASSes). `spd-b16`'s correction is already applied to `spd-s1`'s evidence and the disproven `596px = 67.6ch` figure survives in no sibling task — it is closeable. `spd-b14-charter-path-durability` duplicates `spd-b19-charter-push-durability` and both are superseded by reality (the charter reached `origin/main` via #4568); b14 retires into b19, **but b19's second criterion is genuinely FALSE — local `main` carries 8 unpushed commits including `d9db991fc`, a DIVERGENT D48–D66 charter amendment** — so b19 needs a reconciliation step, not a rubber stamp. `spd-b13`'s foreign-file fence is itself unexecuted while both tasks it names (`scaffy-backlog-blocks-editable-studio` declaring `root.html.heex`, `sup-w5bk-beta-doc-editor-savestate` declaring `components.ex`) sit open, unclaimed and claimable in the live ready queue.

- **D83 — Every `ch` figure names its FONT, its FONT-SIZE and its DERIVATION METHOD, and every px figure names its platform.** The `ch` the browser resolves inside `min-inline-size: calc(55ch + 80px)` is **10.0107px** (derived: `(630.591 − 80) / 55`) while a `width: 1ch` probe span inside the same element measures exactly **10.000px** — 0.107% apart, enough to move 64.0ch to 63.95ch and hand a future verifier a free overturn. Forced Georgia agrees to four decimals, so the divergence is native-face-specific and unexplained. Separately, `55ch` is 540.12px at 16px Georgia and ~607px at the surface's real 18px `var(--bp-body-size)` — any `ch` arithmetic quoted without its font-size is meaningless. And every number this epic holds was read on **headless Chromium on macOS with a 0-width overlay scrollbar**; a classic 15px scrollbar removes ~15px from the panel at every width, pushing 1280 further under the criterion and moving the gate-reachability boundary from ~764 to ~779px. The instrument records the scrollbar width and the matrix states it is a macOS reading.

## Wave-5 review amendment (BROWSER wave, 2026-07-20) — D84–D88

Every number below was produced by `scripts/studio-desk-measure.mjs` against deployed
guerrilla (served SHA `0b4c677fdb88caa1238095cc5cbe4f624a4d65dc`, slot **queried** = blue),
and every one was reproduced by the reviewer on an independent run before being written here.

- **D84 — THE BROWSER WAS REACHED, AND THE HEADLINE CRITERION IS MET AND *STAMPED*. The disease is in remission.** Five waves after it was first declared, `>=55ch at viewport 900px` is answered by a browser instead of by prose: `.editor-panel` 856px, `.bp-paper-surface` at its own `max-width: 720px`, gutter **read** 40+40=80px, **content 640px** — `64.00ch` native (Iowan Old Style @18px), `57.93ch` forced Georgia, `69.78ch` forced Source Serif 4. **All three faces MEET, identical in both entry states, no horizontal scroll.** Four independent runs by two agents, digit-for-digit. And per D74(b) the number is now WRITTEN INTO THE LEDGER: the epic task's criterion 1 is `met: true` with the full derivation as evidence. **Ruling: this closes the loop D74(b) opened — a decision is not a stamp, and the stamp is now taken. No future wave may re-declare this criterion; it may only refute the measurement, and only with a run of the instrument.**
- **D85 — D75 IS PARTLY REFUTED, BY THE INSTRUMENT BUILT TO TEST IT. The floor binds in 2 of 54 cells, and where it binds it CAUSES the defect the gate exists to prevent.** D75 said `calc(55ch + 80px)` is dead CSS at every reachable viewport. Measured per ACTUALLY-FORCED face, it binds at **viewport 1280 under Georgia, in both entry states**: `min-inline-size` 687.632px pushes the surface 676 → 687.625px, and `.editor-body.bp-paper-body` then **overflows by 12px** — a real horizontal scrollbar, which is exactly what the 720px gate exists to prevent. So D75's "dead at every reachable viewport" holds **only for the narrow native face**; the wide-face risk D59 flagged is now measured, not hypothetical. Note the bind was found by EXPERIMENT (force `min-inline-size: 0` and re-measure), never by comparing arithmetic — there is no sum to get wrong. **Ruling: `spd-w5-measure-lever-moves` (round 2) must pick its constant from the per-face matrix, and whatever it ships must not reintroduce a 12px overflow at 1280 under a wide face. Filed as `spd-b28-floor-binds-georgia-1280-overflow`.**
- **D86 — D76's Georgia figure is WRONG and was overturn #7 averted; its structural claim stands.** D76 recorded "viewport 1280 fails at 53.95ch Georgia". Genuinely forced, Georgia at 1280 reads **55.04ch and MEETS** (marginally). D76's 53.95 divided the NATIVE box by Georgia's advance — the exact cross-face division D75 bans. D76's native number (content 596px = 59.60ch) and its structural claim (the `content` container is declared on `.editor-panel`, which holds the column PLUS the docked inspector) are both CONFIRMED. **Ruling: the ban on cross-face division is not a style preference — it manufactured a false criterion failure that sat in this charter as fact. Every `ch` figure is produced by measuring the box under the face it names.**
- **D87 — THE LAYOUT MEASURE IS MET AND THE *VISIBLE* MEASURE IS NOT. The default-open inspector eats up to 340px, and this is D36's signature one more time.** Below the `wide` bucket the Document inspector is out of flow and OVERLAYS the content box while being **server-default OPEN**. Native face, drilled, both entry states: viewport 1024 → content 640px but **visible 380px = 38.00ch**; 900 → 448px = 44.80ch; 800 → 39.80ch; 764 → 39.60ch; 700 → 33.20ch; 640 → 27.20ch; 500 → 17.60ch. At 1440/1280 it DOCKS and costs nothing. Criterion 1 is honestly met — it is about the measure the layout HOLDS, and the charter's vision explicitly wants the inspector to overlay rather than dock as the last step of squeeze. But the user's first sight of a document at 1024px is a 38ch column with a panel sitting on it. **Ruling: a protection that is technically satisfied while the user's experience is the thing the protection existed to prevent is not satisfied. The inspector's default-open state must be decided PER WIDTH BUCKET, on the matrix. Filed as `spd-b29-inspector-overlay-eats-the-measure`; it is a DIFFERENT lever from the round-2 floor slice and must not be folded into it.**
- **D88 — The 640–763px band, measured end to end: only its bottom edge falls short, and the floor is inert across all of it.** The wave was asked to chase the band where gate-reachability (viewport ≥ ~764px) leaves the corrected floor inactive. Native face: **764 → content 672px = 67.20ch MEETS · 700 → 608px = 60.80ch MEETS · 640 → 548px = 54.80ch FAILS** (Georgia 49.61ch fails; Source Serif 4 59.75ch meets). At 640 the floor computes `min-inline-size: 0px` — inert, exactly as D58's structural claim predicted. Viewport 500 (`phone`) fails in all three faces (45.20 / 40.92 / 49.28ch) with zero strips and 3 crumbs — D56's dead end IS closed, the measure at that width is not. **Ruling: the band does NOT need its own rule; it needs one rule at its bottom edge. Only `viewport 640` and below fall short, the shortfall is ~0.2ch at 640 native, and `phone` is a different layout with a different criterion. Round 2 scopes to the 640-and-below edge and must NOT raise a panel floor across 640–763, where a raised floor buys nothing and materialises a horizontal scrollbar.**
- **D89 — `:focus-visible` does NOT filter by modality on PROGRAMMATIC focus, and the review nearly shipped the opposite as a comment.** `spd-b20`'s ring (`.pane-column[tabindex="-1"]:focus-visible`) was written with the rationale "a mouse user gets the focus target without an unwanted ring". Probed live at 1280 before shipping: a programmatic `.focus()` matches `:focus-visible` and paints `2px solid rgb(44,109,90)` at offset -2px in **all three** modalities — after a key press, after a mouse click, and with no prior input. Chrome grants `:focus-visible` to programmatic focus on a non-input element regardless of how the user arrived, so `:focus` would behave identically here and a mouse user DOES see the ring until they click away. The comment was corrected before it merged. **Ruling: `:focus-visible` may not be cited as a keyboard-only filter on any element focused programmatically. This is logged as a decision precisely because it was the REVIEW that almost committed the epic's own disease — an unverified CSS claim in a confident comment — one slice after diagnosing it.**

## Roadmap — BROWSER wave (wave 5)

Round 1 dispatches immediately (four slices, disjoint file sets). Round 2 is the lead's
post-merge dispatch and is gated on `spd-s9`'s matrix. Per D19 every model column reads `opus`.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| 9 | The instrument + the matrix — committed Playwright harness, nine widths × three faces, provenance-stamped (D70/D72/D74/D75/D80/D81/D83) | `spd-s9-live-measure-proof` | 1 | — | opus | large |
| L | Ledger honesty — 11 merge stamps, epic criteria 0 + 3, `spd-b16` closed, `b14`→`b19` retire, `spd-b13` fence executed (D82) | `spd-w5-ledger-seal` | 1 | — | opus | medium |
| M | `.modal-backdrop` has no CSS rule — out-of-flow it, and give the census the inverse assertion (D78) | `spd-w5-modal-backdrop-outofflow` | 1 | — | opus | small |
| A | The strip's `aria-expanded` is decorative and Enter drops focus to `<body>` (D79) | `spd-w5-strip-aria-focus-return` | 1 | — | opus | small |
| G | Make the protected measure actually protect — re-gate on the reading column's own box, unify the gutter token, amend the parity pin (D75/D76/D77) | `spd-w5-measure-lever-moves` | 2 | s9, M | opus | large |

Backlog actually filed this wave (the Decide-time list named four slugs that were never
created under those names — corrected here at review from the live ledger):
`spd-b20-expanded-pane-focus-ring` (BUILT at review) · `spd-b21-strip-focus-browser-proof` ·
`spd-b23-harness-ref-replay` · `spd-b24-blocked-lifecycle-is-not-a-fence` ·
`spd-b25-task-ls-all-pagination-stalled` · `spd-b27-serif-token-desync-editor-vs-root` ·
`spd-b28-floor-binds-georgia-1280-overflow` · `spd-b29-inspector-overlay-eats-the-measure`
(filed at review — see D87).

## Wave log

- **2026-07-20 — Wave 5 (BROWSER), Decide.** Two of the wish's premises were one wave stale and the survey caught both: the four round-3/4 PRs were already MERGED at 21:55Z and guerrilla's `/opt/barkpark` HEAD **is** #4569's merge commit with the BEAM restarted ten minutes after, so M0 was ledger work, not landing; and the PROVE wave HAD reached an authenticated browser. The disease is narrower and worse than "nobody reached the browser": that measurement was a one-shot recorded as prose, so D58 shipped a `width − 80` arithmetic result wearing a live-reading label (D72), and D60 accused D40 of narrating fiction when D40 was right down to the line number (D73). **Verification did what four waves of prose could not: it found the epic's real bug.** `calc(55ch + 80px)` has never bound at any reachable viewport — eleven for eleven `floorBinds: false` (D75) — because the gate reads `.editor-panel`, the box that holds the reading column PLUS the docked inspector, so **viewport 1280 delivers a 596px content measure = 53.95ch Georgia, below the epic's own criterion, at a mainstream desktop width, silently** (D76). The same mechanism lets a 360px secondary pane switch the floor off entirely. M3 as scoped (gutter unification) was confirmed structurally and refuted in effect — zero pixels at zero widths — and is fused into the D76 slice rather than shipped as a rescue (D77). Two unrelated live defects surfaced en route: `.modal-backdrop` has no CSS rule anywhere and crushes the panel to its floor in two clicks (D78), and the strip's `aria-expanded` never flips while Enter dumps focus to `<body>` (D79). Wave cut: Round 1 = `spd-s9` (the instrument, non-droppable) + ledger honesty + modal-backdrop + strip a11y, all file-disjoint; Round 2 = the re-gating, gated on the matrix. Paper: `studio-space-priority-desk-browser-2026-07-19`.

### Wave 2026-07-20 — Wave 5 (BROWSER), Review

**WHAT LANDED. The wave had one job and it did it: the browser corner nobody had reached in five waves is reached, and the epic's headline criterion is answered with a number and STAMPED (D84).** Four slices built, all four green, all four gates re-run by the review on its own final state.

- `spd-s9-live-measure-proof` — **the wave**. `scripts/studio-desk-measure.mjs`, 845 lines, one new file, zero product code. Authenticates against deployed guerrilla via the D24e login-ticket flow, drills to a real paper, and prints 54 records: 9 widths × 3 **actually-forced** faces × 2 entry states, descending (D80), every historical overturn designed structurally unreachable. **Viewport 900px = content 640px = 64.00ch native / 57.93ch Georgia / 69.78ch Source Serif 4 — MEETS in all three faces, both entry states.** The review ran it independently and reproduced every digit. It also caught **two would-be overturns in itself** before publishing (a pre-socket transient, and a lazily-unloaded self-hosted face reading as bare fallback serif) and documented both in its own header rather than erasing them — which is the single strongest signal in this wave that the method has changed.
- `spd-w5-modal-backdrop-outofflow` — D78 cured. `.modal-backdrop` / `.modal-card` / `.modal-header` / `.modal-body` shipped (the builder correctly found the brief's premise incomplete: a scrim over a transparent card is not a fix), plus the census's **inverse** assertion, which this epic has never had and which is the direction that catches a backdrop that has LOST its positioning. **The review put the builder's own load-bearing doubt in a browser**: the "absolute resolves against the initial containing block" claim was reasoned from the cascade and never watched. Injected at 1280/900/500 into the live desk — pane row identical before/after, backdrop rect == viewport rect, `elementFromPoint` proves it is not clipped by either ancestor's overflow, card centred and fitting. **The claim holds.**
- `spd-w5-strip-aria-focus-return` — D79 cured, with the ARIA modelling call made explicitly rather than mechanically: the strip is NAVIGATION, not a disclosure, so `aria-expanded` is REMOVED (a state that can never change is a lie to AT) and `aria-controls` names the region the control actually replaces. Focus returns via `phx-mounted={JS.focus()}`. The builder's central doubt — does `phx-mounted` fire for a node added by a patch where the TAG changes? — **the review settled from the LiveView source**: morphdom's keyed lookup rejects the BUTTON→DIV match (`compareNodeNames` false) so the node is genuinely *added*, and independently `execNewMounted` sweeps `[phx-mounted]` after every patch, firing for any element without the private `mounted` marker — which a freshly-created div never has. **Both paths converge: it fires.**
- `spd-w5-ledger-seal` — pure ledger, zero repo files, all five parts executed. Eleven merge stamps verified individually with `gh`, epic criteria 0 and 3 closed, `spd-b16` retired, `b14`→`b19` folded. Its most valuable output is a **negative** result it went looking for and reported plainly: `lifecycle_status: blocked` **fails open** — it hides a task from `ready` but does not gate `claim`, and its own probe claim silently flipped both fenced tasks to `in_progress`. Filed as `spd-b24`.

**WHAT THE REVIEW FIXED IN PLACE.** On `spd-s9`: the human table can no longer destroy the matrix (a formatting throw at the end of a ~10min authenticated run would have discarded the whole deliverable); the in-floor `ch` derivation's hardcoded `calc(55ch + 80px)` now names itself an assumption and **raises a warning when it rots**, proven non-vacuous by mutation — this matters because round 2 is chartered to change exactly that formula; and the floor-bind experiment restores inline `!important` priority instead of silently promoting a declaration. On `spd-w5-modal-backdrop`: built `spd-b20`, the focus ring the sibling slice needed and was fenced out of — focus was landing somewhere a keyboard user could not see, which is half a cure.

**WHAT STALLED / WHAT IS HONESTLY OPEN.** `spd-w5-strip-aria-focus-return` criterion 0 is an honest MISS, not a flip: a non-zero `[aria-expanded="true"]` was judged unreachable without fabricating a second persistent toggle, and D79 backs that. `spd-b20` criterion 2 is an honest MISS: the ring is proven to PAINT in a live browser, but the end-to-end "press Enter, watch it appear" needs the fix deployed — `spd-b21` owns it. Epic criterion 2 (desktop ≥1280 unchanged) is left for the lead, and the D85 Georgia bind is the nuance it must weigh. Round 2 (`spd-w5-measure-lever-moves`) was correctly NOT built — it is sequenced behind s9 and the backdrop slice by design.

**FOUR CHARTER FACTS CHANGED BY MEASUREMENT (D84–D89)** — the cure working as intended: D75 partly refuted (the floor DOES bind, 2/54, and causes a 12px overflow when it does); D76's Georgia figure refuted as overturn #7 averted, its structure confirmed; the 640–763 band resolved (only the 640 edge falls short; the band needs no rule of its own); and the **visible** measure exposed as the thing the layout measure was hiding (D87).

**WHAT THE NEXT WAVE SHOULD TAKE.** In order: (1) merge round 1 — `spd-s9` first (docs+script only), then the two Elixir branches **together**, since `spd-b20`'s ring lives on the backdrop branch and the `tabindex` it hangs off lives on the aria branch; (2) dispatch `spd-w5-measure-lever-moves` with D85's per-face bind data and D88's band ruling as its inputs — it must not reintroduce the 1280/Georgia overflow and must not raise a panel floor across 640–763; (3) **`spd-b29` is the real prize** — the layout measure is won and the visible measure is not, and a 38ch column under an open inspector at 1024px is now the epic's largest user-facing gap; (4) `spd-b21` re-runs the strip focus proof against the deployed build, which also closes `spd-b20` c2.

## Wave-6 amendment (THE VISIBLE MEASURE wave, 2026-07-20) — D90–D101

Wave 5's cure worked, so wave 6 opens on ground truth rather than on prose. Nine verifiers ran
against `origin/main` `6a63f9905` and deployed guerrilla (served SHA identical). Two of the
wave's own opening premises were already stale when it opened and are struck below. Where a
decision here supersedes an earlier one, the earlier keeps its number; the strike is authoritative.

- **D90 — Round 1 is FULLY LANDED, and the red that held #4633 was a MIS-CALIBRATED guard, not a flake of luck.** All three PRs are merged: `f1a80675e` (#4631, the instrument) → `1ff41c4bb` (#4632, the modal backdrop) → `6a63f9905` (#4633, the strip ARIA), which is `origin/main`'s tip and the SHA guerrilla serves. The failure that reddened #4633's branch was `api/test/barkpark/sheets/engine_perf_test.exs` — **not** its `@bound_ms` complexity floor, as three documents assumed, but `assert ratio < 6.0`, a **quotient of two wall-clock timings** (2100 rows over 700). The identical merged tree passes on main (`Test (Elixir 1.18.1 / OTP 27.0) => success` at `6a63f9905`), which is the definition of a flake established by re-execution. But the guard is worse than noisy: a faithful 12-trial replication on **idle** hardware failed **5 of 12** with mean ratio **6.11 — above the ceiling** — and a log-log sweep shows the engine is genuinely superlinear with a rising exponent (k = 0.94 → 1.47 → 1.76 → **1.81**), so the expected 3×-row ratio is ~5.8–6.5 and straddles 6.0 by construction. One trial read **12.15**, above the 9.0 the test's own moduledoc calls the quadratic signature. The moduledoc's promises ("why it will not flake", "~3.9× locally") are both refuted by measurement, and the test deliberately opts out of the repo's `:flaky` exclusion. **Ruling: treat a red on `engine_perf_test.exs` exactly as Format and Sobelow are treated — check main's own run before attributing it to a PR. Filed as `spd-b32` (recalibrate the guard) and `spd-b33` (the engine's ~O(n^1.8) vs its documented O(cells+edges) contract). Both are Sheets-plugin questions outside this epic's surface fence; they are filed, not fought.**

- **D91 — `spd-b29`'s shape is RULED, and it is neither of the two the wave inherited: it is a HYBRID, proven in a browser end to end.** Both candidate shapes were built and driven against deployed guerrilla at viewport 1024. **Shape (a), server-seeded, is refused — and D12's refusal now carries a number.** The static render's root element is bare `<html lang="en">`, `mount.ex` seeds `width_bucket: "wide"`, and the true bucket arrives only in a post-connect `handle_event`: measured cold-load marks are `firstAnimationFrame` t=20.1ms, `DOMContentLoaded` t=79.5ms, **`phx-connected` t=419.5ms** — so a server-seeded close cannot land before ~400ms of a 300px panel sitting on the reading column, on every document open. No cookie exists that could supply a first-byte width signal (`document.cookie` appears nowhere in `root.html.heex`). **Shape (b), CSS-only default-closed, does NOT flash** — first sampled frame at t=38.0ms already shows the panel off-canvas, **0 of 400 frames ever visually open, zero transitions** — but it **fails `spd-b29`'s own criterion 3 in the browser**, which is the criterion that matters. Tested in its strongest honest form (`translateX(calc(100% - 41px))`, leaving the strip and its control on screen and clickable), three real clicks give: collapsed → **`is-open` w=300 `aria-expanded="true"` and `transform: matrix(1,0,0,1,259,0)`, still off-canvas** → collapsed. The control toggles forever between "collapsed strip" and "open-but-CSS-hidden"; **the inspector's contents can never be seen below `wide`, and `aria-expanded="true"` announces a panel the user cannot see — the exact class of a11y lie #4633 just landed to fix.** The cause is structural: `sidebar_toggle_panel` is a bare `!` flip and CSS is stateless, so a rule that suppresses `.is-open` suppresses it for the server default and the user's explicit open alike. The blunter variant (`translateX(100%)`) is worse still — Playwright cannot click the control at all: *"`<div data-role="content" class="editor-panel">` intercepts pointer events"*. **The ruling is the hybrid: CSS paints the default-closed state at first paint (no flash — that property comes ONLY from a rule in the cascade at first paint), and the rule yields to an EXPLICIT user open via a DOM marker the server stamps — which the server knows without knowing the viewport, so D12's flash never opens.** Proven end to end: first frame t=26.8ms closed, **0/300 inspector-visible frames, no transitions**; stamping the marker → `transform: none`, inspector visible; removing it → closed again. Reader column at 1024 goes **420px → 720px** when the inspector is not overlaying. **File set: `root.html.heex` (the rule + the scrim guard), `studio_live/components.ex` (render the marker on the `<aside>`), `shared/paper.ex` (seed "the user has not asked" beside `sidebar_open: true`), `handlers/paper.ex` (set it in the toggle).**

- **D92 — D16 BINDS, and the wave's chartered round order INVERTS to honour it.** `spd-b29` needs `root.html.heex` by construction (the no-flash property exists only in the cascade at first paint) and `spd-w5-measure-lever-moves` already declares sole ownership of the same file. D16 is explicit — *"root.html.heex is single-owner per round; two slices touching it never dispatch in the same round"* — and D27/D28 record two prior rounds reshaped to honour it. The strategic direction's promise that the two levers would have "strictly disjoint declared file sets" is **void as written**. Two ways out existed; **pre-provisioning `spd-b29`'s CSS inside the floor slice is REFUSED by D67 — CSS written against an element no slice yet renders is UNVERIFIED CSS, and the whole value of this rule is a first-paint behaviour that cannot be proven while its server consumer does not exist.** So the slices sequence, and the order flips: **`spd-b29` is round 1 and sole owner of `root.html.heex`; `spd-w5-measure-lever-moves` is round 2, `after: [spd-b29]`.** The inversion is deliberate and has three reasons. (1) The wave's headline moved from the layout measure to the visible measure, and `spd-b29` is that headline. (2) `spd-b29` is now the better-specified of the two — a browser proved its shape AND both of its refutations — while the floor slice's sanctioned outcome set was just reopened (D93). (3) The floor slice's own inputs change if the inspector's docking does, so it deserves a brief written on top of a landed `spd-b29` rather than beside it. **Constraint on `spd-b29`, load-bearing for epic criterion 2: its rule is scoped `html:not([data-width-bucket="wide"])` and may not move one pixel at viewport 1280 or 1440, where the inspector docks and costs nothing (D87).**

- **D93 — The floor slice's binary is FORECLOSED on both horns; its outcome set is REOPENED, and the gutter unification may never be sold as the fix.** The brief offered (A) move the lever to `.editor-panel { min-width }` scoped by bucket, or (B) retire rule and gate together, and declared "there is no third option". Measurement closes both doors part-way. **(A)** may not raise a panel floor anywhere across viewport 640–763, where D88 measured 764 → 67.20ch and 700 → 60.80ch already MEETING and a raised floor buys nothing while materialising a scrollbar. **(B)** regresses viewport 1280 under forced Georgia from **55.04ch MEET to 53.95ch FAIL**: the MEET is *produced by* the bind (bound content 607.625px ÷ 11.0479 = 55.00ch; strip the floor and the column reverts to 676 − 80 = 596px ÷ 11.0479 = 53.95ch). D76's discredited number is numerically the correct POST-RETIREMENT value — **this is arithmetic on measured inputs, not a measurement, and the slice must confirm it with an instrument run before choosing (B).** And **the `--paper-gutter` unification does NOT resolve the Georgia bind**: `container-name: content` sits on `.editor-panel`, which is **976px** at viewport 1280, so container-ported breakpoints re-base onto 976 and the narrow-gutter rule (`max-width: 767px`) cannot match — the unified floor computes **byte-identical** to the shipped literal there (Iowan 630.591 / Georgia **687.632** / Source Serif 4 ~585, unchanged), reproduced to the third decimal by an independent harness. The much-quoted **~598.6px is CONFIRMED (598.591px) and STRATEGICALLY IRRELEVANT**: it is the **Iowan face only**, reachable only in a 48px window of container width (720–767px), where the floor already closes zero pixels. Per face at the 24px gutter: 598.591 / 655.632 / ~553 — all three still under the 720px gate, so D77's "zero pixels at zero widths" now holds face-independently. **Georgia's 655.632px under the narrow gutter IS below the 676px column, and that near-miss is a loaded gun: anyone who does not check which query base the breakpoint lands on will conclude the unification fixes the bind. It does not.** The charter's own roster row G already names a third shape — *"re-gate on the reading column's own box"* (D76's ruling) — and that shape is now the sanctioned default. **Ruling: the slice picks its outcome on the per-face matrix, must leave zero cells where the floor binds AND horizontal overflow is true, must raise no panel floor across 640–763, and may NOT claim in its commit message or evidence that the gutter unification addresses D85.**

- **D94 — Epic criterion 2 is RE-AUTHORED, because its literal wording has been false since round 1 and its "layout" half has NO LOCK AT ALL.** Against pre-epic `89f151c21`, four file-verified counts falsify "wide-bucket DOM and layout identical": `data-role` went 0 → ≥4 in `studio_live/components.ex`; `.pane-column` went `min-width:200px; flex-shrink:0` → `min-width:clamp(140px,18vw,260px); flex-shrink:1` (rigid → compressible); `.editor-panel` gained `min-width:560px` + `container-type:inline-size`; and `.pane-layout` went `overflow:hidden` → `overflow-x:auto` — **which is what converts D85's 12px bind from a clipped non-event into a user-visible horizontal scrollbar, inside criterion 2's own band.** Worse, the locks were injection-tested. Regressing `collapse?/3` is caught **only** by the 40-cell `display_state/4` exhaustive table (hardcoded literals — the epic's one genuinely non-vacuous wide lock); the neighbouring "bit-identical to `collapse?/3`" test derives its expectation from the function it guards and **stayed green**, exactly as vacuous as suspected. And regressing wide-bucket **geometry** — `.pane-column` 260px → 180px, a change that visibly narrows every nav column at 1280/1440 — passes **77 tests, 0 failures** across all five width/measure suites. **There is no lock on wide-bucket layout geometry anywhere in this repo.** The A/B that would settle it is cheap: `89f151c21..origin/main` is 46 commits, 98 files, **zero migrations**, so the pre-epic tree deploys to the idle green slot against the same database. **Ruling: criterion 2 now reads — Desktop ≥1280 shows no user-visible regression vs pre-epic `89f151c21`: (a) the wide/standard `display_state/4` table is unchanged, pinned by literal constants; (b) inert attribute additions (`data-role`, `data-width-bucket`) and the container declaration are IN SCOPE and permitted by name; (c) instrument rows at 1280 and 1440 across all three forced faces show no horizontal overflow on `.editor-body.bp-paper-body` and content ≥55ch; (d) `spd-b28` is fixed, or carved out by name with its 12px measured and owned. A geometry lock is filed as this wave's own slice, and it must be a LITERAL pin (the idiom that worked), never a derived one (the idiom that didn't).**

- **D95 — `spd-b28` FOLDS; it may not be dispatched as a build, and its acceptance gate names a task that does not exist.** Criterion 2 reads "After **`spd-w5-measure-gate-right-box`** lands…" — `bp task get` returns `not_found` and the string appears nowhere in this charter, so **b28 is un-closeable by construction**. Its criterion 1 (record the bind, amend D75 to native-face-only, correct D76's Georgia figure) is **already paid in full on `origin/main` by D85 and D86**. Its criterion 2 is literally an acceptance test of the floor slice's output; dispatching it separately would make a second builder re-run the instrument against a change it did not make on a build it does not control — the self-referential-proof failure this epic keeps producing. **Ruling: fold b28's criterion 2 verbatim into `spd-w5-measure-lever-moves` as its bind-census criterion, close b28's criterion 1 now on D85/D86, and close b28 itself on the floor slice's evidence. The phantom id is repointed at `spd-w5-measure-lever-moves` in the same ledger touch.**

- **D96 — The secondary pane is a DEAD USER PATH twice over, so D76's pressure case may no longer be cited as live user-facing justification — and one of the two breaks is a real, shipped, five-waves-invisible bug.** **Break 1:** `@editor_view == :paper` dispatches to `studio_paper_view`, whose attr list has no `doc_actions` — `resolved_doc_actions/1` is threaded only into `studio_editor_shell`, the classic branch. Measured on the real paper: the only `.document-header button` is Share, and `[data-test-id="open-secondary-picker"]` count is **0**. So on the only surface that has `.bp-paper-surface` — and therefore the only surface where the 55ch floor exists at all — the secondary pane cannot be opened, period. **Break 2:** on the classic surface the button renders, the picker opens with 99 real candidates, and clicking one does **nothing** — no pane, no flash, no console error, and the tell: **the modal stays open**. Root cause found by experiment, not inference: `.modal-card` carries `onclick="event.stopPropagation()"`, and LiveView's click handling is window-delegated, so that inline handler kills **every** `phx-click` inside the card. Three-part proof: the ✕ inside the card does not close it either; clicking the **backdrop** (same event, outside the card) does close it; and `removeAttribute('onclick')` then clicking the **same** candidate id renders `.bp-secondary-pane` count **1**. It is the only such attribute in `api/lib` (CSP allow-lists it by name), so the defect is unique to this one modal. Five waves of green tests missed it because the only covering test drives `render_click(view, "select-secondary", …)` **over the socket**, never touching the DOM — structurally incapable of seeing a client-side dispatch defect. **The two surfaces are DISJOINT**: the surface that HAS the floor has no entry point, and the surface that HAS the entry point has no `.bp-paper-surface`. Even with break 2 fixed, D76's pressure case needs a cross-surface navigation no affordance offers. **Ruling: D76's CSS effect stands as measured (`.editor-panel` 976 → 616px, `min-inline-size` resolves `0px`, content 536px = 53.60ch native — the real path reads 536, not D76's injected 530, and the charter takes the measured number). Its USER path is refuted. The floor lever must be justified on D85's 12px overflow and D87's visible table, never on the secondary pane. Break 2 is this wave's own round-1 slice; break 1 is filed as `spd-b34`.**

- **D97 — The instrument is the seal's single point of failure, and it currently has TWO: a flaky drill and a one-shot provenance stamp.** **Flake:** `drillToDocument`'s `waitForSelector('.bp-paper-surface')` timed out after 30s for **three independent verifiers**, then succeeded for two of them minutes later on the same SHA — it clicks the first `[phx-click="select"]` row in a Papers list that concurrent epic waves are rewriting live (104 rows; the first row changed between two runs). **A Round-B run that fails is not evidence about the desk, and a wave that reads a drill timeout as a desk fact records a non-measurement as a measurement — this epic's exact disease.** **Provenance:** `readProvenance()` runs **once**, before the browser launches, and its single snapshot is stamped into all 54 records; there is no per-row timestamp anywhere. Caught in the act: a sweep bracketed by pre/post reads ran 59.7s and observed `barkpark-slot@green` entering **inside** the sweep window (blue-only → blue+green → green-only across three reads, SHA constant). A same-SHA rotation is benign; a merge landing mid-window would be equally invisible and would silently misattribute every later row. **Third gap:** the instrument prints `visible_content_px` but its `ok?` column is explicitly documented as the **LAYOUT** measure, so the visible verdict this wave seals on **does not exist yet and must be authored**. **Ruling: all three are one round-1 slice on one file. Until it lands, every sweep is bracketed by a pre- AND post-run provenance read and discarded on mismatch; a drill timeout is reported as an instrument failure, never as a desk fact.**

- **D98 — `lifecycle_status: blocked` is not merely fail-open, it is DESTRUCTIVE fail-open, and it may never be used as a fence again.** Claiming a `blocked` task succeeds with no resistance **and the claim write itself flips `blocked` → `in_progress`**; releasing afterwards lands on `open`, never back on `blocked`. The fence is destroyed one-way by the act of testing it, so it cannot even be trusted across a claim/release cycle. **Ruling: no collision-prevention plan in this epic may rest on `blocked`. File ownership is enforced by the round/`after` graph and the `files:` labels, which is what D16 and the sequenced-rounds law were already for.** Consequently `spd-b13`'s fence is dead machinery: its unblock trigger fired when `spd-s9` merged, yet `sup-w5bk-beta-doc-editor-savestate` is **still** `blocked` with its FENCE NOTICE intact while `scaffy-backlog-blocks-editable-studio` reads `open` only as a side effect of a probe, with its FENCE NOTICE prose orphaned in place. `spd-b13u` executes properly this wave or closes as moot.

- **D99 — `bp search` WORKS; D62's diagnosis stands and its exit-code detail does not.** The correct form is `bp search query "<text>"` with **no** dataset positional (`bp search query production studio` → `usage: too many arguments for search query (expected 1)`; `bp search production studio` → `unknown command "search"`, which is the shape seven surveyors read as "no working verb"). A correct call returns 789–897 real hits. On the current binary (`dev/a18e67c99`) both bad forms exit **2**, not 0 as D62 records. **Ruling: D62's core finding is current; its exit-0 clause is struck. And `spd-b26` — cited by a brief this wave — was never a real task: it 404s, it is absent from full-text search, and it is absent from all 39 `spd-*` rows in `bp task ready --all`.**

- **D100 — The 640-and-below edge and the phone bucket are NAMED, not chased.** The only lever that moves viewport 640 is shrinking the `@media (max-width: 767px)` gutter, which buys ~2–4px (~0.2–0.4ch native) — enough for native's own ~0.2ch gap and nowhere near Georgia's ~5.4ch. A gutter tuned until one face passes while another still fails is gerrymandering a threshold and would ship as a face-dependent claim this charter's own D83 forbids. Surface `max-width: 720px` has zero leverage there (the panel is already narrower). Changing `--bp-body-size` is cross-surface, cross-epic (unified-aesthetic owns the type scale) and would move the 900px numbers criterion 1 is stamped on. **And the epic never held a phone ch criterion:** its four acceptance criteria name exactly one ch figure (viewport 900), `spd-b6`'s own criterion is "content readable, crumbs navigate, `document.body.scrollWidth == innerWidth`", and the vision frames phone as a single-pane drill. 45.20ch native at viewport 500 also sits inside the classical 45–75 readable band. **Ruling: record viewport 640 native (~0.2ch short) and forced Georgia (~5.4ch short) as a named, owned shortfall, and state plainly that `phone` was never gated on ≥55ch — its criterion is navigability plus no horizontal scroll, both already met (D88/D56).**

- **D101 — The comparison bar this epic keeps invoking is HALF SOURCED, and the Paper says so.** Two of the six named products yield real evidence. **Notion** made its page-details panel default to the user's last state in Oct 2024, with a first-party rationale that is this epic's own problem stated by someone else: *an open panel by default "could distract from the main content and create navigation issues with multiple scrollbars."* **Sanity Studio** does not overlay at narrow widths at all — panes collapse into a tab bar and the user drills. **Material Design 3**'s permanent/persistent/temporary taxonomy puts ~1024–1440px in a tier that favours dockable over modal panels. **Vercel, Linear, Contentful and Kinsta are NOT confirmed** — no public documentation describes their inspector behaviour at these widths, and no authenticated session was driven. **Ruling: no comparable product was found that ships a document inspector OPEN BY DEFAULT AND OVERLAYING primary content at laptop widths — the two sourced examples do the opposite. That is directional support for `spd-b29`, and it is stated as directional. Any wave claiming a live cross-product comparison must have driven the sessions; "the Kinsta bar" is a craft standard in this charter, not a layout citation.**

- **D102 — `spd-b29` SHIPPED the D91 hybrid, and the default below `wide` is now the collapsed strip — chosen by measurement, and here is what would have changed the choice.** Shipped selector: `html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened])`, reproducing `.is-collapsed`'s GEOMETRY (`position: static; flex: 0 0 auto; width: auto; transform: none; box-shadow: none`) plus `display: none` on `__title`/`__body`, plus a scrim suppression so the desk never dims a document under an inspector nobody can see. **The measured delta, one face (Iowan Old Style 18px, `ch` = 10.0078px by a probe span INSIDE the surface, gutter READ per row): viewport 1024 `visible_content_px` 380 → 599 (37.97ch → 59.85ch), 900 256 → 475, 800 220 → 439, 764/700/640 236 → 471, 500 176 → 411.** Sub-wide widths still do not reach 55ch (they land 41–47ch) — but the binding constraint there is now the PANE, not the inspector, which is the round-2 floor slice's problem and not this rule's. **Wide is unmoved, measured by deleting the rules from every stylesheet at runtime and diffing every field: 1600/1440/1280 identical before and after, and viewport 1280 still yields `surfaceWidth` 676px — the floor slice's input, intact.** **WHAT WOULD HAVE DECIDED IT THE OTHER WAY.** Default-OPEN below `wide` would have been right if the inspector DOCKED rather than overlaid there — it does not; it is `position: absolute` at every sub-wide width measured, costing 260px of overlap. It would also have been right if the reading column had room to spare — at 1024 the pre-change reader saw 37.97ch, well under any measure standard. And **`spd-b29` deliberately did NOT resolve the direction ambiguity in CSS**: the toggle now reads the post-connect `width_bucket` assign so one click opens from the painted-closed state, because CSS is stateless and a rule that suppresses `.is-open` suppresses the user's explicit open too (D91's refutation of shape (b)). Reading `width_bucket` at CLICK time is not a re-opening of D12: it paints nothing before the user acts. **Two obligations remain OPEN, honestly missed rather than flipped: the no-flash frame sample and the single end-to-end click were measured on a static harness (shipped CSS + real rendered desk DOM), not against the deployed build, because the instrument is hard-bound to guerrilla and the change is unmerged.** Both close with one instrument run post-merge. **A residual a11y lie is FILED, not fixed:** in the painted-closed state the control still renders `aria-expanded="true"` and a chevron-down, because the server does not know the bucket at first paint — the same class of defect #4633 landed to fix, deliberately not smuggled into this slice's fence.

- **D103 — THE 640–763px BAND HYPOTHESIS IS CONFIRMED AS A COHERENCE DEFECT AND REFUTED AS A FIX, by an instrument run, not by arithmetic.** The wave-6 direction set this as its primary question: the band may be doomed not by arithmetic but by a QUERY-BASE MISMATCH the epic authored into itself — the surface's gutter is viewport-`@media`'d (48px total below 767px) while the protected floor is `calc(55ch + 80px)` behind a `@container content (min-width: 720px)` gate, so in the band the floor over-reserves 32px AND the 720px gate over-reserves the panel width needed to reach it. The reviewer ran the hardened instrument against deployed guerrilla (served SHA `6a63f9905`, slot **queried**, bracket matched, drill attempt 1 on the named default document, 54 rows, 0 warnings) and read the gutter per row rather than assuming it. **The mismatch is REAL and measured**: at viewport 800 the read gutter is 40+40=80px, and at 764 / 700 / 640 it is **24+24=48px** — the `@media (max-width: 767px)` rule is applying while the floor's literal still says 80. **And it costs exactly zero pixels at every width in the band.** Per-row, native face, drilled: **viewport 764 → panel 720px, gate ON, floor 630.591px, `binds: false`** (the panel already clears the floor, so lowering it to `55ch + 48px` = 598.591px changes nothing); **700 → panel 656px, gate OFF, floor computes `0px`**; **640 → panel 596px, gate OFF, floor `0px`**. A floor that is inert cannot over-reserve anything, whatever its formula. The 32px is arithmetically true and operationally void — D93's "loaded gun" fired exactly as charted. **The second horn is worse than void, it is a trade against the epic's own criterion.** Lowering the gate so the floor binds in the band puts a `min-inline-size` of 598.591px (Iowan, unified gutter) inside a 596px panel at viewport 640: the surface grows past its own panel and `.editor-body.bp-paper-body` takes real horizontal overflow — D39/D85's defect, deliberately materialised — to move native from 54.80ch to ~55.02ch. Under forced Georgia the unified floor is 655.632px in that same 596px panel: ~60px of overflow to reach ~55.0ch. **A threshold tuned until one face crosses the bar while another needs a 60px scrollbar to follow it is gerrymandering, and D83 already forbids the face-dependent claim it would ship as.** **Ruling: the band needs no rule, and this is now the SECOND independent confirmation of D88's ruling — D88 measured the band's outcomes, this measures its MECHANISM and finds the mechanism inert. `--paper-gutter` unification remains worth shipping as coherence (a viewport-scoped gutter and a container-scoped floor that disagree by 32px is a latent trap for the next author), and it may never be sold as the band's fix, per D93. The 640-and-below edge stays a NAMED, OWNED shortfall per D100. A refutation bought with a measurement is worth as much as a fix, and this one cost 33 seconds of a committed instrument rather than a wave.**

## Roadmap — THE VISIBLE MEASURE wave (wave 6)

Round 1 dispatches immediately — four slices, strictly disjoint file sets. Round 2 is the lead's
post-merge dispatch. Per D19 every model column reads `opus`. Per D92 the chartered round order
is INVERTED: the inspector owns `root.html.heex` this round, the floor slice follows it.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| I | The visible measure — the inspector's default becomes bucket-aware via the D91 hybrid; no flash, still openable at every width | `spd-b29-inspector-overlay-eats-the-measure` | 1 | — | opus | large |
| N | The instrument stops being the seal's single point of failure — deterministic drill, bracketed provenance, an authored VISIBLE verdict (D97) | `spd-w6-instrument-hardening` | 1 | — | opus | medium |
| S | The secondary picker has been dead since it shipped — `onclick="event.stopPropagation()"` kills every `phx-click` in the card (D96) | `spd-w5-secondary-pane-reachability` | 1 | — | opus | small |
| W | Wide-bucket geometry gets its first lock, and epic criterion 2 gets an honest pin (D94) | `spd-w6-wide-geometry-lock` | 1 | — | opus | medium |
| G | Make the protected measure actually protect — re-gate on the reading column's own box, on the reopened outcome set (D93/D95) | `spd-w5-measure-lever-moves` | 2 | I | opus | large |
| Z | The visible matrix re-run and the seal ruling — seal on the visible number or hand off a NAMED successor (D97/D94) | `spd-w6-visible-seal-ruling` | 2 | I, N, G | opus | medium |

Backlog filed this wave: `spd-b30-instrument-coverage-one-document-one-path` ·
`spd-b31-studio-live-strict-selector-audit` · `spd-b32-sheets-linearity-guard-miscalibrated` ·
`spd-b33-sheets-engine-superlinear` · `spd-b34-paper-editor-no-doc-actions` ·
`spd-b35-presence-dot-intercepts-action-bar` · `spd-b36-cross-browser-surface-measure-coverage` ·
`spd-b37-serif-stack-disagreement-root-vs-editor`

## Wave log

- **2026-07-20 — Wave 6 (THE VISIBLE MEASURE), Decide.** The wish asked for the 640–763 band and the seal. Both premises were already one wave stale, and saying so was the wave's first act: D88 had answered the band end to end before this wave opened, and all three round-1 PRs had merged — including #4633, whose red was a mis-calibrated Sheets timing guard that fails ~40% on idle hardware (D90). So the wave moved its headline from the measure the LAYOUT holds to the measure the READER SEES. Criterion 1 is stamped met on "viewport 900 = content 640px = 64.00ch", reproduced four times by two agents — an honest number about the box the layout holds, while the reader at viewport 1024 sees **38.00ch with a panel sitting on the text**, reproduced digit-for-digit this wave on a different document. That gap, not the band, is the epic's largest remaining user-facing defect. Verification then reshaped the wave three more times: `spd-b29`'s implementation shape was ruled in a browser rather than inherited from a prompt, and both candidate shapes were refuted — server-seeding costs a measured ~400ms flash, CSS-only makes the inspector permanently un-openable below `wide` while announcing `aria-expanded="true"` (D91); D16 then forced the chartered round order to INVERT, because the hybrid needs `root.html.heex` and pre-provisioning it is refused by D67 (D92); and the floor slice's "there is no third option" binary was foreclosed on both horns, with the `--paper-gutter` rescue refuted face-independently and its famous ~598.6px exposed as a single-face number for a window where the floor already closes zero pixels (D93). Epic criterion 2 — the literal gate on sealing — was found false on four counts and, worse, **unlocked**: a 260px → 180px wide-column regression ships green through 77 tests in five suites (D94). And the secondary pane, which D76's pressure case rests on, turns out to have been dead since it shipped: the picker's own `.modal-card` carries an inline `stopPropagation` that kills every `phx-click` inside it, proven by removing the attribute and watching the same click work (D96). Wave cut: round 1 = the inspector (the headline), the instrument's own hardening (the seal depends on it and it currently fails at the drill), the dead picker, and the first wide-geometry lock — all file-disjoint; round 2 = the floor lever on top of a landed inspector, then the visible matrix and the seal ruling. **The one outcome this wave refuses is closing the epic while the reader sees 38ch.** Paper: `studio-space-priority-desk-visible-2026-07-20`.

### Wave 2026-07-20 — Wave 6 (THE VISIBLE MEASURE), Review. Grade A−.

**WHAT LANDED.** Four round-1 slices, all four green, all four gates re-run by the review on its own final state, and — the check this wave most needed — **the four-way UNION was merged and gated together: 1711 Studio-surface tests, 0 failures, `studio-literal-check` PASS (367 files), Part E ratchet 165/165 Δ0, `paper-editor-mirror` PASS both directions, instrument syntax clean.** The union mattered here rather than being ceremony: `spd-b29` edits the stylesheet `spd-w6-wide-geometry-lock` parses, and b29 introduces this sheet's first multi-line comma-separated selector list — the exact shape the census parser mis-keys (see the review fix below).

- `spd-b29-inspector-overlay-eats-the-measure` — **the wave**. The D91 hybrid ships as ruled: CSS owns first paint, the rule yields to a server-stamped `data-user-opened` marker, and `sidebar_open` stays unconditionally true so D12's ~400ms flash never opens. The load-bearing part the browser proof could not reach — does LiveView keep the marker across a diff that re-renders the `<aside>`? — is settled by a test that picks a probe (`sidebar-toggle-section`) which genuinely re-renders the panel and then **guards its own non-vacuity** by asserting the inspector subtree actually changed. Ruling written as D102, naming what would have decided it the other way.
- `spd-w6-instrument-hardening` — all three D97 holes closed, and **the review re-ran the whole instrument independently rather than reading the builder's table**: 54 rows, 0 warnings, bracket matched over a 32.8s window, drill resolved on attempt 1 against the committed default document, and the reference matrix reproduced **digit-for-digit** (visible 1440→640 · 1280→596 · 1024→380 · 900→448 · 800→398 · 764→396 · 700→332 · 640→272 · 500→176; 12 of 54 cells MEET, i.e. 6 of 27 per entry state, in all three faces). The builder's flagged divergence is **confirmed and they were right**: at viewport 1280 under genuinely-forced Georgia the cell reads visible 608px = 55.04ch, not 596 — because the floor BINDS there (`min_inline_size` 687.632px pushes the surface 676 → 687.625px), which is D85 and D86 reproducing exactly. The brief's reference list is per-viewport and can only be the native-face row; that premise, not the builder, was wrong.
- `spd-w5-secondary-pane-reachability` — D96 cured by containment rather than by cancelling events: the backdrop drops its `phx-click`, the card's existing `phx-click-away` becomes the dismiss, and the inline `stopPropagation` is gone. The new test **drives nothing** — it asserts on the markup a browser receives, including a sweep of every element's attribute names for any inline `on*` handler — which is the only shape that could have caught this, since five waves of socket-level `render_click` tests were structurally blind to a client-side dispatch defect.
- `spd-w6-wide-geometry-lock` — epic criterion 2's layout half gets its first lock: literal pins plus a 14-entry census of every rule declaring box geometry on the pane families at any nesting depth, four fault injections each reverted and re-run green, and the decorative `collapse?/3` bit-identity test retired **by conversion** rather than deletion (it reached 8 panes where the non-vacuous table stops at 5, so deleting would have lost real coverage). The review re-derived all six converted rows against `collapse?/3`'s actual arithmetic — the builder's own named residual risk — and they are correct.

**WHAT THE REVIEW FIXED IN PLACE.** On `spd-w6-wide-geometry-lock`, the parser hole the builder found by *reading* their own code and reported honestly: `last_line/1` keyed each rule by the last line before its brace, so a comma-separated selector list written one selector per line was censused by its FINAL selector only — `.pane-column,\n.something-else { width: 180px }` reads as `.something-else`, the pane family never matches, and the rule is invisible. One newline and one comma smuggles D94's own 260px→180px regression past every assertion in the file. The walk now takes continuation lines backward while the line above ends in a comma, stops at at-rule headers, and is covered by two new negative controls on a synthetic sheet, **non-vacuous by mutation** (reverting to `[List.last(lines)]` reds the multi-line control and only it). This is not hypothetical: `spd-b29` introduces the first such selector list in this sheet in the same wave. On `spd-b29`, the painted-closed rule reproduces `.is-collapsed`'s geometry to override the overlay block but did not reset the `z-index: 5` that block also sets — and z-index applies to flex items regardless of `position`. Inert today, which is exactly why no gate and no browser run would have caught it; reset because the rule's stated contract is that geometry *exactly*. On `spd-w5-secondary-pane-reachability`, `csp.ex` still named `editor_fields.ex` as the consumer of a handler that no longer exists — corrected, with the hash itself left allow-listed and annotated, because retiring it changes the served CSP surface and `spd-b35` owns that proof.

**THE PRIMARY QUESTION, ANSWERED.** The wish asked the wave to break or confirm the band hypothesis with the instrument rather than argue it. Done, and it is **confirmed as a coherence defect and refuted as a fix** — recorded as **D103**. The query-base mismatch is real and measured (gutter read 40+40 at viewport 800, **24+24 at 764/700/640**, against a floor whose literal still says 80), and it closes **zero pixels at every width in the band**, because the floor is inert across all of it: gate ON at 764 where the panel already clears it, gate OFF at 700 and 640 where it computes `0px`. Lowering the gate to make it bind trades a 0.2ch native shortfall for real horizontal overflow — and needs ~60px of scrollbar to carry Georgia over the same bar. That is D93's loaded gun firing as charted, and it cost 33 seconds of a committed instrument instead of a wave.

**WHAT IS HONESTLY OPEN.** `spd-b29`'s criteria 1 and 2 are MISSES, not flips: both demand proof "against the deployed build", which is unmeetable pre-merge, and both close with one instrument run post-merge — the lead should expect them, not read them as a shortfall. The residual `aria-expanded="true"` lie in the painted-closed state is filed (`spd-b29f`) rather than smuggled into a fenced slice. Epic criterion 2 is **advanced but not closed**: it now has a layout lock, but D94(c)'s instrument rows and `spd-b28`'s 12px bind remain, and its evidence field is still empty — that is `spd-w6-visible-seal-ruling`'s. **The epic does NOT seal this wave, and that is the correct outcome**: the visible verdict on the *pre-b29* build is 6 of 27 cells, and until the merged build is measured nobody knows what b29 bought in the instrument's own numbers rather than a harness's.

**LEDGER.** Honest on all four slices — evidence stamped as the work happened, misses recorded as `attempts` with real notes rather than silent `met:false`, merge criteria correctly left for the lead. Two defects fixed: `spd-w6-instrument-hardening` had lapsed back to `lifecycle: open` with 7/7 criteria met and its work sitting on a branch — one `bp task next` from a second builder rebuilding a finished slice — re-claimed to hold `in_progress`; and `spd-w5-ledger-seal`, 7/7 with zero repo files and therefore no merge dependency, was closed on evidence after independently re-verifying its central claim against the epic task. Round-2 slices verified untouched and `open`, exactly as the sequenced-rounds law requires.

**WHAT THE NEXT WAVE SHOULD TAKE.** In order: (1) merge round 1 — `spd-w6-instrument-hardening` first (scripts-only, no Elixir gate), then the three `.ex`/`.heex` branches, which **wait for `Test (Elixir 1.18.1 / OTP 27.0)`**; Format is advisory-by-design (D23). (2) Dispatch `spd-w5-measure-lever-moves` on top of a landed `spd-b29`, with D103 as a hard input: it may **not** sell the gutter unification as the band's fix, and D93's outcome set stands. (3) Then `spd-w6-visible-seal-ruling`, which is the only slice that can answer whether this epic seals — it must re-run the instrument against the **merged and deployed** SHA, because every visible number this wave holds describes the build b29 was written to fix. (4) `spd-b29f` and `spd-b21` are the cheap a11y closers.

## Wave-7 amendment (THE SEAL wave, 2026-07-20) — D104–D116

- **D104 — THE COLLAPSE IS REAL AND TOTAL, AND IT IS DEGENERATE RATHER THAN DISHONEST.** Two independent bracketed runs of the committed instrument against deployed guerrilla (served SHA `15e057f83`, slot **blue** queried, bracket matched over 30.9s and 29.8s windows, drill attempt 1, **0 of 54 rows differing between the runs**) report `inspector.position: "static"`, `overlays_surface: false`, `overlap_over_content_box_px: 0` and **`visible_content_px == content_px` in 54 of 54 rows**. Below `wide`, in the only state the instrument samples, the subtraction no longer applies and the visible measure has collapsed onto the layout measure — the wave direction's central read-code claim, now run-proven at full strength. **But the collapse is not the indictment the direction feared.** The subtraction stopped applying because the 300px absolute overlay genuinely became a 41px in-flow strip, not because anyone edited the metric: `sidebar.width_px` reads 300 at 1440/1280 and **41 at every sub-wide width**, `display: flex`, `position: static`, `z-index: auto`. Measured against the wave-6 pre-b29 visible table every row is a large real gain — 1024 380→599, 900 448→640, 764 396→631, 700 332→567, 640 272→507. **Ruling: a seal on the default-state numbers would NOT be sealing on a definitional artefact; the direction's fear is correct as a mechanism and refuted as an indictment of this delta. What survives is PROSPECTIVE blindness — the occluder list is hand-maintained and has exactly one entry, so the number is honest today and structurally unable to stay honest.**

- **D105 — THE 200px DISPUTE RESOLVES AGAINST THE HARNESS, BY ARITHMETIC THE RUN SUPPLIES RATHER THAN BY ARGUMENT.** D102's static-harness table (1024→599, 900→475, 800→439, 764/700/640→471, 500→411) matches the deployed run **exactly at 1024 and 500 and nowhere else**. That is the diagnosis, not a coincidence: at viewport 1024 the live pane rail is `[44,260]` → panel 720, precisely the `44+260=304` the harness froze; at 500 the rail is `[]` on both. At the five widths where the live desk shows only a 44px strip (`pane_builder.ex:796-797` — at narrow with an editor open every pane is `:hidden` except one rigid strip) the harness measured a **different row**, not a differently-configured one. Independent corroboration: at viewport 900 the panel is 856px, above `.bp-paper-surface`'s own `max-width: 720px`, so the surface's cap binds and content is 640px; a 300px absolute inspector overlaps that centred box by ~192px, giving 448px — exactly the instrument's twice-reproduced 448. **Ruling: D102's sub-wide harness figures (900 475, 800 439, 764/700/640 471) are STRUCK as artefacts of a frozen pane rail. The deployed instrument's numbers are the charter's.**

- **D106 — `spd-b29` COST 41px AT EVERY SUB-WIDE WIDTH, AND D100's OWNED SHORTFALLS ARE STALE BY EXACTLY THAT.** The 41px in-flow strip comes out of the panel. Where the surface's own 720px cap binds (900, 800) it costs 0–5px; where the **panel** binds (1024, 764, 700, 640) it costs the full 41. Panel widths and floor values on the deployed build are **byte-identical to D103's pre-b29 run** (764 → panel 720 / floor 630.591px; 700 → 656 / `0px`; 640 → 596 / `0px`), which is what proves the loss happens *inside an unchanged panel*. Consequences: viewport 640 native is **4.30ch short, not ~0.2ch**, and forced Georgia **9.10ch short, not ~5.4ch**; and **viewport 700 / Georgia regressed from 55.04ch MEET to 51.33ch FAIL** — a brand-new shortfall created by `spd-b29` and owned by no decision. **Ruling: D100's per-face figures are SUPERSEDED by this entry. Viewport 700 / Georgia is named and owned here. Any ruling quoting D100's numbers ships a false record.**

- **D107 — "DESKTOP ROWS" IS DEFINED HERE, BEFORE THE TABLE IS CONSULTED.** The term is undefined in the wave wish, in the strategic direction, AND verbatim in the seal-ruling's own brief — and the verdict moves with where the line falls (≥764 seals clean at all three faces; ≥700 fails on Georgia; ≥640 fails on two). A threshold chosen after seeing which side it lands on is the epic picking its own passing grade. **Ruling: "desktop rows" = the seven viewports 1440, 1280, 1024, 900, 800, 764, 700. Excluded and named: viewport 640 (owned shortfall, D100 as amended by D106) and viewport 500 / `phone` (never ch-gated — its criterion is navigability plus no horizontal scroll, D100). This definition is fixed and may not be renegotiated by the slice that consults it.**

- **D108 — THE SEAL IS REFUSED. `spd-b29` RELOCATED THE CRUSH; IT DID NOT REMOVE IT.** One real click on `[data-test-id="sidebar-toggle-panel"]` against the deployed merged build stamps `data-user-opened`, the b29 rule stops matching (it is scoped `:not([data-user-opened])`), and the pre-b29 `@container content (max-width: 860px)` overlay reasserts in full — `position: absolute`, `width: 300px`, `z-index: 5`, scrim rendering. Measured, per-face, probe-derived, no cross-face division: **1024 → 380px (38.00ch Iowan / 34.40ch Georgia / 41.43ch Source Serif 4); 900 → 448px (44.80 / 40.55 / 48.84); 764 → 396px (39.60 / 35.85 / 43.18). 0 of 9 user-opened cells MEET; 9 of 9 default cells MEET.** Those px figures are the wave-6 baseline **to the pixel** — the seal-ruling's own quoted 1024→380 · 900→448 · 764→396. The reader who opens the panel to read metadata sees precisely the desk this epic was filed to fix. And the seal-ruling's own acceptance criterion 6 reads verbatim: *"A seal taken while the reader sees 38ch is a criterion failure."* **Ruling: NO SEAL. The default-state table is a genuine, measured, large win and is recorded as such. The user-opened state is the epic's remaining defect; it is handed to a NAMED successor with this table as its charter. A true no-seal is preferred to a false seal, and that preference is written here as a decision rather than discovered later.**

- **D109 — AT THE MOMENT OF THE CLICK, THE LAYOUT NUMBER RISES WHILE THE READER LOSES 219px.** `content_px` **increases** (1024: 599 → 640; 764: 631 → 672) because the 41px strip leaves flow and hands its width back to the panel, while `visible_content_px` **collapses** (599 → 380; 631 → 396). **Ruling: on the single interaction this epic is about, the layout metric and the reader move in OPPOSITE directions. This — not the collapse — is the strongest available argument for an occlusion-derived metric, because it needs no counterfactual and is on the deployed build now.**

- **D110 — THE INSPECTOR STATE BECOMES A MATRIX DIMENSION; THE NAVIGATION AXIS IS RETIRED.** `drilled` and `cold-load` agree in **54 of 54 cells across two independent runs** — the matrix spends 27 rows re-proving that how you arrived does not matter and **zero** rows on the axis that changes the answer by 219px. A grep of the instrument for any click on the inspector toggle returns zero hits; its "two entry states" are navigation paths, never open/closed. **Ruling: `inspector_state ∈ {default, user-opened}` replaces `entry_state` as the second axis, at all nine widths and all three faces. D80's descending-sweep discipline is KEPT (the bucket dead-band is widen-only; a fresh-nav-per-row shortcut is a different protocol and is not adopted). This is the highest-value single change available to this wave.**

- **D111 — THE SCRIM IS DIMMING, NOT HIDING, AND IT IS REPORTED RATHER THAN SUBTRACTED.** When it renders (`position: absolute; inset: 0` on `.editor-with-preview`, which contains `.bp-paper-surface`) it covers the **entire** content box at 55% black — `scrim_covers_content_fully: true` at 1024, 900 and 764. Counting that as occlusion makes `visible = 0px` at every sub-wide user-opened width, so no seal is ever possible in that state and the metric can no longer rank improvement. Counting it as nothing is D36 in a new form. **Ruling: `visible_content_px` measures GEOMETRIC occlusion — can the reader see the glyph at all. The scrim is reported alongside as `dimmed_content_px` + `scrim_alpha`, named in every row it renders, and never folded into the headline number. Silence about it is what is forbidden; neither arithmetic alone is.** In the default state it renders in **0 of 54 rows** — b29's scrim guard works — so it contributes nothing to the table the epic would have sealed on, and everything to the state it must not seal on.

- **D112 — OCCLUSION IS ATTRIBUTED BY DIFF, NEVER BY IDENTITY-MATCHING A TOPMOST ELEMENT.** `elementsFromPoint` structurally skips `pointer-events: none` **and never returns a pseudo-element** — the scrim is both (`.editor-with-preview:has(.bp-doc-sidebar.is-open)::after`, `pointer-events: none` deliberate and authored, because a click-catching scrim would swallow edits). Proven live: with the scrim painted over them the leftmost samples return the identical topmost element they return when no scrim exists. Forcing `pointer-events: auto` via an **injected stylesheet** (a pseudo has no inline style — this is a real deviation from the instrument's two existing inline-style mutate-measure-restore uses) flips those samples at 1024/900/764, and restore is byte-identical in all four runs. But what it detects is *"an ancestor became topmost"*, which is **ambiguous** — `main.bp-paper-surface` is already topmost at one sampled point with no scrim at all. **Ruling: occlusion is the DIFF between a pointer-events-natural sample and a pointer-events-forced sample. Matching a topmost element against a known list would rebuild the hand-maintained occluder list the redesign exists to abolish. A non-vacuity guard proving the forced sample DIFFERS from the natural one in a known-scrim state is MANDATORY (D31/D39): an injected rule whose selector drifts out of sync with the stylesheet is a silent no-op, and a vacuous pass here would falsify the seal itself.** Element occluders (a modal backdrop, a sticky bar, `spd-b35`'s presence dot, an overlay nobody has written yet) are caught automatically by this design — that is what it buys.

- **D113 — THE FLOOR LEVER IS REFUTED BY MEASUREMENT AND RETIRED AS A PIXEL LEVER.** A bucket-scoped `html:not([data-width-bucket="wide"]) .editor-panel { min-width: N }` was injected live at N ∈ {700, 800, 900, 1000, 1200}. **Viewport 900: delta 0px at EVERY floor up to 1200px** — the panel widens 856→1200 and the surface does not move one pixel, because `max-width: 720px` binds absolutely. **Viewport 800: +5px, saturating** (0.5ch; and the cap does *not* bind there — the binder is `panel(756) − strip(41) = 715`, five pixels under). **Viewports 764 / 700 / 640: +41 / +105 / +165px that DO NOT REACH THE READER** — `.pane-layout` starts scrolling horizontally (`scrollWidth 844 > clientWidth`, `overflow-x: auto`) and the surface's right edge lands **19.5 / 83.5 / 143.5px beyond the viewport**, `surface_fully_visible: false` at all three. That is D88's prediction reproduced live rather than argued. **And the slice's premise is dead: `.editor-panel`'s left edge is 44px at EVERY sub-wide width** — the rail has already yielded everything, there is no squeeze left to convert, and `.pane-column`'s D94 `flex-shrink` is not in play at all (the columns are `display: none`, not shrunk). Its target rows also **already pass**: 900, 800 and 764 MEET ≥55ch at all three faces. **Ruling: `spd-w5-measure-lever-moves` is RE-CHARTERED from a pixel lever into a COHERENCE slice — outcome (C)'s container move plus the at-rule pin of D114 plus `--paper-gutter` unification — and its result may NEVER be sold as a reader-width fix (D77/D93/D103 compounded). Note for the record that `.editor-panel` already ships `min-width: 560px`: the lever was always a RAISE of a shipped floor, never an introduction.**

- **D114 — OUTCOME (C) IS LANDABLE FOR THREE TEST EDITS, AND ITS REAL HAZARD IS UNGUARDED BY EVERY EXISTING TEST.** Probe-applied in a throwaway worktree: **exactly 3 breaks, all in `wide_geometry_lock_test.exs`, NONE in `measure_parity_test.exs`** (which has **zero** occurrences of `container-type`/`container-name` and is fully inert — D77's "3 of 24 assertions break" belongs entirely to the separable `--paper-gutter` rewrite and must stop being quoted as one risk with this). The direction's prediction that `.editor-panel`'s own census entry breaks is **REFUTED**: `declared_geometry_props/1` collects property NAMES and discards values, proven by the real output's `Missing: []`. The three real breaks are (1) the literal `value!(block, ".editor-panel", "container-name") == "content"` pin, (2) the new reading-column rule absent from `@geometry_census`, (3) that same selector absent from the `scoped?` closed literal allowlist — and adding it is a **genuine widening** of the lock's permitted set (the rule applies at 1280/1440 by design), so it lands with a stated reason, not as boilerplate. **THE HAZARD: a half-done edit that renames the container but leaves the 860px inspector at-rule pointing at `content` ships GREEN through 73 tests in five suites** — deliberately sabotaged and re-run to prove it — with the overlay-vs-dock threshold silently resolving against the READING COLUMN instead of the full panel, off by the inspector's own 300px, at every width, with no error and no red until someone measures. At-rule headers are excluded from the census **by design** (`last_line/1` halts at them, with its own negative control). That is D39/D40's disease re-authored inside the slice meant to cure it. **Ruling: the slice MUST add an at-rule-name pin, or outcome (C) ships an unlocked hinge. `.editor-panel` KEEPS `container-type: inline-size` — only the NAME moves — because the strict reading reds a fourth assertion in `editor_panel_containment_test.exs`, a guard whose moduledoc is about a real Blink containing-block hazard.** The stale prose in `root.html.heex` still calling `.editor-panel` the `content` container is re-authored in the same slice, or it becomes the next cold agent's false map (D69's pattern in a new file).

- **D115 — THE INSTRUMENT'S "~10 MINUTES" IS OFF BY ~20x AND IS A LIVE FALSE-BLOCKER.** Four real observations of a full authenticated 54-row sweep: **29.8s, 30.9s, 32.8s, 59.7s**. The `~10 minutes` claim appears **five times across four comment sites**. A builder or verifier trusting it treats a 90s run as already 9x over budget and aborts it, or waits 10x too long before suspecting a genuine hang. Two further comments are now **FALSE** rather than imprecise, both from `spd-b29`: `default_state_note` reads *"server-default OPEN — this is the state a user lands in"* when below `wide` that same `is-open` class paints a 41px collapsed strip with title and body `display: none`; and the block comment above the inspector measurement claims docking would double-count *"at exactly the two widths (1280, 1440)"* when the deployed build docks at **every** sub-wide width. **Ruling: all corrected in the instrument slice, with the replacement wording naming the observed range and its worst case rather than replacing one over-confident number with another.**

- **D116 — THE LEDGER'S SHORT NUMBERS ARE AMBIGUOUS AND MAY NEVER BE USED TO DISPATCH.** Four collisions are live in the epic's children, every one of them `open`: **`spd-b18`** (`-btn-focus-visible-desk-wide` / `-census-built-paper-editor-css`), **`spd-b21`** (`-emit-motion-duration-tokens` / `-strip-focus-browser-proof`), **`spd-b30`** (`-instrument-coverage-one-document-one-path` / `-wide-bucket-ab-measured`), **`spd-b35`** (`-presence-dot-intercepts-action-bar` / a BARE-ID task about a dead CSP hash). A Decide or a lead skimming by short number misfiles work against the wrong task. **Ruling: every reference in this charter, in any brief, and in any dispatch is by FULL SLUG. And D98's fence residue is executed this wave rather than deferred a third time — `scaffy-backlog-blocks-editable-studio` keeps its correct `open` status but loses its orphaned FENCE NOTICE prose, and `sup-w5bk-beta-doc-editor-savestate` flips `blocked` → `open` and loses its notice too, closing `spd-b13u`.**

## Wave-8 amendment (THE INSTRUMENT'S EVIDENCE wave, 2026-07-20) — D117–D135

**These decisions were authored at wave-8 Decide and landed at wave-8 Review, and the gap between those
two facts is the wave's sharpest finding (D135).** The wave Paper's Decide section states that
"the ruling itself is written and COMMITTED to the charter as D117-D134". It was not. The charter at
`origin/main` ended at **D116**, and a scan of every `origin/*` branch for a charter containing D120 or
D134 returned zero hits — while the instrument **merged** citing D121/D130/D131 in code comments that
resolved to nothing. Two builders discovered this by looking and correctly refused to build on it. The
text below is transcribed from the wave Paper, which is the authoritative record of what Decide ruled;
Review's role here is to make the citations resolve, not to re-decide them.

- **D117, D118, D119 — PROMOTED FROM WAVE-7 REVIEW, AND STILL UNRESTATED.** Decided and sabotage-proven at wave-7 Review, narrated only in the seal paper, never written to the charter file — which topped at D116 and would have collided with a freshly minted D117. **Ruling: these numbers are RESERVED to the wave-7 Review findings and may not be reused. Their content is not restated here because the wave-8 Paper does not restate it, and inventing it would be exactly the fabrication this charter exists to prevent. The next wave that needs to cite D117-D119 must first transcribe them from the wave-7 seal paper into this file.** Note for the record that wave-8 dispatch briefs used "D119" for a *different* claim (the short-number allocator being the defect rather than the names); that usage is superseded here by D133, and any brief still citing D119 for the allocator is citing the wrong number.

- **D120 — NO SEAL.** The seal condition fails on **both** clauses in the DEFAULT state, before the user-opened state is consulted — three cells fail, and two of the three were owned by no decision. The written ledger is NAMED as satisfiable and the seal on it is DECLINED, because D107 fixed the desktop rows before any table was seen precisely so the epic could not pick its own passing grade. **Ruling: NO SEAL, confirming D108 on the hardened instrument. Review re-ran the gate against `65541e2d4` == `origin/main` (slot BLUE queried over ssh, bracket MATCHED, non-vacuity guard 21 applies / 21 passed, 54 rows, 0 unsettled) and the three failing default cells are forced Georgia at 1280 (596px = 53.95ch), 1024 (599px = 54.22ch) and 700 (567px = 51.33ch), same-face probe advance 11.0469 px/ch at 18px, shipped horizontal overflow 0px at all three. Native and Source Serif 4 MEET >=55ch at all seven of D107's desktop widths. Every failing cell now has a named owner — 1280 and 1024 on `spd-b28-floor-binds-georgia-1280-overflow`, 700 on D106, 640 on D100 as superseded by D106. THE SHORTFALL ACCOUNTING IS CLOSED.** `spd-w6-visible-seal-ruling` remains the slice that must write this ruling as the epic's formal gate; what it inherits from here is a decided outcome and a bracketed main-sha run, not an open question.

- **D121 — THE TABLE IS 54 ROWS, NOT 162.** 9 widths x 3 forced faces x 2 inspector states. The 162 figure multiplied the row count by the three figures each row reports. A ruling expecting 162 declares a correct run incomplete or invents a fourth axis. **Ruling: 54 rows is a COMPLETE run. This is pinned in the instrument's `--help` and in `artifact.row_count_note` so the correction travels with the data.**

- **D122 — THE NON-VACUITY PRECONDITION PASSED 21/21, WITH EVERY NON-APPLYING ROW ACCOUNTED.** The alternative failure mode is a false seal manufactured by the instrument built to prevent one. **Ruling: `applies > 0` is the load-bearing half — `applies: 0` is vacuous, not a pass, and `artifact.non_vacuity_guard.vacuous` records it explicitly. Reproduced by Review in two further runs.**

- **D123 — THE REPRODUCTION TEST PASSES AND THE ~200px DISPUTE IS CLOSED.** Two measurements of one quantity 200px apart is the tell that saved the last wave; a 1.2px refinement is not that. **Ruling: closed. Review adds that three independent runs — the builder's on `3be27f0fd`/green and two of Review's on `65541e2d4`/blue — agree on 0 of 216 compared values across `visible_content_px`, `content_px`, `legacy_inspector_subtraction_px` and `visible_ch`.**

- **D124 — #4737 IS NOT COHERENCE-ONLY; IT COST 12px AT 1280 AND 9px AT 1024.** A geometry disclaimer in a commit message is a claim, and this epic measures claims. D93 predicted it verbatim and required a run that was never done. **Ruling: the disclaimer is struck; the cost is on the record.**

- **D125 — BUT THE MEET IT REMOVED WAS MANUFACTURED BY A FLOOR BIND THAT OVERFLOWED THE COLUMN IT PROTECTED.** Both halves belong on the record, and the consequence is sharper than a regression: **no configuration on record makes 1280/Georgia both meet the bar and avoid a scrollbar.** **Ruling: the 1280/Georgia MEET that #4737 removed was never real reading width, and the pair D124+D125 must always be quoted together.**

- **D126 — THE IN-FLOW CEILING, PER WIDTH AND PER FACE.** `ceiling = min(panel_px, surface cap 720) - gutter - 55 x probe px/ch`. At 1024: **90.0px native, 32.4px forced Georgia, 135.5px Source Serif 4**; at 700 forced Georgia **0.4px**. Because the 720px surface cap binds at every width at or above 1024, widening the viewport buys NO inspector room — the ceiling is **FLAT from 800 through 1440**. This is what converts the successor from a discovery wave into a closing one. **Ruling: docking is arithmetically dead at 1024; the question was never dock-or-overlay. CORRECTION, on the record rather than silently swapped — the "a 300px dock leaves ~42ch" figure in the Paper's ceiling section and in the wave-8 Decide narration is the PRE-gutter panel remainder (420px) and *exceeds* the overlay's 378.958px, so as written it refutes the sentence it supports. The correct comparable is the gutter-subtracted 340px = 34.00ch native, which is worse than the overlay by 38.958px on every face. The conclusion survives; the figure is STRUCK. Any brief still quoting 420px or ~42ch is quoting a struck number.**

- **D127 — THE USER-OPENED STATE IS HANDED OVER AS A PRE-REGISTERED QUESTION, NOT RULED EXEMPT.** Exempting a mode after seeing an unfavourable table is D107's gerrymandering with extra steps. **Ruling: the successor MAY rule it exempt — after stating the rule before it looks.**

- **D128 — THE SUCCESSOR IS `spd-b39-user-opened-inspector-shape-successor`, BY FULL SLUG.** It already exists; minting a new one forks the ledger. **Ruling: successor work is written ONTO `spd-b39`, which now carries the full user-opened table, the ceiling arithmetic, the pre-registered question and the corrected comparables — enough that a cold reader opening it alone can state the problem and the arithmetic.**

- **D129 — THE MD3 COMPARABLE IS CORRECTED AND CONTENTFUL IS STRUCK.** D101 cited MD2's archived taxonomy and a pixel range MD3 does not state, and MD3's only third-pane endorsement is gated to **1600dp+**, above every width this epic tests. One clean citation beats three shaky ones. **Ruling: MD3 cited accurately (two-tier standard/modal, 600-1199dp, standard sheets shrink rather than overlay); Contentful STRUCK as unsourced; Sanity retained width-unconfirmed; Linear checked and inconclusive. D101's law holds — "the Kinsta bar" is a craft standard in this charter, never a layout citation.**

- **D130 — THE INSTRUMENT HAD A SILENT NO-OP THAT INVERTED ITS OWN DOCTRINE.** The entrypoint guard compared a raw `path.resolve(process.argv[1])` against `fileURLToPath(import.meta.url)`. That is asymmetric: Node resolves ESM module URLs through realpath, while `argv[1]` arrives verbatim from the shell. macOS `/tmp` symlinks to `/private/tmp`, so `INVOKED_DIRECTLY` never fired and the process exited **0 with zero bytes on stdout AND stderr** — through `tee`, an empty file at exit 0, one careless `| tail` from being read as "no failures". **Ruling: both sides resolve through realpath; the fix is SYMMETRY, not a `/tmp` special case. Red-tested through a symlink: before exit 0 / 0 bytes, after exit 1 / 119 stderr bytes, failing by name. REVIEW ADDENDUM — the same slice reintroduced the same disease one level up: `const OUT_PATH = resolveOutPath()` ran at module scope ~80 lines ABOVE the `const die` it calls, so all three malformed-`--out` paths threw a raw `ReferenceError: Cannot access 'die' before initialization` instead of the named failure they compose, and none had been exercised because the red-test hit the `--doc=` path. Fixed at Review by resolving inside the entrypoint chain. Filed as `spd-b46-entrypoint-guard-untested`: two unexercised failure paths in one slice whose whole purpose is readable failure is a testing gap, not bad luck.**

- **D131 — THE EPIC HAD NEVER COMMITTED A RUN ARTIFACT, AND THAT IS WHY EVERY WAVE RE-MEASURES.** A table that cannot be retrieved gets re-derived, wrongly, by whoever needs it next. #4736 added 859 lines and zero save-to-disk capability, so the wave-7 sweep survives only as prose in a closed task with `viewport 500 / user-opened` blank at byte level. **Ruling: `--out <path>` writes the complete run — every row plus a flattened `run.artifact` provenance header — and committed runs live in `scripts/measurements/`. The write happens AFTER the provenance bracket closes, so no unbracketed matrix can reach disk. The D131 blank is FILLED, not explained away: viewport 500 / user-opened carries `dimmed_content_px` 174.944 in all three faces at `scrim_alpha` 0.55, and `visible_content_px` is 174.944 too — equal because D111 is working, the scrim dims rather than hides.**

- **D132 — EPIC CRITERION INDEX 2 (0-BASED) IS THE EMPTY ONE, AND D124/D125 ARE ITS MISSING EVIDENCE:** desktop >=1280 is NOT unchanged. **Ruling: the epic's own acceptance criterion 2 is answered by the D124/D125 pair, and must be stamped with both halves or not at all.**

- **D133 — COLLISION FAMILIES, AND SLUG UNIQUENESS DOES NOT CATCH CONTENT DUPLICATES.** Decide counted nine; the sweep found **ten**, and the tenth (`spd-w8`, five members) was minted *by this wave's own slice allocation while the sweep was running* — the defect reproducing under observation, which is the strongest available evidence that the fault is the allocator and not the existing names. `spd-b27` and `spd-b37` are the same finding filed 93 minutes apart under non-colliding slugs, a class slug uniqueness structurally cannot catch. Renumbering would dangle references inside merged PR bodies, which are immutable. **Ruling: collisions are prevented at allocation time, never repaired by renaming; content duplicates are caught by reading, not by the id. Every reference in this charter, in any brief, and in any dispatch — and every ledger write, including re-parenting — is by FULL SLUG (`bp task get spd-b28` 404s). `spd-b40-ledger-short-number-collisions` carries the current census and the counting traps that inflate and hide the count.**

- **D134 — THREE TICKETS, ONE MEASUREMENT, AND ONLY ONE NEEDS THE BACKFILL MECHANISM.** A done task's criteria are frozen: stamping returns `409 not_in_progress:done` and re-claiming returns `409 not_ready`, so the only backfill is `bp doc patch` + `bp doc publish` — which writes a draft overlay invisible to `bp task get` until published and **bypasses every guard**: no epoch fence, no criterion-text check, no lease. **Ruling: backfill by patch is permitted and MUST paste the full before/after array, because nothing in the system will catch a malformed `--set` that silently clobbers ten rows. Open tasks close by the normal claim-stamp-close path and may not use it.**

- **D135 — A DISPATCH BRIEF IS NOT A CHARTER, AND A PAPER SAYING "COMMITTED" DOES NOT COMMIT ANYTHING.** Wave 8's Paper asserted that D117-D134 were "written and COMMITTED to the charter"; the charter ended at D116 and no branch carried them. Wave 8's briefs then cited those numbers as settled law, and the instrument merged citing D121/D130/D131 in code comments that resolved to nothing — so a cold agent following them hits exactly the confident-empty-grep this epic has been overturned by twice. Two builders caught it by looking: one held `spd-b30-georgia-1280-unbound-after-container-move` at 2/3 rather than close it on a decision that existed in no tree, which is the discipline the epic was overturned twice for lacking. Compounding it, the brief-level and Paper-level D-numbering **disagreed** — the briefs used D119 for the allocator, which the Paper had assigned to a wave-7 promotion and D133 to the allocator — so two artefacts in one wave cited different decisions under one number. **Ruling: a wave that authors D-numbers MUST land them in the charter FILE in the same wave that cites them, and a Paper's claim to have done so is a claim like any other — this epic verifies claims. Decide writes decisions; Review writes the log. A brief may quote a decision, never create one, and never renumber one. A citation to a D-number the charter does not define is a defect in the citing artefact.**

## Wave-9 amendment (THE RULING LANDS wave, 2026-07-20) — D136–D147

**This wave owed exactly one run and one landing.** Wave 8 ruled NO SEAL at Decide and then did not
land the ruling — D135's disease, discovered in the wave that authored the cure. Wave 9 does not
re-derive the table. `git diff --name-only 65541e2d4 origin/main` returns exactly three paths — this
charter, `scripts/measurements/spd-visible-table-2026-07-20.json`, `scripts/studio-desk-measure.mjs` —
and **zero product code**. The desk has not moved one byte since it was measured. So the wave's proof
obligation is DIFFERENTIAL, not discovery: prove the committed table survives the merged instrument
against the currently-served build, with the expectation registered BEFORE the run and the diff
MECHANICAL. That prediction could fail. It did, once, in five — which is the wave's most useful finding
(D138) and the reason this charter does not say "0 of 54".

- **D136 — NO SEAL. THE EPIC'S FORMAL GATE, REFUSED ON ALL THREE LEDGERS, IN WORDS.** A refusal that does not say which ledger it is taken on invites the next wave to infer the friendliest one. All three are stated, and all three refuse.
  **(i) THE WRITTEN LEDGER.** Of four acceptance criteria on `studio-space-priority-desk`, indices 0, 1 and 3 carry `met: true` with evidence; index 2 carries `met: false` with an EMPTY evidence string. That emptiness is not unmet-pending — the criterion is ANSWERED AND FALSE (D140). A criterion set one of whose criteria measurement has DISPROVEN cannot complete as written. The criterion the wish mistook for it is index 1, and index 1 IS genuinely met — but it is scoped to exactly one width and one state: at a 900px viewport in the DEFAULT state the column measures 640.000px = 64.00ch native / 69.78ch forced Source Serif 4 / 57.93ch forced Georgia, each divided by its own face's probe span at 18px. One width, one state, is not the epic.
  **(ii) THE CHARTER LEDGER** — D107's seven desktop viewports (1440, 1280, 1024, 900, 800, 764, 700; 640 excluded as a named owned shortfall and 500/phone never ch-gated), DEFAULT state, >=55ch on all three faces. **REFUSED by three of twenty-one cells**, all forced Georgia: 1280 at 596.000px = 53.95ch, 1024 at 599.000px = 54.22ch, 700 at 567.000px = 51.33ch. All three report `overflow_px: 0` — genuinely narrow columns, not scroll-masked. The other eighteen MEET: native and forced Source Serif 4 clear 55ch at all seven widths; forced Georgia clears it at 1440, 900, 800 and 764. D106's figures for the excluded 640 are quoted and D100's are STRUCK: native 50.7ch (**4.30ch short**), forced Georgia 45.9ch (**9.10ch short**). The "~0.2ch / ~5.4ch" figures may not be quoted — they were the USER-OPENED state read as the default one.
  **(iii) THE USER'S ORIGINAL COMPLAINT** — the reader who clicks the inspector open. **REFUSED**, and refused hardest. Across D107's seven widths x three faces in the USER-OPENED state, on the VISIBLE verdict (D139): **5 MEET, 16 FAIL**. The clean claim is the sub-wide one — **at 1024, 900, 800, 764 and 700 x three faces, 15 of 15 FAIL, without exception.** The sharpest single cell: at a 1024px viewport under the native face one click takes the reader from 599.000px = 59.90ch to 378.958px = **37.90ch** — 220.042px = 22.00ch gone — with the inspector at `position: absolute`, `width: 300px`, overlapping the content box by 260px.
  **Ruling: NO SEAL. Three ledgers, three refusals, one verdict. This is D120 promoted from a wave decision to the epic's formal gate; `spd-w6-visible-seal-ruling` closes on THIS number.** A seal on the written ledger was argued for and is defeated by arithmetic, not by preference: criterion 2 is falsified, so the set cannot complete.

- **D137 — D117, D118 AND D119, TRANSCRIBED VERBATIM; AND WAVE 8's NOTE ABOUT D119 IS STRUCK.** D135 requires a wave that cites a D-number to land it in this FILE. D117-D119 have been cited eight times and defined zero. Recovered from the published wave-7 seal Paper `studio-space-priority-desk-seal-2026-07-20` (`_draft: false`), blocks `block-94` / `block-95` / `block-106`:
  - **D117 — THE AT-RULE PIN WAS BLIND TO AN UNNAMED CONTAINER QUERY.** `container_at_rules/1` parses `@container <name> (…)` only, so a perfectly legal unnamed `@container (max-width: …)` would slip past BOTH of spd-w5's new guards at once: the census never parses it, and the name pin has nothing to compare. That is the SHARPEST form of D114's hazard rather than a weaker one — an unnamed query resolves against the NEAREST ancestor container, so which of content/panel answers it is an accident of markup, and the two differ by the inspector's 300px. Fixed by counting every `@container` token in the decommented sheet against the named parse. Sabotage-proven: one injected unnamed rule -> 1 failure naming it by count; revert -> 16 tests / 0 failures.
  - **D118 — THE ANNOUNCEMENT AND THE ACTION WERE COUPLED BY A COMMENT.** `visually_open?` in `components.ex` and `painted_closed?` in `handlers/paper.ex` are one predicate written twice, in two files, in opposite polarity. spd-b29f's builder named the drift as the slice's most likely rot and left it in prose. Fixed by pinning the invariant a reader checks with their eyes rather than the implementation: across all sixteen (bucket x panel_open x user_opened) states, a control announcing OPEN must announce CLOSED after one press, and vice versa. Sabotage-proven: `painted_closed? = false` -> 1 failure; revert -> 128 / 0. It reds on a drift in EITHER file, from either side.
  - **D119 — THE SHORT-NUMBER COLLISIONS ARE AN ALLOCATOR DEFECT, NOT A NAMING ACCIDENT.** D116 counted four families; a re-read of all 81 children counts EIGHT (`spd-b12` and `spd-b14` were missed entirely, `spd-b30` is now THREE-way, `spd-b38` is newly two-way — and `spd-w5` / `spd-w6` carry seven and four respectively). Two of those were created BY THIS WAVE, hours after D116 ruled against them, because builders allocate `spd-bNN` concurrently in isolated worktrees and structurally cannot see each other's filings: the collision rate is a function of wave WIDTH, not of care. Renumbering the existing pairs buys nothing while the allocator stands. **Ruling: new slugs drop the counter entirely (a descriptive slug needs none) or ids are minted server-side; D116's full-slug law stands meanwhile.**
  **Ruling: the wave-8 amendment's closing sentence — "any brief still citing D119 for the allocator is citing the wrong number" — is STRUCK. It is false on the Paper's own text: D119 IS the allocator ruling, in its own title. D133 does not supersede it; D133 is a LATER CENSUS of the same ruling (ten families, pulled at 89 children) and its own source text, the census inside `spd-b40-ledger-short-number-collisions`, ends "it is the strongest available evidence for D119." The wave-8 briefs were right and the charter was wrong. D133's "Decide counted nine" is corrected: the nine is D119's own ENUMERATION (its prose says eight while enumerating nine), so the census reads 4 (D116) -> 8-in-prose/9-enumerated (D119) -> 10 (D133). D119 and D133 are quoted TOGETHER, the way D124+D125 are, never one as the other's supersession.** The amendment that declined to read the Paper it pointed at, and then ruled on what it contained, is the confident-empty-grep reproduced by the guard written to prevent it.

- **D138 — THE COMMITTED TABLE SURVIVES; THE INSTRUMENT IS ~80% DETERMINISTIC, NOT 100%.** The prediction registered before the run was **0 of 54 rows differing, tolerance ZERO, diff MECHANICAL**. The instrument-delta premise it rested on was itself false and made the prediction STRONGER: the committed artifact was not written by `d7a4f1547` but RE-RUN at `09dde3292` (the TDZ-fix commit) after a redeploy, and `git diff 09dde3292 c30d4a2d2 -- scripts/studio-desk-measure.mjs` is EMPTY — so this predicted an identical script reproducing itself against an unchanged build. **The run diverged: 1 of 54 rows, 8 fields.** Per the halt rule it was attributed, not called noise. The divergent row is `640 / user-opened / source-serif-4`: the face override failed, `font.face_applied` went `true -> false`, the stack fell back to Iowan and every ch-derived figure moved with it (`content_ch` 59.75 -> 54.8, `probe_px_per_ch` 9.1719 -> 10). **The box did not move** — `visible_content_px` 270.967 and `content_px` 548 are identical in both runs; only the ch CONVERSION changed. The instrument DETECTED this itself and emitted a fourth warning naming the row and the substituted family (`measure.mjs:1030`, designed-in impossibility #6) — it did not report a fallback as the named face. Four further runs against the same served build each returned `0 of 54 rows differing, 0 field diffs, identical warning set, exit 0`. The divergent row is outside the ruling set on BOTH axes (640 excluded by D107; user-opened handed over by D127). A sixth invocation exited 1 having written ZERO bytes with its stderr lost — a hard whole-run failure in six attempts, undiagnosed. **Ruling: the honest sentence is "4 of 5 completed runs reproduce the committed table at tolerance zero; the fifth diverged in one row outside the ruling set and the instrument caught it itself". This charter, every brief and every Paper quote that sentence and NEVER "0 of 54". D97's single-point-of-failure concern is NOT retired: the face-override flake and the zero-byte hard failure are filed as `spd-instrument-nondeterminism-characterised`, and a run that writes zero bytes is an INSTRUMENT FAILURE reported as such, never as a desk fact.** Bounded retries on a NAMED fail-closed abort (the `[data-user-opened]` marker check, observed 1 in 3) are permitted — those runs write nothing, so retrying is safe — while tolerance on row VALUES stays zero.

- **D139 — THE USER-OPENED VERDICT IS QUOTED FROM `visible_meets_55ch`, NEVER `content_meets_55ch`.** Every row carries BOTH fields and on the 21 desktop user-opened cells they disagree by FIFTEEN: `content_meets` = 20, `visible_meets` = 5. Quoting the layout field would let this ruling claim 20-of-21 MEET in the very state it is refusing to seal on — the exact inversion of the verdict. The honest ledger is **5 MEET, 16 FAIL**; the earlier "6 MEET" miscounted a list of five, and "0 of 9 user-opened desktop cells" is D108 correctly scoped to the THREE widths it measured (1024/900/764 x three faces), which still reproduces exactly — but D108's companion clause "9 of 9 default cells MEET" is now **FALSE** (1024/forced Georgia default is 54.22ch) and is superseded here. The five that MEET all sit in the wide bucket where the inspector **DOCKS** rather than overlays: `position: static`, `overlap_over_content_box_px: 0`, scrim absent, one-click delta **0.000px** — 1440 on all three faces, 1280 on native and Source Serif 4. **The sixteen failures decompose by CAUSE and must be quoted decomposed: THIRTEEN are OVERLAY-CAUSED (the cell MEETS in default and FAILS on one click) and THREE are INHERITED from the D136(ii) default shortfall and fail in BOTH states (forced Georgia at 1280, 1024, 700).** Charging the inherited three to the inspector would double-count the default shortfall. **Ruling: the ruling names which field it quotes; the 13/3 decomposition is the epic's statement of the user-opened harm; the scrim figures ride ALONGSIDE and are never folded in (D111) — `scrim_alpha: 0.55`, `covers_content_fully: true`, `dimmed_content_px` equal to the row's whole `visible_content_px` in each of the 21 rows where it renders, and 0 of 27 default rows.**

- **D140 — EPIC CRITERION 2 IS ANSWERED AND FALSIFIED UNDER BOTH OF ITS TEXTS, SO D94-vs-D132 DOES NOT NEED ADJUDICATING TO RULE.** D94 re-authored criterion 2 into a four-clause compound test; **that re-authoring was never applied** — the live task still carries the original "Desktop (>=1280px) behavior is unchanged…" verbatim, `met: false`, `evidence: ""`. D132 then ruled on the original text. They are not rival rulings: D94 governs the TEXT, D132 governs the SLOT and the EVIDENCE, and neither is struck. Both texts fail, independently — the original by D124 (#4737 cost 12px at 1280 and 9px at 1024: not unchanged), and D94's clause (c), which demands rows at 1280 and 1440 across all three forced faces at content >=55ch, by the measured 1280/Georgia 53.95ch. D124's costs reconcile to one pre-#4737 figure: 596+12 = 599+9 = **608px = 55.04ch**, which is precisely D125's manufactured MEET — a floor bind that overflowed the column it protected. **Ruling: criterion 2 is stamped ANSWERED AND FALSIFIED with `met: false` and a full evidence string carrying the D124+D125 pair (D125's law), the measured figures, and the statement that BOTH wordings fail. The stored criterion text is SYNCED to D94's, because the stored string is the only wording a cold agent reads and leaving it stale is D135's defect pointed the other way. The stamp must also say, rather than imply, that D94's own pre-epic A/B against `89f151c21` was NEVER RUN — `spd-b30-wide-bucket-ab-measured` is open at 0/3.** The epic task is lifecycle `open`, so D134's patch backfill is BARRED; this closes by the normal claim-stamp-close path.

- **D141 — D120's OWNERSHIP LINE NAMES A MECHANISM THAT IS NOT PRESENT ON THE MEASURED BUILD.** D120 attributes the 1280/1024 forced-Georgia failures to `spd-b28-floor-binds-georgia-1280-overflow`. On `65541e2d4` the floor binds in **0 of 54 cells** (`min_inline_size_px = 0`) and `overflow_px = 0` in exactly those cells — the slug asserts two mechanisms, NEITHER present. `spd-b28` is itself `done`, and its own close reason says verbatim: "That shortfall is owned by `spd-b30-georgia-1280-unbound-after-container-move`, NOT by this ticket." The failures are real; the cause is the **720px surface cap plus Georgia's 11.0469 px/ch advance at 18px**, not a floor bind and not an overflow. **Ruling: the ownership is restated BY MECHANISM. The 1280 and 1024 forced-Georgia cells and the 700 cell are owned by `spd-b42-georgia-default-shortfall-inflow-width` (open, 0/4, the actual fix ticket); D106 keeps the 700 finding and D100-as-superseded-by-D106 keeps 640. `spd-b28` is cited for its own retired 12px overflow and for nothing else, and epic criterion 1's evidence string — which still cites "binds in 2 of 54 cells" against a different SHA — is corrected in the same write.** This also unblocks `spd-b30-georgia-1280-unbound-after-container-move`, held at 2/3 by a builder who correctly refused a decision that existed in no tree (D135): that decision now exists, and it is this one.

- **D142 — THE EPIC CLOSES ON A VERDICT.** NO SEAL is a verdict, not an incompletion. An epic that cannot close without sealing is held hostage by its own optimism, and keeping it open as a container for a successor is how ledgers rot — 86 children, 52 of them open, is the evidence. **Ruling: `studio-space-priority-desk` closes at wave-9 Review on D136, with `spd-w6-visible-seal-ruling` closed as its gate. `spd-b39-user-opened-inspector-shape-successor` is moved to ROOT and stands as its own work, carrying the 27-row table, the D126 ceiling arithmetic, D127's pre-registered question and D139's decomposition. Nothing stays open under a closed epic; nothing closes without a sentence.** D134's backfill is not needed anywhere in this closure — every task involved is `open`.

- **D143 — THE SWEEP GETS ITS DOCTRINE BEFORE IT SEES THE LIST, AND THE FOURTH BUCKET IS NAMED.** The same anti-gerrymander logic that made D107 fix the desktop rows first. Every open child goes to exactly ONE bucket with a written reason: **(1) CLOSED** — done in fact, obsoleted, or a duplicate of a named sibling; **(2) RE-PARENTED to `spd-b39`**; **(3) RE-PARENTED OUT** under the surface fence; **(4) STANDALONE ROOT.** The fence as previously stated does not cover what the sweep actually found: **zero** open children reference `cloud/` or `api/tenancy` at all, exactly ONE crosses to `internal/cli` (`spd-b25-task-ls-all-pagination-stalled`), and SIX are core Tasks/Sheets-plugin bugs mapping to none of the three destinations. **Ruling: bucket 4 absorbs them as standalone roots, because forcing a Tasks-plugin ledger bug into a Studio-desk or PDS fence is a category error. Two named exceptions: `spd-b25` is CLOSED as a duplicate, not re-parented — the identical defect is already tracked open at `pds-bl-task-ls-pagination-stalled` and `tlv-bl-tasks-ls-offset-broken`, and re-parenting would mint a fourth copy; `spd-b24-blocked-lifecycle-is-not-a-fence` IS re-parented, to `task-lifecycle-visibility-epic`, which already carries `tlv-bl-ready-allowlist-consolidation` on the identical `queue.ex:35` / `claim.ex:26` allowlist. The census must recurse `spd-b39`'s subtree (D144) and re-read immediately before mutating — the ledger moved twice during wave-9 verification alone.**

- **D144 — THE COLLISION COUNT IS CONVENTION-DEPENDENT AND THE CENSUS MUST RECURSE; AND ONE SHORT NUMBER RESOLVES SILENTLY.** Four, eight, nine, ten — every prior count was right for its moment and its convention, and none said which convention it used. On a full descendant read (86 direct children + 5 grandchildren under `spd-b39` = 91 nodes; no other child has descendants) there are **SEVEN open-vs-open `spd-bNN` families — b12, b14, b18, b21, b30 (three-way), b35, b44 — or TEN if `spd-wNN` wave groupings are counted the way D133 counted them (adding w5, w6, w8).** Two of the seven (`spd-b38`, `spd-b44`) are invisible to a scan of the epic's direct children — they only appear one level down under `spd-b39`, so a top-level census undercounts by two families structurally. `spd-b44` was minted **ten minutes after the sweep task that diagnosed the allocator defect**, which is D119 reproducing under observation for the third recorded time. **Ruling: any quoted collision count NAMES its convention and its timestamp and states that it recursed. The worst case is not the 404s — `bp task get spd-b28` / `spd-b12` / `spd-b14` / `spd-b30` all return `not_found`, which is loud — it is `spd-b35`, where one of the two colliding tasks is literally named `spd-b35`, so `bp task get spd-b35` RESOLVES SILENTLY to the dead-CSP task and shadows `spd-b35-presence-dot-intercepts-action-bar`. A silent wrong answer outranks a 404. The bare slug is retired this wave. This wave applies D119 to ITSELF — partially, and the partial failure is the point. The three backlog items it mints (`spd-instrument-nondeterminism-characterised`, `spd-palatino-linotype-unmeasured`, `spd-scrim-guard-real-but-wrong-selector-untested`) carry NO counter at all, the first in this epic to do so. The five slices kept the `spd-w9-` WAVE prefix — and on filing, the ledger revealed a pre-existing `spd-w9-b29-noflash-frame-sample`, so `spd-w9` became a SIX-member family the moment this wave filed into it. **D119 reproduced under observation for the FOURTH recorded time, inside the wave that transcribed D119 and ruled on it.** That is not carelessness; it is the allocator, exactly as D119 said, and a wave prefix is a counter wearing a different hat. **Ruling extended: wave prefixes are counters too. The successor mints NO shared prefix — every slug is descriptive and standalone, or ids are minted server-side.** `spd-b40-ledger-short-number-collisions` may NOT close on its own text — its title still says "Four" and its criterion 1 is not merely unmet but WORSE than at filing.**

- **D145 — "NATIVE" IS NOT A FACE, IT IS A PLATFORM VARIABLE — AND THAT STRENGTHENS D136(ii) RATHER THAN WEAKENING IT.** The instrument reports `probe_px_per_ch: 10` exactly for the native face, which reads like a fallback. It is not: Iowan Old Style Roman's `0` advance is 1139/2048 em = 10.0107px at 18px, and Chrome floors `1ch` to LayoutUnit (1/64px) — 10.0107 x 64 = 640.688 -> 640 -> **10.0000**. The same model reproduces Georgia (11.047852 -> 11.046875 = the reported 11.0469) and Source Serif 4 (587/64 = 9.171875 = 9.1719) exactly, and the artifact independently records the unquantized 10.0107 in `in_floor_px_per_ch` by a different derivation. Correcting the 0.107% understatement flips **zero** cells — the tightest native cell, 700, moves 56.70ch -> 56.639ch, still 1.64ch clear. But the shipped stack is `Iowan Old Style, Palatino Linotype, Palatino, Charter, Georgia, "Source Serif 4", serif`, and which member wins is a PLATFORM fact: macOS gets Iowan (and Charter, at an identical advance); stock Linux falls through to the self-hosted Source Serif 4 webfont and MEETS comfortably; **Linux with `ttf-mscorefonts-installer` resolves the UNFORCED stack to Georgia and lives D136(ii)'s three failing cells for real.** **Ruling: the forced-Georgia rows are not a synthetic stress face — they faithfully simulate a reachable configuration, so D136(ii) stands on firmer ground than "a face nobody gets". The word "native" is retired from ruling prose in favour of naming the resolved family. One genuine hole is filed rather than guessed: `Palatino Linotype`, the WINDOWS-native winner and second in the stack, has never been measured; it fails only if its `0` advance exceeds 0.5727 em, which sits BETWEEN Iowan's 0.5562 and Georgia's 0.6138 — a coin-flip on the largest desktop platform, filed as `spd-palatino-linotype-unmeasured`.**

- **D145 APPENDED NOTE (2026-09-02, `task-a2f3b567899e9851`) — THE PALATINO GAP IS RECORDED AS UNMEASURED, NOT RESOLVED.** `spd-palatino-linotype-unmeasured`, the hole D145 filed rather than guessed, was closed `cancelled` / platform-blocked on 2026-09-02: this fleet has no Windows host, so the coin-flip D145 names is still open on the largest desktop platform. It is one command on any Windows box, and the charter records it so the next person with one does not have to re-derive it: `node scripts/font-zero-advance.mjs "C:\Windows\Fonts\pala.ttf"`. D136(ii) fails for Windows iff the reported `0` advance exceeds 0.5727 em — between Iowan's 0.5562 (passes) and Georgia's 0.6138 (fails). Until that runs, every ruling that says the shipped stack meets is MEASURED on macOS and Linux and UNKNOWN on Windows. **Separately confirmed the same day, on the deployed reader:** D145's model of the Source Serif 4 leg is exact and the self-hosted fallback is sound — `/fonts/SourceSerif4Variable-Roman.woff2` serves 200 / 426716 B / `font/woff2`, and where the stack head is absent the face loads on the natural render path (no manual `document.fonts.load`) and measures **9.1797 px/ch at 18px**, matching D145's 587/64 = 9.171875 derivation. The earlier "Source Serif 4 never loads" report was an instrument misread: `document.fonts` enumerates every DECLARED `@font-face` regardless of load state, and `document.fonts.check` returns false by spec for a declared-but-unloaded webfont — on macOS Iowan wins, so the browser correctly never downloads it. No descriptor was broken.

- **D146 — CRITERION 8's GATE PROOF IS NECESSARY AND NOT SUFFICIENT, AND BOTH GATES PASS BY EXECUTION.** Nobody had run them; they were run. `docs-anchors-check: PASS (12 pre-existing warnings)`, `check-doc-budgets: PASS`, both exit 0, card count exactly 7 — and they still pass with a ~200-line charter amendment and a second ~700KB measurement artifact in tree. The premise holds by construction: the charter is in neither script's scope (`check-doc-budgets.sh` has no entry for `.claude/workflows/**`; `docs-anchors-check.sh` excludes `.claude/` in three separate mechanisms), and `scripts/measurements/**` is referenced by neither. **Ruling: criterion 8 is satisfied by those two outputs, AND the record states that the `doc-gates.yml` JOB runs 25 named steps of which criterion 8 names two — once the charter's `.md` extension trips the blanket `**/*.md` glob, all 21 other blocking gates run unconditionally and can red the PR for reasons wholly unrelated to this wave. A red there is not this wave's fault and still blocks merge. `docs/cards/plugins.md` sits at exactly 2400B of its 2400B cap; any card edit reds the budget gate.**

- **D147 — THE SERIF-STACK ATTACK DOES NOT LAND, AND `spd-b37`'s PREMISE IS FALSE.** `spd-b37-serif-stack-disagreement-root-vs-editor` asserts that `root.html.heex` declares `--paper-font-serif` Source-Serif-4-first and that "the editor sheet wins". **There is no cascade contest to win.** `root.html.heex` declares that variable in exactly TWO places, both scoped to fixed-position chrome popovers — `:4828` inside `.bp-slash-menu` and `:5023` inside `.bp-paper-format` — and NEVER on `.bp-paper-surface`, `.bp-paper-editor-body` or `:root`; it only CONSUMES it. The built `bp-paper-editor.css`'s `:root,:host` declaration is the sole declaration in scope for the reading column, so every ch figure in this epic rests on it alone. **Ruling: `spd-b37`'s criterion 2 is already SATISFIED by the committed artifact, which names `font.resolved_family` on all 54 rows with `fell_back_to_generic_serif: false`; its criterion 1 is mis-framed and harmonising the two popover declarations changes zero ch figures. The task is re-scoped to what actually survives — a cosmetic chrome-vs-surface disagreement (the same finding as `spd-b27-serif-token-desync-editor-vs-root`, already `cancelled`, per D133) plus the stale comment at `root.html.heex:95-97` claiming the surface body face is Source Serif 4, which now leads nothing. The inheritable question is D145's Palatino gap, not this one.**

## Roadmap — THE RULING LANDS wave (wave 9)

Five slices, all round 1, all dispatched together. Per D19 every model column reads `opus`. Per D135
the charter is written and COMMITTED by Decide — this file, this wave, before any builder flies — and
briefs may quote D136-D147 but may not create or renumber a decision. Four of the five slices are
LEDGER-ONLY by design and touch zero repository files, so their file sets are disjoint by construction;
the sweep and the hygiene slice partition the child list by explicit exclusion so they never write the
same task.

| # | Slice | Task | Round | Model | Size |
|---|---|---|---|---|---|
| E | The differential evidence becomes a committed mechanism — the mechanical differ, N runs with stderr captured, the artifact on disk (D138) | `spd-w9-differential-evidence-committed` | 1 | opus | medium |
| R | The ruling is stamped — `spd-w6-visible-seal-ruling` 0-8 against D136-D147, epic criterion 2 ANSWERED AND FALSIFIED (D136/D140/D141) | `spd-w9-seal-ruling-stamped` | 1 | opus | medium |
| S | The child sweep — every open child bucketed by D143 with a written reason, by full slug (D143/D144) | `spd-w9-child-sweep-executed` | 1 | opus | large |
| H | Ledger hygiene — the epic's stray dotted keys unset, `spd-b40` re-scoped honestly, the bare `spd-b35` retired (D144) | `spd-w9-ledger-hygiene` | 1 | opus | small |
| B | The successor inherits corrected arithmetic and a live provenance — `spd-b39` to root (D139/D141/D142/D145) | `spd-w9-successor-handoff` | 1 | opus | medium |

Backlog filed this wave: `spd-instrument-nondeterminism-characterised` ·
`spd-palatino-linotype-unmeasured` · `spd-scrim-guard-real-but-wrong-selector-untested`

## Wave log

## Roadmap — THE SEAL wave (wave 7)

Round 1 dispatches immediately — three slices, strictly disjoint file sets. Round 2 is the lead's
post-merge dispatch. Per D19 every model column reads `opus`. The charter is written by Decide and
by the round-2 ruling slice only; round-1 slices paste their evidence into their own bp tasks.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| M | The instrument measures the state the user CHOSE — `inspector_state` axis, occlusion by diff, the scrim named as dimming, the false comments corrected (D110/D111/D112/D115) | `spd-w7-instrument-occlusion-and-state-axis` | 1 | — | opus | large |
| C | The floor lever retires as a pixel lever and lands as coherence — outcome (C) plus the at-rule pin the census cannot give (D113/D114) | `spd-w5-measure-lever-moves` | 1 | — | opus | large |
| A | The inspector stops lying about its own state — `aria-expanded` in the painted-closed strip | `spd-b29f-inspector-aria-lie-in-painted-closed` | 1 | — | opus | small |
| R | The ruling on the hardened metric — NO SEAL is the expected outcome, written as a decision, with the named successor and its charter (D107/D108) | `spd-w6-visible-seal-ruling` | 2 | M, C | opus | medium |

Backlog filed this wave: `spd-b38-b29-cost-41px-at-panel-bound-widths` ·
`spd-b39-user-opened-inspector-shape-successor` · `spd-b40-ledger-short-number-collisions`

## Wave log

### Wave 2026-07-20 — Wave 7 (THE SEAL), Decide.

The wish asked this wave to seal on `visible_content_px` or hand off a named successor. It hands off,
and the reason is a measurement rather than an argument. Both of the wish's own premises were one wave
stale and saying so was the wave's first act — `spd-w5-measure-lever-moves` was already re-anchored at
wave-6 Decide (its live brief opens by naming D74/D79 as wrong), and D93 had already foreclosed the
(A)/(B) binary the wish offered. Then the ground moved twice more: all four "LANDING NOW" PRs were
already merged, **and guerrilla was already serving `15e057f83`** — so the measurement that decides the
epic was runnable on day one, with nothing built first. Round 0 was dead before it was written.

The direction's central fear — that `visible_content_px` would collapse onto the layout number and the
epic would seal on a definitional artefact — is **confirmed as a mechanism and refuted as an indictment**
(D104). The collapse is total, 54 of 54 rows, reproduced in two bracketed runs with zero rows differing.
But it happened because a 300px absolute overlay genuinely became a 41px in-flow strip, so every default
row is a large real gain. The sharpest attack on the direction ("you inferred this from reading code")
was answered by running it; its escape hatch — that the harness was right and the metric already honest —
was closed in the other direction, with the harness identified as the artefact by arithmetic the run
supplied (D105).

What actually decided the wave was the state nobody had measured. The instrument never clicks the
inspector toggle; its "two entry states" are navigation paths that agree in 54 of 54 cells. One real
click reasserts the overlay and the reader measures **380px = 38.00ch at viewport 1024** — the wave-6
baseline to the pixel, and verbatim the number the seal ruling's own criterion names as a disqualifier
(D108). `spd-b29` relocated the crush from the default state into the state the user chooses; it did not
remove it. So the epic does not seal, "desktop rows" is defined **before** the table is consulted rather
than after (D107), and the successor is named and handed the user-opened table as its charter.

Three further findings reshaped the build. `spd-b29` cost 41px at every sub-wide width, which makes
D100's owned shortfalls stale by exactly that and creates a **new** one at viewport 700 under Georgia
that no decision owned (D106). The floor lever was refuted live — 0px at 900 at every injected floor up
to 1200px, and gains at 764/700/640 that push the surface off-screen — and its premise is dead, because
`.editor-panel`'s left edge is 44px everywhere and the rail has already yielded everything (D113); it is
re-chartered as coherence only. And outcome (C) turns out to be cheap in tests but to carry a hazard
every existing test is blind to: a half-done edit leaving the 860px at-rule pointed at the wrong box
ships **green through 73 tests in five suites**, deliberately sabotaged and re-run to prove it (D114).

The one outcome this wave refuses is a seal taken on the default state while one click away the reader
sees 38ch. Paper: `studio-space-priority-desk-seal-2026-07-20`.

### Wave 2026-07-20 — Wave 8 (THE INSTRUMENT'S EVIDENCE), Review. Grade B+.

**The wave ruled, and then failed to land the ruling.** D120 — NO SEAL — was decided at wave-8 Decide,
with its reasoning intact and its failing cells named. The wave Paper then stated that "the ruling itself
is written and COMMITTED to the charter as D117-D134". It was not. The charter ended at **D116**, no
`origin/*` branch carried D117-D134, and the instrument **merged** citing D121/D130/D131 in code comments
that resolved to nothing. For the length of this wave the epic's ruling existed only inside a Paper that
claimed to have written it down. That is the wave's defining defect, and it is the same false-"live"
claim the wish warned about in a different register: a Paper asserting a write is a claim, and this epic
verifies claims. Review transcribed D117-D135 into the charter from the Paper, which is the authoritative
record of what Decide ruled; Review's job there was to make citations resolve, not to re-decide them.

**Two builders caught it before Review did, and both refused to build on it.** One held
`spd-b30-georgia-1280-unbound-after-container-move` at 2/3 precisely because its third criterion demands a
charter DECISION that existed in no tree — "closing it would have been a false seal on a decision that
does not exist". That is the discipline this epic was overturned twice for lacking, exercised
unprompted. Compounding the fault, brief-level and Paper-level numbering **disagreed**: the briefs used
D119 for the short-number allocator, which the Paper had assigned to a wave-7 promotion and D133 to the
allocator. Two artefacts in one wave cited different decisions under one number (D135).

**What landed in the tree.** One slice of four, `spd-w8-instrument-entrypoint-and-artifact`. The
entrypoint guard now resolves both sides through realpath — symmetry, not a `/tmp` special case — closing
a defect where the instrument could **exit 0 having written zero bytes to stdout AND stderr**, which
through `tee` is an empty file at exit 0 and one careless `| tail` from reading as "no failures" (D130).
`--out` writes the complete run with a flattened provenance header, `--help` exists for the first time,
and the first run artifact in this epic's history is committed at `scripts/measurements/` (D131). The
other three slices were ledger-only by design and produced zero repository change between them.

**Review re-measured rather than accepted, and found one real bug.** The committed run was taken on
`3be27f0fd`/green, one commit behind main — the builder flagged this himself and pointedly declined to
claim it measured main. The box has since re-deployed, so Review re-ran the gate against **`65541e2d4` ==
`origin/main`, slot BLUE queried over ssh, bracket MATCHED, guard 21 applies / 21 passed, 54 rows, 0
unsettled**. Across three independent runs — the builder's plus two of Review's — **0 of 216 compared
values differ**. The builder's own stated doubt is closed by measurement rather than by argument. The bug:
`const OUT_PATH = resolveOutPath()` ran at module scope ~80 lines above the `const die` it calls, so all
three malformed-`--out` paths threw a raw `ReferenceError` instead of the named failure they compose —
D130's disease reintroduced by the fix for D130, inside the slice whose whole purpose is that the
instrument must never fail unreadably. None had been exercised; the red-test hit the `--doc=` path
instead. Fixed at Review; filed as `spd-b46-entrypoint-guard-untested`.

**The table, measured against main.** Default state, D107's seven desktop widths: native and Source Serif
4 MEET >=55ch at all seven; forced Georgia fails at exactly three — 1280 (53.95ch), 1024 (54.22ch), 700
(51.33ch) — and every one now has a named owner (D120/D106/D100-as-superseded). User-opened: **0 of 21
sub-wide cells meet**, 1024 collapsing to 378.958px = 37.90ch native. D108's NO SEAL is confirmed on the
hardened instrument, on main, with the shortfall accounting **closed**.

**Next wave: dispatch `spd-w6-visible-seal-ruling` and nothing else until it lands.** It is the epic's last
gate and was never dispatched. It no longer has anything to discover — only to write D120 as the epic's
formal ruling and hand `spd-b39` the successor charter. Its criteria 0, 1 and 7 are already satisfied by
artefacts in the tree and on the ledger; a reviewer note on the task spells out which, so it inherits a
bracketed main-sha run instead of re-deriving one. Paper: `studio-space-priority-desk-ruling-2026-07-20`.

## Wave-10 amendment (THE INSPECTOR STOPS BORROWING THE COLUMN, 2026-07-20) — D148–D160

**Root work, not epic residue.** `studio-space-priority-desk` closed at wave-9 Review on D136's NO SEAL
(D142), so `spd-b39-user-opened-inspector-shape-successor` stands as its own root. This is its first wave.

**TRANSCRIBED AT REVIEW, AND THAT IS ITSELF THE WAVE'S DEFINING DEFECT.** D135 rules that a wave which
cites a D-number MUST land it in this FILE in the same wave, and that a Paper's claim to have done so is
a claim like any other. The wave-10 Paper asserted verbatim that D148–D160 were "written and COMMITTED
to `.claude/workflows/bp-studio-space-priority-charter.md` in the same wave that cites them." They were
not. The charter ended at **D147**; `git diff --name-only origin/main..<branch>` on all four built
branches returned zero charter paths; and three of the four slices shipped code comments citing D148,
D149, D151, D152, D155 and a `D156b` that is not a decision at all — so a cold agent following the merged
tree would hit exactly the confident-empty-grep this epic has been overturned by twice. **This is D135's
disease reproducing for the THIRD recorded time, in the wave whose own Paper quotes D135 while doing it.**
Review transcribed D148–D160 from the published Paper (`spd-inspector-successor-wave-2026-07-20`, the
authoritative record of what Decide ruled) so the citations resolve; Review's job here was to make
citations resolve, not to re-decide them. **Ruling extended: "Decide writes decisions" is not satisfied by
Decide writing them into a Paper. The charter FILE is the ledger; a decision that lives only in a Paper is
a decision that does not exist for any builder cutting a worktree from `origin/main`.**

- **D148 — The Tier-2 ladder ships and costs ZERO lines of CSS**, because the overlay and its 55%-black
  scrim live entirely inside `@container panel (max-width: 860px)`, which stops matching at panel 980.
  Confirmed independently twice at Decide, and re-confirmed at Review: the ladder slice's diff touches no
  `.heex` and no stylesheet, and the four CSS gates were never implicated.
- **D149 — The dock stays 300px.** Trimming to 292px is gerrymandering to one face's arithmetic ceiling —
  the move D83 and D103 forbid — and 260px moves `wide` by 40px, which epic criterion 2 forbids outright.
  The forced-Georgia cell is INHERITED from the default-state shortfall, so charging it to the ladder
  double-counts it. Owned by `spd-b42-georgia-default-shortfall-inflow-width`, not by this clause.
- **D150 — D127 Part 1 is amended PER FACE, before the run.** The ladder's claim is that the THIRTEEN
  overlay-caused failures of D139's decomposition are abolished — **not** that all three faces MEET.
  Forced Georgia at 1024 lands at 54.31ch against a default cell already at 54.22ch: the ladder adds
  0.09ch and does not fix an inherited shortfall. Registering this BEFORE the deployed run is what keeps
  it a prediction that can fail rather than a result read backwards (D127's own order law).
- **D151 — `display_state/5` is additive by ARITY, and the `/4` equivalence test is what keeps D94(a)
  from hollowing out.** Elixir dispatches `/5` separately, so the `/4` table is untouched by
  construction — but a call-site swap to `/5` satisfies D94(a) LITERALLY while making its 40-cell table
  stop describing what the desk renders. The equivalence suite (4 buckets × 1..8 panes × both editor
  states, inspector CLOSED) is the bridge that keeps the old lock load-bearing, and it is a named
  deliverable rather than an implication.
- **D152 — The fifth input is seeded in `mount.ex`; defaulting at the READ site is the same hole wearing
  a green test.** `sidebar_user_opened` was seeded only by `sidebar_assigns/1`, reached only from
  `setup_paper_view` — measurably ABSENT on a fresh mount for sheet, graph, field form and desk root.
  Reading it as `@sidebar_user_opened` in the pane comprehension raises `KeyError` through
  `Phoenix.LiveView.Diff.process_keyed/5` in 5 of 7 views. `Map.get(assigns, …, false)` at the read site
  compiles, goes green, and silently pins every non-paper desk to false.
- **D153 — A successful fix makes the non-vacuity guard VACUOUS, so its law becomes CONDITIONAL and
  acquires a mandatory positive control.** All 21 `guard_applies` rows in the committed table are the
  sub-wide user-opened scrim rows this wave abolishes. Once abolished, `vacuous: true` is the PREDICTED
  outcome — but a drifted selector produces the identical zero. **A run is INVALID unless >0 rows in the
  SAME run render a scrim and the guard is seen to fire.**
- **D154 — Dismissal is the SIBLING-scrim shape, and the tier gate may not key on `width_bucket`.** Both
  existing `components.ex` precedents are siblings, never wrappers, which is why D96 does not condemn
  them — D96's real law is "no dismiss handler on an ANCESTOR of the dialog". `phx-click-away` is
  REFUSED: browser-driven, it fires on a prose click at the DOCKED tier, so a docked inspector would
  dismiss itself when the reader clicks into the document. And after the ladder, 1024 is `standard` AND
  docked, so a bucket-keyed gate announces `aria-modal` on a docked panel; the gate is computed
  server-side from `display_state/5`'s own inputs.
- **D155 — Tier 3 is a summoned DESTINATION with a new crumb kind; `nav_path` is not extended; the
  paper-only scope is said out loud.** At `narrow` and `phone` the arithmetic is closed (D113): a 300px
  dock at viewport 800 leaves 376px against the overlay's 396.9px — the dock is WORSE. So the panel takes
  the full pane and **dimming is ABOLISHED, not tuned**: the defect D127 names is INDETERMINACY, and a
  panel that covers the pane completely says it is on top by being the only thing there.
- **D156 — "Wide moved zero pixels" is THREE proofs, each named for what it actually proves, and the lock
  is BLIND today.** (i) the CSS-text census proves the sheet's TEXT did not change unscoped; (ii) the
  runtime rule-deletion diff proves the rules are inert at 1280/1440; (iii) the bracketed deployed run
  proves pixels. `pane_family?/1` matches only `pane-layout`/`pane-column`/`editor-panel`, so
  `.bp-doc-sidebar.is-open` is invisible to the epic's one non-vacuous wide lock — proven by mutation:
  a 300px→200px dock edit passes 16 of 16 while moving 1280 wide content 596px→640px. **There is no
  `D156b`; a wave-10 code comment cites one. Any brief or comment citing `D156b` is citing nothing.**
- **D157 — The instrument's third-state defect is the SILENT DROP, and D121's literal 54 is retired as a
  NUMBER while its doctrine survives.** Feeding a synthetic third-state row into a real run: 55 rows go
  in, `destination` appears ZERO times in the output, no error raised — three summary loops hardcoded
  `['default','user-opened']`. The subsequent null `.toFixed` crash was already contained by the existing
  try/catch, so the crash was the visible symptom of the harmless half. `expected_row_count` becomes
  arithmetic (widths × faces × states-applicable), never a literal.
- **D158 — The comparables are re-quoted from D129 and three inherited figures are corrected.** MD3 is
  cited accurately (two-tier standard/modal, 600–1199dp, standard sheets shrink rather than overlay);
  its only third-pane endorsement is gated to 1600dp+, above every width this epic tests. Sanity is
  retained width-unconfirmed. The `420px / ~42ch` dock comparable stays STRUCK per D126 — the correct
  figure is the gutter-subtracted **340px = 34.00ch**.
- **D159 — The Part E baseline of 165 is CURRENT, and both colour gates were re-proven by mutation.**
  Seeding `rgba(0, 0, 0, 0.55)` — the natural scrim spelling — leaves `studio-literal-check` PASS while
  Part E goes 165→166; tokenising an existing literal SHRINKS it to 164 and fails just as hard. The two
  gates have INVERSE blind spots (D53) and every brief touching `root.html.heex` names BOTH commands.
- **D160 — The round split is FILE-TRUTH, and D16 is satisfied by arithmetic rather than by scheduling.**
  Round 1's four slices are disjoint by file set, so `root.html.heex` has exactly one owner without any
  slice waiting on a scheduler. Rounds 2 and 3 are the lead's post-merge dispatch.

## Decisions — wave 11 (THE DESTINATION IS A NAVIGATION)

- **D161 — D127 has no lettered sub-conditions, and the exemption test is written HERE, before the run.**
  D127's whole text is a PERMISSION ("the successor MAY rule it exempt — after stating the rule before it
  looks"), one paragraph, no `(a)/(b)/(c)`. The trichotomy quoted all wave is partly traceable to the
  wave-10 roadmap's slice-X title, which cites D154 — so `D127(b)` names a task row, not a decision. Citing
  `D127(a)/(b)/(c)` is the D135 disease for a fourth time and is BANNED. The test itself is adopted now, as
  D161, so it can fail: **the user-opened state is exempt from the dimming verdict only if (i) round-trip
  fidelity holds — default→open→dismiss returns the reading column bit-identical at every width and face in
  ONE run; (ii) the exit is cheap, plural and visible BEFORE it is looked for; (iii) the mode declares
  itself — no scrim renders in any row.** Condition (iii) is already MET on the deployed build
  (`content: none`, live-read at 375 and 800, both themes). (i) and (ii) are this wave's work.
- **D162 — The a11y-absence finding is renumbered here; it was never D139.** On-disk D139 is the
  `visible_meets_55ch` verdict decomposition. The "no role, no aria-modal, no Escape, no focus trap, while
  two sibling modals have all of it" text quoted inside `spd-w9-child-sweep-executed` matches nothing in
  this file. The FINDING is true and now live-proven — Escape pressed at 375 and 800 did nothing,
  `document.querySelectorAll('[phx-window-keydown]').length === 0` on the whole page, the sole exit measures
  16×16px and renders `chevron-down` on a BACK action — but it is D162, and the sibling modals demonstrably
  have the ARIA quintet WITHOUT a focus trap or focus restore (zero `.focus(` tied to either modal).
- **D163 — There is no WAI-ARIA/APG citation anywhere in `barkpark_web`, and Tier 3 says so out loud.**
  `grep -i 'APG|WAI-ARIA'` over this charter returns zero — the claim was never D158 (which is about MD3 and
  Sanity comparables). The one APG-cited, focus-trapped, `inert`-marking modal primitive lives in
  `cloud/priv/static/app.js` and is OUT OF FENCE; it may not be ported across. Tier 3's semantics rest on
  INTERNAL precedent, and every brief that ships them names that fact rather than implying a standard.
- **D164 — `aria-modal` is REFUSED at Tier 3, and D154's scrim node is DORMANT, not executed.** The
  destination is `position: absolute; inset: 0` over an opaque `var(--surface)` (no alpha in any of seven
  theme pairs, live-read solid `rgb()` at both widths) — a scrim node beneath it can never be hit-tested,
  and `aria-modal` asserts outside-content is inert where at `phone` `display_state/4` returns `:hidden` for
  every pane. Shipping either to tick a criterion written before the geometry existed is this epic's own
  disease. The truthful semantics are a LANDMARK with an accessible name, a truthful `aria-expanded`, and
  `inert` on the covered content. **D154 survives intact for any tier where the panel overlays PART of a
  pane — D170 establishes that no such tier is reachable today, so D154 is held, not repealed.**
- **D165 — `inert` is a SERVER-RENDERED attribute or it does not exist.** Proven twice on the deployed
  build: `el.inert = true` survives until the next LiveView diff, then morphdom removes it because the
  server markup carries no such attribute — and toggling the inspector IS that diff, so an imperative hook
  would self-disable on first use with no error. It must render as `inert={…}` in HEEx from the assign.
  Two corollaries, both measured: the inert-induced blur is **asynchronous (~38ms)**, so focus-in-before-inert
  is required for ARIA correctness and NOT to beat a synchronous blur, and any builder that sets inert then
  synchronously reads `document.activeElement` reads stale focus; and `isContentEditable` stays `true` under
  an inert ancestor, so a test asserting non-editability that way is vacuous — the discriminating probe is
  that `.focus()` is a no-op. Cost is one attribute: `.editor-body` sits four levels ABOVE the
  `phx-update="ignore"` boundary and an ancestor of that subtree already carries a dynamic assign-computed
  `aria-label`. Live run with the caret in production prose: zero autosave ops across 700ms (> the 300ms
  debounce), zero JS errors, wrapper `innerHTML.length` 953 → 953 across a real server diff.
- **D166 — Escape is not a bare `phx-window-keydown`, and nested precedence is RATIFIED as free.** Driven
  live against the deployed bundle, the split is FOUR SWALLOW / TWO DOUBLE-FIRE, not the two-and-two the
  briefs carried: slash, wikilink, the `#` tag menu AND the command palette all register at document
  CAPTURE and `stopImmediatePropagation` (the palette because `class CommandPalette extends SlashMenu` —
  its own Escape branch is unreachable dead code), while the format-bubble link input and the markdown
  source textarea let Escape bubble untouched. **The swallowers are a feature: with the palette open, the
  first Escape closed it and never reached window, the second did.** That is the nested-modal grammar for
  free and it is preserved, not worked around. The double-firers are the real work, and LiveView has NO
  client-side veto seam (`on()` is a bare bubble-phase `window.addEventListener`, `bind()` pushes
  unconditionally) — so the inspector's Escape owns its own window listener with an `activeElement` guard.
  A third silent-death mode is standing law: a focused element carrying `phx-keydown` suppresses EVERY
  `phx-window-keydown` on the page, so no `phx-keydown` may be added inside the destination. **A
  socket-driven `render_keydown` test proves the server handler and NOTHING about the key** — the browser
  proof is R's, by name.
- **D167 — The dismissal grammar is a HEADER and a CRUMB, both visible rather than discovered.** The header
  is Tier-3-scoped only, docked tiers unmoved: a back control at a genuine 44px target carrying
  `arrow-left` (the glyph must point the way the action goes — D46 on the strip), and the document's real
  title, which today is the hardcoded literal `"Document"` while the correct expression already exists
  eleven lines up in the same module (`paper_doc.title || slug || "Paper"`). Measured live: the head grows
  36.195px → 61px, `head.bottom == body.top` exactly (109==109 at narrow, 145==145 at phone), zero overlap,
  and at 1280 and 1440 the rects are byte-identical before and after. No new colour literals, no new icon
  asset, and no test references these class names.
- **D168 — Crumbs extend to NARROW, and the strip is not the answer there.** `desk_crumbs/1` is gated
  `@width_bucket == "phone"`; at narrow the `<nav>` is never emitted — genuinely absent, not hidden. The
  44px strip DOES return cleanly (`expand-pane` truncates `nav_path`, which resolves `editor: nil` and runs
  `clear_paper_view/1`, which resets `sidebar_user_opened: false` — so there is no staleness defect), but it
  is a whole-document exit, not a graduated one. So D56's "dead end" framing is retired as overstated and
  replaced by the real gap: **narrow has no discoverable return that keeps the document open.** The gate
  becomes `bucket in ["narrow","phone"]`, the crumb grows an inspector segment when
  `has_editor? and sidebar_user_opened`, and the trailing document crumb stops being a dead `<span>` and
  dismisses via `sidebar-toggle-panel` — already in `@safe_events`, so ZERO `caps.ex` entries.
- **D169 — The tier gate is an ENUMERATION, never a negation.** `bucket in ["narrow","phone"] and
  user_opened` — `!= "wide"` is FORBIDDEN because the wave-10 ladder made `standard` + user-opened a real
  DOCKED state, and a negation would announce destination semantics on a docked panel (D154's own warning).
  No plumbing is needed: `width_bucket` and `user_opened` are already declared attrs at the sidebar's call
  site and `has_editor?` is implied by `:if={@paper_doc}`.
- **D170 — The wide scrim is ABOLISHED, because the arithmetic is right and empirically VACUOUS.** The
  `n=5 → panel 844px` figure reproduces exactly — and reaches nothing. With an inspector present the pane
  row is FIXED at `[44, 260]` (papers route to a two-pane `/studio/paper/<slug>` shell), so `panel = vw − 304
  ≥ 976` at every wide viewport; click-drilling reaches 3 nav panes but those states carry NO inspector; and
  the one shape that would breach 860 — the 360px `.bp-secondary-pane` — is unreachable because the paper
  editor does not render the `doc_actions` header (zero `phx-click` nodes containing `secondary` on the live
  page). **So D149's "two live claims on one number" dissolves: abolishing costs zero live pixels, and it
  was never a live positive control either.** D153 stays satisfiable by a control that was executed on the
  deployed build: forcing `.editor-panel` width flips the scrim at exactly 860px inclusive (861 → `none`,
  860 → `""`) at both 1280 and 1440. That forced-container control is the deliberately-held synthetic
  positive D153 sanctions in those words. The abolition rests on the PAPER-ROUTING INVARIANT, not on the
  number 3 — if papers ever land on a deeper path, or the paper editor gains the doc-actions header, the
  breach returns; that is filed, not assumed.
- **D171 — The bucket stamp has a +32px WIDEN-ONLY dead-band, and it is a second vacuity trap in the same
  sweep.** `while (cur < raw && w >= EDGES[cur] + 32) cur++` — a page widened to viewport 1280 stamps
  `standard`, live-confirmed. Narrowing has none. Any no-reload width sweep that arrives at 1280 or 1024
  from below tests the wrong tier while passing. **Every reading in the deployed run asserts
  `data-width-bucket` equals the expected bucket as a PRECONDITION of the reading.** The related scare is
  refuted and needs no work: `data-user-opened` survives every bucket boundary in both directions with no
  reload (no code path can clear it — `handle_event("width-bucket", …)` assigns only `width_bucket` and
  `focus_pane_idx`), a RELOAD is the only reset, and `runRoundTrip` re-summons inside its per-width loop
  anyway, so the closed-vs-closed comparison is structurally unreachable.

## Roadmap — wave 11 (THE DESTINATION IS A NAVIGATION)

Per D19 every model column reads `opus`. Round 1 is file-disjoint by D160/D16 — `root.html.heex` has
exactly one owner. Rounds 2 and 3 are the lead's post-merge dispatch.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| A | Tier-3 chrome CSS + the wide scrim abolished (D167/D170) | `tier3-header-chrome-and-wide-scrim-abolished` | 1 | — | opus | medium |
| B | The return grammar in markup — header identity, narrow crumbs, `inert`, the destination marker (D162/D164/D165/D167/D168/D169) | `tier3-return-grammar-markup` | 1 | — | opus | large |
| K | The wide-geometry lock learns to see the inspector (D156) | `wide-geometry-lock-sees-the-inspector` | 1 | — | opus | small |
| E | Escape, focus-in and focus-return — the guarded window listener (D166) | `inspector-dismissal-and-return-grammar` | 2 | A, B | opus | medium |
| R | The bracketed deployed run — round-trip fidelity, the held positive control, the bucket precondition (D161/D153/D171) | `inspector-shape-bracketed-deployed-run` | 3 | A, B, K, E | opus | medium |

## Roadmap — wave 10 (THE INSPECTOR STOPS BORROWING THE COLUMN)

Per D19 every model column reads `opus`. Round 1 dispatched together (file-disjoint by D160);
rounds 2–3 are the lead's post-merge dispatch.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| L | The Tier-2 ladder — at `standard` the rail yields and the inspector docks in flow (D148/D149/D150/D151/D152) | `inspector-ladder-standard-dock-in-flow` | 1 | — | opus | medium |
| D | The summoned destination at `narrow`/`phone` — dimming abolished (D155) | `inspector-narrow-destination-surface` | 1 | — | opus | medium |
| W | D102's wide-unmoved proof becomes committed tooling (D156) | `wide-rule-deletion-diff-committed` | 1 | — | opus | medium |
| I | The instrument learns a third state and a round trip — the silent drop dies first (D157) | `desk-measure-learns-third-state-and-round-trip` | 1 | — | opus | medium |
| G | The wide-geometry lock learns to see the inspector (D156) | `wide-geometry-lock-sees-the-inspector` | 2 | D | opus | small |
| X | The exit is cheap and plural — sibling scrim, truthful tier gate, returning crumb (D154) | `inspector-dismissal-and-return-grammar` | 2 | L, D | opus | large |
| B | The bracketed deployed run — the only artefact permitted to speak about the deployed render (D150/D153) | `inspector-shape-bracketed-deployed-run` | 3 | L, D, I, G, X | opus | medium |

## Wave log

### Wave 2026-07-20 — Wave 10 (THE INSPECTOR STOPS BORROWING THE COLUMN), Review. Grade A−.

**The shape got decided and built, and the wave answered D127's question in the only currency this
epic accepts: geometry that exists in the tree.** The question was whether a user-summoned inspector is
a MODE with the reading bar suspended, or whether the bar is law and the panel must become something
else. The answer shipped is neither-by-decree but **a ladder keyed to how much room there actually is** —
at `wide` the inspector docks and nothing moves (Tier 1, zero cells); at `standard` the nav rail yields
so the inspector docks IN FLOW (Tier 2, D148/D151); at `narrow`/`phone` the panel stops pretending to
share and becomes a summoned destination over the whole pane with **dimming abolished rather than tuned**
(Tier 3, D155). The half-suspended read D127 ruled a DEFECT — prose at 55% black, layout metric rising
while the human loses 219px — does not survive at any width in any state. That is the wish's central
demand, met.

**What landed, all four slices green on their own gates.** `inspector-ladder-standard-dock-in-flow` —
`display_state/5` as a pure additive ARITY with a `/4` equivalence bridge (4 buckets × 1..8 panes ×
both editor states) that keeps D94(a)'s 40-cell table load-bearing after the call-site swap, plus a new
exhaustive open-dimension table with its own `map_size` guard; `pane_builder_test.exs` verified
byte-identical at `d1e3b5c13b7b729e4c9e83de6d0aa085`; the D152 wiring hole closed in `mount.ex` (the
`@`-read killed 5 of 7 views with `KeyError` through `Diff.process_keyed/5`). Zero CSS, exactly as D148
predicted. **1741 tests, 0 failures** — 1725 baseline + 16 new, so nothing was silently skipped.
`inspector-narrow-destination-surface` — one NEW bucket-keyed selector list, `root.html.heex` +75/−0
insertions-only, the b29/D91 rules byte-untouched, and a scrim lock that EVALUATES THE CASCADE rather
than asserting a rule exists (the D39/D40 vacuity), with an in-process mutation control. All four CSS
gates green, **Part E ratchet 165/165 Δ0** (D159). `wide-rule-deletion-diff-committed` — D102's
"wide is unmoved, proven by deleting the rules at runtime" stops resting on an evaporated harness:
`deleteRule(` existed nowhere in the tree. Fidelity reproduced at tolerance ZERO (1280 → 976/676/596,
1440 → 1136/720/640), the default deletion set IDENTICAL across 18 fields at both widths, and the ch ban
is STRUCTURAL — Review confirmed by execution that clean px passes while a ch-shaped key, a ch-shaped
value and a nested ch figure all hard-throw. `desk-measure-learns-third-state-and-round-trip` — the
SILENT DROP dies first and is proven dead by execution (18 rows in, `destination` printed ZERO times, no
error raised, on the pre-fix printer from git HEAD); `expected_row_count` is arithmetic now (75, and 54
for the two-state run — both verified by Review calling the export directly), and D121's literal 54 is
gone from code and `--help`.

**Review's mutation passes, because a green gate is not evidence.** The ladder's clause was deleted:
4 of 16 new tests red, `pane_builder_test.exs` unmoved — the lock genuinely bites. `position: absolute`
was stripped from the destination rule: the suite reds by name. That second mutation **disproves the
premise of a task the builder filed against himself** —
`summoned-destination-position-coupling-untested` claimed the lock pins the four properties
independently and would "stay green on three of four", but the suite asserts `position` explicitly and
fails loudly. The task is corrected on the ledger rather than left to send someone chasing a non-issue.

**The one real bug Review fixed.** `runRoundTrip` called `openInspectorByRealClick`, which `die()`s on
an unreachable toggle — and `runRoundTrip` runs MID-SWEEP, before the provenance bracket closes and
therefore before anything reaches disk. One missing toggle at one width discarded **every row already
collected and wrote ZERO bytes**, which D138 rules an INSTRUMENT FAILURE rather than a desk fact. That
is the precise all-or-nothing abort this slice was filed to END, reintroduced by the pass it added. The
builder named the asymmetry in his own review and asked a reviewer to push on it; Review did.
`openInspectorByRealClick` gains `fatal` (default true, so the matrix sweep and `user_opened_proof` keep
D97 semantics — an unreached row is not a desk fact) and the round trip passes `fatal: false`, returning
a named skip symmetric with `dismissInspectorByRealClick`.

**THE WAVE'S DEFINING DEFECT IS D135, FOR THE THIRD RECORDED TIME.** The wave Paper stated verbatim that
D148–D160 were "written and COMMITTED to the charter in the same wave that cites them". They were not:
the charter ended at **D147**, no built branch touched it, and three of four slices shipped code
comments citing D148/D149/D151/D152/D155 — plus a **`D156b` that is not a decision at all** — into a
tree where they resolve to nothing. This is the confident-empty-grep the epic has been overturned by
twice, arriving inside the wave whose own Paper quotes the rule against it. Review transcribed D148–D160
from the published Paper onto the ladder slice's branch, so the charter merges WITH the wave (D68) and
the citations resolve the moment they land. **The lesson is now written into the amendment: "Decide
writes decisions" is not satisfied by Decide writing them into a Paper.**

**Ledger audited HONEST — no lies to fix on the wave's own four tasks.** All four left
`lifecycle: in_progress`, stamped every non-merge criterion with substantial evidence as they worked
(361–1820 bytes each), and correctly left the merge-gated criterion `met: false` with empty evidence for
the lead. All four parent to `spd-b39`. Three discovered-but-not-taken items were filed and published
during the run (`spd-b47-ladder-backstrip-expand-collision`,
`summoned-destination-position-coupling-untested`, `desk-measure-printer-proof-harness`), and the three
deferred slices sit `open` and unclaimed exactly as the sequenced-rounds law requires.

**What the lead must know before merging.** (1) **Merge order is not free.** The destination slice makes
the exit MORE load-bearing — the panel now covers the pane completely, so the only way out is the one
`.bp-doc-sidebar__collapse` button (verified present, a real `<button>` with `aria-expanded`, so it is
not a dead end) with no Escape, no focus trap and no focus return. `inspector-dismissal-and-return-grammar`
owns that and is round 2. Shipping Tier 3 before it is an honest, bounded regression in escapability.
(2) **`spd-b47` is inherited, not new**: the ladder's 44px back-strip reuses the `narrow`-with-editor
rule VERBATIM, so its `expand-pane` behaviour at `standard` is identical to what already ships at
`narrow` — worth settling, but the ladder did not create it. (3) Nothing in this wave has run in a
browser against the deployed build; every ch figure is transcribed from the committed 54-row table and
never re-derived or cross-face divided.

**Next wave: merge round 1 (all four are file-disjoint), then dispatch by dependency.**
`wide-geometry-lock-sees-the-inspector` the moment the destination slice merges — the census must
enumerate the FINAL rule set. `inspector-dismissal-and-return-grammar` once the ladder AND destination
merge; it is the escapability debt this wave took on deliberately. Then, after all five merge and
**deploy**, `inspector-shape-bracketed-deployed-run` — the only artefact permitted to speak about the
deployed render, with D150's per-face prediction registered BEFORE the run so it can fail, and D153's
positive control MANDATORY because a successful fix makes the non-vacuity guard vacuous and a drifted
selector produces the identical zero. Paper: `spd-inspector-successor-wave-2026-07-20`.

### Wave 2026-07-20 — Wave 11 (THE DESTINATION IS A NAVIGATION), Review. Grade A−.

**Wave 10's tier-2 ladder is merged and live — verified, and the wish's premise was understated.** All
FOUR of wave 10's round-1 slices are on `origin/main` (#4922 the ladder, #4923 the summoned destination,
#4924 the instrument's third state, #4925 the rule-deletion diff), not one. Wave 11 then finished the
shape it left open: the destination shipped its geometry without its door.

**What landed, all three round-1 slices green on their own gates and green together.**
`tier3-header-chrome-and-wide-scrim-abolished` — the Tier-3 exit earns a 44px touch target scoped by
ENUMERATION (`narrow`/`phone` + `[data-user-opened]`, never `:not(wide)`, because standard docks), with
`justify-content: center` load-bearing so the 16px glyph does not sit 14px from where the finger aims;
and the wide scrim is ABOLISHED (D170) on the paper-routing invariant — papers land on a fixed [44,260]
shell so `.editor-panel` is `vw − 304`, giving 976 at 1280 and 1136 at 1440, both clear of the 860px
generator. The slice did two things beyond its brief and both were necessary: the cascade test asserted
the OPPOSITE of D170 and would have red-mained the merge, and the 44px rule had no tripwire at all.
`tier3-return-grammar-markup` — arrow-left, the document's real title, the enumeration gate, crumbs at
narrow, a server-rendered `inert` (never JS-set: morphdom strips a JS-set inert on the very diff the
toggle produces), `data-inspector-destination` and `data-test-id="sidebar-dismiss"`. Two brief premises
were FALSE and both were fixed: `arrow-left` was not in the icon map and `icon/1` answers an unknown
name with the "file" glyph rather than raising, so `layouts/studio.html.heex` and `chat_live.ex` have
BOTH been painting a document icon on a back control for months — independently confirmed at Review;
and `width_bucket` never reached `studio_paper_view/1` from its only call site, so the component fell to
`"wide"` on every viewport and the spd-b29f aria-expanded fix has been pinned to the wide branch since
it shipped. `wide-geometry-lock-sees-the-inspector` — `pane_family?/1` was blind to `.bp-doc-sidebar`,
proven by MUTATION rather than argument: `flex: 0 0 300px` → `0 0 200px` passed 16/16 on the pre-wave
lock while moving 44px of wide reading column; the new lock reds by name.

**Review's two fixes, both found by integrating before merging rather than after.**
(1) **The narrow crumb trail was half-shipped.** The markup slice widened `desk_crumbs/1` to
`["narrow","phone"]`, but `root.html.heex` still read `.bp-desk-crumbs { display: none }` with a single
`phone` override — written when the trail was a phone-drill affordance. The narrow markup landed inside
a `display: none`, so the desk emitted an escape route out of the Tier-3 destination that no reader
could see and AT announced a way out of a trap that did not exist. That is worse than not emitting it.
Fixed on the CSS slice (which owns the file), tripwired, and the tripwire is mutation-proven — reverting
to phone-only reds it by name. **Neither builder could have caught this alone: it lives exactly in the
seam between two file-disjoint slices, which is the cost the file-truth dispatch law (D160) pays for its
parallelism, and the reason Review integrates.**
(2) **The census collision the geometry-lock builder predicted, arriving exactly as predicted.** That
slice taught `pane_family?/1` to see `.bp-doc-sidebar` in the same wave the CSS slice added a
`min-width` to `.bp-doc-sidebar__collapse` — `min-width` is a geometry property, so the first thing the
new eye saw was the new rule. Integrated, the census red 1/17 with "New in the stylesheet (found, not
declared here)". That is the tripwire working, not failing; Review declared the entry and kept the count
comment truthful (15 → 26, delta ELEVEN, not 25/TEN). **This creates a real merge-order dependency** —
the census is exact in both directions, so the geometry-lock branch is RED standalone until the CSS rule
exists. Review stacked it on the CSS slice's branch so both PRs are green; see the handoff below.

**Full integration: 1769 tests, 0 failures**, plus `design/check.mjs` PASS (18 surfaces, Part H 270
contrast checks), `studio-literal-check` PASS (367 files, no colour literal), `studio-link-lint` PASS.

**THE WAVE'S DEFINING DEFECT IS D135 AGAIN — THE FIFTH RECORDED TIME, AND A NEW MECHANISM.** Wave 10's
log closed by writing the lesson down: "Decide writes decisions" is not satisfied by Decide writing them
into a Paper. Wave 11's Decide DID write D161–D171 to the charter, in a real commit (`6c65b6209`) — and
committed it to **LOCAL main**, unpushed, with no PR and no remote branch, alongside an unrelated PDS
epic's charter commit. `origin/main`'s charter contained ZERO mentions of D161 or D171, while all three
built slices shipped code comments citing D164, D165, D167, D168, D169 and D170 into a tree where they
resolved to nothing. The previous four occurrences were confident-empty greps; this one is a correct
write to the wrong ref, which is harder to see and produces the identical cold-agent experience. Review
cherry-picked `6c65b6209` onto the CSS slice's branch so the decisions merge WITH the code that cites
them (D68). **The lesson extends: a charter commit that is not on a branch headed for `origin/main` has
not been written. Decide must verify the ref, not the commit.**

**Ledger audited HONEST — no lies to fix.** All three built tasks left `lifecycle: in_progress`, parent
`spd-b39`, `wave_paper` linked, every non-merge criterion stamped with substantial evidence as they
worked (278–1069 bytes each), and the merge-gated criterion correctly `met: false` with empty evidence
for the lead. Recorded SHAs resolve. Two discovered-but-not-taken items were filed and published mid-run
(`spd-standard-bucket-scrim-unruled`, `icons-unknown-name-tripwire`); Review filed a third,
`spd-instrument-open-leg-stale-locator`. The two deferred slices sit `open` and unclaimed exactly as the
sequenced-rounds law requires.

**What the lead must know before merging.** (1) **MERGE ORDER IS NOT FREE THIS WAVE.** Merge
`…tier-3-chrome-earns-a-44px-exit-and-the--0-r` FIRST — it carries the charter (D161–D171) and the CSS
rule the census declares. The geometry-lock branch is stacked on it and must merge SECOND; merging it
first reds main. The markup branch is independent. (2) The lead closes the merge-gated criterion on all
three tasks (index 7 / 10 / 6 respectively). (3) **Escapability is still an honest, bounded debt**: there
is no Escape key and no focus management at Tier 3 — `inspector-dismissal-and-return-grammar` owns that
and is round 2. What wave 11 added is that the exit is now findable (44px, arrow-left, named) and
plural (the back control AND the document crumb), which was not true before. (4) `standard` is now the
ONLY bucket in the sheet where a scrim can still render, and nobody has ruled on whether it should;
`spd-standard-bucket-scrim-unruled` holds that question, and the geometry lock's new positive control
SITS on standard, so a ruling that suppresses it must move the control or the file goes quietly vacuous.
(5) Nothing in this wave ran in a browser against the deployed build — the CSS slice's measurement is a
reconstructed shell using the real deployed stylesheet bytes, which is honest and is not the desk.

**Next wave: merge round 1 in the order above, then dispatch by dependency.**
`inspector-dismissal-and-return-grammar` the moment the CSS and markup slices merge — it wires Escape to
the tier predicate and destination marker they create, and D164/D166 already refuse the sibling-scrim /
`aria-modal` / bare `phx-window-keydown` shape its original criteria described. Then, after all five
merge AND the box deploys, `inspector-shape-bracketed-deployed-run` — the only artefact permitted to
speak about the deployed render, with D150's per-face prediction registered BEFORE the run, D171's
bucket precondition on every reading, and D153's positive control MANDATORY. Fold
`spd-instrument-open-leg-stale-locator` into that slice: it owns the instrument file.
Paper: `spd-inspector-shape-wave-11-2026-07-20`.

## Wave-12 amendment (PAY THE EXEMPTION'S PRICE, 2026-07-20) — D172–D181

> Restored to this branch by wave-12 **Review** (D68). D172–D181 and the wave-12 roadmap
> were committed to **LOCAL main only** (`f55af5a03`, unpushed, `6c65b6209`-style) while all
> five built slices shipped code comments citing D173–D181 into a tree whose `origin/main`
> charter topped out at **D171** — the **6th recorded recurrence** of the D135/D68 disease
> (wave 11 was the 5th). Transcribed verbatim here onto **E's `-r` branch** so the decisions
> the code cites reach `origin/main` WITH the code that cites them. The lesson stands, again:
> a charter commit on local `main` is not written until it is on a branch headed for `origin/main`.

- **D172 — MOVE 0 was already paid, and `git merge-tree` lied about it.** The wave opened believing
  `4bc01ec78` and `925839169` sat on loop-epic branches with no PR. Both are on `origin/main`, squashed as
  `1b71730d8` (#5015) and `aef158da9` (#5016), merged 2026-07-20 on sibling `-r` branches; three
  independent surveyors reproduced it and `gh pr view` lists both target SHAs verbatim. Round zero had
  nothing to do. **Instrument warning, bought here:** legacy 3-arg `git merge-tree` reported CLEAN where a
  real `git merge --no-commit --no-ff` found conflicts. It is not trusted in this repo.
- **D173 — Escape owns a guarded window listener at BUBBLE phase, and CAPTURE is forbidden.** D166 is
  upheld and refined by a real browser run rather than re-argued. The veto set is NOT empty: the
  format-bubble link input's Escape branch is `preventDefault()`-only (`format-bubble.js:115-118`) and the
  bubble portals itself to `document.body` (`:146`), so it escapes `.editor-body`'s `inert` —
  `A preventDefault-only reaches window BUBBLE: 1 => DOUBLE-FIRE CONFIRMED`. The refinement is the new
  law: **a capture-phase hook breaks D166's free nested precedence in both placements that fire.**
  `C window-CAPTURE hook w/ palette open: hook=1 menu=1 => HOOK RUNS FIRST — IT EATS THE PALETTE ESCAPE`,
  and document-capture fails identically because the menus register their capture listener inside `open()`
  (`slash-menu.js:202`), so the hook is always first: `F doc-CAPTURE hook mounted BEFORE menu open():
  hook=1 menu=1`. An aside-scoped listener is DEAD for the real cases (`D2: Escape targeted at <body>
  reached aside-capture = 0`). The one shape that works is D166's own — window BUBBLE plus an
  `activeElement` veto: `H1 veto hook, focus IN link input: dismissals=0 => veto WORKS`; `H2 veto hook,
  focus on destination button: dismissals=1 => exit FIRES CORRECTLY`. Veto scope is `.bp-paper-format`
  (never a bare `input`, which would veto Escape from every input on the desk). The markdown source
  textarea is inert-dead (`canvas/index.js:1750` appends inside `.editor-body`) and is kept only as honest
  insurance. Corrected line numbers: the swallowers are `slash-menu.js:436-439` and
  `wikilink-menu.js:251-254`, not the 283/120 the briefs carried.
- **D174 — `api/assets/paper-editor/` stays out of fence this wave, and the reason is the BUNDLE, not
  purity.** The cheapest behavioural fix is one line — `stopPropagation()` in the format-bubble Escape
  branch, measured clean (`E1 stopPropagation added: window BUBBLE=0 => double-fire ELIMINATED`;
  `E2 with palette open: menu=1 window BUBBLE=0 => palette precedence INTACT`). The "out of fence" claim
  as stated was false (charter:137 chartered `spd-b10f` directly into that directory). **But source edits
  do not ship.** The layout loads a committed, minified 496KB artifact (`root.html.heex:5741`) whose last
  build is `4c8032701` (#2891) — **five commits stale**. Shipping one line means rebuilding that artifact
  and dragging five unreviewed commits into the deployed editor, in the same wave whose deliverable is a
  deployed measurement. That would confound the terminal run. Filed, not taken. (My proofs still bind:
  `git log 4c8032701..origin/main` over the three Escape sources is EMPTY.)
- **D175 — The scrim generator is NOT dead everywhere: the secondary-pane breach makes `standard` +
  user-opened LIVE, and it is this wave's sharpest finding.** D170's conclusion at wide survives — its own
  unconditional kill switch (`root.html.heex:2066-2069`, specificity (0,4,2) over the generator's (0,3,1))
  holds regardless of geometry. **Its supporting arithmetic does not.** `panel = vw − 304 ≥ 976` fails the
  moment a 360px `.bp-secondary-pane` is open. `secondary_doc` is assigned in exactly three places
  repo-wide — `mount.ex:186` (seed), `handlers/secondary.ex:82` (set), `:92` (clear on close) — and **no
  navigation handler clears it**. Open a non-paper document, click "Open another", then navigate to a
  paper: at `standard` + user-opened the Tier-2 ladder leaves nav `[44]`, so
  `panel = 1024 − 44 − 360 = 620 < 860`, the generator matches, and **no suppression rule covers
  `standard` + `[data-user-opened]`** — the b29 guard (`:2028`) excludes user-opened, D165's abolition is
  narrow/phone-scoped, D170's is wide-scoped. That is a real, uncaught, visible 55%-black scrim over prose
  the reader is actively reading, with the inspector genuinely docked beside it: the exact D127 defect,
  reached through an orthogonal feature. Coverage is zero — `grep -rl secondary_doc api/test/` returns
  nothing. **Ruled: BOTH halves ship.** `secondary_doc` clears on primary-document navigation AND
  `standard` + user-opened gets its suppression rule. Resting the abolition on an invariant alone is
  precisely what D170 already did once, and this is the invariant breaking.
- **D176 — D153's live-run law is unsatisfiable from real rows, and D170's stated control is IMPOSSIBLE
  as written.** Post-ladder every reachable cell either lifts the panel clear of 860 or is suppressed, so
  no fresh run can render a scrim in `run.rows`. D170 claims the forced-container control "was executed on
  the deployed build … verified at both 1280 and 1440" — **it cannot have been**: at wide, D170's own
  unconditional suppressor makes the reading byte-identical with the generator present and deleted
  (`WITH GENERATOR: wide true none none` / `GENERATOR DELETED: wide true none none`). The control is real
  but it discriminates in **exactly one cell** — `standard` + user_opened, `861 → none`, `860 → ""` — and
  that cell flips to `none/none` when the generator is deleted. Two further traps are law: a fixture
  omitting `data-width-bucket` produces a **FALSE GREEN** indistinguishable from the standard cell, and
  the shipped `--positive-control` is a different mechanism entirely (an unconditional `!important`
  `::after`) that **passes on a fixture with no generator at all**. D153 is amended: the positive control
  is the FORCED-CONTAINER control at `standard`, executed offline against a committed fixture, and it may
  never be quoted as a desk row. Viewport is irrelevant to it — the suppressors key on the stamped
  attribute, the generator on the forced container width; do not re-encode viewports into this control.
- **D177 — The instrument's third state has COLLAPSED into the second; the destination is DERIVED, not
  summoned.** `DESTINATION_CONTROLS` (`studio-desk-measure.mjs:1756-1762`) names two selectors that exist
  nowhere on `origin/main`. The destination is *entailed* by `bucket in ["narrow","phone"] and
  user_opened`, so the instrument's `user-opened` rows at narrow/phone **already are** the destination —
  the separate state is a duplicate reached through an env override. Compounding it,
  `applies_at: (w) => w < 1280` includes **1024, which is `standard` and refuses the predicate**
  (`components.ex:111-113` against the bands at `root.html.heex:1264`) — three pre-loaded false-failure
  rows. **Ruled: retire the summoned third state.** Stamp `is_destination` on the user-opened rows from
  the `[data-inspector-destination]` marker; the row count returns to 54 with 18 carrying it. Those 18
  report `visible_meets_55ch: NULL`, **never FALSE** — a reading column covered by design is not a failing
  measure, and a FALSE there is an instrument defect, not a desk fact.
- **D178 — `fatal:false` does not protect the open leg, and the zero-byte run is back.**
  `openInspectorByRealClick` resolves ONE locator to `[data-test-id="sidebar-toggle-panel"]` before its
  retry loop (`:1672`) and never re-checks presence, while #5014 flips that same button to
  `sidebar-dismiss` at Tier 3 (`components.ex:425`). Proven in a real browser against a forcing fixture:
  the second iteration blocks for the full auto-wait and throws a **raw Playwright TimeoutError at
  11093ms, `instanceof MeasureError === false`** — and throws identically at 11072ms **with
  `fatal:false`**, the exact mode `runRoundTrip` uses (`:1930`) so an unreachable toggle costs only that
  pass. `main()` has a `finally` but no `catch` (`:2613`) and `writeRunArtifact` runs only after it exits
  normally (`:2676`), so the throw writes **zero bytes** — D138's defect reintroduced through a different
  door than the one wave 10 closed. The fix is proven: a non-blocking presence re-check per iteration
  yields the function's own named skip, `MeasureError` at 1090ms. The dismiss leg is robust not because
  Locators are lazy but because `DISMISS_CONTROLS` is a **priority list of both spellings** resolved by
  `firstPresent()`; the open leg gets the same shape.
- **D179 — Browser Back leaves the desk; the affordance is KEPT and the reason is recorded in code.**
  `sidebar_toggle_panel/1` is a pure assign (`handlers/paper.ex:117-126`) — proven by mutation, not
  reading: injecting a `push_patch` there cascaded 15/26 failures, and removing `push_patch` from the
  sibling `expand_pane/2` reds exactly the two control assertions with `expected … to patch, but got
  none`. So a destination shipping an arrow, a document name and a crumb while Back silently exits the
  Studio is a real lie of the chevron's own family. Option (a), a URL-borne sidebar param, must be
  designed against `?desk=` preservation (`paths.ex:86-92`) and against `expand-pane`'s own push_patch
  (`scope.ex:170-178`), which knows nothing about `sidebar_user_opened`; option (c) unwinds #5014.
  **Ruled (b): keep the affordance, record in code why the DOM is a full-screen destination while the
  click stays non-navigational, and lock it with a no-patch test.** The lock pins pane ids AND
  `editor open: false` AND `sidebar_user_opened == false` — pinning pane ids alone stays green if the
  reset chain is refactored away.
- **D180 — spd-b47's live outcome is a THIRD one neither option named, and the strip's label is
  truthful.** Measured on a live process: at `standard` with the ladder engaged the surviving strip is
  `{1, "Papers"}`, and clicking it yields `panes ["pane-structure","pane-papers"], editor open: false,
  strips []` — it closes the whole document. Not a dead control, not a squeezed inspector. The task's
  stated mechanism is also false: `expand-pane` DOES reach `sidebar_user_opened`, **transitively**, via
  `rebuild_panes → clear_paper_view → sidebar_assigns(nil)`. `pane idx N → Enum.take(nav_path, N)` is
  coherent because pane 0 IS the root pane and each ordinary segment contributes exactly one pane, so the
  label names its destination in every topology — **there is no affordance lie**. But the ladder tier has
  exactly TWO affordances and the crumb trail is not one of them: `desk_crumbs/1` is gated
  `in ["narrow","phone"]`, so `standard` is the one bucket that hides the whole rail **without** offering
  the trail. That is a live gap against "cheap and plural" and it ships with the keyboard exit.
- **D181 — An ungated Escape binding ships SILENTLY GREEN, so its own test is mandatory.** Mutating the
  tier gate to bare `true` reds **exactly one test — the probe's own**; with the probe removed and the
  mutation still applied the suite is `167 tests, 0 failures`, while the mutation demonstrably lands the
  binding on `class="bp-doc-sidebar is-collapsed"` with no `data-user-opened` (Escape becomes a global
  open-the-inspector key at every bucket, including wide). Two corollaries bought the same way:
  `render_keydown` does **not** enforce `phx-key` — with `phx-key="Banana"` the behavioural Escape test
  stayed GREEN, so the key is pinnable **only** by asserting the rendered attribute literally; and a
  shared `defp` must live at module bottom, because placing it under an `attr(...)` block raises
  `CompileError … cannot declare attributes for function inspector_destination?/2`. Corrections to numbers
  now in circulation: negating the tier predicate reds **2** tests, not 3, and `phx-window-keydown` occurs
  **17** times in `api/lib`, not 12/14/15/16 — cite none of the four.

## Roadmap — wave 12 (PAY THE EXEMPTION'S PRICE, CLOSE THE BRACKET)

Per D19 every model column reads `opus`. Round 1 is file-disjoint by D160/D16 — `root.html.heex` has
exactly one owner, and this round it is **E**, because the Studio's `phx-hook`s are defined INLINE in
that file (`Hooks.WidthBucket`, `Hooks.EditorFocus`, ~line 6027-6280), so the guarded window listener
D173 mandates cannot live anywhere else. That single fact sequences the wave: **S** carries D175's
suppression rule into the same file and is therefore round 2, behind E. Rounds 2 and 3 are the lead's
post-merge dispatch.

| # | Slice | Task | Round | After | Model | Size |
|---|---|---|---|---|---|---|
| E | Escape at bubble phase with the `activeElement` veto, focus in and focus RETURN, and the crumb trail reaches `standard` (D173/D180/D181) | `tier3-keyboard-exit-and-focus-return` | 1 | — | opus | large |
| N | Navigational truth — the strip closes the document, Back leaves the desk, both ruled in code and locked (D179/D180) | `spd-b47-ladder-backstrip-expand-collision` | 1 | — | opus | medium |
| I | The instrument's three preconditions — the open leg's stale locator, the collapsed third state, the 1024 false-failure rows (D177/D178) | `spd-instrument-open-leg-stale-locator` | 1 | — | opus | medium |
| P | The forced-container threshold control becomes runnable code, offline, and it can FAIL (D176) | `scrim-threshold-forced-container-control` | 1 | — | opus | medium |
| T | The icon vocabulary tripwire and the warning card that paints a document (D46's class, generalized) | `icons-unknown-name-tripwire` | 1 | — | opus | small |
| S | The secondary-pane breach — `secondary_doc` clears on navigation AND `standard` gets its rule (D175) | `spd-standard-bucket-scrim-unruled` | 2 | E | opus | medium |
| R | The bracketed deployed run — round-trip fidelity, the derived destination, the bucket precondition (D150/D171/D176/D177) | `inspector-shape-bracketed-deployed-run` | 3 | E, I, P | opus | medium |

## Wave log — wave 12

### Wave 2026-07-20 — Wave 12 (PAY THE EXEMPTION'S PRICE), Review. Grade A−.

**Round 1's five file-disjoint slices all built green and cohere.** The wave provisions the
payment D127's exemption owes: the keyboard exit and its focus round trip (E), the two
navigational lies ruled and locked (N), the instrument's three terminal-run preconditions
fixed (I), the forced-container scrim control made runnable and able to FAIL (P), and the icon
vocabulary tripwire that also fixed a 14-week-live bug (T). The live *consummation* — the
bracketed deployed run R — is correctly deferred to round 3; this wave makes it possible.

**What landed, per slice (final branch = the `-r` carrier).**
- **E — `tier3-keyboard-exit-and-focus-return`** (`…escape-at-bubble-phase-focus-in-and-focu-0-r`,
  carries the charter). `Hooks.InspectorEscape` inline in `root.html.heex`: a window BUBBLE-phase
  Escape listener with an `activeElement` veto scoped to `.bp-paper-format`, rendered only at Tier 3
  via a `:if={@destination}` hook element carrying the `data-escape-*` contract. Capture is refused
  in code with the measured reason (it eats the nested-menu grammar). Focus IN via
  `phx-mounted={JS.focus(to: #bp-doc-sidebar)}` onto a `tabindex=-1` landmark; focus RETURN via
  `dismiss_or_toggle/2` = `JS.push |> JS.focus(to: #bp-doc-sidebar-toggle)` on both the back button
  and the document crumb. ZERO new `caps.ex` entries (reuses `sidebar-toggle-panel`), no new
  `handle_event` head. The duplicated tier predicate collapsed to ONE shared `defp
  inspector_destination?/2` at module bottom, now read by four callers. Crumb trail widened to reach
  `standard` when the ladder is engaged — closing exactly the gap N's D180 comment names. The D181
  binding test asserts the RENDERED attributes literally (render_keydown does not enforce phx-key)
  in an inversion-sensitive quadruple. Review re-ran the two non-Elixir gates on the final branch:
  `studio-literal-check` PASS (367 files) and `design/check.mjs` PASS (18 surfaces, Part H 270
  contrast checks, ratchet undisturbed by the added JS).
- **N — `spd-b47-ladder-backstrip-expand-collision`** (`…navigational-truth-the-strip-closes-the--1-r`).
  Ships NO behaviour: two rulings in code (D180 the strip is a DOCUMENT-CLOSE reached transitively
  through `clear_paper_view/1`; D179 the Tier-3 dismiss is a pure assign while Back leaves the desk)
  and a new lock file with a real `refute_patch/2` made falsifiable by TWO contrast controls that
  `assert_patch`. The strip lock pins pane ids AND editor-open false AND `sidebar_user_opened ==
  false` off `:sys.get_state`. Honest 2-segment-path scope caveat, residue filed.
- **I — `spd-instrument-open-leg-stale-locator`** (`…the-instrument-s-three-preconditions-the-2-r`).
  Review re-ran the real-chromium forcing repro: **6/6 PASS** (before = raw TimeoutError@10s, after =
  named MeasureError@1s; rename-followed to reached:true; fatal:false returns a named skip). `node
  --check` green. `is_destination` now DERIVED from the server `[data-inspector-destination]` marker
  (54 rows / 18 destination, verified by direct export call); the 1024 false-failure rows retired via
  a `WIDTH_BANDS` table mirroring the pre-paint EDGES.
- **P — `scrim-threshold-forced-container-control`** (`…the-forced-container-threshold-control-b-3-r`).
  Review re-ran the gate: `node --check` + `--self-test` **green**, with the exact discriminating cell
  (`standard`+user_opened: `none`@861 / `""`@860), the false-green trap REJECTED, and the
  generator-deletion self-test proving the control CAN fail. Satisfies D176/D153.
- **T — `icons-unknown-name-tripwire`** (`…the-icon-vocabulary-tripwire-and-the-war-4-r`). Added the
  missing Lucide `alert-triangle` (correct `m21.73 18-8-14` path), fixing `chat_readiness_card/1`
  which had painted the plain document glyph on every AI-not-ready warning. A `lib/`-wide balanced-brace
  tripwire over `known_icon?/1` with real non-vacuity guards (>30 sites, >3 files, >10 names). Unknown
  policy is compile-time resolved: raise in `:test`, `Logger.warning` + fallback in `:dev`/`:prod`
  (`:dev` grouped with `:prod` because `tab_icon/1` passes tenant strings verbatim).

**Cross-slice coherence.** E and N cohere precisely: N's D180 comment documents that `standard`
hides the rail without offering the trail, and E closes exactly that gap by widening
`crumb_trail_bucket?/3` to the ladder tier. Shared `inspector_destination?/2` predicate — no
duplicated helpers. I and P are file-disjoint from each other and from the Elixir slices; R (round 3)
consumes both. No conflicting UI states.

**Review made no code changes — all five slices were already correct.** The only mutation this phase
made was the charter restore above and the epic heartbeat.

**The gate-run honesty.** Round-1's JS slices (I, P) were re-run to green in the review worktree
against real Chromium. E's two non-Elixir gates were re-run green. The Elixir `mix test` portions of
E/N/T were NOT independently re-run: this worktree has no `deps/`, and borrowing `_build` across
worktrees is structurally broken (D61/elixir-build-borrow-broken); a fresh `deps.get`+compile risks
OOM on this shared host. Those three rest on the builders' green scoped runs, full adversarial static
review, and CI's `elixir` workflow (`Test (Elixir 1.18.1 / OTP 27.0)`) as the merge backstop.

**Ledger audited HONEST — no lies to fix.** All five built tasks: `lifecycle: in_progress`, parent
`inspector-dismissal-and-return-grammar`, `wave_paper` linked, every non-merge criterion stamped with
substantial evidence (195–1162 bytes) as they worked, the merge-gated final criterion correctly
`met: false` / empty for the lead. Deferred S (round 2) and R (round 3) sit `open` and unclaimed per
the sequenced-rounds law. Five residue tasks filed, published and parented mid-run
(`b47-strip-behaviour-unmeasured-beyond-two-panes`, `scrim-control-uncied-and-fixture-drift`,
`icons-tab-icon-tenant-guard`, `spd-instrument-nondeterminism-characterised`, and the two above). No
task outside this wave was touched.

**What the lead must know before merging.**
1. **E's `-r` branch carries the charter** (D172–D181 + this log). If E is dropped, the decisions the
   other four slices cite must move to another merged branch, or `origin/main` again resolves them to
   nothing. Prefer merging E; the five round-1 branches are otherwise file-disjoint and order-free.
2. **Close the merge-gated criterion** on each task: E index **12**, N **9**, I **9**, P **8**, T **6**.
3. **T changes `icon/1` to RAISE on unknown names in `:test` globally.** The scoped gate (544/0) is
   green; watch the FULL `elixir` suite on CI for any other test rendering an unmapped icon name.
4. **The live payment is round 3.** R (`inspector-shape-bracketed-deployed-run`) is the artefact that
   converts D127's exemption from provisioned to PAID by measurement; it needs E+I+P merged AND the box
   deployed, then folds `spd-instrument-open-leg-stale-locator` (already built as I) and quotes P's
   forced-container control as D153's positive.
5. **Nothing this wave ran against the deployed build** — E's Escape behaviour (capture-vs-bubble
   resolution, the veto on a real focused input, focus-return after inert's ~38ms async blur) is proven
   only at the server/rendered-wiring level; the browser proof is R's, by name.

**Next wave.** Merge round 1 (E first for the charter, then N/I/P/T in any order; `.ex`/`.heex` wait
for the `elixir` gate, Format is advisory D23). Then dispatch **S** (`spd-standard-bucket-scrim-unruled`,
round 2) the moment E merges — it carries D175's suppression rule into `root.html.heex`, which E owns
this round. Then, after E+I+P merge AND guerrilla serves the merge SHA (D47/D63), dispatch **R**
(round 3) — the deployed run that finally pays the exemption. Grade **A−**: five clean, honest,
adversarially-tested slices with two real bugs fixed and no bloat; docked for the 6th-time
charter-to-local-main defect that Review again had to rescue, and because the wish's verb ("pay") is
provisioned by this wave but consummated only by the deferred R.

Paper: `spd-inspector-exemption-paid-wave-12-2026-07-20`.

## Wave-13 amendment (THE ROUND TRIP RAN, 2026-07-21) — D182–D189

> Ground truth for every decision below: guerrilla serves `bc64d869a3a82beb1b39824196f60236b2082dbc`
> on slot **blue**, ssh-read PRE and POST every run and unchanged throughout — identical to
> `origin/main`. Wave 12's E (#5086), N (#5087) and I (#5088) are merged AND deployed. The charter
> is NOT stranded this time: D172–D181 are on `origin/main` with zero diff, and the D68 disease did
> not recur at the charter layer. It recurred one layer up instead: this wave's Paper
> (`spd-round-trip-fidelity-wave-2026-07-21`) was found carrying **49 blocks of the Cloud GUI Remake
> round-11 wave**, cross-written by a concurrent session. That content has its own home
> (`cloud-gui-remake-wave-2026-07-21-seal`, 61 blocks, a superset), so the stray body was replaced
> rather than rescued. **A shared ledger is a shared surface: a wave Paper id is not private.**

- **D182 — ROUND-TRIP FIDELITY HOLDS ON THE DEPLOYED BUILD. D161(i) is PAID, by measurement.**
  `default → open → dismiss`, on the SAME page instance with no reload at any point, returns the
  reading column **bit-identical at 27 of 27 cells** — 9 widths (1440, 1280, 1024, 900, 800, 764,
  700, 640, 500) × 3 faces — compared strictly (`!==`, no tolerance) over the six `ROUND_TRIP_FIELDS`
  (`content_px`, `content_ch`, `px_per_ch`, `visible_content_px`, `visible_ch`, `gutter_px`). Three
  independent sweeps (rt2, rt3, rt4) each report `cells 27 / identical_cells 27 /
  returns_bit_identical true`; the non-identical `(viewport, face, field, before, after)` list D161
  demands is **EMPTY in every run that ran**. Determinism of the SAME build: **0** round-trip cell
  diffs rt2-vs-rt3 and rt2-vs-rt4, **0** matrix field diffs across all four runs, identical click
  counts. Nothing drifts. This is the epic's oldest open thread, unmeasured since D127 was written,
  and it is now closed in the affirmative. The 71-commit-behind 2026-07-20 baselines were NOT used
  as comparands (D183's sibling ruling stands): determinism is run-1 vs run-2 of the SAME build.
- **D183 — `round_trip.dismiss_control` is a HALF-TRUTH and may never be quoted; the per-width table
  is the citable form. D161(ii) is MET.** The run-level scalar is set from `widths[0]` alone
  (`studio-desk-measure.mjs:2183`), so it reads `[data-test-id="sidebar-toggle-panel"]` /
  "toggle re-click — the only dismissal deployed today". That is false about two-thirds of the sweep.
  The deployed grammar is **SPLIT**: the toggle re-click at 1440/1280/1024, and the purpose-built
  `[data-test-id="sidebar-dismiss"]` at **all six destination widths** (900, 800, 764, 700, 640,
  500). Every destination row — the only rows where the exit matters — has a real dismiss affordance.
  With #5086's Escape and the visible control, the exit is cheap, plural and visible before it is
  looked for: **(ii) is MET.** A bracket row quoting the scalar would understate the very condition
  it is reporting on; that substitution is banned by name.
- **D184 — THE EXIT CODE CANNOT GATE THE ROUND TRIP.** A failing open leg `return`s (not `continue`s)
  out of `runRoundTrip` (`:2124-2136`), so one flaky width costs **all 27 cells, never a partial** —
  and the skip is a returned value, not a throw, so `main()` completes, `writeRunArtifact` runs, and
  the process **exits 0**. The only `process.exit(1)` is the top-level `.catch` (`:3505-3511`).
  A gate reading `$?` certifies a skipped round trip as a pass. **Gate on
  `round_trip.ran === true && returns_bit_identical === true`**, and the artefact that gets COMMITTED
  must be one where `ran` is true. Observed once in four runs: three real clicks at 1440 never
  produced `[data-user-opened]` (the wide sidebar sat at `width_px: 41` — click 1 collapsed a 300px
  default, clicks 2-3 were no-ops). D138 already records this failure and PERMITS bounded retries on
  it; that permission is the recipe. **No flake rate is recorded here** — four runs is not a rate
  study, and D138's "observed 1 in 3" is a sibling observation, not a measurement. Note the failure
  is a DIFFERENT one from D178's rename case (the control is present and clicked; the desk simply
  does not re-open), so `open-leg-repro.mjs` should not be assumed to reproduce it.
- **D185 — D171's bucket precondition DOES NOT EXIST IN CODE, and the RAW band is the only sound
  form.** `width_bucket_stamped` is stamped on every row and printed, but **no line anywhere compares
  it to an expected band** — the single warning that reads it (`:2677`) is about `inspector.position`,
  not bucket agreement. The precondition is not weakly built; it is absent, and R's criterion 4
  cannot be honestly stamped off a structural argument. **Ship the assertion, in the RAW
  `bandNameFor(width)` form.** A held-bucket-aware mirror would recompute what the browser computed,
  from the same inputs, by the same algorithm, and agree BY CONSTRUCTION — including in the precise
  case D171 exists to catch: a sweep arriving at 1280 from below stamps `standard`, and the mirror,
  fed the same held bucket, also predicts `standard` and certifies a row that tested the wrong tier.
  It is a tautology wearing a guard's uniform. Raw disagreement with the stamp **is** the signal:
  ascending the nine widths diverges at exactly 640, 1024 and 1280; over `w = 200..1600 × 4` held
  buckets, narrowing-or-equal (`raw <= cur`) diverges **nowhere**. The structural guarantee is
  therefore real — and `WIDTHS[0]`-dependent with nothing guarding the dependency: widening
  500→1440 without reload lands `wide` (agrees), but 500→**1280** would stamp `standard` while the
  raw band is `wide`. A ruling protects nothing against that edit; an assertion catches it on the
  first run. **Report, never `die()`** — R's criterion 4 imposes a REPORTING duty ("reported as such,
  not silently measured"), and a fatal mid-sweep abort discards every collected row and writes zero
  bytes, which D138 rules an INSTRUMENT FAILURE.
- **D186 — The 1024 `position: static` warnings are a STALE EXPECTATION — neither drift nor flake.**
  D108 measured `absolute` at that cell **before the Tier-2 ladder shipped**. `display_state/5`
  (`pane_builder.ex:913`, landed in `4074d1986` / #4922 — `git merge-base --is-ancestor` confirms it
  is inside `65541e2d4..bc64d869a` and not before it) takes `visible_pane_widths_px` from `[44, 260]`
  to `[44]`, so `panel` goes 720 → **980**, past the `@container panel (max-width: 860px)`
  generator's threshold, and the inspector legitimately **docks in flow**. The reading column at that
  cell went from 378.958px (37.90ch) to **600.000px (60.00ch)**; the ladder commit's message
  pre-registered every one of those figures and the deployed build returns them to the digit
  (60.00ch native MEET / 54.31ch forced Georgia FAIL — D149's inherited default shortfall, not a
  ladder cost / 65.42ch Source Serif 4 MEET). The identical 6-warning set fired in **4 of 4** runs:
  zero variance, so this is not the ~80% non-determinism. It is a single-cell change — 900 and below
  still read `absolute`, and D108 still holds there — and that scoping is itself the confirmation
  that the ladder moved precisely the cell it claimed. **The `overlayAsserted` gate must NARROW to
  `standard AND panel <= 860`, not be silenced**: an unexplained permanent warning teaches the next
  reader to ignore a live tripwire, and deleting it loses the signal that would catch the ladder
  being reverted. The bracket carries these three rows as the ladder's **confirming** rows.
- **D187 — D175's compound state is REACHABLE through real affordances, and it PAINTS. D96 is
  REFUTED.** Executed end to end on the deployed build, no DOM injection and no fixture: open a Tasks
  document → its header carries `[data-test-id="open-secondary-picker"]` (alive, **99 candidates
  offered**, spd-w5's fix works) → the root pane is now a 44px collapsed strip, so click the strip to
  expand it (spd-s6's own affordance) → Papers → a paper. `Scope.select/2` is `push_patch`, so the
  LiveView never remounts and **`secondary_doc` survives the navigation**. At `standard` / innerWidth
  1024 with the inspector user-opened: `.editor-panel` measures **620** — `1024 − 44 − 360`, D175's
  arithmetic EXACTLY, not approximately — `::after` content `""`, background `rgba(0, 0, 0, 0.55)`,
  position absolute, z-index 4. It is not merely computed: screenshotting the reading column, then
  suppressing only the generator and re-shooting the identical 620×500 clip, mean luminance over
  310,000 pixels moves **240.493 → 175.104 (Δ 65.389 darker)**. That is the exact D127 defect, on the
  bucket this wave rules, reached through an orthogonal feature. **D96's "even with break 2 fixed,
  D76's pressure case needs a cross-surface navigation no affordance offers" is refuted** — the
  affordance exists (collapsed-strip `expand-pane` + nav `pane-item`, both real UI, both patch-level).
  You cannot open a secondary pane FROM a paper, but you do not need to: you open it on a task and
  carry it in. **A premise correction rides with it:** the plain 1024/standard cell is NOT "a clean
  MEET by arithmetic, no guard applies". With a secondary pane open and the inspector at its server
  default the panel is **560**, and the scrim is suppressed ONLY by b29's `:not([data-user-opened])`
  clause — a guard whose sole discriminator is the attribute the user is one click away from setting.
  `studio-desk-measure.mjs` has **no driver path** to this state (it drills root → Papers → paper and
  never opens a secondary pane), so **the bracket must declare it OUT-OF-MATRIX in words**. Omitting
  it in silence would let the artefact read as "no scrim renders anywhere post-ladder", which is now
  demonstrably false. Coverage remains zero: `grep -rl secondary_doc api/test/` exits 1.
- **D188 — The terminal run fires WITHOUT `--positive-control`, and `zero_cause` may not read
  DESK-FIXED (proven).** D176's strike is no longer prose: it is EXECUTED. Taking P's fixture,
  deleting the fenced 860px generator entirely (657 bytes, 5715 → 5058, no second generator
  surviving), then injecting the LITERAL `POSITIVE_CONTROL_RULE` text from
  `studio-desk-measure.mjs:2221-2224`, `::after` content flips `none` → `""` at bucket=wide /
  panel=1136 — **on a fixture with no threshold to certify** — reproduced byte-identically on two
  independently created worktrees. The mechanism is now understood, not just observed: **no real
  suppressor uses `!important`**, so an unconditional `!important` `::after` wins over every one of
  them regardless of specificity, with or without the generator. `zero_cause` is chosen only by
  `run.positive_control` and host presence, so passing the flag would print DESK-FIXED (proven) for a
  proof about a different, weaker claim (the hit-test plumbing works). The honest reading on this
  build is **DESK-FIXED (unproven)** — `.editor-with-preview` present in 54/54 hit-tested rows, the
  scrim rendering in **0** of them — with P's forced-container control quoted as a SIBLING section,
  never as a desk row (D176). Any permanent assertion of this strike must READ `measure.mjs`'s source
  text at runtime, never hand-copy the rule literal: a copy is the un-tied-snapshot failure already
  filed against P's fixture, and it would silently certify a stale rule.
- **D189 — The prediction is a COMMITTED FILE, split from its checker, and it may never quote a
  trusted scalar.** No committed prediction file has ever existed in this repo (`git ls-files |
  grep -i predict` is empty); every prior registration was prose in a task brief (D138) or a charter
  Decision (D150, D161). The format, invented and mutation-proven here: rows keyed by the composite
  **`viewport_px|inspector_state|face`** — never an index, never a summary scalar (rows key on
  `viewport_px`, NOT `width`; tooling written against `width` silently indexes nothing). Every
  predicted field carries a **`basis`** — `arithmetic` (a miss is real font drift), `recomputed`,
  `ruling`, `prior-observation` (a miss is same-build non-determinism) — because without it every
  failure reads identically and the reader cannot tell drift from flake, which is exactly the
  ambiguity this epic keeps re-litigating. The checker **RECOMPUTES and never reads a row's own
  verdict**: flipping one row's `content_meets_55ch` while leaving its raw numbers untouched goes RED
  with `SELF_INCONSISTENT`, the precise class `studio-desk-compare.mjs:216-218` copies verbatim
  without recompute. It refuses any prediction quoting `applies_in_rows`, `passed_in_rows` or
  `vacuous` — and that is not theoretical: on the skipped run the guard reads `vacuous: true` with
  `applies_in_rows: 0`, so `passed_in_rows: 0` is a pass proving nothing. **Three exit states, not
  two** (green / mismatch / **unevaluated**), so "the run produced no evidence" can never be recorded
  as either a pass or a wrong prediction. Use `probe_px_per_ch`, never `in_floor_px_per_ch` (unstable
  per row, carries empty-string values). The prediction JSON is **frozen at registration**; the
  checker `.mjs` stays fixable — it had a real misattribution bug within minutes of being written,
  and freezing them together would force a choice between shipping a known-buggy checker and breaking
  the freeze. The per-face figures are now OBSERVED FACT, not assumption, read off the round trip's
  own before/after at 18px: **native 10.0000 → 55ch = 550.00px; georgia 11.0469 → 607.58px;
  source-serif-4 9.1719 → 504.45px.** No cross-face division anywhere.

## Roadmap — wave 13 (THE ROUND TRIP RAN)

Per D19 every model column reads `opus` (Fable 5 is spend-limited). Round 1 is file-disjoint: P's
rescue touches two pure-new files, the instrument slice owns `studio-desk-measure.mjs` alone, and the
two `scripts/measurements/` slices add new files only. `root.html.heex` has **no owner this wave** —
nothing here edits it, so D16 is satisfied trivially.

| # | slice | task | round | files |
|---|---|---|---|---|
| A | Rescue P — land the forced-container control | `scrim-threshold-forced-container-control` | 1 | `scripts/studio-scrim-threshold-control.mjs`, `scripts/fixtures/` |
| B | The instrument's bucket precondition + two honesty fixes | `spd-w13-instrument-bucket-precondition` | 1 | `scripts/studio-desk-measure.mjs` |
| C | Register the prediction as a committed, frozen file | `spd-w13-prediction-registered` | 1 | `scripts/measurements/` (2 new files) |
| D | Commit the D187 compound-state repro | `spd-w13-d175-compound-repro` | 1 | `scripts/measurements/` (1 new file) |
| E | Fire the terminal bracketed run; commit the artefact | `inspector-shape-bracketed-deployed-run` | **2** | `scripts/measurements/` (artefact + bracket) |

**E is round 2 by law, not by caution.** It must run the GATED instrument (B) against a REGISTERED
prediction (C) — a prediction committed after the run it governs is worthless — and it quotes P's
control (A) as D153's positive. Dispatching it beside its unmerged dependencies would burn a builder
to produce a BLOCKED report. The lead dispatches E after A+B+C merge and guerrilla serves the merge
SHA (D47/D63).

**What the lead must know before merging.**
1. **`pr-task-gate` will BLOCK slice A on ledger state, not on code.** `scripts/pr-task-gate.sh`
   accepts only `in_progress` (with `claim.worker`) or `done` (with `claim.closed_by`); the task is
   `open` with a claim that lapsed 2026-07-20T21:23Z, so a structurally correct PR carrying the
   correct `Task:` line fails anyway. Every slice brief carries the re-claim instruction first.
2. **`elixir.yml` fires on EVERY PR** — it has no `paths:` filter at all. These four slices change no
   `.ex`/`.heex`, so it should pass trivially, but it is not skipped and a builder expecting silence
   will be surprised. `main` has no branch protection and no rulesets; enforcement is doctrine-level.
3. **The round trip is already PROVEN (D182).** E's job is to commit the artefact from the final
   instrument against the registered prediction — it is a formalisation of a settled fact, not a
   discovery. If E's open leg draws the 1-in-4 flake, retry per D138; do not report `ran:false` as
   a finding.
4. **`measurement-baselines-are-61-commits-stale` is DEFERRED, not closed.** Its criterion 3 requires
   this wave's own post-ladder artefact as a precondition, and its criterion 2 edits
   `pane_builder.ex`, outside this wave's file fence. It becomes actionable the moment E lands. The
   distance is now **71** commits and grows daily — compute it fresh, never quote a fixed number.

Paper: `spd-round-trip-fidelity-wave-2026-07-21`.

## Wave log — wave 13

### Wave 2026-07-21 — Wave 13 (THE ROUND TRIP RAN), Review. Grade A−.

**The wish is PAID, and the payment survived being attacked.** D127(a) — round-trip fidelity, the
epic's oldest unmeasured condition — is now measured on the deployed build and returns the reading
column **bit-identical at 27 of 27 cells**, re-confirmed by Review in three further full runs against
`bc64d869a3a82beb1b39824196f60236b2082dbc` / slot blue, bracketed PRE and POST. The wave's real
achievement is not the green: it is that the green is now **defensible**, because the instrument
asserts its own preconditions and the prediction that governs it was frozen before the run.

**What landed, per slice (final branch = the `-r` carrier).**
- **B — `spd-w13-instrument-bucket-precondition`**
  (`…the-instrument-asserts-its-own-bucket-pr-1-r`, **carries the charter**). D171/D185's bucket
  precondition, which did not exist in code, now checks **72 readings per run** (54 sweep + 18
  round-trip legs) where the count was previously 0 — in the RAW `bandNameFor()` form D185 requires,
  never a held-bucket mirror that would agree by construction. Reports, never `die()`s. D183's
  dismiss half-truth is gone (per-width table + rollup replace the `widths[0]` scalar); D186's
  `overlayAsserted` is narrowed to `standard AND panel <= 860` rather than silenced, warnings 6 → 3
  with the survivors pre-existing and already filed.
- **C — `spd-w13-prediction-registered`** (`…register-the-terminal-run-s-prediction-a-2-r`). The
  repo's first committed prediction file, frozen, split from a fixable checker that RECOMPUTES every
  verdict and never trusts a row's own — with four exit states demonstrated, `SELF_INCONSISTENT`
  among them.
- **D — `spd-w13-d175-compound-repro`** (`…commit-the-d175-compound-state-repro-the-3-r`). D187's
  compound-state scrim made permanently re-runnable through real affordances only. Re-run live by
  Review: 9/9 PASS, 620px geometry exact, `--simulate-fixed-build` goes RED on exactly the three
  scrim-dependent checks.
- **A — `scrim-threshold-forced-container-control`** was NOT rebuilt: the rescue had already been
  performed by its claim holder, PR #5098 is open, rebases clean and its gate passes. It needs a
  merge decision, not a builder.

**Review fixed three things in place, two of them defects neither builder could have seen alone.**
1. **The bucket precondition did not reach the round-trip CELLS** (B). A width whose stamp disagreed
   with the raw band warned, but its three face cells still counted toward `cells`/`identical_cells`
   — so `returns_bit_identical`, the headline this wave exists to establish and the value round 2's
   gate asserts, could be computed partly over a comparison of two different TIERS. The builder found
   this and filed it rather than fixing it; it sits on the wish's own metric, so Review closed it.
   Withdrawn cells now report `identical: null`, are counted visibly, and full coverage is required
   before the claim is made. **Proven by mutation:** band edge 640 → 700 gives 64/72 preconditions,
   3 cells withdrawn at 640, and `returns_bit_identical` **false** on a 24-of-24-identical sweep that
   would previously have read 27/27 **true**.
2. **A genuine CROSS-SLICE defect** (C). C's dismiss-grammar check read the run-level
   `rt.dismiss_control` scalar and skipped itself when absent — and B **deletes that scalar**, by
   D183, by name. Merged as-is, two individually-correct slices would have produced a guard that
   CANNOT FAIL on the exact affordance condition D161(ii) turns on, silently and green. The checker
   now reads the per-width table and treats a missing grammar as a MISS; the frozen prediction is
   untouched, which is precisely the split D189 exists to permit. Proven by four mutations.
3. **A cold-reader gap** (D): L4's failure could not distinguish "the desk removed the picker" from
   "today's unpinned first task lacks one". It now names the task and says to pin `--task`.

**THE FINDING THIS WAVE PRODUCED BY ACCIDENT, AND IT MATTERS FOR ROUND 2.** Running C's checker
against a real round-trip artefact — which no builder ever had — gives **exit 1, 24 misses, all at
viewport 1280, all three faces**, with **0 self-inconsistencies and 27/27 cells returned unchanged**.
`content_px` at 1280 reads **640**, where the 2026-07-20 table recorded **596**: exactly +44px, the
collapsed-strip width, deterministic across three independent runs. This is **not** a round-trip
failure — the round trip is clean — it is the desk having genuinely moved at one width since
`65541e2d`, caught by a `prior-observation` basis doing exactly the job D189 designed it to do. The
prediction stays FROZEN: a prediction edited to match the run it governs is worthless. **Round 2 must
therefore NOT gate green on `check-prediction` exiting 0.** Gate on
`round_trip.ran === true && returns_bit_identical === true` (D184), and REPORT the 1280 misses as the
registered, correctly-labelled staleness they are.

**Ledger audited.** All three built tasks claimed, stamped as they worked, left `in_progress` with
merge-gated criteria open for the lead. A's task is honestly `in_progress` under its rescue holder.

**What the lead must know before merging.**
1. **B's `-r` branch carries the charter** (D182–D189 + this log). It was stranded on **local main**
   — the **7th** recurrence of the D135/D68 disease. If B is dropped, the decisions C and D cite
   resolve to nothing on `origin/main`.
2. **Merge B BEFORE C.** They are file-disjoint and will not conflict, but C's fix is what keeps B's
   scalar deletion from silently voiding a guard. Either order is safe on disk; B-then-C is the order
   the evidence was gathered in.
3. **A (#5098) needs a merge decision, not a builder.** Its remaining reds are content-impossible for
   a two-`.mjs` diff.
4. **Round 2 is `inspector-shape-bracketed-deployed-run`** — deferred BY DESIGN under the
   sequenced-rounds law, not a failure of this wave.

Paper: `spd-round-trip-fidelity-wave-2026-07-21`.

### Wave 14 amendments (2026-07-21, D190–D197) — HARDEN-AND-CONVERGE

Paper: `spd-inspector-shape-harden-wave-2026-07-21`. Root task: `spd-b39-user-opened-inspector-shape-successor`.

- **D190 — Wave 14 is convergence, not design.** The founding defect (user-opened inspector crushing
  the reading column) is SOLVED in shape and LIVE: wide docks in-flow (Tier-2 ladder, `display_state/5`,
  #4922), narrow is a summoned full-panel destination with dimming abolished + a Tier-3 return grammar
  (#4923/#5014/#5015), keyboard Escape+focus-in+focus-return is PAID (#5086), and round-trip fidelity
  returns the column BIT-IDENTICAL 27/27 on the deployed build (D182). The wave's job is to make that
  shape **defensible** — turn the still-unguarded behaviours into mutation-proven tests — while the two
  named seal-blockers (bracketed run, scrim FIX) stay named residue. Spine = `api/test/barkpark_web/**`
  (collision-free with the crown that owns `root.html.heex`).

- **D191 — The scrim FIX is NOT taken in-fence this wave (PIN-ONLY).** Verification proved
  `spd-standard-bucket-scrim-unruled` is mechanically claimable now — tier3-keyboard #5086 (b650154a1)
  is an ancestor of `origin/main`, no open PR touches `root.html.heex`, and cloud-gui-remake lives in
  `cloud/**` (zero `.heex`), so the "crown owns root.html.heex" framing was refuted. BUT a crown merge-
  freeze is arming and D16 gives `root.html.heex` exactly one owner per round. RULING: this wave pins
  the behavioural half via `spd-w13-secondary-doc-zero-coverage` (pure LiveView test, no `root.html.heex`
  edit); the CSS/assign FIX stays **SEAL-BLOCKER 2** residue, dispatched by the lead post-freeze as a
  round-owning root.html.heex slice. RIVAL B (make the fix the whole wave) rejected as the spine —
  strand/collision risk under the freeze; absorbed as residue instead.

- **D192 — The complete secondary_doc fix clears in BOTH `clear_paper_view/1` AND `setup_paper_view/2`.**
  paper→non-paper routes through `clear_paper_view/1` (shared.ex:779-814 `_ ->` branch); paper→paper
  routes through `setup_paper_view/2`. Neither clears `secondary_doc` on `origin/main` (confirmed) — so
  a stale secondary doc set via `select-secondary` survives navigation, shrinks the standard-bucket panel
  to 620px < the 860px scrim threshold, and the scrim paints over live prose (D175/D187). The wave-14
  test asserts the CURRENT persistence on BOTH legs (green today, `paper_doc==nil` proving the nav path
  ran = non-vacuity), so whichever leg the fix lands on, the behaviour change touches this test.

- **D193 — `spd-b41`'s remaining leg (`root.html.heex` CSS ↔ `visually_open?`) is the one true coupling
  gap; it is locked READ-ONLY.** The 2↔3 leg (`components.ex:visually_open?` ↔ `handlers/paper.ex:painted_closed?`)
  is already green and mutation-proven (paper_canvas_test.exs:1606, 129/0). The 1↔2 leg — root.html.heex:2002's
  `:not([data-width-bucket="wide"]) … :not([data-user-opened])` compound vs the negation of
  `visually_open? = panel_open && (bucket=="wide" || user_opened)` — has ZERO cross-file coverage. A new
  file-disjoint test `File.read!`s root.html.heex and asserts the painted-closed bucket set equals that
  negation, mutation-proven with a SYNTHETIC sabotaged selector string (never editing root.html.heex).
  In-fence: the test is a READER of the crown file, never a writer.

- **D194 — format-bubble stays residue, NOT a slice.** The blur/hide + Escape-swallow logic is in
  `api/assets/paper-editor/src/format-bubble.js` — a THIRD fence (npm/JS, D174-excluded), its proof bar
  is a real browser, its bundle is 5 commits stale, and it is ALREADY filed as
  `paper-editor-bundle-stale-and-escape-stoppropagation`. Do not duplicate; do not half-ship.

- **D195 — The merged-unclosed set is 14, not 7.** A BFS over spd-b39's 69-descendant subtree, filtered
  for "all criteria met except one MERGE-GATED", cross-checked by `git merge-base --is-ancestor`, found
  14 tasks merged-to-main yet lifecycle=open: the 8 already known (#4922-4925, #5014-5016, #5086) PLUS
  #5087, #5088, #5097, #5098, #5127, #5128. `spd-b39-seven-merged-children-need-the-merge-stamp` is
  itself stale ("seven"). `spd-b29f` is a same-species case (done-not-closed, criterion still met:false)
  under the OLD parent. A reconciliation task widens the sweep to 14 and re-stamps the root's 5 criteria.

- **D196 — The shortest seal move is a git push, not code.** The bracketed run's slices A (#5098) and
  B (#5127) are merged; only slice C (`spd-w13-prediction-registered`, branch
  `loop-epic/register-the-terminal-run-s-prediction-a-2-r`, tip eb39567c0) is unpushed — 2-ahead,
  merge-tree clean (0 conflicts, 2 additive files under `scripts/measurements/`), never on origin, no
  PR. Push C → merge → an OPERATOR holding `~/.ssh/barkpark_indx` fires
  `inspector-shape-bracketed-deployed-run` (readProvenance() die()s without ssh to guerrilla). That
  stamps **SEAL-BLOCKER 1**. No agent/CI can fire the run — Decide names the human.

- **D197 — "sealable" ≠ "ledger-reads-sealed".** No mechanical seal predicate exists for spd-b39 (the
  only `seal-predicate.mjs` in the repo belongs to cloud-gui-remake). The root's 5 acceptance_criteria
  all read met:false despite D182/D148-D189 — stale prose inherited from the wave-8/9 handoff, never
  re-stamped. Nothing auto-flips them when the blockers clear. Reconciliation is named LEAD work,
  distinct from and blocking any future seal claim.

**The seal path (what stands between this wave and a sealable desk).** Two out-of-fence stamps + one
ledger reconcile: (1) push+merge slice C, then the operator fires the bracketed run — SEAL-BLOCKER 1;
(2) the lead dispatches `spd-standard-bucket-scrim-unruled` as a round-owning root.html.heex slice once
the freeze lifts — SEAL-BLOCKER 2; (3) `spd-b39-seal-ledger-reconciliation` executes the 14-task
stamp-and-close sweep and re-stamps the root's 5 criteria. Cross-surface inspector (sheet/graph/media)
is EXPANSION, post-seal.

**Wave 14 slice table.**

| # | slice | task | round | builder | files |
|---|---|---|---|---|---|
| S1 | Pin secondary_doc persistence (D175 behavioural half) both nav legs | `spd-w13-secondary-doc-zero-coverage` | 1 | fable | `api/test/barkpark_web/live/studio/studio_live_secondary_doc_test.exs` (new) |
| S2 | Couple the painted-closed CSS rule to `visually_open?` (1↔2 leg) | `spd-b41-inspector-paint-rule-vs-announcement-uncoupled` | 1 | fable | `api/test/barkpark_web/studio/inspector_paint_announcement_coupling_test.exs` (new) |

Two disjoint new test files, both in-fence, both round 1, `root.html.heex` has **no writer** this wave
(S2 reads it) — D16 satisfied trivially. The scrim FIX, the bracketed run, and format-bubble are named
residue, not slices.

### Wave 15 amendments (2026-07-21, D198–D205) — KILL THE LAST REACHABLE CRUSH

Paper: `spd-standard-scrim-crush-wave-2026-07-21`. Root task: `spd-b39-user-opened-inspector-shape-successor`.
Wave 14's pins (S1/S2) never landed on `origin/main` (verified: no `secondary_doc` test anywhere, no
`inspector_paint_announcement_coupling_test.exs`) — so this wave WRITES the fix, it does not flip a pin.
NOTE for the lead: the D190–D197 amendment itself was stranded on a feature branch (never merged to
`origin/main`, whose charter stopped at D189); this wave-15 commit carries D190–D205 forward together.

- **D198 — Wave 15 TAKES the scrim FIX (reverses D191's PIN-ONLY posture).** Lead-verified at dispatch:
  ZERO of 24 open PRs touch `root.html.heex` or `shared/paper.ex` (widened to `shared.ex` — still zero),
  and the D16 round-1 owner tier3-keyboard `#5086` (b650154a1) has released to `origin/main` — so
  single-ownership of `root.html.heex` is UNCONTENDED this wave and D191's "crown owns the file" framing
  no longer holds. The PDS-crown merge-freeze (wave 20) blocks MERGING, never BUILDING. RIVAL A wins:
  pay the LIVE breach this wave with two file-disjoint mutation-proven slices; push normally, expect
  merge to lag behind the crown. RIVAL B (shape rebuild) rejected — the docking arithmetic already loses
  (a 300px dock at v=1024 yields 34ch, worse than the overlay) and D190 already ruled this epic
  convergence, not design. RIVAL C (test-only, wave-14 redux) rejected — the wish says FIX, and banking
  tests around a known-broken behaviour adds no user value while the breach stays live.

- **D199 — FIX 1 is IDENTITY-GATED, not unconditional (corrects D192's literal seam).** Verification
  (V1) PROVED by mutation that bolting `secondary_doc: nil` onto `clear_paper_view/1` +
  `setup_paper_view/2` REGRESSES split-view-compare: `clear_paper_view/1` is not only a nav leg — it
  fires on same-document Save/reload through `rebuild_panes`'s `_ ->` branch (`Fields.save` on
  "Saved", `reload-remote-doc`), so an unconditional clear WIPES a live `.bp-secondary-pane` on the
  next save (probe: `present? false` after a same-doc reload with the naive fix; `true` on clean code).
  RULING: clear the `secondary_doc`/`secondary_schema`/`secondary_type` trio ONLY on an ACTUAL
  primary-document identity change — `not same_editor_doc?(old, new)` (the predicate already exists at
  `shared.ex:934`, already consumed at `shared.ex:741`/`:758`). This kills the compound scrim on real
  navigation while leaving same-doc saves/reloads (and the same-PAPER slug-rename re-render of
  `setup_paper_view/2`) untouched. The protective test MUST assert BOTH: nav-to-a-different-doc clears
  `secondary_doc` (with `paper_doc` non-nil proving the nav path ran = non-vacuity) AND a same-document
  Save/reload with a split-view open PRESERVES it.

- **D200 — FIX 2 REPAIRS the merged positive control, not only adds a guard.**
  `inspector_summoned_destination_test.exs:344-367` hard-codes today's bug (`winning_content(standard,
  user_opened:true, pane:860) == ""`) as its "positive control" — written before D175 found the compound
  breach. Verification (V2) proved that adding ONLY the standard suppressor flips BOTH of that test's
  assertions (`860 → "none"`, and `861 → "none"` too, because the suppressor sits OUTSIDE the 860px
  `@container` and is therefore pane-unbounded). So FIX 2 = one CSS suppressor
  (`html[data-width-bucket="standard"] .editor-with-preview:has(.bp-doc-sidebar.is-open[data-user-opened])::after
  { content: none; }`, mirroring the narrow/phone sibling at `root.html.heex:2141-2142`) + two NET-NEW
  mutation-proven guards (`standard/620 == "none"` with a non-vacuity precondition, plus a
  deletion-mutation control that reds when the suppressor is regex-removed from the source string) + a
  REQUIRED repair of the positive control at BOTH assertions. `task-c967eebb8a51715f` (positive-control
  repair) is FOLDED into S2 (same test file → D16 same-file collision), not built independently.

- **D201 — Task reuse, ZERO mint for the fix work.** S1 = `spd-w13-secondary-doc-zero-coverage` (direct
  child of spd-b39; EXPANDED from test-only to identity-gated behavioural clear + LiveView test). S2 =
  `spd-standard-bucket-scrim-unruled` (NARROWED to the FIX-2 CSS+test half; re-parented from the
  grandchild slot to spd-b39 direct). `task-c967eebb8a51715f` patched "do not claim — folded into S2."
  The two slices are file-disjoint (S1: `shared.ex`/`shared/paper.ex` + `studio_live_secondary_doc_test.exs`;
  S2: `root.html.heex` + `inspector_summoned_destination_test.exs`), both round 1, parallel.

- **D202 — The arithmetic absorbs the sharpest attack on RIVAL A.** CLEAN standard (no `secondary_doc`)
  NEVER crosses 860 within 1024-1279: panel = v − 44, crossing at v ≤ 904, entirely inside NARROW (floor
  640, ceiling 1023). So FIX 1 alone removes the ONLY reachable standard scrim (the COMPOUND state,
  panel = v − 44 − 360 = 620 at v=1024); FIX 2 is genuine defense-in-depth, its guard modelling the 620px
  compound width. The survey's 900/800/764/700 widths are NARROW, not standard, and moot — narrow/phone
  abolish dimming unconditionally via the `inset:0` destination-cover rule (`root.html.heex:2120`), never
  reaching the `@container(panel≤860)` path. Abolishing prose-dimming at standard applies the SETTLED
  D127 invariant, not exempting a mode after an unfavourable table — it dodges the D170-ordering trap.

- **D203 — Ledger reconcile is 15 rows, not 14.** Verification (V4/V6) confirmed all 14 of D195's
  merged-unclosed tasks (`#4922-4925, #5014-5016, #5086-5088, #5097-5098, #5127-5128`) are MERGED and
  still lifecycle=open with exactly one unmet MERGE-GATED criterion each; PLUS
  `spd-b29f-inspector-aria-lie-in-painted-closed` is a 15th same-species row (lifecycle=done, PR `#4738`
  merged) under the OLD closed parent `studio-space-priority-desk`. File `spd-b39-seal-ledger-reconciliation`
  (parent spd-b39) carrying the 15-row stamp-and-close worklist AND a SEPARATE per-criterion re-verify of
  spd-b39's own 5 root criteria — NOT a blanket flip (≥2 of the 5 demand the shape be RULED+MEASURED on
  the deployed build, still open pending SEAL-BLOCKER 2 landing). Patch
  `spd-b39-seven-merged-children-need-the-merge-stamp` (stale "seven") as superseded. All 15 PRs merged
  pre-freeze, so their task rows CAN close now — the freeze holds only NEW merges.

- **D204 — Seal path, status-updated.** SEAL-BLOCKER 1 = push slice C (`spd-w13-prediction-registered`,
  branch `loop-epic/register-the-terminal-run-s-prediction-a-2-r`, tip eb39567c0, re-confirmed
  merge-tree-clean against the CURRENT origin/main tip, 2 additive `scripts/measurements/` files, no PR)
  → merge → an OPERATOR holding `~/.ssh/barkpark_indx` fires `inspector-shape-bracketed-deployed-run`
  (D196 human-only; `readProvenance()` die()s without ssh). SEAL-BLOCKER 2 = this wave's FIX (S1+S2) —
  moves from PIN-ONLY residue to IN-FLIGHT. Reconcile = D203. Cross-surface inspector (sheet/graph/media)
  = EXPANSION, post-seal.

- **D205 — `reset_nav_for_switch/1` async transient is named, not fixed.** Verification (V5) found the
  workspace/project-switch leg assigns `editor_view: :form` directly (bypassing the `rebuild_panes` case)
  but every one of its exits chains into `rebuild_panes()` or `push_patch → handle_params →
  rebuild_panes` — so the identity-gated clear still closes this leg, just possibly one LiveView cycle
  later. Benign: the transient window holds `editor_view: :form`, never `:paper`, so it is not a
  reachable scrim state. S1's builder is told the identity gate disarms it; no separate fix.

**Wave 15 slice table.**

| # | slice | task | round | builder | files |
|---|---|---|---|---|---|
| S1 | FIX 1 — identity-gated `secondary_doc` clear on nav + LiveView protective test (both legs) | `spd-w13-secondary-doc-zero-coverage` | 1 | fable | `api/lib/barkpark_web/live/studio/studio_live/shared.ex`, `shared/paper.ex`, `test/barkpark_web/live/studio/studio_live_secondary_doc_test.exs` (new) |
| S2 | FIX 2 — standard-bucket scrim suppressor + cascade guard + positive-control repair | `spd-standard-bucket-scrim-unruled` | 1 | fable | `api/lib/barkpark_web/layouts/root.html.heex`, `test/barkpark_web/studio/inspector_summoned_destination_test.exs` |

Two file-disjoint slices, both round 1, dispatched in parallel. S2 is `root.html.heex`'s sole owner this
round (D16). Both fable — S1 carries the split-view regression trap (D199), S2 the cascade + merged
positive-control repair (D200). Ledger reconcile (`spd-b39-seal-ledger-reconciliation`) and slice-C push
(SEAL-BLOCKER 1) are LEAD/operator work, not builder slices.

### Wave 16 amendments (2026-07-22, D206–D214) — THE VERDICT-AND-SEAL WAVE (Arm: B)

Wave paper: `spd-b39-residue-wave-2026-07-22`. Research-program **Arm B** (survey 5, verify 3, digest
light, review rank-and-fix; /papers/epic-cycle-research-program-abcde). The wish carried at least two
stale premises (items 1 and 3); this wave NAMES them (D206, D203) instead of obeying them —
premise_failures are reported explicitly at Review.

- **D206 — The headline premise is DEAD at L1.** The fresh bracketed run (2026-07-22, artifact
  `scripts/measurements/spd-b39-residue-run-2026-07-22.json`, fired with origin/main's FINAL instrument
  blob `d5218a8f6`, served_sha `9d956b611` == origin/main at run time, slot blue, provenance bracket
  matched, round_trip 27/27 bit-identical, bucket precondition 72/72): at viewport 1024 the USER-OPENED
  reading column is **60.00ch native, panel 980px, is_destination=false, scrim renders in 0 of 54 rows,
  dimmed_content_px=0**. The wish's "38ch crush at 1024" cites the pre-ladder wave-8/9 record (panel 720,
  scrim alpha 0.55, dimmed ≈38ch) — that state no longer exists on the deployed build. **No fix slice
  exists this wave.** Item 1 of the wish resolves by STAMPING, not building (D208).

- **D207 — Forced-georgia shortfall: RECORDED AND EXEMPT, not a defect.** The only sub-55ch user-opened
  desktop faces in the run are forced-georgia 1280 = 53.95ch (−1.05) and 1024 = 54.31ch (−0.69); native
  clears at every non-destination desktop width (min 59.60ch@1280) and source-serif-4 clears everywhere
  (64.98/65.42). RULING: forced-georgia is the deliberately-widest stress face (11.0469px/ch registered),
  not the deployed default; successor criterion 2's own text accepts "records its shortfall per face,
  named and owned". The shortfall is hereby named (this decision) and owned (the run artifact). No
  compound-selector slice is spent on <1.1ch of a forced stress face. If a future wave ships a real
  per-face floor, it starts from this record.

- **D208 — Successor root criteria stamping map (per-criterion, never blanket).**
  Criterion 0 ← the run (27 user-opened rows = 9 widths × 3 forced faces, hardened instrument with D185
  bucket precondition). Criterion 1 ← rulings D148/D149/D154/D170 (shape chosen: Tier-2 in-flow dock +
  Tier-3 summoned destination, wide scrim abolished) + D190/D198 (shape SOLVED, rebuild rejected).
  Criterion 2 ← the run + D207 (native/ssf4 clear 55ch; georgia shortfall recorded per face). Criterion 3
  ← D161 (exemption question pre-registered before any run) + D202 (abolition applies the settled D127
  invariant — not a post-table exemption). Criterion 4 ← run row {1024, user-opened, native}:
  dimmed_content_px=0, visible_ch=60.00 == content_ch=60.00, is_destination=false, scrim.renders=false.
  The label sentence: **"dimmed and visible are identical because nothing is dimmed — dimmed_content_px=0
  in every non-destination row, and in destination rows visible is NULL (covered), never quoted as
  content."** `spd-b44-dimmed-vs-visible-label-identity` closes on the same row.

- **D209 — Slice C's MERGE is the committed floor.** The PDS crown sealed 12/12 at 2026-07-21T21:52:28Z —
  the freeze window is over, and scripts/** was never in its blast radius. Branch
  `loop-epic/register-the-terminal-run-s-prediction-a-2-r` (tip `eb39567c0`, 2 purely-additive
  `scripts/measurements/` files) merge-trees clean against origin/main with zero conflicts; no open PR
  touches the lane. The repo has NO branch protection and NO rulesets (verified via gh api) — every gate
  is review discipline, not a merge blocker; elixir.yml runs unconditionally (no paths filter) and passes
  trivially; security.yml and doc-gates path-skip a scripts-only diff; merging does NOT deploy (deploy.yml
  has no scripts/** path — correct, nothing to deploy). The builder RE-CLAIMS
  `spd-w13-prediction-registered` first (claim lapsed 2026-07-21, epoch 7) so pr-task-gate reads green.

- **D210 — Residue goes to ZERO this wave: the bracketed run fires ROUND 2, from this host.** V1 proved
  the "operator" is us — `~/.ssh/barkpark_indx` authenticates, the guerrilla token resolves, playwright
  1.59.1 + chromium are cached, and the instrument fired clean. `inspector-shape-bracketed-deployed-run`
  dispatches AFTER `spd-w13-prediction-registered` MERGES (its criterion 2 requires the frozen prediction
  + checker ON MAIN before the run). Recipe deltas vs the D206 run: fire TWICE on the same build
  (criterion 5 determinism), run `scripts/measurements/check-prediction.mjs` against the frozen
  prediction, quote the forced-container control (`scripts/studio-scrim-threshold-control.mjs`) as a
  SIBLING section — NEVER the shipped `--positive-control` flag (D188, proven false-green) — which also
  upgrades zero_cause from "DESK-FIXED (unproven)" to proven (criterion 6). served_sha may read
  `9d956b611` or later (api/** merges auto-deploy; scripts/** merges don't) — both contain every wave-15
  fix; the provenance bracket guards mid-run rotation as always.

- **D211 — Ledger-pipeline ruling from the V3 pilot: read each row's lifecycle FIRST.** The digest's
  blanket "all 15 claims lapsed, just re-claim" was wrong for the pilot row (spd-b29f was lifecycle=done,
  not lapsed-in_progress). Recipe: (1) `bp task get` → read lifecycle_status; (2) in_progress w/ lapsed
  claim → claim renews the lease; (3) already done → `bp task stage <id> open` FIRST (an UNDOCUMENTED
  done→open door — same ledger-lie bug class as tlv's #5621 publish door; flagged to tlv and filed as
  `tlv-bl-stage-verb-done-reopen-door`; builders use it ONLY for sanctioned reconciliation and watch for
  tlv gating it); then claim → pulse → stamp (verbatim `--criterion-text`) → close → re-GET to verify
  state, never just exit codes. Merge SHAs re-verified BY CONTENT (git log `Task:` trailer + diff
  content), never `--is-ancestor` alone. Pilot succeeded: spd-b29f now done 6/6 with SHA-cited evidence
  (`ce8943e58`, #4738).

- **D212 — b24 + c967 are straight verdict-closes.** `spd-b24-blocked-lifecycle-is-not-a-fence`:
  premise already ruled half-wrong 2026-07-21 (blocked IS claim-equivalent to open); the invariant is
  locked on origin/main by `api/test/barkpark/tasks/claimable_statuses_test.exs` (#5537, `aee876e4f`,
  which names spd-b24 in its moduledoc); no live tlv builder touches queue/claim/validation. CLOSE with
  ruling; the deferred true-blocking-primitive decision survives as new tlv backlog row
  `tlv-bl-true-blocking-primitive-decision` (SendMessage-ping tlv before the close, per the wish's
  coordination clause). `task-c967eebb8a51715f`: folded into wave-15 S2, which MERGED as `2dcf32b7a`
  (#5554) with the positive control repaired at BOTH assertions (860 ⇒ `""`, 861 ⇒ nil against the
  in-memory unsuppressed source, non-vacuity refute guard present) — evidence-close citing that SHA.

- **D213 — Charter lands on origin/main in the SAME wave that cites it.** D69 doctrine (builders read the
  charter via `git show origin/main:...`) means an uncommitted or locally-stranded charter is invisible.
  The Decide phase itself lands this amendment via branch `loop-epic/spd-b39-residue-decide-charter` + PR
  + merge (docs+json only), carrying: this amendment, the run artifact
  (`scripts/measurements/spd-b39-residue-run-2026-07-22.json`), and this run's grip ledger recipe rows.
  The PRIMARY checkout stays untouched: it is DIVERGED (HEAD `4f84fd087`, unpushed charter commits, its
  instrument copy 333 lines stale, missing the D185 bucket precondition) — stewarding it is backlog row
  `spd-bl-primary-checkout-diverged` (preserve → reset --hard origin/main → never fire the stale local
  instrument; V1 dodged this by running origin/main's blob). The D37 stub is NOT amended (its own text
  forbids it).

- **D214 — Wave 16 shape: three ledger slices round 1, slice-C merge round 1, terminal run round 2.**
  Honest count: items 1 and 3 of the wish are named premise failures (stale headline; superseded
  pointer), absorbed as D206/D203 rulings, not builds. The wave's end state: all 15 reconciliation rows
  closed with SHA evidence, the superseded pointer closed, spd-b39's 5 root criteria stamped TRUE
  per-criterion (D208), b24/c967/spd-b44 closed, slice C merged, and the terminal bracketed run PAID —
  residue zero. If the round-2 run cannot complete, unstamped bracketed-run criteria stay met:false with
  an honest note naming the missing run (pre-ruled fallback, wave paper block "Sharpest attack").

**Wave 16 slice table.**

| # | slice | task | round | builder | files |
|---|---|---|---|---|---|
| S1 | Push + merge slice C — the frozen prediction and its checker land on main | `spd-w13-prediction-registered` | 1 | opus | `scripts/measurements/check-prediction.mjs`, `scripts/measurements/spd-round-trip-prediction-2026-07-21.json` (both already authored on the local branch — push, PR, merge; no rebuild) |
| S2 | The 15-row seal-ledger reconciliation + superseded-pointer close + spd-b39 root-criteria stamp (D208) | `spd-b39-seal-ledger-reconciliation` | 1 | opus | (ledger-only — no repo files) |
| S3 | Verdict-closes: spd-b24 close-with-ruling, c967 evidence-close, spd-b44 label-identity close | `spd-b39w-verdict-closes` | 1 | opus | (ledger-only — no repo files) |
| S4 | THE TERMINAL BRACKETED RUN — twice, predicted, controlled; D127's exemption PAID | `inspector-shape-bracketed-deployed-run` | 2, AFTER S1 MERGES | fable | `scripts/measurements/` (new run artifacts only) |

S2 and S3 touch disjoint ledger rows (S2 owns the spd-b39 root row and the 15 worklist rows; S3 owns
b24/c967/spd-b44). S4 is the ONLY round-2 slice — it never dispatches beside an unmerged S1.

## Wave log — wave 16 (append at Review)

### Wave 2026-07-22 — Wave 16 (THE VERDICT-AND-SEAL WAVE), Decide. **Arm: B.**
Verify round: V1 FIRED the instrument (38ch crush refuted at L1 — 60.00ch@1024 user-opened native;
only forced-georgia reads sub-55ch, ruled recorded-exempt D207); V2 proved slice C still clean + no
branch protection exists; V3 piloted the close pipeline on spd-b29f (done→open stage door discovered,
flagged to tlv). Decisions D206–D214. Wave: S1 slice-C merge, S2 reconciliation, S3 verdict-closes
(round 1) + S4 terminal bracketed run (round 2, after S1). Backlog filed:
`tlv-bl-stage-verb-done-reopen-door`, `tlv-bl-true-blocking-primitive-decision`,
`spd-bl-primary-checkout-diverged`. Review appends the grade + premise_failures/review_fixes counts here.

### Wave 2026-07-22 — Wave 16 (THE VERDICT-AND-SEAL WAVE), Review. **Arm: B.** Grade A-.

**Landed (round 1, all green):** S1 `spd-w13-prediction-registered` MERGED at `dc4d2db02` (#5684) — the
frozen prediction + checker are on main; the reviewer executed the checker (the builder never ran it):
all four exit paths proven and a mutation test (one flipped raw after-value → 3 SELF_INCONSISTENT + 1
ROUND_TRIP miss) shows it genuinely recomputes; zero code fixes. S2 reconciliation: 15/15 worklist rows
done with SHA-cited evidence (trailer-bleed catch on tier3-header-chrome verified real — `1b71730d8`
#5015, not stacked #5016); superseded pointer cancelled. S3 verdict-closes: b24 (ruling, `aee876e4f`
#5537), c967 (`2dcf32b7a` #5554), spd-b44 (run row) — all verified, task closed done 5/5 by Review.

**Review_fixes (2, both ledger):** the epic root's 5 criteria were stamped met:true with LITERAL 'C' as
evidence (vacuous — the one material defect, on the crown row of the seal; grade capped at A- for it);
Review re-stamped all 5 with the full D208 evidence map. And spd-b39w-verdict-closes criterion 4 was
stamped + the task closed on Review's independent three-row verification.

**Premise_failures (3 = 2 external + 1 internal):** wish item 1 (38ch crush) dead at L1 (D206); wish
item 3 superseded (D203); internal — our stage-door filing was a mis-premise, hereby folded as:

- **D215 — Stage-door retraction (correction of D211's framing).** The `done→open` stage transition is
  the RATIFIED D7 reopen edge (`transitions.ex` lists `{done, open}` under terminal→reopen; `stage.ex`
  gates on that one table), NOT an undocumented door of the #5621 bug class. `tlv-bl-stage-verb-done-reopen-door`
  is closed as a mis-premise duplicate; the real defect (stale capabilities-manifest description feeding
  `bp task stage --help`) is owned by `task-13bc8127adedfee0` (tlv epic). D211's operational recipe is
  UNCHANGED — stage-open for done rows is legal and sanctioned. Attribution fix: cite #5537/`aee876e4f`
  by SHA, not as tlv-publishdoor-builder's work.

**Round-2 intel (for S4):** the frozen prediction ALREADY reads MISMATCH against the D206 residue
artifact — 24 misses, all viewport 1280, all faces, all basis `prior-observation` (predicted 596px/59.6ch
from the 2026-07-20 table; the deployed build measures 640px/64ch default-state at 1280; before==after,
so a real layout move, NOT a round-trip failure). Round-trip claims hold 27/27; covered-column ruling
HELD in 18 rows. The prediction stays frozen: when S4 fires, expect exit 1 in exactly this shape and read
the per-miss `basis` field — stale absolutes wrong, structural/ruling claims held. That IS the honest
quotable ruling; re-freezing after seeing results is the corruption the design forbids.

**Next:** dispatch S4 `inspector-shape-bracketed-deployed-run` (its sole dep is merged): fire twice on
the same build from origin/main's instrument blob, checker against the frozen prediction, forced-container
control as a SIBLING section, new artifact files only, Task trailer PR; lead closes criterion 11 on
merge, then Review seals the epic root (in_progress 5/5). After S4: epic residue zero.

---

## Wave 17 — THE HAND-AUTHORING WAVE (owner report, 2026-07-29)

> Wave 17 paper: **`studio-space-priority-desk-wave-2026-07-29`** (style=article).
> Anchor: bp task **`task-f559f7c508527010`** (P0, 6 criteria, claimed `strategist`, **epoch 4**).
> Amended 2026-07-29 (D216–D231).

**The wish, verbatim (L1 — a human used the product):** *"As an interactive CMS it does not really work
good yet — for example the Desk Structure shows buttons — but for example when creating a paper and
selecting it, we see nothing. So right now AI has created everything — we need to be able to add things
physically as well."*

Sixteen waves of this epic optimised the geometry of a pane that already has a document in it. Not one
asked whether a document could get there. The charter carries ZERO authoring commitments across D1–D215
— that silence is the finding, and Wave 17 is new scope, not a re-litigation.

- **D216 — The create-seam fix is EXACTLY TWO EDITS, both necessary, together sufficient; `handlers/fields.ex`
  is NOT touched.** The direction's "three defects, any one sufficient" is refuted in both directions, by a
  four-cell mutation matrix on the strict acceptance (canvas hook + "Add block" + no empty state):
  **A+B → 2/2 pass** (`editor_view=:paper block_mode=true canvas=true addblock=true`); **A only → RED** at
  ACCEPT-3 (pane opens, `block_mode=false`, no canvas); **B only → RED** at ACCEPT-1 (still "Select a
  document to edit"); **neither → the owner's bug.**
  **A** = `pane_builder.ex:422`, blocks branch: `Content.get_blocks_doc(slug, …)` → `Content.fetch_doc_with_draft(type_name, slug, …)`,
  threading the REAL `is_draft`/`has_published` (they are hardcoded `false` today, so a draft paper would
  otherwise open claiming to be published). **B** = `shared.ex:176`, `seed_new_doc_content/1`.
  **RULING: fix the STORAGE side, keep the NAVIGATION.** Published-id navigation is *correct* — every
  non-blocks type already depends on it, and `same_editor_doc?/2` (`shared.ex:1009`) normalises both sides
  through `Content.published_id/1`, so fix A cannot break document identity, presence, secondary (D199),
  refs or discard. Navigating to a `drafts.` id is the cheap lever and it is FORBIDDEN.

- **D217 — THE FOURTH DEFECT DOES NOT EXIST. Its evidence was a harness artifact, and this correction is
  the wave's most important finding.** The digest reported an unlocated defect on the `nav_path → editor_doc`
  path because mutating `handlers/fields.ex` to navigate to the real draft id STILL rendered blank. Root
  cause of that result: `zz_repro_new_doc_editor_test.exs` mounts the Studio **ROOT** (`nav_path == []`) and
  fires `new-document` from there, so `nav_path` becomes a SINGLE segment with no type-list segment in front
  of it; `walk_path/7` (`pane_builder.ex:252`) then finds no structure node for ANY id, draft or published,
  fixed or unfixed. **Proof it is an artifact:** with the complete fix applied and the human journey 2/2
  green, `zz_repro` still fails **2/2**. And no human can reach that state — both `phx-click="new-document"`
  render sites (`components.ex:992` header action, `components.ex:1022` empty-list CTA) live INSIDE a
  document-type list pane. **Ruling: the "fourth defect" is retired; a repro that drives a state the UI cannot
  produce is an instrument, not a fact, and may not be cited by any slice.**

- **D218 — The defect is BLOCKS-SHAPED, not paper-shaped and not type-general.** Measured by running the
  desk `+` per type: `paper` and `session` (the exact `Content.blocks_type?/1` whitelist, `block_ops.ex:50`
  `["paper","session"]`) go blank; `post` (`editor_doc="drafts.post-…"`, a real form, no empty state),
  `sheet`, `task` and `ticket` all open fine, because every non-blocks branch resolves through
  `fetch_doc_with_draft`. The surveyor who "ran it and saw `post` fail" ran the root-level harness of D217.
  **Ruling: the fix and the guard gate on `blocks_type?/1` — two types, not one and not six.**

- **D219 — The seed is `%{"blocks" => []}` and NOT a hand-rolled paragraph.** Two live worktrees carried
  rival uncommitted prototypes. `[]` is the one that trips the writer's birth chokepoint
  (`writer.ex:310 maybe_apply_paper_template/2` → `Papers.Template.maybe_seed/3`, which fires ONLY on an
  explicit empty list), producing the locked `tpl-title` h1 + an empty `tpl-body` paragraph, `derive_title`,
  and `style: "article"` — a formed starter document with `ingress`/`featured` ghost slots, not a void.
  A hand-rolled one-paragraph seed BYPASSES the template (`blocks != []`) and measurably loses the title
  block, the article style stamp AND every ghost slot. **Binding on the guard: assert the PERSISTED shape
  (`tpl-title` locked/role:title + `tpl-body` paragraph), not merely that a pane appeared** — nothing joins
  `shared.ex` to `writer.ex:310` but convention, and `bp-pd-layout-ledger-reconcile-charter.md` D13 already
  records that chokepoint as untested end-to-end (open residue `pdd-t16-writer-path-test`). Asserting the
  shape discharges that residue as a side effect.

- **D220 — `pane_builder.ex:203` carries the IDENTICAL missing-draft-fallback and ships in the SAME slice.**
  The reserved `["open", type, id]` segment (the backlinks-panel jump) calls `Content.get_blocks_doc/4` with
  the same published-only resolution and the same hardcoded `is_draft: false, has_published: false`. A
  backlink to any draft-only paper opens nothing, silently. Fix it beside :422 or the wave leaves a second
  blank screen it already knew about.

- **D221 — `session` is IN scope for the resolution fix, OUT of scope for the birth template, and its schema
  icon is fixed this wave.** `blocks_type?/1` covers session, so A+B repair its resolution. But
  `maybe_apply_paper_template(attrs, "paper")` matches papers ONLY (`writer.ex:345` is the catch-all), so a
  session seeded `blocks: []` persists as an untemplated empty list → block mode with **zero canvas runs**:
  a second, different blank. Extending the birth template to session is **named out of scope** and filed.
  IN scope, because it is a one-field fix that also unblocks any session-covering guard:
  `priv/plugins/bulldocs/schemas/session.json:4` ships `"icon": "🧵"`, which `BarkparkWeb.Icons` **raises**
  on under `:test` (`icons.ex:260`) and silently mis-paints in prod (`:274` warn + "file" fallback).

- **D222 — The never-blank contract is built at the `<:empty_state>` slot. NOT at `paper.ex:701`, and NEVER
  inside `clear_paper_view/1`.** Three independent constraints converge:
  (a) **`:701` is DEAD CODE on this path** — a `raise` planted in it never fired across **1483** studio
  LiveView tests. Both and only two `view: :paper` producers return a bare `nil` editor on a lookup miss
  rather than `%{view: :paper, doc: nil}`, and `Document.content` is `field :content, :map, default: %{}`
  (`document.ex:21`), so the `when is_map(content)` head at `:639` always matches. Assigning a named state
  at `:701` paints a screen no user can reach. This also settles the digest's second correction by mutation:
  `%{}` IS a map, `Projection.read_blocks(%{})` → nil → the else-branch (`paper_block_mode: false`), so
  defect 3 is a genuine never-blank violation but **not** what fires.
  (b) **`clear_paper_view/1` is D199-radioactive.** D199 is live and non-vacuous: injecting the naive
  unconditional secondary clear reds `studio_live_secondary_doc_test.exs:159` by name ("same-doc reload must
  NOT wipe a live secondary pane"). It fires on same-doc Save/reload; a never-blank state routed through it
  paints "cannot render" over a healthy document mid-autosave.
  (c) **The reachable seam is `editor_doc == nil` → `editor.ex:476`, and `slot :empty_state` (`editor.ex:348`,
  documented `:283-284`) is DECLARED AND NEVER FILLED** — `grep -rn '<:empty_state' api/lib api/test` exits 1.
  The extension point for exactly this problem was built and left dead.
  **Ruling:** fill `<:empty_state>` at the sole `studio_editor_shell` call site (`components.ex:1283`) from a
  NEW assign computed where `editor == nil` but `nav_path` named a document. `clear_paper_view/1` and
  `setup_paper_view/2` are not modified. Constraints: the markup must NOT carry class `editor-body`
  (D180's `editor_body_tag/1` regex asserts it is `""` after a document close), must not resurrect
  `editor_doc`, and `clear_paper_view/1` must keep calling `sidebar_assigns(nil)`.

- **D223 — Structure-polish D19 binds the DESK TREE, not the editor pane.** That CUT ("do not retry in a
  future wave") is a Go-client structural fact: old binaries drop unknown node types and collapse bare lists.
  The Studio editor pane has no Go client. **D222 is not forbidden by D19** — say so explicitly, because a
  builder will otherwise read the CUT as covering it.

- **D224 — The desk becomes operable: `pane_item` → `<button type="button">`; `pane_doc_item`'s OUTER div
  STAYS a div and only `.bp-doc-row-body` becomes a button.** The convention is written down and therefore
  self-reproducing: `panes.ex` `pane_item/1`'s docstring says *"Renders a `<div class="pane-item">` (NOT a
  `<button>` — matches the Studio convention)"*. **Delete that sentence in the same diff.** Measured blast
  radius across the whole `live/studio` + `components` trees: **1740 tests, exactly ONE failure** —
  `studio_components_pane_test.exs:259`, a bare `assert html =~ ~s(<div)` (attributed: the same trees are
  1740/0 after revert). This replicates D55 at 40× scale and confirms its lesson — **no test anywhere in
  `test/` ever clicks a desk row through the DOM**; selection is only ever driven as
  `render_click(view, "select", %{"id" => …})`, which would pass identically if the row were a `<p>`. A
  builder who hits red will not hit red, and green is also what a `tabindex`-on-div half-fix produces.
  Binding sub-rulings, each measured or spec-derived:
  1. The D55 byte-frozen regex is on **`pane-column`** (`studio_live_width_bucket_test.exs:101-102`), a
     different component. It does NOT red. The `pane-item`/`pane-doc-item` class attributes are frozen
     nowhere — and nothing guards them either.
  2. The outer `.pane-doc-item` hosts the bulk-publish checkbox as a **sibling** of the row body; a
     `<button>` cannot contain a `<button>`.
  3. When `.bp-doc-row-body` becomes a button, its three inner `<div>`s become `<span>`s (button content is
     phrasing content). Consequently **`.pane-doc-sub` needs an explicit `display: block`** — it declares
     none, and as an inline box its vertical margins stop applying and `text-overflow: ellipsis` silently
     dies. `.pane-doc-main` is safe (blockified as a flex item of `.bp-doc-row-body`); `.pane-doc-title`
     already declares `display: flex`.
  4. Use **`aria-current`, never `aria-selected`** — `studio_components_pane_test.exs:258` is
     `refute html =~ "selected"` and reds on the latter.
  5. The doc row's `aria-label` is composed **from the TITLE**. The row carries `title={@doc_id}`, and
     `title=` is the accname fallback of last resort: converting to a button without an explicit label
     UPGRADES the raw draft id into speech ("drafts.paper-7780f97accedfd66"). Keep `title=` as the sighted
     tooltip; it is then correctly ignored for accname.
  6. The `.pane-item` UA reset must be declared **before** its existing `border-left: 3px solid transparent`
     or `border: 0` wipes the selected-row rail, and `width: 100%` is not optional (`.pane-body` is a plain
     block container, so a button there shrink-to-fits). Target the bare class, not `button.pane-item`, so
     the `a.pane-item.nav-plugin-entry` variant survives — the `.pane-section-header` reset
     (`root.html.heex:1560-1567`) is the in-file precedent, as is `button.pane-column--collapsed` (`:1677-1682`).
  7. The `+` button's accessible name is measured as the **empty string** (icon-only, no `aria-label`, no
     `title`, while its siblings at `:976`/`:984` carry `title=`). Name it.
  8. Ring spelling is settled: `outline: 2px solid var(--ring); outline-offset: -2px` (`:1504`, `:1681`,
     `:1707`). No `:focus-visible` exists today for `.pane-item`, `.pane-doc-item`, `.bp-doc-row-body`,
     `.pane-add-btn`, `.bp-doc-checkbox` or `.bp-desk-chip`.
  9. **D79's focus-loss class is inherited and is a BROWSER question**: activating a control that re-renders
     itself dropped `document.activeElement` to `<body>`. It cannot be answered by any ExUnit test — it goes
     in the browser harness (D226), not in a mix test.

- **D225 — Pending feedback is a SOCKET ASSIGN. `phx-disable-with` may never be the thing a guard asserts,
  and may never go on an icon-only button.** The common premise is wrong in both directions:
  `phx-disable-with` DOES fire for a plain non-form `phx-click` (`view.js:1668-1673` → `putRef` `:1434-1492`),
  and the repo already ships five such uses. But (a) **LiveViewTest never runs the JS client** — probed: the
  post-`render_click` server HTML is the pre-click button verbatim, no `disabled`, no text swap, no
  `phx-click-loading` — so a guard on it proves a string is in markup, the exact vacuous green this wave
  exists to end; and (b) on the icon-only `+` the client does `RESTORE := el.textContent` (empty), overwrites
  `textContent` (destroying the SVG), and on undo restores `""` — **leaving the button permanently blank.**
  A socket assign renders `disabled` + `aria-busy` + a label swap into server HTML and is fully observable
  offline (probed: `disabled="" aria-busy="true"` after `render_click`). Supporting gaps: `aria-busy` appears
  **zero** times in `api/lib`; `design/tokens.json` has no pending/busy/loading token; the only shipped
  affordance is `.phx-click-loading { opacity: .6 }` (`root.html.heex:3752`), authored as a double-submit
  guard, JS-applied, invisible to every ExUnit test — i.e. precisely the faint grey tint the owner read as a
  dead control.

- **D226 — CI: the OFFLINE LiveView guard is the required gate; the browser harness is the belt-and-braces
  proof, and D81 does not forbid it.** `elixir.yml:23` carries a standing order that the workflow **must
  never gain a workflow-level `on: … paths:` key**, so a guard inside `mix test` cannot be path-dodged; any
  new browser workflow WILL be path-filtered and can silently never run on a PR that misses its paths.
  The browser lane is nonetheless real and proven: `scripts/create-quickstart-smoke.sh` boots an ephemeral
  Phoenix on a throwaway port + throwaway DB with a **self-minted** admin token (12 passed, 0 failed), and a
  headless browser authenticated over plain `http://127.0.0.1` via `POST /v1/auth/login-tickets` →
  `/login/ticket/<t>` reproduced the owner's bug on a **brand-new, freshly-migrated, empty database** in
  **54s wall** — so the defect is not corpus-, instance- or guerrilla-specific.
  **D81's "committed, NOT a CI gate" is scoped to the DEPLOYED-guerrilla instrument** (it `die()`s without
  `ssh -i ~/.ssh/barkpark_indx`, a guerrilla admin token, an https host and a landed deploy). None of that
  applies to an ephemeral local instance: `endpoint.ex:104-112` adds `secure: true` to the session cookie
  only when `:session_secure` is set. **Ruling: D81 does not transfer; the harness may gate.**
  **And it MUST authenticate and assert its identity.** In `MIX_ENV=dev` there is no anonymous path:
  `plugs/optional_session_token.ex:47` falls through to `token_from_dev_config()`, verifying the seeded
  `config/dev.exs:90` `:dev_browser_token` — a principal that cannot exist in production, on a measurably
  reduced surface (`[phx-click="shares-open"]`: 0 anonymous vs 1 admin). A harness that "doesn't
  authenticate" silently degrades to that principal and still reports green. Assert a discriminator.

- **D227 — The journey guard CREATES ITS OWN DOCUMENT. D97 was this bug, diagnosed away as flake.** D97
  recorded `drillToDocument`'s `waitForSelector('.bp-paper-surface')` timing out at 30s for three
  independent verifiers, ruled it concurrent row churn, and pinned the instrument to a committed known-good
  `--doc` slug. **Measured now:** a pre-existing draft-only paper renders `bp-paper-surface=false` on
  origin/main and `true` after fix A. The drill clicked the first row; when that row was a draft-only paper
  the selector could never appear. **There is no abandoned code fix in this epic — there is an abandoned
  DIAGNOSIS, shipped as a workaround.** Ruling: the new guard never clicks "the first row" and never takes
  the `--doc` escape hatch, or it inherits the exact blindness that hid this for five subsequent waves.

- **D228 — The guard must ALSO open a PRE-EXISTING draft-only paper.** Only the blocks branch lacks the
  draft fallback, so ANY never-published paper or session is unopenable — not just a fresh one. Two fossils
  in production prove the human cost: `drafts.paper-b28358ff271b260e` (`_createdAt` 2026-07-09) and
  `drafts.paper-3149ef706e777628` (2026-07-06), both `blocks: 0`, both `_updatedAt == _createdAt` — created,
  found blank, abandoned. **The owner hit this twice, silently, three weeks before he reported it.** Both
  rows are KEPT as evidence; the strategist's `drafts.paper-7780f97accedfd66` is kept for the same reason.
  Free second guard, adopted: a fixed create seam means no new `blocks: 0 && _updatedAt == _createdAt` paper
  draft ever appears — an assertable invariant over the live corpus.

- **D229 — Do NOT route the `+` button through `BlockOps.upsert_blocks_doc/3`.** Probed seven ways: the
  literal `+` shape (`blocks: []`, title "Untitled") returns `{:error, {:halted, "This paper has a title but
  no content yet…"}}` and writes NO row; wall-compliant registered labels do not rescue it; **`bypass_wall:
  true` does not rescue it either** — the hollow gate (`block_ops.ex:277`) sits BEFORE
  `enforce_blocks_wall` (`:425`) and has no escape hatch at all. Behind it the wall then refuses on
  `description` and on `unknown_tag`. Worse, `handlers/fields.ex` already flashes `{:halted, reason}` as
  "Create cancelled: …", so this route converts *"I click + and see nothing"* into *"I click + and am told my
  paper has no content, and nothing is created."* The hollow gate and the authoring wall are two sealed
  epics' deliberate doctrine; the `+` button is not a publish. **Ruling: fix the READ side (D216); leave the
  write path alone.**

- **D230 — Named out of scope, so nobody discovers it in review.** (1) The publish-wall self-rescue: a fresh
  "Untitled" paper cannot be published out of the draft state — four sequential refusals (`description` ≥20
  chars → tag `tag` → `strength` 1-100 → `rationale` ≥20 chars → `unknown_tag`), plus a halt on "no content
  yet". The acceptance bar for Wave 17 stops at **SAVE**, not at publish. (2) guerrilla's 6-20s TTFB (2
  cores, load ~9.6) — the wave fixes what is wrong at ANY latency and refuses to chase it. (3) The
  `bp doc publish` 500 on large payloads: probed as **load, not code** — the identical `limit=100` request
  that failed later returned 200 on 3/3 retries, and `doc.publish` / `bulldocs.publish` are different
  endpoints, so "bulldocs succeeds" is not a controlled comparison. Filed as an investigation with a
  deterministic-repro bar, not as a confirmed defect. (4) Any open-ended aesthetic redesign.

- **D231 — This amendment lands in THIS file, per D37.** The `-desk-` path named in every Wave 17 brief is
  the 516-byte MOVED stub whose own text says *"Do not read or amend this file; do not cite it in a brief."*
  Four verifiers re-confirmed it this wave. Wave 17's docs-only PR carries **this** charter.
  **Methodological residue, recorded because it cost real time:** `bp search` was unreachable for six of
  fifteen surveyors AND **exited 0 while failing** (`context deadline exceeded` on
  `/v1/capabilities`) — so several "no prior art" findings are UNCHECKED, not absent. And the
  `tooling/grip/ledger/` corpus now poisons repo-wide `grep '<<<<'` conflict probes: a prior row's own
  documented `rerun` string contains the marker, so the MUST-RUN conflict probe returns 2 false positives.
  **Use `git merge-tree --write-tree` exit status, never marker-grep.** (PR #6055 is `MERGEABLE`/`BLOCKED` —
  a gate, not a conflict — and its only `shared/paper.ex` hunk is at `:374`, 265 lines from Wave 17's seam.)

### Wave 17 plan — 6 slices, 3 in round 1

| # | slice | round | task | files | model |
|---|---|---|---|---|---|
| S1 | create seam A+B+:203 + committed offline journey guard | 1 | `spd-w17-create-seam` | pane_builder.ex, shared.ex, new test | opus |
| S2 | desk operability — focusable named controls + rings | 1 | `spd-w17-desk-operable` | panes.ex, root.html.heex, components.ex, 1 test line | fable* |
| S3 | session schema icon (unblocks a session-covering guard) | 1 | `spd-w17-session-icon` | session.json | opus |
| S4 | never-blank contract at `<:empty_state>` | 2 (after S1) | `spd-w17-never-blank` | pane_builder.ex, shared.ex, editor.ex, components.ex | fable* |
| S5 | browser journey harness + CI workflow | 2 (after S1) | `spd-w17-browser-journey` | tooling/studio-journey/, scripts/, .github/workflows/ | opus |
| S6 | honest pending feedback (socket assign + aria-busy) | 2 (after S2) | `spd-w17-pending-honest` | components.ex, handlers, root.html.heex | opus |

\* fable-marked slices remap to Opus under the standing `no_fable` override (D19).

**HIGH-FLIP-RISK, named for the reviewer:** S1's judgment *"`handlers/fields.ex` needs no edit; navigation
stays published-keyed"* is the exact judgment the direction got wrong, in the opposite direction — it wants
an INDEPENDENT re-derivation, not a re-read. S4's judgment *"`paper.ex:701` is dead code"* rests on a bounded
negative (1483 tests + a static read of two producers), which is strong but not exhaustive; treat `:701` as
"not the seam to build on", never as "safe to delete".

**Fence:** `api/lib/barkpark_web/live/studio/**`, `api/lib/barkpark_web/components/studio_components/**`,
`api/lib/barkpark_web/studio/pane_builder.ex`, `api/lib/barkpark_web/layouts/root.html.heex`,
`api/test/barkpark_web/{live/studio,components}/**`, plus S5's new `tooling/studio-journey/`. Felix-pristine
fences itself strictly OFF `api/lib/barkpark_web/live/studio` (its D82) and Site Spawner fences OUT `api/**`
entirely (its D83) — so the overlap the lead warned about is smaller than feared. **One unadjudicated soft
edge:** Felix's fence reads `api/test` unqualified. Wave 17 claims `api/test/barkpark_web/{live/studio,components}/**`
by atomic bp claim; it is written down here rather than assumed.

## Wave log — wave 17 (append at Review)

### Wave 2026-07-29 — Wave 17 (THE HUMAN PATH), Review. Grade **A-**.

**The wish.** The owner sat down with the product and it did not work: *"when creating a paper and
selecting it, we see nothing… we need to be able to add things physically as well."* Rule one was
REPRODUCE IT AS A HUMAN FIRST, and this wave is the first in the epic that did — in the verify phase,
in a real authenticated browser on the deployed instance, before any diagnosis. The frames show the
Papers desk gaining an `Untitled` draft row after a click on `+` while the content pane still reads
*"Select a document to edit"*, twice (immediately and after 20s, so not a race); the control frames
show an EXISTING published paper opening into a full canvas with `+ Add block` and `Auto-saved`. The
machinery was present; only the never-published path was blank.

**Round 1 landed — three slices, all reviewed, all pushed with PRs.**

| slice | final branch | PR | verdict |
|---|---|---|---|
| `spd-w17-create-seam` | `…create-seam-a-new-paper-opens-in-0-r` | #7566 | THE owner's bug. `pane_builder.ex`'s blocks branch (and the reserved `["open", type, id]` segment) resolved published-only, so every never-published paper resolved to nothing; `seed_new_doc_content/1` now seeds an empty blocks LIST, which is what trips the paper template. Guard re-run by the reviewer against unmodified `origin/main`: **3 tests, 3 failures**, all on `refute html =~ "Select a document to edit"`. |
| `spd-w17-desk-operable` | `…make-the-desk-operable-every-structure-a-1-r` | #7567 | The defect was a written-down convention in `pane_item/1`'s docstring; that sentence is deleted. Rows are real buttons with composed accessible names, `aria-current`, and focus rings; the icon-only `+` gains a name. |
| `spd-w17-session-icon` | `…fix-the-session-schema-s-unrenderable-ic-2-r` | #7568 | Grew, in review, from one file into the class: `form_response.json` and scaffy `command.json` carried unmapped emoji too, and a new JSON-parsing scan over every `priv/plugins/*/schemas/*.json` found two MORE dead names (`shield`, `link`). Also delivers `spd-w17-sibling-schema-icons`. |

**Reviewer fixes in place** (each mutation-proven, each in the class ExUnit structurally could not see):
a brand-new paper was greeting its author with its own Slug field painted red — the inspector seeded
from the raw `drafts.` id and failed its own format check (`sidebar_assigns/1` now normalises through
`published_id`); the `div → button` conversion silently dropped the rows from body's `line-height: 1.6`
to the UA button's `normal` (`line-height: inherit` restored); and one new assertion was an
anywhere-match with an `or`, the same shape as the stale assertion the slice deletes.

**Held at round 2 BY DESIGN** (the sequenced-rounds law, not a stall): `spd-w17-never-blank` and
`spd-w17-browser-journey` after #7566, `spd-w17-pending-honest` after #7567. Dispatch in that order.

**What this wave did NOT do, and it matters.** Nobody has looked at the FIXED screen in a browser.
The reproduction is L1; the fix is proven offline. Anchor criteria 1–4 (`task-f559f7c508527010`) stay
open with honest `--miss` notes, and the browser-journey slice is what closes them. The format leg of
every gate exits 1 on this host on 88 untouched files — Elixir 1.19.5 installed against a pinned
1.18.4 — verified differentially against main's own red Format job on the real 1.18.1 toolchain, which
lists 94 files and none of this wave's, so no PR introduces one.

**And CI caught a real one.** #7566's guard was green on the scoped studio suite three times and RED on
all three arms in the full CI run — a process-global `BARKPARK_PAPER_CANVAS` leak from four sibling
suites. Reproduced locally, fixed by pinning the flag, re-pushed. See D233; that is the wave's own
lesson landing on the wave.

**D232.** A schema's icon is a shipped product string, not source, and `priv/` was a fourth hole in a
tripwire whose own moduledoc named three. Three schemas were wrong at once. The scan is the fix; the
two edits were the symptom.

**D233 — a scoped `mix test` is not the suite, and this wave proved it on itself.** The journey guard
was green on `test/barkpark_web/live/studio` three separate times and went **RED on all three arms** in
CI's full 12,971-test run, on exactly one line: `assert html =~ data-test-id="studio-paper-block-editor"`.
Cause, reproduced locally rather than guessed: `BARKPARK_PAPER_CANVAS` is read from the
**process-global** environment at render time, and four sibling suites deliberately set it to `"0"` to
pin the legacy opt-out (`paper_editor_test_helpers.ex`, `studio_live_paper_canvas_test.exs`,
`paper_canvas_test.exs`, `studio_live_paper_test.exs`). Running the guard with `BARKPARK_PAPER_CANVAS=0`
reproduces CI byte for byte. Note what stayed GREEN under the hostile env: `refute html =~ "Select a
document to edit"` — the owner's bug is fixed either way; a paper inheriting the OFF flag opens into the
read-only View pane plus the toggle. **The defect was in the guard, not in the fix.** The guard now pins
the flag ON (the mainline default per D7/D9) with the same `prev`/`put`/`on_exit` idiom the OFF suites
use. Any future test whose assertion depends on `BARKPARK_PAPER_CANVAS` must pin it; inheriting it is
an order-dependent green.

## Wave-18 amendment (LOOK AT THE FIXED SCREEN, THEN MAKE ABSENCE ILLEGAL, 2026-07-30) — D234–D250

Wave 18 is the second half of the owner's hand-authoring report. Wave 17 fixed the create seam and
nobody had looked at the fixed screen. **This wave looked, in the verify phase, twice, independently, in
real authenticated chromium on the DEPLOYED build** (guerrilla @ `e4ed31a103fac3b29c6310e82e27cfd83c61c50a`,
provenance bracketed PRE and POST on every run, `matched=true`). The confirmation the owner and the lead
were owed now exists. It also **split**, and the refuted half is the owner's own bug still live. Every
decision below is a run, not a read.

- **D234 — THE CONFIRMATION RAN. Leg A PASSES; leg B REFUTES; the wave reorders around leg B.**
  Leg A (a paper the driver created itself, D227-clean, no `--doc` hatch): desk loads 6 Structure rows →
  Papers patches **100 doc rows in 936 ms** → `+` carries `aria-label="New paper"`, `tabIndex 0` → create
  navigates `…/studio/paper` → `…/studio/paper/paper-844ec41c73b7e431` in **767 ms** → a real editor for
  THAT id (`studio-paper-block-editor` present, 1 contenteditable `tiptap ProseMirror`, `paper-add-block`
  present, `aria-label="Editing Untitled"`) → real key events → **server truth `blocks: 3`, types
  `[heading, paragraph, paragraph]`, `_updatedAt 22:49:11` vs `_createdAt 22:49:07`** → survives a full
  reload. **Wave 17's fix is real and the owner's bug is DEAD on the new-paper path.**
  Leg B is D228's leg, which the direction had dropped: **a PRE-EXISTING draft-only paper does not open
  into an editor.** Proven by a four-cell matrix that also rules OUT the `drafts.` id form as the cause —
  both id forms agree for both fossils, so the variable is the DOCUMENT:
  `fossil-A bare / fossil-A drafts / fossil-B bare → shell=1 body=0 ce=0 addblock=0 footer=0`, versus
  `created bare / created drafts → shell=1 body=1 ce=1 addblock=1 footer=1`. Both D228 fossils confirmed
  live first (`drafts.paper-b28358ff271b260e` and `drafts.paper-3149ef706e777628`, both `blocks: 0`, both
  `_updatedAt == _createdAt`; 18 draft-shaped of 609 papers). A `blocks: 0` pre-existing paper renders the
  paper shell plus the metadata sidebar and **nothing between** — no editable body, no `+ Add block`, no
  footer, no `aria-label`. It does not say "I cannot render this" and it does not say "Select a document
  to edit". **Wordless absence — the owner's exact disease, on the deployed build, today.** Zero console
  errors and zero pageerrors on every leg: the failure is silent, which is why it survived a wave.

- **D235 — D221's "second, different blank" is REFUTED on its render half. `blocks: []` ALREADY has a
  named state, at BOTH flag values, and slice work there would be VACUOUS.** Settled by run, not read:
  a session born through the desk's own seed persists `%{"blocks" => []}` (D221's persistence half is
  CONFIRMED — `writer.ex` `maybe_apply_paper_template(attrs, "paper")` matches papers only) and then
  renders `<p class="bp-paper-editor-empty">This paper has no body blocks yet. Add one below.</p>` plus
  the full `+ Add block` form plus `0 words · 0 blocks`. And the premise "that sentence is flag-OFF-only"
  is FALSE: on origin/main the sentence sits at `paper_editor.ex:227` and the `<%= if @canvas_on? do %>`
  branch does not open until `:231`, so it is flag-independent by construction; the `+ Add block` form
  (`:367`) and the footer (`:383`) are likewise AFTER the branch closes. This also refutes the digest's
  claim (6) that `+ Add block` is not on the deployed screen — it is, measured, on the canvas-ON default.
  **Ruling:** nothing in this wave "adds a named state" for `blocks: []`. What is wrong there is HONESTY,
  not absence — the sentence says "This **paper**" to someone editing a **session**, carries neither the
  id nor the type, and is painted `--paper-ink-faint` italic (`root.html.heex:3937`), the same faint-grey
  family the owner read as inert. That is a one-line honesty fix riding the seam D236 names.

- **D236 — THE BLANK IS `read_blocks -> nil`, AND ITS ADDRESS IS THE `true ->` ARM. D222 is AMENDED:
  `<:empty_state>` is a THIRD seam, not the paper seam.** Three verifiers converged. `Projection.read_blocks/1`
  returns nil for content with no blocks/body list — `%{}`, `%{"blocks" => "invalid"}`, and (measured on both
  fossils) content where the `blocks` key is **absent entirely**. `setup_paper_view` then takes its else arm
  (`paper_block_mode: false`, `paper_html: ""`), `show_editor = paper_block_mode && (canvas_on || paper_edit_mode)`
  is false, and the `cond` in `studio_live/components.ex` falls to its final `<% true -> %>` arm, which renders
  `<article id={"paper-body-#{@slug}"} data-rev={@paper_rev}>{raw(@paper_html)}</article>` — an EMPTY element.
  Confirmed on the deployed DOM by a plain authenticated curl for both fossils:
  `<article id="paper-body-drafts.paper-b28358ff271b260e" data-rev="0"></article>`, `paper-canvas-run` count 0,
  `"I cannot render"` count 0. And confirmed by a branch fingerprint: `branch: "HTML-legacy(raw paper_html)"`,
  `article_inner_len: 0`, `article_upd: null` (so NOT the stream arm), `editor_empty_sentence: 0` (so NOT
  D235's sentence, which lives inside `paper_block_editor/1` and is unreachable when `show_editor` is false).
  **Ruling:** build the paper-pane named state at that `true ->` arm, gated on `@paper_html` being blank so a
  legitimate legacy HTML-only paper with real `body_html` stays byte-identical. D222's three prohibitions
  survive intact and are re-affirmed: NOT at `paper.ex:701` (dead on this path), NEVER inside
  `clear_paper_view/1` (D199-radioactive), markup must not carry class `editor-body` (D180). D222's
  `<:empty_state>` ruling is CORRECT for `editor_doc == nil` and **structurally cannot reach a resolved
  document** — it lives inside `editor.ex`'s `if @editor_doc do … else`, and the paper pane never calls
  `studio_editor_shell` at all. D222's `unrenderable_content` reason is therefore MISFILED at that slot and
  moves here. Brief the site by SELECTOR, not line: D222's cited `components.ex:1283` has rotted to `:1287`
  and D225's `root.html.heex:3752` to `:3784` — the charter demonstrating D60/D73 on itself.

- **D237 — WAVE 17'S OWN GUARD IS VACUOUS OVER THE DEPLOYED BLANK, and this is the stamped-evidence class,
  not a slip.** `studio_live_new_paper_journey_test.exs` creates its draft-only fossil with
  `content: %{"blocks" => []}` — a **LIST**, so `read_blocks` returns `[]`, `paper_block_mode` is true, the
  editor renders, and `assert_real_editor!/2` (`refute html =~ "Select a document to edit"` +
  `assert html =~ studio-paper-block-editor`) passes. The production fossils' content yields a **non-list**.
  The fix moved the fossil from a weak generic named state to ABSOLUTE BLANK and the test passed because its
  fixture is not the shape the bug lives in. **Ruling:** any fixture for D236's seam MUST omit the `blocks`
  key entirely (or set it non-list). A `blocks: []` fixture is a false green and is now a named defect shape.

- **D238 — A SUCCESSFUL SAVE ANNOUNCES NOTHING, FOREVER. Fourth never-blank case, and the root of the
  owner's "inert".** `[data-test-id=bp-paper-footer-save]` — a `role="status" aria-live="polite"` region, and
  the page's ONLY `aria-live` — was **the empty string** after a save proven to persist (server `blocks: 3`),
  polled for 25 s. The footer counts DID move ("1 words · 2 blocks" → "9 words · 3 blocks"), so the page was
  alive; the announcement region was silent. Code cause on origin/main: `paper_ops/2`'s `{:ok, _result}` branch
  assigns `sync_paper_edit_doc / push_canvas_echo / push_task_previews / push_block_renders / paper_halt: nil`
  and **never `save_status`**, while all three error branches assign `"Save failed"`. `save_status_label(_) -> ""`
  renders nil as empty. **The canvas save affordance can only ever say nothing or "Save failed".** There is no
  "Saving…" transient anywhere and `"Saving"` appears 0 times in the served page. **Ruling:** the success branch
  must announce. This is offline-assertable at the assign and mutation-provable; it is not a design question.

- **D239 — A FIFTH NEVER-BLANK CASE THE CONTRACT DID NOT COVER: THE DESTINATION RAISES. `/studio/rest` and
  `/studio/plugins` return HTTP 500, and anchor criterion 4 is DONE — it found this.** Every Desk Structure row
  was clicked from a freshly loaded `/studio` on the deployed build. Six rows: Papers, Sheets, Tasks patch
  correctly; Projects and Fleet are anchors that navigate; **…Rest is DEAD on click** (8 s, no URL change, no
  `aria-current`, silent console) **and its destination 500s**: authenticated `rest 500` / `plugins 500` /
  `studio 200`. Root cause named, with guerrilla's own stacktrace from the verifier's own request:
  `** (FunctionClauseError) no function clause matching in BarkparkWeb.Icons.resolve_paths/2` at
  `icons.ex:258: resolve_paths(nil, :warn)` ← `icons.ex:293` ← `studio_live/components.ex:1106`.
  `resolve_paths(name, policy \\ @unknown_icon_policy) when is_binary(name)` has **no non-binary clause**, so a
  nil name never reaches the `:warn` policy and the module docstring's promise — *"Outside :test this warns and
  falls back rather than raising — a cosmetic glyph never crashes a page"* — **is false for nil**. D221's own
  sentence ("silently mis-paints in prod") is true only for an unknown BINARY name. Three emitters, four
  unguarded dynamic render sites, and it REPRODUCES OFFLINE on a clean local DB with the identical stack:
  `structure.ex:254 plugin_group_node` emits `%Node{… type: :list}` with **no `:icon`** so all five
  `plugin-grp-*` children carry the struct default nil (structural — `/studio/plugins` crashes with zero
  fixtures, and the pane materialises even where the row is invisible because `gating: :none` forces every
  placement); `structure.ex:301 rest_child_node` has two nil paths (the orphan branch omits `:icon`, the schema
  branch takes `Map.get(schema, :icon)`); `pane_builder.ex:981 list_items` forwards `icon: child.icon`
  UNGUARDED where the placed-node path at `:285/:339` correctly uses `node.icon || (schema && schema.icon)`;
  `components.ex:1106` (the `_ ->` catch-all — the stack frame) and `:1057` (`:header`) render
  `<.icon name={item.icon}>` UNGUARDED where `:1023` and `:1068` guard. **And a third, larger crash site:**
  `studio_components/editor.ex:407` renders `@editor_schema.icon` unguarded inside `studio_editor_shell`, so
  **any document of an iconless schema 500s the whole Studio editor** — not an edge case, a product-breaking
  one: create a schema without an icon and its documents are unopenable. `drawable_icon/1` exists at
  `editor.ex:617/621` and is applied at only two of the sites that need it. Nothing caught it because of the
  20 files in `api/test/barkpark_web/studio/` only 6 mount a LiveView and none of the five `pane_builder*`
  suites render — they assert the DATA, and `icon: nil` passes right through them; the icons tripwire is a
  literal scanner and cannot see `name={item.icon}`. **Ruling:** the fail-safe clause at `icons.ex` closes the
  whole class and makes the docstring true; the call-site guards are what keep a WRONG glyph from silently
  returning. Because `@unknown_icon_policy` is `:raise` under `:test`, the guard needs **no browser** — it is
  an ordinary `assert_raise`-before / named-state-after ExUnit proof.

- **D240 — TRANSPORT DECIDED BY RUN: CDP WINS. Build ONE transport; no Playwright, no `Input.insertText`.**
  `tooling/search-smoke/journey-smoke.mjs`'s `type()` — `Input.dispatchKeyEvent {type:"keyDown", text,
  unmodifiedText, key}` + `keyUp`, nothing else — inserts characters into the real `<bp-paper-canvas>` TipTap
  contenteditable and the whole save round-trip completes: keystroke → TipTap transaction → `bp-canvas-ops`
  CustomEvent → the hook's `paper-ops` pushEvent (the literal Phoenix frame was captured:
  `["4","10","lv:phx-…","event",{"type":"hook","event":"paper-ops","value":{"ops":[{"op":"patch-block",…}]}}]`)
  → server persist, read back over the API rather than the DOM. Proven twice — a text edit AND a STRUCTURAL
  edit (Enter creating a new paragraph block persisted as `{"id":"c-1-c29e06c6","type":"paragraph",…}` with
  **no save click at all**). Three transports were raced on the committed
  `api/assets/paper-editor/src/canvas/__harness.html` against the real built bundle; all three insert and all
  three emit an identical `patch-block` op, so `Input.insertText` is available but redundant. CDP also survives
  the https login-ticket → Secure-cookie leg on deployed guerrilla, needs no npm and no browser download
  (ubuntu-latest ships Chrome; `CHROME=/usr/bin/google-chrome`), and already implements the exact self-test /
  report-mode / exit-0-1-2 split this instrument needs. Playwright by contrast must be resolved out of the JS
  monorepo (`resolvePlaywright` via `createRequire`), which in CI means a `pnpm install` plus a chromium
  download. **Ruling:** CDP, reusing `studio-desk-measure.mjs`'s AUTH half only (`POST /v1/auth/login-tickets`
  with a body that must stay `{}` — an `email` mints a USER-shaped ticket; 60 s TTL; single-use; https because
  the cookie is `Secure`).

- **D241 — `tooling/**` DODGES THE REQUIRED GATE, so the revert-red obligation lives in ExUnit and NEVER in
  Chrome.** Measured: `tooling/studio-journey/journey.mjs` → `compile=false test=false`, and
  `.github/workflows/studio-journey.yml` → `compile=false test=false` too. `tooling/` appears in NEITHER
  `ELIXIR_COMPILE_PATHS` nor `ELIXIR_TEST_ONLY_PATHS`, so a tooling-only PR gets `mix-test` **skipped against a
  gate value of literally `false`**, which the aggregator's allow-set accepts as legitimate, and `Elixir gate`
  reports GREEN. Worse, a new `studio-journey.yml` carrying a `paths:` key is **permanently** un-promotable:
  `required-checks-generate.sh` stage **S4** excludes by name every check defined in a paths-filtered
  `pull_request` workflow ("a required required absent context never reports"). A third path set is also a code
  change — `assert_set_name` accepts only `compile|test` and exits 2 on anything else. And promotion cannot ride
  the introducing PR at all: the generator only emits names it OBSERVED on ≥2 sampled shas.
  **Ruling:** the browser harness ships as a committed instrument with a `--self-test` mutation proof plus a
  REPORT-MODE live lane (the `search-starter-smoke` doctrine, whose header states the reason: *"a deploy outage
  is not a property of anybody's diff"*, and which costs 1 m 07 s – 2 m 16 s). It is EVIDENCE, not a gate. Every
  "reds when the fix is reverted" criterion in this wave is carried by a test under `api/test/**`, which is
  already inside the required gate at zero new CI cost (`api/test/barkpark_web/studio/pane_builder_test.exs` →
  `compile=true test=true`). No slice may claim revert-red on a Chrome lane.

- **D242 — `spd-w17-pending-honest` IS DEFERRED, because its criterion 3 is UNSATISFIABLE AS WRITTEN and its
  blocking question is a file nobody read.** Three measurements, each of which would have cost a builder a
  round. (1) Every desk handler is fully SYNCHRONOUS — `Scope.select/2` is `assign(focus_pane_idx: nil)` +
  `push_patch`, `Fields.new_document/2` is an inline `Content.create_document` + `push_patch` — so there is no
  instant in which a pending assign could render, offline or in a browser. D225 is right that a socket assign is
  the shape; what D225 does not say is that the assign has nowhere to live until the handler DEFERS. Pending
  feedback is not "add an assign", it is "split a synchronous handler". (2) `push_patch` runs `handle_params`
  **SYNCHRONOUSLY INSIDE THE EVENT REPLY** (`channel.ex` `sync_handle_params_with_live_redirect` calls
  `call_handle_params!` then `handle_changed(…, ref, opts)` with the EVENT's own ref) — measured on the real
  StudioLive, **20/20 post-params**: clicking `#item-author` returns HTML that already carries
  `pane-item selected`, a `.pane-doc-item` and "Ada Lovelace". So an assign recomputed or cleared by
  `handle_params`/`rebuild_panes` is INVISIBLE in `render_click`'s return, and the naive reading of D225 fails
  offline for exactly the controls in scope. (3) The assertion SITE, not the deferral idiom, is the
  discriminator: on `render_click`'s RETURN VALUE both `start_async` and `send(self(), …)` show pending
  **200/200** (and 50/50 under 500 busy processes — an ordering guarantee via `Task.start_link` +
  `report_async_result`, not a race), while `render(view)`/`has_element?` AFTER the click show idle **20/20** for
  both. So the digest's "a `send(self(),…)` guard would RED while the feature WORKED" is FALSE for a
  return-value guard; the real hazard is the INVERSE and worse — a return-value guard is GREEN for
  `send(self(),…)` too, which gives a browser-visible window of microseconds. A DOM pin alone cannot pin
  perceptibility; the slice needs a structural pin on the deferral itself. **And the deciding file is unread:**
  `handlers/lifecycle.ex`'s `finish_handle_params` determines whether ANY pending assign survives, and no
  verifier opened it. A slice whose correctness rests on an unanswered question is re-scoped, not shipped.
  **Ruling:** deferred to the backlog with the criteria respecified — the brief must require `start_async`
  (or Task+monitor, per the genuine `api_tester_live.ex:55-60/:147` precedent, NOT `media.ex`/`refs.ex`'s
  `send(self(),…)`), assertion on `render_click`'s return value only, a `render_async` pin on the CLEAR so
  "permanently pending" cannot pass, and `finish_handle_params` read FIRST. `live_isolated` cannot probe this —
  it raises "cannot invoke handle_params/3 … not mounted nor accessed through the router live/3 macro" — so the
  probe must ride a real route. Note also that `aria-busy` still appears **zero** times in `api/lib` and zero
  times on the deployed page, and `.phx-click-loading{opacity:0.6}` at `root.html.heex:3784` is still the only
  in-flight affordance: D225 holds on the deployed build.

- **D243 — #7567 LANDED FOUR THINGS AND GUARDED TWO. The rings and the `+` label are UNGUARDED, and it is
  mutation-proven at the full gate.** Genuinely guarded, each proven by mutation → RED (99 tests, 1 failure):
  `pane_item` is `<button type="button">` (root-pinned by `assert <button` + `refute "<div"` over the whole
  render), `aria-current="true"` on selection, `.bp-doc-row-body` is a `<button>`, its composed `aria-label`
  comes from the title not the doc id, and the outer `.pane-doc-item` stays a div (a genuine ROOT pin:
  `html |> String.trim_leading() |> String.starts_with?("<div")`). The empty-list CTA is DONE and guarded too
  (`studio_live_empty_pane_test.exs`) — the premise that it is missing is FALSE; a real
  `<button class="btn btn-primary btn-sm">New document</button>` already renders. But removing **all four** of
  `.pane-add-btn:focus-visible`, `.pane-item:focus-visible`, `.bp-doc-row-body:focus-visible` and the `+`
  button's `aria-label` from origin/main leaves the **exact gate #7567 itself cited** fully green:
  **1747 tests, 0 failures.** Any future edit to `root.html.heex` silently deletes all three desk rings.
  Only the component unit test catches either landed mutation — `desk_row_ladder_test.exs` asserts class
  vocabulary only and would pass if every row were a `<p>`. **Ruling:** guard what landed. And note the grep
  discipline this produced: an unescaped `.` and `[…]` made `.btn:focus-visible` read 4 and
  `.pane-column[tabindex="-1"]:focus-visible` read 0, while `grep -F` gives 0 and 2 — **the opposite conclusion
  on both.** Any CSS-selector census in this epic uses `grep -F`.

- **D244 — THE DESK CHIPS' `role="tab"` IS A LIE IN BOTH STATES, and no test renders them.** `aria-selected={active}`
  in HEEx renders a **bare valueless** `aria-selected` when true and **omits the attribute entirely** when false —
  probed: inactive `<a class="bp-desk-chip " role="tab" href="#">x</a>`, active
  `<a class="bp-desk-chip is-active" role="tab" aria-selected href="#">x</a>`. Neither is a valid ARIA boolean, so
  a `role="tab"` inside `role="tablist" aria-label="Desk filters"` never announces selection. There is no
  `aria-controls` anywhere and no `role="tabpanel"` anywhere in the Studio tree, no roving tabindex and no
  arrow-key handler; and `role="tab"` on an `<a href>` overwrites the link role so AT stops announcing a control
  that navigates. The correct idiom already exists twice in-repo (`sheet_grid.ex:3077` and `chat_live.ex:3196`
  both use `to_string(...)`); `components.ex` is the lone outlier. `grep 'bp-desk-chip\|Desk filters'` over
  `api/test` returns **nothing** — zero tests render a chip. Per D79's standing law (*an ARIA state attribute that
  never changes is a lie to assistive technology and is worse than its absence*), **Ruling:** strip
  `role="tablist"` / `role="tab"` / `aria-selected` and use `aria-current="true"` on the active chip, matching what
  `pane_item` already does — which also makes the desk ONE selection vocabulary instead of the current three
  (`aria-current="true"`, `aria-current="page"`, `aria-selected`) plus a silent fourth (the `:plugin_link` anchor
  carries no `aria-current` at all).

- **D245 — RING-BEFORE-CONTROL IS BACKWARDS FOR THE CHECKBOX, and one of slice 3(c)'s three targets can never
  fire.** `.bp-desk-chip` is an `<a role=tab href>` — natively focusable, so its `:focus-visible` ring is REAL and
  ships alone. `.bp-doc-checkbox` is a bare `<span phx-click>` with no `tabindex`, no `role`, no `aria-checked` and
  no accessible name, and it is the **only** entry point into bulk-select mode (`toggle-doc-checkbox` has exactly
  one emitter and one handler; the bulk action bar only appears once something is checked), so a keyboard user can
  never reach bulk publish at all — and a `:focus-visible` rule on it is a **vacuous green by construction**. Same
  for `.pane-doc-item:focus-visible`, which D224 sub-ruling 8 lists: the outer div is not focusable.
  **Ruling:** the binaries are ORDERED — tab-reachability first (the span becomes a real control with
  `role="checkbox"` + `tabindex="0"` + `aria-checked` + Space/Enter), THEN the ring. A ring shipped before the
  control is a lie with a test behind it. Note `panes_test.exs`'s test NAME says "renders a checkbox span" but it
  asserts only class + handler, so a span→button conversion stays green: no blocker, stale name.
  Relatedly: "Projects and Fleet are anchors while the rest are divs" is now **half stale** — the deployed desk has
  24 `button.pane-item`, 2 `a.pane-item.nav-plugin-entry` and **0 `div.pane-item`**. The anchors are focusable and
  named; `root.html.heex:1543-1546`'s comment says the bare `.pane-item` class is targeted *specifically so* the
  anchor variant keeps the same rhythm. It is an idiom inconsistency worth a low-priority row, **not** an
  operability failure, and framing it as one would spend a slice on nothing the DOM can call broken.

- **D246 — D233's "the mainline default per D7/D9" is a PHANTOM CITATION; derive the flag from code.** D7 is
  `collapse?/3` as the wide-bucket reducer; D9 is caps classification for the `width-bucket` hook. Neither mentions
  the canvas flag, block mode, or any editor default, and `grep BARKPARK_PAPER_CANVAS` over this 2,157-line charter
  returns exactly four hits, **all inside D233 itself**. The flag's default is a CODE fact and must be cited as one:
  `paper_canvas.ex` `paper_canvas_enabled?/0` returns `true` for `nil` and only the literal `"0"`/`"false"` opt out,
  and `config/runtime.exs:54-55` additionally force-sets `"1"` in `:prod` when unset — doubly ON. Confirmed on the
  box: `BARKPARK_PAPER_CANVAS` is absent from the live serving process environ (`grep -ci canvas` → 0) and from every
  env file and `start.sh` (`rc=1`). D233's ruling (pin the flag in any test whose assertion depends on it) stands;
  only its authority line is struck. **And its MUST-RUN loop was vacuous:** `for FLAG in 1 0` over those two suites
  cannot discriminate anything, because each file pins its own flag in its own `setup` — both runs were 38 tests /
  0 failures with byte-identical counts, a pass produced by the wrong thing.
  Two more citation corrections while we are here. The digest's `api/lib/barkpark_web/live/studio/paper_canvas.ex`
  **does not exist** (`fatal: path … does not exist in 'origin/main'`); the real path is
  `…/live/studio/studio_live/paper_canvas.ex`. And guerrilla's serving unit is `barkpark-slot@blue.service`, not
  `barkpark.service` — the latter has `MainPID=0` and an empty `Environment=`, so `journalctl -u barkpark.service`
  returns `-- No entries --` and `systemctl show barkpark.service -p Environment` proves nothing. Any ops command
  in a brief must name the slot unit.

- **D247 — WAVE 17'S FOUR STALE-OPEN TASKS SHIPPED; SQUASH-MERGE MEANS SHA ANCESTRY LIES.** `920d563ee`,
  `a0ce94ee3` and `e0f3eb240` are NOT ancestors of origin/main, and that is squash-merge, not unmerged work:
  PR **#7566 → `c820cce8c`**, **#7567 → `6020b31a8`**, **#7568 → `544eec20d`**, all three MERGED and all three
  ancestors of main. #7568 covers BOTH `spd-w17-session-icon` and `spd-w17-sibling-schema-icons` (its head branch is
  session-icon's reviewer branch). All four claims are EXPIRED with `worker: null`, so a close needs a FRESH claim,
  not the recorded epoch. **Ruling:** never read "sha is not an ancestor" as "the work did not land" in a
  squash-merge repo; resolve through the PR's `mergeCommit`.

- **D248 — FENCE AMENDED: `api/test/barkpark_web/studio/**` IS IN.** The wave's declared test fence
  (`api/test/barkpark_web/{live/studio,components}/**`) omitted a third studio test directory — 20 files including
  all five `pane_builder*` suites, `measure_parity_test.exs` and `wide_geometry_lock_test.exs` — which is exactly
  where D239's nil-icon guard and any registry-derived type enumeration belong, and it is inconsistent with
  `pane_builder.ex` being in-fence while its tests were not. It is inside CI's `api/**` set either way
  (`compile=true test=true`), so only the charter sentence needed widening. Note the side effect honestly: the
  amended fence also contains `claude_chat_test.exs`, main's own flake — see D249.

- **D249 — MAIN'S GATE FLAKE IS INTERMITTENT AND LOAD-DEPENDENT, AND ITS GREEN IS VACUOUS.**
  `api/test/barkpark_web/studio/claude_chat_test.exs` "removes the stderr capture file on close" failed 1-in-13013
  on `453ee749a`; the SAME commit reran GREEN (`Test (Elixir 1.18.1 / OTP 27.0)` success, `Elixir gate` success — main
  is green as of this wave), 13/13 and 40/40 green on a quiet host, and 5 failures in ~30 runs under 24 CPU spinners.
  Mechanism: `claude_chat.ex` spawns `sh -c 'exec "$0" "$@" 2>>"<path>"'`, so the CHILD SHELL creates the file
  asynchronously after `Port.open`, and `terminate/2` → `cleanup_stderr` → `File.rm` races that open. **But the
  bigger finding is that the test's PASS is vacuous:** every PASSING run leaked exactly one new 0-byte
  `barkpark-claude-<uuid>.stderr` (6/6 measured; 582 such files on the host, 385 zero-byte, back to 26 Jul). The
  invariant it claims to protect is violated on every run of this shape. **Ruling:** do NOT `:flaky`-tag it (the
  escape hatch exists — `:flaky` is in `test_helper.exs`'s default `exclude:` — but tagging would bless a leak). Fix
  it in its own PR outside this wave's fence: wait until the child has created the file before closing, and clean up
  after the child is reaped. Filed. Until then, a red on that line is checked against main's own run first, then
  re-run — the D90 discipline. Separately: the advisory `Format` check is RED on main and the two formatters
  DISAGREE — CI's 1.18.1 names 63 unformatted test files, local 1.19.5 names one — so `mix format` locally does not
  satisfy CI and can lengthen its list. Format is not required (`Elixir gate` rolls up only changes, mix-test,
  mix-prod-compile, validation-perf, path-escape); three of CI's 63 are inside this fence.

- **D250 — BRANCH PROTECTION IS LIVE, and the SR-1 "no branch protection" memory is STRUCK.**
  `required_status_checks.contexts: ["Elixir gate","PR references an active task"]`, `enforce_admins: true`,
  `strict: false`, `allow_force_pushes: false`, no required reviews. So: `--admin` cannot bypass; a slice does not
  need to be up to date with main (no rebase treadmill); everything else (Format, Sobelow, Doc budgets,
  Typecheck+jest) is advisory. The gate is fail-CLOSED on skips — a `skipped` upstream passes only when its
  dispatcher gate string is literally `false`, and an api/** PR therefore must actually RUN and PASS mix-test.
  The task gate accepts a task claimed moments earlier (the `in_progress` branch needs only
  `lifecycle_status == in_progress` plus a non-empty `claim.worker` — no timestamp, no lease age), it re-fires on
  push, body edit and label change, and **nothing fires it on a ledger change** — so claim BEFORE opening the PR.
  Verified live: all three wave-18 slice tasks red the gate with *"is still 'open' and carries no claim at all"*.

**Named OUT of scope for wave 18, so nobody discovers it in review.** (1) The publish-affordance triple, and it is
worse than D230 measured: on the HAND path there is **no publish control at all** — the Publish CTA is minted in
`DocActions.default_doc_actions/2` and reaches the DOM only through the `studio_editor_shell` branch, which papers
never take; `paper_editor.ex` contains the string "publish" zero times; the paper sidebar's Publish section is two
read-only spans, there is no `description` input anywhere under `live/studio`, and no add-label/add-tag handler
exists in `api/lib/barkpark_web`. The read-only decision is documented and its stated rationale ("papers publish IN
PLACE, so wiring Publish would always fail") is **false for every hand-created paper**, because
`Content.create_document` forces `doc_id = drafts.<id>` and coerces status to draft. Also measured: `POST /v1/data/mutate`
creates a draft and publishing it returns **HTTP 422 `label_spine`**. Of D230's six refusals exactly one is
content-dependent and it clears with a typed paragraph — but a heading at **block 0** is SKELETON, so the obvious
path ("retitle, add a headline, save") still halts with "no content yet". Filed as three DOM binaries, built later.
(2) Focus-after-select — a genuine unowned fourth binary, offline-assertable and proven non-vacuous (0 marked
elements after `select` at all four buckets vs **1 and 1** for `expand-pane` at narrow), but its DESTINATION is an
unresolved decision: `select` truncates so the clicked pane is always the LAST pane, which `collapse?/3` protects at
wide/standard (the row itself survives, wearing `aria-current`, so the browser has no reason to move focus at all) —
while at narrow the surviving strip's `expand-pane` would CLOSE the document, and at phone there are **zero** pane
elements so the `focus_pane_idx` idiom is structurally unusable. Refutes the "widening" premise: the defect stays
exactly two buckets at every depth. Filed with the destination named as the open question. This also refines D224
point 9: the SYMPTOM (`activeElement`) needs a browser, but the CURE's presence in server HTML is offline-assertable.
(3) An Enter-at-tail structural edit that emitted `remove-block` for the last block plus `insert-after` block 1 —
one observation on a 5-day-stale local instance, PLAUSIBLE not confirmed, data-loss-shaped, filed with a
reproduce-on-main bar. (4) `.btn:focus-visible` (base-class blast radius, needs an app-wide visual review Fable
cannot give this wave) and `.pane-column:focus-visible` (already shipped at `root.html.heex:1704/1730`; its task is a
verification residue, not a CSS edit) — both DEFERRED IN WRITING rather than absorbed, so `cody-reviewer-w5`'s stale
assignment is not silently stolen. (5) Any open-ended aesthetic redesign: Fable is unavailable this wave.

**Litter this wave created, recorded so it is not mistaken for corpus.** The deployed confirmation created a real
draft on guerrilla production, `paper-844ec41c73b7e431`, carrying "VERIFY W18 HEADING". It will appear in Papers
lists and in any future draft census until deleted.

## Roadmap — wave 18 (LOOK AT THE FIXED SCREEN, THEN MAKE ABSENCE ILLEGAL)

Five slices build this run; two are deferred to round 2 because they touch the same regions of
`studio_live/components.ex` as a round-1 slice and this epic has already logged that co-scoped fixes need ordered
merges. Every slice is a binary the DOM or the server answers; none cites taste.

| # | round | slice | task | model | the binary |
|---|---|---|---|---|---|
| 1 | 1 | Journey harness, committed and re-runnable (CDP) | `spd-w18-journey-harness` | opus | both legs run and report; `--self-test` reds on a mutated fixture |
| 2 | 1 | The fossil blank: a resolved-but-unrenderable paper SAYS SO | `spd-w18-fossil-named-state` | opus | the empty `<article>` becomes a named state carrying id + real type + a way out |
| 3 | 1 | A successful save announces itself | `spd-w18-save-announces` | opus | `save_status` is assigned on `{:ok,_}`; the `aria-live` region is non-empty |
| 4 | 1 | The destination stops raising (nil icon) | `spd-w18-nil-icon-500` | fable | `/studio/rest` + `/studio/plugins` + an iconless-schema document all render instead of raising |
| 5 | 1 | Guard what #7567 landed | `spd-w18-guard-rings-and-label` | opus | deleting any ring or the `+` label REDS the suite |
| 6 | 2 | `<:empty_state>` filled — the third seam | `spd-w18-empty-state-seam` | opus | a not-found document names itself instead of "Select a document to edit" |
| 7 | 2 | The desk chips answer when touched | `spd-w18-desk-chips-answer` | fable | chip ring exists; `aria-current` replaces the fake `role=tab`; the checkbox is reachable then ringed |

**HIGH-FLIP-RISK, named here and in the briefs.** Slice 4's blast-radius judgment: adding a non-binary clause to
`resolve_paths/2` silences a `:test`-mode raise that other suites may rely on, and the slice touches four render
sites across two modules plus two emitters. Slice 6's enumeration-derivation judgment: five candidate derivations
give five different answers (registry 37 types; desk-tree 3 gated / 25 ungated and **`session` absent from both**;
filenames 35 snake_case strings of which ~17 are strings no doclist carries plus two phantoms; DB registry per
dataset; deployed 39–47 including types in no code registry), `post` and `page` exist in NO code-level derivation
(they are DB rows from `seeds/demo.ex`), and an enablement-filtered derivation silently drops `ticket` plus 25 frt
types. A genuinely independent second reviewer is owed on both before merge.

## Wave log — wave 18 (append at Review)

### Wave 2026-07-30 — Wave 18 (LOOK AT THE FIXED SCREEN, THEN MAKE ABSENCE ILLEGAL), Review. Grade **A**.

**The confirmation the owner and the lead were owed now EXISTS, and it is committed.** The lead's three
attempts died in `studio-desk-measure.mjs`'s instrument-failure path. This wave built the instrument
instead: `tooling/studio-journey/journey.mjs` walks create → open → type a heading and a paragraph →
persist, in real authenticated chromium on the DEPLOYED build, and reports **LEG A 7/7 PASS, exit 0 on
two different served builds of guerrilla with PRE == POST provenance on both** (`e4ed31a10` created
`paper-a84538babb6a928a`; `25e69158a` created `paper-92511c83866819e0`). Persistence is read back from
the drafts-perspective API, never from the DOM behind the `phx-update="ignore"` wrapper. **Wave 17's fix
is real.** LEG B refutes the other half live: both D228 fossils render `shell=1 body=0 contenteditable=0
addblock=0 footer=0 visible_text=0` — the owner's disease, still on the deployed build, which is what
slice 2 fixes.

**Round 1 landed — five slices, all reviewed, all gate-green, all pushed with PRs.**

| slice | final branch | PR | verdict |
|---|---|---|---|
| `spd-w18-journey-harness` | `…commit-the-journey-harness-create-type-s-0-r` | #7896 | The wave's crown: the confirmation is now a re-runnable instrument with a mutation-proven `--self-test` (good=0, rot=1) and a report-only CI lane whose header states in capitals that it gates nothing and cannot. Six traps encoded, three of them found by producing a FALSE verdict first — the stale-canvas decoy alone passed HYDRATE in 0.0s on the previous document. Reviewer fix: the litter sweep deleted by TIMESTAMP alone, so a document a human created in the same seconds was a deletion candidate; now bounded by shape too (untitled, no more blocks than the seed), with the residual window documented. |
| `spd-w18-fossil-named-state` | `…a-resolved-paper-that-cannot-render-says-1-r` | #7897 | The owner's blank has a name. A never-blank arm in FRONT of the legacy `true ->` arm, keeping the `<article>`, its id and its `data-rev` verbatim and replacing only the emptiness with `role="alert"` copy carrying the published id, the REAL type, a reason and keyboard ways out. `blank_body?/1` is neither `== ""` nor a bare tag-strip, so an image-only legacy body stays byte-identical. D237's fixture law honoured and wave 17's vacuum closed. Reviewer fix: the repair button was offered on an HTML-backed blank, which `reject_implicit_html_conversion/1` HALTS — a control that cannot do what it says. Now withheld there, with the honest reason, and the refusal is DRIVEN in the test. |
| `spd-w18-save-announces` | `…a-save-that-lands-says-so-paper-ops-stop-2` | #7898 | One line, exactly right: `paper_ops/2`'s `{:ok,_}` branch assigns the SAME `"Auto-saved"` token the single-op seam already assigned, so the page's only `aria-live` region can finally say success instead of only silence or failure. Three tests including both arms on one mounted view. Nothing to fix. |
| `spd-w18-nil-icon-500` | `…the-desk-destination-stops-raising-a-nil-3` | #7899 | D239's HTTP 500 closed at both layers, plus a third and larger crash site the survey had not named: `editor.ex:407` 500'd the WHOLE Studio editor for any document of an iconless schema. The new guard RENDERS — the reason nothing caught this is that none of the five `pane_builder*` suites does. Nothing to fix; the flip-prone `:raise` judgment is re-derived below. |
| `spd-w18-guard-rings-and-label` | `…guard-the-desk-focus-rings-and-the-plus--4` | #7900 | D243's unguarded shipped work, guarded: three rings pinned from one list with per-selector sabotage controls, and the `+`'s accessible name pinned by computing it in a mounted desk (`title` deliberately does not count). Reviewer re-proved BOTH mutations rather than reading them: cutting `.pane-item:focus-visible` reds 2/10 by name, `aria-label={nil}` reds 2/2. |

**Cross-slice proof, not per-slice hope.** All five branches were merged locally onto `origin/main` —
clean, no conflicts — and `test/barkpark_web/{studio,components,live/studio}` run **2123 tests, 0
failures** on that merge. Two slices touch `studio_live/components.ex` (2 and 4); they merge cleanly but
merge them in a known order and re-run the combined suites.

**HIGH-FLIP-RISK, re-derived independently, NOT flipped.** Slice 4 made the non-binary `resolve_paths/2`
clause fall back under `:raise` too. The builder's case holds (a non-binary name is runtime DATA, never
an authored literal, and the tripwire it trades away was never able to fire — no studio test rendered).
But the POLICY-AWARE alternative is strictly stronger at identical production safety: raise under
`:raise` (test only), warn + fall back under `:warn` (dev/prod), so a future unguarded `name={item.icon}`
site reds in any test that renders it. That fork is named in #7899 for a genuinely independent second
reviewer, and it was not flipped because verifying it needs a full-suite run this host could not give.

**Held at round 2 BY DESIGN** (the sequenced-rounds law, not a stall): `spd-w18-empty-state-seam` after
slices 2 and 4 merge; `spd-w18-desk-chips-answer` after slice 4. The chips slice must EXTEND slice 5's
`@desk_focus_rings` — slice 5 pins the two chip rings as ABSENT on purpose, so it will red for that
builder, by design.

**Filed, not fixed** (four published children, three of them because guerrilla's `/v1/data/mutate` was
500ing while builders tried): `spd-w18-bl-repair-button-endtoend` (the repair direction of the never-blank
button is a code reading, not a run — the refusal direction IS proven), `spd-w18-bl-select-detects-dead-destination`
(the nil-icon 500 is gone, the BLINDNESS in `Scope.select` is not), `spd-w18-share-access-btn-names`
(`airdrop-open` / `access-open` carry `title=` only — the `+`'s defect, unfixed, two buttons over), and
`spd-w18-bl-chat-render-golden-flake` (found by the reviewer: `chat_render_golden_test.exs:200` red once
in the combined studio run, green alone and green on the pinned re-run — D249's shape in a new file, and
not caused by this wave).

**What this wave still has NOT done.** Nobody has watched a REFUSED save, or the repair button, in a real
browser; the deployed 200 on `/studio/rest` and `/studio/plugins` is unconfirmed until slice 4 merges and
someone re-probes them authenticated; and the desk is measured at 1500x1000 only. The instrument to do all
three now exists and is committed — that is the difference this wave made.

## Wave-19 amendment (THE ANSWER CONTRACT, 2026-07-30) — D251–D269

**The law this wave writes is not "never blank" — it is NOTHING THE DESK DOES IS SILENT.** A deliberate press either
changes the screen, or names by name why it cannot, inside a bounded time, with a keyboard-reachable way out. Wave 18
closed three of the five ways this desk answers a human with nothing; wave 19 closes the fifth, generalises the first,
and pays two debts wave 18 handed forward. Every decision below was re-derived on `origin/main` at `051112568`, and
where a wave-18 conclusion was overturned it is overturned by executed output, not by reading.

- **D251 — #7899 IS SETTLED IN FAVOUR OF THE REVIEWER'S POLICY-AWARE FORK, and the fork was BUILT AND RUN before this
  ruling, not argued.** `resolve_paths/2` gets `:raise` → raise, `_` → warn-and-fall-back, instead of the builder's
  fall-back-under-both. Three independent grounds, each measured. (1) **Production safety is byte-identical**: main's
  only head is `def resolve_paths(name, policy \\ @unknown_icon_policy) when is_binary(name)` (`icons.ex:258`), so a
  `nil` name raises `FunctionClauseError` under `:warn` too — prod was NEVER saved by policy, and both arms make
  `:warn` warn. With the fork installed, all three of the PR's render tests (`/studio/plugins`, `/studio/rest`, the
  iconless-schema editor) PASS, so the fork fixes the three authenticated 500s exactly as well as the PR does.
  (2) **Zero collateral, measured**: fork + the PR's unmodified test file = `2123 tests, 2 failures`, and both
  failures are the PR's OWN assertions at `nil_icon_never_crashes_test.exs:148` and `:155`; after inverting those two,
  `2124 tests, 0 failures, exit 0`, plus `25 tests, 0 failures` over every other `resolve_paths` caller and the icons
  tripwire, and `mix format --check-formatted` exit 0. (3) **The fork extends the module's own shape**: `unknown_icon/3`
  on main is ALREADY policy-aware (`:raise` at `:267` raising `ArgumentError`, `:warn` at `:281` warning and painting
  `"file"`), so fall-back-under-both would be the module's ONLY policy-blind clause. **The honest bound, recorded so
  nobody oversells it:** the `:raise` arm is unreachable from all 15 current dynamic `<.icon name={…}>` sites — every
  one routes through a total helper, or `|| "file"`, or sits inside `if item.icon`. It is a tripwire for regressions,
  not a fix for anything live. It catches two future shapes: a new unguarded dynamic site, and a **truthy** non-binary
  (`:folder || "file"` evaluates to `:folder`) at `nav.ex:427`, `components.ex:1154`, `components.ex:1199`. Modest,
  real, free. **The builder's counter-argument is genuinely strong and loses narrowly**: "nobody writes `name={nil}`,
  so `:raise` cannot catch an authorship bug" is partly right — but the bug that shipped WAS an authorship bug
  (`plugin_group_node/2` omitted `:icon`), and the PR's replacement guard is two hand-written `known_icon?` loops
  covering only today's two emitters.

- **D252 — adopting the fork costs THREE COUPLED EDITS, and shipping only the code half leaves the module contradicting
  itself.** (a) The two test assertions invert. (b) The in-code comment "Warn and paint the 'file' glyph under BOTH
  policies" and the moduledoc section "The non-binary fail-safe" both argue for as-is and must be rewritten.
  (c) **`spd-w18-nil-icon-500`'s acceptance criterion C4 reads "Icons.resolve_paths no longer raises for a non-binary
  name" — under the fork it DOES raise under `:raise`.** C4 must be amended to scope the promise to `:warn` (dev/prod)
  or the merged code contradicts its own task. **#7899 is CLOSED AS SUPERSEDED, not amended in place**: both halves of
  its diff apply clean to current `origin/main` despite 11 commits of drift (`git apply --check` CLEAN on both), so a
  fresh branch carrying the whole diff plus the fork is cheaper and avoids cross-session branch contention on
  `loop-epic/the-desk-destination-stops-raising-a-nil-3`.

- **D253 — TWO SCOPE ADDITIONS TO #7899 ARE REFUSED, and one of their premises is FALSE.**
  `components.ex:1199` is NOT an unguarded third site: it sits inside `<%= if item.icon do %>` (the `plugin_link`
  anchor) and is nil-safe by construction — its only exposure is an unknown *binary*, a class D232 already owns.
  All three dynamic `item.icon` sites existed at the PR's merge base `453ee749a`, so it is not drift. And
  `spd-bl-plugin-link-aria-current` is already OPEN at priority 3 with its own description citing **D245** as a
  deliberate wave-18 decision not to spend a slice; riding it in #7899's successor would contradict D245 and expand a
  diff an independent reviewer was asked to judge. **One precision gap in the builder's census is recorded rather than
  fixed**: C9(3) omits `nav.ex:427` (`tab[:icon] || "file"`) and `components.ex:1154` (`pane[:icon] || "file"`) — both
  nil-safe, so no defect, but the census is not exhaustive as claimed and those two are exactly where a truthy
  non-binary slips through.

- **D254 — `origin/main` IS RED ON `doc-gates`, THE CAUSE IS WAVE 18'S OWN #7897, AND THE FIX IS TO HARDEN THE
  DETECTOR — NOT TO ANNOTATE.** `scripts/studio-literal-check.sh:92`'s `LITERAL` regex reads the HTML numeric entity
  `&#160;` at `components.ex:1769` as a 3-digit hex colour (`&#xa0;` does not match — `x` is not hex). Blame:
  `88ec6fb8b (#7897)`. **The blast radius is far larger than one red**: the step is
  `Studio literal-color gate (blocking)` at `doc-gates.yml:388` with no `continue-on-error`, and on run
  `30511684123` the **14 steps after it were SKIPPED — including 7 further BLOCKING gates** (studio-link-lint,
  web-literal-check, go-literal-check, the code-comment citation guard, tenant fail-open read baseline, preview-env
  isolation, PortableDoc render-parity completeness, scaffy anchor-drift) plus all 5 tripwire self-tests. Seven
  blocking gates have not run on main since #7897 merged, and no wave-19 builder can distinguish their own red from
  the standing one on any of the eight. **The annotation path is REFUTED BY MUTATION and is the WEAKENING option**:
  `lit-allow-next-line` exempts the ENTIRE LINE, and with it in place a genuine `#ff0000` appended to that same line
  reported **PASS**. The hardened form `(?<!&)#(?:…)` caught that identical mutant and named it, still catches injected
  `#abc` / `hsl(210 40% 50%)` / `color:#ff0000`, and stops matching only an `&`-prefixed hex run, which cannot be a
  working colour in any scanned surface. It also fixes a LATENT CLASS, not an instance: `sheet_grid.ex` carries six
  numeric entities (`&#9664 &#9654 &#10697 &#9679 &#9662 &#9662`) that escape only by digit-count luck, and any future
  3- or 6-digit typographic entity reds the gate again. Part E is unmoved either way and this is STRUCTURAL, not
  lucky: `design/exemptions.json` ledgers 9 paths and `components.ex` is not one of them, so five injected colour
  literals moved Part E by `740 → 740`, every row delta 0.

- **D255 — the detector edit OBLIGES a `--selftest`, because `studio-literal-check.sh` is the only one of the three
  literal gates without one.** `go-literal-check.sh --selftest` and `studio-link-lint.sh --selftest` both run as CI
  tripwire steps (`doc-gates.yml:434`, `:404`); the Studio gate has none. Since this fix EDITS THE DETECTOR, that
  asymmetry becomes load-bearing: nothing automated would catch a future edit that blinds the `LITERAL` regex.
  `go-literal-check.sh:59-103` is directly copyable and is the only durable form of the mutation proof. **And evidence
  for this gate must quote the scanned-file COUNT (372 today; the charter's historical figure of 367 is stale), never
  just the word PASS** — `ROOT` derives from `dirname $0`, so a relocated copy prints
  `PASS — 0 Studio chrome file(s) scanned` and exits 0.

- **D256 — D235 HALF-HOLDS, and the half that holds is the half that matters.** Re-derived as a RENDER, not a trace:
  a `session` persisted through the real Studio create path (`Handlers.Fields.new_document` →
  `Shared.seed_new_doc_content("session")` → `%{"blocks" => []}`) and mounted authenticated shows, at
  `BARKPARK_PAPER_CANVAS=1`, **318 visible characters** carrying the named sentence at `paper_editor.ex:238-239`
  verbatim plus the Add-block form and a `0 words · 0 blocks` footer. So D221's "second blank" is REFUTED on its
  render half at the prod default, and a fourth seam there would be vacuous work on a passing screen — the wish's
  constraint 2 is answered by citation, not by a slice. **At `BARKPARK_PAPER_CANVAS=0` the same document renders ZERO
  visible characters** and `data-test-id="paper-unrenderable-notice"` is absent from the ENTIRE page: `read_blocks([])`
  returns a list ⇒ `paper_block_mode` true ⇒ the arm at `components.ex:253` wins and `:279`'s `blank_body?` is never
  evaluated, so **#7897's notice is structurally unreachable for any blocks-list document**. The flag-OFF arm also
  loses the shell's `aria-label="Editing <slug>"`. **This is a DECISION, not a build**: `BARKPARK_PAPER_CANVAS` is
  set NOWHERE on either live host — absent from `/opt/barkpark/.env`, absent from all of `/etc/systemd/system/`, and
  absent from the environ of BOTH running BEAMs on BOTH boxes (guerrilla `157.180.90.121` pids 2468576/2489148; prod
  `89.167.28.206` pids 1980542/2095796; both serving `/api/schemas` 200) — and `paper_canvas_enabled?/0` reads
  `nil -> true`. The wordless arm is reachable only from `System.put_env` inside the suite. Building a named state
  there is exactly the `paper.ex:701` mistake D222 spent a ruling avoiding. **The guard that makes this decision
  falsifiable ships anyway**: a test asserting the flag-OFF body is non-empty would red the moment an operator exports
  `BARKPARK_PAPER_CANVAS=0`, and that is filed.

- **D257 — WAVE 18'S SHIPPED WAY OUT DOES NOT GET YOU OUT, BOTH WAYS, AND THE REPAIR BUTTON IS A THREE-STAGE TRAP.**
  Measured on a blockless-seeded paper through a real `live/2` mount. **Stage A**: the write LANDS
  (`blocks=[paragraph]`, `save_status="Auto-saved"`) but `paper_pane_op/2`'s `{:ok,_}` arm calls only
  `sync_paper_edit_doc/1`, which assigns `paper_doc` and NOTHING ELSE (`shared/paper.ex:567-574`), so
  `paper_block_mode` stays FALSE and the notice re-renders; the writer's own broadcast cannot save it because
  `Handlers.Lifecycle.paper_block/2` returns `{:noreply, socket}` on `frame[:sender] == self()`
  (`lifecycle.ex:71-73`). **Stage B, unpredicted and the sharp part**: the block write ALWAYS mints
  `body_html = "<p></p>"` (`block_ops.ex:366-368` → `put_body_html/2`), so `html_backed_body` flips true,
  `repairable` flips FALSE, **the repair button VANISHES after one press**, and the reason text flips to the
  HTML-backed variant which now asserts "…was stored as saved HTML that renders nothing a reader can see … the body
  cannot be started from here" — FALSE about a document that gained a real block list 200ms ago. **A named state
  that lies is worse than a blank.** **Stage C**: the write path stays open behind the vanished button — replaying
  `paper-add-block` appends a SECOND empty paragraph, notice still present, editor still absent. Net: the document is
  PERMANENTLY TRAPPED with zero working ways out after one press of the control wave 18 shipped as the way out.
  **And the second way out is a 404 for every viewer**: the emitted href is `/d/production/studio/paper`,
  `route_info` returns `:error` and a real `get/2` returns **404**, because `studio_paper_view/1` never declares
  `attr(:scope_prefix, …)` and its sole call site (`components.ex:1268-1296`) never passes it — even though
  `rebuild_panes` already carries `scope_prefix` in the socket and `@scope_prefix` is used 130 lines away at `:1143`.
  Two independent causes: the missing thread, AND a wrong fallback grammar (`Paths.studio_path("", …)` yields the
  unroutable `/d/ds/studio/paper`; the routable flat form is `Paths.flat_root(ds) <> "/paper"`).

- **D258 — the repair fix is the ASSIGN-ONLY mode re-derive PLUS the stream fill; `refetch_paper/1` is NOT a safe
  drop-in and the naive assign-only variant would paint a NEW blank.** Wired into `paper_pane_op/2`, `refetch_paper/1`
  breaks two existing tests that drive it with a hand-built `%Socket{}`:
  `** (KeyError) key :lifecycle not found in: %{live_temp: %{}}` from its `stream/3` → `attach_hook`, against a
  clean-main control of `10 tests, 0 failures` on the same two files. The `assign/3`-only re-derive
  (`paper_block_mode = is_list(Projection.read_blocks(content))` + `paper_html` + `paper_rev`, guarded on a mode
  CHANGE) is regression-free at `1500 tests, 0 failures` across `test/barkpark_web/live/studio/` — identical to the
  clean control. **But it carries an UNMEASURED residual, code-derived and named rather than hidden**: under
  `BARKPARK_PAPER_CANVAS=0` it flips `paper_block_mode` true while `:paper_blocks` is still the empty stream
  `setup_paper_view/2` reset (`paper.ex:711`) and `show_editor` is false, so `components.ex:253` renders
  `<article phx-update="stream">` with zero children — a new blank of exactly the class this wave outlaws. **The fix
  therefore re-derives the mode AND fills the stream (refetch_paper's body), with the two hand-built-socket unit
  tests migrated to a real LiveView socket.** Threading `scope_prefix` also scopes the "Open standalone" link at
  `components.ex:171` (a THIRD instance of the same missing-thread class) to `/w/…/p/…/papers/<slug>`, which IS a
  real route, reddening one pinned expectation at
  `studio_live_portable_doc_accessibility_proof_test.exs:175` — a test expectation to update, not a regression.

- **D259 — LANE 2'S ENUMERATION IS AMENDED THREE WAYS, and one of the amendments kills a VACUOUS GREEN.**
  (a) **`draft_only` is DROPPED from the reason enum**: D220's draft-first fetch means a never-published document
  RESOLVES (probe: `editor = %{type: "post"}`, non-nil), so it never reaches the empty branch and the reason cannot
  fire. Ship `not_found`, `no_schema`, `unknown_node`, keeping `nothing_selected` as the distinct default.
  (b) **The derivation needs THREE arms, and arm 1 is a CI trap.** A pristine `mix ecto.create && mix ecto.migrate`
  database — exactly what `elixir.yml:348-349` builds, with no seed step before `mix test` at `:417` — holds **ONE**
  production schema row, `paper`, inserted by migration `20260524120000_move_papers_to_production.exs:151`. Locally
  it holds 37, and those are runtime residue (inserted 2026-07-18 → 2026-07-26; boot registration is OFF in test per
  `config/test.exs:138`). `Content.list_schemas` also returns **ZERO** on any dataset but `"production"`, which is
  the fence's house style for isolated test datasets. So `arm1 == arm2 == 37` locally makes a single `count > 0`
  assertion pass off arm 1 alone and UNABLE to detect a dead arm 2. **Assert each arm separately, and draw criterion
  6's floor membership (`paper, sheet, task, session`) from ARM 2, never from `list_schemas`** — `sheet`, `task` and
  `session` are absent from a pristine DB and would red in CI. (c) **`task` and `listener` are NOT host-bootstrap
  types** — both come from the Tasks *plugin*'s `register_schemas/1` (`plugins/tasks.ex:78-81` →
  `tasks/schema.ex:48`, `:826`) and are in arm 2. The genuinely third arm is exactly ONE type: `tag`, via
  `SchemaBootstrap.init/1` → `TagRegistry.register!/1`, deliberately outside the plugin walk whose `Registry.all()`
  is empty under `config :barkpark, :plugins, []`. State that honest size rather than implying a large third arm.

- **D260 — THE FOUR REASONS ARE NOT DISTINGUISHABLE FROM THE SHELL'S ATTRS, AND THE SEAM D222 ALREADY PRESCRIBED IS
  WHERE THEY BECOME DISTINGUISHABLE.** `Shared.rebuild_panes/1` derives every editor assign from one value
  (`shared.ex:798-801`: `new_schema = editor && editor[:schema]` …), and `PaneBuilder` has **NINE** distinct
  nil-editor producers all returning the same bare `nil` (`pane_builder.ex:255, 304, 378, 382`, four `build_editor`
  arms, the `[]` clause at `:156`) — measured: `not_found == unknown_node == no_schema == nothing_selected == nil`.
  From `@panes` + `@nav_path` they ARE distinguishable, and D222 anticipated this verbatim ("from a NEW assign
  computed where `editor == nil` but `nav_path` named a document"): `nothing_selected` = `nav_path == []`;
  `unknown_node` = 1 pane, `role: :nav`, `selected: "nosuchtype"`; `not_found` = 2 panes, last `role: :list` WITH
  `type_name`; `no_schema` = 2 panes, last is the **…Rest** pane with NO `type_name`. `@nav_path` is already in scope
  at the fill site, so criterion 3 needs no new plumbing. **The reason is computed in `rebuild_panes` from
  `(panes, nav_path)`; `PaneBuilder.build/3`'s 2-tuple is NOT widened** — that costs 36 call-site edits (1 lib, 35
  test, 28 in one file). The fill site is `components.ex:1418` inside `studio_live_shell/1` (`:1018`), not D222's
  `:1283` nor the task's `:1287`; locate by selector. `no_schema`'s real door is a schemaless orphan degrading to a
  non-drillable `:document` node under …Rest (`pane_builder.ex:377-378`); the `"open"` backlinks door RESOLVES the
  same document with `schema: nil` and never reaches the empty branch, so `no_schema` is desk-path-only.
  **D237 HOLDS and is now a hard fixture prohibition**: a `blocks: []` paper resolves with `view: :paper` and never
  reaches `studio_editor_shell` at all, so a guard fixtured that way is a FALSE GREEN — fixture non-resolution
  (missing id, unmatched segment, schemaless orphan), never empty content.

- **D261 — LEG C IS THE INSTRUMENT FOR THE ANCHOR CRITERION, AND THE NAIVE CENSUS IS WRONG THREE WAYS — all three
  caught by execution, not by reading.** (1) **An unnamed beat is silently UNASSERTED, and it is worse than
  "unasserted"**: the self-test loop iterates the EXPECTED keys (`journey.mjs:1713`), so with LEG C failing on
  `/rot/` with five FAIL rows the run still printed `SELF-TEST PASS` and exited 0. The deliverable is therefore a
  **COVERAGE GUARD that walks the PRODUCED keys** and reds on any beat `SELF_TEST_EXPECT` does not name — proven by
  deleting one key: `✗ good/DESK-ROWS/pane-doc-item: the run PRODUCED this beat and SELF_TEST_EXPECT does not name
  it`. Without it every future leg is a decoration by default, and a `HARNESS` abort stops reading as a pass.
  (2) **Snapshot-diff attribution is UNSOUND**: on `/rot/` the DEAD `#item-sheet` reported
  `✓ … panes 1 → 2 · rows 6 → 7` — credited with the PREVIOUS row's answer arriving 900ms later; on `/good/` every
  row reported the previous row's URL. A quiesce fixed the off-by-one and did NOT fix the false green, and cannot:
  measured answer latency runs 1.6s → never-within-15s, so no bounded quiet window is sound. **Attribution must be BY
  IDENTITY** — `aria-current` newly on THIS row, or the URL newly carrying THIS row's own `phx-value-id`; pane/row
  counts are recorded but can never make a beat green alone. (3) **Identity attribution then FABRICATES a dead row for
  every `plugin_link`**: `<a id="plugin-link-…" class="pane-item nav-plugin-entry" href=…>` matches `.pane-item` so
  the census enumerates it, and it has NEITHER `phx-value-id` NOR `aria-current` — proven with a fixture anchor that
  really navigated and was reported DEAD. Anchors attribute to their OWN `href`, and because an anchor row is a real
  document load the census must explicitly RETURN TO THE DESK after one (the next row then needed 2 presses, not 1 —
  a fresh dead mount). Bounding: the per-row cap is SOFT (`poll` checks its cap AFTER the predicate,
  `journey.mjs:196-198`), so a nominal 3.0s cost 6.4–6.9s per row under load; LEG C carries a HARD `LEG_C_BUDGET`
  (default 90s) and rows past it are **PENDING/"UNMEASURED, which is not the same as working"**, never FAIL —
  converting an exhausted runner budget into a dead row fabricates a defect.

- **D262 — LEG B'S ORACLE IS NOW VACUOUS AND WILL REPORT FAIL FOREVER ON A FIXED SCREEN.** `EDITOR_SHAPE`
  (`journey.mjs:754-767`) has NO selector for #7897's notice and scopes `visible_text_chars` to
  `.bp-paper-editor || [data-test-id='studio-editor']` — the notice lives in `main.bp-paper-shell`, so the region is
  null and the count is measured against nothing. Live proof of the contradiction on served `051112568`: the harness
  printed `shell=0 body=0 … visible_text=0 chars — WORDLESSLY BLANK` for a page whose server HTML carries
  `<div class="bp-paper-unrenderable" role="alert" aria-live="assertive"
  data-test-id="paper-unrenderable-notice" data-doc-id="paper-b28358ff271b260e" data-doc-type="paper">` exactly once,
  for BOTH id forms. **So the digest's "notice is structurally unreachable for blocks-list docs" is true and #7897 is
  simultaneously LIVE AND WORKING on the fossil path — LEG B's FAIL is a false negative.** Fixing the oracle rides
  in the same file as LEG C and is part of that slice, not a separate one.

- **D263 — A CLIENT-SIDE PRESS ANSWER IS SHIPPABLE, IT WAS PROVEN L1 ON THE DEPLOYED BUILD, AND ITS CLEAR MESSAGE
  MUST NOT CLAIM SUCCESS.** D225 + D242 close the SERVER route (confirmed at framework level: `channel.ex:911-918` →
  `sync_handle_params_with_live_redirect` replies with the event's own ref, and `finish_handle_params` does not
  blanket-reset, so a naive pending assign would STICK). The CLIENT seam is wide open and precedented: 20 hooks in one
  nonced inline script at `root.html.heex:6115-7500`, `#studio-panes` already mounts `WidthBucket`
  (`components.ex:1053`) whose entire body is a `resize` listener — zero collision — and `csp.ex`'s nonce covers
  inline `<script>` blocks, so no policy change. LiveView reads exactly ONE hook per element (`view.js:995-999`), so
  the shape is EXTEND `WidthBucket.mounted()` with a delegated click listener, not a second hook. **The ordering
  discovery that makes it work**: our listener is on a descendant container, LiveView's is on `window`
  (`live_socket.js:830-833`), so ours fires FIRST — `target.hasAttribute("data-phx-ref-src")` read AT CLICK TIME is
  an exact discriminator for "LiveView is about to discard this press", the same condition as `bindClick`'s own early
  return (`live_socket.js:857-859`), which is the discard mechanism that alone reproduces the owner's report. Three
  branches proven live: honoured press → "Opening…" at dt=0, cleared at dt=125ms via ref-drop, five consecutive
  presses 1009/230/692/1944/850ms all cleared with `pendingStillSet:false`; discarded-in-flight second press → LiveView
  sends NO frame and changes NOTHING while the hook says "Still working on your last press…" and does NOT stamp a
  second pending; real CDP-Offline lost press → the named 8s ceiling fired at dt=8003 with words.
  **THE HARD CONSTRAINT, and it is the most important line in this decision**: pressing `#item-rest` on the deployed
  build ANSWERS (ref drops in 1944ms) and changes nothing — no URL change, `aria-current` stays on `#item-paper`, six
  row texts identical. A ref-drop clear that says "Opened." would report SUCCESS for a dead row — the hook would
  manufacture a NEW lie in place of the old silence. **The clear must be NEUTRAL ("Done") or the hook must verify an
  actual screen change (URL patch or `aria-current` move) before claiming one.** Two obvious mitigations are refuted:
  a connectivity gate at click time cannot see the lost-press class (under real Offline `[data-phx-main]` stayed
  `phx-connected` for OVER 8 SECONDS), and `phx:page-loading-stop` would stick forever because
  `withPageLoading`'s element path calls `onLoadingDone()` only on the ok branch (`view.js:1326`) — the same defect
  the shipped `.phx-click-loading{opacity:.6}` has, which is not merely faint but UNBOUNDED (`PUSH_TIMEOUT=30000`).
  **The live region must render OUTSIDE the LiveView root** or morphdom patches it mid-announce, which means
  `root.html.heex` — so **D16 gives `root.html.heex` to the press-answer slice this round**, and the a11y-residue
  slice that also wants two CSS rules there is deferred to round 2.

- **D264 — LANE 4 SHIPS THE ANNOUNCER AND THE ACCELERATOR STAYS SEPARATE, because the PaneBuilder half of the
  latency is REFUTED.** One Structure-row nav to `["paper"]` costs **25 Repo queries / 8.6–15.4 ms DB / 12.5–28.7 ms
  wall** at 8,400 documents / 42 types, byte-identical across three runs scoped and unscoped, measured on a host at
  load 26–42 (so these are UPPER bounds). `type_census` is **ONE** query, 1.85–2.57ms, 21–25% of DB time, and it is
  NOT a seq scan: `GroupAggregate → Index Scan using documents_type_dataset_index`, `rows=8400`,
  `Buffers: shared hit=788`, `Execution Time: 4.981 ms`. `Content.list_schemas` fires ONCE, not 2–4 (the second
  appears only on a genuine gated miss, which `["paper"]` is not — it is a direct root child; `["nope"]` traces
  `2× Structure.build` and DB doubles to 25.9ms). **The actual dominant cost is a deliberately-disabled memo**:
  `resolve_read_dataset_id/2` fires 7×, six hit the no-project branch → 18 of the 25 queries are tenancy reads, and
  the memo that would collapse them (`write_scope.ex:235-255`) is gated OFF for LiveView ON PURPOSE — worth ~2–4ms.
  **A census TTL cache is ILLEGAL**: `analytics.ex:38-40` documents that totals include DRAFTS so the …Rest counts
  are honest, `rest_child_node/3` renders `"#{type} (#{total})"` verbatim, and a draft-only create immediately
  produced the displayed title `"draftyType (1)"` — any TTL makes a displayed integer wrong after any write, which is
  the lying-surface class this epic keeps closing. So **no query-optimisation slice ships**, D230(2)'s refusal to
  chase host TTFB stands, and the announcer is bound to a SEPARATE filed root-cause slice with the pending answer
  FORBIDDEN from citing latency as an acceptance criterion. Honest bound: only `PaneBuilder.build/3` was profiled —
  not `handle_params` → render → diff → socket encode — so a residual seconds-scale cost could still live there.

- **D265 — THE LANE-4 FLOOR IS REFUSED, NOT MEASURED, AND THE BINARY WAS PURCHASED INSTEAD.** Load never fell below
  8.05 on 10 cores and peaked at **40.81**, with two processes from another session running **10h47m / 602 CPU-minutes
  each**, deliberately spawning 24 busy-loops apiece to stress-reproduce `claude_chat_test.exs:808`. Per
  measure-on-a-quiet-host, no latency number from this wave may be quoted as the floor, and the 10-cold-load
  measurement is FILED, not built. **What WAS purchased is criterion 1, and it is stronger than the ask**: a discarded
  press puts **ZERO `"type":"click"` frames** on `/live/websocket`, reproduced 4/4 with a same-run positive control of
  32/32 answered presses that DID emit one. The source-level reason is at the line:
  `pushWithReply(e,t,i){if(!this.isConnected())return Promise.reject(new Error("no connection"));` and the drop is
  SILENT (`exc=0` on every discarded press). **The frame COUNT is a TRAP and any guard that counts frames will pass on
  a dropped press**: `phx_join` and `WidthBucket`'s own `"type":"hook"` event share the wire, so a discarded press
  reads `live_frames=2`. Match `"type":"click"`, never count. **And `phx-connected` is REFUTED in BOTH directions as
  the discriminator**: `connected_at_press` was false in 31/31 probes and 29 were honoured anyway, while the one probe
  that HAD `phx-loading` is the one dropped — the class is applied post-mount-diff (`view.js:618`), so it is lagging
  and not on the causal path. The desk also looks pressable before the socket joins: `#item-paper` ships in the
  dead-mount HTML, 504,500 bytes in 393ms. **A THIRD failure mode is recorded as UNATTRIBUTED and must not become a
  quoted number**: a 5056–5067ms gap between `readyState="complete"` and a dispatchable press, observed 28 times with
  an 11ms spread that load jitter does not explain, during which in-page truth says the row was present the whole time
  — clicks would be QUEUED, not dropped. It is absent from wave 18's ledger of five and it is the first number to
  re-take on a quiet host.

- **D266 — THE ANCHOR SCOREBOARD AND THE WAVE PLAN ARE MISALIGNED, AND FOUR OF THE FIVE UNMET CRITERIA ARE CLOSABLE
  WITHOUT NEW CODE.** `task-f559f7c508527010` is 1/6. **C1** ("a person can create a document, add a heading and a
  paragraph, and save it") is EXACTLY what wave 18's LEG A 7/7 did, and it is now confirmed on TODAY's build by a
  fourth independent run: `served 051112568 → 051112568, LEG A 7/7 PASS, 46.7s wall, self-clean deleted 1/1`. **C3**'s
  mutation half is satisfied by `--self-test-site good` (7/7, exit 0) versus `rot` (3/7, exit 1), plus the D241 ExUnit
  revert-red. **C2 is REFUTED, not merely unstamped** — its two attempt notes cite "the fix is unmerged" and "nobody
  has looked at the fixed screen", both now FALSE, but the criterion says *an empty paper* and D262 shows the
  instrument that reports on it is vacuous; C2 gets a `--miss` recording the fossil finding, not a stamp. **C4 is
  substantively answered by wave 18's verify phase and blocked only mechanically**: that census recorded rows by
  visible LABEL while the desk serves opaque ids (`item-paper, item-sheet, item-plugin-doclist-75745103,
  plugin-link-…, item-rest`), so nobody can prove the two censuses describe the same rows — lane 3's remaining work
  is one line: record element id AND visible label AND outcome in the same row. **C5 is UNSATISFIABLE AS WRITTEN**
  ("PR merged to main") for a seven-PR report task and must be restated to "every PR this report depends on is merged
  and LIVE on the deployed build, each named by number, proven by `git merge-base --is-ancestor <sha> <served
  commit>`". **AND A LATENT ERASER MUST NOT BE TRIPPED**: `drafts.task-f559f7c508527010` agrees on all six `met`
  flags, is 42 seconds NEWER, and carries ZERO attempts against the published row's three — and
  `claim.work_field_digests.acceptance_criteria` is byte-identical (`753990f590c6aa31`) on both, so the close/stamp
  fence is STRUCTURALLY BLIND and will not 409. **Never publish that draft**; stamp the published row one criterion at
  a time with `--criterion-text`, then read the published perspective back and assert the attempt counts survive.

- **D267 — THE STALE-OPEN MIRROR IS LIVE ON FOUR WAVE-18 TASKS AND IS ONE LEAD ACT FROM TRUE.**
  `spd-w18-fossil-named-state` 9/10, `spd-w18-save-announces` 7/8, `spd-w18-journey-harness` 10/11 and
  `spd-w18-nil-icon-500` 10/11 are all `open` with expired claims and `worker: null`, and each one's single unmet
  criterion is the verbatim "PR merged to main (LEAD closes this criterion)". That criterion is now TRUE for three of
  them (#7897 `88ec6fb8b`, #7898 `bc05b9168`, #7896 `b43c0b41e`, all ancestors of the served commit) and false only
  for #7899. `spd-w18-guard-rings-and-label` is the same shape (#7900 `f1ac08c29` MERGED, task open, claim expired
  04:19Z). Leaving them open makes the board under-report wave 18 and will make wave 19 look like it re-did settled
  work.

- **D268 — THE SHARED CHECKOUT IS POISONED FOR COMMITS AND THE WAVE-19 CHARTER PR IS BRANCHED FROM #7795's HEAD, NOT
  FROM `origin/main`.** Local `main` is **48 ahead / 42 behind** `origin/main`, carrying foreign
  `PPCC2` / `omx(team): merge worker-N` commits from another live session, with 6+ charter `.md` files dirty.
  Committing the charter from HEAD would drag all 48 into the PR. And because #7795 (which carries D234–D250) is still
  OPEN, a wave-19 charter branched from `origin/main` would either lose those decisions or conflict with #7795 when it
  lands — and a conflicted PR silently never runs its workflows. Branching from #7795's head `9ea7344` makes the
  wave-19 PR a strict DESCENDANT: it carries D234–D250 plus D251–D269, merges cleanly whether or not #7795 lands
  first, and if #7795 lands the wave-19 branch is a fast-forward. #7795's required contexts are both green
  (`Elixir gate` success, `PR references an active task` success) and its only reds are the two advisory Vercel
  deploys, so it remains landable independently.

- **D269 — THE DESK-MARKUP SURFACE IS ONE OWNER, NOT FOUR, and that is why three a11y-residue tasks collapse into one
  deferred slice.** Five residue items plus lane 2's fill site all live in
  `api/lib/barkpark_web/live/studio/studio_live/components.ex` and FOUR of them inside `studio_live_shell/1` (`:1018`):
  `focus_on_mount` at `:1097`, the two title-only `.pane-add-btn`s at `:1106`/`:1116` (the `+` at `:1124` DOES carry
  `aria-label`), the `role="tablist"` chips at `:1134-1146`, the `aria-current`-less `plugin_link` at `:1191-1203`,
  and the fill site at `:1418`. Four builders in four worktrees editing one 400-line HEEx sigil is exactly the
  co-scoped-ordered-merges trap this epic has already logged. `spd-w18-share-access-btn-names` is confirmed and
  correctly scoped (the workspace-level pair at `:1346-1367` renders visible text and is properly excluded) and is
  ~20 lines of markup plus ~15 of guard, 28 lines from the chips edit — a separate worktree buys a guaranteed conflict
  for zero isolation. `spd-bl-doc-checkbox-is-an-unfocusable-span` is already ABSORBED by the chips task's criteria
  5/6/7 and is closed on that PR, carrying forward one constraint: the outer `.pane-doc-item` must stay a `<div>`
  because the checkbox is a SIBLING of the row body and a button cannot contain a button. **A MERGED guard already
  waits for this slice and will RED on main until it is finished**: `studio_desk_focus_ring_guard_test.exs:150-166`
  `refute`s that `.bp-desk-chip:focus-visible` and `.bp-doc-checkbox:focus-visible` exist, so adding the rings reds
  main's own guard until the selectors move into `@desk_focus_rings` — that is the guard working, not a regression.
  **`spd-bl-focus-after-select`'s destination IS DECIDED**: the focus target is the `tabindex="-1"` landmark lane 2
  builds on the document surface — NOT the 44px collapsed strip (whose `expand-pane` CLOSES the document) and NOT
  `focus_pane_idx` (structurally unusable at phone, where `pane_columns` is 0). It therefore rides behind lane 2, not
  beside it. `spd-b18-btn-focus-visible-desk-wide` is RE-DEFERRED IN WRITING: its acceptance is a visual pass over the
  `.btn` call sites, which is taste, and Fable is unavailable.

## Roadmap — wave 19 (THE ANSWER CONTRACT)

Six slices build this run; two are deferred to round 2 on real dependencies (`root.html.heex` single ownership per
D16, and a deployed census that would publish a false verdict table before the nil-icon 500 is fixed). Every slice is
a binary the DOM, the server, the router or a gate answers; none cites taste. **All slices are `opus`: Fable is
unavailable and forbidden this wave, so the press-answer slice — which would otherwise take fable on the
visually-designed-surface axis — carries its design constraints written out in D263 instead of a reviewer's eye.**

| # | round | slice | task | model | the binary |
|---|---|---|---|---|---|
| 1 | 1 | The nil-icon 500 lands, with the policy-aware fork | `spd-w19-nil-icon-policy-fork` | opus | three authenticated 500s render; `:raise` raises, `:warn` falls back; suite green |
| 2 | 1 | main stops being red on `doc-gates`, and the detector gets teeth | `spd-w19-literal-gate-entity` | opus | the gate PASSes at 372 files; `--selftest` REDs on a planted literal |
| 3 | 1 | The way out actually gets you out, both ways | `spd-w19-way-out-works` | opus | one press swaps notice→editor; the "back" href returns 200 |
| 4 | 1 | `<:empty_state>` filled — the third seam, registry-derived | `spd-w19-empty-state-seam` | opus | a not-found document names its id, type and reason instead of "Select a document to edit" |
| 5 | 1 | LEG C: the desk-row census instrument, and LEG B stops lying | `spd-w19-legc-census-instrument` | opus | `/good/` green and `/rot/` red per row; an unnamed beat REDS the self-test |
| 6 | 1 | A press answers in words, and never claims a success it did not get | `spd-w19-press-answer-hook` | opus | a press renders a named state at dt≈0 and clears; a dead row is NOT announced as opened |
| 7 | 2 | The deployed census + the verdict table (after 1, 5) | `spd-w19-desk-row-census-run` | opus | every row kind pressed on the deployed build; dead ones named by id AND label |
| 8 | 2 | The desk chips and the nameless buttons answer (after 6) | `spd-w19-desk-chips-and-names` | opus | chips are keyboard-operable and ringed; share/access have accessible names |

**HIGH-FLIP-RISK, named here and in the briefs.** Slice 1's policy judgment: D251 overrides a builder's documented
decision on a diff an independent reviewer was already asked to judge, and a reviewer could reasonably hold that C4
as written means the builder delivered exactly what was asked and the fork is a NEW requirement rather than a
correction — a genuinely independent second reviewer is owed before merge. Slice 4's enumeration-derivation judgment:
D259 kills a vacuous green that passes in CI off a single migration-inserted row, and the three-arm/per-arm-assertion
shape is the whole value of the slice — if a reviewer re-derives only the union count, the defect survives review.
Slice 6's honesty judgment: D263's neutral-clear constraint is what separates an announcer from a new lie, and it is
the single easiest thing for a builder to get wrong in a way that LOOKS correct.

## Wave log — wave 19 (append at Review)

### Wave 2026-07-30 — Wave 19 (THE ANSWER CONTRACT), Review. Grade **A**.

**Round 1 landed whole: six slices, all reviewed, all gate-green, all pushed with PRs.** The two round-2
slices are deferred by design on real dependencies, not by failure.

| slice | final branch | PR | verdict |
|---|---|---|---|
| `spd-w19-nil-icon-policy-fork` | `…the-desk-destination-stops-raising-a-nil-0` | #8070 | The owed debt, paid the stronger way. #7899's whole 504-line diff replayed clean onto `origin/main` plus the reviewer's policy-aware fork, implemented as a mirror-image private pair above the `unknown_icon/3` pair it copies, so the module carries ONE policy concept. All three coupled edits shipped, including a third stale moduledoc place the builder found while editing. **The reviewer settled the builder's own biggest blind spot by RUN: the FULL suite is 27 doctests / 13026 tests / 0 failures — the `:raise` arm reds nothing anywhere in 13k tests.** No reviewer fixes were needed. HIGH-FLIP-RISK stands and an independent second reviewer is still owed: this overrides a builder's documented decision on a diff a reviewer was already asked to judge. |
| `spd-w19-literal-gate-entity` | `…main-stops-being-red-on-doc-gates-an-htm-1-r` | #8071 | main's standing `doc-gates` red fixed at the DETECTOR — a `(?<!&)` lookbehind — with `components.ex:1769` byte-identical and no `lit-allow` anywhere; the annotation path is refuted by mutation. The mandatory `--selftest` ships with a blocking CI tripwire, and all 14 previously-skipped steps were run locally rather than guessed at. **Reviewer fix: a vacuous green REPRODUCED on `origin/main` — a relocated copy of the script derives ROOT from `dirname $0`, scans 0 files and printed `PASS — 0 Studio chrome file(s) scanned` with exit 0.** Closed with a `MIN_CHROME_FILES = 200` floor plus a sixth self-test case that copies `$0` out of the tree and asserts it REDS, mutation-proven at floor 0. |
| `spd-w19-way-out-works` | `…the-way-out-actually-gets-you-out-the-re-2` | #8072 | Both of wave 18's ways out were broken and both are fixed, through a real `live/2` mount on the real fossil shape at BOTH flag values. The repair is the mode re-derive PLUS the stream fill, and the third defect the fix surfaced — the notice arm sharing the STREAMED arm's container id, so the notice would have survived its own repair — is fixed too. The back link is proven as a ROUTE (`route_info/4` + a real 200), never as a string equality against the same `Paths` call the component makes. No reviewer fixes needed. One criterion is a stated DEVIATION, not a pass: glyph count at canvas OFF is 0 by design, so the discriminating assertions were made instead. |
| `spd-w19-empty-state-seam` | `…the-third-seam-a-document-that-does-not--3-r` | #8073 | The declared-and-never-filled slot is filled and the default shrug is unreachable on that path, with the reason derived from `(panes, nav_path)` and `PaneBuilder.build/3` at ZERO diff. **The enumeration is the slice's real value and it is honest: killing arm 2 leaves the union at 38 — a naive union guard stays GREEN — while arm 2's own assertions red with `count=0`.** The `blocks: []` fixture prohibition is honoured and proven positively. **Reviewer fixes: `tabindex="-1"` shipped on the recovery ANCHOR, which bought nothing (an `<a href>` is already programmatically focusable) while removing the ONLY way out from the tab order in the `:no_schema` and `:unknown_node` arms — mouse-only, i.e. the owner's dead control in a new place.** D269 says "the tabindex=-1 LANDMARK", so the `-1` moved onto the `role="alert"` container; mutation-proven both ways, criterion 10 amended via `bp`. Copy fix: `:no_schema` rendered "orphanType names a orphanType". |
| `spd-w19-legc-census-instrument` | `…leg-c-the-desk-row-census-instrument-a-c-4` | #8074 | The coverage guard is the deliverable that matters and it works in both directions — deleting `CENSUS: PASS` from the expectation now reds with "an unnamed beat is silently unasserted, so it can never red and it is a decoration", and on its first run it caught four real defects the beat-level check called PASS. Attribution is by identity, counts reach no decision (structurally: `identityWitness()` is the only producer of a PASS), and the `/rot/` decoy that moves both counts without naming itself is red for it. **LEG B's vacuous oracle is fixed and the reviewer re-observed the difference: `named_state=1[role=alert] region=main.bp-paper-shell visible_text=210 chars · the page SAYS SO BY NAME` where it used to print `WORDLESSLY BLANK`.** No reviewer fixes needed. Budget default is 150s not 90s — a flagged, measured deviation named inside the criterion's own evidence. |
| `spd-w19-press-answer-hook` | `…a-press-answers-in-words-within-a-frame--5-r` | #8075 | A press answers in words within one frame, outside the LiveView root so morphdom cannot patch it mid-announce, riding the existing nonced hook with zero CSP change. **D263's hard case is honoured: words are bound to observed evidence (URL patch / `aria-current` move), and with neither witness the answer is the neutral "Done." — so `#item-rest`, which answers and changes nothing, is never announced as opened.** Two lost-press shapes get words instead of silence, proven on the deployed build with an in-page MutationObserver because a `Runtime.evaluate` on that thread was measuring its own sampler. **Reviewer fixes, both invisible to a browser-only gate: (1) it REDS a merged guard — `editor_panel_containment_test.exs` censuses every `position: fixed` selector in `root.html.heex` and `.bp-press-answer` was unclassified, so this would have gone RED on the required Elixir gate at merge; (2) ZERO `api/test/**` coverage against the wave's own D241, now `press_answer_region_guard_test.exs` — the region in the SERVED html of a real authenticated desk GET, structurally outside the LiveView root, and the three literals that bind the clear to evidence, each with a sabotage control. Mutation-proven: renaming the region id reds 3 of 11.** The reviewer also settled the builder's top risk: the HEEx compiles, `--warnings-as-errors` clean. |

**Cross-slice integration, verified rather than assumed.** All 15 branch pairs merge clean (`git merge-tree`),
and a combined integration branch of all six slices runs **2174 tests, 0 failures** on
`test/barkpark_web/{studio,components,live/studio}/` with `studio-literal-check`, its selftest and
`design/check.mjs` all green. Two slices edit wave 18's leg-A journey test at different lines; they merge.

**What the wave did NOT do, honestly.** The anchor criterion the wish calls "nobody has touched" —
*whatever the Desk Structure buttons do when clicked is verified to do it, or the dead ones are named* —
is still **not answered as a binary on the deployed desk**. Wave 19 built the instrument that can answer
it and proved it can produce a legible per-row table, but `spd-w19-desk-row-census-run` is round 2 by
design: pressing before the nil-icon fork merges would record `/studio/rest` and `/studio/plugins` rows
as DEAD when the cause is a crash this wave already fixed — a published false verdict. That sequencing is
correct and it is also the reason the owner's second complaint survives another wave.

**Ledger.** All six slice tasks in_progress, published, evidence-bearing, correct parent and `wave_paper`,
with only the merge-gated criterion open for the lead — the honest state. Both round-2 tasks untouched at
0/N. Eight builder follow-ups all exist and are published. Reviewer ledger work: criterion 10 of
`spd-w19-empty-state-seam` amended (its stored wording contradicted the shipped landmark placement, with
the original evidence preserved); `pr_url` + `final_branch` stamped on all six; two new findings filed —
`spd-w19r-literal-gate-floor-siblings` (p3: `go-literal-check.sh` and `web-literal-check.sh` carry the
identical relocated-ROOT hole with no floor) and `spd-w19r-live-studio-suite-flake` (p3: two
non-reproducible reds in `test/barkpark_web/live/studio/` across eight runs, and the brief's clean-main
13015/2 control did not reproduce either — a review run measured 13026/0).

**Next wave takes, in this order.** (1) Merge round 1 — `spd-w19-literal-gate-entity` FIRST, because it
unblocks 7 further blocking `doc-gates` steps for everyone else. (2) Dispatch
`spd-w19-desk-row-census-run` the moment `spd-w19-nil-icon-policy-fork` and
`spd-w19-legc-census-instrument` are both ancestors of the served commit — that is the owner's second
complaint, and it is the last binary in the original report still unanswered. (3) Dispatch
`spd-w19-desk-chips-and-names` once `spd-w19-press-answer-hook` merges (it owns `root.html.heex` next
under D16 and a merged guard is already REFUTING the two rings it must add). (4) Then the residue this
wave named and did not take: `task-34d256d198849a98` (p2 — the legacy-HTML body arm still shares the
streamed arm's container id, the same trap one arm over), `spd-w19-click-loading-falls-through` (p2 — an
in-flight row is transparent to hit-testing, so a second press lands on whatever is underneath), and the
`blocks: []` honesty residue D235 named: the sentence still says "This **paper**" to someone editing a
**session**, carries neither the id nor the type, and is painted the same faint grey the owner read as
inert.

## Decisions — `spd-b42` (the DEFAULT-state forced-Georgia shortfall)

- **D270 — `spd-b42`'S ARITHMETIC IS STALE AND ITS TRIM BUYS ZERO PIXELS: THE BINDER OF THE WIDE READING MEASURE
  IS NO LONGER THE DOCK, IT IS A 660px SURFACE CAP THAT ARRIVED FROM ANOTHER EPIC.** The task was filed on
  2026-07-20 against D120's bracketed table (forced Georgia at 18px, probe-derived 11.0469 px/ch, same face:
  **viewport 1280 → content 596px = 53.95ch**, **viewport 1024 → 599px = 54.22ch**, **viewport 700 → 567px =
  51.33ch**) and its brief derived a fix from `content = panel − dock − 2 × --paper-gutter`, i.e. 976 − 300 − 80
  = 596 at viewport 1280. **That model no longer describes the deployed sheet.** On 2026-08-12,
  `pe-w1-reader-editorial-typography` (#11626, `3968dbc16`) landed `max-width: 660px` on `.bp-paper-surface` — a
  deliberate editorial measure of 580px, ~69 characters per line at 18px on the NATIVE face, replacing an
  effective 720px. It is not a pane rule, not an inspector rule, and `wide_geometry_lock_test.exs`'s
  `pane_family?/1` never saw it, so a 16px change to the wide desk's reading measure at viewport 1280 shipped
  green through this epic's own layout lock.

  **MEASURED, NOT ARGUED (two bracketed runs, deployed `8a05efce1055e97549605779462430cf8afc4753`, slot blue,
  `--doc=pds-w23-triage-round-2026-09-06`, 54 of 54 rows, provenance bracket MATCHED, positive control RAN and
  the guard FIRED so the zero is DESK-FIXED-proven rather than a broken check, `xscroll` no in every row).**
  The DEFAULT-state forced-Georgia rows now read: **1440 → 608px = 55.04ch MEET (floor bound)**, **1280 → 580px
  = 52.50ch FAIL**, **1024 → 580px = 52.50ch FAIL**, **900 → 608px = 55.04ch MEET (floor bound)**, **800 →
  580px = 52.50ch FAIL**, **764 → 612px = 55.40ch MEET**, **700 → 567px = 51.33ch FAIL**. Every one of those ch
  figures is forced Georgia at 18px over a same-face `width: 1ch` probe at 11.0469 px/ch; no cross-face
  division anywhere (D83/D86). `surface_max_width_px` reads **660** in every row where the cap binds, and
  `content_px` is a flat **580** at viewport 1440, 1280, 1024, 900 and 800 alike — the tell that the pane, the
  column and the inspector have stopped being the binder at all.

  **THREE CONSEQUENCES, IN ORDER OF WHAT THEY COST.**

  1. **THE TRIM IS REFUSED, BECAUSE IT IS WORTH ZERO PIXELS.** At viewport 1280 the reading column is 676px
     (pane 976 − a 300px dock) and the cap clips the surface to 660px, so trimming the dock to 288px takes the
     column to 688px and the surface stays **660px** — `content_px` stays 580, the ch stays 52.50 and the row
     stays FAIL. Same at viewport 1024: the column is already 679px (pane 720 − the 41px `spd-b29` strip),
     the cap binds, and a 32px strip takes it to 688px with the surface still at 660. A 12px trim of shipped
     inspector chrome and a 9px trim of the strip for **zero reader pixels** is exactly the change D77/D93/D103
     forbid being sold as a measure fix, and D149 refused this trim once already. **This PR therefore ships NO
     dock or strip trim** — a change measured at zero reader pixels is not shipped as a measure fix. Whether the
     trim is refused for good, and what replaces it, is the owner's call (recommendation below).

  2. **THE ONLY MECHANISM IN THE SHEET THAT BEATS THE CAP IS THE PROTECTED FLOOR, AND IT IS UNREACHABLE AT THE
     FAILING WIDTHS.** `min-inline-size: calc(55ch + 2 × var(--paper-gutter))` resolves to 687.63px under
     forced Georgia and OVERRIDES `max-width` (a min beats a max), which is precisely why viewport 1440 and 900
     MEET at 608px while 1280 does not: their reading columns are 836px and 815px, both over the
     `@container content (min-width: 720px)` gate, while 1280's is 676px and 1024's is 679px. So the lever at
     viewport 1280 is not "trim the dock to 288" but **"get the reading column to 720px", i.e. a dock of 256px
     or less** — a 44px trim, which is the move D149 refused outright as an epic-criterion-2 breach when it was
     put at 260px. **At viewport 1024 the gate can never fire at all: the pane IS 720px, so the column is
     720 − (any in-flow inspector) and is below the gate for every inspector wider than zero.** Lowering the
     720px gate instead is refused by measurement, not taste: at a 676px column the floor would resolve to
     687.63px inside it and overflow by 11.6px, which is D85's measured defect and D125's ruling.

  3. **THE FAILING SET IS BIGGER THAN THE TASK SAYS, AND ONE OF ITS MEMBERS IS OWNED BY NOBODY.** Of D107's
     seven desktop rows, forced Georgia now fails at **FOUR** — 1280, 1024, 800 and 700 — where D120 recorded
     three. **Viewport 800 is new since D120 and is a direct consequence of the cap**: its reading
     column is 715px (pane 756 − the 41px strip), comfortably over 660, so the surface used to fill the column
     and now stops at the cap. DERIVED, not measured, and labelled as such: 715 − 80 = 635px of content =
     57.48ch forced Georgia at 18px before the cap, against the 580px = 52.50ch the instrument reads today. Separately, the NATIVE
     face now fails at viewport 640 (507px = 50.70ch); 640 is already an owned shortfall (D100 as amended by
     D106), but it was owned as a Georgia-and-Source-Serif problem, and the native face joining it is new
     information the shortfall accounting should carry.

  **WHAT THE REAL QUESTION IS, STATED SO THE SUCCESSOR CANNOT DRIFT OFF IT.** Two shipped bars are in direct
  conflict at every width where the cap binds. `pe-w1`'s editorial bar says the measure is 580px because ~69
  CPL at 18px is the readable band on the native face. This epic's bar says the measure is ≥55ch for the widest
  forced face, which for Georgia at 18px is 607.58px of content — a 687.58px surface, 27.58px wider than the
  cap allows. **Both cannot hold. No inspector width, gutter or container gate resolves it, because the binder
  is neither the inspector nor the gutter.** The three shapes that could are each a ruling rather than a trim:
  raise the cap for the paper EDIT surface only (and part company with the public reader that
  `measure_parity_test.exs` exists to keep it identical to); make the bar face-relative (which is D107's
  gerrymandering unless it is fixed before the table is seen); or accept the shortfall for wide serif faces at
  the widths where the editorial cap binds, on the record, the way viewport 640 is accepted.

  **RECOMMENDATION — NOT A RULING. Lane-authored decisions are proposed here and ratified by the owner
  (owner-queue item 41, 2026-09-06); a lane may not both propose and ratify.** What the measurement establishes
  as FACT: no in-flow inspector width makes viewport 1280 or 1024 reach 55ch under forced Georgia while the 660px
  cap stands, and viewport 700 remains arithmetically foreclosed for a second, independent reason (its column is
  615px, under the cap, so the D126 in-flow ceiling of 0.42px is still the binder there). So `spd-b42`'s
  criteria 1 and 2 are not closable by any change inside its own scope. **lead-studio recommends** that the owner
  rule the third shape above: forced Georgia at 18px in the DEFAULT state becomes an owned shortfall at viewport
  1280, 1024, 800 and 700, on the same footing as viewport 640 (D100/D106) — because pe-w1 already chose 580px as
  the editorial measure, and the other two shapes either break the measure parity that `measure_parity_test.exs`
  exists to keep or are D107's gerrymander. Until the owner rules, `spd-b42` is BLOCKED ON OWNER, its claim held. What the slice ships instead is this decision plus the missing tripwire:
  `.bp-paper-surface`'s `max-width` and `--paper-gutter` are now pinned by value in
  `wide_geometry_lock_test.exs`, mutation-proven (660 → 720 reds the lock naming the geometry, restore greens
  it), so the next cross-epic change to the wide desk's reading measure reds this epic's own lock instead of
  passing it. **The re-measure command, for anyone who wants to check this rather than believe it:**
  `node scripts/studio-desk-measure.mjs --sha=$(ssh root@157.180.90.121 'cd /opt/barkpark && git rev-parse HEAD') --doc=pds-w23-triage-round-2026-09-06 --positive-control --out <path>`.
  Note that the committed `DEFAULT_DOC` (`studio-space-priority-desk-browser-2026-07-19`) has aged off the
  100-row Papers window and now fails the drill loudly, exactly as D97 designed it to.

## spd-b8 amendment (THE SHARED `.editor-panel` FLOOR IS MEASURED, 2026-09-06) — D271

*Numbered D271, not D270: D270 is already allocated by open draft PR #16382, so this amendment starts after it
to avoid a collision.*

- **D271 — THE BARE `.editor-panel` 560px FLOOR IS ACCEPTED FOR SHEETS, GRAPH AND MEDIA. It is measured, it
  clips nothing, and the one overrun it participates in is a LIVE SCROLLER owned by `.pane-column`, not by the
  floor.** Measured on deployed guerrilla at served sha `17f4adba1c5948be250050aabfadab79ef3b4432` (pre and post
  bracket identical; footer `Barkpark v0.2.26.2058 · 17f4adba1`), Chromium 147.0.7727.15, three surfaces × four
  viewports × 900 tall, navigation-only, raw JSON at
  `scripts/measurements/spd-b8-editor-panel-blast-radius-2026-09-06.json`.

  | surface | 1024 | 900 | 720 | 640 |
  |---|---|---|---|---|
  | Sheets (`.editor-panel.sheet-editor`, `sheet/sheet-798717`) | 720px · 1024/1024 · **FITS** | 856px · 900/900 · **FITS** | 676px · 720/720 · **FITS** | 596px · 640/640 · **FITS** |
  | Graph (`.editor-panel.graph-editor`, `graph/<paper id>`) | 764px · 1024/1024 · **FITS** | 856px · 900/900 · **FITS** | 676px · 720/720 · **FITS** | 596px · 640/640 · **FITS** |
  | Media (`.editor-panel.media-explorer-panel`, `mediaAsset`) | 560px · 1024/1024 · **FITS** | 560px · 900/900 · **FITS** | 560px · **788/720** · **OVERRUNS** | 560px · **788/640** · **OVERRUNS** |

  (cells read *panel `getBoundingClientRect().width` · `.pane-layout` scrollWidth/clientWidth · verdict*.
  `min-width: 560px`, `position: relative` computed on all twelve; `container-type` computed `inline-size` on
  graph and media and `normal` on the sheet — D33/D42's carve-out is live on the deployed build.)

  **THE ROW'S STATED MECHANISM IS STALE AND THIS IS THE HEADLINE.** `spd-b8` was filed in July against
  `.pane-layout { overflow: hidden }`, from which it derived "the sum of pane floors exceeding the viewport makes
  the desk CLIP horizontally rather than crush, and content can become unreachable". On origin/main the rule is
  **`.pane-layout { display: flex; flex: 1; overflow-x: auto; overflow-y: hidden; }`** — a scroller on the
  overrun axis. Measured, not inferred: `overflowX` computes to `auto`; `scrollLeft` moves from 0 to the full
  overrun (68px at 720, 148px at 640); and after that scroll the panel's right edge sits at **exactly**
  `innerWidth`. Nothing is unreachable at any measured width. The valve is the "it costs nothing when nothing
  overflows" clause the layout comment already claims, and this is the first measurement that exercises it.

  **WHAT THE MEDIA OVERRUN ACTUALLY IS.** 44 (collapsed strip) + 44 (collapsed strip) + 140
  (`.pane-column--last.bp-doc-list`, at the bottom of `min-width: clamp(140px, 18vw, 260px)`) + 560
  (`.editor-panel`, pinned at exactly its floor) = 788, invariant at both 720 and 640 and reproduced on two cold
  loads each. Sheets and Graph escape it for a structural reason, not a lucky one: opening a document collapses
  the list panes to ONE 44px strip, so their row is `44 + panel` and the panel takes the remainder — 596px at
  640, comfortably above its own floor. Media has no document open, so the desk keeps a full list column, and it
  is that column plus two strips — 228px of `.pane-column` chrome — that the viewport cannot hold beside a 560px
  panel. **Scoping `min-width` off `.media-explorer-panel` would remove the overrun** (560 → 492 at 720) and is
  therefore the tempting move; it is refused, because the floor is not the party at fault and removing it buys a
  narrower media panel at every width in exchange for making one selector two.

  **SO THE RESIDUE IS FILED WHERE IT BELONGS, AND IT IS NOT THIS TASK'S FILE.** The open question left standing
  is whether the narrow bucket should keep a 140px list column beside a floored content pane at all — a
  `.pane-column` / bucket-policy question (its phone sibling, `html[data-width-bucket="phone"] .pane-layout:has(>
  .editor-panel) .pane-column { display: none }`, already answers it below 640 by hiding the column outright).
  `spd-b6-sub500-phone-proof` is the neighbouring row. Nothing in `root.html.heex` changes under D271 and no
  colour gate is spent.

  **NON-VACUITY.** The instrument's verdict is three independent witnesses (`.pane-layout` scrollWidth >
  clientWidth; any child's right edge > innerWidth; `documentElement.scrollWidth` > innerWidth), and it is not a
  detector that can only say FITS: it printed CLIPS on 2 of 12 cells, on the surface with the widest chrome, at
  the two narrowest widths, twice each from cold. `view_edit_parity_test.exs` + `studio_components_pane_test.exs`
  are 52 tests / 0 failures on the branch, which is true by construction — D271 changes no CSS.

  **D29 AND D42's CENSUS LINE NUMBERS ARE ALL STALE; the roster is not.** Derived from origin/main rather than
  from the row: paper `studio_live/components.ex:194` (row said `:98`), media `:1627` (`:797`), beta `:1692`
  (`:861`), classic `studio_components/editor.ex:552` (`:367`), graph `live/studio/graph_view.ex:113` (correct),
  sheet `live/studio/sheet_grid.ex:2589` (`:2478`). Six roots, exactly as D42 corrected D29 — cite the roster by
  name, never by the line.

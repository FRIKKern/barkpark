# Studio Space-Priority Desk (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Wave Session Card** (epic COMPLETE, #3981) — is
> preserved verbatim at `.claude/workflows/bp-wave-session-card-charter.md`. Do NOT read this
> file for wave-session-card history. This slot is now the memory of the
> **Studio Space-Priority Desk** epic.
>
> Epic anchor: bp task **`studio-space-priority-desk`** (published, guerrilla).
> Wave 1 paper: **`studio-responsive-desk-wave-2026-07-19`** (style=article).
> Decided 2026-07-19.

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

## Roadmap

Wave 1 (this wave — 7 slices; ROUNDS ARE LAW, a slice never dispatches beside its unmerged dependency):

| # | Slice | Task | Round | Model | Size |
|---|---|---|---|---|---|
| 1 | CSS space-priority foundation — the crush fix; sole owner of root.html.heex this round | `spd-s1-css-foundation` | 1 | fable | large |
| 2 | Width-bucket server seam, INERT (handle_event + caps + optional hook attr; no call-site activation) | `spd-s2-bucket-server-seam` | 1 | opus | medium |
| 3 | Pane anatomy roles + display-state table (pane_builder.ex + its test only) | `spd-s3-pane-anatomy-roles` | 1 | fable | medium |
| 4 | Reconciliation — activate the hook, stamp data-roles, server strips at narrow/phone | `spd-s4-bucket-reconciliation` | 2 (after 1,2,3) | fable | large |
| 5 | Desk chrome restyle — type-scale consumption + Plex Mono + secondary-pane/sheet-toolbar responsiveness | `spd-s5-desk-restyle` | 3 (after 4) | opus | medium |
| 6 | Phone drill + breadcrumb component (CSS pre-provisioned by S1) | `spd-s6-phone-drill-breadcrumb` | 3 (after 4) | opus | medium |
| 7 | View↔edit parity guard + docs/cards/studio.md + wide-bucket regression pins | `spd-s7-parity-guard-card` | 4 (after 5,6) | opus | small |

Backlog (filed as published children, future waves): `spd-b1-pane-state-persistence` (localStorage theme-pattern for bucket/inspector memory) · `spd-b2-docs-anchors-prune-fix` (find -prune for node_modules/.omx) · `spd-b3-dead-admin-shell-css` (root.html.heex:534–583 dead .sidebar/.main block) · `spd-b4-stamp-2532-criteria` (bookkeeping repair, evidence = commit 961e76d6f) · `spd-b5-navshell-wave2-triage` (3 unfiled nav-shell residue items — different epic, verify still-real) · `spd-b6-sub500-phone-proof` (true <500px verification; tooling floor blocked it).

## Wave log

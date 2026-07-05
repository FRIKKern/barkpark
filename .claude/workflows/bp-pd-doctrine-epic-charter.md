# Epic charter — the PortableDoc editor rebrand (pd-doctrine)

**Mission.** The Beta (continuous-canvas) PortableDoc editor becomes THE editor, governed by the
five doctrine rules. Design truth: paper `portabledoc-doctrine` on guerrilla (LIVE roadmap board,
`label proj:pd-doctrine`). Session memory: `portabledoc-content-first-doctrine`.

## The five rules (all user-ratified 2026-07-05 — do not relitigate)
1. **Forced initial blocks** — a doc type declares its opening set (block 0 title, block 1 featured image), seeded as forced initialValue.
2. **Locked placement** — mandated blocks can't be deleted/moved; enforced in editor AND server.
3. **100% render parity** — every element in the canvas looks exactly as the frontend render; same producer, byte for byte.
4. **The sidebar test** — reads as article → body block; otherwise → the WordPress-style right sidebar (publish state, slug, taxonomies, relations, trade metadata).
5. **No modes — ever** — opening a document IS the editor; affordances are hover tooltips + right-click menus (chrome around content, never transforming it). The /papers reader stays the public render.

## Decisions (settled)
- **D1 editor-first**: enforcement lands in the Beta canvas (schema-v2 generalization later). t0 closed.
- **D2 Beta→main**: the canvas is promoted to the main editor; legacy retire-or-keep is t11's call to CHART, not make.
- **D3 additive enforcement**: papers with no locked blocks save byte-identically; migration only via t5 (dry-run first).
- **D4 server-authoritative locks**: upsert_paper validates directly (bypasses hooks!); Bulldocs before_save covers mutate; Patch rejects remove/move of locked + strips locked/role from patch-block. SHIPPED #1161.
- **D5 resolve-for-display (new, wave 1)**: canvas live-preview of task/query blocks resolves snapshots for DISPLAY only — the diff baseline the editor saves against stays the UNresolved source blocks. Resolved rows must never persist into the doc via a save (would freeze stale snapshots and break D3 byte-stability).
- **D6 parity closes toward View (new, wave 1)**: View↔Edit divergences close by aligning the EDIT surface to the published render, not vice versa, unless View is objectively broken — published papers' bytes stay stable (render_test.exs is the tripwire).
- **D7 cutover shape (new, wave 2)**: the mainline cutover = flip `BARKPARK_PAPER_CANVAS` default to TRUE with an explicit env opt-out (`=0/false` keeps the old behavior); the legacy per-block editor is KEPT reachable behind the opt-out this wave (retirement is a wave-3 execution once the cutover soaks). t11's audit may AMEND this with evidence (a found blocker gap flips the default back until fixed) but does not relitigate the direction — Beta→main is D2.
- **D8 fleet paints server-side (new, wave 2)**: canvas node views for non-prose fleet blocks NEVER hand-mirror markup — display HTML is produced by `Render.render_block/2` (the reader's emitter) server-side and painted into read-only atoms; the block itself rides verbatim (bpBlock) and stays the save baseline (D5's display/baseline split, generalized).

## Reconciliation 2026-07-05 (architect wave 2)
- **Wave 1 is MERGED to main as #1169** (`57e3be94`, "Rebrander wave 1: locks felt, parity gated, featured placeholder, live preview, WP sidebar") + integration fix `e921c186` (sidebar relations resolve TITLES via `Content.reference_title`, never raw ids — binding pattern for all future sidebar work). Suite baseline is now **7207/0**.
- Task tree on guerrilla reconciled: t2/w3(`au-w5-paper-parity-w3`)/t13/t9/t6 all `done` (closed task-native). OPEN: t8 (p1), t10 (p2), t12 (p1), t11 (p1), t5 (p3), t7 (p3) + the m1/m2/m3 rollups.
- Landed-outside-the-loop check: #1170 (Studio login on core auth) and #1171 (pulse channels) touch Studio/api but not the paper editor — rebase noise only, no doctrine impact. Nothing pd-doctrine landed outside the loop.
- Verified in tree at origin/main: the w3 tripwire lives at `api/test/barkpark/portable_doc/render/view_edit_parity_test.exs` (mutation-verified); the t9 channel is `bp:task-preview` (`shared/paper.ex:116-129` push, `root.html.heex:~4423-4451` hook, legacy consumer `components/paper_editor.ex:571+` via `Render.render_block(block, %{style: :article})` + `TaskResolver.apply_preview/2`); the canvas bpOpaque verbatim-carry mechanism is `canvas/run-convert.js` + the read-only-atom pattern in `canvas/embed-node.js`; reader fleet emitters are `render/components.ex` (`tasks_html`, `task_detail_html`, `cards_html`, `pipeline_html`, `notes_html`, `status_legend_html`, `task_board_html`, `roadmap_html`) + `render/figures.ex` (`diagram_html`, `asciicast_html`) + `render/forms.ex` (`form_html`).
- Canvas is still flag-gated: `PaperCanvas.paper_canvas_enabled?/0` reads `BARKPARK_PAPER_CANVAS`, **default FALSE** (`paper_canvas.ex:138-146`); the mode toggle is `editor_mode_toggle/1` (`components/paper_editor.ex:35`, call sites `components.ex:795/836`). These are t11's cutover-charting + t12's execution surface.
- t5 caution from wave 1 ("only after human live-polish") is superseded by explicit user direction: t5 goes in wave 2 **dry-run-first** (D3); the APPLY against prod data remains a human step.

## Reconciliation 2026-07-05 (architect wave 1)
- Task tree on guerrilla matches this charter exactly: DONE t0/t1/t3/t4 + p-resolve-seam (#1161, `3f570979`). No pd-doctrine work landed outside the loop since. `rebrand/pd-doctrine-m1` branch is merged history.
- Server enforcement verified in tree: `api/lib/barkpark/portable_doc/patch.ex:192-274` (locked remove/move rejection + locked/role strip), `api/lib/barkpark/content/papers/template.ex` (seed + shape), `api/lib/barkpark/plugins/bulldocs.ex` before_save, `query_controller.ex:157-188` (?resolve=tasks seam).
- Canvas JS has ZERO `locked` handling today (bp-attrs.js, run-convert.js grep-clean) — t2 is genuinely unbuilt; the legacy per-block editor's delete/move buttons (paper_editor.ex:246/448 region) are unguarded.
- ⚠️ **The external `bp-paper-editor-parity-charter.md` is GONE from this checkout** (untracked file, wiped by a concurrent worktree reset). The w3 head (`au-w5-paper-parity-w3`) is now driven by the `view-edit-parity` workflow (`.claude/workflows/view-edit-parity.workflow.js`) + a fresh audit run — its slice below is self-contained by design.
- Media picker already exists in the canvas host (`paper_canvas.ex`) — t13 binds it, does not build one.

## Wave 1 (cut 2026-07-05) — integration order 1→5
1. **t2 canvas locks** (large) — the felt half of D4; finishes the M1 lock journey.
2. **au-w5-paper-parity-w3 render unification** (large) — rule 3's engine; unblocks the t8→t10/t12 spine.
3. **t13 featured placeholder** (medium) — every new paper currently opens looking damaged post-#1161; pure perfecting.
4. **t9 live-preview** (medium) — finishes the journey #1161's seam was built for. Respect D5.
5. **t6 WP sidebar** (large) — rule 4 lands in the mainline canvas (D2).

DEFERRED to wave 2: **t11** mainline gap-audit (audit is honest only AFTER wave 1's surface exists), **t5** migrate (locks UX must be proven first, D3 dry-run), **t7** classify (feeds sidebar v2). Then the unblocked spine: t8 fleet-in-canvas → t10 parity gate + t12 no-modes.

### Wave-1 mechanics (all builders)
- The paper-editor bundle is COMMITTED (`api/priv/static/assets/bp-paper-editor.bundle.js` + web mirror). NEVER hand-merge it: on rebase/conflict, take source, re-run `npm run build` (+ `build:web` if the mirror changed), then `scripts/paper-editor-mirror-check.sh`.
- JS slices extend the `npm test` script in `api/assets/paper-editor/package.json` with their new `__*.test.mjs`.
- DB-backed LiveView tests (paper_canvas_test.exs etc.) run locally where Postgres is up; CI's full suite (7119/0 baseline) is authoritative at PR time. Targeted `CC=clang mix test <file>` is the per-slice gate.
- Visual verify against a REAL local server per memory `local-portable-testing`; `scripts/status-manifest-check.sh` untouched-green.

## Wave 2 (cut 2026-07-05) — staged build, binding order
Three parallel heads from main, then two sequential heads on the integration branch:
1. **t8 fleet-in-canvas** (large, FIRST) — every fleet block paints in the canvas via the ONE reader producer; the epic's highest-leverage head, seeded by t9's channel + w3's tripwire.
2. **t5 corpus migration** (medium, parallel) — dry-run-first backfill mix task (D3); apply stays human-gated.
3. **t11 mainline gap-audit + debt fixes** (medium, parallel) — the honest audit (wave-1 surface exists) + the three pre-loaded gaps fixed; charts the cutover t12 executes.
4. **t10 canvas⇄reader parity gate** (medium, AFTER t8 lands on the integration branch) — CI-blocking byte-parity, proven on injected drift.
5. **t12 kill-the-modes** (large, LAST, after t8+t10+t11) — canvas default-on, mode toggle retired, affordances = hover + context-menu chrome. If t8 slips, t12 is cut from the wave, not rushed.

DEFERRED to wave 3: **t7** field classification (p3, feeds sidebar-v2; D1 says schema-v2 generalization comes later — it must not ride the cutover wave), the paper-aware publish lifecycle (needs a draft model), slash-menu warm-rust polish, legacy-editor retirement execution (t11 charts it this wave).

### Wave-2 mechanics (all builders)
- Everything in "Wave-1 mechanics" still binds. Suite baseline **7207/0**.
- Bundle conflicts: source-union then **REBUILD** (`npm run build` + `build:web` if the mirror changed) + `node --check` on the built bundle — a wave-1 union nested one slice's code inside another's unclosed function. Then `scripts/paper-editor-mirror-check.sh`.
- Sidebar/relations UI must resolve display strings via `Content.reference_title`, never print raw ids.
- Close tasks task-native (`bp task close <id> <worker> <epoch>`, CAS); NEVER `bp doc patch`+publish a task with edges.
- Verify against a REAL local server per memory `local-portable-testing`; canvas work needs `BARKPARK_PAPER_CANVAS=1`.

## State
DONE: t0 decision · t1 template+seed · t3 gate · t4 title-derive · p-resolve-seam (#1161) · **wave 1: t2 locks-felt · w3 render-unification+tripwire · t13 featured placeholder · t9 live preview · t6 WP sidebar (#1169, merged `57e3be94`)**.
IN WAVE 2: t8 · t5 · t11 · t10 · t12 (staged: t8/t5/t11 parallel → t10 → t12).
WAVE 3 POOL: t7 classify · publish lifecycle (unfiled → file it) · legacy retirement execution.

## Working rules for the loop
- Claim via `bp task next <worker>` / `bp task claim`; close CAS with the epoch. Tasks: `label proj:pd-doctrine`.
- **NEVER `bp doc patch`+publish a task that has edges** without re-adding them via `POST /v1/tasks/edges` (patch+publish severs edges — proven twice).
- Quality gates per slice: full `mix test` (7119 baseline) at integration, `--warnings-as-errors` (the prod gate compiles what test doesn't), aesthetics guard for UI, `scripts/status-manifest-check.sh` untouched-green.
- JS work: both editors must honor locks (canvas diff-ops AND per-block editor buttons paper_editor.ex:246/448); `locked` needs the BpAttrs round-trip (bp-attrs.js:39) before any canvas UX.
- Verify visually against a REAL local Barkpark (memory `local-portable-testing`): boot `BARKPARK_SEED_PROFILE=clean PHX_SERVER=true mix phx.server`, create a paper via curl-localhost, check /papers/:slug + Studio.
- PRs: small slices, fail-before tests, additive by construction; merge when real gates green (Format/Vercel are advisory reds).
- Model note (2026-07-04): Fable hit its monthly spend cap — prefer Opus for delegated stages.

## Definition of epic-done
All `proj:pd-doctrine` tasks done; a new paper in Studio opens as a document (locked title + featured
placeholder), edits in ONE modeless surface where every fleet block renders exactly as /papers does,
metadata lives in the right sidebar, and CI gates canvas⇄reader parity.

## t11 mainline gap-audit — the cutover chart (recorded 2026-07-06)

Audit paper (guerrilla, design_doc `portabledoc-doctrine`): **`pdd-t11-mainline-gap-audit`**
(`/papers/pdd-t11-mainline-gap-audit`) — the full Beta-canvas vs legacy per-block editor gap
matrix (feature parity · doc-type coverage · a11y · perf). Honest now that wave-1's surface
exists. Slice branch: `loop-epic/t11-mainline-gap-audit-the-three-pre-loa-2`.

**The three pre-loaded debt gaps — FIXED in the t11 slice** (gated: paper-editor `npm test` +
`view_edit_parity_test.exs` + `studio_view_task_resolve_test.exs`):
- **Source-mode locked-title displacement** → `clampLockedPrefix` (`canvas/source-realign.js`),
  wired into `_exitSourceMode` (`canvas/index.js`). The source→rich exit now reconstructs the
  locked template prefix VERBATIM client-side (the felt half of D4, twin of `locks.js`), so a
  delete/move/re-text of the locked title in markdown source no longer diverges the client from
  the server veto (`{:locked_block, id, op}`). Additive (D3). Test: `src/__source_locked.test.mjs`.
- **View-mode task blocks unresolved** → `paper_stream_items/3` (`shared/paper.ex`) now routes
  through `Content.Papers.resolve_tasks_in_blocks/2` — the SAME `/papers` reader producer
  (rule 3), session-tenant-scoped, fail-closed, DISPLAY-ONLY (D5: the save baseline stays the
  unresolved paper_doc blocks). Test: `studio_view_task_resolve_test.exs`.
- **Two-right-panels UX** → the `bp-backlinks-panel` aside is retired; inbound references fold
  into the WP sidebar's **Relations** section (`components.ex` — outbound References + Used-by /
  Linked / Derived, resolved titles via `reference_title`, never raw ids). One calm right column.

**D7 cutover CALL — CONFIRMED (sequenced, NOT relitigated).** No BLOCKER gap was found that
flips the default back (the D7 amend trigger); the three debt gaps are fixed and locks are
server-authoritative at every layer incl. the new source-mode clamp. Confirm the direction:
flip `BARKPARK_PAPER_CANVAS` default → TRUE with an explicit env opt-out (`=0/false` keeps the
per-block path). **Sequencing is already the charter's order, not a new decision:** t12 executes
the flip AFTER t8 (fleet-in-canvas) + t10 (parity gate) land — with the flag on today, non-prose
fleet blocks render as boundary widgets (t9 preview), not fully-painted in-canvas node views,
which clears the honest-affordance bar but NOT the "every fleet block renders exactly as /papers"
epic-done bar. **Prose papers are cutover-ready now; full-fleet cutover waits on t8+t10.**

**Legacy retire-or-keep CALL — KEEP behind the opt-out this wave; wave-3 retirement is NARROW.**
What wave-3 retirement removes: the `editor_mode` toggle (`components/paper_editor.ex:35`, call
sites in `components.ex`) + the flag-OFF PROSE branch. It does NOT remove `edit_block` — that
renders the non-prose boundary widgets in BOTH modes (task/sheet/diagram/image), so it is shared
infrastructure, not legacy. Two preconditions before retiring: (a) t8 lands so non-prose fleet
blocks paint fully in-canvas; (b) the per-document Beta editor gains canvas eligibility (today
`canvas_eligible=true` only for the paper view — non-paper block types stay per-block) OR the
non-paper block-editing story is settled. Execution stays wave 3 — this audit only charts it.

## Wave log

### Wave 2026-07-05 (wave 1) — 5/5 green, all perfecter-passed
**Landed.** The full wave-1 cut, every slice above the bar after polish:
- **t2 canvas locks** — locked/role round-trip (bp-attrs/run-convert, D3-additive), locks.js filterTransaction veto, diff-guard never emits remove/move for locked ids, legacy editor hides move/delete on locked blocks. Perfecter closed a doctrine hole the builder missed: Enter-in-locked-title displaced the template — now vetoed at 3 layers (canvas locked-tail veto, **patch.ex NEW rejection class `{:locked_block, id, op}` for DISPLACING ops**, LiveView clamps). Any future slice inserting into a locked prefix via raw ops gets rejected — that's the doctrine working.
- **w3 render unification** — parity found already single-sourced (`--bp-*` tokens in paper-surface.css; :article emits bare semantic HTML). Residual cross-file drift closed with a one-producer TRIPWIRE test (`view_edit_parity_test.exs`, mutation-verified) — the seed t8/t10 build the CI gate on. Zero unintentional divergences; matrix at `docs/specs/2026-07-05-view-edit-parity-matrix.html`. View bytes untouched (D3/D6 held).
- **t13 featured placeholder** — reader skips empty-src images (no broken `<img src="">` on /papers); canvas + per-block editor both show a calm evergreen ghost frame that IS the picker affordance (rule 5). Perfecter closed the flagship gap: the SEEDED featured block (run boundary) now works today on both editors.
- **t9 live-preview** — TaskResolver.preview/2 non-destructive twin, session-tenant-scoped fail-closed, separate push channel; D5 proven (untouched save = zero ops) in both gated files. Perfecter made it VISIBLE: previews paint via the reader's own Render producer server-side (rule-3 parity, no JS bundle change). WC `applyTaskPreviews` deliberately unbuilt — it is t8's node-view work; the channel is its documented forward twin.
- **t6 WP sidebar** — five sections (Publish/Slug/Context/Labels/Relations), pure `{:doc_field,…}` seam structurally incapable of emitting block ops, a11y-correct, collapse without reflow. Perfecter defused a paper-bricking bug: publish/unpublish rode the drafts-twin events (papers are published-in-place) — Publish is now honest read-only state. **A paper-aware publish lifecycle is REAL unfiled work (needs a papers draft model).**

**Integration orders (binding).** Merge 1→5 (t2 → w3 → t13 → t9 → t6); expect small conflicts in paper_editor.ex + root.html.heex between t2/t13; on ANY bundle conflict take source + rebuild + mirror-check. Full 7119 suite at PR time is authoritative (every slice gated on borrowed/targeted builds). Post-merge: close `au-w5-paper-parity-w3` on guerrilla (open/unclaimed — deliberately not mutated from worktrees); fix the stale styles.css:143 comment in the next slice that rebuilds the bundle.

**Debt ledger (accumulated, wave-scoped).**
- ZERO live-browser verification this wave (profile lock) — the human live-polish pass is now load-bearing: Enter in locked title (BARKPARK_PAPER_CANVAS=1) must no-op calmly; ghost frame renders + picker opens; sidebar toggles.
- Fold into **t11**: canvas markdown SOURCE mode (Mod-Shift-m) can locally displace the locked title (server rejects, view diverges until reload); Studio read-only VIEW mode renders query task blocks unresolved (paper_stream_items never task-resolves); two-right-panels UX (backlinks aside + sidebar ~580px) — fold backlinks into Relations.
- File NEW: paper-aware publish lifecycle (t5 or sidebar-v2 — needs a draft model, not a button); slash-menu warm-rust palette polish (chrome inconsistency, separate small task).
- For **t8**: standalone embeds lose list bottom-margin (no .bp-paper-surface ancestor — noted in the matrix); container-NESTED task blocks get pushed rows but no painted preview (top-level only); build ON the t9 channel, not around it.

**Stalled.** Nothing. No relitigation needed; D1–D6 all held under adversarial polish.

**Next wave should take.** (1) INTEGRATE FIRST — this wave is worthless unmerged and the branches interlock. (2) **t8 fleet-in-canvas** — now unblocked by w3, and BOTH t9's channel and w3's tripwire were explicitly built as its seeds; it's the highest-leverage head. (3) **t11 mainline audit** — now honest (wave-1 surface exists) and pre-loaded with three found gaps. (4) t5 migrate only after the human live-polish confirms the locks FEEL right (its stated gate). t7 classify stays pooled behind sidebar-v2.

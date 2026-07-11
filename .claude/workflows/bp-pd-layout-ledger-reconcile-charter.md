# PD-Layout-Engine + Doctrine Drafts — Ledger Reconcile (epic charter)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **parity-page** at `bp-parity-page-charter.md` (plus the
> earlier occupants it names in its own header note). This file is now the memory of the
> **pd-layout-engine ledger-reconcile** epic.

Epic anchor: bp task slug **`pd-layout-engine`** (published, GitHub #1425). Wave Paper:
`pd-layout-engine-wave-2026-07-11`. Server: guerrilla. This is a **LEDGER wave**: the
deliverable is truth — three stale-open ready anchors (`pd-layout-engine`,
`drafts.pd-doctrine`, `drafts.pdd-m1`) closed on file:line + merged-PR + fresh-test-run
evidence, every honest remainder parked as a live, well-named task. One small code slice
exists only because verification proved two doc-notes false and one tripwire narrower
than its claim.

## Vision

None of the three anchors appear in `bp task ready`; each closed criterion carries
evidence a stranger can re-run. The layout engine epic closes on its four merged waves
(#1435/#1445/#1454/#1461) with its two open children honestly resolved — one
superseded-by-decision with a named open successor, one answered by a per-block-type
arbiter with the cards divergence ratified. The content-first doctrine tree stops being a
false-done pocket: every rebrander hollow-close is retro-stamped with HEAD-verified
evidence (REOPEN NOTHING that code proves), the corpus-APPLY human gate stays open with
an executable recipe, and the three genuine coverage gaps live as filed backlog, not
silence.

## Operational facts (builders read FIRST)

- **`bp task stamp` is NOT live on guerrilla** (route 404s; task-79d71bc80427f0e4 awaits
  merge). Stamping mechanics this wave:
  - OPEN task you are closing: `bp task claim <id> <worker>` → `bp task close <id>
    <worker> <epoch> done "<reason>" --set 'criteria:=[{"index":N,"met":true,"evidence":"…","criterion":"<text-guard>"}]'`
    — index-merge rides the same rev-CAS write (close.ex:276-365). Supply the
    `criterion` text-guard on every entry.
  - ALREADY-DONE task you are retro-stamping: `bp task get <id> -o json` → rewrite the
    FULL acceptance_criteria array → `bp doc patch task <doc_id> --set
    'acceptance_criteria:=[…full array…]'` → `bp doc publish task <bare-id> --yes`.
    Patch replaces the whole flat field — never send a partial array.
- **Publish-collapse every drafts.\* task you touch**: close/patch writes in place on the
  draft row (fine for ready-derivation), but publish afterward so no future edit forks a
  twin. Publish copies + deletes the draft; it never touches lifecycle_status.
- **Unmet criteria never block a close** (soft warning only) — an honest met:false with
  an explaining evidence string is the CORRECT ledger state for a waived/residue
  criterion.
- **No layer gates an epic close on open children** (verified: close.ex, board.ex,
  fence.ex, CI). Honesty is the only guardrail — the epic anchor is closed by the LEAD at
  Review, never by a builder slice.
- **Go toolchain**: always `CC=clang` (the bare `cc` is a Claude wrapper, not clang).
- **Never run `mix barkpark.paper.doctrine_backfill --apply`** anywhere this wave — the
  corpus APPLY is a human gate (drafts.pdd-t5-migrate), parked with a recipe.

## Decisions

- **D1 — pd-le-dashboard-pipeline-blocks closes as SUPERSEDED-BY-DECISION, not done.**
  Slate-2 charter D21 (pipeline `layout:{mode:"flow"}` Go-only, additive, honest
  degrade) and D22 (dashboard Go-only, "NO Elixir twin… an ACCEPTED, conscious
  ⊆-projection divergence") consciously override the task's cross-surface criterion;
  PR #2110 MERGED 2026-07-10. The cross-surface residue is NOT dropped: open successor
  **tr-agg-resolver-wave** (parent pdrender-block-parity, GH #2113) already scopes
  dashboard+gauge Elixir twins — cite it in the close, file nothing new (dedup law).
  GH issue #1455 gets closed/annotated in the same slice.
- **D2 — The fullbleed arbiter is answered PER-BLOCK-TYPE; the binary premise is
  refuted.** At HEAD the web reader: cards STRETCH (portable-doc.tsx:925 grid
  sm:grid-cols-2, 1fr tracks), notes container-stretch/content-left (:881/:885/:889),
  pipeline LEFT-PACKS (:985 flex-wrap flex-start). One verdict for the triplet does not
  exist; pd-le-compose-fullbleed-parity closes on the matrix, not the coin flip.
- **D3 — Cards' web-grid-stretch vs TUI-left-pack is RATIFIED as an accepted per-surface
  divergence.** Same family as gauge-list/dashboard/pipeline-flow (TUI canvas-economy
  left-pack; slate-2 precedent). No Path-A right-padding, no boxFixtures entry for
  cards. Mandatory correction rides with the ratification: align_test.go:20-30 must stop
  claiming "notes/cards/pipeline LEFT-PACK" as reader-parity (false for cards), and
  dashboard.go:20 must cite **D22**, not the loose "charter-D12".
- **D4 — Widen the divide-formula tripwire to the module root.** Verification proved
  TestNoInlineDivideFormulaOutsideSolver greps only internal/pdrender (go test cwd), so
  "one solver repo-wide" was manually-asserted, not CI-enforced. The test now walks up to
  go.mod and greps from there; the epic-close evidence may then honestly say repo-wide.
- **D5 — Retro-stamp doctrine (sp-w2/storm-t8 precedent): verify-at-HEAD, stamp, REOPEN
  NOTHING code proves.** The rebrander bulk-close (2026-07-05/06) left 10+ done tasks at
  0/N with empty evidence in both draft and published copies; the code is the arbiter and
  it confirms the work. Every stamp carries file:line + PR/sha + a fresh test-run count.
- **D6 — pdd-t14's calm no-op is RATIFIED over caret-lands-in-body.** The real PM Plugin
  (index.js:531-556 filterTransaction) drops the tx — no flash, no divergence — which is
  cleaner than the task's imagined caret move. Crit "caret lands in the body" stamps met
  with this ratification cited; the jsdom mounted-editor test gap (crit 3) stays honestly
  met:false with residue task **pdd-t14-jsdom-residue** filed (the editorProp-ignored
  regression class is uncatchable by pure predicates).
- **D7 — pdd-t15's C2 is AMENDED to name the real gate.** The t10 corpus is fleet-only by
  design; title/h1 parity is pinned by render_test.exs:772 (bare `<h1>`) +
  view_edit_parity_test.exs:57 (h1 in @parity_elements) + the byte-equal render proof.
  Amend the criterion text in the same doc-patch that stamps it; never stamp met:true
  over the obsolete literal wording.
- **D8 — pdd-t12's a11y criterion stays met:false; browser eyeball is a parked human
  gate.** Helpers are unit-proven (__one_surface.test.mjs) but the node-view DOM wiring
  is browser-only on the PR's own manual-verify list. Residue task
  **pdd-t12-a11y-eyeball** carries the recipe.
- **D9 — pdd-m1 closes on its 3 proven criteria; drafts.pdd-t5-migrate stays OPEN as the
  corpus-APPLY human gate.** 111 prod papers: 2 conforming / 90 unmigrated / 19
  html-exempt; the DoctrineBackfill mix task exists, tested, never run. The park patches
  the 6-step recipe (dry-run → human review → staging snapshot+idempotence → --apply →
  visual sample → stamp+publish) into the task. An open child under a done parent is
  correct here — ready-derivation has no parent gate.
- **D10 — pd-doctrine's "Doctrine paper reflects shipped reality" is read as the
  ledger-mirror it is.** The portabledoc-doctrine paper renders the live task tree; once
  this wave's stamps land, the tree reads true (M1 done with t5 visibly open = shipped
  reality). Evidence cites this reading explicitly.
- **D11 — Cross-epic evidence is cited by task id + PR sha, never assumed by nesting.**
  #2283 (p-quality-gate children) and #2446 (pd-everything-editable) prove doctrine
  criteria but live under sibling epics.
- **D12 — The epic anchor `pd-layout-engine` is closed by the LEAD at Review**, after S1
  merges and S2 lands: close reason cites W1-W4 PRs (#1435/#1445/#1454/#1461, all
  MERGED), the repo-wide tripwire (post-D4), fresh `go test ./internal/pdrender/...
  -count=1` PASS, and the two children's resolution (D1-D3) with successor link.
- **D13 — t16's Writer-path pin gap is backlog, not a blocker.** Core helpers are tested
  (template_test.exs:16-17/42/25-27/78); no test drives POST /v1/data/mutate → Writer
  create end-to-end. Residue task **pdd-t16-writer-path-test** filed; t16 stamps 3/3 with
  the pin gap named in the evidence string.

## Roadmap

### Wave 1 (this wave — 5 slices, integration-ordered)

1. **pdle-r1-pdrender-doc-truth** (small, opus, code+PR) — dashboard.go D22 citation,
   align_test.go doc-note reframe per D2/D3, tripwire widened to module root per D4.
   Gate: `CC=clang go build ./... && CC=clang go vet ./internal/pdrender/ && CC=clang go
   test ./internal/pdrender/ -count=1`.
2. **pdle-r2-le-children-close** (medium, opus, ledger) — D1 supersede-close of
   dashboard-pipeline-blocks (+ GH #1455 sync), D2/D3 matrix-close of
   compose-fullbleed-parity citing the r1 PR. Epic itself NOT closed (D12).
3. **pdle-r3-m1-closeout** (medium, opus, ledger) — retro-stamp t1/t2/t3/t4/t13, stamp +
   close + publish-collapse drafts.pdd-m1, park t5 with the D9 recipe.
4. **pdle-r4-doctrine-stamps** (large, opus, ledger) — retro-stamp the ten hollow-done
   pd-doctrine children (t6/t9/t10/t11/t12/t14/t15/t16/t17/t19) per D5-D8/D13 with
   paste-ready evidence; publish-collapse every draft.
5. **pdle-r5-doctrine-anchor-close** (medium, fable, ledger) — stamp m2/m3 rollups from
   child evidence, then stamp + close + publish-collapse drafts.pd-doctrine per D10/D11.
   Runs after r3+r4.

Then (lead, at Review): close `pd-layout-engine` per D12; verify all three anchors gone
from `bp task ready`; wave log.

### Backlog (filed as published children of pd-doctrine — residue under its anchor)

- **pdd-t14-jsdom-residue** (P2) — jsdom mounted-editor test for the locked-Enter veto;
  pins the D6 calm no-op (the editorProp-silently-ignored regression class needs a
  mounted editor to catch).
- **pdd-t12-a11y-eyeball** (P2, human gate) — live browser keyboard/screen-reader pass
  over the one-surface canvas (tabindex/role/aria + Enter/Space→NodeSelection wiring is
  on the shipping PR's manual-verify list; unit helpers alone can't prove it).
- **pdd-t16-writer-path-test** (P3) — integration test: POST /v1/data/mutate create with
  blocks:[] → template seeded + title derived (writer.ex:191 regression currently
  uncaught by the suite).

## Wave log

### Wave 2026-07-11 (wave 1 — the flagship ships)

**Landed.** All three slices done, gates green at review:

- **pp-w1-author-flagship** — `gui-tui-parity-page` LIVE on guerrilla at rev 1
  (style=article, 66 top-level / 70 total blocks), all 8 D2 sections + colophon, zero
  screenshots, zero code changes. Published ONCE; offline-first verification made the
  skeleton final so the patch+ifRev law was never needed post-publish. Reviewer re-ran
  every gate leg independently (cmd/dump 80→424 lines side-by-side / 40→675 stacked,
  pass2 harness 19/19 types, reader HTML with grid + 6-role legend, bp paper view 80)
  and confirmed the offline blocks JSON is byte-identical to the published paper.
  Branch `…-0-r` carries only the empty marker commit + this wave-log entry.
- **pp-w1-ledger-truth** — parity-state ws-012 item 0 corrected (diff vs pre-write
  snapshot proves exactly one block, one item changed), the three false-done stubs
  (p-retheme, p-live-plans, p-white-ladder) carry the honest annotation, probe paper
  unpublished (bp doc get → not_found). Note: the reader serves HTTP 200 soft-404s for
  unpublished papers — existence gates must use the API signal (filed:
  pp-b-existence-gate-signal).
- **pp-w1-canvas-verify** — stalled in-window (flagship published after this builder
  finished; the paper 404'd for them), RESOLVED AT REVIEW: reviewer regenerated the
  live-blocks JSON, repointed the driver at the review worktree, fixed a real bug —
  the harness's `bp-ready` wait is racy (element upgrades+mounts empty synchronously
  during bundle-script execution, before the inline listener attaches; the blocks
  setter applies content via `setContent(…,false)` without re-firing) — and ran the
  gate green: clean mount, full 66-id round-trip, one patch-block op keyed gtp-002,
  `.bp-section__grid` with `--bp-tracks:2`, 11 readonly chips as expected offline
  degrade. Race documented on pp-b-canvas-harness-generic.

**Lead closes on merge:** the LEAD-CLOSES criterion on each of the three slice tasks;
parity-s1…s7 + parity-s8-goal against sections of the live paper; then the anchor
`parity-page` with https://guerrilla.barkpark.cloud/papers/gui-tui-parity-page as
evidence (anchor c1/c2/c3/c4 are all now provable from this wave's stamps).

**Next wave should take:** nothing is owed on the wish itself — it is fulfilled once
the lead closes. Highest-leverage follow-ons, already filed: pp-b-branch-protection
(P2 — required-named freshness check was bypassable), the resolver arc named by the
page's own §8 (query-driven task blocks → realtime — the "plans are living documents"
goal), pp-b-dump-harness + pp-b-canvas-harness-generic (turn this wave's two proven
/tmp verification drivers into documented tooling), and the stale parity-state item
"terminal renderer knows none of the 11 new blocks — unreadable in the TUI" which
pdrender parity (14/14, #1357) has since falsified — next ledger-truth pass should
correct it the same snapshot-diff way ws-012 was.

### Wave 2026-07-11 (pd-layout-engine ledger reconcile — wave 1, reviewed)

**Landed.** Four of five slices green through review; grade A-. Paper:
`pd-layout-engine-wave-2026-07-11` (debrief appended, published).

- **pdle-r1-pdrender-doc-truth** — merge `loop-epic/pdrender-doc-truth-d22-citation-per-bloc-0-r`
  (NOT the base branch): D22 citation + per-block reader-parity matrix (all
  portable-doc.tsx anchors re-verified at HEAD) + module-root divide-formula
  tripwire with decoy-proven teeth. Reviewer hardening rides the -r branch
  (0be051d1): grep failures red the test instead of passing vacuously; an
  owner-liveness self-check kills silent pattern drift. Gate green post-fix.
- **pdle-r2-le-children-close** — half landed: dashboard-pipeline-blocks closed
  SUPERSEDED-BY-DECISION (D1; GH #1455 CLOSED, successor #2113 OPEN — both
  reviewer-confirmed). The fullbleed matrix-close is honestly BLOCKED on the r1
  merge (its idx2 cites the r1 doc-note); everything else is pre-proven in the
  task's evidence. Re-dispatch or lead-complete after merge.
- **pdle-r3/r4/r5 (ledger)** — pdd-m1 done 3/3 + t5-migrate parked with the
  corpus-APPLY recipe (--apply never run); the ten pd-doctrine hollow-done
  children retro-stamped honestly (t14 2/3, t19 2/3, t12 3/4 stay honest-false
  with residue tasks); m2/m3 rolled up 3/3; drafts.pd-doctrine closed done and
  collapsed. Reviewer re-ran every gate leg (39/0, 50/0, 146/0, npm pass, bp
  legs verbatim) and spot-checked six file:line anchors at HEAD — all true.
- **Reviewer ledger fixes:** publish-collapsed the two leftover draft twins
  drafts.pdd-t7-classify + drafts.pdd-t8-canvas; review_note stamped on pdle-r1
  naming the -r merge target.

**Lead closes on merge:** r1 c4 → fullbleed matrix-close (r2 idx2/idx3) → r2
close → epic anchor `pd-layout-engine` per D12 (cite #1435/#1445/#1454/#1461 +
post-D4 module-root tripwire + fresh go test PASS) → slice LEAD criteria
(r3 c5, r4 c4, r5 c3). Open by design: pdd-t5-migrate (corpus-APPLY human
gate), pdd-t12-a11y-eyeball (human), pdd-t14-jsdom-residue,
pdd-t16-writer-path-test. Stale charter note found: `bp task stamp` IS live on
guerrilla — drop the operational-facts bullet next slot edit.

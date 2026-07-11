# Parity Page — recreate cfd0e75b in PortableDoc (parity-page epic charter)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **pd-everything-editable** at
> `bp-pd-everything-editable-charter.md` (plus the earlier occupants it names in its own
> header note). This file is now the memory of the **parity-page** epic.

Epic anchor: bp task slug **`parity-page`** ("Recreate the GUI↔TUI parity page (cfd0e75b)
fully in PortableDoc", published, priority 1, GitHub #1438). Wave Paper:
`parity-page-wave-2026-07-11`. Server: guerrilla. Flagship deliverable slug:
**`gui-tui-parity-page`**.

## Vision

One flagship PortableDoc paper on guerrilla, `gui-tui-parity-page`, that IS the GUI↔TUI
parity page: eight sections mirroring the design-language spec, built entirely from
native blocks — glyph rows as real shared-vocabulary text, board/detail side-by-sides as
`section{layout:{mode:grid,tracks:2}}` grids of terminal/card/task blocks, the momentum
header as the task-list's own derived tally, the white ladder as the zero-input
`status-legend` block. Zero screenshots, zero code changes (none were needed — every
block type renders on web + TUI + WASM today). The page doesn't depict parity; it renders
through the very parity spine it documents. The 7 `parity-sN` children (+ new
`parity-s8-goal`) close against SECTIONS of the one paper; the anchor closes with the
live URL as evidence.

## Non-negotiable operational facts (builders read FIRST)

- **Write law (proven live on `parity-page-probe-w1`):** `bp bulldocs publish <slug> -f
  paper.json -s guerrilla --yes` ONCE with the full block skeleton (full replace, NO
  CAS — never republish mid-build). Every subsequent edit: `bp doc get paper <slug> -s
  guerrilla -o json` → read the top-level INTEGER `rev` (NOT the `_rev` hash) → `bp
  bulldocs patch <slug> -f ops.json -s guerrilla --yes` where ops.json embeds
  `"ifRev": <int>` in the body head. `--if-rev` alongside `-f` is silently dropped
  (run.go:445). Stale ifRev 412s and applies nothing — that is correct behavior, re-read
  and retry. Op vocabulary: append-block, insert-after, patch-block, replace-block,
  remove-block, move-block.
- **Env gotcha:** `BARKPARK_URL` in this environment points at api.barkpark.cloud —
  pass `-s guerrilla` explicitly on EVERY bp command.
- **Proven block shapes:** lift verbatim from `/tmp/probe_paper.json` +
  `/tmp/probe_ops.json` (wave-1 probe) and the live `portabledoc-showcase` paper
  (101 blocks; e.g. card slots fd-049, terminal fd-059, section grid fd-013, stat
  fd-071). Paragraphs are `content:[{type:text,value:…}]` — never a bare `text` key.
- **Momentum header is NOT a block type:** it renders automatically inside any
  task-list whose static `snapshot` is non-empty (components.ex:57,643). Never author a
  separate stat block for it. TUI shows one static spinner frame — caption it as a
  static snapshot, never claim animation.
- **status-legend takes ZERO input** (`{"type":"status-legend"}`) — rows derive from
  design/status-manifest.json via StatusVocab. Never hand-type glyphs.
- **task-list / task-board: static author-pinned `snapshot` rows** (offline-safe,
  proven). Row shape: {title,status,priority,worker,criteria:{met,total},phase}. Valid
  statuses: open, ready, in_progress, blocked, done, closed, cancelled.
- **roadmap: NEVER a live query** — the resolver emits rows without left/width, so a
  query-driven roadmap degrades to overlapping full-width bars. Author static rows with
  `left`/`width` (0–100).
- **Side-by-side = `{"type":"section","layout":{"mode":"grid","tracks":2},"blocks":[…]}`**
  — golden-proven side-by-side at 80 cols (cellW=39), degrades to stack at 40. Children
  nest under `blocks` (decode.go maps it to Children for the TUI too).
- **Verification is offline-first, never a dev server:**
  - TUI: `CC=/usr/bin/clang go run ./internal/pdrender/cmd/dump <blocks.json> 80` — a
    pure local-file renderer (no HTTP path exists in it), proven to reproduce the
    section-grid goldens from a script. Also run at 40 to see the stack degrade.
  - Reader HTML: `cd api && SHOWCASE_BLOCKS=<blocks.json> OUT_DIR=<dir> mix run
    --no-start scripts/pass2_audit_harness.exs` (harness dedups first-block-per-type —
    run variants in separate files if that matters).
  - Live (after publish): `curl -s https://guerrilla.barkpark.cloud/papers/<slug>` +
    `bp paper view <slug> --width 80 -s guerrilla`. Do NOT assert exact
    `bp-section__grid` counts in reader HTML (known benign doubling).
  - Edit canvas: forked static harness (pattern:
    `api/assets/paper-editor/src/canvas/__harness.html`, `BP_PAPER_EDITOR_NO_INJECT`,
    relative bundle paths) + headless Chromium; playwright is vendored at
    `js/node_modules/.pnpm/playwright@1.59.1/node_modules/playwright` (avoids the
    shared chrome-devtools-MCP profile contention). Fleet blocks (status-legend,
    task-*) degrade to `bp-canvas-readonly-chip` offline — documented, expected, not
    a failure.
- **Bundle freshness:** the staleness found during verification (post-#2398) was paid
  mid-wave by the pd-everything-editable epic — PR **#2446** (merged 2026-07-11,
  1ac1122b regenerates api/priv/static/assets/bp-paper-editor.*). Canvas verification
  runs `git log -1 -- api/priv/static/assets/bp-paper-editor.bundle.js` vs
  `git log -1 -- api/assets/paper-editor/src/` FIRST; if src is newer again, rebuild in
  a WORKTREE for harness use only (never `npm run build` in the main checkout).
- **Main checkout stays on main.** Any code/asset commit goes through a worktree + PR
  with `Task: <id>` in the body; api-assets changes wait for the Elixir Test gate. Pure
  paper authoring is PR-less — the live render is the evidence.

## Decisions

- **D1 — BUILD the page; "already exists" does not apply.** cfd0e75b is an unrecoverable
  external Claude Artifact (not a git object; not in the 108-paper corpus); the
  parity-state gap-map's "Recreate the page — done" is a FALSE POSITIVE meaning the 11
  component block TYPES shipped. Three surveyors + corpus enumeration converged.
- **D2 — One flagship paper, slug `gui-tui-parity-page`, style=article, EIGHT sections.**
  Spec→section map: §0+§2→s1(alive), §1→s2(glyphs), §3 body→s3(board), §3
  detail→s4(detail), §3 TUI rules→s5(tui), §5→s6(quality), §6→s7(identical), and orphan
  §4 "THE GOAL — plans are living documents" becomes section 8 (new child
  `parity-s8-goal`) — it is the spec's most consequential section and deserves a home.
  Orphan §7 (open decisions) + the cross-reference footer fold into a short closing
  colophon block, no child: decision-log meta, not durable design content.
- **D3 — Source of truth = `.claude/workflows/bp-task-design-language-spec.md`; spec wins
  on divergence.** The artifact's own HTML is unrecoverable; the "§15" citation in
  s4/components.ex proves the spec is a compressed retelling — artifact-only extras are
  gone and are NOT owed.
- **D4 — Anchor criteria amended to match reality.** c1 → sections of the ONE paper
  (8 sections); c2 → native blocks matching the spec (one-paper reading — zero
  component-leaf grandchildren exist and none are owed); c3 → the real proven spine
  (guerrilla reader + real pdrender TUI at 80 cols + edit-canvas mount + golden gates
  green) replacing the unsourced "9 renderers" count, which is defined nowhere.
- **D5 — s4 owns the nav-stack/detail-model content; s5 references it** (the two briefs
  overlapped; one owner prevents drift inside the paper itself).
- **D6 — Offline-first verification with cmd/dump is CANON.** The "no offline TUI path"
  claim was refuted by running the tool; author → verify offline (cmd/dump 80+40, pass2
  harness) → publish → verify live (curl + bp paper view) → canvas leg.
- **D7 — The planned bundle-regen slice was DROPPED at Decide:** while this wave
  verified the staleness, the pd-everything-editable epic shipped the regen in #2446
  (merged before our builders flew). Never build what a sibling epic already merged;
  the canvas slice re-checks freshness instead of assuming.
- **D8 — Ledger truth is wave work:** reword parity-state's ws-012 "Recreate the page"
  card to cite the real recreation; annotate the three false-done stub tasks
  (p-retheme, p-live-plans, p-white-ladder — real capabilities, zero-evidence docs);
  delete the wave-1 scratch paper `parity-page-probe-w1` after verification.
- **D9 — Out of scope:** Next.js demo ignores section layout (already filed, cd-11); any
  code change (no render gap found across all 20 needed block types); the momentum
  spinner animating in TUI (pre-authorized static frame).
- **D10 — Backlog filed, not built:** cmd/dump harness wiring, branch-protection audit
  (#2398 merged over a red required-named freshness check — the debt got paid by #2446
  but the gate-bypass hazard remains), generic parametrized canvas harness,
  offline-degrade polish (task-detail empty string; roadmap query trap), spec/code
  cross-ref staleness (§15 comment, spec's stale status-legend row).

## Roadmap

### Wave 1 (this wave — 3 slices, integration-ordered)

1. **pp-w1-author-flagship** (large, fable, PR-less) — author `gui-tui-parity-page`
   (8 sections) as blocks JSON, verify offline (cmd/dump 80+40 + pass2 harness), publish
   once, patch with ifRev thereafter, verify live (reader HTML + bp paper view 80).
   Produces the content that closes every parity-sN section child.
2. **pp-w1-canvas-verify** (medium, opus, PR-less) — check bundle freshness at HEAD
   (post-#2446), fork the static canvas harness over the LIVE paper's real blocks;
   prove clean mount, round-trip id order, one-op edit, `.bp-section__grid` present;
   fleet chips expected offline.
3. **pp-w1-ledger-truth** (small, opus, PR-less) — parity-state ws-012 card corrected via
   replace-block+ifRev; false-done stubs annotated; probe paper deleted.

Then (lead, at review): flip section-children criteria with live-URL evidence, close
s1–s8 + the anchor, log the wave.

### Backlog (filed as published children of parity-page)

- **pp-b-dump-harness** (P3) — wire cmd/dump into a documented script; today it is real,
  working, and referenced by nothing.
- **pp-b-branch-protection** (P2) — #2398 merged over a failing non-advisory-named
  check; audit required-check config so freshness reds actually block.
- **pp-b-canvas-harness-generic** (P3) — parametrize the canvas harness (RUN via fetched
  JSON) instead of forking per verification.
- **pp-b-offline-degrade** (P3) — task-detail renders 0B offline (should be an explicit
  placeholder like its siblings); roadmap-from-query silently produces overlapping bars
  (synthesize positions or warn).
- **pp-b-crossref-staleness** (P4) — components.ex:67 cites a nonexistent "spec §15";
  the spec's block-status table still marks status-legend "▫ next" though it shipped.

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

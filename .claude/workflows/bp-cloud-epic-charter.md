# PortableDoc Everything-Editable — finish line (pd-everything-editable epic charter)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **self-update W5** at `bp-self-update-w5-charter.md`,
> **gui-premium W5** at `bp-gui-premium-w5-charter.md`, **p-quality-gate** at
> `bp-hollow-paper-gate-charter.md`, **composition-doctrine** at
> `bp-composition-doctrine-charter.md`, and **aesthetic-unification (reconciliation)** at
> `bp-aesthetic-unification-reconciliation-charter.md`. This file is now the memory of
> the **pd-everything-editable** finish-line epic.

Epic anchor: bp task slug **`pd-everything-editable`** ("EPIC · PortableDoc Beta:
everything editable, 1:1 with the reader", published, priority 1, 10 children +
this wave's additions). Wave Paper: `pd-everything-editable-wave-2026-07-11`.
Server: guerrilla. Sibling epic (named successor, NOT scope):
`paper-edit-parity-endgame` (render-path unification).

## Vision

Every authorable PortableDoc block type is editable in the mainline (canvas-on) Studio
editor, 1:1 with the reader — no block type reaches the "not editable yet" catch-all
(paper_editor.ex:1339), every editable block byte-aligns with the reader render, and the
nested-editing UX is proven in a live browser. The anchor closes only when all three of
its criteria carry file:line/PR/run evidence — never on vacuous green (the 2026-07-08
false-done cleanup is precedent). This wave: pay the bundle debt, fix the one real C2
break (card chrome), close the one real C1 gap (5 DataViz types), and leave C3 honestly
open with a packaged, unblockable checklist.

## Non-negotiable operational facts (builders read FIRST)

- Render-path unification law: ONE producer, never fork reader/editor paths. Server
  paints non-prose blocks via `Render.render_block/2`; editor JS never hand-writes
  reader fleet markup (§3 forbidden-literal gate).
- .ex/.heex changes WAIT for the Elixir Test CI gate before merge. Goldens byte-unchanged
  except owned regens. Worktrees from origin/main after `git fetch`. Claim your bp task
  BEFORE working. PR body carries `Task: <id>`. `cc` is a Claude wrapper — always
  `CC=/usr/bin/clang`.
- D8 (below): every PR touching `api/assets/paper-editor/src/**` rebuilds AND commits
  the bundle (`npm run build`, then commit the two artifacts under
  api/priv/static/assets/). The build is deterministic — a dirty diff after your build
  means the committed bundle was stale, not flake.
- The hollow-paper gate cannot false-negative content-ADDING edits (ratchet only halts
  the non-hollow→hollow edge) — a live-pass failure is a real editor bug, never gate
  interference.

## Decisions

- **D1 — Anchor stays OPEN this wave; close is a later ceremony.** C1 is factually FALSE
  at HEAD: `stat`, `stats`, `stat-grid`, `heatmap`, `chart` (compose.ex:1115-1145) have
  zero editor clauses (exhaustive grep of paper_editor.ex's 31 case heads), are absent
  from @canvas_fleet_types (paper_canvas.ex:167) and from slash-insert — proven both
  statically and by a live authored-paper round-trip on localhost. No close on unmet
  criteria.
- **D2 — C1 is scoped to the mainline canvas-on surface.** Classic (canvas-off) mode
  intentionally routes all fleet types to the catch-all (view/delete/reorder); it is a
  legacy opt-out, not the doctrine surface. The anchor's C1 text is updated to
  ":1339, mainline canvas surface" (was stale ":1312", unscoped).
- **D3 — DataViz editability ships via the server-paint fleet pattern, not hand-mirrored
  node-views.** Blocks paint through `Render.render_block/2` (ONE producer, doctrine D8)
  with edit islands for config — byte-parity with the reader by construction. Why: the
  parity gate exists because hand-mirroring rots.
- **D4 — DataViz types stay slash-UNinsertable in v1** (CANVAS_SLASH_TYPES stays 23,
  lockstep smoke untouched). Why: data-bearing, API-authored blocks — an empty slash
  insert is meaningless; same structural-exclusion precedent as sheet/embed.
- **D5 — The card chrome break is C2-blocking and rides THIS wave by ADOPTING the
  existing sibling task `parity2-bug-card-slot-chrome`** (stays parented under
  paper-edit-parity-endgame; wave_paper stamped on it). Why: at HEAD the editor node-view
  (card-node.js:264-300) emits model-A `bp-card__t/__d/__media/__action` chrome while the
  reader's `card_html/2` (components.ex:349-381) is model-B bare-semantic (`<h2>`/`<p>` —
  card_widget_test.exs:96-102, green, REFUTES the chrome) — WYSIWYG is broken on the very
  widget #2398 grew. Dedup law: the bug is already owned; never double-file.
- **D6 — Fix direction: the editor moves to model B. NEVER revert the reader to model
  A.** Model B is the graduated cross-surface shape (web+email+TUI, PRs #1529/#1539).
- **D7 — bp-card__ goes BACK into the §3 forbidden list + card gets a mounted-shape gate
  (`__card_parity.test.mjs`, twin of `__section_parity.test.mjs`).** Why: the current §3
  graduation (canvas_reader_parity_gate_test.exs:377-385) is a permit resting on a
  now-false premise ("reader emits bp-card__*" — it no longer does); card parity is
  otherwise invisible to CI.
- **D8 — The bundle no-rebuild precedent (since #1984) is RESCINDED.** Every PR touching
  `api/assets/paper-editor/src/**` rebuilds and commits the bundle (proven deterministic;
  esbuild 0.24.2 pinned). A catch-up regen slice goes first this wave. Why:
  paper-editor.yml has been red on main for 3 pushes at "Assert committed bundle is
  fresh" — a permanently-red workflow erodes all CI signal. (Correction of record: it is
  a persistent red, NOT a mechanical merge-blocker — no branch protection/ruleset
  exists.)
- **D9 — C3 stays open; pd-ee-live-verify is an infra-blocked agent task, not a human
  mandate.** chrome-devtools MCP cannot launch any browser on this host (all instances
  share one hardwired profile dir; the lock is held by another LIVE session —
  do-not-clobber). App-side prerequisites are all green (local Studio 200 admin-open,
  showcase holds every checklist type, LiveView JS served). The task brief now carries
  the expanded checklist (+card slots from #2398, +hollow-ratchet probe) and the unblock
  recipe (unique userDataDir). The infra defect is filed
  (`pd-ee-chrome-mcp-userdatadir`).
- **D10 — The 5 vacuous-done children get retro evidence stamps, not reopens.** Their
  ledger rows (met:0, evidence:"") are a bookkeeping defect; the code claims are verified
  TRUE at HEAD (PR #1233/845acf5f is a HEAD ancestor; action/figure/terminal node files
  exist; __section_parity ran 11/11 live). Distinct from fabrication — evidence says so.
- **D11 — Render-path unification is REFUSED as scope.** It is the sibling epic
  `paper-edit-parity-endgame` (2 open tasks: S10 card chrome — adopted here per D5 —
  and task-detail empty-state; S12-S17 remain charter-only backlog THERE, deliberately
  not re-filed here).
- **D12 — asciicast/form/questionnaire read-only is ratified scope-narrowing** under
  pd-ee-fleet-config-decision (islands v1, "stay minimal"); no work owed by this epic.
- **D13 — TUI is out of scope for this anchor.** All three criteria are web-worded;
  #2398 added editing capability, not a new block type — no pdrender renderer owed.
- **D14 — Honest C2 stamp language until the card slice merges:** "parity gates green at
  HEAD (44 tests/0 failures at fc9665e4: view_edit_parity + canvas_reader_parity_gate +
  card_widget; delta since proven-green CI run d655b753 diff-verified inert) MODULO
  parity2-bug-card-slot-chrome." Never unconditional green.

## Roadmap

Wave 2026-07-11 (this wave, integration-ordered — S2/S3 share the bundle artifacts and
the parity gate test file, so they sequence via file-truth collisions; S1 lands first):

1. **S1 · pd-ee-bundle-regen** (small, opus) — catch-up rebuild+commit of
   bp-paper-editor.bundle.js/.css; paper-editor.yml returns green on main. Pays the
   ba893d5e/29176820/5dd34bbd debt under D8. No source changes.
2. **S2 · parity2-bug-card-slot-chrome** (large, fable, ADOPTED from sibling epic) —
   card-node.js node-view rewritten to model-B DOM byte-aligned with card_html/2;
   dead editor CSS dropped; §3 graduation reverted (D7); __card_parity.test.mjs added;
   bundle regen rides (D8).
3. **S3 · pd-ee-dataviz-editors** (large, fable) — stat/stats/stat-grid/heatmap/chart
   become canvas-editable via server-paint + edit islands (D3); painted_fleet rows +
   forbidden literals added to the parity gate; no slash insert (D4); bundle regen rides.

Later waves / backlog (filed as published children of the anchor):
- **pd-ee-live-verify** (open, carries C3) — execute the live browser checklist the
  moment a free Chrome profile exists; evidence = screenshots + console messages +
  reload-persistence per step.
- **pd-ee-chrome-mcp-userdatadir** (p2) — host infra: per-session userDataDir for
  chrome-devtools-mcp so agent browser passes stop deadlocking on one shared profile.
- **pd-ee-dataviz-structured-editors** (p3) — v2 structured UIs (heatmap 2D grid editor
  covering its 3 render modes; chart series/axes forms) replacing the v1 JSON islands.
- **pd-ee-sheet-embed-audit** (p3) — sheet/embed editability audit (reached by no
  surveyor this wave).
- **pd-ee-reader-stale-cache** (p3) — a deleted paper kept serving HTTP 200 on the
  public reader route after a confirmed DB delete; find and fix the stale cache layer.
- **Close ceremony** (after S1-S3 merge + C3 unblocks): stamp C1/C2/C3 with evidence,
  final audit, close the anchor.

## Wave log

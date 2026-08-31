# Dispatch Frontier — file-truth wave charter

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **airdrop-grants enforcement-endgame** charter formerly here is preserved
> verbatim at `.claude/workflows/bp-airdrop-grants-endgame-charter.md`. This file is now
> the memory of the **dispatch-frontier file-truth** wave.

Epic anchor: bp task slug **`dispatch-frontier-goal`** (UUID 1ab62264-5daa-4adb-b72d-c69819686e47 —
`bp task get` resolves the SLUG, 404s the UUID). 12 children (v2 added df-file-edge +
df-lint-files-nudge); cmux-bridge-goal is a nested sub-goal. NOTE: df-exclude-epic-roots-from-hard-conflict
carries only `area:tui` — enumerate children via parent_id traversal, never label search. Server: guerrilla.

## Vision

Answer "how many agents can run at once without colliding" with CODE, not vibes. The frontier QUERY
already exists and is good (`taskboard.Frontier` + `bp task frontier` + `bp cmux dispatch`, PR #1191
and the df-* children). What it lacks is TRUTH (0 authored `area:` labels across the ~67-task live
ready corpus — the frontier is honest but starved) and TEETH (the frontier predicts; nothing enforces
at claim time). This wave finishes the vein:

- **File truth**: tasks declare their file blast radius as `files:` labels; `interferes()` gains its
  strongest surface edge — intersecting declared file sets are NEVER co-dispatched; disjoint declared
  sets upgrade to "file-proven isolated". Undeclared stays unproven — missing metadata buys less
  parallelism, never more.
- **Atomic frontier claim**: `bp task next <worker> --frontier` — compute the frontier, claim the top
  pick by id via the existing epoch-CAS claim, on a lost race recompute and try the next non-colliding
  pick. The claim carries declared files as `resources`, so the server's existing resource fence
  rejects intersecting concurrent claims. N workers running this concurrently each land on a mutually
  non-colliding task — the executable answer to the headline question.
- **Honest overlap report**: when two in_progress claims share declared files, `bp task frontier`
  names the pair and the shared surface — the lead learns at claim time, not merge time.
- **The number everywhere**: `bp task ready` (the most-used verb) grows the one-line
  `FRONTIER · N independent` header.

Yardstick collision: the agent-onramps w2 3-way clause-stack pile-up on `internal/cli/onramp_cmd.go`
(merge 56b144f6, resolved by hand — bp-agent-onramps-w2-charter.md:48). Every collision slice ships a
deny-path test that encodes that trio and proves the NEW edge catches it.

## Decisions

- **D1 — `files:` label is the scope source, not the blast-radius tooling.** `tooling/blast-radius/index.json`
  and `tooling/barkpark-sync/nodes.json` are gitignored Node-built caches no Go code reads; consuming them
  at frontier time breaks Go-only + clone-freshness. Labels are already decoded end-to-end
  (fetch.go:202 → Task.Labels); a `files:` prefix sits beside `area:`/`phase:`/`proj:` (board.go:207-209).
  Tooling may SEED labels out of band; the runtime never depends on that having happened.
- **D2 — one repo-relative path per label; trailing `/` = directory prefix; no globs in v1.** Exact-path
  + dir-prefix intersection covers the real collisions; globs risk false confidence. Paths normalized
  (no leading `./`, no trailing whitespace) because the server resource fence is exact-string match —
  dir-prefix entries fence only against identical strings server-side (accepted v1 looseness; the
  client-side frontier does the prefix logic). LIVE-CONFIRMED 2026-07-10: a dir-prefix claim passed the
  fence against a held file under that dir, exactly as documented.
- **D3 — file edge is the strongest SURFACE edge: checked after cross-root block edges, before area.**
  Both declare + intersect → hard conflict naming the shared path. Both declare + disjoint → cleared
  (file truth trumps coarse `area:` buckets and the neighborhood proxy) with new risk class
  "file-proven isolated". Either undeclared → ABSTAIN, fall through to today's area/neighborhood logic.
  Dependency (block) edges still trump everything — ordering is not a file question.
- **D4 — deny-path fixtures must defeat the existing proxies or they are vacuous green.** The onramps trio
  shared an epic root and would share `area:cli` — either proxy already hard-conflicts them. The fixture
  puts three tasks in DIFFERENT roots with NO area labels so intersecting `files:internal/cli/onramp_cmd.go`
  is the SOLE catcher; a control asserts the trio is co-admitted without the labels. Delete the file
  edge → the test goes red. (Non-vacuity re-proven at close-out by code trace: without the file edge the
  cross-root trio falls to the neighborhood proxy and co-admits — frontier_test.go:589-642.)
- **D5 — slice 2 ADOPTS cb-next-frontier-claim (re-briefed reserved→build); df-next-frontier closed as
  superseded.** Two reserved markers described the same claim-before-spawn vein — one owner. It stays
  parented under cmux-bridge-goal (itself a child of dispatch-frontier-goal): "under 1ab62264" holds
  transitively and the cmux lineage is preserved.
- **D6 — `--frontier` is a client-side intercept over claim-by-id; the queue endpoint is untouched.**
  Bare `bp task next` is the server queue claim `POST /v1/tasks/claim` (not frontier-aware; extending it
  would force the Elixir gate + openapi regen). `POST /v1/tasks/:doc_id/claim` already exists, is atomic
  (per-doc advisory lock + FOR UPDATE, claim.ex:69-75,139), and already accepts `resources`. A lost race
  returns `not_ready` (NOT `already_claimed`, claim.ex:154-157) — the loop treats it as skip-and-try-next,
  never task-gone. Epoch<=0 in a claim response is a hard failure (client.go:987 TaskClaimN,
  client.go:1040-1041 TaskClaimResources — citation refreshed at close-out; the file grew since D6 was
  written). LIVE-CONFIRMED 2026-07-10: lost race returned not_ready on guerrilla.
- **D7 — claims carry declared files as `resources` (Go client change only).** The server fence
  (`check_resources_free`: global `task-resources` advisory lock, jsonb overlap scan, 409
  `resource_conflict` + holders — claim.ex:77-79,194-227) already shipped as resource-claim
  successor; the Go client just never sent resources and drops the `conflicts` holders array
  (client.go:870-875) — both fixed client-side. Query predicts (ready set), claim enforces (in_progress
  set): complementary, never conflated. LIVE-CONFIRMED 2026-07-10: identical-resource claim rejected with
  resource_conflict naming the holder's doc_id + worker.
- **D8 — overlap report lives on `bp task frontier` output fed by `board.Now`, NOT `bp cmux status`.**
  cmux status is per-pane (one `BARKPARK_TASK`); `board.Now` is the full in_progress claim set with
  labels already fetched (board.go:329-334) — a pure `ClaimOverlaps` costs zero new requests.
- **D9 — the TUI NOW/NEXT band stays retired.** Commit 92a618f8 removed it deliberately ("the spine is
  the whole board"); do not resurrect. The number's homes: `bp task frontier` (exists) + a new
  `bp task ready` header. `ready` is manifest-dispatched with no intercept today (cli.go:146 case "task"
  intercepts only frontier/lint/create) — the header needs a real intercept, table/human output only,
  `-o json` byte-untouched.
- **D10 — ledger truth stamped in the decide phase.** Goal criteria C1/C2 were satisfied by merged
  PR #1191 but sat met:false with empty evidence (earned-but-unstamped drift); stamped now via doc patch.
  C3 stays open for wave review since this wave upgrades the design of record from area-aware to file-aware.
- **D11 — adoption is the bottleneck, so lint nudges it.** files: coverage starts at 0%; `bp task lint`
  (df-lint-area-nudge precedent, tasks_lint_cmd.go) grows a files: nudge + measurable files-less count.
  Epic-cycle decide phases author `files:` labels on wave tasks from now on — this wave's own tasks
  carry them (dogfood).
- **D12 — close-out verdict: CLOSE, plus exactly ONE Go-only fix slice.** Every v2 promise is
  file:line-verified merged (#2147/710cbe53) and the fence is LIVE-proven on guerrilla. But #2147
  INTRODUCED a regression: the `bp task ready` FRONTIER header (cli.go:194 → printReadyFrontierHeader,
  tasks_next_cmd.go:273-293) calls fetchCrossEdges — one sequential ~10s `/v1/graph/:root` call per ready
  root, no aggregate deadline — stalling the interactive/table path ~231s on today's 30-root board
  (git-proven: the parent of 710cbe53 had no header; -o json/piped is unaffected via machineOut; only
  fires when ReadyRootSpan>=2, which is this board's normal state). Per the wish's flip rule (a shipped
  v2 behavior broken live) this earns the smallest honest fix: the ready header computes capacity WITHOUT
  the network fan-out (pure Frontier over the snapshot — a capacity number needs no cross-root graph
  precision); the explicit `bp task frontier` / `next --frontier` fan-out gets a bounded concurrent
  fan-out + total wall-clock deadline (fetchCrossEdges is already best-effort; dropping under deadline is
  safe). Deny-path per D4: a blocking fake graph client must NOT stall the header. The frontier verb's own
  slowness is pre-existing (#1308) — the same fix covers it; no server change (anchor-fenced).
- **D13 — C3 stamped-as-strengthened, not amended.** The criterion's "area:-aware interference as the
  design of record" is satisfied and exceeded: docs/contracts/dispatch-areas.md:68-108 is the FILE-aware
  design of record (strict superset per D3), and all 12 children are verified parented under the goal via
  parent_id traversal. Evidence cites the doc + frontier.go/overlaps.go anchors + the 12/12 roster.
  The lead stamps C3 and closes the epic at review once wave-3 slices land.
- **D14 — ledger hygiene: stamp from close_reason, caveat the decayed one, finish cb-ledger-close.**
  8 v1-era children are done with 0/N criteria stamped. 7 carry true, checkable close_reason narratives
  (PRs #1191/e0680fd8, #1308, #1309, #1315, #1348 + named green tests) — earned-but-unstamped drift
  (the D10 pattern), NOT the 2026-07-08 false-done-fabrication class; the honest fix is copying each
  close_reason's evidence into the per-criterion evidence fields, no rebuild. df-seed-area-labels has NO
  close_reason and its seeding has since decayed (0/60 ready leaves carry area:/files: today) — it gets an
  explicit decay caveat as evidence, never a copy-paste stamp. df-exclude-epic-roots-from-hard-conflict
  gains the missing proj:dispatch-frontier label. cmux-bridge-goal (criteria:[] — empty array; the server
  emits criteria_progress:null for that, a quirk automated audits must not skip over) gets its criteria
  authored+stamped by FINISHING cb-ledger-close, the still-open grandchild whose recorded blockers
  (cb-live-smoke, cb-docs-card) are stale — both are done and fully stamped.
- **D15 — the gap register is part of the close (see §Gap register).** Deliberately-not-done work is
  named with its home; silence is the only forbidden outcome.
- **D16 — D11's authoring promise gets a home outside this charter.** The promise "decide phases author
  files: labels" lived only at D11 — invisible to every other epic's decide phase. The epic-cycle
  workflow's TASKS_BLOCK (.claude/workflows/bp-epic-cycle.workflow.js) grows the files:-label authoring
  instruction pointing at docs/contracts/dispatch-areas.md; dispatch-areas.md gains the D2
  exact-match-looseness note (dir-prefix labels fence server-side only against identical strings).
  Doc-only; lint stays a nudge, never a gate.

## Roadmap

Shipped before this wave (context, all merged):
- df-frontier-fn / df-independentready-switch / df-cli-frontier-verb (PR #1191) — Frontier model + verb, one shared count
- df-area-vocabulary (#1309), df-lint-area-nudge (#1315), df-graph-crossdep (#1308), df-seed-area-labels,
  df-exclude-epic-roots-from-hard-conflict (#1348)
- cmux-bridge-goal wave 1 (#1200, #2134) — `bp cmux dispatch` consumes Frontier; hooks/status/install

v2 (SHIPPED — all three slices in one PR #2147 / commit 710cbe53, merged 2026-07-10):
1. **df-file-edge** (large) — `files:` label convention + exported `taskboard.FilesOf` + file edge in
   `interferes()` + file-proven risk class + `taskboard.ClaimOverlaps` + OVERLAP section in
   `bp task frontier` + dispatch-areas.md contract + onramps deny-path fixture.
   Files: internal/taskboard/{frontier.go,frontier_test.go,board.go,overlaps.go,overlaps_test.go},
   internal/cli/tasks_frontier_cmd.go(+test), docs/contracts/dispatch-areas.md.
2. **cb-next-frontier-claim** (large, ADOPTED) — `bp task next <worker> --frontier` client intercept
   (claim-by-id retry loop, resources-carrying claims, conflicts holders decoded) +
   `bp cmux dispatch --claim` claim-before-spawn + `bp task ready` FRONTIER header.
   Files: internal/cli/{cli.go,tasks_next_cmd.go(new)+test,cmux_dispatch.go(+test)},
   internal/apiclient/client.go(+task_claim_test.go).
3. **df-lint-files-nudge** (small) — `bp task lint` nudges workable leaves missing `files:` labels;
   files-less count in JSON so adoption is measurable.
   Files: internal/cli/tasks_lint_cmd.go(+test).

Wave 3 (close-out, 2026-07-10 — this wave; slices are parallel, zero file overlap):
1. **df-v3-ready-header-decouple** (medium, fable) — fix the D12 regression: ready header without
   network fan-out; bounded+deadlined fetchCrossEdges for the explicit frontier verbs; D4-grade
   deny-path (a blocking fake graph client must not stall the header).
   Files: internal/cli/tasks_next_cmd.go(+test), internal/cli/tasks_frontier_cmd.go(+test).
2. **df-close-ledger-stamp** (small, opus) — D14 in full: stamp 7 v1-era children from close_reason;
   decay-caveat df-seed-area-labels; label df-exclude-epic-roots-from-hard-conflict; author+stamp
   cmux-bridge-goal criteria by finishing cb-ledger-close. bp mutations only — no repo files, no PR.
3. **df-docs-files-doctrine** (small, opus) — D16: TASKS_BLOCK files:-label authoring instruction in
   bp-epic-cycle.workflow.js + D2 looseness note in docs/contracts/dispatch-areas.md.
Lead stamps C3 per D13 and closes the epic at review once all three land.

## Gap register (deliberately NOT done — named per D15, with homes)

- **files: adoption is 0/60** on the live ready corpus (bp task lint files_less=60, measured
  2026-07-10). Seeding across live epics stays "Later" (below); the measurement instrument is
  `bp task lint` (tasks_lint_cmd.go). D16 wires authoring-time doctrine so NEW wave tasks carry labels.
- **epic-cycle consuming `bp task next --frontier`** for builder dispatch — the epic-loop layer's job,
  fenced out by the anchor ("actually orchestrating agents"). Zero frontier references in
  bp-epic-cycle.workflow.js today; a future wish must name it.
- **Studio/board overlap surfacing** — anchor-fenced ("Studio UI"); board_live.ex/board.ex carry zero
  frontier hooks. Home: this register + "Later" below.
- **`/v1/graph/:id` is pathologically slow on guerrilla** (~10-12s/call — the server-side root cause
  D12 works around client-side). Server work, anchor-fenced. Filed as standalone published task
  `graph-endpoint-latency` (deliberately NOT a child — this epic closes; the work is the API's).
- **Hollow design_doc Paper** — the anchor's design_doc points at the near-empty "dispatch-frontier"
  Paper; the real content lives in docs/contracts/dispatch-areas.md. Owned by the cloud epic's
  p-dispatch-frontier-content backlog item — not duplicated here.

Later (unchanged): out-of-band files: seeding across live epics (scope.mjs-assisted hygiene);
optional board/TUI overlap surfacing; glob semantics only if real briefs demand them; server-side
resource fence on the queue endpoint only if a consumer materializes (Elixir gate + openapi).

Ledger hygiene done in decide phases: goal C1/C2 evidence stamped (PR #1191); df-next-frontier closed
as superseded by cb-next-frontier-claim; the D14 children pass is wave-3 slice 2.

## Wave log

- **v1 (2026-07-06 → 2026-07-08, predates this charter file):** #1191/e0680fd8 (07-06) Frontier model +
  `bp task frontier` verb — the C1/C2 evidence; #1200 (07-06) cmux bridge wave 1; #1308/9d7b9404 (07-08)
  cross-root block-edge precision (df-graph-crossdep — origin of the fetchCrossEdges fan-out D12 later
  bounds); #1309 (07-08) area: vocabulary contract (df-area-vocabulary); #1315 (07-08) `bp task lint`
  area nudge (df-lint-area-nudge); #1348/5a8d68a2 (07-08) epic roots don't displace their children
  (df-exclude-epic-roots-from-hard-conflict); df-seed-area-labels closed 07-08 (label hygiene, no code —
  seeding since decayed, see D14). v1 closed its tasks under the pre-rubric convention: real merged PRs,
  unstamped criteria — the D14 debt.
- **v2 (2026-07-10):** decisions D1-D11 ratified; #2134/4e99ae35 closes cmux-bridge wave 1;
  #2147/710cbe53 ships all three v2 slices (files: truth + file edge + overlap report, --frontier atomic
  claim + cmux --claim + ready header, lint files nudge) in one integration-ordered PR. C1/C2 stamped at
  decide time (D10). The wave log was left EMPTY at the time — paid now, at close-out.
- **wave 3 / close-out (2026-07-10):** two-round verification (12 surveyors + 5 verifiers). LIVE fence
  proof on guerrilla: identical-resource claim → resource_conflict naming the holder (D7); dir-prefix
  claim passes exact-match (D2); lost race → not_ready (D6); ClaimOverlaps observed live (overlaps=1).
  D4 deny-path re-proven non-vacuous by code trace. Regression found and classified: #2147's ready
  header stalls the interactive path ~231s on a 30-root board (D12) — the one fix slice this wave cuts.
  Verdict: CLOSE with D12-D16. Slices: df-v3-ready-header-decouple (fable), df-close-ledger-stamp
  (opus), df-docs-files-doctrine (opus). Backlog filed: graph-endpoint-latency (standalone,
  server-side). Wave Paper: dispatch-frontier-wave-2026-07-10. C3 stamps as-strengthened per D13; the
  lead closes the epic at review.

### Wave 2026-07-10 (wave 3 review — built, reviewed, ready to merge)

All three slices landed green and reviewed; nothing stalled. **df-v3-ready-header-decouple**
(branch `loop-epic/ready-header-answers-instantly-decouple--0`, commit 6caeae67): the D12 fix —
`bp task ready` header computes with ZERO graph calls (pure `taskboard.Frontier` over the snapshot,
`FrontierOpts{}` in printReadyFrontierHeader); `fetchCrossEdges` → `fetchCrossEdgesBounded` (8-worker
pool, ONE 4s total deadline, best-effort fold on expiry, buffered sends so abandoned workers never
block). Reviewer re-proved the D4 deny-path non-vacuous (restoring the CrossEdges call turned
TestReadyFrontierHeaderZeroGraphCalls red at 2 graph hits) and ran the pool tests under -race: clean.
Accepted looseness: the header count can read slightly higher than `task frontier`'s when real
cross-root block edges exist (D12: a headline needs no cross-root precision); on live guerrilla
(~10s/graph call) the 4s deadline usually yields zero cross edges until `graph-endpoint-latency`
fixes the server. **df-close-ledger-stamp** (bp-only, no branch): D14 done — 7 v1-era children
stamped met==total from close_reason evidence (test names verified in-tree; suites re-run green at
review), df-seed-area-labels 0/3 with the honest decay caveat (files_less=60), proj:dispatch-frontier
added to df-exclude-epic-roots-from-hard-conflict, cmux-bridge-goal criteria (a)-(f) authored+stamped
6/6, cb-ledger-close claimed(epoch 3)+closed done 5/5. **df-docs-files-doctrine** (branch
`loop-epic/files-doctrine-reaches-every-decide-phas-2`, commit 6624b896 + this review commit): D16 —
one files:-authoring bullet in the epic-cycle TASKS_BLOCK, D2 server-fence caveat in
dispatch-areas.md; all three doc gates green. Next: the LEAD merges both branches (PR bodies carry
Task: <id>), closes the merge-gated criteria (df-v3 c6, df-docs c4, df-close-ledger-stamp c6
read-back), stamps goal C3 as-strengthened per D13, and CLOSES dispatch-frontier-goal — remaining
work (graph-endpoint-latency, files: seeding, epic-cycle --frontier consumption, Studio overlap
surfacing) lives in the §Gap register, not in a new wave.

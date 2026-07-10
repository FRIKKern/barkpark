# Dispatch Frontier — file-truth wave charter

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **airdrop-grants enforcement-endgame** charter formerly here is preserved
> verbatim at `.claude/workflows/bp-airdrop-grants-endgame-charter.md`. This file is now
> the memory of the **dispatch-frontier file-truth** wave.

Epic anchor: bp task slug **`dispatch-frontier-goal`** (UUID 1ab62264-5daa-4adb-b72d-c69819686e47 —
`bp task get` resolves the SLUG, 404s the UUID). 10 children; 8 df-* done, cmux-bridge-goal is a
nested sub-goal. Server: guerrilla.

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
  client-side frontier does the prefix logic).
- **D3 — file edge is the strongest SURFACE edge: checked after cross-root block edges, before area.**
  Both declare + intersect → hard conflict naming the shared path. Both declare + disjoint → cleared
  (file truth trumps coarse `area:` buckets and the neighborhood proxy) with new risk class
  "file-proven isolated". Either undeclared → ABSTAIN, fall through to today's area/neighborhood logic.
  Dependency (block) edges still trump everything — ordering is not a file question.
- **D4 — deny-path fixtures must defeat the existing proxies or they are vacuous green.** The onramps trio
  shared an epic root and would share `area:cli` — either proxy already hard-conflicts them. The fixture
  puts three tasks in DIFFERENT roots with NO area labels so intersecting `files:internal/cli/onramp_cmd.go`
  is the SOLE catcher; a control asserts the trio is co-admitted without the labels. Delete the file
  edge → the test goes red.
- **D5 — slice 2 ADOPTS cb-next-frontier-claim (re-briefed reserved→build); df-next-frontier closed as
  superseded.** Two reserved markers described the same claim-before-spawn vein — one owner. It stays
  parented under cmux-bridge-goal (itself a child of dispatch-frontier-goal): "under 1ab62264" holds
  transitively and the cmux lineage is preserved.
- **D6 — `--frontier` is a client-side intercept over claim-by-id; the queue endpoint is untouched.**
  Bare `bp task next` is the server queue claim `POST /v1/tasks/claim` (not frontier-aware; extending it
  would force the Elixir gate + openapi regen). `POST /v1/tasks/:doc_id/claim` already exists, is atomic
  (per-doc advisory lock + FOR UPDATE, claim.ex:69-75,139), and already accepts `resources`. A lost race
  returns `not_ready` (NOT `already_claimed`, claim.ex:154-157) — the loop treats it as skip-and-try-next,
  never task-gone. Epoch<=0 in a claim response is a hard failure (client.go:957-959).
- **D7 — claims carry declared files as `resources` (Go client change only).** The server fence
  (`check_resources_free`: global `task-resources` advisory lock, jsonb overlap scan, 409
  `resource_conflict` + holders — claim.ex:77-79,194-227) already shipped as the Beads file-claim
  successor; the Go client just never sent resources and drops the `conflicts` holders array
  (client.go:870-875) — both fixed client-side. Query predicts (ready set), claim enforces (in_progress
  set): complementary, never conflated.
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

## Roadmap

Shipped before this wave (context, all merged):
- df-frontier-fn / df-independentready-switch / df-cli-frontier-verb (PR #1191) — Frontier model + verb, one shared count
- df-area-vocabulary (#1309), df-lint-area-nudge (#1315), df-graph-crossdep (#1308), df-seed-area-labels,
  df-exclude-epic-roots-from-hard-conflict (#1348)
- cmux-bridge-goal wave 1 (#1200, #2134) — `bp cmux dispatch` consumes Frontier; hooks/status/install

This wave (integration-ordered — merge 1 before 2; 3 is independent):
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
   Compile-depends on `taskboard.FilesOf` from slice 1 (contract pinned in the brief; rebase after 1 merges).
3. **df-lint-files-nudge** (small) — `bp task lint` nudges workable leaves missing `files:` labels;
   files-less count in JSON so adoption is measurable.
   Files: internal/cli/tasks_lint_cmd.go(+test).

Later (not this wave): out-of-band files: seeding across live epics (scope.mjs-assisted hygiene);
optional board/TUI overlap surfacing; glob semantics only if real briefs demand them; server-side
resource fence on the queue endpoint only if a consumer materializes (Elixir gate + openapi).

Ledger hygiene done in decide phase: goal C1/C2 evidence stamped (PR #1191); df-next-frontier closed
as superseded by cb-next-frontier-claim.

## Wave log

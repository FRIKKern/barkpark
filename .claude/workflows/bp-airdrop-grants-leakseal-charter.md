# Airdrop Grants — leak-seal wave charter (epic close-out)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **dispatch-frontier file-truth** charter formerly here is preserved verbatim at
> `.claude/workflows/bp-dispatch-frontier-charter.md`. The **airdrop-grants** permanent
> decision record lives at `.claude/workflows/bp-airdrop-grants-endgame-charter.md` — the
> epic-complete Wave log entries land THERE (close-out slice), not here. This file is the
> memory of the leak-seal wave only.

Epic anchor: bp task slug **`airdrop-grants`** — CLOSED 2026-07-10 (lifecycle done, honest
acceptance_criteria stamped; all children done; sole residual = standalone
`ag-broadcast-revoked-residual`). Server: guerrilla.

## Vision

The endgame wave (#2145) merged the deny matrix and it did its job: it found TWO CONFIRMED
grant-enforcement leaks — a grantee's SEARCH and BACKLINKS reads bypass Layer-2 grant
narrowing. This wave seals both at their true choke points, flips the committed-skipped deny
repros from documenting-the-hole to protecting-the-fix, and closes the epic with the full
evidence trail. Finished state: a grantee's search/backlinks reads are indistinguishable from
every other grant-narrowed read — same `Scope.scope_to_grants` union, fail-closed
(`where: false` on undecidable), applied only when `grant_scoped: true` — while members,
tokens, and anonymous stay byte-identical.

## Non-negotiable operational facts (builders read FIRST)

- **The local checkout is BEHIND origin/main** (#2145 = 602eb4a3 is on origin only). The deny
  repros (`grant_search_deny_test.exs`, `grant_single_doc_deny_test.exs`) and
  `test/support/access_fixtures.ex` exist ONLY on origin/main. `git fetch origin` then
  worktree from **origin/main** or the fail-before command errors "no such file" instead of
  producing RED.
- Elixir local gates need a warm `_build/test` (build-borrow into fresh worktrees is broken —
  lockfree-worktree-gate) and `CC=/usr/bin/clang`.
- Both build slices are .ex → they WAIT for the Elixir Test CI gate. Claim BEFORE working.
  PR body carries `Task: <id>`.

## Decisions

- **D1 — Search seal at the pipeline seam + retriever base query.** Add
  `grant_scoped: Keyword.get(opts, :grant_scoped)` to `retriever_opts`
  (query_pipeline.ex ~99-116). Apply grant narrowing ONCE in the Postgres
  `DocumentsRetriever` base query right after `scope_to_owner` (documents_retriever.ex:59) —
  that single point covers all three pipeline invocations (primary :130, try_drop_tokens :192,
  try_typo_widen :207) AND count (:87) AND facets (:93), since all derive from `base`. This
  seals every consumer of `Content.search_documents` at once (SearchController, SearchChannel,
  federated) — no per-caller edits.
- **D2 — Indx path: opts-threading + count seal.** Add `:grant_scoped` to the
  `Keyword.take` in the Indx retriever's `scope_opts/1` (plugins/indx/retriever.ex:373);
  `Content.Query.get_documents_by_ids` already gates (query.ex:1017-1018), so rows seal by
  threading alone. The `total` (length(ranked) pre-hydration, retriever.ex:105) would still
  over-count out-of-grant matches — for `grant_scoped` callers, recompute total as ONE
  grant-narrowed Postgres count over the ranked candidate id set
  (`Document |> where(id in ^ranked_ids) |> grant narrowing |> count`), fail-closed. A
  reported total must never exceed grant-visible matches (SearchChannel defaults engine indx).
- **D3 — Hoist ONE public wrapper, in the search slice.** Add public
  `Content.Scope.maybe_scope_to_grants(query, opts)` beside `scope_to_grants/3`
  (no-op unless `opts[:grant_scoped]`, pulls caller_context + workspace_id off opts); delete
  the private copy in query.ex:128-138 (its `import ... Scope` already exists — add the name,
  keep all 10 call sites working); consume it from DocumentsRetriever. No third/fourth private
  copy, ever. Anchor-safe: no `@canonical` marker or docs-card anchor binds the private def.
  Courtesy (non-gated): tenancy.md's "canonical scope helpers" prose gains one line.
- **D4 — Backlinks seal INSIDE the shared graph helpers, not a backlinks-only wrapper.**
  Opts-conditional `Scope.maybe_scope_to_grants` in (a) `resolve_doc/3`'s inline query
  (graph.ex ~896-912) and (b) `scope_query/2` (graph.ex ~949-956, which serves `docs_by_id`,
  `hydrate_nodes`, `fetch_doc`). This seals the HTTP backlinks cell, the scoped-route
  backlinks (scoped_paper_controller.ex:72), AND the Studio PaneBuilder graph/blast-radius
  pane for a grant-admitted socket (shared.ex:635 → pane_builder.ex:490-531 already threads
  the flag; Graph just ignored it). Same conditional in `scoped_docs_query/1`
  (orphans/dangling) as defense-in-depth — inert today (/v1/graph is :require_token, no grant
  fold). Provable no-op for every caller without the flag (only AssignGrantScope,
  ResolveWorkspace, LiveScope ever set it).
- **D5 — Studio graph-pane protection is unit-level, not socket-level.** New
  graph_test.exs cases prove `resolve_doc` / `reverse_referencers` / `traverse` grant-narrow
  when opts carry `grant_scoped` + a grant-bearing caller_context (use
  `Barkpark.AccessFixtures`), and stay byte-identical without the flag. No LiveView harness
  this wave — the mechanism is shared, the unit tests protect it.
- **D6 — RED-before evidence, unskip+fix in ONE PR.** The guards merged skipped in #2145, so
  there is no guard+fix decoupling issue. Each slice: remove the `@tag skip:` line FIRST, run
  the deny file on pre-fix code — expect EXACTLY 1 failure with the positive controls green
  (non-vacuous RED) — stamp that output into the task evidence, then fix, re-run to 0
  failures.
- **D7 — Integration order: search → backlinks → close-out.** The hoist (D3) lands in the
  search slice; the backlinks slice consumes `Scope.maybe_scope_to_grants/2` and merges
  AFTER search. Backlinks may build in parallel from origin/main (files are otherwise
  disjoint: graph.ex + graph_test.exs + grant_single_doc_deny_test.exs vs
  query_pipeline.ex + documents_retriever.ex + scope.ex + query.ex + indx/retriever.ex +
  grant_search_deny_test.exs) — write the two graph seams against
  `Scope.scope_to_grants/3` behind `opts[:grant_scoped]` checks if the wrapper is not yet
  on main, then swap to the public wrapper on the pre-PR rebase.
- **D8 — Error-emitters sweep verdicts (recorded, no build needed).** Federated search is
  bare `:api` — a grant is never admitted there, fails closed (deny test already green in
  #2145). `search_local` is RequireLoopback-trusted, never threads scope_opts. Suggestions
  returns query STRINGS from analytics, no Document rows — no narrowing surface. The
  plugin-pane path rides Content.Query base_query → already gated. No other
  `Content.search_documents` or Graph-read consumer needs its own seal.
- **D9 — binary_id guard: N/A on both slices.** resolve_doc matches `doc_id` strings via
  `where`, grant narrowing is field-equality — no raw-id `Repo.get` is introduced. Don't
  invent a guard where no raw-id touch exists.
- **D10 — Close-out mechanics (anchor has NO acceptance_criteria today).** Stamp criteria via
  `POST /v1/data/mutate` patch (flat top-level `acceptance_criteria` in
  {criterion,met,evidence} shape) then PUBLISH (the doc is published — an unpublished patch
  strands a competing draft). Patch criteria BEFORE claiming, or set them IN the close call —
  patching after claim trips the `doc_changed_since_claim` digest fence. Close needs a live
  claim epoch (claim-by-id first). Verify via `bp doc get` (task projection hides
  criteria/close_reason). Evidence trail: the 15 enforcement PRs #1303 #1339 #1353 #1372
  #1398 #1431 #1432 #1434 #1442 #1451 #1491 #1504 #1521 #1527 #1538, endgame #2145, plus
  this wave's two seal PRs.
- **D11 — Wave-log debt: ADOPT the stranded #2145 retro, don't re-derive.** Commit 48a18f85
  (branch `loop-epic/airdrop-grants-wave1-review-log`) drafted the endgame retro into THIS
  slot file and was orphaned. Fold its content into
  `bp-airdrop-grants-endgame-charter.md` § Wave log (currently EMPTY), corrected: the
  authoritative test count is **6,348** (full battery, #2145 PR body) not the 1,982 partial
  reviewer run; record the falsified write-side suspicion (writes were already gated per
  event — the real leak was reads on a live socket) and the empirical discovery of BOTH
  leaks. Then append the leak-seal epic-complete entry.
- **D12 — Exactly ONE honest backlog task; standalone, not built.**
  `broadcast_revoked/1` (access.ex:559-565) no-ops for grants without a bound
  grantee_user_id. Blast radius today is ZERO: only a claimed grant (which HAS a bound user)
  can mount a live desk; token/anonymous grantees read over HTTP which reloads active-only
  grants per request. File as defense-in-depth for a hypothetical future surface that mounts
  a session for an unbound grant — explicitly NOT a confirmed leak. Standalone (no parent —
  the closed epic keeps zero open children), label proj:airdrop-grants, priority 3. The
  parked UX items (grantor-own filter, grant history) and test-helper tidies stay parked —
  not filed as leaks, not built.

## Roadmap — this wave (integration-ordered)

1. **ag-search-grant-leak** (medium, priority 1) — D1+D2+D3. Files:
   api/lib/barkpark/search/query_pipeline.ex, api/lib/barkpark/search/documents_retriever.ex,
   api/lib/barkpark/plugins/indx/retriever.ex, api/lib/barkpark/content/scope.ex,
   api/lib/barkpark/content/query.ex, api/test/barkpark_web/controllers/grant_search_deny_test.exs.
2. **ag-backlinks-grant-leak** (medium, priority 1) — D4+D5, merges after 1 (D7). Files:
   api/lib/barkpark/content/graph.ex, api/test/barkpark/content/graph_test.exs,
   api/test/barkpark_web/controllers/grant_single_doc_deny_test.exs.
3. **ag-epic-closeout** (small, priority 1, lead/reviewer work, after 1+2 merge) — D10+D11+D12.
   Files: .claude/workflows/bp-airdrop-grants-endgame-charter.md + ledger acts via bp.

After this wave: NOTHING. The epic is closed; the only residual is the D12 backlog task.

## Close-out wave decisions (Decide, 2026-07-10 evening — these supersede D10 where they conflict)

*(Restored verbatim by the review pass: the close-out docs PR #2274 committed wave-log
entries citing D13–D21 while this defining section existed only in the Decide session's
uncommitted working copy — the references dangled on main until this commit.)*

Verification round complete (6 verifiers, first-hand proofs). The seals the wish asks for are
MERGED, FAITHFUL, and LIVE — this wave builds ZERO .ex. Its product is truth: an honest,
evidence-rich epic death certificate plus a clean scene.

- **D13 — Seal verified faithful; zero build slices.** #2177 implements D1–D5 with zero
  drift (verified line-by-line by two surveyors). Both deny files pass **FIRST-HAND at merged
  HEAD**: `CC=/usr/bin/clang mix test test/barkpark_web/controllers/grant_search_deny_test.exs
  test/barkpark_web/controllers/grant_single_doc_deny_test.exs` → **8 tests, 0 failures**
  (two seeds, all 8 named via --trace: denial cases + positive controls). Skip pattern
  extinct across api/test. `maybe_scope_to_grants` has exactly ONE def repo-wide
  (scope.ex:249). The two lanes no one had sealed on paper — federated search fan-out and
  loopback `search_local` — were traced firsthand and HOLD (D8 upgraded from recorded to
  proven): flat federated is bare `:api` (grant never folded, fails closed to Default scope,
  contract test 1/0), scoped federated narrows via the same ResolveWorkspace seam, and
  `search_local` is RequireLoopback-403 structurally unreachable by any grant principal.
- **D14 — Crown evidence = the first-hand deny run, NOT a live smoke.** The hoped-for live
  guerrilla grantee-denial smoke is IMPOSSIBLE with disposable resources, for two independent
  deployed reasons: (a) flat `/v1/data` grant routes are hardwired to the seeded Default
  workspace (assign_default_scope.ex:23) — a grant on an isolated throwaway workspace is
  never admitted; (b) the ONLY HTTP grant→user bind (`POST /v1/access/claim`) requires a
  confirmed-email account (claim_flow.ex:56/74) — a throwaway mailbox can't confirm.
  NO closeout text may claim a live narrowed read was executed; it provably wasn't and can't
  be. What WAS live-proven: grant mint/revoke, fail-closed claim, backlinks 200-not-404
  shape, deploy liveness.
- **D15 — CI honesty law.** #2177's required "Test (Elixir 1.18.1 / OTP 27.0)" check
  concluded **FAILURE** — 9,599 tests, 10 failures, ALL pre-existing `ChatLiveTest` reds
  identical on the base commit (repaired post-merge by #2192 ecff8270, already an ancestor of
  main; tracked+closed as task-085b24d019427644). The PR body's "7084 tests, 0 failures"
  claim is FALSE against the CI artifact. Nowhere may the ledger say "gate green" for #2177.
  The deny files' pass is cited via the first-hand 8/0 run (D13), not CI elimination.
  **ag-search-grant-leak criterion 6's stamped evidence is poisoned** (text asserts "gate
  green", evidence never proves it) — it gets corrected this wave.
- **D16 — One seal PR, not two.** No per-slice seal PRs ever existed: ONE integration PR,
  **#2177** (`integrate/airdrop-seal`), whose body carries only `Task: ag-search-grant-leak`
  (the backlinks slug was folded in without its own Task: line — say so plainly wherever the
  evidence trail enumerates task→PR links). Every criterion/close text that said "two seal
  PRs" / "both seal PRs" is reworded to "the single seal PR #2177".
- **D17 — "A-/ship" provenance.** The phrase exists ONLY in PR #2145's own body,
  author-self-declared; that PR has ZERO GitHub review objects and no grade appears anywhere
  in git history or the ledger. The wave log records it as the PR author's self-description
  ("judged A- / ship" — the author's own words), never as an external grade.
- **D18 — Anchor remediation mechanics (supersedes D10's claim-then-close for the anchor).**
  The anchor is ALREADY lifecycle done (patched directly at 16:50Z, bypassing ag-epic-closeout,
  criteria empty). Remedy: **patch + publish `acceptance_criteria` onto the done anchor** —
  mechanic PROVEN live on scratch task task-e2de78bb68847f03 (patch on a done task returns
  200, publish flips it, lifecycle stays done; no terminal-state guard) — and **refresh the
  anchor's close_reason** so its narrative is TRUE after this wave (single PR #2177, honest
  CI note, D11 commit, D12 task id). Never attempt claim/close on the done anchor. The
  claim/close cycle belongs to **ag-epic-closeout**: claim by explicit id (`bp task claim
  ag-epic-closeout <worker>` — lapsed claim, epoch 2, worker null; NEVER `bp task next`),
  read the fresh epoch from the claim response, close with criteria set IN the close call.
  Verify every write via `bp doc get` by id (`--perspective drafts` is unreliable — always
  echoes published).
- **D19 — D12 residual filed AT DECIDE.** `ag-broadcast-revoked-residual` (standalone, no
  parent, label proj:airdrop-grants, priority 3) is filed by the Decide phase itself, with
  the framing SHARPENED per verification: token/anonymous CallerContexts never carry grants
  AT ALL (from_token/1 and anonymous/0 never resolve grants; Grant binds exclusively to
  grantee_user_id) — structurally nothing to go stale, stronger than "reloads per request".
  The closeout slice verifies and cites it rather than filing it.
- **D20 — Debris pruning (slice ag-debris-prune).** Safe to prune NOW (content-verified
  absorbed/superseded by main, no PRs lost): `integrate/airdrop-seal` (+worktree wt-seal),
  `integrate/airdrop-endgame` (+wt-ag), `loop-epic/seal-the-search-grant-leak-thread-grant--0`
  and `-0-r`, `loop-epic/seal-the-backlinks-grant-leak-opts-condi-1` and `-1-r` (+their
  wf_35e83e2f worktrees), `loop-epic/deny-matrix-gap-tests-shared-grant-fixtu-1`,
  `loop-epic/plugin-pane-grantee-audit-grant-admitted-2` (+wf_9a68415a-061-9/-10, both clean),
  the orphan detached worktree wf_9a68415a-061-14, the six merged `feat/ag-*` branches
  (#1303/#1372/#1434/#1451/#1521/#1538) + their `/Volumes/SATECHI/github/bp-ag-*` worktrees,
  and the origin copies of merged branches. **`loop-epic/airdrop-grants-wave1-review-log` is
  deleted ONLY after the D11 retro text is verifiably on origin/main** — it is the sole copy
  of commit 48a18f85 anywhere. Never `git add -A`; never touch other sessions' dirty files
  in .claude/workflows/ (github-bridge charter + two untracked charters belong to concurrent
  sessions).
- **D21 — Expected reds, do not chase.** check-doc-budgets WILL fail on any md-touching PR
  (tenancy.md 8821 > 8300B, pre-existing, owned by task-c9927aee99f5e965) — advisory here.
  pr-task-gate requires the task claimed BEFORE the PR opens — claim ag-epic-closeout first;
  PR body carries `Task: ag-epic-closeout`. The docs PR is md-only → it does NOT wait for the
  Elixir Test gate (repo law: doc-only merges on its own gates).

## Roadmap — close-out wave (integration-ordered, 2 slices, zero .ex)

1. **ag-epic-closeout** (fable, small, priority 1) — execute D11 + D14–D19: correct the
   poisoned evidence, pay the wave-log debt (docs PR), stamp + truth-up the anchor, verify
   the residual, close itself. Files: .claude/workflows/bp-airdrop-grants-endgame-charter.md,
   .claude/workflows/bp-airdrop-grants-leakseal-charter.md (commit both, explicit paths) +
   ledger acts via bp.
2. **ag-debris-prune** (opus, small, priority 2) — execute D20. Prunes the safe list
   immediately; deletes the review-log branch only once the D11 text is on origin/main.

Backlog filed at Decide (not this wave's build): `ag-broadcast-revoked-residual` (D19),
`ag-deny-matrix-residual-coverage` (scoped-federated narrowing contract test + RequireLoopback
403 contract test — the two unasserted cells verification flagged), `bp-drafts-perspective-bug`
(`bp doc query/ls --perspective drafts|raw` silently ignored; drafts invisible except via
`bp doc get` by exact id — burned a verifier, left 2 unreachable orphan drafts on guerrilla).

After the close-out wave: NOTHING. The epic is closed; the only residual is the D19 backlog
task.

## Wave log

_(the epic-complete entry itself belongs in bp-airdrop-grants-endgame-charter.md per D11)_

### Wave 2026-07-10 — leak-seal (2 of 3 slices built; close-out correctly BLOCKED)

**Landed (review-fixed, gates green, RED-before independently re-proven):**

- **ag-search-grant-leak** — sealed per D1+D2+D3: `grant_scoped` threads through
  `QueryPipeline.retriever_opts` (one point covers primary + drop-tokens + typo-widen);
  the ONE public wrapper `Content.Scope.maybe_scope_to_grants/2` hoisted, private copy in
  `Content.Query` deleted (call sites re-pointed via import); `DocumentsRetriever`
  applies it once on `base` (results+count+facets, every route); Indx forwards the flag
  (rows via `get_documents_by_ids`) and recomputes `total` via new grant-narrowed
  `Content.count_documents_by_ids/3` (fail-closed, 2 new unit tests). Deny test un-skipped
  in the same PR. Reviewer re-proved RED-before by reverting pipeline+retriever to main:
  exactly 1 failure (the deny), positive control green; restored → 0. Gate: 659/0.
  Reviewer fix: one `mix format` nit. **Final branch:
  `loop-epic/seal-the-search-grant-leak-thread-grant--0-r`.**
- **ag-backlinks-grant-leak** — sealed per D4+D5 inside the shared Graph helpers:
  `resolve_doc/3`, `scope_query/2` (docs_by_id/hydrate_nodes/fetch_doc → HTTP backlinks,
  scoped-route backlinks AND the Studio graph/blast-radius pane), `scoped_docs_query/1`
  (defense-in-depth, inert today). Uncovered target → nil → `[]` backlinks (200, never
  404). 4 new unit tests (resolve_doc / reverse_referencers / traverse hydration /
  nil-ctx fail-closed) + un-skipped HTTP deny. Reviewer re-proved RED-before by reverting
  graph.ex to main: 5 failures; restored → 31/0. Reviewer fixes: **performed the D7
  pre-merge swap** (branch rebased onto the search -r branch; all three bridge
  `if opts[:grant_scoped]` guards → `Scope.maybe_scope_to_grants/2`; wrapper doc +
  tenancy.md consumer lists gain the Graph helpers) and refreshed the deny test's stale
  "backlinks LEAKS" moduledoc. **Final branch:
  `loop-epic/seal-the-backlinks-grant-leak-opts-condi-1-r` — STACKED on the search -r
  branch; merge search first, then this (its PR diff collapses to graph-only once search
  merges).** Combined suites on the stack: 813/0.

**Stalled (honestly):** **ag-epic-closeout** — builder verified its precondition unmet
(no seal PRs merged) and refused to fabricate a close; task left claimed + in_progress,
all criteria unmet, zero code changes. Correct per the false-done finding. It
pre-recovered the D11 inputs (stranded #2145 retro at commit 48a18f85; authoritative
test count 6,348; D12 backlog framing for `broadcast_revoked/1`).

**Ledger:** all three wave tasks truthful (claims live, evidence stamped, merge-gated
criteria left for the lead); anchor untouched (open, unclaimed, 0 criteria). No fixes
needed.

**Next wave / lead:** merge search-r (Elixir Test gate — .ex waits for it), then
backlinks-r; flip both merge-gated criteria; then re-run **ag-epic-closeout** exactly as
specced (D10 stamp anchor, D11 wave-log debt in bp-airdrop-grants-endgame-charter.md,
D12 file the ONE broadcast_revoked backlog task, close the anchor). Note the closeout
claim (epoch 1) may lapse — re-claim before closing. After that: NOTHING remains on this
epic.

### Wave 2026-07-10 evening — close-out wave (Decide)

Verification round (6 verifiers, first-hand proofs) established: the seals merged as ONE
integration PR #2177 (not the two -r branch PRs the log above anticipated — they were folded
into `integrate/airdrop-seal` and never surfaced as PRs), faithful to D1–D5, live on
guerrilla; both deny files pass first-hand at merged HEAD (8/0, two seeds); federated +
search_local lanes hold. THREE TRUTH CRACKS found and decided (D15–D18): #2177's Elixir CI
check was FAILURE (pre-existing ChatLiveTest reds, fixed in #2192) and ag-search-grant-leak's
"gate green" evidence is false; the anchor was flipped done directly at 16:50Z with empty
criteria while ag-epic-closeout stayed open (false-done); the live grantee smoke is
impossible with disposable resources (D14). Wave cut: 2 slices, zero .ex —
**ag-epic-closeout** (fable) + **ag-debris-prune** (opus). Backlog filed:
ag-broadcast-revoked-residual, ag-deny-matrix-residual-coverage, bp-drafts-perspective-bug.
Wave Paper: `airdrop-grants-wave-2026-07-10-close`.

### Wave 2026-07-10 (evening) — seals merged, close-out executed, EPIC COMPLETE

The lead deviated from D7's two-PR order: both seal branches integrated on ONE branch and
merged as the **single PR #2177** (`integrate/airdrop-seal`, squash 989a9c75,
2026-07-10T14:54:45Z) — there were never two seal PRs (D10's "two seal PRs" line is
superseded; the PR body carries only `Task: ag-search-grant-leak`). Deploy run 29101630245
green → live on guerrilla. First-hand proof at merged HEAD: both deny files → **8 tests,
0 failures**. CI honesty (D15): #2177's required Elixir check concluded FAILURE — 10
pre-existing ChatLiveTest reds identical on base, repaired post-merge by #2192 (ecff8270);
never recorded as "gate green". A live guerrilla grantee-denial smoke was proven IMPOSSIBLE
with disposable resources (D14) and never executed.

**ag-epic-closeout** then ran as specced: poisoned criterion-5 evidence on
`ag-search-grant-leak` corrected to the honest CI story + first-hand 8/0; the D11 wave-log
debt paid in `bp-airdrop-grants-endgame-charter.md` (adopted 48a18f85 retro corrected to
the authoritative 6,348 full-battery count + the epic-complete entry); the anchor
`airdrop-grants` stamped with published acceptance_criteria carrying the full evidence
trail and a truthful close_reason; residual `ag-broadcast-revoked-residual` verified
published/standalone/priority 3 (D12). The epic is CLOSED — nothing remains.

### Wave 2026-07-10 — close-out wave (reviewed; grade A-)

**ag-epic-closeout** — SHIPPED, honest end to end. PR #2274 (squash 8032d5c8, doc-only,
merged by the builder per repo law) pays the D11 debt exactly: adopted retro under "the
endgame wave (reviewed)" with the 6,348 correction, plugin-pane NO-LEAK, falsified
write-side suspicion, "A-/ship" attributed per D17; epic-complete entry carries #2177,
first-hand 8/0, deploy run 29101630245, D14 impossibility, D15 CI-FAILURE truth. Ledger
verified first-hand: anchor `airdrop-grants` done+published with 6 met criteria and zero
"gate green"; ag-search-grant-leak criterion-5 evidence now states the FAILURE verdict;
residual published standalone P3. The builder's pre-existing-red merge call ("Doc budgets +
anchors", broken on main by #2273's bulldocs literal) was verified proven and filed
(design-check-part-e-bulldocs-red). **Reviewer fix:** the committed wave-log entries cited
D13–D21, but that defining Decide section lived only in the Decide session's uncommitted
working copy — restored verbatim (plus the Decide wave-log entry) on
`loop-epic/epic-close-out-correct-poisoned-evidence-0-r`; the stale working copy in the
main checkout was backed up and reset to HEAD so `make update` stays unblocked.

**ag-debris-prune** — SHIPPED, refs-only (no commit, correctly no branch). 14 enumerated
branches + 14 worktrees + orphan + 8 origin copies of MERGED PRs pruned; per-worktree clean
checks held; the 11 non-enumerated `feat/ag-*` branches with live bp-ag-* worktrees
correctly untouched. The literal charter gate can NEVER pass — its `feat/ag-*` glob
over-matches those 11 out-of-scope live branches (Decide-phase gate-authoring flaw); the
builder reported the honest scoped gate instead of fabricating green — correct call. The
D11 guard held at build time (retro not yet on origin/main → review-log branch left
intact, stamped honestly). **Reviewer completion:** guard re-checked post-merge (grep -c =
1 on origin/main) → `loop-epic/airdrop-grants-wave1-review-log` (48a18f85) deleted; D20
now fully discharged; evidence appended to criterion 1 and re-published. The lead
verification criterion (index 3) stays open for the lead.

**Wave verdict:** the wish is fully served as merged — seals live, deny repros protective,
epic closed on a truthful, evidence-dense trail. Deductions: the D13–D21 dangling
references reached main (permanent-record defect, review-fixed) and the unpassable
debris gate glob. After the -r branch merges: NOTHING remains on this epic. Residual
backlog stands published: ag-broadcast-revoked-residual (P3),
ag-deny-matrix-residual-coverage (P3), bp-drafts-perspective-bug (P2),
design-check-part-e-bulldocs-red (P1, main's Doc budgets job is red for every PR until
fixed — cross-epic, urgent for whoever owns docs CI).

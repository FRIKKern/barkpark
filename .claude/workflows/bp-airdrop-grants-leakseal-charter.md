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

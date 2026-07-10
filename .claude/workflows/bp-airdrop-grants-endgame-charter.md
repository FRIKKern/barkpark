# Time-Boxed Airdrop Grants — Enforcement Endgame Charter

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **cmux-bridge** charter formerly here is preserved verbatim at
> `.claude/workflows/bp-cmux-bridge-charter.md` (agent-onramps waves remain at
> `bp-agent-onramps-*-charter.md`). This file is now the memory of the
> **airdrop-grants enforcement-endgame** wave.

Epic anchor: bp task slug **`airdrop-grants`** (UUID 06ea2166-7301-4c8a-9c48-4dd16aa3492e — `bp task get` resolves the SLUG, 404s the UUID). 20 children (`ag-*`), 18 done. Server: guerrilla. Design paper: `time-boxed-airdrop-grants`.

## Vision

A grant = {scope slice, principal, expiry} that is **indistinguishable from no grant the moment it stops being valid — on every surface, at every moment**, including a grantee sitting inside a mounted LiveView desk when the clock runs out or the grantor clicks revoke. Enforcement LANDED across ~14 merged PRs (#1303→#1538); the 2026-07-09 crash killed nothing. This wave is the endgame: close the ONE confirmed leak (LiveView read-path mount-snapshot staleness), prove the rest airtight with DENY-matrix protective tests (vacuous-green law), give the grantor an honest Access panel with countdown chips and one-click revoke, stamp the MCP/CLI parity evidence, and finish the ledger. **Never rebuild what landed.**

## Ground truth (wave exploration, 2026-07-10)

- **HTTP paths are airtight.** Scoped reads (ResolveWorkspace → Access.admits_desk? → scope_to_grants, fail-closed where:false), flat reads (:api_grant_read = ResolveTokenOwner + AssignGrantScope, read-only by design so caller_context can never downgrade a write), writes (grantees are tokenless Users; AssignGrantScope never mounts on writes; WriteScope stamps server-authoritative scope). CallerContext.from_user reloads ACTIVE grants in-query per request → expiry/revocation fresh every request.
- **LiveView WRITES are already closed** — the #1504 Caps gate re-runs `derive(socket)` per :write/:admin/:deny event, and `Caps.derive` reloads grants via `Access.list_active_grants_for_grantee/1` (active-filtered in SQL). Mid-session expiry AND revoke are caught; tested at `studio_live_caps_gate_test.exs:319`. The strategize-phase worry ("event gate must re-check expiry") was already satisfied for writes.
- **LiveView READS are the leak.** `select*` events are `@safe_events` (:none tier) → the Caps gate `{:cont}`s without re-deriving. Reads narrow via `scope_to_grants` fed the MOUNT-TIME `:caller_context` snapshot (`scope_opts(socket)` → `from_conn` returns the assign verbatim; `live_scope.ex:384-388`). `covers_workspace_read?` (scope.ex:244-248) re-checks only grantor authority — never the grant's own `expires_at`/`revoked_at`. The slice-3 expiry reaper (`studio_live.ex:107-131,176-184`) refreshes only `:caps` + `:access_grants`, NOT `:caller_context`. Revoke emits NO live signal (audit-only; the only grantee push is `{:airdrop_granted}` on mint). Net: expired grant → reads leak, writes blocked; revoked grant → reads leak, writes blocked (Caps re-derive catches it), until reconnect.
- **DENY suite is broad and genuinely non-vacuous** (~2,900 LOC, 8 files) but has named empty cells: search-with-grant (SearchController rides :api_grant_read + scope_opts but ZERO grant tests), QueryController.show/backlinks by-id (classic leak shape, untested on HTTP), flat-route HTTP expired/revoked (only transitively covered), FederatedSearchController (bare :api — assert fail-closed, not silently widened), mid-session REVOKE on a socket. Four test files carry byte-identical ~30-line `grant_authority!`/`bind_grant!` helpers — a 4-way drift hazard, no shared fixture exists.
- **legacy_controller is NOT a grant surface** (rides `[:api,:require_token,LegacyDeprecation]`, no AssignGrantScope; caller_context only for field-visibility). The "query vs legacy grant-deny drift" premise from the wish is moot — both share ONE FallbackController for error shape. Recorded as n/a, not a gap.
- **Field-visibility (Envelope.render) is a separate, sealed axis** — row scoping (grants) vs field scoping (visibility); a grantee's CallerContext flows into render/3 and still gets private fields redacted; nil caller fails closed to anonymous.
- **Plugin-owned reads (tasks/sheets/media/tickets/quiz) have NO scope_to_grants** — unreachable over HTTP for grantees (token-gated), but whether a grant-mounted Studio socket loads plugin-pane data is UNVERIFIED. Must-verify grey area this wave.
- **Parity (pillar 3) is COMPLETE.** All six access verbs (grant/ls/show/revoke/claim/mine) exist on /v1/access, in the capabilities manifest as CORE commands, in `bp access` (verified live against guerrilla), and reach MCP via the generic manifest→MCP bridge (`bp mcp serve --tools all`; bridgeShadowedIDs excludes only the five curated task verbs). The bridge SHIPPED as mcp-w1 #1790 — child `ag-manifest-mcp-bridge` is done-by-another-epic; the wish's "e663def2" id is unresolvable on guerrilla and denotes this same shipped capability.
- **Access panel ground truth:** `airdrop_sheet/1` is a mint-only FUNCTION component (deliberately not a LiveComponent) in `studio_components/modals.ex:312`, already on the bp_radio/bp_checkbox kit. No Studio surface lists or revokes grants. Verbs already exist: `Access.list_grants_for_workspace/1` (active-filtered in-query, workspace view — NO grantor-own filter exists), `Access.revoke/2` (idempotent, server-authorized grantor-or-admin), plus the `:access_grants` grantee assign already on the socket. `shares_modal` (P6 network shares) and `item_share_popover` (/s/ links) are DIFFERENT features — do not touch.

## Decisions

1. **Fix the read leak with event-driven refresh, not per-select DB reloads** — refresh `socket.assigns.caller_context` (fresh `CallerContext.from_user`) in the existing `:access_expiry_tick` handler, AND add a grantee-addressed revoke PubSub broadcast from `Access.revoke/2` (mirror the mint-time `{:airdrop_granted}` push) whose handler reloads grants + caller_context; if admission no longer holds (no covering grants, not a member) the socket re-runs mount authorization and dies/redirects. Why: the tick + broadcast cover exactly the two liveness events (expiry, revoke) at zero hot-path cost, matching the reaper architecture already in place; per-select reloads tax every navigation to catch events that announce themselves.
2. **Defense-in-depth in the covering predicate** — `covers_workspace_read?` additionally re-applies the active predicate on the struct (`expires_at` time-compare; `revoked_at` nil-check is stale-safe only for expiry). Why: catches expiry even if a refresh path is ever missed; explicitly NOT sufficient alone for revoke (snapshot's revoked_at is nil forever) — the DB reload in decision 1 is the revoke truth.
3. **One shared grant fixture, then fill the named DENY cells** — consolidate the 4 duplicated `grant_authority!`/`bind_grant!` helpers into `test/support/access_fixtures.ex`; add deny tests for: search-with-grant, QueryController.show + backlinks out-of-scope-by-id, flat-route HTTP expired/revoked, FederatedSearch fail-closed. Why: the fixture removes a 4-way drift hazard and is what every new deny test would otherwise copy a 5th time; the cells are the only genuinely unproven surfaces.
4. **query-vs-legacy deny unification is CLOSED as n/a** — legacy is not a grant-narrowing surface; both controllers already share FallbackController. Why: evidence overrode the wish's premise; building a unifier for a non-existent pair is waste.
5. **Plugin-pane grantee exposure gets a verdict, not an assumption** — a slice verifies whether a `{:grant,ctx}`-admitted socket loads plugin-pane data (tasks/sheets/media have no scope_to_grants); protective test either proves fail-closed or the slice gates plugin panes OFF for grant-scoped sockets (fail-closed by absence — grants cover documents, not plugin content). Why: the one grey area a reading could not settle; gating off is the only fix that adds no new enforcement seams.
6. **Access panel = sibling `access_panel/1` function component** extending the kit in `modals.ex` — NOT a fork of airdrop_sheet, NOT a LiveComponent. Two honest sections: "Your access" (grantee's own `:access_grants` assign, countdown chips) and "Active grants in this workspace" (`Access.list_grants_for_workspace/1`, membership-gated, one-click revoke via `Access.revoke/2`). Why: reuses the two existing list verbs verbatim — zero new query paths, zero new enforcement seams; the workspace view matches the API index semantics (a grantor-own filter would be a new query path, forbidden this wave). `access-open`/`access-close` join `Caps.@safe_events`; `access-revoke` classifies :write (server re-authorizes anyway). Countdown = client-side JS on `data-expires-at`; a row whose clock hits zero vanishes on next re-list because `active_where` excludes it — the panel is a live-active view, not a history log (recorded, accepted).
7. **`ag-manifest-mcp-bridge` closes as shipped-by-another-epic** (mcp-w1 #1790 + w2 annotations); the "e663def2" reference is this same capability. Remaining parity work is EVIDENCE, not build: a Go guard test pinning that no `access.*` verb is bridge-shadowed, plus one live `--tools all` tools/list stamped into the ledger. Caveat recorded: **MCP access parity = `--tools all`** — the default `--tools tasks` is deliberately curated (Cursor's 40-tool cap); do not mistake the default surface for a gap.
8. **Builder laws**: worktrees from origin/main after `git fetch`; claim BEFORE working; PR body carries `Task: <id>`; `.ex/.heex` changes WAIT for the Elixir Test CI gate (Go-only slices merge on the Go gate); Elixir local gates run in a checkout with a warm `_build/test` (build-borrow into fresh worktrees is broken — see lockfree-worktree-gate); `CC=/usr/bin/clang` on every Go/mix gate (cc alias shadows clang); raw ids guarded with `Ecto.UUID.cast` (binary_id 500 gotcha); every enforcement test proves the DENY path with a positive control beside it.

## Roadmap

**Wave 1 (this wave — the endgame, 5 parallel slices):**
1. `ag-liveview-read-liveness` (large, priority 1) — fresh grant truth for socket reads: tick refreshes caller_context; revoke broadcasts; dead grant = dead desk. Owns `live_scope.ex`, `studio_live.ex` (reaper region), `access.ex` (revoke broadcast), `scope.ex` (covering predicate), + NEW socket deny test file.
2. `ag-deny-matrix-gaps` (medium, priority 1) — shared `access_fixtures.ex` + the empty DENY cells (search, show/backlinks, flat expired/revoked, federated). Test-only.
3. `ag-plugin-pane-grantee-audit` (small, priority 1) — verdict + protective test on plugin-pane data for grant-scoped sockets; gate off if leaky.
4. `ag-studio-access-panel-countdown` (medium, priority 2, pre-existing child) — the Access panel per decision 6.
5. `ag-access-mcp-parity-proof` (small, priority 2) — Go guard test + live tools/list evidence per decision 7. Go-only.

**Ledger acts this wave:** `ag-manifest-mcp-bridge` closed with #1790 evidence (decision 7). 18 done children left untouched — their DENY coverage was re-verified by exploration, no false-done found in this tree.

**After this wave:** the epic anchor `airdrop-grants` closes when the five slices merge and the reviewer confirms the socket deny test red-before/green-after story. Nothing further is roadmapped — the epic is done at that point unless the plugin-pane audit (slice 3) uncovers a leak large enough to warrant its own follow-on.

**Parked:** grantor-own ("grants I minted") panel filter — needs a new grantor_id query path; file under a future UX vein only if users ask. Grant history view (expired/revoked rows) — needs a non-active query, same story.

## Wave log

### Wave 2026-07-10 — the endgame wave (reviewed)

*(Adopted from the stranded #2145 retro — sole copy was commit 48a18f85 on the local-only
branch `loop-epic/airdrop-grants-wave1-review-log`; folded here per the leak-seal charter's
D11, with the test count corrected to the authoritative full-battery number.)*

**All five slices built green and reviewed; integration-proven.** The reviewer scratch-merged all
five onto origin/main (including the mid-wave `#2138` scope-chip landing): zero conflicts,
`mix compile --warnings-as-errors` clean, **6,348 Elixir tests 0 failures** (full `test/barkpark`
battery per the #2145 PR body — the retro as originally drafted cited the reviewer's 1,982-test
partial run), Go `internal/cli` green. The wave merged as PR #2145 (602eb4a3, 2026-07-10T08:50Z).
The PR body's "judged A- / ship" is the **PR author's own self-description** — zero GitHub review
objects exist on that PR; it is not an external grade.

1. **ag-liveview-read-liveness** — the ONE confirmed leak is CLOSED. Tick + `{:airdrop_revoked}`
   broadcast rebuild `caller_context`, re-derive caps, re-run admission (dead grant = dead desk,
   redirect /login); `covers_workspace_read?` re-applies expiry on the struct (revoke asymmetry
   documented). RED-before/GREEN-after proven for all three DENY tests. The strategize-phase
   **write-side suspicion was FALSIFIED**: writes were already gated per event (the #1504 Caps
   gate re-derives on every :write/:admin event) — the real leak was reads on a live socket.
   Reviewer fixed one `mix format` violation → final branch
   `loop-epic/liveview-read-liveness-expired-revoked-g-0-r`.
2. **ag-deny-matrix-gaps** — shared `test/support/access_fixtures.ex` (4-way drift hazard gone);
   show/federated/flat-expired+revoked cells filled with deny + positive controls. Found TWO REAL
   LEAKS empirically: **search** (grant_scoped dropped in `QueryPipeline.retriever_opts`,
   reviewer-verified in code) and **backlinks** (`reverse_referencers`' `resolve_doc`/`docs_by_id`
   never grant-narrow). Both committed as `@tag :skip` executable repros; fix tasks
   `ag-search-grant-leak` + `ag-backlinks-grant-leak` filed (reviewer added acceptance criteria +
   published them). The criterion-3 reframe ("expired ⇒ back-compat, not zero rows" on the flat
   route) is CORRECT — grants narrow, never gate, and "expired = byte-identical to no grant" is
   proven literally.
3. **ag-plugin-pane-grantee-audit** — VERDICT: NO LEAK. The pane path reads all plugin content
   through the type-agnostic `Content.Query.base_query → maybe_scope_to_grants` seam
   (file:line trace in the test moduledoc); a mutation-probed rendered-desk guard pins it.
4. **ag-studio-access-panel-countdown** — `access_panel/1` beside `airdrop_sheet` on the kit;
   "Your access" + membership-gated workspace grants with one-click revoke; `ExpiryCountdown`
   client hook; zero new query paths; both deny layers tested (Caps :write gate AND server
   grantor-or-admin refusal).
5. **ag-access-mcp-parity-proof** — Go guard (no `access.*` in `bridgeShadowedIDs` + the six
   `bp_access_*` tools generate over a live MCP session) + guerrilla `--tools all` evidence +
   the curated-default caveat comment. Go-only, merges on the Go gate.

**Ledger:** five wave tasks in_progress with honest evidence, merge-gated criteria open for the
lead; `ag-manifest-mcp-bridge` closed with #1790 evidence; leak tasks published with criteria.

**Handoff taken by the leak-seal wave:** fix the two leaks, un-skip the repro tests as the
red-before proof, then close the epic anchor `airdrop-grants`. (Executed — see the next entry.)

### Wave 2026-07-10 — leak-seal + epic close (EPIC COMPLETE)

Decision record: `.claude/workflows/bp-airdrop-grants-leakseal-charter.md` (D1–D21).

- **ONE seal PR, not two.** Both leaks — search (D1+D2+D3: `grant_scoped` through
  `QueryPipeline.retriever_opts`, the single public wrapper `Content.Scope.maybe_scope_to_grants/2`,
  the `DocumentsRetriever` base-query seal, the Indx grant-narrowed total) and backlinks
  (D4+D5: opts-conditional narrowing inside the shared Graph helpers `resolve_doc/3`,
  `scope_query/2`, `scoped_docs_query/1`) — merged together as the single integration
  **PR #2177** (`integrate/airdrop-seal`, squash **989a9c75**, 2026-07-10T14:54:45Z). There
  were never two seal PRs; the PR body cites only `Task: ag-search-grant-leak` (the backlinks
  slug was folded in without its own `Task:` line).
- **Crown evidence (first-hand at merged HEAD):**
  `CC=/usr/bin/clang mix test test/barkpark_web/controllers/grant_search_deny_test.exs
  test/barkpark_web/controllers/grant_single_doc_deny_test.exs` → **8 tests, 0 failures**
  (seeds 823631 and 402530; denial cases + positive controls, all 8 named via `--trace`).
  The `@tag :skip` repros from the endgame wave were un-skipped in the same PR with
  non-vacuous RED-before proof on pre-fix code.
- **CI honesty (D15):** #2177's required `Test (Elixir 1.18.1 / OTP 27.0)` check concluded
  **FAILURE** — 9,599 tests, 10 failures, ALL pre-existing Studio ChatLiveTest reds identical
  on the base commit (repaired post-merge by #2192 ecff8270 on main; tracked closed as
  task-085b24d019427644). The PR body's "7084/0" claim is false. This merge is NOT recorded
  as "gate green" anywhere.
- **Deploy:** run **29101630245** green → live on guerrilla.
- **Live-smoke impossibility (D14):** a live guerrilla grantee-denial smoke was proven
  IMPOSSIBLE with disposable resources — flat `/v1/data` routes hardwire the seeded Default
  workspace (`assign_default_scope.ex:23`) and `POST /v1/access/claim` requires a
  confirmed-email account (`claim_flow.ex:56/74`) — and was never executed. The first-hand
  deny suite above is the proof of record.
- **Epic closed.** Anchor `airdrop-grants` carries the full honest evidence trail (15
  enforcement PRs #1303 #1339 #1353 #1372 #1398 #1431 #1432 #1434 #1442 #1451 #1491 #1504
  #1521 #1527 #1538; endgame #2145; seal #2177) as published acceptance_criteria. The one
  residual is filed standalone (D12): `ag-broadcast-revoked-residual` — `broadcast_revoked/1`
  no-ops for unbound grantees; explicitly NOT a confirmed leak (zero blast radius today),
  priority 3, no parent. Nothing else remains on this epic.

# Charter — AXI alignment: brief views in the capabilities contract

Epic task: `task-908417832622ea39` · Driving review: `/papers/axi-agent-ergonomics-review` (guerrilla) · Wave Paper: `axi-brief-views-wave-2026-07-18` · Filed 2026-07-18, decided (post-verification) 2026-07-18.

## Mission

Implement the AXI (axi.md) efficiency and disclosure principles as **capabilities-manifest contracts**, so every agent surface — bp CLI, `bp mcp serve`, Studio chat loopback, `bp chat`, JS SDK — inherits them from one server-side implementation. Never hand-carve per-command fixes: the manifest is the moat; anything done per-surface must be a projection of a manifest-declared contract.

## Measured baselines (2026-07-18, guerrilla, admin tier — beat these, then restate them in the paper)

| Probe | Today (re-measured at verify) | Target |
|---|---|---|
| `bp task ready` (50 tasks, piped JSON) | 356,325 B | ≤ 15 KB |
| `bp task prime` | 112,858 B (drifted from 104 KB — re-baseline before/after) | ≤ 5 KB |
| `bp task prime --worker <self>` (the real resume scenario; ready = 64.6% of it) | 71,451 B | ≤ 5 KB |
| `bp search query "herd layer"` (242 hits) | 2,284,412 B | ≤ 45 KB |
| MCP `task_ready` (JSON-RPC envelope) | 287,390 B | brief cards |
| MCP `task_prime` (JSON-RPC envelope) | 72,603 B | brief cards |

Measured brief projection of 11 live worker-scoped prime docs: 50,421 B → 4,107 B (>12x). Prime lands ≤5 KB only if the brief prime response also trims `recent_events` to 5 rows (10 rows = 903 B pushes it to ~5.16 KB).

## Decisions (final — verification-backed; follow these, not earlier drafts)

1. **Rollout = ONE PR with request-side opt-in emission, NOT two-PR sequencing.** Proven: `DisallowUnknownFields` recurses into Command (test-proven), so a stale installed binary bricks on any unknown command-level key **regardless of merge order** — two-PR ordering protects nothing (binaries upgrade on no schedule; `min_cli` is dead; no version header). The proven-safe mechanism is the `?build=1` precedent (bb8484dee, shipped Go model + server emission in ONE commit): the server emits the command-level `views` key **only when the caller sends `?views=1`** on `GET /v1/capabilities` (gate structurally identical to `maybe_put_build`, capabilities.ex:244-250). Stale binaries never send it → always receive the exact old shape. ETag is content-addressed over the projected body, so views/non-views bodies get distinct etags — no 304 cross-contamination. `docs/cli/manifest.schema.json` gains the additive optional command-level `views` $def in the same PR (it is `additionalProperties:false`). No `manifest_version` bump — no bump discipline exists and the field is additive-optional.
2. **`views` descriptor shape (frozen for this wave):** `views: {"supported": ["brief","full"], "default": "full", "default_for_agents": "brief"}` on `task.ready`, `task.prime`, `search.query`. Commands without a `views` key are full-only forever — `task.get`/`task_show` never declare it; they ARE the escape hatch. Go models `Views *Views` (`json:"views,omitempty"`) on Command with exactly those three keys (strict decode requires modeling every emitted key).
3. **Brief card (task) =** `id`/`doc_id`, `title`, `status`, `lifecycle_status`, `priority`, `assignee`, `claim{worker, epoch, now}`, `criteria_met`/`criteria_total`, `child_count`, `parent_id`, `updated_at`. **No `content` echo, no `work_digest`/`work_field_digests`.** `child_count` is NET-NEW on list routes: build `batch_child_counts/1` mirroring `batch_edge_counts/1` (params.ex:190-205 — one grouped query over `type:"task"` by stripped `content->>'parent_id'`), **with the same workspace/project tenancy filters `show`'s `child_tasks/2` applies** (unscoped copy = cross-tenant existence-count leak). `claim.now` already exists fully formed — it just survives the cut.
4. **De-dup (R2): full view keeps exactly ONE claim copy — the TOP-LEVEL one.** Evidence: every Go consumer (apiclient `ClaimEpoch`, cmux, taskboard wire struct, run.go mutation printer), all controller tests, and `TaskResolver.worker_of/1` (task_resolver.ex:379-384, feeds web/ + @barkpark/react task-boards) read top-level `claim`; `content.claim` has ZERO confirmed HTTP-envelope readers. So: full view's `content` echo drops its `claim` key (top-level `claim` stays, sourced as today from `Map.get(content,"claim")`); brief has top-level `claim{worker,epoch,now}` only. Storage (`Document.content["claim"]`) is untouched — it is the write-path source of truth.
5. **Server route defaults stay FULL.** SDK/Studio/taskboard/web untouched (taskboard TUI fetches hardcoded URLs with no view param — proven safe on two counts). Clients opt in: CLI resolves brief in `runCommand` (option B, verified): `globals` gains a `view` field + `--full` boolFlag; brief when `out.machineOut()` (json/yaml — folds piped-default and explicit `-o json`; explicit `-o table` while piped stays full) AND `!g.full` AND the command declares `views`; `applyQuery` appends `?view=` when `g.view != ""` (zero signature changes — g is already threaded). MCP `task_ready`/`task_prime` set `view=brief` on their local `g` before `execManifestCommand`; bridge tools inherit generically wherever a command's manifest declares `default_for_agents`. Never resolve inside `buildManifestRequest` (it is pure, writer-less, and headless MCP shares it). Server tolerance for early `?view=` senders is proven (byte-identical 200s on ready/prime with unknown view values — controller never reads the param today).
6. **R5 help[] hooks at `runCommand` post-2xx** (the `warnIfDefaultPageMayBeTruncated` call-site pattern, run.go:236-240 — proven to fire in all four output modes), **never inside `renderSuccess`** (proven structurally silent under `-o json`/`-o yaml`). Server authors `help[]` next to the six mutation emitters (claim, claim_by_id, stamp, pulse, close, release — precedent: `close_response/1`'s `warnings:` sibling): 1–3 concrete command templates with REAL ids/epochs. **Pulse BUMPS the epoch — its help[] must carry the fresh response epoch, never the caller's.** MCP surfaces help[] for free (raw body passthrough). `--frontier` and cmux dispatch bypass runCommand — exempt this wave, filed as backlog.
7. **R3 includes `search_channel`** — it is live infrastructure (web finder + site-spawner-provisioned sites; `find-shape.ts` treats HTTP and WS replies as one shape — deferring WS = user-visible divergence). One shared hit-envelope builder serves `search`, `search_local`, and the channel's `build_reply` (three byte-identical 9-field emitters today); **federated** documents surface adopts it via a thin re-keying adapter (`hits`/`total`, no correctedTo/facets/truncation); federated **media surface is out of scope** (AssetResponse renderer, not a document). Snippets: extend `Highlighter.document_field_text/2` with a bounded window around the first match (no `ts_headline` this wave — none exists in the repo); brief search cards route through the sealed `field_readable?` predicate (`visible_highlight_fields` pattern) — hand-rolled cards that bypass Envelope are a leak. Default stays full → the six pinned shape tests stay green untouched; `view=brief` gets new tests. Channel carries `view` in the query message params.
8. **R7 re-specified — the exit-0 premise is REFUTED** (measured: bare `bp` exits 1 on failure AND on healthy-server-no-TTY; `bp <noun>` bare exits 2). Real fixes: (a) schema-load failure advice becomes target-appropriate (derive from `cfg.BaseURL`/`ServerSource()` — remote host → "check <url> is reachable / bp doctor", local → mix phx.server), replacing the hardcoded main.go:81 string; (b) non-TTY with schemas LOADED prints a compact AXI-style status card (`bin:`/`description:`/`count:`/`help[N]:` lines) instead of surfacing bubbletea's raw "could not open a new TTY" error — exit 0 on a successful card, nonzero on failure; (c) `bp task` bare gains ONE live counts line (from `/v1/tasks/prime` `counts`) above the verb list. Per-noun counts for other nouns: deferred (no bundled counts endpoint exists — backlog).
9. **NEW slice — guerrilla `ticket.status` schema outage** (found live at verify): tickets.ex:139-146 ships `type:"string"` + `options: %{"list" => [...]}` — the sole outlier among 22 options-bearing fields — and apiclient's strict `Options []string` decode kills ALL client schema loading against guerrilla (TUI boot, scope switcher, paper doc-resolution). Fix both ends: tickets.ex → `type:"select"` + flat options array (the codebase's own convention), AND schema.go decodes Options tolerantly (the file's own stated philosophy, already applied to Validation). This blocks R7's live testing and is a present-tense outage — own slice, this wave.
10. **R4 layered:** the last-resort byte guard lives in `mcpRun` (mcp_tasks.go:803) — ONE clamp covers 7/8 curated + all ~107 bridge tools (task_create's compact receipt needs none). Truncation notice follows the AXI format with the byte total and the exact escape command. Server-side, brief projection IS the diet; the `--all` nudge (`warnIfDefaultPageMayBeTruncated`) is already the house pattern.
11. **mcp_tasks.go:478 docstring** ("content.claim.epoch") becomes actively wrong under brief — rewritten to `claim.epoch` in the same Go slice, not follow-up debt.
12. **Brief prime trims `recent_events` to 5 rows** (full keeps 10) — required to clear the ≤5 KB target.
13. **Vocabulary note:** task documents already carry a `content.brief` authoring field (PortableDoc body). The view name "brief" collides in vocabulary only, not wire shape — docs must say "brief VIEW" when ambiguity is possible.

## Wave-1 plan (slices + rounds — rounds are law)

| Slice | Task | Surface | Round | Model |
|---|---|---|---|---|
| S1 brief view + de-dup + child_count (R1/R2 server) | `axi-s1-brief-view-dedup` | Elixir tasks_controller/params | 1 | fable |
| S2 manifest `views` declaration, `?views=1` opt-in emission | `axi-s2-manifest-views-optin` | Elixir capabilities + schema.json | 1 | opus |
| S3 CLI/MCP brief consumption + mcpRun guard + help[] render | `axi-s3-cli-brief-consume` | Go manifest/cli/mcp | 1 | fable |
| S4 success-side help[] templates (R5 server) | `axi-s4-help-templates` | Elixir tasks_controller/params | 2 — AFTER S1 merges (same files) | opus |
| S5 search snippets + shared hit envelope (R3) | `axi-s5-search-snippets` | Elixir search×4 + highlighter | 1 | fable |
| S6 content-first no-arg + counts line (R7) | `axi-s6-content-first-noarg` | Go cmd/barkpark + cli.go | 1 | opus |
| S7 ticket.status options fix + tolerant decode | `axi-s7-ticket-options-fix` | Elixir tickets.ex + Go apiclient | 1 | opus |

S1/S3 land brief independently (either merge order is safe: CLI sending `?view=brief` early is proven inert; server emitting views is opt-in-gated). End-to-end brief lights up when S1+S2+S3 are all on main — the lead runs the byte probes then.

## Backlog (filed as published child tasks — not this wave)

`axi-b1-frontier-cmux-brief-help` (frontier/cmux paths bypass runCommand), `axi-b2-noun-counts-endpoint` (bundled per-noun counts), `axi-b3-ts-headline-snippets` (real body highlighting), `axi-b4-barkpark-url-env-footgun` (dead env-var names silently ignored — recurring landmine), `axi-b5-js-sdk-options-decode-audit` (unchecked JS-side options blast radius). Plus the charter's standing deferrals: R6 TOON/`-o brief` encoding, R8 SessionStart prime line, R9 MCP server-instructions, R10 chat `--tools all` + render_appendix counts.

## Laws

1. Manifest-first: every new behavior is declared in `/v1/capabilities` and consumed generically; zero per-command Go special-casing in the bridge path.
2. Truncation honesty: anything omitted or truncated says so inline with the exact command that retrieves the rest (the `--all` nudge is the house pattern).
3. Empty states, exit codes, `no_ready`-as-non-error are already correct — do not regress them; protective tests where touched.
4. Measure before/after with `wc -c` probes in evidence stamps; a claim without a byte count is not evidence (distrust vacuous green). Measure prime with `--worker <self>` (the real scenario) as well as bare.
5. Elixir PRs wait for the Elixir Test gate; check main's own gate health before blaming a cycle PR.
6. Builders work in worktrees only; the primary checkout stays on main. Use `CC=/usr/bin/clang` for Go vet/test (the `cc` alias shadows the compiler).
7. New-key safety = opt-in emission, never merge ordering. Any future manifest field follows the `?build=1`/`?views=1` pattern.

## Wave log

### Wave 2026-07-18 — round 1 built + reviewed, grade A-

All six round-1 slices built green and survived adversarial review (gates independently re-run from a clean review worktree; pairwise merge-tree checks clean against origin/main and each other). Only review fix anywhere: gofmt on `internal/cli/noarg_test.go` (S6). Debrief: Paper `axi-brief-views-wave-2026-07-18`.

**Landed (merge-ready branches):**

| Slice | Final branch | Proof |
|---|---|---|
| axi-s1 brief view + de-dup + child_count | `loop-epic/brief-view-claim-de-dup-child-count-land-0` | 82 tests 0F; prime 78,339 B → 3,816 B (20.5x); tenancy-leak protective test |
| axi-s2 ?views=1 manifest opt-in | `loop-epic/capabilities-manifest-declares-views-per-1` | 65 tests 0F; distinct etags, no-304 cross-contamination, default byte-identical |
| axi-s3 CLI/MCP brief consume + clamp + help[] | `loop-epic/cli-mcp-consume-brief-views-generically--2-r` | build/vet/test green; json-silence probe ported as protective test |
| axi-s5 search brief cards + snippets | `loop-epic/search-returns-brief-hit-cards-snippets--3` | 58 tests + 4 doctests 0F; 73,186 B → 898 B (81.5x); private-field leak test |
| axi-s6 content-first no-arg | `loop-epic/non-tty-bp-prints-a-content-first-status-4-r` | build/vet/test green on final state (gofmt fix committed) |
| axi-s7 ticket.status outage fix | `loop-epic/ticket-status-object-shaped-options-no-l-5` | 146 tests 0F + go apiclient ok; exact guerrilla fixture proves old abort → new success |

**Stalled:** nothing. axi-s4-help-templates is round-2 by design (same files as S1) — open, unclaimed, honest.

**Ledger:** clean, zero fixes — all built slices in_progress with evidence-stamped criteria, merge-gated criteria left open for the lead; backlog b1–b5 filed and published.

**Next wave takes:** (1) merge round 1 — S7 FIRST (live outage), then S1/S2/S5 behind the Elixir Test gate, S3/S6 on Go gates; S3+S6 merge from their `-r` branches. (2) Lead closes merge-gated criteria on merge, then re-runs the charter byte probes on guerrilla (ready ≤15 KB, prime ≤5 KB incl. --worker, search ≤45 KB, MCP brief) and stamps the numbers. (3) Dispatch axi-s4-help-templates the moment S1 merges. (4) Then backlog by value: b3 (real body snippets), b1 (frontier/cmux brief+help), b5, b2, b4; standing deferrals R6/R8/R9/R10 stay parked.

### Wave 2026-07-19 (wave 2, finishing) — round 1 built + reviewed, grade A-

All seven round-1 slices built green and survived adversarial review (gates independently re-run from a clean review worktree). Only review fix anywhere: `omitempty` on `TaskNotice`'s marshal fields (axi-b1's frontier machine JSON shipped `"task_id":"","blockers":null` noise — against the wave's own nil-key-omission law). Debrief: Paper `axi-brief-views-wave-2026-07-19`.

**Landed (merge-ready branches):**

| Slice | Final branch | Proof |
|---|---|---|
| axi-w2-s1 compact machine JSON | `loop-epic/machine-json-output-goes-compact-renderj-0` | exactly the 7 pinned tests re-pinned; ready piped 28,565→21,889 B (== jq -c ±1) |
| axi-w2-s2 brief card v2 nine-cut diet | `loop-epic/brief-card-v2-the-nine-cut-diet-lands-in-1` | 102 tests 0F; realistic 50-card page 11,005 B (≤15,360), hostile 28,594 B (≤30,720); help[] truncation-honesty line |
| axi-b1 help[]/notices parity ×5 surfaces | `loop-epic/help-and-notices-parity-across-every-typ-2-r` | Go gates green; typed twins match the help:/notice: house vocabulary exactly |
| axi-b2 counts endpoint (Elixir) | `loop-epic/bundled-per-type-counts-endpoint-get-v1--3` | 5 tests 0F + 80 manifest contract tests 0F; Scope fail-closed verified |
| axi-w2-s5 bare-noun counts line (Go) | `loop-epic/bp-noun-bare-shows-a-live-counts-line-fo-4` | 16 unit tests incl. all degrade seams; consumes b2's frozen shape verbatim |
| axi-b3 snippet NO-GO + highlight bounding | `loop-epic/search-snippets-stay-app-level-measured--5` | 41 tests 0F + 209 consumer tests; 50-hit heavyweight page 4.5 MB→<45 KB |
| axi-b5 codegen protective options test | `loop-epic/js-sdk-options-decode-lock-the-clean-aud-6` | 66/66 vitest; premise refuted honestly, test-only, no changeset |

**Stalled:** nothing. axi-b4 is round-2 by design (shares cli.go with s5) — open, unclaimed, honest.

**Ledger:** one fix — axi-b5's claim lapsed post-build leaving lifecycle `open`; patched to `in_progress` + republished. Everything else clean: evidence stamped mid-work, merge-gated criteria open for the lead, wave-1 tasks untouched, b6/b7 filed.

**Next wave takes (the lead, post-merge close-out):** (1) merge round 1 — file sets disjoint; b1 merges from its `-r` branch; b2 may red the api gate on the docs/openapi.json golden (regen via CI artifact); b1 overlaps the concurrent PDS cycle on internal/cli — resolve at merge. (2) Close each task's merge-gated criterion + CAS-close on merge. (3) Dispatch axi-b4 the moment s5 merges. (4) CLOSE-OUT per decision 23: fresh binary, live guerrilla probes (ready ≤15 KB, prime bare AND `--worker` with a REAL held claim ≤5 KB, search ≤45 KB, `--full` escape, MCP tool-text — name the measurement point), re-claim the epic FRESH (epoch 4 lapsed+reaped), stamp criterion 0 with exact stored wording + live numbers + disclosed worst case, update `/papers/axi-agent-ergonomics-review`'s after-table (fresh read then patch; CLI `--if-rev` is a silent no-op, b6), close the epic with the fresh worker+epoch CAS; never cite #4167. (5) Backlog open: b6, b7; deferrals R6/R8/R9/R10 parked.

# bp Context-Compression Epic — Charter

Epic task: `task-495cc9a9af43472c` · Wave Papers: `ctx-compression-wave-<date>` · Ground truth: `/papers/ctx-compression-capstone` (crown), `-headroom-lessons`, `-spend-census`, `-handle-doctrine`, `-view-tiers-seam`, `-taskboard-flagship`.

## Vision

Every byte a first-party bp payload puts into an agent's context is paid again on every later turn (measured 5–6x cache-amplification for early bytes). This epic compresses **presentation, never truth**: native-only projections at the exact point a payload enters context, each shipped with a protective kit (tripwires, key-set pins, opt-out identity proofs) and measured honestly — `count_tokens` before token claims, envelope `total_cost_usd` before dollar claims, bytes labeled as bytes until converted. Seal before tiers: any surface that gets a smaller projection first gets its visibility gates sealed.

## Decisions

All 12 capstone judgment calls are RATIFIED on the recommended column (recorded verbatim in the epic task's `notes`). Wave-1 verification (2026-07-24, seven verifiers, proofs run against origin/main `83c41e66c`) forced the following refinements — each final, verification-backed:

1. **Client-side projection at print (Direction B).** `internal/manifest/fetch.go:40` always fetches the FULL manifest (hardcoded `?views=1`, ETag-cached) and that fetch never reaches context; the 95.7 KB enters as stdout at `runCapabilities` (`internal/cli/builtins.go:44`). A server view saves zero wire and zero context while dragging in ETag/Vary + two-language schema scope. The AXI views grammar structurally cannot reach the capabilities builtin (bootstrap carve-out) — this is a sibling mechanism, not a grammar fork.
2. **The ratified byte targets are REVISED — they failed real reconstruction.** Against the live 142-command manifest, the exact ratified keep-list as nested JSON = 42,025–46,359 B (2.1–2.3x), not 24,266 B/3.9x; the 17,543 B/5.5x TSV is only reachable by dropping summaries, which breaks invoke-completeness. The original fixtures are gone and were built on a smaller manifest and/or without summaries. Honest menu (all invoke-complete, measured): nested-JSON ~42 KB/2.28x · array-of-tuples ~26.5 KB/3.62x · TSV/cmd ~21.5 KB/4.47x.
3. **Brief encoding = array-of-tuples JSON with a legend header; nouns catalog dropped.** ~26.5 KB / 3.62x — the only JSON-family encoding near the ratified band; structurally collision-free (TSV/packed are only *data-dependently* safe today, and a future re-add of `Flag.default` breaks them silently); still `json.loads`-parseable. Nouns catalog (~3.8 KB) is droppable: every noun appears in the command list; only 24 noun-level summaries are lost (recoverable via `--full`).
4. **Targets are RATIOS, never fixed bytes.** The manifest grows (95,666 → 95,915 B already). Tripwire: brief ≤ 32% of full bytes on the committed fixture (≥3.1x floor with headroom under the measured 3.62x).
5. **Tokens still win; count_tokens runs POST-build.** Fixtures don't pre-exist (order: build → regenerate → count) and no API key is reachable (`bp secret ls` has none — human provisioning dependency). Pre-registered fallback: ship bytes labeled bytes-with-conversion-pending. If a later count_tokens run shows another invoke-complete encoding beats tuples by >10% tokens, flip by amendment; ties break to JSON-family.
6. **The projection spec is BRIEF-KEEP-LIST v1 and pins FIELDS *and* ENCODING.** Fields: per command `noun, verb, summary, auth_tier, writes, args[name,type,required], flags[name,type]` + top-level `manifest_version, server, auth_tier, etag, legend`. Cut: nouns catalog, http, id, mutation_op, set_key, scoped_prefix, default_output, dry_run, batch, source, paginated, views, since, arg/flag summaries, flag defaults. Identical fields span 2.07–4.47x by encoding alone — a keep-list without an encoding rule is not a spec. Server-portable: a later server-side `?view=brief` adopts it verbatim (nothing foreclosed; AXI's `?view=` vocabulary is deliberately reused, not forked).
7. **`--full` stays byte-identical; `-o table` untouched.** Brief fires only on `out.machineOut() && !g.full` (the existing AXI resolution predicate). The `--full` identity test is the client-side adaptation of AXI's opt-out-byte-identical proof.
8. **The protective kit ships in the same PR** — ratio tripwire (realistic fixture + hostile synthetic), legend/exact-shape pin, `--full` byte-identity, determinism (two renders identical), and an invoke-completeness acceptance test (every command composable from the brief alone). This is the FIRST test coverage this stdout path has ever had (verified: no test pins `runCapabilities` output today).
9. **Fixtures get a durable home**: `tooling/scaffy-duels/fixtures/` (committed, regenerable via recorded commands). `docs/cli/fixtures/full-manifest.json` is regenerated to the live 142-command shape (proven safe: no test asserts a total count) and `docs/cli/fixtures/**` is added to `go-tests.yml` paths (closes the #963→#969-class fixture-drift gap).
10. **Seal `Tasks.Query.to_render_map` NOW with EXPLICIT dataset threading.** `rows_for_query(query, scope \\ [], opts \\ [])`; `dataset = opts[:dataset] || query["dataset"] || "production"`. Both callers updated: reader `content/papers.ex:1074` passes its stamped `dataset:`; Studio preview `shared/paper.ex:377` passes `socket.assigns.dataset` (it never stamps the query — deriving from the query map would gate the WRONG schema there, a silent wrong seal). Gate hoisted ONCE per call above the doc map (board.ex:190 pattern). Gated: priority, assignee, claim, labels (`else: []`). Ungated (board precedent, counts-never-text): title, lifecycle_status, dependency_count, criteria_progress. Per-field independent gating (keys map 1:1 to schema fields), chosen consciously over board.ex's worker-union.
11. **Nil-polarity flips fail-closed, catch-all included, sibling folded in.** `envelope.ex:222` nil→false AND the `:244` catch-all→false (`:internal`/admin clauses untouched). Static caller-trace: all 6 production callers pass non-nil structs; exactly one test assertion breaks (`envelope_test.exs:256`) and is rewritten atomically. The in-family sibling `listen_controller.ex:395` (nil → unredacted document, fail-OPEN) is REMOVED in the same slice — its one test call passes `CallerContext.anonymous()` instead. Fence = regression tests (incl. first-ever catch-all pin) + doctrine comment + `docs/contracts/portable-doc-inline.md:23` rewrite + `scripts/nil-polarity-check.sh` grep gate wired into doc-gates.yml (Credo does not exist in this repo).
12. **Did-you-mean ships as its own small slice** (2,757 typed errors / 1.19 MB waste): `task show`→`get` + `task list`→`ls` alias intercepts in cli.go's `case "task":` (tui/server-ls precedent) + hint-threading via a sibling `usageErrHintf` (widening `usageErrf` would touch 63 no-op call sites). Probe-proven live: byte-identical stdout for aliases, `error.hint` in JSON envelopes, table mode unaffected; ~25–30 functional LOC.
13. **Live before/after session is n=1 DIRECTIONAL SMOKE, pre-registered.** Fixed committed prompt, model pin matching count_tokens fixtures, one `--output-format json` envelope per arm (JSONL summation banned), >2x the $0.55 spawn floor per arm, `--full` escape rate reported as a named metric. "Paid on every session" is softened to **amplified-per-call** (capabilities is absent from the census top-8; per-session count unmeasured). "12–92x" is corrected to the measured 12–81.5x band.
14. **task-8ad8d5cfe98c70aa is already closed** (verified: done, closed 2026-07-24T00:21Z, evidence cites merge 83c41e66c). No ledger action; the stopgap has zero file overlap with this wave.
15. **Charter path is explicit** (this file). The bp-epic-cycle default silently targets the cloud charter — always pass `charter_path`.
16. **Naming**: slice prefix `ctx-` (`ctx-s<N>-<slug>` wave slices, `ctx-b<N>-<slug>` backlog). Slices are children of `task-495cc9a9af43472c`, carry flat `wave_paper`, and `files:` labels per docs/contracts/dispatch-areas.md. The `epic-candidate` label drops on chartering.
17. **Census thresholds stay forbidden until measured; duel budget $30–80 (wave 2); board clamp raise-then-fold** — the raise already landed (PR #6033); the fold is future board-tier work, out of this epic's wave 1.

## Roadmap

### Wave 1 (this wave) — born-brief session start + seals

| Slice | Task | Surface | Round | Model | Size |
|---|---|---|---|---|---|
| Manifest brief projection at print + protective kit + fixtures | `ctx-s1-brief-manifest` | Go CLI | 1 | fable | large |
| Seal Tasks.Query.to_render_map (dataset-threaded gate) | `ctx-s2-seal-query-rows` | Elixir | 1 | opus | medium |
| Nil-polarity flip + listen_controller seam removal + fence | `ctx-s3-nil-polarity` | Elixir | 1 | opus | small |
| Did-you-mean: task show/list aliases + JSON hint threading | `ctx-s4-did-you-mean` | Go CLI | 1 | opus | small |
| count_tokens calibration script + token confirmation | `ctx-s5-count-tokens` | tooling | 2 (after s1) | opus | small |
| Live before/after directional smoke session | `ctx-s6-live-smoke` | tooling | 2 (after s1) | opus | medium |

### Backlog (filed, not this wave)

- `ctx-b1-paired-duel` — the $30–80 pre-registered brief-vs-full duel (wave 2), audit-wrap duel runs inside, cage spec pre-registered.
- `ctx-b2-server-view-brief` — server-side `?view=brief` adopting BRIEF-KEEP-LIST v1 verbatim; MUST fix QueryController `list_etag` param-fold + Vary (RFC 9110, query_controller.ex:481–489) in the same change.
- `ctx-b3-bp-park` — `bp park` as plugin + 2 MB ceiling + mandatory summary (ratified shape), wave 3+.
- `ctx-b4-mcp-tools-all-sizing` — deliberate MCP `--tools all` exercise session to size the sibling session-start payload (census: essentially unexercised, 4 calls ever).
- `ctx-b5-provision-count-tokens-key` — HUMAN: provision an Anthropic API key via `bp secret set`; unblocks ctx-s5's token leg.
- `ctx-b6-memoized-visibility-gate` — thread a memoized gate through TaskResolver resolve/preview (per-block get_schema → once-per-render).

### Future waves

- Wave 2: paired duel + token-confirmed encoding ratification + census thresholds (measured first).
- Wave 3+: server `?view=brief` + RFC 9110 fix, `bp park`, MCP sizing, board tier fold.

## Laws

- Compress presentation, never truth. Native-only. `count_tokens` before token claims; envelope `total_cost_usd` before dollar claims; bytes labeled bytes until converted. Seal before tiers. Targets are ratios, never fixed bytes. A brief missing one field costs more than it saves — invoke-completeness is the acceptance test, and the `--full` escape rate is the alarm.
- Elixir slices: no local toolchain exists on the dev machine (verified) — the local gate is a targeted `mix test` WHERE available; `elixir.yml` CI green is the binding proof either way. Builders state which they ran.

## Wave log

(append-only; one dated H3 per wave)

### Wave 2026-07-24 — wave 1 built + reviewed, grade A-

**Landed (4 slices, all pushed, PRs open, lead merges):**

- `ctx-s1-brief-manifest` → PR #6052 (`loop-epic/born-brief-bp-capabilities-machine-outpu-0`). Born-brief `bp capabilities`: BRIEF-KEEP-LIST v1 tuples, 95,915 B → 26,502 B (3.62x / 27.6%, under the 32% tripwire). Full protective kit (invoke-completeness, legend pin, cut-list pin, ratio tripwire, hostile synthetic, `--full` byte-identity, table-untouched — first coverage this stdout ever had). Fixture regen 40→142 commands; frozen duel pair committed; `docs/cli/fixtures/**` added to go-tests.yml. Reviewer re-ran the Go gate green and additionally proved caps-brief fixture == briefManifest(caps-full) byte-identical. No fixes needed.
- `ctx-s3-nil-polarity` → PR #6053. envelope.ex nil clause + :244 catch-all flipped fail-CLOSED; listen_controller fail-open nil seam REMOVED; selftest-tripwired `scripts/nil-polarity-check.sh` fence wired into doc-gates.yml. Reviewer independently re-derived the dead-path claim (all 6 callers thread non-nil; `ScopeHelpers.from_assigns` always puts `:caller_context` via `from_conn` → `anonymous()`). Runnable gates green locally; **elixir.yml on the PR is the binding mix proof**. Comment-sweep follow-up filed: `task-3afeb5994c839c27`.
- `ctx-s4-did-you-mean` → PR #6054. `task show`→`get`, `task list`→`ls` aliases (stderr note, stdout byte-identical); `error.hint` did-you-mean threaded into JSON envelopes via `usageErrHintf` sibling (63 no-op usageErrf sites untouched). Go gate green; reviewer verified clean merge + combined green suite with s1's 142-command fixture.
- `ctx-s2-seal-query-rows` → PR #6055 (**CI-gated, second-review-owed**). `rows_for_query/3` sealed with the explicit dataset cascade; preview passes `socket.assigns.dataset` (HIGH-FLIP-RISK judgment re-derived by reviewer — the adjacent `agg_for_query` fetcher already threads it). Mix gate unrun locally (no toolchain, charter-designated); criteria 2/4/5 stay open pending elixir.yml green. An independent second reviewer is warranted before merge per the flip-risk protocol.

**Cross-slice:** all four merge cleanly together; combined Go suite + fence scripts green on the integration merge. s2's gate correctly passes `anonymous()`, composing with s3's flip. Structural note for the dedup ledger: `row_field_visibility_gate/1` is now the third inline copy of the anonymous-gate helper (board.ex, board_live.ex, query.ex) — `ctx-b6-memoized-visibility-gate` is the natural consolidation point.

**Deferred by design (round 2, sequenced behind s1):** `ctx-s5-count-tokens`, `ctx-s6-live-smoke`.

**Next wave:** (1) lead merges round 1 — order: #6052 (s1) first, then #6053/#6054 (independent), #6055 after elixir.yml green + independent dataset-threading second review; lead closes each task's merge-gated criteria on merge. (2) Dispatch `ctx-s5-count-tokens` once s1 is on main (bytes-pending fallback works without a key; `ctx-b5` human key provisioning unblocks the token leg). (3) Dispatch `ctx-s6-live-smoke` after s1 merges (arm A needs the brief-default binary from main); pre-register before any run. (4) Token verdict either confirms tuples or files the >10% amendment. Wave 2 proper: paired duel (`ctx-b1`), census thresholds measured-first.

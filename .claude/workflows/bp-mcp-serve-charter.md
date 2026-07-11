# bp mcp serve — Epic Charter

Epic task: `bp-mcp-serve-epic` (published). Wave tasks are its children (`parent_id=bp-mcp-serve-epic`).

## Vision

The capabilities manifest becomes its THIRD surface: the same tree that drives CLI dispatch and help becomes, verbatim, an MCP tool catalog over stdio. A Cursor user adds a five-line stanza to `~/.cursor/mcp.json` (`command: "bp", args: ["mcp","serve"]`), restarts, and Barkpark Tasks appear as first-class tools — the agent claims with `task_next`, reads the brief, closes with epoch-CAS `task_close`, never shells out. The five task tools are CURATED: their MCP descriptions carry the barkpark-tasks.mdc doctrine (claim-first, epoch-from-claim, lifecycle_status is the done-signal, criteria-in-close, re-claim on lapse) so the tool schema itself teaches the workflow. Underneath, the BOLD bet ships in the same epic: a generic capabilities→MCP bridge where every manifest verb becomes a tool (`bp_<noun>_<verb>`) with auto-derived inputSchema — a new plugin's verbs appear as Cursor tools with zero Go changes. This is path B; path A (shell-based `.cursor/rules/barkpark-tasks.mdc`, d49b7c40) already shipped.

## Decisions

1. **Built-in intercept, not manifest noun.** `case "mcp": return runMCPServe(...)` in Execute's noun switch (cli.go:93–354, like `cmux`/`doctor`), evaluated before `loadManifest`. Why: `mcp` is not a manifest noun — it shadows nothing (cli.go:174/282 precedent).
2. **Official `github.com/modelcontextprotocol/go-sdk` (v1.6.x).** Non-generic `Server.AddTool(t *Tool, h ToolHandler)` with `Tool.InputSchema = json.RawMessage` + `StdioTransport`. Why: post-1.0 semver-stable, go.mod match is exact (`go 1.25.0` both sides), dynamic data-built tools are first-class (compiling spike proved it), ~5 net-new runtime modules in a binary already carrying Azure+AWS. Hand-rolled JSON-RPC is the fallback ONLY if review rejects the deps. mark3labs is dominated (v0.x, needs go 1.25.5).
3. **Extract the dispatch seam first.** `execManifestCommand(g, ctx, m, cmd, tail) (status int, body []byte, err error)` factored out of `runCommand` (run.go:45–133, minus dryRun/prod-guard/pagination-`--all`/render); `runCommand` refactors to consume it. Same treatment for `runTaskCreate`'s send step (raw bytes, not exit code). Why: NO raw-JSON seam exists today (exploration confirmed) — this is the third surface's dispatch primitive, and the CLI render path becomes a consumer of it.
4. **stdout is sacred; the discipline is "never call the renderer."** MCP handlers go through the seam only — never `handleResponse`/`renderSuccess`/`renderErrorEnvelope`; any helper still taking `*writer` gets one backed by stderr + io.Discard. The update notice is already stderr-only + TTY-gated (update_notice.go:143/217) — no work. The "doctor staleness hook" is `make doctor`, NOT an in-binary print — no work. Protective tests: SDK in-memory transport unit test + an exec'd real-stdio smoke asserting stdout carries only JSON-RPC frames.
5. **Headless liveness: force `yes=true` inside MCP tool execution.** The prod write-guard (run.go:103/1070) and `runTaskCreate`'s guard read stdin and would HANG a headless server. `dryRun` is never set.
6. **The curated five are hand-mapped — they are NOT 1:1 verb aliases.** `task_ready`→task.ready; `task_next`→task.next (POST /v1/tasks/claim, worker_id req); `task_show`→task.**get**; `task_close`→task.close (observed_epoch int req, criteria via `set`); `task_create`→the client-side `runTaskCreate` mutation builder (`{create:{_type:task}}` + kind/lifecycle_status injection) because the LIVE manifest has NO task.create verb (verbs: ls, ready, prime, get, claim, close, next, move). Enums (`lifecycle_status ∈ done|cancelled|blocked`) are hand-written in the curated schemas — the manifest has no enum metadata. Descriptions carry the doctrine verbatim: epoch comes from the claim response `doc.claim.epoch`; 409 `doc_changed_since_claim` → re-read then re-close (or `--set observed_rev=`); `{ok:false,reason:"no_ready"}` at HTTP 200 is empty-queue, not an error.
7. **Generic bridge is in-wave, opt-in: `--tools tasks|all`, default `tasks`.** Why the default: Cursor hard-caps 40 MCP tools ACROSS ALL SERVERS and silently drops the excess; the live manifest is 107 commands. Naming `bp_<noun>_<verb>`; inputSchema auto-derived from manifest Args/Flags (all 111 live args carry type+summary — property descriptions come free); required = Arg.Required. Under `--tools all`, curated tools shadow their manifest twins (skip generating bp_task_ready/next/get/close); everything else (incl. bp_task_claim by-id, bp_doc_create) still generates.
8. **Never re-implement arg placement or body typing.** Tool handlers translate MCP arguments to the CLI's positional+flag tail and feed the seam, so `ArgLocation` inference (url.go:93), `--set k:=json` typing, MutationOp/SetKey wrapping all ride the existing code. Non-string JSON scalars from the client are stringified into the existing string body path (server coerces via fetch_int — observed_epoch already rides as a string today).
9. **Result shape:** tool result = raw response JSON as one text content block; HTTP ≥400 → `IsError=true` with the error envelope verbatim. No re-rendering, no summarizing.
10. **Startup:** fetch manifest once via `loadManifest(g, ctx)` (ETag cache; `--manifest`/`$BARKPARK_MANIFEST` override honored); fail fast to stderr + nonzero exit if unreachable. The mcp.json `env` block (`BARKPARK_API_URL`, `BARKPARK_API_TOKEN`, …) is the documented instance override — env sits above the config-file layer (cli.go:523).
11. **Docs land where the byte budgets allow.** Recipe → `docs/setup/CURSOR.md` (expand the reserved "## MCP (optional, coming)" section; it owns `canonical-for: cursor-integration`, is budget-ungated). Command reference → `docs/cli/HANDBOOK.md` "## Other built-ins". One-line path-B pointer → `.cursor/rules/barkpark-tasks.mdc`. NO edits to cards (cli.md 2393/2400B), TASK-SYSTEM.md (15996/16000B), or INDEX.md (3B headroom). Docs slice merges LAST and coordinates with the sibling session landing CURSOR.md.
12. **CLOSE the epic this wave (reconcile-and-close, 2026-07-11).** Every clause of the anchor's description is evidenced at HEAD cbef2af2 with FRESH proof, not remembered green: stdio subcommand + curated tools registered under the anchor's exact names (internal/cli/mcp_tasks.go:113/152/194/226/319, PR #1790=cac9b43d), manifest-seam reuse (mcp-w1-seam, execManifestCommand in run.go), stretch bridge (mcp_bridge.go:80, #1790), Cursor path-B docs (#1791=398612d2), w2 catalog/resources/validation (#1993=94efd1f5), Path A d49b7c40 intact. Full unfiltered Go gate green at HEAD; real-exec stdio smoke green (12.35s, not vacuous). Why: 8/8 children done with 47/47 criteria met and zero unbuilt anchor scope — leaving the epic open is ledger rot.
13. **Close mechanics = self-update precedent.** The epic doc carries NO acceptance_criteria of its own (prose only; evidence lives on children). So: rewrite `content.description` into the PR-cited close story via doc patch + publish, THEN `bp task close bp-mcp-serve-epic <worker> 0 done` (epic is unclaimed — claim=null verified 2026-07-11 — so epoch 0 is accepted; no open-children guard exists). NEVER raw-mutate lifecycle_status — that skips the task.closed event. Why: live-proven house style (isu-reconcile-epic-close), and the write contract mandates task.close as the only lifecycle flip.
14. **task_show is NOT naming drift — stamp the comment, fix nothing.** The registered MCP tool name IS `task_show` (mcp_tasks.go:194), matching the anchor verbatim; it deliberately wraps the `task.get` manifest verb for MCP-client familiarity, documented in-source at mcp_tasks.go:70-71. Why: both survey and verify confirmed the divergence is intentional and self-documented; the close story cites that comment as the resolution.
15. **One residue slice, doc-truth only — and it is WIDER than the wish guessed.** The "six tools" staleness (post-#2580, which shipped task_stamp/task_pulse 57 min after #2588, code-only) infects 9 doc surfaces (CURSOR.md:113, CODEX.md:174, CLAUDE-CODE.md:135, WINDSURF.md:91, COPILOT.md:125, ZED.md:99, GEMINI-CLI.md:96, AGENT-ONRAMPS.md:107, HANDBOOK.md:165), the in-binary help (mcp_serve.go:382-384, proven stale by running a fresh build's --help), 5 stale source comments (mcp_stdio_smoke_test.go:8, mcp_bridge.go:28, mcp_http_test.go:219, mcp_serve_test.go:45+:133 — the assertions beside them are already correct at 8), and the @canonical aka list (mcp_tasks.go:75 omits task_show/task_create). Why one slice: same root cause, uniform fix (say eight, list all 8), disjoint from everything else in flight.
16. **validation.md gets the truth in the same slice.** Line 145 "curated six" → eight; line 184 "Status: transcript pending" is now FALSE (live smoke green per ve-w2-mcp-deploy's met criteria AND this wave's own authenticated tools/call transcript) — replace with the dated 2026-07-11 redacted addendum; line 180's "(401)" expectation is WRONG: the live deny path is HTTP 200 carrying a JSON-RPC tool-result error (isError:true, code unauthorized) — correct it or a future reader thinks the guard is broken. Why folded here (not ve-w2-mcp-deploy's): one doc, one writer, cross-link the ve task instead of splitting a file between epics.
17. **--http stays out of the stdio onramp docs.** docs/setup/REMOTE.md (canonical-for: remote-agent-onramp) already fully owns the --http/bearer/forward-through recipe; the 8 CLI-agent onramp docs stay stdio-only and CROSS-LINK it. Why: dedup law — zero '--http' hits exist in those docs today and that is correct, not a gap.
18. **D18 is cited CROSS-EPIC, never as ours.** "Paper resources template-only in HTTP mode" (D18) is viable-everywhere-epic's ratified charter decision (committed 05c42173) — textually distinct from THIS epic's own template-only degrade (mcp-w2-resources: unreachable-API → template-only, stderr-only, stdio startup; plain narrative in this charter's wave-2 log, no D-number). Why: the verify round proved the two are related but provenance-distinct; conflating them misattributes a sibling epic's decision.
19. **OAuth for Claude.ai remote is DISCLAIMED by name.** It appears nowhere in this epic's words; it is viable-everywhere w3 scope (ve-w3-oauth-as, see docs/setup/REMOTE.md:7/90). Why: the close story names it with a pointer so nobody reopens this epic for it.
20. **Live-proof claim is scoped honestly: read + fail-closed only.** Proven live on guerrilla at HEAD (2026-07-11): authenticated tools/call task_ready returned real ledger docs; the SAME call with no bearer and with a bogus bearer both refused (isError:true, unauthorized, zero data). Write tools were deliberately NOT invoked live. Why: distrust-vacuous-green — stamp exactly what ran, no more.
21. **Downstream consumers are cited, not re-homed.** task-scc-bl-mcp-chat-toolset (studio-claude-chat) and ve-bl-mcp-http-ingest-ambient (viable-everywhere) reference `bp mcp serve` because they CONSUME the seam this epic built — they are other epics' scope. No drafts.* exist anywhere in the cluster (swept — nothing to publish-collapse); no unbuilt Cursor path-B remainder exists.

## Roadmap

Wave 1 (this wave, integration-ordered):

1. `mcp-w1-seam` (small) — extract `execManifestCommand` + raw-bytes task-create send; refactor callers. THE PREREQUISITE.
2. `mcp-w1-core` (large) — go-sdk dep + `bp mcp serve` intercept + server loop + stdout discipline + the five curated task tools + in-memory-transport tests.
3. `mcp-w1-bridge` (medium) — generic capabilities→MCP bridge behind `--tools all`, schema auto-derivation, curated-shadowing.
4. `mcp-w1-smoke` (small) — exec'd real-stdio smoke test: initialize → tools/list → tools/call against the built binary; stdout purity gate.
5. `mcp-w1-docs` (small) — CURSOR.md MCP section (mcp.json global + per-project + env override + 40-tool warning), HANDBOOK built-in reference, .mdc pointer.

Future waves (not filed): MCP resources for Papers; tool annotations (readOnlyHint/destructiveHint); `task_prime` curated tool; manifest hot-refresh on ETag change; live Cursor handshake validation write-up.

Wave 3 (2026-07-11, reconcile-and-close — the LAST wave, integration-ordered):

1. `mcp-close-doc-truth` (medium) — the MCP surface says EIGHT tools everywhere it still says six: 9 doc files + in-binary help + 5 stale source comments + @canonical aka list + validation.md truth refresh (eight, dated live-transcript addendum, 401→isError correction). Decisions 15-17.
2. `mcp-epic-close-stamp` (small) — rewrite the epic description into the PR-cited close story (decisions 12-14, 18-21) and seal it: `bp task close bp-mcp-serve-epic <worker> 0 done`. Runs after doc-truth's PR is up (cites it merged or names it as the blessed open child).

After wave 3 the epic is CLOSED. Anything MCP-flavored beyond it belongs to viable-everywhere (remote/OAuth) or the consuming epics (studio-claude-chat toolset, ingest-ambient).

## Wave log

### Wave 2026-07-09 (wave 1 — the whole epic in one wave)

**Landed (all five slices green; reviewer integrated + fixed in place):**

- `mcp-w1-seam` — clean extraction: `buildManifestRequest`/`sendManifestRequest`/`execManifestCommand` in run.go (build-once preserves `--file -` stdin; withUsage flag reproduces exact error rendering) + `sendTaskMutations`/`firstMutationID`/`mutateErrorMessage` in tasks_create_cmd.go. No fixes needed. Branch: `loop-epic/execmanifestcommand-raw-json-dispatch-se-0`.
- `mcp-w1-core` — `bp mcp serve` works, but the builder (seam absent from its worktree) shipped a parallel dispatch (`mcpInvoke` + apiclient-based `mcpTaskCreate`). REVIEWER REWIRED it onto the seam per decisions 3/8: curated handlers now build a CLI tail and call `execManifestCommand`; task_create rides `sendTaskMutations`. `registerTaskTools`/`registerBridgeTools` gained the `globals` param; `runMCPServe` forces `g.yes` (decision 5). Test now also asserts the POSTed close body (worker_id/epoch/status + TYPED criteria) through the seam. Branch: `loop-epic/bp-mcp-serve-live-over-stdio-with-five-d-1-r` (contains seam via merge).
- `mcp-w1-bridge` — schema derivation/naming/shadowing all correct. Its fenced `execManifestCommand` shim had a DIFFERENT signature than the seam's (captured rendered stdout, `(string,error)`) and its `bridgeRegistrar` interface had NO implementer in core. REVIEWER dropped both: `registerBridgeTools(srv *mcp.Server, g, ctx, m) error` registers straight onto the server; handlers ride the seam + `mcpRun` (raw JSON, IsError≥400 — decision 9, which the shim's rendered-stdout result violated). Tests reworked to a real in-memory MCP session (cursor-drained tools/list; tools/call round-trip vs direct CLI dispatch). Branch: `loop-epic/generic-capabilities-mcp-bridge-under-to-2-r` (contains core-r).
- `mcp-w1-smoke` — excellent hermetic design (harness test proves the tripwire non-vacuously). Pre-integration it SKIPPED its primary exec assertions; on the -r branch (merged bridge-r) `TestMCPServeStdioSmoke` runs LIVE and passes: byte-pure ndjson JSON-RPC stdout from the built binary, exactly the five curated tools. Reviewer additionally hand-drove `--tools all` over real stdio: 37 tools vs the fixture manifest, curated five present, shadowed twins absent, frames pure. Branch: `loop-epic/real-stdio-smoke-gate-byte-pure-json-rpc-3-r`.
- `mcp-w1-docs` — CURSOR.md recipe/HANDBOOK bullet/mdc pointer all accurate. Two reviewer fixes: (1) origin/main landed the sibling's CURSOR.md after the branch fork — merged main so the add/add conflict is pre-resolved (MCP section replacement is the sole diff vs main); (2) corrected the false "Tasks-plugin-disabled server starts cleanly with no task tools" claim — core deliberately fails fast (`manifest has no task.<verb> verb`), the right UX. Branch: `loop-epic/cursor-mcp-registration-docs-cursor-md-r-4-r`.

**Integration order for the lead:** seam → core-r → bridge-r → smoke-r → docs-r. The -r branches are stacked merges, so merging smoke-r brings seam+core-r+bridge-r; docs-r is independent of the code branches. On merge, close each task's "PR merged" criterion (all claims lapsed — re-claim for a fresh epoch; the reviewer's evidence patches moved the acceptance_criteria work-digest, so expect the close fence 409 → re-read → close).

**Stalled:** nothing.

**Next wave (charter future list, in value order):** (1) live Cursor handshake validation write-up — the one thing no test proves is a real Cursor client end-to-end; (2) MCP resources for Papers; (3) tool annotations (readOnlyHint/destructiveHint — cheap now that the bridge sees `cmd.Writes`); (4) `task_prime` curated tool; (5) manifest hot-refresh on ETag change. Also consider: graceful `--tools all` on a tasks-less instance (currently fails fast because the curated five are mandatory — right for the default, debatable under `all`). And commit this charter to git — it is still untracked in the main checkout.

### Wave 2026-07-09 (wave 2 — deepen the third surface)

**Landed (all three slices green; reviewer stacked, fixed, and live-verified):**

- `mcp-w2-catalog` — Writes-derived `bridgeAnnotations` (read=ReadOnlyHint:true; write=+DestructiveHint:&true, conservative by design), `task_prime` sixth curated tool (worker/limit → `--worker/--limit` via the seam; description carries the prime-never-claims + re-claim-on-lapse doctrine), graceful `--tools all` on a tasks-less manifest (stderr warn, bridge-only; default `tasks` still fails fast). All sync sites updated; smoke runs LIVE asserting six tools. REVIEWER FIXES: the expanded doc comment had pushed the `@canonical capability:mcp-task-tools` marker >6 lines from `registerTaskTools`, redding `docs-anchors-check.sh` §8 (doc-gates.yml triggers on .go — would have failed CI); marker moved adjacent to the func. Stale "curated five" copy fixed in `printMCPServeHelp`, CURSOR.md "### The tools" (+task_prime bullet), HANDBOOK.md; "four reads" → "three reads". Branch: `loop-epic/honest-mcp-tool-catalog-writes-derived-a-0-r`.
- `mcp-w2-resources` — published papers as MCP resources: startup enumeration via doc.ls through the seam → concrete `barkpark://papers/<id>` entries + one `{id}` template for post-startup papers; shared read handler pins `--perspective published` on doc.get and returns raw JSON (decision 9); best-effort degrade (unreachable API → template-only, stderr-only). REVIEWER FIX (real bug): `paperDocShape` read `content.blocks`, but the LIVE query endpoint renders content fields FLAT (top-level `blocks`) — every title silently fell back to the `_id`; now reads both shapes, verified live (titles like "Truth Fabric — Masterplan (Lean)"). Also documented resources in CURSOR.md ("### Resources: published papers") + `mcp serve` help. Branch: `loop-epic/published-papers-browsable-as-mcp-resour-1-r` (contains catalog-r).
- `mcp-w2-validation` — `docs/ops/mcp-serve-validation.md`: honest-delta write-up of an exec'd read-only JSON-RPC session against live guerrilla (5 tools at capture time — pre-catalog, stated explicitly), byte-pure stdout, token never in a frame; CURSOR.md `### Validation` pointer. REVIEWER ADDENDUM: re-drove the live session from the fully-stacked branch — 6 curated tools with honest annotations, 65 published papers listed with heading-derived titles, template present, `resources/read` round-tripped a real 24.8 KB paper, exit 0. Branch: `loop-epic/bp-mcp-serve-proven-against-a-real-serve-2-r` (contains resources-r + catalog-r; this charter entry rides it).

**Integration order for the lead:** the -r branches are stacked merges — merging `loop-epic/bp-mcp-serve-proven-against-a-real-serve-2-r` alone brings the whole wave (catalog-r + resources-r + validation + this log). On merge, close each task's "PR merged" criterion (claims held by the epic-builder workers at epoch 1; the builders' evidence patches moved the work-digest, so expect the close fence 409 → re-read → close, or re-claim if lapsed).

**Stalled:** nothing.

**Next wave (charter future list, remaining):** (1) manifest hot-refresh on ETag change — the last unbuilt item from the wave-1 list (server restart is currently the only way a new plugin's verbs appear mid-session; the SDK supports `listChanged`). (2) Resources depth: `resources/list` is a single 200-cap page and titles come from a full-document list response — consider a lighter projection or `--all` pagination if paper corpora grow; also consider `resources/subscribe` off the listen SSE feed. (3) An optional real driven-Cursor screenshot remains garnish (GUI calls are LLM-mediated — the transcript is the proof). (4) DestructiveHint on additive creates is conservatively true — revisit only if a manifest write-kind signal ever exists. The epic's charter roadmap is otherwise MINED OUT — consider closing the epic after this merge.

### Wave 2026-07-11 (wave 3 — reconcile and close, REVIEWED — grade A, THE EPIC IS SEALED)

Paper: `bp-mcp-serve-epic-wave-2026-07-11` (debrief appended, published). Decisions 12-21 above
were this wave's ratified choices; both slices landed green.

- `mcp-close-doc-truth` — merge **`loop-epic/doc-truth-refresh-every-mcp-surface-says-0-r`**
  (NOT the base branch): every MCP surface now says EIGHT curated task tools — 9 onramp docs
  + in-binary help + 7 stale source comments (2 beyond the brief: 'curated'/'six' split across
  a newline in mcp_bridge.go:49 and mcp_stdio_smoke_test.go:208) + @canonical aka list (full 8,
  marker still adjacent to registerTaskTools) + validation.md truth refresh (eight; '(401)' →
  tool-result error isError:true/unauthorized inside HTTP 200; 'transcript pending' → the dated
  2026-07-11 redacted live-smoke addendum, zero token bytes). The stamp/pulse verb lines were
  added at the canonical renderAgentsMDBody source so all three embeds (.mdc,
  CLAUDE-BARKPARK.md, CODEX.md AGENTS block) + the golden stay byte-parity — 20 files, the 3
  extra mechanically forced by TestOnrampAgentsMdWrapperParity. Reviewer fix on the -r branch
  (dc7371c7): validation.md's "Still owed: the live remote smoke" pointer was left
  contradicting the new addendum 30 lines below — retired with a see-below pointer. Historical
  numeral run-logs (5-tool/6-tool snapshots) deliberately preserved as honest point-in-time
  records. Full slice gate re-run green on the -r branch (build/vet/test + zero six-hits +
  anchors-check PASS + budgets PASS).
- `mcp-epic-close-stamp` — ledger-only, zero repo commits (branch
  `loop-epic/epic-close-out-bp-mcp-serve-epic-sealed--1` is empty vs main; nothing to merge).
  **`bp-mcp-serve-epic` is CLOSED**: description rewritten into the PR-cited close story
  (anchor→evidence clause map at cbef2af2; #1790=cac9b43d, #1791=398612d2, #1993=94efd1f5,
  Path A d49b7c40; cross-epic corroboration #2588=304e45fb + #2580=46f7ea5d cited as other
  epics' deliverables; D18 attributed to viable-everywhere 05c42173; OAuth disclaimed as
  ve-w3-oauth-as; live proof scoped read+fail-closed; doc-truth named the blessed open child;
  original anchor preserved verbatim), draft collapsed, sealed via the close verb only at
  epoch 0 (epic was unclaimed). Reviewer re-verified every file:line anchor via
  `git show cbef2af2` and all seven shas — all real; 47/47 child-criteria arithmetic checks.

**Lead closes on merge:** merge doc-truth's -r branch, then close its criterion 5 (MERGE-GATE);
on mcp-epic-close-stamp close criterion 5 (LEAD GATE — reviewer already verified the stamp
trail honest but the builder's lease was still live at review, so the close needs a re-claim
after it lapses; worker epic-builder-epic-close-out-bp-mcp-serve-epic-sealed-, epoch 6 at
review time). No other residue: backlog none, drafts none, downstream consumers cited not
re-homed.

**Next wave:** none — the epic is sealed and its roadmap mined out. Anything MCP-flavored
beyond this belongs to viable-everywhere (remote OAuth = ve-w3-oauth-as, ingest-ambient) or
studio-claude-chat (toolset consumer).

# CMUX × Barkpark Bridge — Epic Charter

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **agent-onramps wave-2** charter formerly here is preserved verbatim at
> `.claude/workflows/bp-agent-onramps-w2-charter.md` (wave-1 remains at
> `bp-agent-onramps-charter.md`) — nothing was lost. This file is now the memory of the
> **cmux-bridge** epic.

Epic anchor: bp task `cmux-bridge-goal` (UUID a4614954-1f7a-4095-9935-5475ee717164, parent `dispatch-frontier-goal`, published). Slug children (`cb-*`) — 13 after wave 2 files cb-live-smoke + cb-ledger-close. Server: guerrilla.

## Vision

A cmux/tmux pane running an agent auto-owns exactly one Barkpark task for its lifetime. The board shows `cmux-<SURFACE_ID>` holding it; the lease renews quietly on activity; on stop the task closes with per-criterion evidence or the lease honestly expires into a resume. Nothing the bridge does can ever hurt the agent: every hook path exits 0 with empty stdout, always — and a human can still diagnose a dead bridge in one command (`bp cmux status`). Everything rides the existing `/v1/tasks` lease/epoch contract; there is no parallel ledger and no server change.

## Ground truth (wave-1 exploration, 2026-07-10)

The bridge is BUILT and merged at HEAD (c34774d5 + c3adf3f5): `internal/cli/cmux_hook.go` IS the hook adapter, `internal/taskboard/cmux.go:36` IS CmuxWorkerID(); install/status/dispatch verbs exist and are tested. The ledger lagged the code (inverse of the false-done finding). Verified by RUNNING the suites (CC=/usr/bin/clang), not trusting briefs:

- cb-worker-id 3/3 met · cb-hook-entrypoint 5/5 · cb-install-print 3/3 · cb-dispatch-verb 5/5 (`--proven-only` proven via shared `TestParseFrontierFlags`, tasks_frontier_cmd_test.go:45) → evidence-closed this wave.
- cb-status-verb 3/4 (the server-unreachable degradation line is rendered by code but never asserted) — lead closes it when cb-hook-breadcrumb merges.
- cb-hook-failsafe 2/3 — grep guard missing; the fail-safe matrix (cmux_hook_test.go:236) has ZERO Stop/PreToolUse rows; empty-stdout is unasserted on the Stop path (the branch-heaviest, 4 network calls). Wave-1 slice.
- REAL drift: the interactive `bp tasks` board (program.go:847/:864 → ResolveWorker) and the desk TUI (cmd/barkpark/tui-mutations.go:361 workerIdentity clone) are cmux-BLIND — a raw cmux pane (CMUX_SURFACE_ID set, BARKPARK_WORKER_ID unset) self-fences: hook claims as `cmux-<surface>`, board closes as `tui-<host>` → 409. Masked whenever the install shell-line exports BARKPARK_WORKER_ID.
- No tripwire binds the install shell-line literal (cmux_install.go:37) to Go tier-2 (`"cmux-"+surface`, cmux.go:41) — each test pins its own literal; prefix drift ships silently.
- Swallowed hook failures leave zero breadcrumb; `bp cmux status` conflates 404 with unreachable (cmux_cmd.go:105); cmux_hook.go:12,49 claim a 300s TTL (real server default 2700s, ttl_sweeper.ex:106); `expired_at` is written post-mortem-only by the sweeper so status never shows a live countdown.
- NOTHING wires the hooks in any settings file; `bp cmux install` is print-only by design; the bridge appears in no doc card. "Auto-owns" is aspirational until install --merge + docs land. Only unrecorded hand smokes (Jul 6-7 renew stamps) prove the live loop.

## Decisions

1. **Reconcile before building** — evidence-close the four fully-proven children with file:line + test evidence; the wave builds only the honest delta. Why: the ledger is the spine; real-done-left-ready is as corrosive as fake-done.
2. **Parent by slug `cmux-bridge-goal`** — new children use `parent_id=cmux-bridge-goal`, same as existing siblings (a4614954 is that doc's UUID; `bp task get` resolves the slug, 404s the UUID). Why: one tree, no fork.
3. **Adopt cb-hook-failsafe as the matrix task** — patch its criteria to add Stop/PreToolUse failure rows + empty-stdout assertions; the grep guard scopes to `cmux_hook.go` hook paths only (`cmux_cmd.go` status legitimately prints stdout). Why: hookStopClose's whole failure surface is uncovered, and empty-stdout is unguarded exactly where a stray Print would break Claude Code's hook parsing.
4. **Interactive boards claim as CmuxWorkerID** — program.go + desk TUI switch from ResolveWorker/workerIdentity to taskboard.CmuxWorkerID. Semantic call, made: in a cmux pane the PANE owns the task, so a human pressing `c`/`x` acts as `cmux-<surface>`, not `tui-<host>`. Why: this makes "one function, honored everywhere" true; the self-fence is a live bug.
5. **Single-source the shell-line** — one exported constant/helper feeds Go tier-2/3 AND the install shell-line; one test asserts CmuxWorkerID(surface=X) equals what the printed line would export for X. Why: independently-pinned literals are what allow silent divergence.
6. **Fail-safe ≠ fail-invisible** — the hook writes a last-error breadcrumb (beside the renew stamp, same state dir) on every swallowed failure; `bp cmux status` surfaces it, disambiguates 404 vs unreachable, shows claim age from `claim.ts_iso` (TTL from BARKPARK_TASK_LEASE_TTL_SECONDS, default 2700, rendered as approximate), and the wrong 300s comments die. Why: the agent is never broken, but a dead bridge must be diagnosable in one command; `expired_at` cannot drive a live countdown.
7. **Adoption = `bp cmux install --merge`** (existing child cb-install-merge): additive JSON merge into ~/.claude/settings.json, dedup by exact command string, backup first, --yes gate, idempotent, malformed → print-only fallback, never removes a foreign hook. Why: print-only install means "auto-owns" never happens organically. The verb NEVER touches repo `.claude/settings.json` and only runs when a human invokes it.
8. **Pane-context-on-claim is PARKED** — claim body stays `{"worker_id"}`; structured surface/workspace fields require a server write-path change (tasks.ex claim map), violating Go-only/no-server-change, and the worker string already carries the surface id. Why: weakest delta, real contract cost.
9. **SUPERSEDED (was: cb-next-frontier-claim stays a reserved design marker)** — the dispatch-frontier-v2 epic built it: PR #2147 (710cbe53) landed `bp cmux dispatch --claim` (claim-before-spawn, exports BARKPARK_WORKER_ID=cmux-dispatch-<id> + BARKPARK_TASK_EPOCH into the pane, cmux_dispatch.go:113/:171) and closed cb-next-frontier-claim 7/7. No open cmux residue from #2147.
10. **Builder law**: `cc` alias shadows clang — every Go gate runs `CC=/usr/bin/clang` (CGO_ENABLED=0 fine). Go-only slices merge on the Go gate; PR bodies carry `Task: <id>`; worktrees from origin/main after git fetch; builders claim first.

### Wave-2 decisions (2026-07-10)

11. **The smoke is a committed bash harness, `scripts/cmux-smoke.sh`, invoking `bp cmux hook <event>` directly with synthetic stdin** inside its own env — real guerrilla, real task documents, no live Claude session (deterministic and honest; stdin never drives hook behavior, env does — cmux_hook.go drainHookStdin). Manual-run with the invocation documented in its header, NEVER CI-wired (the whole harness family — claude-chat-e2e.sh, media-smoke.sh, idp-interop.sh — is deliberately manual). Pure script slice: merges on its own gate (bash -n + a real PASS run), no Go gate needed.
12. **Isolation recipe (both seams, both proofs)** — capture guerrilla creds from the real config FIRST, then `HOME=$SCRATCH` AND `XDG_CONFIG_HOME=$SCRATCH/.config` (install --merge hard-targets `os.UserHomeDir()/.claude/settings.json` with no flag override; hook state roots at `os.UserConfigDir`, which IGNORES XDG on macOS — set both for cross-platform truth). Export BARKPARK_API_URL/API_TOKEN/WORKSPACE/PROJECT/DATASET explicitly (env beats config, cli.go envContext). MANDATORY preflight: `bp task get` a known task must succeed before any scenario is trusted — under isolated HOME a missing scope var silently falls to the baked localhost:4000 floor and every scenario masquerades as dead-server. Proof of untouched: before/after shasum-256 on BOTH real targets — `~/.claude/settings.json` AND `~/.config/barkpark/config.json` — byte-equal (login-E2E precedent, extended to the second target login never had). `trap … EXIT` cleans scratch + closes throwaway tasks (no repo trap convention exists; this harness sets one because sequential rm -rf leaks on early failure).
13. **Scenario forcing (distrust vacuous green)** — epoch bump: delete the whole cmux state dir (`$XDG_CONFIG_HOME/barkpark/cmux` + `$HOME/Library/Application Support/barkpark/cmux`) to beat the 60s renew throttle (renewDue fails OPEN); never compute sha1 stamp filenames. Dead server: `BARKPARK_API_URL=http://127.0.0.1:1` (connection-refused = instant; hookTimeout is a hard 4s package var, a black-hole host stalls 4s×4 calls on Stop). Breadcrumb + lease asserted via `bp cmux status -o json` fields (claim_worker string-equal `cmux-$CMUX_SURFACE_ID`, claim_epoch integer-bumps, last_error.event), not file spelunking. Close-vs-leave driven by the task doc's acceptance_criteria: Stop with met:false → honest leave-claimed, NO breadcrumb; flip met:true via `/v1/data/mutate` patch → Stop closes through the observed_rev CAS. Throwaway tasks created AND closed inside the harness, labeled `smoke`; BARKPARK_WORKER_ID stays UNSET so tier-2 (`cmux-<surface>`) is what's proven.
14. **Docs owner = docs/setup/TASK-SYSTEM.md, NOT docs/cards/cli.md** — budget math forces it (the wish's sanctioned fallback): cli.md is 2393B against the CI-hard 2400B card cap (7 bytes free — a section cannot fit without sacrificing existing CLI coverage), while TASK-SYSTEM.md (15996/16000B) carries the claim/lease/renewal narrative the bridge natively extends (canonical-for:task-system-guide). The docs PR MUST bundle a compensating ~800B trim of TASK-SYSTEM.md human prose in the same commit or check-doc-budgets.sh reds. No cli.md edit this wave; no new card (7-card cap is law); cb-docs-card's criteria are patched on the ledger to name the real owner.
15. **Uninstall is documented honestly as a manual edit** — `bp cmux` has only hook|dispatch|install|status; NO uninstall verb exists and the doc must not invent one. Uninstall = remove the barkpark hook group from `~/.claude/settings.json` (install --merge is additive, backs up first, never touches foreign groups). Env-dialect law honored by showing NO placeholder syntax at all — hook lines are bare `bp cmux hook <event>` commands; auth points at `~/.config/barkpark/`.
16. **Goal close = CREATE anchor criteria, then mark met** — cmux-bridge-goal has NO acceptance_criteria field (verified); "stamp" means create-then-evidence, not annotate. Siblings d55dc406 (cb-worker-id 3/3), dc443429 (cb-hook-entrypoint 5/5), 89251775 (cb-hook-failsafe 7/7) are verified genuinely done on the published ledger — do NOT re-close (failsafe's claim is an expired lease with lifecycle=done; the lifecycle signal is what gates read, and a re-close would need a churning re-claim). The wish's "close them" was stale.
17. **This charter is untracked — the ledger-close slice commits it** with the wave-1 log reconstructed below (the only durable copy lived in PR #2134's body) and the wave-2 log appended at close. Law on disk beats law in a PR body.

## Roadmap

**Wave 1 (MERGED as PR #2134, 4e99ae35 — HARDEN + on-ramp, 5 parallel slices):**
1. `cb-hook-failsafe` — complete the fail-safe proof: grep guard + Stop/PreToolUse matrix rows + empty-stdout everywhere (medium). Owns cmux_hook_test.go + new guard test file; touches no product code.
2. `cb-worker-id-unify` — interactive board + desk TUI claim/close honor CmuxWorkerID; protective self-fence test (medium). Owns program.go + cmd/barkpark/tui-mutations.go.
3. `cb-shellline-tripwire` — single-source constant binds shell-line to Go tier-2; cross-derivation test (small). Owns taskboard/cmux.go + cmux_install.go shell-line region.
4. `cb-hook-breadcrumb` — last-error breadcrumb + status hook-health/honesty (404-vs-unreachable, claim age, TTL truth); lands the server-unreachable assertion that completes cb-status-verb (medium). Owns cmux_hook.go product code + cmux_cmd.go; tests in NEW files only (cmux_hook_test.go belongs to slice 1).
5. `cb-install-merge` — the additive settings writer in NEW file cmux_install_merge.go; only a minimal flag hook in runCmuxInstall (slice 3 owns the shell-line region of cmux_install.go) (medium).

**Wave 2 (this wave — PROVE + document + CLOSE, 3 slices):**
1. `cb-live-smoke` — committed repeatable E2E harness `scripts/cmux-smoke.sh` against guerrilla: scratch tmux-equivalent env + `install --merge` into scratch HOME → SessionStart claims a throwaway smoke-labeled task as `cmux-<surface>` → PreToolUse renews (epoch bumps, same worker) → Stop honestly leaves-claimed on unmet criteria, closes after met-flip → dead-server row proves exit 0 + byte-empty stdout + breadcrumb + honest `bp cmux status`. Isolation shasum-proven on both real targets (Decisions 11–13). Replaces the unrecorded Jul 6-7 hand smokes. Script-only slice.
2. `cb-docs-card` — the bridge's doc story in docs/setup/TASK-SYSTEM.md (Decision 14): install → auto-own → diagnose (breadcrumb/status) → uninstall (manual, Decision 15); compensating trim in the same PR; budgets + anchors gates green. Criteria patched to the real owner.
3. `cb-ledger-close` (lead) — commit this charter (wave-1 log reconstructed, wave-2 log appended), create+evidence anchor criteria on cmux-bridge-goal, close cb-live-smoke/cb-docs-card merge-gated criteria on merge, close cmux-bridge-goal. Epic COMPLETE when this lands.

**Parked:** pane-context on the claim (server change — file under the tasks-server vein if ever wanted). Claim-before-spawn dispatch UNPARKED and shipped by #2147 (Decision 9).

## Wave log

### Wave 1 — 2026-07-10 — MERGED as PR #2134 (4e99ae35), judged A / ship
Reconstructed from the PR body (the charter was untracked when the wave closed; committing it is a wave-2 obligation — Decision 17).

The bridge code already existed at HEAD (c34774d5 + c3adf3f5) — this wave RECONCILED the lagging ledger (4 tasks evidence-closed against merged PRs: cb-worker-id 3/3, cb-hook-entrypoint 5/5, cb-install-print 3/3, cb-dispatch-verb 5/5), then built the honest delta:

1. **Fail-safe matrix completed** (test-only) — every hook error path proven exit-0 + EMPTY-stdout under a fault-injecting server: Stop with dead/hung/409-fenced/500 server, oversized stdin, unwritable state dir; plus a source tripwire (no os.Exit/fmt.Print in cmux_hook.go — mutation-probed both directions; cmux_hook_guard_test.go:20).
2. **One worker id honored everywhere** — the interactive `bp tasks` board and desk TUI switch to CmuxWorkerID, killing the live self-fence bug (pane hook claims cmux-<surface>, board tried to close as tui-<host> → 409).
3. **Shell-line tripwire** — the install line and Go tier-2 derivation share one constant (taskboard.CmuxSurfaceExport, cmux_install.go:94); they can never drift silently.
4. **Breadcrumb diagnosis** — fail-safe ≠ fail-invisible: swallowed hook failures stamp a local last-error that `bp cmux status` surfaces (404-vs-unreachable disambiguated, claim-age + TTL truth, wrong 300s comments dead).
5. **`bp cmux install --merge`** — the additive settings writer (backup, dedup by exact command string, --yes gate, idempotent, foreign hooks untouched), so "a pane auto-owns its task" happens without hand-editing.

Parked honestly at the time: pane-context-on-claim (server write path — violates no-parallel-ledger) and the live E2E harness (this wave 2). Post-wave-1 fact: #2147 (710cbe53) shipped `bp cmux dispatch --claim` and closed cb-next-frontier-claim 7/7 (Decision 9 superseded). Ledger after wave 1: 11/12 children done; cb-docs-card the only open child; cmux-bridge-goal open, no anchor criteria yet.

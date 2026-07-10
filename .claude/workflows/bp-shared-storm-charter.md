# Shared Storm — Epic Charter

Epic task: `shared-storm-epic` (published, open, priority 1). Founded 2026-07-09 at the CLOSING wave — t1–t6 shipped code before this charter existed; this file is the epic's memory from here to close.

## Vision

An anonymous jarl-card visitor clicks the lightning card and every other visitor sees the strike land in realtime — a shared, durable "total strikes" counter served by a Barkpark **pulse** plugin. The core API has **no CORS**; the plugin owns its whole public surface (`:public_api` bucket, PublicCors, and its own abuse caps). A hostile client hammering any pulse surface hits plugin-owned caps, gets a structured 429 + Retry-After it can honor with exponential backoff, and the feed stays readable for everyone else. Fresh-install invariant holds: all plugins off → Barkpark still works (`default_enabled?: false` on pulse). The epic closes only when every child task carries per-criterion evidence — this epic does not join the false-done list.

## Decisions

1. **Discard both stranded branch pointers; adopt the worktree's uncommitted files.** `storm-t7-hardening-docs` @ 71d7748f is an ancestor of main with 0 commits ahead (an unrelated SCIM fix, #1577); `feat/pulse-cost-so-far` @ 6e0bfe3c is byte-identical to merged #1545 and regressive elsewhere (removes `default_enabled?: false`, lacks main's newer migrations). But the wt-storm-t7 **worktree** holds real uncommitted t7 work: `api/test/barkpark_web/pulse_abuse_drill_test.exs` (176 lines) + tight-cap fixtures in `api/config/test.exs`. Why: the drill is already written against main's shipped controller constants (burst 3, daily Retry-After 3600, byte-cap 400) — rebuilding it is waste; the branch commits carry nothing.
2. **Adopt via a fresh branch off main — never edit the stranded worktrees in place.** Why: those worktrees belong to dead sessions; copying the two files onto a clean branch keeps history honest and lets the strands be pruned.
3. **No new token bucket.** The hardening mechanism is `Barkpark.RateLimiter` (core, generic, ETS, supervised, reused by ticket/api plugs); the pulse plugin owns the **policy** at its own call sites. Why: the CORS law is "mechanism in core, policy in plugin" — same shape as PublicCors. The write path shipped hardened in #1171 (per-IP bucket, daily cap, byte cap, structured 429); forcing a plugin-local re-implementation is churn against working tested code.
4. **The one genuine open hardening seam this wave: GET /recent + /stats are unthrottled.** Close it controller-locally (bill a per-IP RateLimiter bucket in `recent/2`/`stats/2`), NEVER via a plug on the `:public_api` pipeline. Why: `recent` is DB read amplification with zero backpressure today; a pipeline plug would collaterally throttle Bulldocs/Sheets and every other `:public_api` plugin route.
5. **Defer per-IP socket-connect and per-IP cursor caps — accepted residual, recorded here.** Why: they require `connect_info` plumbing in `endpoint.ex` (core file), risk NAT-nuking legit shared-IP visitors, and protect a vanity counter; joins already fail closed on unknown channels and cursors are per-socket throttled at 80ms. An honest close beats gold-plating.
6. **Docs land in the pulse @moduledocs, not the card.** `docs/cards/plugins.md` is at its hard byte cap EXACTLY (2400/2400 — one added byte reds CI) and already names pulse in the `:public_api` row; `Barkpark.Plugin` @moduledoc already states "the plugin owns its own abuse caps." The caps + client-backoff mechanics go in `api/lib/barkpark/plugins/pulse.ex` @moduledoc (unbudgeted, unanchored). Why: net-zero card edits at an exact cap are a trap; the canonical seam sentence already exists.
7. **Honest close requires backfilling t1–t6 evidence.** All six are lifecycle done with EVERY criterion met:false, evidence:"" — the false-done-evidence pattern. t1–t4 evidence comes from main (#1171 + live files/tests); t5 (guerrilla deploy) and t6 (jarl-card client) can only be proven by live smoke against guerrilla + the jarl-card page. Why: "done" that git can't see must be proven where it lives.
8. **PR/task truth**: #1171 = t1–t4; #1214/#1222 (dashboard) and #1412/#1545 (cost telemetry) were unplanned extra work, not t5/t6; t5/t6 have no in-repo commit by design.

## Roadmap

| # | Slice | Status | Size |
|---|-------|--------|------|
| t1–t4 | Plugin skeleton, ingest+counter, feed/stats, TTL sweep (+CORS, write-path caps) | SHIPPED #1171 (evidence backfill pending) | — |
| t5 | Deploy pulse to guerrilla + jarl-card channel + smoke | done, unproven → t8 backfills via live smoke | — |
| t6 | jarl-card client (separate repo) | done, unproven → t8 backfills via live fetch | — |
| extra | Studio dashboard (#1214/#1222), cost telemetry (#1412/#1545) | SHIPPED, unplanned bonus | — |
| **t7** | Hardening drill + read-path throttle + docs (`storm-t7-hardening-docs`) | THIS WAVE | medium |
| **t8** | t1–t6 evidence backfill (`storm-t8-ledger-evidence`) | THIS WAVE | small |
| **t9** | Strand prune + epic close (`storm-t9-close-out`) | THIS WAVE, after t7 merges | small |
| deferred | Per-IP socket-connect cap, per-IP cursor cap (connect_info plumbing) | ACCEPTED RESIDUAL (Decision 5) | — |

## Wave log

### Wave 2026-07-10 — closing wave (t7 + t8 built; t9 honestly blocked)

**Landed:**

- **t7 hardening (`storm-t7-hardening-docs`)** — built on `loop-epic/pulse-t7-adopt-abuse-drill-throttle-read-0`, reviewed + formatted on **`loop-epic/pulse-t7-adopt-abuse-drill-throttle-read-0-r` @ abe71767 — merge THIS branch**. Adopted the stranded worktree's abuse drill (now 233 lines, extended with read-flood tests) + `config/test.exs` tight-cap fixtures per Decisions 1/2; closed the Decision-4 seam (per-IP read bucket `{:pulse_read, ip, channel}` 30-burst/10-per-sec in `recent/2`+`stats/2`, reusing `rate_limited/2`); caps table + client backoff contract + XFF-spoofability caveat in the pulse @moduledoc per Decision 6 (`docs/cards/plugins.md` untouched at its 2400B cap). Gate green on the -r branch: 46 tests 0 failures across the 5 pulse suites + docs-anchors + doc-budgets. Reviewer independently re-proved the throttle protective (neutering `check_read_bucket/2` flips exactly the 2 read-flood tests RED). Only review fix needed: `mix format` on the drill test. NOT pushed/merged — lead merges the -r branch (wait for Elixir Test gate) and closes criterion 3.
- **t8 evidence backfill (`storm-t8-ledger-evidence`)** — ledger-only, no branch. All six done children t1–t6 now carry non-empty per-criterion evidence (t1–t4 from #1171 + file:line anchors + named tests; t5/t6 live smokes 2026-07-10). Reviewer re-verified live: pulse `/stats` 200 (total=1955), pulse preflight 204 + `access-control-allow-origin: *`, core `/v1/data` preflight 204 with ZERO CORS headers — the plugin-owns-CORS law holds in prod. Criterion 3 (LEAD re-read of t1–t6) open.

**Stalled (correctly):**

- **t9 close-out (`storm-t9-close-out`)** — refused to run because its precondition (t7 merged) is unmet; pruning wt-storm-t7 now would destroy the only copy of unmerged t7 work. Builder stamped full reconciliation into all 3 criteria (met:false), pruned nothing, deleted nothing. New fact recorded there: `feat/pulse-cost-so-far` ALSO exists on origin, so pruning needs `git push origin --delete feat/pulse-cost-so-far` on top of the local `-D` (the t9 instruction's "local-only" claim was wrong).

**Next wave:** (1) Lead pushes + merges `loop-epic/pulse-t7-adopt-abuse-drill-throttle-read-0-r` (.ex/.exs change — wait for the Elixir Test gate), closes t7 criterion 3 → t7 done. (2) Lead re-reads t1–t6 evidence, closes t8 criterion 3 → t8 done. (3) Re-run t9 exactly as written plus the origin deletion: prune wt-storm-t7 + tmp worktrees, delete `storm-t7-hardening-docs` + `feat/pulse-cost-so-far` (local AND origin), confirm all children done, close `shared-storm-epic` citing #1171 (t1–t4), t5/t6 live smokes, the t7 merge PR, bonus #1214/#1222/#1412/#1545, and Decision-5 deferrals. After t9 the epic closes honestly — nothing else remains.

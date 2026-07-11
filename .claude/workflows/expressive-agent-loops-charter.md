# Expressive Agent Loops — epic charter

**Epic anchor:** `task-d7b7ce69e14d9124` (expressive-agent-loops — Barkpark Tasks pushes for live, lock-grade feedback)
**Prep Paper (read first):** `/papers/wave-deck-zen-handoff` on guerrilla — the deck→epic-cycle mapping, the ratified direction, and §"Tasks-side pushes" carrying the wave-1 task ids.
**Concept board (the target feel):** claude.ai/code/artifact/02bc9243-d092-49de-806d-288631fa8a7d — criteria as locks, momentum header, activity ticker, TUI-parity glyphs.
**Design handoff in-repo:** `docs/specs/wave-deck-zen/` (Zen deck + dashboard-storyboard variant + screenshots).

## The wish

> Agent loops narrate themselves live: criteria stamped mid-claim with honest misses, a now-line pulse on every board, one event stream feeding every surface — proven by a real run, not a demo.

Every phase and gate is checked against that sentence.

## Laws (non-negotiable, from ratified decisions)

- **D1 · One-substrate law.** Wave = chat session · gate = AskUserQuestion ask row · decision log = wave Paper · any deck/board surface = projection with no state of its own. A slice needing its own store, second event stream, or run loop is a fork — redesign it.
- **D2 · Vocabulary is pinned.** Lifecycle glyphs/colors come 1:1 from `design/tokens.json` lifecycle (○ dim → ○ bright → braille spinner blue → ✓ TEAL; `!` amber blocked; done-teal ≠ status-ok green). No lookalikes, no per-surface translation. The task design-language spec's §0 is the acceptance test: *it must feel alive; you always feel progress.*
- **D3 · Evidence or nothing.** `stamp --met` requires evidence; `--miss` records the honest attempt without flipping. Close still validates the full set — stamp is progress, close is the seal. Distrust vacuous green: every verifier claim needs a run proof.
- **D4 · Stamp-as-you-go.** Builders in this epic USE the capabilities they build the moment they merge (dogfood order: stamp/pulse land first, later slices stamp their own criteria live).

## Wave 1 scope — the four filed children (already perfected, claim them; do NOT refile)

| slice | task id | surface |
|---|---|---|
| `bp task stamp` — criterion-level mid-claim evidence + `--miss` attempts | `task-79d71bc80427f0e4` | api/ + internal/cli |
| `bp task pulse` — now-line + lease renewal, one atomic write | `task-9e59a7bd4fb241a2` | api/ + internal/cli |
| task events feed — `/v1/tasks/events?since=` cursor stream | `task-1780b182cf404dc7` | api/ + internal/cli |
| TUI locks strip — criteria ladder `✓✓⠹○ 2/4` on `bp tasks` board | `task-70eb8244dd1e702a` | internal/taskboard |

Dependency order (revised at Decide 2026-07-11): **stamp → pulse → events feed**, with **locks strip ∥** (Go-only, builds against the pinned wire shapes in D8/D9) and a fifth small slice, **dogfood wiring** (`.claude/workflows/bp-epic-cycle.workflow.js` teaches the new verbs; node-check gated). Pulse and events are NO LONGER parallel — events criterion 1 demands ordered `task.pulse` events, so pulse (now carrying an explicit event-emission criterion) lands first. The epic parent's own criterion 2 ("a real agent loop demonstrably stamps criteria live") is the wave's integration proof, closed at Review with a real epic-cycle run.

## Wave-1 build decisions (Decide 2026-07-11 — verification-backed, follow these)

- **D5 · Work-digest narrows to the brief.** PROVEN broken by construction otherwise: the claim-time work_digest hashes acceptance_criteria in full, so a mid-claim stamp makes the default-path close 409 `doc_changed_since_claim` (probe output: `{:error, {:doc_changed_since_claim, …, ["acceptance_criteria"]}}`). Fix (ships INSIDE the stamp slice): `WorkDigest.field_digests/normalize` reduces each acceptance_criteria entry to its `criterion` string before hashing — progress subfields (met/evidence/attempts, present or future) never trip the fence; criterion-text edits/adds/removes/reorders still do. Update the WorkDigest moduledoc + close.ex "work-defining" comment; add `work_digest_test.exs` pinning both directions (none exists today — no golden churn).
- **D6 · Advisory-lock keys.** The repo is genuinely split (proven): claim/ttl_sweeper/compactor lock `task:<doc_id>` (string), close/release/move/fence/mutations lock `task:<uuid>`. Rev-CAS is the real cross-family correctness contract; the lock only reduces contention. **Stamp joins the close family** (controller resolves doc_id → `task.id`, locks `task:<uuid>`) — it must serialize with close over the same criteria. **Pulse joins the renewal family** (`task:<doc_id>` string) — it must serialize with the TTL sweeper's reap. Family convergence + fixing the false "SAME key close uses" comments = backlog, not this wave.
- **D7 · Auth = holder + verb-appropriate epoch.** Both verbs check `claim.worker == worker` — extract `Release.check_holder/2` into `Tasks.Internal.check_holder/2` (stamp slice does the extraction; pulse consumes it). **Stamp epoch-fences exactly like close** (a lapsed/fenced claim cannot stamp; renew then restamp — accepted friction). **Pulse does NOT epoch-fence** (it IS the renewal; matches shipped `do_renew`) and **REFUSES on a lost lease** (`{:error, :not_holder}`) — it is a new write path (a `do_renew` sibling in its own module), NEVER a thin `claim_by_id` call, because claim_by_id's fall-through silently RE-CLAIMS with a fresh digest when the lease lapsed (proven hazard). Worker+epoch are world-readable; the API token stays the only security boundary.
- **D8 · Wire vocabulary pinned.** New mutation_events kinds: **`task.criterion`** (stamp, both paths) and **`task.pulse`**, emitted via `Tasks.Internal.insert_mutation_event!` in the same transaction (D1 one funnel). `--met` REQUIRES non-empty `--evidence` (reject otherwise). `--miss` appends `{"note","ts","worker"}` to a criterion-level `attempts` list, bounded to the 5 most recent (enforced in app code — no schema bound exists), and MUST pin `met` explicitly: the existing parse/merge paths default met→true when absent (proven), the exact footgun that would flip a lock on a miss. Schema validation passes `attempts` through untouched (proven) — no migration. CLI (pinned for the dogfood slice): `bp task stamp <id> <worker> <epoch> --criterion N (--met --evidence "…" | --miss --note "…")` → `POST /v1/tasks/:doc_id/stamp`; events: `bp task events --since <cursor>` → `GET /v1/tasks/events?since=`. New verbs = manifest map + route tuple + controller action only (Go dispatch is fully generic, proven live; content-addressed capabilities ETag means the verb appears on the next bp invocation, no rebuild).
- **D9 · Pulse shape.** `content.claim.now = {"text","ts","criterion"?}` written in the SAME atomic `Repo.update_all` as the epoch bump + ts_iso refresh; work_digest untouched. Module `Barkpark.Tasks.Pulse` (bare `Barkpark.Pulse` is Shared Storm's); docstring disambiguates from taskboard's SSE-keepalive `pulseMsg`. CLI: `bp task pulse <id> <worker> --now "…" [--criterion N]` (no epoch arg — pulse survives fences). Staleness renders from `claim.now.ts` vs lease TTL.
- **D10 · Events feed = a NEW keyset query, not Prime reuse.** `GET /v1/tasks/events?since=<mutation_events.id>`: WHERE dataset + `type='task'` + `id > since`, ORDER BY id ASC, batch ≤500, and the projected shape INCLUDES `id` as the cursor (Prime.recent_events has no id and sorts by inserted_at — replay-unsafe; do not reuse). Route mounts ABOVE `/tasks/:doc_id` (prime's comment is the precedent). Tail query proven 0.39ms on the PK index; NO migration now — a `(dataset,type,id)` index is backlog before the table 10x's. Criterion 1 rescoped: claim/close/move ordering provable at build; stamp/pulse kinds verified in the same PR's tests once those merged (integration order guarantees it).
- **D11 · Board ladder renders with ZERO new glyphs.** `CriterionItem` widens to carry attempts; ladder token in `richRowMeta`: ✓ teal (met) · `!` amber (recorded miss — reuses blocked's allowlisted rune) · braille spinner ONLY for the criterion named by the live pulse's `criterion` field · ○ (untouched) + the existing fraction. Everything from `tokens_gen.go` GenLifecycle — glyph_budget allowlist unchanged, `board_theme_parity_test.exs` untouched, Go-only merge lane stays open. Goldens regenerated in the same PR. NOTE: `activityband.go` does not exist (NOW/NEXT band retired, Amendment 7); braille = `spinner.go`, glyph render = `components.go`, model = `types.go`.
- **D12 · "Every board", honestly scoped.** Wave-1 = TUI board + Studio `/admin/projects` + papers-reader task-board embeds (all already live on `documents:<dataset>`). CLI table / MCP prime are one-shot by construction; the web Next.js embed has no client realtime — both filed as backlog, never silently claimed.
- **D13 · task-566d782d09bd0eea (bp task renew) is superseded.** Its criteria contradict shipped `do_renew` (epoch IS bumped). Cancelled with a pointer to pulse; the cmux auto-renewal half re-filed as a backlog task (cmux hook pulses).

## Wave 2+ (do not build in wave 1; seed the handoff)

Workflow mode in the regular chat: `gated: true` arg on bp-epic-cycle (AskUserQuestion between phases, countdown default-pick logged), phase furniture (whisper + dots) in Studio chat + CLI statusline, chat consuming the events feed. Then the deck-skin projection (P3) and in-phase steering (P4) per the Paper.

## Engineering doctrine for this repo (hard-won; violate = red)

- Main checkout stays on `main`; ALL branch work in worktrees (EnterWorktree). Elixir verification in the integration worktree pattern (`cp _build/test` + symlinks) — warm tree is contended.
- `.ex/.exs/.heex` changes WAIT for the Elixir Test gate before merge; Go-only may merge on its own gate. Elixir CI needs fetch-depth:0 (git-describe tests).
- Contract-shape changes grep the WHOLE lib/ + test/ tree (error emitters are duplicated: query_controller AND legacy_controller).
- Guard + fix never co-merge (fail-before gate) — decouple.
- PRs reference their task id (pr-task-gate is required-by-name). Advisory reds (Format, Vercel) never block; "Changeset present" is correctness.
- bp CLI freshness: `make cli-build` after CLI-touching merges; taskboard goldens updated in the same PR as renderer changes.
- Repo `cc` alias shadows clang → `CC=/usr/bin/clang` if cgo/wasm builds misbehave.
- **Shared `api/_build/test` is contended and can be CONTAMINATED** (a concurrent worktree's `mix compile --force` bakes its own `media_upload_dir` path; direct `mix test` in the main checkout then reds 3/3). Elixir gates run ONLY in the builder's own worktree with the isolation recipe (symlink `api/deps`, `cp -a api/_build/test`, then compile+test there) — a red in the shared checkout is contamination first, regression second.

## Run policy

- Models: Fable for strategy/digest/decide/review; Opus for builders/judges of the Elixir slices; Sonnet for survey. Never Haiku.
- Workers claim via `bp task claim <id> <worker>` and close with `--set criteria:=[…]` evidence — the ledger is the spine; the wave Paper is opened at Strategize and closed as the debrief.
- Gates for this run: unattended defaults are acceptable (lead decides between phases as today); this epic BUILDS the substrate that wave-2 gates will ride.

## Wave log

### Wave 2026-07-11 (wave 1 — stamp · pulse · events · locks strip · dogfood)

**Landed (all five slices built + reviewed green; branches STACKED in merge order):**

1. `bp task stamp` (task-79d71bc80427f0e4) — `loop-epic/bp-task-stamp-criterion-level-live-evide-0-r`. Criterion-level mid-claim evidence + D5 digest narrowing + check_holder/merge_criteria extraction to `Tasks.Internal`. Reviewer added 4 ConnCase HTTP tests pinning the exact CLI wire shape (body-string args + query-string flags).
2. `bp task pulse` (task-9e59a7bd4fb241a2) — `loop-epic/bp-task-pulse-now-line-lease-renewal-in--1-r`, stacked on stamp-r. Now-line + lease renewal in one atomic write, own write path (never claim_by_id). Reviewer caught a REAL red: the branch added a 9th verb while the manifest test still pinned `== 8` (builder's gate excluded that suite); fixed in the stack resolution — manifest now pins 10 verbs + the task.pulse shape (no epoch anywhere).
3. Events feed (task-1780b182cf404dc7) — `loop-epic/task-events-feed-v1-tasks-events-since-k-2-r`, stacked on pulse-r. `GET /v1/tasks/events?since=` keyset replay over mutation_events (id = cursor, never Prime reuse); route above `/tasks/:doc_id` with a route_info precedence test. Manifest pins 11 verbs.
4. TUI locks strip (task-70eb8244dd1e702a) — `loop-epic/tui-locks-strip-criteria-ladder-now-line-3-r` (Go-only lane, independent). Criteria ladder `✓⠹!○ 2/4` with narrow-fallback shedding, now-line ticker with TTL decay, momentum criteria tally; goldens genuinely show all three. Zero new glyphs.
5. Dogfood wiring (task-eal-w1-dogfood-wiring) — `loop-epic/epic-cycle-dogfood-wiring-builder-prompt-4-r` (this branch; also carries the charter cherry-pick). Builder prompts now stamp per criterion + pulse at phase boundaries.

**Cutover warning (D5):** any lease claimed BEFORE stamp merges carries an old-style work_digest; its first default-path close after deploy 409s `doc_changed_since_claim` once. Recovery: re-read then pass `observed_rev`. One-time, documented.

**Deliberate scope holds:** TUI pulse decay uses the board's pre-existing 5-minute `leaseTTL` UI constant (matches the claim glyph), not the server's 2700s reap TTL — consistent liveness vocabulary, revisit only if it confuses. Detail-frame attempts/pulse rendering filed as task-46d05e6c3369941e.

**Open on the epic:** criterion 2 (a real epic-cycle run demonstrably stamps live) needs stamp/pulse DEPLOYED first — close it on the first post-merge epic run. TUI live ○→✓ flip proof (locks-strip criterion 3) same dependency.

**Next wave should take:** (1) the real-run integration proof (epic criterion 2 + TUI live flip) immediately after merge+deploy; (2) `bp task events` consumption in a first surface (chat/statusline per Wave 2 plan, gated:true arg); (3) backlog: lock-key convergence, (dataset,type,id) index, MCP task_stamp/task_pulse hand-mapping, release-at-HTTP, cmux auto-pulse, web embed realtime — all filed as published children of the epic.

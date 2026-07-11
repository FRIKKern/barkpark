# Chat Task-Hands — epic charter

**Epic anchor:** `task-aafff98c7169f534` (chat-task-hands — the Studio chat wields bp tasks + bulletproof provider login onboarding)
**Lineage:** wave 2 of the Wave Deck direction (`/papers/wave-deck-zen-handoff` — ratified: workflow mode in the regular chat, one substrate, no fork). Wave 1 (expressive-agent-loops, `task-d7b7ce69e14d9124`) landed stamp/pulse/events/locks-strip — this wave makes the chat able to actually USE them.
**Wave Paper:** `chat-task-hands-wave-2026-07-11` (the wave's living story; this charter is the epic's memory).

## The wish

> The Studio chat can always wield Barkpark tasks — bp auto-installed and authenticated in every session — and when Claude (or Codex) isn't ready, the chat walks the user through a small, bulletproof login instead of failing silently.

## Laws (non-negotiable)

- **D1 · One-substrate law (refined 2026-07-11).** ONE credential/config substrate: env vars injected at the chat's Port.open — no config files, no new stores, no second event stream. Two *consumers* of that one seam are legitimate and both ship: the MCP loopback (merged, w12) and bp-on-PATH for the agent's Bash tool (proven viable in plan mode). A slice needing its own auth store is a fork — redesign it.
- **D2 · Never fail silent (vocabulary corrected 2026-07-11).** Every not-ready state renders a NAMED next step in the chat surface. The honest taxonomy, split by lane: **claude lane** = no-binary, not-logged-in (expired credentials degrade to not-logged-in by design — the shapes are indistinguishable without an API call); **bp lane** = no-task-hands (token mint refused), task-token-expired. "Expired/denied device code" and "wrong server" are DROPPED — falsified: api/ has zero device-link endpoints (that flow is cloud-control-plane only, a different account system), and the bp URL is always self-derived from this node's Endpoint, so no second value exists to mismatch. Silence is the bug.
- **D3 · Security posture unchanged — and one leak CLOSED.** Admin-only chat, public-demo hard refuse, per-host opt-out all stand (they keep gating the tab/mount). Barkpark still never sees, stores, or refreshes provider tokens ($HOME OAuth stays the boundary). The bp token minted for chat sessions is scoped and revocable (kind=api, read+write curated, TTL 4h/24h cap, revoked on teardown) — never the host admin token. NEW: the spawn-env slice also SCRUBS the inherited prod secrets (today the child inherits the full BEAM env — DATABASE_URL, SECRET_KEY_BASE, BARKPARK_KEK, every token; live-proven leak) via `{~c"VAR", false}` unsets.
- **D4 · Dogfood.** The proof of criterion 1 is a live chat transcript claiming/stamping/pulsing/closing a real task — which also closes expressive-agent-loops' open criterion 2. The dogfood session runs ARMED (bypassPermissions): plan mode gates every write behind an approval card, on BOTH substrates (Bash and MCP tools gate identically) — the mode picks the transcript, not the substrate.
- **D5 · Codex is trigger-gated.** Trigger checked this wave: CLOSED (no demand signal, Claude-depth backlog not dry). Ship `Capabilities.codex/0` stub + probe target returning binary:false; criterion 4 is designed-not-built (honest).

## Verified ground (2026-07-11 — run-proofs, trust these over memory)

- **:env MERGES, never replaces** (OTP 26–28 stable; proven on 28). Unlisted vars inherit; `{~c"NAME", false}` unsets; **both key and value MUST be charlists** — any binary on either side is an ArgumentError crash at Port.open. The existing `args:` list stays binaries; only the `env:` tuples are charlists. HOME/PATH survive a merge, so claude's OAuth is unaffected.
- **Injected env propagates to grandchildren** (claude's Bash tool subprocesses AND its `--mcp-config` MCP child) — one injection feeds both lanes; scrubbed vars STAY scrubbed down the tree.
- **The chat's plan-mode argv executes Bash reads with zero asks**; writes are GATED (approval card via `--permission-prompt-tool stdio`), not refused. Same for MCP write tools. Autonomous dogfood ⇒ armed bypass.
- **The minted bpcs_ token drives the full task loop over HTTP** — claim/stamp/pulse/close all 200, ledger lands done (ConnCase proof). Task verbs are bearer-gated (`:token_root` → `[:api, :require_token]`), never admin. **Epoch mechanics:** claim→epoch 1; stamp does NOT bump; pulse BUMPS; close is EPOCH-ONLY CAS (worker string is unchecked audit metadata; stamp/pulse ARE holder-gated). The agent must re-read `doc.claim.epoch` from every verb response before the next epoch-gated call.
- **Flat /v1/tasks routes scope to the seeded Default workspace** (AssignDefaultScope), NOT the token's workspace_id. Correct on single-workspace guerrilla; a real gap for multi-workspace (backlogged).
- **Guerrilla host reality:** claude 2.1.207 installed + authed as root (the slot user) at /usr/local/bin — claude readiness needs ZERO deploy work. bp exists only as a stray manual build at /opt/barkpark/bp, off the BEAM's PATH, unconfigured, unmanaged by any deploy step — "auto-installed bp" requires a real instance-deploy.sh install step. **/usr/local/bin IS on the running BEAM's PATH** (/proc-proven), so installing bp there makes it resolvable with no PATH injection.
- **`claude auth status --json` costs ~1–2s** (exit 0/1, `loggedIn` bool, account fields) — readiness probing must be async (spinner), never inline in mount. `claude --version` works with no credentials.
- **Unauthed live stream footgun:** the result frame says `subtype:"success"` but `is_error:true` / `terminal_reason:"api_error"`, and the assistant frame carries `error:"authentication_failed"` — subtype alone misclassifies; the runtime guard keys on is_error/terminal_reason/error.
- **`claude auth login` is manual OAuth code-paste** (spawn, scrape URL, relay pasted code to stdin — needs a held-open process); `setup-token` looks TTY-gated. Driving login from the card is BACKLOGGED; wave-1 card shows instructions + live Re-check.
- **Mint-refused today is silent** (Logger.warning, session spawns handless). CLI precedence (flags > set-env > persisted config > baked dev-token) means OMITTING env on refusal silently falls through to whatever ~/.config/barkpark holds — possibly a different server or higher-privileged token. Refusal must inject a poison sentinel, never absence.
- **Baseline green:** the 4 Elixir chat test files = 347 tests, 0 failures (×2 runs). Go build/vet clean. **Gate regex trap:** `-run 'TestMcp'` matches ZERO tests — real names are `TestMCP*`; every Go gate in this wave uses `TestMCP`.
- **Overlapping ledger tasks** (link, don't duplicate): `task-eal-bl-mcp-stamp-pulse` (task_stamp/task_pulse missing from mcp_tasks.go — 6 tools today, no stamp/pulse) re-parented into this epic as a wave slice; `task-scc-bl-mcp-hands-indicator` superseded by the onboarding-card slice (lead closes it on card merge).

## Decisions (wave 1, ratified 2026-07-11)

1. **Spawn-env injection** at claude_chat.ex Port.open (~:699): merge-add `BARKPARK_API_URL` (mcp_api_url()), `BARKPARK_API_TOKEN` (the SAME minted bpcs_ session token the MCP config uses — one mint, two consumers), `BARKPARK_WORKER_ID` (`claude-chat-<session-id-prefix>`, cmux-style: one worker per chat tab, subagents share the fencing lease); scrub the secret denylist with `{~c"VAR", false}` (enumerate against everything runtime.exs reads). Charlist tuples only.
2. **Mint-refused → poison + rendered state**: inject `BARKPARK_API_TOKEN=bpcs-mint-refused` (an explicitly-invalid sentinel; keeps URL pointed at THIS server so calls 401 here instead of resolving elsewhere) and surface `no_task_hands` in the chat readiness state.
3. **Probe module** `Barkpark.StudioChat.Probe`: pure, provider-neutral `%{provider, binary, path, version, authed?, account}`; claude via `--version` + `auth status --json`; bp via find_executable only (its auth is mint-driven — there is NO login step to onboard); codex stub (binary check, designed-not-built). Config-injectable binary names for tests (existing fake-binary idiom). Always run async off the LiveView (dispatch_send template / Task + handle_info).
4. **Gate inversion**: `enabled?/0` drops `launchable?` — becomes `flag_on? and not public_demo?`. Nav tab + mount keep gating on THAT (posture unchanged: flag-off/public-demo/non-admin still redirect; those 4 chat_live gate tests STAY). Binary/auth absence renders the onboarding card inside the bp-composer chrome, keyed off a `@readiness` assign; Re-check re-probes and unlocks the composer without reload. The 2 claude_chat_test.exs enabled? tests that gate on binary presence flip; new deterministic card tests cover each named state (including the previously-dead `:binary_not_found` copy).
5. **Runtime auth guard**: the Session detects `authentication_failed` / `is_error`+`terminal_reason:"api_error"` frames and emits a typed auth-failure the LiveView maps to the not-logged-in card state — never trust `subtype:"success"`.
6. **bp auto-install**: deploy/instance-deploy.sh builds `./cmd/barkpark` and installs atomically to `/usr/local/bin/bp` on every deploy (idempotent; ARM64 host builds native). No PATH injection needed.
7. **MCP lane completed**: wire `task_stamp`/`task_pulse` into mcp_tasks.go (existing backlog task, re-parented) — tool descriptions must teach epoch re-capture (pulse bumps) and explicit worker-id.
8. **Dogfood transcript** is the final slice: armed session on guerrilla post-deploy, claims/stamps/pulses/closes a scratch task; evidence stamps epic criterion 1 AND expressive-agent-loops criterion 2.

## Wave-1 plan (tasks filed 2026-07-11, children of the epic, wave_paper=chat-task-hands-wave-2026-07-11)

| # | Slice | Task | Builder | Files |
|---|---|---|---|---|
| 1 | spawn-env injection + secret scrub + poison-on-refusal | task-cth-w1-spawn-env | fable | api/lib/barkpark_web/studio/claude_chat.ex (+its test) |
| 2 | Probe module + Capabilities.codex/0 stub | task-cth-w1-probe | opus | api/lib/barkpark/studio_chat/probe.ex, capabilities.ex (+tests) |
| 3 | gate inversion + onboarding card + runtime auth guard | task-cth-w1-onboarding-card | fable | chat_live.ex, nav.ex, claude_chat.ex enabled?, tests |
| 4 | MCP task_stamp/task_pulse | task-eal-bl-mcp-stamp-pulse | opus | internal/cli/mcp_tasks.go (+test) |
| 5 | bp install on deploy | task-cth-w1-bp-deploy-install | opus | deploy/instance-deploy.sh |
| 6 | dogfood transcript (sequenced LAST, after merge+deploy) | task-cth-w1-dogfood | fable | — (evidence-only) |

Integration order: 1→2→3 (Elixir train, stacked or sequential — 1 and 3 touch claude_chat.ex, different regions, sequence them), 4 and 5 parallel anytime, 6 strictly last.

## Engineering doctrine (hard-won; violate = red)

- Main checkout stays on `main`; worktrees for all branch work; Elixir slices WAIT for the Elixir Test gate; Go-only lanes merge on their own gate.
- Stacked Elixir branches: squash-merges force `--onto` rebases of children; sequence the train, one PR at a time.
- Per-Elixir-PR: regen `docs/openapi.json` (`CC=/usr/bin/clang` in worktrees — the cc alias shadows clang); tenant-scope gate wants `# global-read:` DIRECTLY above any by-PK read; TASK-SYSTEM.md has a 16000B cap — assign doc edits to ONE slice.
- `:env` tuples are charlists BOTH sides (`{~c"K", ~c"v"}` / `{~c"K", false}`); the sibling `args:` list stays binaries — mixing the encoding rules is the copy-paste trap.
- Go test gates use `TestMCP` (uppercase) — `TestMcp` matches nothing and greens vacuously.
- TTL sweeper reaps idle claims mid-train: re-claim before the pr-task-gate runs; pulse keeps leases warm AND bumps the epoch — re-read `doc.claim.epoch` after every verb.
- SupervisionIsolationTest flakes (task-fcfdf59d0dd22dc5) — rerun once, don't chase. Postgrex disconnect noise in chat tests is known teardown racing, not a red.
- PRs reference their task id; builders stamp criteria mid-claim and pulse at phase boundaries.

## Run policy

Fable strategy/digest/decide/review; Opus builders for well-specified seams; Fable builders for the subtle/cross-surface slices. Never Haiku. Ledger is the spine; wave Paper opens at Strategize and closes as the debrief. Unattended gates acceptable.

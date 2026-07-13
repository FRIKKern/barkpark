<!-- doc-tier: agent | canonical-for: connectors-epic | budget: 6000tok -->
# Barkpark Connectors — Epic Charter

Make it a first-class, two-minute product action to connect a Barkpark agent to an external
service. Design paper: `/papers/personal-agent-provider-bridge`. Epic: `bp-connectors-epic`.

## Vision

A Barkpark workspace connects an agent to the services its people already use — you TALK TO the
agent from Slack/Discord/Telegram/Teams/WhatsApp/iMessage, and the agent ACTS ON GitHub/Linear —
through one provider-agnostic core, with a Barkpark **Session as the durable cross-surface memory**
(start on Slack Monday, continue on Discord Friday, same thread). Cloud multi-tenant from day one:
each workspace installs its own connectors, credentials isolated, the agent runs sandboxed with
NO host access. The brain and most of the plumbing already exist — this epic builds the *connect
experience* on top of them, not a new engine.

## Two directions, one catalog

- **Channel connector** = inbound, you talk to the agent → **Vercel Chat SDK** adapter (`chat` npm).
- **Tool connector** = outbound, the agent acts → **MCP** (Barkpark already serves MCP via `bp mcp serve`; the mirror is the runner consuming an external MCP).

## Decisions

Tagged **[RATIFIED]** = user/design decision, locked. **[VERIFY]** = must be proven by the verify
fleet with run output before a builder relies on it (distrust vacuous green).

- **D1 [RATIFIED] — Cloud multi-tenant from day one.** Every workspace connects its own services; credentials + sessions isolated per workspace.
- **D2 [RATIFIED] — Channel-first.** The first shipped direction is Channel connectors; Tool connectors (GitHub/Linear via MCP) follow.
- **D3 [RATIFIED] — Six first-focus channels, grouped by ONBOARDING not code.** Easy trio (Telegram, Slack, Discord — light official adapters, prove the core) → heavy pair (Teams = Azure Bot reg + Bot Framework; WhatsApp = Meta Business + number + app review + 24h session window) → **iMessage = self-hosted operator profile ONLY** (community adapter, Apple has no server API, needs a Mac + Apple ID relay; does NOT fit Cloud multi-tenant).
- **D4 [RATIFIED] — External Node bridge on the Chat SDK, not three protocols in Elixir.** One codebase, swappable adapters, `thread.stream()` piped from Barkpark SSE. The BEAM stays the engine; the bridge is a client of `/v1/chat`.
- **D5 [RATIFIED] — Two execution profiles behind one Connector/Session layer.** Self-hosted/operator = the `claude` CLI subprocess, full host access, `bypassPermissions` OK, gate = your user-id. Cloud tenant = a **sandboxed runner per workspace**, no host access, connector-scoped tools, gate = external user → workspace principal. This **reverses** `bypassPermissions` for Cloud (it survives only self-hosted).
- **D6 [RATIFIED] — Session = memory, keyed by the Claude session UUID (`chat_sessions.id`).** A thread ↔ session map (`thread_id → session_uuid`) is the only per-conversation state the bridge holds. The SAME session is reachable from any channel (cross-surface continuity).
- **D7 [VERIFIED — total leak] — Session ownership migration.** Proven: `chat_sessions` (and `chat_messages`) have ZERO owner/workspace/tenant column on origin/main; every StudioChat read/list/resume/mutate keys purely on the session UUID with no scope filter; the only gate is a flat global-admin route check. Slice A adds `owner_workspace_id` (nullable `binary_id`, no FK, no default — greenfield/additive) + seals the store funnels. See D14–D17.
- **D8 [VERIFIED — ALREADY MERGED] — `/v1/chat` HTTP+SSE transport is on main and live.** Proven: PR #2857 (commit `0b699edf`, 2026-07-13) merged an 8-route ChatController (CRUD + send/interrupt/approval + SSE, 39 tests) to origin/main; `git merge-base --is-ancestor 0b699edf origin/main` → true; guerrilla answers **401 not 404** on `/v1/chat/sessions`. The local primary checkout is a diverged fork ~109 commits behind and never received the merge — that is why pre-survey grep found nothing. Slice B collapses from "land the transport" to "tenant-scope the existing merged one." **All builders branch off `origin/main`, never local HEAD.** See D18.
- **D9 [VERIFIED — premise CORRECTED, deferred to P1] — Per-workspace OAuth install + routing.** Correction: run-secrets is NOT workspace-scoped — it is a flat instance-global `name→value` KV table (`secrets`, PK `:name`), gated by global `:require_admin`, `list/0` returns every secret with no tenant filter. Real per-workspace scoping needs a new `workspace_id` column + scoped-admin gating — build work, not "confirm and ride." Filed as a P1 backlog task, NOT a P0 gate this wave. The `provider_team_id → workspace` map lands with P2/P3 routing.
- **D10 [OPEN FORK — decide via a verify/research slice] — The sandbox runner.** Candidates: **Vercel Sandbox** (Firecracker microVM, GA — native to our stack, preserves the claude-subprocess shape), containers, or an API-based agent (no shell). **Hard bar: first response ≤10s** (Linear AgentSession marks agents unresponsive past 10s) → cold-start is a measured acceptance criterion, not a preference. This is the one decision the design has NOT made; the wave that needs it must resolve it with numbers.
- **D11 [RATIFIED] — Notion is OUT.** Not a messaging surface; if ever wanted, it is a Tool (MCP), never a channel.
- **D12 [RATIFIED] — Streaming cadence starts post-once-per-turn** (rate-limit-safe), live-edit-on-throttle is a later refinement.

## Wave map

- **P0 — Tenant seam + engine seam** (runner-independent, START HERE). D7 migration + D8 land/confirm `/v1/chat`. Proof: a workspace-owned session, create + POST message + SSE reply via curl.
- **P1 — Sandboxed tenant runner.** Resolve D10 with a cold-start benchmark (≤10s), stand up the per-workspace runner (connector-scoped creds, no host access), prove one isolated turn.
- **P2 — Provider-agnostic core.** The Chat SDK bridge: normalized thread→Session map, streaming glue, the connect/OAuth-install abstraction, per-tenant routing. Because all channels land together, this abstraction is DESIGNED now, not discovered later.
- **P3a — Easy trio** (Telegram + Slack + Discord) on the core, multi-tenant. **P3b — Heavy pair** (Teams + WhatsApp; kick off Teams Azure onboarding in parallel from P0). **P3c — iMessage** (self-host profile only). Studio Connectors catalog UI.
- **P4 — Tool direction + polish.** GitHub/Linear via MCP, permission cards, cross-surface continuity, self-hosted operator profile offered alongside.

## Wave 1 = P0 — decisions (D13–D20, ratified at Decide with two verify rounds in hand)

The two verify legs are settled (see D7/D8). Wave 1 ships THREE parallel-file slices. The proof-is-the-product
stays: via curl, create a **workspace-owned** session, POST a message, read the streamed SSE reply — AND a
second tenant provably cannot see or resume it. That cross-tenant LEAK negative test is mandatory (D19).

- **D14 — Migration is additive/greenfield.** `add :owner_workspace_id, :binary_id, null: true` on `chat_sessions` (no FK, no default — mirrors `20260629150300_add_owner_id_to_documents.exs`). Pre-migration NULL rows read admin/`:global`-only; invisible to any workspace-scoped caller.
- **D15 — Scope rule = `scope_to_workspace/3` semantics, NOT `scope_to_owner` and NOT dataset OR-fallback.** A scoped caller filters `where owner_workspace_id == ^ws` (nil caller ws → `where: false`, zero rows, fail-closed; NULL row never matches an equality, so legacy rows stay invisible). Do NOT use `scope_to_owner`'s `OR is_nil(owner_id)` carve-out (that would blanket-expose every legacy row) nor the `dataset_id OR (is_nil … AND dataset==)` legacy string shim (chat_sessions never had a prior tenant identifier). New partial composite index `create index(:chat_sessions, [:owner_workspace_id, :last_active_at], where: "archived_at IS NULL", name: :chat_sessions_workspace_active_last_active_at_index)` to serve the scoped sidebar query.
- **D16 — External principal = `ApiToken`, NOT airdrop `Grant`/`ClaimFlow`.** Proven wrong fit: `ClaimFlow.resolve/2` requires an authenticated, email-matching, `confirmed_at`-set `User` — a Slack/Discord/Telegram user has no Barkpark account. Reuse ONLY airdrop's scope-ladder + live-revalidation PATTERN. For P0 the connector principal is a **workspace-bound `ApiToken` carrying a `chat` permission** (ApiToken already has `workspace_id`, extensible `kind`, nullable `owner_user_id`). NO new `principal_type`, NO `CallerContext`/`Membership`/`Tenancy.Auth` enum edits this wave (that is maximum blast radius on the exact isolation core we are sealing). Per-external-user attribution (`external_identities`) is a later-wave concern, not P0.
- **D17 — Seal at the STORE layer (`studio_chat.ex` funnels), not the route pipeline.** `chat_live.ex` bypasses the controller and calls the store directly, so sealing only the controller leaves the LiveView sidebar open. **Fixed store contract (parallel builders share this verbatim):** the read/list/mutate funnels take a `scope` argument that is either `:global` or a `workspace_id` binary.
  - `:global` → no filter (greppable admin superuser path, mirrors `Scope.scope_to_workspace_global/1`). Behaviour identical to today.
  - a `workspace_id` → `Scope.scope_to_workspace(query, ws, nil)` fail-closed.
  - Funnels that gain the arg: `get_session(id, scope)`, `list_sessions(opts, scope)`, `list_messages(session_id, scope)` (and `/2` limit variant threads it), `delete_session(id, scope)`, `archive_session(id, scope)`, `unarchive_session(id, scope)`, `get_session_with_messages(id, scope)`.
  - `create_session(attrs)` stamps `owner_workspace_id` = (`{:workspace, ws}` → `ws`; `:global` → `nil`).
  - Keep a back-compat default (`scope \\ :global`) so no non-chat caller breaks; every chat call site passes an explicit scope.
- **D18 — Auth model: global-admin stays a superuser fast-path; a scoped connector path is ADDED (not a breaking swap).** A new plug `BarkparkWeb.Plugs.RequireChatAccess` replaces `:require_admin` on the `/v1/chat` pipeline and resolves `conn.assigns.chat_scope`: a token with global `admin` permission → `:global` (unchanged — live admin/bp-chat usage keeps working); a workspace-bound token carrying the `chat` permission → `{:workspace, token.workspace_id}`. The controller threads `conn.assigns.chat_scope` into every store call. `chat_live.ex` keeps its `:admin` `on_mount` gate and passes `:global`. A route-pipeline swap to `:scoped_admin` is NOT viable (the routes carry no `/w/:ws` segment and `require_admin` is flat-global — nothing for a scoped gate to key on).
- **D19 — Cross-tenant negative test (mandatory, hybrid).** (a) Controller: mint a connector token in workspace A, create a session (`owner_workspace_id=A`); a connector token in workspace B gets **404** on GET/index/show/messages/interrupt/approval/events for A's session (join the existing not-found oracle — a wrong-tenant id is indistinguishable from a missing id, NOT a distinct 403), AND a `:global` admin still sees it. Invert the existing `chat_controller_test.exs` "two admins read the SAME session" test (`Auth.create_token/5` already takes an optional `workspace_id`). (b) Store/LiveView: `delete/archive/unarchive` fail-closed against a foreign workspace. The `events` SSE route MUST scope `get_session` BEFORE subscribing to `Recorder.topic(id)` so tenant B cannot join tenant A's live stream by guessing a UUID.
- **D20 — Hold the line on D10.** No runner/sandbox work this wave; that fork needs cold-start numbers in a later wave.

## Wave 1 slice plan (3 slices, all `builder_model: opus` — Fable is out of credits this run)

- **Slice A — `connectors-w1-tenant-seam` (gating).** Migration + `session.ex` field + `studio_chat.ex` store seal (D15/D17) + `chat_live.ex` passes `:global` + store-level & LiveView-level tenant tests (D19b). Files: `api/priv/repo/migrations/…_add_owner_workspace_id_to_chat_sessions.exs`, `api/lib/barkpark/studio_chat/session.ex`, `api/lib/barkpark/studio_chat.ex`, `api/lib/barkpark_web/live/studio/chat_live.ex`, `api/test/barkpark/studio_chat_test.exs`, `api/test/barkpark_web/live/studio/chat_live_test.exs`.
- **Slice B — `connectors-w1-transport-scope` (depends on Slice A's store contract).** New `RequireChatAccess` plug + router pipeline swap + `chat_controller.ex` threads `chat_scope` into the sealed store funnels + `events` scope-before-subscribe + controller cross-tenant negative test (D19a). Files: `api/lib/barkpark_web/plugs/require_chat_access.ex` (new), `api/lib/barkpark_web/router.ex`, `api/lib/barkpark_web/controllers/chat_controller.ex`, `api/test/barkpark_web/controllers/chat_controller_test.exs`. Branch off `origin/main`; build against Slice A's committed store contract (rebase onto A before merge).
- **Slice C — `connectors-w1-teams-longlead` (parallel human gate, disjoint files).** `docs/ops/teams-azure-bot.md` runbook modeled on `docs/ops/github-sync.md`: AAD app + multi-tenant Azure Bot resource + Teams channel + manifest + org-consent steps, the human-gate framing (fakes-first, blocks no code), and the workspace-scoped secrets table (`teams.app_id`, `teams.app_password`, `teams.tenant_id`). Blocks nothing.

P1 backlog (filed, NOT this wave): scope run-secrets per-workspace (D9 correction); resolve D10 sandbox-runner with a ≤10s cold-start benchmark; P2 Chat SDK bridge (thread↔session map) — do NOT start until P0 merges.

Teams Azure Bot registration runs in parallel as Slice C's human gate. Do NOT start P1/runner work until D10 is resolved.

## Builder discipline

- Every builder isolates in a **worktree** (`cp _build/test`, symlink `deps`, `CC=clang`; NEVER symlink `_build`; `MIX_ENV=test mix ecto.migrate` before any harness that seeds a new table). See `[[lockfree-worktree-gate]]`, `[[elixir-build-borrow-broken]]`.
- Every `.ex/.exs/.heex` change **WAITS for the Elixir Test gate** before merge (`[[dont-merge-before-elixir-test]]`).
- **Distrust vacuous green** (`[[distrust-vacuous-green]]`): the tenant-ownership work needs a cross-tenant LEAK negative test, or a pass is meaningless. Sessions/tenancy are high blast radius.
- Wire contract for `/v1/chat` and the thread→session map is FIXED in this charter — parallel builders share one written truth.
- The wave Paper is the live spine: workers report `coverage[]`, stamp evidence as they go.

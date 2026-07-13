<!-- doc-tier: agent | canonical-for: bp-chat-tui-epic-charter | budget: 12000tok -->
# Barkpark Chat TUI — Epic Charter

Epic task: `bp-chat-tui-epic` · Vision paper: `/papers/barkpark-chat-tui` (One Chat, Two Surfaces — ratified) · Founding wave paper: `barkpark-chat-tui-wave-2026-07-12`

## Vision

`bp chat` in any terminal drops you into the SAME conversation you left in Studio: same Postgres-truth sessions list, same transcript rendered block-for-block by pdrender, live streaming reply, Esc interrupts mid-stream — authenticated by the CLI's existing data-plane bearer token. Not a lookalike but a second client of the one engine (StudioChat + ClaudeChat + Recorder), with a golden-transcript parity gate making "identical" a CI fact from day one. Ratified laws bind every wave: **Law 1** — no GUI-only widgets; chat affordances are PortableDoc block types first. **Law 2** — continuity is the test; a mid-session surface switch keeps draft/rail/approvals. Vision waves 1+2 (transport + harness + client MVP) fold into this founding wave; interactive cards (vision wave 3) are backlog, with pending approvals surfaced read-only so Law 2 stays honest.

## Decisions

Ground truth behind each decision lives in the wave paper's verification section (5 verifiers, run-proofs attached).

- **D1 — Transport = SSE + plain HTTP verbs under `/v1/chat`. No Phoenix Channels.** Why: a bare non-LiveView process was PROVEN to drive a session end-to-end (PubSub reads via `Recorder.topic/1`, writes via `Recorder.ensure/1 → Recorder.session_pid/1 → ClaudeChat.{send_message,interrupt,respond_permission,set_permission_mode}`), and the Go side already ships a proven 195-line stdlib SSE client (`internal/apiclient/listen.go`) vs zero websocket/Phoenix-wire prior art.
- **D2 — The transport NEVER calls `adopt_sink`.** Why: Recorder must remain the persisting sink + verbatim PubSub rebroadcaster; all writes are plain GenServer calls to the Session pid with no sink-identity gate (proven, `claude_chat.ex:615-681`). `adopt_sink` is only for single-writer tab takeover.
- **D3 — Auth = data-plane bearer token (`cfg.Token`, set by `bp setup --target connect` / `bp attach`), routes gated `require_token` + `RequireAdmin` (token `admin` permission).** Why: `bp login` sets `cfg.CloudToken` (control plane) which is NEVER sent in data-plane `Authorization` headers — the direction's "bp login token" phrasing was refuted by trace; Studio's cookie-admin and token-admin are different populations, and token-admin is the honest translation of the Studio gate.
- **D4 — The wire contract is fixed in this charter (Wire contract below) so server, apiclient, and TUI slices build in parallel.** Why: three isolated builders need one written source of truth, not negotiation.
- **D5 — No shed-and-close backpressure; resume is by TURN BOUNDARY.** Live deltas are ephemeral (never persisted — proven); persisted message rows carry `seq`. Replay = rows with `seq > Last-Event-ID`, then go live. Why: ListenController's shed-and-close would drop live tokens; there is no token-level replay store.
- **D6 — The events route rides the `AcceptBarkparkVendor` plug.** Why: bare `Accept: text/event-stream` 406s under `:accepts ["json"]` — both negotiation tests proven green today.
- **D7 — Client = native `bp chat` builtin** (`case "chat":` in `internal/cli/cli.go`'s switch, NOT a manifest verb), new `internal/chat/` package on the taskboard chassis (spine.go single-producer discipline, alt-screen, 100ms tick), `completionNouns` gains `"chat"`. Why: full-screen streaming TUIs are the documented builtin carve-out; the completion-nouns drift guard reds otherwise (reproduced live).
- **D8 — Settled assistant messages render via `FromMarkdown.blocks` JSON → `pdrender.Decode` → `RenderDoc` — no projection layer.** Why: the exact block JSON round-trips with ZERO shape mismatch across all 10 block types incl. mermaid + portabledoc fences (proven). Go has NO markdown→blocks converter, so the transport serves per-assistant-message `blocks` (server-side `FromMarkdown.blocks/1`) alongside `source_markdown` on GET session/messages. Streaming = plain-text live tail, re-rendered per tick; the tail SETTLES by refetching the message tail at the turn boundary (`result` frame → one GET, which also picks up AI titles per D15). Full-transcript re-render per 100ms tick is MVP-fine (measured: 0.5ms common / 20ms worst @ 20 rich messages); per-message cache is backlog `ct-bl-render-cache`.
- **D9 — Chat carve-out from live.go's "events never carry truth" doctrine:** chat SSE deltas ARE the live-tail truth (they are never persisted anywhere); settled truth stays Postgres (client re-syncs the message tail at each turn boundary via GET). The carve-out must be stated in `internal/chat`'s package doc.
- **D10 — Figure numbering resets per message** (each reply is its own document). Why: `RenderDoc` re-seeds `figN` per call (proven); per-message reset is the deliberate chat convention, documented in the TUI package doc — not an accident inherited from the default.
- **D11 — Interrupt UX:** Esc flips to "interrupting" immediately (the control ack is semantically EMPTY); the true signal is the terminal `result` frame with `terminal_reason:"aborted_streaming"` → render "Interrupted — session live", never an error. The client owns its OWN 8s wedge timer (the LiveView's is LiveView-local). Esc with no active turn = silent no-op — proven on the real binary: benign ack `{"still_queued":[]}`, no error, no hang.
- **D12 — Steer = honest queue (engine D43, re-proven on v2.1.207):** a mid-turn send is buffered by the CLI, the running turn completes untouched, a fresh `system/init` fires, and the queued frame runs as its own turn. The TUI renders it with a `⧗ queued` badge; never claim live injection.
- **D13 — Golden harness = Mechanism A (3-mirror field/structural projection, sheets/preview pattern), scoped to the ASSISTANT REPLY BODY on day one.** Why: cross-engine byte-diff is impossible by construction; the reply-body round-trip is proven feasible with one markdown fixture. Tool/todo/approval/thinking rows are bespoke HEEx (`chat_tool_renderer.ex`, zero PortableDoc refs) with no pdrender twin — their TUI renderers + parity mechanism are the named backlog slice `ct-bl-toolrow-renderers`, NOT silently covered by the phrase "golden transcript".
- **D14 — Law-2 continuity round-trip set = {draft, rail_snapshot, mode, model_choice, effort_choice, seq-derived cursor, approval cards read-only via message replay}.** `GET /v1/chat/sessions/:id` returns the FULL struct — `list_sessions` omits draft/choices (documented vacuous-green trap). Everything else (bypass arming, expand state, question scratch) is proven throwaway even Studio-to-Studio.
- **D15 — Titles: the MVP client refreshes the session (GET) at each turn boundary to pick up AI titles.** Why: `Titles.kick_title` pid-messages the caller (the LiveView) and the Recorder relays NOTHING title-shaped on its topic (proven by grep + test) — a PubSub subscriber never sees titles. Lifting titles onto the Recorder topic is backlog `ct-bl-recorder-titles`.
- **D16 — Attachments never ride the media plugin** (`GET /media/files/*` is any-token-public — the exact leak the engine's design avoids). Out of MVP; backlog `ct-bl-chat-attachments` with chat-owned auth.
- **D17 — charple theme ships as an independent slice.** Seeds proven through `derive()` today: 160 slots, 0 overrides, 0 AA misses. Light `{bg '250 42% 98%', ink '249 10% 14%', accent '241 57% 45%'}`, dark `{bg '249 10% 14%', ink '249 15% 93%', accent '249 100% 66%'}`, pin `surface.dark '249 12% 6%'`. Charmtone palette is MIT; Crush code is FSL — copy NO code.
- **D18 — Parked for this wave:** `task-ad931ba2e0d0bdf4` (recorder/session core→web decoupling) stays unclaimed; wave builders must NOT absorb it. It is the sole open task touching the engine files.
- **D19 — Builder environment law:** `export CC=clang` first (this host aliases `cc` to a Claude wrapper — the literal one-liner gate FAILS at `go vet` otherwise); never `mix phx.server` (boot-blocker); targeted `CC=clang mix test <file>` only; `listen_controller_test.exs` gets one re-run before trusting a red (1/18 transient flake observed); guerrilla proofs use disposable sessions only (1531 real chat_messages rows live there).
- **D20 — Claude version pin:** pinned 2.1.206 vs installed 2.1.207 (local AND guerrilla). The real-binary suite reds on the pin BY DESIGN. Bump is backlog `ct-bl-claude-pin-bump`; never bypass the pin silently in CI.
- **D21 — Scope is intentionally INSTANCE-GLOBAL ADMIN for the founding wave.** `chat_sessions`/`chat_messages` have no tenant, workspace, project, dataset, or owner column, and existing Studio chat is an instance-operator surface. The flat `/v1/chat` routes therefore require a data-plane bearer token with global `admin` permission; any such admin may list, read, send to, interrupt, and answer approvals for every chat session on the instance. No workspace header/query/path narrows or expands this authority. Tenant/owner isolation requires a separately authorized schema/backfill/scoped-route migration and is out of this wave; never fake tenancy in the controller.
- **D22 — The transport is a strict adapter, never a process-launcher API.** POST session mints the UUID server-side and always derives cwd from `ClaudeChat.cwd/0`. Executable, argv, environment, cwd, session id, resume, minter/token, and bypass arming are never request-controlled. Mode/model/effort values must pass the existing `Session`/`ClaudeChat` allowlists; `bypassPermissions` is not accepted remotely because its Studio ceremony is not representable here. Unknown keys, wrong JSON types, invalid enums, negative/non-integer `since`, and malformed `archived` values return the canonical 400 envelope before any store/runtime call. Message content is the only free-form process input and is byte-bounded; approval accepts only `allow` or `deny` and never caller-supplied `updatedInput` (allow echoes the server-held original ask).
- **D23 — Remote errors are secret-safe by construction.** Ordinary HTTP failures go through `BarkparkWeb.ErrorResponse`. The SSE serializer never exposes `stderr_tail`, raw exceptions, paths, argv, environment, tokens, or internal `inspect` output. Recorder/Studio retain their existing bounded in-process stderr tail, but the HTTP exit frame contains only `status` plus the fixed public `reason` enum `clean | failed_start | crashed | idle_reaped | unknown`; numeric subprocess status is included only when it is an integer. The redaction boundary is the ChatController serializer: DROP the tail — heuristic plaintext scrubbing is not a security claim.
- **D24 — SSE viewers do not own runtimes.** The controller subscribes only to `Recorder.topic/1`; it never calls `adopt_sink` and never closes Recorder/ClaudeChat when the HTTP client disconnects. Chunk error, request-process exit, or normal return terminates the stream. Subscription/helper ownership is wrapped in `try/after`; a helper is linked or monitored, receives `:stop` in `after`, and exits when the request process dies. Subscriber/helper counts return to baseline after disconnect. Normal operation drops no chat frames and emits no ListenController overloaded shed-and-close event. A config-backed per-connection `max_heap_size` defaults to ListenController's 10,000,000-word node-safety cap and may terminate a pathological stalled connection; this emergency process cap is not a replay promise. The client reconnects and refetches settled Postgres truth at the turn boundary; unreplayable live deltas can be lost only on abnormal disconnect.

### Wire contract (v1, fixed for this wave)

All routes admin-token gated: `pipe_through [:api, :require_admin]`; the events route additionally `AcceptBarkparkVendor`. Session ids are the chat session UUIDs (same id is the CLI `--resume` key).

| Route | Body → Response |
|---|---|
| `POST /v1/chat/sessions` | `{mode?, model?, effort?}` → 201 full session JSON; id is server-minted and cwd is always `ClaudeChat.cwd/0` |
| `GET /v1/chat/sessions?archived=` | → `{sessions:[…]}` sidebar shape (`list_sessions/1`) |
| `GET /v1/chat/sessions/:id` | → FULL session (incl. draft, rail_snapshot, mode, model_choice, effort_choice, title, status, token/context metrics) + `messages:[…]` seq-asc; assistant rows carry `blocks` (server-side `FromMarkdown.blocks/1`) alongside `source_markdown` (D8). Optional `?since=<seq>` returns only newer rows (the turn-boundary tail refetch) |
| `PATCH /v1/chat/sessions/:id` | exact allowlisted keys `{draft? \| mode? \| model_choice? \| effort_choice? \| title?}` → 200; strict types/enums, `bypassPermissions` rejected |
| `POST /v1/chat/sessions/:id/messages` | `{content}` → 202 `{accepted:true}` (Recorder.ensure → session_pid → send_message; server does not distinguish queued — the client badges from local turn state per D12) |
| `POST /v1/chat/sessions/:id/interrupt` | → 202 `{request_id}` |
| `POST /v1/chat/sessions/:id/approval` | `{request_id, decision:"allow"|"deny"}` → 204 (`respond_permission`); no caller-supplied input/updatedInput |
| `GET /v1/chat/sessions/:id/events` | SSE stream, see below |

SSE frames:
- Replay phase (on connect, when `Last-Event-ID` present): each persisted row `seq > Last-Event-ID` → `id: <seq>` / `event: message` / `data: <message row JSON>`.
- Live phase: `event: chat` / `data: <raw claude stream-json frame, verbatim>` (no id — deltas are unreplayable by design, D5). `{:claude_chat_permission, ask}` → `event: permission`. `{:claude_chat_exit, status, _internal_tail}` → `event: exit` / `data: {"status":…,"reason":"clean|failed_start|crashed|idle_reaped|unknown"}`; the internal tail is NEVER serialized (D23).
- `: keepalive` comment every 30s. Never shed-and-close (D5). No per-event DB redaction (admin-only route).

### Security, validation, and transport verification obligations

Bounds are part of the wire contract, not implementation trivia: title and request_id are at most 256 UTF-8 bytes; message content and draft are at most 64 KiB each; since is an integer in 0..9,223,372,036,854,775,807. The endpoint-wide 100 MB parser ceiling is NOT the chat limit. Over-limit values fail with the canonical 400 envelope before any store/runtime call.

A. **Eight-route auth matrix:** every route returns 401 for a missing/invalid bearer and 403 for a valid non-admin bearer (16 route assertions), with canonical request-id-bearing envelopes; auth runs before UUID/store/runtime work.
B. **Global-scope ratification:** two distinct valid global-admin tokens can list/read/control the same session. Workspace/project/dataset query parameters or headers neither narrow nor escalate access; there are no scoped chat routes.
C. **UUID/not-found oracle safety:** for an authenticated admin, malformed UUID and well-formed absent UUID return shape-equivalent canonical 404 envelopes. Unauthenticated/non-admin requests remain 401/403 for both existing and absent ids.
D. **Strict params:** table-driven rejection covers unknown keys, non-map bodies, wrong types, invalid mode/model/effort/decision, bypassPermissions, negative/non-integer since, malformed archived, and oversized title/request_id/content/draft; each rejection proves zero Recorder/ClaudeChat calls.
E. **No launcher escalation:** command, executable, args, env, cwd, session_id, resume, minter, token, updatedInput, or bypass_armed in a body returns 400. A valid create persists ClaudeChat.cwd/0 and proves spawned command/env remain configuration-derived.
F. **Exit secrecy:** inject a tail containing a bearer token, filesystem path, and arbitrary plaintext secret; none appears in SSE bytes, whose exit frame is exactly the fixed status/reason schema. Controller failures use ErrorResponse with no inspect output.
G. **SSE ownership/cleanup:** normal disconnect, chunk error, request-process death, and helper crash all terminate helper/subscription state and return counts to baseline while Recorder/ClaudeChat remain alive; no adopt_sink/close call; keepalive remains green.
H. **Availability/no-shed:** ChatController has no overloaded event or threshold drop/close path; the configured max_heap_size emergency cap is installed, and abnormal-disconnect live-delta loss plus settled-refetch recovery is documented.
I. **Preserve the founding contract:** replay seq > Last-Event-ID, live verbatim chat frames, permission, public exit, keepalive, exactly eight routes, AcceptBarkparkVendor, zero transport adopt_sink calls, focused controller tests, and the seven-file chat baseline all remain green.

Client key vocabulary (MVP): Enter = send · Esc = interrupt · Ctrl+C = quit · launch view = sessions picker (list/resume/new) · scroll follows taskboard windowing (follow-mode while streaming, freeze on manual scroll).

## Roadmap

### Wave 1 — founding wave (2026-07-12): transport + harness + working MVP
Integration order; slices 1–5 build in parallel (disjoint files), slice 6 runs after merges.

1. `ct-w1-transport` (large, fable) — `/v1/chat` controller: session CRUD + send/interrupt/approval + SSE events per the wire contract. Files: `api/lib/barkpark_web/controllers/chat_controller.ex` (new), `api/lib/barkpark_web/router.ex`, `api/test/barkpark_web/controllers/chat_controller_test.exs` (new, seam-style per ListenController convention).
2. `ct-w1-golden-harness` (medium, opus) — Mechanism A reply-body parity harness: generator mix task → one fixture mirrored to `api/test/support/fixtures/` + `internal/pdrender/testdata/`, freshness-lock ExUnit test, Go projection test. Merges before or with the client, never after.
3. `ct-w1-apiclient` (medium, opus) — Go `internal/apiclient` chat methods (CreateChatSession/ListChatSessions/GetChatSession/SendChatMessage/InterruptChat/ChatEvents SSE) against the charter wire contract, httptest-proven.
4. `ct-w1-tui-client` (large, fable) — `internal/chat/` package + `bp chat` builtin wiring: sessions picker, transcript via pdrender, streaming tail, Esc interrupt w/ 8s wedge timer, queued badge, draft round-trip, read-only approval cards.
5. `ct-w1-charple` (small, opus) — `design/themes/charple.json` + `node design/emit.mjs --write` + goldens `-update` + ratchet entry.
6. `ct-w1-live-smoke` (small, fable) — end-to-end proof on guerrilla with a DISPOSABLE session: `bp chat` list/create/resume/send/stream/interrupt, evidence stamped on the task. Runs after 1+3+4 merge and auto-deploy.

### Wave 2+ — filed backlog (children of `bp-chat-tui-epic`)
- `ct-bl-cards-interactive` — approval/question/plan cards answerable from the TUI (vision wave 3; PortableDoc block types first per Law 1).
- `ct-bl-toolrow-renderers` — TUI shape-dispatch renderers for tool/todo/approval/thinking rows + their own parity mechanism (D13 scope boundary).
- `ct-bl-render-cache` — per-message rendered-lines cache for long rich transcripts (measured need at ~100 rich messages).
- `ct-bl-recorder-titles` — lift AI-title delivery onto the Recorder topic so all surfaces see titles push, not poll (D15).
- `ct-bl-manifest-commands` — `chat.*` commands in the capabilities manifest for SDK/MCP discoverability.
- `ct-bl-claude-pin-bump` — bump `scripts/claude-pinned-version.txt` 2.1.206→2.1.207 + green the opt-in real-binary suite (D20).
- `ct-bl-chat-attachments` — attachments over the chat transport with chat-owned auth (D16).
- `ct-bl-queue-fixtures` — NDJSON fixtures for `still_queued:[]` no-turn interrupt + mid-turn queue races (recorded raw captures exist in the wave paper) wired into the harness.

## Wave log

### Wave 2026-07-13 — founding wave (transport + harness + working MVP)

**Landed (5 green slices, all gates re-run green on review; grade A−).**

- `ct-w1-transport` — `/v1/chat` controller: 8 admin-gated routes, strict Recorder/ClaudeChat adapter (no adopt_sink, no launcher controls, no shed-and-close), SSE replay→live, public `{status,reason}` exit (D23). Gate green: chat_controller 39/39 + 7-file baseline 521/521. Branch `loop-epic/v1-chat-transport-session-crud-send-inte-0`. No review fixes.
- `ct-w1-golden-harness` — Mechanism-A reply-body parity: pure generator + two byte-identical mirrors + ExUnit freshness lock + Go projection test. 10 ExUnit + 3 Go subtests green; regen zero-drift verified. Branch `loop-epic/golden-transcript-parity-harness-mechani-1`. No review fixes.
- `ct-w1-apiclient` — Go `apiclient` chat bindings (8 methods + SSE), 17 httptest cases, cwd/launcher exclusion + public-exit asserted. Branch `loop-epic/go-apiclient-chat-bindings-crud-send-int-2`. No review fixes.
- `ct-w1-tui-client` — `bp chat` native builtin: picker, pdrender transcript, streaming tail, Esc-interrupt wedge, queued badge, draft round-trip, read-only cards. 27 tests + docs gates green. **Review fix:** exit reducer decoded a `stderr_tail` field the transport never emits (contradicts D23) and dropped the public `reason` enum (null-status crash misreported as "status 0"); corrected to `{status,reason}` + pinned the previously-untested exit path. Final branch `loop-epic/bp-chat-mvp-native-tui-client-sessions-p-3-r`.
- `ct-w1-charple` — charmtone-seeded 4th theme through `derive()`, emitted to all 16 surfaces, ratchet `charple:2` (surface.dark + an AA fg-dim pin, both reasoned). `check.mjs` PASS (216 AA checks), `emit --write` zero drift. Branch `loop-epic/charple-theme-charmtone-seeded-fourth-th-4`. No review fixes.

**Stalled.** `ct-w1-live-smoke` — blocked exactly as its gate anticipates: guerrilla returns 404 pre-merge (no `/v1/chat` deployed). Honestly left in_progress, 0/5, all misses stamped. Runs after transport+apiclient+tui-client merge and auto-deploy.

**Ledger audit.** Two premature "PR merged" stamps reset by the reviewer (golden-harness crit 5, tui-client crit 8 — merge-gated, LEAD owns); tui-client crit 0 (native-builtin dispatch, genuinely proven) flipped to met. All slices left in_progress — the LEAD closes merge-gated criteria on merge.

**Discovered / filed.** `ct-bl-tui-apiclient-dedup` — the TUI ships its own `httpTransport`+`readSSE`+wire-types instead of consuming the apiclient bindings; the tree now carries two Go SSE parsers. Not blocking (the `Transport` interface makes the swap clean); filed as backlog.

**Next wave takes:** the live smoke (once slices merge + deploy), then `ct-bl-tui-apiclient-dedup` (collapse to one SSE parser) and `ct-bl-cards-interactive`/`ct-bl-toolrow-renderers` toward full Studio parity.

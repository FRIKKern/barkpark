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
- **D4 — The wire contract is fixed in this charter (§Wire contract below) so server, apiclient, and TUI slices build in parallel.** Why: three isolated builders need one written source of truth, not negotiation.
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

### Wire contract (v1, fixed for this wave)

All routes admin-token gated: `pipe_through [:api, :require_token, :require_admin]`; the events route additionally `AcceptBarkparkVendor`. Session ids are the chat session UUIDs (same id is the CLI `--resume` key).

| Route | Body → Response |
|---|---|
| `POST /v1/chat/sessions` | `{cwd?, mode?, model?}` → 201 full session JSON |
| `GET /v1/chat/sessions?archived=` | → `{sessions:[…]}` sidebar shape (`list_sessions/1`) |
| `GET /v1/chat/sessions/:id` | → FULL session (incl. draft, rail_snapshot, mode, model_choice, effort_choice, title, status, token/context metrics) + `messages:[…]` seq-asc; assistant rows carry `blocks` (server-side `FromMarkdown.blocks/1`) alongside `source_markdown` (D8). Optional `?since=<seq>` returns only newer rows (the turn-boundary tail refetch) |
| `PATCH /v1/chat/sessions/:id` | `{draft? \| mode? \| model_choice? \| effort_choice? \| title?}` → 200 |
| `POST /v1/chat/sessions/:id/messages` | `{content}` → 202 `{accepted:true}` (Recorder.ensure → session_pid → send_message; server does not distinguish queued — the client badges from local turn state per D12) |
| `POST /v1/chat/sessions/:id/interrupt` | → 202 `{request_id}` |
| `POST /v1/chat/sessions/:id/approval` | `{request_id, decision}` → 204 (`respond_permission`) |
| `GET /v1/chat/sessions/:id/events` | SSE stream, see below |

SSE frames:
- Replay phase (on connect, when `Last-Event-ID` present): each persisted row `seq > Last-Event-ID` → `id: <seq>` / `event: message` / `data: <message row JSON>`.
- Live phase: `event: chat` / `data: <raw claude stream-json frame, verbatim>` (no id — deltas are unreplayable by design, D5). `{:claude_chat_permission, ask}` → `event: permission`. `{:claude_chat_exit, status, tail}` → `event: exit` / `data: {"status":…,"stderr_tail":…}`.
- `: keepalive` comment every 30s. Never shed-and-close (D5). No per-event DB redaction (admin-only route).

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

(empty — Review appends per wave)

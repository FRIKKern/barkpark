# Studio Claude Chat — Excellence Epic (sessions, resume, T3 parity)

## Vision

The Studio chat tab (`/studio/chat`) grows from a single ephemeral subprocess into a
**session-native agent workspace**: every conversation is remembered, listable, and
resumable; the product patterns that make t3code feel great (session sidebar, titles,
stop/interrupt, queued messages, cost visibility, crash recovery) exist here — but
rendered the Barkpark way (PortableDoc blocks, LiveView, admin-gated trust model).
Iterate in epic-cycle waves until the quality is undeniable.

USER WISH (verbatim): "We need to do vast improvements - being able to remember
sessions and return to them - we want to learn from all the most important patterns
of T3 - and run a epic cycle loop figuring out the most essential and enhancing
parts - then implementing it - over and over until we are at an incredible high
quality."

## Ground truth (verified against the local `claude` binary 2026-07-09)

- `--session-id <uuid>` — pin the session id at spawn time. We generate the UUID,
  so persistence needs NO wire-protocol parsing: the id is known before the first byte.
- `-r, --resume <session_id>` — resume a conversation by id; history is rehydrated
  by the CLI from its own transcript store. **PROVEN empirically 2026-07-09**:
  `--print --session-id <minted-uuid>` turn 1 ("remember PINECONE-42") →
  `--print --resume <uuid>` turn 2 recalled the codeword; both turns echoed the
  pinned session_id in their result JSON.
- `--fork-session` — resume into a NEW session id (branching).
- `-c, --continue` — most recent conversation in cwd.
- Transcripts live in `~/.claude/projects/<munged-cwd>/<session-id>.jsonl`, written
  by the CLI itself — the CLI is the transcript store; we persist metadata + our
  rendered view, not raw history.
- Current architecture (shipped w1–w2c, PRs #1612 #1628 #1646 #1656 #1658):
  `BarkparkWeb.Studio.ClaudeChat` (Port GenServer, stream-json wire protocol,
  control-protocol permission bridge) + `ChatLive` (progressive PortableDoc
  streaming, per-kind skeletons, approval cards, mode switch). One subprocess per
  LiveView mount; everything dies with the tab. That is the gap this epic closes.

### Wave-1 wire verification (2026-07-09, real binary v2.1.205, harnesses wire_a–d.py in session scratchpad)

- **Long-lived process CONFIRMED**: one `--print` stream-json process accepts a 2nd
  user frame after the 1st `result` — no respawn, model memory kept in-process.
  `system/init` fires **once per TURN** (not per process), each echoing session_id;
  the existing init idempotency (chat_live.ex) handles this.
- **`--session-id` + `--resume` in stream-json mode CONFIRMED**: minted-uuid turn 1,
  separate `--resume <uuid>` process recalled the codeword; resume does NOT mint a
  new id.
- **Interrupt on the raw wire CONFIRMED** (not SDK-only): stdin
  `{"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}` →
  `control_response subtype:success (still_queued:[])` → partial assistant frame →
  terminal `result` with `subtype:"error_during_execution"`, `is_error:true`,
  `terminal_reason:"aborted_streaming"` — **and the session survives** (next user
  frame runs normally). GOTCHA: subtype alone is indistinguishable from a real
  error; discriminate via `terminal_reason == "aborted_streaming"` and/or tracking
  that WE sent the interrupt.
- **`set_permission_mode` CONFIRMED, key is `mode`**:
  `{"subtype":"set_permission_mode","mode":"acceptEdits"}` → response echoes
  `{"mode":"acceptEdits"}`. The alt key `permission_mode` returns success with an
  EMPTY response — a silent no-op (vacuous-green trap: always assert the echoed
  `response.mode`). `set_model` also returns success (verify the next result's
  modelUsage key actually changed before trusting it). `initialize` returns the
  slash-command/capability list.
- **Result frame fields** (for session metadata): `session_id`, `subtype`,
  `is_error`, `duration_ms`, `num_turns`, `result`, `stop_reason`, `total_cost_usd`,
  `usage{input_tokens,output_tokens,cache_*}`,
  `modelUsage{<model>:{…,contextWindow,maxOutputTokens,costUSD}}`,
  `permission_denials[]`, `terminal_reason`, per-turn `uuid`. Mid-turn system
  subtypes to tolerate/ignore: `hook_started`, `hook_response`, `status`,
  `thinking_tokens`; top-level `rate_limit_event`.

## Decisions

- **D1 — CLI is the history store; Barkpark is the session index.** We do not
  duplicate transcripts. A `chat_session` record (Barkpark doc or lightweight
  store) holds: session uuid, title, cwd, mode, model, created/last-active,
  usage totals, status. Reopening = `--resume <uuid>` + replaying our persisted
  rendered messages (or re-rendering from the result of resume).
- **D2 — Pin session ids at spawn** via `--session-id` (we mint the UUID). Never
  scrape ids from init events.
- **D3 — T3 parity by evidence, not vibes.** Each wave's slices cite the t3code
  pattern they port (miner report below) and adapt it to LiveView + PortableDoc.
- **D4 — Trust model unchanged**: admin-gated live_session, public_demo hard-off,
  binary-absent hides the tab. Session index respects the same gate.
- **D5 — Epic-cycle loop drives the work**: Fable strategize/decide/review, Opus
  explore/build, bp tasks as the spine, waves repeat until the lead (me) + user
  judge the bar met.
- **D6 — Store = dedicated Ecto table pair, NOT a doc type. FINAL.**
  `chat_sessions` + `chat_messages` in `api/priv/repo/migrations/` (pulse_events /
  mutation_events prior art). The doc route is disqualified by evidence, not taste:
  schema `visibility:"private"` on the query API gates on `authed?` = *any*
  api_token (query_controller.ex:375) — a read-only worker token could read admin
  chat transcripts (cwd, tool inputs, host paths). Revisions reads are any-member
  (router.ex:1598-1607) and SSE listen has no schema-private gate
  (listen_controller.ex:89,199-205). Only search is sealed. An Ecto table with **no
  HTTP route ever** — LiveView reads Repo directly (org_admin_live prior art) — is
  admin-gated by construction. Forfeiting bp-CLI/revisions access to transcripts is
  a D4 *benefit*, not a cost. Never add an HTTP route or export path over these
  tables.
- **D7 — Persist source markdown per message, render on read.** Each message row:
  `role`, `source_markdown`, `metadata` (jsonb: tool inputs, usage, result-frame
  fields), `seq`. Re-render through FromMarkdown/Render on load so the improving
  render engine wins; never store HTML. Persist on message COMPLETION, never per
  delta. D1 absolute: never read `~/.claude/projects/*.jsonl`.
- **D8 — Resume mechanics.** The minted UUID is the `chat_sessions` PK *and* the
  `--session-id`/`--resume` key (one identity, no cursor column). Session row is
  created on FIRST user send, never on mount (no empty rows). Reopen = replay our
  messages instantly (no spawn, status resumable) + lazy `--resume <uuid>` spawn on
  the next send. Never eager respawn; never scrape ids off hook_* frames.
- **D9 — The args seam (vacuous-green law).** All flag assembly lives in a public
  pure `ClaudeChat.build_args(mode, session_opts)`; `command/2` threads
  session_opts start_session → Session.start → init. The `:command` test override
  bypasses default_args verbatim (claude_chat.ex:73-78) — flag assertions through
  it are vacuous. Rules: (i) unit-test build_args directly (fresh ⇒
  `--session-id <uuid>`; resume ⇒ `--resume <uuid>` and NOT `--session-id`);
  (ii) prove end-to-end with a `:binary` argv-echo fake (keeps default_args, unlike
  `:command`); (iii) `:command` fakes are ONLY for Port-plumbing behavior tests.
- **D10 — Interrupt = control frame, first-class outcome.** `ClaudeChat.interrupt/1`
  writes the interrupt control_request on stdin (proven on the raw wire — no
  port-close primary fallback needed; keep a timeout-close guard if no ack).
  Stop replaces Send while a turn runs (t3 item 10: NO send queue). The interrupt
  result is `subtype:"error_during_execution"` — classify as "interrupted" (never
  "error") via tracked `interrupt_requested` + `terminal_reason=="aborted_streaming"`.
  Session survives; composer stays live.
- **D11 — Crash recovery.** Port exit ⇒ fail the running turn honestly, force-cancel
  ALL pending approval cards to `approval_status: :canceled` rendering "✗ canceled"
  (today they hang: chat_live.ex:202-210 never touches them and resolve_permission
  silently no-ops post-exit), mark the session record `exited`, status `:offline`.
  Next send transparently lazy-resumes. Nothing hangs; nothing lies.
- **D12 — Mode/model mid-session via control frames; the respawn path dies.**
  `set_permission_mode` frame with key `mode` (NEVER `permission_mode` — silent
  no-op) replaces the context-destroying restart (chat_live.ex:87-104). Tests must
  assert the echoed `response.mode`, not just subtype:success. The old
  "switching mode restarts the session" test gets rewritten to the new contract.
- **D13 — AI title: layered, fire-and-forget, clobber-guarded.** Strategy order:
  (B) direct Anthropic Messages API in judge.ex style (haiku, json_schema
  `{title}`, ~$0.0002, <1s) when `ANTHROPIC_API_KEY` is configured → (A) one-shot
  `claude -p --model haiku --no-session-persistence --strict-mcp-config` with a
  replaced system prompt (~$0.01-0.03, 4-9s, OAuth, key-less) → (fallback) derived
  title from the first user message truncated to 50 chars. Supervised via
  `Task.Supervisor.start_child(Barkpark.TaskSupervisor, …)` with explicit timeout
  kill for the CLI path; result messages back to the LV. Clobber guard:
  `title_source` column — AI write only lands while `title_source == "default"`;
  a human rename is never overwritten. Strip ```json fences before decode; any
  failure/empty/timeout keeps the default title.
- **D14 — Routing + sidebar chrome.** `live("/chat/:session_id", ChatLive)` joins
  the SAME `:admin_studio` live_session (router.ex ~618) so `push_patch` switches
  sessions with no remount; `handle_params/3` becomes the single source of truth
  and mount stops eagerly spawning (chat_live.ex:54 inverted: mount = chrome +
  session list only). Sidebar pills reuse `.badge` + NEW tokenized lifecycle
  variants (the `.bp-pill` classes referenced by external_sync_pill.ex are NOT
  defined in any CSS — do not trust them); relative time = copy/extract
  board_live.ex:3156-3168 `age_label`; all chrome consumes emitted tokens and
  `scripts/studio-literal-check.sh` must pass. Prefix tab-highlight
  (nav.ex:478 starts_with?) keeps the chat tab active on deep links for free.

### Wave-2 decisions (2026-07-09, decided from explorer evidence)

- **D15 — Archive is a shelf axis, NOT a status.** New nullable
  `archived_at :utc_datetime_usec` column on `chat_sessions` (+ partial index
  `ON (last_active_at) WHERE archived_at IS NULL`). NEVER fold "archived" into
  `status` — `@statuses ~w(active working exited)` is a *liveness* axis validated
  in two sites (session.ex:23/71, studio_chat.ex:225) and `update_status`/
  `mark_exited` would clobber an archive-as-status on the next turn. `list_sessions`
  filters `is_nil(archived_at)` and gains a **cap of 50** (recency-desc means a
  live session always sorts to the top — no working-session exemption needed;
  `list_sessions(archived: true)` lists the shelf). Delete = `Repo.delete(session)`
  — the message FK is already `on_delete: :delete_all` (migration line 63), no
  manual cleanup. Deleting/archiving the session ON SCREEN must
  `push_patch(to: "/studio/chat")` (handle_params only auto-resets on navigation,
  not on handle_event — chat_live.ex:80-106).
- **D16 — Rename prior art is the SHEET TAB, not board_live.** Clone the
  begin/commit/cancel triad from sheet_grid.ex:1159-1172 + 3005-3035
  (`renaming_session` assign, dblclick/F2 to start, form phx-submit to commit,
  Escape cancels) and the row kebab menu from the sheet context menu
  (sheet_grid.ex:2988-2997, `role="menu"`/`role="menuitem"` buttons). ONE
  divergence: blur COMMITS (resource-list semantics), unlike the sheet's
  cancel-on-blur. Store side is done — `StudioChat.rename/2` pins
  `title_source:"human"`.
- **D17 — control_response gets a typed dispatch; the catch-all stops eating it.**
  Today the interrupt ACK and the set_permission_mode echo both fall through
  Session's generic dispatch (claude_chat.ex:479) into ChatLive's catch-all
  (chat_live.ex:320) and are DROPPED. Fix at the Session: track minted
  `request_id → kind` (`:interrupt | :set_mode | :set_model`) and dispatch
  `{:claude_chat_control, kind, response_map}` to the sink. ChatLive: on
  `{:claude_chat_control, :set_mode, resp}` assert the echoed `resp["mode"]` —
  on mismatch/absence revert the optimistic assign + honest system line (D12
  vacuous-green: never trust subtype:success). Mode PERSISTENCE: new
  `StudioChat.set_mode/2` (mirror of update_status/2, validate_inclusion on
  modes), called in BOTH set-mode branches (live AND no-live-session) whenever
  `store_session_id` is set — reopen must show the mode you switched to, and the
  next lazy spawn's build_args must carry it. `set_model` gets NO persistence
  this wave (no UI exists; model is already persisted off the result frame —
  symmetry here would be speculative surface).
- **D18 — :interrupting gets a timeout guard; teardown is extracted + idempotent.**
  `stop_turn` schedules `Process.send_after(self(), {:interrupt_timeout, sid},
  @interrupt_timeout_ms)` (8_000, config-overridable for tests). On fire, if
  `status == :interrupting` still: `ClaudeChat.close(session)` + full teardown.
  A `result` arriving first makes the timer a no-op (guard on status; no cancel
  needed). CRITICAL correction to the direction: `:close` does NOT emit
  `{:claude_chat_exit}` (that fires only on real port exit_status,
  claude_chat.ex:415-416) — so the inline crash-recovery at chat_live.ex:328-346
  (cancel pending approvals, mark_session_exited, honest system message,
  status :offline) must be EXTRACTED into one shared idempotent private fn
  called by the exit handler, the interrupt-timeout handler, and the
  (currently thin) DOWN handler. Idempotence guard: already `:offline` ⇒ no-op
  (the close-then-DOWN sequence double-fires otherwise).
- **D19 — Headroom ring: per-turn snapshot columns, window captured from the
  frame, geometry-first SVG, header placement.** The denormalized session totals
  are `inc:`-summed across turns and CANNOT drive the ring. Migration adds
  `last_context_tokens :integer` + `context_window :integer` (nullable) to
  `chat_sessions`; `record_result`/`record_result_metrics` additionally SET
  (not inc) `last_context_tokens = input + cache_read + cache_creation + output`
  of the most-recent result frame and `context_window =
  modelUsage.<model>.contextWindow` captured from the frame — NEVER a hardcoded
  model→window map (goes stale silently). Render: from-scratch inline-SVG circle
  (stroke-dasharray arc — the arc length IS context_used/window; there is NO
  ring prior art in Studio) in the chat HEADER next to the mode select (NOT the
  sidebar — the sidebar belongs to the lifecycle slice), plus session
  `total_cost_usd` as text. Color = token ramp: `--ok` <70%, `--warn` 70–90%,
  `--danger` ≥90%, track `--primary-soft`; all `var(--…)`, studio-literal-check
  must pass. HONEST unknown state: nil `context_window` (pre-migration session,
  no result yet) renders a hollow ring + "—", never a fake full/empty arc.
- **D20 — Single-writer via Registry takeover; next_seq retries; E2E proof rides
  along.** Two tabs on one session today spawn two `claude --resume` OS
  processes (the real harm: concurrent writers on the CLI's own transcript) and
  race next_seq (loser's message SILENTLY dropped — callers discard
  `{:error, _}`). Fix: (a) `Barkpark.StudioChat.SessionRegistry`
  (`Registry, keys: :unique`, added to the application supervision tree);
  `Session.start` gains `name: {:via, Registry, {SessionRegistry, uuid}}`; on
  `{:error, {:already_started, pid}}` ChatLive TAKES OVER via a new
  `ClaudeChat.adopt_sink(pid, self())` (Session demonitors old sink, monitors
  new, sends `{:claude_chat_detached}` to the old sink; old tab shows an honest
  "opened in another tab" banner, composer disabled, sending again takes back).
  Session lifetime stays owner-tab-bound (dies on current sink DOWN; other tab
  lazy-resumes on next send) — NO DynamicSupervisor this wave. (b)
  `append_message` retries on the mapped `chat_messages_session_id_seq_index`
  constraint error (re-read max, re-insert, ≤3 attempts); persist callers stop
  discarding `{:error, _}` (log + honest system line). (c) The real-binary E2E
  resume proof is an ACCEPTANCE CRITERION of this slice, not a slice:
  `@moduletag :real_binary` ExUnit test through OUR seam (`:binary` override
  with env-resolved absolute path — `claude` is NOT on PATH on this host;
  the `:command` override bypasses build_args and proves nothing), two turns —
  codeword stamped, close, `--resume`, `recall =~ codeword` (substring, model
  may wrap it) — 60_000ms assert_receive timeouts, excluded by default in
  test_helper.exs (one-line append; @moduletag not @tag, see
  phase8_e2e_test.exs:20), opt-in via `scripts/claude-chat-e2e.sh` (idp-interop
  pattern: resolve CLAUDE_BIN or refuse; ~$0.43 + ~40s per run, never in the
  default lane or CI).
- **D21 — Approvals persist end-to-end; the pending pill is downstream of that.**
  approval_status is persisted NOWHERE today (roles :approval/:system never hit
  the store; a pending-at-exit approval simply VANISHES on reopen). Slice:
  (1) persist on ask — `append_message` role `"approval"`, metadata
  `{request_id, tool_name, input, approval_status: "pending"}`; (2) new
  `StudioChat.update_approval_status/3` updates that row's metadata on resolve
  (allowed/denied) and on crash-cancel (all pending → "canceled"); (3)
  `replay_role/1` learns `"approval"` and replay reconstructs
  `approval_status` + `tool_name` for the terminal-state card; a row still
  "pending" at reopen RENDERS as canceled AND the flip is persisted during
  replay (the store never lies twice). (4) Sidebar pill: denormalized
  `pending_approvals :integer default 0` on chat_sessions (inc on ask, dec on
  resolve, zero on cancel-all); `session_pill/1` precedence
  PendingApproval (`--warn`) > Working > Exited > Idle.

### Wave-1 shared interfaces (parallel builders converge on these names)

- `Barkpark.StudioChat` context (`api/lib/barkpark/studio_chat.ex`):
  `create_session/1`, `get_session/1`, `list_sessions/0` (recency desc, sidebar
  fields only), `append_message/2` (also bumps `message_count`, `summary`,
  `last_active_at`), `update_status/2`, `mark_exited/1`, `rename/2` (sets
  `title_source: "human"`), `maybe_set_ai_title/2` (no-op unless
  `title_source == "default"`), `record_result_metrics/2`.
- Schemas: `Barkpark.StudioChat.Session` (PK `:id` Ecto.UUID, autogenerate:false —
  the minted claude session id; `title`, `title_source` default "default", `cwd`,
  `mode`, `model`, `status` in active|working|exited, `last_active_at`, `summary`,
  `message_count`, `input_tokens`, `output_tokens`, `total_cost_usd`) and
  `Barkpark.StudioChat.Message` (`session_id` FK delete_all, `seq`, `role`,
  `source_markdown`, `metadata` map). Index `[:session_id, :seq]` unique;
  sessions `[:status, :last_active_at]`.
- `ClaudeChat`: `build_args(mode, session_opts)` pure/public;
  `start_session(opts)` accepts `session_id:` + `resume:` (boolean);
  `interrupt/1`, `set_permission_mode/2`, `set_model/2` casts writing
  control_request frames (minted request_id).
- `ChatLive` assigns: `:store_session_id` (minted uuid | nil),
  `:interrupt_requested` (boolean). Approval terminal states:
  `:allowed | :denied | :canceled` ("✗ canceled").

## T3 pattern inventory

Full source-verified inventory: `.claude/workflows/bp-studio-chat-t3-patterns.md`
(read it before deciding or building — it carries exact mechanics + portability
notes). The ranked build order: (1) resume via minted `--session-id` + persisted
cursor + own-store display history, (2) long-lived streaming session with stdin
user frames + steer + control-channel setModel/setPermissionMode/interrupt,
(3) stop/interrupt as first-class turn outcome, (4) crash recovery = fail turn +
cancel approvals + LAZY resume (never eager respawn), (5) AI title on first turn
(clobber-guarded), (6) git hidden-ref checkpoints + memory rewind, (7) usage/
context-headroom ring off the result frame, (8) mid-session model/mode,
(9) sidebar recency + status pills, (10) optimistic echo + restore-on-failure
(no send queue — steer instead), (11) images as base64 stream-json blocks.

Key reframe to respect in every decision: **the CLI is the resumable memory
backend; Barkpark's own store is the display history.** Never read
`~/.claude/projects/*.jsonl` for display.

## Roadmap (initial cut — the Decide phase refines each wave)

1. **Session persistence + resume** — session index store, `--session-id` pinning,
   session list UI (sidebar or picker), reopen = resume. THE core wish. ← WAVE 1
2. **Stop/interrupt + lifecycle honesty** — cancel a running turn, offline/crash
   recovery, reconnect semantics. ← WAVE 1
3. **Titles + metadata** — auto-generated session titles, last-message preview,
   relative timestamps, usage/cost per session. ← titles + sidebar metadata in
   WAVE 1; headroom ring / cost surfacing deferred.
4. **Queued messages / composer UX** — type while the agent works, queue sends.
   (t3 verdict: NO queue — Stop gates the composer; optimistic echo later.)
5. **Polish to the bar** — empty states, error states, keyboard, density,
   evergreen aesthetic parity with the rest of Studio.

## Wave 1 plan (decided 2026-07-09) — "from a moment to a place"

Five slices, integration order S1 → S2 → S3 → S4 → S5. S1/S2 are independent and
parallel; S3 requires S1+S2 merged (build against the shared interfaces above);
S4 requires S2 (+ S1 for mark_exited, nil-safe); S5 requires S1 (+ one-line
chat_live hook). File ownership is partitioned to minimize overlap — S3 owns
mount/handle_params/sidebar/persistence regions of chat_live.ex, S4 owns
composer/result-classification/exit-handler regions, S5 adds one handle_info.

| # | Slice (bp task) | Owns |
|---|---|---|
| S1 | `scc-w1-store` | migration + `Barkpark.StudioChat` context + schemas + tests |
| S2 | `scc-w1-wire-seam` | claude_chat.ex: build_args seam, --session-id/--resume threading, interrupt/set_permission_mode/set_model casts + tests |
| S3 | `scc-w1-sessions-ui` | router `/chat/:session_id`, ChatLive handle_params refactor, session sidebar, persist-on-completion, replay + lazy resume |
| S4 | `scc-w1-honest-turns` | Stop/interrupt UX, interrupted state, crash recovery (force-cancel approvals → "✗ canceled", mark exited), mode switch via control frame |
| S5 | `scc-w1-ai-title` | `Barkpark.StudioChat.Titles`: layered B→A→derived, fire-and-forget, clobber-guarded |

Quality bar (Kinsta/Vercel): the sidebar is the product, not a debug list —
priority pills (PendingApproval > Working > Completed), relative timestamps,
denormalized summaries (instant render), empty state that teaches. Test law:
distrust-vacuous-green — see D9; LiveViewTest render_submit bypasses disabled
attrs, so assert attributes, not just outcomes.

## Wave 2 plan (decided 2026-07-09) — "trustworthy and managed"

Wave 1 made sessions a place; wave 2 makes that place trustworthy: a managed
resource list (rename/archive/delete, bounded), a UI that never lies under
adversity (wedged interrupt, stale mode, vanished approvals), visible session
economics (headroom ring), and single-writer discipline for the same session
in two tabs. Four of five slices FINISH wave-1 promises; only the ring is new
surface.

| # | Slice (bp task) | Owns | Migration |
|---|---|---|---|
| S1 | `scc-w2-lifecycle` | sidebar as product: rename UI, kebab menu, archive/unarchive, delete, list cap 50 + archived toggle (D15/D16) | `archived_at` + partial index |
| S2 | `scc-w2-honest-state` | control_response typed dispatch, mode persistence (`set_mode/2`), :interrupting timeout + extracted idempotent teardown (D17/D18) | none |
| S3 | `scc-w2-headroom-ring` | per-turn context snapshot capture + header SVG headroom ring + cost text (D19) | `last_context_tokens` + `context_window` |
| S4 | `scc-w2-single-writer` | SessionRegistry + adopt_sink takeover, next_seq retry-on-conflict, real-binary E2E resume proof as AC (D20) | none |
| S5 | `scc-w2-approvals` | approval persistence end-to-end, replay as terminal states, pending-approval sidebar pill (D21) | `pending_approvals` count |

File ownership: S1 owns the SIDEBAR region of chat_live.ex + the list side of
studio_chat.ex; S2 owns the composer/handler region of chat_live.ex + the
control-frame region of claude_chat.ex; S3 owns record_result + the header
region; S4 owns Session start/init/adopt in claude_chat.ex + append_message in
studio_chat.ex + ensure_session; S5 owns the approval handlers/replay + pill.
Integration order **S1 → S2 → S3 → S4 → S5** (S2 before S4: both touch
claude_chat.ex; S1+S2 before S5: pill rides list_sessions select, teardown fn
absorbs the approval cancel-persist). Builders build against main; the
integrator reconciles in that order.

## Gates

- Elixir: `mix test test/barkpark_web/live/studio/chat_live_test.exs test/barkpark_web/studio/claude_chat_test.exs test/barkpark/portable_doc/from_markdown_test.exs`
  (worktree recipe: `ln -sfn $MAIN/api/deps deps && cp -R $MAIN/api/_build/test _build/test` — verified working in the gui-premium epic)
- Studio chrome: `bash scripts/studio-literal-check.sh` (no color literals)
- Real-binary E2E harnesses exist in the session scratchpad (not committed) —
  builders may replicate the pattern for new features.

## Wave log

### Wave 2026-07-09 (wave 2 BUILT + REVIEWED — trustworthy and managed)

All five slices built green and reviewed at the Kinsta/Vercel bar; nothing
stalled. As in wave 1, the reviewer serialized the wave into ONE integration
chain — each `-r` branch contains everything before it, so the lead merges
**`loop-epic/w2-approvals-that-survive-persist-approv-4-r`** (chain head:
S1 → S2-r → S3-r → S4-r → S5-r, integration order per the plan) and gets the
whole wave. Combined gate on the chain head: **173 tests 0 failures**
(chat_live + claude_chat + studio_chat, ran across 3 seeds), the charter
three-file gate green (134 tests), studio-literal-check PASS, and
`mix compile --force --warnings-as-errors` clean.

- **Landed**: sidebar as a managed resource list — inline rename (sheet-tab
  triad, blur commits), kebab menu, archive shelf (`archived_at` + partial
  index), delete, cap 50, teaching empty states (S1); typed control-response
  dispatch + mode persistence (`set_mode/2`) + un-wedgeable Stop (8s
  interrupt timeout + ONE idempotent `teardown_session/2`) (S2);
  context-headroom ring — per-turn snapshot columns, frame-captured
  contextWindow, geometry-first SVG arc + cost in the header, honest
  unknown state (S3); single-writer sessions — SessionRegistry +
  `adopt_sink/2` takeover with honest detached banner, `next_seq` retry ≤3
  on the unique index, real-binary E2E resume proof (`:real_binary` tag +
  `scripts/claude-chat-e2e.sh`) (S4); approvals persisted end-to-end —
  pending rows, resolve/cancel-all flips, canceled-on-reopen, denormalised
  `pending_approvals` + "needs you" pill (S5).
- **Reviewer fixes worth knowing**: (1) S2×S4 claude_chat.ex conflicts
  reconciled (init state carries BOTH `pending_controls` and `sink_ref`);
  (2) S5's cancel-persist moved from the pre-S2 inline exit handler into the
  extracted `teardown_session/2` (as the plan required), so crash,
  interrupt-timeout AND unexpected-DOWN all persist approval cancellation;
  (3) S5's `persist_approval_ask` re-routed through S4's
  `persist_store_logged` (log-don't-discard discipline); (4) fixed a LATENT
  wave-1 test flake: `capture_path` tmp files collided ACROSS `mix test`
  runs (`System.unique_integer` restarts per BEAM; a fake command can flush
  its capture file after on_exit's rm_rf) — stale frames from a previous run
  failed the interrupt write-path test intermittently; names now carry
  `System.pid()` + rm_rf-before-use. Verified 5 seeds green.
- **Known seams for the NEXT wave** (reviewed, deliberate, not blockers):
  (a) reopen-cancels-pending (S5) vs single-writer (S4): tab B merely
  VIEWING a session that tab A drives will cancel-persist tab A's live
  pending approvals — reopen doesn't consult the SessionRegistry yet;
  (b) rapid double mode-switch can mis-revert (acks are correlated by value,
  not request_id); (c) `take_over` stamps store status "working" even when
  no turn runs (mirrors the spawn path's convention; self-corrects on next
  result); (d) the kebab menu can clip at the scroll-container edge on the
  last row; (e) real-binary E2E happy path is code-reviewed, not yet run on
  this host (refuse path verified) — run `scripts/claude-chat-e2e.sh` once
  before calling D20c proven.
- **Next wave should take**: (1) run the real-binary E2E once on the host
  (~$0.43) and stamp D20c; (2) registry-aware reopen (don't cancel approvals
  a live owner can still resolve; consider a live "view-only" reopen);
  (3) correlate mode-switch acks by request_id; (4) message-level polish
  toward t3 parity — optimistic echo + restore-on-failure (t3 item 10),
  images as base64 blocks (t3 item 11), git checkpoint/rewind (t3 item 6);
  (5) sidebar search/filter once real usage grows past the 50 cap;
  (6) surface `last_context_tokens` compaction awareness (ring resets after
  CLI compaction — verify against a real long session).

### Wave 2026-07-09 (wave 1 BUILT + REVIEWED — sessions are a place)

All five slices built green and reviewed at the bar; nothing stalled. The
reviewer serialized the wave into ONE integration chain — each `-r` branch
contains everything before it, so the lead merges
**`loop-epic/ai-session-titles-layered-haiku-one-shot-4-r`** (head of chain:
S1-r → S2 → S3-r → S4-r → S5-r) and gets the whole wave. Combined gate on the
chain head: 135 tests 0 failures (chat_live 60 + claude_chat 32 + studio_chat
30 + titles 22, ran 3x) + studio-literal-check PASS +
`mix compile --force --warnings-as-errors` clean + the charter three-file gate
green.

- **Landed**: chat_sessions/chat_messages store + StudioChat context (S1);
  build_args seam + `--session-id`/`--resume` threading +
  interrupt/set_permission_mode/set_model control frames (S2);
  `/studio/chat/:session_id` routing, lazy mount, session sidebar,
  persist-on-completion, replay + lazy resume (S3); Stop/interrupted
  classification, crash force-cancels approvals, control-frame mode switch
  (S4); layered AI titles, clobber-guarded, fire-and-forget (S5).
- **Reviewer fixes worth knowing**: S3/S4 built against vendored forks of
  S1/S2 — reconciled to the canonical interfaces (`session_opts` map, string
  statuses — atom statuses failed `validate_inclusion` SILENTLY); Titles
  treated the canonical store's `{:ok, %Session{}}` as a refusal (the sidebar
  never learned the title) — fixed; `title_kicked`/`interrupt_requested` now
  reset per session switch (stale-state bugs across `push_patch`); summary is
  owned by user/assistant only + md furniture stripped; the result frame's
  answering model is persisted; replay hardened (unknown role / nil markdown
  can't make a session unopenable); latent `test/support/data_case.ex` drain
  bug (`Process.demonitor(ref, flush: true)` → `[:flush]`) exposed by the
  title task and fixed; LV tests pin null title seams (a host
  `ANTHROPIC_API_KEY` would otherwise make tests hit the real API).
- **Next wave should take**: (1) session delete/archive + `list_sessions` cap —
  the sidebar grows unboundedly and there is NO delete path; (2) rename UI over
  the existing `rename/2` (the store guard is proven, no surface calls it);
  (3) persist mid-session mode switches (the store row keeps the spawn-time
  mode → stale on reopen; needs a `StudioChat.set_mode/2`); (4) `:interrupting`
  timeout guard (a wedged CLI leaves "Stopping…" forever); (5) cost/usage
  surfacing in the sidebar off the already-denormalized totals (t3 item 7);
  (6) PendingApproval pill elevation + approval state on reopen; (7)
  real-binary E2E resume proof on the host (harness pattern exists,
  uncommitted); (8) `next_seq` retry-on-conflict for truly concurrent
  same-session appends.

- **2026-07-09 wave 2 DECIDED** (post-merge of #1681): five slices filed as
  scc-w2-lifecycle / scc-w2-honest-state / scc-w2-headroom-ring /
  scc-w2-single-writer / scc-w2-approvals under epic `studio-claude-chat`
  (D15–D21 above). Explorer corrections folded in: archive = `archived_at`
  column (status is a liveness axis — folding archive in breaks two
  validate_inclusion sites + the pill map); rename prior art = sheet tab
  triad, NOT board_live/org_admin (they have no inline rename); `:close` does
  NOT emit `{:claude_chat_exit}` so the interrupt-timeout teardown is an
  extract-and-share refactor, not a free reuse; the ring CANNOT ride the
  summed totals (needs per-turn snapshot + frame-captured contextWindow —
  grep proves contextWindow appears nowhere in the repo today); the
  two-tab harm is two `--resume` OS processes on the CLI's own transcript,
  fixed by Registry takeover (Sheets.Session is the house pattern) with
  next_seq retry as belt-and-suspenders; approvals are persisted NOWHERE, so
  slice 5 is real persistence work, not pill cosmetics; the real-binary E2E
  proof rides S4 as an AC (excluded-by-default `:real_binary` tag + script,
  ~$0.43/run).

- **2026-07-09 wave 1 DECIDED**: store = Ecto pair (doc route disqualified —
  private-schema query gate is any-token, query_controller.ex:375); resume =
  minted-uuid PK + lazy `--resume` (proven in stream-json mode); interrupt =
  raw-wire control frame (proven; discriminate via terminal_reason); mode switch
  via `set_permission_mode` key `mode` (respawn path removed); title = layered
  Judge-API → claude-p-haiku → derived, clobber-guarded. Slices scc-w1-store,
  scc-w1-wire-seam, scc-w1-sessions-ui, scc-w1-honest-turns, scc-w1-ai-title
  filed under epic `studio-claude-chat`.

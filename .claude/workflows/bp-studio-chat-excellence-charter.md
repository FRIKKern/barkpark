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

### Wave-3 decisions (2026-07-09, decided from explorer ground truth)

- **D22 — Reopen of a LIVE session ADOPTS; cancel-persist is only for the dead.**
  `load_stored_session` consults the SessionRegistry BEFORE any store write:
  `Registry.lookup(Barkpark.StudioChat.SessionRegistry, session.id)`. Live owner
  ⇒ `ClaudeChat.adopt_sink(pid, self())` + `Process.monitor(pid)` + assign
  `session: pid` with live status, and the unconditional
  `cancel_pending_approvals` (chat_live.ex:1145) is SKIPPED — the replayed
  pending approval cards (rebuilt from the store) stay ANSWERABLE because the
  tab holds a live pid. No live owner ⇒ today's cancel path (approvals truly
  dead). This makes "reopen of a live session" and "two-tab takeover on send"
  ONE code path — both adopt; the old tab gets the already-built
  `{:claude_chat_detached}` banner. Accepted honesty gap (deliberate): adopt_sink
  hands over FUTURE frames only and mid-turn streaming is never persisted
  (D7), so a mid-turn reopen shows a brief gap until the next port frame —
  do NOT extend the Session to snapshot streaming state this wave. Adoption
  hardening rides the same slice: the `{:already_started, other}` branch must
  survive a pid that died between lookup and adopt (alive?/immediate-DOWN
  guard) WITHOUT persisting+echoing a message the model never received.
- **D23 — Control acks correlate by `request_id`, never by value.** The Session
  already keys `pending_controls` on request_id (claude_chat.ex:445-459); the
  dispatch to the sink must carry it — `{:claude_chat_control, kind,
  request_id, resp}`. ChatLive records the request_id of each outbound
  set_mode/set_model and matches acks against it; a stale ack from a rapid
  double-switch can no longer mis-revert a newer optimistic assign. Persisted
  mode = the LAST acked value.
- **D24 — Send is two-phase: optimistic echo first, dispatch second; every
  send-failure restores the full draft.** The composer becomes server-bound:
  `value={@composer_draft}` + `phx-change` tracking — an uncontrolled input's
  retained DOM text is invisible to `render/1`, so restore tests are vacuous
  without the binding (clear = `draft: ""`, not just the id bump).
  `handle_event("send")` assigns echo + `draft: ""` + `:thinking` and returns
  immediately (first diff = instant echo); dispatch (ensure_session, wire
  write, persist) continues via `send(self(), …)`. Failure taxonomy (matrix,
  wave-3 exploration): create_session `{:error}` (DE-FANG the strict match at
  chat_live.ex:1091 — a crashed LV cannot restore anything), spawn error,
  dead-pid adopt, port-write failure ⇒ remove the echo, restore the draft
  VERBATIM, honest system line, NO orphan user row (persist only after a
  dispatched frame). Delivery honesty bar is "dispatched", not "delivered":
  `send_message` becomes a call whose reply carries the real `safe_command`
  outcome (it currently rescues everything to `:ok` — claude_chat.ex:601-610).
  EXCEPTION: persist-exhaustion AFTER a dispatched frame is
  save-may-not-survive, NOT send failure — echo stays, "⚠ could not be saved"
  line, composer stays CLEARED (restoring would double-send to the model).
- **D25 — Images = chat-scoped file store + data-URI inline render; the media
  plugin is DISQUALIFIED.** Wire proven on the real binary (v2.1.205): a user
  frame with `content: [{type:"text"},{type:"image",source:{type:"base64",
  media_type,data}}]` is accepted and the model sees the image. Widen
  `send_message` to accept a content-block list (text-only stays the default
  shape). Store: bytes NEVER in jsonb (D7 smell) and NEVER via the media
  plugin — `GET /media/files/*path` is public and "private" delivery is
  any-token (access.ex:114), the exact leak D6 disqualified. Bytes go to a
  chat-owned dir (`config :barkpark, Barkpark.StudioChat, :attachments_dir`),
  pointer `{path, media_type, sha256, byte_size}` in message metadata jsonb
  (no migration); replay reads the file and inlines `<img src="data:…">`
  SERVER-SIDE in the admin LiveView — no HTTP route ever (D6), and no CSP is
  set on the html pipelines so data: URIs render. `delete_session` removes the
  session's attachment dir (files must not outlive the row). Composer
  paste/drop = a phx-hook feeding `allow_upload` (accept png/jpeg/gif/webp,
  max_file_size 3MB — base64 inflation ×4/3 must stay under the API's ~5MB
  cap); NEVER reuse handlers/media.ex `upload_image` (routes bytes to the
  public media URL). Malformed image bytes degrade SOFTLY at the API (success
  result, model narrates) — not a restore-on-failure trigger.
- **D26 — Checkpoint/rewind is CUT this wave, without regret.** Ground truth
  killed the premise: `--fork-session` re-ids a FULL-memory branch — proven to
  NOT drop turns (codeword test, v2.1.205), and no message-level rewind flag
  exists. Memory-rewind-to-turn-N works only by truncating the CLI's
  undocumented private transcript jsonl — version-fragile, violates D1
  (never read `~/.claude/projects/*.jsonl`), and needs a per-turn cursor that
  D8 deliberately omits. File-only rewind IS safe (hidden-ref
  `GIT_INDEX_FILE` pipeline proven to leave HEAD/branch/index untouched) but:
  whole-tree restore clobbers concurrent uncommitted edits in the shared
  checkout, default plan mode means checkpoints capture no agent writes, and
  `add -A` costs ~1s/turn. Park until the CLI exposes a real rewind
  primitive; the git mechanics are banked in the wave-3 exploration report.
- **D27 — The ring is honest across compaction; surface `compact_boundary`
  instead of "fixing" anything.** Proven: `totalUsage` resets per user message
  and `cache_read` tracks the CURRENT prompt prefix, so the ring self-corrects
  on the first post-compaction turn — the "cache accounting keeps it inflated"
  premise was WRONG. The real gap: the CLI's
  `{"type":"system","subtype":"compact_boundary",compact_metadata:{trigger,
  pre_tokens}}` frame is silently eaten by ChatLive's catch-all
  (chat_live.ex:468). Add a handle_info clause appending an honest system line
  ("Conversation compacted (was ~N tokens)", auto vs manual wording) + a guard
  test: synthetic compact_boundary followed by a small result frame ⇒ ring
  frac SHRINKS. Known one-turn wrinkle (mid-turn compaction inflates that
  single turn's sum; multi-round-trip turns overcount cache_read per
  round-trip) gets a code comment, NOT a formula change — the formula
  faithfully reflects totalUsage and "fixing" it breaks the honest
  single-call case.

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
   (t3 verdict: NO queue — Stop gates the composer; optimistic echo ← WAVE 3.)
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

## Wave 3 plan (decided 2026-07-09) — "the conversation itself reaches the bar"

Waves 1–2 made sessions a place and made that place trustworthy. Wave 3 takes
the MESSAGE LOOP to the Kinsta/Vercel bar: instant echo that never loses your
words, images riding the same turn, and the two honesty seams wave 2 knowingly
shipped are CLOSED. Checkpoint/rewind was explored honestly and CUT (D26);
sidebar search/filter stays deferred (cap-50 recency still serves); the
compaction-ring "lie" was disproven and replaced by a cheap real feature (D27).

| # | Slice (bp task) | Owns | Migration |
|---|---|---|---|
| S1 | `scc-w3-reopen-adopt` | reopen of a live session adopts via SessionRegistry; drop unconditional cancel-persist; dead-pid adopt hardening (D22) | none |
| S2 | `scc-w3-control-honesty` | control acks correlated by request_id + compact_boundary honest system line + ring-shrink guard test (D23/D27) | none |
| S3 | `scc-w3-send-honesty` | optimistic echo, `composer_draft` binding, dispatch-outcome seam, full failure-matrix restore tests (D24) | none |
| S4 | `scc-w3-images` | composer paste/drop, content-block wire widening, chat-scoped attachment file store, data-URI replay, delete lifecycle (D25) | none (metadata jsonb) |

File ownership: S1 owns `load_stored_session` + the `{:already_started}`
adopt branch of `ensure_session`; S2 owns the control/system `handle_info`
clauses in chat_live.ex + the control dispatch in claude_chat.ex; S3 owns the
send handler + composer markup + `ensure_session`'s create branch + the
`send_message` cast→call conversion in claude_chat.ex; S4 owns the
`send_message` payload widening (additive: binary OR content-block list),
composer attachment strip, replay `<img>` rendering, and
`StudioChat` attachment store. Integration order **S1 → S2 → S3 → S4**
(S3 before S4: both touch `send_message` and the composer — S4 keeps its
changes additive and the integrator reconciles on S3's call shape).

## Gates

- Elixir: `mix test test/barkpark_web/live/studio/chat_live_test.exs test/barkpark_web/studio/claude_chat_test.exs test/barkpark/portable_doc/from_markdown_test.exs`
  (worktree recipe: `ln -sfn $MAIN/api/deps deps && cp -R $MAIN/api/_build/test _build/test` — verified working in the gui-premium epic)
- Studio chrome: `bash scripts/studio-literal-check.sh` (no color literals)
- Real-binary E2E harnesses exist in the session scratchpad (not committed) —
  builders may replicate the pattern for new features.

## Wave log

- **2026-07-09 wave 3 DECIDED** (post-merge of #1681 + #1693; D20c executed,
  1 test 0 failures): four slices filed as scc-w3-reopen-adopt /
  scc-w3-control-honesty / scc-w3-send-honesty / scc-w3-images under epic
  `studio-claude-chat` (D22–D27 above). Explorer corrections folded in:
  reopen=adopt is the seam-CLASS killer but NOT a 3-line fix (adopt_sink
  transfers future frames only — pending cards reconstruct from the store,
  streaming accepts a next-frame gap); "a failed send loses the text" is
  FALSE today (composer_rev bumps only on success) — optimistic echo
  INTRODUCES that hazard, so the slice re-establishes the guarantee with a
  server-bound draft + de-fanged create_session strict match + a
  dispatched-not-delivered honesty bar; media plugin DISQUALIFIED for image
  bytes (public serve route + any-token "private" delivery = the D6 leak) —
  chat-scoped file store + server-side data-URI inline wins (no CSP on html
  pipelines, verified); checkpoint/rewind CUT — --fork-session proven to
  keep FULL memory (no rewind primitive exists; transcript surgery violates
  D1 + D8); compaction-ring lie DISPROVEN (totalUsage resets per user
  message) — replaced by surfacing the silently-dropped compact_boundary
  frame. Stale umbrella task `task-589350071374f35b` (w2 parity — substance
  shipped across w2a/w2b/w2c + scc-w2-*) closed.

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
  last row; (e) RESOLVED 2026-07-09: `scripts/claude-chat-e2e.sh` was
  EXECUTED on this host post-review — **1 test, 0 failures. D20c proven.**
  Seams (a)/(b) are taken by wave 3 (D22/D23); (c)/(d) remain minor.
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

### Wave 2026-07-09 (wave 3 BUILT + LEAD-INTEGRATED — reviewer phase lost to spend cap)

Landed (4 slices, integrated by the lead after the Fable reviewer hit the monthly
spend limit; lead resolved the S3×S4 send-path collision by hand and re-gated):
- **scc-w3-reopen-adopt (D22)**: reopen of a LIVE session adopts it via
  SessionRegistry (adopt_sink + monitor); replayed pending approval cards stay
  answerable through the adopted pid; only ownerless sessions cancel-persist.
  Dead-pid adopt race yields an honest offline line, never a phantom send.
- **scc-w3-control-honesty (D23/D27)**: control acks carry request_id end-to-end
  ({:claude_chat_control, kind, request_id, resp}); a stale set-mode ack can no
  longer mis-revert; persisted mode = last ACKED value; compact_boundary frames
  surface as an honest system line.
- **scc-w3-send-honesty (D24)**: two-phase send — phase 1 echoes + clears the
  (now server-bound) composer in the first diff; {:dispatch_send} does
  ensure_session → wire write (send_message is now a GenServer.call returning
  the REAL dispatch outcome) → persist; every hard failure withdraws the echo
  and restores the words verbatim; persist-exhaustion warns but never restores
  (anti-double-send).
- **scc-w3-images (D25)**: paste/drop images ride the same user frame as base64
  content blocks; chat-owned attachment store (attachments_dir/<session>/<sha256>,
  pointer-only jsonb, server-side data-URI replay, no HTTP route); 3MB cap with
  honest inline errors; image-only sends valid.

Lead integration notes: union of S3-call semantics × S4-widened content on
send_message; phase-1 echo upgrades to the full text+thumbnail bubble on
dispatch when attachments exist (withdraw_pending_echo); image-only sends skip
the empty text echo; S4's validate_send no-op handler removed (composer-change
owns the form's phx-change and feeds allow_upload validation). Gate: 224 tests
0 failures × seeds default/42/99999; studio-literal-check PASS; format clean.

Cut: checkpoint/rewind (D26 — --fork-session keeps full memory; no rewind
primitive exists). Disproven: compaction ring lie (D27 — totalUsage resets per
user message).

Next wave should take: (1) real-browser verify of paste/drop + adopt flows;
(2) attachment GC for deleted/aged sessions beyond delete_session purge;
(3) sidebar search/filter when the 50-cap starts hiding real sessions;
(4) restore staged attachments on dispatch failure (today only text restores —
the strip empties if the wire write fails after consume); (5) charter D20c
follow-through: periodic real-binary E2E in a scheduled lane, not just on-demand.

### Wave 2026-07-09 (wave 4 — server-owned runtime, LEAD-BUILT inline)

**D28 — The server owns the agent runtime; tabs are viewers.** User mandate:
"I should not be needed to hold my tab open for the chat to continue going."
One `Barkpark.StudioChat.Recorder` per live session (Registry-keyed, under
`RuntimeSupervisor`) is the Session's PERMANENT sink: it persists every durable
outcome (assistant/tool rows, result metrics + context snapshot, approval asks,
exit → cancel-pendings + mark-exited) and rebroadcasts every frame verbatim on
PubSub `studio_chat:<id>`. ChatLive subscribes instead of owning: `terminate/2`
no longer closes the session, navigating away only unsubscribes, and the w2/w3
adopt/detach/take-over machinery is REPLACED by co-viewing (all tabs render
live; sends still serialize through the single Session; user turns broadcast
via {:chat_user_message} so transcripts converge). ChatLive store writes now:
user-message persist + approval RESOLUTION only; `record_result` is read-only
(recording there too would double-sum). Idle reaper: 30 min of frame-silence
(config `:studio_chat_idle_reap_ms`) closes the subprocess honestly
({:claude_chat_exit, :idle_reaped}) — invisible: next send lazy-resumes.

Proof: 233 tests × 3 seeds green (9 new recorder tests own the persistence
seam — including "runtime survives a viewer's death"); REAL-BINARY detached
proof executed: turn sent, no viewer subscribed, `BARKPARK-DETACHED-OK`
persisted to the store by the Recorder alone. warnings-as-errors clean,
studio-literal-check PASS.

Known accepted gaps → wave 5 candidates: (1) streaming tail is not snapshotted
— a reopen mid-turn shows a gap until the next frame (Recorder could buffer
the current turn's deltas and replay to a late subscriber); (2) the title kick
still lives in ChatLive (needs an open tab on the FIRST turn; move to Recorder
for fully-detached first turns); (3) interrupt-timeout force-close is
tab-driven (move the D18 timer into the Recorder); (4) sidebar "working" pill
while fully detached only updates on result frames; (5) subscribe-then-read
replay window can double-render a message that persists in the gap (rare,
cosmetic, converges on reopen).

### Wave 2026-07-09 (wave 5 — living sidebar cards + model picker, LEAD-BUILT inline)

**D29 — The sidebar is a live window into every running agent.** User mandate:
"We want to see them working, what they are working on." Every Recorder derives
an activity off its frames — init → working "thinking…", stream deltas →
"writing…" (change-only: 100 deltas = 1 event), assistant tool_use → the
concrete tool line ("Bash — mix test"), permission → needs_you "waiting:
<tool>", result → idle, exit → offline — and broadcasts it on the GLOBAL topic
`studio_chat:activity`. Every chat tab subscribes once at mount and overlays
the map on the stored rows: working pill with a breathing dot + the live tool
line in evergreen mono replaces the stale summary; on idle/offline the overlay
yields to the fresh store row (always refresh_sessions on activity — events
are change-only, so cheap). Recorder also persists status "working" on init so
COLD sidebar loads agree. resolve_permission drops its own overlay entry (the
Recorder can't see the user's click; the next frame republishes truth).

**D30 — Model choice is intent; observed model is fact.** User mandate: "choose
our model in a premium way — I feel stuck on Haiku." `model_choice` column
(nil = CLI default) — distinct from `model` (the answering model off the
result frame). Picker (default/haiku/sonnet/opus/fable, allowlist-normalized,
fail-closed) in the header: persists via set_model_choice, steers a LIVE
session via the set_model control frame (no pend/revert — its ack can be an
empty success, D12 trap; the next init/result reports fact, rendered dim-mono
beside the picker), rides the next spawn as `--model <alias>` (fresh AND
resume). REAL-BINARY PROBE: this host's CLI default is claude-fable-5;
`--model opus` → claude-opus-4-8 — the picker delivers real switches and the
fact-readout ends the "what am I talking to?" guessing.

Gate: 248 tests × 3 seeds; studio-literal-check PASS; warnings-as-errors clean.
Wave-6 candidates: turn elapsed-time on working cards; activity line in the
browser tab title; per-model cost hinting in the picker; observed-model change
system line when a switch lands mid-session.

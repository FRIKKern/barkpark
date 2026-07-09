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

### Wave-6 decisions (2026-07-09, decided from real-binary ground truth — v2.1.205, harnesses ask2/exitplan2/deny/wire_init*.py in session scratchpad)

- **D31 — Permission asks get ROLES; the store is the router.** The single wire
  message `{:claude_chat_permission, ask}` stays (it already carries
  tool_name/input/title — claude_chat.ex dispatch_event); discrimination happens
  DOWNSTREAM. `Recorder.persist_approval_ask` branches role by `ask.tool_name`:
  `"AskUserQuestion"` → `"question"`, `"ExitPlanMode"` → `"plan"`, else
  `"approval"` (Message.role is a free string — NO migration). Every seam that
  today matches `role == "approval"` widens to ONE needs-you set
  (`~w(approval question plan)`), threaded consistently: `bump_on_append`'s
  pending_approvals inc, `cancel_pending_approvals`, `find_approval`, ChatLive's
  `teardown_session` pending→canceled flip, and replay. The `pending_approvals`
  counter remains THE one counter and now means "the agent needs you" (partial
  widening leaves the sidebar pill lying for questions). Terminal statuses REUSE
  `allowed|denied|canceled` — an answered question is `allowed` (answers in
  metadata), keep-planning is `denied`; no new labels, so `@approval_terminal`
  stands. ChatLive's `{:claude_chat_permission, ask}` handler applies the same
  tool_name discrimination for live rendering.
- **D32 — Allow ALWAYS echoes updatedInput; ONE answer seam widens.** PROVEN:
  a bare `{"behavior":"allow"}` FAILED ExitPlanMode on the real binary
  (ZodError, mode stayed plan); `{"behavior":"allow","updatedInput":<input>}`
  succeeded — matching the CLI's own internal checkPermissions shape.
  `respond_permission` decision becomes `:allow | {:allow, updated_input} |
  {:deny, message}`; plain `:allow` echoes the ORIGINAL ask input as
  updatedInput (Session tracks pending ask inputs by request_id — never trust
  the caller to round-trip it), `{:allow, updated}` carries the caller's map.
  Question answers ride `{:allow, %{"questions" => unchanged, "answers" =>
  %{<question string> => <value>}}}` — the answers Record keys on the QUESTION
  STRING (proven; the CLI keys internally by K.question), custom free-text
  rides as the value, multiSelect = comma-joined labels (`"Cat, Dog"` proven).
  Deny REQUIRES message (schema); a denied question surfaces the message as an
  is_error tool_result — code-evidenced, spot-check when building the dismiss
  path. Empty answers on allow → "The user did not answer the questions."
- **D33 — Plan mode gets `--permission-prompt-tool stdio` too.** Today
  build_args omits the flag in plan mode (claude_chat.ex:162), so ExitPlanMode
  asks NEVER reach Barkpark — the CLI auto-handles them. Plan mode is the
  product default; the flag ships in ALL modes. Consequence accepted: other
  tools' asks in plan mode now also reach us and render as honest approval
  cards. D9 applies — prove via build_args pure unit tests, never `:command`.
- **D34 — Proposed-plan card: store markdown, render on read, OBSERVE the
  flip.** `input.plan` IS the markdown and is already persisted in ask metadata
  (D7 satisfied; `input.planFilePath` is a CLI side-effect file, ignore it).
  Card: title = first heading via a ~3-line helper over `FromMarkdown.blocks`
  (`%{"type"=>"heading","text"=>t}`); body = `render_paper_html(plan)` in FULL,
  collapsed by CSS clamp (max-height + `var(--…)`-token fade) — NEVER
  pre-truncate the markdown (an unbalanced fence degrades the whole doc to one
  code block); expand/collapse = per-tab socket assign (kebab-menu pattern,
  never broadcast). Approve = `{:allow, echoed input}`; the CLI flips its OWN
  mode plan→prePlanMode(default) inside the tool — we send NO set_permission_mode
  follow-up. The flip is observable ONLY on the NEXT turn's `system/init`
  `permissionMode` (the terminal result frame's permission_mode is null —
  asserting there is vacuous-green). Observe init's permissionMode and persist
  via `set_mode/2` whenever it differs from the stored mode, so reopen and the
  next lazy spawn carry the post-plan mode. Keep planning = `{:deny, "The user
  wants to keep planning — continue in plan mode."}` (proven: model re-plans,
  next init still plan).
- **D35 — Resolutions BROADCAST; answer-in-progress stays per-tab.**
  `resolve_permission` today mutates only the resolving tab (no PubSub) — a
  co-viewing tab's card stays pending until reopen, and for questions that
  means an open form for an already-answered ask. After `update_approval_status`
  succeeds, broadcast the resolution on `studio_chat:<id>` (terminal status +
  request_id + answers); all tabs converge their card. Chip selections /
  custom-answer text / expand state remain socket-local. needs_you activity
  vocabulary upgrades by role: question → "asking you", plan → "plan ready",
  approval keeps "waiting: <tool>".
- **D36 — Composer power: initialize handshake, slash menu, sticky drafts,
  sticky model.** (a) Session sends `{"subtype":"initialize"}` right after
  spawn (proven: the CLI answers immediately, BEFORE any turn; no capabilities
  payload needed); `control_kind` learns `:initialize`; the ack's
  `response.commands` (`{name, description, argumentHint, aliases?}`) is the
  authoritative list, HELD in the Recorder runtime so a late-joining tab still
  gets it; fallback = `system/init.slash_commands` names; hard floor = builtins
  `/model /plan /default`. Permission routing is the stdio FLAG, not the
  handshake (proven) — initialize is purely additive. (b) Slash menu: leading
  "/" opens a combobox (adapt the bp-sheet-grid.js fn-autocomplete pattern:
  server-stamped vocabulary, client listbox, ARIA combobox roles, arrow/enter/
  escape nav); selection INSERTS text and dispatches a native `input` event so
  the server-bound draft stays in sync (D24). Builtins route to our existing
  control paths; advertised commands send as plain user text frames (proven to
  execute, num_turns=0). GUARD: harness result frames echoed a DIFFERENT
  session_id on slash turns — spot-check D8 pinning survives a slash command
  before enabling session-mutating ones (/compact /clear), else ship those
  insert-only with the assumption marked. (c) Sticky drafts: `draft` column on
  chat_sessions (model_choice migration pattern); captured at the TOP of
  handle_params BEFORE dispatch (the switch-away moment), restored in
  load_stored_session (full struct — get_session carries it), persisted-cleared
  on send. Write on switch-away, not per-keystroke. (d) Sticky model:
  reset_to_new_chat seeds model_choice from a DEDICATED
  most-recent-non-default-model_choice query — never from list_sessions' select
  (it omits model_choice; the naive seed reads nil and ships "default" forever,
  vacuous-green).

### Wave-7 decisions (2026-07-09, decided from real-binary + code ground truth — "the transcript IS the terminal")

- **D38 — Tool-specific rendering = shape dispatch over persisted metadata.input;
  BOTH render paths widen first.** The full tool `input` map is persisted
  verbatim and uncapped on every tool row (recorder.ex:302) — but both render
  paths DROP it today: live append keeps only tool_use_id+output
  (chat_live.ex:730/2524) and replay keeps only output (chat_live.ex:2465-2473).
  Foundation move: thread `input` + `tool` (+ `tool_use_id` in replay) through
  both maps, then dispatch renderers on INPUT SHAPE, never a hardcoded name
  (names are host-binary-dependent — the cmux binary emits `Agent` where vanilla
  says `Task`, and lacks TodoWrite/MultiEdit entirely). Shapes, wire-proven
  v2.1.205: Edit `{file_path, old_string, new_string, replace_all}`; Write
  `{file_path, content}` (render as all-added); Task/Agent
  `{description, prompt, subagent_type, run_in_background}`; MultiEdit
  `{file_path, edits:[…]}` is UNVERIFIED on this host — handle defensively as
  stacked hunks, no dedicated proof. Diff engine: REUSE
  `Barkpark.Papers.TextDiff.diff_lines/2` (tested DP-LCS returning
  `%{op: "="|"+"|"-", text}`) — do NOT build a second Myers differ (the
  original List.myers_difference plan is superseded; a second line-diff engine
  is the exact capability-dup the repo polices). Chrome: `--ok`/`--ok-soft`
  added lines, `--danger`/`--danger-soft` removed, mono, collapsible via the
  existing ⎿ details pattern; truncation lives at RENDER ("+N more lines",
  show ~20 lines collapsed, cap the expanded pre honestly for huge hunks) —
  persist stays full for replay fidelity, no persist cap this wave.
  studio-literal-check must pass (var()/hsl(var(--*-hsl)/α)/color-mix all pass;
  raw hsl(digit)/#hex fail).
- **D39 — TodoWrite = ONE living checklist card; the Recorder owns the
  collapse.** Each TodoWrite arrives as a fresh tool_use with a UNIQUE id, so
  find-by-tool_use_id cannot collapse — the Recorder tracks "this turn's todo
  row" (the tool_use_id of the turn's FIRST TodoWrite-shaped block) in state,
  RESET on `system/init` (the per-turn boundary, recorder.ex:189); a later
  TodoWrite in the same turn UPDATES that persisted row's metadata.input in
  place (new `StudioChat.update_tool_input/3`, the attach_tool_result pattern:
  find by tool_use_id, changeset metadata, Repo.update) instead of appending.
  Replay therefore reconstructs ONE final-state card for free. Live
  convergence: the Recorder keeps rebroadcasting frames VERBATIM; ChatLive's
  assistant reducer applies the SAME pure rule — a TodoWrite-shaped tool_use
  supersedes the turn's existing todo card in-memory (tracked per turn, reset
  on the broadcast init frame) — so all tabs that saw the turn converge;
  a mid-turn joiner appends one card with the latest state (correct content,
  later position — accepted; reopen converges). Shape-TOLERANT: accept both
  `{content, status, activeForm}` (modern) and `{content, status, priority,
  id}` (legacy); status map pending→☐, in_progress→◐ (+ activeForm as the live
  line when present), completed→☒. TodoWrite is ABSENT from this host's cmux
  binary (swapped for Barkpark task tools) — build fixture-driven, degrade to
  nothing when no TodoWrite ever arrives, and the vanilla-binary proof is a
  spot-check, not a blocker.
- **D40 — Task/Agent spawns render as nested traces; `parent_tool_use_id`
  joins the persisted row (this IS new plumbing — the "zero wire plumbing"
  framing was half-wrong).** Every frame carries top-level
  `parent_tool_use_id` (null = top-level; a tool_use id = child of that
  spawn), and child tool_use/tool_result frames interleave on the SAME stream
  — wire-proven. The Recorder discards it today (it only reads
  message.content blocks). Fix: persist non-nil `ev["parent_tool_use_id"]`
  into the metadata of every row the Recorder writes; live + replay render
  rows with a parent as an INDENTED nested trace under their parent's ● row,
  labeled with the spawn's `description`. Name/shape-tolerant per D38
  (match both `Task` and `Agent`, or the `{description, prompt,
  subagent_type}` shape). The parent's own ⎿ tool_result (subagent summary +
  usage) already attaches via the existing machinery.
- **D41 — Thinking is a PULSE, not a snippet — premise CORRECTED, snippet
  CUT.** The wire carries thinking FRAMES but never thinking TEXT: every
  thinking_delta and every assistant thinking block arrives with
  `thinking: ""` — only `estimated_tokens` and a ~3.8KB ENCRYPTED signature
  are populated, identical across models (fable + sonnet probed, v2.1.205).
  There is nothing to collapse. Build instead: a ✻ thinking row driven by
  `system/thinking_tokens` (`estimated_tokens` is monotonic CUMULATIVE — use
  it; thinking_delta's per-block counts are NOT cumulative, never sum them)
  with a live "✻ thinking… ~N tokens" counter; the row opens on the first
  thinking signal and settles when the first text_delta/tool_use/result
  arrives. All these frames ALREADY reach ChatLive via the Recorder's
  verbatim rebroadcast — they just fall through the catch-all
  (chat_live.ex:914); add handler clauses above it. Replay: the Recorder
  accumulates the turn's thinking tokens and persists a compact row (role
  `"thinking"`, metadata `{tokens: N}`) BEFORE that turn's assistant blocks
  so replay order matches live order; replay renders the dim mono
  "✻ thought for ~N tokens" line. NEVER persist or render the signature.
  Forward-compatible: the handler reads `delta["thinking"]` and would append
  text if a future CLI populates it — falls back to the counter today.
- **D42 — Esc interrupts from anywhere; the two real Esc consumers get
  stopPropagation; the keyboard hint is unconditional.** Only TWO surfaces
  actively consume Esc (slash combobox, bp-chat-composer.js:228-231; session
  rename, chat_live.ex:1187-1188) and NEITHER stops propagation — a naive
  global listener double-fires through them. Fix: document-level keydown
  added in ChatComposer's mounted/destroyed (BarkparkPaperContextMenu
  precedent); the slash-menu Escape branch adds `e.stopPropagation()`; the
  rename input is marked (data attribute) and the global handler skips when
  focus is inside it. Otherwise Escape pushes `stop_turn` — the server
  handler already exists (chat_live.ex:282) and must stay a no-op when no
  turn runs. Native ⎿ details don't consume Esc and the global handler must
  not close them. Footer: a quiet UNCONDITIONAL mono hint line
  "esc interrupt · / commands · ↵ send" as a SIBLING of the D37 cost strip —
  the cost strip's `:if last_result.cost_usd` conditional stays; the hint
  never hides behind it.
- **D43 — Steering resolves to honest QUEUE; the composer never locks.**
  Real-binary probe (twice, v2.1.205): a user frame written mid-turn is NOT
  injected into the running turn — the CLI buffers it, turn 1 completes
  untouched, then a fresh system/init fires and the queued frame runs as its
  own turn. The "remove the gate and it steers" bet is DISQUALIFIED; the t3
  "mid-turn = steer" pattern is t3's own engine, not the raw binary. Build
  the honest fallback: delete the silent drop-gate (chat_live.ex:232) so a
  mid-turn send runs the normal D24 two-phase path — wire write immediately
  (the binary buffers it), optimistic echo rendered with a "⧗ queued" badge,
  persisted IMMEDIATELY with `metadata.queued: true` (never defer — words
  must never be lost; the queued row interleaving among the running turn's
  assistant rows on replay is accepted temporal truth). The badge is
  LIVE-ONLY state: it clears in-memory when the next system/init fires
  (the queued turn starting); replay renders a plain ❯ row (position tells
  the story; metadata.queued is kept as a historical fact, not chrome).
  Interrupt-with-queued-frames interplay (`still_queued` in the interrupt
  ack) is out of scope this wave.

### Wave-8 decisions (2026-07-09, decided from explorer ground truth — composer cockpit + agent drill-down)

- **D44 — Composer cockpit is LAYOUT ONLY; the input stays an `<input>`; the
  phx-change forms survive the move.** The brief's "textarea on top" is CUT by
  evidence: D24 tests pin `input#chat-composer[value=...]` (chat_live_test
  3334/3350/3379) and the hook's Enter-to-submit rides the single-line input —
  a textarea is a separate future decision, not a restyle rider. Header slims
  to title + status label (+ admin note); the header's STANDALONE
  observed-model span (chat_live.ex ~1467) is DELETED — it duplicates the
  picker-adjacent span (~1499), which moves WITH the picker as the dim mono
  fact suffix (intent beside fact, D30). The footer row lives INSIDE
  form#chat-composer-form as a new flex child under the input: left cluster =
  the mode `<form phx-change="set-mode">` and model `<form
  phx-change="set-model">` KEPT as form wrappers (10+ test selectors target
  `form[phx-change=...]`) with the selects restyled borderless (transparent
  bg, no border, token-colored text, hover affordance only — all `var(--…)`);
  right cluster = mini context ring, attach icon button, Send/Stop (semantics
  untouched: same phx-submit/phx-click on the same form).
  `context_ring` gains `size` (`:md` default 30px | `:sm` ~16px — geometry is
  viewBox-relative so only pixel width/height change; the 9px % label HIDES at
  :sm) and `show_cost` (`:sm` in the footer passes false — the ring's built-in
  trailing cost span would double-render against the D37 strip). Attach button
  = `<label for={@uploads.attachments.ref}>` styled as an icon button (image
  icon exists, icons.ex:24) — live_file_input hardcodes `id={@upload.ref}`
  (LV 1.1.28), so label-for opens the native dialog with ZERO hook change;
  the hidden input, attachment strip, paste/drop hook, and upload errors stay.
  Placeholder: only the idle/ready clause of `composer_placeholder/1` becomes
  the teaching copy "Plan, build… / for commands" — never advertise
  @-mentions; degraded-state clauses keep their honest text. The D37 cost
  strip + D42 hint line relocate as ONE quiet mono line directly below the
  footer row: hint UNCONDITIONAL (test-pinned), cost segment still
  `:if @last_result.cost_usd` (the fresh-mount ⏵ refute must keep passing).
  IMMOVABLE client contract: form#chat-composer-form as hook root,
  input#chat-composer, ul#chat-slash-menu with `phx-update="ignore"` (#1831),
  data-commands. No mic, ever. Header-select test assertions MOVE to the
  composer footer — updated, never deleted.
- **D45 — Task lifecycle lands in the Recorder: merge-stamp the spawn row,
  session-lifetime correlation, notification-driven completion, teardown
  flip.** The four `system/task_*` frames already reach the Recorder and are
  already rebroadcast verbatim by the catch-all (recorder.ex:276-279); what's
  new is persistence + consumers. NEW `StudioChat.merge_tool_metadata/3`
  (sibling of update_tool_input — which REPLACES metadata.input and would
  clobber the spawn's `{description,prompt,subagent_type}`; never reuse it):
  find by tool_use_id, `Map.merge` into metadata, `:noop` on no match. Stamp
  keys on the SPAWN row: `task_id`, `task_status`
  ("running" on task_started; terminal from notification/updated),
  `task_progress` (latest "Running …" description — the wire field is
  `description`, not `line`). Correlation: task_started/task_progress/
  task_notification all carry tool_use_id directly; ONLY task_updated is
  task_id-only — hold `task_index :: %{task_id => %{tool_use_id, last_line}}`
  in Recorder state as SESSION-LIFETIME state, never inside the per-turn
  system/init reset (recorder.ex:229-233) — a background agent outliving its
  turn must still resolve. Completion is driven primarily off
  task_notification (tool_use_id + status + summary aboard); task_updated
  resolves via the map when possible and drops harmlessly otherwise.
  Persist COARSELY, broadcast every frame: status transitions always persist;
  task_progress persists only when the line differs from the map's last_line
  (wave-5 change-only discipline — never a row-per-progress, never a
  per-frame Repo.update on an unchanged line). Teardown ships IN THE SAME
  SLICE: new `StudioChat.interrupt_running_tasks/1` modeled exactly on
  cancel_pending_approvals (transaction, rows where
  `metadata->>'task_status'='running'` → `"interrupted"`), called from
  `session_exited/1` alongside cancel_pending_approvals — a crashed or
  idle-reaped session must never replay a live spinner. task_progress does
  NOT feed the sidebar (a child's assistant tool_use frames already drive
  publish_activity); the fine progress line is transcript-only.
- **D46 — Agent drill-down: render-time buckets keyed by parent_tool_use_id;
  per-tab expand override; value-equality-guarded live merge.** Grouping is
  by ID MATCH, never consecutive position (children of parallel spawns
  interleave in seq order — charter D40 + the multi-block reducer prove it):
  at render, bucket rows whose `parent_tool_use_id` equals a top-level spawn
  row's `tool_use_id` under that spawn; everything else stays top-level in
  seq order. ORPHAN children (parent id present, no matching spawn in this
  transcript) fall back to today's flat indented row — never vanish. One
  nesting level (deeper is wire-unproven); a child that is itself a spawn
  renders as a plain spawn row inside its parent's bucket. The agent block:
  collapsed header `● Agent(subagent_type — description)`; while
  `task_status == "running"` a breathing live progress line ("Running: …",
  token-colored, CSS animation) + child count; completed = collapses to the
  agent's ⎿ report (metadata.output — already attached by the w6.5 machinery,
  role "tool" spawn row must stay role "tool" or attach_tool_result noops).
  Expand state is a per-tab override map `agent_expanded :: %{tool_use_id =>
  bool}` (plan-card precedent, never broadcast): default open while running,
  collapsed when terminal; a manual toggle ALWAYS wins over the default.
  ChatLive gets task_* handle_info clauses ABOVE the noop catch-all
  (chat_live.ex:1055): merge task_id/task_status/task_progress into the
  in-memory row matched by tool_use_id (task_updated matches by task_id — the
  row carries it from live task_started or replay hydration) with a
  VALUE-EQUALITY guard: identical status+progress ⇒ return the socket
  unchanged (messages are a flat :for comprehension; every reassign is an
  O(n) server render per tab — the guard converts hot progress into
  render-on-change). Replay: the role-"tool" replay_message clause
  additionally reads task_id/task_status/task_progress from metadata — a
  reopened mid-run session shows the honest last-persisted line, an
  interrupted one shows "interrupted" (D45 teardown), never a fake spinner.
  All chrome via emitted tokens; studio-literal-check passes.

### Wave-9 decisions (2026-07-09, decided from explorer ground truth — mission control)

- **D47 — Agents rail: task_id-keyed, one new jsonb column, EXTEND the D45
  clauses.** `system/background_tasks_changed` is a task_id-keyed SNAPSHOT
  carrying NO tool_use_id (t3-patterns:147-149 is the spec of record), so the
  rail keys on `task_id` — the spawn-row `merge_tool_metadata` route is
  DISQUALIFIED (matches on tool_use_id, cannot express snapshot drain) and a
  `role:"rail"` message row is DISQUALIFIED (occupies a transcript seq).
  Persistence = NEW jsonb column `chat_sessions.rail_snapshot`, map
  `%{task_id => %{"row" => %{task_type, description}, "workflow" => tree,
  "status" => "running"|"completed"|"interrupted", "usage" => last-known
  totals}}`, updated in place (migration sibling of model_choice's).
  Recorder: `rail_snapshot` lives in `new_state` as SESSION-LIFETIME state
  (exactly like task_index — NEVER inside the per-turn init reset,
  recorder.ex:237-241). New `background_tasks_changed` clause ABOVE the
  catch-all (recorder.ex:331): replace the live row set; a task_id that
  vanished from the wire snapshot flips its persisted entry to a terminal
  status ("completed" unless already terminal) — entries are never deleted,
  so replay shows the last-known rail. The EXISTING `task_progress` clause
  (recorder.ex:304-311) GROWS rail capture of `ev["workflow_progress"]`
  (first-match dispatch — a second clause would never fire); task_updated/
  task_notification stamp entry status when the task_id has a rail entry.
  Change-only law (both files, ONE shared signature fn): structural signature
  = the workflow tree with token/usage fields stripped (phase titles + agent
  labels + models + states) — structural/state change ⇒ persist + re-render;
  token-only tick ⇒ Recorder skips the Repo.update, ChatLive throttles the
  assign (D46 value-equality + wave-5 change-only precedents; reuse ONE
  computation for the agent block and the rail or they diverge). ChatLive:
  new clauses above ITS catch-all (chat_live.ex:1145) — that catch-all
  silently dropping these frames is exactly why the user saw no agents.
  Render: a NEW rail region directly below the composer, Claude-Code-TUI
  style — one row per live snapshot task (`task_type` glyph + description),
  workflow rows expand (per-tab `rail_expanded` map, agent_expanded
  precedent) into the phase→agent tree: state glyph breathing while running
  (D46 pattern), model, token counts. Replay: hydrate the rail from
  `rail_snapshot`; `interrupt_running_tasks/1` (studio_chat.ex:672) EXTENDS
  its contract to also flip rail entries `"running"` → `"interrupted"` in the
  same call — a reopened session never shows a fake live rail. Rail rows and
  D45/D46 transcript spawn rows are intentionally DISTINCT surfaces (mission
  control vs history) — no dedup. Bloat guard: persist the structural tree +
  last-known totals only (never per-frame usage churn), cap 20 entries
  (prune oldest terminal).
- **D48 — Settings: real modes, ceremonial bypass, effort as model's twin.**
  (a) Both `@modes` constants (claude_chat.ex:36, session.ex:27) become the
  REAL six: `plan acceptEdits auto dontAsk manual bypassPermissions`.
  Audit verdict (probed, v2.1.205): `--permission-mode default` is
  SILENTLY ACCEPTED and echoed back — a correctness alignment, not a crash
  fix. Legacy handling: NO data migration, NO read-time rewrite — a stored
  `"default"` keeps spawning verbatim (proven safe); the footer select
  renders one extra `<option value="default">ask (legacy)</option>` ONLY
  while the current session carries it, so the select never renders
  unselected; the `/default` builtin is DELETED (mode_label learns the six).
  The "invalid mode" test (studio_chat_test.exs:309-315) and
  claude_chat_test.exs:92/149 default-argv pins are REWRITTEN with the list
  (use a genuinely-invalid string like "yolo").
  (b) bypassPermissions fail-closed law: `normalize_mode/1` KEEPS mapping
  `"bypassPermissions"` → `"plan"` (claude_chat_test.exs:97 stands and now
  encodes the law — an untrusted string can never fail open into bypass).
  The ONLY road to bypass: the footer pick opens an inline arm panel
  (--danger tokens, loud) requiring type-to-confirm ("bypass") + an explicit
  Arm button (net-new UX; data-confirm is not enough); the arm handler
  persists mode via `set_mode` (whose validate_inclusion now admits it).
  Spawn threading: `session_opts` gains `bypass_armed: boolean`, set by
  ChatLive ONLY from the persisted session row (never a raw event param);
  build_args resolves `mode == "bypassPermissions" and bypass_armed` ⇒ emit
  `--permission-mode bypassPermissions --allow-dangerously-skip-permissions`
  (both flags — lead-probed requirement); otherwise the mode goes through
  normalize_mode as today. NO live steer into bypass: an armed pick
  mid-session persists + honest "applies from the next resume" line (the
  running process lacks the allow flag). Non-bypass picks keep D12/D17 live
  set_permission_mode steering.
  (c) Effort clones model_choice across all seven sites: migration
  `add :effort_choice, :string`; session field; `set_effort_choice/2` +
  `recent_effort_choice/0` (dedicated query — never list_sessions, D36d
  vacuous-green); `effort_args(%{effort: e})` ⇒ `["--effort", e]` appended
  in build_args (allowlist `low medium high xhigh max`, fail-closed to nil =
  omit the flag; D9 pure-unit + :binary argv-echo proofs); recorder
  session_opts gains `effort:`; ChatLive mount/reopen/new-chat seeds mirror
  model_choice. UI: an effort select as a sibling
  `<form phx-change="set-effort">` in the composer-footer left cluster,
  composed visually with the model select as one "Fable · high" group
  (model_label + new effort_label). Mid-session effort change: persist +
  honest "effort applies from the next resume" system line — NO set_effort
  control verb exists (grep-proven; the four control subtypes are closed).
- **D49 — Plans as papers: server-side projection, deterministic slug,
  request_id-keyed metadata merge.** New thin seam module
  `Barkpark.StudioChat.PlanPapers`: `publish(session_id, request_id,
  plan_markdown)` = `FromMarkdown.blocks/1` → `Content.upsert_paper(%{"slug"
  => slug, "blocks" => blocks, "style" => "article", "dataset" =>
  "production"})` — SCOPE-LESS (resolve_write_scope([]) lands the seeded
  Default workspace, the same tenant `/papers/:slug` reads; upsert publishes
  unconditionally, block_ops.ex:209) — no HTTP, no ingest token. Slug is
  DETERMINISTIC: `"chat-plan-" <> first 12 hex of sha256(session_id <>
  request_id)` — upsert's {dataset, slug} keying makes re-approve
  idempotent by construction. paper_id == slug; paper_url =
  `"/papers/#{slug}"`. THE gap the explorers found: no request_id-keyed
  metadata merge exists (merge_tool_metadata keys on tool_use_id which plan
  rows lack; update_approval_status writes approval_status only) — add
  `StudioChat.merge_approval_metadata(session_id, request_id, patch)`
  reusing `find_approval/2` (already role-inclusive of "plan") +
  `Map.merge` + `Repo.update`. Hook: inside `resolve_permission`
  (chat_live.ex:3143), gated `role == :plan` AND decision == allow, AFTER
  the allow hits the wire: `Task.start` fire-and-forget — publish → merge
  `%{"paper_id" => id, "paper_url" => url}` onto the plan row → broadcast
  `{:plan_paper, request_id, %{...}}` on `studio_chat:<id>` (all tabs
  converge; the Task never touches the socket). Failure honesty: a publish
  failure broadcasts `{:plan_paper_failed, request_id}` → live-only honest
  system line; the approve NEVER fails or blocks. Create on APPROVE only
  (keep-planning plans stay chat ephemera). Render: the plan card's
  TERMINAL branch (chat_live.ex:1492-1498) gains a quiet "→ published as
  Paper" link off `@message.paper_url`; replay: `build_plan_message` +
  the role-"plan" replay clause carry paper_id/paper_url from metadata —
  the link survives reopen forever. D7 stands: the markdown in metadata is
  the source; the Paper is a projection.
- **D50 — Gutter matrix: one flush-text helper, honest margin ceiling,
  fixture-driven rows.** The three shipped bugs (#1844 pre-wrap template
  whitespace, #1849 first-block margin, tool-row wrap) share one blind
  spot: nothing asserts rendered-HTML geometry — both existing regression
  tests are string-presence proxies (#1849 would pass with zero matching
  elements; #1844's assertion actually fires on the setup's user row).
  Build: (i) a tiny stable hook — `data-gutter-text` attribute added to
  each gutter text node in message_body/agent_block/live-chrome
  (ATTRIBUTE-ONLY edits; the :plan branch is covered via its existing
  `.bp-chat-md` class — S3 owns that region); (ii) ONE generic helper
  `assert_flush_gutter_text/1..2` over the raw render(view) string: for
  every data-gutter-text carrier, refute `~r/>\s*\n/` immediately after the
  opening tag (the defect lives in the SERIALIZED bytes — raw regex is MORE
  faithful than a normalizing parser), plus a LazyHTML structural check
  (lazy_html is already the LV 1.1.28 test parser; Floki is NOT a dep —
  never add it) that `.bp-paper-surface.bp-chat-md > :first-child` exists
  and is a block element the margin rule targets. HONEST CEILING accepted:
  computed margin-top is unobservable without a browser (stylesheet rule +
  static HTML) — the margin half is rule-presence + structural assertion,
  documented as such; NO headless-browser harness this wave. Matrix = row
  type × the shapes that row actually renders (never a forced cartesian):
  ❯ user (plain/multiline/wrapped/long-word), ● assistant paper-html
  (heading-first/paragraph/multiline), ● tool + ⎿ output (long label wrap,
  multiline pre), ✻ thinking, todo card, agent block (header + running
  line + report), plan card body, queued badge row — all driven by
  enable_fake_chat + send_frame fixtures through the REAL Recorder
  (chat_live_test.exs:55/131 machinery). OUT of scope: #1831 (morphdom
  class, not geometry), the assistant plain-fallback cell (unreachable
  without a render crash), streaming delta chrome (stretch only). Bugs
  found are filed as fixes in the owning slice's region or tiny standalone
  commits — never template rewrites inside this slice.

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

## Wave 6 plan (decided 2026-07-09) — "when the agent asks, the product answers"

Waves 1–5 made sessions durable, honest, server-owned, and alive. Wave 6 takes
the two moments the agent needs the human — AskUserQuestion and ExitPlanMode
(which EVERY session hits; plan mode is the default) — from a generic
Allow/Deny lie to the best-rendered surfaces in the chat, then gives the
composer its power features. Three slices, integration order **S1 → S2 → S3**.

| # | Slice (bp task) | Owns | Migration |
|---|---|---|---|
| S1 | `scc-w6-ask-ui` | roles-in-store router + needs-you widening + updatedInput answer seam + plan-mode stdio flag + question form card + resolution broadcast (D31/D32/D33/D35) | none |
| S2 | `scc-w6-plan-card` | the `"plan"` role's card ONLY: title helper, clamped PortableDoc preview, Approve/Keep-planning, observed mode-flip persist, plan replay (D34) | none |
| S3 | `scc-w6-composer-power` | initialize handshake capture + slash-menu combobox + sticky per-session drafts + sticky model default (D36) | `draft` column |

Region contract (chat_live.ex is hot — S1/S2 share the permission path, S3
stays out of it): **S1 owns** the `{:claude_chat_permission}` render router,
the `:question` card branch, replay/teardown/resolve widening for ALL new
roles (including `"plan"` in the role set and a minimal honest `"plan"`
fallback rendering), the resolution broadcast, and ALL studio_chat.ex +
recorder.ex + claude_chat.ex respond/build_args changes. **S2 owns** only the
`:plan` template branch + plan replay clause + expand toggle + approve/keep
events + the init-frame mode observation — it does NOT touch studio_chat.ex
role plumbing or claude_chat.ex. **S3 owns** the composer form region,
handle_params draft capture, load_stored_session/reset_to_new_chat seeds, the
initialize additions in claude_chat.ex (new public fn + control_kind clause —
disjoint from S1's respond_permission region), and the Recorder commands hold.
Builders build against main; the lead reconciles in S1 → S2 → S3 order.

## Wave 7 plan (decided 2026-07-09) — "the transcript IS the terminal"

Waves 1–6.5 built Claude Code's skeleton (sessions, honesty, server runtime,
asks, gutters, ⎿ results); wave 7 gives it the terminal's soul: every tool
call renders the way the CLI renders it, thinking breathes, the keyboard
drives, and the composer never locks. Five slices, integration order
**S1 → S2 → S3 → S4 → S5**.

| # | Slice (bp task) | Owns | Migration |
|---|---|---|---|
| S1 | `scc-w7-tool-diffs` | input/tool threading through BOTH render paths + shape-dispatch renderer module + Edit/Write colored diffs via Papers.TextDiff, collapsible, honest truncation (D38) | none |
| S2 | `scc-w7-todo-card` | TodoWrite living checklist card — Recorder per-turn collapse + `update_tool_input/3` + ChatLive supersede rule + shape-tolerant render + single-card replay (D39) | none |
| S3 | `scc-w7-agent-trace` | persist `parent_tool_use_id`, nested indented subagent trace live + replay, Task/Agent-tolerant labeling (D40) | none |
| S4 | `scc-w7-thinking-pulse` | ✻ thinking pulse off system/thinking_tokens + persisted `"thinking"` row for replay (D41) | none |
| S5 | `scc-w7-keyboard-steer` | global Esc → stop_turn + stopPropagation on the two consumers + unconditional footer hint + queue-honest mid-turn send (D42/D43) | none |

Region contract (chat_live.ex and recorder.ex are hot): **S1 owns** the tool
render clause (~1450), the replay tool clause (2465-2473), the live append
opts (730/2522-2530), and a NEW renderer module
(`BarkparkWeb.Studio.ChatToolRenderer`) that S2/S3 add functions to. **S2
owns** the Recorder's TodoWrite branch inside persist_assistant_blocks + turn
tracking in Recorder state, `StudioChat.update_tool_input/3`, and the ChatLive
assistant-reducer supersede rule + its checklist render fn. **S3 owns** the
parent_tool_use_id threading into persist_assistant_blocks metadata (additive
— S2 and S3 both touch that function; the lead reconciles in S2 → S3 order)
and the nesting render/replay. **S4 owns** new handle_info clauses above the
ChatLive catch-all (914), the Recorder's thinking accumulation + `"thinking"`
row persist, and its replay clause. **S5 owns** bp-chat-composer.js, the
footer region, and the send-gate region (chat_live.ex:232 + the D24 two-phase
path) — disjoint from S1–S4. Builders build against main in isolated
worktrees; the lead integrates in order and resolves recorder.ex overlaps.

## Wave 8 plan (decided 2026-07-09) — "cockpit and crew"

Waves 1–7 built the terminal's soul; wave 8 makes the composer the single
place you drive from and turns agent spawns into living, inspectable crew.
Three slices. Integration order **S2 → S3 → S1** (S1 is region-disjoint and
can land in parallel; S3 builds against S2's metadata-key contract —
`task_id`/`task_status`/`task_progress` — with fixtures, no merge dependency
for building).

| # | Slice (bp task) | Owns | Migration |
|---|---|---|---|
| S1 | `scc-w8-composer` | header slim + composer footer row (borderless mode/model + fact suffix, mini ring, attach label-button, Send/Stop) + `context_ring` size/show_cost variants + teaching placeholder + cost/hint relocation + test migration (D44) | none |
| S2 | `scc-w8-agent-lifecycle` | Recorder task_* clauses + session-lifetime task_index + `merge_tool_metadata/3` + coarse persist + `interrupt_running_tasks/1` in session_exited (D45) | none |
| S3 | `scc-w8-agent-block` | render-time bucket grouping + expandable agent block (running/completed states) + per-tab agent_expanded + ChatLive task_* handle_info merges + replay hydration (D46) | none |

Region contract (chat_live.ex is hot — THREE-way split): **S1 owns** the
header row (~1463-1512), the composer form region (~1843-1973),
`composer_placeholder/1`, and the `context_ring` component — it does NOT
touch the :tool branch, handle_info clauses, or replay. **S2 owns**
recorder.ex + studio_chat.ex ONLY (no chat_live.ex at all). **S3 owns** the
transcript comprehension + :tool template branch, chat_tool_renderer.ex, the
new task_* handle_info clauses above the catch-all (~1055), the role-"tool"
replay_message clause (~2718-2728), and the agent_expanded assign. The
immovable client contract (D44) binds S1; the replay-parity law (persisted
row IS the truth) binds S2/S3. Two hotfixes landed mid-wave and are LAW at
integration: #1831 (`phx-update="ignore"` on #chat-slash-menu) and #1844
(pre-wrap tight text nodes + tool-row hanging indent) — their regression
tests must stay green untouched.

## Wave 9 plan (decided 2026-07-09) — "mission control"

Waves 1–8 built the cockpit; wave 9 makes it mission control: you LAUNCH and
WATCH multi-agent work from the chat (the rail), the settings stop lying
(real modes, ceremonial bypass, effort), approved plans graduate into real
Papers, and the alignment-bug class dies under a rendered-HTML matrix. Four
slices, buildable in parallel; the rail gets the strongest builder.

| # | Slice (bp task) | Owns | Migration |
|---|---|---|---|
| S1 | `scc-w9-agents-rail` | rail region below the composer + Recorder background_tasks_changed/workflow_progress capture + `rail_snapshot` persistence + replay hydration + interrupt flip (D47) | `rail_snapshot` jsonb |
| S2 | `scc-w9-settings-surface` | real six-mode list + legacy-default handling + bypass arm ceremony + `bypass_armed` threading + effort_choice end-to-end + composer-footer model·effort group (D48) | `effort_choice` string |
| S3 | `scc-w9-plan-papers` | `PlanPapers` seam module + `merge_approval_metadata/3` + resolve_permission :plan hook + plan-card link + replay (D49) | none |
| S4 | `scc-w9-gutter-matrix` | rendered-HTML geometry matrix + flush-text helper + `data-gutter-text` attribute-only hooks (D50) | none |

Region contract (chat_live.ex is hot — FOUR-way split): **S1 owns** a NEW
rail region directly below the composer block, its new handle_info clauses
above the catch-all (~1245 after #1863/#1878 drift), rail replay hydration, recorder.ex task-clause
extensions + the new background_tasks_changed clause, and the rail side of
studio_chat.ex (`rail_snapshot` persistence fns + the interrupt_running_tasks
extension). **S2 owns** the composer-footer form cluster (~2138-2218), the
arm-panel UI, mode/effort labels, claude_chat.ex (@modes, normalize_mode,
build_args, effort_args, session_opts), session.ex (@modes + effort_choice
field), studio_chat.ex set_mode/set_effort_choice/recent_effort_choice, and
the recorder session_opts line (~110-119, one-key addition — lead reconciles
with S1's recorder work). **S3 owns** the `:plan` template branch + plan
replay clause + resolve_permission's :plan hook + the new PlanPapers module +
`merge_approval_metadata/3` in studio_chat.ex (disjoint function from S1/S2's
studio_chat regions). **S4 owns** tests + attribute-only `data-gutter-text`
additions to message_body/agent_block/live-chrome text nodes — NOT the :plan
branch (S3), NOT the composer footer (S2), NOT the rail (S1). Builders build
against main in isolated worktrees; the lead integrates S1 → S2 → S3 → S4 and
reconciles the recorder.ex and studio_chat.ex touch points.

## Gates

- Elixir: `mix test test/barkpark_web/live/studio/chat_live_test.exs test/barkpark_web/studio/claude_chat_test.exs test/barkpark/portable_doc/from_markdown_test.exs`
  (worktree recipe: `ln -sfn $MAIN/api/deps deps && mkdir -p _build && cp -R $MAIN/api/_build/test _build/test` — verified working in the gui-premium epic; the `mkdir -p _build` is REQUIRED on a fresh worktree or the cp dies)
- Wave-9 pinned five-file chat suite (374 tests, 0 failures baseline on main 1da4ea5d, 3 seeds 37/74/111):
  `mix test test/barkpark_web/live/studio/chat_live_test.exs test/barkpark_web/studio/claude_chat_test.exs test/barkpark/studio_chat_test.exs test/barkpark/studio_chat/recorder_test.exs test/barkpark/studio_chat/titles_test.exs`
- Studio chrome: `bash scripts/studio-literal-check.sh` (no color literals)
- Real-binary E2E harnesses exist in the session scratchpad (not committed) —
  builders may replicate the pattern for new features.

## Wave log

- **2026-07-09 wave 9 CRASH RECOVERY** (host crash ~18:20 killed all four
  epic-builder processes; the bp ledger survived intact): this is a
  RESURRECTION, not a re-decision — D47–D50, the four-way region contract and
  the S1→S2→S3→S4 integration order all stand; the four published briefs were
  re-perfected in place (append-only amendments, re-published), NOT re-filed.
  What the recovery established: (1) all four tasks still `in_progress` at
  epoch 1 under the dead `epic-builder-w9-s*` workers — builders re-claim with
  the EXACT worker string from `claim.worker` (same-worker renewal passes the
  fence, bumps the epoch; read the new epoch from `doc.claim.epoch`, never
  hard-code 2); because the briefs were amended AFTER the original claims, the
  digest close-fence WILL 409 `doc_changed_since_claim` — resolve per the verb
  contract: re-read, close with `--set observed_rev=<rev>`. (2) The lone
  recoverable debris is S3's: rescue branch `rescue/scc-w9-plan-papers-partial`
  (ceb06778, parented on main HEAD 1da4ea5d) carries a faithful-to-D49
  `plan_papers.ex` + `StudioChat.merge_approval_metadata/3` + one alias line —
  ADOPTED as S3's starting commit (builder branches a fresh worktree FROM
  ceb06778; the rescue branch itself sits in a locked worktree and cannot be
  checked out twice); remaining S3 work = the resolve_permission :plan hook,
  {:plan_paper,…} broadcast/handle_info, card link, replay threading, and the
  ENTIRE test suite (branch has zero tests, was never compiled). S1/S2/S4 left
  zero debris — clean starts from main. (3) Anchor drift under
  #1863/#1868/#1878/#1849 corrected in the briefs: chat_live handle_info
  catch-all 1145→1245 (the dangerous one), recorder merge_tool_metadata
  494-499→def studio_chat.ex:469 + call recorder.ex:650-651, task_index
  helpers →662-683, agent_expanded is a DOUBLED reset site (2533 AND 2607),
  build_args →104, S4's gutter region extends to 1631 (the #1849 first-child
  CSS rule lives at 1629-1631), chat suite path gains the `/studio/` segment.
  (4) Gate pinned: the wave-9 five-file suite (chat_live + claude_chat +
  studio_chat + recorder + titles) = 374 tests, 0 failures baseline proven on
  main in a throwaway worktree; recipe needs `mkdir -p _build`; 3 seeds
  37/74/111; studio-literal-check + warnings-as-errors unchanged. No w9
  fragment pre-landed on main (rail_snapshot / effort_choice / bypass_armed /
  PlanPapers / data-gutter-text all grep-clean) — every slice is genuinely
  unbuilt.

- **2026-07-09 wave 9 DECIDED** (post-merge of waves 1–8 + hotfixes #1831
  #1844 #1849 #1863): four slices filed as scc-w9-agents-rail /
  scc-w9-settings-surface / scc-w9-plan-papers / scc-w9-gutter-matrix under
  epic `studio-claude-chat` (D47–D50 above). Explorer corrections folded in:
  (1) the rail keys on `task_id`, NOT the D45 tool_use_id spawn row —
  background_tasks_changed carries no tool_use_id and is a snapshot; persist
  = new `chat_sessions.rail_snapshot` jsonb (merge-onto-spawn-row and
  role:"rail" message both provably wrong); (2) `--permission-mode default`
  is SILENTLY ACCEPTED by the real binary (echoed verbatim) — settings is an
  alignment, not a panic fix; no data migration, legacy option renders only
  while carried; (3) two tests INVERT when the mode list grows
  (studio_chat_test.exs:309-315 uses bypassPermissions as its invalid
  example; claude_chat_test.exs:97 pins normalize_mode fail-closed — the
  latter STAYS as law, bypass arming lives OUTSIDE normalize_mode via
  session_opts.bypass_armed read from the persisted row only); (4) no
  set_effort control verb exists — effort is spawn-time `--effort`,
  mid-session change honestly says next-resume; (5) plans-as-papers is small
  but needs ONE new seam: a request_id-keyed metadata merge
  (merge_tool_metadata and update_approval_status both provably don't fit);
  upsert_paper publishes unconditionally into the same Default tenant
  /papers/:slug reads — deterministic sha-slug makes re-approve idempotent;
  (6) the first-block-margin half of the QA helper is UNOBSERVABLE from
  render(view) (stylesheet rule, no CSSOM) — scoped honestly to
  rule-presence + structural first-child; the flush-text half asserts raw
  serialized bytes; a tiny data-gutter-text hook is the one markup edit the
  tests-only slice may make.

- **2026-07-09 wave 8 DECIDED** (post-merge of waves 1–7 + hotfixes #1831
  #1844): three slices filed as scc-w8-composer / scc-w8-agent-lifecycle /
  scc-w8-agent-block under epic `studio-claude-chat` (D44–D46 above).
  Explorer corrections folded in, wire capture verified
  (scratchpad/wirecap/wire_task.ndjson, real foreground Agent spawn):
  (1) "textarea on top" CUT — the composer input stays `<input type=text>`
  (D24 value-selector tests + hook Enter semantics pin it); (2) TWO
  observed-model spans exist — the header one is deleted, the
  picker-adjacent one moves as the fact suffix; (3) context_ring has a
  built-in cost span that would double-render in the footer — `show_cost`
  variant suppresses it; (4) the task frames already reach the Recorder AND
  are already rebroadcast verbatim (catch-all) — the build is persistence +
  consumers, not wire plumbing; (5) update_tool_input REPLACES
  metadata.input and would clobber the spawn's input — a merge sibling is
  required; (6) only task_updated lacks tool_use_id — correlation map is
  session-lifetime (NEVER under the per-turn init reset; background agents
  outlive turns), completion drives primarily off task_notification;
  (7) stale-running teardown (interrupt_running_tasks in session_exited)
  ships WITH the lifecycle slice or crashed sessions replay fake spinners;
  (8) grouping must key on parent_tool_use_id ID MATCH — parallel spawns'
  children interleave in seq order, consecutive chunking misattributes.

### Wave 2026-07-09 (wave 9 BUILT + REVIEWED — mission control, crash-recovery rebuild)

All four resurrected slices rebuilt green and reviewed at the Kinsta/Vercel
bar; nothing stalled. Reviewer fixes, in place: **S2** (a) the two builders
had filed migrations under the SAME version `20260709210000` (rail_snapshot
vs effort_choice — Ecto rejects duplicate versions on a fresh DB; the shared
test DB masked it) — effort_choice renumbered to `20260709211000` on the
`-r` branch and proven to apply cleanly; (b) the bypass arm panel's form had
`phx-change` but no `phx-submit`, so Enter in the confirm input fell through
to a NATIVE form submit (navigates the LiveView away) — `phx-submit` added
riding the same server-side exact-word guard, protective test added. **S3**:
a RAISE inside `PlanPapers.publish` crashed the fire-and-forget Task
silently and the promised `{:plan_paper_failed}` honest line never appeared —
rescue scoped to the publish call only (a raise after a successful publish
can never lie). S1/S4 needed no fixes. Ledger: S2's criterion-4 evidence
re-stamped with the renumbered migration; all four tasks verified
`in_progress` at epoch 2 under the exact resurrected worker names, 7/8
(S4: 6/7) criteria met with evidence, only "PR merged" open for the lead.
Integration DRY-RUN onto origin/main (6d075683) in S1 → S2-r → S3-r → S4-r
order: ONE trivial conflict (S1's `interrupt_rail_entries` and S3's
`merge_approval_metadata` both insert before `find_approval` in
studio_chat.ex — resolution: keep both); combined six-file suite on the
integrated state **453 tests, 0 failures** across seeds 37/74/111,
`--warnings-as-errors` clean, studio-literal-check PASS. Merge the **`-r`
branches for S2/S3**, the **originals for S1/S4**. This charter copy rides
the S2 `-r` branch (the wave-9 recovery + decide entries were still
uncommitted in the main checkout — wave-8 precedent). Known honest ceilings
for the NEXT wave (builder-flagged, none blocking): the `workflow_progress`
wire shape is built to the t3-patterns FLAT-list spec but UNPROVEN on a real
binary (a nested `children` tree would neither render nor trip the
change-only guard); the D34 post-plan `permissionMode: "default"` assumption
is unverified against the six-mode CLI; `--effort` acceptance is
allowlist-proven but not binary-proven; a reopened armed-bypass session
re-arms on the next spawn with no re-ceremony (persisted mode IS the arming
record — deliberate, worth a product look); rail token counts lag until the
next structural change (per D47); a `background_tasks_changed` snapshot also
flips rail entries that only ever arrived via `task_progress` (e.g. a
foreground workflow) to "completed" — spec-ambiguous, revisit with real wire
capture; recorder_test idle-reaper flake filed as task-c0cbe467eb44c161.

### Wave 2026-07-09 (wave 8 BUILT + REVIEWED — cockpit and crew)

All three slices built green and reviewed at the Kinsta/Vercel bar; nothing
stalled. The branches are INDEPENDENT (no chain); the reviewer dry-ran the
full three-way merge onto current origin/main (#1849 included) — clean in
S1 → S2 → S3 order — and ran the combined suite on the integrated state:
**225 tests 0 failures** (recorder 46 + chat_live 179),
`mix compile --warnings-as-errors` clean, studio-literal-check PASS. Merge
the **`-r` branches** (`…-composer-cockpit-…-0-r`, `…-agent-lifecycle-…-1-r`,
`…-agent-drill-down-…-2-r`); plan order S2 → S3 → S1 works, but any order is
conflict-free. This charter copy rides the agent-lifecycle `-r` branch — the
wave-8 Decide content was still uncommitted in the main checkout; merging
commits it.

- **Landed**: composer cockpit (S1/D44) — slim header (title + status),
  borderless mode/model selects in the composer footer with the dim-mono
  observed-model fact suffix, `:sm` context ring (pct-label tests migrated
  to arc-dasharray geometry proofs), image-attach `<label>` button, Send/Stop
  right cluster, teaching placeholder ("Plan, build… / for commands"), hint
  line unconditional, cost single-rendered (show_cost=false on the footer
  ring). Agent lifecycle persisted (S2/D45) — `merge_tool_metadata/3`
  merge-not-clobber seam, four Recorder task_* clauses above the catch-all
  with verbatim rebroadcast, SESSION-LIFETIME task_index (proven across a
  turn boundary), coarse progress persist (SENTINEL-poison proof),
  `interrupt_running_tasks/1` teardown flip on every death path. Agent
  drill-down (S3/D46) — ID-match bucket grouping (parallel-spawn interleave
  test), expandable agent block with breathing "Running: …" line + step
  count, per-tab `agent_expanded` override (toggle wins across the
  running→completed transition), value-equality-guarded live merges, replay
  hydration incl. interrupted-shows-no-spinner.
- **ONE ratified deviation from D44**: the footer row is a SIBLING of
  `form#chat-composer-form`, NOT a child — nested `<form>`s are invalid HTML
  (the parser drops the inner mode/model forms; the builder proved it with a
  failing run, and D44 also demands the form wrappers survive — the two
  demands are jointly unsatisfiable as written). Send re-associates via
  `form="chat-composer-form"`; visually identical, submit/interrupt semantics
  unchanged. Treat the sibling + form-attribute shape as the amended D44.
- **Reviewer fixes (on the -r branches)**: S1 — aria-label on the icon-only
  Send button + a guard test pinning `label[for]` == the id LiveView renders
  on live_file_input (the flagged LV-convention blind spot: an LV upgrade
  changing the id now fails a test instead of shipping a dead attach
  button). S2 — new refute test that task_* frames never publish to the
  activity topic (criterion 5 was code-verified only) + `mix format` over
  the new test block. S3 — fixed a REAL crash: a stale `agent-toggle`
  (session switched under an in-flight click) found no spawn row and raised
  ArgumentError on `not nil`, killing the LiveView; guarded no-op +
  regression test.
- **Accepted edges (documented, not bugs)**: a late task_progress after a
  terminal status would flip a LIVE block back to running (ordered stream
  makes it theoretical; store-side unaffected); S3's live task_notification
  defaults a missing status to "completed" while S2 persists only binary
  statuses (off-contract frame either way); the ⎿ report markup is
  duplicated between message_body's :tool branch and agent_block
  (extraction candidate, not blocking).
- **Ledger**: the builders' leases expired at 17:11 and lifecycle reverted
  to `open` (a lie to `bp task ready` — a fresh builder could re-claim
  finished work); the reviewer re-claimed all three as `epic-reviewer-w8`
  (epoch 3) to restore `in_progress`. On merge the lead closes criterion
  "PR merged" on scc-w8-composer (idx 8), scc-w8-agent-lifecycle (idx 7),
  scc-w8-agent-block (idx 7) — re-claim for a fresh epoch if lapsed.
- **Next wave**: the WISH is now fully covered (composer consolidation +
  agent drill-down both shipped, live + replay). Take: (1) a real-browser
  drive of the cockpit — label-for native picker, borderless hover
  affordance, and the drill-down under a real spawning session (code-correct
  + test-covered, never visually confirmed); (2) a two-tab task_*
  convergence test through a REAL Recorder (both suites use identical
  fixture shapes but no integrated wiring test exists); (3) extract the
  shared ⎿ report component; (4) a textarea/auto-grow composer as its own
  decision (D44 cut it deliberately, not forever).

### Wave 2026-07-09 (wave 7 BUILT + REVIEWED — the transcript IS the terminal)

All five slices built green and reviewed at the Kinsta/Vercel bar; nothing
stalled. The reviewer serialized the wave into ONE integration chain — each
`-r` branch contains everything before it — so the lead merges
**`loop-epic/keyboard-first-esc-interrupts-from-anywh-4-r`** (chain head:
S1-r → S2-r → S3-r → S4-r → S5-r, integration order per the plan) and gets
the whole wave. Combined gate on the chain head: **349 tests 0 failures**
across the five-file suite (5 consecutive green runs incl. seeds 37/74/111;
one unreproduced flake in the very first combined run — the suite's known
capture-file/timing flake class, never seen again), studio-literal-check
PASS, `mix compile --warnings-as-errors` clean. `git merge-tree` proves the
chain head merges CLEAN onto current origin/main (#1772). This charter copy
on the chain head carries the wave-7 Decide content that was still
uncommitted in the main checkout — merging the chain commits it.

- **Landed**: Edit/Write/MultiEdit render as real colored line diffs —
  input+tool threaded through BOTH render paths, shape-dispatch renderer
  (`ChatToolRenderer.classify/1`, never tool names), TextDiff reuse (no
  second engine, grep-guarded by a test), `--ok/--danger` token chrome,
  collapse >20 lines behind details with an honest "+N more lines", replay
  parity proven (S1/D38); TodoWrite as ONE living ☐/◐/☒ checklist card —
  Recorder-owned collapse (`update_tool_input/3`, per-turn first-id
  tracking, init reset), ChatLive in-memory supersede, shape-tolerant
  modern+legacy items, single-card replay (S2/D39); Task/Agent spawns as
  nested traces — `parent_tool_use_id` stamped on every Recorder row,
  ● spawn headline with description prominent, children indented behind an
  evergreen gutter live AND on replay (S3/D40); ✻ thinking pulse — live
  "thinking… ~N tokens" off system/thinking_tokens (cumulative max, never
  delta sums), settles to a durable "thought for ~N tokens" row, Recorder
  flushes a `"thinking"` row BEFORE the turn's blocks, signature never
  stored, forward-compat text path (S4/D41); keyboard-first — document-level
  Esc → stop_turn (strict no-op when idle), stopPropagation on the slash
  menu, rename input skipped by data attribute, unconditional footer hint
  "esc interrupt · / commands · ↵ send", and the silent mid-turn drop-gate
  DELETED: mid-turn sends queue honestly ("⧗ queued" badge, immediate wire
  write + persist with metadata.queued, badge clears on the next init,
  plain ❯ on replay) (S5/D42+D43).
- **Reviewer fixes worth knowing**: (1) THREE slices created
  `BarkparkWeb.Studio.ChatToolRenderer` (S2 even at a different path —
  would have been a silent duplicate-module compile break); unioned into ONE
  module at `live/studio/chat_tool_renderer.ex` (diff + todo + spawn
  sections). (2) The tool_use reducer and `persist_assistant_blocks` are a
  three-way union: todo-supersede × D38 input threading × D40 parent/spawn
  opts — reconciled in both ChatLive and Recorder (arity /3 with state
  threading). (3) NEW cross-slice rule the merge surfaced: a SUB-AGENT's
  TodoWrite must not hijack the main turn's living card — collapse only
  top-level TodoWrites; a child-frame todo persists as a plain indented tool
  row (guard test added, D39×D40). (4) Diff-shaped ● headers now show only
  `Tool — path` (both tool_line copies, ChatLive + Recorder) — the old
  header dumped old_string/new_string previews that duplicated the diff
  right below. (5) The per-turn init reset now covers todo_card_id +
  pending_thinking + queued badges in one place.
- **Known seams (reviewed, deliberate, not blockers)**: (a) the exact
  `estimated_tokens` wire field/nesting is charter-sourced, not
  fixture-proven on this host — a wrong guess degrades to an honest 0-token
  absence, never a crash; real-binary spot-check recommended; (b) MultiEdit
  is defensively handled, unverified on this host's binary; (c) the JS
  document-Esc hook is read-verified + server-contract tested only
  (LiveViewTest can't drive hooks) — a manual browser pass pre-ship is
  called out in the S5 evidence; (d) one LV test pins the literal gutter
  style `border-left: 2px solid var(--primary)` — brittle if a later
  aesthetic pass moves it to a class; (e) diff-shaped rows recompute the DP
  diff per render (capped, bounded transcripts — memoize only if long
  sessions hurt); (f) a queued badge can linger cosmetically if a session
  dies before its next init (replay drops it).
- **Ledger**: all five tasks were richly evidence-stamped by the builders
  but their claims had EXPIRED, flipping lifecycle back to `open` — the
  ledger read "available work" for built slices. Re-claimed all five under
  `epic-reviewer-w7` (epoch 3, in_progress). The lead closes each on merge
  (the one unmet criterion per task is "PR merged"; close with worker
  epic-reviewer-w7 / epoch 3).
- **Next wave should take**: (1) real-binary spot-checks — thinking_tokens
  field shape, MultiEdit input shape, a real Task spawn trace end-to-end;
  (2) a real-browser pass — global Esc (slash-menu precedence, rename skip),
  details expand on diffs, the queued badge under a genuinely running turn;
  (3) surface diff STATS on the collapsed header row (t3 shows "+12 −3" in
  the summary line — ours shows it above the hunk); (4) wave-6 leftovers
  still open: chosen answers on the terminal question card, /compact //clear
  pinning spot-check, per-model cost hints; (5) consider memoizing tool
  diffs for very long transcripts.

- **2026-07-09 wave 7 DECIDED** (post-merge of waves 1–6.5: #1681 #1693 #1702
  #1708 #1712 #1741 #1746): five slices filed as scc-w7-tool-diffs /
  scc-w7-todo-card / scc-w7-agent-trace / scc-w7-thinking-pulse /
  scc-w7-keyboard-steer under epic `studio-claude-chat` (D38–D43 above).
  Explorer corrections folded in, probed on the real binary v2.1.205:
  (1) "input is already plumbed" was HALF-true — persisted verbatim but
  dropped by BOTH render paths; threading it is S1's foundation. (2) Tool
  names are host-dependent (cmux emits `Agent` for `Task`, lacks
  TodoWrite/MultiEdit) — dispatch on input shape. (3) A second Myers differ
  is a capability-dup: reuse Papers.TextDiff.diff_lines. (4) The Task nested
  trace needs NEW persistence (parent_tool_use_id is discarded today).
  (5) Thinking TEXT never reaches the wire (empty across models, encrypted
  signature) — the collapsible snippet is CUT; the ✻ pulse rides
  system/thinking_tokens. (6) Steering probe: the binary QUEUES a mid-turn
  frame and runs it as the next turn — steer-into-turn is disqualified;
  build "⧗ queued" honestly. (7) A global Esc double-fires through the slash
  menu and rename (neither stops propagation) — stopPropagation lands on the
  consumers, not guard-soup in the global handler.

### Wave 2026-07-09 (wave 6 BUILT + REVIEWED — when the agent asks, the product answers)

All three slices built green and reviewed at the Kinsta/Vercel bar; nothing
stalled. The reviewer serialized the wave into ONE integration chain — each
`-r` branch contains everything before it — so the lead merges
**`loop-epic/w6-s3-composer-power-slash-menu-off-the--2-r`** (chain head:
S1-r → S2-r → S3-r, integration order per the plan) and gets the whole wave.
Combined gate on the chain head: **300 tests 0 failures** across the five-file
suite (seeds default/42/99999), studio-literal-check PASS,
`mix compile --warnings-as-errors` clean. Main moved during the wave
(#1733/#1734 theme work) — ZERO overlap with the chat files, the chain merges
cleanly onto new main. S3 carries migration `20260709203417` (nullable `draft`
column on chat_sessions). This charter copy on the chain head carries the
wave-6 Decide content that was still uncommitted in the main checkout —
merging the chain commits it.

- **Landed**: the agent-asks/human-answers path end-to-end — respond_permission
  widened to `:allow | {:allow, updated_input} | {:deny, msg}` with plain allow
  ALWAYS echoing the tracked ask input as updatedInput (D32), the stdio
  permission bridge in ALL modes incl. plan (D33), roles-in-store router
  (question/plan/approval) + the ONE needs-you role set threaded through
  pill/cancel/find/teardown/replay (D31), a real AskUserQuestion form (chips
  with descriptions, multiSelect toggle, custom answer, N/M progress, one
  submit keyed by question string, comma-joined multiSelect), and D35
  resolution broadcasts converging co-viewing tabs (S1); the rich
  proposed-plan card — first-heading title, FULL plan through the paper engine
  clamped by CSS with a token fade, per-tab expand, Approve = allow-echo /
  Keep planning = the exact D34 deny string, observed-init mode-flip persist,
  plan replay in terminal/pending states (S2); composer power — initialize
  handshake held in the Recorder with init-names fallback + builtins floor,
  ARIA slash combobox (server-stamped vocab, native-input-event insert per
  D24), builtins /plan · /default · /model routed server-side on submit,
  sticky per-session drafts (switch-away capture, full-struct restore,
  clear-on-send), sticky model default via a dedicated query (S3).
- **Reviewer fixes worth knowing**: (1) S2's standalone `resolve_plan` was
  replaced by routing plan-approve/plan-keep through S1's ONE resolve seam —
  plan resolutions now broadcast to co-viewing tabs too (S2 built against bare
  main and could not); S1's minimal plan fallback card deleted in favor of
  S2's rich card (one `plan_outcome_label`, "✗ kept planning"). (2) S1's
  declared blind spot closed: an end-to-end LV wire test (tee-captured stdin)
  proves the multiSelect answer reaches the wire comma-joined, keyed by the
  question string. (3) Question replay honesty tests added — answered row
  reopens as the terminal line, dangling pending reopens "✗ canceled", never a
  dead form. (4) `/model <typo>` no longer silently resets the sticky choice
  to the CLI default — unknown alias shows usage; explicit `/model default`
  resets (tests added). (5) Latent capture-file flake hardened (wait ceiling
  3s → 8s; it fired once under full-suite load).
- **Known seams (reviewed, deliberate, not blockers)**: (a) the
  dismissed-question deny surfacing as an is_error tool_result is
  code-evidenced, not re-proven on the real binary; (b) the JS combobox
  keyboard nav (ArrowUp/Down/aria-activedescendant/insert) is verified by
  reading + server-contract tests only — LiveViewTest cannot drive hooks;
  (c) /compact · /clear ride as plain user text with the D8 pinning assumption
  marked, unverified on the real binary; (d) the D35 broadcast carries
  {request_id, status} without the answers payload — nothing renders answers
  post-resolution today, deviation accepted; (e) a replayed pending question
  under a live owner re-seeds a BLANK form (accepted D22 gap).
- **Next wave should take**: (1) real-binary spot-checks — dismiss-deny
  is_error surfacing, /compact · /clear session pinning, initialize commands
  shape on the current CLI; (2) a real-browser pass over the slash combobox,
  question chips, and the plan clamp/fade; (3) surface the CHOSEN answers on
  the terminal question card (today just "✓ answered" — t3 shows the values);
  (4) theme the new cards under the [data-bp-theme] blocks that landed
  mid-wave (#1734); (5) wave-5 leftovers: turn elapsed-time on working cards,
  activity in the tab title, per-model cost hints in the picker.

- **2026-07-09 wave 6 DECIDED** (post-merge of waves 1–5: #1681 #1693 #1702
  #1708 #1712; scc-w1..w5 closed): three slices filed as scc-w6-ask-ui /
  scc-w6-plan-card / scc-w6-composer-power under epic `studio-claude-chat`
  (D31–D36 above). Explorer corrections folded in, all proven on the real
  binary v2.1.205: (1) bare `{"behavior":"allow"}` FAILS ExitPlanMode — every
  allow must echo updatedInput (D32 upgrades this from "polish" to
  prerequisite); (2) plan mode omits `--permission-prompt-tool stdio`, so
  ExitPlanMode asks never reached us — the flag now ships in all modes (D33);
  (3) the CLI flips its own mode on plan-approve; the flip is visible ONLY on
  the next system/init permissionMode, never the result frame (D34); (4)
  question answers ride `updatedInput.answers` keyed by the question STRING,
  multiSelect comma-joined (D32); (5) initialize returns the rich command list
  at spawn with no capabilities payload, and permission routing is the stdio
  flag, not the handshake (D36); (6) 13 downstream sites assume
  role=="approval" — the needs-you role set widens them all in one slice or
  the sidebar pill/cancel/replay lie for questions (D31); (7) resolve does not
  broadcast — co-viewing tabs keep a stale open form without D35.

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

### Wave 2026-07-09 (wave 6.5 — terminal anatomy, LEAD-BUILT inline)

**D37 — The transcript imitates the Claude Code terminal.** User mandate:
"Please imitate this in our Chat" (after the ASCII anatomy walk-through).
Gutter vocabulary: `❯` user prompts (left-aligned, no bubble), `●` assistant
prose, `● Tool(args)` mono tool rows, `✻` system lines. NEW capability under
the aesthetic: tool RESULTS are now captured — the CLI reports them as
user-frame tool_result blocks keyed by tool_use_id (wire-proven with a live
probe); the Recorder attaches each output to its persisted tool row
(metadata.output, 4KB cap) and rebroadcasts, ChatLive updates the in-memory
row, and replay reads it back — so `⎿ first-line-of-output` renders live AND
on reopen, with multiline outputs collapsed behind details ("+N lines", full
pre on expand). Turn spinner: evergreen arc + `working… Ns · Stop to
interrupt` driven by a self-ticking 1s clock that disarms when the turn ends.
Footer status strip goes mono: `<mode> ⏵ <model> · <duration> · $<cost>`.

Gate: 307 tests × 3 seeds; studio-literal-check PASS; warnings-as-errors
clean. Unknown tool_use_id results are safe noops (echoed test-fake frames
never match).

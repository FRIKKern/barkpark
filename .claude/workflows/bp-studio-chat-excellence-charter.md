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

## Gates

- Elixir: `mix test test/barkpark_web/live/studio/chat_live_test.exs test/barkpark_web/studio/claude_chat_test.exs test/barkpark/portable_doc/from_markdown_test.exs`
  (worktree recipe: `ln -sfn $MAIN/api/deps deps && cp -R $MAIN/api/_build/test _build/test` — verified working in the gui-premium epic)
- Studio chrome: `bash scripts/studio-literal-check.sh` (no color literals)
- Real-binary E2E harnesses exist in the session scratchpad (not committed) —
  builders may replicate the pattern for new features.

## Wave log

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

- **2026-07-09 wave 1 DECIDED**: store = Ecto pair (doc route disqualified —
  private-schema query gate is any-token, query_controller.ex:375); resume =
  minted-uuid PK + lazy `--resume` (proven in stream-json mode); interrupt =
  raw-wire control frame (proven; discriminate via terminal_reason); mode switch
  via `set_permission_mode` key `mode` (respawn path removed); title = layered
  Judge-API → claude-p-haiku → derived, clobber-guarded. Slices scc-w1-store,
  scc-w1-wire-seam, scc-w1-sessions-ui, scc-w1-honest-turns, scc-w1-ai-title
  filed under epic `studio-claude-chat`.

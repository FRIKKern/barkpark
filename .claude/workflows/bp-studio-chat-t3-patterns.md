# t3code pattern inventory — mined 2026-07-09 (source-verified, file:line refs into the t3code repo)

Reference document for the studio-chat-excellence epic. The reframe: t3code is not
"wrap a CLI stream" — it is an event-sourced engine where the CLI is a replaceable,
restartable actor whose only durable identity is a session_id pointer.

## Ranked build order for our Studio chat
1. **Resume** — mint the session UUID ourselves, launch with `--session-id <uuid>`;
   persist a cursor {session_id, last_assistant_uuid, turn_count}; display history
   comes from OUR store, model memory comes from `--resume <uuid>`. Guard: never
   capture session_id off system/hook_* frames.
2. **Long-lived streaming session** — one process across turns; subsequent user
   turns are stream-json {"type":"user",...} stdin frames, NOT respawns; a message
   sent mid-turn is a "steer" (same turn, no new boundary). setModel /
   setPermissionMode / interrupt are control-protocol frames on the live channel.
3. **Stop/interrupt** — two verbs: interrupt turn (control frame, session lives) vs
   stop session (teardown). "interrupted" is a first-class terminal turn state.
4. **Crash recovery** — on process death: fail the turn, force-cancel ALL pending
   approval cards (nothing hangs), mark session exited; do NOT auto-respawn. Lazy
   respawn on next user send via --resume from the persisted cursor. (Natural
   Elixir fit: Port :DOWN → GenServer.reply(from, :cancel) for pending approvals.)
5. **AI title on first turn** — one cheap fire-and-forget LLM call ("3-8 words,
   summarize the request, don't restate"); only replaces the title if it is still
   the default — a human rename is never clobbered.
6. **Checkpoints/rewind** — every turn = git commit on hidden ref
   refs/<ns>/checkpoints/<thread>/turn/<n> using a throwaway GIT_INDEX_FILE (user's
   index/HEAD untouched); revert = git restore --source <oid> + rollback the
   resume cursor N turns (memory + files rewind together).
7. **Usage/cost** — read usage/total_cost_usd/modelUsage off the result frame;
   context-headroom ring gauge (red >90%), dollars captured but not foregrounded.
8. **Model/mode mid-session** — control frames + carried on the next turn frame;
   no restart. Per-thread sticky drafts persisted diff-only on send.
9. **Sidebar** — recency = latest USER message; denormalized summary columns so
   the list renders without loading threads; priority status pills
   (PendingApproval > AwaitingInput > Working > PlanReady > Completed); unseen-
   completion dot keyed off lastVisitedAt.
10. **Queued messages** — there is NO send queue: send gates to Stop while
    running; optimistic echo before ack; failed sends restore the full composed
    input into the composer. Mid-turn second message = steer.
11. **Images** — base64 content blocks inlined in the stream-json user frame:
    {type:"image",source:{type:"base64",media_type,data}}.

## Load-bearing mechanics (exact, from source)
- Fresh session: mint UUID → SDK sessionId → `--session-id <uuid>`. Resume:
  cursor.resume → `--resume <id>`. Message-granular fork: resumeSessionAt =
  last assistant message uuid (captured from message.uuid on the wire).
- Durability guard: hasDurableClaudeSessionId returns false for system subtype
  hook_started|hook_progress|hook_response.
- Persistence: SQLite WAL, table provider_session_runtime(thread_id PK,
  status, last_seen_at, resume_cursor_json, runtime_payload_json). Cursor
  re-persisted after EVERY durable assistant message and every turn.
- Reopen read path: no live process → load persisted cursor → adapter starts
  `claude --resume <session_id>`; cwd rehydrated from runtime_payload_json.
- History display = replay of t3's OWN event log (projection tables,
  incremental fold checkpointed by last_applied_sequence) — never the CLI jsonl.
- Approvals: Deferred per request_id in a map; teardown force-resolves all to
  "cancel". AskUserQuestion surfaced as structured input regardless of mode;
  ExitPlanMode intercepted (capture plan, deny with "wait for feedback").
- Title prompt: "concise thread titles for coding conversations… summarize the
  user's request, not restate it… 3-8 words… no quotes/filler/prefixes" →
  JSON {title}, sanitized, cap ~50 chars, fallback "New thread".
- Idle reaper: 30-min idle sessions force-stopped (5-min sweep), cursor kept —
  resume makes this invisible to the user.

## Caveat
Do not lean on ~/.claude/projects/*.jsonl as the history store — t3 deliberately
does not. Our store owns display; the CLI owns model memory.

## UX pass 2 (2026-07-09, lead skim of apps/web/src — ranked for waves 6+)

1. **AskUserQuestion → real question UI** (`pendingUserInput.ts`): option chips +
   custom-answer field, multi-question progress (questionIndex/isLastQuestion/
   canAdvance), answered-count. Arrives on OUR wire as a can_use_tool
   control_request for tool AskUserQuestion (input carries the questions);
   today we render a generic Allow/Deny card. Highest-leverage gap.
2. **ExitPlanMode → proposed-plan card** (`proposedPlan.ts`): title from first
   markdown heading (proposedPlanTitle), strip leading heading/Summary
   (stripDisplayedPlanMarkdown), collapsed 8-line preview
   (buildCollapsedProposedPlanPreviewMarkdown) + expand; Approve / keep
   planning actions. t3 intercepts the ExitPlanMode can_use_tool: captures
   plan, DENIES with "wait for feedback", then the human decides. Plan mode is
   our default — we currently print plans as prose with a generic card.
3. **Slash commands**: composer `/` menu = builtins (/model /plan /default)
   merged with the CLI's OWN advertised commands from the initialize control
   response (we already receive that list — charter wave-1 wire notes).
4. **Sticky drafts + sticky model** (`composerDraftStore.ts`,
   DEFAULT_MODEL_BY_PROVIDER): per-thread composer drafts survive switching
   away (we clear); last model pick = default for new chats.
5. **@-file mentions** (`composer-editor-mentions.ts`): cwd path autocomplete,
   inserted as chips.
6. **Files-changed diff panel** (`diffPanelStore.ts`, `diffFileActions.ts`):
   per-turn diffs of what the agent touched. Memory-rewind stays CUT (D26);
   the file-side VIEW is viable alone.
7. **Keybindings** (`keybindings.ts`): Esc interrupt, thread-jump ⌘1-9,
   model-picker jump, focus-aware (terminalFocus/previewFocus guards).
8. **Command palette + unseen-completion dot**: fuzzy session search;
   dot keyed off lastVisitedAt for "finished while you were away".
9. **Steering**: a mid-turn send JOINS the running turn (same turnId) instead
   of being gated behind Stop.

Wave-6 recommended cut: #1 + #2 (agent-asks/human-answers surfaces), #3+#4 as
one composer slice. Wave-7: #6 diff panel (bold), #7+#8 polish, #9 steering.

## Wave-9 ground truth: Workflows-pane data sources (lead probe 2026-07-09)

Goal: a Studio "/workflows" pane tailing the host's run files. What's ACTUALLY on disk
under ~/.claude/projects/<proj>/<session>/subagents/workflows/wf_*/:
- `journal.jsonl` — ONLY {type:started, key, agentId} + {type:result, ...} per agent
  (it exists for resume caching). NO phases, NO labels, NO progress events.
- `agent-<id>.jsonl` — the agent's full transcript, GROWS LIVE while it works →
  live activity = tail the file: last assistant tool_use (name+input), message
  count, token usage from entries. This is the live signal.
- `agent-<id>.meta.json` — {agentType, spawnDepth} only.
- Phase titles / agent labels / narrator log() lines live in the HARNESS process,
  not on disk — a web pane can render runs + per-agent live activity + results,
  but NOT the phase grouping unless it infers from prompts (first line of the
  agent transcript carries the prompt, which our epic-cycle prompts prefix with
  role words like "You are an EXPLORER…"). Design for that honestly: group by
  inferred role or flat list, never fake phase boxes.
- Run liveness: dir mtime / any agent file written in the last N seconds.

## Wave-9 ground truth: settings surface + plans-as-Papers (lead probes 2026-07-09)

- `--effort <low|medium|high|xhigh|max>` EXISTS and works (verified: --effort high
  --model opus → OK). The composer's model control should become model+effort
  ("Fable · high") per the user's mock.
- `--permission-mode` REAL choices: acceptEdits, auto, bypassPermissions, manual,
  dontAsk, plan. NOTE: "default" (our current middle mode) is NOT in the CLI's
  list — audit what we actually pass today. bypassPermissions additionally
  requires --allow-dangerously-skip-permissions (arming flag); exposing it is
  consistent with the tmux-tab trust model (admin already has full shell), but
  it must be visually loud + explicitly armed, never a casual dropdown pick.
- set_permission_mode control frame (key 'mode') steers a LIVE session; whether
  the CLI accepts an effort control verb mid-session is UNPROBED — spawn-time
  --effort is the proven path.
- PLANS AS PAPERS: the chat lives inside the API app — on ExitPlanMode approve
  (or on ask), create a real Bulldocs Paper from input.plan markdown via the
  server-side document context (workspace/project/dataset scoping applies),
  persist the paper id/URL onto the plan row's metadata, link it from the plan
  card, and let the paper radiate to reader + TUI. Plans stop being chat
  ephemera and become first-class documents.

## Wave-9 ground truth #2: the agents rail is ALREADY ON THE WIRE (lead probe 2026-07-09)

User mandate: "I need it to work like the Claude Code TUI — see the agents below
the chat." A live Workflow run over our exact wire (--print stream-json) emits:
- `system/background_tasks_changed` {tasks: [{task_id, task_type
  (local_workflow/…), description}]} — THE rail rows, pushed on every change
  (appears on launch, empties on completion). This is the below-input agent
  list the TUI renders.
- `system/task_started` {task_id, tool_use_id, workflow_name, prompt, task_type}
- `system/task_progress` — the crown jewel: carries `workflow_progress` = the
  FULL phase/agent tree ({type: workflow_phase|workflow_agent, title/label,
  model, state, tokens…}) + usage {total_tokens, tool_uses, duration_ms} +
  description "P: <agent-label>" + last_tool_name. Emitted repeatedly — apply
  the wave-5 change-only discipline before broadcasting to sidebars.
- `system/task_updated` {patch:{status,end_time}} + `system/task_notification`
  {status, output_file, summary} on completion.
NO disk tailing required for live rendering (the earlier journal/transcript
notes remain valid for HISTORICAL runs the session didn't watch). The Recorder
already rebroadcasts these frames verbatim; ChatLive drops them today. Build:
persist the rail snapshot per session (replay parity), render the rail below
the composer (rows = background tasks; expand a workflow row = phase→agent
tree from the latest workflow_progress), co-viewing via the existing PubSub.
Headless gotcha: dynamic workflows hit a "Review dynamic workflow before
running" permission ask — our approval card already handles it (proven by the
user actually running one from the chat).

## Workflow + subagent VIEW (mined 2026-07-09)

Source-verified: fresh shallow clone of github.com/pingdotgg/t3code @ f61fa949
(2026-07-09). Headline: **t3code has NO workflow/subagent tree view.** Zero hits
repo-wide for `workflow_progress` and `background_tasks_changed`; those frames
fall into `handleSystemMessage`'s default branch → a runtime.warning row
(ClaudeAdapter.ts:2758-2763). No agents rail, no phase boxes, no per-agent
token counts. Our rail is AHEAD on orchestration viz — what t3 wins on is
timeline hygiene: fold-on-settle, show-last-only, and zero-commit timers.

### How subagents actually render (flat, uncorrelated)
1. **One generic row per Task spawn.** Any tool whose name contains
   agent/task/subagent classifies as `collab_agent_tool_call`
   (apps/server/src/provider/Layers/ClaudeAdapter.ts:600-612), titled
   "Subagent task" (ClaudeAdapter.ts:869-870), hammer icon
   (apps/web/src/components/chat/MessagesTimeline.tsx:1875-1877), rendered by
   the same `SimpleWorkEntryRow` as every other tool: icon + heading + truncated
   preview + chevron expand + ✓/✗ glyph (MessagesTimeline.tsx:1900-2056).
2. **Label recipe** (ClaudeAdapter.ts:840-852): prefer
   `subagent_type: description`, fallback prompt slice ≤200 chars, never raw
   JSON. Expanded body = prompt/detail in a `max-h-64` scrollable `<pre>`
   (MessagesTimeline.tsx:2050).
3. **No child correlation.** `parent_tool_use_id` appears exactly 3× in the
   adapter and never in the view: nulled on synthesized user messages (:916),
   listed as a noise key (:1274), and used ONLY to drop subagent
   `message_delta` token usage (:2080). Child tool calls are not nested,
   grouped, or attributed — subagent stream activity lands flat in the same
   work log (content_block_start at :2248 has no parent filter).
4. **Orphan subagent output** (assistant frames arriving with no active turn)
   auto-starts a *synthetic turn* so it still displays instead of being lost
   (ClaudeAdapter.ts:2466-2507).
5. **task_started/task_progress/task_notification** map to task.started /
   task.progress / task.completed events (ClaudeAdapter.ts:2668-2718) but the
   `workflow_progress` payload (the phase/agent tree) is DISCARDED — only
   task-level summary + usage survive. In the work log: task.started is
   filtered out (apps/web/src/session-logic.ts:634), task.progress renders as
   a "Reasoning update" row with tone=thinking → bot icon
   (ProviderRuntimeIngestion.ts:469-488, session-logic.ts:685-717).
   `tool_progress` (elapsed-seconds per tool) is mapped to a runtime event
   (ClaudeAdapter.ts:2793-2806) then dropped — ingestion has no case for it.

### Progressive disclosure (their real craft)
6. **Show-last-only while running**: `MAX_VISIBLE_WORK_LOG_ENTRIES = 1`
   (MessagesTimeline.logic.ts:12) — one live work row; everything older folds
   behind "+N previous tool calls" (logic.ts:443-475, tsx:1149-1188).
7. **Fold-on-settle**: once a turn is no longer streaming, ALL its work rows
   collapse behind the terminal assistant message with a one-line header
   "Worked for 3m 12s" / "You stopped after 42s" for interrupts
   (deriveTurnFolds, logic.ts — label construction right before
   `foldsByAnchorEntryId.set`). Duration measured from the USER message
   boundary, not the first output (comment at the TurnGroup type).
8. **Settle-gated glyphs**: while running, an empty tool result shows a
   neutral "–"; when the turn settles, neutral flips to ✓ (tsx:1940-1944 —
   `turnSettled` gate). Failure = red ✗ with "Failed" tooltip.

### Re-render hygiene
9. **Identity-stable rows**: rows are re-derived every frame but each row
   reuses the previous object if a per-variant shallow compare passes
   (`computeStableMessagesTimelineRows` + `isRowUnchanged`,
   logic.ts:538-600) so memoized row components skip. List is virtualized
   (LegendList, tsx:474).
10. **Self-ticking timers outside React**: "Working for Xs" mutates its own
    `textContent` on a 1s interval — zero React commits while streaming
    (tsx:1077-1102). Same trick documented for row sections that subscribe to
    the UI store directly so a toggle re-renders one row, not the list
    (tsx:1104-1147, 1190-1236).
11. **Lifecycle collapse**: started/updated/completed activities for the same
    toolCallId merge into ONE row updated in place
    (session-logic.ts:759-781, deriveToolLifecycleCollapseKey :849).
12. **The only persistent rail is the PLAN**: PlanSidebar renders TodoWrite /
    TaskCreate-Update-List state as steps with ✓ / spinning LoaderIcon /
    pending circle (PlanSidebar.tsx:36-47, step tint :216-226; state folded in
    ClaudeAdapter.ts:667-800). Agents get no panel.

### Deltas worth stealing (ranked for OUR rail)
1. **Fold-on-settle**: when a workflow/turn completes, collapse the rail's
   expanded tree into one line — "Worked for 3m 12s · 7 agents · 142k tokens"
   — click to re-expand. We stay default-expanded forever; t3 proves the
   post-completion collapse is what keeps long threads readable.
2. **Show-active-only while running**: fold completed agents behind
   "+N done" and keep only live agents visibly breathing (their
   MAX_VISIBLE=1 is the aggressive version; ours can be per-state).
3. **Self-ticking elapsed timers client-side**: per-agent "12s" labels via a
   JS hook mutating textContent — never server ticks, zero LiveView patches
   per second.
4. **Settle-gated glyph semantics**: neutral "–" while running, flips to ✓
   only when the run settles — composes exactly with our provenance-gated
   completion flips.
5. **Interrupt vocabulary**: "You stopped after 42s" as a first-class fold
   label — name the interruption instead of graying it out.
6. **Subagent row label recipe**: `subagent_type: description` (fallback:
   prompt ≤200 chars), never raw JSON; expanded detail clamped to a
   scrollable max-height block so expand never explodes the timeline.
7. **Lifecycle collapse discipline**: one row per agent/tool identity updated
   in place, never appended rows per progress event (we do this for the rail;
   apply it to any chat-inline echo of task.progress too).
NOT worth stealing: their subagent model itself — flat, uncorrelated,
phase-blind. On workflow viz we have no competitor here.

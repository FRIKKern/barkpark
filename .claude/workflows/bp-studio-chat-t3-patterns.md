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

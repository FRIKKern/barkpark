# Wave Session Card — Epic Cycle in Barkpark Chat (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Noo-Noo Disk Guardian** — is preserved verbatim at
> `.claude/workflows/bp-noo-noo-disk-guardian-charter.md`. Do NOT read this file for noo-noo
> history. This slot is now the memory of the **Wave Session Card** epic.
>
> Epic anchor: bp task **`task-c461d30da137ae74`** (published, guerrilla). Children: wsc-s1..s5
> (task-e24d433d072ee8c0, task-a232a271f4007966, task-8c92a966b28eda80, task-8059027150fc6680,
> task-a0e41d82867633dc) + wsc-bl-* backlog.
> Wave Papers: wave 1 **`wsc-wave-2026-07-16`** (style=article).
> Ratified design map: Paper **`/papers/epic-cycle-session-card`** — this epic EXECUTES it.
> Sibling charters whose laws bind here: `bp-chat-tui-charter.md` (D13 reply-body parity, D14
> sidebar omission law, D25/D47 rail band), `bp-studio-chat-excellence-charter.md` (D29
> change-only activity, D45 task-frames-never-flicker-sidebar, D57–D62 wave-11 journey truth
> table + fixture provenance, D66 scoped-region golden).

## Vision

Barkpark Chat becomes THE cockpit for Epic Cycles, without ever getting louder for anyone
else. A session running an Epic Cycle earns exactly two extra sidebar-card lines: seven phase
ticks (done=evergreen, active=breathing, future=dim) with a settled/total agent counter
(13/17, Claude-Code-style), and the epic-goal line it advances (epic title · slices
closed/total · wave_status heartbeat) — intermingled from the task spine the Doing strip
already rides. `bp chat` mirrors the same two lines in its session list and grows the
Claude-Code below-composer workflow panel: a collapsed strip, arrow-down focuses it (never
stealing composer keys), Enter expands the two-pane Phases | agents detail, Esc collapses —
view-only. Two north stars judge everything: **minimalism** (plain chats pay zero — proven by
byte-identical rendered-row diffs and conditional TUI geometry) and **honesty** (interrupted
renders interrupted; elapsed/tokens render only when the wire carries them, never
synthesized). Parked for later layers: CycleFleet ledger cockpit, stop/pause control, live
task_* folding in Go.

## Decisions

- **D1 — One truth table, forever.** `workflow_summary/1` is a thin additive projection over
  the wave-11 `workflow_journey/1` (studio_chat.ex:1208) + `workflow_node_terminal?/failed?`
  helper sets; any parallel status/counting logic is an auto-reject. Why: the pinned contract
  is D57–D59 of the studio-chat charter, and a diverged duplicate set already caused a real
  bug once (fixed in wave-11 itself). Note: `workflow_summary/1` does not exist yet — briefs
  that referred to it as existing were naming drift; `workflow_journey/1` is the real prior art.
- **D2 — s1 READS timestamps; nobody stamps.** `workflow_agent` nodes already carry
  `startedAt`/`queuedAt`/`lastProgressAt` in every state and `durationMs`/`tokens`/`toolCalls`
  once terminal, persisted verbatim by `rail_put_workflow` (studio_chat.ex:1078) — proven to
  survive the full fold→signature-gate→Repo.update→reload round-trip (throwaway probe, 3/3
  green) AND confirmed in 4 real guerrilla prod rows including an `error` terminal that still
  carried `durationMs: 439`. Why: the earlier "s1 adds first-seen/settled stamps" lean is
  refuted by evidence; the fields are wire-carried and DB-safe today.
- **D3 — Pinned `workflow_summary/1` shape (the cross-surface contract).** Returns `nil` when
  the rail has no workflow-bearing entry (plain chats pay zero). Else, over the
  **highest-seq** rail entry carrying a `"workflow"` list:
  `%{label, ticks, phase, phase_index, phases_total, agents_done, agents_total, running,
  terminal?, outcome, tokens, started_at, ended_at}` where `ticks` = ordered per-phase
  statuses straight from `journey.phases[].status`; `agents_done` = `summary.done +
  summary.failed` (the 13/17 counter — settled means terminal, failure counted honestly);
  `tokens` = settle-on-state `summary.tokens` (a floor while running, never a live counter);
  `started_at` = min agent `startedAt` (nil when absent — background/codex origins carry
  none); `ended_at` = entry-level `"end_time"` when D5 has stamped it, else nil; `label` = the
  entry's `row.description` composite string treated as ONE opaque label (never em-dash-split).
  Why: every field is read from wire truth; the counter reuses the journey's own counts so no
  second counting exists.
- **D4 — Agent states are never enumerated.** All logic goes through the terminal?/failed?
  sets; the wire carries non-terminal states beyond `start` (`progress` observed in the
  interrupted fixture) plus terminal `done`/`error`. Caveat recorded: `attempt>1` and
  entry-status `"interrupted"` shapes exist ONLY in fixtures today (zero real prod evidence) —
  synthetic-only coverage, no per-attempt UI. Why: a `{start,done}` enumeration provably
  misses `progress`.
- **D5 — Terminal whole-workflow elapsed comes from `task_updated.patch.end_time`.** s2 widens
  the Recorder's `task_updated` path (recorder.ex:1175–1184, currently reads only
  `patch.status`) to also fold `end_time` onto the rail entry (via the `rail_stamp_status`
  seam in studio_chat.ex). Live elapsed = `now − min(startedAt)`. Where neither exists,
  elapsed is omitted — never synthesized. Why: `end_time` is real wire data currently dropped
  on the floor; no phase- or entry-level timestamp exists anywhere else (proven in prod data).
- **D6 — s2 broadcasts on a NEW distinct tuple `{:chat_workflow, sid, summary}`** on
  `activity_topic()`, change-only, gated by `commit_rail`'s existing `rail_signature` change
  check (recorder.ex:1259–1265). D45 is NOT amended; its blanket refute test stays verbatim.
  Reusing the `{:chat_activity}` tuple is an auto-reject. Why: the 3-variant probe matrix
  proved the distinct tuple passes 60/60 even ungated, while tuple-reuse trips D45's refute
  AND would KeyError at runtime in chat_live.ex:1840 (`activity.state` access).
- **D7 — Busiest-child line DROPPED this wave** (was s2's bonus). Why: no ranking signal
  exists anywhere (`grep busiest` = 0 hits; the Recorder's task_index carries no
  recency/usage field) — inventing a metric violates the honesty star. Backlogged as
  wsc-bl-busiest-child.
- **D8 — "PRs open" DROPPED from the epic-goal line.** Why: zero data source exists — the
  github plugin syncs Issues only (projection.ex:113,139), no PR concept anywhere in api/lib.
  Fabrication excluded; backlogged as wsc-bl-prs-open.
- **D9 — Epic-goal line = one `parent_id` hop, via the EXISTING documents subscription.**
  `hand_task_row/2` (chat_live.ex:4788) widens to carry `parent_id` (both feeding paths
  already hold full content — no new read). Epic-doc broadcasts pass through a SIBLING clause
  in the `{:document_changed, %{type: "task"}}` fold matching `doc_id == a held hand-task's
  parent_id` — the existing claim.worker/in_progress clause is untouched. Line renders: epic
  title · slices closed/total · wave_status. Why: a 7-epic corpus sample proves one hop lands
  the epic root (children always direct, child_count 0); the current fold provably drops epic
  broadcasts (chat_live.ex:1801).
- **D10 — The list wire carries a COMPACT derived summary, never raw rail_snapshot.**
  `list_sessions/2` select-widens `rail_snapshot` (in-process only); `sidebar_json/1` and the
  Studio sidebar emit a small `workflow` object (= `workflow_summary/1` output) on
  workflow-bearing rows only. The raw blob stays off the list wire:
  chat_controller_test.exs:446's `refute rail_snapshot` STAYS, plus a new assert pinning the
  compact key, plus a new Ecto-doctrine test mirroring the draft/effort_choice omission tests.
  This is a deliberate, narrow amendment to chat-tui D14: derived display data may ride the
  list; continuity blobs never. The PR description must say "amends D14". Why: a real
  29-agent snapshot measured 38,308 bytes — shipping it per-row to every sidebar consumer
  fails minimalism; the compact summary is ~200 bytes.
- **D11 — Minimalism is proven, not asserted.** s3 adds a NEW sidebar-scoped golden region
  (chat_render_golden_test.exs pattern, studio-chat D66) slicing out only the `session_stamp`
  wall-clock text — the file's own doc comment names that as the sidebar's sole
  nondeterminism. The existing transcript golden region is untouched. Plain/idle rows must
  diff byte-identical with-vs-without workflow data present. TUI-side, idle sessions keep the
  3-line footer and the `height-5` constant so frames are byte-identical.
- **D12 — s4 decodes the compact wire summary; no Go fold on the list path.**
  ChatSessionSummary (internal/apiclient/chat.go:156) gains the matching compact field;
  parity = field-projection tests against shared JSON fixtures of the D3 shape emitted by
  s1's Elixir tests and mirrored into internal/chat/testdata/ (mechanism-A, never byte-diff;
  the chat-tui D13 reply-body harness is NOT extended — it is reply-body-only by law). Why:
  the server computes once; three surfaces render one truth.
- **D13 — s5's panel is view-only and turn-boundary fresh.** Data = the open session's
  `entry.workflow` decoded from the full-session GET (which already carries rail_snapshot);
  s5 ports the journey GROUPING (phases|agents panes, label pair-grammar, model family,
  format_tokens) to Go for the panel only. NO new SSE frame this wave: the activity topic
  provably never reaches /v1/chat (topic mismatch chat_controller.ex:339 + receive-loop drops
  unknown tuples at 398–421) — a bridge is genuinely new wire code, backlogged as
  wsc-bl-workflow-sse. Accepted UX ceiling: mid-turn the panel lags until the next
  turn-boundary/permission refetch. Why: honesty over fake liveness.
- **D14 — s5 focus model.** New `focusZone` field on Model (composer default). Arrow-down
  moves focus to the strip ONLY when the strip is visible; otherwise KeyUp/KeyDown keep their
  scroll meaning. KeyRunes ALWAYS compose while composer has focus (regression: typing never
  moves panel selection). Enter expands the two-pane detail, up/down selects phase, Esc
  collapses back to composer. Footer geometry (`chatFooter` + `bodyHeight`) becomes
  conditional on strip presence. Why: no focus-zone prior art exists (flat handleChatKey);
  the answerable-card focus ring (chat-tui D35) is a different concept — don't conflate.
- **D15 — Elapsed/tokens honesty across all surfaces.** Per-agent elapsed = `durationMs`
  (terminal) or `now − startedAt` (live); whole-workflow per D5; tokens = settle-on-state
  floor; rows/origins without timestamps omit the figure entirely. Interrupted renders
  interrupted (mid-flight agents keep `startedAt`, never get `durationMs` — proven in the
  round-trip probe).
- **D16 — Spine and gates.** s1 → s2 → s3 serialize (all touch studio_chat.ex; Elixir Test CI
  gate; never merge .ex before it). s1 → s4 → s5 (s4/s5 share render.go/model.go — honest
  files: labels let the frontier serialize them; s3 runs parallel to the Go chain). Builders
  claim-first in worktrees off origin/main; live proofs use disposable sessions only — never
  guerrilla's live chat corpus.

- **D17 — Wave 2: s3 is SALVAGED, never rebuilt.** wsc-s3 was fully BUILT and REVIEWED locally
  on `loop-epic/wsc-s3-...-2-r` (commit `7280968a0`, review gate 500/0) but never pushed — the
  lead's "no PR, no branch → unbuilt" was false. The landing mechanism is **Path B
  (extract-and-reapply)**: `git diff fda0d1b93 7280968a0 > /tmp/s3.patch` (the s3-only delta =
  8 files, 1055 ins / 4 del) then `git apply --3way` onto fresh origin/main → single clean
  commit. VERIFIED on today's advanced origin/main (d38434b53): patch applies with ZERO
  conflicts, `mix compile --warnings-as-errors` EXIT=0, the four targeted files pass **500/0**,
  and the D11 sidebar golden renders **byte-identical** (no GOLDEN_REGEN needed). The reviewed
  tree IS the spec — a blind rebuild is an auto-reject. Path A (`rebase --onto`) is a fallback;
  Path B is preferred (no buggy intermediate commit). The "changed in both" conflict fear is
  real ONLY for a naive full-branch `git merge` (which re-carries the already-merged s1/s2) — no
  salvage path does that. PR body must say "amends D14".
- **D18 — s3 is the API PRODUCER the merged Go card waits on.** LATENT GAP confirmed: the
  merged s4/s5 Go decoder (internal/apiclient/chat.go:182/184) declares
  `Workflow *ChatWorkflowSummary` + `Epic *ChatEpicGoal` (both `omitempty`), but origin/main's
  `sidebar_json/1` (chat_controller.ex:904) emits NEITHER — so the merged bp-chat card feature
  is inert dead code today (not a crash: nil → plain path). s3's `sidebar_json` widening is
  exactly the producer that de-inerts it; landing s3 completes the three-surface truth. This
  raises s3's stakes: it is not just the LiveView sidebar, it is the cross-surface wire producer.
  Fixture parity is byte-identical across the Elixir and Go mirrors and the literal atom key
  `terminal?` decodes correctly on both sides (go test green).
- **D19 — Wave-2 backlog ranking (honesty-star order).** Two picks pulled this wave:
  **wsc-bl-real-fixtures** (highest value, lowest risk — mostly testdata; hardens all five
  merged surfaces against prod-shaped data per D62) and **wsc-bl-workflow-sse** (removes the D13
  mid-turn lag ceiling). Both serialize behind s3 (real-fixtures collides on
  studio_chat_test.exs + wants s3's producer landed; workflow-sse touches the D16 .ex spine).
  **wsc-bl-prs-open stays PARKED** — verifier proved it gets ZERO parallelism benefit over
  waiting for s3 (same-file collision on the epic-goal fold queues it behind s3 anyway) while
  additionally requiring a net-new external-data subsystem AND a REVERSAL of a tested, ratified
  honesty decision (s3's tests assert "PRs open" absent everywhere; two merged Go files encode
  the D8 exclusion). Shipping it means reopening D8 first. **wsc-bl-busiest-child stays PARKED**
  — D7 re-confirmed: `grep busiest` = 0, task_index carries no recency field, session-level
  recency is wrong-granularity, per-node tokens are deliberately-suppressed noise. Inventing a
  rank violates the honesty star.
- **D20 — SSE wire carries the COMPACT summary, not the raw rail.** wsc-bl-workflow-sse
  subscribes the SSE forwarder to the workflow tuple and emits `workflow_summary/1`'s compact
  map as a new `event: workflow` frame — so Go decodes it with the EXISTING
  `ChatWorkflowSummary` struct (one parser across list + SSE), riding the D14 no-raw-rail law
  (the raw 29-agent rail measured 38,308 bytes). The raw rail is what FORKS (a second Go parser
  + a duplicated fold). THREE tripwires: (a) D45 — never route `task_*` frames into
  `publish_activity`/`{:chat_activity}` (reds recorder_test.exs); (b) change-only — inherit
  `commit_rail`'s rail-signature gate, never push from inside `task_progress`; (c) the activity
  topic is GLOBAL and NOT tenant-scoped — an SSE forwarder MUST filter `{:chat_workflow, sid, _}`
  to the connection's own session (a tenancy requirement, not cosmetics). The producer already
  fires into the void on main; the bridge needs a SUBSCRIBER, not a new producer.
- **D21 — attempt>1 closes by DOCUMENTED PROOF, never a synthetic capture.** `attempt` is
  external Claude-Code-CLI Task-tool telemetry, forwarded through the rail verbatim
  (`rail_put_workflow` is a bare `Map.put`, no field logic); barkpark has ZERO write/derive path
  and NO repo mechanism (workflow runner or Studio UI) to force a retry. All 39 real guerrilla
  rail entries and every committed fixture show `attempt=1`. So wsc-bl-real-fixtures criterion 2
  ("Real attempt>1 capture OR documented proof the wire never emits retries") closes via the
  documented-proof branch (this trace + the 39/39 check), never a fabricated `attempt=2` (D62 +
  honesty star forbid it). Criterion 1 (a REAL interrupted-run fixture) is separately capturable
  from a DISPOSABLE session and stays a genuine deliverable.

- **D22 — SSE wiring is (a): re-broadcast `{:chat_workflow, sid, summary}` on the PER-SESSION
  `Recorder.topic(session_id)`, NOT a `^id` filter on the global activity topic.** Verify PROVED
  (a) end-to-end in a throwaway worktree: a 3-file diff (recorder.ex +9 second broadcast inside
  the EXISTING `broadcast_workflow`, chat_controller.ex +9 one `stream_loop` clause +
  `sse_workflow_frame/1`, recorder_test.exs +35 leak test) — recorder+studio_chat 221/0,
  chat_controller 52/0, D45 refute (recorder_test.exs:1174) 628ms GREEN, change-only gate
  (:1421) 489ms GREEN, and a NEW cross-session isolation test (:1524) 400ms GREEN proving
  session B's change never reaches A's per-session subscriber while A's OWN change does.
  Tenancy is safe BY CONSTRUCTION — the topic string embeds the session id, so no manual filter
  can be forgotten (the D20(c) requirement is met by the topic key itself). The forwarder needs
  NO edit (it already subscribes `Recorder.topic(id)` at chat_controller.ex:339) and
  **studio_chat.ex is NOT touched** (D16 serialize point untouched). (b)'s only appeal — "no
  recorder change" — buys 8 call-site signature edits and a leak guard living in an `_other`
  fall-through; the d45-refute worry that touching `broadcast_workflow` reopens the D45 surface
  is EMPIRICALLY nil (the classify-only-workflow-tuple diff keeps the verbatim refute green).
  Why: minimal, precedent-conformant, tenant-safe without a hand-written pin.
- **D23 — The `event: workflow` frame is WORKFLOW-ONLY and UNREPLAYABLE (no `id:`).** The frame
  carries `Jason.encode!(workflow_summary)` — byte-identical to the list wire's `workflow` key,
  decoded by the ONE existing `apiclient.ChatWorkflowSummary` parser — and NO `epic` sibling and
  NO `id:` seq. Epic-goal is a SEPARATE `put_epic` concern on the list wire, never in the
  broadcast tuple; Verify proved both the Go list-card path (`workflowCardLines` guards
  `epic==nil`, render_test.go:472/477 green) and the strip path (never had an epic arg) render
  SAFELY with nil epic — so carrying epic is a freshness nicety, never a crash risk, and is OUT
  of scope this wave (the list card's epic line simply stays turn-boundary fresh). No `id:`
  matches the runtime/permission/exit live-delta precedent (chat_controller.ex:471-481). Why:
  smallest honest frame that removes the D13 lag; epic staleness is not the ceiling being lifted.
- **D24 — The Go footprint is WIDER than one reduce.go case: a NEW State field + a new frame
  case + collapsed-strip render edits.** Verify (V2, build/vet/test all exit 0) proved
  `State.Workflow` (reduce.go:74) is the RAW `*Workflow` rail fold (carries `Nodes`), a
  DIFFERENT, incompatible type from the compact summary — so the frame needs a NEW field
  `LiveWorkflow *ChatWorkflowSummary` (grep: does not exist today) + a new `case "workflow":` in
  `reduceFrame` (unmarshal → overwrite → return `st, nil` with NO Effect: that missing
  turn-boundary refetch IS the lag removed) + render.go edits so `workflowStripVisible` /
  `renderWorkflowStrip` / `workflowPanelLines` read the compact field for the COLLAPSED one-liner
  (Label/AgentsDone/AgentsTotal/Ticks/Phase/StartedAt/EndedAt/Tokens all present). The
  Enter-expanded `renderWorkflowDetail` iterates per-agent `Nodes` the compact summary
  STRUCTURALLY lacks, so it CANNOT live-freshen from the frame — it stays turn-boundary fresh
  from the raw `st.Workflow` fold. That is an ACCEPTED ceiling this wave (the visible lag is the
  collapsed strip, not the drill-down), backlogged as `wsc-bl-workflow-sse-detail`. Why: D20's
  compact-on-the-wire law is exactly what forces a second in-memory representation.
- **D25 — The attempt=1 corpus test is SCOPED to `workflow_agent`-typed nodes, and "39/39
  guerrilla" is NOT load-bearing.** Verify proved every `attempt` occurrence across the whole
  in-tree corpus is literal `1` (837 in ndjson + 62 in testdata; only 3 ndjson + 3 testdata
  files carry `workflow_agent` nodes at all). So the invariant test MUST iterate parsed nodes,
  filter `type=="workflow_agent"`, assert `attempt==1`, and no-op on fixtures with none — a naive
  file-wide "every file has attempt=1" would false-pass on the 8 non-workflow fixtures. The
  D21 close = this in-tree test + the structural argument (`rail_put_workflow` is a bare
  `Map.put`, no derive path); the wave-1 "39 real guerrilla entries" figure is a survey-time
  observation, NOT a committed artifact, and must be a footnote, never the proof substrate
  (honesty star forbids leaning on guerrilla's live corpus). A fabricated `attempt=2` is an
  auto-reject.

### Wave 3 — the AGENT-DETAIL round (2026-07-17). Decisions D26–D34 (drill the workflow card one level to per-agent detail; PURE PRESENTATION, verified by running)

- **D26 — The signature strip MUST be extended, or the feature is INVISIBLE (V1 proved by running).**
  `strip_workflow_node/1` (studio_chat.ex:892) is a `Map.take` of 6 structural fields
  `[type,title,label,phaseIndex,model,state]` — every per-agent detail field is dropped, so a
  detail-only frame yields an EQUAL `rail_signature` and is BOTH (a) not re-rendered (`fold_rail/2`
  returns the socket unchanged, chat_live.ex:5901) AND (b) not persisted (`recorder.ex:1265` skips
  the write) — the live pane FREEZES and a reopen never surfaces it. wsc-ad-gui extends the strip to
  ALSO retain exactly `[lastToolName, lastToolSummary, resultPreview, attempt, promptPreview]` — the
  render-driving detail fields. NEVER `lastProgressAt`/`tokens`/`durationMs` (they tick every
  heartbeat and would defeat the change-only guard). A probe test (mirror studio_chat_test.exs:1139)
  proves a detail-only delta moves the signature AFTER the fix and did not before (verifier ran both
  directions green). Accepted consequence: the "▸ NOW" age line does not self-tick — it refreshes
  only when a tool/summary/state/attempt change bumps the signature (this is D13 turn-boundary
  freshness applied to detail; a live SSE upgrade rides wsc-bl-workflow-sse-detail, not this wave).
- **D27 — The no-affordance gate is STRUCTURAL, NEVER the row's `origin` (V5 correction — the trap
  the brief phrasing invited).** All three committed rail fixtures are `origin=background` AND carry a
  populated 35/35/12-node `workflow` array full of detail — because a `local_workflow` task ALSO rides
  a `background_tasks_changed` snapshot that stamps `origin=background` while `rail_put_workflow`
  attaches the detail-laden nodes independently (studio_chat.ex:907, :1097). Gating the expand
  affordance on `origin ∈ {background,codex}` would HIDE the drill-down for EVERY real captured
  epic-cycle session. The affordance is gated on `workflow_agent_detail/1` returning non-empty detail
  for the node; codex rows (`rail_apply_codex_item` never writes detail fields) and genuinely
  detail-less nodes fall out by construction. The `origin` string is never consulted.
- **D28 — `workflow_agent_detail/1` — the new pure parity fold + its dual-mirror fixture.** A NEW
  public `def` beside `workflow_summary/1` (studio_chat.ex:1313): takes the rail_snapshot, returns a
  LIST of normalized per-agent detail maps over the highest-seq workflow-bearing entry (`[]` when
  none), reusing `workflow_node_terminal?/failed?` (D1 — one truth table, no second classifier). Each
  map = `{agentId, label, model, state, terminal?, promptPreview, lastToolName, lastToolSummary,
  resultPreview, attempt, tokens, startedAt, lastProgressAt, durationMs}` with ABSENT fields OMITTED
  (never a fake `0`/`""`); `startedAt`/`lastProgressAt`/`durationMs` pass through as RAW epoch-ms
  (surfaces format their own age — D31). `resultPreview` is opaque text (a JSON-encoded string) —
  passed through verbatim, NEVER re-parsed. Mirrored byte-identical:
  `api/test/support/fixtures/workflow_summary/workflow_agent_detail.json` +
  `internal/chat/testdata/workflow_agent_detail.json`, both written from ONE encoded string via
  `REGEN_WORKFLOW_AGENT_DETAIL=1`, folded from the SAME two committed captures
  (`epic_cycle_progress` + `epic_cycle_interrupted` — V6 proved both carry populated detail:
  promptPreview/lastToolName 759/759, lastToolSummary 718, resultPreview 694 on the completed run).
  Two freshness tests (fresh-fold==api mirror AND api==Go bytes), mirroring studio_chat_test.exs:2239/2250
  (verifier proved that gate NON-vacuous: one drifted byte reds it).
- **D29 — `attempt` is plain `int`; the `>1` chip is render-tested by an explicitly-SYNTHETIC node
  (V2).** `attempt` sits on every node, always value `1`, never omitted (unique `.attempt = [1]`
  across all fixtures) → Go decodes plain `int`, chip gate is `attempt > 1`. No real capture carries
  `attempt>1`, so the chip's render branch is exercised by a hand-built, comment-labelled SYNTHETIC
  node INSIDE the render test — NOT folded into the real-capture parity fixture (which stays
  verbatim-from-real per D62/D25; a fabricated `attempt=2` in the CORPUS invariant test stays an
  auto-reject, unchanged).
- **D30 — TUI third level = additive `wfAgent int` + `wfAgentDetail bool`, NEVER a single `depth int`
  (V4 proved by ref-count).** The D14 model is already bool-per-level; a `depth int` would rewrite
  `wfExpanded`'s 13 source + 10 test refs, editing the very byte-locked tests. Two new fields:
  `wfAgent` (agent cursor within the selected phase's agents — the right pane has no cursor today) +
  `wfAgentDetail` (pane open), reset at openSession/leaveSession AND the vanished-strip guard. The
  pane is appended INSIDE `workflowPanelLines()` under `if m.wfAgentDetail` (mirroring the
  `wfExpanded` block, render.go:461) so paint and geometry never disagree and frame height stays
  fixed. `handleWorkflowKey` gains Enter(open)/Esc-or-left(pop one level)/Up-Down(move `wfAgent`) —
  and MUST NOT add a `tea.KeyRunes` case, so composer safety stays depth-agnostic by construction
  (TestWorkflowKeyRunesAlwaysCompose extended to the new depth). Go `WorkflowNode` (workflow.go:66-77)
  gains `Attempt int` + `PromptPreview/LastToolName/LastToolSummary/ResultPreview *string` +
  `LastProgressAt *int64` (camelCase json tags) — `json.Unmarshal` silently drops them today.
- **D31 — Ages/tokens use each surface's OWN existing helper on RAW epoch-ms; no shared age
  formatter.** The fold exposes `lastProgressAt/startedAt/durationMs` as raw epoch-ms. Go reuses
  `formatElapsed(now.Sub(UnixMilli(*lastProgressAt)))`, `formatTokens`, and the width-based
  `truncate` (render.go); Elixir uses its own markup/`format_duration`. Field-projection parity is on
  the RAW ms fields, NOT the rendered age string — the two grammars (`"42s"` vs `"42.0s"`)
  legitimately differ and must not be forced byte-identical. resultPreview cap: TUI reuses `truncate`;
  GUI keeps single-line rows on CSS ellipsis (byte-identical) and, for the expanded multi-line result,
  a small `String.slice(text,0,299)<>"…"` guarded on `length>300` (no `~300` precedent existed — this
  is a deliberate new N=300 on opaque text; do NOT reuse `summary_preview`, its markdown-stripping is
  wrong for a tool result).
- **D32 — The claimed-build-task INTERMINGLE is DESCOPED from this wave; refiled as
  wsc-bl-agent-task-join (V7 killed the "zero new subscription" premise).** The join is a SOFT slug
  match with NO id on the wire, AND the two emitters diverge (bp-epic-cycle `build:<slug>` one segment;
  wild-bulk-cycle `build:<domain>:<slug>` two segments — a naive `build:(.+)` mismatches the second),
  AND — decisively — the existing `hand_tasks` fold (chat_live.ex:4900) is scoped by EXACT-match to the
  CURRENT session's own worker (tasks/prime.ex:108), while epic subagents claim under distinct
  `epic-builder-<slug>` workers. So reusing the fold verbatim would surface NOTHING for any
  `build:<slug>` row — a silently-dead affordance that "passes review because nothing is shown". That
  fails the honesty star (distrust vacuous green). BOTH slices drop the intermingle criterion this wave
  and ship the PURE agent-detail presentation only. The intermingle is refiled: broaden the fold to
  scope by the epic `parent_id` (surfacing subagent claims), join `slug(title)` against the label's
  LAST colon-segment (handles both emitter shapes), degrade-on-ambiguity to nothing, deep-link
  `/admin/projects?task=<id>` (target real: chat_tool_renderer.ex:432 + board_live.ex:248 honor it).
- **D33 — The D66 open-session golden is regenerated IN-DIFF (the affordance adds bytes); the D11
  sidebar + plain rows stay byte-identical.** Any per-agent expand affordance changes the
  `workflow_agent` row's HTML, and the D66 fixture replay already expands the entry-level rail (agent
  rows are inside the locked region). So `chat_render_golden.html` is regenerated in the SAME PR via
  `GOLDEN_REGEN=1`, the diff justified as limited to the new affordance markup on detail-bearing agent
  rows. Non-workflow rows pay zero (no agent rows → no affordance); the whole D11 sidebar/list golden
  is UNTOUCHED (agent detail is open-session only); the detail BODY renders only on explicit toggle
  (default CLOSED, keyed by `agentId` in a NEW override map — mirror `agent_expanded`, chat_live.ex:181)
  so it never enters the determinism-guarded default-open region. If any live age ever lands in a
  locked region, slice it via `slice_stamps/1` (chat_render_golden_test.exs:333). Baselines are GREEN
  on origin/main (V3 167/0 first-try; V4 all four Go locks + vet exit 0).
- **D34 — GUI round 1, TUI round 2 (a fixture dependency, not just file overlap).** wsc-ad-gui authors
  `workflow_agent_detail/1` AND both fixture mirror bytes (the Elixir REGEN writes the Go mirror too).
  wsc-ad-tui's Go field-projection + freshness tests READ
  `internal/chat/testdata/workflow_agent_detail.json`, which does not exist until ad-gui merges — so
  ad-tui is round 2, `after:[wsc-ad-gui]`; the lead dispatches it after merging ad-gui. Disjoint
  surfaces otherwise (Elixir vs Go — no source-file overlap). Builders branch from origin/main (local
  main is diverged +4/−14 — the epic-cycle-charter-commit trap; steward reconciles). Both opus (Fable
  exhausted this wave).

### Wave 3 · round 2 — the ad-tui DECIDE finalizations (2026-07-17). Decisions D35–D39 (dep MERGED, 3 verifiers PROVED the seam by RUNNING; ad-tui is now round 1 of THIS run)

`wsc-ad-gui` is MERGED (#3959) — `workflow_agent_detail/1` (studio_chat.ex:1398) + the byte-identical
dual-mirror `workflow_agent_detail.json` (both 40714 bytes, `cmp` IDENTICAL) are ON MAIN. The D34
fixture dependency is satisfied, so wsc-ad-tui reclassifies from round 2 to **round 1 — it builds this
run**. Three verifiers PROVED the mechanism (not asserted): baseline gate GREEN (`go vet` zero output +
`go test` ok on first run, single package so api-suite flakes cannot appear here), the decode+derive
parity PASSED on all 34 fixture nodes with the 6 additive fields, and the seam blueprint re-anchored at
HEAD. The Decide finalizations, each following the evidence over the direction's prose:

- **D35 — the agent cursor is Enter-THEN-arrow, never arrow-then-Enter (T1, byte-lock forces it).**
  Depth-1 `Up/Down` is byte-locked to `wfPhase` (TestWorkflowEnterExpandsEscCollapses, model_test.go:446:
  Enter lands wfPhase=5, Down→6 clamps, Up→5). So the agent cursor CANNOT arrow at depth-1. Grammar:
  at depth-1 (`wfExpanded && !wfAgentDetail`), **Enter** drills to agent detail — land `wfAgent = 0`
  and set `wfAgentDetail = true` ONLY if the landed agent carries detail (a signal field present),
  else an honest no-op (D27 structural gate). Inside detail (`wfAgentDetail`), **Up/Down** cycle
  `wfAgent` clamped to `min(len(phase.Agents), workflowDetailMaxAgents=8)` (the cursor must agree with
  the truncated painted list, render.go:546); **Esc OR left** pops ONE level (`wfAgentDetail→false`,
  staying expanded+focused). `KeyLeft/KeyRight` are BOTH fully unclaimed in the package (grep exit 1) →
  free to bind. Landing on index 0 (not "the breathing agent") is the safe default: `WorkflowPhase`
  carries no per-agent active marker, and in a real epic-cycle every `workflow_agent` node carries
  `promptPreview` so agent 0 always has detail.
- **D36 — Go DERIVES `terminal`/`failed` from `State`; the struct freezes at exactly 6 new fields
  (T2, empirically proven).** The fixture materializes `terminal`/`failed`/`agentId`, but at RUNTIME
  the rail wire carries NO terminal/failed (they are fold-DERIVED). Go derives them via
  `workflowStateTerminal` (workflow.go:51) + `workflowStateFailed` (workflow.go:56) — both already
  exist and mirror the Elixir `@workflow_node_terminal`/`@workflow_node_failed` sets. Adding
  `Terminal *bool`/`Failed *bool` would DISHONESTLY trust a wire bool the design forbids; adding
  `AgentId` is unneeded because the cursor is POSITIONAL (`wfAgent` indexes `phase.Agents`). Proven:
  a verifier added the 6 fields, decoded the shared fixture, and derive(State)==materialized
  terminal/failed with **0 mismatches across all 34 nodes** (30 terminal / 4 live / 0 failed), plus an
  independent python cross-check. The 6 fields are `Attempt int` + `PromptPreview/LastToolName/
  LastToolSummary/ResultPreview *string` + `LastProgressAt *int64` (camelCase tags) — frozen; no 7th.
- **D37 — the synthetic-honesty Go unit test is a MANDATE, because the shared fixture is VACUOUS for
  three honesty stars (T3).** Every one of the 34 fixture nodes is detail-bearing AND `attempt==1` AND
  `failed==false`, so a parity test on it passes the D27 no-affordance star, the `attempt>1` chip, and
  the positive `failed`-derive VACUOUSLY. The builder MUST author a Go unit test on hand-built nodes
  (mirror studio_chat_test.exs:2331/2441): (a) a thin node with NO signal fields → `agentHasDetail`
  false → Enter no-ops (no affordance); (b) an `attempt=3` node → the `attempt 3` chip renders; (c) a
  `state=failed` node → Go derives `terminal==true` AND `failed==true`. A verifier already proved the
  shape compiles+passes (TestWorkflowAgentDetailSyntheticThinNode). This is a filed acceptance
  criterion, not advice.
- **D38 — the reset-seam list is FIVE seams for `wfAgentDetail` and phase-change for `wfAgent`; the
  direction's 3-seam list was incomplete (T4).** `wfAgentDetail` resets to false at: openSession
  (model.go:267), leaveSession (model.go:313), the vanished-strip guard (keys.go:89), the
  **typing-snapback** (keys.go:101 — the composer-safety seam the direction OMITTED: a printable key
  must dismiss the pane and snap home), and Esc's two-level pop. `wfAgent` resets to 0 at openSession,
  leaveSession, AND on **every phase change** (keys.go:202 `wfPhase--` / keys.go:211 `wfPhase++`) — a
  new nesting level with no wfExpanded precedent, because a stale cursor would index past the new
  phase's agent list.
- **D39 — presentation mirrors the SHIPPED GUI code (#3959), not the commit-message prose.** The
  rendered order is `chip → about → now → done` with the **attempt chip FIRST** (gated `attempt>1`),
  labels are **lowercase** `about`/`done`, and NOW is a **bare `▸` glyph with NO label** (uppercase
  ABOUT/NOW/DONE in prose is drift). NOW (`not terminal` + tool line) and DONE (`terminal` +
  resultPreview) are MUTUALLY EXCLUSIVE. Body: `about` = promptPreview wrapped; `▸` + lastToolName +
  `· ` lastToolSummary + `· ` age (`formatElapsed(now − UnixMilli(*lastProgressAt))`, D31) while live;
  `done` = resultPreview capped via `truncate` (D31 N=300). A selected-agent HEADER row via the
  existing `workflowAgentLine` carries glyph/label/model-family/tokens/elapsed — so model/tokens
  appear via the reused row (consistent with the list it drilled from), NOT as extra pane chips. Every
  field individually omitted when its pointer is nil — nothing labeled "thinking" (the wire carries
  none), nothing fabricated. **attempt-int invariant:** `Attempt` stays plain `int` (D30) — a
  `workflow_agent` node always carries `promptPreview`+`attempt` together, so the Go `agentHasDetail`
  predicate keys on the 4 `*string` pointers and an attempt-only-no-prompt node does not occur.

### Wave 4 — the COCKPIT round (2026-07-18). Decisions D40–D46 (execution map + needs-you + steer paper; every load-bearing choice PROVEN by running against the 820-value real resultPreview corpus, the live guerrilla wire, and probe-red byte-locks)

- **D40 — Snippet extraction is truncation-tolerant BARKPARK-vocab key-regex; codex SNIPPET_KEYS are NOT ported (proven on all 820 real captures).** 0/820 real resultPreview values parse as JSON — 817 truncate at exactly 401 chars ending `…` (upstream cap; recorder.ex applies none), and the codex extractor renders literal brace-noise on 813/820 (its parse-first path throws on 820/820). Its vocabulary (headline/verdict/recommendation/…) occurs ZERO times in real data; Barkpark's agents write `direction/summary/title/test_summary/evidence/notes`. Algorithm (`agentSnippet(resultPreview string) string`, render.go): (1) TrimSpace; empty → "". (2) DEFENSIVE whole-parse (json.Unmarshal → map) → first present key — exercised by ZERO real fixtures, so a SYNTHETIC untruncated-object fixture is MANDATED (D29/D37 precedent). (3) truncation-tolerant key-regex, KEYS in priority order `direction, summary, title, test_summary, evidence, notes` — pattern `"<k>"\s*:\s*"((?:\\.|[^"\\])*)` (RE2-safe; captures to end-of-string when the closing quote was clipped); unescape `\n \t \" \\ \/`, DROP a dangling trailing backslash. (4) bare-prose fallback (payload not starting `{`): strip leading md markers, first line, first sentence — first-sentence extraction applies ONLY here. (5) clean: newlines/tabs → space, collapse whitespace, strip trailing `…`/`...`. (6) all fail → "" (render NOTHING) — NEVER brace-noise. Key-extracted values go FULL to render's existing width truncate (D31) — the summary/title IS the headline. Truncation trigger is WELL-FORMEDNESS (ellipsis), never length. This is RENDER-side interpretation, explicitly distinct from D28's FOLD-side never-re-parse law (the fold still passes verbatim). Snippets paint ONLY under SETTLED agents, as a dimmed second line. Proof run: 813 regex / 7 prose-fallback / 0 empty / 0 brace-noise on 820.

- **D41 — The stall badge is HONESTY-GATED: `no progress since <clock>`, never `stalled <age>`; needs-you outranks; NO crashed/stopped state EVER.** Code-confirmed: `lastProgressAt` is deliberately excluded from the persistence signature (studio_chat.ex:895-898) and the TUI's copy refreshes only at the 4 FetchTailEffect sites — staleness is unbounded in principle (frozen across one long tool call), so a naive `now−lastProgressAt>90s` verdict would FABRICATE stalls. The badge (non-terminal agents only, warn token) reads `no progress since <HH:MM>` — a phrasing that stays TRUE under any client-side staleness; show it when age > 90s. Precedence: a pending answerable card suppresses every stall badge — WAITING is never stalled (the studied fleetStatus law: stalled is computed only when no question is pending). bp has NO pid/liveness signal — never render `crashed`/`stopped`/`dead`.

- **D42 — Refetch-on-expand: ONE-SHOT FetchTailEffect on the collapse→expand EDGE; no polling; RESOLVES wsc-bl-workflow-sse-detail.** Wired surgically in keys.go's expand branch via the designated single dispatch site (`m.execEffect(FetchTailEffect{SinceSeq: m.st.LastSeq})`) — lands in the same idempotent reduceTailFetched merge path; edge-gated by `!m.wfExpanded` so it cannot re-fire. Cost accepted eyes-open: one measured 38,308-byte full-session GET per discrete user action (the D20 no-raw-rail law targets ROUTINE/broadcast paths; a user-action GET is the same risk class as the accepted turn-boundary refetch). The "slow cadence while expanded" idea is REJECTED — it reopens the polling question D13 settled. This decision ANSWERS backlog `wsc-bl-workflow-sse-detail`'s design question (on-expand refetch, not a richer wire frame) — that task closes with a pointer here.

- **D43 — The terminal result box ships on RAIL TRUTH + the cached picker epic; NO new wire this wave (the refetch lever was PROVEN unable to freshen the grade line).** Proven three ways (live wire + controller + Go types): `epic`/wave_status rides ONLY the sessions-LIST wire (`sidebar_json` + `put_epic`); `full_session_json` structurally has no `:epic` key, Go `ChatSession`/`State` have no Epic field — so FetchTailEffect can NEVER carry a grade line. Worse: live guerrilla shows 0/4 workflow sessions with an epic key, because `epic_goal` resolves via the session's OWN worker holding a parented in_progress slice — the watched launcher session holds none (the same D32 join gap). Box content = `EntryStatus` verbatim (`completed`/`interrupted`) + settled/total + tokens + FIRST-CLASS failed surfacing (`✕ N failed` whenever `j.Failed > 0` — today j.Failed renders NOWHERE at summary level; a "completed" entry can carry failed agents) + the grade line ONLY from the cached picker Epic (`m.sessions` lookup by `st.SessionID`, ~10-15 lines, render-only) when `WaveStatus` contains the `complete — grade` substring (validated safe against 3 real ledger strings; 0 false positives on non-complete strings). An interrupted wave is NEVER dressed up with a stray resultPreview. Widening `session_json` with epic + making `epic_goal` resolve for launcher sessions goes to backlog `wsc-bl-epic-on-session-json`, sequenced BEHIND the steer paper's join design (D46) — shipping the wire first would be a null field, the D32 dead-affordance trap.

- **D44 — D35 amended: ONE `visibleAgents(phase)` projection pins running agents; the cap STAYS `workflowDetailMaxAgents=8`; the codex `16` is a full-screen constant and is NOT ported.** The agent cursor clamps to the PAINTED (visible) list, not a raw `min()` against the phase length. A new pure projection `visibleAgents(phase)` pins every running agent (wire order) and backfills with settled agents up to the cap, returning the painted nodes, their row→agent index map, and a SETTLED-only overflow count. ALL THREE current consumers — the row-list painter (render.go:746), the third-level detail slice (render.go:498), and the Up/Down cursor clamp (keys.go:257) — read this one projection, so paint == addressable == cursor range BY CONSTRUCTION (probe proved today's bug: running agents at wire index 9 and 17 in an 18-agent phase are silently folded into `+10 more`, cursor-unreachable, detail-pane nil). The detail pane indexes `visible[wfAgent]` through the index map, NEVER `phase.Agents[wfAgent]` directly — missing this makes the detail level address the WRONG agent while the row list looks correct; a test asserts detail-pane-agent == painted-row-agent on a >8 mixed phase. Edge rule (running > 8): pin the first 8 running in wire order; the overflow suffix then reads `… +N more (M running)` so hidden live agents are never silent. Transcript budget stays 8. A SYNTHETIC >8-agent mixed fixture is MANDATORY — no real fixture exceeds 5 agents/phase, so the collision is invisible to the existing suite.

- **D45 — needs-you: the pill REPLACES the tick-line status word (needs-you > working, the strip_kind law); Enter-jump rides a single-accumulator offset walk; ZERO new data wire.** Data is already complete on both surfaces: `answerable()` covers approval+question+plan on the open session (fresh mid-turn via the permission-frame refetch), and `pending_approvals` is the deliberately role-WIDENED counter on the list wire. Paint: the collapsed strip flips `⏸ needs you — approval pending` (warn token) and the tick-line status word `working` is REPLACED in place — never a fourth line, never side-by-side (ports Studio's `session_pill`/`strip_kind` single-badge precedence: pending ask beats running turn). Enter-jump: a needs-you branch AHEAD of the expand branch in handleWorkflowKey (composer Enter still sends; expanded-panel Enter still drills). Offset: refactor `transcriptLines` into ONE shared accumulator that optionally captures the start line of the target RequestID's block (`transcriptLines()` stays a thin wrapper — no forked walk to drift); `m.scroll` is set Home-style, clamped to `[0, maxScrollTop]`; the jump targets `m.focusedCard()` (cardCursor untouched) and sets `m.focus = focusComposer` after, mirroring the Esc-pop, so arrows scroll again immediately. Also close the pre-existing `answerFocused` asymmetry (it never resets m.focus) under the same criterion. NAMING FIX: the idle-geometry byte-lock is charter **D11** (render_test.go:737 tags it so) — earlier prose calling it "the D14 byte-lock" collided with the chat-tui charter's D14 focus law; use D11.

- **D46 — Steer is a PAPER this wave (design-first HELD against the code-first rival); its ratified fact-base.** Claude-lane builders are bound to sessions by NOTHING — a hard architectural fact, not an unused feature: Task-tool subagents claim under `epic-builder-<slug>` worker strings; the ONE persisted binding (`epic_assignment_runtime_attempts`) is DB-CHECK-constrained `provider='codex'` AND `execution_target='managed'` (CycleFleet is the Cloud MANAGED fleet product, a separate system — structurally unusable for the claude lane); the hand_tasks fold is exact-worker `==` at both its live and hydrate paths. The taxonomy MUST split by lane: the claude adapter steers mode/model ONLY (closed enum — safe/proven); codex's ONLY steer verb is live TEXT INJECTION into a running turn (`turn/steer` — a materially different risk row, never folded into the same "safe" bucket); same-PID mid-turn queue (`send_turn`) is safe/proven. Claude-lane fleet steering can only be ASYNC task-layer mutation (note/patch the builder's claimed task — no PID is reachable from another session). D32 cost-split CORRECTION for the paper: the `parent_id` WHERE-fragment filter is CHEAP (shipped precedent: `epic_slice_counts/1`); the REAL unproven cost is the slug-join across the two divergent emitter label shapes + degrade-on-ambiguity. Race/cancel are OUT (engine limit). Deliverable: a published Paper + 1-3 follow-up slice specs (including whether `wsc-bl-epic-on-session-json`'s launcher-epic resolution rides the join design), or a documented no-go.

## Roadmap

Wave 1 (this wave — all five pre-filed, perfected at Decide):
1. **wsc-s1** `task-e24d433d072ee8c0` — `workflow_summary/1` pure fold (D1–D4 shape contract)
   + shared parity fixtures. Elixir. **medium**. Blocks all.
2. **wsc-s2** `task-a232a271f4007966` — Recorder `{:chat_workflow}` change-only broadcast (D6)
   + `end_time` rail stamp (D5). Elixir. **medium**. After s1; blocks s3's live path.
3. **wsc-s3** `task-8c92a966b28eda80` — Studio sidebar two lines, live+cold; compact wire
   summary (D10); epic-goal line (D8/D9); sidebar golden region (D11). Elixir. **large**.
4. **wsc-s4** `task-8059027150fc6680` — bp chat session-list mirror decoding the compact wire
   summary (D12). Go. **medium**. After s1 (contract), parallel to s3.
5. **wsc-s5** `task-a0e41d82867633dc` — below-composer workflow panel: strip → focus → expand
   → collapse (D13–D15). Go. **large**. After s4 lands (file overlap), else after s1.

Wave 2 (2026-07-17 — land the stranded flagship, then push past the honesty ceilings):
1. **wsc-s3** `task-8c92a966b28eda80` — SALVAGE + land (Path B, D17). Studio sidebar two lines
   + compact wire (D10) + epic-goal (D9) + sidebar golden (D11). Elixir. **large**. Round 1
   (builds this run). Also the API producer the merged Go card waits on (D18).
2. **wsc-bl-real-fixtures** `wsc-bl-real-fixtures` — REAL interrupted fixture from a disposable
   session + documented-proof close of attempt>1 (D21). Elixir/testdata. **medium**. Round 2,
   AFTER s3 merges (collides on studio_chat_test.exs; hardens s3's landed producer).
3. **wsc-bl-workflow-sse** `wsc-bl-workflow-sse` — live workflow SSE frame carrying the COMPACT
   summary (D20), removes the D13 mid-turn lag ceiling. Elixir + Go. **medium**. Round 2, AFTER
   s3 merges (touches chat_controller.ex/recorder.ex on the D16 spine).

Wave 2 · round 2 (2026-07-17 — s3 IS MERGED #3865, so both picks are ROUND 1 THIS RUN):
1. **wsc-bl-real-fixtures** `wsc-bl-real-fixtures` — REAL interrupted capture (disposable
   SIGKILL or D62 verbatim-node-replay) + scoped attempt=1 corpus test (D21/D25). Elixir/testdata.
   **medium**. Round 1. Files: studio_chat_test.exs + a NEW ndjson only. Land FIRST (test-only).
2. **wsc-bl-workflow-sse** `wsc-bl-workflow-sse` — wiring (a) `event: workflow` frame (D22/D23) +
   wider Go footprint (D24). Elixir + Go. **medium**. Round 1 (disjoint files from real-fixtures).
   Merges after real-fixtures; NEVER before Elixir Test green (touches recorder.ex/chat_controller.ex).

Wave 3 (2026-07-17 — the AGENT-DETAIL round; D26–D34; GUI round 1, TUI round 2):
1. **wsc-ad-gui** `task-a4a49ad69f3c8ab8` — Studio rail `workflow_agent` rows EXPAND to
   ABOUT/NOW/DONE + attempt chip; NEW pure `workflow_agent_detail/1` fold + dual-mirror fixture +
   strip extension (D26) + structural affordance gate (D27). Elixir. **large**. Round 1 (builds this
   run). opus. Authors the shared fixture the TUI reads.
2. **wsc-ad-tui** `task-3be0030a7769861d` — third focus level on the s5 panel (Enter→agent detail,
   Esc/left back), additive `wfAgent`+`wfAgentDetail` (D30), Go `WorkflowNode` +6 fields, field
   projection parity. Go. **large**. Round 2, `after:[wsc-ad-gui]` (needs the fixture on main). opus.

Wave 4 (2026-07-18 — the COCKPIT round; D40–D46; all three round 1):
1. **wsc-map-inline** `task-85306c724906c02d` — execution map: settled-row snippets (D40 extractor),
   stall badge (D41), refetch-on-expand (D42), terminal result box (D43), visibleAgents projection
   (D44). Go/internal/chat. **large**. Round 1. fable.
2. **wsc-needs-you** `task-8596bfb8188aa880` — needs-you pill + strip flip + Enter-jump-to-card
   (D45). Go/internal/chat. **medium**. Round 1 (function-level disjoint from map-inline; same
   files render.go/keys.go — lead merges map-inline FIRST, needs-you rebases). opus.
3. **wsc-steer-design** `task-b399a1068ea742f6` — the steer decision PAPER (D46 fact-base). No
   code. **medium**. Round 1. fable.

Backlog (filed, published, NOT this wave — PARKED per D19):
- **wsc-bl-epic-on-session-json** — widen `full_session_json` with `epic` (reuse `put_epic`) + Go
  `ChatSession.Epic` + State hydration, AND make `epic_goal` resolve for the watched LAUNCHER
  session (today it resolves via the session's own worker holding a parented slice — launcher
  holds none, so 0/4 live workflow sessions carry epic). Filed at Wave-4 Decide (D43): shipping
  the wire first would carry a null field (the D32 dead-affordance trap); sequenced BEHIND the
  D46 steer paper's join design.
- **wsc-bl-agent-task-join** — the claimed-build-task INTERMINGLE (agent row ⇄ its bp task become one
  row: pulse now-line + criteria count + `?task=` deep-link). Filed at Wave-3 Decide (D32): descoped
  from wsc-ad-gui/tui because the existing hand-task fold is exact-worker-scoped and cannot see the
  subagent `epic-builder-<slug>` claims, and the two emitter label shapes diverge. Needs the fold
  broadened by epic `parent_id` + a last-segment slug join — real query work, out of the pure-
  presentation scope this wave. Not fabricated; deferred on evidence.
- **wsc-bl-agent-detail-fixture-gaps** — a genuine codex-origin row + a workflow-less background-origin
  row fixture (Go + Elixir) asserting `workflow_agent_detail/1` projects empty (no affordance) for
  them. Filed at Wave-3 Decide (V5 gap): no committed fixture exercises the no-affordance path today —
  it is proven only by code trace, not by a test. Low-risk hardening.
- **wsc-bl-prs-open** — real "PRs open" source for the epic-goal line. Parked: net-new
  github-PR subsystem + reverses a tested D8 decision; zero parallelism benefit vs waiting on s3.
- **wsc-bl-busiest-child** — fleet-phase busiest-child now-line. Parked: D7 holds, no signal.
- **wsc-bl-workflow-sse-detail** — **RESOLVED at Wave-4 Decide (D42)**: the design question is
  answered as on-expand refetch (one-shot FetchTailEffect on the collapse→expand edge), built
  inside wsc-map-inline; no richer wire frame. Task closes with a pointer to D42.
- **wsc-bl-completed-line-source** — the completed-wave line "complete · grade · n/n merged"
  (design-map block 5) has no grade/merged-count data source today; honestly renders
  "complete · n/n". Same honesty class as D8. Backlogged, not fabricated.
- **wsc-bl-mock-fidelity** — cosmetic mock-fidelity gaps (epic-goal glyph `⌖` vs shipped `↳`;
  settled/total counter not in `tabular-nums`; Go renders raw "completed" vs Studio "complete").
  Deferred; s3 lands as the reviewed spec verbatim.

## Wave log

### Wave 1 (2026-07-16) — close-out (debt paid at Wave 2 Decide; Review never ran)
Five slices filed and built; the merge train landed PARTIALLY and the log was never written.
- **wsc-s1** `task-e24d433d072ee8c0` → **#3836 MERGED** — `workflow_summary/1` pure D3 fold +
  shared parity fixtures (Go+Elixir mirrors byte-identical).
- **wsc-s2** `task-a232a271f4007966` → **#3838 MERGED** — Recorder `{:chat_workflow}` change-only
  broadcast (D6) + `end_time` rail stamp (D5). Producer fires on `activity_topic()`.
- **wsc-s4** `task-8059027150fc6680` → **#3837 MERGED** (ledger `done`) — bp chat session-list
  decodes the compact `workflow` + sibling `epic` wire fields.
- **wsc-s5** `task-a0e41d82867633dc` → **#3839 MERGED** — below-composer workflow panel.
- **wsc-s3** `task-8c92a966b28eda80` → **BUILT + REVIEWED, NEVER PUSHED** (`7280968a0`, gate
  500/0). The stranded flagship. Its absence left the merged s4/s5 Go card inert (D18). Wave 2
  lands it. The first build `bfa771898` had a real bug (diverged `%{state,…}` reading `endTime`
  + a `{:chat_workflow}` overlay that KeyError'd on s2's D3 broadcast); the reviewer's `-2-r`
  branch fixed it to one canonical `workflow_summary/1` ticks-based render. That reviewed tree
  is the salvage spec.
- Ledger drift: s1/s2/s5 sat merged-but-open with lapsed claims; the stale duplicate charter PR
  **#3823** (pre-D16, would revert D16) was closed as superseded-by-#3826 at Wave-2 Decide.

### Wave 2 (2026-07-17) — s3 LANDED (#3865); backlog deferred to round 2
Decide reconciled with reality (both the lead note AND the ledger were wrong: s3 is built, not
unbuilt). This wave lands the stranded s3 (Path B salvage, verified 500/0 + byte-identical
golden on today's main) and pulls the two highest-value honesty-ceiling backlog items
(real-fixtures round-2, workflow-sse round-2 — both after s3 merges). Decisions D17–D21 folded
above. Wave Paper: `wsc-wave-2026-07-17`. Review will append the debrief.


**Outcome (steward close-out 2026-07-17):** wsc-s3 LANDED — **#3865 MERGED** to origin/main.
The reviewed salvage tree (852e21b44) was based on a stale main (5518decd8); origin had advanced
past site-spawner W6 (deploy_runner.ex), so a naive merge would have reverted W6. Steward
cherry-picked the clean 8-file/1055-line s3 commit onto current origin/main (`wsc-s3-land`),
Elixir Test green, Sobelow verified stale-baseline noise (router.ex CSRF only — s3 touches no
router/pipeline file). `task-8c92a966b28eda80` closed done (6/6 criteria; #3865 evidence).
D18 confirmed live: s3 is the API producer the merged s4/s5 Go card waited on — three-surface
truth now complete. Stale pre-D16 charter dup #3823 CLOSED. Backlog round-2 (wsc-bl-real-fixtures,
wsc-bl-workflow-sse) NOT built this wave — they serialize behind s3 and are a future round.

### Wave 2 · round 2 (2026-07-17) — BOTH picks MERGED (#3909 + #3910)
Wave Paper: `wsc-wave-2026-07-17-r2` (style=article). s3 (#3865) is MERGED and LIVE on guerrilla,
so both picks are unblocked and dispatch as ROUND 1 (disjoint file sets — build in parallel).
Decide ran two explore rounds; five verifiers PROVED the seam (no rumor survived). Decisions
D22–D25 folded above. Two slices dispatched:
- **wsc-bl-real-fixtures** — REAL interrupted capture from a DISPOSABLE session (SIGKILL not
  SIGTERM — the signature is the ABSENCE of a terminal result frame; verifier reproduced it on
  live wire bytes) OR the D62 verbatim-node-replay path, folded through fold_rail→workflow_journey
  →workflow_summary, + a `workflow_agent`-scoped attempt=1 corpus test (D25). Test-only
  (studio_chat_test.exs + a NEW ndjson). Baseline 157/0 green. LAND FIRST. opus.
- **wsc-bl-workflow-sse** — wiring (a) `event: workflow` SSE frame (D22, proven 3-file/221-0),
  workflow-only + unreplayable (D23), wider Go footprint incl render.go collapsed-strip (D24).
  Elixir + Go. Gates on Elixir Test; merges after real-fixtures. opus.
Known main-flakes to rerun-once (NOT real breaks): queue_test.exs:462 planner-sensitivity +
the sandbox-ownership DBConnection cascade (media_search / history_test:15 / rate_limit:24).
New backlog filed: **wsc-bl-workflow-sse-detail** (D24 expanded-detail ceiling). PARKED still:
prs-open, busiest-child (honesty star holds them). Review appends the debrief.


**Outcome (steward close-out 2026-07-17):** BOTH round-2 slices LANDED.
- **wsc-bl-real-fixtures → #3909 MERGED** — REAL SIGKILL-interrupted ndjson + `workflow_agent`-scoped attempt==1 proof; test-only (Elixir + prod-compile green, no Go gate, Sobelow test-only noise). Task closed done.
- **wsc-bl-workflow-sse → #3910 MERGED** — the `event: workflow` SSE frame + per-session `Recorder.topic` re-broadcast + Go `LiveWorkflow` state/reduce/render. Its `.go` change exposed a LATENT foreign scaffy Go-gate drift on main (`corpusFileCount=7` vs 12 files) — fixed by foreign #3912 (7→12); steward then rebased #3910's sse commit clean onto the fixed main, go-vet + Elixir green, Sobelow verified baseline noise (touches recorder/chat_controller, NO router/pipeline). Task closed done.
Wave-2 round-2 COMPLETE — all five surfaces now honest on prod-shaped interrupted data + bp chat's strip updates mid-turn. Remaining backlog: **wsc-bl-workflow-sse-detail** (D24 expanded-detail ceiling) + the newly-filed agent-detail slices **wsc-ad-gui / wsc-ad-tui** (see-what-subagents-are-doing); PARKED by honesty-star: prs-open, busiest-child.
### Wave 3 (2026-07-17) — AGENT-DETAIL round: wsc-ad-gui MERGED (#3959); wsc-ad-tui deferred
Wave Paper: `wsc-wave-2026-07-17-ad` (style=article). Drills the workflow card one level to per-agent
detail. Two explore rounds + a 15-report survey digest + a 7-verifier PROVE round ran; decisions
D26–D34 folded above. Every load-bearing claim was proven by RUNNING (not reading): V1 reproduced the
signature-strip FREEZE and the fix, V2 resolved node-vs-frame field location + `attempt` cardinality by
jq, V3/V4 ran the Elixir (167/0) and Go (4 locks + vet) baselines green on origin/main and proved the
freshness gate non-vacuous, V5 caught the origin-gate TRAP (all fixtures are background-origin WITH
detail), V6 confirmed the two committed captures carry populated detail (no fresh capture needed), V7
killed the "zero new subscription" intermingle premise. Two slices dispatched:
- **wsc-ad-gui** `task-a4a49ad69f3c8ab8` — Elixir, **large**, round 1, opus. Gate:
  `cd api && CC=clang mix test test/barkpark/studio_chat_test.exs test/barkpark_web/live/studio/chat_render_golden_test.exs`.
- **wsc-ad-tui** `task-3be0030a7769861d` — Go, **large**, round 2 `after:[wsc-ad-gui]`, opus. Gate:
  `cd internal/chat && CC=clang go vet ./... && CC=clang go test ./...`.
The claimed-build-task intermingle was DESCOPED to `wsc-bl-agent-task-join` (D32 — the existing fold
can't see subagent claims; shipping it half-wired is a dead affordance). New backlog:
`wsc-bl-agent-task-join`, `wsc-bl-agent-detail-fixture-gaps`. Known main-flakes to rerun-once (NOT
breaks): queue_test.exs:462 + the sandbox-ownership cascade (media_search / history_test / rate_limit).
Review appends the debrief.


**Outcome (steward close-out 2026-07-17 — Review DIED on a session limit, so this is the steward debrief):**
- **wsc-ad-gui → #3959 MERGED.** The Studio rail per-agent drill-down: `workflow_agent_detail/1` pure fold + the D26 rail signature-strip extension (retains lastToolName/lastToolSummary/resultPreview/attempt/promptPreview — without it a detail-only frame yields an equal signature and the pane freezes) + chat_live.ex expand UI (structural affordance gate, D27) + dual-mirror Go+Elixir testdata. Built off a stale base; steward cherry-picked clean onto current origin/main. One steward fix: the attempt chip used non-existent `--warning`/`--warning-soft` tokens with rgba/hex literal fallbacks (tripped the Studio literal-color gate) → canonical `--warn-soft`/`--warn`. Elixir + go-tests green, Sobelow verified baseline noise (no router/pipeline). Task closed done.
- **wsc-ad-tui → NOT built this run.** It is round 2 `after:[wsc-ad-gui]` (needs the GUI fixture on main, D34) and the Review phase errored on a session limit before round 2 dispatched. The GUI fixture is now on main, so wsc-ad-tui is a clean follow-up round (Go TUI third focus level; consumes the same dual-mirror `workflow_agent_detail.json`).
Backlog carried: `wsc-bl-agent-task-join` (D32 intermingle), `wsc-bl-agent-detail-fixture-gaps`, `wsc-bl-workflow-sse-detail`; PARKED: prs-open, busiest-child.

### Wave 3 · round 2 (2026-07-17) — the ad-tui FINISH round: wsc-ad-tui MERGED (#3979) — EPIC COMPLETE
Wave Paper: `wsc-wave-2026-07-17-ad-tui` (style=article). Finishes the stranded wsc-ad-tui (Review
died on a session limit last round; the GUI dependency is now MERGED). ONE slice this wave. Two
explore rounds + a 12-report survey digest + a 3-verifier PROVE round ran; every load-bearing claim
proven by RUNNING: the Go baseline gate is GREEN (vet zero output + `go test` ok first run, single
package), the decode+derive parity PASSED 0-mismatch on all 34 fixture nodes with the 6 additive
fields, and the seam blueprint re-anchored at HEAD (`KeyLeft/KeyRight` unclaimed, byte-lock tests all
pass). Decisions D35–D39 folded above (Enter-then-arrow grammar, Go-derives-terminal/failed at 6
frozen fields, synthetic-honesty test MANDATE, 5-seam reset list, presentation mirrors GUI code).
- **wsc-ad-tui** `task-3be0030a7769861d` — Go/bp chat, **large**, **round 1** (dep MERGED), opus.
  Third focus level on the s5 panel: Enter→agent detail (chip→about→▸now/done), Esc/left back; additive
  `wfAgent`+`wfAgentDetail`; Go `WorkflowNode` +6 fields; field-projection parity + synthetic-honesty
  unit test. Gate: `cd internal/chat && CC=clang go vet ./... && CC=clang go test ./...`.
Builder cuts off origin/main (advances fast — foreign scaffy/connectors/site-spawner); steward rebases
the `-r` branch (cherry-pick the slice commit) before PR. If repo-wide go-tests red, `gh run rerun
<run> --failed` FIRST (recurring sandbox flakes + foreign scaffy corpus-count drift — not this slice's
break). Backlog carried unchanged. Review appends the debrief.


**Outcome (steward close-out 2026-07-17):** wsc-ad-tui → **#3979 MERGED**. bp chat's workflow panel gains a THIRD focus level (Enter → per-agent detail: about=promptPreview / ▸now=lastTool+age / done=resultPreview + attempt>1 chip; Up/Down cycle agents; Esc/left pops back; composer keeps every key). 6 pointer fields on Go `WorkflowNode` (decode-only, Mechanism A — wire already carries them); terminal/failed Go-DERIVED from State; additive `wfAgent`/`wfAgentDetail` (never a depth int); composer-safety proven (no KeyRunes claim); field-projection parity 0-mismatch on all 34 fixture nodes + a SYNTHETIC thin-node test for the D27 no-affordance honesty star. The cycle's Review recovered a mid-pipeline StructuredOutput failure via resumeFromRunId (20 agents, grade A). Steward cherry-picked the 2 Go commits clean onto current origin/main (base stale); the reviewer's own charter-outcome commit conflicted with origin's D35-D39 and was skipped — THIS entry reconciles it. go-tests + Elixir green (Go-only), Sobelow n/a, task closed done.

**The AGENT-DETAIL round is COMPLETE across BOTH surfaces (Studio #3959 + bp chat #3979).** The Wave Session Card epic is at DESIGNED COMPLETION — every merged surface drills from the workflow card into per-agent detail, honest and quiet. All remaining backlog is deferred-by-design: `wsc-bl-agent-task-join` (D32 intermingle), `wsc-bl-agent-detail-fixture-gaps`, `wsc-bl-workflow-sse-detail` (D24 ceiling); PARKED by the honesty star: `wsc-bl-prs-open`, `wsc-bl-busiest-child`.

### Wave 4 (2026-07-18) — the COCKPIT round: execution map + needs-you + steer paper (D40–D46)
Wave Paper: `wsc-wave-2026-07-18` (style=article). The user's wish (learn from the studied
scasella/claude-dynamic-workflows-codex clone) becomes bp chat's cockpit wave: inline result
snippets on the execution map, honest stall visibility, a needs-you state that jumps to the gate,
and the steer design paper. A 14-surveyor survey + 6-verifier PROVE round ran; every flagship
choice was settled by RUNNING, and two attacks on the direction LANDED and were absorbed:
- Snippet extraction: 0/820 real resultPreview values parse as JSON; the codex extractor renders
  brace-noise on 813/820 — "headline-first" was MISCALIBRATED. D40's truncation-tolerant
  Barkpark-vocab extractor was prototyped and run: 813 regex / 7 prose / 0 empty / 0 brace-noise.
- The result-box freshness lever was REFUTED live: `epic` rides only the LIST wire; the single
  GET has no epic key and 0/4 live workflow sessions carry epic at all (launcher worker holds no
  parented slice). D43 narrows the box to rail truth + cached picker epic; wire widening filed as
  `wsc-bl-epic-on-session-json` behind the D46 join design.
- The collapse probe proved TODAY's bug (running agents at wire index ≥9 silently folded and
  cursor-unreachable) and sized both fixes: D44 ships the pin-running `visibleAgents` projection
  at cap 8; the codex `16` is not ported.
- Both byte-locks proven fail-before by probe edits going RED then reverted (geometry lock =
  charter D11; the "D14 byte-lock" label was a mislabel — fixed in D45).
Three slices dispatched (all round 1):
- **wsc-map-inline** `task-85306c724906c02d` — Go, **large**, round 1, fable. D40-D44. Gate:
  `cd internal/chat && CC=/usr/bin/clang go vet ./... && CC=/usr/bin/clang go test ./...`.
- **wsc-needs-you** `task-8596bfb8188aa880` — Go, **medium**, round 1, opus. D45. Same gate.
  Function-level disjoint from map-inline but SAME FILES (render.go/keys.go) — lead merges
  map-inline first; needs-you rebases before merge.
- **wsc-steer-design** `task-b399a1068ea742f6` — design paper, **medium**, round 1, fable. D46.
  Gate: paper published + linked to the task.
Dispatch freshness: origin/main green (04893e486); all three slices unclaimed; the epic claim is
LAPSED (epoch 12, steward-adtui-fin) — RE-CLAIM before any PR opens or pr-task-gate fails.
Backlog: `wsc-bl-workflow-sse-detail` CLOSED (resolved by D42); NEW `wsc-bl-epic-on-session-json`.
Review appends the debrief.


**Outcome (Review 2026-07-18): ALL THREE slices GREEN — grade A.** Zero code defects found; the
reviewer's only hands-on work was the cross-slice integration the plan already mandated.
- **wsc-map-inline** `task-85306c724906c02d` → branch `loop-epic/wsc-map-inline-tui-panel-becomes-an-exec-0`
  (d98510eb8) reviewed AS-IS, no fixes. D40 extractor adversarially checked (escape-pair handling,
  dangling-backslash clip, RE2 unterminated tail) — sound; the 820-preview corpus test + synthetic
  whole-parse fixture + the mandated 18-agent D44 fixture all pin real behavior (cursor==paint==detail
  proven, running at wire 0/9/17 never folded). Gate + gofmt + vet green. MERGE FIRST.
- **wsc-needs-you** `task-8596bfb8188aa880` → **final branch `loop-epic/wsc-needs-you-workflow-strip-panel-surfa-1-r`**
  (5011ba668): the reviewer performed the mandated rebase onto map-inline and resolved the two
  render.go/model_test.go conflicts — the combined tree is PROVEN coherent (needsYou ⇒ stall badges
  suppressed by construction; banner and badges can never co-render; full gate -count=1 green on the
  merged tree). Lead merges map-inline, then this -r branch lands needs-you conflict-free.
- **wsc-steer-design** `task-b399a1068ea742f6` → paper `wsc-steer-fleet-design` published/linked;
  gate re-run GATE_PASS. Reviewer re-verified the ONE citation the builder inherited unverified:
  `Capabilities.codex()` DOES advertise `modes: []`/`models: []` (capabilities.ex:146-164) — the
  mode/model crossover branch is confirmed unreachable. Migration CHECKs, claude closed-enum steer,
  codex turn/steer injection all re-confirmed at cited lines. Follow-ups real: `wsc-steer-open-session-managed`
  filed+published, `wsc-bl-agent-task-join` perfected, ruling recorded on `wsc-bl-epic-on-session-json`.
  Branch is an --allow-empty marker — lead may merge or discard it (the gate reads Barkpark, not git).
Ledger: honest end-to-end — all proof criteria stamped with evidence mid-build, lifecycle
in_progress, merge criteria left open for the lead (map-inline C6, needs-you C4, steer C4). No fixes
needed. Known accepted ceilings (not defects): D43 result box is short-lived (visible only while the
strip stands on a fresher live summary — the geometry byte-locks forbid a persistent post-settle
panel); stall badge has no entry-lifecycle gate (an interrupted wave's frozen agent wears it —
factually true); HH:MM is operator-local. Next: lead merges (map-inline → needs-you-r → this charter
branch), closes the three merge criteria + wsc-bl-workflow-sse-detail (D42), then the epic returns to
DESIGNED COMPLETION with the D46 build slices (`wsc-bl-agent-task-join` → `wsc-steer-open-session-managed`,
`wsc-bl-epic-on-session-json` riding the join) as the visible backlog.

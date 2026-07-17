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

Backlog (filed, published, NOT this wave — PARKED per D19):
- **wsc-bl-prs-open** — real "PRs open" source for the epic-goal line. Parked: net-new
  github-PR subsystem + reverses a tested D8 decision; zero parallelism benefit vs waiting on s3.
- **wsc-bl-busiest-child** — fleet-phase busiest-child now-line. Parked: D7 holds, no signal.
- **wsc-bl-workflow-sse-detail** — live-freshen the Enter-expanded two-pane Phases|agents
  DETAIL from a richer wire payload. Filed at Wave-2 round-2 Decide (D24): the compact summary
  structurally lacks per-agent `Nodes`, so the SSE frame can only live-freshen the collapsed
  strip; the expanded detail stays turn-boundary fresh. Needs either a richer targeted payload
  or an on-expand refetch — deferred, not fabricated.
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

### Wave 2 · round 2 (2026-07-17) — the two honesty-ceiling backlog picks BUILDING
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

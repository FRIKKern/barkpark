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

Backlog (filed, published, NOT this wave):
- **wsc-bl-prs-open** — real "PRs open" source for the epic-goal line (github-plugin PR state).
- **wsc-bl-busiest-child** — fleet-phase busiest-child now-line (needs a principled signal).
- **wsc-bl-workflow-sse** — live workflow frame over /v1/chat SSE (mid-turn TUI freshness).
- **wsc-bl-real-fixtures** — capture REAL interrupted + attempt>1 wire fixtures (studio-chat
  D62 provenance; both shapes are synthetic-only today).

## Wave log

### Wave 1 — 2026-07-16 — grade A- (review complete)

All five slices built AND review-hardened; every builder claimed within the same second, so the
D16 spine ("after s1") was impossible and THREE independent `workflow_summary/1` implementations
were born — the review's main work was collapsing them back to ONE truth table (D1). Lead merges
the -r branches in this order (stacked, integration-proven conflict-free onto origin/main;
Elixir PRs wait for the Elixir Test gate; `git branch` local — the -r branches are unpushed):

1. **wsc-s1** → `loop-epic/wsc-s1-workflow-summary-1-pure-d3-shape--0` (8b13b51d0, UNCHANGED by
   review — the canonical D3 fold + shared parity fixtures were right the first time; 150/0).
2. **wsc-s2** → `loop-epic/wsc-s2-recorder-chat-workflow-change-onl-1-r` (fda0d1b93; contains
   s1). Review dropped s2's bridge `workflow_summary/1` twin. {:chat_workflow} distinct-tuple
   broadcast + end_time stamp ride unchanged; 215/0.
3. **wsc-s3** → `loop-epic/wsc-s3-studio-sidebar-two-lines-phase-ti-2-r` (7280968a0; contains
   s1+s2-r). Review fixed TWO integration-fatal defects: s3's summary twin had DIVERGED from
   the pinned D3 shape (%{state,…} — no ticks/running/terminal?/outcome, read "endTime" where
   s2 stamps "end_time"), and the {:chat_workflow} overlay read `ws.state` → guaranteed
   KeyError on the first live ping. Now one canonical shape everywhere; the tick strip renders
   straight off `summary.ticks` (a skipped Perfect phase reads honestly un-filled); the compact
   wire pins the full canonical key set (`terminal?` serialises verbatim). Sidebar golden
   UNCHANGED (regen byte-identical). 500/0. PR body must say "amends D14".
4. **wsc-s4** → `loop-epic/wsc-s4-bp-chat-session-list-mirrors-the--3-r` (8e4e45e7c). Review
   fixed the decode to the REAL wire: `terminal?` json tag, epoch-ms *int64 timestamps (the
   string typing would have ERRORED the whole session-list decode on the first workflow row),
   sibling `epic` key (the nested epic_goal could never decode), six-state tick vocabulary
   (✕ for interrupted). Invented fixtures replaced by s1's shared workflow_summary.json —
   mechanism-A parity now real.
5. **wsc-s5** → `loop-epic/wsc-s5-below-composer-workflow-panel-str-4-r` (ed80a45be; contains
   s4-r). Builder work was excellent (1:1 journey port, honest clocks, conditional geometry);
   review only merged s4-r (import-list unions).

Integration proof: s3-r + s5-r merged onto origin/main = zero conflicts; Go gate green; 563
Elixir tests 0 failures across all five gate files. Known follow-ups: the epic-goal fold runs
3 small queries per workflow row per refresh_sessions (memoize if fleets multiply); mid-turn
TUI panel freshness stays turn-boundary (wsc-bl-workflow-sse); real interrupted/attempt>1
captures (wsc-bl-real-fixtures). Ledger: honest — two evidence rows corrected with dated
reviewer notes (s3 C1 wire shape, s4 C1 fixture parity), `review_note` stamped on all five.

**Next wave takes:** (1) lead merge train + close the five merge-gate criteria + push this
charter branch (PR #3826); (2) LIVE proof against a real running epic cycle — the epic-level
exit gate no slice could run (disposable session, Studio card + bp chat panel side by side);
(3) wsc-bl-workflow-sse for mid-turn liveness — the wish's "just like Claude Code" feel wants
sub-turn updates; (4) then wsc-bl-real-fixtures / wsc-bl-busiest-child / wsc-bl-prs-open as
data sources appear.

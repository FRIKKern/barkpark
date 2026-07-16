# Wave-Session-Card — Epic Cycle in Barkpark Chat (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Noo-Noo Disk Guardian** — is preserved verbatim at
> `.claude/workflows/bp-noo-noo-disk-guardian-charter.md`. This slot is now the memory of the
> **wave-session-card (wsc)** epic.
>
> Epic anchor: bp task **`task-c461d30da137ae74`** (published, guerrilla).
> Design paper (pre-ratified map): **`/papers/epic-cycle-session-card`**.
> Wave Papers: wave 1 **`wsc-wave-2026-07-16`** (style=article).
> Slices: wsc-s1 `task-e24d433d072ee8c0`, wsc-s2 `task-a232a271f4007966`,
> wsc-s3 `task-8c92a966b28eda80`, wsc-s4 `task-8059027150fc6680`, wsc-s5 `task-a0e41d82867633dc`.

## Vision

Barkpark Chat becomes the place you WATCH an Epic Cycle run. A session driving
`bp-epic-cycle` earns exactly two extra lines on its existing sidebar session card:
(1) seven phase ticks — done=evergreen, active=breathing, future=dim — with a
settled/total agent counter (13/17, Claude-Code-style); (2) the epic-goal line it
advances (epic title · slices closed/total · wave_status heartbeat), intermingled from
the task spine. `bp chat` mirrors the same two lines in its session list and grows the
Claude-Code below-composer workflow panel: collapsed strip → arrow-down focus → Enter
two-pane Phases|agents detail → Esc collapse. Two north stars judge everything:
**minimalism** — every idle session and plain chat renders BYTE-IDENTICAL to today,
proven by golden regions and conditional TUI geometry; **honesty** — interrupted renders
interrupted, elapsed/tokens render only when the wire carries them, never synthesized.
Later layers (NOT this epic): CycleFleet ledger cockpit, verify proof cards, burn strip,
stop/pause control.

## Decisions

- **D1 — Timestamps are READ, never stamped.** `workflow_agent` nodes already carry
  `startedAt`/`queuedAt`/`lastProgressAt` on every state and `durationMs`/`tokens`/`toolCalls`
  once terminal, persisted verbatim and DB-round-trip-proven (probe: 29/29 agents keep all
  fields after fold→signature-gate→Repo.update→reload; real guerrilla rows confirm incl. a
  439ms `error` terminal). s1 reads them; no fold stamping.
- **D2 — One truth table, ever.** `workflow_journey/1` (studio_chat.ex:1209, scc-charter
  D57–D59) is the only status/count source; `workflow_summary/1` is a projection OVER it
  (calls it; 13/17 = `summary.done + summary.failed` / `agents_total`). Parallel counting =
  auto-reject. Never enumerate agent states as `{start,done}` — `progress` is a real third
  wire state (interrupted fixture); use `workflow_node_terminal?/failed?` sets only.
- **D3 — workflow_summary/1 contract (pinned).** `nil` for rails without workflow nodes
  (plain chats pay zero); else
  `%{state, phase, phase_index, phases_total, agents_done, agents_total, tokens, started_at, ended_at, label}`
  — `tokens` = journey `summary.tokens` (settle-on-state, an honest floor while running);
  `started_at` = min agent `startedAt` (nil when absent); `ended_at` = entry `"endTime"`
  (nil until D5 lands / for legacy rows); `label` = the entry's `row.description` as ONE
  opaque string (no em-dash parsing — there is no separate name field on the wire).
- **D4 — Live broadcast = NEW distinct tuple, D45 untouched.** s2 broadcasts
  `{:chat_workflow, sid, summary}` on `Recorder.activity_topic()`, change-only, fired from
  `commit_rail` exactly when `rail_signature` changes. Probe matrix proved: this placement
  trips zero tests; reusing `{:chat_activity}` is an auto-reject (D45 refute reds AND
  chat_live.ex:1840 `activity.state` KeyErrors at runtime). D45's law is not amended.
- **D5 — Terminal elapsed comes from the wire's own end_time.** s2 widens the
  `task_updated` fold to read `patch.end_time` (today dropped — recorder.ex:1177 reads only
  status) and stamp it on the rail entry as `"endTime"`. Elapsed renders only from real
  endpoints: live = now − `started_at`; terminal = `ended_at` − `started_at`; anything
  missing ⇒ omitted. Honesty is free: interrupted agents never receive `durationMs`.
- **D6 — The wire carries the SUMMARY, never the snapshot.** List/sidebar rows gain a
  compact derived `workflow` map (+ `epic` map) — ~300B; raw `rail_snapshot` (measured
  38,308B for a 29-agent run) never rides a list surface. bp-chat-tui charter **D14 stays
  literally intact**: `chat_controller_test.exs:446`'s `refute rail_snapshot` is NOT
  flipped; new parallel tests assert the compact keys present only for workflow sessions
  and absent for plain ones.
- **D7 — Select-widen is server-side only.** `list_sessions/2`'s Ecto select gains
  `rail_snapshot` (DB→app on localhost is cheap); it is folded to the compact summary
  before any assign or JSON — the snapshot itself never leaves the app layer on a list path.
- **D8 — Epic-goal line = title · slices closed/total · wave_status. "PRs open" is DROPPED.**
  Zero data source exists anywhere (github plugin syncs Issues only; grep-proven);
  fabricating a number violates honesty. Backlogged behind a real PR-state feed.
- **D9 — Epic feed rides existing plumbing.** `hand_task_row/2` widens with `parent_id`
  (both feeding paths already hold full content — pure projection); the
  `documents:<dataset>` fold gains a SIBLING clause matching `doc_id == a held task's
  parent_id` (the current `claim.worker + in_progress` filter provably drops epic
  broadcasts); one `parent_id` hop = the epic goal (7-epic corpus proof, all direct
  children). A shared helper `epic_goal_line(session)` (via
  `Runtime.worker_id(provider, session_id)`) serves both ChatLive and `sidebar_json`,
  computed ONLY for sessions whose rail carries workflow entries.
- **D10 — Busiest-child line DROPPED this wave.** No ranking signal exists (task_index has
  no recency/cost field; `busiest` has zero precedent); inventing one violates honesty.
  Backlogged.
- **D11 — Minimalism is proven, not asserted.** Studio: a NEW sidebar-scoped golden region
  (the existing transcript golden excludes the sidebar by construction; slice out
  `session_stamp` text — the sidebar's only clock read; cold mounts have an empty activity
  overlay) plus a with-vs-without-rail rendered-row diff. TUI: footer stays exactly 3 lines
  and list rows unchanged when no workflow — `bodyHeight`'s `height-5` becomes conditional,
  goldens lock both shapes.
- **D12 — TUI freshness = turn boundaries, accepted.** `FetchTailEffect` fires only on
  open/result/permission/answer/wedge-timeout (proven; the 100ms tick never refetches), and
  no PubSub→SSE bridge exists (topic mismatch AND `stream_loop` drops foreign tuples). The
  panel may lag mid-turn; a live SSE workflow frame is a backlogged follow-up, never a
  poll-harder hack.
- **D13 — No Go port of the summary fold.** s4 renders the compact wire fields verbatim
  (one-truth-table across surfaces). Only s5 decodes `entry.workflow` nodes — for the OPEN
  session's detail panel — and its phase-glyph derivation is locked by field-projection
  parity fixtures generated from the Elixir fold (mechanism-A pattern, NEW fixture pair —
  never an extension of the reply-body parity harness).
- **D14 — s5 interaction contract.** Strip renders below the composer only while the open
  session's rail has a live workflow. Arrow-down from the composer focuses the strip
  (KeyDown becomes conditional; otherwise `scrollBy` exactly as today); Enter expands the
  two-pane Phases|agents detail; up/down selects phase; Esc collapses to composer. Typing
  in the composer NEVER leaks into the panel (new `focusZone` field on Model, regression-
  tested). View-only — stop/pause has no wire primitive and stays parked.
- **D15 — Fixture-only shapes render defensively.** `attempt>1` and entry status
  `"interrupted"` have ZERO real-world captures (guerrilla sweep: all 39 entries
  completed/failed, every attempt=1). No attempt-specific UI; states via the shared sets;
  a real-capture task is backlogged (D62 provenance law).

## Roadmap

Integration order: **s1 → s2 → (s3 ∥ s4 → s5)** — s1 pins field shapes (blocks all);
s2 blocks only s3's live path; s4/s5 share `internal/chat` files so they sequence.

| # | Task | Slice | Size | Model |
|---|------|-------|------|-------|
| s1 | task-e24d433d072ee8c0 | `workflow_summary/1` pure fold (reads timestamps, D2/D3) | S | opus |
| s2 | task-a232a271f4007966 | Recorder `{:chat_workflow}` change-only broadcast + `endTime` fold (D4/D5) | M | opus |
| s3 | task-8c92a966b28eda80 | Studio sidebar two lines, live+cold + compact wire projection + epic feed (D6–D9, D11) | L | fable |
| s4 | task-8059027150fc6680 | bp chat session-list mirror from compact wire fields (D6, D13) | M | opus |
| s5 | task-a0e41d82867633dc | below-composer workflow panel — strip/focus/expand (D13, D14) | L | fable |

Backlog (published children of the epic, not this wave):
- live SSE workflow frame + live task_* folding in Go (lifts D12's turn-boundary ceiling)
- PR-state data source for the epic-goal "PRs open" figure (D8)
- busiest-child now-line for fleet phases (needs a real ranking signal, D10)
- real captures: interrupted run + attempt>1 retry fixtures (D15, D62 provenance)
- later layer (design paper): CycleFleet ledger cockpit, verify proof cards, burn strip,
  stop/pause control protocol

## Wave log

(waves append here at Review)

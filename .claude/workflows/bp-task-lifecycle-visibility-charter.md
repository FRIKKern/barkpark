# Task Lifecycle Visibility (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Personal Development Server** (decided 2026-07-19) —
> is preserved verbatim at `.claude/workflows/bp-pds-charter.md`. Do NOT read this file for
> PDS history. This slot is now the memory of the **Task Lifecycle Visibility** epic.
> A durable identical copy of THIS charter lives at
> `.claude/workflows/bp-task-lifecycle-visibility-charter.md` (the slot rotated three times
> on 2026-07-19 alone — future waves should read the named copy if the slot has moved on).
>
> Epic anchor: bp task **`task-lifecycle-visibility-epic`** (published, guerrilla).
> Wave 1 paper: **`task-lifecycle-visibility-wave-2026-07-19`** (style=article).
> Decided 2026-07-19.

## Vision

You open `bp tasks` (or /admin/projects, a paper's task-board block, bp chat) while an epic
cycle runs and you watch it THINK. The strategist names candidate slices and dim dotted
circles (◌ `considering`) appear at the bottom of the brightness ladder, each carrying its
object (considering-researching-it vs considering-building-it). Survey picks candidates up
and they shift to ◎ `researching` — the wave's one new hue (violet = active investigation).
Decide promotes survivors to `open` (the familiar circle: READY) and visibly discards the
rest — a kill is a rendered `cancelled` event, never a silent disappearance. Builders claim,
spinners spin, checks land. Nothing about today's direct filing changes: `bp task create`
still births open, `ready` still lists open, `next` still claims only ready work, claim/close
CAS and epoch fences untouched.

The state graph (not a linear funnel):

```
considering ⇄ researching          open → considering   (cycle re-weighs backlog)
     │  │          │               open ⇄ blocked, open → in_progress ⇄ blocked → done
     │  └─→ open ←─┘               … exactly as today
     ↓       ↓
 cancelled (discard, ledger-honest)
```

**OPEN MEANS READY.** `bp task ready` lists open; only open|blocked is claimable — held by
construction: the ready/claim allowlist is `~w(open blocked)` (queue.ex:35, claim.ex:26) and
the new states are simply not in it.

## Decisions

- **D1 — considering/researching are first-class `lifecycle_status` values (5→7)**, growing
  `Validation.lifecycle_statuses/0` (validation.ex:17), NOT a parallel engagement field.
  Why: exclusion-by-construction is proven (allowlist `~w(open blocked)` in queue.ex:35 AND
  claim.ex:26); every surface already keys rendering off lifecycle_status; the overlay-field
  rival lost because a considering task would stay lifecycle=open and claimable by
  convention only.
- **D2 — the DB CHECK constraint migrates in lockstep, as TWO migrations**: (1) DROP + ADD
  `documents_task_lifecycle_status_check` with the 7-value IN-list and `validate: false`
  (metadata-only, no scan); (2) a SEPARATE migration executing
  `ALTER TABLE documents VALIDATE CONSTRAINT documents_task_lifecycle_status_check`
  (SHARE UPDATE EXCLUSIVE, non-blocking). Why: verify PROVED Ecto.ConstraintError on
  considering-inserts without it (tasks_test.exs:363); ecto_sql 3.13.5 emits NOT VALID; the
  widening is monotonic so VALIDATE can never fail; prod is only 2,704 rows so this is
  habit-correct insurance, not outage mitigation. Never combine DROP+ADD+VALIDATE in one
  migration transaction (the ADD's ACCESS EXCLUSIVE lock would be held through the scan).
- **D3 — engagement companion map** `content.engagement = {object: "research"|"build",
  holder, ts, note}`, validated via `check_optional_map` (claim-map precedent), **no CAS
  epochs**. Why: thought is not contended work; the object field is how "considering CARRIES
  ITS OBJECT" (user statement 2) is stored.
- **D4 — honesty lease = second TtlSweeper sweep** (same module, same advisory-lock family
  `task:<doc_id>`, same CAS-rev update pattern, NO epoch machinery): researching with stale
  `engagement.ts` lapses → considering (engagement cleared); considering with stale ts →
  engagement cleared, stays considering-unowned. Own config key
  `task_engagement_ttl_seconds` (default 900s — thought idles faster than the 45-min work
  lease). Emits additive `task.engagement_lapsed` (payload mirrors lease_expired minus epoch
  fields). Why: a task stuck in researching because its cycle crashed is a lie; reuse the
  reap PATTERN, never the claim/epoch code path.
- **D5 — kill = ledger-honest cancel, never delete by default.** Discarding a candidate =
  `Tasks.close/3` → `cancelled` + required `close_reason`; `"discarded"` joins the
  `outcome.resolution` options. Hard delete remains a rare explicit human verb for pure
  noise. Why: dangling `content.dependencies` ids strand dependents FOREVER fail-closed
  (queue.ex:134); the false-done reopen recipe requires surviving docs; "what's been going
  on" must be answerable from the ledger alone. This satisfies user statement 3 ("delete…
  then it will not be open") — cancelled is not open, not claimable, not ready.
- **D6 — axis-2 cancelled-blocker stranding is an EXPLICIT DEFERRAL** (backlog task
  `tlv-bl-axis2-cancelled-strand`): dependency satisfaction keys on `done` only, so a
  cancelled blocker also strands dependents naming it in content.dependencies. Why: a
  query-time carve-out changes claim semantics repo-wide — its own blast radius.
- **D7 — ONE transition-legality table, enforced at the Writer seam.** New pure module
  `Barkpark.Tasks.Transitions.legal?/2`; `Content.Writer` checks it inside
  do_create/do_upsert (where prev_doc is in scope) for type=task lifecycle_status CHANGES.
  Engine primitives (close/fence/sweeper/move/compactor raw `Repo.update_all`) bypass by
  construction and stay disciplined by their hardcoded literals. Legal via patch/stage:
  considering⇄researching; considering|researching→open|cancelled;
  open→considering|blocked|cancelled; blocked→open|cancelled; in_progress→blocked|open;
  done→open; cancelled→open; no-op same→same. REFUSED via patch: any→done, any→in_progress
  (must use close/claim verbs), done|cancelled→considering|researching. Why: a forged
  "done" has real teeth (cascade_unblock_dependents fires on done, close.ex:426);
  done→open stays legal because the false-done reopen recipe depends on it.
- **D8 — one generic sanctioned verb: `bp task stage <id> <state> [--object research|build]
  [--note …]`** — manifest verb `task.stage`, `POST /v1/tasks/:doc_id/stage`, enforcing the
  same Transitions table, writing/clearing the engagement map, emitting additive
  `task.staged` (payload: from, to, object, holder, note). No curated MCP twin — the
  generic bridge auto-exposes it; no `bridgeShadowedIDs` entry needed. Why: manifest
  machinery makes one generic verb as cheap as three narrow ones; one table, two
  enforcement points, zero drift.
- **D9 — glyphs/hues:** considering = **◌ U+25CC**, dim (~35% fg, ascii `?`); researching =
  **◎ U+25CE**, violet (#7c3aed light / #a78bfa dark, ascii `R`). The brightness ladder
  extends DOWNWARD (thought dimmer than open-backlog-50%). Both glyphs proven single-cell
  (runewidth + uniseg). RULING: ◌'s reuse by `instanceLifecycle.provisioning` is ACCEPTED —
  disjoint vocabularies that never render side-by-side; revisit only if a surface mixes them.
- **D10 — BOTH manifests get rows** (they are parallel and proven independent):
  (a) `design/tokens.json` lifecycle + `emit.mjs` LIFE_ORDER — same-commit bundle with
  board.go life consts, glyphAllowlist entries, `internal/semrole/semrole.go` hand map,
  taskboard + internal/cli goldens, and `design/validate.mjs` REQUIRED_LIFE (a closed list
  that silently skips new states today);
  (b) `design/status-manifest.json` statuses+roles + a new `violet` tone +
  paper-surface.css `.bp-g--considering/--researching` + gridblocks.go vocab + the email
  hardcoded tone/role allowlists (cards_email.ex:347 `~w(info ok warn danger)`,
  panels_email/fleet_email role clauses). Why: verify PROVED TaskResolver passes raw
  lifecycle_status through (`other -> other`) into StatusVocab — papers/pdrender/email are
  a real 7th surface family that would otherwise render considering as bright open.
- **D11 — fail-open flip ships WITH the rows, same PR per surface.** Unknown lifecycle
  renders as a DIM NEUTRAL glyph, never bright open (Go TUI's `·` is the model). Placement
  vs styling: an unknown status keeps a HOME (the open column — never drop a row; the web
  test pins column only) but `color_role` decouples from `col` so the unknown row styles
  `:unknown`/dim. board_live `col_label/1` gains a catch-all (today it CRASHES on a new
  column atom); `safe_role` default flips off `:open`; chat rail default flips off
  `--life-in_progress`. Why: verify proved 5 of 6 surfaces currently fail INTO bright open —
  the worst possible direction for "open means ready".
- **D12 — Studio board grows two dim columns** `:considering`/`:researching` at the ladder
  bottom; considering's object renders as a small secondary marker read from
  `engagement.object`, NOT a hue split of one collapsed lane. Paper task-board blocks'
  `board_roles()` lists (components.ex:562, fleet_email.ex:603) also gain the two thought
  columns. Why: visibility is the epic; a collapsed lane with per-object hues would break
  the col==color_role coupling for marginal gain.
- **D13 — web + @barkpark/react are ONE slice** (same runtime path:
  document-detail.tsx → @barkpark/react PortableDoc; web/lib/task-board-columns.ts is
  orphaned dead code — updated minimally, kill-or-revive filed as backlog). Web freshness is
  HONESTLY SCOPED to the 5-minute ISR ceiling this wave; task-triggered cache bust and live
  chat transition streaming are backlog. Why: proven that task CAS writes never reach
  webhook dispatch (broadcast_document_mutation never calls the dispatcher) — real web
  liveness is new architecture, not rows+glyphs.
- **D14 — chat this wave = cheap tier**: color the EXISTING Studio chat chips from the
  lifecycle_status already in every reachable payload (proven: task_ready docs[] and
  task_get doc/children all carry it) + fail-open defaults; `task_create`'s receipt learns
  to echo the real lifecycle_status (so births-as-considering are visible). Live per-task
  transition streaming in transcripts = backlog.
- **D15 — brief card: additive 14th key** `engagement`, omit-when-absent
  (criteria_progress precedent, params.ex:234); the 13 frozen fields untouched;
  lifecycle_status (already field #5) carries the new values for free. AXI wave 2 has no
  live tasks/PRs/claims on these files — declare `files:` labels and proceed.
- **D16 — sequencing law**: Front A (substrate + both manifests + every surface's fail-open
  flip) fully MERGED before any engine writes the new states;
  `bp-epic-cycle.workflow.js` amendment is the LAST merge of the wave (round 3).
- **D17 — Front B shape**: STRATEGY_SCHEMA gains `candidates[]` ({key,title,object,why}) —
  filed+PUBLISHED as considering at birth (boards read the published ledger only; the
  publish wall is paid once, with a considering-tier AC: one placeholder criterion
  `"resolved: promoted or discarded"`); survey/verify prompts get a ONE-mutation carve-out
  (stage your linked candidate to researching, nothing else); PLAN_SCHEMA gains
  `candidates_resolved[]` ({task_id, outcome: promoted|discarded, note}); Decide promotes
  via stage→open and REUSES the candidate doc as `wave[].task_id`.
- **D18 — ready stays DERIVED, never stored.** The spec states it explicitly (open +
  deps-met, rendered bright; same stored value `open`). desk_groups gains one thought chip
  `{"in": ["considering","researching"]}` mirroring the closed-chip `{"in":[...]}` pattern.

## Roadmap

Wave 1 (this wave — 8 slices; rounds are law, round ≥2 dispatches only after its deps MERGE):

| # | Slice task | Round | Size | Model |
|---|-----------|-------|------|-------|
| S1 | `tlv-s1-substrate-enum-and-migrations` — enum 5→7, two CHECK migrations (validate:false + separate VALIDATE), engagement map validation, resolution `discarded`, desk_groups thought chip, red-test fixes | 1 | M | opus |
| S2 | `tlv-s2-tokens-manifest-chain` — tokens.json rows + LIFE_ORDER + Go life consts/glyphAllowlist/semrole hand map + taskboard+cli goldens + validate.mjs REQUIRED_LIFE + design-language spec update | 1 | M | opus |
| S3 | `tlv-s3-status-manifest-papers-chain` — status-manifest.json rows + violet tone + paper-surface.css .bp-g--* + gridblocks.go + email tone/role allowlists + board_roles thought columns | 1 | M | opus |
| S4 | `tlv-s4-web-react-vocab-failopen` — all JS/TS vocabulary copies + fail-open flips (react inline.tsx/taskboard.ts, web component-projections.ts/task-board-columns.ts) | 1 | M | opus |
| S5 | `tlv-s5-studio-board-chat-failopen` — board.ex thought columns + color_role decouple + :unknown, board_live col_label catch-all + peek roles, chat chip coloring + rail default flips | 2 (after S1, S2) | L | fable |
| S6 | `tlv-s6-engagement-lease-sweeper-briefcard` — second TTL sweep + task.engagement_lapsed + brief-card engagement key + create-receipt lifecycle echo | 2 (after S1) | M | opus |
| S7 | `tlv-s7-transition-gate-stage-verb` — Transitions table + Writer seam guard + task.stage manifest verb/endpoint + task.staged events | 2 (after S1) | L | fable |
| S8 | `tlv-s8-epic-cycle-walks-its-graph` — workflow amendment (candidates[], survey/verify carve-out, candidates_resolved[]) + charter doctrine; LAST merge of the wave | 3 (after S5, S6, S7) | M | fable |

Backlog (filed + published, not this wave): `tlv-bl-tasks-ls-offset-broken` (server ignores
offset on /v1/tasks; --all self-aborts), `tlv-bl-axis2-cancelled-strand`,
`tlv-bl-web-task-cache-bust`, `tlv-bl-chat-live-transition-stream`,
`tlv-bl-js-vocab-drift-gate` (status-manifest-check.sh covers no JS copy),
`tlv-bl-task-board-columns-dead-code`, `tlv-bl-ready-allowlist-consolidation`
(queue.ex:35/claim.ex:26 duplicate), `tlv-bl-task-prime-chip-gap` (prime payload matches
neither chip branch).

Future waves: Front B live-fire (watch a real cycle think end-to-end on the boards), web/chat
liveness plumbing, generated JS vocabulary + drift gate.

## Wave log

### Wave 2026-07-21 — correctness spine (wave 3), grade A−

Reviewed and pushed 5 round-1 slices (all gates re-run green by the reviewer, file-disjoint → no
inter-slice conflicts). PRs #5529–#5533, held for the lead to merge.

**Landed:**
- `tlv-bl-ready-allowlist-consolidation` (#5529) — `Validation.claimable_statuses/0` single-sources
  the `~w(open blocked)` allowlist; queue.ex Ecto `in`, queue.ex raw-SQL CTE (`= ANY(?)`), and
  claim.ex guard all derive from it. `@canonical capability:task-claimable-statuses` stamped.
  board.ex:1001 4th copy stays deferred to `tlv-bl-board-ready-allowlist-4th-copy` (round 2).
- `tlv-s7-transition-gate-stage-verb` (#5530, `-r`) — pure `Transitions.legal?/2` D7 table + the
  sanctioned `bp task stage` verb (`POST /v1/tasks/:doc_id/stage`), engagement map write/clear, no
  epoch machinery. Writer-seam enforcement + D7a flip remain handed to the felix Writer-seam slice
  (`tlv-bl-writer-seam-transition-gate`) — stage is sanctioned but NOT yet the only guarded path.
  Reviewer fixed the plugins/tasks moduledoc verb census (12→13).
- `tlv-bl-release-epoch-and-restore` (#5531) — ruling-pins release's always-open landing (doctrine
  comment, no restore) + regression-guards the missing/blank observed_epoch loud error.
- `tlv-s6-engagement-lease-sweeper-briefcard` (#5532) — second TTL sweep lapses stale
  considering/researching engagement; additive `task.engagement_lapsed`; brief-card 14th key
  `engagement` (omit-when-absent); CLI+MCP create receipts echo the born lifecycle_status. Two
  pre-existing macOS help-test pipe deadlocks skipped locally (filed `task-cab17fc3d93d8c71`); linux
  CI is the merge authority.
- `tlv-bl-axis2-cancelled-strand` (#5533) — documents the fail-closed axis-2 ruling (D6) + two
  protective tests; zero production code. Escape hatch (cancelled→open) is reachable via the new
  stage verb.

**Cross-slice coherence proven:** stage writes `engagement{object,holder,ts}` in ISO8601; the S6
sweep reads/clears it with matching parse semantics; brief card omits when absent; the axis-2 escape
hatch rides the stage verb. All five slices touch disjoint files.

**Ledger truthful:** no fabricated `done`; every merge-gated "PR merged" criterion left `met=False`
for the lead. (Four slice tasks sit `open` — claims released; S6 sits `in_progress` with a stale
claim. Both honest; the lead closes the merge criteria on merge.)

**Next wave — dispatch order:** merge round-1 (#5529–#5533, any order). THEN the 3 round-2 backlog
slices as their deps land: `tlv-bl-outcome-resolution-unenforced` + `tlv-bl-board-ready-allowlist-4th-copy`
(after #5529 merges — both extend validation.ex), and `tlv-bl-tasks-ls-offset-broken` (after #5530
merges — S7 restructures tasks_controller.ex). Then the felix Writer-seam slice closes D7/D7a.

### Wave 2026-07-22 — finishing wave (wave 4), grade A−

Reviewed and pushed 4 round-1 slices (all gates re-run green by the reviewer; octopus-merge of all
four final branches against origin/main proven conflict-free). PRs #5585–#5588, held for the lead
(.ex PRs wait for the CI Elixir Test gate).

**Landed:**
- `tlv-bl-outcome-resolution-unenforced` (#5585) — `check_outcome/2` micro-validator: a present
  off-enum `outcome.resolution` (incl. `""`) 422s naming the 7 advertised values (mirrors schema.ex's
  select byte-for-byte); absent/nil ok; non-map keeps the byte-identical shape error. Strict always-on
  per D23 (guerrilla census clean). Mutation-proven.
- `tlv-bl-board-ready-allowlist-4th-copy` (#5586) — board.ex `ready?/1` derives
  `@claimable_statuses` from `Validation.claimable_statuses/0`; the 4th and LAST lifecycle-string
  allowlist copy is dead. Gate narrowed per D22 (board_live_test.exs:319 + theme parity; the 6-failure
  connected?-mount regression is `tlv-bl-board-live-connected-mount-regression`).
- `tlv-bl-cli-empty-arg-guard` (#5587) — bindArgs treats empty positionals as absent (D24): required →
  friendly missing-arg error + usage; optional → no map key. Zero wire change re-verified at all four
  consumers (run.go:584/:708/:845, internal/manifest/url.go:120).
- `tlv-bl-tasks-ls-offset-broken` (#5588, `-r`) — `/v1/tasks` honors `?offset=` (clamped [0,100k]) +
  id tiebreaks in both `apply_index_order/2` arms (total order — pages disjoint over a frozen ledger);
  task.ls manifest flag + openapi regen + TASK-SYSTEM.md honesty. Reviewer fixed the flag's help copy
  ("Ready-queue row offset." → "Task-index row offset.") and re-regenerated openapi.json. Honest
  residual: desc:updated_at shears under concurrent writes mid `--all` sweep; keyset = eventual cure.

**Evidence-closed at Decide (landed in wave 3, premises verified L1 before cutting):**
`tlv-bl-ready-allowlist-consolidation` (#5537/#5529), `tlv-bl-release-epoch-and-restore`
(#5535/#5531), `tlv-bl-axis2-cancelled-strand` (#5536/#5533), tlv-s6 (#5538; dup #5532
closed-not-merged). Backlog filed: `tlv-bl-publish-door-lifecycle-guard` (prio 1 — publish
resurrection door PROVEN open), `tlv-bl-board-live-connected-mount-regression`,
`tlv-bl-ready-offset-clamp`.

**Deferred by design (round 2):** `tlv-bl-writer-seam-transition-gate` — THE CROWN (D7b contract:
published-fallback was-resolution, exemption = birth OR :sync, only mutate_controller_test.exs:126
flips). Dispatches ONLY after #5530 (tlv-s7 stage verb) merges.

**Next wave — dispatch order:** (1) LEAD: green #5530 (regen docs/openapi.json via CI artifact — its
only PR-caused red) and merge it; re-run main's Elixir gate past the 429 StatusController flake.
(2) Merge round-1 #5585–#5588 (any order; all pairwise conflict-free; #5588 is line-disjoint from
#5530 but merge #5530 first to keep the courtesy ordering). (3) THEN dispatch
`tlv-bl-writer-seam-transition-gate` (fable) — the crown closes D7/D7a and the proven draft-twin
forgery door. (4) `tlv-bl-publish-door-lifecycle-guard` is the strongest new prio-1 candidate
(publish-door resurrection is run-proven open). Then tlv-s5/tlv-s8 per the epic roadmap.

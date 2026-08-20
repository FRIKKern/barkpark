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

> **Decisions D19–D24 were introduced in the wave-3/wave-4 logs below** (the numbers
> D22/D23/D24 are cited inline against the finishing-wave slices) and were never lifted into
> this section; the next free number is therefore D25.

- **D25 — advisory blocking is FINAL; Barkpark grows NO hard-fence lifecycle primitive.**
  A `blocked` task is claim-EQUIVALENT to `open` (both are in the claimable allowlist), and
  readiness is a DERIVED, deps-met render (D18) that holds work back at query time — never a
  stored hard fence that forbids a claim. Barkpark deliberately does not add a "truly blocked"
  primitive that would refuse claims: the funnel doctrine keeps `open` == ready and lets a
  human/agent claim a `blocked` row to unblock it. Single-sourced and test-locked:
  `Validation.claimable_statuses/0 == ~w(open blocked)` (validation.ex:31,49-50,
  `@canonical capability:task-claimable-statuses`); the derived copies in queue.ex (Ecto `in`
  + raw-SQL CTE `= ANY(?)`), board.ex `ready?/1`, and claim.ex all reference it (consolidated
  #5529/#5586). Proven real by `claimable_statuses_test.exs` (#5537): 8 tests / 0 failures
  green, and forking the single source to `~w(open)` reds 4 tests (the pin, blocked-ready,
  blocked-after-dep-flip, blocked-edge) — reviewer re-verified L1 on origin/main
  2026-07-22. This decision SUPERSEDES the phantom "D32" citation that
  `tlv-bl-true-blocking-primitive-decision` was authored against: the charter never carried a
  D32 (it topped at D24), and the ruling substance previously lived only under the
  **OPEN MEANS READY** section + D18 + the validation.ex:26-31 comment. D25 formalizes it so
  the ledger row can close against a real authority. No production code, no new fence.

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

### Wave 2026-07-22 — backlog finish wave (wave 5), Arm D (straight-to-build), grade A−

**Arm: D** — research-program arm D (`/papers/epic-cycle-research-program-abcde`): the wish +
charter went DIRECTLY to Decide with NO survey and NO verify fleet; builders verified their own
premise at L1 first; the REVIEW was the wave's entire quality system. Four disjoint-ground
backlog rows were cut; all four premises CONFIRMED at L1 (none refuted on the ground).

**Landed (3 green slices, reviewer re-ran every gate on the final branch):**
- `task-13bc8127adedfee0` (S1, #5705) — `task.stage` manifest description now enumerates the four
  terminal/blocked reopen edges (`done→open`, `cancelled→open`, `blocked→open`, `in_progress→open`)
  the enforced `Transitions.legal?/2` gate already sanctions for a stageable target. Doc-only `.ex`,
  zero behavior change; welded with a keep-the-claim reopen test + a mutation-proof substring
  assertion. Reviewer gate: `mix test stage_test.exs` 12/0.
- `task-1471170216ac6b54` (S2, #5706 `-r`) — close-drift recovery leads with `observed_rev` (strict
  full-rev CAS, bypasses the work-digest fence) instead of the dead-end "re-read then close again";
  the 409 already names `current_rev` + `changed_fields`. Flipped every CLI/MCP/manifest/onramp
  surface + wired a reachable MCP `observed_rev` property; 3-case regression (re-read repeats /
  observed_rev succeeds / stale rev still 409s). Reviewer fix: trimmed the onramp line so
  `docs/setup/CODEX.md` holds its 10100B budget (S2 had it at 10207B → now 10096B). Reviewer gates:
  `mix test tasks_test.exs` 28/0, `go test -run Onramp` ok, `check-doc-budgets.sh` PASS.
- `tlv-bl-js-vocab-drift-gate` (S4, #5707) — `status-manifest-check.sh` Part 5 byte-checks the two
  hand-maintained TS vocab twins (react `STATUS_ROLES`, web `STATUS_LADDER`) against
  `design/status-manifest.json` (role set + order + glyph + label); `unknown` is the ONE sanctioned
  non-manifest role; fails closed. Reviewer re-ran the gate + mutation-re-proved (label desync +
  extra role each red). Shell-only, merges on its own gate.

**Ruled (S3, `tlv-bl-true-blocking-primitive-decision`):** premise CONFIRMED but the slice was
authored against a **phantom charter D32** that never existed (the charter topped at D24). Per the
LEAD ruling (2026-07-22 12:18), the REVIEW phase authored **D25** above (advisory blocking is FINAL;
`blocked` claim-equivalent to `open`; readiness derived not fenced; single-sourced +
`claimable_statuses_test.exs` #5537 test-locked, reviewer re-verified 8/0 at L1), reworded the two
S3 criteria D32→D25, and stamped the invariant proof. The row closes on the D25 charter merge (this
entry's PR) — the lead lands it.

**Ledger truthful:** S1/S2/S4 all `in_progress` with their "PR merged" criteria left `met=false` for
the lead; no fabricated `done`; every slice carries its `wave_paper` + epic parent. S3 honestly
records the phantom-D32 refutation and the lead's D25 resolution.

**Next wave — dispatch order:** (1) LEAD merges the green round-1 PRs #5705 (S1, waits CI Elixir
Test), #5706 (S2, waits CI Elixir Test), #5707 (S4, own gate) — all pairwise file-disjoint. (2)
Merge THIS charter PR (D25) and close `tlv-bl-true-blocking-primitive-decision` citing the merged
D25 SHA + `claimable_statuses_test.exs`. (3) Then the crown `tlv-bl-writer-seam-transition-gate` and
`tlv-bl-publish-door-lifecycle-guard` remain the top round-2 candidates, then tlv-s5/tlv-s8.

### Wave 2026-08-18 — reconciliation (wave 6), Opus-only (Fable capped to Aug 21), grade A−

A reconcile-and-close wave, not a fresh-build wave — the ledger's own subject applied to itself.
The epic exists to make a task's state read TRUE on every surface; three weeks after the last
touch, this wave re-derived the epic's own children to truth. **NO builders dispatched** — movement 4
(finish an offline- AND mutation-provable backlog row) found nothing finishable this wave, so the
code wave is empty by design, and for THIS epic that honest verdict IS the deliverable.

**True split (re-derived from L1, four Opus verifiers PROVING by running):** 44 children =
**24 done / 17 open / 1 considering / 2 cancelled**. child_count 44 is NOT the open count — the 17
open rows are the whole job. origin/main was 41b16d78db at Decide (the digest's d7da14e8fc is an
ancestor, no divergence); every ancestry proof re-run against 41b16d78db.

**The one evidence-close (handed to the LEAD — its sole unmet criterion is merge-gated):**
`ledger-merge-criterion-autostamp` (4/5). Built by **#5742 = `9e7132846f`**, which carries the exact
`Task: ledger-merge-criterion-autostamp` trailer and `git merge-base --is-ancestor 9e7132846f
origin/main` = YES. The sole unmet criterion is **0-based index 4** (`met=false, merge_gate=true`,
"PR merged to main (LEAD closes this criterion on merge)."). **Pay `--criterion 4`, never 5** — the
D87/search-template-w12 gotcha: `bp task close --criterion` is 0-based, briefs are 1-based. Claim is
LAPSED (worker=null, epoch=8): re-claim first to mint a fresh epoch, read the CURRENT holder+epoch
immediately before close, then close `done` stamping the merge SHA. Criterion text must be byte-exact
including the trailing period or the close 409s `criteria_mismatch`.

**The one clean re-parent (PERFORMED + verified this wave):**
`pds-bl-merge-gated-criteria-carry-the-flag` → PDS epic `task-2ac1f95237c4a8e5` (open, top-level,
accepting children). Its subject is the PDS merge-gated class; #9527's own body names it "parented to
a different epic". Move confirmed by re-reading `parent_id` = `task-2ac1f95237c4a8e5`.

**Mis-parent rows KEPT under this epic (verified, NOT moved):**
- `cloud-console-data-query-id-prefix-bug` — its only plausible owner `cloud-console-hardening-epic`
  is IN its terminal close TODAY (NO-SEAL ruling, forwarding ~427 orphans OUT, D93 "no re-homing this
  wave"); the bug is **api-side** (`/v1/data/query`), not a console-GUI defect. Re-homing would strand
  it. It is still genuinely UNBUILT on origin/main (query_controller reads no `id_prefix`, rejects no
  unknown param) — do not close by evidence.
- `task-eal-bl-lock-key-convergence`, `task-eal-bl-cmux-auto-pulse`, `spd-b44-slug-allocator-assigns-not-guesses`,
  `graph-endpoint-latency`, `task-6e819f39fe3aa9e6`, `task-11390a3b900c8a09` — no foreign task-system
  umbrella epic exists (bp search returned only this epic); this epic IS their umbrella.
- `task-eal-bl-events-cold-index` (considering) — epic-NATIVE by content (ordered mutation-event
  replay is the spine of lifecycle visibility). `considering` is correct — it dogfoods D1's new
  first-class state. LEAVE.

**The named seal-blockers — LEAVE (genuine offline-unbuildable-this-wave defects):** `tlv-s5`
(Studio board, 0/6) and `tlv-s8` (epic-cycle walks its graph, 0/5) — both unbuilt, Fable-tier,
live-surface; their deps (s1/s2/s6/s7) all DONE, so blocked SOLELY by the Fable cap (to Aug 21) +
live surface. Zero commit hits on any ref.

**Offline-buildable backlog — LEAVE (movement 4 found no clean finish):**
- `tlv-bl-tui-close-drift-resync-guidance` (highest bar, 86) — reword+pin is offline-provable, but
  crit[0]'s second clause needs model-layer surgery (the interactive board close wires plain
  `DoClose`, not `DoCloseRev`; the only `DoCloseRev` caller is `cmux_hook.go:245`), and crit[2] is a
  server-side CAS guarantee the `serve()` unit mock cannot enforce. A genuine Go slice, not a stamp.
- `tlv-bl-task-board-columns-dead-code` — "dead" is only half true: no runtime importer, but
  `component-golden-parity.test.ts:51` + `task-board-columns.test.ts:18` import it and the 31/0 suite
  passes → a delete is a REHOME, not a free delete. crit[1] is merge-gated.
- `tlv-bl-js-vocab-generator` — genuinely unbuilt (its only commit hit #5707 builds the DONE
  drift-gate SIBLING and explicitly DEFERS the generator — a phantom-citation trap avoided); needs a
  new build-time emitter + retiring the Part-5 gate; crit[2] merge-gated.

**Live/prod-gated backlog — LEAVE (D13/D14 new-architecture residue):** `tlv-bl-web-task-cache-bust`,
`tlv-bl-chat-live-transition-stream` (Studio subscribes for the Doing strip, but the transcript
transition-stream is unbuilt — brief slightly overstates the gap), `tlv-bl-task-prime-chip-gap`.

**Convergence verdict — recommend AGAINST seal-and-spin.** `tlv-s5` and `tlv-s8` are real above-bar
defects blocking the epic's own D11/D12/D14 and D17 criteria and cannot be built this wave
(Fable-capped, live-surface). The correct next move is a Fable wave after the Aug-21 cap lifts. Where
the ledger already read true, the wave manufactured no findings — already-honest-with-evidence is the
A-grade for a ledger-truth epic reconciling itself.

**Next wave — dispatch order:** (1) LEAD closes `ledger-merge-criterion-autostamp` by evidence
(re-claim → `--criterion 4` → merge SHA `9e7132846f`). (2) After Aug-21 Fable cap lifts: dispatch
`tlv-s5` (fable, round 2, live Studio) then `tlv-s8` (fable, round 3, LAST merge — shared workflow
file). (3) Offline-buildable backlog as dedicated slices when a build wave has room:
`tlv-bl-tui-close-drift-resync-guidance` (Go, highest bar), `tlv-bl-js-vocab-generator` (build wave),
`tlv-bl-task-board-columns-dead-code` (low-bar rehome). Wave paper:
`task-lifecycle-visibility-wave-2026-08-18`.

### Wave 2026-08-18 — done-set false-done audit (wave 7), Opus-only (Fable capped to Aug 21)

A VERIFY-HEAVY AUDIT — not a build wave, not a reconcile wave. Wave 6 spent its judgment on the 17
open rows and treated the ~24 done rows as settled background; this wave put the DONE set on trial.
**VERDICT: 0 false-done across all 25 live-L1 done rows. Zero reopens; none manufactured. Stated even
though it is zero.**

**True denominator:** 25 done (44 children = 25 done / 16 open / 1 considering / 2 cancelled —
re-derived twice from live L1; child_count is NOT the done count). Pinned snapshot
origin/main = `e21bf409893d9de66542a31b06716e3c33d8f102` (== HEAD at audit time — verified live, not stale).

**SWEEP A — SHA-ancestry at 100%.** All 15 merge-citing done rows resolve to a real `merge_commit_sha`
on FRIKKern/barkpark, and every SHA is an ancestor of e21bf40 (`git merge-base --is-ancestor` RUN, never
a PR-head shortcut). The four no-SHA "Historical completion reconciled from N/N" substrate rows
(`tlv-s1..s4`) landed as the ADJACENT group **#4392–#4395** — NOT the survey brief's #5529–5533, which
are later finishing-wave PRs — all ancestors with substance present on main (validation.ex 7-value vocab,
emit.mjs LIFE_ORDER, status-vocab.test.ts). The three dup-PR pairs BOTH landed: the dup is a harmless
empty re-merge sharing the primary's `headRefOid`, never a masked non-landing.

**SWEEP B — engine-close provenance at 100%.** Recovered per-row from `doc.claim`, NOT from `bp task
events` (which carries no worker/epoch/actor/closed_by on any event — a real ledger-observability gap,
filed): 22 clean engine closes, 3 null-worker closes (`closed_by="None"`), 0 rows matching the
fabrication shape (null-claim + boilerplate + 0/N + zero-evidence); all 25 carry `criteria_met == total`.
The pre-#6420 close path stamped "None" six days BEFORE the sentinel guard (`448749cf18`, PDS-D290)
landed 2026-07-28; the hole is closed on origin/main today.

**Two-lane decision check (Paper/decision-existence, NOT ancestry).** D25 (this charter — advisory
blocking FINAL), **D212** (`bp-studio-space-priority-charter.md:1751` — authorizes the spd-b24 verdict-close
AND forwards the true-blocking successor), and D6 (axis-2 cancelled-strand deferral) were all git-shown REAL
on origin/main and COVER their cited closes. The census's "phantom D212" flag was REFUTED — D212 exists and
names spd-b24 explicitly.

**Vacuous-green DISPROVEN by RUNNING the probes.** The one structural false-done candidate —
`tlv-bl-js-vocab-drift-gate` — is a REAL guard: `status-manifest-check.sh` Part 5 reds on
label/glyph/dropped-role/order drift across BOTH TS twins, with required roles derived DYNAMICALLY from the
manifest (so a genuinely new state cannot be silently skipped). The Go empty-arg guard kills its mutant at
`cli_test.go:298`; four Elixir guard suites red on mutation, including the claimable_statuses exemplar
(`~w(open blocked)`→`~w(open)` reds 4 tests). The survey's "silently skips new states" concern belongs to
`design/validate.mjs` `REQUIRED_LIFE` (a hardcoded 9-element literal) — a SEPARATE, still-vacuous gate,
filed to backlog.

**Trust verdict:** the done set of task-lifecycle-visibility-epic is TRUE, independently re-verified,
false-done count **ZERO**. Where the ledger already read true, the audit manufactured no findings —
already-honest-with-evidence is the A-grade for a ledger-truth epic auditing itself.

**Build wave: EMPTY by design** (read-only fence, audit complete, zero false-done). Decide-phase products:
this wave-log note + the trust-verdict Paper + the committed re-derivation ledger rows, all on ONE docs-only
PR. **Backlog filed (published epic children, not this wave):** `tlv-bl-events-actor-attribution` (prio 2 —
task events carry no close attribution; provenance recoverable only from `doc.claim`),
`tlv-bl-validate-mjs-required-life-hardcoded` (prio 2 — make the design-token validator's hardcoded
`REQUIRED_LIFE` manifest-driven), `tlv-bl-null-worker-close-path-audit` (prio 3 — regression-test the #6420
sentinel guard + document the `worker=None`+epoch corner).

**Next wave — dispatch order:** unchanged from wave 6 for the OPEN rows — after the Aug-21 Fable cap lifts,
dispatch `tlv-s5` then `tlv-s8`; then the offline-buildable and the three new audit-filed backlog rows as a
build wave has room. Wave paper: `task-lifecycle-visibility-donefalse-audit-2026-08-18`.

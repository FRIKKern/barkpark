# Epic Charter — GitHub Issues/Projects Bridge (`github` plugin)

Target repo: **FRIKKern/barkpark** (public). Ledger: **guerrilla.barkpark.cloud** (private). Off by default.

## Vision

Barkpark (the guerrilla ledger) is the SINGLE SOURCE OF TRUTH. A maintainer adds `github`
to `BARKPARK_PLUGINS` and provisions a GitHub App — from that moment the ledger and the repo
are one board with a clear seam. You work tasks in Barkpark exactly as before; within ~30s a
mirror GitHub Issue in FRIKKern/barkpark appears or updates (title, body + `Task:` trailer,
labels, state, `parent_id`→sub-issue, `blocks`→marker block). Lifecycle done→closed(completed),
cancelled→closed(not_planned). A GitHub Projects v2 board auto-populates as a READ-ONLY
executive dashboard (Status/Priority/Worker/Goal via GraphQL) that nobody edits back. An
outsider who cannot see guerrilla opens an issue → within a minute a task `gh-<num>` lands
labeled `src:github`+`needs-human`, born through the SAME tob-w2 find-or-create dedup seam so
a re-delivery never doubles it; one adopt flips ownership into Barkpark and drops a backlink
comment. Claims, epochs, fencing, rail_rev NEVER leave Barkpark. GitHub field values are NEVER
read back into a task. The loop is broken BY CONSTRUCTION: the App's own writes echo back as
`source="github"` mutation_events (skipped by the outbound cursor) and as `[bot]`-authored
webhooks (dropped on inbound), and a `synced_rev` equality check makes a no-op edit a no-op
sync. Everything ships and gates against a MOCKED GitHub (Bypass); App creation is the only
human gate and it blocks nothing in code.

## Decisions

- **D1. Model the outbound mirror on the proven `Barkpark.Sync` machinery, not greenfield.**
  Copy `PushCursor` (monotonic upsert + `bootstrap_if_absent` skipping ALL pre-enable history)
  and the drain discipline (write-then-advance quarantine, halt-not-skip on transient). Why:
  this code is adversarially hardened; the GitHub mirror needs the exact same invariants.
- **D2. Level-triggered reconcile, NOT edge-triggered replay.** The durable cursor/outbox is the
  at-least-once SOURCE; draining a mutation_event ENQUEUES a debounced per-task Oban MirrorJob
  (`unique` on doc_id, `schedule_in: 30`, coalescing a burst into one write) that reads the task's
  CURRENT full state and reconciles the issue to it. Why: debounce, reorder-tolerance, coalescing
  fall out for free; GitHub is an external non-CAS target — desired-state convergence is right.
- **D3. Idempotency + de-loop key = the flat content field `github:{repo,issue,synced_rev}`.**
  Stored as plain task CONTENT via `Content.*` (like `code_refs`), NEVER a declared task-schema
  field — the github plugin must never mutate the tasks plugin's schema. `synced_rev` = the task
  `_rev` last mirrored; MirrorJob no-ops when `rev == synced_rev`; persist issue NUMBER so replay
  is PATCH not CREATE. Why: single flat field is the entire idempotency + intake anchor, no side
  table, no uncloseable crash window.
- **D4. Loop prevention is STRUCTURAL, three independent cuts.** (1) inbound DROPS any event whose
  sender is the App's own `[bot]` identity, before it can mint a mutation; (2) the outbound cursor
  reader EXCLUDES `source="github"` mutation_events — inbound-applied writes are stamped
  `source: :github` (`save_event` does `to_string(source)`; verified the Outbox `source="sync"`
  exclusion is the exact proven pattern); (3) outbound skips when `task._rev == github.synced_rev`.
  Any one alone breaks the loop. Why: a mirror loop is the single catastrophic failure mode.
- **D5. Ownership matrix is a single pure, test-enumerable module; NO field is bidirectional.**
  `Barkpark.Plugins.Github.Fields` declares per field: owner + direction; the reverse GitHub→task
  field writer simply DOES NOT EXIST in the codebase. A property test asserts no field is both
  directions. Why: directional purity becomes a machine-checked invariant, not a doctrine.
- **D6. Inbound intake reuses `Tasks.Dedup.check_new_task/5` via the normal Content create path,
  keyed on a deterministic `gh-<num>` doc_id.** Re-delivery collapses because the doc_id already
  exists (birth has a `prev_doc` → Dedup returns `:ok`, upsert is a no-op). Adoption is an
  EXPLICIT operator action, never automatic — the intake never auto-claims a worker slot. Repo
  issues map to TASKS, never the Tickets plugin.
- **D7. Ledger wins on disagreement, but disagreement is VISIBLE.** Outbound reconcile PATCHes
  GitHub to the ledger's desired state (GitHub has no rev we respect). If the issue was hand-edited/
  closed/transferred out-of-band, RECORD the drift in a `github_sync_conflicts` quarantine + Studio
  notice before converging (the `PushConflict` posture). Carve-out: issue DELETED/transferred →
  mark `github.state=detached`, surface it, NEVER recreate (that would fight a human).
- **D8. GitHub App auth = a singleton GenServer copying `Bokbasen.Auth`** (RS256 app-JWT →
  installation token, cached with TTL + refresh); HTTP over `Req` with an `api_base` override for
  Bypass; REST for Issues, GraphQL for Projects v2. Why: the exact singleton-auth + Bypass-tested
  pattern is already proven in-repo. Test key is generated — no real credentials.
- **D9. Secondary-rate-limit safety = one low-concurrency Oban queue + `{:snooze, secs}` on
  403/429 with reset headers** — retryable, never dead-lettered. Level-triggered reconcile means a
  snoozed job re-reads current state when it runs, so no intent is lost.
- **D10. Projects v2 is strictly one-directional GraphQL, sequenced LAST, isolated.** Auto-add +
  Status/Priority/Worker/Goal custom-field writes only, diffed against the stored projection so an
  unchanged task writes zero GraphQL. No code path reads a Projects field back. Why: its API surface
  is the fiddliest; quarantine it so it can't destabilize the Issues loop.
- **D11. `PR` linkage is unchanged.** The `Task:` trailer + `pr-task-gate` stays canonical;
  issue-closing keywords are derived niceties. The mirror renders a `Task: <doc_id>` trailer into
  the issue body so GitHub-side PRs keep working with the existing gate.
- **D13 (wave 8). Pre-adoption outbound gate — the intake task is OUTBOUND-DARK until adoption.**
  `MirrorJob.reconcile` cancels on `link.state == "intake"` (`{:cancel, :intake}`, the `:detached`
  twin) BEFORE any GitHub call. Barkpark never PATCHes an issue it has not been granted ownership
  of; adoption is the consent moment that re-opens the path. The guard keys on the state string,
  NEVER on synced_rev absence — an adopted task also lacks `synced_rev` until its first mirror,
  and that consent-moment first push must stay live.
- **D14 (wave 8). Inbound breadth is bookkeeping-only, in a sibling handler.** `Intake` stays
  birth-only (its `@canonical` identity). A sibling `Github.InboundEvents` handles
  `issues.deleted`/`issues.transferred` (gh-born task → detach) and `issues.closed` by a non-bot
  sender on a `state=="intake"` task (→ detach, reason `closed_by_author`). Every path runs the
  bot-drop FIRST, then `Link.put(state: "detached")` + `Conflicts.record(kind: "detached",
  detail.reason: deleted|transferred|closed_by_author)`. No `lifecycle_status` write EVER (the
  ownership matrix says outbound_only — an inbound lifecycle write is a bidirectionality breach),
  no field read-back, no new conflict kind (Health's 3-kind bucketing untouched). Lookup is by the
  deterministic `gh-<num>` doc_id only; outbound-mirrored issues keep the reactive 410 detach.
  Missing task / non-intake close → deliberate `:ignored` 2xx with a test asserting it. Detached
  is not adoptable (adopt gate unchanged).
- **D15 (wave 8). Tenancy threads at the edges; the service layer is already scope-clean.**
  `Adopt`/`Intake` already thread `:workspace_id`/`:project_id` opts — only the callers pass `[]`.
  Studio: `resolve_action_handlers/2` closes over `ctx.scope` (the onixedit arity-3 precedent).
  HTTP: the adopt controller derives `ScopeHelpers.scope_opts(conn)`; the `:token` plugin bucket
  gains the `/w/:ws/p/:proj` scoped mirror (the `:api`-bucket precedent, router.ex ~949) and
  `github.adopt`/`github.status` set `scoped_prefix`. Inbound: optional `intake_workspace_id`
  (env-resolved via Settings; absent → default workspace, today's behavior) threaded into
  ingest opts. Never accept raw tenancy params that bypass membership enforcement.
- **D16 (wave 9). Scoping/exposure is HUMAN-gated; the mechanism is FILED, never front-run.** The public
  mirror discloses the entire internal backlog (2026-07-13: 277 open / 1193 total issues on public
  FRIKKern/barkpark, 100% App-authored, ~195/day, full engineering bodies with file:line + internal
  doc_ids). The remedy is a human choice among FIVE distinct options (keep-public / dataset-scope /
  allowlist / body-strip / separate-private-repo) owned by task `github-bridge-mirror-exposure-decision`
  (open, needs-human, 0/3). No outbound mirror-eligibility predicate or reconcile-over-shared reap ships
  until that ruling — building any specific predicate SOURCE pre-selects an option and front-runs the human
  (the task's own crit-2: enactment slices are filed AFTER the ruling, carrying its parameters). When built:
  the DEFAULT is mirror-all (zero regression), and an explicit `adopt` is operator consent ⇒ the eligibility
  branch EXEMPTS non-nil-state links (adopted/synced), gating only never-adopted, born-outbound tasks. The
  enforcement seam is `MirrorJob.reconcile/3` (the sole funnel `converge/5` is reached through; an
  outbox/cursor-only gate LEAKS because `handle_defer`/`handle_flatten` self-reenqueue via `Oban.insert`).
  Filed as `github-bridge-spine-outbound-scoping`, blocked on the ruling.
- **D17 (wave 9). Conflict rows discriminate by `detail.source`, never by a new kind (extends D14).** Four
  semantically-distinct problems reuse the frozen `out_of_band_edit` kind (human drift = no source; graphql;
  sub_issue_rejected; client_error), and `Conflicts` dedups by `{repo,issue,kind}` → two co-occurring
  distinct problems on ONE issue collapse to one operator row and one Resolve silently clears both. Fix:
  widen the dedup key to `{repo,issue,kind,COALESCE(detail->>'source','')}` in BOTH `Conflicts.open_row/1`
  AND the partial unique index `github_sync_conflicts_open_key` (lockstep migration). COALESCE guards the
  Postgres null-is-distinct trap so "five human edits (no source) = one row" holds. Merge-not-overwrite (the
  other half of the charter's two options) already shipped in wave 8; this closes the operator-visible
  conflation only, no new kind (Health's 3-kind bucketing untouched).
- **D18 (wave 9). GitHub-status read-scope honors the token's OWN dataset.** `Health.snapshot/1` today
  DISCARDS its argument (param is `_opts`, always aggregates all `Settings.datasets()`) and the `:token`
  route sets scope to the seeded Default → any valid operator token reads whole-fleet health (a
  cross-boundary read). Fix (string-scope): make `Health.snapshot/1` actually filter by the dataset string
  AND constrain the effective dataset to `conn.assigns.api_token.dataset` in the controller — NOT via
  `ScopeHelpers.scope_opts/1` (returns the seeded Default on flat routes = still leaky). True per-workspace
  isolation (net-new `workspace_id` columns on `github_sync_conflicts` + `sync_push_cursors` + backfill) is a
  separate filed slice, not this wave.

## Ownership matrix

| Field / aspect | Owner | Direction | GitHub representation |
|---|---|---|---|
| title | Barkpark | outbound_only | issue title |
| description / brief | Barkpark | outbound_only | issue body + `Task: <doc_id>` trailer |
| lifecycle_status | Barkpark | outbound_only | issue `state` + `state_reason` (done→closed/completed, cancelled→closed/not_planned, else open/reopen) |
| priority | Barkpark | outbound_only | label + Projects `Priority` field |
| worker (claim) | Barkpark | outbound_only | attribution comment/label + Projects `Worker` field |
| status (derived) | Barkpark | outbound_only | label + Projects `Status` field |
| goal / parent_id | Barkpark | outbound_only | native sub-issue link + Projects `Goal` field |
| blocks edges | Barkpark | outbound_only | `<!-- barkpark:blocks -->`-fenced marker block in body |
| acceptance_criteria | Barkpark | outbound_only | task-list checkboxes in body (flagship liveness signal) |
| `src:github`, `needs-human` labels | GitHub-origin, Barkpark once born | inbound_intake_only | issue labels (set at birth, then Barkpark-owned) |
| issue title/body/author (outsider) | GitHub | inbound_intake_only | read ONCE at birth to seed `gh-<num>` |
| `github:{repo,issue,synced_rev,state}` | Barkpark (bookkeeping) | internal | stored in task content, never rendered to GitHub |
| Projects v2 Status/Priority/Worker/Goal | Barkpark | outbound_only | GraphQL field values, NEVER read back |
| claim, epoch, fence, rail_rev | Barkpark | never | NEVER represented on GitHub |

## Roadmap

**Wave 1 — foundation — ✅ DONE (#1229).**
1. Plugin skeleton (off by default) + settings_schema/validate_settings — `github.ex` + `plugin.json`
2. Field-ownership matrix + pure task→issue projection — `github/fields.ex` + `github/projection.ex`
3. GitHub App auth + REST client (Bypass) — `github/auth.ex` + `github/client.ex` + `github/errors.ex`
4. Durable cursor + outbox reader + `source="github"` exclusion (DB-only) — `github/cursor.ex` + `github/outbox.ex`
5. `content.github` Link helper + inbound HMAC signature verifier (pure) — `github/link.ex` + `github/signature.ex`

**Wave 2 — outbound mirror engine (the heart) — ✅ DONE (#1232):** debounced per-task Oban `MirrorJob` assembling
cursor→outbox→projection→client→Link idempotency; no-op on `rev==synced_rev`; `{:snooze}` on 429;
lifecycle close mapping; drain worker on `oban_crontab`; wire routes/cron into `github.ex`.

**Wave 3 — inbound intake — ✅ MERGED (#1234, `3fbd61ca`):** webhook controller + endpoint raw-body cache + signature plug (from
wave-1 verifier) + `[bot]`-identity drop + intake via `Content` create through the `Tasks.Dedup`
seam (deterministic `gh-<num>`, `src:github`+`needs-human`, `source: :github`) + "tracked
internally" backlink comment. Wave-2.5 carries folded in (tenant scope threaded into `reconcile`,
`active?/0` memoized in DrainWorker). `@canonical capability:github-inbound-intake` on `Intake.ingest/2`.
`Intake.ingest/2` short-circuits a re-delivery to `{:ok, :exists, doc}` (reads the outsider issue
EXACTLY ONCE at birth); born-dark task stamps `content.github.state = "intake"` (the wave-4 adopt find-key).

**Wave 4 — adoption + conflict quarantine — ✅ DONE (#1236):** adopt action (Studio doc_action + `bp github adopt`)
strips `needs-human`/flips ownership/posts backlink; `github_sync_conflicts` record-then-converge
on out-of-band edits; deleted issue → `detached`, never recreated; dedup-refusal surfaced (no silence);
webhook secret memoized (kill pre-verify audit amplification). The plugin dir now ships **18 modules**
(adds adopt, cli, conflict, conflicts + the `github_adopt_controller` + `github_sync_conflicts` migration).

**Wave 5 — Projects v2 + relations — ✅ MERGED (#1237, `1069a8b7`):** one-directional GraphQL auto-add + custom fields
(diffed against a stored `projects_fingerprint` so an unchanged task writes ZERO GraphQL);
`parent_id`→native sub-issues (deferred-retry when parent unmirrored, cap-flatten past 8-level/100-child);
`blocks`→`<!-- barkpark:blocks -->` body marker (projection already renders it; wire the `blocker_issue_refs`
hydration). Isolated LAST so it can't destabilize the proven Issues loop. **See the "Wave 5 CUT" section for
the 4-slice build plan.**

**Wave 6 — observability — ✅ MERGED (#1238, `f7f47cc8`):**
sync-health state (cursor/lag/queue-depth/open-conflicts) + `/admin/github` `:ops` console (pulse precedent) +
`bp github status` verb + fold in the 3 wave-5 deferrals (child-count cap, real-422 distinction, GraphQL-RATE_LIMITED
visibility). **See the "Wave 6 CUT" section for the 4-slice build plan.**

**Wave 7 — needs-human — ✅ DONE (2026-07-08, LIVE on guerrilla):** App `barkpark-bridge-frikkern`
created + installed on FRIKKern/barkpark, secrets provisioned, `github` whitelisted — bridge live
(active:true, cursor==head, 0 conflicts; 433 tasks carry an outbound link). Two live-found fixes
merged: **#1243** (`db8b7382`, MirrorJob resolves repo via Settings env→DB) and **#1247**
(`80fc9b73`, project top-level task title + draft/publish mirror-job dedup). Outbound round-trip
(create→issue→close) and inbound BOT-DROP verified live; the **human-opened inbound issue test did
NOT happen** — that is wave 8's gate.

**Wave 8 — the inbound journey, proven and hardened — 🔨 CUT (2026-07-09, architect pass):** fix the
live `resolve_doc_actions` struct-Access defect (shared antipattern with onixedit) + scope-aware
Studio adopt; gate the outbound mirror on `state=="intake"` (D13 — adoption is the consent moment);
widen inbound bookkeeping (D14 — deleted/transferred/human-closed intake → VISIBLE detach, bot-drop
first, no lifecycle write ever); thread tenancy at the adopt/intake edges (D15) + pay the test debt
(full-stack signed-body ConnCase, conflicts detail merge-not-overwrite, Health `db_ok` liveness);
then ONE live human-opened issue driven intake→adopt→backlink. **See the "Wave 8 CUT" section.**

**Wave 9 — exposure hardening + scoping-gate reconciliation — 🔨 CUT (2026-07-13):** two un-gated named-failure
fixes (D17 conflict-source dedup; D18 github-status dataset read-scope) + reconcile the human exposure gate in
the ledger (cite/enrich `github-bridge-mirror-exposure-decision`, refresh the count, correct its phantom-charter
citation) + file the outbound-scoping SPINE as a needs-human-blocked backlog child (D16). Two opus slices,
file-disjoint, each with a fail-before Bypass test. **See the "Wave 2026-07-13 — Wave 9 CUT" wave-log entry.**

## Wave log

### Wave 2026-07-13 — Wave 9 CUT — exposure hardening + scoping-gate reconciliation (architect pass, two rounds of ground truth)

**Reconciliation (audited vs `main` + the live guerrilla ledger + FRIKKern/barkpark, 2026-07-13):**
- The lead brief's "waves 1-3 shipped" is STALE — waves 1-6 merged (#1232-#1238), wave 7 (human App gate) done,
  wave 8 S1-S4 merged and LIVE on guerrilla (D13 intake gate, D14 inbound breadth, D15 tenancy; `content_probe` +
  `inbound_events` + `db_ok` all on main). The bridge is live and mirroring.
- **w8-S5 is a human live-proof gate, not loop-buildable.** The charter's earlier "HALTED" prose (the S5 builder
  refused to run against a then-undeployed intake gate) is superseded: s1-s4 are deployed; S5 remains the one
  human-driven one-issue journey (born-dark → pre-adopt edit untouched → adopt → consent mirror → clean close).
  No code blocks it. Not in this wave.
- **The exposure OPEN QUESTION is now OWNED, not unfiled.** Task `github-bridge-mirror-exposure-decision`
  (open, needs-human, priority 2, 0/3) is the ruling gate — filed twice (an earlier 442-count version
  `task-7b4f323525daa2d5` was cancelled as a duplicate). Fresh count at cut: 277 open / 1193 total / 916 closed,
  ~195 issues/day (was 134/609 on 2026-07-10 — roughly DOUBLED). Re-count at ruling time.
- **Charter-desync corrected:** the decision task cites a section 'Wave 2026-07-10 — LIVE-PROOF CUT FIRED,
  decision 4' that does NOT exist (git log stopped at wave 8, #1994). THIS section + D16 are the real owner of
  the exposure-ruling context; the decision task now carries `wave_paper` + a Decide reconciliation note pointing
  here.

**The crux Decide ruled (evidence overrode the Strategize lean "build the knob either way"):** two rounds of
verification proved the decision task is STRICTER than that lean — its crit-1 is a HUMAN choice among five
distinct options and its crit-2 files enactment slices AFTER the ruling carrying its parameters. An inert
default=mirror-all knob is compatible with crit-3's narrow "zero destructive action" text, BUT building any
specific predicate SOURCE (label/workspace/flag) pre-selects an option and front-runs crit-1 — exactly the "two
parallel un-reconciled records" the survey warned against. RULING: this wave builds NO spine. It ships the two
un-gated named-failure fixes, reconciles the human gate in the ledger, and files the spine fully pre-specified so
the human ruling → one-wave enactment (D16).

**Wave = 2 slices (both opus — Fable exhausted; file-disjoint, parallel):**
- **S1 (D17) conflict-source dedup** — `github-bridge-w9-s1-conflict-source-dedup`. Widen dedup to
  `{repo,issue,kind,COALESCE(detail->>'source','')}` in `Conflicts.open_row/1` + a lockstep migration recreating
  the `github_sync_conflicts_open_key` partial unique index. Reverse the now-wrong merge-collapse test
  (`conflicts_test.exs:101-126` → 2 rows) + a net-new fail-before test: graphql + sub_issue_rejected on the SAME
  `{repo,issue}` → 2 distinct open rows (fails before, passes after) + a protective test that five no-source human
  edits still dedup to ONE row (COALESCE null-trap guard). No new kind (D14 held). Gate:
  `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/github/conflicts_test.exs`.
- **S2 (D18) github-status dataset read-scope** — `github-bridge-w9-s2-health-dataset-scope`. Make
  `Health.snapshot/1` honor its dataset arg (filter datasets_snapshot + conflicts by the string) AND constrain the
  controller's effective dataset to `conn.assigns.api_token.dataset` so no token reads whole-fleet. Fail-before: a
  token scoped to dataset A must NOT see dataset B's health. NOT ScopeHelpers (seeded-Default trap). Gate:
  `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/github/health_test.exs test/barkpark_web/controllers/github_status_controller_test.exs`.

**Backlog filed (published children, needs-human / blocked):**
- `github-bridge-spine-outbound-scoping` (child of the decision task) — SPINE-A eligibility gate + SPINE-B
  reconcile-over-shared reap, pre-specified with the settled seam (`reconcile/3`), the adopt-exemption ruling
  (D16), and the dead-code `Client.close_issue/4` reuse (close + `Link.put(state:detached)` to avoid the D7
  reopen-storm). Blocked on the human ruling; builder claims the moment an option is chosen.
- `github-bridge-w9-health-workspace-isolation` (child of epic) — the BIGGER GAP-2 upgrade: net-new
  `workspace_id`/`dataset_id` columns on `github_sync_conflicts` + `sync_push_cursors` + backfill + populate from
  MirrorJob's carried `workspace_id`, so a token in workspace A never sees workspace B's "production" health.

**Doctrine unchanged and LAW:** Barkpark is the single source of truth; mirror is OUTBOUND-only; inbound is
intake/bookkeeping-only; `mutation_events.source` stays EXACTLY `"github"`; no field is bidirectional;
`Conflicts.record` stays DB-only; source is never read back; plugin off by default.

**Verify fleet proofs (trust > prose):** github plugin suites run GREEN locally in the main checkout with a warm
build — conflicts 22/0, health+status-controller 20/0, mirror_job 38/0, client 33/0. A bare worktree fails at
`mix deps.get`; builders borrow main's `deps` + `cp -a _build/test` (lockfree-worktree-gate), never symlink
`_build` under concurrent compile. GAP-1 premise partly refuted (merge-not-overwrite already shipped; the
residual is the operator-visible conflation D17 fixes). GAP-2 sharper than framed (`?dataset=` is a dead param,
not just "blank"). Paper: `github-bridge-wave-2026-07-13`.

### Wave 2026-07-07 — Wave 1 foundation (5/5 green, merge-ready)

**Landed** — all 5 disjoint-file slices, every gate against mocked/pure GitHub, nothing wired live:
1. **Plugin skeleton** (`github.ex` + `plugin.json` + test) — off by default, deliberately inert:
   `register_routes/1`, `oban_crontab/0`, `register_schemas/1` all `[]`. Real surface: `settings_schema/0`
   (6 App creds, private_key+webhook_secret `:password`+`:masked`), fail-closed `validate_settings/1`
   (5 required creds; malformed-row fail-OPEN gap closed by perfecter), `desk_items/1` → `/admin/github`
   (dodges the studio desk scoper). NOT whitelisted → dark until wave 7.
2. **Safety spine** (`fields.ex` + `projection.ex`) — pure. `Fields` = test-enumerable ownership matrix,
   NO reverse writer exists so bidirectionality is impossible by construction; property test asserts no
   field is bidirectional and claim/epoch/fence/rail_rev are `:never`. `Projection.task_to_issue/1` covers
   title/body/labels/state/state_reason/synced_rev + `Task: <doc_id>` trailer + idempotent prose-preserving
   fence; exhaustive lifecycle→state table.
3. **App auth + REST client** (`auth.ex` + `client.ex` + `errors.ex`) — Bokbasen-shaped (D8), Bypass-tested
   (21 tests incl. real RS256 verify). Singleton GenServer mints RS256 app-JWT → installation token
   (cached monotonic+expires−60); Client wraps create/update/close_issue + labels/comment; 401→refresh-once;
   rate-limit surfaces `retry_after` WITHOUT sleeping (D9). 4 typed errors, token-redacting Inspect.
4. **Cursor + outbox** (`cursor.ex` + `outbox.ex`) — DB-only, structural copy of Sync.PushCursor/Outbox.
   Cursor rides `sync_push_cursors` under reserved key `github:outbound` (no migration); `bootstrap_if_absent`
   seeds MAX(mutation_events.id) → no backlog mirror. Outbox `fetch` = `id > after AND type=="task" AND
   (source IS NULL OR source != "github")` — loop-cut #2. Verified D6: task lifecycle events carry the kind
   in `mutation` while `type`="task", so the type filter captures ALL task events.
5. **Link + signature** (`link.ex` + `signature.ex`) — pure/Content. `Link` = flat `content.github`
   {repo,issue,synced_rev,state} via `Content.*` ONLY, stamps `source: :github` (loop-cut #2 twin);
   `synced?/1` = synced_rev==_rev (loop-cut #3). `Signature` = pure X-Hub-Signature-256 HMAC-SHA256,
   constant-time, fails closed. No route/plug (wave 3 wires it).

**Stalled** — nothing. Zero NOT-GREEN. Boot-test showed 4 PRE-EXISTING/environmental failures (unseeded
local DB → empty /api/schemas; existing bulldocs→OnixEdit invariant #3 violation) — verified no host code
references `Barkpark.Plugins.Github`, so the fresh-install invariant holds; zero new boot-test failures.

**Cross-wave contracts wave 2+ MUST honor (perfecter-flagged, not defects here):**
- **AUTH START (blocks wave 2 runtime).** `Github.Auth` is a singleton GenServer that NO slice starts.
  Wave 2 MUST add it to `register_workers/1` (or supervision) or `Auth.token/0` crashes no-process at runtime.
- **DRAFT-TWIN (sharpest handoff).** `Link.put` writes the DRAFT row (Content.upsert coerces status→draft).
  Wave-2 MirrorJob MUST read the link via `Link.get` (draft-first) — reading the PUBLISHED perspective misses
  `github.issue` and CREATES a duplicate issue. Also owe a publish strategy or every mirrored task shows a
  permanent unpublished draft twin in Studio.
- **4xx ERROR CLASSIFICATION.** 422/validation surfaces as `NetworkError{reason:{:http,422}}` — status IS
  preserved in the tuple. Wave-2 MirrorJob MUST classify `{:http, s in 400..499}` as non-retryable/dead-letter,
  else it retries a permanent 422 forever. (No 5th error type added, respecting D8's fixed 4-type set.)
- **synced_rev NO-OP IS DEAD IN STEADY STATE.** Link.put's own stamp write bumps _rev, so synced_rev always
  lags current _rev → `synced?/1` ~never true right after a mirror. The REAL loop guard is the source=github
  outbox exclusion (airtight). synced_rev equality only catches a coalesced/duplicate Oban job and converges
  via ONE redundant idempotent PATCH, not a loop. If wave 2 wants the no-op optimization to actually fire it
  needs a different convergence key than `synced_rev == current _rev` — D3's wording implies more than the
  mechanism delivers. Reconcile D3 wording or accept the redundant-PATCH convergence.
- **LOOP-CUT #2 IS AN EXACT STRING.** Wave 3 inbound MUST stamp `mutation_events.source` as exactly `"github"`
  (`to_string(:github)`). If wave 3 ever namespaces it (`"github:inbound"`) those rows slip the exclusion and
  echo back out → mirror loop. Guard in wave-3 review.

**Next wave: Wave 2 — outbound mirror engine (the heart).** Assemble cursor→outbox→projection→client→Link into
a drain worker (`oban_crontab`) + debounced per-task `MirrorJob` (unique on doc_id, schedule_in:30). Wire
Auth into `register_workers`, wire routes/cron into `github.ex`. Land the 4xx/snooze classification and the
`Link.get` draft-first read as first-class. `@canonical capability:github-mirror-reconcile` on the reconcile fn.

> ⚠️ CHARTER DRIFT: this file was concurrently reverted to its pre-wave-2-cut state — the architect's Wave-2
> amendments (**D12** publish-twin/creds-resolver, **D3 AMENDED**, the 4-slice Roadmap Wave 2 detail, and the
> "Wave 2 CUT" log entry) were lost by a base-drift worktree write. Re-apply them from PR #1229's follow-on and
> the wave-2 slice branch commit messages. The wave-2 facts survive in the log entry below.

### Wave 2026-07-07 — Wave 2 outbound mirror engine MERGED (#1232)

**RECONCILED (this architect pass):** Wave 2 landed on `main` as a single squash — commit `bb547f57`
`feat(github): wave-2 outbound mirror engine — DrainWorker + MirrorJob + creds bridge (#1232)`. The
base-drift blocker below was resolved by the integrator (rebased onto `origin/main`, past #1228/#1230).
The github plugin now ships 12 modules under `api/lib/barkpark/plugins/github/`
(auth, client, cursor, drain_worker, errors, fields, link, mirror_job, outbox, projection, settings,
signature) + `plugins/github.ex` wiring. `github_mirror: 2` Oban queue is declared in `config/config.exs`;
`DrainWorker enabled: false` in `config/test.exs`. Waves 1+2 are DONE. The two cross-wave carries
(TENANT SCOPE, `active?/0` memoize) are folded into Wave 3's cut below.

### Wave 2026-07-07 — Wave 2 outbound mirror engine BUILT (superseded by the MERGED entry above)

The heart is assembled. All four slices built + perfected; each carries a `-p` (perfecter) branch. Real forward
movement on the WISH — not micro-repair. Tasks→Issues now flows end-to-end drain→enqueue→reconcile→create/PATCH
→stamp, with loop-immunity proven. Branches: `loop-epic/{mirrorjob-…-0, github-settings-…-1,
link-publish-twin-…-2, drainworker-…-3}` (+ each `-p`).

**Landed (on branches, pending integration):**
1. **MirrorJob** (`github/mirror_job.ex`, 13 tests) — Oban worker on `github_mirror`, `unique` on `{doc_id,dataset}`
   period:60 (D2 coalesce), `enqueue/1` `schedule_in:30`. `reconcile/2` carries
   `@canonical capability:github-mirror-reconcile`; loads task DRAFT-FIRST (contract #2, normalises off the
   `drafts.` prefix so the `Task:` trailer is clean), short-circuits on detached link (D7) + `synced?` coalesce
   (D3 amended), projects, CREATE-or-idempotent-PATCH, stamps `Link.put`. Full D8 4-type error map incl. permanent
   422 dead-letter + NotFound-on-update→`detached` never-recreate. Perfecter fixed a born-closed terminal-state
   drift + nil-repo crash-loop guard.
2. **`Github.Settings` + Auth rewire** (`github/settings.ex` + `auth.ex`, 53 tests) — Bokbasen-shaped env→DB creds
   resolver: `get_credentials/0`, fail-closed `active?/0` (whitespace-trimmed), `repo/0`, `datasets/0` (env-only
   `:github_mirror_datasets`, default `["production"]`). `required_creds/0` made public in `github.ex` = single
   source driving both `validate_settings/1` and `Settings.required_keys/0`. `Auth.config/0` delegates
   (keyword→map, verified no external caller). Wave-1 tests stay green.
3. **Link publish-twin collapse (D12)** (`link.ex` +83 / `link_test.exs` +111) — already-published tasks re-publish
   via `Content.publish_document(source: :github)`, collapsing the draft twin AND stamping the publish
   `mutation_event` `source:"github"` (outbox-excluded, machine-checked immunity test). Perfecter fix: a genuine
   never-published draft is LEFT a draft (never force-published under a human).
4. **DrainWorker + wiring (integrator)** (`github/drain_worker.ex` + `github.ex` + `config.exs`, 23 tests; full
   plugin suite 125/125) — supervised drain-tick GenServer on the `PushWorker` precedent: per-tick re-bootstraps
   each whitelisted dataset's cursor to head (D1 backlog skip, closes a builder-latent flood bug), idle-gates on
   `active?`, `Cursor.get`→`Outbox.fetch`(source≠github)→enqueue MirrorJob per event→write-then-advance,
   HALT-not-skip + capped backoff on enqueue error. Seams injected (no Oban/net/sleep in tests).
   `register_workers/1`→`[Auth, DrainWorker]` (AUTH START ✓); `oban_crontab` empty; static `github_mirror: 2`
   queue added. Capstone proves drain-level loop-immunity. `Code.ensure_loaded?(Settings)` seam guard keeps a
   pre-slice-2 boot dark.

**Stalled** — nothing NOT-GREEN. Wave is code-complete.

**BLOCKER before merge (base drift — sharpest risk):** the slice branches were cut off the wave-1 base, BEFORE
#1228 (columns) and #1230 (autoupdate) merged. Naive merge of a `-p` branch REVERTS those PRs — slice 3's raw
diff shows ~1400 phantom DELETIONS (`columns-node.js`, `autoupdate_rollout_worker.ex`, cloud registry, …).
Integrator MUST rebase each `-p` onto current `origin/main` (or cherry-pick ONLY the `github/`+`config` hunks)
before landing. Merge order: slices 1, 2, 3 (file-disjoint), THEN slice 4.

**Cross-wave carries for wave 3+ (perfecter-flagged, not defects):**
- **TENANT SCOPE (real gap).** `reconcile/2` uses EMPTY opts → default workspace/project only. DrainWorker threads
  DATASET but not workspace/project, so a non-default-tenant task is silently not-found or mis-written. Wave 3 (or
  a fast wave-2.5) MUST thread real tenant scope from the outbox event into `reconcile`.
- **`active?/0` IS NOT FREE.** Each call = 1 DB read + 1 audit-row insert + telemetry. DrainWorker calls it every
  tick — MUST memoize (short TTL) or it hammers the DB and buries genuine admin audit events.
- **LOOP-CUT #2 IS AN EXACT STRING.** Wave-3 inbound MUST stamp `mutation_events.source` exactly `"github"`; any
  namespacing (`"github:inbound"`) slips the outbox exclusion → mirror loop. (Carried from wave 1.)
- **CONFLICT QUARANTINE (D7) is wave 4.** Out-of-band GitHub edits converge silently today; only
  deleted/transferred issues get `detached`. Expected until wave 4.

**Next wave: integrate + merge the 4 wave-2 `-p` branches (rebased), THEN Wave 3 — inbound intake.** Webhook
controller + raw-body cache + signature plug (wave-1 verifier) + `[bot]`-identity drop + `Content` create through
the `Tasks.Dedup` seam (deterministic `gh-<num>`, `src:github`+`needs-human`, `source: :github`) + backlink
comment. Fold TENANT-SCOPE threading and `active?/0` memoization into wave 3's cut (or a fast wave-2.5 cleanup).

### Wave 2026-07-07 — Wave 3 inbound intake BUILT (4/4 green, merge-ready)

The full outsider journey is assembled end-to-end: `issues.opened` webhook → signature-verified request edge →
born-dark `gh-<num>` task through the Dedup seam → best-effort backlink comment. Real WISH movement (the second
of the two directions the vision promised), not micro-repair. All 4 slices GREEN, every perfecter SHIP IT, zero
NOT-GREEN. Both wave-2.5 carries closed in the same wave. `@canonical capability:github-inbound-intake` on
`Intake.ingest/2`.

**Landed (on branches, pending integration):**
1. **Request plumbing (slice 1)** — `BarkparkWeb.Plugs.CacheBodyReader.read_body/2` tees RAW bytes into
   `conn.assigns[:raw_body]` ONLY on `/v1/plugins/github/webhook` (path-scoped, every other path reads through
   at zero cost, byte-identical to Plug.Parsers default → no route regresses); `endpoint.ex` wires
   `body_reader:` into the existing `Plug.Parsers.init`. `GithubWebhookSignature` plug reads raw_body +
   `x-hub-signature-256` + `Settings.get_credentials()[:webhook_secret]`, delegates to the wave-1 constant-time
   `Signature.verify/3`. FAIL CLOSED via a single `reject/1`: nil/non-binary raw_body, missing header,
   blank/absent secret (dark plugin), tampered sig → 401+halt. New `:github_webhook` pipeline (accepts json +
   sig plug, the ONLY auth — no token, no CORS) + dormant `/v1/plugins` bucket. Companion edit: registered
   `:github_webhook` in the `plugin_routes` allow-list (`router/plugins.ex`) or the bucket raises at compile.
   10 tests, full 607-file compile clean.
2. **Intake service (slice 2)** — `Barkpark.Plugins.Github.Intake.ingest/2`, five ordered gates: event filter
   (`action=="opened"`+issue else `:ignored`); bot drop (`sender.type=="Bot"` → `:dropped` BEFORE any Content
   write, loop-cut #1); deterministic `gh-<num>` doc_id; `Content.create_document(..., source: :github)` so
   first delivery runs Dedup and re-delivery is an idempotent no-op AND `mutation_events.source` stamps EXACTLY
   `"github"` (loop-cut #2, tested against `Outbox.fetch`); best-effort backlink via injectable `comment_fun`
   (logged-and-swallowed on failure). Born open+UNCLAIMED, `src:github`+`needs-human`, never touches
   synced_rev/claim/worker/epoch. 15 tests (0 failures), anchors gate PASS.
3. **Controller + wiring (slice 3)** — `BarkparkWeb.GithubWebhookController.receive/2`: `X-GitHub-Event:
   issues` → `Intake.ingest/2` (dataset from `Settings.datasets/0`); `ping` → 200; other → 202 no-op. Every
   verified-but-unactionable delivery is 2xx (no retry storm); only a genuine intake `{:error,_}` is 5xx
   (retryable, idempotent via `gh-<num>`). `register_routes/1` returns `{:post,"/github/webhook",…,auth:
   :github_webhook}`. App-env seam (`:github_webhook_intake_fun`) makes dispatch unit-testable without slices
   1+2. 24 tests (with plugin_test), clean compile.
4. **Wave-2.5 carry cleanup (slice 4)** — (a) TENANT SCOPE: thread workspace_id/project_id from the drained
   outbox MutationEvent → MirrorJob args → `reconcile` opts → load_task + Link.put, so a non-default-tenant
   task is read/stamped under its OWN scope (was mis-writing bookkeeping into seeded Default → re-CREATE loop).
   Back-compat: absent keys keep wave-2 default-scope; Oban unique keys unchanged. Also fixed a real latent bug
   (default_enqueue passed a map to a binary-only enqueue — FunctionClauseError, masked by the always-injected
   seam). (b) `active?/0` MEMOIZE: ~5s monotonic-TTL cache in DrainWorker state (injectable `active_ttl_ms`),
   D9-safe — idle_ms(15s) > TTL(5s) so steady-state idle always re-resolves; memo only bites sub-5s backoff
   storms; bootstrap guard intact. Targeted 28/0, full github dir 177/0, `--warnings-as-errors` clean.

**Stalled** — nothing NOT-GREEN. Wave is code-complete on branches; same base-drift integration discipline as
wave 2 applies (rebase each `-p` onto current origin/main; land slices 1,2,4 then 3).

**Cross-wave carries for wave 4 (perfecter-flagged, not defects):**
- **DEDUP-REFUSAL SILENT DROP (design edge, wave 4 owns).** A FIRST-delivery outsider issue the Dedup seam
  judges a look-alike returns `{:error,{:duplicate_task,_}}` — no task, no backlink, no linkage — and because
  nothing persisted, EVERY re-delivery re-refuses (no future `adopt` can find the issue). Faithful to D6 but
  the outsider gets total silence. Wave 4 (adopt/quarantine) MUST decide how to surface a swallowed intake
  (comment? label? dead-letter?).
- **DB-AUDIT AMPLIFICATION on the live route.** The signature plug calls `Settings.get_credentials()` per
  request (after cheap raw_body+header checks, before sig verify), which logs a "read" audit row + telemetry
  by design — so any unauth POST carrying an `x-hub-signature-256` header forces a DB write before the sig is
  checked (mild flood primitive on a probed endpoint). Inherent (can't verify without the secret); fix is a
  short-TTL secret memoization at the Settings layer (mind webhook-secret rotation staleness). Wave 4 decision.
- **INTEGRATION-ONLY WIRING.** The endpoint tee surviving into the router pipeline is exercised end-to-end only
  by slice 3's ConnCase (parse_body L71 before Router L85 — provably correct by inspection). Keep a ConnCase
  that POSTs a real signed body through the full stack; confirm GitHub's `Accept: */*` resolves to json and
  isn't 406'd before the sig gate. Double-backlink race (concurrent first-delivery) collapses to ONE task row
  via the unique constraint — negligible.
- **LOOP-CUT #2 STAYS AN EXACT STRING.** (carried) any future inbound path must stamp source exactly `"github"`.
- **CONFLICT QUARANTINE (D7) + `detached` handling remain wave 4.** Unchanged from wave 2.

**Next wave: Wave 4 — adoption + conflict quarantine.** `adopt` action (Studio doc_action + `bp github adopt`)
strips `needs-human`/flips ownership into Barkpark/posts a backlink, keyed on `github.state=="intake"` (the
value this wave stamps). `github_sync_conflicts` record-then-converge on out-of-band GitHub edits; deleted/
transferred issue → `github.state=detached`, never recreated. Fold in the two intake design edges above:
surface a dedup-refused intake (don't leave the outsider silent) and memoize the webhook secret to kill the
pre-verify audit amplification. `@canonical` on the adopt entry point.

### Wave 2026-07-07 — Wave 3 inbound intake MERGED (#1234) — RECONCILED (architect pass)

Wave 3 landed on `main` as squash `3fbd61ca feat(github): wave-3 inbound intake — outsider issue → born-dark
task (#1234)`. The plugin dir now ships **14 modules** (waves 1-3): auth, client, cursor, drain_worker, errors,
fields, intake, link, mirror_job, outbox, projection, settings, signature (+ `plugins/github.ex`). New host-side:
`BarkparkWeb.Plugs.CacheBodyReader`, `BarkparkWeb.Plugs.GithubWebhookSignature`, `BarkparkWeb.GithubWebhookController`,
the `:github_webhook` router pipeline + `/v1/plugins` bucket, `endpoint.ex` body_reader wiring. `github.ex`
`register_routes/1` now returns the one webhook route; `register_workers/1 → [Auth, DrainWorker]`. Waves 1+2+3 DONE.
Verified against code (all four wave-4 carries confirmed live): (1) dedup-refusal `{:error,{:duplicate_task,_}}`
from `Content.create_document` bubbles straight out of `Intake.birth/2` with NO comment/persist — silent (intake.ex
L164-166); (2) MirrorJob `classify(%NotFound{}, :update, …)` stamps `state:"detached"` but records NO quarantine row
(mirror_job.ex L275-281); (3) the signature plug reads full `Settings.get_credentials()` per request → audit-row +
telemetry BEFORE sig verify; (4) `content.github.state == "intake"` is the adopt find-key. All four are the Wave 4 cut.

### Wave 2026-07-07 — Wave 4 adoption + conflict quarantine BUILT (5/5 green, merge-ready)

The intake→adopt journey CLOSES and D7 goes from doctrine to running code. Real WISH movement, not micro-repair:
an operator now flips a born-dark `gh-<num>` intake into Barkpark ownership with one verb; no outsider is met with
silence; out-of-band GitHub drift is RECORDED before the ledger overwrites it; a deleted/transferred issue detaches
with a surfaced record and is never recreated; the live webhook endpoint stops amplifying an audit row per probe.
All 5 file-disjoint slices GREEN, every perfecter SHIP IT, zero NOT-GREEN. Branches: `loop-epic/{quarantine-substrate-…-0,
adopt-action-…-1, dedup-refusal-surfacing-…-2, conflict-quarantine-…-3, webhook-secret-memoize-…-4}` (+ each `-p`).

**Landed (on branches, pending integration):**
1. **Quarantine substrate (slice 1)** — new `github_sync_conflicts` side table (migration mirrors the `pulse_events`
   plugin-owns-a-table precedent) + `Github.Conflict` schema + `Github.Conflicts` recorder. Columns repo/issue/doc_id
   (nullable)/dataset/kind(`out_of_band_edit|detached|dedup_refused`)/detail(map)/resolved_at(nullable)/timestamps;
   indexes `[:repo,:issue]` and `[:kind,:resolved_at]`. `record/1` DEDUPS an already-open `{repo,issue,kind}` by
   update-in-place under `FOR UPDATE` (one open conflict per key, never a pile — now DB-enforced via a partial unique
   index, not just a documented caveat); `list/1` open rows newest-first filtered by repo/kind; `resolve/1` clears +
   lets the key re-open. DB-only, NEVER touches `Content.*`/`mutation_events` — no loop surface (asserted by a test).
2. **Adopt action (slice 2)** — `Github.Adopt.adopt/3` (`@canonical capability:github-adopt`) loads draft-first, gates
   STRICTLY on `content.github.state=="intake"` (already-`adopted` → idempotent `{:ok,doc}`; else `:not_intake`; missing
   → `:not_found`), strips `needs-human` (keeps `src:github`), sets `github.state="adopted"`, persists via
   `Content.upsert_document(source: :github)` with the `Link.put` draft-twin collapse so the mutation_events.source is
   EXACTLY `"github"` (D4 cut #2, outbox-excluded). NEVER touches claim/worker/epoch (D6), never reads a GitHub field
   back (D5); backlink rides an injectable `:comment_fun`. `Github.CLI.commands/0` + `github.ex` `cli_commands/0`
   delegate (tickets merge-safe `Code.ensure_loaded?` pattern) so `bp github adopt` falls out of `/v1/capabilities`
   with NO Go source change. `GithubAdoptController` on `POST /v1/plugins/github/adopt/:id` (`:token` bucket, seam-injectable).
   Studio "Adopt from GitHub" doc_action surfaced only for an intake task (string+atom-key safe, onixedit precedent).
3. **Dedup-refusal surfacing (slice 2/label-3)** — `Intake.birth/2`'s `{:error,{:duplicate_task,verdict}}` branch (was
   a silent re-refuse-forever drop) now: posts a maintainer comment via `:comment_fun`; records a findable
   `dedup_refused` dead-letter row via a NEW injectable `:conflict_fun` seam (resolves the slice-1 recorder dynamically
   so it compiles before slice 1 lands); returns a DISTINCT `{:refused, doc_id}` mapped to 2xx by the webhook controller
   (no GitHub retry-storm, comment posts once). Genuine non-dedup create errors stay `{:error,_}`→5xx retryable
   (fail-open preserved). 4 tests trip the REAL `Tasks.Dedup` seam.
4. **Conflict quarantine + detached visibility (slice 4)** — `Client.get_issue/3` (thin sibling of `update_issue`).
   MirrorJob's UPDATE path now GETs+fingerprints ONLY the ledger-owned projected fields (title/body/labels-sorted/state
   via `:erlang.phash2`) BEFORE the idempotent PATCH; a stored `synced_fingerprint` that differs → records an
   `out_of_band_edit` conflict, THEN PATCHes (ledger wins), THEN stamps `Link.put` with `synced_rev`+`synced_fingerprint`
   for next-pass drift detection. GET reads GitHub values ONLY to fingerprint the RECORD, never into a task field (D5).
   Absent a stored fp → records nothing, just stamps (rolls forward, NO backfill). Detached branch records a `detached`
   conflict before stamping `state:"detached"`+cancel; never recreated (D7). 403/429 on the extra GET snoozes via
   `classify` (D9).
5. **Webhook secret memoize (slice 5)** — `Settings.webhook_secret_cached/0` resolves ONLY the webhook_secret,
   memoized in `:persistent_term` with a monotonic TTL (app-env `webhook_secret_ttl_ms`, default 5000ms). Cache hit
   within TTL → zero DB touch; the signature plug reads the memoized value so an unauth probe carrying
   `x-hub-signature-256` no longer forces a DB write + audit row before HMAC verify. Fail-closed 401 semantics
   byte-for-byte unchanged; a dark plugin caches nil. Rotation staleness bounded to one TTL window.

**Also caught + fixed (severe pre-existing bug, NOT wave-4 scope):** the wave-3 `GithubWebhookController` matched
`{:ok, _doc}` (2-tuple) against `Intake`'s real `{:ok, :born|:exists, doc}` (3-tuple) — a PERPETUAL 500 on every
successful inbound birth once the plugin is enabled; the controller test passed VACUOUSLY on 2-tuple stubs (classic
vacuous-green trap). Fixed in isolated commit `4a4127c8` (+ test `9c221f1f`), zero-conflict with sibling slices.
Without it, inbound intake is DEAD in prod — it SHOULD land (integrator may drop only if the fix is owned elsewhere).

**Stalled** — nothing NOT-GREEN. Wave is code-complete on branches; same base-drift integration discipline applies
(rebase each `-p` onto current origin/main — slice 4's `-p` was verified to fast-forward cleanly, but confirm the rest).
Merge order: slice 1 (substrate) FIRST → then 3 (intake.ex) + 4 (mirror_job.ex) in parallel → 2 + 5 any time.

**Integrator MUST resolve — substrate is built TWICE:** slice 1 AND slice 4 both ship `conflict.ex` / `conflicts.ex` /
`priv/repo/migrations/20260707120000_create_github_sync_conflicts.exs` (slice 4 built them to run in isolation). The
perfecter made them byte-identical to slice-1's `-p` tip, so keep ONE and the dedup is trivial — but if slice-1's `-p`
gets further polish before landing, RE-SYNC slice 4's three copies to whatever ships as slice 1; do NOT let slice 4's
copies win a divergent conflict.

**Cross-wave carries / known edges (perfecter-flagged, not defects):**
- **MIGRATION INDEX ON A SHARED TEST DB.** The partial-unique index was added to the (already-applied, still-max,
  unmerged) migration file. On main / any fresh or prod DB it has NEVER run → applies clean first time. But a worktree
  whose test DB already applied the old (indexless) version needs a drop-and-remigrate (or `mix ecto.reset`) to pick up
  the index — it will NOT re-run on the same timestamp. CONFIRM the partial unique index exists post-deploy.
- **`Conflicts.record/1` reconverge branch is not deterministically unit-tested** (true concurrent txns are impractical
  under the SQL sandbox). Proven: the DB rejects a duplicate open row and the constraint surfaces as the exact
  `constraint: :unique` shape the detector keys on. The reconverge is defense-in-depth; worst case the losing insert
  errors and the Oban job / webhook retries + converges. No consumers depend on it today.
- **persistent_term memoize has no single-flight.** A concurrent probe burst arriving exactly at the TTL boundary yields
  O(concurrency-at-boundary) racing misses, each a DB read + a node-wide-GC `persistent_term.put`. Steady-state within
  the window is still zero-DB — a large net reduction vs the per-request audit-write it kills. Acceptable for an
  off-by-default single-node plugin; if a load test shows GC pressure the swap is persistent_term→ETS (out of scope).
- **CARRY-FORWARD (blocks a future test).** When the wave-3 full-stack signed-body ConnCase is finally written it MUST
  call `Settings.reset_webhook_secret_cache/0` or set `webhook_secret_ttl_ms: 0` in setup, or a cached secret bleeds
  across cases and flips a 401/200.
- **TENANCY (matches wave-3 posture, not new).** Adopt controller + Studio arity-3 handler adopt in the DEFAULT
  workspace/project only; a non-default-tenant intake returns `not_found`. Same limit as onixedit arity-3 and wave-3 intake.
- **INHERENT to D7:** every update-path reconcile now does GET+PATCH (doubles GitHub calls on the update path; the GET
  doubles as the detachment probe, rate-safe via snooze). Drift on a QUIESCENT task's issue is only detected on that
  task's NEXT edit (level-triggered — nothing schedules a job for an untouched task; polling is out of scope).

**Next wave: Wave 5 — Projects v2 + relations** (the wish's stated w5): one-directional GraphQL auto-add + Status/
Priority/Worker/Goal custom-field writes diffed against the stored projection (D10, isolated LAST so it can't
destabilize the Issues loop); `parent_id`→native sub-issues (deferred-retry when the parent is unmirrored, cap-flatten
past 8-level/100-child); `blocks`→`<!-- barkpark:blocks -->` marker block in the body (D11). NOTE: the
`github_sync_conflicts` table now carries real data that NOTHING renders yet — Wave 6's `/admin/github` console +
`bp github status` (reading conflicts + cursor lag, `Conflicts.resolve/1` wired to a button) is the natural home and a
strong alternative if the human wants operators to SEE the quarantine before Projects v2 polish.

### Wave 2026-07-07 — Wave 4 adoption + conflict quarantine MERGED (#1236) — RECONCILED (architect pass)

Wave 4 landed on `main` as squash `09229948 feat(github): wave-4 adoption + conflict quarantine (D7) — the
intake→adopt journey closes (#1236)`. Verified against the tree: the plugin dir ships **18 modules** (waves 1-4:
adopt, auth, cli, client, conflict, conflicts, cursor, drain_worker, errors, fields, intake, link, mirror_job,
outbox, projection, settings, signature + `plugins/github.ex`). New host-side: `GithubAdoptController` on
`POST /v1/plugins/github/adopt/:id` (`:token` bucket); migration `20260707120000_create_github_sync_conflicts.exs`
LIVE. `MirrorJob.update/7` now GET+fingerprints ledger-owned fields before the PATCH → `Conflicts.record` on drift
(`out_of_band_edit`) / detach (`detached`) / dedup-refusal (`dedup_refused`); `Link.put` stamps `synced_fingerprint`
for next-pass drift detection (mirror_job.ex L254-327 confirmed). `bp github adopt` falls out of `/v1/capabilities`
via `Github.CLI.commands/0` (no Go change). The single substrate-built-twice integration risk (slice 1 vs slice 4
both shipping the migration) resolved cleanly — ONE migration on main. Waves 1+2+3+4 DONE. Wave 5 is the last MAJOR
feature wave — the "one board" payoff.

**Confirmed live seams Wave 5 builds on:** (1) `Github.Settings` already surfaces `:project_id` (`get_credentials()[:project_id]`,
optional cred) — the Projects gate; (2) `Projection` already RESERVES the `blocks` marker and hydrates `"blocker_issue_refs"`
(a caller-provided list of issue numbers) — Wave 5 wires the hydration source (projection.ex L55-59, L240-245); (3)
`Github.Fields` already carries `projects_field:` per field (`:status`/`:priority`/`:worker`/`:goal`) and `issue_attr: :sub_issue`
for `parent_id` — the Projects field map + sub-issue direction are already declared, machine-checkable; (4) `Link.put` merges
ARBITRARY github-map keys — `projects_fingerprint`/`projects_item_id`/`sub_issue_parent` stamp with NO link.ex change (same
pattern as w4's `synced_fingerprint`); (5) `Client.request/4` is REST-path shaped — GraphQL needs a sibling that POSTs to
`<base>/graphql`, reusing `Auth.token/0` + the exact error classifier; (6) `MirrorJob.converge/5` (mirror_job.ex L189-209) is
the wiring keystone — hydrate blocker refs BEFORE `Projection.task_to_issue`, run Projects/Relations AFTER create/PATCH.

### Wave 2026-07-07 — Wave 5 CUT FIRED (architect reconciliation pass)

Reconciled against `main` HEAD `09229948` (wave-4 merge). Waves 1-4 DONE + merged (#1229/#1232/#1234/#1236);
the plugin dir ships **18 modules**; no work landed OUTSIDE the loop that touches the github plugin (the
interleaved #1227/#1228/#1231/#1233/#1235 are all paper-editor, disjoint). Wave 5 files (`projects.ex`,
`relations.ex`) do NOT yet exist — this is a clean start.

**All Wave 5 seams VERIFIED LIVE (architect grep pass, so the 4 slices build without surprise):**
- `Settings` surfaces `:project_id` (settings.ex L63) — the D10 Projects gate (blank → whole path no-ops).
- `Client.get_issue/3` LIVE (client.ex L85); base resolution `@default_api_base`+`cfg_base` (L328-337) is the
  spot slice-1 `graphql/2` reuses (`<base>/graphql`); `graphql`/`add_sub_issue` are pure ADDITIONS (absent today).
- `Projection` renders the `blocks` fence from `blocker_issue_refs` (L241) via `upsert_fenced` (L173) and
  `neutralize_sentinels` scrub (L306) — slice 3 SUPPLIES the hydration + adds ONLY a `barkpark:parent` marker.
- `Fields.matrix` carries `projects_field:` (`:priority`/`:worker`/`:status`/`:goal`) + `issue_attr: :sub_issue`
  on goal (fields.ex L55-92) — the Projects field map + sub-issue direction are already machine-declared.
- `Link.put` merges arbitrary github-map keys, defaults `source: :github` (link.ex L117-140) —
  `projects_fingerprint`/`projects_item_id`/`sub_issue_parent` stamp with NO link.ex change (w4 `synced_fingerprint` twin).
- `MirrorJob`: `converge/5` L189 (hydrate BEFORE `Projection.task_to_issue` L192), `after_create` L236,
  `update/7` L254, `reconcile/3` L164, `Link.synced?` short-circuit L176 (the `relink` bypass point).

**Cut CONFIRMED unchanged: the 4 file-disjoint slices below.** Land order 1 → (2 ∥ 3) → 4. Slice 1 solely owns
`client.ex`; slice 4 solely owns `mirror_job.ex`; slices 2/3 are new files (+ slice 3 appends one marker to
`projection.ex`). Every GraphQL/REST edge Bypass-mocked or seam-injected; NEVER live, NEVER boot phx.server.
Projects is OUTBOUND → NO new inbound route → do NOT regenerate `docs/openapi.json`. No new bp verb → no Go gate.
ALL agents on Opus. The flagship gate-invariants: **unchanged task → ZERO GraphQL** (slice 2/4) and **a Projects
error NEVER fails the issue mirror** (slice 4 failure-isolation).

### Wave 2026-07-07 — Wave 5 Projects v2 + relations BUILT (4/4 green, merge-ready)

The ledger and the repo become ONE BOARD. This is the last MAJOR feature wave and it delivers the wish's stated
w5 payoff, not micro-repair: a configured Projects v2 board auto-populates as a READ-ONLY Status/Priority/Worker/
Goal dashboard nobody edits back, the issue tree mirrors the task tree (`parent_id`→native sub-issue, `blocks`→
body marker), and the whole Projects/relations layer is quarantined LAST + failure-isolated so it can NEVER
destabilize the proven Issues loop. All 4 file-disjoint slices GREEN, every perfecter SHIP IT / READY TO MERGE,
zero NOT-GREEN. Both flagship gate-invariants are built + tested: an UNCHANGED task writes ZERO GraphQL
(fingerprint diff), and a Projects/relations failure returns the issue-mirror's `:ok` unchanged (log+continue).

**Landed (on branches, pending integration):**
1. **Client GraphQL + sub-issue transport (slice 1, `client.ex`)** — two PURE additions reusing the proven
   `request`/`do_request`/classify pipeline verbatim. `graphql/3` POSTs `%{"query","variables"}` to `<base>/graphql`;
   a 200-with-`errors` surfaces as `%NetworkError{reason:{:graphql,errors}}` (NO 5th error type — D8's 4-type set
   held); clean 2xx → `{:ok, data|body}`; all transport/4xx/5xx/rate paths classify identically to REST.
   `add_sub_issue/4` POSTs `sub_issue_id` to `/repos/:repo/issues/:n/sub_issues`, a 422 left as `{:http,422}` for the
   Relations caller to map→`:ok`. 6 Bypass tests; gate 245/0.
2. **`Github.Projects` (slice 2, D10, new file)** — one-directional Projects v2 GraphQL, `project_id`-gated (blank →
   `:noop`, ZERO GraphQL, Issues loop untouched) and fingerprint-diffed (`:erlang.phash2(desired)` == stored →
   `:noop` = the flagship unchanged→zero-writes invariant). On a changed fingerprint: resolve node id via
   `get_issue`, `addProjectV2ItemById` (skipped when `projects_item_id` stored), query board fields once, write each
   non-nil field (`singleSelectOptionId` for Status/Priority/Worker matched case-insensitively, text for Goal);
   missing field / unmatched option → log+skip that ONE field. Desired values read off `Fields.matrix` exactly as
   the projection derives labels. No reverse writer exists (D5). `@canonical capability:github-projects-sync`.
3. **`Github.Relations` (slice 3, D11, new file + `projection.ex` marker)** — `hydrate_blocker_refs/3` gathers blocks
   blockers from BOTH substrate views (content.blocked_by + the authoritative `Tasks.dependencies` graph),
   draft-first-loads each, reads `content.github.issue` via `Link.get`, decorates the doc with `blocker_issue_refs`
   (the exact key projection.ex L241 renders); an unmirrored blocker is OMITTED, never fabricated — reads DB, writes
   nothing. `sync/5` mirrors `parent_id`→native sub-issue: no parent→`:noop`; parent unmirrored→`{:defer,
   :parent_unmirrored}`; depth past cap→`{:flatten, parent_id}`; else `get_issue`→child db id→`add_sub_issue`, 422
   tolerated as `:ok`. Adds a `<!-- barkpark:parent -->` fenced marker to projection.ex (caller-hydrated
   `parent_marker` key, blocks-discipline: sentinel-scrubbed, idempotent, absent→no marker). Mutates no task (D4).
   Gate 259/0, docs-anchors PASS.
4. **Wiring (slice 4, `mirror_job.ex`, failure-isolated)** — `converge` hydrates `blocker_issue_refs` (+cap-flatten
   `parent_marker`) onto the in-memory doc BEFORE `Projection.task_to_issue` (pure decoration, no new GitHub call).
   After the issue exists + its mirror converged, a new `sync_projections` step runs Projects.sync then
   Relations.sync, EACH wrapped so any `{:error,_}`/raise is logged+swallowed and the reconcile still returns the
   issue-mirror's `:ok`; only a `RateLimitError` MAY `{:snooze,s}` the whole reconcile (D9). Projects `{:ok}` stamps
   `Link.put` (`source:github`, outbox-excluded) so an unchanged task writes ZERO GraphQL next pass. Relations
   `{:defer,:parent_unmirrored}` enqueues the parent MirrorJob + a bounded relink child (60s, cap 3 → cap-flatten);
   `{:flatten,id}` stamps the marker + re-enqueues once; `relink:true` bypasses the `Link.synced?` short-circuit.
   Projects/Relations resolve through an injected seam that no-ops via `Code.ensure_loaded?` when the module isn't
   loaded — an absent projection module IS the isolation invariant. Existing non-relink behavior byte-identical.
   8 isolation/snooze/defer/flatten/hydration/zero-GraphQL/relink tests; gate github dir 248/0 + `barkpark_web/`
   2410/0, warnings-as-errors clean.

**Stalled** — nothing NOT-GREEN. Wave is code-complete on branches; standard base-drift integration discipline
applies (rebase each `-p` onto current `origin/main` before landing; land 1 → (2 ∥ 3) → 4).

**INTEGRATION CONTRACTS the integrator MUST verify end-to-end (every perfecter verified return-shapes against the
CHARTER, not sibling real code — the seam no-op is the only safety net until slices meet):**
- **GraphQL error shape is the linchpin.** Slice 2 assumes a Projects success has NO top-level `errors`; slice 1
  DOES surface a 200-with-`errors` as `{:error, %NetworkError{reason:{:graphql,_}}}` — so the contract HOLDS. But
  confirm at integration that slice 1 never returns `{:ok, %{"data"=>nil,"errors"=>…}}` on a permission/add error,
  or slice 2 mis-reads it as `:projects_item_add_failed`/empty-fields instead of bubbling.
- **GraphQL RATE_LIMITED is a 200-body error**, surfaced as `{:graphql,errors}` on `NetworkError` — it is NOT a
  `RateLimitError`, so slice-4's snooze will NOT fire on it; it is log+continued (safe) and re-attempted on the
  task's next change (no fingerprint stamped on failure). Acceptable per one-directional/level-triggered design;
  a quiescent task will not self-heal a rate-limited repaint. Slice-4 wiring MUST still classify+snooze a plain
  403/429 bubbled from the extra `get_issue`/`add_sub_issue` (REST rate-limit → `RateLimitError`).
- **Pass the link MAP, not a `%Document{}`, into `Projects.sync`/`Relations.sync`** (the `Link.get` result, plain
  map|nil) — a struct would raise on Access. In-contract callers are fine; this is a slice-4 wiring note.
- **hydrate returns a struct-tagged map** (`Map.put(%Document{}, string_key, v)`); `Projection.get/2` reads
  string-key-first so it works, but the real Projects/Relations must not strictly reshape the struct.
- **cap-flatten `parent_marker` render** now ships in slice-3's projection.ex — confirm slice 3's projection edge
  lands WITH slice 4's cap-flatten stamp (slice-4 perfecter worked in isolation and saw the w1 projection, which
  does not render it; slice 3 supplies the render — forward-compatible, verify they meet).

**Cross-wave carries / deferrals (perfecter-flagged, not defects — Wave 6 territory):**
- **`add_sub_issue` blanket-tolerates ALL 422 as `:ok`** — right for the steady-state already-linked replay, but
  silently swallows a 422 from another cause (max-sub-issues, cycle) with NO cap-flatten marker. Distinguish in a
  follow-up.
- **Child-count cap (>100 children) NOT built** — only the depth cap (default 8) ships; a parent with many shallow
  children still native-links. Builder TODO'd for wave 6.
- **Fingerprint hashes only task desired-state, not board state** — a board field/option ADDED after a task's
  fingerprint was stamped won't repaint until the task itself changes. Acceptable per one-directional design; a
  board edit is not a resync trigger.
- **Priority form divergence (by design):** Projects writes the RAW value (`"2"`); the issue LABEL uses
  `priority:p2`. Operators must name board Priority options for the raw values. Architect's settled choice.
- **Minor perf:** the immediate parent is loaded twice per relations sync (isolation-preserving). Left as-is.

**Next wave: Wave 6 — observability (the natural + strongest next cut).** The system now carries substantial hidden
sync state that NOTHING renders: `github_sync_conflicts` rows (out_of_band_edit/detached/dedup_refused, since wave
4), cursor lag / queue depth, and now projects fingerprints + relation defer chains + cap-flattens. Wave 6's
`/admin/github` `:ops` console (pulse precedent) + `bp github status` verb (reading conflicts + cursor lag, with
`Conflicts.resolve/1` wired to a button) is the last loop-buildable wave and the home for the two above deferrals
(distinguish real 422s; add the child-count cap). Then Wave 7 is the human gate (GitHub App creation, Projects v2
board + single-select fields, secret provisioning, whitelist) — blocks NO code and lights the whole epic up.

### Wave 2026-07-07 — Wave 5 Projects v2 + relations MERGED (#1237) — RECONCILED (architect pass)

Wave 5 landed on `main` as squash `1069a8b7 feat(github): wave-5 Projects v2 dashboard + relations (D10/D11) —
one board (#1237)`. Verified against the tree: the plugin dir now ships **20 modules** (waves 1-5: adopt, auth, cli,
client, conflict, conflicts, cursor, drain_worker, errors, fields, intake, link, mirror_job, outbox, projection,
**projects**, **relations**, settings, signature + `plugins/github.ex`). No github work landed OUTSIDE the loop.
The four-major-feature-wave arc (outbound → inbound → adopt/quarantine → Projects/relations) is COMPLETE and merged;
the ledger and the repo are one board. Wave 6 (observability) is the last loop-buildable wave — the human App gate
(wave 7) lights the whole epic up but blocks no code.

**Verified live seams Wave 6 builds on (architect grep pass vs HEAD `1069a8b7`):**
- `Github.Conflicts` (conflicts.ex): `list(opts)` → open rows newest-first, filters `:repo`/`:kind`, default limit 100;
  `resolve(id)` → `{:ok, %Conflict{}}` | `{:error, :not_found}`, idempotent; kinds =
  `out_of_band_edit | detached | dedup_refused`. The console + `bp github status` read `list/1`; the console 'Resolve'
  button wires `resolve/1` (already shipped — NO new mutation surface).
- `Github.Cursor.get(dataset)` → outbound high-water mark (0 when none); `Github.Outbox.fetch(dataset, after_id, limit)`
  → drainable task events (`type=="task"`, `source != "github"`, `id > after_id`) — Health computes pending backlog as
  `length(Outbox.fetch(dataset, cursor, cap))` (reuses the exact drain filter, no outbox.ex change) and head as
  `MAX(mutation_events.id)` for the dataset (raw `Repo` read on `Barkpark.Content.MutationEvent`, id is the PK).
- `Github.Settings.datasets/0` (mirror datasets, default `["production"]`), `Settings.repo/0`, `Settings.active?/0`.
- Oban queue `github_mirror` declared static in `config/config.exs:146` (concurrency 2) — depth = count `Oban.Job`
  rows `where queue == "github_mirror" and state in ~w(available scheduled executing retryable)`.
- Pulse `:ops` console precedent: `plugins/pulse.ex` `register_routes/1` returns
  `{:live, "/pulse", Barkpark.Plugins.Pulse.Web.DashboardLive, :index, auth: :ops}` → the router's
  `plugin_routes(scope: :ops)` block (router.ex L614-622, `live_session :plugin_ops`, `on_mount [{LiveAuth,:ops},…]`,
  layout `{Layouts,:studio}`) mounts it at `/admin/pulse`. `desk_items/1` → `%{type: :link, path: "/admin/pulse", …}`.
  github.ex `desk_items/1` ALREADY returns `%{type: :link, path: "/admin/github", …}` — wave 6 wires the real page.
- `Github.CLI.commands/0` returns a `[cli_command()]`; `github.ex cli_commands/0` delegates via
  `Code.ensure_loaded?` — the `bp github status` verb appends here with NO Go source change (the adopt precedent).
- `GithubAdoptController` on `POST /v1/plugins/github/adopt/:id` (`:token` bucket, plugin route) is the shape the new
  read-only `GET /v1/plugins/github/status` copies. `docs/openapi.json` DOES enumerate `/v1/plugins/github/*` +
  `adopt` (verified) → a new `:token` route MUST regenerate it.
- **Fold-in anchors:** `Relations.add_sub_issue/4` (relations.ex L222-229) blanket-tolerates ALL 422 as `:ok` (4b);
  `Relations.depth_exceeded?` TODO (relations.ex L240-242) caps on DEPTH only, no child-count (4a);
  `MirrorJob.projection_error/3` (mirror_job.ex L682-689) SWALLOWS a `%NetworkError{reason:{:graphql,errors}}` with a
  bare `Logger.warning` — a rate-limited GraphQL repaint is invisible (4c); `sync_projects`/`sync_relations`
  (L621-677) have `repo`+`num` in scope to thread into the conflict record.

### Wave 2026-07-07 — Wave 6 observability BUILT (4/4 green, merge-ready)

All four cut slices came back green; the last loop-buildable wave is done. What landed:
- **Slice 1 — `Github.Health.snapshot/1`** (new `health.ex` + test, `@canonical capability:github-sync-health`): a pure,
  network-free local-read aggregate — open conflicts bucketed by the fixed 3-kind set (+ newest-50 rows, repo-filtered
  or repo-wide when dark), per-dataset cursor/head/lag/pending over the EXACT w2 `Outbox.fetch` drain window (task-only,
  source≠github, cap 500 + `pending_capped`), and `github_mirror` Oban depth by the four live states. Every sub-read is
  defensively wrapped → total on a dark plugin or missing table (degrades to zeros, never a 500). ZERO GitHub calls.
- **Slice 2 — `/admin/github` `:ops` console** (`web/ops_live.ex` + `github.ex` `:live` route): pulse-pattern LiveView,
  5s `send_after` poll (no PubSub), the ONE control is a per-row `data-role="github-resolve"` button wired to the
  already-shipped `Conflicts.resolve/1`; renders the not-provisioned banner, per-dataset panel, queue depth, conflicts
  by kind, empty-state. HEeX auto-escaped; `:ops` gated (admin/ops on_mount, anonymous→redirect proven), never public_demo.
- **Slice 3 — `bp github status`** (`GET /v1/plugins/github/status` on `:token`): read-only `{ok, health: <snapshot>}`,
  optional blank-coerced `?dataset=`, frozen `github.status` cli_command falls out of `/v1/capabilities` with NO Go
  change, `docs/openapi.json` regenerated (clean single-op diff). Reaches Health via a `:github_status_fun` app-env seam
  (adopt's `:github_adopt_fun` precedent) so it compiles green before/with the Health slice.
- **Slice 4 — the 3 w5 deferrals folded into `relations.ex` + `mirror_job.ex`** (disjoint owner): a real sub-issues 422
  now disambiguates already-exists (idempotent `:ok`) from a legible rejection (`{:sub_issue_rejected,…}`); the flatten
  gate also fires on >100 DISTINCT children (prefix-normalized doc_id group-by, dedups the draft/published twin, LIMIT
  cap+1, fail-open); `projection_error` now RECORDS a GraphQL 200-body RATE_LIMITED (previously swallowed) AND the
  real-422 as an `out_of_band_edit` conflict (detail.source discriminator) — `RateLimitError`→`{:snooze}` byte-identical,
  failure isolation intact, `Conflicts.record` stays DB-only.

Gates green across slices (health/ops_live/github subdir + broad `barkpark_web` swath; 2712 tests 0 fail on slice 2;
Go build/vet/test + openapi zero-drift on slice 3; docs-anchors PASS). Perfecter cleared all four adversarially: pure
reads, no ledger writes, no `mutation_events`, no GitHub/Auth/Client call, no read-back of a GitHub field (D5/D7 clean),
no injection (rendered values HEeX-escaped or plain data), idempotent resolve + re-read.

**Integrator MUST action (from the perfecter notes, none block):**
1. **ONE `health.ex`.** Slices 1 and 2 each ship a `health.ex` (twin-substrate: slice 2 shipped it as a dependency to
   run in isolation). Keep ONE, confirm snapshot-SHAPE parity — OpsLive.render consumes
   `:active/:repo/:conflicts{...}/:datasets[{dataset,cursor,head,lag,pending,pending_capped}]/:queue{available,scheduled,executing,retryable,total}`;
   preserve the `@canonical capability:github-sync-health` marker's `doc:` backlink through the dedup (slug-uniqueness
   holds — only one file today).
2. **Sequence 2 then 3 on `github.ex` `register_routes/1`.** Both append; slice 3 branched off main and couldn't see
   slice 2's `:live` route → resolve by keeping BOTH `:live` and `:status`, add `:live` to the plugin_test route-list
   assertion. Slice 4 is file-disjoint (relations/mirror_job) — merge any time.
3. **Health seam once whitelisted.** Slice 3's controller resolves `Health.snapshot/1` (1-arity) dynamically — until the
   Health module lands the endpoint 500s when `github` is on; merge Health with-or-before slice 3, match arity exactly.

**Deliberate non-blocking tradeoffs (builder/perfecter-flagged, for a future slice, NOT wave-6 rework):**
- `Health.safe/2` swallows raises AND exits per the totality rule → a real DB outage reads as a "healthy zero" snapshot,
  not a 500. Intentional no-500-on-a-probe; a separate liveness signal is a future nicety.
- `lag` (max event id − cursor, ALL event types) can exceed `pending` (mirrorable task rows only) when non-task traffic
  sits between cursor and head — honest per field names; the console renders BOTH so an operator doesn't misread
  lag>0/pending=0 as a stall.
- Blank `?dataset=` = whole-fleet health for any valid operator token (Health owns dataset scoping; consistent with the
  charter's noted arity-3 dataset-only scope limit) — flag for a scoping slice if per-dataset isolation is wanted.
- SHARED-KIND DETAIL COLLAPSE (slice 4): graphql + sub_issue_rejected reuse the frozen `out_of_band_edit` kind, and
  `Conflicts.record` dedups by `{repo,issue,kind}` → a co-occurring drift + projection error on the SAME issue collapse
  to one row (later detail.source wins). Convergence + PATCH unaffected, only the visible detail; a real fix (merge-not-
  overwrite, or key on detail.source) belongs in slice-5's `conflicts.ex`, out of this slice's disjoint scope.

**PRE-EXISTING latent bug re-flagged (NOT wave-6 code):** `github.ex resolve_doc_actions/2` raises "Document does not
implement Access" on a `%Document{}` during the broad test swath (wave-4 code, rescued by the Registry so tests stay
green). File a cleanup slice.

**Gate-automation fix:** slice-3's gate named `test/barkpark/plugins/github/github_test.exs` — that path does NOT exist,
`mix test` tolerates a missing path (exit 0), so the verb-count-pin never ran under the gate. The real file is the
PARENT `test/barkpark/plugins/github_test.exs` (12/12 pass, verified explicitly). Fix the glob in any downstream loop
automation so the pin actually runs.

**Wave 6 = DONE (pending integration).** Only Wave 7 remains — the human GitHub App / Projects board / secret gate that
lights the whole epic up but blocks NO further code. The loop has mined the epic out.

### Wave 2026-07-09 — RECONCILIATION + Wave 8 CUT — the inbound journey, proven and hardened

**Reconciliation (audited vs git + the live guerrilla ledger + FRIKKern/barkpark):**
- The old carry list ("adoption action, D7 quarantine, deleted→detached") is STALE — all merged in
  wave 4 (#1236). Waves 5 (#1237) and 6 (#1238) merged; wave 7 (the human gate) is DONE and the
  bridge is LIVE on guerrilla (App `barkpark-bridge-frikkern`, active:true, cursor==head,
  0 conflicts). Live-found fixes #1243 (repo env→DB) and #1247 (title + draft/publish dedup) merged.
- **The inbound half has NEVER fired live.** FRIKKern/barkpark holds 442 issues — ALL authored by
  the bridge App, ZERO human-authored. On the ledger: 433 tasks carry an outbound `content.github`
  link (all `synced`), ZERO `gh-<num>`/`state=="intake"` tasks exist. Wave 8 = prove and harden
  that journey.
- **Ledger cleanup:** the 4 stale draft twins (`drafts.github-bridge-w3..w6` — empty-title,
  open, expired-claim siblings of DONE published waves) are DISCARDED (`bp doc discard-draft`),
  never published — publishing would have overwritten the done records with empty drafts.
- **Gate-glob note:** the wave-6 "fix the glob" item is prose-only — the bad path
  `test/barkpark/plugins/github/github_test.exs` exists ONLY in this charter's old task-spec text;
  no live automation references it. The real file is the parent `test/barkpark/plugins/github_test.exs`.
  Nothing to fix in CI; do not copy the old path into any future gate.
- **OPEN QUESTION for the human (not a slice):** the public mirror exposes the ENTIRE internal
  backlog — 420 issues minted in 2 days, full engineering bodies with file:line refs, on a public
  repo. This is the vision working as designed ("one board"), but the human should confirm
  public-roadmap intent or ask for a scoping slice (label/goal/workspace filter or body-stripping).

**Confirmed live defects driving the cut** (explorer-verified, file:line):
- `github.ex adoptable_intake?/1` (~L323-332): the middle `get_in(doc, ["content","github","state"])`
  rung RAISES on any `%Document{}` task lacking a github key — i.e. nearly every task in Studio with
  the plugin on. The Registry's PER-PLUGIN rescue masks it (only github's contribution is dropped;
  baseline actions survive) → log spam per render + a latent 500, not a broken header. onixedit's
  `hide_publish_action?/1` carries the IDENTICAL ladder (github copied its precedent) — one shared fix.
- `MirrorJob.reconcile` has NO intake guard: a pre-adoption Barkpark edit to a born-dark `gh-<num>`
  task (ordinary triage!) drains → converge → PATCHes the OUTSIDER's issue with Barkpark's projection
  (forced title, fenced body, intake labels) before any consent. No test covers a `state=="intake"`
  link. D13 closes this.
- `Intake.ingest` ignores everything but `opened`: issues.deleted/transferred leave a live-looking
  link; an outsider closing their own intake issue leaves the task needs-human forever, invisibly.
  D14 closes this, bookkeeping-only.
- Adopt callers all hardcode `[]` scope (Studio `action_handlers/0`, adopt controller L44, CLI);
  webhook ingest_opts carries only a dataset — intake lands in the default workspace. D15 closes this.
- Test debt still unpaid at HEAD: no full-stack signed-body ConnCase (controller test calls the
  action directly and its own moduledoc admits the gap); `Conflicts.refresh` OVERWRITES detail on the
  `{repo,issue,kind}` dedup key (a graphql projection error clobbers a recorded human drift);
  `Health.safe/2` renders a DB outage as healthy-zeros with no liveness bit.

**The wave = 5 slices** (S1-S4 parallel, file-disjoint; S5 is the human-driven live gate after
S1-S4 merge + auto-deploy). Tasks: `github-bridge-w8-s1..s5` under `github-bridge-epic` (reopened).
Quality bar: ZERO silent states — every inbound event acts, records, or deliberately no-ops with a
test asserting which. Doctrine unchanged and LAW: Barkpark is the single source of truth, mirror is
OUTBOUND-only, inbound is intake/bookkeeping-only, `mutation_events.source` stays EXACTLY `"github"`,
no field is ever bidirectional, claims/epochs/fencing/rail_rev never leave Barkpark, Conflicts.record
stays DB-only, plugin off by default.



### Wave 2026-07-09 — Wave 8 BUILT + REVIEWED (4/4 code slices green; live proof HALTED honestly)

S1-S4 all came back green, survived adversarial review, and PROVEN COHERENT TOGETHER: a throwaway
integration branch merged all four `-r` branches onto `origin/main` (`ba893d5e`) with zero conflicts —
combined github suite **436/0**, full `test/barkpark_web/` swath **3023/0** (router changed in s4),
`--warnings-as-errors` clean. Reviewer branches (the ones to MERGE): `loop-epic/{studio-adopt-surface-
fixed-struct-safe-c-0-r, pre-adoption-mirror-gate-mirrorjob-cance-1-r, inbound-event-breadth-deleted-
transferre-2-r, adopt-tenancy-at-the-http-cli-edge-test--3-r}`. Any merge order works (file-disjointness held).

**Landed (on `-r` branches, pending integration):**
1. **S1 Studio adopt surface** — new shared `Barkpark.Plugins.ContentProbe.content_get/2` (never raises
   on struct/atom-key/string-key doc shapes, never mints atoms); `github.ex adoptable_intake?/1` +
   `onixedit.ex hide_publish_action?/1` rewired, both raising 3-rung ladders deleted (the live
   "Document does not implement Access" defect is dead — protective tests call `resolve_doc_actions/2`
   DIRECTLY, no Registry rescue); `github.ex resolve_action_handlers/2` threads `ctx.scope` into
   `Adopt.adopt/3` per the onixedit precedent (verified against the real `dispatch_action` ctx). Gate 55/0.
   Repo-grepped the anti-pattern: the two remaining `get_in(doc, ["content"…])` sites (bulldocs.ex,
   tasks board_live.ex) pattern-match plain maps first — safe, no further cleanup owed.
2. **S2 pre-adoption mirror gate (D13)** — `intake?/1` + ONE `{:cancel, :intake}` cond branch after
   `detached?`, before relink/synced/converge; keyed on the state STRING only. Intake+edit → cancel
   under `Bypass.down` (zero HTTP); PROTECTIVE twin: adopted-no-synced_rev still converges (the
   consent-moment first push stays live — GET+PATCH fire, synced_rev+fingerprint stamped). Gate 38/0.
3. **S3 inbound event breadth (D14)** — new `Github.InboundEvents.handle/2` (bookkeeping-only sibling;
   bot-drop FIRST via now-public `Intake.bot_sender?/1`); deleted/transferred → detach+record
   (`detail.reason` discriminator), human-closed intake → detach `closed_by_author`, adopted close /
   missing task → `:ignored`; NO lifecycle write, no new conflict kind, source stays EXACTLY `"github"`
   (asserted on every mutation row). Controller routes the 3 actions with an explicit 2xx/5xx clause per
   tag + a `:github_webhook_inbound_fun` seam; `Settings.intake_workspace_id/0` (D15 env var) threads
   `:workspace_id` into ingest_opts, absent → byte-identical. Gate 54/0.
4. **S4 adopt tenancy at the edge + test-debt trio (D15)** — adopt controller passes
   `ScopeHelpers.scope_opts(conn)`; `:token` plugin bucket mounted under the `/w/:ws/p/:proj` scoped
   mirror on `[:scoped_api, :require_token]` (membership 403s before any controller); `scoped_prefix`
   on `github.adopt`+`github.status` (matches the capabilities.ex:528 literal exactly); the carried
   FULL-STACK signed-body ConnCase (raw string body through endpoint→CacheBodyReader→HMAC plug→real
   Intake; tampered → 401 + zero tasks); `Conflicts.refresh` merges detail (drift + graphql notes both
   survive one row); `Health.snapshot` gains `db_ok` (SELECT 1 under `safe/2` — tells "quiet" from
   "blind"). Elixir gate 46/0; Go build/vet/test green.

**Reviewer fixes (on the `-r` branches):** S3 +1 commit — protective controller tests proving the D15
workspace threading END-TO-END (env set → `:workspace_id` reaches BOTH handlers' opts; env absent →
NO key, the byte-identical claim now enforced; nothing had asserted it). S4 +1 commit — `mix format`
on health.ex + conflicts_test.exs (was drifted). S1/S2 needed nothing.

**Stalled — S5 live proof, HALTED for exactly the right reason.** The builder verified the precondition
(s1-s4 merged + deployed) was UNMET and refused to run: deployed main has NO intake gate in MirrorJob,
so script step 3 would have PATCHed the outsider's live public issue — the precise D13 violation s2
exists to prevent. Zero probe issues opened, zero criteria flipped, no code changed. Task left claimed
+ in_progress with the halt reason now stamped in `notes` (reviewer). This is the distrust-vacuous-green
posture working.

**Notes for the lead / next wave:**
- Merge the four `-r` branches in any order; Elixir Test gate before each merge; then close each task's
  merge-gated criterion ("PR merged to main…") and the lifecycle — builders left them honestly open.
- S4's gate string sets `CC` only for `go build`; `go vet`/`go test` need `CC=/usr/bin/clang` EXPORTED
  locally (the `cc` alias shadows clang). CI exports it globally — env quirk, not a defect.
- S1's scope-threading proof reads the closure env via `:erlang.fun_info(handler, :env)` — OTP-internal;
  fine on the pinned toolchain, revisit if an OTP bump breaks it.
- After s1-s4 merge + guerrilla auto-deploy: re-dispatch **github-bridge-w8-s5** (the one-issue human
  journey: born-dark → pre-adopt edit leaves the issue untouched → adopt → consent-moment first mirror
  → clean close, evidence stamped + wave-log entry). That is the whole remaining wave.
- Still open from the reconciliation: the human OPEN QUESTION on public-backlog exposure (420 internal
  issues on a public repo) — confirm intent or cut a scoping slice.

## Wave 8 CUT — the inbound journey, proven and hardened (2026-07-09, architect pass)

**Wish increment:** an outsider opens an issue on public FRIKKern/barkpark and every subsequent
thing they do — edit nothing, delete their issue, close it, have it transferred — leaves the ledger
coherent and VISIBLE, never overwrites their words pre-adoption, and one adopt (CLI or a Studio
button that renders without raising) flips ownership cleanly in ANY workspace. Fixture-first for all
code; the live step is one-issue-only.

### Slice 1 — Studio adopt surface: struct-safe content probe + scope-aware handler (`github-bridge-w8-s1`)
- **Surface:** new `api/lib/barkpark/plugins/content_probe.ex` + `plugins/github.ex` +
  `plugins/onixedit.ex` + tests.
- **Build:** one shared `Barkpark.Plugins.ContentProbe.content_get(doc, string_keys)` that never
  raises on any doc shape (struct → `Access.key(:content)` then string/atom probes on the inner
  plain map; plain map → `"content"`/`:content` then string/atom probes; bare-key `get_in` NEVER
  runs against a struct). Rewire `github.ex adoptable_intake?/1` and `onixedit.ex
  hide_publish_action?/1` onto it. Add `github.ex resolve_action_handlers/2` per the onixedit
  precedent (onixedit.ex ~L108-125): scope==[] → bare arity-3 `Adopt.adopt(doc_id, dataset, [])`,
  else a closure passing `ctx.scope` as the opts. Keep `action_handlers/0` as the scope-less fallback.
- **Gate:** `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/github_test.exs
  test/barkpark/plugins/onixedit_test.exs test/barkpark/plugins/content_probe_test.exs` — the
  load-bearing PROTECTIVE test: a real `%Barkpark.Content.Document{}` task struct WITHOUT a github
  key through `resolve_doc_actions/2` DIRECTLY (no Registry rescue) returns `prev` unchanged and
  does not raise; same shape for onixedit. Intake doc still gets the button; scope threads.
- **Size:** medium.

### Slice 2 — pre-adoption mirror gate: intake link → `{:cancel, :intake}` (`github-bridge-w8-s2`)
- **Surface:** `github/mirror_job.ex` + `test/.../mirror_job_test.exs` only.
- **Build:** D13. `intake?/1` helper (twin of `detached?/1` ~L560) + a `reconcile/3` cond branch
  right after the `detached?` branch, BEFORE converge: `intake?(link) -> {:cancel, :intake}`.
  Key on `state=="intake"` ONLY — never synced_rev absence.
- **Gate:** `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/github/mirror_job_test.exs`
  — intake link + Barkpark edit → `{:cancel, :intake}`, ZERO HTTP (Bypass.down); PROTECTIVE:
  `state=="adopted"`, no synced_rev → still converges (the consent-moment first push stays live).
- **Size:** small.

### Slice 3 — inbound event breadth: deleted/transferred/closed → visible detach (`github-bridge-w8-s3`)
- **Surface:** new `github/inbound_events.ex` + `github_webhook_controller.ex` + `github/intake.ex`
  (`bot_sender?/1` public) + `github/settings.ex` (optional `intake_workspace_id/0`) + tests.
- **Build:** D14 exactly (bookkeeping-only sibling handler; bot-drop first; detach via `Link.put` +
  `Conflicts.record kind:"detached"` with `detail.reason` discriminator; closed acts ONLY on
  `state=="intake"`; missing task → `:ignored`). Controller dispatches the 3 actions to
  `InboundEvents.handle/2`, everything else to `Intake.ingest/2` as today, maps EVERY new outcome
  tag to an explicit 2xx clause (a new tag with no clause = CaseClauseError = GitHub retry-storm).
  Thread `workspace_id: Settings.intake_workspace_id()` (env `BARKPARK_GITHUB_INTAKE_WORKSPACE_ID`,
  nil-absent) into ingest_opts for both handlers.
- **Gate:** `cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/github/inbound_events_test.exs
  test/barkpark/plugins/github/intake_test.exs test/barkpark_web/controllers/github_webhook_controller_test.exs`
  — every action path acts/records/no-ops with an assertion; Bot-sender closed → `:dropped`, NO
  detach (the outbound mirror closes issues as the App — its echo must not detach); adopted-task
  close → `:ignored`; `mutation_events.source == "github"` EXACTLY on every Link.put row.
- **Size:** large.

### Slice 4 — adopt tenancy at the HTTP/CLI edge + test-debt trio (`github-bridge-w8-s4`)
- **Surface:** `github_adopt_controller.ex` + `github/cli.ex` + `router.ex` (scoped `:token` mount)
  + `github/conflicts.ex` + `github/health.ex` + NEW `test/barkpark_web/controllers/github_webhook_integration_test.exs`.
- **Build:** D15 edge-threading (controller `ScopeHelpers.scope_opts(conn)`; scoped mirror of the
  `:token` plugin bucket per the `:api` precedent router.ex ~949; `scoped_prefix` on
  `github.adopt`/`github.status`); the carried full-stack signed-body ConnCase (raw JSON STRING
  body — never a map, or the CacheBodyReader tee is bypassed — + real X-Hub-Signature-256 +
  `webhook_secret_ttl_ms: 0` + `Settings.reset_webhook_secret_cache()` in setup/on_exit);
  `Conflicts.refresh` merges detail (`Map.merge(existing.detail, new)`) instead of overwriting;
  `Health.snapshot/1` gains a `db_ok` liveness bit (`safe(fn -> SELECT 1 end, false)`).
- **Gate:** `cd api && CC=/usr/bin/clang mix test test/barkpark_web/controllers/github_adopt_controller_test.exs
  test/barkpark_web/controllers/github_webhook_integration_test.exs test/barkpark/plugins/github/conflicts_test.exs
  test/barkpark/plugins/github/health_test.exs` + the Go smoke (`CC=/usr/bin/clang go build ./... &&
  go vet ./internal/cli/... && go test ./internal/cli/...` — manifest-only CLI change).
- **Size:** large.

### Slice 5 — LIVE PROOF, the wave's human gate (`github-bridge-w8-s5`)
After S1-S4 merge + auto-deploy: confirm the App's Issues webhook subscription, open EXACTLY ONE
human-authored issue on FRIKKern/barkpark, verify `gh-<num>` born-dark (labels, unclaimed,
`state=="intake"`, backlink comment), EDIT the task pre-adoption and verify the outsider's issue is
NOT patched (S2 live), `bp github adopt gh-<num>` (needs-human stripped, adopted, backlink, no
auto-claim), next edit fires the consent-moment first mirror, then close out cleanly. Every
observation recorded as task evidence + a wave-log entry. Any misbehavior → file a child task,
never hotfix live. **Size:** small.

**Integration order:** S1-S4 parallel (file-disjoint by design: S1=github.ex/onixedit.ex/probe,
S2=mirror_job, S3=webhook controller/inbound_events/intake/settings, S4=adopt controller/cli/router/
conflicts/health). S5 strictly after S1-S4 merge + deploy. Elixir Test gate before every merge;
pr-task-gate needs the task in_progress at PR-open.

## Wave 6 CUT — observability (2026-07-07, architect pass)

**Wish increment:** the epic has been accumulating hidden sync state for four waves — open `github_sync_conflicts`
(out_of_band_edit/detached/dedup_refused, since w4), the outbound cursor + its drain backlog, the `github_mirror`
Oban queue, and now Projects fingerprints + relation defer/flatten chains (w5) — and NOTHING renders any of it. Wave 6
gives operators EYES: a read-only sync-health aggregate, an `/admin/github` `:ops` console that paints it + the open
conflicts (with the already-shipped `Conflicts.resolve/1` wired to a per-row 'Resolve' button), and a `bp github
status` verb returning the same health as JSON. It also FOLDS IN the three wave-5 deferrals since this wave owns the
visibility surface: a real 422 (max-sub-issues/cycle) becomes a recorded conflict instead of a silent `:ok`, a
GraphQL RATE_LIMITED (a 200-body `{:graphql,errors}`, NOT a 403/429) becomes a recorded conflict instead of an
invisible `Logger.warning`, and the child-count cap (>100) joins the depth cap in Relations. This is the LAST
loop-buildable wave; wave 7 is the human App/board/secret gate that lights the epic up and blocks no code.

**Hard contracts every slice MUST respect (charter decisions + lead rules):**
- **READ-ONLY (D5/D7).** The observability surface NEVER edits a task or a GitHub value. The ONLY mutation it exposes
  is `Conflicts.resolve/1` (already built in w4 — a maintainer clearing an open quarantine row; it touches only the
  side table, never `Content.*`/`mutation_events`, so no loop surface). No new task-mutating or GitHub-writing path.
- **NO GitHub calls in Health.** The health aggregate is PURE local reads (Postgres: conflicts, cursor, outbox,
  mutation_events, oban_jobs). It never calls `Auth.token/0`/`Client`/GraphQL — a health read must work with the
  plugin dark and NEVER hit the network. (Bypass isn't even needed for the Health test; there are no HTTP edges.)
- **D4 cut #2 — the exact string.** The fold-in conflict records (slice 4) go through `Conflicts.record/1` — DB-only,
  it emits NO `mutation_events` row, so there is no loop surface and no `source` stamp to get wrong. Do NOT route a
  conflict record through `Content.*`/`Link.put`.
- **`:ops`/`:token` gating, NOT public_demo.** The console is `auth: :ops` (admin/ops on_mount gate, the pulse
  precedent) — NEVER `public_demo`, NEVER anonymous. `bp github status` rides the `:token` bucket (bearer-gated
  operator read, `auth_tier: "read"`) exactly like `github adopt`.
- **openapi regen (slice 3 only).** `GET /v1/plugins/github/status` is a new PUBLIC `:token` route → the slice MUST
  run `cd api && mix barkpark.openapi` and COMMIT the regenerated `docs/openapi.json` (adopt is already in it; the
  generator enumerates plugin routes even off-by-default). This is the ONLY slice that touches openapi.json.
- **bp verb → Go smoke (slice 3 only).** A new manifest verb needs NO Go source change (the `Code.ensure_loaded?`
  delegate), but prove nothing broke: `CC=/usr/bin/clang go build ./... && go vet ./internal/cli/... && go test
  ./internal/cli/...`. Do NOT hand-edit `docs/cli/fixtures/full-manifest.json` — the Go tests look up task/ticket
  nouns, so a new `github` verb breaks nothing.
- **NO boot-started DB-touching worker** (CI sandbox lesson). Wave 6 adds NO worker. A LiveView console needs a
  `ConnCase`/`Phoenix.LiveViewTest`; the Health/fold-in modules run under `Barkpark.DataCase`. Every slice runs its
  targeted github tests PLUS a broad `DataCase`/`ConnCase` swath (`mix test test/barkpark_web/` for the console) so a
  bare plugin-dir run can't hide a sandbox/endpoint regression. NEVER boot `phx.server` (codelist seed OOMs). ALL
  agents on Opus — never Fable, never Haiku.

**Integration order + disjointness:** Slice 1 (`Github.Health`, new file) is FOUNDATIONAL — slices 2 and 3 both
render it — so it lands FIRST. Slices 2 (console: new `web/ops_live.ex` + `github.ex` route) and 3 (status:
new controller + `cli.ex` + `github.ex` route + openapi) BOTH append to `github.ex` `register_routes/1` → they are
NOT file-disjoint on `github.ex`; land **2 then 3** and rebase 3 onto 2 (the same hot-file sequencing this epic runs
every wave for client.ex/mirror_job.ex). Slice 4 (fold-ins) solely owns `relations.ex` + `mirror_job.ex` — disjoint
from 1/2/3, lands any time. So: land 1 → 2 → 3 (sequential on github.ex) with 4 in parallel. Test-DB contention:
re-run a gate once before declaring failure.

### Slice 1 — `Github.Health`: pure sync-health aggregate (FOUNDATIONAL, new file)
- **Surface:** new `api/lib/barkpark/plugins/github/health.ex` + `test/barkpark/plugins/github/health_test.exs`.
- **Build:** `Health.snapshot(opts \\ []) :: map()` — a pure LOCAL-READ aggregate (NO GitHub call). Compose:
  - **Conflicts:** `Github.Conflicts.list(repo: Settings.repo(), limit: 200)` bucketed by `kind` →
    `%{out_of_band_edit: n, detached: n, dedup_refused: n, total: n, open: [<the rows as plain maps, newest-first,
    capped e.g. 50>]}`. (Settings.repo() may be nil when the plugin is dark → pass no `:repo` filter in that case.)
  - **Cursor + lag, per dataset** (`Settings.datasets/0`, default `["production"]`): for each dataset
    `cursor = Cursor.get(ds)`; `head = MAX(mutation_events.id)` for that dataset (a bounded `Repo.aggregate` /
    `Repo.one(from e in Barkpark.Content.MutationEvent, where: e.dataset == ^ds, select: max(e.id))`, nil→0);
    `pending = length(Outbox.fetch(ds, cursor, 500))` (reuses the EXACT drain filter — task, source≠github, id>cursor;
    cap 500 so the query is bounded, display "500+" when it hits the cap). Return
    `%{dataset: ds, cursor: cursor, head: head, lag: max(head - cursor, 0), pending: pending, pending_capped: pending >= 500}`.
  - **Queue depth:** count `Oban.Job` rows `where queue == "github_mirror" and state in
    ~w(available scheduled executing retryable)`, grouped by state → `%{available: n, scheduled: n, executing: n,
    retryable: n, total: n}`. Use `Repo.all(from j in Oban.Job, where: …, group_by: j.state, select: {j.state,
    count(j.id)})` folded into a map (missing states → 0).
  - **Active flag:** `active: Settings.active?()` and `repo: Settings.repo()` for the console header.
  - Wrap each sub-read defensively (a missing table / dark plugin must yield zeros, never crash) — `snapshot/0` is
    called from a LiveView mount and a controller; it must be total. Return a plain string-or-atom-keyed map that
    both the LiveView (slice 2) and the JSON controller (slice 3) render.
- **Decisions respected:** D5 (read-only, no GitHub read-back), D7 (surfaces the visible quarantine), the
  no-network/no-worker rule (pure Postgres reads).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/health_test.exs
  test/barkpark/plugins/github/` (worktree recipe: copy `_build/test` + link `deps`; `export CC=/usr/bin/clang`).
  `Barkpark.DataCase`. Assert: with the DB empty → all zeros, `active: false`, never raises; after inserting two open
  conflicts (one `out_of_band_edit`, one `detached`) via `Conflicts.record/1` → the bucket counts + `total` match and
  the `detached` shows in `open`; after `Cursor.put(ds, N)` with a higher `MAX(mutation_events.id)` → `lag` is the
  positive delta and `pending` counts only task/source≠github rows past the cursor; a `source: "github"` event past
  the cursor does NOT inflate `pending`; queue depth reflects an inserted `github_mirror` Oban job. NO Bypass needed
  (there are no HTTP edges — assert Health issues zero network calls by construction).
- **Size:** medium.

### Slice 2 — `/admin/github` `:ops` console: render health + open conflicts + Resolve button
- **Surface:** new `api/lib/barkpark/plugins/github/web/ops_live.ex` (mirror `plugins/pulse/web/dashboard_live.ex`) +
  `api/lib/barkpark/plugins/github.ex` (`register_routes/1` appends the `:live` route) +
  `test/barkpark/plugins/github/web/ops_live_test.exs`.
- **Build:**
  - `Barkpark.Plugins.Github.Web.OpsLive` — `use BarkparkWeb, :live_view`. `mount/3`: `assign(socket, :health,
    Github.Health.snapshot())`; on `connected?` schedule a slow `Process.send_after(self(), :refresh, 5_000)` periodic
    re-read (pulse precedent — NO PubSub needed; health is a poll). `handle_info(:refresh, …)` re-reads + reschedules.
  - `handle_event("resolve", %{"id" => id}, socket)` → `Github.Conflicts.resolve(String.to_integer(id))`, then
    re-read `Health.snapshot()` into assigns (the resolved row drops out of `open`), `{:noreply, …}`. Put a
    `data-role="github-resolve"` `phx-click="resolve" phx-value-id={row.id}` button on each open-conflict row. This
    is the ONLY control on the page — everything else is read-only text.
  - `render/1`: a header (repo + active flag + a warning banner when `active: false` — "plugin not provisioned"),
    a per-dataset cursor/lag/pending/queue-depth panel (tabular-nums, pulse's inline-style aesthetic), a conflicts
    section grouped by kind with the open rows (repo#issue, kind, doc_id, inserted_at, the Resolve button), and an
    empty-state (`data-role="github-health-empty"`) when there are zero conflicts. Keep it a single `~H` block, no
    external assets (CSP), theme-neutral inline styles like the pulse dashboard.
  - `github.ex` `register_routes/1`: APPEND `{:live, "/github", Barkpark.Plugins.Github.Web.OpsLive, :index,
    auth: :ops}` to the existing route list (the pulse `{:live, "/pulse", …, auth: :ops}` shape). This mounts it at
    `/admin/github` via the router's `plugin_routes(scope: :ops)` block — the `desk_items/1` link already points there.
    Do NOT touch the router (the `:plugin_ops` live_session already exists). Keep the webhook + adopt routes byte-identical.
- **Decisions respected:** D5/D7 (read-only dashboard + the one already-built `Conflicts.resolve` control), `:ops`
  gating (NOT public_demo), off-by-default (the route only resolves a live handler when `github` is whitelisted —
  the `:ops` on_mount still admin-gates it regardless).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/web/ops_live_test.exs
  test/barkpark/plugins/github/ test/barkpark_web/` — `ConnCase` + `Phoenix.LiveViewTest`. Assert: with two open
  conflicts seeded, `live/2` (or `render/1` on a directly-mounted socket) shows both kinds + the counts + the
  per-dataset cursor/lag panel; clicking the `github-resolve` button on a row calls `Conflicts.resolve` (the row is
  gone from `list/1` afterward and drops out of the re-rendered `open`); the empty-state renders when there are none.
  Mount the LiveView directly with a health-seeded DB (the `:ops` on_mount admin gate can be satisfied the way the
  existing plugin-ops LiveView tests do — grep `test/barkpark_web/` for an `:ops`/`:admin` live_view test harness and
  reuse it). Run the broad `test/barkpark_web/` swath to prove no router/endpoint regression from the new route.
- **Size:** large.

### Slice 3 — `bp github status` verb: health JSON on the `:token` bucket
- **Surface:** new `api/lib/barkpark_web/controllers/github_status_controller.ex` (mirror `github_adopt_controller.ex`) +
  `api/lib/barkpark/plugins/github/cli.ex` (APPEND a `github.status` command to `commands/0`) +
  `api/lib/barkpark/plugins/github.ex` (`register_routes/1` appends the `:token` GET route) + regenerated
  `docs/openapi.json` + tests. **Rebase onto slice 2 (both touch github.ex `register_routes/1`).**
- **Build:**
  - `GithubStatusController.status/2` — read-only: `json(conn, Github.Health.snapshot())` wrapped in a `200
    {ok: true, health: <snapshot>}` envelope (mirror the adopt controller's success shape). No params required
    (optional `?dataset=` filter is fine but not required). NEVER mutates.
  - `github.ex` `register_routes/1`: APPEND `{:get, "/github/status", BarkparkWeb.GithubStatusController, :status,
    auth: :token}` (the `:token` bucket — bearer-gated operator READ, like adopt but GET/read). Keep the console
    `:live` route (slice 2) + webhook + adopt byte-identical.
  - `Github.CLI.commands/0`: APPEND (do not replace the adopt map) `%{id: "github.status", noun: "github", verb:
    "status", summary: "Show GitHub sync health (open conflicts by kind, per-dataset cursor lag, mirror queue
    depth). Read-only.", http: %{method: "GET", path_template: "/v1/plugins/github/status"}, auth_tier: "read",
    args: [], flags: [%{name: "dataset", type: "string", summary: "Filter to one dataset.", default: nil}], writes:
    false, batch: false, paginated: false, dry_run: false, default_output: "table", scoped_prefix: nil}` — the frozen
    `cli_command()` shape (copy the adopt map's field set exactly). `github.ex cli_commands/0` already delegates via
    `Code.ensure_loaded?`, so `bp github status` falls out of `/v1/capabilities` with NO Go change.
  - Regenerate openapi: `cd api && mix barkpark.openapi` and COMMIT `docs/openapi.json` (the new `:token` route MUST
    appear; adopt already does).
- **Decisions respected:** D5 (read-only, no GitHub read-back), D6-adjacent (operator-tier `:token`, not admin),
  the openapi-regen + Go-smoke lead rules.
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark_web/controllers/github_status_controller_test.exs
  test/barkpark/plugins/github/github_test.exs test/barkpark/plugins/github/` — `ConnCase`. Assert: an authenticated
  `:token` GET returns 200 with the health envelope (seed a conflict → it appears in the body); an unauth GET is
  401/403 (bucket-gated). PLUS the Go smoke: `CC=/usr/bin/clang go build ./... && go vet ./internal/cli/... && go
  test ./internal/cli/...`. PLUS confirm `docs/openapi.json` now contains `/v1/plugins/github/status` (a `grep`
  assertion is fine). Do NOT hand-edit `docs/cli/fixtures/full-manifest.json`.
- **Size:** medium.

### Slice 4 — fold in the 3 wave-5 deferrals: real-422 + GraphQL-RATE_LIMITED visibility + child-count cap
- **Surface:** `api/lib/barkpark/plugins/github/relations.ex` (child-count cap + real-422 distinction) +
  `api/lib/barkpark/plugins/github/mirror_job.ex` (record the surfaced errors as conflicts) + extend
  `relations_test.exs` + `mirror_job_test.exs`. The ONLY slice touching either file.
- **Build:**
  - **(4b) Real 422 vs idempotent already-linked (relations.ex `add_sub_issue/4`, L222-229).** Today ALL 422 →
    `:ok`. GitHub's sub-issues API returns 422 for BOTH "already a sub-issue" (idempotent, correct `:ok`) AND a REAL
    failure (max-sub-issues, would-create-cycle). Distinguish on the 422 body when available: if the error payload's
    message/errors indicate "already"/"exists" (case-insensitive substring on the surfaced `%NetworkError{}` body) →
    `:ok` (idempotent); otherwise return a DISTINCT `{:error, {:sub_issue_rejected, parent_num, child_db_id,
    detail}}` so the wiring records it. If the body is not available to disambiguate, keep the conservative `:ok` but
    prefer surfacing when the classifier preserved a body. (Check what `Client.add_sub_issue`'s `%NetworkError{}`
    carries — `reason: {:http, 422}` plus any `:body`/`:message`; match on what's there.)
  - **(4a) Child-count cap (relations.ex `depth_exceeded?` / the cap-flatten gate, L240-246).** Extend the cap: past
    the depth cap OR when the parent already has > 100 CHILDREN → `{:flatten, parent_id}` (the existing cap-flatten
    path). Count children with a bounded query that DEDUPS the draft/published twin: both the `drafts.<id>` and
    `<id>` rows carry the same `content.parent_id`, so a naive count double-counts. Count DISTINCT published doc_ids —
    e.g. count task docs whose `content.parent_id == parent_doc_id`, normalizing `drafts.`-prefixed ids to their
    published id and `Enum.uniq`-ing (or a `SELECT count(DISTINCT …)` keyed on the published id). Cap the query
    (`limit 101`) so a giant parent doesn't scan the world — you only need "> 100?", not the exact count. Reuse the
    task substrate's existing child-query if one exists (grep `parent_id` in `tasks.ex`/content queries); otherwise a
    scoped `Repo` query on the task documents table filtered by `content.parent_id`. Keep it cheap and correct-on-dedup.
  - **(4c) GraphQL RATE_LIMITED visible (mirror_job.ex `projection_error/3`, L682-689 + the `sync_projects`/
    `sync_relations` callers, L621-677).** A GraphQL rate-limit is a 200-body `%NetworkError{reason: {:graphql,
    errors}}` (NOT a `%RateLimitError{}`), so it currently falls to the bare `Logger.warning` swallow — a quiescent
    rate-limited repaint is invisible. Thread `repo` + `num` into the error handler (both are in scope at the
    `sync_projects`/`sync_relations` call sites) and, when the swallowed reason is a `{:graphql, errors}` NetworkError
    (detect a RATE_LIMITED/rate-limit token in the errors, OR record any `{:graphql,_}` as the safe superset), record
    a conflict: `Conflicts.record(%{repo: repo, issue: num, doc_id: doc_id, dataset: dataset, kind:
    "out_of_band_edit", detail: %{source: "graphql", errors: <errors>}})` — reuse the existing `out_of_band_edit`
    kind (do NOT add a new kind; the three-value inclusion set in `Conflict.changeset` is fixed and slice 1's Health
    buckets on it) OR, if a distinct label reads better, extend the `Conflict` inclusion set to add
    `"projection_error"` and teach Health's buckets about it (charter-permitted since Health is slice 1 in the same
    wave — but the SIMPLER path is to reuse `out_of_band_edit` with a `detail.source` discriminator). Also record the
    real-422 from (4b): when `sync_relations` gets `{:error, {:sub_issue_rejected, …}}`, record a conflict the same
    way BEFORE swallowing (so the issue mirror still returns `:ok` — failure isolation preserved). Keep the
    `%RateLimitError{}` → `{:snooze}` branch byte-identical (a REST 403/429 still snoozes; a GraphQL 200-body
    rate-limit records-and-continues, since it can't snooze without re-reading — level-triggered on next edit).
  - **Failure isolation is inviolate:** every fold-in still returns the issue-mirror's `:ok` — recording a conflict
    NEVER dead-letters the issue. `Conflicts.record/1` is DB-only (no `mutation_events`, no loop surface).
- **Decisions respected:** D7 (record-then-continue, disagreement VISIBLE), D9 (REST rate-limit still snoozes;
  GraphQL 200-body rate-limit records+continues), D11 (cap-flatten extended to child-count), D4 (conflict record is
  DB-only, no `source` stamp, no loop surface), failure isolation (issue mirror `:ok` unchanged).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/relations_test.exs
  test/barkpark/plugins/github/mirror_job_test.exs test/barkpark/plugins/github/` — `DataCase` + seam/Bypass. Assert:
  (a) `add_sub_issue` 422 "already a sub-issue" → `:ok` (idempotent, no conflict); (b) a 422 max-sub-issues/cycle body
  → `{:error, {:sub_issue_rejected, …}}` and the wiring records ONE `out_of_band_edit`/`sub_issue_rejected` conflict,
  reconcile still `:ok`; (c) a parent with > 100 deduped children → `{:flatten, parent_id}` (a draft+published twin of
  the same child counts ONCE — seed both rows, assert the count is not doubled); (d) a `Projects.sync` returning a
  `%NetworkError{reason: {:graphql, [%{"type" => "RATE_LIMITED"}]}}` → a conflict recorded + reconcile returns `:ok`
  (the issue is still PATCHed + `synced_rev` stamped — failure isolation intact); (e) a plain REST `%RateLimitError{}`
  still `{:snooze, s}` (byte-identical). Run the full github dir to prove no w5 test regressed.
- **Size:** large.

**Carried to wave 7 (human gate, blocks no code):** GitHub App creation on FRIKKern/barkpark, install, generate
private key + webhook secret, create the Projects v2 board + Status/Priority/Worker/Goal single-select fields,
provision secrets into guerrilla, add `github` to the whitelist. Runbook `docs/ops/github-sync.md` (human-tier) +
`@canonical capability:github-sync-health` on `Health.snapshot/1`. After wave 6 the whole epic is code-complete and
dark — wave 7 flips one whitelist and the board lights up.

## Wave 5 CUT — Projects v2 + relations (2026-07-07, architect pass)

**Wish increment:** the ledger and the repo finally become ONE BOARD. A maintainer with a configured Projects v2 board
sees every mirrored task auto-populate as a READ-ONLY executive dashboard — Status/Priority/Worker/Goal painted via
one-directional GraphQL that NOBODY edits back — and the issue tree mirrors the task tree: `parent_id`→native GitHub
sub-issues, `blocks`→a fenced marker block in the body. An UNCHANGED task writes ZERO GraphQL (diffed against a stored
`projects_fingerprint`, same lever as w4's drift fingerprint). Projects v2 is quarantined LAST + failure-isolated: a
Projects GraphQL error or a relations hiccup must NEVER fail the Issues mirror — the issue is the source of truth, Projects
+ relations are projections that log+continue. This is the fiddliest API surface in the epic; it ships behind `project_id`
being configured (absent → the whole Projects path is a no-op, the proven Issues loop is untouched).

**Hard contracts every slice MUST respect (charter decisions):**
- **D10 — Projects v2 is strictly ONE-DIRECTIONAL GraphQL, isolated.** Auto-add + Status/Priority/Worker/Goal writes ONLY,
  DIFFED against the stored `projects_fingerprint` so an unchanged task writes ZERO GraphQL. NO code path reads a Projects
  field value back into a task (the reverse writer must not exist). Gate the ENTIRE Projects path behind
  `Settings` `project_id` being present+non-blank — absent → no-op, Issues loop unaffected.
- **D11 — relations.** `parent_id`→native sub-issues; `blocks`→`<!-- barkpark:blocks:start -->`-fenced body marker (the
  projection ALREADY renders this from a caller-hydrated `blocker_issue_refs` — Wave 5 supplies the hydration, never
  re-implements the marker). PR linkage (`Task:` trailer) is UNCHANGED — do not touch it.
- **D11-retry (this-wave refinement).** When a `parent_id`'s parent task is NOT mirrored yet (no `content.github.issue`),
  the sub-issue link DEFERS — it never errors and never fabricates. Mechanism: `Relations.sync` returns `{:defer,
  :parent_unmirrored}`; the wiring (slice 4) enqueues the PARENT's `MirrorJob` immediately (so the parent gets an issue) AND
  re-enqueues the CHILD with `schedule_in: 60` + a `relink` arg + a bounded `relink_attempt` counter (cap 3). A `relink`
  reconcile BYPASSES the `Link.synced?` short-circuit (else a synced child never re-links) but still no-ops the issue
  create/PATCH when nothing changed — Projects/Relations are the point. On cap exhaustion OR when depth > 8 levels / a parent
  has > 100 children, CAP-FLATTEN: skip the native sub-issue and record a `<!-- barkpark:parent -->` body marker naming the
  parent task id instead (projection renders it, same fence discipline as `blocks`).
- **D5 — NO bidirectional field editing.** GraphQL/REST reads (issue node_id, parent/blocker issue numbers, project field
  metadata) are used ONLY to WRITE the projection — NEVER to write a GitHub value into a task field.
- **D4 cut #2 — the exact string.** Any bookkeeping write that mutates a task (the `projects_fingerprint`/`projects_item_id`/
  sub-issue-link stamp via `Link.put`) stamps `mutation_events.source` EXACTLY `"github"` (`Link.put` already defaults
  `source: :github`) so it stays outbox-excluded — no new loop surface.
- **D9 — rate safety.** Every extra GraphQL/REST call rides the SAME low-concurrency `github_mirror` Oban queue; a 403/429
  on a Projects/relations call surfaces `retry_after` and the wiring may `{:snooze, s}` (level-triggered re-read loses no intent)
  OR, for a failure-isolated projection call, log+continue. A Projects error MUST NOT dead-letter the issue mirror.
- **NO boot-started DB-touching worker** (CI sandbox lesson). Wave 5 adds NO new worker; if tempted, gate OFF in
  `config/test.exs`. Every slice runs its targeted github tests PLUS a broad `DataCase`/`ConnCase` swath (a bare plugin-dir
  run hides sandbox/endpoint regressions). ALL GitHub HTTP (REST **and** GraphQL) is Bypass-mocked or seam-injected — NEVER
  live, NEVER boot `phx.server` (codelist seed OOMs). Projects is OUTBOUND to github.com → it adds NO inbound route, so
  `docs/openapi.json` is unchanged (do NOT regenerate). No new bp verb this wave → no Go gate.

**Integration order + disjointness:** Slice 1 (Client GraphQL + sub-issue transport) touches the HOT `client.ex` — it is the
ONLY slice that touches it, and it lands FIRST. Slices 2 (`Github.Projects`, new file) and 3 (`Github.Relations`, new file +
`projection.ex` for the parent-marker) are file-disjoint from each other and from slice 1; they call `Client` through an
INJECTED seam (`@client Application.get_env(...) || Client`, dynamic-dispatched `client_mod().graphql(...)`) so they COMPILE and
TEST without slice 1 in the tree (tests stub the client; runtime resolves to the real Client slice 1 extends). Slice 4 (wiring)
touches the HOT `mirror_job.ex` — the ONLY slice that touches it — and depends on 1+2+3 existing; it lands LAST. So: land 1 →
then 2 + 3 (parallel) → 4. Sequence anything touching `client.ex`/`mirror_job.ex` (each is one slice's sole owner). Test-DB
contention: re-run a gate once before declaring failure. ALL agents on Opus — never Fable, never Haiku.

### Slice 1 — Client transport: `graphql/2` + `add_sub_issue/4` (the GraphQL + sub-issue edge)
- **Surface:** `api/lib/barkpark/plugins/github/client.ex` (add two verbs, reuse the existing `request`/`do_request` pipeline)
  + `test/barkpark/plugins/github/client_test.exs`.
- **Build:**
  - `Client.graphql(query, variables \\ %{}, opts) :: {:ok, map} | {:error, struct}` — POST to `<base>/graphql` (NOT
    `/repos/...`; the GraphQL endpoint is the api base + `/graphql`) with JSON body `%{"query" => query, "variables" =>
    variables}`, reusing `Auth.token/0`, the base resolution, headers, timeouts and the EXACT error classifier already in
    `request/4`. Add ONE post-2xx wrinkle GraphQL needs: a GraphQL response is `200 OK` even when it carries a top-level
    `"errors"` array — so after the normal 2xx decode, if the decoded body has a non-empty `"errors"` list, return
    `{:error, %NetworkError{reason: {:graphql, errors}, endpoint: url}}` (reuse the existing `NetworkError` — do NOT add a 5th
    error type; D8's 4-type set is fixed). A clean 2xx with `"data"` → `{:ok, data_or_body}`.
  - `Client.add_sub_issue(repo, parent_number, child_issue_id, opts) :: {:ok, map} | {:error, struct}` — the native sub-issue
    REST edge `POST /repos/:repo/issues/:parent_number/sub_issues` with body `%{"sub_issue_id" => child_issue_id}` (GitHub's
    sub-issues API keys on the child's DATABASE id, not its number — the caller resolves it from `Client.get_issue`'s `"id"`).
    Thin sibling of `add_labels/3`; same auth/base/classification. Idempotent-tolerant: a 422 "already a sub-issue" is a
    permanent non-retryable outcome the caller treats as success (classify leaves it `%NetworkError{reason:{:http,422}}` —
    the Relations caller maps 422 to `:ok`).
  - Do NOT change any existing verb, the base resolver, or the retry/snooze semantics. `graphql` and `add_sub_issue` are pure
    additions.
- **Decisions respected:** D8 (fixed 4-error set — GraphQL errors ride `NetworkError`), D9 (same snooze-safe classification),
  D10 (the GraphQL transport Projects needs).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/client_test.exs test/barkpark/plugins/github/` (worktree
  recipe: copy `_build/test` + link `deps` first; `export CC=/usr/bin/clang`). Bypass-stub `POST /graphql`: assert (a) a clean
  `{"data":{...}}` → `{:ok, data}`; (b) a `200` with `{"errors":[...]}` → `{:error, %NetworkError{reason: {:graphql, _}}}`;
  (c) `add_sub_issue` POSTs the exact `sub_issue_id` body to the exact `/sub_issues` path and a 422 surfaces as
  `%NetworkError{reason:{:http,422}}`; (d) a 403 with rate headers on either verb → `%RateLimitError{}` (classifier reused).
  Run the full github dir to prove no existing client/mirror test regressed.
- **Size:** medium.

### Slice 2 — `Github.Projects` (D10): one-directional Projects v2 GraphQL, diffed
- **Surface:** new `api/lib/barkpark/plugins/github/projects.ex` + `test/barkpark/plugins/github/projects_test.exs`. Calls
  `Client` through an injected seam (default `Barkpark.Plugins.Github.Client`), so it compiles/tests without slice 1 landed.
- **Build:**
  - `Projects.sync(task_doc, repo, issue_number, link, opts) :: {:ok, %{fingerprint: term, item_id: String.t()}} | :noop |
    {:error, term}`. Contract:
    - **Gate:** if `Settings` `project_id` (`get_credentials()[:project_id]`) is blank → `:noop` immediately (zero GraphQL).
    - **Desired field values (pure):** derive the Status/Priority/Worker/Goal values from the SAME source the labels come from —
      read `Fields.matrix/0` entries whose `projects_field` is non-nil (`:status`/`:priority`/`:worker`/`:goal`) and pull the
      corresponding value off the task content (status = derived from lifecycle_status+claim exactly like the projection's
      status label; priority = `content.priority`; worker = `content.claim.worker`||`content.worker`; goal = `content.parent_id`).
      Build a `%{status: ..., priority: ..., worker: ..., goal: ...}` desired map (nils allowed — a nil field is simply not written).
    - **Diff (D10 — zero GraphQL when unchanged):** `fingerprint = :erlang.phash2(desired)`. Read the stored
      `Link.get(task_doc)["projects_fingerprint"]`. If it EQUALS `fingerprint` → `:noop` (write NOTHING). Only a changed
      fingerprint proceeds to GraphQL.
    - **GraphQL sequence (only on a changed fingerprint):** (1) resolve the issue's GraphQL node id — `Client.get_issue(repo,
      issue_number, opts)` returns `"node_id"` (REST already gives it; do NOT add a verb); (2) `addProjectV2ItemById(projectId,
      contentId: node_id)` → item id (idempotent: re-adding an existing item returns its id; a stored `projects_item_id` off the
      link lets you SKIP the add on subsequent syncs); (3) query the project's fields ONCE to map field NAME→{fieldId, and for a
      single-select, optionName→optionId}: `node(id:$projectId){... on ProjectV2 { fields(first:50){ nodes {
      ... on ProjectV2SingleSelectField { id name options { id name } } ... on ProjectV2FieldCommon { id name } } } } }`;
      (4) per non-nil desired field, `updateProjectV2ItemFieldValue(projectId, itemId, fieldId, value:{singleSelectOptionId:
      <id>})` for Status/Priority/Worker single-selects (match the desired value to an option by name; an UNMATCHED option name →
      log+skip that ONE field, never crash), and `value:{text: <goal>}` for Goal if it is a text field. Field/option NAMES are
      operator-configured on their board — match case-insensitively; a missing field name → skip that field (the board may not
      define it), never error.
    - Return `{:ok, %{fingerprint: fingerprint, item_id: item_id}}` so the wiring stamps `Link.put` with `projects_fingerprint`
      + `projects_item_id`. Any GraphQL `{:error, _}` from `Client` bubbles as `{:error, _}` — the WIRING (slice 4) is what
      swallows it (log+continue); `Projects.sync` itself must be honest about failure so tests can assert it.
  - NEVER read a Projects field value back into `task_doc` (D5) — this module only ever WRITES to GraphQL and RETURNS a
    fingerprint/item-id to stamp. No reverse path exists.
- **Decisions respected:** D10 (one-directional, diffed, `project_id`-gated, isolated), D5 (no read-back), D4 (the stamp the
  caller makes is `source:"github"`).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/projects_test.exs test/barkpark/plugins/github/` — Bypass
  the GraphQL endpoint via the injected client seam (or a real Bypass `POST /graphql`). Assert: (a) blank `project_id` → `:noop`,
  ZERO client calls; (b) a stored `projects_fingerprint` EQUAL to the current desired fingerprint → `:noop`, ZERO GraphQL
  (the flagship "unchanged → zero writes" invariant); (c) a CHANGED fingerprint → `addProjectV2ItemById` then
  `updateProjectV2ItemFieldValue` fired with the exact fieldId+optionId for a mapped single-select, and `{:ok,%{fingerprint,
  item_id}}` returned; (d) an unmatched option name → that field skipped, others still written, no crash; (e) a client
  `{:error,_}` → `{:error,_}` returned (isolation is the caller's job). Verify no reverse-write helper exists (a grep-style
  assertion or a moduledoc note is fine; the property test in `fields.ex` already guards bidirectionality at the matrix level).
- **Size:** large.

### Slice 3 — `Github.Relations` (D11): sub-issues + blocker-ref hydration + cap-flatten marker
- **Surface:** new `api/lib/barkpark/plugins/github/relations.ex` + `api/lib/barkpark/plugins/github/projection.ex` (add ONLY a
  `<!-- barkpark:parent -->` cap-flatten marker, mirroring the existing `blocks` fence discipline) + tests
  (`test/barkpark/plugins/github/relations_test.exs` + extend `projection_test.exs`). Calls `Client`/`Link` through injected
  seams so it compiles/tests without slice 1.
- **Build:**
  - `Relations.hydrate_blocker_refs(task_doc, dataset, opts) :: map` — resolve the task's `blocks`/blocker edges (read the
    task's blocker task ids the same way the task substrate exposes them — `content.blocked_by` / task edges), load each blocker
    task DRAFT-FIRST via `Content.get_document`, read its `content.github.issue` (via `Link.get`), collect the mirrored issue
    NUMBERS into a list, and return `task_doc` with `"blocker_issue_refs"` merged onto it (the exact key the projection reads at
    projection.ex L240). A blocker with no mirrored issue is simply omitted (never fabricate — projection's rule). This is the
    hydration source the w1 projection left as a caller-provided key; it does NOT write to GitHub or the DB — it only decorates
    the in-memory doc the projection body render consumes.
  - `Relations.sync(task_doc, repo, issue_number, dataset, opts) :: :ok | :noop | {:defer, :parent_unmirrored} | {:error, term}`
    — native `parent_id`→sub-issue linking:
    - No `content.parent_id` → `:noop`.
    - Resolve the parent task's mirrored issue via `Link.get(parent_task)["issue"]` (load the parent DRAFT-FIRST). Parent
      unmirrored (`nil`) → `{:defer, :parent_unmirrored}` (the wiring handles the retry per D11-retry — NEVER error, NEVER guess).
    - **Cap-flatten (D11):** if the parent chain depth > 8 OR the parent already has > 100 children (bound the walk/count with a
      cheap query; if the count is impractical, cap on depth alone and TODO the child-count) → do NOT create a native sub-issue;
      instead return `{:flatten, parent_task_id}` and let the projection's new `<!-- barkpark:parent -->` marker carry it (the
      wiring hydrates a `"parent_marker"` key onto the doc, symmetric to `blocker_issue_refs`). Keep this path simple — a body
      marker is a graceful degradation, not a second linking system.
    - Otherwise: resolve the CHILD issue's database id via `Client.get_issue(repo, issue_number, opts)["id"]`, then
      `Client.add_sub_issue(repo, parent_issue_number, child_db_id, opts)`. A 422 "already linked" → `:ok` (idempotent). Stamp
      nothing here beyond returning `:ok` — the wiring records `sub_issue_parent` in the link if it wants dedup (optional).
  - `projection.ex`: add a `<!-- barkpark:parent:start -->…<!-- barkpark:parent:end -->` fenced marker rendered from a
    caller-hydrated `"parent_marker"` key (a parent task id string), EXACTLY like the `blocks` marker — scrub the sentinel from
    human prose first (reuse the existing sentinel-scrub), idempotent upsert, absent key → no marker. This is the cap-flatten
    fallback surface; it does not change any existing `blocks`/acceptance/trailer behavior.
- **Decisions respected:** D11 (native sub-issues + `blocks` marker via the reserved hydration key + cap-flatten to a body
  marker), D11-retry (defer, never error), D5 (reads issue ids ONLY to write links, never into a task field), D4 (no task
  mutation in this module — it decorates in-memory + calls GitHub; the link stamp is the wiring's `source:"github"` write).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/relations_test.exs
  test/barkpark/plugins/github/projection_test.exs test/barkpark/plugins/github/` — `DataCase` + Bypass/seam. Assert: (a)
  `hydrate_blocker_refs` on a task with two blockers (one mirrored, one not) → `blocker_issue_refs == [mirrored_num]`, and
  `Projection.task_to_issue` on that doc renders the `blocks` marker with that number; (b) a task with a mirrored parent →
  `add_sub_issue` called with the child's db id + parent number, 422 tolerated as `:ok`; (c) an UNMIRRORED parent →
  `{:defer, :parent_unmirrored}`, no `add_sub_issue` call; (d) depth > 8 (or > 100 children) → `{:flatten, parent_id}` and the
  projection renders the `<!-- barkpark:parent -->` marker; (e) no `parent_id` → `:noop`. Re-projection is idempotent (the new
  parent marker upserts inside its own fence, human prose preserved).
- **Size:** large.

### Slice 4 — wiring: MirrorJob.converge → hydrate + Projects + Relations, failure-isolated
- **Surface:** `api/lib/barkpark/plugins/github/mirror_job.ex` (the ONLY slice touching it) + extend
  `test/barkpark/plugins/github/mirror_job_test.exs`. Depends on slices 1+2+3 existing.
- **Build:**
  - In `converge/5` (mirror_job.ex L189), BEFORE `Projection.task_to_issue`: `task_doc =
    Relations.hydrate_blocker_refs(task_doc, dataset, opts)` (+ hydrate `"parent_marker"` when a prior relations pass flattened)
    so the projected BODY carries the `blocks` (and cap-flatten parent) marker. This is a pure in-memory decoration — no new
    GitHub call on the issue-mirror path.
  - AFTER the issue exists and the issue mirror has converged (i.e. at the END of the successful `patch`/`after_create` path,
    once the issue NUMBER is known and the issue create/PATCH returned `:ok`), run a NEW private `sync_projections/…` step that,
    each independently and FAILURE-ISOLATED (wrap each in a `try`/`with` that logs and returns `:ok` on any `{:error,_}` — a
    Projects GraphQL error or a relations error MUST NOT change the reconcile's `:ok`; the issue is the source of truth):
    - `Projects.sync(task_doc, repo, num, link, opts)` → on `{:ok, %{fingerprint, item_id}}` stamp `Link.put(doc_id, dataset,
      %{projects_fingerprint: fingerprint, projects_item_id: item_id}, opts)` (source:"github", outbox-excluded); on `:noop` do
      nothing; on `{:error,_}` LOG + continue.
    - `Relations.sync(task_doc, repo, num, dataset, opts)` → `:ok`/`:noop` continue; `{:flatten, parent_id}` → re-enqueue this
      task once with a hydrated `parent_marker` (or stamp a link key the next converge reads) so the body marker lands; `{:defer,
      :parent_unmirrored}` → per D11-retry: enqueue the PARENT's MirrorJob now + re-enqueue THIS child with `schedule_in: 60`,
      `relink: true`, `relink_attempt: n+1` (cap 3, then flatten); `{:error,_}` → LOG + continue.
  - Add the `relink` reconcile branch: when the job args carry `relink: true`, reconcile BYPASSES the `Link.synced?`
    short-circuit (so a synced child still re-links) but the issue create/PATCH still no-ops when nothing changed; then runs
    `Relations.sync` (+ Projects). Bound by `relink_attempt` so it can never loop forever. Keep the existing non-`relink`
    behavior byte-identical.
  - **Snooze vs swallow:** a Projects/relations RATE-LIMIT (`%RateLimitError{}`) MAY `{:snooze, s}` the whole reconcile (D9,
    level-triggered — safe, the issue PATCH re-runs idempotently). Any OTHER Projects/relations error is SWALLOWED (log+continue,
    reconcile returns the issue-mirror's `:ok`). NEVER dead-letter the issue mirror on a projection failure.
- **Decisions respected:** D10 (Projects wired AFTER the issue exists, `project_id`-gated inside `Projects.sync`, failure-isolated),
  D11 + D11-retry (relations wired after the issue exists; defer/flatten handled here), D9 (snooze only on rate-limit; swallow
  otherwise), D4 (every `Link.put` stamp is `source:"github"`), D2 (reconcile still reads CURRENT state — the hydration + syncs
  read the live task/link).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/mirror_job_test.exs test/barkpark/plugins/github/` — Bypass
  the REST issue edge + the GraphQL edge (or inject Projects/Relations seams). Assert: (a) a normal mirror still creates/PATCHes
  the issue AND stamps `synced_rev` even when `project_id` is blank (Projects `:noop`, issue loop 100% unaffected — the isolation
  invariant); (b) a Projects GraphQL `{:error,_}` (Bypass 500 on `/graphql`) → reconcile STILL returns `:ok` and the issue is
  still PATCHed + `synced_rev` stamped (failure isolation — the flagship safety property); (c) a task with a mirrored parent →
  `add_sub_issue` fired after the issue exists; (d) an unmirrored parent → parent MirrorJob enqueued + a `relink` child job
  enqueued (seam-count the enqueues), reconcile returns `:ok`; (e) `blocker_issue_refs` hydrated → the PATCH body carries the
  `blocks` marker; (f) an UNCHANGED task on a second reconcile writes ZERO GraphQL (Projects fingerprint `:noop`). Run the full
  github dir + a broad `mix test test/barkpark_web/` swath once to prove no endpoint/sandbox regression.
- **Size:** large.

**Carried to wave 6+ (not this wave):** the `/admin/github` sync-health console reading `github_sync_conflicts` + cursor lag +
Projects/relations sync state (`bp github status`, `Conflicts.resolve/1` wired to a button) — wave 6 observability, now with
Projects + relations state to render; and the wave-7 human App + Projects-board provisioning gate (create the board + the
Status/Priority/Worker/Goal single-select fields, provision `project_id` into guerrilla). `@canonical
capability:github-projects-sync` on `Projects.sync/5` and `capability:github-relations` on `Relations.sync/5`; the wave-7
runbook backlinks both.

## Wave 4 CUT — adoption + conflict quarantine (2026-07-07, architect pass)

**Wish increment:** the intake→adopt journey CLOSES. An operator takes a born-dark `gh-<num>` intake task and, with one
`bp github adopt <task>` (or a Studio button), flips ownership INTO Barkpark — `needs-human` stripped, `github.state`
`intake→adopted`, a "Tracked as gh-<num> on the board" backlink posted. No outsider is ever met with SILENCE (a
dedup-refused issue now gets a maintainer comment + a findable dead-letter row). Out-of-band GitHub drift is RECORDED
before the ledger overwrites it (ledger-wins-but-VISIBLE), and a deleted/transferred issue detaches with a surfaced
record and is NEVER recreated. The live webhook endpoint stops amplifying audit rows on every probe.

**Hard contracts every slice MUST respect (charter decisions):**
- **D5 — NO bidirectional field editing.** Adoption reads the issue only at intake BIRTH (already done in wave 3); it
  NEVER re-reads GitHub field values into the task. Slice 4 may GET the issue to compute a drift *fingerprint* for a
  quarantine RECORD (observability), but MUST NOT write any GitHub field value into a task field.
- **D4 cut #2 — the exact string.** Any inbound/bookkeeping write that mutates a task stamps `mutation_events.source`
  EXACTLY `"github"` (`to_string(:github)`), never `"github:inbound"` — else it slips the outbox exclusion → mirror loop.
- **D4 cut #1 — bot drop.** Slice 4's inbound-drift handler MUST drop `sender.type == "Bot"` events BEFORE recording:
  our OWN MirrorJob PATCH makes GitHub fire `issues.edited`/`closed` with a `[bot]` sender; recording those as
  "conflicts" would false-positive on every mirror write. Drop them exactly like `Intake` does.
- **D6 — adoption is EXPLICIT, never auto-claim.** Adopt flips ownership + clears the `needs-human` gate ONLY. It NEVER
  sets a claim/worker/epoch (those NEVER leave Barkpark). A human/agent claims the adopted task through the normal
  `bp task` path afterward.
- **D7 — ledger wins, but VISIBLE.** Record drift BEFORE converging; detached issues surface + never recreate.
- **CI LESSON (memory + wave log).** A boot-started DB-touching worker breaks the FULL ExUnit sandbox. No slice here
  adds a boot-started worker; if one is tempted (it should not be), gate it OFF in `config/test.exs`. Every slice runs
  its targeted github tests PLUS a broad `DataCase`/`ConnCase` swath locally before green (a bare plugin-dir run hides
  sandbox + endpoint regressions). GitHub HTTP is Bypass-stubbed or seam-injected — NEVER live, NEVER boot phx.server.

**Integration order + disjointness:** Slice 1 (quarantine substrate) is FOUNDATIONAL — slices 3 and 4 consume its
`Github.Conflicts` recorder, so it lands FIRST. Slices 2 (adopt, touches `github.ex`) and 5 (memoize, touches
`settings.ex` + plug) are file-disjoint from everything and build in parallel with slice 1. Slice 3 touches `intake.ex`,
slice 4 touches `mirror_job.ex` + `client.ex` — disjoint from each other and from 2/5. So: land 1 → then 3 + 4 (parallel)
→ 2 + 5 any time. Sequence anything touching `github.ex`/`intake.ex`/`mirror_job.ex` (each is one slice's sole owner).
Test-DB contention: re-run a gate once before declaring failure. ALL agents on Opus.

### Slice 1 — quarantine substrate: `github_sync_conflicts` table + `Github.Conflicts` recorder
- **Surface:** new migration `priv/repo/migrations/<ts>_create_github_sync_conflicts.exs` · new
  `api/lib/barkpark/plugins/github/conflict.ex` (Ecto schema) · new `api/lib/barkpark/plugins/github/conflicts.ex`
  (recorder) · test.
- **Build:**
  - Migration (mirror the `pulse_events` precedent `priv/repo/migrations/20260705280000_create_pulse_events_and_counters.exs`
    — a plugin owning its own non-document table is established): `create table(:github_sync_conflicts)` with
    `repo :text null:false`, `issue :bigint null:false` (nullable-not — but a dedup-refused intake HAS an issue number,
    so always set it), `doc_id :text` (nullable — a dedup-refused intake has no task yet), `dataset :text null:false`,
    `kind :text null:false` (`"out_of_band_edit" | "detached" | "dedup_refused"`), `detail :map null:false default: %{}`
    (the drift payload / dedup verdict), `resolved_at :utc_datetime_usec` (nullable — quarantine is "open" until cleared),
    `timestamps(type: :utc_datetime_usec)`. Index `[:repo, :issue]` and a partial-ish index `[:kind, :resolved_at]`.
  - `Github.Conflict` schema: plain Ecto schema over the table, `changeset/2` casting the fields, `kind` validated to
    the three-value inclusion set.
  - `Github.Conflicts` recorder: `record(attrs) :: {:ok, %Conflict{}} | {:error, cs}` — inserts a row via
    `Barkpark.Repo`. DEDUP an already-open conflict: if an unresolved row for the same `{repo, issue, kind}` exists,
    UPDATE its `detail`/`updated_at` instead of piling duplicates (a human editing an issue five times is ONE open
    conflict). `list(opts \\ [])` → open conflicts (optionally filtered by repo/kind) newest-first, for the wave-6
    console + tests. `resolve(id)` sets `resolved_at` (used later; ship it now so the console has it).
  - This module is DB-only, NEVER touches `Content.*` or `mutation_events` (a conflict record is out-of-band bookkeeping,
    NOT a task mutation — so it can never re-trigger sync). No loop surface.
- **Decisions respected:** D7 (the visible quarantine substrate), D3-adjacent (side table is fine HERE — it is NOT task
  content and never mutates the tasks schema).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/conflicts_test.exs` (worktree recipe: copy
  `_build/test` + link `deps` first) — `Barkpark.DataCase`. Assert: record inserts a row; a second record for the same
  `{repo,issue,kind}` UPDATES (still ONE open row); `list/1` returns open rows newest-first and filters by kind; `resolve/1`
  sets `resolved_at` and drops the row from `list`. Run the migration in the test DB (DataCase runs against the migrated
  schema — ensure `mix ecto.migrate` is reflected in the copied `_build`; if the copied build predates the migration, run
  `CC=/usr/bin/clang mix ecto.migrate` in the worktree once).
- **Size:** medium.

### Slice 2 — adopt action: `bp github adopt <task>` + Studio doc_action
- **Surface:** new `api/lib/barkpark/plugins/github/adopt.ex` · new `api/lib/barkpark/plugins/github/cli.ex` · new
  `api/lib/barkpark_web/controllers/github_adopt_controller.ex` · `plugins/github.ex` (`register_routes/1` adds the adopt
  route; add `cli_commands/0`; add `resolve_doc_actions/2` + `action_handlers/0`) · tests.
- **Build:**
  - `Github.Adopt.adopt(doc_id, dataset, opts) :: {:ok, %Document{}} | {:error, term}` — load the task DRAFT-FIRST
    (mirror `Intake.fetch_existing`/`MirrorJob.load_task`). Gate: only a task whose `content.github.state == "intake"`
    is adoptable; anything else → `{:error, :not_intake}` (idempotent-safe: a second adopt of an already-`adopted` task
    → `{:error, :not_intake}` or `{:ok, doc}` no-op — pick `{:ok, doc}` so the CLI/UI is idempotent, document the choice).
    On adopt: (1) strip `"needs-human"` from `content.labels` (keep `src:github`); (2) set `content.github.state` =
    `"adopted"`; (3) persist via `Content.upsert_document(..., source: :github)` (D4 cut #2 — the stamp is EXACTLY
    `"github"`; reuse the `Link.put` draft-twin-collapse pattern OR call `Link.put` for the github sub-map + a separate
    label write — simplest: build the merged content and upsert once, then collapse the draft twin like `Link.put` does
    if the task was published). NEVER touch claim/worker/epoch (D6). (4) Post the backlink via an injectable
    `:comment_fun` seam (default `&Client.create_comment/4`), best-effort (logged-and-swallowed), body
    `"Tracked as gh-<num> on the Barkpark board."` `@canonical capability:github-adopt aka:adopt,claim-issue,flip-ownership`
    on `adopt/3`.
  - `Github.CLI.commands/0` → the `cli_command()` map (frozen shape — copy `Barkpark.Plugins.Tickets.CLI.commands/0`):
    `%{id: "github.adopt", noun: "github", verb: "adopt", summary: "Adopt a src:github intake task into Barkpark
    (strip needs-human, flip ownership, post a backlink). Never auto-claims.", http: %{method: "POST", path_template:
    "/v1/plugins/github/adopt/:id"}, auth_tier: "read", args: [%{name: "id", required: true, type: "string", summary:
    "Task id (gh-<num>)."}], flags: [%{name: "dataset", type: "string", summary: "Dataset.", default: "production"}],
    writes: true, batch: false, paginated: false, dry_run: false, default_output: "minimal", scoped_prefix: nil}`.
    `github.ex` `cli_commands/0` delegates via `Code.ensure_loaded?(Github.CLI)` (the tickets merge-safe pattern) so the
    manifest picks it up dynamically — NO Go code needed, `bp github adopt` falls out of `/v1/capabilities`.
  - `GithubAdoptController.adopt/2`: read `:id` + `dataset` param → `Adopt.adopt/3` → 200 `{ok: true, task: id, state:
    "adopted"}` or 4xx `{error:{code,message}}` (`:not_intake` → 409/422, `:not_found` → 404). `register_routes/1`
    appends `{:post, "/github/adopt/:id", BarkparkWeb.GithubAdoptController, :adopt, auth: :token}` (the `:token` bucket —
    bearer-gated operator action under `/v1/plugins/github/adopt/:id`; NOT `:admin`, so `bp` with an operator token runs it).
  - Studio doc_action (secondary surface): `github.ex` `resolve_doc_actions(prev, ctx)` — when `ctx.doc_type == "task"`
    and the doc's `content.github.state == "intake"`, APPEND `%{"name" => "github_adopt", "label" => "Adopt from GitHub",
    "kind" => "modal", "icon" => "github"}` (read the intake state off `ctx.doc` string- AND atom-key safe, the onixedit
    `hide_publish_action?` precedent). `action_handlers/0` → `%{"github_adopt" => fn doc_id, dataset, _mode ->
    Adopt.adopt(doc_id, dataset, []) end}` (the `action_handler` type — `(doc_id, dataset, mode) -> {:ok,_}|{:error,_}`).
    If the doc_action wiring proves costly, the CLI verb ALONE satisfies the wish — ship the CLI verb first, the button second.
- **Decisions respected:** D6 (explicit, never auto-claim), D4 cut #2 (`source: "github"` stamp), D5 (does not read GitHub
  fields back — it only WRITES ledger-owned bookkeeping + a comment).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/adopt_test.exs
  test/barkpark_web/controllers/github_adopt_controller_test.exs test/barkpark/plugins/github_test.exs` — `DataCase`/`ConnCase`.
  Assert: an `intake` task → `needs-human` stripped, `github.state == "adopted"`, `src:github` KEPT, claim/worker UNSET, the
  `comment_fun` seam called once with a `gh-<num>` body; a non-intake task → `{:error, :not_intake}` (or idempotent no-op) and
  NO comment; the birth `mutation_events` row for the adopt write has `source == "github"` EXACTLY; `resolve_doc_actions/2`
  appends the adopt action ONLY for an intake task and NOT for a plain task. PLUS the Go smoke (a bp verb was added —
  manifest-driven, no Go source change, but prove nothing broke): `CC=/usr/bin/clang go build ./... && go vet ./internal/cli/...
  && go test ./internal/cli/...`. Do NOT regenerate `docs/cli/fixtures/full-manifest.json` — the Go tests look up their own
  nouns (task/ticket), so a new `github` command breaks nothing.
- **Size:** large.

### Slice 3 — dedup-refusal surfacing: no outsider gets silence
- **Surface:** `api/lib/barkpark/plugins/github/intake.ex` (the `{:error, {:duplicate_task, _}}` branch) + test.
  Consumes `Github.Conflicts` (slice 1).
- **Build:** In `Intake.birth/2`, the `Content.create_document` call returns `{:error, {:duplicate_task, verdict}}` when
  `Tasks.Dedup.check_new_task` judges the outsider issue a look-alike (confirmed: `Content.Writer` bubbles it verbatim).
  Today that drops to `{:error, reason}` — SILENT, and because nothing persists, every re-delivery re-refuses forever and no
  future `adopt` can find the issue. Fix that ONE branch:
  - Post a maintainer-visible comment via the SAME injectable `:comment_fun` seam (best-effort, logged-and-swallowed), body:
    `"This issue looks related to existing tracked work; a maintainer will review it."` (distinct from the birth backlink).
  - Record a dead-letter row: `Conflicts.record(%{repo: <repo>, issue: number, doc_id: nil, dataset: dataset, kind:
    "dedup_refused", detail: <the duplicate_task verdict map>})` so the refusal is FINDABLE (wave-6 console + a maintainer can
    manually reconcile). The dedup of slice 1's recorder means a re-delivery updates the same open row, never piles duplicates.
  - Return a DISTINCT outcome `{:refused, doc_id}` (extend the `result` type + moduledoc). The wave-3 controller maps a
    non-`{:error,_}` result to 2xx — make sure `{:refused, _}` lands as 2xx (accepted, NOT a 5xx retry-storm), so GitHub
    never re-delivers and the maintainer comment posts exactly ONCE. If the controller currently only 2xx's `{:ok,_}`/`:ignored`/
    `:dropped`, add `{:refused,_}` to its 2xx set (a one-line companion edit in `github_webhook_controller.ex` — note it as a
    same-slice touch; it is NOT owned by another wave-4 slice).
  - Preserve fail-open: a genuine NON-dedup create error still returns `{:error, reason}` → controller 5xx (retryable), because
    that IS a transient failure worth retrying. Only `{:duplicate_task, _}` becomes `{:refused, _}`.
- **Decisions respected:** D6 (Dedup seam unchanged — we surface its verdict, never bypass it), D4 cut #2 (no NEW task mutation;
  the Conflicts row is not a task write), D7 spirit (the refusal is now VISIBLE).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/intake_test.exs` — `DataCase`. Assert: a dedup-refused
  first delivery (inject a `Tasks.Dedup` that returns `{:error,{:duplicate_task,_}}`, or craft attrs that trip the real judge
  seam the intake test already stubs) → ZERO tasks born, the `comment_fun` seam called ONCE with the maintainer body, a
  `github_sync_conflicts` row with `kind == "dedup_refused"` and the verdict in `detail`, and the outcome is `{:refused, _}`;
  a re-delivery → still ONE open conflict row, comment posted AT MOST once more (dedup by open row); a genuine `:ok` birth is
  unaffected (existing tests stay green).
- **Size:** medium.

### Slice 4 — conflict quarantine: record out-of-band drift before converging + detached visibility
- **Surface:** `api/lib/barkpark/plugins/github/mirror_job.ex` + `api/lib/barkpark/plugins/github/client.ex` (add
  `get_issue/3`) + tests. Consumes `Github.Conflicts` (slice 1).
- **Build:** The wave-2 MirrorJob does a BLIND idempotent PATCH; if a human hand-edited/closed the issue out-of-band the ledger
  silently overwrites it with no trace (D7 violated). Make the UPDATE path RECORD drift before it converges — ledger still wins:
  - Add `Client.get_issue(repo, number, opts) :: {:ok, map} | {:error, struct}` (`GET /repos/:repo/issues/:n`) — a thin sibling
    of `update_issue`, same auth/error classification.
  - In `MirrorJob.update/7`, BEFORE the PATCH: `Client.get_issue`. On `{:ok, issue}` compute a `current_fp` fingerprint over
    ONLY the ledger-owned fields the projection controls (`title`, `body`, `labels`-sorted, `state`) — e.g. a `:erlang.phash2`
    of that tuple. Read the stored `synced_fingerprint` off `Link.get(task_doc)["synced_fingerprint"]`. If a stored fp exists
    AND `current_fp != stored` → the issue drifted out-of-band since our last write → `Conflicts.record(%{repo, issue: number,
    doc_id, dataset, kind: "out_of_band_edit", detail: %{"github_fields" => <the drifted issue title/state/labels>, "observed_fp"
    => current_fp}})`. This GET reads GitHub values ONLY to fingerprint for the quarantine RECORD — it NEVER writes a GitHub value
    into a task field (D5 intact). THEN do the existing PATCH (ledger wins), THEN stamp `Link.put` with BOTH `synced_rev: rev`
    AND `synced_fingerprint: fingerprint(desired)` (Link.put already merges arbitrary github-map keys — no link.ex change).
    A `get_issue` `NotFound`/`410` → route to the detached branch below (the issue vanished between drain and reconcile).
  - Detached visibility (build the record AROUND the existing stamp): in `classify(%NotFound{}, :update, …)` — the branch that
    already stamps `state: "detached"` and returns `{:cancel, :detached}` — FIRST `Conflicts.record(%{repo, issue, doc_id,
    dataset, kind: "detached", detail: %{"reason" => "issue deleted or transferred; not recreated"}})`, THEN stamp + cancel.
    Do NOT recreate (unchanged — D7 carve-out). The repo/issue for the record come from the link (`issue_number(link)` + `repo()`).
  - Keep the extra GET cheap + rate-safe: it rides the same debounced, low-concurrency `github_mirror` queue (D9); a 403/429 on
    the GET snoozes exactly like the PATCH (reuse `classify`). Absent a stored `synced_fingerprint` (first-ever mirror, or a task
    mirrored before this slice) → record NOTHING on that first pass (nothing to compare against), just PATCH + stamp the fp so
    the NEXT reconcile can detect drift. This makes the feature roll forward without a backfill.
- **Decisions respected:** D7 (record-then-converge; detached surfaced + never recreated), D5 (GET fingerprints for a record,
  never writes GitHub values into task fields), D9 (extra GET on the same snooze-safe queue), D4 (the `Link.put` fp stamp is
  `source: "github"`, outbox-excluded — no new loop surface).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/mirror_job_test.exs
  test/barkpark/plugins/github/client_test.exs` — Bypass-stub GitHub (the existing mirror_job/client Bypass pattern). Assert:
  (a) a task with a stored `synced_fingerprint`, whose Bypass `get_issue` returns a DIFFERENT title/state → a
  `github_sync_conflicts` row `kind: "out_of_band_edit"` is written BEFORE the PATCH, the PATCH still fires (ledger wins), and
  the new fp is stamped; (b) an issue whose `get_issue` fp MATCHES the stored fp → NO conflict row, PATCH proceeds only if the
  ledger changed; (c) a `get_issue`/`update_issue` 404 → a `kind: "detached"` row is written, `state: "detached"` stamped,
  `{:cancel, :detached}` returned, and NO recreate; (d) first-ever mirror (no stored fp) → no conflict row, fp stamped for next
  time. Verify the extra GET does not break the existing snooze/dead-letter classification tests.
- **Size:** large.

### Slice 5 — webhook secret memoize: kill the pre-verify audit amplification
- **Surface:** `api/lib/barkpark/plugins/github/settings.ex` (add a memoized secret reader) +
  `api/lib/barkpark_web/plugs/github_webhook_signature.ex` (read the memoized value) + test.
- **Build:** The live `POST /v1/plugins/github/webhook` signature plug calls `Settings.get_credentials()` per request (after the
  cheap raw_body + header checks, before HMAC verify) — and `get_credentials/0` reads the DB fallback row, which logs a `"read"`
  audit row + telemetry EVERY call. So any unauthenticated POST carrying an `x-hub-signature-256` header forces a DB write before
  the signature is even checked — a mild flood primitive on a probed public endpoint.
  - Add `Settings.webhook_secret_cached/0 :: String.t() | nil` — resolves ONLY the webhook_secret and memoizes it with a short
    monotonic TTL. Back it with `:persistent_term` keyed `{Barkpark.Plugins.Github.Settings, :webhook_secret_cache}` storing
    `{value, deadline_native}`; on a cache hit within TTL return the value with ZERO DB touch; on miss/expiry resolve via
    `get_credentials()[:webhook_secret]`, store `{value, now + ttl}`, return it. TTL from app-env
    `config :barkpark, Barkpark.Plugins.Github, webhook_secret_ttl_ms: <n>` default `5_000` (rotation staleness bounded to ~5s —
    a secret rotation takes effect within one TTL window; document this tradeoff in the fn doc). persistent_term writes are rare
    (≤ once per TTL) so the global-GC cost is negligible.
  - The `GithubWebhookSignature` plug reads `Settings.webhook_secret_cached()` instead of `Settings.get_credentials()[:webhook_secret]`.
    Behavior UNCHANGED: nil/blank secret → still fail-closed 401 halt (a dark plugin never verifies). Only the read cadence changes.
  - Determinism for tests: expose a private-but-test-reachable reset (or read TTL from app-env so a test sets
    `webhook_secret_ttl_ms: 0` to force re-resolve, and clears the persistent_term in setup). Inject the underlying resolver via a
    seam (default `&get_credentials/0`) so the test can count DB reads.
- **Decisions respected:** the wave-3 fail-closed signature contract (unchanged semantics), D8 (creds resolution stays the single
  env→DB source — this only caches ONE field).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark_web/plugs/github_webhook_signature_test.exs
  test/barkpark/plugins/github/settings_test.exs` — `ConnCase`/`DataCase`. Assert: N plug invocations within the TTL resolve the
  secret with the underlying resolver called AT MOST once (seam counter); a valid signed body still passes, a tampered body still
  401-halts, a blank/absent secret still 401-halts (fail-closed unchanged); past the TTL the resolver is re-called (rotation
  eventually visible). Reset the persistent_term in `setup` so tests do not leak cache across each other.
- **Size:** small.

**Carried to wave 5+ (not this wave):** Projects v2 GraphQL dashboard (D10), `parent_id`→sub-issues + `blocks`→marker block (D11),
the `/admin/github` sync-health console reading `github_sync_conflicts` + cursor lag (wave 6), `Conflicts.resolve/1` surfaced as an
operator verb/button (shipped in slice 1, wired to UI in wave 6), and the wave-7 human App-provisioning gate.

---

## Wave 3 CUT — inbound intake (2026-07-07, architect pass)

**Wish increment:** an outsider who cannot see guerrilla opens an issue on public FRIKKern/barkpark →
within ~a minute a task `gh-<num>` lands (labeled `src:github`+`needs-human`), born DARK through the
existing `Tasks.Dedup` find-or-create seam, plus a "tracked internally" backlink comment on the issue.
No auto-claim (adoption is wave 4). Loop stays broken by construction.

**Hard contracts every slice must respect:** D3 (deterministic `gh-<num>` doc_id is the idempotency
anchor), D4 cut #1 (drop `[bot]`-sender webhooks BEFORE any mutation), D4 cut #2 (`mutation_events.source`
stamped EXACTLY `"github"` = `to_string(:github)` — NEVER `"github:inbound"`), D6 (reuse the Dedup seam
via the normal Content create path, deterministic `gh-<num>`, NEVER a bespoke create; intake NEVER
auto-claims a worker slot — adoption is an explicit wave-4 action). Signature is verified over the RAW
request body with the wave-1 `Github.Signature` verifier (constant-time, fail-closed). Intake is
`issues.opened` ONLY (not edited/closed/labeled/reopened).

### Slice 1 — request plumbing: raw-body cache + signature plug + webhook bucket
- **Surface:** `BarkparkWeb.Plugs.CacheBodyReader` (new) · `BarkparkWeb.Plugs.GithubWebhookSignature`
  (new) · `endpoint.ex` (body_reader wiring) · `router.ex` (new `:github_webhook` pipeline + bucket).
- **Build:**
  - `CacheBodyReader.read_body/2` wraps `Plug.Conn.read_body/2` and, ONLY when
    `conn.request_path == "/v1/plugins/github/webhook"` (the plugin's webhook path — never global),
    appends the read chunk to `conn.assigns[:raw_body]` (accumulate across chunks). Every other path
    reads through untouched (no assign, zero cost). This is the standard Phoenix cache-body-reader
    idiom scoped by path so the 100 MB JSON parser doesn't buffer every request.
  - Wire it into `endpoint.ex` `parse_body/2`: add `body_reader: {BarkparkWeb.Plugs.CacheBodyReader,
    :read_body, []}` to the existing `Plug.Parsers.init(...)` opts (line ~108). Do NOT change parsers,
    length, or the rescue branches.
  - `GithubWebhookSignature` plug: reads `conn.assigns[:raw_body]` (the exact bytes GitHub signed),
    the `x-hub-signature-256` request header, and the secret from
    `Barkpark.Plugins.Github.Settings.get_credentials()[:webhook_secret]`; calls
    `Github.Signature.verify(raw_body, header, secret)`. On `:ok` pass through; on ANYTHING else
    (bad/missing signature, missing raw_body, blank secret, plugin not active) respond `401` with the
    canonical `{error:{code:"unauthorized",message:...}}` JSON envelope and `halt`. FAIL CLOSED — never
    accept when it cannot verify.
  - `router.ex`: add a `pipeline :github_webhook` = `plug :accepts, ["json"]` +
    `plug BarkparkWeb.Plugs.GithubWebhookSignature`, and a scope block
    `scope "/v1/plugins", BarkparkWeb do pipe_through :github_webhook; plugin_routes(scope:
    :github_webhook) end` (mirror the `:public_api`/`:ingest` dormant-bucket blocks — dormant until
    slice 3's `register_routes` contributes the route). Body is already parsed at the endpoint, so this
    pipeline only asserts content type + verifies the signature; signature is the ONLY auth (no token,
    no CORS — this is a server-to-server GitHub callback, not a browser origin).
- **Decisions respected:** D4 cut #1-prep (raw-body + signature edge), signature-over-RAW-body,
  fail-closed.
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark_web/plugs/github_webhook_signature_test.exs
  test/barkpark_web/plugs/cache_body_reader_test.exs` — ConnCase; craft a conn with `assigns.raw_body`
  set + a real `Signature.sign/2` header + a stubbed webhook secret (set `config :barkpark,
  :github, webhook_secret: ...` or the env key `Settings.get_credentials` reads, in test setup) →
  assert pass; tamper the body → 401 halt; missing raw_body → 401. For the reader, assert a github-path
  conn accumulates `assigns.raw_body` and a non-github path does not.
- **Size:** medium.

### Slice 2 — intake service: born-dark task through the Dedup seam
- **Surface:** `Barkpark.Plugins.Github.Intake` (new: `github/intake.ex`) + test.
- **Build:** `ingest/2` (or `handle_delivery/2`) takes the decoded webhook `payload` (a map) + `opts`.
  - **Event filter:** act ONLY on `payload["action"] == "opened"` with an `"issue"` present. Any other
    action (edited/closed/labeled/reopened/…) → `:ignored`. (`X-GitHub-Event: issues` is asserted by the
    controller; Intake defends on `action` too.)
  - **Bot drop (D4 cut #1):** if `payload["sender"]["type"] == "Bot"` (the App's own writes always carry
    a `[bot]` sender of type `"Bot"`), return `:dropped` BEFORE any Content write. This is the structural
    loop cut — a webhook the App itself caused never mints a task.
  - **Deterministic doc_id (D3/D6):** `doc_id = "gh-" <> to_string(payload["issue"]["number"])`. Build
    task attrs: `title` = issue title; `content` = `%{"kind" => "task", "description" => issue body,
    "labels" => ["src:github", "needs-human"], "lifecycle_status" => "open", "github" => %{"repo" =>
    <owner/name>, "issue" => number, "state" => "intake"}}` (source-of-outsider bookkeeping; do NOT set
    `synced_rev` — this task is inbound-born, not outbound-mirrored). NEVER set a claim/worker/epoch.
  - **Create via the normal path (D6):** call `Barkpark.Content.create_document("task", attrs, dataset,
    Keyword.put(opts, :source, :github))` with the deterministic `doc_id` in attrs. This routes through
    `Content.Writer` → `Tasks.Dedup.check_new_task/5`. On FIRST delivery there is no `prev_doc` so Dedup
    runs (a fresh outsider issue is not a dup of internal tasks → `:ok`, task is born). On RE-DELIVERY the
    `gh-<num>` doc already exists → `prev_doc` is set → Dedup is skipped and the upsert is an idempotent
    no-op (never a second task). `source: :github` → `Broadcast.save_event` stamps
    `mutation_events.source = to_string(:github) = "github"` EXACTLY (D4 cut #2) so the wave-1 Outbox
    (`source != "github"`) excludes it and it NEVER echoes back OUTBOUND.
  - **Backlink comment:** after a successful birth (NOT on re-delivery no-op, NOT on drop/ignore), post a
    "tracked internally" comment via an injectable seam `comment_fun` (default
    `&Barkpark.Plugins.Github.Client.create_comment/4`), best-effort — a failed comment is logged, never
    fails the intake (the task already exists; loop-safety doesn't depend on the comment). Follow the
    DrainWorker seam-injection precedent so the test asserts the call without live HTTP.
  - Repo string comes from `Settings.repo()`; dataset from `opts` (default the first `Settings.datasets()`
    — but thread it explicitly, see Slice 4). Adoption/auto-claim: NONE (wave 4).
- **Decisions respected:** D3, D4 cut #1 + cut #2, D6.
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/intake_test.exs` — `Barkpark.DataCase`,
  NEVER boot phx.server. Assert: (a) opened issue → exactly ONE `gh-<num>` task, labeled
  `src:github`+`needs-human`, unclaimed; (b) re-delivery of the SAME payload → still ONE task (idempotent,
  Dedup-seam no-op); (c) `sender.type=="Bot"` → `:dropped`, zero tasks; (d) `action != "opened"` →
  `:ignored`, zero tasks; (e) the birth `mutation_events` row has `source == "github"` EXACTLY (query the
  row — this is the loop-cut #2 machine check); (f) `comment_fun` seam is invoked once on birth, not on
  re-delivery/drop. Mock the backlink via the `comment_fun` seam (no Bypass needed) OR the mirror_job_test
  Bypass pattern if calling `Client` directly.
- **Size:** medium.

### Slice 3 — webhook controller + route wiring (ties slices 1+2 together)
- **Surface:** `BarkparkWeb.GithubWebhookController` (new) + `plugins/github.ex` `register_routes/1`.
- **Build:**
  - Controller `receive/2` (action name): read `X-GitHub-Event` header. For `"issues"` → decode is
    already done (parsed params); hand `params` (the parsed payload) to `Github.Intake.ingest/2` with the
    dataset threaded (Slice 4). For `"ping"` → `200 {ok: true}` (GitHub's install handshake). Any other
    event → `202` no-op (accepted, ignored). Always return `2xx` on a verified-but-unactionable delivery
    so GitHub doesn't retry-storm. Signature was already verified by the Slice-1 plug in the pipeline, so
    reaching the controller means the delivery is authentic.
  - `github.ex` `register_routes/1`: return `[{:post, "/github/webhook",
    BarkparkWeb.GithubWebhookController, :receive, auth: :github_webhook}]` (was `[]`). The
    `plugin_routes(scope: :github_webhook)` block from Slice 1 expands this to
    `POST /v1/plugins/github/webhook` under the signature pipeline. Update the `github.ex` @moduledoc
    "Wave 2 posture" note that says routes stay `[]` — Wave 3 wires the webhook route.
- **Decisions respected:** D6 (issues.opened only, enforced jointly by controller event-gate + Intake
  action-gate), D4 (the plug+drop chain is now live end-to-end).
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark_web/controllers/github_webhook_controller_test.exs`
  — ConnCase, full end-to-end: build a real `issues.opened` JSON body, sign it with
  `Github.Signature.sign(body, secret)`, POST to `/v1/plugins/github/webhook` with
  `x-hub-signature-256` + `x-github-event: issues` headers and `raw_body` primed (in ConnCase the
  endpoint body_reader runs — put the raw body via `Plug.Conn.put_req_header("content-type",
  "application/json")` + `conn(:post, path, body)` so the cache reader captures it) → assert 2xx + task
  born; bad signature → 401 + zero tasks; `ping` → 200; `x-github-event: issues` with a bot sender → 2xx
  + zero tasks. Depends on Slices 1+2 being present in the tree.
- **Size:** medium.

### Slice 4 — wave-2.5 carry cleanup: tenant scope + `active?/0` memoize
- **Surface:** `github/mirror_job.ex` + `github/drain_worker.ex` + `github/settings.ex` (+ tests).
- **Build:** (a) **TENANT SCOPE** — thread real workspace/project scope from the drained outbox event
  into `MirrorJob` args and on into `reconcile/3` opts, so a non-default-tenant task is loaded and
  written under its own scope instead of the default workspace/project. Add `workspace_id`/`project_id`
  to the `MirrorJob` args map (kept back-compatible: absent → current default behavior) and forward them
  as opts to `load_task`/`Link.*`. (b) **`active?/0` MEMOIZE** — the DrainWorker calls
  `Settings.active?/0` every tick = 1 DB read + 1 audit-row insert + telemetry each time; memoize with a
  short TTL (e.g. cache the boolean + a monotonic timestamp in DrainWorker state, re-resolve only past
  ~5s) so a dark install's idle ticks stop hammering the DB + burying genuine admin audit rows. Do NOT
  change the enable/disable semantics — only the read cadence.
- **Decisions respected:** D2 (level-triggered reconcile still reads CURRENT state), D9 (no behavior
  change to snooze/retry). File-disjoint from slices 1-3, so it can build in parallel.
- **Gate:** `CC=/usr/bin/clang mix test test/barkpark/plugins/github/mirror_job_test.exs
  test/barkpark/plugins/github/drain_worker_test.exs` — assert reconcile honors threaded scope opts
  (a task in a non-default workspace is found/written) and the memoized `active_fun` is called at most
  once within the TTL window across N ticks (seam-injected counter).
- **Size:** small.

**Integration order:** Slices 1, 2, 4 are file-disjoint and build in parallel. Slice 3 depends on 1+2
(it wires their route + calls Intake) — land it AFTER 1+2 merge. Test-DB contention: re-run a gate once
before declaring failure. All agents on Opus. `@canonical capability:github-inbound-intake` marker goes on
`Intake.ingest/2` (public entry, aka:`webhook,issues.opened,gh-birth`) — the wave-7 runbook backlinks it.

**Carried to wave 4+ (not this wave):** adoption action (`bp github adopt` + Studio doc_action strips
`needs-human`/flips ownership/posts a backlink), conflict quarantine (D7 `github_sync_conflicts`
record-then-converge), deleted-issue → `detached`. The `github.state == "intake"` bookkeeping value this
wave stamps is the wave-4 adopt action's find-key.

### Wave 2026-07-13 — Wave 9 landed (steward-merged, grade A-)

**Landed.** The 2-slice named-failure wave shipped; the exposure spine stays human-gated (per D16 — building a specific eligibility predicate would front-run the open `github-bridge-mirror-exposure-decision` task's crit-1, a human choice among five options). **#2908** (`28b43636`) = D17 conflict-source dedup: `Conflicts.open_row/1` AND the partial unique index now key on `{repo,issue,kind,COALESCE(detail->>'source','')}` (lockstep migration; COALESCE guards the null-is-distinct trap; NO new kind — D14 held) so two co-occurring distinct-source problems on one issue stay two operator rows instead of silently collapsing to one. **#2909** (`47bbf463`) = D18 status dataset read-scope: `GET /v1/plugins/github/status` no longer leaks whole-fleet sync health to any operator token — `Health.snapshot/1` now honors its dataset arg (was a dead `_opts` param) and the controller constrains to `conn.assigns.api_token.dataset` (NOT ScopeHelpers, which returns the seeded Default on flat `:token` routes) — a cross-tenant read-leak sealed. Both merge-gated criteria closed with evidence; both slices carried fail-before protective tests, gates green.

**Steward notes.** (1) The Decide-phase charter commit `8c6c2974` (D16-D18 + wave-9 cut) never reached origin/main — the recurring "charter never pushed" trap; recovered by cherry-pick onto main (`32942c08`) before the fix PRs. (2) #2909's Sobelow reddened on a baseline DRIFT (not a new risk): D18's ~53 added lines shifted the two safe `@queue_states` `String.to_atom` findings from health.ex:255/266 → 308/319 (bounded module-attribute list, Low Confidence) — baseline refreshed on-branch.

**Backlog filed:** `github-bridge-spine-outbound-scoping` (the fully-specified but human-gated mirror-eligibility predicate — build only after the exposure decision rules), `github-bridge-w9-health-workspace-isolation`.

**Next wave takes:** resolve `github-bridge-mirror-exposure-decision` (needs a human ruling among the five scoping options) → then build `github-bridge-spine-outbound-scoping` + the reconcile-over-shared path for the ~277 already-mirrored issues; `github-bridge-w9-health-workspace-isolation`.

### Wave 2026-07-13 — Wave 6 RECONCILE BUILT + REVIEWED (1/1 green, grade A, merge-ready)

> **Charter reconcile note (for the steward):** the main-checkout working tree carries an UNCOMMITTED architect-pass entry titled "Wave 6 RECONCILE + console DB-outage honesty (architect pass, two rounds of ground truth)" that was authored AFTER this review worktree branched from origin/main, so it is absent here. On integration, keep BOTH: the architect plan entry, then this review-outcome entry. They do not contradict.

**The wish was STALE; the wave reconciled and shipped one honest slice.** The "Wave 6 — observability" wish asked to BUILD the `/admin/github` :ops console, the `bp github status` verb, `Health.snapshot/1`, and both W5 deferrals — all of which shipped six days ago as **#1238** (`f7f47cc8`) and were hardened by Waves 7/8/9 (verified against origin/main by grep + running the suites + hitting live guerrilla). Vein A (`resolve_doc_actions/2` Access raise) is DEAD (Wave 8 #1994; fail-before probe reproduced 5 failures, restore → 19/0). Vein C (shared-kind detail collapse) is SEALED by D17 #2908. Rebuilding any of it would be false-done waste. The wave built the ONE honest loop-buildable residual.

**Built + reviewed (ONE slice, opus):**
- **`github-bridge-console-db-honesty` — GREEN, final branch `loop-epic/console-db-outage-honesty-surface-db-ok--0-r`.** The console under-surfaced the Wave-8 `db_ok` liveness field: `render/1` never read it, and the "Plugin not provisioned — credentials missing" banner keyed on `not active`, which ALSO degrades to false through `safe/2` during a real DB outage — misreporting an outage as missing credentials. Fix (presentation-only, reuses only the shipped `db_ok`, invents no new sync state, adds no v1 route → no openapi regen): a pure `health_banner/1` (`:db_down` when `db_ok==false` regardless of active; `:inactive` only when `db_ok==true and not active`; else `:ok`) that `render/1` calls once to drive both banners — no branch logic duplicated in HEEx; a distinct db-down banner (`data-role="github-health-db-down"`); `db_ok` surfaced as its own reachable/unreachable indicator (`data-role="github-db-status"` via pure `db_status_label/1`); a lag-vs-pending caption. The `:db_down` path is proven by a direct unit test over the pure helper (the in-process test Repo is always up, so a full mount cannot force an outage) — genuine fail-before (13 tests, 1 failure; compiler flagged the missing `:db_down` clause unreachable) → green 13/0.
- **Reviewer fix in place (commit `b4df907d`):** the db-down banner hardcoded `hsl(0 70% 50% / 0.10)` + a `var(--danger,#d13)` border fallback; aligned it to the sibling not-provisioned banner's token-driven form (`border: var(--danger)`, `background: hsl(var(--danger-hsl) / 0.10)`) so it shifts correctly for dark mode. Gate stayed 13/0. Nothing else changed — logic, HEEx escaping, defensive `parse_id` no-op, and empty/db-down/inactive states were already correct.

**Ledger audit: CLEAN, no fixes required.** Slice task `in_progress` (correct — not done), criteria 0-5 stamped with concrete evidence AS built, criterion 6 left open + MERGE-GATED for the lead. Epic `wave_status` honestly records the single-slice cut + the stale-wish finding. Backlog (`w6-console-live-proof` needs-human, `w9-health-workspace-isolation` open, `mirror-exposure-decision` human + its blocked `spine-outbound-scoping` child) all filed as published open children. No task outside this wave touched.

**Grade: A.** The wave's highest-value act was the decision NOT to build — it caught a stale wish that would have rebuilt six-day-old shipped code (a false-done trap), proved the reconciliation by running suites + hitting live guerrilla, and shipped the one genuine operator-honesty fix with a real fail-before test. Not A+ only because the visible build output is a single presentation-only slice (the epic's loop-buildable frontier was already essentially done) and the console it hardens still has never been eyeballed live — correctly deferred as needs-human.

**Lead on merge:** close the MERGE-GATED criterion 6 on `github-bridge-console-db-honesty` and flip its lifecycle to `done`; integrate the `-r` branch (carries the token-polish commit `b4df907d` atop the builder's `56501f4a`). No docs/openapi.json regen. **Next wave headline:** `github-bridge-w9-health-workspace-isolation` (a tenancy-hardening wave — NOT read-only observability). Wave Paper: `github-bridge-wave-2026-07-13`.

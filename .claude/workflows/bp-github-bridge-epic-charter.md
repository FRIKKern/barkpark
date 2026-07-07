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

**Wave 1 — foundation (this wave, 5 parallel, all mocked/pure):**
1. Plugin skeleton (off by default) + settings_schema/validate_settings — `github.ex` + `plugin.json`
2. Field-ownership matrix + pure task→issue projection — `github/fields.ex` + `github/projection.ex`
3. GitHub App auth + REST client (Bypass) — `github/auth.ex` + `github/client.ex` + `github/errors.ex`
4. Durable cursor + outbox reader + `source="github"` exclusion (DB-only) — `github/cursor.ex` + `github/outbox.ex`
5. `content.github` Link helper + inbound HMAC signature verifier (pure) — `github/link.ex` + `github/signature.ex`

**Wave 2 — outbound mirror engine (the heart):** debounced per-task Oban `MirrorJob` assembling
cursor→outbox→projection→client→Link idempotency; no-op on `rev==synced_rev`; `{:snooze}` on 429;
lifecycle close mapping; drain worker on `oban_crontab`; wire routes/cron into `github.ex`.

**Wave 3 — inbound intake:** webhook controller + endpoint raw-body cache + signature plug (from
wave-1 verifier) + `[bot]`-identity drop + intake via `Content` create through the `Tasks.Dedup`
seam (deterministic `gh-<num>`, `src:github`+`needs-human`, `source: :github`) + "tracked
internally" backlink comment.

**Wave 4 — adoption + conflict quarantine:** adopt action (Studio doc_action + `bp github adopt`)
strips `needs-human`/flips ownership/posts backlink; `github_sync_conflicts` record-then-converge
on out-of-band edits; deleted issue → `detached`, never recreated.

**Wave 5 — Projects v2 + relations:** one-directional GraphQL auto-add + custom fields (diffed);
`parent_id`→sub-issues (deferred-retry when parent unmirrored, cap-flatten past 8-level/100-child);
`blocks`→body marker block.

**Wave 6 — observability (optional):** sync-health state (cursor/lag/last-error/queue-depth) +
`/admin/github` `:ops` console (pulse precedent) + `bp github status` verb.

**Wave 7 — needs-human:** GitHub App creation on FRIKKern/barkpark, install, generate private key +
webhook secret, create Projects v2 board + single-select fields, provision secrets into guerrilla,
add `github` to the whitelist. Runbook doc (`docs/ops/github-sync.md`, human-tier) + `@canonical`
markers on `MirrorJob.reconcile` and intake find-or-create. Blocks NO code slice.

## Wave log

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

### Wave 2026-07-07 — Wave 2 outbound mirror engine BUILT (4/4 green on `-p` branches, NOT yet merged)

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

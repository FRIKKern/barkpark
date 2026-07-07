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

**Wave 4 — adoption + conflict quarantine — ⏳ ACTIVE (cut below):** adopt action (Studio doc_action + `bp github adopt`)
strips `needs-human`/flips ownership/posts backlink; `github_sync_conflicts` record-then-converge
on out-of-band edits; deleted issue → `detached`, never recreated; dedup-refusal surfaced (no silence);
webhook secret memoized (kill pre-verify audit amplification). **See the "Wave 4 CUT" section at the
bottom for the 5-slice build plan.**

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

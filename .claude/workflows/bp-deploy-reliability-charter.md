# Deploy Reliability — Epic Charter

Epic task: `task-fb4fb869490b4213` · Wave 1 Paper: `deploy-truth-wave-1-2026-08-05`

## Vision

**The ledger is the product, and the repair is its first proof.**

One command prints the fleet's deploy health as a *rate with volume beside it*, over a pinned
window, with a named taxonomy derived from the row's own cause — not from whichever progress
caption was on screen when the process died. Every fix in this epic must move a number that
ledger prints, and the ledger must be capable of printing a **worse** number: `UNCLASSIFIED`
going up is the taxonomy's honesty gauge.

`bp cloud site status` stops saying "live" and starts saying "live, serving a build from six
days ago — 2,137 deploys have failed since."

The wish names three things and all three are load-bearing: *repair the deployments that fail*,
*ways to figure out typical deployment issues*, *a log so we notice when deployments are failing*.
A wave that only fixes bugs leaves the operator blind next time; a wave that only builds
dashboards leaves the fleet broken. They ship in one causal order — the instrument first,
because the repairs are scored on it.

**Ground truth at epic open (2026-08-05, control-plane Postgres `cloud-db-1`):** 26,423
deployments, 17,171 failed, **65.0% lifetime / 87.3% over 7d**. Four sites — `astro-search`,
`search`, `search-ember`, `search-capstone` — carry **89% of all failures** and have produced
**zero live releases since 2026-07-30 03:36 UTC**.

## Decisions

- **D1 — The ledger counts on RAW `failure_reason` + `stage`, read from the control-plane
  database, never from the API's projection.** *Why:* `deployment_json/1` humanizes `failure_reason`
  (router.ex:10303) and, since cch-w28-s5, also `detail` (router.ex:10359 → `stage_caption/2` →
  `humanize/1` on failed rows). Counting the rendered field groups by prose, and prose collapses
  distinct causes.

- **D2 — The API is not a census surface, and this is a capability gap, not a serialization one.**
  *Why:* `GET /v1/sites/:id/deployments` clamps at 200 (`parse_limit(…, 100, 200)`, router.ex:6318)
  and `Registry.list_deployments/3` has **no offset clause at all** — `?offset=`, `?cursor=`,
  `?page=`, `?before=` are all ignored, proven by the byte-identical first row. Five sites each
  exceed 3,500 rows, so 200/site is a ~51-hour window. The 688-row census that opened this epic
  saw 2.6% of reality.

- **D3 — THE STANDING LAW: a rate over a PINNED window with VOLUME printed beside it, refusing to
  report below n≈200. Absolute before/after counts are FORBIDDEN.** *Why:* daily deploy volume fell
  2,766 → 74 in six days (37x). Any absolute comparison across that would credit this epic for
  nobody deploying — the exact vacuous green the epic exists to refuse.

- **D4 — Slice order ranks by BLAST RADIUS, not by class count.** *Why:* `BOX_BUSY_409` is 51.4% of
  failed rows and `FORBIDDEN_403` only 6.2%, but 8,576 post-clamp deploys across four sites produced
  **zero** live releases; their 409s and 500s are *downstream* of a dead site re-firing forever.
  Class counts rank symptoms; blast radius ranks causes.

- **D5 — THE PUBLIC-READ CLAMP STAYS MOUNTED. The bug is the half D6 already mandated and
  `graph_corpus` never implemented.** *Why:* site-spawner **D6** says verbatim that a public-read
  token is clamped to "published perspective **+ public-visibility schemas**". `graph_corpus/2`
  (tasks_controller.ex:1067) pins `perspective: :published` correctly and then takes
  `Content.list_schemas/2` with **no visibility predicate** — 33 of 39 production schemas are
  private, and a mutation proof showed a freshly published private-type document's title in the
  corpus within seconds. Perspective is clean; visibility leaks. The fix belongs INSIDE
  `graph_corpus`, not in the allowlist.

- **D6 — A readmit is NEVER an allowlist line alone, and it CO-MERGES with a cost bound.**
  *Why (two independent reasons, both proven):* (a) `extract_ds_type/1` (public_read.ex:143-144) has
  exactly two URL-shaped clauses and no catch-all, while `schema_public?/1` calls it unconditionally
  — `/v1/graph` has no `:type` segment, so a bare readmit is a `FunctionClauseError` **500**, not a
  fix. (b) The 500 class and the 403 class are the same bug six hours apart: `graph_corpus` is the
  top crash frame in guerrilla's journal during the storm, exhausting `POOL_SIZE=10`
  (runtime.exs:717) and 500-ing the *whole box*; `graph_corpus` crash frames run 9,566 (07-28) →
  **0** (08-01). The clamp was also a load shedder. Readmitting without a bound re-creates a
  2,950-row class larger than the 1,070 it removes.

- **D7 — The classifier keys on `(stage, raw failure_reason prefix)`, and `BOX_BUSY` keys on
  `HTTP 409`, never on `already_running`.** *Why:* `stage` is a near-perfect partition (409→PLAN
  100%, DOC_ID_EMPTY→HEALTH 100%, 403→BUILD 99.9%), and 3,814 of 8,830 409 rows (43%) carry the bare
  pre-2026-07-30 string with no machine-readable code at all.

- **D8 — `UNCLASSIFIED` is load-bearing and MUST be able to go up.** *Why:* a taxonomy that cannot
  report its own ignorance is an instrument pointed at the wrong root. Zero failed rows have a NULL
  `failure_reason`, so an `UNCLASSIFIED` count is a statement about the classifier, not the data.

- **D9 — A box-busy 409 is a DEFERRAL that RE-FIRES, not a terminal failure — and the deferral is
  COUNTED and VISIBLE.** *Why:* D44 requires the queue be "effectively serial per site … so the
  trailing rebuild runs AFTER the in-flight build". The serialization already exists one layer down
  (`site-deploy.sh` `flock -w 1200`) and the BEAM 409 makes it unreachable. The publish is genuinely
  lost: `Deploy.start/1` hardcodes `:ok`, all 11,868 `site_deploy` Oban jobs are `completed` with
  zero failures, and 46% of 409s were never followed by any live build. Silently dropping a collided
  deploy is the vacuous green this epic refuses; a counted deferral is not.

- **D10 — The active-deployment dedup index re-keys on `(site_id, environment)`.** *Why:*
  `deployments_active_site_ref_index` is `UNIQUE (site_id, git_ref)` and `git_ref` is NULL on
  26,395 of 26,423 rows (all 8,830 409 rows). A btree unique treats NULLs as distinct, so the index
  **has never deduplicated a single content-auto deploy**. This is not a migration risk introduced
  by the fix; it is a hole that was always open.

- **D11 — The cheapest large lever is an EXISTING COLUMN nobody sets: `webhooks.types`.** *Why:*
  all five `site-autodeploy-*` rows carry `types = {}`, the box dispatcher already honours it
  (webhooks.ex:197, empty array = match everything), and the CP registrar's body has no `:types` key
  at all. 68,523 of 75,922 deliveries (**90.3%**) are `task` mutations — this repo's own bp ledger
  rebuilding five demo websites that render only `paper`. A doc-type filter cuts enqueues ~86% with
  zero new capability. Honest cost: the decorative all-types graph background becomes
  eventually-stale, covered by the hourly `TemplateFreshnessWorker` (D57).

- **D12 — "console → cause" is REFUTED. The diagnosis slice collapses to ANSI + raw + stage.**
  *Why:* the console's last line is more specific than `failure_reason` on **27 of 920** failed rows
  (2.9%), 54% of failed rows have **no console at all**, and `humanize/1` rewrites only 52 of 17,171
  rows (0.30%) — the same 27 rows either intervention would buy. The real payload is ANSI: **1,351
  rows carry raw `0x1B` bytes** and nothing strips them anywhere (not cloud, not CLI, not the SPA).

- **D13 — Any raw failure field is `FailureCopy.scrub(...)`, NEVER the bare column.** *Why:*
  `humanize/1` **is** the secret-scrub carrier (`classify() |> scrub()`, failure_copy.ex:289) and the
  scrub deliberately wraps the cond. Today `scrub/1` redacts 0 of 17,171 rows, so the guard is free —
  and `task-4f363dc65ac43203` is an OPEN row naming exactly this ("a new serializer field … ships
  unscrubbed and nothing reds").

- **D14 — DO NOT ADD ANOTHER PER-DEPLOYMENT ALERT PRODUCER.** *Why:* `deployment_failed` already
  fires — **840 emails in three days to one inbox**, first row 3m24s after PR #9407 merged, peaking
  at 135/hour. Three producers exist. On a fleet failing thousands of times the missing instrument is
  a RATE, not a 841st email.

- **D15 — Alert suppression is NOT this epic's.** *Why:* it is doubly owned by
  `cch-w28-s6-followup-oban-mail-queue-uncaps-reaper-alerts` and by cloud-console-hardening wave 31
  slice 7, which names `registry.ex:6676` explicitly and is unmerged. A third open row on the same
  lines is waste.

- **D16 — A `templates/**`-only change trips NO blocking gate and AUTO-DEPLOYS guerrilla, so every
  template slice MUST carry its assertion in `deploy/site-deploy-node.sh`.** *Why:* proven live on
  PR #9528 — all four required contexts `success` while thirteen substantive jobs `skipped`; the
  three advisory workflows that do cover templates all carry workflow-level `on: paths:` filters,
  which the committed contract declares **structurally unrequirable forever** (D18 of honest-gates).
  `deploy/site-deploy-node.sh` is in `CONSOLE_PATHS`, so routing the assertion there buys a blocking
  Console gate for free.

- **D17 — Any change to `public_read.ex` or the graph admission path is HUMAN-GATED with a NAMED
  independent reviewer, and co-merges its leak-still-closed mutation proof.** *Why:* site-spawner
  **D106** rules exactly this by name for these two files, and states that the clamp shipped without
  its companion fix was "a FALSE CLAIM". This epic inherits that precedent rather than re-litigating it.

- **D18 — Respect cloud-console-hardening's live fences.** *Why:* cch wave 31 decided 2026-08-05 and
  is unmerged: its s1/s8 own `cloud/.../web/router.ex` and its s7 owns `registry.ex`. Regions are
  disjoint from ours (different functions, thousands of lines apart) so this is REBASE cost, not
  semantic duplication — but it must be sequenced, not discovered.

- **D19 — `GITHUB_PUSH_UNBUILDABLE` is a receipt, not a failure, and is excluded from the rate
  denominator.** *Why:* 7 rows (0.04%), deliberately born failed by `github_build_available?/1`
  returning a hardcoded `false`, and only the human-gated `gh-1` can ever move them. Counting them
  permanently inflates a rate this epic cannot touch. Owner: the `dwb` epic
  (`dwb-webhook-deploy-artifact-gap`), not this one.

- **D20 — Probe credentials on a production content API are an open action, not housekeeping.**
  *Why:* five public-read/read probe tokens were minted on guerrilla during wave 1 survey+verify, and
  `grep 'v1/tokens'` on origin/main returns exactly ONE route — `post`. There is **no revoke route**,
  so revocation is a DB action. The missing revoke path is itself a filed defect.

## Roadmap

Ordered by blast radius (D4), then by what the ledger needs to score the rest (D3).

| # | Slice | Surface | Size | Round | Status |
|---|---|---|---|---|---|
| 1 | Graph visibility filter + bounded corpus + by-name readmit | `api/**` | large | W1 r1 | in flight |
| 2 | The fleet ledger: server classifier, census route, cursor, honest payload | `cloud/**` | large | W1 r1 | in flight |
| 3 | The 409 storm: outcome-carrying start, counted deferral, index re-key | `cloud/**` + migration | large | W1 r1 | in flight |
| 4 | Webhook doc-type filter — the ~86% zero-capability lever | `cloud/**` | medium | W1 r1 | in flight |
| 5 | The swallow: a build that cannot read its corpus records the upstream status | `templates/**` + `deploy/**` | medium | W1 r1 | in flight |
| 6 | `bp cloud deployments` + a `site status` that can show a failure | `internal/**` | medium | W1 r2 | deferred to lead dispatch |
| 7 | The rate notice: consecutive-failure / fleet-rate alert (NOT a new per-deployment producer) | `cloud/**` | medium | W2 | filed |
| 8 | The 500 caption lie: a completed 39MB build reported as "the instance refused the deploy" | `cloud/**` | small | W2 | filed |
| 9 | HEALTH probe 308 — three slot-a units in systemd `failed` state right now | `deploy/**` | small | W2 | filed |
| 10 | Scoped-search private-type leak (live today, wider than the graph one) | `api/**` | medium | W2 | filed |
| 11 | `/v1/graph/:id` leaks a draft-only title at the DEFAULT perspective; `?drafts=true` 500s 10/10 | `api/**` | medium | W2 | filed |
| 12 | No token-revoke route exists — mint is public-facing, revoke is DB-only | `api/**` | small | W2 | filed |
| 13 | Retire the two redundant search clones (27.4% of all deployments) | ops | small | W2 | filed |

**Not this epic:** alert suppression (cch, D15); the GitHub push-to-deploy lane (`dwb`, D19);
provisioning-path humanization (`task-3b59e1ea682c03a1`, `cchi-w26-bl-two-unhumanized-failure-tails`).

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the number that moved -->

### Wave 2026-08-05 — founding wave · Paper `deploy-truth-wave-1-2026-08-05` · grade **A−**

**Five of six slices built, reviewed, gate-green, pushed and PR'd. Nothing merged yet — the lead merges.**
The sixth (`dr-w1-s6`, the CLI reader) was deferred to round 2 BY DESIGN, behind s2's census route.

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| Graph visibility + bound + readmit | `dr-w1-s1-graph-visibility-bound-readmit` | `…schema-visibility-i-0-r` | [#9613](https://github.com/FRIKKern/barkpark/pull/9613) | 52 tests, 0 failures |
| The fleet deploy ledger | `dr-w1-s2-fleet-ledger-classifier` | `…a-named-taxonomy-1-r` | [#9614](https://github.com/FRIKKern/barkpark/pull/9614) | 119 tests, 0 failures · full cloud suite 2782/0 |
| 409 deferral + index re-key (**MIGRATION**) | `dr-w1-s3-409-deferral-index-rekey` | `…counted-deferra-2-r` | [#9615](https://github.com/FRIKKern/barkpark/pull/9615) | 69 tests, 0 failures · full cloud suite 2758/0 |
| Webhook doc-type filter | `dr-w1-s4-webhook-doctype-filter` | `…on-every-b-3` (unchanged) | [#9616](https://github.com/FRIKKern/barkpark/pull/9616) | 84 tests, 0 failures · full cloud suite 2753/0 |
| The swallow records the cause | `dr-w1-s5-swallow-records-upstream-status` | `…read-its-corpus-reco-4-r` | [#9617](https://github.com/FRIKKern/barkpark/pull/9617) | selftest 137/137 · typecheck clean · 14 tests, 0 failures |

**What landed.** All three clauses of the wish are addressed, unevenly and honestly so.
REPAIR: the 403 root cause (54% of failures, one plug's allowlist) is closed with the visibility half D6
always mandated plus a named concurrency bound, because re-admitting an unbounded corpus derivation is what
made `graph_corpus` guerrilla's top crash frame. The 409 class (51.4% of failed rows) stops being a terminal
`failed` and becomes a counted deferral that re-fires, and the dedup index is re-keyed onto columns that are
actually present — `git_ref` was NULL on 26,395 of 26,423 rows, so a btree unique treated every one as
distinct and the index had never deduplicated anything. The webhook doc-type filter is the wave's cheapest
lever: 90.3% of deliveries were this repo's own `bp task` writes rebuilding five sites that render only papers.
DIAGNOSE: a build that cannot read its corpus now records WHICH upstream condition stopped it, so seven causes
stop collapsing into one illegible row. NOTICE: the ledger exists as a classifier, a rate that refuses to print
below n=200, and an operator census route.

**What did NOT land, and must be said plainly.** Nothing is merged, so the AFTER number does not exist yet —
this wave shipped the instrument and the repairs, not the proof that the rate moved. The five live webhook rows
on guerrilla still carry `types = {}` (no sanctioned mutation path from the sandbox). Nothing RENDERS the ledger:
the console and `bp cloud site status` still show the humanized reason only, which is exactly the "notice"
half of the wish, and it is the deferred slice.

**Review fixes made in place** (five commits on the `-r` branches):
1. **s1** — the admission cap's ETS table was created by whichever request arrived first, so ETS made that
   request its OWNER and destroyed the table when it finished. Under exactly the concurrency the cap exists to
   shed, slots were forgotten and siblings raised `ArgumentError`: a 500 from the guard against 500s. Now
   created at application boot, pinned by a mutation-proved test.
2. **s2** — two committed router fences (the moduledoc route table, the head-fence GET census) that the new
   route tripped and the slice did not move. Both would have reddened the Cloud gate on merge.
3. **s2 × s3, the wave's most important fix** — s3 relocates 8,830 rows from `failed` to `deferred`;
   s2's classifier had no arm for that status and answered `nil`, so those rows would have become INVISIBLE
   and the headline failure rate would have HALVED because rows stopped being counted. That is the vacuous
   green this charter forbids in writing, and it would have been the wave's headline number. The census now
   has three cohorts and a deferral is visibly relocated, never deleted.
4. **s3** — the two deferral paths disagreed: one returned an error on a failed re-queue so Oban retried, the
   other recorded SUCCESS for a publish that was at that moment lost. Made consistent.
5. **s5** — the `bp-corpus-status` marker is an interface the deploy row reads back, and its only proof was a
   shell fixture that HARD-CODES the text, i.e. the assertion ran in the wrong direction. Value shaping moved
   to the dependency-free `lib/markers.ts` and pinned by six mutation-proved tests.

**Ledger.** All five slice tasks sit `in_progress` with merge-gated criteria correctly left open for the lead.
One overclaim corrected: `dr-w1-s3` criterion #2 asserted the slice-2 ledger buckets the deferral, which was
not true and not proved — now true only because of review fix (3), and stamped saying so. Three criteria the
builders could not close because builders do not push (two PR-body criteria, one astro-shape verification)
were stamped against the PRs opened here. Two follow-ups filed: `dr-bl-deferral-requeue-failure-untested`,
`dr-bl-map-landing-empty-marker`.

**Merge order matters, and is not optional this wave.** s2 at or before s1 (so the before/after rate is
measurable, and so the deferral bucket exists before s3 relocates into it) → s1 → **s3 ALONE** (the only
migration; `cloud/**` auto-deploys and the post-merge hook migrates) → s4 → s5 after s1.
**s1 is HIGH-FLIP-RISK and a genuinely independent second security reviewer is owed before merge (D17).**

**Next wave takes:** dispatch `dr-w1-s6` the moment s2 merges — the ledger has no human reader and that is
half the wish. Then the AFTER measurement as a rate with volume over a pinned window, the live webhook-row
repair (`dr-w1-s4-followup-repair-live-webhook-types`), and `dr-bl-scoped-search-private-leak` (priority 0 —
a LIVE leak wider than the one this wave closed, and it should reach the same security reviewer).

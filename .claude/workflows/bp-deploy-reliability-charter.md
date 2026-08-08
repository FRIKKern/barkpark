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

### Wave 2 decisions (2026-08-06) — the deploy gets a black box recorder

- **D21 — THE DURABLE BUILD LOG IS A FILE KEYED ON `build_id`, NEVER ON `slug`. search-template
  **D31 STANDS** and is AMENDED for keying and retention; journald is a BACKFILL SOURCE and a
  fallback read path, never the store.** *Why:* D31's title is "Durable seam is a FILE CONTRACT,
  never journalctl" and its *Why* is entirely about DeployRunner's in-memory re-attach seam — it
  rules on what the RUNNER reconstructs from, and never contemplated an operator-facing
  per-deployment record. It is silent on the two properties the recorder lives on. The defect is
  exactly and only wrong-noun keying: `deploy_runner.ex:524` names the log
  `Path.join(dir, "#{req.slug}.log")` and `:543` `fresh_run_files/1` truncates it at every launch.
  Observed live, three minutes apart: build `caf056f10a8b6837` emitted 33,227 bytes of build output
  at 23:36 UTC; at 23:39 UTC `search-capstone.log` was **0 bytes**, truncated by the next launch.
  journald is disqualified as the STORE four ways, each measured: retention is 8.74 days, global,
  undeclared (`journald.conf` is bare `[Journal]`; default cap 3.8 G, current use **3.6 G** — at the
  ceiling and vacuuming) and hostage to API chatter (949,210 lines on 2026-08-01 alone); the fast
  read path needs the EXACT unit name (0.16 s exact vs **121 s** globbed) and the Deployment row
  carries no `unit_name` at all; the build is scheduled to leave this box (site-spawner wave 9,
  "THE BUILD LEAVES THE SERVING BOX"); and reading it means the API shelling `journalctl` with a
  row-derived unit name. journald IS permitted for (a) a one-time backfill of builds predating the
  recorder and (b) a secondary lookup when the file is gone — both gated on the row persisting
  `unit_name` at launch. **The backfill window expires:** the oldest retained entry is
  2026-07-28T05:45:56 and the journal is at its cap, so every day of delay drops the oldest failures.

- **D22 — EVICTION MUST BE A DISTINGUISHABLE ANSWER. "log evicted" and "no log was ever recorded"
  may never be the same value.** *Why:* proved by mutation. With `@max_tracked_runs` lowered 32→2 the
  delete branch executed for the first time and removed the whole quartet; afterwards
  `DeployRunner.status("evictme")` and `DeployRunner.status("never-deployed-at-all")` returned
  **byte-identical** idle maps. Over HTTP it is worse: `resolve_status_match/2` collapses evicted,
  truncated-away and never-started into ONE 404 that the control plane treats as keep-waiting.
  A tombstone is required — and it must be written at FINALIZE (`cache_and_cleanup/4`), because the
  manifest carries no `exit_code`, no `failure_reason` and no `finished_at`, so a prune-time
  tombstone could not say why anything failed.

- **D23 — ORDER THE FIX: per-launch TRUNCATION first, eviction second. The 32-run cap is a SITE cap
  and has never fired.** *Why:* `manifest_path/2` is `"#{slug}.manifest.json"` — one manifest per
  slug, forever — so `length(manifests) > 32` needs more than 32 distinct SITES. Guerrilla has 16.
  `prune_run_state_dir` has never evicted anything and, at this fleet size, cannot; it also has zero
  test coverage. Truncation, by contrast, fires on EVERY repeat deploy and is 100% of the loss for
  search-capstone's 25 failures. A wave that shipped eviction honesty first would have fixed the path
  that never runs and left the path that runs every time.

- **D24 — THE WIRE-CARRIED `log` ARM IS DEAD THREE WAYS. Do not build the recorder on it.** *Why:*
  `normalize_report/1`'s first `cond` arm is `is_list(body["stages"])` and every box render path
  emits `stages` as a list unconditionally, so the `body["log"]` arm at `:1481` is unreachable in
  production; the box renders `log` as a JSON **array** while the arm guards `is_binary`; and the log
  file holds RAW CHILD OUTPUT ONLY (`grep -c BPSTAGE` = 0 on a real 30,993-byte failing build) so
  `parse_lines/1` would return `[]` even if it fired. Six `normalize_report` tests exist and **zero**
  drive `"log"`. Related and binding: `emit()` (site-deploy-common.sh:55) collapses newlines and
  `cut -c1-240` every BPSTAGE detail against a single-line `@stage_re` — **a multi-line record
  structurally cannot cross that wire.** The extractor stays a one-line SUMMARY; the record is
  out-of-band.

- **D25 — search-capstone's 25 failures are ONE bug, and the producer is the PROVISIONER'S OWN
  `rm_rf!`, not the template and not the spawner.** *Why:* guerrilla's journal holds the confession
  verbatim at 2026-08-05T21:01:45 — `%File.Error{reason: :eexist, path: ".../search-capstone/src",
  action: "remove files and directories recursively from"}`. `materialize/4` (provisioner.ex:140-166)
  is `rm_rf!(partial)` → `mkdir_p!` → `cp_r!` → **`rm_rf!(src)`** → `rename(partial, src)`; the raise
  landed on the delete, leaving `src` half-deleted with `app/` intact and `components/`, `lib/`,
  `schemas/`, `next.config.mjs` gone — exactly 44 files. The moduledoc's guarantee ("a crash mid-copy
  dies in `src.partial`, never in a half-populated `src`") protects the COPY window; this fired in the
  DELETE window. Two same-slug deploys were in flight and provision runs in the Elixir runner BEFORE
  the script's per-slug `flock`, so it is unserialized by construction. **The wedge is permanent
  because the digest fingerprints the TEMPLATE, never `src`:** the marker survived, its digest still
  equals the live template's digest recomputed today over 66 files, so `provisioned_fresh?/3` returns
  true forever and self-heal can never fire. Fix the CLASS — serialize provision per slug, never
  delete `src` before the rename lands, and make the marker attest to `src`'s integrity rather than
  the template's provenance. Blast radius is search-capstone alone: all 10 sites were checked and the
  same-template siblings provisioned within 100 seconds are byte-complete.

- **D26 — A PROVISION FAILURE BECOMES A NAMED, TYPED REFUSAL — and site-spawner D34 still holds: NOT
  a 7th stage.** *Why:* this is the wave's thesis in its purest form and the cheapest repair in it.
  `deploy_runner.ex:479-489` answers a `{:provision_failed, reason}` with a `Logger.warning` and
  `{:error, :start_failed}` — no deployment row, no BPSTAGE, no `failure_class` — so the
  `%File.Error{}` struct that names the exact path and the exact action, and would have solved this in
  one read, went to journald and nowhere else while every operator surface showed 25 identical
  "Module not found" builds. D34 deliberately made PROVISION silent to avoid a 13-file blast radius,
  and that trade is respected: the fix is a typed 500 code carrying a scrubbed reason, not a new
  stage name.

- **D27 — REPAIRING THE CHECKOUT YIELDS A GREEN BUILD AND STAGE AND THEN DIES AT HEALTH. The HEALTH
  gate must be able to tell SLOW from BROKEN, and that ships in the SAME wave or the rate does not
  move.** *Why:* a restored hardlinked tree built clean — `✓ Compiled successfully in 82s`, `EXIT=0`,
  all 29 module errors gone — and STAGE's `exit 13` guard is satisfied (`.next/standalone/server.js`
  present, 7286 B). But `health_gate_node` probes with `--max-time 8` and breaks only on 200, and the
  repaired build renders that page in **~48 s**, so every one of 20 attempts reports the last
  completed hop, a `308`. The decisive control: the LIVE, previously-GREEN capstone release behaves
  identically (`308/8.4s, 308/8.0s, 308/8.0s` under the ceiling; `200/48.1s` without it) while sibling
  slots on the same box at the same moment render in **1.3 s**. So the latency is capstone-specific
  and pre-existing — the repair EXPOSES it, it does not cause it. Honest headline: two repairs, not
  one. **Quote the ratio (48 s vs 1.3 s, same box, seconds apart), never the absolute seconds** — the
  measurement was taken at load average 13.45.

- **D28 — THE 500 CLASS IS DB POOL STARVATION PLUS A POLL LOOP WITH ZERO 5xx TOLERANCE. The pool is
  NOT this epic's; surviving it is.** *Why:* FallbackController is REFUTED — `grep -c
  FallbackController` over 184,159 journal lines returns **0** against 858 "Sent 500". The real term
  is `DBConnection.ConnectionError`, landing on the deploy door's own auth plug
  (`auth.ex:49 verify_token/1` ← `RequireToken.call/2` ← `require_admin/2`), rendered by `ErrorJSON`
  (the crash path, which never reaches `action_fallback`) into the same `internal_error / unknown
  error` constant. Correction to the framing: those 500s are the FAST queue-drop shape (n=159,
  **median 1,203 ms**), not the 15 s checkout timeout, and search — not deploy — is the dominant
  consumer (753 stack frames in `query_pipeline.ex:190` vs 333 in `verify_token`). The pool repair is
  owned by `jpf-bl-oban-pool-partition`. **What IS ours:** `deploy.ex:869-870` fails terminally on any
  non-2xx/non-404 while `{:error, _}` two clauses below gets a 45-beat grace budget — 91% of the
  door's 500s are on that poll arm, so one pool blip on beat 37 of a nearly-finished build kills it.
  Proven by mutation: a probe test asserting a 5xx poll then a real success FAILED before
  (`left: {:ok, :live} / right: {:ok, :failed}`) and passes after a ~4-line grace arm, 54 tests 0
  failures, with the three pre-existing bounded-grace tests still green. **A start-arm retry is safe
  by construction** — the box answers 409 `already_running` and `:655` already converts 409 into a
  counted deferral (D9), so a racing retry degrades to a deferral, never a double-build.

- **D29 — `FailureCopy.scrub/1` CANNOT SEE BARKPARK'S OWN TOKEN. D13's evidence sentence is RETIRED;
  D13's conclusion stands.** *Why:* measured against the REAL module on origin/main, 2,000 tokens
  minted with the production expression (`auth.ex:502`): `BARKPARK_TOKEN=<tok>` leaks **1902/2000 =
  95.1%**, and so do two shapes nobody asked about — a bare token in prose and a colourised
  `token=`. Three independent holes: the key clause's `\b` cannot fire after the `_` in
  `BARKPARK_TOKEN`; the provider-prefix clause lists sk/pk/ghp/xox/hcloud and **not** `bppat_` or
  `bpcs_` — the scrub knows every other vendor's credential and not its own; and the bare-entropy
  clause needs 32 contiguous alnum, which a base64url body usually breaks. `grep -n bppat
  failure_copy_test.exs` prints **nothing**. So D13's "scrub redacts 0 of 17,171 rows, so the guard is
  free" is equally explained by "scrub cannot see the credential this fleet actually mints" — it must
  stop being quoted as a safety proof. The fix that works is the PREFIX clause (all six shapes → 0%,
  table still 87/87); the key-clause lookbehind alone leaves prose and ANSI shapes at 93.1% and must
  not ship as if sufficient. **Order matters for raw logs:** the shipped `scrub |> strip_ansi` leaks a
  colourised token 95.1%; `strip_ansi |> scrub` leaks 0%. And a MUTATION CONTROL found a second
  defect: deleting the entire Bearer clause leaves the 87-test table fully GREEN while the Bearer leak
  goes 0% → 94.2% — one clause of the credential redactor is unpinned today, against the module's own
  comment that a pattern without positive AND negative rows "is not shippable".

- **D30 — THE CENSUS IS 403-DARK IN PRODUCTION AND THAT IS A PERMANENT HUMAN GATE, NOT A SLICE. The
  reader ships over the TEAM-scoped route instead.** *Why:* `require_platform_operator/2` has exactly
  one pass condition and prod returns **403 for the real token / 401 for a bogus one** — authentication
  passes, allowlist membership fails; `/v1/me` reports `platform_operator:false`. The hole is already
  an open, priority-1, 0/3-criteria row (`gr-ops-platform-admin-emails`) that declares itself NOT
  AGENT-BUILDABLE, is one of cloud-console's THREE PERMANENT HUMAN GATES, and needs a container
  RECREATE because `docker-compose.yml:67` is a bare passthrough. **Do not file an env slice; file a
  dependency.** The escape: `GET /v1/sites/:id/deployments` returns **200 today with an ordinary team
  token and already carries `failure_class`** — a whole-fleet census was reconstructed by hand from it
  (13 sites, 1,255 rows, 355 live / 833 failed / 67 deferred). Any acceptance criterion asserting "the
  census returns 200" is vacuous green by construction until a human touches prod. Two traps for the
  reader: `sites[]` carries a bare `site_id` with no name, and EVERY `pct` on the payload is `nil` at
  current volume, so the table must render the refusal in every rate column.

- **D31 — CORRECTS D18: the live console fence is cloud-console-hardening wave **33**, not wave 31,
  and this wave does NOT touch the console render path.** *Why:* wave 31's fences MERGED on 2026-08-05
  (#9591, #9655, #9656, #9657), so D18's "unmerged, must be sequenced" is two waves stale. Wave 33 is
  VERIFYING — one phase ahead of us, zero PRs, zero merges — and its s3 is re-aimed onto
  `deployConsoleHtml` (app.js:11637) and `deployDetailHtml` (:10763), which is exactly where
  `task-54326937e919e2cf` would put a `failure_class` pill. Wave 33 saw the collision and declined to
  fire, correctly, on the reading that our wave 2 had cut zero slices — a reading that is FALSE as of
  this hour. So we decline in return: **the console half of the reader is deferred**, the CLI half
  ships. Wave 33 also disclaims the recorder twice by name ("this wave does not touch `deploy/`";
  "hard boundary"), so `deploy/**`, `api/lib/barkpark/sites/**` and `internal/builder/**` are
  uncontested ours.

- **D32 — `internal/**` TRIPS ZERO REQUIRED CONTEXTS WHILE AUTO-DEPLOYING — the same hole D16 named
  for `templates/**`, and D16's own citation is a phantom.** *Why:* live protection requires exactly
  four contexts (`Elixir gate`, `PR references an active task`, `Cloud gate`, `Console gate`) and
  `internal/cli/**` and `internal/builder/**` measure false on all of them, while `deploy.yml` lists
  `internal/**` in its push-to-main paths — merged IS live. The Go suite is not a rescue: `go-tests.yml`
  carries a workflow-level `on: paths:` key, which honest-gates D18 declares structurally unrequirable
  forever. Separately, **D16 cites PR #9528 as its live proof and #9528 changed exactly ONE file** —
  `tooling/grip/ledger/pds-w47-n1-adjudication-2026-08-04.md`, a PDS markdown row. The mechanism is
  sound and independently re-derived from the three path-escape scripts; only the number is borrowed.
  The real witness is this epic's own **#9617**, whose `deploy/site-deploy-node.sh` edit pulled a
  templates PR into the Console lane. CONSEQUENCE, accepted honestly this wave: the CLI reader slice
  ships with an ADVISORY gate only. The remedy (a `__app.test.mjs` derivation reading the Go file plus
  ONE exact-file `CONSOLE_PATHS` entry, the shape already used for
  `internal/taskboard/testdata/styleguide_lifecycle.txt`) is filed, not built, because it would
  collide with the extractor-lift slice on the same test file.

- **D33 — THE EXTRACTOR LIFTS INTO `deploy/lib/site-deploy-common.sh`: one de-duplication buys a
  BLOCKING gate over BOTH engines.** *Why:* `build_failure_reason()` exists twice and the 8-line
  bodies are md5-identical (`181029d3bc98b876d99d67ae704841a4`) at site-deploy.sh:1939 and
  site-deploy-node.sh:1433, so a repair to one engine leaves the DEFAULT engine
  (`runtime_target` defaults to `:static`) compressing every failed build to one line. Both already
  source the common lib at their own line 125, and the common lib is ALREADY in `CONSOLE_PATHS` while
  `deploy/site-deploy.sh` is NOT — so declaring paths is not needed and would ship
  dispatch-with-no-assertion. The Console harness already has TEETH here
  (`__app.test.mjs:10050` asserts `/build_failure_reason\(\) \{/` against `DEPLOY_NODE_SH`), proven by
  mutation: lifting the function reds that test (`not ok 1 … "build_failure_reason is the fixture's
  stem producer"`) on a clean 3/3 tree. Repointing that ONE assertion at `DEPLOY_COMMON_SH` must land
  in the SAME commit as the lift or main goes red. The Cloud gate is unaffected — its derivation reads
  a different line (the `FATAL: 401 Unauthorized` echo), and `CLOUD_ESCAPE_MIN` is a floor.

- **D34 — THE AFTER MEASUREMENT IS A SLICE, IT IS HARDER THAN ASSUMED, AND IT PRINTS BOTH
  CONVENTIONS.** *Why (four measured constraints):* (a) at an 81-minute window the BEFORE cohort is
  n=565 (the census COMPUTES 89.38%) and the AFTER is n=144 (the census REFUSES it) — printing
  "89.4% → 36.8%" quotes a percentage the epic's own code declines to emit. Widen until BOTH sides
  clear n≥200; ~85 rows/hr accrue, so this is a matter of waiting, not of a blocked measurement.
  (b) A pinned window is reproducible ONLY if `to` sits **≥19 minutes behind wall clock** (max deploy
  duration 00:18:06; p99 976 s) — the 37→38 drift a surveyor saw was an open-ended `to`, not a mutating
  table; the identical pinned query returned 505 twice, 20 s apart. (c) `status: "building"` rows
  classify to `nil`, which is neither `not_attempted?` nor `deferred?`, so they land in `attempted` and
  pad `volume`; zero in the measured windows, latent fleet-wide. (d) **THE HEADLINE IS SUBSTANTIALLY A
  RECLASSIFICATION AND THE WAVE MUST SAY SO:** BEFORE has 269 terminal `failed` 409s and ZERO
  deferrals; AFTER has 26 deferrals and ONE failed 409. Scored under BEFORE's own convention a busy-box
  refusal is a failure, and AFTER is **54.86%**, not 36.81%. So 89.4→36.8 is roughly 89.4→54.9 of real
  repair plus ~18 points of definitional gift. The ledger's own moduledoc anticipated exactly this; the
  CODE is honest and the NARRATIVE is what is at risk. Print both conventions side by side, and print
  the per-site split beside the aggregate — search-capstone alone is 50.9% of AFTER failures and is
  0-live in BOTH windows, so it is a constant, not a variable, and removing it reads 23.0%.
  `GITHUB_PUSH_UNBUILDABLE` (D19) is **zero rows** across the span: report the zero, never omit it.

- **D35 — THE ONE INDEPENDENT SECURITY REVIEWER GOES TO THE LEAK, AND THE CRITERION IS REWRITTEN INTO
  A SATISFIABLE FORM.** *Why:* the clause "merged BY a NAMED independent reviewer who is not the
  author" has NEVER been discharged pre-merge anywhere in this repo — site-spawner's own D122 records
  that all seven wave-10 PRs show `reviews=0`, author == merger, and "a gate that wants it must invent
  one"; cch D181 ruled the same wording UNSATISFIABLE after the fact. This epic ALREADY carries one
  stuck instance (`dr-w1-s1` c6, open at 6/8). The ONE precedent that worked is cch **D182**:
  lead-dispatched, POST-merge, re-derived by DRIVING merged bytes on a case the builder never drove,
  output a written ruling plus a filed row plus a durable
  `tooling/grip/ledger/cch-w15-v8-independent-review-*.md`. Copy that shape. D17's fence is literal and
  narrow (`public_read.ex` and the graph admission path), the leak fix touches that neighbourhood and
  the recorder does not, so a reviewer spent on the recorder discharges nothing the charter demands.
  The recorder instead carries a SECRETS MEASUREMENT criterion (re-prove D29's numbers against the
  MODULE) and its raw-log surface is gated on that measurement, not on a second reviewer this workflow
  cannot spawn. **And the obvious leak fix is a trap:** mounting `PublicRead` on `:scoped_api` would
  403 all 21 routes there and take the live flagship dark — search-template **D49** and the shipped
  `public_read_search_matrix_test.exs` moduledoc both say so by name. The fix belongs in
  `restrict_anonymous_to_public_types/3`, keyed on the public-read PERMISSION (the predicate already
  exists as `AnonPerspective.public_read_token?/1`, and `CallerContext.from_token/1` already carries
  `roles: perms` into the retriever) — and it MUST move `query_controller.ex:640 authed?/1` in the same
  PR, which the retriever's own comment names as its parity partner. The existing matrix test is green
  and STRUCTURALLY BLIND (its fixture schema is `visibility: "public"`), so a builder who runs it and
  sees green ships nothing.

- **D36 — CORRECTS D20: a revoke route EXISTS and is REACHABLE, the count is EIGHT, and the unscoped
  primitive behind it is itself a defect.** *Why:* `DELETE /v1/shares/tokens/:token_id`
  (router.ex:2027, `:require_admin`) calls `Auth.revoke_token/1`, whose binary-id arm is an UNSCOPED
  `Repo.get(ApiToken, uuid)` with no `kind`, no `share_scope` and no workspace predicate — it will
  revoke a `kind="api"` public-read token by id today, over HTTP, no DB and no migration. Proven
  reachable without mutating: 401 anon, **404 "token not found"** for a bogus UUID with the admin
  bearer. The asymmetry is the defect: `list_share_tokens/1` filters `share_scope IS NOT NULL` so LIST
  is family-scoped while REVOKE is not, and `GET /v1/shares/tokens` returns `{"tokens":[]}` against 56
  live tokens. So the retirement is an OPS ACTION AVAILABLE NOW, not work blocked behind building a
  route. The count is **eight, not five**: seven `probe-%` rows (5 public-read + 2 read, all
  `revoked_at` NULL, all id-addressable including the two the filed task omitted) plus
  `lead-verify-403fix` (`ac8ff595-…`, `{public-read,read}` — strictly more privilege than any probe,
  raw secret actually disclosed into a transcript, and invisible to every `probe-%` filter used so
  far). All eight pass `verify_token/1`'s exact WHERE. Note the criterion trap: "revocation verified
  by a request that now fails" is UNSATISFIABLE for all eight — the mint returns an unprefixed
  base64url ONCE and no ledger file records one — so the verifiable form is a DB read-back of
  `revoked_at` plus a fresh mint→revoke→401 round-trip on a throwaway.

## Roadmap

Ordered by blast radius (D4), then by what the ledger needs to score the rest (D3).

| # | Slice | Surface | Size | Round | Status |
|---|---|---|---|---|---|
| 1 | Graph visibility filter + bounded corpus + by-name readmit | `api/**` | large | W1 r1 | in flight |
| 2 | The fleet ledger: server classifier, census route, cursor, honest payload | `cloud/**` | large | W1 r1 | in flight |
| 3 | The 409 storm: outcome-carrying start, counted deferral, index re-key | `cloud/**` + migration | large | W1 r1 | in flight |
| 4 | Webhook doc-type filter — the ~86% zero-capability lever | `cloud/**` | medium | W1 r1 | in flight |
| 5 | The swallow: a build that cannot read its corpus records the upstream status | `templates/**` + `deploy/**` | medium | W1 r1 | in flight |
| 6 | `bp cloud deployments` + a `site status` that can show a failure | `internal/**` | medium | W1 r2 | superseded by W2 #16 (CLI half only; console half fenced by D31) |
| 7 | The rate notice: consecutive-failure / fleet-rate alert (NOT a new per-deployment producer) | `cloud/**` | medium | W3 | filed |
| 8 | The 500 caption lie → **poll grace for 5xx + phase + request_id** | `cloud/**` | medium | **W2 r1** | in flight (#18) |
| 9 | HEALTH probe: the gate cannot tell SLOW from BROKEN | `deploy/**` | medium | **W2 r1** | in flight (#19, merged into the engine slice) |
| 10 | Scoped-search private-type leak (live today, wider than the graph one) | `api/**` | medium | **W2 r1** | in flight (#20) |
| 11 | `/v1/graph/:id` leaks a draft-only title at the DEFAULT perspective; `?drafts=true` 500s 10/10 | `api/**` | medium | W3 | filed |
| 12 | Token revoke: the primitive is REACHABLE and UNSCOPED (D36) + retire the eight live probes | `api/**` + ops | small | W3 | filed |
| 13 | Retire the two redundant search clones (27.4% of all deployments) | ops | small | W3 | filed |
| 14 | **The black box recorder: a durable build log keyed on `build_id`, honest eviction** | `api/**` | large | **W2 r1** | in flight |
| 15 | **The provision wedge: `rm_rf!` mid-delete leaves a tree that can never self-heal** | `api/**` | large | **W2 r1** | in flight |
| 16 | **`bp cloud site status` stops reporting `live` over a failed newest deployment** | `internal/**` | medium | **W2 r1** | in flight (advisory gate only, D32) |
| 17 | **`scrub/1` learns Barkpark's own token prefix** | `cloud/**` | small | **W2 r1** | in flight |
| 18 | **The deploy engine stops narrowing: one extractor behind a blocking gate + HEALTH slow-vs-broken** | `deploy/**` | large | **W2 r1** | in flight |
| 19 | **The AFTER measurement: n≥200 both sides, both conventions, per-site split** | docs/ledger | medium | **W2 r2** | deferred to lead dispatch |

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

### Wave 2026-08-06 — the black box recorder · Paper `deploy-truth-wave-2-2026-08-06` · DECIDED

**Wave 1 is fully landed and fully deployed, and the repair genuinely worked.** All five PRs merged
(#9613–#9617, charter #9565); every Deploy (production) run reads SUCCESS. Re-derived on a quiet
control-plane box: over the 81 minutes before the fixes went live, 189 deployments / 163 failed
(**86.2%**); over the 81 minutes after, 112 / 37 failed (**33.0%**) with the first 6 deferrals the
fleet has ever produced. That number is real AND partly definitional — see D34, which is binding on
this wave's own headline.

**The direction: the deploy gets a black box recorder, and the repair is cut FROM the first recovered
log.** The remaining failure classes are not N bugs; they are ONE bug at five boundaries. At every
hand-off from where the truth is known to where the operator reads, this system narrows a rich cause
to a fixed-width string and then destroys the original: script→row (one line, forever, by contract);
box API→CP (a constant on the wire, the term only in the journal); runner→disk (one file per SLUG,
truncated per launch); row→operator (`build_log_url` NULL on every box-build); and — the one the
survey found, and the one that mattered most — **provision→nothing at all**, where a `Logger.warning`
swallowed the `%File.Error{}` that explains 63% of all failures.

**The bet, and it paid before a single builder flew.** A verifier raced the truncation window and
captured the real 30,993-byte failing build; a second verifier read it, restored 44 files, and built
it clean. The root of search-capstone's 25 identical failures is ONE bug — the provisioner's own
`rm_rf!(src)` raising mid-delete — and it was diagnosed from a recorded log, exactly as the wave
promised. It also cost the wave its simple headline: the repair yields a green BUILD and STAGE and
then dies at HEALTH (D27), so this wave takes two repairs, not one, and says so.

**Verification corrected the direction eight times, and each correction is a decision above.** The
biggest: the `body["log"]` wire arm the wave nearly built on is dead three ways (D24); the census the
NOTICE clause was to be built on is 403-dark for everyone in production (D30); the "no caller" premise
the lead's own headline task carries is REFUTED at running-system authority; `scrub/1` cannot see
Barkpark's own credential (D29); and the cited proof behind D16 is a phantom wearing a number (D32).

**Coverage deficit: NONE.** 16/16 surveyors and 13/13 verifiers reported.

**Fences this wave respects:** cloud-console-hardening **wave 33** is VERIFYING, one phase ahead, and
its s3 owns `deployConsoleHtml`/`deployDetailHtml`. The console half of the reader is DEFERRED (D31).
`cloud/lib/barkpark_cloud/notifications/**`, `scripts/pds-*` and the console path-escape scripts are
untouched.

**Two things the lead can do TODAY without a builder:** retire the eight live probe credentials over
the already-reachable `DELETE /v1/shares/tokens/:id` (D36), and set `PLATFORM_ADMIN_EMAILS` on the
control plane to un-dark the operator census (D30, `gr-ops-platform-admin-emails`) — noting it grants
the fleet autoupdate kill-switch, so it is a privilege grant needing explicit consent.

**HIGH-FLIP-RISK slices, both owed a genuinely independent second reviewer before merge:**
`dr-w2-s7-scoped-search-permission-clamp` (the P0 live leak — D35 assigns this wave's ONE reviewer to
it, with the satisfiable post-merge wording) and `dr-w2-s4-scrub-knows-our-own-token` (secret-boundary,
and D29's mutation control already proved the table certifies patterns it cannot see).

### Wave 2026-08-06 — REVIEWED · Paper `deploy-truth-wave-2-2026-08-06` · grade **A**

**Seven of seven round-1 slices built, reviewed, gate-green on their final state, pushed and PR'd.
Nothing merged — the lead merges.** `dr-w2-s8` (the AFTER measurement) is round 2 BY DESIGN, behind
s2 + s3 + s6 landing AND deploying.

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| Build-keyed durable log + tombstone | `dr-w2-s1-recorder-build-id-keyed-log` | `…keyed-on-the-de-0-r` | [#9727](https://github.com/FRIKKern/barkpark/pull/9727) | 66 tests, 0 failures |
| Provisioner rm_rf wedge | `dr-w2-s2-provision-rmrf-wedge` | `…identical-failures--1` (unchanged) | [#9729](https://github.com/FRIKKern/barkpark/pull/9729) | 26 tests, 0 failures |
| Poll grace for 5xx + named refusal | `dr-w2-s3-poll-grace-5xx-and-named-refusal` | `…beat-stops-killi-2-r` | [#9730](https://github.com/FRIKKern/barkpark/pull/9730) | 58 tests, 0 failures |
| The scrub learns our own prefix | `dr-w2-s4-scrub-knows-our-own-token` | `…learns-barkpark--3-r` | [#9731](https://github.com/FRIKKern/barkpark/pull/9731) | 109 tests, 0 failures |
| CLI status stops lying | `dr-w2-s5-cli-status-stops-lying` | `…stops-reporting-liv-4` (unchanged) | [#9732](https://github.com/FRIKKern/barkpark/pull/9732) | build + vet + all Go packages ok |
| One extractor · HEALTH slow vs broken | `dr-w2-s6-engine-one-extractor-health-slow-vs-broken` | `…stops-narrowing-one-fa-5` (unchanged) | [#9733](https://github.com/FRIKKern/barkpark/pull/9733) | 862/862 · engine self-tests 274/274 + 158/158 |
| Scoped-search permission clamp (**P0**) | `dr-w2-s7-scoped-search-permission-clamp` | `…serving-pri-6` (unchanged) | [#9734](https://github.com/FRIKKern/barkpark/pull/9734) | 23 tests, 0 failures (+29 in the two inverted suites) |

**What landed.** The wave's thesis held: the black box recorder was built AND the repair was cut from
the first recovered log. All three clauses of the wish move. REPAIR — the provisioner's DELETE window
is closed (swap-then-unlink, per-slug lock, presence-integrity freshness), which is the single bug
behind 25 identical search-capstone failures; a pool blip on one poll beat stops killing a finished
build; HEALTH stops calling a slow site broken. DIAGNOSE — a build log is now keyed on the DEPLOYMENT
and survives the next launch, a terminal record outlives the log with exit code, reason, stage fold
and an exact-name journald command, and the provision arm that swallowed 63% of this fleet's failures
is a NAMED typed refusal. NOTICE — `bp cloud site status` stops printing a serene "live" over a failed
newest deploy and prints the ledger's `failure_class` the control plane has been shipping all along.
A P0 authorization leak was closed on the side, keyed on the PERMISSION and moving both routes together.

**What did NOT land, and must be said plainly.** Nothing is merged, so the AFTER number still does not
exist — that is `dr-w2-s8`, and it is deferred by design, not by failure. Nothing was proven ON THE BOX
this wave: every slice's evidence is hermetic. The durable record is durable but not yet READABLE — s1
deliberately exposes no HTTP read path, so the operator still cannot fetch a build log; that read path
is the obvious next slice and it is now unblocked by s4. And the scrub fix was measured against a
SOURCE-CODE proxy corpus, not the real `failure_reason` column (charter D13's real replay is still owed).

**Review fixes made in place** (four commits across three `-r` branches):
1. **s1** — `write_terminal_record/2` named the record from `<slug>-<tag>` while every eviction resolves
   it from the LOG's stem. For a pre-change manifest those diverged, so evicting that log wrote an ORPHAN
   tombstone beside the real record and the read answered `:missing` where the truth was `:evicted` — the
   exact conflation the slice exists to remove.
2. **s1 × s2, the cross-slice fix** — s2 added `{:swap_aside_failed, _}` and `{:lock_aborted, _}` to the
   provisioner's error vocabulary in the same wave; neither had a `describe_provision_reason/1` clause, so
   both would have reached the operator as Elixir tuple jargon through the brand-new
   `site_provision_failed` body. That is the wave's own narrowing, one wave later, in a new spelling.
3. **s3** — the poll loop's typed-5xx exit was the one terminal path that dropped the graced-refusal note,
   so "grace never hides" was false on exactly the path where a real fault follows transient blips.
4. **s4** — Fix B reached the key clause past `_`, which put every `*_token`/`*_password` identifier in a
   captured stack trace inside its reach, and `=` is not in the value's stop set: `hashed_password == before`
   rendered `hashed_password =[redacted] before`. A comparison is not an assignment. Two negatives pin it
   and both red without the guard. The slice also left its test table unformatted; `mix format` run.

**Ledger.** All seven slice tasks sit `in_progress` with honest evidence stamped as the builders worked
and merge-gated criteria correctly left open for the lead. No overclaims found — every `--miss` this wave
is a real miss with a stated reason (s1's OOM/tee probe, s4's real-corpus replay, s6's PR-body pair, s7's
live probe). One omission repaired: `dr-w2-s2-verify-capstone-selfheal-live` — the builder tried eight
times to file it and guerrilla's `/v1/data/mutate` was 500ing throughout, so the reviewer filed and
published it. Five other follow-ups were already filed and published against the epic.

**Merge order matters.** s2 → s6 (s2 makes capstone build, s6 makes its slow render a SLOW verdict instead
of a false BROKEN; merging s2 alone leaves capstone red at HEALTH) → s1 (it names s2's two new error
shapes, so it is coherent only after s2) → s4 → s3 → s5 → s7. **s7 and s4 are both HIGH-FLIP-RISK and both
are owed a genuinely independent second reviewer before merge** (D35 assigns this wave's ONE spawned
reviewer to s7; the s4 second pair of eyes is a MANUAL LEAD STEP). s6 is the wave's one deliberately
PERMISSIVE change — a site taking up to 90s to first-200 now goes LIVE with a SLOW verdict.

**Next wave takes:** the read path for the durable record (s1 shipped the data, nothing reads it — that is
the "figure out typical deployment issues" clause still half-open), then `dr-w2-s8` the moment s2+s3+s6
are merged AND deployed, then the live proof on the box (`dr-w2-s2-verify-capstone-selfheal-live`,
`task-7059f3bf9fdd37cf`'s quiet-box re-measurement of the 8s/90s constants), then the two audits this wave
named but did not take: `dr-w2-s7-followup-scoped-media-public-read-audit` (P1, the scoped media surface
and `/v1/graph`'s second copy of the visibility predicate) and `dr-w2-s4-followup-raw-log-order` (P1, the
raw-log read path still scrubs before stripping ANSI).

### Wave 2026-08-06 (wave 3) — REVIEWED · Paper `deploy-reliability-wave-2026-08-06` · grade **A−**

**Four of seven slices built, reviewed, gate-green, PUSHED and PR'd. The other three are round 2 BY
DESIGN** — `s5` (the `box_at_capacity` door refusal) waits on s1+s2 merging, `s6` (control-plane + CLI
render) on s4, `s7` (`strained` at rank 5) on s4+s6. Nothing merged: the lead merges.

**What landed.**

| Slice | Final branch | PR | Verdict |
|---|---|---|---|
| `dr-w3-s1` | `loop-epic/search-capstone-s-25-identical-failures--1` | **#9729** (updated in place) | Five stale `.sobelow-skips` rows replaced by five inline waivers with TAILORED reachability paragraphs; the provision describer moves in beside its producers. Gate re-run green end to end; the waivers independently mutation-proved. |
| `dr-w3-s2` | `loop-epic/the-durable-build-log-is-keyed-on-the-de-0-r` | **#9727** (updated in place) | The two unreachable describer clauses deleted (the single cause of all four Elixir reds), then the REAL second red found on CI: one-second mtime resolution let `File.ls/1` order decide which build log was evicted. Fixed with a total `recency_key/1`. **Review added the same fix to `prune_terminal_records/2`**, which carried the identical bug on the tombstones that make an evicted deploy read `:evicted` rather than `:never_recorded`. |
| `dr-w3-s3` | `loop-epic/the-deferral-taxonomy-stops-being-reason-2` | **#9783** | The deferral taxonomy stops matching `status` alone; `BOX_AT_CAPACITY_DEFERRED` + `DEFERRED_UNCLASSIFIED`; the chain bound is cause-aware; the requeue-failure arm settles `failed` instead of a lost publish wearing "re-queued, not lost". Reviewer re-derived the numerator judgment independently and concurs. |
| `dr-w3-s4` | `loop-epic/the-agent-measures-what-the-box-is-actua-3` | **#9784** | Swap (with its companion total, so swapless ≠ unmeasurable), `PGSizeProbe` finally WIRED after 25 days dark, a named top-10 relation breakdown, and the BEAM's own PSS/swap. **Review closed the builder's biggest stated unknown** by running the exact psql argv against a live PostgreSQL 17 — the output shape is confirmed, not reasoned. |

**What did NOT happen, stated plainly.** Nothing this wave changes anything the owner can see yet. `s4`
measures into a drawer until `s6` renders it; the `box_at_capacity` code `s3` classifies has no producer
until `s5` ships it. Both are sequenced-round consequences, not misses — but the wish is not served until
round 2 lands.

**The one thing the lead must not get wrong: MERGE #9727 BEFORE #9729.** Both branches carry
`describe_provision_reason/1` + `format_posix/1` + `redact/1` in the same region of `deploy_runner.ex`, so
whichever merges second conflicts. In THIS order the resolution is one hunk, "take #9729's side", and the
result compiles because #9729 brings the producers. In the reverse order #9727's deletion commit removes
two clauses `main` has just started needing.

**Next wave takes:** round 2 in dependency order — `s5` the moment #9727 and #9729 are on `main`, then
`s6` once #9784 is in, then `s7` behind both AND behind an agent release that has actually beaten swap
home (a merged `internal/**` change is not a deployed agent). Then `dr-bl-beam-memory-readable-then-bounded`
(P0, D39's real fix: read `:erlang.memory()` before guessing a `MemoryHigh`), and the follow-ups this wave
filed: `dr-w3-s3-followup-capacity-code-handshake`, `dr-w3-pg-probe-url-in-argv`, and
`dr-terminal-record-prune-tie-order` (fixed in review, rides #9727, criterion 2 closes on the first Linux CI run).

---

## Wave 3 — 2026-08-06 — "The box can say no, and the fleet can see why"

Wave 3's own headline move was **refuted by measurement before a builder flew**. The wish asked for a cap
on concurrent site builds and for Cloud-side diagnosis. Half of that is already law; the other half is
aimed at the wrong consumer. Both corrections are recorded here as decisions, because the next wave will
otherwise re-derive the same wrong premise from the same wish.

- **D37 — THE FLEET BUILD CAP IS ALREADY BUILT, ALREADY LAW, AND PROVEN HOLDING LIVE. Do not build it.**
  *Why:* `deploy/lib/site-deploy-common.sh` on `origin/main` carries a fleet-wide build admission gate —
  `BUILD_GATE_SLOTS=1` (:282), `BUILD_GATE_WAIT_DEFAULT=900` (:289), `flock -n 7` fast path (:326) then
  `flock -w "$BUILD_GATE_WAIT" 7` (:334), fd-7 form so the kernel releases on SIGKILL, explicit fail-OPEN
  warnings, and a self-test whose mutation deletes `build_gate_release` and proves the slot leaks. It
  merged 2026-07-30 as `3e27a4915` ("one box, one build", #7868) and BOTH engines call it
  (`site-deploy-node.sh:1628`, `site-deploy.sh:1991`). Proven holding by run on guerrilla 2026-08-06
  08:55-09:00Z: **three sites deploying concurrently, exactly ONE `npm ci`, three processes parked with
  `fd7 -> /run/lock/barkpark-site-build.lock` in state S**, and the per-unit journal reading
  `BUILD started → the box's only build slot is busy — queueing up to 900s → fleet build slot acquired
  after queueing → npm ci`. The strategic direction's premise ("nothing bounds how many DIFFERENT sites
  build together") is FALSE, and has been for a week. A cap slice would ship a duplicate of existing law.

- **D38 — THE REAL HOLE IS QUEUE-NOT-REFUSE: the box's capacity answer never becomes a D9 counted
  deferral, and when the 900s budget lapses it becomes an UNCLASSIFIED TERMINAL failure — a lost publish.**
  *Why:* the box answers the deploy trigger `202` and the engine only meets the gate LATER, inside the
  unit. So `Sites.Deploy.start_on_box/6`'s `{:ok, 409, body} -> defer(...)` arm — the whole D9 seam —
  **can never fire for capacity**. `SiteDeployController` has exactly one 409 code, `already_running`
  (:91), emitted by the PER-SLUG `running_slug?/2`. Measured consequences, all live: 2-5 units sit
  `active running` while parked in `flock`, each burning its 30-minute `@default_run_deadline_ms`
  (armed at LAUNCH, before the engine ever reaches the gate) and holding that slug's single-flight slot,
  so a newer content rev for the same site 409s `already_running` against the reason-blind
  `@max_consecutive_deferrals 6`. On lapse the engine does `emit BUILD failed; exit 15`;
  `exit_label(15)` = `"gave up waiting for the deploy lock (exit 15)"` — which is also the label for the
  PER-SLUG lock, so the sentence names the wrong lock — and no `DeployLedger.classify/2` arm matches that
  prefix, so it falls to `UNCLASSIFIED` and `Deploy.poll`'s `:failed ->` arm makes it terminal.
  **HONEST BOUND: the lapse has NOT been observed in production** — no `exit 15` gate timeout is findable
  on the box. The slice is justified by the blindness and the burned units, which are happening
  continuously, not by the lost publish, which is a thin-margin future (5 units × 2-4 min builds ≈ 720s
  against a 900s budget).

- **D39 — THE BOX IS NOT SWAPPING BECAUSE OF BUILDS. THE KERNEL IS OOM-KILLING THE API, 34 TIMES IN
  14 DAYS. This reframes the whole wish, and no slice in this wave fixes it.** *Why:* measured on
  guerrilla 2026-08-06 08:50-08:58Z: `journalctl -k --since -14d` OOM victim census is **35 beam.smp,
  1 python3**; the running BEAM is 5h38m old on a box with 38 days uptime because it was shot at
  03:13:58 that morning; historical anon-rss at kill 2.62-3.30 GB. PSS budget (RSS triple-counts
  postgres shared_buffers): **beam.smp 1,528 MB PSS + 1,176 MB swap = 2,704 MB of a 3,819 MB box — 58%
  of all anonymous demand**, against a build in flight at 364 MB, postgres ~370 MB, eight serving slots
  ~586 MB. Total anonymous demand 4,620 MB; swap 95.5% full with 94 MB left. **Removing the build
  entirely still overshoots RAM by ~446 MB.** `barkpark.service` carries ZERO resource directives
  (`MemoryMax=infinity`) and runs `mix phx.server`, not an OTP release. Two candidate levers are
  REFUTED by measurement: retiring the three Caddy-unbound standby slots recovers **190 MB of swap and
  2.2 MB of RAM** (file it as swap hygiene, never as a memory lever); and the build is not the swapper
  (build processes held ~9 MB of swap while the box held 2,160 MB). **`MemoryHigh` on `barkpark.service`
  is the real fix and this wave DOES NOT SET IT** — `:erlang.memory()` could not be read (epmd empty,
  `bin/barkpark` has no `rpc` verb), so WHICH subsystem grows is UNPROVEN, and a guessed threshold trades
  periodic OOM kills for permanent reclaim stalls (PSI memory `full avg10` is already 4.46). This wave
  ships the MEASUREMENT (`beam_pss_bytes`, `beam_swap_bytes` from `/proc`); the bound is filed.

- **D40 — `attentionStatus()` IS BLIND TO PRESSURE, RE-PROVED BY RUN, AND THAT IS THE OWNER'S ACTUAL
  COMPLAINT.** *Why:* while guerrilla pegged CPU 100, load 8.08 and p95 16,345 ms against an `over_at`
  of 1000, `bp cloud status` returned `status "ok", rank 8, bucket "healthy"` — in the same minute the
  usage envelope was screaming. `internal/cli/cloud_status_cmd.go:50` switches only on
  `DeprovisionStatus / ProvisionStatus / Suspended / HealthStatus / AgentStatus / UpdateState`. Zero
  vitals inputs across all eight cases. The data, the vocabulary and the render all already exist in
  this repo and have never been connected.

- **D41 — THE NINTH STATE IS `strained`, IT SHIPS GO-ONLY, AND THAT IS MANDATORY UNDER OUR OWN D31 —
  NOT MERELY CONVENIENT.** *Why:* D31 reads *"this wave does NOT touch the console render path … the
  console half of the reader is deferred, the CLI half ships."* `internal/cli/cloud_status_cmd.go` IS
  the CLI half; `cloud/priv/static/app.js` is the ceded half. The cession is now BILATERAL: open PR
  #9705 (cloud-console-hardening wave 34) carries **D392**, which quotes our D31 back and claims the
  console render path, naming `cloud/priv/static/__app.test.mjs` as the only shared file. The four
  briefed "claimants" resolve: **cch-w34-s6 does NOT collide** (its file fence is exactly the three SPA
  files, zero overlap with `internal/cli`); **onb-w1-fleet-health-decompose does NOT collide** (its
  unpushed `7eb18297` adds ONE map key to `rankedBarkparkRow:196`, ~120 lines from `attentionStatus`);
  **dr-w2-s5 does NOT collide** (it fences `cloud_site_cmd.go`). **`jpf-w1-queue-age-alarm` IS the one
  real collision** — open, unclaimed, dark since 2026-07-31, and its criterion 2 inserts `deploy_stalled`
  at the identical rank-5 slot with the identical tail renumbering. **RULING: `strained` takes rank 5;
  `jpf-w1-queue-age-alarm` is DEFERRED behind it and must rebase to rank 6.** Ours is measured live on
  the box the owner is complaining about; jpf's has sat unclaimed for six days. The consequence is a
  DELIBERATE Go/SPA divergence — 9 states in Go, 8 in the SPA — which **no gate reds on** (proved by
  mutation: a nine-state fixture leaves `__app.test.mjs` byte-identical at 873/858/15). That divergence
  is correct under D31 and is recorded HERE so the next surveyor reads it as cession, not drift.

- **D42 — NO NEW `unmetered` ATTENTION STATE. The existing `degraded` arm already covers every box that
  cannot be read.** *Why:* the direction's sharpest self-attack was that promoting pressure into the
  triage vocabulary might promote a NULL. Measured: guerrilla beats REAL non-negative vitals home
  (cpu 0-100 hitting 100 in six of thirty minutes, load 0.47-6.73, mem 51-88, disk 74-76, beat age
  10-31s), and five of six barkparks are live-beating. The ONE unmetered box, muscle-1, has
  `beat.status "absent"`, `last_seen_at null`, all four series empty AND `agent_status "offline"` — so
  `live && b.AgentStatus != "online"` already ranks it `degraded`, in the attention bucket. A tenth
  state would add vocabulary for a population of zero. **`strained` therefore fires only on a POSITIVE
  reading crossing threshold; a nil or `-1` vital NEVER produces `strained`** — the honest "we cannot
  read it" is already spoken by `degraded`.

- **D43 — A CAPACITY DEFERRAL LANDED ON TODAY'S SEAM IS WORSE THAN NOTHING, AND THE FIX IS
  `DEFERRED_UNCLASSIFIED`, NOT `UNCLASSIFIED`.** *Why:* proved by mutation on an `origin/main` tree.
  `deploy_ledger.ex:185` is `def classify(%{status: "deferred"}), do: "BOX_BUSY_DEFERRED"` — status
  alone, never `stage`, never `failure_reason`. A probe asserting that FOUR distinct causes (a
  `box_at_capacity` refusal, the requeue-broken text, pure nonsense, and `nil`) all answer
  `BOX_BUSY_DEFERRED` **PASSED**. `UNCLASSIFIED` is structurally unreachable for a deferred row, so D8's
  "UNCLASSIFIED must be able to go up" is honoured for FAILED rows and violated for DEFERRED ones — the
  mirror of the 8,830-invisible-rows bug, one status over. Driven end to end through the real
  `Deploy.run`, six rounds of a literal `box_at_capacity` 409 produce
  `[:deferred ×5, :failed]` and the sentence *"…it has now refused 6 rebuilds in a row for this site, so
  the instance is not busy but stuck; check its deploy runner"* — a TERMINALLY LOST publish plus a false
  accusation against a runner working exactly as designed. `consecutive_deferrals/1` is reason-blind
  (`take_while(&(&1.status == "deferred"))`), so mixed causes accumulate on one counter. **Routing the
  unknown tail into `UNCLASSIFIED` is refused**: `UNCLASSIFIED` lives in `@classes`, and `@classes` rows
  ARE the failure numerator, so a healthy capacity refusal would inflate the deploy-failure rate — the
  mirror image of vacuous green, i.e. vacuous RED, corrupting the very measurement `dr-w2-s8` exists to
  take. The tail rises INSIDE the deferred cohort.

- **D44 — A THIRD DEFECT, PREVIOUSLY UNNAMED AND WORSE THAN THE OTHER TWO: the requeue-failure path is a
  SILENT LOST PUBLISH that nothing retries, and its "so the Oban job retries" justification is FALSE on
  the production path.** *Why:* `deploy.ex:1226-1230` rewrites `failure_reason` and `detail` and passes
  NO `status` key, so the row keeps the `deferred` status the previous transition set. It therefore
  classifies `BOX_BUSY_DEFERRED`, sits OUTSIDE the failure numerator, and carries the label *"the
  rebuild was re-queued, not lost"* while its own reason text says the opposite. Census probe: 6 genuine
  failures + 3 requeue-broken rows → `volume 9, failed 6, numerator 6`, deferred
  `[%{class: "BOX_BUSY_DEFERRED", count: 3}]` — three lost publishes, zero in the numerator. And
  `Deploy.run/1` is invoked ONLY from inside `Task.Supervisor.start_child` at `deploy.ex:1900`
  (`git grep "Deploy.run("` over `cloud/lib` returns that plus the `def start` delegate), so the return
  value is DISCARDED — there is no Oban job to retry. `git grep "could NOT be re-queued|
  deferral_requeue_failed"` over `cloud/test` returns ZERO: this path has never been tested. **This row
  must write `status: "failed"`** — it IS a lost publish and belongs in the numerator, the opposite
  direction from D43's tail.

- **D45 — SWAP IS THE ONE GENUINELY MISSING VITAL, AND THE EXISTING `mem` VITAL ACTIVELY UNDERSTATES
  THIS CRISIS.** *Why:* all 149 `swap` hits across `*.go`/`*.ex` are compare-and-swap or
  swappable-adapter prose; `MemorySwapMax` has zero occurrences repo-wide. Measured on guerrilla at the
  same instant: `SwapTotal 2097148 kB / SwapFree 2328 kB` = **99.89%, clamping to 100** — while
  `MemAvailable 1641988 of MemTotal 3911580` makes the SHIPPED mem vital report a comfortable **58%**.
  `MemAvailable` clears the floor precisely BECAUSE the BEAM has been paged out (independently corroborated
  at `tooling/pds/fixtures/live-corpus-2026-07-31.json:522`). That is the sharpest argument in the wave
  for shipping swap: the vital already in production is the one telling the reassuring lie. The probe is
  BUILT and mutation-proved; **the swapless branch returns `(0, 0, nil)`, NOT the `-1` sentinel**, and
  carries a companion `swap_total_bytes` so a consumer can tell "none configured" (total 0) from "0% of
  2 GiB" (total > 0) from "could not measure" (both -1) — a bare percent cannot carry three states.
  Copying `memProcProbe`'s `total <= 0 -> error` guard literally would turn every swapless box into a
  `-1`; that one line must diverge, with a named test whose failure message states the consequence.

- **D46 — `PGSizeProbe` IS DECLARED, CONSUMED END-TO-END, AND NEVER WIRED — so `db_size` has ALWAYS read
  "unmetered", and the database it is failing to measure is 3.24 GiB. The seam is SHELL-OUT, not HTTP.**
  *Why:* `report.go:187` declares it, `:261` folds it, `telemetry.ex` normalises it, `usage.ex:219`
  meters it, `cloud_usage.go:710` renders it — and `cmd/barkpark-agent/main.go` wires
  Disk/CPU/Mem/Load/ReqStats and NOT PGSize (`git show origin/main:cmd/barkpark-agent/main.go | grep
  PGSize` exits 1). Live proof: `bp cloud usage guerrilla` returns
  `db_size: {"value":"unmetered", "source":"telemetry.pg_size_bytes"}` while `pg_database_size` returns
  **3,477,617,687 bytes in 0.143s**. There is NO Postgres driver in `go.mod` (no `lib/pq`, no `pgx`), so
  the probe must shell out or ride HTTP. **SHELL-OUT is chosen**: the HTTP seam needs a new `api/` route,
  which drags `openapi.json` regeneration that cannot be run locally and reds the api gate. The
  shell-out's cost is that it is proven on guerrilla ONLY (ssh host-key verification failed on gyl and
  jarl, and `known_hosts` was correctly not touched), so five boxes may keep reporting `-1` — which is
  EXACTLY what they report today, so there is no regression, only an un-uniform improvement. **And the
  per-relation breakdown is free**: top-10 `pg_total_relation_size` costs 0.145s, the same order as the
  bare total, and NAMES the consumers — `mutation_events 1.51 GB + revisions 1.31 GB = 81% of the whole
  database`. A named breakdown obtained in 145 ms with no tree walk is strictly better than the total
  the pipeline was built for. **Retention on those two tables is a DATA-LOSS decision outside this
  wave's fence** — wire the meter, do not let the same slice touch retention.

- **D47 — THE THREE-HOUR CPU RUNAWAY WAS A JOURNALCTL UNIT GLOB, NOT A `du`, AND A `du` OVER THE SITES
  TREE IS AFFORDABLE. The bound is a LIFETIME bound, not a cadence.** *Why:* `task-e05c4e4cea2282e5`
  records `journalctl -u bp-site-build-* --since -14d --no-pager`, PPID 1, orphaned into a dead pipe —
  a journal CONTENT scan whose glob matched no unit. Re-measured this wave: exact unit **0.276s**, glob
  **hangs past 120s**, `--disk-usage` **0.086s cold / 0.01-0.04s warm** (a header read). And measured on
  guerrilla WHILE load was 7.4-8.6, swap 99% consumed and a build running: `du -x --max-depth=2` over
  `/opt/barkpark/sites` = **4.34s cold, 1.11s warm**; `find` over 153,129 inodes = 4.45s; per-slug
  `du -sh` over 30 paths = 1.20s. Only a full-rootfs walk is expensive (22.16s). So the "slow cadence"
  premise is over-conservative at this tree size — but the LIFETIME bound (timeout + kill, `nice -n 19
  ionice -c3` per the existing `BP_NICE` precedent) is mandatory, because the incident was an unbounded
  lifetime, not an expensive command. **The sites tree is also not the space story**: root is 27.4G used
  of 38G, of which `/var` is 10.2G (journal 3.9G + postgres 3.5G), `/opt` 5.9G (sites 4.0G), `/root`
  4.4G, `/tmp` 2.2G. Sites is 15%. And its gigabytes are `src/node_modules` (~2.9G) and `src/.next` —
  load-bearing build caches whose deletion forces a cold `npm ci` on the box that is swapping.
  Reclamation and the cap pull in OPPOSITE directions.

- **D48 — THE JOURNAL IS NOT A LEVER AND ITS CAP STAYS ORDERED BEHIND THE BACKFILL — but D21's stated
  backfill GATE is refuted.** *Why:* `/etc/systemd/journald.conf` on guerrilla is a bare `[Journal]`
  stanza with every directive commented and no `journald.conf.d/`, so the 3.7G is systemd's
  compile-time default `min(10% of 38G, 4G)` doing its job — a policy nobody chose. It is 14% of used
  disk on a box with 9.0G free, so capping it buys at most ~2G on the wrong axis. Retention measured
  8.84 days (oldest entry 2026-07-28T12:37:58Z), and the oldest edge advanced only ~6h51m in 24h — the
  window is WIDENING, not collapsing, so D21's "every day of delay drops the oldest failures" is
  directionally true at ~7h/day, not 1 day/day. **D21 says backfill is "gated on the row persisting
  `unit_name` at launch"; `git grep unit_name origin/main -- cloud` returns ZERO hits, so the gate is
  genuinely unmet — but it is also unnecessary**: unit names are already build_id-keyed
  (`bp-site-build-<slug>-<build_id>-<epoch_ms>.service`), `journalctl -F _SYSTEMD_UNIT` enumerates
  **9,634 retained build units** cheaply, and a backfill can resolve any Deployment row by prefix-matching
  slug+build_id. The backfill is therefore a standalone extraction needing no schema change and no
  recorder — filed, not built.

### Slice-zero correction, and the merge order it implies

The direction mislabelled BOTH owed PRs, in both directions. **#9727 is `dr-w2-s1`** (the recorder), whose
FOUR Elixir reds have ONE cause — two dead `describe_provision_reason/1` clauses at
`deploy_runner.ex:675/:682` under `--warnings-as-errors`. The briefed "CI Postgres container re-init" is
**REFUTED**: the log reads `postgres service is healthy.` at 02:56:01Z, `initdb` ran in full, and the six
`FATAL: role "root" does not exist` lines are the bare `pg_isready` health probe firing on its 10s
interval — the repo-wide pattern, green in four other workflows. Zero tests ran because compile precedes
`mix test`. **#9729 is `dr-w2-s2`** (the provisioner swap-then-unlink wedge), whose red is five STALE
`Traversal.FileModule` baseline anchors line-shifted by its own edits. And **#9729, not #9727, gates the
after-measurement** (`dr-w2-s8` names s2, s3 and s6 by slug; s1 is not in the chain).

The two PRs are COUPLED and neither can go green alone: #9727 pre-landed #9729's *describer* while #9729
holds the *producers* (`provisioner.ex:202` `{:lock_aborted, slug}`, `:240` `{:swap_aside_failed, reason}`).
Mutation-proved: adding one producer drops the warning count 2 → 1, leaving exactly the un-produced shape.
**Ruling: the two describer clauses move to #9729, beside their producers.** #9727 then compiles with a
9-line deletion and chains on nothing; #9729 compiles because it has both halves.

**Also corrected: #9729 is NOT mechanically merge-blocked.** Live branch protection requires exactly four
contexts — `Elixir gate`, `PR references an active task`, `Cloud gate`, `Console gate` — and **all four
PASS on #9729** with `mergeable: MERGEABLE`. `Security gate` is held out by decision S7 and the Sobelow
static-analysis job carries `continue-on-error: true`. The red that reached `Security gate` came from the
genuinely blocking `sobelow-inline-overlap` job's staleness step. The fix is still worth landing, because
normalising that ratchet's red is how ratchets die. **And the briefed MUST-RUN script paths are wrong**:
both scripts live at `api/scripts/`, not `scripts/`.

### Wave 3 plan — 7 slices, 4 in round 1

| # | Slice | Round | Model | Surface |
|---|---|---|---|---|
| s1 | #9729 goes green: inline sobelow waivers + the describer moves in beside its producers | 1 | opus | `api/lib/barkpark/sites/`, `api/.sobelow-skips` |
| s2 | #9727 goes green: the dead describer clauses come out, and its tests run for the first time | 1 | opus | `api/lib/barkpark/sites/deploy_runner.ex` |
| s3 | The deferral taxonomy stops being reason-blind, and a lost re-queue stops calling itself a deferral | 1 | fable | `cloud/lib/barkpark_cloud/` |
| s4 | The agent measures what the box is actually short of: swap, db size + top relations, BEAM footprint | 1 | fable | `internal/agent/`, `cmd/barkpark-agent/` |
| s5 | The box refuses at the DOOR with a typed `box_at_capacity`, and its build scope stops swapping | 2 (after s1, s2) | fable | `api/lib/barkpark/sites/`, `api/lib/barkpark_web/controllers/` |
| s6 | The control plane and the CLI render the three new numbers | 2 (after s4) | opus | `cloud/lib/barkpark_cloud/`, `internal/cli/` |
| s7 | `strained` reaches the triage vocabulary — Go-only, rank 5, under the D31 cession | 2 (after s4, s6) | fable | `internal/cli/`, `cloud/priv/static/__fixtures__/` |

**HIGH-FLIP-RISK slices, owed a genuinely independent second reviewer before merge (a MANUAL LEAD STEP —
this workflow spawns exactly ONE reviewer):** s3 (whether the unknown deferral tail belongs inside or
outside the failure numerator — the wrong call corrupts `dr-w2-s8`'s measurement), s5 (the race between
the door's `flock -n` check and the unit's own acquire — the in-engine flock MUST survive as the
last-resort correctness barrier), s7 (the deliberate Go/SPA divergence, which no gate reds on).

**What this wave does NOT promise.** D28 keeps the pool repair outside this epic and D39 puts the real
memory fix behind a measurement this wave only makes possible. The 76× HTTP 500 class may or may not fall.
That is a MEASUREMENT `dr-w2-s8` takes once s1/s2 and wave 2's s2/s3/s6 are merged AND deployed — never a
promise this wave makes.

---

## Wave 4 decisions (2026-08-06) — Paper `deploy-reliability-wave-4-2026-08-06`

Wave 4 opens the pipe ONCE and pushes all three of the wish's answers down it. Verification refuted
three inherited premises by run; where it did, the evidence wins and the superseded decision is
amended HERE rather than silently re-cited.

- **D49 — THE AGENT IS NOT THE BREAK; THE FOLD IS. "Merged is not measuring" was true and is now
  DISCHARGED — the second break is `normalize/1` + `@vitals`, and it is TWO modules.** *Why:* the
  restart was performed and the pipe watched end to end. Guerrilla's binary was rebuilt at
  11:39:45Z but the PROCESS ran from a **deleted inode** for 29 hours
  (`/proc/3026335/exe -> /usr/local/bin/barkpark-agent (deleted)`, `ExecMainStartTimestamp` 29h
  older than the file). After `systemctl restart` at 11:45:19Z the cutover is exact and leaves no
  room for a confounder: `11:44:56Z swap=ABSENT beam_pss=ABSENT pg_top=ABSENT` →
  `11:45:23Z swap=51 beam_pss=1843045376 pg_top=n=10`. All 20 keys persist at the control plane,
  and `pg_top_relations` already names `mutation_events` 1.53 GB + `revisions` 1.33 GB = **81.3% of
  the 3.52 GB database, measured, at the CP, today**. Ingest is confirmed free-form: the router does
  `Registry.record_event(barkpark, "health", report)` on `conn.body_params` with **no whitelist**, so
  any later fold is retroactive over the whole retained window. Yet `bp cloud instance top guerrilla`
  still renders series `['cpu','disk','load','mem']`. `Telemetry.normalize/1` builds a fixed literal
  envelope; `Metrics.@vitals` is a fixed 4-tuple and `series/1` is `Map.new(@vitals, …)`, so the key
  set is *definitionally* closed. A repo-wide grep for the four field names across `cloud/` and
  `internal/cli/` returns **zero hits**. **CONSEQUENCE FOR SLICE ORDER: the fold no longer depends on
  any agent work.** It can be built and verified against live stored payloads immediately, via
  `GET /v1/barkparks/:id/events`, which serializes `payload: e.payload` UNFILTERED.

- **D50 — THE DEPLOY DEFECT IS ONE WORD, WITH AN IN-FILE PRECEDENT, AND THE `--health-token` TRAP IS
  REFUTED.** *Why:* `instance-deploy.sh:821` uses `systemctl enable --now barkpark-agent`, which does
  **not** re-exec an already-active unit. The correct pattern already exists 30 lines below at
  `:851-853` for `barkpark-mcp` and states the reason in its own comment verbatim (*"restart (not just
  enable --now): an already-running unit must pick up the"*). The briefed trap — that the committed
  unit lost `--health-token` so a bare restart would break the health probe — is **FALSE**: a drop-in
  ALREADY EXISTS at `/etc/systemd/system/barkpark-agent.service.d/health-token.conf` overriding
  `ExecStart=`, which is *why* the running cmdline carried the flag. The restart was performed and the
  post-restart beat reports `service_health {total: 7, pass: 7, failing: []}`. **The slice installs NO
  drop-in; it changes one word.** *Two hazards recorded, both filed not built:* (a) `--health-token`
  appears exactly ONCE repo-wide (the flag definition at `cmd/barkpark-agent/main.go:48`) — no unit,
  provisioner or script ever passes it, so guerrilla is a hand-patched snowflake and every OTHER box
  runs with an empty health token, making `req_per_s`/`p95` unmetered by construction; (b)
  `deploy.yml`'s instance filter is `^(api|internal|deploy|connectors|templates)/` and **excludes
  `cmd/`**, so a `cmd/`-only PR deploys the control plane and never touches guerrilla. That hole is
  LATENT — it did not cause this incident, because #9784 also touched `internal/agent/report.go`.
  **AND THE LEAD'S GATE INSTRUMENT IS BROKEN:** `strings … | grep -c '^swap_used_percent$'` returns
  **0 on a binary that fully contains the field** — Go packs struct tags into one contiguous printable
  run, so `^…$` anchors never match. Unanchored `strings -n 6 | grep -c` returns 1 on the same binary.
  Any re-run of that gate must drop the anchors or it reads a false red.

- **D51 — SUPERSEDES D45'S TRIGGER ARM: SWAP CANNOT BE THE FENCE. IT IS NON-SEPARATING, AND IT IS
  STRUCTURALLY BLIND ON FIVE OF SIX BOXES.** *Why:* D45 survives intact as a *diagnostic* — its real
  argument, that `mem` tells a reassuring lie while the BEAM is paged out, is still true and still
  worth shipping. It dies as a *trigger*, on three independent measurements. (1) **Anti-correlation:**
  a paired 4-minute series on guerrilla ran swap **49.2% → 46.2%** while load1 rose **0.94× → 2.90×
  per core** — occupancy moved the *wrong way* against pressure. `parseSwapPercent` reads
  `SwapTotal`/`SwapFree`, an occupancy **stock**, not `si/so` flow; `vmstat 1 3` at 49.2% showed si/so
  settling to `0 0` with 1.12 GB free RAM. Swap occupancy is a scar, not a vital sign. (2) **No
  separating band:** the live incident hour ran at **58%** swap while D39/D45 fitted at 95.5%/99.89%
  and the box idles at 46-49% — any fence low enough to catch the incident fires on an idle guerrilla,
  and the only viable band is ~9 points wide. (3) **Blind on the fleet:** all six barkparks were
  ssh'd; **only guerrilla has swap configured**, the other five report `Swap: 0 0 0`. A swap arm is
  therefore false-positive-free only because it cannot see 5/6 of the fleet.

- **D52 — THE FENCE IS LOAD-PER-CORE, SUSTAINED, AND IT REQUIRES A NEW AGENT FIELD. THE HARDCODED
  FALLBACK IS REFUSED.** *Why:* over 200 points × 5 reporting boxes (08:27-11:46Z), `load1/cores ≥ 2.0`
  on **≥2 of the last 3 beats** fires 184/198 on guerrilla and **0/198 on every other box — zero false
  positives across 800 healthy-box-points**. The healthy ceiling is 1.24× (dooodo) and guerrilla's own
  floor in-window is 1.56×, so the fence sits 0.76× above anything the fleet did all morning with no
  overlap. The CPU arm is NOT FP-free (`cpu ≥ 90` fires 2/200 on gyldendal) and is dropped; sustaining
  2-of-3 costs 5 firings (184 vs 179) and removes single-beat spikes. **The denominator does not exist:
  the agent `Report` has no `cpu_cores` field**, and `barkpark.server_type` is a nullable *launch pin*,
  not observed truth — wrong or empty on adopted boxes. So the fence needs `runtime.NumCPU()` on the
  beat. **The interim `load1 >= 4.0` fallback is REFUSED**: it is numerically identical today ONLY
  because all six boxes happen to be 2-core, and it is a hardcoded assumption about the fleet's shape
  that goes silently wrong the first time someone launches a 4-core box. Swap ENRICHES the reason
  string and never triggers it — `load 5.5 on 2 cores (2.7×) · 1.0G in swap`, and **"none configured"**
  on the five swapless boxes, never 0%. The reason string must NOT say "CPU": load1 counts
  uninterruptible-sleep, so an I/O-bound box is honestly *load*, not *CPU*.

- **D53 — `strained` MEANS PRESSURE, NOT SPACE. THE DISK ARM IS DECLINED AND FILED.** *Why:* jarl
  reports **disk 95% for all 200 points** and ranks `healthy / ok / rank 8` — a real second silent
  condition, on the wish's clause-1 axis, and adding `disk ≥ 90` to the fence is free. It is declined
  anyway: it widens one word from pressure to space and makes `strained` mean two things, which is how
  a vocabulary rots. Space gets its own answer through the space slice's own rendering. jarl's case is
  filed with its measurement attached, not silently dropped.

- **D54 — AMENDS D42: THE FACTUAL ARM HOLDS VERBATIM, THE RULING ARM IS DEAD — KILLED BY A MERGE, NOT
  BY AN ARGUMENT.** *Why:* D42's factual arm — *a nil or `-1` vital NEVER produces `strained`* — is
  kept word for word; it is what makes a stale agent degrade to honest silence rather than a false
  alarm. Its ruling arm — *"the existing `degraded` arm already covers every box that cannot be read"* —
  was measured on Go alone and is **false of the console since 2026-08-06T11:46:59Z**, when #9788
  merged and shipped a ninth SPA state `unreported` at rank 5. The contradiction is LIVE in production:
  `bp cloud status` calls muscle-1 `degraded / rank 4 / attention` while the deployed console
  (7 occurrences of `unreported` in `curl https://barkpark.cloud/app.js`, HTTP 200) calls the same box
  `unreported / rank 5 / "Never reported"`. Two surfaces, contradictory words, about one box, today.
  D42 must be AMENDED here, not cited, or a builder reads it as licence to leave Go saying `degraded`
  about a box the console calls "Never reported".

- **D55 — SUPERSEDES D41 ENTIRELY. IT IS REFUTED THREE WAYS AND UNSHIPPABLE AS WRITTEN.** *Why:*
  (1) **"No gate reds on" is FALSE, proved by mutation in both directions.** A Go-only ninth state reds
  `cloud_status_cmd_test.go:93` (`fixture has 8 states, code has 9`) AND, on the full package,
  `:232` (`row 2 = ok-box/ok/rank 9, want rank 8`). A fixture-only ninth state reds the mirror
  (`fixture has 9 states, code has 8`). D41's parenthetical measured the **node harness**, which is
  structurally blind — `grep -rn attention_order` returns ZERO hits in any `.mjs`, and the harness
  asserts `attentionRank`/`bucketOf` against its own inline array. Its cited counts are also not
  reproducible: origin/main runs **887 tests / 887 pass / 0 fail** (re-run this wave in a clean
  worktree), not 873/858/15, which was an extraction artifact. (2) **Rank 5 is TAKEN.** #9788 merged
  and is deployed. (3) **It cannot be Go-only under any reading**, because D52 puts the fence's
  denominator in `internal/agent` and its input in the fleet payload.

- **D56 — THE RANK-5 RULING, COVERING ALL FOUR CLAIMANTS AND BOTH SURFACES. ORDERING IS BY LAW, NOT BY
  ARRIVAL.** *Why:* D332(b) — inherited via cch D386 and cited by cch-w34-s6's OWN shipped comment — is
  `failed > unknown > pending > ok`. `strained` is a **measured** condition; `unreported` is the
  **unknown**. A measured condition must outrank an unknown one. **THE LADDER IS:**
  `1 removal_failed · 2 failed · 3 suspended · 4 degraded · 5 strained · 6 unreported · 7 behind ·
  8 removing · 9 provisioning · 10 ok`, buckets **attention ≤6, in-flight 7-9, healthy 10**.
  The four claimants resolve: `unreported` is an **incumbent**, not a claimant; `strained` takes 5;
  `cch-w34-bl-go-twin-unreported` is a **PREREQUISITE, not a competitor** — it is the Go half of
  `unreported`, in the same function and the same fixture, and without it Go and the shipped console
  can never agree, so it is FOLDED INTO the same slice; `jpf-w1-queue-age-alarm` stays DEFERRED and
  must rebase to rank 7+ (it is blocked anyway behind `jpf-w1-push-cp-lane`, whose claim expired
  2026-07-31). **This requires exactly ONE SPA edit and D31 is AMENDED bilaterally to permit it:** the
  grant is precisely `ATTENTION_RANK`, `bucketOf`'s two thresholds, and `__app.test.mjs`'s `KINDS`
  array — roughly five lines, **zero render change**. D31 cedes *"the console render path"* and names
  `deployConsoleHtml` (app.js:11637) and `deployDetailHtml` (:10763); a rank integer is not a render
  path. The rejected alternative was `strained` at rank 6, behind `unreported` — refused because it
  records an accepted D332(b) violation, putting a measured condition below an unknown one, to dodge a
  five-line edit.

- **D57 — `cloud/priv/static/__fixtures__/attention_order.json` IS OURS, NOT CEDED — AND IT IS ALREADY
  DRIFTED ON MAIN, WITH A REQUIRED GATE REPORTING GREEN OVER IT.** *Why:* the fixture's **only** machine
  reader is Go (`cloud_status_cmd_test.go:67`, `table.go:277`, `cloud_verify_cmd_test.go`); zero
  `.mjs`/`.ex`/`.js` readers exist. Neither cession text names it: D31 names the two `app.js` render
  functions, and cch's own **D392** states *"The only file both epics open is
  `cloud/priv/static/__app.test.mjs`."* The jarl-platform charter already records the same fact
  (*"today Go is the fixture's ONLY asserter"*). So D41's "Go-only" LABEL was wrong while its FILE FENCE
  was right. **The drift is live: the fixture says 8 states with `behind` at 5; the shipped `app.js`
  says 9 with `behind` at 6, and nothing catches it** — proved by mutation (making the fixture honest
  about the console REDS the Go gate, while the node harness stays 887/887/0). **Two mechanical traps
  the slice must absorb:** (a) **VACUOUS TRUE** — the fixture dispatches `true` into BOTH the Cloud gate
  and the Console gate (because `cloud/priv/static/**` leads `CONSOLE_PATHS`), so two *required* gates
  RUN expensive jobs and report green having asserted nothing on it, while `go-tests.yml`'s paths
  exclude `cloud/**` entirely — a fixture-only PR runs **no Go suite at all**. Any slice touching
  `__fixtures__/` MUST also touch a `.go` file in the same PR or the only working guard never fires.
  (b) **THE TONE HOLE** — the guard hard-checks `Glyph`/`Label` non-empty but **not `Tone`**, so a ninth
  state with `tone:""` on both sides ships fully green and uncoloured. One-line fix at
  `cloud_status_cmd_test.go:109`, made a criterion of the same slice. **The ladder repair is ONE diff:**
  fixture-alone reds the Go gate, Go-alone silently re-drifts. There is no partial landing.
  `cloud/priv/static/__preview__/scenarios.mjs` is a THIRD file in this neighbourhood that neither
  charter names — its cession status is left OPEN and filed, not decided by a builder.

- **D58 — SPACE RIDES ITS OWN EVENT TYPE AT A SLOWER CADENCE, AND THE PER-SLUG LIST IS CAPPED. THE
  UNCAPPED SHAPE HAS A MEASURED CLIFF.** *Why:* the wire bytes are a non-issue (a 30-slug beat is 3.1 KB
  against Plug's 8 MB default, and `Plug.Parsers` sets no `:length`). The cliff is **Postgres's 2032-byte
  `TOAST_TUPLE_THRESHOLD`** against the *compressed jsonb*. Measured on PG 17.9/pglz with realistic
  high-entropy slugs, the crossover is **between 20 and 25 site slugs** (20 → 1968 B inline, 25 → 2114 B
  TOASTed). Past it, a 14-day window per box goes **34 MB → 58 MB** with heap collapsing to 2 MB and
  TOAST becoming 53 MB, and a 200-point metrics read goes **46 buffers / 3.8 ms → 637 buffers / 9.6 ms**
  — 13.8× — because `GET /v1/barkparks/:id/metrics` pulls up to 200 payloads per chart. **QUOTE THE
  ENTROPY NUMBER, NEVER THE TEMPLATE ONE:** with repetitive template slugs pglz is so effective that 30
  slugs stays inline and the crossover looks like ~100. The comforting number is the wrong one.
  Guerrilla has 10 sites today — safe, but only by 2×. **RULING, both halves:** (a) space is posted as a
  **separate event type on a slower cadence**, not on the 60 s health beat — `metrics.ex:80` keeps only
  health beats, so a space row is never detoasted by a chart render at all; (b) the per-slug list is
  **capped at top-10 by bytes** (10 slugs = 1685 B compressed, comfortably inline), which is exactly what
  the wish asks for — *the site you would act on is named*. #9784's own additions cost **+622 B/beat**
  and **zero measurable retained storage** (34 MB either way), so they need no bound. **And the inherited
  "`agent_events` has no pruner" premise is STALE:** `AgentRetentionWorker` exists (14 d events, 30 d dead
  tokens, 14 d usage samples) and is scheduled `{"30 3 * * *"}` at `config.exs:298`, with `runtime.exs`
  overriding only `:queues` so Cron survives. Azure D30 was resolved by D48. **NOTE THE TWO DATABASES ARE
  DIFFERENT BOXES:** `mutation_events`/`revisions` are guerrilla's CONTENT db (`Barkpark.Repo`);
  `agent_events` is the CONTROL-PLANE db (`BarkparkCloud.Repo`). Conflating them aims the footgun at the
  wrong database.

- **D59 — THE SPACE PROBE'S BOUND IS A LIFETIME BOUND AND ITS ARGV MUST BE DIRECT. `sh -c` BLOWS THE
  BOUND BY 44× WITH AN INDISTINGUISHABLE ERROR.** *Why:* D47's ruling stands and is re-confirmed —
  `du -hx -d1 /opt/barkpark/sites` measured **2.03 s cold / 0.36-0.39 s warm** at load 5.49 on 2 cores,
  a 0.6% duty cycle against a 60 s beat, so the sub-cadence class is unneeded scope. Two corrections to
  the briefed reasoning, one of which is load-bearing. (1) The premise that `timeout(1)` fails to kill
  through `sh -c` is **FALSE** — GNU coreutils 9.4 `timeout` puts the command in a new process group and
  signals the *group* (measured: `timeout` PGID 4044479, grandchild `du` PGID 4044479); only
  `--foreground` leaks. (2) **The real hazard is Go's `exec.CommandContext`, which is exactly the seam the
  probe will be written against.** `runBounded` (`internal/agent/report.go:160-168`) kills only
  `cmd.Process` — no group kill — and then `CombinedOutput()` **blocks in `Wait` until the orphaned
  grandchild closes the inherited stdout pipe**. Measured with the real `du` and a verbatim copy of
  `runBounded`: direct argv under a 200 ms bound returned at **200 ms**; `sh -c "…; echo done"` under the
  same bound returned at **8.77 s — 44× over budget** — and **both returned the identical
  `err=signal: killed`, so a caller cannot tell the bound was blown.** The rule therefore survives for a
  sharper reason than the one briefed, and it forbids not just `sh -c` but pipes, `2>&1` redirections and
  `; echo rc=$?` inside any probe argv. (3) **A killed `du` emits PARTIAL output** — a 3 s bound printed
  5 site rows then `rc=137`, and the Go direct-argv case returned 82 bytes after its kill — which parses
  as a perfectly plausible list that is silently missing half the tree. **Any non-zero exit must DISCARD
  and report unmeasured, never partially land**; under-reporting space is precisely the failure the wish
  names. (4) The sites root is `BARKPARK_SITES_DIR`, default `/opt/barkpark/sites` — but the agent's own
  environ carries only `BARKPARK_CONTROL_URL` and `BARKPARK_HEALTH_URL`, so an env-read probe silently
  falls back on every box. The probe must **report which directory it read**, so a wrong root is visible
  rather than silent.

- **D60 — THE DOOR SHIPS; `flock -n` MUST NOT. THE CENSUS IS THE SERIALIZED GENSERVER, THE SECOND
  OPINION IS `/proc/locks`, AND THERE IS A FIFTH FILE THE SLICE DOES NOT LIST.** *Why:* both blockers are
  gone — **#9727 MERGED 11:31:45Z** (squash `9edfd15a6`, containing #9729), zero conflicts, and its diff
  does **not** touch the `handle_call({:trigger, …})` cond body, so the capacity check lands on clean
  ground. **The primary signal is the in-BEAM census**: `trigger` is a single serialized `handle_call`,
  so the door decision and `start_run` are in one critical section and two concurrent triggers can never
  both observe zero — it touches no lock and cannot steal. **The second opinion is `/proc/locks`**, a
  non-destructive read (5 lines, world-readable, the BEAM runs as root) matched by `FLOCK` +
  `MAJ:MIN:INO` from `File.stat!`; the lock is `/var/lock/barkpark-site-build.lock` (**not** `/run/lock`)
  with `$BARKPARK_BUILD_GATE_LOCK` and `${TMPDIR:-/tmp}` fallbacks a hardcoded path would miss. **`flock -n`
  is REFUSED**: on a *free* lock it ACQUIRES, so it can steal from a unit blocked in `flock -w 900`
  (wakeups are unordered), and it leaks fd 7 by inheritance — three live holders were observed on one
  build (`bash`, `npm`, `tee`). **And `/proc/locks`' PID is not a liveness signal** — one probe named PID
  4020570 while `ps` found nothing, because the fd lived on in an inheriting child; key on the entry's
  PRESENCE. **The in-engine flock SURVIVES as the last-resort correctness barrier**: `build_gate_acquire`
  fails OPEN in three named cases (no `flock(1)`, undeletable lock dir, unopenable lock file), and in each
  one nothing is ever written to `/proc/locks`, so the door reads "free" forever. The door is an early
  honest refusal, never the barrier. **THE FIFTH FILE:** emitting `code: "box_at_capacity"` reds
  `api/test/barkpark_web/contract/error_code_coverage_test.exs`, which globs the controllers and asserts
  every literal is in `Errors.known_codes/0 ∪ @offspec_codes`. Proved by membership: `known_codes` has
  **65 entries and contains neither `box_at_capacity` NOR `already_running` NOR `site_provision_failed`**;
  #9727 itself had to add `site_provision_failed` to `@offspec_codes` (+7 lines) for exactly this reason.
  Baseline is green (2 tests, 0 failures), so any red is the slice's own. **That red is CORRECTNESS, never
  advisory.** *The slice's briefed line anchors are all pre-#9727 and now wrong:* `already_running` is at
  **91-99** (not 86-94), `trigger/1`'s `@spec` at **285-289** (not 203), the D86/D87 comment at **571-572**
  (not 407-412), and the trigger cond body at **405-419** with `running_slug?` at **413**.

- **D61 — THE 409 CONTRACT: `code` EXACTLY, AND `message` MUST BE NON-EMPTY. THE SAME BREAK ALREADY HITS
  `already_running`, THE CLASS SHIPPING SINCE W1.** *Why:* proved by a genuine round trip through
  `FakeBoxRelay → box_refusal/3 → defer/3 → the PERSISTED `failure_reason` → `DeployLedger.classify/1`,
  not fixture against fixture. The briefed constraint was wrong: a code with **no** message and **no**
  request_id classifies CORRECTLY. The real trigger is **code + no message + a stamped `request_id`** —
  `box_refusal/3` appends `" [box request_id: …]"` AFTER the detail while `refusal_detail/1` returns the
  bare code when message is nil, so `deferral_code/1`'s `String.split(" — ") |> hd()` yields
  `box_at_capacity [box request_id: F9tPXq2A]` and the `== "box_at_capacity"` comparison fails →
  `DEFERRED_UNCLASSIFIED`. **The blast radius is wider than the unbuilt slice: the identical break hits
  `already_running`** (PROBE-b3 → `DEFERRED_UNCLASSIFIED` instead of `BOX_BUSY_DEFERRED`), which by D43's
  own logic falls back to the generic chain bound and lands on *"refusing this site persistently for a
  cause the ledger cannot name"* — the false accusation D43 exists to kill. Fail-before / pass-after was
  proved with a one-line stamp-strip in `deferral_code/1`, 99/99 green with both existing suites intact.
  **A second, opposite defect is recorded and NOT in the same slice as the door:** a **CODELESS** body
  whose `message` merely begins with the code string is SPOOFED into `BOX_AT_CAPACITY_DEFERRED`, because
  `deferral_code/1` reads the first `" — "`-delimited segment of whatever prose the box sent, never a
  code. **Ruling: the ledger hardening is its OWN `cloud/` slice**, separate from the `api/` door — they
  are independent defects on opposite sides of the wire, the ledger one is live TODAY, and splitting them
  keeps the fences disjoint so both build in round 1. It is LATENT, not firing: the only production 409
  never calls `put_request_id` and always carries a message.

- **D62 — THE THREE-STATE MECHANISM ALREADY SHIPPED; WAVE 4 EXTENDS IT AND MINTS NO NEW REASON WORD. THE
  CLI's MISSING THIRD STATE IS ABSORBED, NOT DEFERRED.** *Why:* `Usage.instance_meter/2` +
  `unavailable_meter/2` already distinguish value / deliberately-unmetered / measured-and-failed, the last
  via a **conditional** `:unavailable_reason` key normalised against a CLOSED five-word allowlist
  (`exception deadline_exceeded unreachable bad_shape too_many_datasets`), and the SPA already renders all
  three ("Could not measure" / "Not yet metered" / the value). **Axis 3 — "none configured" — must NOT
  reuse that allowlist**: `unavailable_meter/2`'s own docstring says *"the read WAS attempted and it
  FAILED"*, so minting `none_configured` there would make a failure vocabulary describe a read that
  SUCCEEDED, and inherit the warn tint and the "Could not measure" headline for a healthy swapless box.
  **Ruling: axis 3 is carried in DATA, not vocabulary** — `swap_total_bytes == 0` → "none configured"
  (neutral, no tint, never a percent); `> 0` → "<pct>% of <total>"; both `-1` → falls through to the
  existing unmetered/unavailable arms. D45's companion field already encodes exactly this, and the agent's
  own comment names the three states. This needs no enum widening, so D33/D386's closed-enum law costs
  nothing. **THE CLI IS THE HOLE AND IT IS ABSORBED:** `internal/cli/cloud_usage.go` has zero
  `unavailable_reason` hits — not because the renderer is wrong but because
  `internal/cloudclient/client.go`'s `UsageMeter` struct has no field for it, so the reason dies at
  unmarshal one layer below the renderer (`PendingInvitations *int` with `,omitempty` sits one line above
  as the exact precedent). Four reasons to absorb rather than defer: the fold must open that struct
  ANYWAY; `usageStateSeverity` has **no rung for a failed read** (`over_limit 3 > near_limit 2 >
  unmetered 1 > live 0`) so a crashed headline meter rolls a row up as CALM — the vacuous-green shape the
  wish exists to kill; two open cch rows describe one defect; and cch's own backlog row asks for a charter
  widening naming that file, which this decision GRANTS: **`internal/cloudclient/client.go` and
  `internal/cli/cloud_usage.go` are granted to the fold slice by name.**

- **D63 — THE FLEET-LIST SEAM IS ADDITIVE AND UNCLAIMED, BUT IT IS FIVE CALL SITES AND ONE DELIBERATE
  AUTHORIZATION WIDENING.** *Why:* nothing pins the serializer's key set — 31 `Map.keys` assertions across
  `cloud/test/` and **not one targets a barkpark row**; there is no barkpark-row golden fixture and no
  cloud OpenAPI drift gate; Elixir map patterns are subset matches so the two existing `= row` assertions
  survive a new key by construction; and the Go decoder is a plain `json.Unmarshal` with
  `DisallowUnknownFields` appearing only in `internal/manifest` and `internal/template`. `GET /v1/barkparks`
  already prefetches two DISTINCT ON maps before serializing, so a third is symmetric, and the same N+1 was
  already found and fixed once in this domain (`usage.ex:541`). **But `barkpark_json` has FIVE call sites,
  FOUR at arity 1** (router.ex:2078, :2157, :2162, :8196) — boxes that by construction have never beaten —
  so the change must take pressure as a PARAMETER, and those four sites are exactly the case that must
  render "unmetered", never 0%. A design that looks pressure up INSIDE the function puts a per-row query on
  four write paths. **`internal_barkpark_json` (router.ex:8690, NOT :8137) does NOT move in lockstep** — it
  is `require_worker`, cross-team by design, consumed only by a fleet-ops audit whose struct already ignores
  ~15 fields; adding pressure there would be a second differently-authed producer for no consumer. Do not
  touch it. **THE WIDENING, taken deliberately:** the `scope=all` branch is bounded to the caller's own team
  memberships by an INNER JOIN, so it crosses no tenancy line; but the *default* list is
  `require_user_or_pat + require_ability("read")` whereas `/metrics` — today's only pressure surface — is
  `require_user` only, which a PAT fails. So the sub-map newly exposes host pressure to MACHINE principals
  holding a read-scoped PAT. That is defensible (same team's own box, and arguably what `bp cloud status`
  in CI wants) but it is a DECISION, not a side effect, and it is recorded here rather than discovered later.

- **D64 — D39's "`:erlang.memory()` CANNOT BE READ" IS STALE FOR THE TOTAL, AND WIDENING THE BREAKDOWN IS
  ~5 LINES — BUT THE UNIT IS KILOBYTES AND THE NAME DOES NOT SAY SO.** *Why:* the prod BEAM already calls
  `erlang:memory()` every 10 s — `telemetry_poller_builtin.erl:24-26` executes `[:vm, :memory]` with the
  FULL nine-key map — and `GET /v1/instance/metrics` already serves one key of it, token-gated, deployed on
  guerrilla now (401 anon, 200 + 48,213 bytes with a token, `vm_memory_total` moving across scrapes:
  1,692,796 → 1,684,024 → 1,730,828). `periodic_measurements/0` is EMPTY, so the vm gauges come from the
  poller's defaults; `telemetry.ex:74` subscribes to exactly ONE of nine. Widening is `last_value` lines in
  one file — no new route, no epmd, no release, no rpc verb. **THE 1024× TRAP IS ALREADY ARMED:**
  `unit: {:byte, :kilobyte}` is declared, and `TelemetryMetricsPrometheus.Core` scales the value but keeps
  the event-derived name, so the wire format is a bare `vm_memory_total` with no `_kilobytes` suffix — the
  repo's own test says so in a comment. Sanity: 1,730,828 read as KB = 1.65 GiB against beam.smp RSS
  1,399,404 kB; read as bytes it is 1.7 MB against a 1.33 GB process. Meanwhile the AGENT's convention is
  BYTES (`beam_pss_bytes`), so whoever scrapes crosses a unit boundary. **RULE: every new BEAM key either
  carries `unit: {:byte, :kilobyte}` to match its neighbour OR carries an explicit `_bytes` suffix in its
  name — an unsuffixed byte-valued gauge beside an unsuffixed kilobyte-valued one is how "a 1000× unit
  error renders as a memory leak" actually happens.** **THE BOUND STAYS PARKED, with a sharper caveat:**
  1.65 GiB inside-view against D39's measured 2,704 MB (1,528 PSS + 1,176 swap) means `:erlang.memory()`
  does NOT explain the full anonymous footprint — code/loader/allocator carriers and swapped-out pages sit
  outside its accounting. A `MemoryHigh` derived from it alone would be set ~1 GB too low. Wave 5 derives
  the bound from PSS+swap and uses the breakdown for ATTRIBUTION only.

- **D65 — THE CAPABILITIES BLINDNESS IS REAL BUT ITS LEVERAGE CLAIM IS REFUTED; IT IS FILED SUBORDINATE TO
  THE POOL PARTITION, NOT BUILT.** *Why:* `AssignDefaultScope` (router.ex:43, inside `pipeline :api`) puts
  **three** uncached DB round-trips in front of every `/v1/*` request — `get_default_project/0` re-invokes
  `get_default_workspace/0` — including `/v1/capabilities`, whose controller touches no database at all. It
  is live: 827 `Sent 500` and 732 queue drops in one hour, `/v1/capabilities` the 3rd most-500'd path, and a
  `bp search` in this very session returned `internal_error`. **But the leverage claim is wrong:**
  `OptionalToken` runs BEFORE it (router.ex:40 vs :43) and owns 194 crash frames to AssignDefaultScope's 68
  — 2.85× — and `bp` always sends a Bearer token, so every real `bp` call dies one plug EARLIER. Caching the
  default pair would leave `bp` exactly as blind. Root cause is `POOL_SIZE` unset (compiled default 10)
  shared between all HTTP and 29 Oban slots while a single `EdgeProjector` job held a connection for
  **37.98 s**. That repair is owned by the OPEN `jpf-bl-oban-pool-partition` and is NOT PROMISED here. The
  cheap plug fix removes ~8.2% of the 500s and zero percent of authed `bp` traffic; it is filed explicitly
  subordinate, so nobody ships it and reads it as having addressed the class.

- **D66 — NO REQUIRED CONTEXT ASSERTS ON A PURE-GO OR PURE-DEPLOY DIFF, AND EVERY SUCH SLICE MUST SAY SO IN
  ITS OWN BRIEF.** *Why:* the required set is exactly four contexts (`Elixir gate`, `PR references an active
  task`, `Cloud gate`, `Console gate`), re-derived live. `internal/**`, `cmd/**` and
  `deploy/instance-deploy.sh` dispatch **false** on all of them while auto-deploying production. Witnessed on
  a real merged CODE pr — **#9732**, strictly `internal/**` — where all four required contexts concluded
  `success` while **13 expensive leaves concluded `skipped`**, and `go vet + test` ran, passed, and is not
  required (it is structurally unrequirable: a workflow-level `on: paths:` filter means an absent context
  reports "expected" forever). **RULING: every slice whose file set is pure-Go or pure-deploy carries,
  verbatim in its task body, the sentence "No required context asserts on this diff — Cloud/Console/Elixir
  gates all report success by skipping. The blocking evidence for this slice is a live beat read off the
  control plane, not a green PR."** That extends this epic's own slice-zero discipline to the gate layer.

### Wave 4 plan — 8 slices, 7 in round 1

| # | Slice | Task id | Round | Model | Surface |
|---|---|---|---|---|---|
| s1 | The rebuilt agent actually restarts — one word, with the in-file precedent | `dr-w4-s1-agent-release-restarts-the-unit` | 1 | opus | `deploy/instance-deploy.sh` |
| s2 | The agent measures space by named consumer, and its own core count | `dr-w4-s2-agent-measures-space-and-cores` | 1 | opus | `internal/agent/`, `cmd/barkpark-agent/` |
| s3 | The fold: the CP and the CLI render swap, db + top relations, and the BEAM — three-state | `dr-w3-s6-cp-cli-render-new-vitals` | 1 | opus | `cloud/lib/barkpark_cloud/{telemetry,metrics,usage}.ex`, `internal/cli/`, `internal/cloudclient/client.go` |
| s4 | The fleet list carries pressure, prefetched, nil-safe on four write paths | `dr-w4-s4-fleet-list-carries-pressure` | 1 | opus | `cloud/lib/barkpark_cloud/web/router.ex`, `registry.ex` |
| s5 | The door refuses at capacity with a typed 409 — census, not `flock -n` | `dr-w3-s5-door-refuses-box-at-capacity` | 1 | opus | `api/lib/barkpark/sites/`, `api/lib/barkpark_web/controllers/`, `api/test/.../error_code_coverage_test.exs` |
| s6 | The deferral code survives the request-id stamp, and stops being spoofable by prose | `dr-w4-s6-deferral-code-survives-the-stamp` | 1 | opus | `cloud/lib/barkpark_cloud/deploy_ledger.ex` |
| s7 | `:erlang.memory()` names which subsystem grows — D39's parked prerequisite | `dr-w4-s7-beam-memory-breakdown-readable` | 1 | opus | `api/lib/barkpark_web/telemetry.ex` |
| s8 | `strained` reaches the triage vocabulary at rank 5, and the ladder stops being drifted | `dr-w3-s7-strained-reaches-triage` | 2 (after s2, s4) | opus | `internal/cli/`, `internal/semrole/`, `internal/cloudclient/client.go`, `cloud/priv/static/` |

**Model note:** every slice is `opus` by AVAILABILITY, not by judgment — Fable is unavailable for
subagents this wave. On difficulty/surface grounds **s8** (cross-surface ladder coupling, a bilateral
cession amendment, three coordinated pins) and **s5** (the door/unit race) would both have been `fable`.
The lead should weight review attention there accordingly.

**HIGH-FLIP-RISK slices, owed a genuinely independent second reviewer BEFORE merge — a MANUAL LEAD STEP,
because this workflow spawns exactly ONE reviewer, and this wave ARRANGES it rather than discovering it at
Review:** **s5** (the race between the door's census and the unit's own `flock` acquire — the in-engine
flock MUST survive as the last-resort barrier, and the refusal of `flock -n` is the judgment most likely to
be re-litigated by a builder who finds it convenient); **s8** (the rank-5 ruling and the D31 bilateral
amendment — a reachability/ownership judgment across two epics' fences, where being wrong means shipping a
ladder that contradicts a LIVE production console); **s4** (the PAT authorization widening in D63 — a
tenancy-adjacent judgment that is defensible but must not be re-derived by the builder).

**What this wave does NOT promise.** `MemoryHigh` stays parked (D39, and D64 sharpens why a naive threshold
would be ~1 GB too low). The Postgres pool partition stays with `jpf-bl-oban-pool-partition` (D28, D65).
Journal capping and disk RECLAMATION are not taken — D48 orders capping behind the backfill and D47 shows
sites' gigabytes are load-bearing build caches whose deletion forces a cold `npm ci` on the box that is
swapping; **this wave makes space VISIBLE and files what to do about it.** Retention on `mutation_events`
and `revisions` remains a DATA-LOSS decision outside the fence (D46) — sharpened by verification:
`revisions` carries `compaction_snapshot` rows that are the durable REVERSIBLE archive for task compaction,
and `mutation_events.document` is the ONLY surviving copy of 158 adjudication reasons already filed for
recovery. The 76× HTTP 500 class may or may not fall; that stays a MEASUREMENT `dr-w2-s8` takes, never a
promise.

---

### Wave 2026-08-06 (wave 4) — REVIEWED · Paper `deploy-reliability-wave-4-2026-08-06` · grade **A−**

**Seven of eight slices built, reviewed, gate-green on the final state, pushed and PR'd. Nothing merged — the
lead merges.** The eighth (`dr-w3-s7`, `strained` reaching triage) is round 2 BY DESIGN, behind s2 and s4.

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| Agent release restarts the unit | `dr-w4-s1-agent-release-restarts-the-unit` | `…starts-running--0` (unchanged) | [#9823](https://github.com/FRIKKern/barkpark/pull/9823) | `bash -n` exit 0 + pasted live guerrilla proof |
| Agent measures space + cores | `dr-w4-s2-agent-measures-space-and-cores` | `…by-named-consum-1` (unchanged) | [#9824](https://github.com/FRIKKern/barkpark/pull/9824) | go build/vet/test green; gofmt clean |
| The fold — CP + CLI render swap, db, BEAM | `dr-w3-s6-cp-cli-render-new-vitals` | `…and-the-cli-r-2` (unchanged) | [#9825](https://github.com/FRIKKern/barkpark/pull/9825) | 92 tests, 0 failures (baseline 70) + Go suite green |
| Fleet list carries pressure | `dr-w4-s4-fleet-list-carries-pressure` | `…pressure-prefetch-3-r` | [#9826](https://github.com/FRIKKern/barkpark/pull/9826) | 176 tests, 0 failures |
| The door refuses `box_at_capacity` | `dr-w3-s5-door-refuses-box-at-capacity` | `…with-a-typed-4` (unchanged) | [#9827](https://github.com/FRIKKern/barkpark/pull/9827) | 81 tests, 0 failures (+ controller suite 28/0) |
| Deferral code survives the stamp | `dr-w4-s6-deferral-code-survives-the-stamp` | `…the-request-i-5` (unchanged) | [#9828](https://github.com/FRIKKern/barkpark/pull/9828) | 94 tests, 0 failures (baseline 92) |
| `vm.memory` names the subsystem | `dr-w4-s7-beam-memory-breakdown-readable` | `…subsystem-grow-6` (unchanged) | [#9829](https://github.com/FRIKKern/barkpark/pull/9829) | 5 tests, 0 failures (baseline 3) |

**What landed, against the wish's three clauses.**

*See what is taking up space.* The fold (#9825) is the wave's most valuable single PR: `db_size` was
pre-wired and dark only because the probe reported `-1`, and `pg_top_relations` has been arriving at the
control plane since the 11:45:23Z cutover — so `bp cloud instance top` now names `mutation_events` 1.53 GB
+ `revisions` 1.33 GB = 81.3 % of a 3.52 GB database, **retroactively over the whole retained window**, as a
bar chart whose bars are shares of the total. That answer is real today. The disk/journal/sites axis
(#9824) ships the PRODUCER only — see the gap below.

*See a struggling box as struggling.* Swap, the BEAM's own footprint and load-per-core all reach the
control plane and the CLI in three honest states (`none configured` / `<pct>% of <total>` / em dash), five
of six boxes being swapless makes state one the majority case, and the fleet row now carries the pressure
block the ranker reads. `vm.memory` breaks down by subsystem so a leak names itself. But `attentionStatus`
still ranks a 100 %-cpu box `healthy / rank 8` — that is s8, round 2.

*Cap concurrent builds.* Done and typed: the box refuses at the DOOR with `box_at_capacity` 409 before the
artifact is unpacked, off a serialized in-BEAM census plus a non-destructive `/proc/locks` second opinion,
failing open everywhere, with the in-engine `flock -w 900` untouched as the last-resort barrier.

**The wave's one real hole.** `dr-w4-s2` posts space to `/v1/agent/space` under event type `"space"`, and
**neither exists on the control plane** — the type is outside `AgentEvent`'s `~w(health status backup tls
content verify)` allowlist and the route is absent. No wave-4 slice was fenced to touch `cloud/**` for the
agent-ingest path, so the widening could not land with it. Shipped alone the slice measures space perfectly
and 404s it every 15 minutes. Its criterion 2 is honestly left OPEN. Follow-up `task-3b69c3e24bf3d8ca`.

**Review fixes made in place (one commit).** `dr-w4-s4`'s pressure block shipped `load1` without
`cpu_cores` — the denominator D52 rules the strained fence is a ratio against, and which D52 explicitly
refuses to hardcode. `dr-w4-s2` puts `cpu_cores` on the beat for exactly that reason. Without it on the row,
round 2 would have had no denominator on the fleet-list surface and would have had to reopen the file.
Added under the same `measured_or_nil` guard on `…prefetch-3-r`, gate re-run 176/0. Every other slice was
accepted unchanged — six of seven needed nothing, which is a real statement about the build phase.

**Independence owed before merge (high-flip-risk).** `dr-w3-s5`'s door-vs-unit race judgment. The wave
reviewer re-derived it independently and agrees (the census is inside one `handle_call`, so serialization is
structural; every `File.read`/`File.stat` error arm returns `false`; `takes_build_slot?` is `true` only for
`mode: :deploy`) — but the charter's dual-review rule makes the actual second reviewer a manual lead step.

**What the lead must know before merging.**
1. #9827 creates the first real producer of a 409 on a path that always answered 202. If BoxRelay treats a
   409 as fatal rather than as a deferral to retry, deploys that used to queue dishonestly now fail fast.
   The end-to-end retry behaviour is proved by nothing this wave ran.
2. #9827 edits a **fifth file** outside its declared fence — `site_deploy_controller_test.exs` — because that
   suite asserted the old 202 semantics verbatim.
3. #9826 newly exposes host pressure to read-scoped **PAT** principals (charter D63, a decision, not a
   discovery).
4. Merge order is unconstrained. #9828 before #9827 is strictly safer but not required: the door always
   sends a non-empty message, so its code classifies correctly either way.
5. Every slice's last criterion is merge-gated and stays OPEN for the lead to close on merge.

**What the next wave takes.** (a) The CP side of space — the `/v1/agent/space` route plus the `@types`
widening — without which #9824 is a producer talking to nobody. (b) `dr-w3-s7`, unblocked the moment #9824
and #9826 merge. (c) The `MemoryHigh` bound, now that #9829 makes attribution readable and D64 shows why an
`erlang:memory()`-derived threshold would be ~1 GB too low — derive from PSS + swap. (d) Two named residuals:
the deferral classifier's raw-column ambiguity (a codeless `box_at_capacity — <prose>` is byte-identical to
`code — message`; only a structured column closes it) and the `unavailable` token painting neutral in
`semrole.For`.

---

## Wave 5 — the last mile: every instrument reaches a human's eyes

**Wave 5 Paper:** `deploy-reliability-wave-5-2026-08-06`

**SLICE-ZERO, PROVEN BY RUN THIS SESSION, NOT INHERITED.** "Merged is not measuring" is DISCHARGED:
guerrilla's live beat carries `cpu_cores: 2`, `swap_used_percent`, `beam_pss_bytes`, `beam_swap_bytes`
and a `top_relations` naming `mutation_events` + `revisions` as 81% of the database. #9823 worked.
**And the owner's complaint is STILL LIVE, re-measured end to end:** `bp cloud status` returns guerrilla
`status "ok", rank 8, bucket "healthy"` while, in the same minutes, `load15` reads 1.89–2.02× per core
against 2 cores, swap is 92.9% full, PSI `memory full avg10` is 6.95, the box answered **6,472 HTTP 500s
in eight hours**, and `barkpark-slot@blue.service` sits in `failed`. Say it plainly: **the answer to
"can a human see that box as strained" is still NO, and closing that gap is this wave's whole job.**

## Decisions (wave 5)

- **D67 — AMENDS D52: THE SUSTAIN MECHANISM IS `load15`, NOT A BEAT WINDOW. EVERY OTHER D52 CLAUSE
  SURVIVES VERBATIM.** *Why:* D52 specified `load1/cores >= 2.0` on `>= 2 of the last 3 beats`, and that
  shape is **NOT COMPUTABLE FROM WHAT MERGED**. `Registry.latest_health_payload_map/1` is a
  `DISTINCT ON (barkpark_id) ORDER BY inserted_at DESC` — ONE beat — and `merge_pressure/2` folds exactly
  that row, so `/v1/barkparks` (the one payload both `bp cloud status` and the SPA read) carries no window
  at all. k-of-n and latching both need state that is not on the wire. Measured on a fresh 200-point window
  across all six boxes: **every** candidate shape is FP-free (0/800 healthy-box beats), so false positives
  cannot discriminate between shapes and the "keep 0 FPs" criterion is vacuous; what discriminates is
  **flap at the moment the owner looks** — single-beat and 2-of-3 were BOTH DARK at the latest beat
  (1.99×, under the line by 0.01), with 37 scattered dark beats inside otherwise-strained periods.
  **THE ANSWER NOBODY NAMED:** `loadProcProbe` (`cmd/barkpark-agent/main.go:317-332`) already does
  `os.ReadFile("/proc/loadavg")` and `strings.Fields`, then uses `fields[0]` **and throws `fields[1]` and
  `fields[2]` away**. `load15` IS a sustained measurement — a 15-minute kernel EWMA delivered as ONE
  scalar — needing no window, no client state, no new route. Live proof, 12 SSH readings, 3 samples 60s
  apart: at 15:01:02Z guerrilla read load1 **0.64× per core** (dark on any single-beat fence) while its
  load15 was **1.89×**, 5.9× the busiest healthy box; healthy ceiling is jarl at 0.32×/core against
  guerrilla's floor of 1.89×. **RULING: the fence is `load15/cores >= 1.75`, evaluated on the LATEST BEAT,
  with `load1` kept for the reason string's present-tense colour.** Where `load15` is absent (an agent
  that predates it) the fence FALLS BACK to `load1/cores >= 2.0` — this is not the refused fallback: D52
  refused a **hardcoded core count**, an assumption about the fleet's shape; a coarser averaging window is
  a strictly LESS sensitive predicate (163/200 vs 180/180 on the same box) that can under-report and can
  never over-report, which is the honest direction. **The 1.75× number is derived from a RECONSTRUCTED
  load15 series (an EWMA of load1, α=exp(-60/900)) and only 12 spot readings are real — the builder MUST
  re-derive the sweep on real `fields[2]` once the agent reports it, and say so in evidence.**

- **D68 — AMENDS D56 TWICE: THE BUCKET BOUNDARY IS AN INTEGER OFF, AND THE "FIVE LINES, ZERO RENDER
  CHANGE" SPA GRANT IS WITHDRAWN AS UNSATISFIABLE. `strained` SHIPS GO-ONLY THIS WAVE.** *Why, part one:*
  D56 set buckets "attention ≤6, in-flight 7-9" over a ladder placing `behind` at 7 — which MOVES `behind`
  out of attention. Shipped `app.js:5268-5291` has `behind: 6` INSIDE attention (`r <= 6`), the harness
  comment says so, and the Go fixture `attention_order.json` independently places `behind` in attention.
  Applying D56 literally was **run** and reds 4 of 914 assertions, two of them the reclassification:
  `fleetSummary counts buckets` (`__app.test.mjs:3144`) flips `attention 6 → 5`, and `filterFleet`
  (`:3164`) drops `'behind-1'`. A grant issued *because* it was render-neutral must not reclassify every
  out-of-date box. *Why, part two:* the grant named `ATTENTION_RANK`, `bucketOf` and `KINDS`, and that set
  was **proved unsatisfiable by mutation, twice**: rank-map + `bucketOf` alone reds the closed-enum test in
  the harness's own words ("a new fleet state was added without a statusOf arm"), because
  `attentionKinds = Object.keys(ATTENTION_RANK)` is deep-equalled against `KINDS`; adding `KINDS` reds it
  again on `classifyBp` reachability. The measured minimum green diff is **25 changed lines in `app.js`
  + 13 in `__app.test.mjs`, in six parts**, including a `strainedOf(bp)` helper reading `bp.pressure` — and
  deployed `app.js` contains **ZERO** occurrences of `pressure`. It **IS** a render change: `statusOf`
  feeds `statusPill` at six sites, so a `Strained` warn pill appears in the Overview attention queue, the
  fleet cards, the instance H1 and the command palette. *Why, part three — the fence:* cloud-console-
  hardening's declared Surface fence is the bare directory **`cloud/`**, which swallows all three SPA
  files; their charter contains **ZERO** occurrences of `dr-w3`, and their collision census enumerated
  `dr-w2` rows only; and our own OPEN, HANDED-OVER row `dr-bl-spa-unknown-state-buckets-healthy` already
  claims `app.js` + `__app.test.mjs` for THEM. So the grant is UNILATERAL in fact. **RULING: the ladder
  lands in Go, the fixture and the Go tests ONLY. The SPA edit is NOT taken this wave and is not ours to
  take unilaterally.** The corrected integers stand recorded for whoever lands it: **buckets are
  attention ≤8, in-flight 9-10, healthy 11**, and **the ladder moves in ONE commit or not at all** — a
  `classifyBp` kind with no `ATTENTION_RANK` entry yields `undefined`, and `undefined <= 8` is false, so a
  half-landing buckets a strained box **HEALTHY**, the exact inversion this epic exists to kill.
  **THE COST, STATED PLAINLY: an owner who looks at the CONSOLE still sees "Healthy · Online" for a
  strained box.** That is a KNOWN TWO-TIER ladder (Go 11 rungs, SPA 9) and a ceded blindness with a named
  owner, not an oversight — and it is consistent, because the deployed console's Metrics tab plots exactly
  four series (`cpu`, `mem`, `disk`, `load`) and carries zero occurrences of `pressure`, `beam_pss`,
  `top_relations` or `cpu_cores`: **the CLI is where every wave-3/4 instrument is visible, and `bp cloud
  status` is the command the lead actually ran when he found the box reading "ok".**

- **D69 — AMENDS D53 NARROWLY: THE DISK GETS ITS OWN RUNG `filling`, SOURCED FROM THE METER THAT ALREADY
  SAYS 95%.** *Why:* D53's ruling that `strained` must not ABSORB space **stands** — merging pressure and
  space is how a vocabulary rots. But D53 never ruled that space has no rung, and the hole it left is now
  measured at L1: jarl's root filesystem is `38G / 34G used / **1.9G free** / 95%`, flat at 95 across 200
  consecutive beats, while a single site image weighs **2.03–2.05 GB** — *jarl is less than one deployment
  from ENOSPC*, and it has already hit 100% once and taken its CMS down (`jpf-runtime-image-pruning`).
  In the same minute `bp cloud usage jarl` renders `Disk 95% · **over_limit**` and `bp cloud status` places
  jarl in the **HEALTHY** bucket beside the genuinely idle boxes. That is not a measurement gap; it is two
  operator surfaces contradicting each other, with the one an owner opens first being the wrong one.
  **RULING: `filling` enters the ladder at rank 6, fired from `pressure.disk_used_percent` against the
  SAME threshold `bp cloud usage` already ships (`usage.ex:239` — quota 100, warn 70, over 90), never a
  new number.** This also answers the sharpest attack on the wave: `strained` alone would be a vocabulary
  for a population of ONE (only guerrilla reports `cpu_cores`), whereas `disk_used_percent` is live
  FLEET-WIDE on the OLD agent, so the ladder fires on **two** boxes the day it lands — guerrilla `strained`,
  jarl `filling` — with no rollout at all.

  **THE LADDER, FINAL, ELEVEN RUNGS:** `1 removal_failed · 2 failed · 3 suspended · 4 degraded ·
  5 strained · 6 filling · 7 unreported · 8 behind · 9 removing · 10 provisioning · 11 ok`.
  Buckets `attention ≤8 · in-flight 9-10 · healthy 11`. This preserves every shipped bucket assignment
  exactly; only integers move. Go is at **8** rungs today (`attentionRankOrder`, no `unreported`, no
  `strained`) and the fixture agrees with Go, so this is a **three-rung** Go reconciliation, not a
  one-rung touch-up.

- **D70 — BINARY PROVENANCE IS PART OF EVERY VITALS CRITERION, AND `make cli-install` DOES NOT FIX IT.**
  *Why:* the installed `bp` is commit `f59aaf717` (2026-07-31), **31 Go commits behind origin/main**, with
  `strings | grep -c` = **0** for `pss_bytes`, `swap_bytes`, `top_relations` AND `cpu_cores`. The failure
  is ASYMMETRIC and both halves were reproduced: `-o json` surfaces re-print `res.Raw` verbatim
  (`cloud_instance_top_cmd.go:127`), so a stale binary containing **zero bytes** of those names prints
  them anyway — a criterion phrased "run `bp cloud instance top` and see `top_relations`" **passes on a
  binary from last year** and proves the control plane, not the CLI. Meanwhile `bp cloud status` has
  **NO raw path in either direction** — `ListBarkparks` returns `[]Barkpark` with no `Raw` field and
  `-o json` re-encodes the CLI's own ranked structs — so it verifies **FALSE-RED**: a builder who
  correctly ships `strained` and checks with the PATH binary sees "healthy" and abandons a correct fix.
  And `make doctor`'s own printed remedy is not enough: `cli-install` builds from the LOCAL checkout,
  which is 503 commits behind and has **0** occurrences of `cpu_cores`. **RULING: every vitals criterion
  carries, verbatim, "BINARY PROVENANCE — this reading was produced by a bp built from the branch under
  test (`T=$(mktemp -d); git archive <sha> | tar -x -C $T; CC=clang go build -C $T -o $T/bp
  ./cmd/barkpark`) and the evidence quotes that `<sha>` beside the output; the `bp` on PATH is a lagging
  release artifact."** A second trap for the same gate: unanchored `strings … | grep -c strained` returns
  **5**, every hit a substring of `unconstrained` — any presence check must be word-bounded AND
  mutation-proven.

- **D71 — AMENDS D58's ILLUSTRATION, NOT ITS RULING: THE SPACE AXIS IS HOST-CONSUMER SHAPED, NOT ONLY
  DB-RELATION SHAPED.** *Why:* D58's headline example — `mutation_events` 1.54 GB + `revisions` 1.34 GB =
  81% — is a **GUERRILLA** fact. Traced field by field on jarl, the box actually running out of space,
  `SpaceReport` as designed would name **984.7 MB of 33.84 GiB used — 2.85%**: `journal_bytes` 920.1 MB,
  `pg_size_bytes` 64.6 MB (the whole relation axis is rounding error there), and `sites_bytes` **-1** with
  `sites_top` **nil**, because `find / -xdev -maxdepth 4 -type d -name sites` returns **NOTHING** on jarl —
  the design's only named-consumer axis is structurally dark on that box. What is actually there, named by
  no field at all: `/var` = **29G of 33.84 GiB**, of which `/var/lib/containerd` **14G** and
  `/var/lib/barkpark-builder` **11G** (24 `docker save` tarballs at ~471 MB each), with
  `docker system df` reporting `Images 8 · 14.12GB · RECLAIMABLE 14.12GB (100%)` and 7 of 8 backing
  `Exited (1)`/`Created` containers from superseded generations. **RULING: the sites probe's ONE root
  becomes a SHORT LIST of roots (default `["/opt/barkpark/sites", "/var/lib"]`), reusing `duSitesArgs` and
  `parseDuTree` verbatim — they are sites-specific in nothing but their variable names.** Cost measured on
  the live box: `du -hx -d1 /var/lib` = **5.609s cold / 3.200s warm** against `duProbeTimeout = 60s`; `/`
  costs 10.5s and is coarse ("var 29G" is not actionable), so `/var/lib` is the second root, not `/`.
  **AND D47 GETS A SCOPE STAMP:** its "gigabytes are load-bearing build caches" clause was measured on
  guerrilla's `/opt/barkpark/sites` (`node_modules` ~2.9G, `.next`), a tree that **does not exist on
  jarl**; it does NOT transfer to jarl's docker layer, and a builder must not copy it into a refusal to
  reclaim 14 GB of superseded images. Reclamation still belongs to `jpf-runtime-image-pruning`.

- **D72 — SPACE ROWS SHORTEN THE METRICS WINDOW **TODAY**, AND D58's SEPARATION IS ENFORCED AT WRITE AND AT
  FOLD BUT NOT AT FETCH.** *Why:* `router.ex:7738` passes `points` ITSELF as the row limit to
  `Registry.recent_events/2`, which has **no type predicate** (`registry.ex:2724-2734`); `Metrics.build/3`
  then filters to `type: "health"` but echoes `points: points` from opts, never `length(series)` — so every
  non-health row inside the fetched N costs one chart point while the envelope keeps claiming N. Proved
  over the REAL HTTP path using only ALREADY-ALLOWED types, so this is a present-tense defect and not
  contingent on space landing: `?points=200` over a mixed stream renders **188** while the envelope says
  **200**; the default 30 renders 29; the health-only control renders 30/30. At the shipped cadence
  (`DefaultInterval` 60s vs `DefaultSpaceInterval` 15m) space is 1 row in 16 and the arithmetic is exact.
  The existing `metrics_test.exs` is 14 pure tests over hand-built lists that never touch the DB, so it is
  **structurally incapable** of catching this and will keep passing. **RULING: the metrics read fetches
  `points` HEALTH rows, not `points` rows (a `recent_health_events/2` or a `:type` opt — the existing
  `(barkpark_id, inserted_at)` index still backs it, no new index), and the guard lives in the DB-backed
  `metrics_route_test.exs` asserting `length(series.cpu) == points` on a mixed-type stream, MUTATION-PROVEN
  to fail before the fix.** Retention needs **no change** — `AgentRetentionWorker` prunes on `inserted_at`
  with no type filter, so space rows inherit the 14-day window for free at +6.7% row count; a slice that
  "adds space retention" is doing nothing.

- **D73 — THE DOOR'S SOBELOW WAIVER IS PROVEN BY CI RUN, #9827 IS UNHELD, AND THE ONE THING STILL OWED IS
  A HUMAN.** *Why:* the finding was traced, not asserted: `File.read(path)` at `deploy_runner.ex:764` has
  `path = proc_locks_path()` → `Keyword.get(config(), :proc_locks_path, @default_proc_locks)` → `config/0`
  = `Application.get_env/3`, with `@default_proc_locks "/proc/locks"` a compile-time attribute. Application
  config plus a constant — **no request value and no slug anywhere on the path**, which is STRICTLY
  STRONGER than #9729's five accepted waivers, whose safety rests on a regex-validated slug (i.e. on
  validation holding) and which merged today. A six-line inline waiver was pushed (`e84880295`) and the
  gate was **run**: the deciding step goes to `... SCAN COMPLETE ...` with **zero** findings and zero
  occurrences of `deploy_runner` in a 1,913-line job log; `api/.sobelow-skips` is untouched and
  **structurally cannot be involved** (0 of its 52 rows anchor anywhere under `lib/barkpark/sites/`, so the
  line-shift class that burned #9729 has no anchor to shift here); the BLOCKING "does not swallow its own
  inline waivers" job passes in 15s with the annotation counted AND bound (112 vs 111 coverings by
  mutation); and the green is EARNED — the fresh-finding guard still reds on a `String.to_atom` planted on
  this exact tree. **RULING: the waiver stands. #9827 is `MERGEABLE / CLEAN` with ZERO failing checks and
  all four required contexts green — the hold was doctrine, never branch protection, and the doctrine is
  now discharged.** What remains is its own criterion: **an independent second review of the door-vs-unit
  race, which this wave ARRANGES as a MANUAL LEAD STEP.** Two caveats recorded rather than discovered:
  the same PR adds a `File.stat` in `lock_triple/1` on an env/config-derived path that Sobelow 0.14.1
  simply does not cover — a detector bump makes it red later, and it is FILED; and the "Required-check
  spec gate" red on that PR was a **stale merge ref**, cleared by a re-push with no code change
  (115 passed/1 failed → 119 passed/0 failed), a recurring false-red generator worth naming.

- **D74 — THE AGENT IS BUILT **ONCE**, AT WARM-POOL ARM TIME, AND NEVER AGAIN. BLESSING A RELEASE IS A
  CATEGORICAL NON-FIX; THE REPAIR IS `scripts/apply-update.sh`.** *Why:* the premise "the new agent exists
  only where `instance-deploy.sh` ran" is right, and the mechanism is now proved. Only guerrilla has
  `/opt/barkpark/.slots`; jarl, gyl, dooodo and gyldendal do not, and none has any `barkpark-slot@*` unit —
  and `instance-deploy.sh:669` is an **unconditional** `mkdir -p "$APP/.slots"` in the forward deploy path,
  so its absence proves that path has **never completed** there. On all four, the agent binary's mtime
  equals `/etc/barkpark/agent.token`'s mtime **to the minute** (jarl Jul 30 14:25, gyl Aug 5 12:05, dooodo
  Jul 24 12:06, gyldendal Jul 9 16:38) — correlated with the PROVISION ARM, not with the box's git
  checkout. The only two sites in the repo that ever build the agent are `instance-deploy.sh:816-824` and
  `warmpool.go:618`. **All THREE self-update scripts contain ZERO occurrences of "agent"** —
  `apply-update.sh`, `deploy-rebuild.sh` AND `self-update.sh` — and `freshen.go:100` invokes
  `bash scripts/apply-update.sh`, so the survey's proposed patch to `deploy-rebuild.sh` would land on the
  FALLBACK branch and be skipped on the hot path. `v0.2.25` is dated 2026-07-08, a month before
  `fc6a74ca2`; all six boxes report `update_state: "current"` and will do so forever while the fence stays
  dark. **RULING: lift the `[ -f /etc/barkpark/agent.token ]` → `go build ./cmd/barkpark-agent` → reinstall
  unit → `systemctl restart` block into `scripts/apply-update.sh` (the hot path), and mirror it in
  `deploy-rebuild.sh` (the fallback) so neither branch strands the binary.** The staleness is STRUCTURAL
  and RECURRING, not a one-time backfill: without this, every box claimed from the warm pool from now on
  ships whatever agent existed at pool-fill time. Two traps disarmed for the builder: `command -v go`
  returns NO_GO over a bare ssh on **every** box including guerrilla (Go is at `/usr/local/go/bin/go`;
  `instance-deploy.sh:147` exports it) — designing around a non-problem is the likely failure; and gyl +
  dooodo currently FAIL host-key verification (`known_hosts:53`/`:54`), so any fleet-wide ssh sweep breaks
  on 2 of 6 until a human reconciles them. **AND THE CP CAN SEE THIS WITHOUT SSH: a box with a FRESH
  `reported_at` and a NULL `cpu_cores` is definitionally a stale-binary box** — that is the unmetered
  marker, computable server-side with zero new measurement, and it is what turns honest silence into
  something an operator SEES rather than infers from an absence.

- **D75 — THE 500 CLASS IS **ONE** CLASS, D28's FRAME RANKING IS REFUTED AT REQUEST LEVEL, AND THE 5xx
  METER IS A WIDENING OF A RING THAT ALREADY RIDES THE BEAT.** *Why:* over 8 hours of guerrilla's journal
  (390,158 lines), joining every `Sent 500` to its request_id's request line gives **6,472 distinct 500s**,
  of which **6,472 — 100.0% — also emit `DBConnection.ConnectionError`** and 4,746 (73.3%) the literal
  pool-queue-drop text. **There are ZERO non-DB 500s in eight hours**, so a single `db_unavailable` class
  names the entire population. The family split inverts D28: `/v1/tasks*` is **2,506 (38.7%)** against
  `/v1/data/*` **245 (3.8%)** — 10.2:1 the other way — and `/v1/graph*` fails **51.60%** of its requests, a
  surface nothing in this epic has ever named. D28's "753 stack frames in `query_pipeline.ex:190`" is not
  wrong so much as unattributable: `query_pipeline.ex` appears on 598 journal lines of which **0 carry a
  request_id**, at ~60 journal lines per 500, so frame counting measures stack depth, not traffic. The
  running pool is `pool_size=10` with Ecto-default `queue_target=50ms`/`queue_interval=1000ms` — nothing is
  configured in any env source the unit reads — on a 2-core box with 1,142 of 2,047 MB swap consumed.
  **AND THE PREMISE "there is no 5xx field on the beat anywhere" IS HALF WRONG, WHICH MAKES THE INSTRUMENT
  NEARLY FREE:** `BarkparkWeb.RequestStats` is a live 60s ETS ring served at `GET
  /v1/instance/request-stats` (`router.ex:1616`) and polled every beat into `req_per_s` + `p95_ms`; its
  handler binds `_meta` — Phoenix hands it the conn, and therefore `conn.status` — **and discards it**,
  inserting `{key, duration_ms}` with no status. **RULING: widen the existing ring to `{key, duration_ms,
  status}` + an `err_5xx_per_s` in `compute/4`, one field on the route, one on `Report`, one on the
  pressure block — do NOT build a second meter.** For guerrilla today that field reads ≈**0.22 5xx/s
  sustained on a box `bp cloud status` calls healthy**, which is the sentence the wish's DIAGNOSE clause
  needs and which nothing today can say. **HONEST BOUND (D48):** the ring is 60s and per-slot, it dies on
  every blue/green flip and reads 0 for the first minute after boot — it answers "is this box answering
  5xx *right now*", and it can NEVER produce a cumulative "6,472 since Tuesday". That is a different,
  journal-or-Postgres-backed instrument and is not promised under this slice. The pool repair itself
  remains `jpf-bl-oban-pool-partition`'s (D28, D65); nothing here licenses raising `POOL_SIZE` on a 2-core
  box already 1.1 GB into swap.

- **D76 — THE AFTER-MEASUREMENT IS **TAKEN**, AND THE HEADLINE INSTRUMENT IS DARK TO EVERY HUMAN ON PROD.**
  *Why:* `dr-w2-s8` is unblocked on volume and the number was taken **through the instrument**
  (`DeployLedger.census/2` on the live node), not by hand. BEFORE (2026-08-05 17:00→21:24Z): volume 565,
  failed 505, **89.38%**, zero deferrals so both conventions agree. AFTER (21:24Z→2026-08-06 14:16Z, pinned
  ≥19 min behind wall clock per D34(b), reproducible byte-for-byte 25s apart): volume **1718**, deferred
  **528**, failed **748** → **43.54% shipped convention / 74.27% old convention**, a **30.7-point spread
  the convention change itself manufactures**, which is exactly why D34 demands both. **The survey's
  hand-replicated 746/43.42/74.16 is off by TWO ROWS against both the classifier and the raw `status`
  column (`failed|748 deferred|528 live|442`) — the epic's own headline was a hand-replication error, and
  `dr-w3-s3` exists to stop precisely that.** Honesty riders, all measured: the "classifier agrees with
  `status`" check is exact (748/748, 528/528) but **near-vacuous by construction** — `classify/1`
  dispatches on `status` first and the class sets are disjoint, so the falsifiable version is the
  within-status tail (`DEFERRED_UNCLASSIFIED` = 0, `UNCLASSIFIED` = 0, `GITHUB_PUSH_UNBUILDABLE` = 0);
  `BOX_AT_CAPACITY_DEFERRED` has **never fired in production** (all 528 are `BOX_BUSY_DEFERRED`) because
  #9827 is unmerged, so any criterion reading capacity deferrals is unsatisfiable until it lands; the
  per-site split **cannot be delivered as a before/after rate** at this window — every BEFORE per-site
  cohort is 110-114 rows and `rate/2` REFUSES all six, and clearing 200 per-site needs BEFORE to reach
  back ~35 hours (`perfect-proof`, 165 rows in ALL history, can NEVER clear it and its refusal must be
  PRINTED); and the failure mass must be split by cause or the headline over-claims — **144 Turbopack
  rows belong to `search-capstone` ALONE (a site-source compile error, 19% of the numerator) against 298
  `BOX_500 internal_error` rows spread over five sites and three stages**, the latter already root-caused
  as the Postgrex/swap class of D75. Finally the census is a **one-box census** (12 of 13 deploying sites
  live on guerrilla). **AND THE THESIS BITES ITS OWN HEADLINE:** `GET /v1/operator/deploy-ledger/census`
  returns **403 `required: platform_operator`** for the configured operator, because `PLATFORM_ADMIN_EMAILS`
  is **UNSET** in the running `cloud-control_plane_blue-1` container (`runtime.exs:337-340` defaults it to
  `""`), and `git grep 'deploy-ledger' -- internal/ js/ web/` is **EMPTY** — no CLI, SDK or web reader
  exists. The epic's own census is a measurement no human can reach. **RULING: the number above is the
  record; the reachability is a LEAD OPS action (set `PLATFORM_ADMIN_EMAILS`) filed as a backlog row, and
  a CLI reader is filed behind it — building a reader for a route that 403s for everyone would be theatre.**

- **D77 — `drafts.*` TWINS ARE DISCARDED, NEVER CLOSED AND NEVER PUBLISHED; THIS CHARTER ADOPTS
  cch D105 + D190 BY REFERENCE.** *Why:* the epic carries **88 children — 78 open + 10 done, ZERO
  in_progress** — and **11 of the 78 open are `drafts.*` phantoms**, separate DOCUMENTS with their own
  UUIDs (`drafts.dr-w4-s4…` is `18f8b78c-…` at 0/8 while the published `dr-w4-s4…` is `68c44be7-…`,
  **done 8/8**), holding stale criteria snapshots. Two of them shadow SHIPPED slices, and they are
  **CLAIMABLE**: `bp task ready --all` serves 1,952 rows of which **65 are `drafts.*`**, including this
  epic's own goal row and a done slice, because `queue.ex:105-110` has no publication predicate. The
  disposition is already ruled twice in another charter and was never imported here — D105: "count
  `drafts.*` entries as duplicates, never as rows"; D190: "CANCELLED via `bp doc discard-draft`, **never
  closed** … publishing is the dishonest option (it resurrects finished work); closing them is the second
  dishonest option (it treats a duplicate as a row and buys a fake row-shrink)". **RULING: adopted
  verbatim. The honest denominator for this epic is 77 rows, never 88, and never 78 open.** The one
  genuine orphan — `drafts.task-aa775c3d30287a4b`, which is the OWNER'S WISH restated and has no published
  twin at any slug — is PUBLISHED, not discarded. Two open rows own the same `/v1/agent/space` route
  (`task-3b69c3e24bf3d8ca` 13:12:54Z and `task-ca88b8ea571b3470` 14:29:32Z); the older/richer one is kept,
  the younger one's UNIQUE arm (an agent that has proved its consumer absent must BACK OFF, not repeat a
  404 ninety-six times a day) is FOLDED IN before it is closed as a dup. And a pattern worth a standing
  line: **four stale-open rows are blocked forever on "the PR body states X" for a PR that already
  merged** — a criterion satisfiable only before merge is unsatisfiable after it, and must be written as a
  post-merge derivation instead.

### Wave 5 plan — 5 slices, 4 in round 1

| # | Slice | Task id | Round | Model | Surface |
|---|---|---|---|---|---|
| s1 | The triage ladder lands eleven rungs — `strained`, `filling`, `unreported` reach `bp cloud status` | `dr-w5-s1-ladder-reaches-triage` | 1 | opus | `internal/cli/`, `internal/semrole/`, `internal/cloudclient/client.go`, `cloud/priv/static/__fixtures__/attention_order.json` |
| s2 | The beat learns the two things the box already measures and throws away — `load15` and its own 5xx rate | `dr-w5-s2-beat-carries-load15-and-5xx` | 1 | opus | `cmd/barkpark-agent/`, `internal/agent/report.go`, `api/lib/barkpark_web/request_stats.ex`, `cloud/.../web/router.ex` (pressure region) |
| s3 | The control plane lands space — the route, the type, and the window the fetch was silently shortening | `dr-w5-s3-cp-lands-space-and-fixes-the-window` | 1 | opus | `cloud/.../web/router.ex` (agent-route region), `registry/agent_event.ex`, `registry.ex`, `metrics.ex`, `telemetry.ex` |
| s4 | The agent's binary reaches the fleet — the self-update path rebuilds it | `dr-w5-s4-agent-binary-reaches-the-fleet` | 1 | opus | `scripts/apply-update.sh`, `scripts/deploy-rebuild.sh` |
| s5 | Space is measured by HOST consumer, so the box at 95% names its own 25 GB | `dr-w5-s5-space-by-host-consumer` | 2 (after s2, s3) | opus | `cmd/barkpark-agent/main.go`, `internal/agent/report.go` |

**Model note:** every slice is `opus` by AVAILABILITY (Fable is unavailable for subagents) *and*, this
wave, by merit — the SPA grant was withdrawn (D68), so **no slice in this wave is a visually-designed
surface**. On difficulty grounds **s1** (an eleven-rung reconciliation across three pins plus two fences)
would still have drawn `fable`; weight review attention there.

**HIGH-FLIP-RISK, owed a genuinely INDEPENDENT second reviewer before merge — a MANUAL LEAD STEP this
wave ARRANGES rather than discovers:** **s1** (the ladder ordering and the bucket boundary — being wrong
means shipping a Go ladder that contradicts a LIVE production console, and a half-landing buckets a
strained box HEALTHY); and **#9827 itself**, whose sole unmet criterion is the door-vs-unit race review
(D73) — the Sobelow doctrine is discharged, the human is not.

**Sequencing:** s5 is round 2 because it edits the same two files as s2 (`internal/agent/report.go`,
`cmd/barkpark-agent/main.go`, different structs) AND because its live proof needs s3's route to exist —
the space POST currently 404s into the void. s1 decodes `load15` and `err_5xx_per_s` as nullable keys that
s2 emits, which is a WIRE relationship and not a code dependency: absent → nil → honest silence, so both
build in round 1. s2 and s3 both touch `router.ex` in regions ~7,400 lines apart (`@unmetered_pressure`
:468-486 and `merge_pressure/2` :8744-8770 vs the agent routes at :1270-1350); each brief states its
region.

**What this wave does NOT promise.** The CONSOLE still shows a strained box as "Healthy" (D68) — that is a
stated, owned cost, not an oversight. `MemoryHigh` stays parked, and D64's caveat is now a MEASURED ratio
rather than a remembered sentence: `vm_memory_total` 560.7 MB against a same-minute `beam_pss` 878.6 MB +
`beam_swap` 630.3 MB = 1,508.9 MB, a **948 MB / 2.69× gap**, with PSS corroborated against
`/proc/<pid>/smaps_rollup` inside 2% — so a bound read off `:erlang.memory()` would sit ~2.6× below the
2.98–3.30 GB anon-rss the kernel has actually been reaping (32 of 32 OOM victims are `beam.smp`, two of
them today, on a unit with `MemoryHigh=infinity`). The correct input is PSS+swap or, better, the per-slot
cgroup `MemoryPeak`/`MemorySwapPeak` systemd already keeps — **and a prerequisite nobody had named is now
filed: the agent's `findBeamPID` returns the LEXICALLY FIRST `/proc` entry named `beam.smp`, so across a
blue/green cutover (8m30s of overlap today) the `beam_*` series silently changes process, in violation of
the standing `pds-w11-paired-control-measure` ruling to sample ALL slots and report the MAX.** The pool
partition stays with `jpf-bl-oban-pool-partition` (D28, D65, D75). Disk RECLAMATION stays with
`jpf-runtime-image-pruning` — this wave makes jarl's 25 GB VISIBLE and NAMED (D69, D71) and deletes
nothing. `db_unavailable` on the wire is filed, not built: `errors.ex:205-209` shows a new code drags the
OpenApi enum plus `error_code_coverage_test.exs`, and `openapi.json` cannot be regenerated locally.
`/v1/graph` failing 51.6% of its requests is FILED, not absorbed — it is real, it is worse than anything
this epic tracks, and taking it would cost the wave its last-mile shape.

---

### Wave 2026-08-06 (wave 5) — REVIEWED · Paper `deploy-reliability-wave-5-2026-08-06` · grade **A−**

**Four of five slices built, reviewed, gate-green on the final state, pushed and PR'd. Nothing merged — the
lead merges.** The fifth (`dr-w5-s5`, space by HOST consumer) is round 2 BY DESIGN, behind s2 and s3.

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| The eleven-rung triage ladder | `dr-w5-s1-ladder-reaches-triage` | `…eleven-rungs-bp--0` (unchanged) | [#9887](https://github.com/FRIKKern/barkpark/pull/9887) | build + vet + `internal/cli` and `internal/semrole` green; gofmt clean |
| The beat learns `load15` + its own 5xx | `dr-w5-s2-beat-carries-load15-and-5xx` | `…the-box-a-1` (unchanged) | [#9888](https://github.com/FRIKKern/barkpark/pull/9888) | Go suites green · api 19/0 · cloud 23/0 |
| The CP lands space, and the window is fixed | `dr-w5-s3-cp-lands-space-and-fixes-the-window` | `…the-agent-s-spac-2` (unchanged) | [#9889](https://github.com/FRIKKern/barkpark/pull/9889) | 44 tests, 0 failures · `mix format` clean |
| The agent binary reaches the fleet | `dr-w5-s4-agent-binary-reaches-the-fleet` | `…the-fleet-the-s-3-r` | [#9890](https://github.com/FRIKKern/barkpark/pull/9890) | `bash -n` × 3, exit 0 |

**What landed — and this wave finally answers the question the epic opened with.** For four waves the
owner's complaint has been that `bp cloud status` calls a box "ok" while the box is drowning. #9887 closes
it, and the proof is a LIVE read off the real control plane with a `bp` built from the commit under test
(sha `aa19dcca3`, D70's provenance rule honoured): **guerrilla ranks `strained` rank 5 attention** —
"load 5.9 on 2 cores (2.9x, 1m avg) · 1.2 GB in swap" — and **jarl ranks `filling` rank 6 attention** —
"disk 95% used (fills at 90%) · vitals unreadable — agent predates the vitals beat". Both read
`ok / rank 8 / healthy` before that commit. Buckets went `{attention: 4, healthy: 2}` over six boxes. The
D69 ladder landed atomically at eleven rungs with every shipped bucket assignment preserved exactly, and
the `filling` fence is not a second number — `TestFillingThresholdMatchesUsageMeter` reads the ceiling out
of `usage.ex` itself, so the verdict surface and the meter surface cannot drift apart again.

Underneath it, #9888 makes the box report the two scalars it was already computing and discarding: the
kernel's 15-minute load average (`fields[2]`, in memory and thrown away) and its own 5xx rate (Phoenix hands
`RequestStats` the conn and the handler bound `_meta`). D67's 1.75x threshold was **re-derived on real
`fields[2]`** as the decision demanded — healthy ceiling 0.340/core against a strained floor 2.635/core, a
7.7x margin, wider than the reconstruction implied and in the predicted direction. #9889 gives the agent's
15-minute space payload a landing site at last (`"space"` was outside `AgentEvent`'s `@types`; the pre-change
`record_event` rejection is quoted from a run) and fixes a defect that was live and unrelated: the metrics
fetch limited the MIXED stream, so `?points=200` rendered 188 while the envelope claimed 200 —
mutation-proven, with the guard placed in the DB-backed test because the 14 pure tests were structurally
incapable of seeing it. #9890 ends the structural staleness: the agent binary was built once at warm-pool
arm time and never again, on both self-update lanes, and the hot lane is the one `freshen.go:100` runs.

**What did NOT land, and must be said plainly.**

1. **Nothing renders the space payload.** #9889 lands the data and stops, so the wish's "see what is taking
   up space" is NOT satisfied end to end by this wave. Filed as `dr-w5-s3-followup-render-the-space-payload`.
2. **The CONSOLE still calls both of those boxes "Healthy · Online."** That is D68's stated, owned cost, not
   an oversight — but for an epic whose complaint was operator surfaces contradicting each other, shipping a
   two-tier ladder is an uncomfortable state to sit in. Filed as `dr-w5-followup-spa-ladder-two-tier`.
3. **`err_5xx_per_s` reaches the wire and the Go struct and NO operator's eyes.** Found by the reviewer in
   the seam between #9888 and #9887: neither slice is at fault (D75 scoped to landing the field, D69's ladder
   to load and disk), but after both merge a human still cannot see the sentence D75 exists to make sayable.
   Filed as `dr-w5-followup-5xx-reaches-no-eyes` with the rung-vs-detail-line ruling left open.
4. **The wish's third clause — capping concurrent builds — is untouched by this wave**, and correctly so: the
   cap is #9827, whose sole unmet criterion is a human's independent review of the door-vs-unit race (D73).
   Doctrine is discharged; the human is not.
5. **Two live proofs are honest misses, not failures.** #9888's criterion 6 (a real beat carrying the two new
   fields) needs a deploy, not a merge. #9890's criteria 5-6 (a box actually refreshing its binary) would have
   meant pushing unmerged code onto a production host. Both left OPEN with recipes rather than faked — which
   is exactly the discipline the epic is about, and which makes #9890 the merge that unblocks #9888's proof.
6. Every slice's last criterion is merge-gated and stays OPEN for the lead to close on merge.

**HIGH-FLIP-RISK, still owed:** #9887's ladder ordering and bucket boundary. The wave reviewer performed an
independent re-derivation against `origin/main`'s `ATTENTION_RANK` and `bucketOf` and confirms it — that is
ONE reviewer. A genuinely independent second read before merge is a MANUAL LEAD STEP.

**What the next wave takes.** (a) MERGE ROUND 1 in dependency order, then dispatch `dr-w5-s5` — it edits the
same two files as s2 and its live proof needs s3's route to exist. (b) The three render gaps above, which
together are the whole remaining distance between "the instrument measures it" and "a human sees it":
`dr-w5-s3-followup-render-the-space-payload`, `dr-w5-followup-5xx-reaches-no-eyes`, and
`dr-w5-followup-spa-ladder-two-tier`. (c) The two live proofs, which cost a deploy rather than a wave.
(d) #9827's human review — the only thing between this epic and the wish's build-cap clause.

---

## Wave 6 decisions — MERGE AND RENDER (2026-08-06)

Wave 6 builds almost nothing new. It lands what four waves already built, opens the one drawer still shut,
and refuses to let a box wear a green rank it did not earn. Every decision below was re-derived this session
against `origin/main` = `ef77af2748ceda54fdd6e078f71a6e6044b55439`, with run output, not inherited.

**CITATION NOTICE.** `D67`–`D77` return **zero** hits on `origin/main`'s charter (`grep -cE '^\*\*D(6[7-9]|7[0-7])'`
→ `0`). They live only in the still-open wave-5 charter PR **#9876**. Any slice citing the `load15` fence
(D67), the eleven-rung ladder (D68/D69), the multi-root ruling (D71) or the 5xx ring (D75) cites **the PR**,
never main — a builder who `git show origin/main`s them will re-derive the wrong thing. This wave-6 charter
PR is **stacked on #9876's head** precisely so that merging it lands both waves' decisions in one act and
closes that hole; #9876 can then be closed as superseded.

- **D78 — SLICE 1 IS A REPAIR, NOT A RE-RUN: #9888 BREAKS A REQUIRED CONTEXT ON A FILE IT NEVER TOUCHED.**
  *Why:* the four-PR stack merged onto `ef77af274` builds and vets clean (Go `build`/`vet`/`test ./...` all
  rc=0; `cloud` 2965 tests 0 failures; 139 files compiled with zero warnings) — with **exactly one**
  stack-induced red, and it is enforced. `api/test/barkpark_web/controllers/request_stats_controller_test.exs:40`
  asserts the 3-key wire contract and #9888 widens the payload to four: `left: ["err_5xx_per_s","p95_ms",
  "req_per_s","window_s"]` vs `right: ["p95_ms","req_per_s","window_s"]`, deterministic, 3 tests / 1 failure.
  #9888 updated only the UNIT test (`request_stats_test.exs`, 19/19 green); the CONTROLLER test that pins the
  contract is untouched by the whole stack (`git diff --stat origin/main HEAD` on that path is empty).
  Probe-reverting the three api files makes it PASS and leaves the other four api failures standing, so
  exactly 1 of 5 belongs to the stack. **RULING: widen that assertion and update
  `request_stats_controller.ex:14`'s moduledoc (which still pins the 3-key shape and cites a dangling "OC24")
  INSIDE #9888's own diff. A builder briefed "just re-run it" will push and watch the same gate go red.**

- **D79 — REPAIR IN PLACE. RE-CUTTING ANY OF THE FOUR PRs TURNS A GREEN REQUIRED CONTEXT GENUINELY RED.**
  *Why:* `scripts/pr-task-gate.sh` PASSES today for all four against the live guerrilla ledger — but only
  through D58's grace branch: *"open, but the claim by '…' was still live when this PR was opened (it lapsed
  909–1976s after, and was reaped 1821–2784s ago)"*. Every claim has since been reaped, and the workflow
  anchors on `pull_request.created_at`, which its own comment documents does NOT move on `synchronize`.
  So a **re-run clears it and a push buys nothing** — but a close/re-open, or re-cutting the work onto a
  fresh PR, moves `created_at` past the lapse and turns a green required context genuinely red.

- **D80 — A RED NAME IS NOT A DIAGNOSIS: THE ACTION-RESOLUTION OUTAGE IS A THIRD RED CLASS.** *Why:* all
  eight reds on #9887/#9888/#9889/#9890 died inside `Prepare all required actions` — `Getting action download
  info` → `Failed to resolve action download info. Error: Service Unavailable` → `##[error]Service
  Unavailable` — **before checkout, before any script ran**. No gate scan exists in any of those logs.
  I re-ran the eight deciding commands at three tree states per PR (head sha, GitHub's `refs/pull/N/merge`,
  and the TRUE merge onto `ef77af274`): **96 invocations, zero failures**, and the pass is not vacuous —
  appending 500 bytes to `docs/cards/cli.md` made budgets rc=1 (`FAIL: docs/cards/cli.md is 2877B, cap is
  2400B`) and rc=0 again on restore. Three riders: (a) the required **`Cloud gate`** WAS red on `aa19dcca3`,
  as a correct downstream refusal on outage-`abandoned` upstreams (`FAIL changes (dispatcher): unrecognised
  result 'abandoned'. Cannot tell, therefore red.`) — so "none of the failing names is required" is FALSE;
  (b) a check-run's `completed_at` can **lag the job's real death by 42 minutes** (Filebase on `e92cb6fe9`
  reports 17:46:12Z; its log's last line is 17:04:11Z) — date failures by the LOG's timestamps, never
  `completed_at`; (c) `gh run rerun --failed` is **REFUSED while any sibling job in the run is queued**
  (`cannot be rerun; This workflow is already running`), so the re-run is gated on the queue draining, not on
  the fix.

- **D81 — MERGE DAY CHANGES ONE BOX. THE FLEET IS RELEASE-PINNED AND NO MERGE CAN REACH IT.** *Why:*
  `deploy/instance-deploy.sh:818` is the **only** line in the repo that rebuilds an existing box's
  `barkpark-agent` (`grep -rn barkpark-agent scripts/ .githooks/` → zero), and deploy.yml's `instance` job
  SSHes exactly one host, `$GUERRILLA_HOST`. Every other box updates only through
  `Barkpark.SelfUpdate.Checker`, which decides `:behind` by comparing **A.B.C semver releases** — and live,
  all six boxes report `update_state: current` at `0.2.25`, cut **2026-07-08**, `git rev-list --count
  v0.2.25..origin/main` = **2484**. `AutoupdateRolloutWorker` walks instances reporting `behind`; there are
  none, so it advances nothing, forever. Confirmed by `strings`: `load15` and `err_5xx_per_s` are on **zero**
  deployed binaries including guerrilla's newest (Aug 6 14:22); `cpu_cores` is on exactly **one of six**.
  **RULING: no agent-side criterion may say "the fleet", "the boxes" or "every box". It says "guerrilla
  (157.180.90.121), the only box deploy.yml's `instance` job reaches", and carries a paired,
  explicitly-DEFERRED sentence naming the other five and the reason.** Cutting and blessing `v0.2.26` is the
  sole mechanism that carries anything to **jarl — the 96%-full box the wish is literally about** — and it is
  a NAMED HUMAN GATE, filed to the backlog, not a slice.

- **D82 — PROVENANCE CLAUSE: THREE QUOTED READS OR THE CRITERION IS STAMPABLE FROM A UNIT TEST.** *Why:*
  "the beat carries `load15`" is satisfiable by `internal/agent/report_test.go` alone, on a field no deployed
  binary emits. **RULING: every agent-field criterion quotes, in this order — (i)
  `ls -l --time-style=+%F /usr/local/bin/barkpark-agent` on the named box, mtime AFTER the slice's merge;
  (ii) `strings -a /usr/local/bin/barkpark-agent | grep -c '<field>'` ≥ 1 on that same box; (iii) the live
  `/v1/barkparks` JSON excerpt showing the field non-null.** Companion clauses: **MERGE ≠ DEPLOY** — no live
  criterion is stamped in the same hour as its merge, and the evidence quotes
  `gh run list --workflow=deploy.yml --branch=main` reporting `conclusion=success` for that sha (measured:
  `ef77af274`'s deploy run sat `queued` 50+ minutes behind 49 runs at effective concurrency 1); and **FIXTURE
  BAN** — `__fixtures__/attention_order.json` and `testdata/attention_order_cases.json` may satisfy a
  CROSS-SURFACE-AGREEMENT criterion and may never satisfy a SEEING criterion.

- **D83 — THE PRIMARY `strained` ARM IS DEAD CODE ON MERGE DAY; SAY WHICH ARM FIRED.** *Why:* `load15` and
  `err_5xx_per_s` are absent from main, from every live payload, and from every deployed binary, so the
  1.75×/core 15-minute fence is unreachable and only the **2.0 `load1` fallback** can fire, on guerrilla
  alone (live `load 6.3 on 2 cores (3.1x, 1m avg)`). **RULING: any `strained` criterion states WHICH ARM
  fired with the arithmetic quoted; a fallback pass is stamped MET-BY-FALLBACK and adds "primary arm
  (load15 ÷ cpu_cores ≥ 1.75) unproven — load15 is on zero deployed binaries". A stamp produced by
  `unmeteredMarker` is not a `strained` stamp and is its own row.** Rider: **D67's stated rationale is
  REFUTED** — over 30 live readings guerrilla's `load1` ran 3.27–3.85×/core, consistently HIGHER than its
  `load15` at 2.775–2.910×/core, so the fallback is not "strictly less sensitive"; it is noisier in both
  directions and on a rising box it fires FIRST.

- **D84 — THE FENCE ITSELF IS SAFE AND WILL NOT BE RE-DERIVED AGAIN: A 50× CANYON.** *Why:* 30 live readings
  of real `/proc/loadavg` `fields[2]` across all six boxes (all `nproc` = 2): guerrilla 2.775–2.910×/core
  firing **5/5** with zero flap, against a healthy ceiling of **0.055×** (jarl). Any threshold in
  (0.06, 2.77) yields identical verdicts on that window; 1.75 sits 1.59× below guerrilla's floor and 31.8×
  above the healthy ceiling. Rider, and it is a real tripwire: **`LC_ALL=C` on every load-ratio computation** —
  under this shell's locale `awk` printed `2,500` for `2.775` and mangled the magnitude while looking
  plausible.

- **D85 — MULTI-ROOT SPACE MEASURES IN KiB, AND THE OBVIOUS WAY TO DO IT SHIPS A SILENT 1024× LIE.** *Why:*
  `parseHumanBytes` (`report.go:1023`) falls through to `strconv.ParseInt` and accepts a **bare integer as
  BYTES**. Flipping `duSitesArgs` from `-hx` to `-kx` without changing `parseDuTree` therefore produces a
  complete, sorted, error-free list understated by exactly **1024×** — proved on jarl's real rows: total
  parses as 27.17 **MiB** where the truth is 27.17 **GiB**, containerd "13.2 MiB" for 13.2 GiB. No fixture on
  main would catch it (every `du` fixture is `-h`). And `-h` is not good enough: on jarl's `/var/lib` it
  **overstates by 853 MiB (+3.07%)**, which is ~48% of that box's remaining 1.78 GB of headroom.
  **RULING: take `-kx` AND give `parseDuTree` an explicit unit parameter with fixtures duplicated in both
  units. This OVERRIDES `dr-w5-s5` criterion 1's "reusing `duSitesArgs` and `parseDuTree` UNCHANGED —
  generalized by renaming, not rewritten": a rename-only generalization is unsafe here.**

- **D86 — DISCARD ON KILL, LAND ON DEGRADED. A NON-ZERO `du` EXIT DOES NOT IMPLY TRUNCATED OUTPUT.** *Why:*
  the discard rule HOLDS end-to-end — a REAL `du` killed at a REAL 400 ms deadline on the loaded box returned
  `(-1, nil, "timed out after 400ms")` through the real `boundedSpaceRunner`, and `gatherSpace` reported
  `sites_bytes -1 / sites_top nil`. But the OPPOSITE hazard is the live one: an unprivileged `du -hx -d1`
  over a tree with one unreadable subdir printed **every row including the total** and exited **rc=1**. The
  current rule would throw away a complete, correct measurement whenever one child is unreadable or vanishes
  mid-walk — and `/var/lib` is exactly where containerd and barkpark-builder churn. (Mitigating: 10 real runs
  per box across both roots on guerrilla AND jarl were all rc=0 with empty stderr, so the hazard is
  demonstrated, not currently firing.) **RULING: discard on kill/timeout/missing-total-row; LAND when the
  total row is present and every row parsed, and name which roots were degraded.** Two riders: the existing
  `TestSitesProbeNonZeroExitDiscardsPartialOutput` (`report_test.go:885`) already pins the single-root kill
  case, including the killed-with-a-parseable-total-row shape, and **PASSES** — do not re-cut it; and it does
  **not** match `-run 'Space|Du|Tree'`, so that regex "proves" the rule with a run that never executes it.

- **D87 — TWO ROOTS NAME ~85% OF jarl AND ~28% OF guerrilla: THE COVERAGE RULING IS jarl-SPECIFIC.** *Why:*
  jarl is 96% used (35,516,368 of 39,027,964 KiB, 1.78 GB free), `/opt/barkpark/sites` **DOES NOT EXIST**
  there, and `/var/lib` is 28,486,324 KiB (containerd 13.8G + barkpark-builder 11.3G + snapd 2.9G) which with
  `/opt/barkpark` is **82.4%** of used. Guerrilla's same two roots are **28.2%** — the rest is `/var/log`,
  `/root` and `/tmp`. `/var/lib/docker` is a **2.0M decoy**: docker reports 14.12 GB of images and those bytes
  physically ARE `/var/lib/containerd` (containerd snapshotter). **Name PATHS, never daemons, and never state
  the coverage figure fleet-wide.** Cost, re-measured: worst two-root walk **~6.1s** on jarl (the survey's
  14.6s does not reproduce), ~10% of the 60 s bound against a 15-minute cadence — but the bound is **per
  shell-out**, so N roots buy N×60 s of worst case in one cycle: bound the SLICE, not just each root.

- **D88 — THE UNMETERED MARKER IS BUILT AND RENDERS LIVE. SLICE 3 IS THE 5xx HALF AND THE `degraded` HOLE.**
  *Why:* `unmeteredMarker` ships inside #9887 as an explicit DETAIL line ("charter D69 — deliberately NOT a
  rung"), correctly disjoint from `unreported` by construction (the marker requires a PRESENT `reported_at`;
  `unreported` requires an EMPTY `last_seen_at`). A `bp` built at `aa19dcca3` and run three times against the
  REAL fleet printed the finished experience verbatim: `strained Guerrilla … load 6.3 on 2 cores (3.1x, 1m
  avg) · 1.7 GB in swap`, `filling jarl … disk 96% used (fills at 90%) · vitals unreadable — agent predates
  the vitals beat`, `unreported muscle-1`, and the HEALTHY bucket **grew a DETAIL column** for dooodo and gyl
  (`withDetail` is scanned PER BUCKET). **Do not re-cut it.** Two real holes remain: **(a)** `degraded` is
  rung 4 and `strained` rung 5, and `attentionDetail` has arms for removal_failed/failed/suspended/strained/
  filling but **none for degraded**, so a degraded box renders `—` and loses its reading exactly when it is
  most diagnostic — observed live on guerrilla mid-flap at 17:41:23Z, then `strained` with the full sentence
  two runs later; **(b)** `Err5xxPerS` is decoded by #9887 and read by nothing (zero hits in
  `cloud_status_cmd.go`). Corrections to the direction: the marker is live-eligible on **four** of six boxes,
  not five, and only **two** (gyl, dooodo) would otherwise wear a serene `ok`; and the console has **not**
  shipped `unreported` — main's `classifyBp` and the shared fixture carry eight states.

- **D89 — THE OWNER'S BINARY IS THE LAST MILE, AND `make cli-install` FROM MAIN DOES NOT FIX IT.** *Why:* a
  clean `make cli-install` from a fresh clone at `ef77af274` produces a binary whose count for
  `swap_used_percent`, `cpu_cores`, `beam_pss_bytes`, `beam_swap_bytes`, `disk_used_percent`, `load1`,
  `strained` and `filling` is **0 for every one** — main's `cloudclient.Barkpark` has no `Pressure` field at
  all. A binary built at #9887's head has 3 and renders the ladder. **The fix is ONE MERGE plus ONE REBUILD**,
  and it must be an explicit imperative owner-facing line, because three instruments actively say nothing is
  wrong: `bp doctor --onboarding` returns `"cli":{"installed":"dev","up_to_date":true,"detail":"running a dev
  build — release comparison skipped"}` with `ok:true` exit 0 (`doctor_onboarding.go:298`); `bp upgrade
  --check` refuses on the dev ground and exits **2**, not the documented 1-when-behind; and the `cli-v*`
  channel `bp upgrade` resolves against is tag-driven and 13 days stale (newest `cli-v1.16.0`, 2026-07-24), so
  merging publishes nothing. The owner's installed `bp` is `f59aaf717`, 2026-07-31, **322 commits behind**.
  **RULING: a dev build reports UNKNOWN, never up-to-date — honest silence, not a claim. That is this epic's
  own doctrine, applied to its own instrument.**

- **D90 — THE AFTER-MEASUREMENT PUBLISHES 41.77% → 43.76% AND SAYS THE RATE **ROSE**.** *Why:* taken through
  `DeployLedger.census/2` on the live node (via `rpc` — `eval` cannot run it: *"could not lookup Ecto repo
  BarkparkCloud.Repo because it was not started"*), at BEFORE `[2026-08-05T17:00Z, 21:24Z)` / AFTER
  `[21:24Z, 2026-08-06T17:03Z)`: old convention **89.38 → 74.68**; shipped-as-is **89.38 → 43.76** (that row
  compares two DIFFERENT conventions and must never be published as repair); shipped **doctrine-matched**
  **41.77 → 43.76 = +1.99 pp REGRESSION**. Busy-refusal pressure fell (47.6% → 30.9% of volume) while settled
  failures rose, and `BOX_500` per attempt went **8.67% → 15.31%** — doubled, not "tripled", and the digest's
  46.41% doctrine-matched BEFORE is **unreproducible through the instrument at this pin**; 41.77% is the
  derivable value. Census matches the psql pin **exactly** (volume 1947, failed 852, deferred 602, live 493)
  and reproduces D76 byte-for-byte. There is **no `OTHER_FAIL` bucket**: eight classes sum to exactly 852,
  `UNCLASSIFIED` 0, `not_attempted` empty. NEW and cheap: **138 rows — 16.2% of the failure numerator — are
  `the instance refused the deploy (HTTP 503): feature_not_configured — site deploys are not enabled on this
  instance (set BARKPARK_SITE_DEPLOY_APPLY=1)`** across all five hot sites: a configuration tombstone counted
  as a deploy failure. Two `dr-w2-s8` criteria are now false as written — search-capstone is **not** 0-live in
  the AFTER window (12 live), and the source is the instrument via an operator shell, not psql (the HTTP
  route remains 403-dark), which is a strictly stronger claim than the criterion asks for.

- **D91 — THE CAP IS MERGED, IS NOT RUNNING, AND WOULD BIND HARD.** *Why:* guerrilla's checkout is
  `33bb65496` and `git merge-base --is-ancestor ef77af274 HEAD` returns **CAP_ABSENT**; `grep -c
  box_at_capacity api/lib/barkpark/sites/deploy_runner.ex` **on the box** = 0. Zero `box_at_capacity` rows
  have ever existed in production — that is evidence the cap has not shipped, **not** evidence it is broken.
  The feared ordering bug does not exist: `running_slug?` is keyed on `req.slug` while `box_at_capacity?`
  counts `building_slugs(state)` across every deploy-mode run, so the two predicates are **disjoint by
  construction** and `already_running` can never mask a capacity refusal. Neither upstream lock preempts it
  (`deployments_active_site_env_index` is same-site; Oban `site_deploy: 1` serializes JOBS not builds, as the
  code's own moduledoc says). And it will bind broadly: **9,189 of 11,384 non-deferred deployments in 7 days
  (80.7%)** had a foreign-site deployment start within 60 s, so the deferral rate steps on merge day and any
  measurement taken across that boundary must be stratified by class. The retry pipe is alive at volume on
  its sibling path (603 `already_running` deferrals in 2 days; all 5 deferring sites later reached `live`).
  **RULING: slice 3 publishes the STRUCTURAL proof now and states the live refusal as DEFERRED behind a
  deploy, quoting the `merge-base` precondition.** Rider: `systemctl is-active barkpark` reads `inactive`
  **correctly** — that unit is disabled legacy; the live runtime is `barkpark-slot@green` on :4001 and the
  public API answers 200. Any triage rung reading that unit manufactures a fleet-wide false red.

- **D92 — THE HONEST DENOMINATOR IS 71, AND `dr-w3-s7` IS SUPERSEDED — DO NOT RE-CUT IT.** *Why:* the parent
  rail carries 98 children = **86 open + 11 done + 1 cancelled**; 86 − 13 (stale-open rows whose PR already
  MERGED) − 1 (`drafts.*` phantom double-count) − 1 (`dr-w3-s7`) = **71**, of which 4 are BUILT and sitting in
  #9887–#9890, so **67 unbuilt**. D77's "88 / 77 / eleven phantoms" is stale in both directions: the tree
  grew and the drafts cleanup already happened — **one** phantom survives. `dr-w3-s7-strained-reaches-triage`
  (0/11) is superseded by `dr-w5-s1` (11/12, #9887): its own description opens *"THIS SLICE DOES NOT BUILD
  THIS RUN"* and its `files` list is a strict superset. The "PR body states X" criteria are **five, not
  four**, and only **three** are dead: `dr-w2-s4` idx 5 is SATISFIED verbatim in #9731's body line 3 and
  `dr-w2-s6` idx 3 in #9733's body line 7 — both merely unstamped. The phantom
  `drafts.dr-w5-s4-agent-binary-reaches-the-fleet` holds **2/8** where the published twin holds **4/8**, and
  the two shared evidences are byte-identical (461 and 1108 bytes, string-equal), so it is a strict SUBSET:
  copy-before-discard is a **no-op** and discard is safe. Retro-editing a merged PR body to turn a dead
  criterion green would be exactly the vacuous pass this charter forbids — retire them instead.

- **D93 — THE LEDGER'S OWN INSTRUMENTS LIE, SO EVERY CENSUS READS THE PARENT RAIL.** *Why:* `bp doc get task
  drafts.<id>` returns `not_found` for a draft that provably exists (`bp task get drafts.<id>` returns it),
  and `bp doc query task --filter '_id*=agent-binary' --count` returns `total 0` for a document `bp doc get`
  fetches. `bp search` finds the row only by typo-widening, never by exact id. **Any census built on `_id`
  filters or on search is silently vacuous; the only reliable enumeration of this epic is
  `bp task get task-fb4fb869490b4213`.** Filed as an instrument defect.

- **D94 — THE CESSION IS RE-ASSERTED UNILATERALLY, AND THE REAL RACE IS `router.ex`, NOT THE VITALS SEAM.**
  *Why:* cch's declared fence is the **bare `cloud/` tree**; the vitals cession exists only as one sentence in
  that charter's **Wave 36** block — *"deploy-reliability wave 4 owns those this round"* — wave-scoped and
  naming wave 4, hence expired by that charter's own subject-scoping law (D346/D357). Its wave-37 charter
  (#9857) does not re-issue it and mentions this epic nowhere past wave 4. **Wave 6 re-asserts:
  `attentionStatus()`, `internal/cli/**`, `internal/cloudclient/**`, `internal/agent/**`, `cmd/**` and the
  fleet-vitals seam in `registry.ex`/`telemetry.ex`/`metrics.ex` are OURS; `cloud/priv/static/app.js`,
  `__app.test.mjs` and the console path-escape scripts are THEIRS.** Practically the exposure is nil on the
  vitals seam — #9857's D418 explicitly defers the CLI change to cch's backlog and D420 measures
  `primary_team` at **zero files under `internal/`**. The live collision is `cloud/lib/barkpark_cloud/web/
  router.ex`: cch w37 slice 1 takes 18 route-scope sites in the band 2059–8291 while #9888 sits at 481/8764
  and #9889 at 58/1319/7776 — **nearest separation 423 lines** (the survey's "~7,400" is wrong; the
  conclusion survives, the number does not). **Land #9888/#9889 before #9857's builders dispatch.** All ten
  merge trials are CLEAN against today's tip, and a four-deep SEQUENTIAL stack simulation
  (main → 9887 → 9889 → 9888 → 9890) is clean at every step, ending at tree `20b3ed45e4`. One stale foreign
  toucher, #6028, has **no merge base with main at all** and cannot land ahead of the wave.

- **D95 — CI CAPACITY IS THE CONSTRAINT: BUDGET BY PUSH COUNT, NOT RUNNER-MINUTES; FIVE SLICES, TWO NEW PRs.**
  *Why:* measured at decision time, **59 workflow runs QUEUED with 0 in_progress** — effective concurrency
  ~1, and a re-run fired earlier sat queued 18+ minutes without starting while the queue deepened 49 → 58.
  Four workflows have **no path filter at all** (`elixir.yml`, `pr-task-gate.yml`, `reland-check.yml`,
  `aesthetics-guard.yml`), so even a docs-only PR pays the 9-job Elixir gate; there is no cheap PR in this
  repo, only cheaper ones. `elixir.yml`'s triggers must NOT be narrowed inside this wave — it is the enforced
  context, and a non-matching diff reports "expected" forever and deadlocks the merge. **RULING: wave 6 cuts
  five slices, three in round 1, and spends exactly two new PRs — slice 1 pushes to an existing branch,
  slices 4 and 5 are round 2 and open nothing this run.** Rider: rapid iterative pushes manufacture a THIRD
  refusal shape ("… is cancelled.") via `cancel-in-progress`; batch every repair to a PR into ONE push.

### Wave 6 plan — 5 slices, 3 in round 1, 2 new PRs

| # | Slice | Task | Round | Surface | Model |
|---|---|---|---|---|---|
| 1 | Land the stack — repair #9888 in place, re-run the rest | `dr-w6-s1-land-the-stack` | 1 | `api/**` (2 files), inside #9888's branch | opus |
| 2 | The stale binary says so — a dev build reports UNKNOWN | `dr-w6-s2-stale-binary-says-so` | 1 | `internal/cli/doctor_onboarding.go`, `upgrade.go` | opus |
| 3 | The proofs — after-measurement, the cap, the ledger repair | `dr-w6-s3-the-proofs-and-the-ledger-repair` | 1 | `tooling/grip/ledger/**` + bp ledger writes | opus |
| 4 | Space reaches eyes — producer and consumer in ONE slice | `dr-w6-s4-space-reaches-eyes` | 2 (after s1) | agent + CP + `bp cloud instance top` + deploy.yml | opus |
| 5 | The 5xx reaches eyes, and `degraded` keeps its reading | `dr-w6-s5-5xx-and-degraded-keep-the-reading` | 2 (after s1) | `internal/cli/cloud_status_cmd.go` | opus |

**Model note.** Fable is unavailable this cycle, so every slice builds on opus at medium — including slice 4,
which on merit (cross-surface Go↔Elixir↔CLI coupling, a parser unit trap that fails silently, a deploy-regex
change with production blast radius) would otherwise be the wave's fable slice. Its brief is written
correspondingly harder: every trap is named, not left to judgment.

**Where the space render lands — DECIDED.** Fold space into the existing `/metrics` envelope and render it in
`bp cloud instance top`, NOT a new route plus a new `bp cloud usage` section. Reasons: `Registry.recent_events_
of_type/3` arrives generic-on-type with #9889, so the fetch half is free; `storageLines`
(`cloud_instance_top_cmd.go:385`) already implements exactly the three honest states the payload needs
(absent / nil / `[]` / rows); and `bp cloud usage` renders a **meter table** whose cells are
value/limit/state/trend fed from a completely different pipeline (`Usage.gather`, cached usage_samples) — a
named-consumer list has no home in that struct. Four files, zero new routes. The FINISHED EXPERIENCE sentence
therefore moves from `bp cloud usage jarl` to **`bp cloud instance top jarl`**; `bp cloud usage jarl` already
answers "disk 96%" today, which is precisely the answer the wish rejects.

**HIGH-FLIP-RISK, slice 4:** the `-kx` unit change to `parseDuTree`. Both failure directions are silent — a
missed unit parameter understates every consumer by exactly 1024× behind a fully green build, and an
over-eager discard rule throws away complete measurements on the one box that matters. An independent second
reviewer is warranted before merge; this workflow spawns one reviewer, so that dispatch is a manual lead step.

**D66 applies to slices 2, 4 and 5** (pure-Go / mixed-with-`cmd`), and #9890 is a pure-deploy diff that
dispatches **false** on cloud, console and elixir — its green asserts nothing.

**What this wave does NOT take, and says so.** Seven of the ten `dr-bl-w5-*` backlog rows carry forward
untouched. `MemoryHigh` stays parked — and its stated prerequisite was **wrong**: the bound reads per-slot
cgroup counters, which are PID-agnostic, so it never depended on the beam-PID pin. The derivable lever is
**`MemorySwapMax`** (live: the green slot holds 1,307 MB of the box's 1,956 MB of used swap and swapped out
114 MB in two minutes; `MemorySwapPeak` 1,332.6 MB), and the real unbuilt prerequisites are persisting
per-slot swap peaks across restarts (systemd resets them) and choosing unit-vs-slice placement. Filed, not
taken. Also filed: PSI `memory-full avg10` measured **0.60**, not the 4.46 this charter has been quoting —
do not re-quote it.

---

### Wave 2026-08-06 (wave 6) — REVIEWED · Paper `deploy-reliability-wave-6-2026-08-06` · grade **B+**

**Three of five slices built, reviewed, gate-green on the reviewer's final state, pushed and PR'd. Nothing
merged — the lead merges.** Slices 4 and 5 are round 2 BY DESIGN, behind s1's stack.

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| Land the stack (repair #9888 in place) | `dr-w6-s1-land-the-stack` | `…the-box-a-1` (pushed to, head `754346c0f`) | [#9888](https://github.com/FRIKKern/barkpark/pull/9888) | controller 3/0 · unit 19/0 · `mix format` clean on 4 files · assertion mutation-proven |
| A dev-built `bp` says UNREPORTED | `dr-w6-s2-stale-binary-says-so` | `…never-up--1-r` | [#9929](https://github.com/FRIKKern/barkpark/pull/9929) | build + vet + `go test ./internal/cli/...` green (23.2s) · `gofmt -l ./internal` empty |
| The proofs and the ledger repair | `dr-w6-s3-the-proofs-and-the-ledger-repair` | `…after-measuremen-2` (unchanged) | [#9930](https://github.com/FRIKKern/barkpark/pull/9930) | doc-budgets rc=0 · docs-anchors rc=0 · non-ledger files changed = 0 |

**The headline is that the epic measured itself and found a REGRESSION.** `dr-w6-s3` re-derived the
after-measurement through `DeployLedger.census/2` on the live control plane (`rpc`, not `eval` — `eval`
boots a VM with no Repo) and published all three conventions side by side rather than the one that
flatters. Doctrine-matched: **41.77% → 43.96%, +2.19pp worse.** Busy-refusal pressure genuinely fell
(47.61% → 30.12%) — wave 1's re-key works — but settled failures rose, and `BOX_500` per attempt DOUBLED
(8.67% → 14.89%; doubled, not tripled — count went 6.1× while volume went 3.5×). The flattering row
(89.38% → 43.96%) compares two DIFFERENT conventions and is published only as the row that must never be
called repair. The digest's 46.41% is unreproducible at these pins: reported and dropped. Every number
carries its re-derivation command, and every disagreement with the brief's figure is printed beside it
rather than reconciled away.

**The cap's structural verdict is in, and it is stronger than "disjoint".** The feared masking does not
exist: the two arms' DECIDING sets are disjoint by construction (`already_running` decides iff the
requesting slug is itself in flight; `box_at_capacity?` is reached only when it is not), the predicates
DO overlap on a same-slug build, but both arms refuse — so the ordering only decides which LABEL a
same-slug refusal carries. The reviewer re-derived this independently at `origin/main`
(`deploy_runner.ex:440-470`, `581`, `721-760`, `@build_slot_capacity 1`) and confirms it, including two
details the doc omits without changing the conclusion: `box_at_capacity?/2` falls through to
`foreign_build_in_flight?/1` when `building_slugs/1` is empty, and `takes_build_slot?/1` exempts
rollback/teardown. Neither upstream lock preempts (the unique partial index is same-site; Oban's
`site_deploy: 1` serializes JOBS, not builds).

**And the cap is still not on the box.** Re-derived on guerrilla at write time: `CAP_ABSENT` — the commit
object is not merely un-merged, it is not present; `grep -c box_at_capacity deploy_runner.ex` = 0; zero
`box_at_capacity` rows have ever existed in the production ledger. Read that correctly — a predicate that
is not on the box cannot refuse. It is a proof NOT ATTEMPTED, not a failed proof.

**What the wave did NOT deliver, plainly.** Nothing merged, so the wish moved forward on paper only. The
owner still cannot see space, still cannot see the box's own 5xx rate, and the box still does not cap
builds in production. The three clauses of the wish are all sitting in open PRs behind a **frozen GitHub
Actions dispatcher** — 59 queued / 0 in_progress for the whole run, zero workflow runs created for #9888's,
#9929's, #9930's or this charter PR's heads. That is the same condition D80/D95 name; it is not a defect in
any of this work, but it means the wave's own definition of done (LAND the stack) was not reachable.

**Reviewer fixes, both of them the epic's own doctrine turned on itself.** (a) `754346c0f` on #9888: the
`OC24` dangler the builder fixed in the controller survived in TWO more files — `request_stats.ex` and
`api/lib/barkpark_web/router.ex`. `grep -rn OC24 .claude/workflows/` returns exactly one hit
(`bp-cloud-console-charter.md:49`, console AUDIT scope), and `D48` in THIS charter (line 828) is the
journal-cap decision, not an "honest-meters law". All three now cite `BarkparkWeb.RequestStatsTest` and
`RequestStatsControllerTest` — which move with the code by construction — instead of a charter letter,
which does not. (b) `b2c9b2541` on #9929: `bp upgrade`'s dev-build refusal said `make cli-build`, which
builds `dist/bp` and never touches PATH — a user who followed it verbatim re-ran the same stale binary and
got the identical refusal. It now names `git pull && make cli-install` (Makefile:171), the same remedy the
doctor's unreported leg names. One fact, one remedy, two surfaces.

**A charter correction, dated 2026-08-06.** D75's own text (line ~1566) says the 5xx ring "reads 0 for the
first minute after boot". The shipped code does NOT: an empty window returns `nil`, and both the moduledoc
and the controller test now pin that explicitly, because a `0.0` on an unmeasured box reads "this box is
serving no errors" — the most reassuring lie a meter can print. The code is right and the charter sentence
is stale; do not re-quote it.

**Ledger.** All three slice tasks were claimed, stamped as the builders worked, and left `in_progress` with
only merge-gated criteria open — honest, no fabrication found. Reviewer stamped `dr-w6-s2` idx 7 (the D66
sentence, now verbatim in #9929's body, with the honest caveat that the dispatch verdicts are DERIVED from
the file set, not OBSERVED, because no run exists). `dr-w6-followup-reqstats-dangling-oc24` stamped 2/2 and
left open — it rides #9888 to main. Filed: `dr-w6-followup-whoami-cli-freshness-leg` (the tri-state lives
on two surfaces, not three — `bp whoami`'s spine carries no CLI leg at all).

**What the next wave takes.** MERGE, in order: **#9887** (the eleven-rung ladder — it is what actually
changes what the owner sees, and it unblocks `dr-w6-s5`), then **#9889** (CP space ingest — unblocks
`dr-w6-s4`), then **#9888** and **#9890** in any order, then **#9929**/**#9930**. Get #9888 and #9889 in
BEFORE cch #9857's builders dispatch — their slice 1 rewrites 18 route-scope sites in
`cloud/lib/barkpark_cloud/web/router.ex`, 423 lines from our nearest hunk. Then dispatch `dr-w6-s4`
(space reaches eyes — still HIGH-FLIP-RISK on the `-kx` unit change, still owed an independent second
reviewer) and `dr-w6-s5` (5xx + degraded keep the reading). Then, and only then, is the live cap refusal
attemptable: its single unblock condition is `git merge-base --is-ancestor ef77af274 HEAD` returning
CAP_PRESENT on guerrilla — i.e. the box's pull, not another merge. **Stratify any failure-rate measurement
taken across that merge boundary** — deferrals sit inside volume and outside the numerator, so the cap will
step the rate BY DESIGN, and reading that as repair would be the exact error Part A §3 exists to prevent.
## Wave 7 decisions — THE READ HALF, AND THE INSTRUMENT THAT LIES ABOUT ITS OWN FAILURE (2026-08-07)

*Paper `deploy-reliability-wave-7-2026-08-07`. Wave 6's verdict was "three waves built the seeing and never
turned it on." Wave 7's is one level down, and it is worse: **for the disk axis, the seeing was never
CONNECTED — the read half of `space` has never appeared in a charter ruling in any wave, and it exists today
only as two open rail rows that specify it INCOMPATIBLY.** The direction's thesis (reach is the wall) held,
but three of its load-bearing premises fell under verification, and every correction made the wave smaller.*

- **D96 — THE SPACE READ HALF WAS NEVER CHARTERED, TWO ROWS SPECIFY IT INCOMPATIBLY, AND THE RULING IS: FOLD
  INTO `/metrics`, WITH THE SECOND QUERY AT THE ROUTER.** *Why:* a runtime BEAM abstract-code scan over every
  module compiled from #9889's tree printed `COMPILED MODULES REFERENCING normalize_space:
  [BarkparkCloud.Telemetry]` — **one module, the one that defines it, zero callers.** The same probe printed
  `METRICS ENVELOPE TOP-LEVEL KEYS: [:ok, :instance, :latest, :points, :beat, :collected_at, :series,
  :service_health]` / `HAS :space KEY? false`. Live: `POST /v1/agent/space` → **404** while the sibling
  `/v1/agent/report` → 401, so the agent's 15-minute space post is discarded on every box right now. And
  #9889 does not merely fail to add a read — it **actively closes the door**, swapping
  `Registry.recent_events(bp, points)` for `recent_events_of_type(bp, "health", points)` at `router.ex:7784`,
  which makes a space row unreachable from `/metrics` **by construction**. Two open rows own the missing half
  with two designs: `dr-w6-s4` criterion 5 ("the control plane folds space into `/metrics`") versus
  `dr-w5-s3-followup-render-the-space-payload` criterion 1 ("a team-scoped read serves the newest `space`
  event … the SAME no-existence-leak 404 as the sibling `/telemetry` route"). Dispatch both and the wave ships
  two read surfaces for one payload — the dedup failure this epic's doctrine exists to prevent. **RULING: fold
  into `/metrics`.** The CLI already reads exactly that one route (`cloud_instance_top_cmd_test.go:69` asserts
  `GET /v1/barkparks/<id>/metrics`), and `storageLines` is already the three-honest-states renderer.
  `dr-w5-s3-followup` is CLOSED as superseded. **THE COST NOBODY WROTE DOWN, and it is the single most likely
  way this ships green and shows nothing:** because #9889 type-filters the fetch, the fold needs a SECOND
  query (`recent_events_of_type(bp, "space", 1)`) issued **at the router and passed in** — `Metrics.build/3`
  is documented PURE and TOTAL over a passed-in window, so a builder who folds inside `build/3` either breaks
  its purity contract or renders `nil` forever.

- **D97 — S1 SPLITS: THE READ PATH SHIPS FIRST-CLASS, THE PROBE FOLLOWS IT.** *Why:* `dr-w6-s4` as written
  carries 13 criteria spanning `internal/agent` (the `-kx` unit change), `cmd/barkpark-agent`, `cloud/lib`
  (the fold), `internal/cli` (the render) AND `.github/deploy.yml` — four fences and a deploy-config edit in
  one PR. The producer-plus-consumer-in-one-slice principle is right; this row is where it stops being
  affordable. The split is not symmetric: **the CP+CLI half must be the one that ships first-class, because a
  fifth wave of producer-only is the indictment.** `dr-w6-s4` is re-briefed DOWN to the fold plus the render
  (two fences); the agent multi-root/unit work becomes its own row, sequenced AFTER the read path so its bytes
  land somewhere instead of in a drawer.

- **D98 — THE RESIDUAL LINE IS RULED, WITH FOUR GUARDS AND A CLAMP, OR IT IS NOT BUILT.** *Why:* the residual
  is the right idea and its arithmetic does **not** survive its hazards unguarded — measured, all four live.
  (1) **`du -h` rounds UP**, up to **+1 GiB per root** and **systematically positive** (jarl: `du -kx -d1
  /var` = 30 007 316 KiB = 28.62 GiB while `du -hx` prints `29G`), so a multi-root residual is systematically
  **negative**; with 4-8 roots that is up to −8 GiB of phantom on a 39 GiB box, dwarfing every other hazard.
  (2) **Mount boundaries go negative TODAY:** jarl carries a docker overlay whose path `du -x` refuses to
  cross into (2 020 KiB) but happily traverses when rooted at it (1 505 656 KiB) — listing it as a fifth root
  takes the residual to **−1.29 GiB**. (3) **pg double-counts 3.37 GiB** — `du -x -k -s /var/lib/postgresql`
  = 3 615 160 KiB against `sum(pg_database_size)` = 3 528 933 KiB, **97.6% of the same bytes** — on a box
  whose entire used is 26.9 GiB. (4) **`df` capacity ≠ `df` used:** capacity is `ceil(used/(used+avail))` and
  excludes root-reserved blocks, so jarl reads 96% capacity against 91.09% used-of-total — a residual built
  from `disk_used_percent` **invents 1.83 GiB** there (the prior "~2.4 GB" estimate was ~22% high).
  **RULING:** (i) the denominator is `RootUsedBytes` (`report.go:186-187`, set from `df -P -k` at `:779`),
  never `disk_used_percent`; (ii) roots must be disjoint AND each verified same-`st_dev` as `/`, and a root
  failing that test is **EXCLUDED AND NAMED**, never summed; (iii) pg is a `du` root **or** `PGSizeBytes`,
  never both, and the payload says which; (iv) exact units end to end (`du -x -B1`, or `-k` with an explicit
  unit parameter), never `-h`. **And CLAMP: a residual that computes negative prints "roots overlap or cross
  a mount — residual undefined", never a negative gigabyte.** Filed, not taken — it needs the probe and the
  read path first.

- **D99 — THE DEFERRAL CHAIN HAS A DEPTH, THE CODE COMPUTES IT, AND IT REACHES NO EYE. THAT IS THIS WAVE'S
  BEST SLICE.** *Why:* the cap is live and working — **63 `box_at_capacity` rows across 5 sites**, all
  inserted 2026-08-06 22:29:27→22:52:18Z, and **every chain RECOVERED** (longest consecutive run **8**,
  against a cap of 12; site `7c2025a5` deferred at 22:29:27 / 22:30:28 / 22:31:28 then went `building` at
  22:32:29). But `consecutive_deferrals/2` (`deploy.ex:1296`) computes the depth, uses it for the threshold,
  interpolates it into a `Logger.info`, **and discards it**: `git grep -rn "consecutive_deferrals\|in a row"
  origin/main -- cloud/lib internal/` returns hits **only** in `deploy.ex` — zero in `internal/`, zero in the
  console. The operator-visible `detail` is **byte-identical on deferral 1 and deferral 11**
  (`box_at_capacity — the box is at its build capacity (1 of 1 build slots in use) …`). Two facts make this
  urgent rather than cosmetic. **The terminal arm is not theoretical — it has fired in production**: exactly
  one row in the whole ledger carries the terminal wording (site `7c2025a5`, `failed`, 2026-08-05 22:57:53,
  "*it has now refused 6 rebuilds in a row for this site*"), the sibling `BOX_BUSY` cause at its lower cap of
  6, and that publish is terminally `failed` with nothing to re-drive it. **And the 12-cap is a ZERO-PROGRESS
  guard, not a timer** — `Enum.drop_while(...) |> Enum.take_while(deferred and same cause)` means one `live`
  row resets the counter, so a merely-slow box can defer indefinitely without ever tripping it (site
  `d8e9c2c7` took 75 deferrals in 12h and never came within 4 of the cap). `cloud/lib/barkpark_cloud/sites/
  deploy.ex` is touched by **zero** open PRs. Dependency-free, uncontested, auto-deploys on merge, needs no
  agent release to reach any box, and proves itself against a production ledger that already holds the rows.

- **D100 — THE CAP IS LIVE; D91 IS DEAD; AND `_build/prod` IS A TRAP THAT NEARLY PRODUCED THE OPPOSITE
  VERDICT.** *Why:* `/opt/barkpark` HEAD on guerrilla is **exactly** `ef77af274`; `barkpark-slot@blue` (green
  `inactive`) entered active at 22:24:16Z from an `Elixir.Barkpark.Sites.DeployRunner.beam` compiled
  22:22:22Z — 114 s earlier — and `grep -c box_at_capacity` on the live source returns 6. D91's "structurally
  deferred behind a deploy" premise is retired. **THE TRAP, recorded so it does not recur:** `api/_build/prod`
  on that box is a **dead 2026-07-20 directory** whose DeployRunner beam contains zero `box_at_capacity`;
  blue/green builds into `_build_blue` / `_build_green`, so reading `_build/prod` yields a confident, wrong
  "the cap is not deployed."

- **D101 — AN INSTRUMENT THAT CALLS A DEAD BROWSER A CSS DEFECT IS THIS EPIC'S OWN THESIS, LIVE, ON A REQUIRED
  BLOCKING GATE.** *Why:* re-measured at `origin/main` in a clean worktree with an executable Chrome stub that
  starts and immediately exits — the exact CI condition, since the binary *exists* and so the preflight's
  not-executable check does not catch it: **`cssom-parity.mjs` exits 1, `overflow-guard.mjs` exits 2 on the
  identical fault.** `console-harness.yml`'s `1)` arm then prints "*The browser's CSSOM disagrees with the
  authored stylesheet (exit 1). This is a REAL CSS defect in `cloud/priv/static/app.css` — rules the browser
  dropped or rewrote.*" while its own stderr reads "*Chrome never wrote DevToolsActivePort — it did not
  start*". That banner **fired in CI** (job 92711949228). The workflow's case block is correct; the instrument
  lies to it. Root cause is one clause: `const envFailure = err instanceof ReferenceError` (`cssom-parity.mjs:
  646`) while the bring-up throws a plain `Error` at `:603` — the ReferenceError arm is documented as a
  *second* line of defence for a missing global, so the fix **adds** the bring-up class rather than replacing
  it. **FENCE:** no open PR touches `cssom-parity.mjs`; cch wave 37 owns `app.js`, the notifications tree and
  the path-escape scripts, none of which this slice touches.

- **D102 — RE-CLAIMING THE EPIC TASK CLEARS THE TASK GATE; A RE-RUN IS A COIN FLIP THAT DELETES THE CHECK
  FIRST; NEVER RELEASE THE CLAIM.** *Why:* three things were witnessed, not inferred. (1) Claiming
  `task-fb4fb869490b4213` moved it out of `open` entirely — the gate's `in_progress` arm passes on
  `worker != "."` alone and `EXPECTED_WORKER` is empty — and a plain `gh run rerun --failed` then re-fired the
  required context **green on both #9876 and #9905 with no push**, refuting "only a PUSH re-fires a sticky
  verdict" *for* `pr-task-gate.yml`. (2) **Requesting a re-run DELETES that workflow's check-runs**: main's
  head went 36 → 29 → 36 check-runs, the required `Console gate` read **ABSENT (not red)** and combined status
  read `pending`; #9887 sat in that hole **50+ minutes** with `attempt=1 queued` and `attempts/2/jobs` → 404.
  A red required check was thereby converted into a missing one. (3) The Chrome re-run is **1 clear / 1 repeat
  at n=2** — main's run flipped `failure → success`, #9889's attempt 2 completed `failure` on the identical
  refusal. "Re-run and merge" is a loop with an unmeasured trip count, not a step. **And DO NOT RELEASE the
  claim:** the `open` arm reds `released_ge_expired` unconditionally, so a voluntary release is strictly worse
  than letting the 2700 s lease lapse (the reap stamps `expired_at` *after* both PRs' `created_at`, so the
  ordering clause still passes). Two stale premises corrected while measuring: **which** Chrome job refuses is
  not stable (on main's attempt 1 `Overflow guard` PASSED while `Billing tier floor` and `CSSOM parity`
  refused), and a third red class exists that is not Chrome at all — `Failed to resolve action download info.
  Error: Service Unavailable`.

- **D103 — 5xx CANNOT BE RENDERED HONESTLY CLI-ONLY; IT IS A DETAIL LINE WITH ITS VOLUME, AND THE FIX IS FOUR
  LINES OF CONTROL PLANE.** *Why:* 23 samples at 15 s against live guerrilla put `n = req_per_s × 60` at
  **min 58 / median 90 / max 647**, and only **6 of 23 clear the epic's own `@min_sample 200`**
  (`deploy_ledger.ex:164`, where `rate/2` refuses below it and prints the refusal). Worse, **n is strongly
  ANTI-correlated with p95** — n=647 ↔ 121 ms, n=68 ↔ 1518 ms — because `req_per_s` counts *completed*
  requests, so the denominator collapses exactly when the box is sick and any share **inflates precisely when
  it is least trustworthy**: D75's 0.22 5xx/s is **14.4% at median n and 2.0% at max n**, a 7× severity spread
  from one unchanged number. **RULING: a DETAIL LINE, never a rung** (a fence on a bare rate is indefensible;
  a fence on the share needs a denominator not on the wire; `err_5xx_per_s` will be nil on 5 of 6 boxes for
  the foreseeable future, so a rung would be fleet vocabulary that can only ever fire on one box) — **print
  the observation WITH its volume and refuse the share below 200**, reusing `DeployLedger.rate/2`'s refusal
  node so no caller can print a percentage without the volume that produced it. One arithmetic gift:
  `err_5xx_per_s / req_per_s` is **exactly** errors/count (`compute/4` divides both by the identical
  `elapsed_ms`), so the share adds zero estimation error — only sample size is at issue. **Therefore
  `req_per_s`/`p95_ms` MUST join the pressure block**: absent from `merge_pressure` on main AND on #9888, but
  **already in the stored beat jsonb** (`/telemetry` serves guerrilla `req_per_s: 1.83, p95_ms: 2149` today
  off the same health payload) — two keys in `@unmetered_pressure`, two lines in `merge_pressure`, two fields
  on `cloudclient.Pressure`, **no agent change and no box deploy**. `dr-w6-s5` criterion 10's file ban must
  therefore WIDEN to permit `internal/cloudclient/` and `router.ex`, keeping `cloud/priv/static/` ceded — or
  the slice ships the exact denominator-free rate it exists to prevent.

- **D104 — THE CHARTER'S OWN DECISIONS ARE UNCITABLE, AND 86/87/89/90 ALREADY MEAN SOMETHING ELSE.** *Why:*
  `origin/main`'s charter ends at **D66**; D67-D77 live only on #9876 and D78-D95 only on #9905, and the
  working copy carrying D1-D95 is **untracked**. Meanwhile `git grep D86 origin/main -- api/lib cloud/lib`
  hits `deploy_request.ex`, `deploy_runner.ex` (×3) and `prebuilt_artifact.ex` — *site-spawner* D86/D87, about
  prebuilt artifacts — plus `billing.ex` and `registry.ex` (×5) for a third namespace, `PDF-D86`. A builder
  told to "follow D86/D87" finds four confident, shipped, wrong answers. **RULING: every wave-7 task body
  cites `deploy-reliability charter D<n> (PR #9905)`, never a bare `D<n>`, and inlines the rule text.** And
  the **DANGEROUS PARTIAL**: `origin/main`'s D59 clause (3) mandates "*Any non-zero exit must DISCARD and
  report unmeasured, never partially land*" — the exact rule the unmerged D86 reverses — so a builder who
  `git show`s main for the discard rule derives the **opposite** behaviour from a correctly-cited decision.
  Any probe brief must say so in its own words.

- **D105 — CI IS THE CONSTRAINT: THIS WAVE CUTS TWO PRs, AND SAYS WHAT IT IS NOT CUTTING.** *Why:* Actions was
  in declared `major_outage`; a re-run deletes a required check for an unbounded window (50+ min, measured);
  main's own Console gate sat starved with zero dispatched jobs for ~6.4 h before going green. Fifteen PRs are
  open and every one of them merges CLEAN against `ef77af274` — all 105 head-to-head pairs are clean and a
  15-deep stack merges clean in **both** directions, so **there is no merge-order constraint among the open
  PRs at all**. The constraint is GitHub, not the tree. Two round-1 slices, both fence-disjoint from all 15
  open PRs and from cch wave 37, both provable on a local gate; everything else is a deferral with a complete
  brief. **The fence is disjoint at PR level and NOT at slice level, which is the finding:** #9887 rewrites
  `internal/cli/cloud_status_cmd.go` bands `17-135` and `460-471` of a 489-line file, and `attentionDetail`
  sits at `:123` — **inside** that rewrite — so the `degraded`-arm and release-pin slices cannot branch off
  main beside it and are sequenced behind its merge. `internal/agent/report.go` is the opposite: #9888 stops
  at line 550 and the space probe lives at 762-1051, a 211-line gap, so the probe is safe to build
  concurrently once it has somewhere to land.

### Wave 7 plan — 3 slices, 2 in round 1, 2 new PRs

| # | slice | round | surface | model | gate |
|---|---|---|---|---|---|
| 1 | `dr-w7-s1-deferral-chain-names-its-depth` | 1 | `cloud/lib/.../sites/deploy.ex` + `internal/cli/cloud_site_cmd.go` | opus | `mix test test/barkpark_cloud/sites_deploy_test.exs` + `go test ./internal/cli/` |
| 2 | `dr-w7-s2-parity-instrument-refuses-instead-of-accusing` | 1 | `cloud/priv/static/__preview__/cssom-parity.mjs` | opus | dead-Chrome stub ⇒ exit 2; real Chrome ⇒ exit 0 |
| 3 | `dr-w6-s4-space-reaches-eyes` (re-briefed) | 2 | `cloud/lib/.../metrics.ex` + `web/router.ex` + `internal/cli/cloud_instance_top_cmd.go` | fable | `mix test test/barkpark_cloud/metrics_test.exs` + `go test ./internal/cli/` |

**HIGH-FLIP-RISK, slice 3:** the `/metrics`-fold-versus-new-route ruling (D96) and the purity constraint on
`Metrics.build/3`. An independent second reviewer is warranted before merge; this workflow spawns one
reviewer, so that dispatch is a manual lead step.

**D66 applies to slice 2** (pure `cloud/priv/static/__preview__` — the Console gate DOES assert on it, so this
is the one slice this wave whose required context is a real signal rather than a skip).

**What this wave does NOT take, and says so.** The residual line (D98) is filed, not built — it needs the
probe and the read path first, and unguarded it manufactures negative gigabytes. The agent multi-root probe is
filed and sequenced behind the read path so it does not become a fifth producer-in-a-drawer. Cutting and
blessing `v0.2.26` remains a named human gate and is now **strictly ordered**: #9890 must merge and
`BARKPARK_SELF_UPDATE_APPLY=1` must be set on the four frozen boxes FIRST, because
`autoupdate_rollout_worker.ex:135-141` maps a `503` to `Registry.pause_autoupdate(bp)` and **only a human
`bp cloud autoupdate resume` clears it** — all six boxes read `autoupdate_paused: false` today and five of
them will 503, so blessing first would permanently pause five of six boxes, one per tick. Nothing is deleted
from any disk: jarl's 25 GB — `/var/lib/containerd` 13.80 GiB plus `/var/lib/barkpark-builder` 11.30 GiB — is
a **known, filed, unbuilt** platform gap (`cp-ops.yml:99-104` says so verbatim: "*the jarl box hit 100% of 38G
this way and took the instance down*") whose fix, `jpf-runtime-image-pruning`, has sat unclaimed since
2026-08-01. It becomes VISIBLE and NAMED, never smaller.

### Wave 2026-08-07 (wave 7) — REVIEWED · Paper `deploy-reliability-wave-7-2026-08-07` · grade **B+**

**Two of three slices built, reviewed, fixed in place, re-gated, PUSHED and PR'd. Nothing merged — the lead
merges.** The third (`dr-w6-s4-space-reaches-eyes`) is round 2, deferred by the sequenced-rounds law behind
#9889, which is not merged. That is not a stall; it *is* the wave's honest headline, see below.

| Slice | Task | Final branch | PR | Gate on the FINAL state |
|---|---|---|---|---|
| A deferred site names how deep its refusal chain is (D99) | `dr-w7-s1-deferral-chain-names-its-depth` | `…names-how-deep-its-refus-0-r` | [#9959](https://github.com/FRIKKern/barkpark/pull/9959) | 64 tests, 0 failures (cloud) · `go build`+`vet`+`test ./internal/cli` ok · gofmt clean |
| The parity instrument refuses to measure instead of accusing (D101) | `dr-w7-s2-parity-instrument-refuses-instead-of-accusing` | `…refuses-to-measure-1-r` | [#9960](https://github.com/FRIKKern/barkpark/pull/9960) | ENOEXEC binary → 2 · dead-chrome stub → 2 · real Chrome → 0 (1305/1305 heads, MISSES 0) · `proof.sh` clean=0 swallowed=1 · dropped-rule sheet → 1 (MISSES 1) |

**What landed.** S1 is the wish-bearing slice and the wave's strongest work. `defer/3` computed the chain
depth, spent it on the terminal threshold and one `Logger` line, and **discarded** it — so on the production
ledger 63 capacity-deferred rows across five sites carried a byte-identical sentence and refusal 8 read
exactly like a first blip. The depth, the *cause's own* bound (12 for capacity, 6 for a busy box, read from
`max_consecutive_deferrals/1`, never a literal) and the fact that the counter is a **zero-progress guard, not
a countdown** now ride the existing `failure_reason`/`detail` columns — no migration. The consumer shipped in
the SAME PR, per this epic's standing shape-fix after three waves of producers landing in drawers:
`git grep 'deferred' internal/cli/cloud_site_cmd.go` returned nothing before, and `bp cloud site status` now
prints a dedicated `deferral` row plus `deferral_depth`/`deferral_bound` as numbers in `-o json`. A pre-D99
control plane says the depth is *unavailable* rather than printing a zero that would read as "no chain".
S2 closed a gate that accused the stylesheet for the environment's fault, and held the anti-vacuity line that
was the whole point of the slice: the refusal class rides the error **object**, never its message, and
everything the browser reports once it IS up still exits 1 (independently re-derived on both defect paths).

**What did NOT land, and must be said plainly.** The wish names three things; this wave moved one of them,
partly. *"See what is taking up space"* — jarl's 25 GB, the concrete thing the owner asked about — advanced by
**zero merged code**, for the second consecutive wave, because the read half is sequenced behind an unmerged
PR both times. *"See a struggling box as struggling"* advanced by nothing. The cap exists and fires, and S1
makes its refusals legible, which is real progress on the third clause's operator surface — but half the
wave's built output (S2) is CI hygiene on a console-stylesheet gate and serves the wish only by analogy.

**Review fixes made in place** (three commits on the two `-r` branches, each proved by mutation, not reading):

1. **S1** — the deferral arm and the failed-staleness arm both write `reason`, and the deferral arm runs
   SECOND. With a failed NEWEST row and a deferred live pointer the header said "the NEWEST deploy FAILED" and
   then printed the OLDER deferral's sentence beneath it, describing a different row than the status line
   named. The drop is the louder truth and now wins; reverting the guard makes the new test FAIL.
2. **S1** — the depth clause sits ahead of the re-queue promise *because* `short_detail/1` clamps `detail` to
   varchar(255), but every assertion ran on a SHORT reason where the clamp never fires, so the ordering was
   unpinned. A new test forces the clamp with a 180-char box message and pins that the depth survives it.
   (This was the builder's own named gap #3 — the self-review was honest and worth its length.)
3. **S2** — D101 tagged three bring-up steps and **missed the fourth: the spawn itself.** `findChrome()`'s
   `X_OK` preflight cannot see exec-time faults (ENOEXEC — the arm64/amd64 runner-image mismatch class —
   EACCES, ETXTBSY). Measured on the review host (node v22.22.0, darwin): `spawn` throws ENOEXEC
   **synchronously**, so an unexecutable Chrome reached the classifier untagged and printed
   `!! PARITY ERROR: spawn ENOEXEC` at exit 1 — i.e. `console-harness.yml`'s "This is a REAL CSS defect in
   app.css". The slice shipped with its own bug class still live inside it. Both delivery shapes now covered.

**Ledger audit: clean.** Both builders claimed before working, stamped evidence as they went (S1 8/9, S2 6/7),
left lifecycle `in_progress`, and left the merge-gated "PR is merged" criterion OPEN for the lead. The unbuilt
round-2 slice reads open / 0-of-9 / unclaimed. No task outside this wave was touched. One staleness fix: both
now-lines still said "Not pushed", so a flat `review_verdict` was added to each task naming the final branch,
the PR, the fixes on top, and the gate re-run — patched, re-published, read back.

**What the next wave should take.** Dispatch order: merge round 1 (#9959 first — it carries the wish — then
#9960); `dr-w6-s4-space-reaches-eyes` becomes dispatchable only once #9889 merges, and it is HIGH-FLIP-RISK on
two judgments (the `/metrics`-fold-versus-new-route ruling D96, and the `Metrics.build/3` purity constraint)
so an independent second reviewer is owed before merge. Then, in priority order:
**(a)** point the wave at clause 1 and stop deferring it — if #9889 will not merge, re-cut the read half
against what IS on `main` rather than sequencing behind it a third time;
**(b)** take `dr-w7-followup-deploy-follow-spins-on-deferred` (filed this wave, five criteria, unclaimed) —
`cloudclient.SiteDeploymentTerminal` omits `deferred`, so `bp cloud site deploy --follow` polls a SETTLED
deferred row for its full ~10-minute budget against the box that just said it was at capacity and then prints
"deploy in progress" and exits 0. Leaving it open means `status` tells the truth about a deferred row while
`--follow` lies about the same row;
**(c)** two structural debts, both named by their builders and neither taken: S1's producer sentence and the
CLI's `refusal (\d+) of (\d+)` regex are ONE contract across two languages with no shared constant; and
`cssom-parity.mjs` classifies errors in one place at the bottom of a catch block, where two waves have now
added a class and the second one MISSED a step — a `die()`-style helper that picks a class *at the throw site*
(the shape `overflow-guard.mjs` already has) would have made the ENOEXEC hole unwritable.

**ADDENDUM, same day, before the lead touches either PR.** Both wave-7 PRs are RED on `Console gate` — one of
the four required blocking contexts — and **neither red is caused by either PR.** The hosted runner's headless
Chrome is intermittently failing to start:

- #9959, *Overflow guard (rendered)*: `!! OVERFLOW GUARD: Chrome never wrote DevToolsActivePort — it did not start`
- #9960, *Billing tier floor (rendered)*: `!! BREAKPOINT SWEEP (exit 2): Chrome never wrote DevToolsActivePort — it did not start`

`CSSOM parity` **passed** in the same #9960 run, so the fault is intermittent bring-up, not a missing binary.
Every affected probe refused correctly at exit 2 and said in plain words that no claim was being made — the
discipline this epic built is working, and this is the exact fault class wave 7's own D101 slice extends to
`cssom-parity`. What is wrong is the last step: `console-harness.yml`'s `2)` arm converts a REFUSAL into
`exit 1`, so at gate level a refusal is indistinguishable from a defect, and a runner that cannot start Chrome
blocks every PR in the repo — including PRs that touch no console asset at all. Filed as
`dr-bl-w7-runner-chrome-refusal-blocks-every-pr` (published, 5 criteria, unclaimed) with three candidate
shapes and the counter-argument stated: the fix is **not** "make refusals green", which is how a browser gate
quietly stops gating. Not re-run by the reviewer — a `gh run rerun --failed` has previously *deleted* a
required context on this repo, and that is the lead's call, not a reviewer's.

## Wave 8 decisions — NAME THE CAUSE, PUT THE NUMBER IN FRONT OF A HUMAN, LET BOTH SURFACES REFUSE (2026-08-07)

Paper `deploy-reliability-wave-8-2026-08-07`. Epic task `task-fb4fb869490b4213`.
Every number below was re-derived tonight against live `cloud-db-1` (178.105.92.191) and guerrilla
(157.180.90.121) and against `origin/main` at `9e39c60c0` — **not** quoted from the handoff, which was
already stale on three separate facts by the time Decide ran.

- **D107 — THE RATE, RE-DERIVED, AND THE DENOMINATOR IS PART OF THE NUMBER.** Live 24 h at
  2026-08-07 03:00Z: **802 failed / 610 live / 820 deferred over 2,233 attempted rows** — 35.9% of all
  rows, **56.8% of TERMINAL outcomes (n=1,412)**. The census route emits exactly ONE rate key
  (`failure_rate`, denominated on `volume` = attempted, deferrals INCLUDED), measured at 37.55% on the
  pinned 00:30Z window. *Why this matters:* **D34 mandated printing BOTH conventions and that mandate
  has never existed in code.** It was discharged in PROSE by `dr-w6-s3` (11/12 criteria met, all in a
  `tooling/grip/ledger` doc). Wave 8 puts it in the payload: an additive `live` count, a `basis` label on
  every rate node, and a second `terminal_failure_rate`. Proven free: adding all three reds NOTHING
  (2,965 tests → 2,965 tests, 0 failures, byte-identical). Proven guarded: repointing the EXISTING
  `failure_rate` at the terminal basis reds exactly ONE assertion (`deploy_ledger_test.exs:552`,
  `failure_rate.sample == 20` → got 6) — that single assertion is the only thing standing between this
  epic and a silently redefined headline, and it MUST NOT be loosened.

- **D108 — THE NUMBER-ONE FAILURE CLASS IS BOTH SILENT AND MIS-REPORTED, AND THE PRODUCER ALREADY
  WROTE THE CAUSE.** `deploy_ledger.ex:240` matches `"bp-doc-id marker is empty"` in the HEALTH arm and
  throws away the upstream status that sits in the SAME string, after it. Live 24 h: 250 doc-id rows,
  **249 carrying `: graph <status>:` and 1 carrying nothing** (500=131, 0=62, 503=56). Mutation-proven in
  BOTH directions on a clean worktree: the before-state assertion (`classify("HEALTH", g500) ==
  "DOC_ID_EMPTY"`) is green on main and RED once the arm is status-aware — the two runs cannot both pass,
  so neither is vacuous. Whole cloud suite: 2,969 tests, the ONLY failure is the intentional before-state
  test. *Why:* the epic's own taxonomy is the mis-report the wish names.

- **D109 — THE `graph 403` GOES TO THE NAME THAT ALREADY EXISTS.** A fourth marker status exists
  all-time — 403, 8 rows, minted in the public-read-token window 2026-08-05 20:53–21:10. The existing
  `FORBIDDEN_403` already carries the label "the build could not read its content (403)" — the identical
  cause. **RULED: the HEALTH-stage 403 classifies as `FORBIDDEN_403`.** The new `CONTENT_API_*` family
  covers ONLY the statuses that had no name (500 / 503 / 0-unreachable). *Why:* splitting one cause across
  two class names is exactly the defect this wave exists to close; D8's "an unnamed thing goes UP" governs
  the UNNAMED, and 403 is named.

- **D110 — THE TEN BUILD-STAGE GRAPH ROWS STAY `BUILD_FAILED`. DECIDED, NOT OVERLOOKED.** Of 261
  graph-status rows over 48 h, 251 sit in the DOC_ID_EMPTY/HEALTH arm and **10 sit outside it** —
  `stage=BUILD`, `BUILD failed (exit 12): … Caught error rendering /graph.json: Error: graph 500`.
  The build genuinely did fail. Editing only the HEALTH arm leaves those ten where they are, and that is
  a ruling a builder must be able to point at rather than a gap a reviewer discovers.

- **D111 — A CLASS COUNT CARRIES ITS PINNED WINDOW OR IT IS FALSE.** 24 h: NAMED 249 / CAUSELESS 1.
  **7 d: NAMED 259 / CAUSELESS 2,594** — pre-contract history that can never acquire a cause
  retroactively. Any wave-8 sentence of the form "DOC_ID_EMPTY falls to 1" is true only at ≤2 days.
  This is D3 applied to a class count instead of a rate.

- **D112 — `DOC_ID_EMPTY` CHANGES MEANING, AND IT SILENTLY BECOMES THE STATIC-ENGINE BUCKET.** The one
  causeless row is site `astro-search`, `framework=astro`, `kind=static`. `deploy/site-deploy.sh` contains
  **ZERO** references to `bp-corpus-status`; only `deploy/site-deploy-node.sh:492` reads it. So after the
  split, `DOC_ID_EMPTY` means "the cause went unrecorded" and structurally collects the whole static
  fleet. Its label is reworded to say so, and the producer-side residue is filed
  (`dr-bl-map-landing-empty-marker` already exists; wave 8 files the static half beside it).

- **D113 — `feature_not_configured` IS NOT AN ENV HOLE. IT IS A 5,000 ms `GenServer.call` DEFAULT
  WEARING A CONFIG ACCUSATION.** The serving BEAM carried `BARKPARK_SITE_DEPLOY_APPLY=1` for 75 minutes
  before a `feature_not_configured` row landed. Measured on origin/main code, both halves:
  (a) with `enabled?() == true` and a Runner slower than the call budget, the wire returns **503
  `feature_not_configured` at 5,039 ms** with the byte-identical "set BARKPARK_SITE_DEPLOY_APPLY=1"
  message; (b) **the deploy still PROCEEDS** — marker file at +6,050 ms, `DeployRunner.status/1` =
  `:done`. `safe_call/2` (`deploy_runner.ex:411-425`) calls `GenServer.call/2` with no timeout (5,000 ms
  default) and converts ANY `:exit` — including a call timeout — into `{:error, :disabled}`. The row is
  wrong twice over: wrong cause AND wrong outcome. 24 h volume: **207 rows, 24.5% of the numerator.**
  *Consequence:* the direction's "S2 relabels the flag" is REJECTED — a CP-side relabel would be a NEW
  false accusation. The honest fix starts at the API producer.

- **D114 — A WIRE-CODE RENAME AND THE CP'S TRANSIENT ALLOWLIST CO-MERGE, OR NEITHER SHIPS.**
  `sites/deploy.ex:1390` hard-codes `"internal_error"` as the only named code earning retry/grace.
  MUTATION (rename the fake box's code, change nothing else): **3 of 61 tests fail** — poll grace dies
  (`{:ok, :live}` → `{:ok, :failed}`), the start retry dies (`{:ok, :deferred}` → `{:ok, :failed}`, i.e.
  the rename directly INCREASES this epic's own numerator), and the graced-refusal note goes silent.
  REMEDY proven in 2 lines: widen `transient_refusal?/1` → 61/61 green. **Any slice that changes a wire
  code the CP graces MUST carry the allowlist arm in the same PR.** `dr-bl-w5-500-carries-its-own-name`
  is OPEN, priority 1, and its four criteria say nothing about this — it is an armed, unlabelled landmine
  and wave 8 re-labels it.

- **D115 — THE 500 STAYS 500.** Moving the pool-blip crash to 503 costs the CP nothing at the retry layer
  (`transient_refusal?/1` never sees the status — 61/61 green with the envelope at 503) but `DeployLedger`
  keys its refusal class on the STATUS alone, so a 503 refiles those rows into `BOX_UNAVAILABLE_503` —
  **the exact class wave 8 is emptying of `feature_not_configured`.** Keep the status, name the code, and
  make the ledger's refusal arm code-aware (filed, not built this wave).

- **D116 — S3 IS A DELETION, NOT A BOUND. THE GRAPH ROUTE PAYS ~1,300 SERIAL DB ROUND TRIPS FOR A
  BOOLEAN IT THROWS AWAY.** Three bounds already ship (per-type 1000, node budget 2000, concurrency 4 +
  ETS slots) — so the direction's "bound `derive_graph_corpus/2`" is stale. What actually costs:
  `edges.ex:293` sets `dangling = not resolve_target_existence(…)` per reference-value per document,
  un-batched and un-memoized; `derive_graph_corpus/2` then maps `raw_edges` to
  `%{from_id,to_id,kind,weight,plugin_source}` and **`dangling` is never read in the corpus path**
  (`grep -n dangling` over `tasks_controller.ex` hits only the separate `/v1/graph/dangling` route).
  Measured `xact_commit` delta around one call: **+1,484 / +1,318 / +2,332** against a no-call baseline of
  +86…+140. n=30 with the REAL site deploy token: p50 5.958 s, **p95 23.426 s**, 8/30 over 15 s, **4/30
  HTTP 500** clustered at 16.1–17.4 s — right at the `DBConnection` 15,000 ms ceiling. Reproduced on
  demand: request `GMlf-hDV0Jp80lcAAB5S`, `Sent 500 in 18863ms`, then `DBConnection.ConnectionError`.
  A time bound leaves 1,300 round trips and just fails faster.

- **D117 — D17's HUMAN GATE DOES NOT REACH `edges.ex`. RULED HERE SO NO BUILDER RULES IT AT BUILD TIME.**
  D17 (charter line 134) fences `public_read.ex` **and the graph admission path**, and this charter already
  self-rules at line 366 that "D17's fence is literal and narrow." `resolve_target_existence/4` is in
  `api/lib/barkpark/content/edges.ex`; the admission path is `graph_corpus/2`'s ETS slot acquire and
  `visible_schemas/2`. **A cost fix confined to `edges.ex` plus the call from `derive_graph_corpus/2`
  needs NO human gate. Any edit to `visible_schemas/2`, the slot cap, `public_read.ex`, or the router
  allowlist is INSIDE D17 and is human-gated with a NAMED reviewer.** The slice may not cross that line.

- **D118 — THE MEMORY STORY IS REAL, AND `MemorySwapMax` ON THE SERVING SLOT IS FORBIDDEN.** Guerrilla is
  NOT quiet: swap 1,799/2,047 MB (87.9%), load 6.98 on 2 cores, **58.2% of the serving BEAM paged out**
  (SwapPss 701 MB of 1,206 MB), 71.8 MB/min swapping IN at ~97 major faults/s. Postgres is NOT starved —
  12 of 100 connections, ONE active, longest active query 2.30 s while the 15 s checkout timeout fires,
  so the pool timeout is a **BEAM-side stall**, not SQL contention. But the serving BEAM was **globally
  OOM-killed twice in 24 h** (`constraint=CONSTRAINT_NONE … global_oom … task=beam.smp`, anon-rss 1,230 MB
  and 2,449 MB), with `MemoryMax=infinity` on every unit. **The API is the designated OOM victim.**
  Capping the slot makes it die sooner at a cgroup boundary. If a memory lever is ever taken it belongs on
  the per-build transient units (`bp-site-build-<site>-<hash>-<epoch>.service`), never on the slot. Sell
  D116 as removing cold-memory exposure — never as fixing a slow query.

- **D119 — THE GRAPH CLASS'S "ONSET" IS THE PRODUCER FIX, NOT AN INCIDENT, AND BUILD WINDOWS ARE
  ANTI-CORRELATED.** Per-hour, doc-id rows split with/without a trailing status show a hard crossover at
  2026-08-05 21: before it, ZERO rows carry a status; after it, every row does — while guerrilla's journal
  already threw 121/hr and then 703/hr `derive_graph_corpus` errors. **08-05 21:40 is the minute wave-1
  slice-5 started telling the truth.** Rows before it are unrecoverable and any backfill must refuse below
  that timestamp rather than classify them forever-UNCLASSIFIED. Separately: only 13 of 261 graph failures
  (5.0%) land inside a site-build window against an 11.8% wall-clock baseline — **relative risk 0.42.**
  The peak build hours (08-05 18–20, 37/41/44 builds/hr) had ZERO graph failures. Also: the episode ENDED
  with **zero commits on origin/main** between 08-06 19:00 and 08-07 01:30 while deploy volume hit its 30 h
  maximum. Any wave-8 "we fixed it" measured tonight is vacuous green — prove by MUTATION against stored
  rows, never by watching the live rate.

- **D120 — DR OWNS `console-harness.yml` FOR THIS FAULT CLASS, BY THIS CHARTER'S OWN D101.** The Digest's
  claim that "D101 does not exist in the DR charter at all" is **REFUTED**: `D101` is at charter line 2195
  and reads "AN INSTRUMENT THAT CALLS A DEAD BROWSER A CSS DEFECT IS THIS EPIC'S OWN THESIS, LIVE, ON A
  REQUIRED BLOCKING GATE," carrying an explicit FENCE clause excluding cch's `app.js`, notifications tree
  and path-escape scripts. No carve-out, no hand-off, and no new decision is needed — the instrument is
  already claimed with a fence, and wave 8 stays inside it.

- **D121 — A FAILED JOB'S `outputs:` DO REACH `needs.<job>.outputs`. PROVEN ON LIVE GITHUB, AND
  `continue-on-error` STAYS BANNED.** Throwaway probe (run `31136979488`, scratch branch since deleted):
  `A.result=[failure] A.verdict=[REFUSED_ENV]` (output written in the same step that then `exit 1`),
  `B.result=[failure] B.verdict=[REFUSED_LATER]`, `C.result=[success] C.verdict=[MEASURED_OK]`. So the
  refusing job keeps exiting non-zero — `needs.X.result` stays `failure`, fail-closed preserved — **and**
  the aggregator can additionally read a `verdict` output and name an ENVIRONMENT fault instead of
  accusing a stylesheet. `continue-on-error` would launder `result` to `success` and is refused (D19).

- **D122 — THE CHROME REFUSAL IS PER-VM AND STOCHASTIC, SO A RETRY IS THE CORRECT INSTRUMENT — AND IT
  MUST ALLOCATE A FRESH PROFILE AND CAPTURE STDERR OR IT SHIPS A FIX NOBODY CAN AUDIT.** Base rate over
  85 real browser-job attempts: 74 success / 11 failure, 10 of the 11 DevToolsActivePort refusals →
  **p ≈ 11.8% per attempt**, ≈31% per run at three browser jobs. Capacity is REFUTED four ways: same run,
  same second, same sha — `Billing tier floor` success at 00:15:17 while `Overflow guard` refused at
  00:15:17; the one all-3-fail run spanned three Azure regions and two runner images; a same-instant,
  same-region, same-image control succeeded. `#9960` fixed the `.mjs` classifier and changed **nothing**
  in the workflow — its diff for `.github/workflows/console-harness.yml` is EMPTY, and all exit-2 arms
  (lines 438-439 / 516-517 / 591-592) still end in `exit 1`. Captured live on main at 01:03:02Z after
  #9960 merged: the honest banner prints, then `Process completed with exit code 1`, then `Console gate …
  RED on purpose`. **The banner exists; the exit code is the defect.** The profile dir is `mkdtemp`'d ONCE
  before the bring-up loop (`cssom-parity.mjs:565`) and `spawn(…, {stdio:"ignore"})` throws Chrome's
  stderr away in all four instruments — a retry that keeps either is a hidden fix.

- **D123 — `Oban.Plugins.Lifeline` IS SAFE, AND THE PREMISE "5 SILENTLY DROPPED PUBLISHES" IS REFUTED.**
  `cloud/config/config.exs:232` configures Pruner + Cron and nothing else; Pruner never touches
  `:executing`, so 8 jobs (5 `AutoDeployWorker`, oldest 2026-07-28) sit `executing` forever, each orphaned
  by a dead BEAM node. **The double-run danger is structurally impossible**: `perform/1` enqueues and spawns
  a supervised driver and returns — over **13,287 completed AutoDeployWorker jobs, p50 0.329 s, p99 5.771 s,
  max 15.017 s, ZERO over 30 s.** But every zombie's trigger was carried by the next job within
  **62–156 seconds** (job 285013 minted deployment `fe6ab31c` at +91 s; the site reached `live` at 15:02:52).
  **So the cost is a REPORTING lie — 5 rows claiming to be running for up to 10 days — not a lost publish,
  and the wave must say it that way.** The 15.017 s max is exactly Oban's unset `shutdown_grace_period`
  default: the distribution is CLIPPED at the grace boundary, which is why `rescue_after` must be ≥60 s
  (ruled: 5 minutes, 20× the observed max). Adopting Lifeline immediately re-performs the 5 zombies with
  `force: true` — 5 redundant builds. That is the stated one-time price, and the lead discards the rows.

- **D124 — THE RAW-LOG PIPE IS BACKWARDS ON A LIVE SECRET BOUNDARY, AND THE TEST PINS THE LEAK INSTEAD
  OF FAILING ON IT.** `router.ex:10693` ships `failure_reason_raw` as `scrub() |> strip_ansi()`. Measured on
  origin/main: 2,000 fresh colourised `api_key=<24-char>` values → **2,000/2,000 leak under the shipped
  order, 0/2,000 under the flipped one.** Proven end-to-end through the real `GET /v1/sites/:id/deployments`
  route: the JSON field came back `"…403 api_key=Qp9vR4tZ7wN1cB6yH3sD5fG0"` — ANSI stripped, **secret
  intact**, which is what makes it dangerous. Flipping the one line turns it into `api_key=[redacted]`.
  Three things the epic did not know: (a) **the suite is INDIFFERENT** — 142 tests green with the pipe
  either way, and the one boundary test uses a `Bearer sk-live-…` shape that redacts under BOTH orders, so
  it is structurally incapable of catching this; (b) `humanize/1`'s passthrough arm leaks the same way and
  the safe fix is `classify() |> strip_ansi() |> scrub()` (proven: LEAKS=false, 142/142 green) — the filed
  task's "leave humanize/1 alone" is WRONG; (c) `stage_caption/2` and `event_email.ex:105/141` call bare
  `scrub` with no strip at all, so they leak the secret AND raw `0x1B` into a customer's inbox. The figure
  is length-conditional (2/2,000 at 32-48 chars) and must be quoted as "sub-32-char colourised `api_key=`."

- **D125 — THE ROUTER'S ONE LINE IS TAKEN, DESPITE THE ROUTER FENCE.** `cloud/.../web/router.ex` carries
  four open PRs and is on this wave's WILL-NOT-TOUCH list. **Narrow carve-out: line 10693 only**, changed
  to a single call into a new `FailureCopy.raw/1`. It is a live secret boundary, the edit is one line
  ~10,000 lines from any contending hunk, and the alternative is shipping a wave that knows about a leak and
  leaves it. Nothing else in `router.ex` may be touched.

- **D126 — DEFERRAL HONESTY HOLDS; THE PLAN-REWRITER DID NOT FIRE.** 319 chains started in 24 h: **209 end
  failed, 107 end live, 4 open — and all four are the live head of a live site, aged 33–47 s against a 60 s
  debounce**, each with a scheduled Oban job waiting. Longest chain 9. **The 12-cap has fired ZERO times**
  (0 of 208 chain-terminal failures carry the cap's own phrase "rebuilds in a row"). Do NOT open a cap
  slice: the cap guards a condition that does not occur, and what terminates chains is an ordinary failure
  of the kind the rest of this wave is about.

- **D127 — MERGE ORDER IS A RULE, NEVER AN ENUMERATED LIST.** #9888, #9960 and #9922 all merged inside
  **14 seconds** at 00:51Z — after the Digest's own 00:50Z re-derivation. `origin/main` moved twice more
  during Decide. Any charter sentence naming PR numbers has a shelf life measured in minutes. The rule:
  **merge everything CLEAN, then re-query.** Two mechanical corrections that cost real time this wave:
  `git merge-base --is-ancestor <headRefOid> origin/main` returns rc=1 for a MERGED **squash** PR — ask
  `.mergeCommit.oid`; and `gh pr view --json mergeStateStatus` returns `UNKNOWN` on the first query after a
  fetch and must be re-asked. #9887 is blocked by an **ABSENT** required context, not a red one (its
  console-harness run sat `queued` with ZERO jobs for 8 h 18 m) — and per D102 a re-run DELETES the check,
  so the only safe unblock is a fresh head sha.

- **D128 — SIXTEEN MERGED TASKS ARE UNSTAMPED, AND THAT IS THIS EPIC MIS-REPORTING ITSELF.** The epic has
  123 children: 107 open, 12 done, 2 in_progress, 2 cancelled. **16 of the open rows have a MERGED PR and
  31 unstamped criteria between them; nine are exactly ONE criterion short**, and in the three audited the
  sole unmet criterion is a pure merge-gate satisfiable by `gh pr view --json statusCheckRollup` plus
  `.mergeCommit.oid` ancestry. Two of three audited are free closes; the third (`dr-w3-s5`) smuggles "AFTER
  an independent second review of the door-vs-unit race" into the same criterion and `gh pr view 9827
  --json reviews` returns ZERO reviews — so it needs the human, not a stamp. **A bulk-stamp script is
  BANNED**: the obvious extractor (`doc['acceptance_criteria']`) prints NOTHING because criteria live under
  `doc.content`, so it reads every task as fully met and stamps blind; and a check-runs-only verifier misses
  `PR references an active task` entirely, because that is a commit-status. Use `criteria_progress` plus a
  per-task text read.

- **D129 — EVERY SLICE THIS WAVE IS OPUS.** Fable is unavailable fleet-wide. S3 and S5 would otherwise be
  fable on the difficulty axis (blast radius across `/v1/graph/dangling` + EdgeProjector; a required
  blocking gate). They are flagged HIGH-FLIP-RISK instead, and the lead is owed an independent second
  reviewer on both before merge.

### Wave 8 plan — 7 slices, all round 1, file sets disjoint

| # | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|
| 1 | The ledger names the cause AND names its denominator | `dr-w8-s1-ledger-names-cause-and-denominator` | `cloud/**` + `deploy/**` | large | opus |
| 2 | A runner that did not answer stops blaming a flag that is set | `dr-w8-s2-runner-timeout-stops-blaming-the-flag` | `api/**` + `cloud/**` | medium | opus |
| 3 | `/v1/graph` stops paying ~1,300 round trips for a discarded boolean | `dr-w8-s3-graph-stops-paying-for-a-discarded-boolean` | `api/**` | medium | opus |
| 4 | The census reaches a human, and refuses out loud | `dr-w8-s4-census-reaches-a-human` | `internal/**` | medium | opus |
| 5 | A refusal is not an accusation (exit-2 verdict + Chrome retry) | `dr-w8-s5-refusal-is-not-an-accusation` | CI + `cloud/priv/static/__preview__/**` | medium | opus |
| 6 | The raw capture stops leaking a colourised secret | `dr-w8-s6-raw-capture-stops-leaking` | `cloud/**` | medium | opus |
| 7 | Orphaned jobs stop claiming to be running | `dr-w8-s7-orphaned-jobs-stop-claiming-to-run` | `cloud/**` | small | opus |

HIGH-FLIP-RISK (D129, independent second reviewer owed before merge): **S3** — whether the `dangling`
deletion is invisible to `/v1/graph/dangling`, `EdgeProjector` and `corpus_edges/3`, and whether the edit
stays outside D17's fence. **S5** — whether the aggregator's refusal arm can ever green an unmeasured gate.

Coverage: every survey and verify agent reported; there is no coverage deficit this wave.


## Wave 9 decisions — THE VERDICT FLAPS, THE RATE HIDES ITS ABSORPTION, AND THE MOST SEVERE OUTCOME WEARS THE MILDEST NAME (2026-08-07)

Paper `deploy-reliability-wave-9-2026-08-07`. Epic task `task-fb4fb869490b4213`. Every number below was
re-derived at 2026-08-07 02:30–03:15Z against `origin/main` 95642c550, cloud-db-1 (178.105.92.191) and
guerrilla (157.180.90.121). Three of the direction's own premises were refuted by the verify round and are
recorded as reversals, not as footnotes.

- **D130 — #9887 IS NOT MIS-FENCED. IT FLAPS.** The direction's headline ("merge it as written and guerrilla
  still prints ok") is TRUE of the 02:35:07Z beat and FALSE of the box. Replaying all 7,202 health beats the
  CP received in 24 h through the PR's own predicates: guerrilla comes out `strained` on **329 of 1,442**
  beats (23% of all beats, 43% of the 770 where `loadPerCore` is evaluable at all) and jarl comes out
  `filling` on **1,440 of 1,440** (disk 96%). Per hour, guerrilla crosses 1.75/core on **38 of 60** minutes in
  the 01:00Z hour and **11 of 61** in 02:00Z; 02:35Z is one of the 50 that miss. D67's own ruling text names
  the discriminator — *"what discriminates is flap at the moment the owner looks"* — and then ships a
  latest-beat fence anyway. **RULING: wave 9's verdict work is a SUSTAIN mechanism, not a new threshold. Do
  NOT lower 1.75** (dropping it to 1.5 also catches the beat, 405 vs 329 firings, and is arithmetic fitted to
  one reading — declined out loud). And landing #9887 unchanged is still the single strongest verdict win
  available: it fixes jarl on 100% of beats.

- **D131 — `p95_ms` DOES NOT GET A RUNG. THIS REVERSES PRIORITY 2 AS WRITTEN.** Three independent
  refutations. (a) **INSTRUMENT COVERAGE, not discrimination**: dooodo/gyl/jarl emit `p95_ms = -1` (the
  agent's honest-absence sentinel, `report.go:138-141`) on every beat and Gyldendal emits no key at all — a
  naive `p95 >= X → strained` reads three unmetered boxes as the FASTEST in the fleet. (b) **The beat's p95
  is a lottery**: at 1–3 req/s the 60 s ring holds ~66–150 samples, so `ceil(0.95·66)=63` makes p95 the
  4th-slowest request of ~66. One verifier watched it move **1055 → 341 → 866 → 240 → 125 → 99 → 1145 ms in
  ten minutes on an unchanged box**, purely by adding traffic; bucketed, `rps<2` reads a median p95 of
  **1101 ms** and `rps>=5` reads **376 ms**. A p95 fence fires when the box is QUIET — the exact inversion
  D103 already caught for the 5xx share. (c) The direction's `32777` is the **24 h MAX**, not the 02:35:07Z
  beat, which carries `p95_ms 4122`, `swap_used_percent 52` (not 75) and `disk 76`. **WHAT SURVIVES:**
  `p95_ms` and `req_per_s` still join the pressure block per D103 — `req_per_s` is the denominator a 5xx rate
  can never be printed without, and the volume figure is what makes any latency claim readable. The rung is
  declined; the vital is not.

- **D132 — AND YET p95 IS REAL ROUTED-REQUEST LATENCY. The attack on the premise FAILS, mutation-proved on
  the box.** 300 requests to `/live/websocket` moved `req_per_s` **+0.15**; the identical control, 300 to
  `/v1/capabilities`, moved it **+5.10 (= 300/60)** — Phoenix 1.8.9 registers `plug :socket_dispatch` inside
  `__using__` (endpoint.ex:506), i.e. BEFORE `plug Plug.Telemetry`, and halts (:651). Third confirmation:
  **0** socket paths in 20,510 logged requests. 12 concurrent 25-second SSE streams landed at stream OPEN at
  ~0 ms (`Plug.Telemetry` times inside `register_before_send`, and `listen_controller.ex:57-61` chunks
  immediately) and pulled p95 **down** 866 → 99 ms; no 25,000 ms sample ever appeared. A request that raises
  `DBConnection.ConnectionError` DOES land as a 500 with its full duration (`Sent 500 in 17330ms` immediately
  above the error) — and 2,495 of 2,673 attributed pool timeouts on blue are Bandit REQUEST processes, so
  **`err_5xx_per_s = 0` is HONEST, not an instrument pointed at the wrong root.** The slowness is real on a
  long window: **n=20,510 over 84 min — p50 16 ms, p90 1134 ms, p95 2750 ms, p99 8811 ms, max 43,966 ms**,
  with 174 requests over 10 s concentrated in FOUR routes: `/v1/graph` 70/174 (mean 4847 ms, histogram floor
  `le=2500 → 0` — never faster than 2.5 s), `/v1/tasks/prime` 38, `data/search` 34, `data/mutate` 23. The
  instrument that does not lie is `phoenix_router_dispatch_stop_duration_bucket{route=…}` on
  `/v1/instance/metrics` — cumulative since slot boot, already exposed, already authed, **read by nothing**.
  One narrow blind spot to state whenever `err_5xx_per_s` is rendered: a LiveView killed by a pool timeout
  emits no `:stop` and no 5xx sample (7 of 2,673 on blue). Word it *"the HTTP router is answering N 5xx/s"*,
  never *"the box is healthy"*.

- **D133 — `cpu_percent`, SUSTAINED, IS THE ONLY FLEET-METERABLE FENCE, AND IT SEPARATES PERFECTLY.** Payload
  key census over 48 h / 10,974 beats: `cpu_percent`, `load1`, `disk_used_percent`, `mem_used_percent` are on
  **all five** boxes; **`cpu_cores`, `load15` and `swap_used_percent` are Guerrilla-ONLY** (`has_cores` = 766
  on guerrilla, **0** on each of the other four). So `load15/cores` AND the `load1/cores` fallback are
  structurally UNCOMPUTABLE on 4 of 5 boxes — the denominator is absent, and under D42 a nil vital never
  strains. **The trap to name: `load1` IS fleet-wide and guerrilla's `load1_max` is 15.91 against a fleet
  ceiling of 2.63 — beautiful-looking separation that is D52's error re-committed, because the boxes have
  different core counts.** Do not substitute raw `load1`. `cpu_percent >= 85` as a LEVEL is nearly-but-not
  clean (guerrilla 1234/2882, Gyldendal 35, **dooodo 1 — a healthy box**, jarl 0, gyl 0). `cpu_percent >= 85`
  **sustained over a rolling 15-beat window** is clean: **guerrilla 797 beats at ≥12/15 (357 at a full
  15/15); every other box ZERO, and no other box's window ever exceeds 5.** Every threshold from 6 to 15
  yields the identical partition. **RULING: the sustain fence is `cpu_percent >= 85` on ≥12 of the last 15
  beats, stated as calibrated on a fleet where exactly one box is sick.** Named seam cost, which IS the
  slice's work: `merge_pressure/2` (router.ex:8851) folds ONE `%{payload:, reported_at:}` — the CP has no
  beat history at the pressure seam. Honest framing: this is a **fallback forced by an undelivered agent**,
  not a preference; `load15` remains better on the merits and is blocked solely on the human gate
  `dr-bl-w6-cut-and-bless-v0-2-26`. Guerrilla's agent is dated Aug 7 02:36 (hand-rebuilt tonight, first real
  `load15` row 00:56:58Z); jarl's is Jul 30 14:25.

- **D134 — D126 IS STRUCK, AND IT WAS NEVER ON `origin/main`.** D126 read *"The 12-cap has fired ZERO times…
  Do NOT open a cap slice."* It fired **three times on 2026-08-07** (01:20:14Z, 01:37:41Z, 02:33:55Z, all
  `box_at_capacity` at 12) plus one 6-round `already_running` firing on 2026-08-05 22:57:53Z. It also
  contradicted this charter's own D38, which had already recorded the terminal arm as fired in production.
  `origin/main`'s charter is 2,390 lines and contains no D126 — it lived only in the primary checkout's
  uncommitted copy, so the correction lands with its first publication. **Leaving a dead measurement standing
  as live authority is this epic's thesis pointed at itself.** D37's separate prohibition (do not raise the
  cap; the gate is built and is law) stands and is NOT what wave 9 opens.

- **D135 — ABANDONED GETS ITS OWN CLASS. THE MODULE ALREADY OWNS THE READER IT REFUSES TO CALL.** All four
  cap-terminal rows replay through `DeployLedger.classify/2` on `origin/main` as `BOX_BUSY_409`, label *"the
  box was already deploying (HTTP 409)"* — **affirmatively FALSE** for the three capacity rows (the box was
  not deploying that site; it had no free slot). Routing the SAME bytes down the DEFERRED arm returns
  `BOX_AT_CAPACITY_DEFERRED` ×3 / `BOX_BUSY_DEFERRED` ×1: `deferral_code/1` recovers the box's code word
  cleanly, and is wired to the LESS severe path only. Worse, `Sites.Deploy.defer/3` computed the class 90
  lines earlier (`deploy.ex:1189 cause = deferral_cause(...)`, used at :1196 and :1280-1289) and then wrote
  **prose the ledger re-parses**. `git grep "rebuilds in a row"` = one line, the producer, zero consumers.
  **VOLUME HONESTY, per D107: 3 of 3 failed 409-prefix rows in 24 h — a correctness and honesty defect, not a
  rate mover. Quote it as "the taxonomy lies about its most severe outcome", never as "N% of failures are
  mislabelled".** Composition with #10014 (proved by run, not read): semantically DISJOINT — #10014's new arm
  is `content_doc_status/2`, stage-gated to `"HEALTH"` and anchored on `could not read a content document`,
  and sits AFTER `refusal_code`, so it can never see a 409 row; **40 tests, 0 failures with both applied**.
  Textually CONFLICTING in **four** points in `deploy_ledger.ex` (`@classes` after `BOX_BUSY_409`, `@labels`
  after its label line, the cond arm after `refusal_class(code)`, and the defps before
  `refusal_class("409")`). **Compose, do not race.** A producer-side anchor self-test is REQUIRED — #10014 set
  that precedent; without it, rewording `deploy.ex:1200` silently degrades every abandoned row back to
  `BOX_BUSY_409` with nothing failing anywhere.

- **D136 — THE RATE NAMES ITS ABSORPTION, AS TOP-LEVEL KEYS, WITH ITS GO READER IN THE SAME SLICE.**
  `deferred_total` + `absorption = rate(deferred_total, volume)`. Reusing `rate/2` buys @min_sample's refusal
  for free — proved at n=20: `refused == true`, `pct == nil`, `reason == "sample 20 below min_sample 200"`,
  and explicitly `refute pct == 0.0`; at n=200: `refused == false`, `pct == 75.0`, headline `failure_rate`
  unmoved. **The ROW form is BANNED**: mutating `census.deferred` to carry an `ABSORPTION` row broke TWO
  pinned tests (the :519 relocation assertion at :555-556, and an exact-map compare at :650/:704 the survey
  never named). Basis is `@basis_attempted` — no fifth string. **And the Go half ships in the SAME slice**:
  a server-additive key alone is invisible in `bp cloud deployments`' human printer (`cloudclient.DeployCensus`
  has no field for it), and `err_5xx_per_s` is the standing precedent for what that costs — landed in
  `merge_pressure`, **zero consumers anywhere**. A CP-only merge would make absorption the fourth
  landed-and-unread number in this epic.

- **D137 — THE REGIME BOUNDARY IS 2026-08-06 22:24:16Z AND NO RATE CROSSES IT.** `box_at_capacity` has ZERO
  rows before 22:29:27Z; `already_running`'s last row is 19:37:26Z; guerrilla cut blue/green at 22:24:16Z —
  the two 409 classes have **zero temporal overlap**, so the "deferral flood" is a code path going live, not
  a load change. Between 19:49:39Z and 22:11Z `content-auto` produced 5 then 0 rows while `template-auto`
  held at exactly 1/hr: a **2 h 21 m TRIGGER BLACKOUT**, not a quiet pipeline. Re-taken on a busy host, per
  side, with denominators on the same line: **pre-door 1,032 failed / 1,611 terminal = 64.1% (1,032 of 2,308
  all rows); post-door 8 failed / 223 terminal = 3.6% (8 of 900 all rows, 677 of 900 = 75.2% ABSORBED).**
  **AND the counterweight, which must ride the same line:** live/hr roughly DOUBLED (pre ~15–27, post
  28/38/48/48/51). Absorption can only remove attempts; it cannot manufacture releases. Something genuinely
  got better and attribution is unavailable because three things changed at once. The repairs are real too —
  all four previously-dead sites ship again, `internal_error` and Turbopack are at zero — **and**
  `feature_not_configured` still fires (263 rows, last 01:49:05Z, `/opt/barkpark/.env` untouched since
  07-26). Both sentences, one line, always. **The 5.0%-of-202 figure from the direction must never be quoted
  as improvement.**

- **D138 — THE TEAM-SCOPED READ IS ALREADY OPEN, AND WHAT ARRIVES IS CAUSELESS.** Proved by run: a plain
  `member` with a session token gets **200** from `GET /v1/sites/:id/deployments` — `with_team_site/2`
  defaults to `:session` (router.ex:10941) and performs NO role check; the existing test only ever logs in an
  `owner`, so the member case was untested. `bp login` stores a **session** token (`login_device.go:175`;
  PATs carry a `bpc_pat_` prefix and the stored `cloud_token` has none), and `bp sites deployments search -o
  table` printed real rows tonight from the owner's installed binary. The PAT is the one that loses, and the
  two routes disagree: owner+PAT is **401 on the LIST route** and **200 on the singular**. The server ships
  **25 keys** including `failure_class = BOX_AT_CAPACITY_DEFERRED` and a `next_cursor`; `cloudclient.Deployment`
  has **11 fields and no `FailureClass`**, `ListDeployments` sends no `limit` and no `before` so it can never
  page past 100, and `renderDeploymentsTable` prints STATUS·IMAGE_TAG·GIT_REF·STARTED — **three of four
  columns are "—" on every guerrilla row.** A rate WITH its absorption label is already computable from the
  reachable route: for site `search`, the 100 newest rows (00:21:38Z→02:57:30Z) are 20 live / 77 deferred / 3
  failed = **3 of 23 terminal = 13.0%, with 77% of rows absorbed**. **CORRECTION to the lead's answer (c):**
  "platform-operator-gated with the crown dark" is TRUE of `bp cloud deployments` (the `/v1/operator/...`
  census, and the installed binary also lacks the verb) and **FALSE of `bp sites deployments`**, which is
  team-scoped, session-gated, and works right now. Both sentences need saying; they attach to different verbs.

- **D139 — THE TREADMILL LEVER IS REAL, CHEAP, AND ALREADY SHIPPED-BUT-UNREACHED.** A refusal is near-free at
  the box door: `/v1/admin/site-deploy` is **44.1 ms/request** over 448 hits, and `box_at_capacity?/2` is an
  in-memory slot scan — no DB, no disk, no spawn. **The cost is the FAN-OUT.** All five `site-autodeploy-*`
  webhooks on guerrilla still carry `types = {}` (the match-everything sentinel) and delivered **2,310 events
  in 6 h across 5 endpoints = 77.0/hr/endpoint; with `types=[paper]` that is 5.3 — a 93.1% cut.** All-time,
  `task` writes are **96,480 of 106,904 deliveries = 90.3%**, confirming the merged registrar's own comment
  to the decimal on a window 12 days longer. `Registry.ensure_content_webhook/2` is idempotent and unit-tested
  and has **ZERO production callers** (cloud ships exactly two mix tasks, `Release` exports only
  migrate/rollback, no route, no `bp` verb). **But the EFFECT is reachable today with zero code**: `bp cloud
  webhook edit <instance> <webhook-id> --types paper` shipped 2026-07-12 (#2772,
  `cloud_webhook_cmd.go:194-232`), goes through the user-scoped CP proxy PUT with the instance admin token
  staying server-side, and the box's `update_webhook/2` casts `:types` normally. **So charter line 459 ("no
  sanctioned mutation path from the sandbox") and `dr-w1-s4-followup-repair-live-webhook-types`' description
  ("bp webhook update sets URL only") are BOTH STALE — they describe the BOX verb, not the cloud proxy verb.**
  Honest limit: six further content-bound sites have `content_webhook_secret_encrypted IS NULL` and
  `ensure_content_webhook` REVEALS rather than MINTS, so it `:noop`s for them (site-spawner D84); they carry
  no box row and contribute zero deliveries. **Ship the repeatable verb AND run it — never the hand-edit
  alone**, because the next `doc_type` change drifts the row back to `{}` forever with nothing re-asserting it.

- **D140 — THE BEAT CANNOT DATE ITS OWN PRODUCER, AND THE ONLY OTHER ROUTE JUST CLOSED.** No `agent_version`
  key on any box's payload across 1,801 beats in 6 h. The producing binary was readable only as a file mtime
  over SSH, and SSH now fails on **2 of 5 boxes** — `REMOTE HOST IDENTIFICATION HAS CHANGED` for dooodo
  (116.203.91.216, `known_hosts:54`) and gyl (46.225.61.223, `known_hosts:53`), while both beat normally, so
  it is almost certainly a re-image. Consequence: **a missing vital is indistinguishable from a healthy
  vital**, and D133's entire coverage table rests on inference from output rather than from the artifact for
  two boxes. This is the epic's own disease inside the instrument that measures the instruments.

- **D141 — THE JAM IS ONE PASS, AND A REBASE GREENS THE CONSOLE GATE — OBSERVED, NOT INFERRED.** #9959 was
  rebased 328452bb2 → e1d08b665 onto `origin/main` and watched: `Console gate` fail 4s → **pass 2s**,
  `Overflow guard (rendered)` fail 27s → **pass 40s**, all four required contexts pass, BLOCKED → UNSTABLE.
  **#10016 is CLEAN and mergeable right now** — it was never blocked; it is a choice not made, and on a box
  showing these latencies that perf fix is itself a box-health intervention. **But the green does NOT
  validate #10018**: Chrome came up on attempt 1, the retry was never exercised, and console-harness's base
  failure rate is **9.4% (20 of 213 terminal runs since 08-04)** — so budget ~1 in 10 rebases needing a second
  push, and do not read the post-merge silence (3 runs) as efficacy. **#9887's block is a PER-RUN ZOMBIE, not
  concurrency and not runner minutes**: three of its twelve runs have sat `queued` since 2026-08-06T16:43:08Z
  with **ZERO jobs materialized** (a concurrency-blocked run has pending jobs; these have none), four
  different workflows are stuck across two branches, and the class is old — a `pr-task-gate` run from
  2026-07-23T07:38:15Z is still queued. A fresh head sha escapes (12/12 materialized on a test push, adding
  no new zombies). **AND THE MANDATED DIAGNOSTIC LIES**: `gh api …/actions/runs --jq '[…|select(.status=="queued")]|length'`
  returns **0** while **SIX** runs are queued, because the endpoint defaults to the 30 newest runs. Truth needs
  `?status=queued&per_page=100 --paginate`. A verifier who ran the mandated command and stopped would have
  reported "no queue, so not a queue problem" and mis-diagnosed the flagship.

- **D142 — THE JOURNEY METRIC IS BUILDABLE; THE ABANDONED RATE IS FILED PENDING.** The DESC-ordered window
  defines a journey BACKWARDS — structural proof, not argument: under that ordering `max(terminal) - min()`
  is **0.0 s for every group**, because the terminal IS the group minimum. Corrected to ASC: **695
  live-terminated journeys, 2.00 attempts/release, median TTL 0.0 s, p95 364.7 s** (499 of 695 are
  singletons); on the contended subset — the 196 live journeys with ≥1 deferral — **4.55 attempts and 183 s
  median TTL**. The direction's "4.0 attempts/release" is true of the contended subset ONLY; the fleet figure
  is 2.00, and quoting 4.55 as the fleet number is the same sin in the other direction. **The abandoned RATE
  does not ship**, three measured defects: (a) `content_rev` is a sha256 prefix with no ordering, so
  `term_rev <> head_rev` cannot say which way content moved — **5 of 60 abandoned live runs shipped a rev
  FIRST SEEN EARLIER than the run head**, i.e. "shipped stale" hiding inside "abandoned"; (b) all seven
  deploying sites carry the identical `(default, default, production, paper)` tuple, so `content_rev` is
  fleet-global BY CONSTRUCTION (one rev spans 6 sites and 210 rows) and 60 abandonments are ~one correlated
  signal repeated seven times; (c) **78 rows in 24 h carry a NULL rev** (zero carry the `@unknown_content_rev`
  empty string), stranding 67 failed and 4 live journeys as UNMETERED. Plus a **43× swing across the 22:24Z
  door** (0.6% → 26.1%). A journey is a maximal run over `(site_id ORDER BY inserted_at)` terminated by the
  next live/failed row — **segment by RUN, never by rev group** (one rev went live 11 times in 61 minutes) —
  and it must fail closed on the empty rev, which is precisely the value a STRAINED box degrades to.

- **D143 — /v1/graph IS THE MEMORY STORY, MEASURED FROM OUTSIDE THE BEAM, AND #10016 DOES NOT TOUCH IT.**
  D39 stated *"WHICH subsystem grows is UNPROVEN"*; this supplies it. 1 Hz `/proc/<beam>/status` sampling
  aligned to journal timestamps, three independent natural graph calls: **+684 MB, +568 MB, +646 MB within
  2–4 s**, each off a tightly-clustered 403–446 MB idle floor, on a 3,819 MB / 2-core box, decaying back in
  ~10 s. Honesty control: a 1,467,924 kB peak at 03:09:52 had **no** graph call, so graph is a large named
  driver and not the only one. Both 24 h OOM kills shot `beam.smp` itself (anon-rss 1,230,424 kB and
  2,449,108 kB, `MemoryMax=infinity`), and the graph admission cap is 4. **#10016 deletes ~1,300–2,300 serial
  round trips and the pool-connection hold — it reclaims the pool-timeout story and NOT the OOM story, and it
  must not be sold as both.** Attribution method matters as much as the number: `grep -B3 "Sent 500"` returns
  *19 site-deploy / 8 graph* from the same log where the `request_id` JOIN returns **27 `/v1/graph` (56.25%)
  / 18 search / 3 query, 48 of 48 accounted, 48 of 48 carrying `DBConnection`**. Opposite answers, same log —
  **proximity attribution is fiction on an interleaved journal.** Separately, the swap story is
  mis-attributed: `beam.smp` is 5.5% swapped and ranks NINTH; the top eight swap consumers are all
  `next-server` SSR processes, 13 site units on a 2-core box with `MemoryMax=infinity`. The absorption story
  and the OOM story are the same story: a refused attempt is free, a SUCCEEDED one leaves a resident SSR
  process in the memory that later kills the API.

- **D144 — SLOT AND UNIT ARE NOT CONSTANTS, AND THREE MEASUREMENTS IN THIS WAVE DIED ON IT.** Guerrilla cut
  over **four times in 4.2 h** (22:24:16 blue → 00:38:37 green → 00:55:20 blue → 02:35:02 green), so **no
  slot on this box reliably lives 60 minutes** and any instruction phrased as "the last 60 minutes on unit X"
  is unsatisfiable as written. The direction's "64 DBConnection/hr" was read from `barkpark-slot@blue` three
  seconds after the box cut to green; blue is now inactive and that exact command returns a comforting zero.
  Unit-agnostic truth: **461/55/100/5/11/112/2 per hour**, and by `_SYSTEMD_UNIT`, 129 blue + 101 green over
  6 h — the errors **follow the active slot**. Two further traps recorded so they are not re-paid:
  `grep -oE "barkpark-slot@[a-z]+|start.sh"` over `short-iso` output attributes to the SYSLOG IDENTIFIER and
  both slots run `start.sh`, so it silently answers "230 start.sh"; and `BARKPARK_HEALTH_TOKEN` **does not
  exist** in `/opt/barkpark/.env` (24 keys, none matching) while nothing listens on **:4000** — the working
  probe is `/etc/barkpark/agent.health.token` against `localhost:4001`. Run the briefed form verbatim and you
  get two empty strings, which is "I could not look" wearing a clean bill of health.

- **D145 — ERRATA THIS WAVE OWES ITSELF.** (a) The direction claimed the word `unmetered` "appears in no
  cloud/internal source file I grepped" — **FALSE**: 34 hits in `usage.ex` alone, plus `registry.ex:2219` and
  `api/.../router.ex:1612`, and every value-level absence path already fails closed (`measured_or_nil/1`,
  `telemetry_threshold_meter/7`'s `n >= 0` guard, `@unmetered_pressure`, `unavailable_meter/2`'s typed reason
  vocabulary). The nil-vs-zero honesty is **paid**; the defect is one layer up, in a verdict that reads no
  value. (b) The word `strained` genuinely appears in ZERO executable source — its three real hits are all
  comments naming the fence's denominator. (c) `attentionStatus`'s "ok" is the `default:` fallthrough at
  `cloud_status_cmd.go:70`: nothing rejected the box, nothing looked. **THE LAW THAT FOLLOWS, and it is the
  most load-bearing sentence in this wave:** the new verdict must be **TRI-STATE — ok / strained /
  UNMETERED — never binary.** D42's factual arm ("a nil vital never strains") is correct as a FACTUAL claim
  and catastrophic as a VERDICT: fold nil into "not strained" and a box reporting NOTHING classifies
  identically to a healthy box, which is the exact bug wave 9 exists to kill, reconstituted inside its own fix.

- **D146 — WAVE 9 IS ALL OPUS; TWO SLICES ARE HIGH-FLIP-RISK.** Fable is unavailable fleet-wide. S2 (the
  taxonomy split, high blast radius on a file with an open PR) and S7 (the fence, whose calibration rests on
  a one-sick-box fleet and whose UNMETERED arm is the D145 law) would both be fable on the difficulty axis.
  They are flagged HIGH-FLIP-RISK instead and the lead is owed an **independent second reviewer** on both
  before merge.

### Wave 9 plan — 7 slices, 5 in round 1, file sets disjoint within a round

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | The pressure block carries latency and its denominator | `dr-bl-w7-req-volume-joins-the-pressure-block` | `cloud/**` | small | opus |
| 2 | 1 | Giving up on a publish stops wearing the mildest name | `dr-w9-s2-abandoned-is-not-a-transient-409` | `cloud/**` | medium | opus |
| 3 | 1 | A team's deployments table carries its cause and can page | `dr-w9-s3-deployments-table-carries-its-cause` | `internal/**` | medium | opus |
| 4 | 1 | The doc-type filter reaches the five live webhook rows | `dr-w9-s4-webhook-doctype-filter-reaches-live-rows` | `internal/**` | medium | opus |
| 5 | 1 | The beat dates its own producer | `dr-w9-s5-the-beat-dates-its-own-producer` | `internal/**` | small | opus |
| 6 | 2 (after S2) | The rate names its absorption, on both sides of the wire | `dr-w9-s6-the-rate-names-its-absorption` | `cloud/**` + `internal/**` | medium | opus |
| 7 | 2 (after S1) | The verdict reads a sustained vital, and can say UNMETERED | `dr-w9-s7-verdict-reads-a-sustained-vital` | `cloud/**` + `internal/**` | large | opus |

Rounds are law: S6 needs S2's `@classes`/`@labels`/`refusal_class` edits on main before it touches the same
file, and S7 needs S1's `p95_ms`/`req_per_s` keys on main before it widens `merge_pressure`. Neither
dispatches this run.

HIGH-FLIP-RISK (D146): **S2** — whether an `ABANDONED_*` split composes with #10014 rather than colliding,
and whether the producer-side anchor guard can actually lose. **S7** — whether a fence calibrated on a fleet
with exactly one sick box discriminates at all, and whether its UNMETERED arm is genuinely tri-state.

Coverage: every survey and verify agent reported; there is no coverage deficit this wave.

Charter published as a docs-only PR, not pushed to main (D39, honest-gates).

## Wave 10 — the box can be called sick by a number that cannot be window-shopped

Wave 10 Paper: `deploy-reliability-wave-10-2026-08-07`. Twelve verify assignments, every one reported;
**no coverage deficit in either round.** Every number below was re-derived at 2026-08-07 04:20–05:00Z
against `origin/main`, cloud-db-1 (178.105.92.191) and guerrilla (157.180.90.121). Where a wave-10
verifier contradicted the wave-10 direction, the verifier wins and the contradiction is recorded by name.

- **D147 — THE `unmetered → ok` CITATION IS MISFILED, NOT PHANTOM: THE RULING IS **D42**, IT IS LANDED, AND
  THIS WAVE ROUTES AROUND IT BY SCOPE RATHER THAN REVERSING IT.** *Why:* `cloud_status_cmd.go:239` (inside
  unmerged #9887) cites "charter D69 — deliberately NOT a rung", but landed D69 (charter line 1416) is
  *"AMENDS D53 NARROWLY: THE DISK GETS ITS OWN RUNG `filling`"* and contains no word about absence. The
  ruling it MEANS is **D42** (line 735), landed: *"NO NEW `unmetered` ATTENTION STATE … a nil or `-1` vital
  NEVER produces `strained`."* Briefing a builder "the citation is phantom, just fix the comment" would
  have INVERTED the governance: they would add the rung believing nothing opposed it. But D42, D74 and D88
  are all about the **agent PRESSURE beat**, where "unmetered" means a stale agent binary — a rollout gap.
  Wave 10's vital is the **deploy outcome rate**, computed control-plane-side with no agent in the path;
  `grep -in 'deploy rate|deploy_rate|rung.*deploy'` over the landed charter returns **ZERO**. No landed
  decision covers a deploy-rate rung at all. Therefore: the tri-state arm is scoped to the DEPLOY vital,
  the D88 pressure marker is left exactly as shipped, **#9887 needs no edit whatsoever**, and D42 stands
  untouched on its own subject. (Recorded for the record: D42's stated rationale — "vocabulary for a
  population of zero" — is already contradicted by the later landed D88, which counts the marker
  live-eligible on four of six boxes with two wearing a serene `ok`. That reversal is available if a later
  wave wants the pressure rung; this wave does not need it.)

- **D148 — THE RUNG READS THE **RAW** TERMINAL RATE, WITH `box_caused` AS A MANDATORY COMPANION KEY —
  NEVER A REGEX-DERIVED SUBSET AS THE NUMERATOR.** *Why:* the decisive experiment (leave-one-site-out over
  guerrilla's 24 h window, n=1,275) was run and the intuition lost. Composition-shopping hits the
  box-caused subset HARDER than the raw rate: LOO span raw **1.343x** vs graph-substring **1.730x**, and
  retiring the three `search*` sites takes the graph-substring rate to **1.79%** (a 10.7x collapse) while
  raw only falls 46.43% → 25.58% (1.82x). A rung on the substring is a rung that can be silenced by
  decommissioning three sites. It is also 52.6% recall (structurally blind to all 196
  `feature_not_configured` rows) and 4.1% contaminated by BUILD-stage rows — a technique `classify/2`'s own
  landed comment forbids verbatim: *"never from a substring search over the whole capture (a build log that
  prints \"500\" is not a box 500)"*. Deeper reason: **raw depends only on `deployments.status`, an enum.**
  Every subset depends on a regex over operator-authored prose, so a reworded error message silently
  returns the rung to `ok` — a NEW silent-failure class manufactured inside the fix. The price of raw is
  that it accuses the box for a customer's broken Turbopack build (22.6% of rows are `^BUILD failed`); that
  is paid by emitting `box_caused` beside the rate, derived from `classify/2`'s **closed class enum** by a
  pure class→agency map (never a new regex), failing to AMBIGUOUS and never to SITE.

- **D149 — TRI-STATE, AND A **THIRD** ABSENCE CLASS: "NO DEPLOY SURFACE" IS NOT "COULD NOT MEASURE".**
  *Why:* the fleet is degenerate past the point where "6-of-8 UNMETERED" is the right framing. Measured:
  **8 barkparks, 13 sites over 2 barkpark_ids, SIX barkparks with ZERO sites**; only guerrilla (28,698
  lifetime terminal) and jarl (55 lifetime, last 2026-08-03) have ever owned a deployment, and jarl is
  below `@min_sample 200` **forever, in any window**. Fold all of that into one `unmetered` and 7 of 8 rows
  wear a permanent alarm nobody reads — the always-on objection, arriving by a new route. The ruling:
  a box with **no sites at all** has nothing to deploy, so its verdict stays `ok` and it wears a DETAIL
  MARKER (the D74/D88 marker doctrine, applied to a new vital); a box **with sites** whose sample is below
  `@min_sample` classifies **`unmetered`**, ranked below every real-problem rung and above `ok`. The refusal
  reuses `rate/2`'s existing node verbatim — `%{sample, pct: nil, refused: true, reason}` — so "never asked
  to deploy" and "asked too little to score" stay readable without a second mechanism. `attentionStatus`
  must compute the deploy verdict as an EXPLICIT three-way match, so `ok` is returned by a matched clause
  and never again by `default:`.

- **D150 — RENUMBER THE LADDER; DO NOT APPEND. THE FENCE IS 20.0%. THE SPA HALF IS FENCED OUT OF THIS
  WAVE.** *Why:* "append as rank 12" was proven cheaper only by accepting the wrong semantics. Mutation
  probe on origin/main: appending `deploy_failing` to `attentionRankOrder` yields `rank=9, bucket="attention"`
  — bucket fails safe, **rank fails unsafe**: rank 9 sorts BELOW `ok` (8), so the box the epic exists to
  call sick renders last, under every healthy box. Any semantically-correct placement renumbers by
  definition. Landed ladder on origin/main is EIGHT rungs (the eleven-rung D69 ladder is unmerged #9887),
  so wave 10 builds on the 8-rung basis and states it: **1 removal_failed · 2 failed · 3 suspended ·
  4 degraded · 5 deploys_failing · 6 behind · 7 removing · 8 provisioning · 9 unmetered · 10 ok.** The fence
  is **20.0%** — above the site-caused floor (9.5% on the retired-search-sites fleet) and below the raw rate
  with the three `search*` sites removed (25.58%), so it survives the composition crack in both directions.
  THE SPA IS FENCED: cloud-console-hardening wave 41 owns `cloud/priv/static/app.js`, so this wave does NOT
  touch it, and the console's ninth-rung drift (`unreported: 5 … ok: 9`, citing D332(b)) is handed over as a
  filed backlog row rather than fixed under a foreign epic's fence.

- **D151 — THE ATTACK FAILED AND ITS PREMISE WAS INVERTED; THE RUNG STAYS A **BOX** RUNG.** *Why:* the
  partition of the 597-row numerator is **BOX 447 (74.9%) / SITE 138 (23.1%) / AMBIGUOUS 11 / CAUSELESS 1 —
  3.24:1**, independently re-derived at 3.34:1. The two classes offered AS PROOF of site-causation are box
  symptoms: **236 of 237** bp-doc-id rows carry a box-side status in the same string (`graph 500`=124,
  `graph 0`=58, `graph 503`=54), and D113 is now proven **by running**, not by reading — all 86 deploy-route
  503s in 12 h took **≥5,000 ms** (zero fast ones; an env hole answers in ~10 ms), the flag
  `BARKPARK_SITE_DEPLOY_APPLY=1` IS set, and the build started anyway for **84 of 86** refusals against a
  MEASURED 13.1% coincidence floor. Structural finding nobody had: `bounded_cmd/3` bounds `systemd-run` at
  **15,000 ms INSIDE** a `GenServer.call` whose implicit budget is **5,000 ms** — the callee's budget is 3x
  the caller's, so the 503 is reachable deterministically and no test on origin/main pins the caller's
  budget. Consequence: **`dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures` carries a disproven
  premise and must not be built as written.**

- **D152 — THE WINDOW SWING IS **8.6x**, NOT 7x, AND IT IS ABSORPTION, NOT RECOVERY.** *Why:* re-taken on a
  quiet host at 04:27Z: 24 h = **46.28% of n=1,290** (46.67% absorbed); 6 h = **5.38% of n=279** (75.29%
  absorbed). The per-hour table shows why it is not noise — from 22:00Z failures collapse to 0–7/hr while
  deferrals go from 0–2/hr to **137–171/hr**. The box did not recover; the cap started ABSORBING. A rate
  published without its absorption here does not merely lose precision, **it inverts the verdict**. The
  deploy vital therefore ships as an inseparable node carrying `pct`, `sample`, `refused`, `absorption` and
  `box_caused` — a bare percentage is structurally unconstructible, exactly as `rate/2` already guarantees.

- **D153 — THE WEBHOOK FAN-OUT CUT IS REAL AND LARGER THAN CHARTED, AND IT DID **NOT** STOP THE TIMEOUTS.
  DO NOT SELL IT AS A FIX.** *Why:* amplification per document write fell **31.7x → 1.84x** (1,132/hr →
  45/hr) over like-for-like 47-minute windows — a 25x cut, bigger than the charted 14x — and the filter
  landed 03:43:23–03:46:27Z, i.e. **23 minutes BEFORE #10082 merged**, so #10082 did not apply it and,
  because `runWebhookReconcile` writes only on difference, "ran, no-op" and "never ran" are
  indistinguishable in the database. The causal claim is refuted three ways: the post-cut quiet (~61 min) is
  SHORTER than three earlier gaps in the same 12 h (127.6 / 69.2 / 58.0 min); hour 21:00Z served 4,300
  requests with ZERO timeouts **six hours before the filter existed**; and r(webhook deliveries, timeouts)
  = **−0.139**. The real correlate, found while testing this: **r(/v1/graph calls, timeouts) = +0.900**
  (13 h) / +0.912 (same 11 h), with mediation refuted (r(webhooks, graph) = 0.061). That matches landed
  prior art (`dr-bl-w9-graph-corpus-materialization-is-the-oom`, +0.6 GB BEAM RSS per `/v1/graph` call).
  The survey-gated question is hereby ANSWERED OUT LOUD: the fan-out lever was worth pulling, it is already
  pulled, and it is not the mechanism.

- **D154 — #9887 IS **ZOMBIED**, NOT RE-RUN-DELETED, AND D102's MECHANISM IS THE WRONG DIAGNOSIS FOR IT.**
  *Why:* the required set on main is exactly four (`Elixir gate`, `PR references an active task`,
  `Cloud gate`, `Console gate`); #9887's head `aa19dcca3` carries 27 check-runs, all success or skipped, and
  no `Console gate` at all. Its `console-harness` run **31120806862** is `status=queued`, `run_attempt=1`,
  **ZERO jobs**, created 2026-08-06T16:43:08Z — it never dispatched. A re-run bumps the attempt counter;
  this one is at 1. (A re-run DID happen on that head, on the `cloud` workflow, attempt 2, success.) Two
  more workflows on the same sha and three on another are equally stuck, and one `pr-task-gate` run has been
  queued since **2026-07-23 at run_attempt=9 — fifteen days.** This is runner/queue starvation across shas,
  not per-workflow deletion. Remedy is unchanged (a fresh head sha; never another re-run), but the
  instrument must carry BOTH classes and the discriminator is one API call: `run_attempt` and jobs-length.
  #9887 legitimately owes the gate — it touches `cloud/priv/static/__fixtures__/attention_order.json`.

- **D155 — MOVEMENT 3 SHIPS **DISJOINT**; honest-gates **D76** IS NOT REVERSED, AND D120 IS VOID.** *Why:*
  a zombied run renders NO check-run at all (`jobs.total_count = 0`; zero non-completed check-runs on
  #9887's head), so it is the **ABSENT** class, not D76's PENDING class — D76's subject never arises and a
  builder told to "fix pending" would collide head-on with the still-open honest-gates backlog row
  `hgw5-bl-deadlock-pending-informational`. The detector already exists and already says the right words:
  origin/main's `required-checks-verify.sh --deadlock --sha aa19dcca3` exits **3** printing
  `missing: Console gate`. It is silent only because `required-checks-drift.yml` deliberately passes no
  `--sha` and samples a settled MERGED head. What genuinely does not exist anywhere on origin/main is a
  live queued-run query (`select(.status=="queued")` → rc=1). So the buildable residue is: enumerate queued
  runs with the paginated form, date the absent class, discriminate zombied from rerun-deleted, and ship it
  as a NEW script plus a NEW schedule-only workflow — the honest-gates **D61** shape, whose live instance is
  `breakglass-watch.yml`. Proven inert: planting a schedule-only workflow into origin/main's real 43-workflow
  tree and re-running `required-checks-generate.sh` produces a spec **byte-identical to baseline**, and the
  floor says `FLOOR OK … 4 context(s), identical on context AND app_id` — and that green is able to fail
  (a catch-all job name is refused by name, exit 1). **Zero honest-gates files are touched.** Separately:
  the unmerged D120 ("DR OWNS `console-harness.yml` … by this charter's own D101") is VOID — landed D101's
  FENCE clause authorizes exactly `cssom-parity.mjs` and says nothing about `console-harness.yml`.
  Also void as a diagnostic: the queue-diagnostic acceptance criterion must be a **strict inequality**
  (paginated > unpaginated), never a pinned pair — four independent samples gave 0-vs-6, 0-vs-6, 1-vs-7 and
  0-vs-7 within one night.

- **D156 — LOAD IS DEAD AS AN AXIS, MEASURED TWICE MORE.** *Why:* guerrilla's load15 read **1.20/core** at
  04:11Z and **0.92/core** at 04:29Z against the chartered **1.75** fence, on a box carrying 218
  DBConnection timeouts in the preceding 6 h and failing 46% of its terminal deploys. Wave 9's chartered S7
  fence would have called this box healthy tonight. The declined item stands as REFUTED, not merely
  argued: load is the wrong axis, not a mis-tuned one. `p95_ms` stays a vital and does NOT get a rung
  (D131/D132 stand).

- **D157 — THE EPIC'S OWN LEDGER IS THE LARGEST UNREPORTED FAILURE ON THIS BOARD, AND THE REPAIR HAS BEEN
  FILED TWICE AND NEVER RUN.** *Why:* the epic carries **166 children — 152 open / 12 done / 2 cancelled,
  in_progress ZERO** (not 164/145/5). Thirty open rows are named in a PR merged since 2026-08-04 with
  met>0, carrying **45 unstamped criteria, 20 of them exactly one criterion short**; **41 of the 45 are
  lead-owned merge paperwork** and all 32 named PRs are MERGED with their merge commits ancestors of
  origin/main (32/32 verified). **16 rows close outright; 10 get one criterion stamped and stay open; 4 are
  genuinely blocked.** Do NOT bulk-stamp: `dr-w2-s6` owes "the PR body states that dr-w2-s2 and this slice
  are two halves of one repair" and #9733's 4,028-char body contains **zero** occurrences of "s2". Two
  structural traps: (a) criteria live at `doc.content.acceptance_criteria` — `doc['acceptance_criteria']` is
  `null`, so a naive extractor reads all 166 tasks as fully met; (b) ten criteria demand "all four required
  contexts green **on the merge commit**", which is **unsatisfiable by construction** because
  `pr-task-gate.yml` is `on: pull_request` only and is absent from all 19 merge commits queried (six of
  which carry no check-runs at all). Both prior repair rows — `dr-bl-w8-stamp-sixteen-merged-and-unstamped-tasks`
  and `dr-bl-w5-merge-gated-paperwork-is-unsatisfiable` — are OPEN at **0/5** and **0/4**. Also newly
  named: **15 children carry ZERO acceptance criteria**, so every percent-complete instrument scores them
  vacuously complete.

- **D158 — ERRATA WAVE 10 OWES ITSELF (each one would have mis-briefed a builder).** (a) "189 timeouts on
  the ACTIVE green slot" is WRONG twice over: BLUE is active, and the split is **blue 129 / green 89 = 218
  union** — the hourly series 100/5/11/112/2/88 reproduces exactly as the UNION, and the worst hour (112)
  is on blue. The slot flipped mid-window (green served until 04:13:46, blue started 04:13:20), so any
  journal claim must carry its timestamp AND its slot, and only unit-agnostic reads are valid. (b) `Sent
  500` is **113**, not 161. (c) "72.2% of the numerator has fixes already built and stuck" re-derives to
  **69.0% (412 of 597)**, and the doc-id class splits across **TWO literal prefixes (216 + 21 = 237)** — a
  census keying on the raw string reports one cause as two. (d) The repo slug is **FRIKKern/barkpark**;
  `repos/barkpark/barkpark` 404s. (e) The mandated `gh pr diff <n> -- <paths>` cannot run (gh's `pr diff`
  takes no pathspec). (f) The primary checkout is **534 commits behind origin/main** and its
  `console-harness.yml` is 136 lines against origin/main's 926 — one survey's "Console gate is templated /
  not found" was purely that staleness; every CI fact must be re-derived with `git show origin/main:`.
  (g) The wave-9 `pressure` block's `p95_ms`/`req_per_s` DID land (#10079), but `git grep -c Pressure
  origin/main -- internal/cloudclient` still returns **nothing**: the Go client has no field for any of the
  14 pressure keys, so the vitals never reach the verdict. Confirmed independently by four verifiers.
  (h) An **INVERSE** class exists that no wave had named: three Go fields (`DeployCensus.Live`,
  `DeployCensus.TerminalFailureRate`, `DeployRate.Basis`) decode keys the control plane has **never**
  emitted, alongside 48 landed-and-unread payload keys across four serializers.

- **D159 — DECLINED OUT LOUD.** (a) A `p95_ms` rung — D131/D132 stand, and D156 adds a second refutation of
  the whole latency-fence family. (b) Lowering the 1.75 load fence — 0.92/core on a visibly sick box.
  (c) Chasing this hour's biggest failure class — they rotate. (d) `PLATFORM_ADMIN_EMAILS` — untouched, the
  lead owns it; note that the deploy vital rides `GET /v1/barkparks`, which is role-scoped and NOT
  platform-gated, so it reaches an owner's eye without the crown. (e) Automatic REGIME SEGMENTATION of the
  rate — the only available boundary marker (`agent_events.payload->>'git_commit'`, 14-day retention,
  ±1 beat) provably UNDER-counts regimes (four slot flips in 4.2 h need not change HEAD), and a rate that
  silently splits itself on an under-counting boundary is a new window-shopping surface with a machine doing
  the shopping. A pinned window with its absorption is the honest answer; a regime annotation is filed as
  backlog, advisory only. (f) A standalone `(inserted_at)` index on `deployments` — measured, not reasoned:
  planner cost falls 5.1x but real execution only **5.220 ms → 4.484 ms (14%)** while shared buffers TRIPLE
  (631 → 2,274). Filed as a watch item with a ~10x-row-count trigger. (g) Re-cutting #10014/#10015/#9887 —
  all three are built and correct against tonight's rows; #10014's conflict is ONE file and three
  additive-vs-additive hunks caused by #10080 merging out of the order its own task text specified.

- **D160 — WAVE 10 IS ALL OPUS; TWO SLICES ARE HIGH-FLIP-RISK.** Fable remains unavailable fleet-wide.
  **S1** (the rung: a new attention state, a renumbered cross-surface ladder, and a tri-state whose
  UNMETERED arm is the D149 law) and **S3** (an instrument whose whole value is discriminating ABSENT from
  RED from PENDING beside another epic's live ruling) would both be fable on the difficulty axis. They are
  flagged HIGH-FLIP-RISK instead and the lead is owed an **independent second reviewer** on both before
  merge.

### Wave 10 plan — 4 slices, 2 in round 1, file sets disjoint within a round

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | The verdict reads the deploy rate, and can say `deploys_failing` or `unmetered` | `dr-w10-s1-verdict-reads-the-deploy-rate` | `cloud/**` + `internal/**` | large | opus |
| 2 | 1 | An absent required context becomes a dateable class with a queue query that can lose | `dr-w10-s3-absent-required-context-is-dateable` | `scripts/**` + `.github/workflows/**` | medium | opus |
| 3 | 2 (after S1) | The rate names its absorption, on both sides of the wire | `dr-w9-s6-the-rate-names-its-absorption` | `cloud/**` + `internal/**` | medium | opus |
| 4 | 2 (after S1, S3-independent) | The payload contract gets a key-set guard in both directions | `dr-w10-s4-payload-key-set-guard` | `cloud/**` + `internal/**` | medium | opus |

Rounds are law. S2 (`dr-w9-s6`) and S4 both edit `deploy_ledger.ex` and `client.go`, which S1 also edits;
they are sequenced behind S1's merge rather than dispatched beside it — the epic already paid for the
alternative once, when #10080 merged ahead of #10014 and left it CONFLICTING. S1 is scoped to ADD a new
public `box_rates/3` at the end of `deploy_ledger.ex` and must NOT touch `census/3`, `rate/2`, `@classes`,
`@labels` or `classify/2`; S2 owns exactly those regions afterwards.

HIGH-FLIP-RISK (D160): **S1** — whether a raw box rate is defensible as a BOX verdict given 23.1% site-caused
mass, and whether the three-way absence split (no-sites → `ok`+marker, below-sample → `unmetered`, measured →
rung) is genuinely tri-state rather than a fallthrough by a new route. **S3** — whether the ABSENT/PENDING
discrimination is correct beside honest-gates D76, and whether the new workflow is truly inert against the
required-check spec.

Coverage: every survey and verify agent reported; there is no coverage deficit this wave.

Charter published as a docs-only PR, not pushed to main (D39, honest-gates).

## Wave 11 — the vital is a CLOCK, and the clock has never been started

- **D161 — TIME TO WEB IS THE VITAL. `content_rev` CANNOT KEY IT. D142 IS AMENDED FOR LATENCY AND RETAINED
  VERBATIM FOR THE RATE.** Ten waves measured what fraction of ATTEMPT ROWS settle `failed`. That is a
  measure of box waste; the customer's question is a clock. Two independent verifiers ran BOTH keyings on ONE
  pinned 24 h window (`[2026-08-06 06:00Z, 2026-08-07 06:00Z)`, cloud-db-1): D142's run-keyed journey reads
  **p50 0.0 s / p95 399.1 s / max 1,594.0 s**; the revision-keyed census reads **p50 264.7 s / p95 10,422.9 s
  / max 22,637.6 s**. The 26x is not window noise and the mechanism is named, not argued: under D142 a
  `failed` row is TERMINAL and therefore CLOSES a run, so a string of consecutive failures becomes a string
  of SINGLETON runs of identically 0.0 s — **393 of 647 live journeys (60.7 %) are singletons, which is why
  the run-keyed p50 is exactly 0.0 s.** The decisive case: site `d8e9c2c7`, 06:00–12:20 on 08-06, is ONE
  22,638 s (6 h 17 m) revision wait and EIGHTY-TWO D142 runs — 80 singleton `failed` runs at 0.0 s.
  **D142's metric reports 0.0 s for a 6 h 17 m outage**, and its ceiling across the entire 24 h window
  (1,594 s) sits **14.2x below** the single worst wait it is supposed to describe. Run-keying is structurally
  incapable of printing the number this epic exists to expose. D142's refusal is nonetheless scoped to a
  RATE — its own backlog row says "an abandonment rate built on `content_rev` has three measured defects",
  and defect (a) is `term_rev <> head_rev` direction-readability, which a latency never performs. **RULED:
  "segment by RUN, never by rev group" continues to govern the abandoned rate and attempt-cluster reporting
  unchanged; it does NOT govern a latency.** But the census does not therefore get to key on `content_rev`
  either — see D162.

- **D162 — `content_rev` IS NOT A REVISION, AND 100 % OF THE INFLATION REVISION-KEYING PRODUCES IS ITS OWN
  COLLAPSE ARTEFACT. THE CROWN IS THAT THE CONTROL PLANE NEVER RECORDS THE PUBLISH INSTANT.** `content_rev`
  is `binary_part(sha256(json([doc_type, published_count, published_events])), 0, 12)` probed FROM THE BOX at
  enqueue time (`sites/deploy.ex:484`). `published_events/2` filters a **dataset-wide last-50 activity
  window** down to one `doc_type` — AFTER truncation — so other types' churn EVICTS the bound type out of
  the window and moves the hash with zero publishes of that type. The file's own docstring (`deploy.ex:481-483`,
  "a draft edit or another type's churn cannot move it") is FALSE for the events half. Measured, all four ways:
  (a) all 13 sites share `(default, default, production)`, and the live last-50 window is **48 `task` events
  and 2 `paper`** — eleven production websites derive their entire revision from ONE event, and one of the
  two papers is a draft the projection also drops; (b) `task` churn is 148.8 ev/hr against `paper` 9.1 (16:1),
  so the 50-slot window holds **≈19 minutes** of history; (c) DEMONSTRATED — around a real publish at
  03:32:59Z the projection went 1 event → **EMPTY** across 20 minutes with **zero paper publishes in between**;
  (d) **189 distinct `content_rev` in 24 h against 142 published non-draft paper events**, so ≥46 revs (24 %)
  are eviction artefacts no publish accounts for. The key is also not injective: **1,474 of 3,106 (47.5 %)
  `(site, content_rev)` groups repeat**, rev `216e1851b7fb` covering ~345 rows across 2 h 07 m on five sites
  simultaneously, max group span **29.2 h**. And the split that settles it — singleton rev groups read
  **p50 108 s / p95 233 s**, statistically indistinguishable from the per-attempt distribution
  (p50 104 s / p95 225 s), while collapsed groups read p50 152 s / p95 693 s. A second verifier reached the
  same place from the other side: **delivered-as-self p50 is 127 s (n=977) against 8,200 s once supersessions
  are credited (n=3,121)**. The 76x gap the direction named is manufactured by the credit rule and the
  collapse, not by content waiting.
  **The real wait was measured, once, by the only method that can see it — a cross-host join of guerrilla's
  `mutation_events` to cloud-db-1's `deployments`, 144 paper publishes × the 5 webhook-bound sites = 720
  pairs, ZERO censored: publish→web W24 p50 352 s / p95 11,752 s, W7 p50 32,184 s (8 h 56 m) / p95 493,029 s.**
  Against the row-keyed clock (`inserted_at → became_live_at`, W24 p50 74 s / W7 p50 108 s) that is an
  under-statement of **4.8x at 24 h and 298x at 7 d**, and the strict rule (first build STARTED after the
  publish) reproduces the same order — so it is not a successor-rule artefact. **RULED: every latency this
  epic has ever published starts when the CONTROL PLANE ENQUEUED an attempt, not when a human pressed
  publish, and the gap is floored by construction** — `AutoDeployWorker.@schedule_in_default` is 60 s (D44),
  and the measured enqueue lag is p50 61 s / p95 692 s / max 1,550 s. The receiver at
  `web/router.ex:7139-7173` verifies the HMAC, answers 202, and its ONLY act is
  `Sites.AutoDeployWorker.enqueue(site.id)` — **no row, no timestamp, nothing.** Worse, `Deploy.enqueue/6`'s
  `recover_conflict/3` returns `{:duplicate, existing}` and mints NO ROW at all, so **26–35 % of paper
  publishes leave no attempt record anywhere** and are invisible in both numerator and denominator of every
  instrument this epic has built. **THE WAVE-11 CROWN IS THEREFORE NOT A CENSUS — IT IS STARTING THE CLOCK.**
  Until the control plane records the publish instant, a truthful time-to-web is not a query anyone can
  write, and any number that claims to be one is an under-estimate of unknown size.

- **D163 — "ZERO STRANDED" IS VACUOUS, AND CENSORING IS AN IDENTIFIABILITY PROBLEM, NOT A WIDTH ONE.**
  Under the generous successor rule the direction used, `stranded` is **0 at every window width from 1 h to
  168 h** (3,118 revisions at the widest) — that is a property of the RULE, not of the fleet: any site that
  ever deploys again retroactively delivers every earlier revision. Printing it as a fleet-health claim is a
  guard that cannot lose. It is also a function of WHEN YOU LOOK: the same pinned window returned **3 → 2 → 0
  in five minutes**, both survivors 1 m 51 s old. Any published stranded count needs an as-of timestamp and a
  `STILL WAITING ≥ X` representation, never a bare 0. The estimator hazard is sharper and was mis-framed as
  window width: the FLOORED estimator swings **829x** with width (p50 133 s @1 h → 110,251 s @168 h) while the
  DROPPED estimator sits FLAT at 94–150 s at every width — structurally incapable of ever showing delay. But
  narrowing the window is not the fix: **p95 already diverges 11.0x at the NARROWEST width.** The predicate
  that actually discriminates is **`censored_fraction > 1 − q`**, which agreed **14/14** with the empirical
  test of whether the row AT the quantile position is itself censored. `@min_sample 200` does not catch it —
  the 6 h window passes at n=217 with **36.9 % censored**. **RULED: the estimator refuses on identifiability,
  floors rather than drops, prints its window WIDTH beside the number, and reports NULL-key rows as an
  explicit `unmetered` cohort rather than dropping them** (66 such rows in 24 h; and `jarl-website` has 55
  rows, 23 live deliveries and **zero** non-NULL `content_rev`, so a rev-keyed census silently omits an
  entire customer site — the instrument creating a new silent failure). Errata against the wave's own
  verify brief: a ~40 %-censored fixture where p50 drop-vs-floor differ >10x is **UNCONSTRUCTIBLE** (the
  divergence is a step function at exactly 50 %); the same fixture gives **3335.6x on p95**, so the fixture
  targets p95. The tell to assert is the dropper's own denominator: **`sample` shrank 1000 → 600.**

- **D164 — THE REPORTING IS NOT MISSING. IT IS POINTED AT THE WRONG QUANTITY, AT ALARM-FATIGUE VOLUME.**
  The epic's founding sentence — "nothing reports it" — is REFUTED at L1. `notification_deliveries` holds
  **2,291 `deployment_failed` emails SENT** (4 failed), most recent 2026-08-07 05:43Z, rising: **870 on
  Aug 6, 625 Aug 5, 446 Aug 4.** It is default-ON for all 22 teams, wired at three producers, and
  edge-guarded to fire only on the transition INTO failed. So Barkpark already exceeds Kinsta's one opt-in
  email. What it has never sent is a single notification about a revision sitting unpublished. Given that the
  same night's ledger shows nothing stranded and revisions superseded, **the fleet has been emailing ~870
  times a day about attempts that destroyed no content, and zero times about the wait that actually hurts.**
  The external bar agrees on shape and not on ours: Vercel's per-deployment vital is a phase timeline
  (`createdAt` → `buildingAt` → `ready`) plus a SEPARATE `readySubstate` ∈ STAGED/ROLLING/PROMOTED meaning
  "READY but never seen production traffic" — `became_live_at` modelled as a distinct STATE, not a
  subtraction — and NEITHER Vercel nor Kinsta publishes anything shaped like `deploys_failing`. **RULED: the
  wave adds a WAITING alert and does not add a failure alert; the failure alert's volume is itself filed as a
  defect.**

- **D165 — `bp cloud deployments` HAS NEVER PRINTED A NUMBER, FOR ANY ACCOUNT.** Built from origin/main and
  run live, it exits **3** with a 403 (`scope=platform, required=platform_operator`) before reaching the
  payload, because `PLATFORM_ADMIN_EMAILS` is **EMPTY on the serving container** `cloud-control_plane_green-1`.
  Wave 10's crown reads a census no human can fetch. Its refusal copy is excellent and says so out loud
  ("this is NOT a fleet with zero failures"), which is the only reason this is a finding and not an
  incident. Separately confirmed: the host-installed `bp` is commit `f59aaf717` (2026-07-31) and does not
  have the verb at all — any wave proof run with the host binary is measuring a July build. **D158h is
  CONFIRMED and permanent**: `cloud/` emits `terminal_failure_rate` **zero times** while
  `cloud_deploy_census_cmd.go:398` branches on `TerminalFailureRate == nil`, so the headline is welded to its
  "older control plane" arm and no test can tell that from a real older CP. The emitter for all three phantom
  keys **already exists, complete and green, stranded in open PR #10014**, blocked by ONE undeclared path in
  `scripts/cloud-path-escape-check.sh` (`deploy/site-deploy-node.sh`, read by that PR's own test) — a correct
  guard, working correctly, holding a correct fix hostage for a day because nobody read its scan. The
  one-line fix takes the ratchet 120 passed/2 failed → **123/0**. The lead owns #10014; the wave does not
  re-cut it. **D158g is FALSE as written**: `cloudclient.Pressure` exists and is read at seven sites; the
  unread residue is **TWO** keys (`req_per_s`, `p95_ms`), not fourteen.

- **D166 — `tmp_dep_site_live` IS PRODUCTION SCHEMA IN NO MIGRATION, AND IT IS WORTH 236x–498x.**
  `CREATE INDEX tmp_dep_site_live ON deployments (site_id, became_live_at) WHERE became_live_at IS NOT NULL`
  is live on cloud-db-1 (53 pages / 424 kB, `pg_class.oid` 35410 — the HIGHEST of any object on the table, so
  created last, by hand). `git grep tmp_dep_site_live origin/main` returns nothing, and neither does a grep
  over all 327 worktrees. Measured by actual `DROP INDEX` inside a rolled-back transaction (the assignment's
  suggested `enable_indexscan=off` is INVALID — Postgres falls back to a Bitmap Index Scan on the SAME index
  and under-states the cost 14.5x): 7 d census **48.4 ms with / 24,089 ms without** (498x, 815x buffers);
  24 h **35.4 ms / 8,349 ms** (236x); site-scoped **21.7 ms / 4,615 ms** (213x). Wave 10's own
  `dr-w10-bl-inserted-at-index-watch-item` DECLINED a standalone `(inserted_at)` index at 14 % execution gain
  against 3x buffers — same method, opposite verdict, which is what makes this a decision. That row also
  declared the cleanup discipline ("presence or removal verified by reading `pg_indexes` afterwards …
  deployments is back to exactly 9 indexes, zero `tmp_*`") at 05:12Z, and `deployments` now carries TEN:
  **wave 11's own survey created it hours after the epic wrote down the discipline it violated.** RULED:
  land it as a declared migration (`deployments_site_became_live_index`), build cost 40.8 ms / 424 kB, no
  CONCURRENTLY needed at 30 k rows.

- **D167 — #10129 IS CONFLICTING, ITS FENCE IS CLEAR, AND ITS REBASE IS SEMANTIC, NOT MECHANICAL.**
  The direction's "open, MERGEABLE" is stale: `mergeable CONFLICTING / mergeStateStatus DIRTY` at head
  `514ff5c6f`, with all four required contexts GREEN — the block is purely the merge state. The brief's
  "seven conflicting files, one of them router.ex" is wrong twice: `git merge-tree` says **SIX**, and
  **`router.ex` AUTO-MERGES**. Its three router hunks (1891, 8755, 8828 — the fleet-list prefetch and the
  private `barkpark_json/5` serializer) are ~130 lines from the auth band and ~430 from wave 42's ONLY
  router.ex claim (line 1460, D473/D477). **No fence breach; the rebase is authorised on that axis.** The
  real brake is that **#9887 merged at 06:13:52Z carrying the ELEVEN-rung ladder**, so origin/main now reads
  `… degraded 4 · strained 5 · filling 6 · unreported 7 · behind 8 …` while #10129 asserts a TEN-rung ladder
  placing `deploys_failing` at 5 and `unmetered` at 9. A textual rebase mints a thirteen-rung ladder and
  re-places both against three rungs that did not exist when wave 10 decided — **that is a charter decision,
  not a merge resolution a builder may improvise**, and the two `attention_order` fixtures pin it, so
  resolving the `.go` files without regenerating both produces a green tree whose fixture asserts a ladder
  the code no longer implements. #10129 and #10086 do NOT genuinely collide (10129 inserts at
  `client.go:154`, exactly #9887's anchor; #10086's seven hunks are all elsewhere) — order is free, take
  #10086 first. The one genuine collision is **#6028** (stale 2026-07-31), on `router.ex` AND `app.js` —
  wave 42's fence, and clearing it to unblock #10129 would breach that fence by the back door.
  **RULED: the wave does not rebase #10129. The rung question is deferred to the lead with the ladder
  arithmetic written down here, and the wave adds a clock rather than re-litigating a rung.**

- **D168 — SEVENTEEN ZERO-CRITERIA CHILDREN, NOT FIFTEEN; TWO ARE DEAD AND THREE WOULD BE FALSE-CLOSED.**
  The epic now has **182 children (166 open / 12 done / 3 cancelled / 1 in_progress)** — D157's own census
  (166 children, "in_progress ZERO") is stale by 16 rows. Seventeen carry zero acceptance criteria, and
  **two of the seventeen were filed by wave 10 itself, hours after the row that counted fifteen**, which is
  the same recursion the console epic recorded ("TEN today, and seven were filed by the wave sent to fix
  it"). Triage, verified against origin/main: **2 are not live work** (`dr-w5-followup-gyl-dooodo-host-keys`
  cancelled, `task-ca88b8ea571b3470` done); **4 are PAID or half-paid** (the agent `/v1/agent/space` route
  and its `@types` entry both landed; `runBounded` now bounds every shell-out and its comment names the
  three-hour runaway; `@build_slot_capacity 1` + `box_at_capacity?/2` landed in #9827; the jarl disk RANKING
  is fixed at `fillingDiskPercent = 90.0` while `SpaceReport`'s roots still name no build-plane path);
  **8 are genuinely UNPAID with file:line proof** — the three fire-and-forget `Deploy.start/1` sites survive
  at `template_freshness_worker.ex:290`, `router.ex:11240`, `router.ex:12782`; `semrole.go:82` `For/1` still
  has no `unavailable` case; three preview servers still spawn `stdio: "ignore"`, one of them carrying the
  comment *"`stdio: "ignore"` is a refusal nobody can audit"*; `POST /v1/tokens` is still the ONLY token
  route and `internal/cli/token_cmd.go` does not exist, so the three live probe tokens remain unrevokable;
  `DigestEmail.summary/1` still counts only `current`/`behind`/`paused` and a nil `update_state` is counted
  by neither arm. **The repair row's own claim that five are "shipped work no criterion can record" is too
  generous for at least three of them — they are UNSHIPPED work whose zero criteria hide that it is
  unshipped, and closing them as paperwork would be false-done fabrication.** One row
  (`task-a4b939801795cf94`) must be RE-SPECIFIED before any criterion: the `CONTENT_API_*` family it names
  never landed in code (`git grep CONTENT_API origin/main` hits ONE line — this charter, 2424). The trap is
  live-consumed, not latent: `cmux_hook.go:270-293` returns `(0,false)` for an absent list, so **all 15 live
  zero-criteria rows are structurally unclosable by the turn-boundary hook.** The refusal seam exists —
  `AuthoringWall` is already `@walled_types ~w(paper task)` with an Exemptions ledger and a second producer
  already routed through it — but its grandfathering is UNVERIFIED (the ledger's moduledoc says it "only ever
  holds deploy-snapshot rows"), so the guard is filed and the backfill ships.

- **D169 — ERRATA WAVE 11 OWES ITSELF.** (a) The lead's provenance hazard — "origin/main's charter stops at
  D105, D106–D146 exist only on #9976/#10069" — is STALE: `b4ef025cf` carries **D105 through D160**, landed
  by #10101, so those two PRs are redundant and should be CLOSED, not rebased. (b) D142's sub-claim of
  "78 rows in 24 h carry a NULL rev" does not reproduce: **66**, split failed 49 / **deferred 14** / live 3 —
  and D142 has no `deferred` bucket at all, because that status postdates it. The daily series runs 1–122 and
  never equals 78; 78 was a true point reading quoted as a fleet constant. (c) The direction's "the fleet
  materially improved at 2026-08-06 20:00Z" is REFUTED: a journal sweep of 16:30Z–00:30Z returns **eleven**
  unit transitions and the FIRST is **22:24:16Z**, and no commit landed on origin/main between 16:52:47Z and
  00:14:48Z — a **7 h 22 m merge gap that swallows the entire window.** D137's boundary stands; the
  19:00–22:00Z quiet is the 2 h 21 m TRIGGER BLACKOUT it already names, i.e. a denominator collapse.
  (d) The direction's own census window (06:08–06:35Z) **straddles a slot cut at 06:19:03Z, a Caddy upstream
  rewrite at 06:19:38Z and an agent binary roll at 06:20:25Z** — the third mid-measurement flip inside this
  epic. (e) `site_artifacts` being empty is CORRECT and by design, not a failure: `SiteArtifact`'s moduledoc
  says bytes are "dropped the moment the deployment settles", `drop_artifact/1` is called at two settle
  sites, and all **6 prebuilt deploys ever** (against 30,453 box-builds) still carry `artifact_sha256` — the
  durable receipt survives while the bytes are reaped. That thread is CLOSED. (f) The webhook `types` filter
  leaked: five endpoints declaring `types={paper}` received **6,545 `task` deliveries against 705 `paper`**
  over 24 h, ending abruptly at 03:46:11Z with no commit and no deploy to explain it — **cause NOT
  established**, filed as an open question, and every attempt-rate figure over any window ending before
  03:46Z today has a denominator ~10x inflated by triggers that were never supposed to fire. (g) Only **5 of
  13 sites** have a content-publish webhook at all; the other paper sites never auto-deploy on publish and
  nothing says so.

- **D170 — DECLINED OUT LOUD, do not silently revive.** (a) A revision-keyed census (D162 — the key is not a
  revision, is not injective, and manufactures its own inflation). (b) Re-keying wave 10's `box_rates/3` or
  deleting the attempt rate — this wave ADDS, never substitutes, and `#10129`'s `box_rates/3` is preserved
  verbatim. (c) Rebasing #10129 or re-cutting #10014/#10015 — the merge blockage and the ladder arithmetic
  are the lead's (D167, D165). (d) An `AuthoringWall` min-1-criteria publish gate — the seam is right but the
  grandfathering is unverified and a naive gate 422s every republish of the legacy corpus (D168). (e)
  Kaplan-Meier quantile estimation under censoring — a real alternative to refusing, deliberately not
  evaluated; if the lead wants a NUMBER at p95 rather than a refusal, this is the unexplored road. (f)
  `PLATFORM_ADMIN_EMAILS` — still the lead's, still unset, and D165 now measures exactly what it costs.
  (g) Automatic regime segmentation — D159(e) stands, and tonight's 06:19:03Z flip is its fifth confirmation.

- **D171 — WAVE 11 IS ALL OPUS; TWO SLICES ARE HIGH-FLIP-RISK.** Fable remains unavailable fleet-wide, so
  every slice is opus@medium regardless of difficulty. **S1** (a new table on a hot HMAC receiver, plus a
  migration, plus the population that today mints no row at all) and **S3** (a guard whose two measured
  failure modes are both silent: a naive AST match silently drops every GUARDED `def … when` clause, costing
  17 keys with no error, and `merge_job_status/4` builds keys from VARIABLES that no literal extractor can
  see) are flagged HIGH-FLIP-RISK, and the lead is owed an **independent second reviewer** on both before
  merge.

### Wave 11 plan — 7 slices, 6 in round 1, file sets disjoint within a round

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | The control plane records the publish instant — the true t0 | `dr-w11-s1-record-the-publish-instant` | `cloud/**` | large | opus |
| 2 | 1 | `bp cloud site status` learns to tell time | `dr-w11-s2-site-status-tells-time` | `internal/cli/**` | medium | opus |
| 3 | 1 | The payload contract gets a bidirectional key-set guard that can lose | `dr-w11-s3-payload-key-set-guard` | `scripts/**` + `cloud/test/**` | medium | opus |
| 4 | 1 | The delivery census refuses an unidentifiable percentile and names who is still waiting | `dr-w11-s4-delivery-census-refuses` | `cloud/lib/**` | large | opus |
| 5 | 2 (after S4) | The alert points at the WAIT, not at the attempt | `dr-w11-s5-waiting-alert` | `cloud/lib/**` | medium | opus |
| 6 | 1 | The census index becomes declared schema | `dr-w11-s6-declare-the-live-index` | `cloud/priv/repo/migrations/**` | small | opus |
| 7 | 1 | Seventeen children get criteria, and three are not false-closed | `dr-w11-s7-zero-criteria-backfill` | ledger only | medium | opus |

Rounds are law. S5 reads the still-waiting cohort S4 builds and is sequenced behind its MERGE, not dispatched
beside it. Within round 1 the file sets are disjoint: S1 owns `router.ex:7139-7173` and new files only; S4
owns `deploy_ledger.ex` inserted at line 675 (the free region ~115 lines above #10129's EOF anchor, so it
cannot conflict with the crown in either merge order) and must NOT touch `census/3`, `rate/2`, `@classes`,
`@labels` or `classify/2`; S3 READS `router.ex` and `client.go` but edits neither. Two coupled edits are
named so nobody discovers them in review: S3 adds `internal/cloudclient/**` to `CLOUD_PATHS` and must raise
`CLOUD_ESCAPE_MIN` in the SAME commit (the floor is `-lt`, so forgetting it decays silently rather than
reding) — and #10014's own one-line fix touches the same array, so a trivial conflict is expected and the
floor is one higher if that lands first. S4 ships its Go reader in the same slice (D136's landed precedent),
so it cannot create the unread key S3 exists to catch.

MIGRATIONS FOR THE LEAD TO ORDER: S1 (a `content_publishes` table) and S6 (`deployments_site_became_live_index`,
which also DROPs the undeclared `tmp_dep_site_live`). Distinct version stamps are specified in each brief.

HIGH-FLIP-RISK (D171): **S1** — whether recording the publish instant on the HMAC receiver is genuinely
non-blocking and cannot fail the 202, and whether the recorded population truly includes the 26–35 % of
publishes that mint no deployment row. **S3** — whether the extractor can SEE what it claims to census, given
both measured blind spots, and whether its anti-vacuity floor can actually lose.

Coverage: every survey and verify agent reported; there is no coverage deficit this wave. Two questions
remain OPEN and are filed rather than assumed: the cause of the 03:46:11Z webhook `types`-leak stop (D169f),
and whether `AuthoringWall`'s Exemptions ledger can grandfather the legacy task corpus (D168).

Charter published as a docs-only PR, not pushed to main (D39, honest-gates).

## Wave 12 — the harm changed its name, and this time the epic's own fix is what moved it (2026-08-07)

Wave 11 built the half that WRITES the true clock. Wave 12 builds the half that READS it, and points it at
the outcome that now dominates — but verification overturned four of the direction's load-bearing facts and
one of the digest's, so the cut below follows the evidence, not the plan.

- **D172 — THE RATE IS DILUTED, NOT BLIND, AND DILUTION IS WORSE THAN EXCLUSION.** The direction said
  `deferred` sits in `@not_attempted_classes` and is EXCLUDED from the published rate. REFUTED at file:line —
  `@not_attempted_classes` is exactly `["GITHUB_PUSH_UNBUILDABLE"]` (`deploy_ledger.ex:112`); deferrals live
  in a separate `@deferred_classes` and stay INSIDE `volume = total(attempted)` (`:537`) while never entering
  the numerator. So every deferral actively drives `failure_rate` toward zero. Proven by a fixture that holds
  failures at 120 and live at 120 across four windows: published 50.0% → 40.0% → 25.0% → **12.0%** while the
  terminal rate is flat at 50.0%; on the fleet, 21.15% published vs **45.51%** terminal. **RULING: the repair
  is ADDITIVE ONLY.** Mutating `volume` to subtract deferrals reds TWO pre-existing tests (the D9 relocation
  tripwire and the unnamed-deferral test) — so D170b is now proven by mutation rather than asserted, and
  `@not_attempted_classes` is left alone.
- **D173 — #10192 MERGES AFTER A RE-RUN AND ONE ALLOWLIST ROW, AND THE ROW THE FILE ITSELF PRESCRIBES IS
  WRONG.** Its two reds were ONE environment refusal double-counted (the Overflow guard self-declares "an
  ENVIRONMENT refusal (exit 2), NOT a measured screen defect (exit 1)"; Console gate is its fail-closed
  rollup printing "Measured defects (exit 1) in this run: none"). A re-run turned both green: zero non-green
  check-runs, `mergeStateStatus` BLOCKED → CLEAN. But merging it into main reds the payload key-set census
  on SET EQUALITY — "new phantom: delivery" — because the guard landed via #10190 AFTER #10192's checks ran
  and does not exist on its branch. `strict:false` means the stale green merges and MAIN's Cloud gate
  discovers the red. The commented MERGE-ORDER NOTE's row, pasted verbatim, greens the phantom arm and reds
  a DIFFERENT test (the KNOWN-OPEN tracker regex `dr-w11-payload-divergence-close|PR #\d+`). The correct
  reason must OPEN with `PR #10192`. "Nothing else is needed" was false — an instrument whose prescribed
  remedy was never itself run, which is this epic's signature defect appearing inside its own fix.
- **D174 — CHAIN CLOSED-LIVE RATE IS REFUSED AS A HEADLINE; THE FENCE FIRING IS THE CROWN. D126 IS
  REFUTED.** The 12-cap HAS fired: 7 rows table-wide carry `in a row`, 6 of them capacity fences on
  2026-08-07 between 01:20:14Z and 03:41:33Z across search-ember, search-capstone (×2), live-auto, search,
  astro-search. Each firing is a publish ABANDONED after 12 refusals — the one deploy-reliability quantity
  no bucket swap can dilute, because it is an absolute count and not a rate. Meanwhile the 48.9% chain
  closed-live figure is a SEVEN-DAY number whose 24h value is 28.3%; its cause split (capacity 93.6% vs busy
  19.7%) is a DISJOINT-ERA artefact, not a property of the cause; time-matched, the chain adds only +1.8pp in
  the capacity era; and D142's refusal of chain-derived rates pending a real chain KEY applies unchanged.
  **Ship the absolute abandonment count, alerted; refuse the rate.**
- **D175 — THE SUCCESSOR RULE NEEDS NO HARDENING; DO NOT SPEND A SLICE.** Loose, 15-minute-bounded, and
  trigger+source-matched rules agree on 431/431 chains, zero disagreements, because the successor arrives at
  the 60s Oban debounce (gap p50 60.8s, max 103.4s) and the fleet has one label pair (content-auto/box-build
  on 2,471 of 2,494 rows). D162/D163 stand; the residual is closed, not re-opened.
- **D176 — THE PUBLISH-KEYED JOIN IS RULED, AND `dr-w11-followup-publish-instant-has-no-reader`'s OWN
  PRESCRIPTION IS WRONG ON 85% OF TODAY'S POPULATION.** The rule is `ORDER BY became_live_at` where
  `became_live_at IS NOT NULL`, guarded by `inserted_at >= received_at` (conservative: it can only
  UNDER-credit; it moves exactly one of twenty rows, by 21x), plus the redundant `became_live_at >=
  received_at` bound purely as a seek predicate — provably free (`count(*) where became_live_at <
  inserted_at` = 0 over 30,648 rows) and worth 684x fewer buffers and 103x less time (37,614 → 55 shared
  hits; 39.781ms → 0.386ms). The task's "nearest forward `inserted_at`" picks a **deferred** row for 17 of
  20 publishes and all 17 never went live. Three more rulings: the censor date is the MIGRATION instant
  (08:10:38Z), never `min(received_at)`, which mistakes "no publishes yet" for "recorder not running";
  `site_never_live` is STRUCTURALLY UNREACHABLE through the HMAC receiver and must not ship as a live
  bucket; and `content_publishes` counts DELIVERIES, not publishes — 20 rows are four bursts of five, one per
  webhook-bound site, crediting only 14 distinct deployments, so any denominator phrased as "publishes"
  over-counts by the fan-out factor.
- **D177 — "TWO PRODUCERS, ONE SILENT" IS REFUTED, AND THE REAL SILENT PRODUCER IS WORSE.** There is ONE
  row-writer (`sites/deploy.ex:1249`) and it ALWAYS emits the chain sentence; the 1,110 chainless rows are a
  ROLLOUT BOUNDARY (prose exists on exactly 228–250 rows, min `inserted_at` 2026-08-07 04:18:46.189162, and
  after that instant coverage is 100% on both cause codes). The genuinely silent producer is
  `auto_deploy_worker.defer_behind_running_build/2`, which writes **NO ROW AT ALL** — its own comment says
  the active-deployment index correctly refused to mint one. Measured from Oban: 2,256 jobs vs 1,052 rows in
  twelve hours = **1,204 uncounted attempts against 277 counted (4.35:1)**; today it is 0.086:1 and 0 per
  minute. It is not fixed — it is dormant, and it returns as a FUNCTION OF LOAD, i.e. exactly when the number
  matters. Quote it as "attempts that minted no row", never as "uncounted deferrals" (the `{:duplicate,
  queued}` re-drive arm shares the shape).
- **D178 — THE ALARM IS A 1:1 SHADOW OF `status='failed'` AND WENT SILENT BY THE SAME MECHANISM.** Over 54
  hours: 2,286 failures vs 2,296 `deployment_failed` notifications, total absolute hourly divergence 72
  (~3%). The dispatch fires only on the edge INTO "failed" (`registry.ex:6882-6883`), so a deferred
  transition notifies nobody by construction. The collapse instant is **22:15–22:30Z on 08-06, not 20:00Z**
  — at 15-minute resolution the hourly bucket splits into a 2h04m near-total TRIGGER STOPPAGE (four rows)
  and then the rename. Suppression is a hard zero: `notification_deliveries` has only `sent` (2,999) and
  `failed` (5) table-wide, `Withhold` was deployed through the entire 870/day peak, and the reaper — the
  ONLY producer `@reap_alert_cap` governs — produced ZERO failures on every day 08-03…08-07 with a
  table-wide max of ONE per minute. **Do not spend a slice on the reaper or an Oban mail queue.** D164
  corrected twice: all 2,297 emails went to ONE recipient (not 22 teams), and the channel is YOUNGER than
  the epic — zero rows before 2026-08-03 14:57:40Z, against 6,119 failures on 07-31…08-02 that alerted
  nobody because the dispatch did not exist. RULING: change what the alert READS, never how loudly it sends.
- **D179 — THE 20:00Z IMPROVEMENT IS REAL RECOVERY. "NOTHING RECOVERED" IS REFUTED, AND SO IS DIGEST FACT
  5.** Guerrilla reset to `ef77af274` (#9827 — this epic's own dr-w3-s5 typed `box_at_capacity` door) at
  2026-08-06 22:19:52Z, **9m35s before the first `box_at_capacity` row** and 5h27m after its own merge; the
  two causes never coexist, and `running_slug?` is evaluated before `box_at_capacity?`, so the new rows are a
  NEW POPULATION, not relabelled ones. Across that boundary, live-of-attempted goes **33.4% → 94.4%** while
  the arrival rate nearly DOUBLES (72/hr → 135/hr), and every named failure class collapses with the load:
  503 feature_not_configured 191→4, HTTP 500 internal_error 123→1, HEALTH bp-doc-id empty 84→7, other 86→10.
  So the classes the epic filed as configuration and code defects were largely ONE cause wearing four names.
  Both things are true at once: rows WERE relabelled, and the fleet DID recover. The instrument that can only
  accuse still cannot report this, and no box records its own code age.
- **D180 — CAPACITY IS ANSWERABLE NOW, AND IT IS NOT THE LEVER. DO NOT RAISE `@build_slot_capacity`.** The
  build clock already exists twice and nothing reads it: `deployments.console` carries a per-stage `at` on
  120,427 entries, and guerrilla's journald logs every acquire/queue/release. True compile p50 **28.7s** /
  p95 90.1s (DB, un-overlapped) and p50 39.0s / p95 133.0s (journald, saturated); the naive all-rows interval
  (p50 79.3s) is a TRAP because `emit BUILD started` fires at `site-deploy-node.sh:1610` and the gate is only
  taken at :1628, so the console BUILD interval includes the flock wait — the apparent "6 concurrent builds"
  on a 1-slot box is the first measurement of QUEUE DEPTH, not a broken gate. Capacity ≈ 78–95 builds/hr
  against 103.6 attempts/hr: ρ 1.28 at peak, 0.58 at median. The flock fence has NEVER timed out, so builds
  are never concurrent and `task-cbde37238506ed7c`'s swap-thrash MECHANISM is wrong. `claimed_at` is written
  at completion (max gap to `became_live_at` 16.9s over 10,232 rows) and must never be used for queue math.
  The levers are demand (D181) and a reader over what is already recorded.
- **D181 — THE CHURN SURVIVED THE LEAK; S-C MUST NOT BE SCOPED TO IT.** Task deliveries stopped
  2026-08-07 03:46:11Z (cause still unestablished) and attempts fell ~200/hr → ~77–82/hr, so the leak was
  ~62% of pre-04:00Z load. Post-leak: 348 attempts against 26 real paper publishes = **13.4 attempts per
  publish, ~59% deferred**. Two live amplifiers remain — all five webhooks bound to ONE shared dataset (1
  publish → 5 rebuilds) and the chain's further ~2.6x. The denominator is also five sites dressed as
  thirteen: five webhooks carry 98.4% of attempts, three more deploy only on the hourly template clock, five
  have no automation at all, and 100% of 24h deferrals come from ONE box.
- **D182 — A NEW SILENT LOSS CLASS, UPSTREAM OF EVERY INSTRUMENT THIS EPIC OWNS.** Over 24h, **4 of 134
  production-dataset paper publishes produced ZERO `webhook_deliveries` rows (3.0%)** — including THIS WAVE'S
  OWN PAPER (event 176805, 2026-08-07 08:13:46Z). Those publishes are absent from `content_publishes`, from
  `deployments`, and from every census this epic has built, and nothing reports them. `Webhooks.Dispatcher.
  dispatch_async/7` fans out through `Task.Supervisor.start_child` and discards the result
  (`dispatcher.ex:79`, `:98-108`); journald has no entries for the window. **Root cause is UNESTABLISHED and
  the slice must not claim one** — it makes the class COUNTABLE. Three of the four trace to one document, so
  the 3.0% may be a per-doc pathology; it is a magnitude, not yet a rate.
- **D183 — THE ONE-SIDED FLOOR THAT ACTUALLY DECAYS IS THE ELIXIR ONE, AND IT IS INSIDE A REQUIRED GATE.**
  `CLOUD_ESCAPE_MIN=6` is EXACTLY tight (population 6 on a clean origin/main checkout) and flipping `-lt` to
  `-ne` would red nothing today — the worry is refuted by run, and flipping it would also REVERSE this
  epic's own dr-w2-s6 reasoning. The real defect is `ELIXIR_ESCAPE_MIN=8` against a measured population of
  **29** (its own comment says 24): dropping `api/test` from the scanner loses **18 of 29 reads (62%)** and
  the ratchet still prints OK, exit 0, inside the REQUIRED Elixir gate. The remedy is already LANDED next
  door — `cch-w30-s3` deleted `CONSOLE_ESCAPE_MIN` entirely and replaced the magic integer with per-idiom
  DERIVED floors plus `--print-floors`, with the harness asserting `--check`'s count equals `--list-escapes`'
  distinct count. **Port that shape. Do not bump an integer and do not use `-ne`.**
- **D184 — THE ZERO-CRITERIA CENSUS SPLITS: THE SELF-TEST IS WIREABLE TODAY, THE RATCHET IS NOT.**
  `epic-zero-criteria-census.sh` has ZERO callers of any kind (six grep hits, all self-references) — the
  purest clause-2 failure in the epic. Its `--self-test` is fully hermetic (mktemp fixtures + `python3`, 8/8
  cases, exit 0, 0.04s) and can be wired blocking today; its RATCHET shells `bp`, which is not on GitHub
  runners, and exits 2 UNKNOWN on every PR forever (proven by PATH-strip). Wire the self-test into
  `shell-harnesses.yml` and say plainly that this workflow is NOT one of the four required contexts. The
  token-free ratchet port is filed, not built, and it must first reconcile a denominator delta (`bp` reports
  204 children, the public query route 203).
- **D185 — #10129 IS NOT REBASED, AND THE LEAD OWES TWO RULINGS, NOT ONE.** The conflict set is SIX paths
  (`attention_order.json`, `cloud_status_cmd.go`(+test), `attention_order_cases.json`, `client.go`,
  `semrole.go`) and it is stable across two different `origin/main` tips; `router.ex` auto-merges, so the
  fence worry is dead. D150's ratified basis is OBSOLETE **in its own words** — it states it builds on the
  EIGHT-rung ladder "the eleven-rung D69 ladder is unmerged #9887", and #9887 merged at 06:13:52Z. A textual
  rebase yields THIRTEEN rungs and silently mints two unratified rulings: (1) `deploys_failing` at rank 5
  now outranks `strained`, `filling` AND `unreported`, which nobody has argued; (2) `unmetered` becomes a
  discontiguous attention rung against main's landed `unmeteredMarker` NON-rung precedent (D67/D69). The
  pins DO fire — FIVE of them, including an undocumented `TestAttentionBucket` count guard and
  `semrole_test.go` — so this is a PROVENANCE risk, not a silent-green risk. And #10129's `unmetered`
  fixture row ships `tone: ""`, which main's vocabulary pin now forbids outright ("fixture tone must be a
  real semantic role … an uncoloured status ships invisible"). **Wave 12's LEAN stands and is now
  arithmetic:** a `deploys_failing` rung on the raw 24h attempt rate publishes 21% today and ~1% tomorrow
  about a fleet deferring 847 attempts, and it fails OPEN to `ok` (not closed to `unmetered`) because the
  sample stays far above `min_sample` 200. Its input must be the delivery clock.
- **D186 — REVERSAL, SUPERSEDING THE LEAD'S STANDING INSTRUCTION: #9976 AND #10069 MUST BE MERGED, NOT
  CLOSED.** Neither touches the charter; between them they carry 13 `tooling/grip/ledger/*.md` files, ALL
  absent from origin/main by path AND by content — eleven of thirteen distinctive measurements grep ZERO on
  main's whole tree, with a false-positive control (generic infra strings DO hit). Both are OPEN /
  MERGEABLE / CLEAN with ZERO failing checks and all four required contexts green; nothing blocks them.
  Two corrections: `dr-w8-lifeline-safety-rederivation.md` IS genuinely redundant (its headline p50 0.329s /
  p99 5.771s / 13,287 jobs is on main at `cloud/config/config.exs:246-250`), and the "p95 breakdown" the
  brief said would be destroyed **does not exist** — that file records zero measured percentiles; its real
  asset is two mutation-proven ring errata. The green "Re-land advisory" on both compares FILE PATHS only
  and must not be cited as content evidence.
- **D187 — TWENTY-EIGHT MERGE-GATED CHILDREN ARE CLOSABLE NOW.** There are **43** open children exactly one
  criterion short, not nine; **31** of them have a sole unmet criterion whose text is literally "MERGE-GATED
  (the LEAD closes this)"; **28** of those resolve to an already-MERGED PR and are satisfied this minute,
  against an epic accreting ~80 open rows/day at ~1 closed. Only three remain genuinely gated: #10019 (the
  raw-capture SECRET-LEAK fix, red since 02:18Z on Console gate + Overflow guard + Billing tier floor — the
  same environment-refusal family as #10192's, so a re-run candidate, and unnamed anywhere in this wave's
  brief), #10129, and #10192. ZERO open children sit at `total=0`, so D168's backfill is paid. Two method
  traps for whoever re-derives: criteria live at `doc.content.acceptance_criteria` (a top-level read returns
  empty and reads as "no criteria"), and `content.github.issue` is a MIRROR ISSUE number, not the PR.
- **D188 — ARTIFACT IDENTITY IS NOT A KEY AND WILL NOT BECOME ONE THIS WAVE.** Where both sides record a
  digest the artifact the box served matches the row byte-for-byte — but that is 6 rows of 30,633. All
  30,627 `box-build` rows carry NULL, including EVERY live deployment that closes a superseded revision, and
  the box writes `.bp-prebuilt-sha256` only on the prebuilt arm, so the comparison is unrunnable in both
  directions for 99.98% of the fleet. One `content_rev` produced FOUR distinct artifacts — the build is not
  reproducible, so neither column is a content key. `promotion_attrs/1` really does drop `content_rev` and
  `artifact_sha256`, but it is UNREACHABLE today (promote 422s `not_promotable` for static/node before it,
  and the only container site has `prebuilt_enabled=false`) — file it as a FENCED trap that arms the moment a
  container site turns prebuilt on, not as a live defect. And there is no clock skew (`min(became_live_at −
  inserted_at)` = +6.199704s, zero negatives over 10,232 rows), so D176's range-seek guard loses nothing.
- **D189 — WAVE 12 IS ALL OPUS; TWO SLICES ARE HIGH-FLIP-RISK.** Fable is unavailable fleet-wide, so every
  slice is `opus` at medium and the difficulty axis is expressed in scope, not in model. **HIGH-FLIP-RISK:
  S3** — whether a counter can actually SEE a publish that fired zero deliveries (the failure is the absence
  of a row, and the producer discards its own result), and whether the write path is reachable without
  admin. **S6** — whether BOTH deferral producers emit the new structure, given that the silent one mints no
  row to hang a column on, and whether the migration is safe against a live 30,633-row table. Both are owed
  an INDEPENDENT second reviewer before merge; this workflow spawns only one, so that dispatch is a manual
  lead step.

### Wave 12 plan — 8 slices, 7 in round 1, file sets disjoint within a round

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | Unblock #10192 with the row its own note got wrong | `dr-w12-s1-unblock-10192-allowlist-row` | `cloud/test/**` (on #10192's branch) | small | opus |
| 2 | 1 | The publish clock gets a reader that is correct on an empty table | `dr-w12-s2-publish-clock-reader` | `cloud/lib/**` (new module) | large | opus |
| 3 | 1 | A publish that fires zero webhooks becomes countable | `dr-w12-s3-zero-delivery-publish-countable` | `api/lib/**` | medium | opus |
| 4 | 1 | The Elixir escape floor stops decaying by one | `dr-w12-s4-elixir-escape-derived-floor` | `scripts/**` | medium | opus |
| 5 | 1 | The zero-criteria census gets a caller that can lose | `dr-w12-s5-zero-criteria-census-caller` | `.github/workflows/**` | small | opus |
| 6 | 1 | The deferral becomes structure, and the silent producer speaks | `dr-w12-s6-deferral-becomes-structure` | `cloud/lib/**` + migration | large | opus |
| 7 | 1 | `siteWaitingSince` stops excluding the deferral chain | `dr-w12-s7-waiting-counts-deferrals` | `internal/cli/**` | medium | opus |
| 8 | 2 (after S1) | The rate names its terminal denominator and its abandonments | `dr-w12-s8-terminal-rate-and-abandonment` | `cloud/lib/**` + `cloud/test/**` | large | opus |

Rounds are law. S8 owns `deploy_ledger.ex` AND the `@known_open` list in `payload_key_set_census_test.exs`,
which S1 also edits on #10192's branch — so S8 is sequenced behind S1's MERGE rather than dispatched beside
it, and its brief opens with the `AFTER dr-w12-s1-unblock-10192-allowlist-row merges` line. Within round 1
the file sets are disjoint by construction: S2 creates a NEW module (`publish_clock.ex`) and deliberately
does not touch `deploy_ledger.ex`; S6 writes the new deferral columns but leaves `classify_deferred/2`
reading prose, so it never enters `deploy_ledger.ex` either; S3 is the only `api/**` slice; S4 and S5 are
`scripts/**` and `.github/workflows/**`.

MIGRATION FOR THE LEAD TO ORDER: S6 adds deferral-structure columns to `deployments`. Stamp
`20260807150000` or later — prod's applied head is `20260807140000` (D166's drift is closed; all ten
`deployments` indexes are now declared).

FENCE: cloud-console-hardening wave 43 owns `cloud/priv/static/app.js`, `cloud/lib/**/web/auth.ex` and
`router.ex`'s auth region. No wave-12 slice touches any of them.

LEAD ACTIONS THIS WAVE, recorded so they cannot be lost: merge #9976 and #10069 (D186); re-run #10019's
three environment-refusal checks (D187); close the 28 satisfied merge-gated children (D187); rule on
`deploys_failing`'s rank and on whether `unmetered` is a rung at all before any #10129 resolution (D185).

Coverage: every survey and every verify agent reported; there is no coverage deficit this wave. Questions
carried OPEN and filed rather than assumed: the root cause of the four zero-delivery publishes (D182), why
same-slug `already_running` collapsed 277 → 1 (D179), and the cause of the 03:46:11Z delivery-leak stop
(D181, inherited from D169f).

Charter published as a docs-only PR, not pushed to main (D39, honest-gates). It carries D161–D171 forward
from the still-blocked #10173, so merging THIS PR makes #10173 redundant.

### Wave 2026-08-07 (wave 12) — REVIEWED · Paper `deploy-reliability-wave-12-2026-08-07` · grade **A−**

**All seven round-1 slices built, reviewed, gate-green, PUSHED and PR'd. Nothing merged — the lead merges.**
`dr-w12-s8-terminal-rate-and-abandonment` was deferred to round 2 BY DESIGN (it edits the same `@known_open`
list and `deploy_ledger.ex` that S1 edits on #10192's branch); its task is open, unclaimed, 0/10, which is the
correct ledger state for a sequenced slice and not a stall.

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| Unblock #10192's delivery phantom | `dr-w12-s1-unblock-10192-allowlist-row` | `…refuses-an-unidentif-3-r` (#10192's OWN branch) | [#10192](https://github.com/FRIKKern/barkpark/pull/10192) | census 11/0 · full cloud suite 3058/0 |
| The publish clock gets a reader | `dr-w12-s2-publish-clock-reader` | `…gets-a-reader-that-is--1` | [#10244](https://github.com/FRIKKern/barkpark/pull/10244) | 11 tests, 0 failures |
| A zero-webhook publish becomes countable | `dr-w12-s3-zero-delivery-publish-countable` | `…zero-webhooks-becom-2-r` | [#10245](https://github.com/FRIKKern/barkpark/pull/10245) | 46/0 · full `test/barkpark/webhooks/` 111/0 |
| The Elixir escape floor stops decaying | `dr-w12-s4-elixir-escape-derived-floor` | `…ratchet-stops-decaying-3` | [#10246](https://github.com/FRIKKern/barkpark/pull/10246) | ratchet exit 0 (29 reads / 4 idioms) · harness 127/0 |
| The zero-criteria census gets a caller | `dr-w12-s5-zero-criteria-census-caller` | `…census-gets-a-caller-i-4` | [#10247](https://github.com/FRIKKern/barkpark/pull/10247) | self-test PASS, exit 0 · 4 jobs parse |
| The deferral becomes structure (**MIGRATION**) | `dr-w12-s6-deferral-becomes-structure` | `…becomes-structure-and-the-p-5` | [#10248](https://github.com/FRIKKern/barkpark/pull/10248) | 89/0 · full cloud suite 3051/0 |
| `siteWaitingSince` counts refused rounds | `dr-w12-s7-waiting-counts-deferrals` | `…stops-excluding-the-one-6` | [#10249](https://github.com/FRIKKern/barkpark/pull/10249) | build + vet + `go test ./internal/cli/` ok · gofmt clean |

**CROSS-SLICE PROOF, run once by the reviewer rather than inferred from seven separate greens.** All seven
branches were merged together onto `origin/main` (46b5373ed) in a probe branch — every merge clean, no
conflicts — and the integrated tree runs: cloud suite **3071 tests / 0 failures**, `go build ./...` +
`go test ./internal/cli/ ./internal/cloudclient/` ok, `api` webhooks suite 111/0, the Elixir escape ratchet
exit 0, the zero-criteria self-test PASS. Seven greens on seven trees is not the same claim as one green on
the tree that will exist after merge, and this wave has both.

**What landed against the wish.** The wish was three verbs: find the failures still SILENT or still
MIS-REPORTED, fix them, and make the reporting able to LOSE. All three moved, and the strongest work is on
the third.

*Still silent, now countable.* S3 closes the loss class UPSTREAM of every instrument this epic owns: a publish
that fires zero webhooks was indistinguishable from a publish nobody subscribed to, because `fan_out/3`
discarded its own outcome and the failure IS the absence of a row. `selected` is now recorded synchronously in
the caller before the task is spawned (so it survives a task that never starts) and `settled` after the stream
drains, with `minted < selected` at WARNING. S6 makes the OTHER silent producer speak —
`defer_behind_running_build/2` still correctly mints no deployment row, but the attempt is now counted on the
in-flight row it coalesced onto (1,204 attempts that minted no row vs 277 counted deferrals over twelve hours;
0.086:1 today, i.e. dormant, not fixed).

*Still mis-reported, now correct.* S7 removes the exclusion that made the censored waiting clock structurally
unable to see a deferral chain — the one shape whose wait is genuinely unbounded and now 53.6% of attempts —
and measures it from the chain's FIRST refusal rather than its newest (= shortest) round, with the clock named
in the sentence per #10189. S6 ends the producer↔reader-through-English coupling: chain depth/bound/cause are
columns written by the same fenced transition that writes the sentence, and the sentence is KEPT.

*Reporting able to lose.* S4 is the sharpest finding of the wave and it is about the epic's own guards.
`ELIXIR_ESCAPE_MIN=8` was a whole-population floor over a scanner with four independent doors: deleting
`api/test` from its `find` — ONE WORD, 62% of coverage — collapsed the census 29→11 and the ratchet still
printed `OK`, exit 0, INSIDE the REQUIRED Elixir gate. It now carries per-idiom derived floors, and its harness
runs a mutant of the REAL script against the REAL repo. S5 gives `epic-zero-criteria-census.sh` its first
caller of any kind (six repo-wide grep hits, all self-references). S1 stops #10192's stale green from redding
main after merge, and corrects the file's own MERGE-ORDER NOTE, whose scripted reason greens one arm by redding
another.

**What did NOT land, and must be said plainly.**
1. **Nothing is merged, so no AFTER number exists.** The 69% failure rate is not yet measured post-fix, and no
   slice this wave was a repair of the failure rate itself — this was an instrumentation wave.
2. **Nothing READS S6's five new columns.** By brief it is write-only; `DeployLedger` still classifies off the
   reason string and the Go CLI still regex-parses depth out of English. If
   `dr-w12-s6-followup-serialize-deferral-columns` is never taken, this wave shipped five columns nobody reads.
3. **S3 has no durable table**, so the epic's SQL census still cannot query the fan-out records — they live in
   telemetry + journald only (`dr-w12-s3-followup-census-reads-fanout-records`).
4. **S5 makes the census RUN, not CATCH.** The ratchet that would actually catch zero-criteria children is
   deliberately unwired (it shells `bp`, absent on runners). "The census can no longer silently break" is the
   honest claim; "zero-criteria tasks are now caught in CI" is not.
5. **S2's reader has no human surface.** Every operator read path is behind `require_platform_operator` and
   `PLATFORM_ADMIN_EMAILS` is unset on prod (D165), so nothing a human can reach calls `PublishClock`.

**Review fix made in place** (one commit, `556ad6d41` on `…zero-webhooks-becom-2-r`): S3's `record/3` runs
INLINE in the publishing process on the `:selected` arm, and its `metadata = Map.put(ctx, :phase, phase)` sat
OUTSIDE the three `safely/1` wrappers. The slice's whole contract is that the counter can never fail the publish
it counts, and that held only by the argument "ctx is a literal map at all three call sites". Proved the
exposure by mutation — a `record/3` that raises before the first `safely` failed 27 of 46 dispatcher fixtures —
and wrapped the body, so the guard is structural rather than argued. Every other slice was already right and
was left alone.

**Adversarial re-derivations the reviewer ran rather than trusting the reports.** S1: deleting the allowlist row
→ `new phantom (declared by Go, emitted by nobody)`; installing the MERGE-ORDER NOTE's verbatim reason →
`a KNOWN OPEN row must name the task or PR that closes it`. Both confirmed, both 11 tests / 1 failure. S2:
deleting `AND dd.inserted_at >= p.received_at` from `@census_sql` → 2 of 11 red, so the honesty guard is
genuinely pinned and not merely described. S4: case 5b read line by line — it really does run a mutant of the
real script against the real repo via `ELIXIR_PATH_ESCAPE_ROOT`, guarded by a `cmp -s` so it cannot pass
vacuously. S7: `sitePendingRows` compared statement by statement against the pre-refactor `siteWaitingSince` —
the `liveIdx` scoping, the stamp fallback and the keep-on-ambiguity rule are preserved exactly.

**LEAD ACTIONS, named so they cannot be lost.**
- **MERGE ORDER: #10192 (S1) FIRST.** `dr-w12-s8` edits the same `@known_open` list and `deploy_ledger.ex`;
  re-derive it on main after #10192 lands. #10192 also carries `deploy_ledger.ex`, which S8 owns.
- **MIGRATION `20260807150000` (S6) MUST BE APPLIED BEFORE THE DEPLOY.** `coalesced_attempts` carries a schema
  default, so every deployment INSERT now names it — new code against an un-migrated DB fails hard on every
  insert rather than degrading. The catalog-only-ALTER safety argument is ANALYTIC and was applied only against
  `barkpark_cloud_test`; the ACCESS EXCLUSIVE lock still queues behind any long statement on `deployments`.
- **INDEPENDENT SECOND REVIEW is owed on S3 and S6** (D189 flagged both HIGH-FLIP-RISK). This workflow spawns
  one reviewer; that dispatch is a manual lead step.
- **The lead closes the merge-gated criterion on every one of the seven slice tasks on merge.** All seven are
  correctly left `in_progress` with the merge criterion open.

**Ledger.** Honest across the board — seven tasks, every one claimed, every non-merge-gated criterion stamped
with evidence as the work happened, lifecycle `in_progress`, no false `done`. One fix: S5's PR-body criterion
was correctly stamped `--miss` (builders do not push, so there was no body to quote); the reviewer opened
#10247 with the required sentence verbatim and stamped it met. Two new tasks filed from the review itself —
`dr-w12-rv-publish-clock-match-ceiling` (the lateral is bounded below but not above, so a three-week-later
deploy reads as "delivered" and would enter a percentile once the sample clears `min_sample`) and
`dr-w12-rv-site-waiting-page-truncation` (a chain older than the 20-row page reads as a short wait with no
marker saying the page ran out). No task outside this wave was touched.

**HOUSEKEEPING NOTE for whoever maintains this file.** This log jumps from wave 7 straight to wave 12: waves
8, 9, 10 and 11 have `### Wave N plan` sections but NO `REVIEWED` entry. That is the orphaned-wave-log failure
mode — merging a charter PR mid-wave strands the reviewer's entry on a dead branch. This entry is appended on
the charter PR's OWN branch (#10208) for exactly that reason.

**What the next wave should take.** Round 2 first: `dr-w12-s8-terminal-rate-and-abandonment`, re-derived on
main after #10192 merges — it is the last slice standing between the epic and a rate that names its own
denominator, and #10014 is superseded by its re-cut. Then close the read half of what this wave wrote:
`dr-w12-s6-followup-serialize-deferral-columns` (five columns nobody reads) and
`dr-w12-s3-followup-census-reads-fanout-records` (a loss class recorded only in journald). Then the AFTER
number — nothing in twelve waves has yet measured the failure rate post-repair, and an epic founded on "69% of
deploys fail and nothing reports it" owes that measurement more than it owes another instrument.

## Wave 13 — every instrument is built and unreachable, and the one class anyone can read has never once been true (2026-08-07)

**THE RE-FRAME, AND IT IS A CORRECTION TO MY OWN DIRECTION.** Strategize named TIME TO WEB the vital on the
strength of a p95 of 58m46s and a 5.0% band of publishes unserved within an hour. **Verification refuted the
tail by measurement, and I follow the evidence.** That distribution is a blend of a dead regime with a live
one PLUS right-censoring. Split at D179's boundary and cut so every row had a full hour of observation:
**n=1,110, p50 3m32s, p95 15m49s, max 42m19s, and ZERO publishes unserved within the hour** — reproduced under
a second timestamp column (`live.inserted_at`: p50 181.9s, p95 801.0s) and a second observer. The 75 "unserved"
rows are 65 `already_running` rows from the dead regime plus 8 rows inserted 0–17 minutes before the query.
**Not one publish has waited an hour in the current regime.** The direction's own absorb-clause said the
measurement, not the plan, sets the weights. It did. The weight moves to REACHABILITY and to THE HONEST NAME.

That is not a retreat to the instrument-completion rival, because the measurement also sharpened what is
actually wrong. **This epic now owns FOUR readers that are built, correct, tested, and reachable by nobody** —
`PublishClock` (zero callers), `DeployLedger.delivery/3` (zero router callers), the five deferral columns (zero
serializers), and `renderDeployDelivery` (a Go reader that can only ever print its own null arm, because
`census/3` emits no `:delivery` key). **And the one class a human CAN read has never in its life been true of a
single row.** Wave 13 is: make the built things reachable, make the named things honest, and stop calling an
UP box unavailable.

- **D190 — TIME TO WEB IS THE VITAL, BUT THE QUEUE IS NOT TODAY'S HARM; SHIP THE CLOCK AS A TRIPWIRE, NOT AS
  AN EMERGENCY.** Post-D179 uncensored drain is p50 213s / p95 954s / max 2,539s / unserved **0**, against a
  pre-D179 p95 of 42,854s — a 45x gap across one boundary. The instrument still earns its build because the
  dead regime PROVES the number can reach 13h31m and nothing noticed; but no slice this wave may be justified
  by a wait that is not happening. **Corollary, and it is the harder half: nothing in this fleet noticed the
  RECOVERY either.** An instrument that can only accuse is as broken as one that cannot accuse.
- **D191 — A LATENCY NUMBER NAMES ITS UNIT, NOT JUST ITS WINDOW.** On identical rows, identical window,
  identical clock: row-weighted p95 **949.1s** vs chain-head-weighted p95 **618.7s** — **53% apart**, purely on
  whether you count REFUSALS or WAITING PUBLISHES (1,110 rows are 139 actual waits, 8.0 rows per wait). The
  direction's own finished-experience sentence was row-weighted and did not say so. **RULING: every published
  time-to-web figure carries window + unit + regime boundary + per-site spread (measured 4.6x across six
  sites, 327s–1,514s at p95), or it is not published.** A percentile that hides its unit is the same defect
  class as a rate that hides its denominator, and this epic exists because of the second one.
- **D192 — THE AGGREGATE HIDES AN HOUR AT 39 MINUTES, AND THE TAIL IS NOT DEMAND-DRIVEN.** Hourly p95 swings
  8x inside the "healthy" window: 290.9s at 06:00Z, **2,365.5s at 07:00Z**, 297.3s at 09:00Z. The WORST hour
  carried n=58 — one of the quietest — while the busiest hour (n=171) read p95 742.5s. **So the survey's
  inference that drain time is a property of DEMAND RATE is NOT supported by post-regime data.** That
  inference was the argument for inverting the amplifier sequencing; it is downgraded to a hypothesis. A
  published 12h p95 of 949s would have read healthy while a site owner in hour 07 waited 42 minutes.
- **D193 — THE ABANDONMENT ALREADY NOTIFIES. THE PREMISE "IT REACHES NOBODY" IS REFUTED AT L1.** All seven
  abandonments have a `notification_deliveries` row: event `deployment_failed`, status `sent`, one recipient,
  six of seven matched within <1s. `fail/2` writes `status: "failed"` through `transition_deployment_fenced`,
  whose edge guard suppresses only `failed→failed`, so the edge fires every time. **The defect is not silence
  — it is that the most severe outcome in the fleet is indistinguishable from the least severe**: one event
  name (`event_email.ex:118`), one renderer arm (`render.ex:75`), one settings toggle (`email_settings.ex:73`).
  **Movement 4 is therefore SPLIT A CATEGORY, not ADD A PRODUCER**, and `DeployLedger` already classifies
  `ABANDONED_AT_CAPACITY`/`ABANDONED_BOX_STUCK` with distinct labels, so the taxonomy is built and only the
  notification arm is undifferentiated.
- **D194 — AND THE ALERT COPY MAY NOT SAY "YOUR CONTENT NEVER REACHED THE WEB."** Proven on site
  `d8e9c2c7`: the chain runs 11 deferrals, fails terminally at 01:37:41Z — and **defers again at 01:38:49Z**,
  68 seconds later. `fail/2` does not requeue; the next webhook mints a fresh chain. What is abandoned is THE
  CHAIN, not necessarily the content. Any copy stronger than "this rebuild chain was given up on after N
  refusals" is unproven by the data we hold, and establishing whether the content landed needs the
  `content_publishes` join, not this row.
- **D195 — BOTH FENCES HAVE FIRED, AND `deferral_depth` CANNOT SEE EITHER.** The bound is dispatched by
  CAUSE (`deploy.ex:1202` against `max_consecutive_deferrals(cause)`, `:1340-1343`): **12** for
  `BOX_AT_CAPACITY_DEFERRED`, **6** otherwise. The seven abandonments split exactly that way — six at depth 12
  (capacity, 08-07 01:20:14Z–03:41:33Z, five sites) and one at depth 6 (busy, 08-05 22:57:53Z). The two
  surveyors who contradicted each other measured two disjoint eras of two different columns: `deferral_depth`
  is 22–23 rows old with max value 4, and the `refusal N of M` prose exists only on `deferred` rows from
  2026-08-07 04:18:46Z — **37 minutes AFTER the last abandonment**, and a terminal row carries the abandonment
  clause instead of the refusal prose, so a histogram over `refusal N of M` structurally cannot contain a
  fence firing. **RULING: any abandonment reader keys on the anchored abandonment clause or on
  `DeployLedger`'s `ABANDONED_*` class — NEVER on `deferral_depth >= 12`, which returns zero forever.**
  D174's ruling (ship the absolute count, refuse the rate) stands and is confirmed on the numbers.
- **D196 — THE LARGEST SURVIVING CLASS IS 100% MISNAMED, NOT 44.5% MISNAMED, AND THE CONFIG FIX IS ALREADY
  DONE.** `BOX_UNAVAILABLE_503` has **exactly ONE distinct `failure_reason` all-time — 265 rows, every one
  `feature_not_configured`** — so the label "the box was unavailable (HTTP 503)" has never once been true of
  any row it names. And the flag IS set: `/opt/barkpark/.env:24`, **both** per-slot env files the systemd unit
  actually reads, the running BEAM's `/proc/<pid>/environ`, and `deploy/instance-deploy.sh:671`'s
  `write_slot_env()` carries it forward across every redeploy (D38). Proof by contradiction: in the 08-06
  13:00Z hour **15 deploys went LIVE on that same box while 44 were told "site deploys are not enabled on this
  instance"** — a live deploy at 13:03:34Z and a refusal at 13:03:38Z, four seconds apart. **RULING: the
  remedy is the CLASSIFIER. The config arm is BANNED as D3 vacuous green — there is nothing left to set.**
  `refusal_class("503")` (`deploy_ledger.ex:342`) keys on the HTTP code alone and discards the box's own code
  word, which the 409 arm already reads via `deferral_code/1`. The 503 arm is the 409 arm before wave 9 fixed
  it. **And #10015 makes this MANDATORY, not optional**: it introduced `deploy_runner_unavailable` on the SAME
  503 (D115 kept it there deliberately), so the class is now a union of two causes with OPPOSITE operator
  instructions — "you switched deploys off" vs "your runner was slow" — behind one label naming neither.
- **D197 — THE HONESTY GAUGE STRUCTURALLY CANNOT SEE A WRONG NAME.** `UNCLASSIFIED` is **0** on every calendar
  day 08-01 → 08-07, and 0 post-boundary. The taxonomy genuinely PARTITIONS the surviving failures; it does
  not NAME them. D8's gauge is live and reading zero honestly — and that zero is compatible with 44.5% of the
  numerator wearing a false label. **A partition test is not a naming test; the epic must stop reading one as
  the other.**
- **D198 — #10014 IS NOT SUPERSEDED, AND ITS UNBLOCK IS FOUR LINES, NOT ONE.** It carries a `CONTENT_API`
  classifier repair that exists NOWHERE on main (`git grep CONTENT_API origin/main` hits only this charter)
  and is worth **162 of 163 doc-id rows in the rolling 24h = 38.6% of ALL failures**, with the anchor proven
  theft-free (zero matches outside doc-id rows over 7 days, all 264 `stage=HEALTH`). Its Cloud gate is red on
  the path-escape ratchet ALONE (`R_COMPILE: success`, `R_TEST: success`, 2,982 tests pass). **But its merge
  is textually clean while being semantically blocked**: #10192 planted three `@known_open` `:phantom` rows
  (`payload_key_set_census_test.exs:548/:550/:552`) each reasoned "PR #10014 carries the emitter", and the
  census asserts SET EQUALITY, so #10014 emitting `live`/`terminal_failure_rate`/`basis` without deleting
  those rows reds the arm from the other side. **Unblock = 1 line in `CLOUD_PATHS` + 3 row deletions.** CI on
  the stale merge ref cannot see the second half. Closing #10014 as superseded costs 162 failures a day their
  cause.
- **D199 — s8 IS RE-CUT TO ITS RESIDUE, AND TWO OF ITS TEN CRITERIA WERE UNEXECUTABLE AS WRITTEN.** Proven by
  running every key through the census on main: `live`, `terminal_failure_rate` and `basis` land Elixir-only
  and green **if and only if** their three phantom rows are deleted in the same commit (adding the emitter
  alone reds with "no longer phantom … DELETE the allowlist row"). `deferred_total` and `abandoned` **RED the
  UNREAD arm** — neither has any `json:` tag in `internal/cloudclient`. And **per-site `live` /
  `terminal_failure_rate` do NOT red — they pass SILENTLY**, which is worse: `@pairs` has no `DeployCensusSite`
  entry and `sites: site_rows(...)` is a CALL the extractor's one-level bound never enters, so the census is
  **blind to every per-site key** while `DeployCensusSite` declares neither field. **RULING: since #10014
  already emits the first three, s8 re-cuts to the residue — the Go decoders for `deferred_total`/`abandoned`,
  and closing the per-site census blind spot so the instrument can see its own back.** Two traps ruled in
  advance: `rate/2 → rate/3` via a default arg is a TRIPLE red (thread `basis` as a real argument or use two
  named wrappers), and adding `basis` to only ONE of `rate/2`'s two clauses is GREEN because the extractor
  unions clause payloads — so the REFUSED node would ship `Basis: ""` forever and the census structurally
  cannot enforce clause symmetry. The fixture must.
- **D200 — THE PER-SITE PUBLISH CLOCK NEEDS A SITE PREDICATE IN THREE SQL CONSTANTS, AND MUST NOT SHIP
  PERCENTILES.** `@census_sql`'s only `WHERE` is on `received_at`; `@live_sites_sql` and `@live_deploys_sql`
  are fleet-wide. So `censor_node/3`'s zero-branch — otherwise genuinely good, it prints "0 of N live deploys
  … carry a recorded publish delivery" rather than a bare zero — would quote ONE SITE'S zero against the
  FLEET'S denominator. **And per-site percentiles are unsafe independent of sample size**: the lateral is
  bounded below and not above (`dr-w12-rv-publish-clock-match-ceiling`), so a site whose next live deploy is
  three weeks out enters the percentile as a real 20-day measurement — diluted at n=68 fleet-wide, **decisive
  at n=1 per-site.** Ship BUCKETS plus a censored `waiting >= Xs` lower bound. The pinned-SQL test uses
  `assert sql =~` (contains), so extending `@census_sql` does not red it.
- **D201 — AND THE PER-SITE NODE MAY NOT EXPLAIN A ZERO WITH THE ONLY EXPLANATION IT CAN REACH.**
  `content_publishes` has exactly ONE writer arm — the HMAC content webhook at `router.ex:12341` — so five of
  thirteen sites can ever have a row. The only site-scoped "has a publish trigger" fact available INSIDE the
  control plane is `sites.content_webhook_secret_encrypted`, and it says **6** while guerrilla holds **5**
  active `site-autodeploy-*` webhooks: `auto-proof` has a cloud-side secret, zero publishes, and no guerrilla
  webhook. **A node that explains that owner's zero as "you have a trigger, we just have no data yet" tells a
  falsehood to precisely the owner who most needs the truth.** The honest cause line lives in a different
  database on a different host. **RULING: the node says "we cannot verify your publish trigger from here", or
  it says nothing.** (Today's per-site refusal is additionally censorship-by-YOUTH — the recorder was 2h13m
  old at survey and every hot site sat at n=13–14 against `min_sample` 20 — but the permanent hazard is the
  opposite: a genuine customer publishing 3x/day sits at n=3 and is refused forever. The slice states which
  population it is calibrated for.)
- **D202 — #10129's INPUT IS ALREADY PINNED BY MUTATION; ITS WINDOW IS NOT PINNED BY ANYTHING.** The
  direction's priority 5 aimed at the wrong number. #10129 reads `rate(failed, failed + live)` — the TERMINAL
  rate — and mutating the denominator to `attempted` **REDS** (`deploy_ledger_test.exs:1693`, `sample == 250`
  got 500). But mutating the WINDOW from `-24 :hour` to `-7 :day` leaves **1,176 Elixir tests green**, because
  `grep -rn 'deploy_rate' cloud/test/` returns **ZERO** — the router's `merge_deploy_rate/2` and its window
  pinning have no Elixir test at all. The window is a floating `DateTime.utc_now()` minus 24h, which the
  ledger's own moduledoc forbids in writing (`:74-75`) and which `parse_window/2` refuses for the census route
  by design. Same input, same fence, opposite rungs: 42.8% rolling vs 5.1% calendar. **RULING: the slice is
  "pin the WINDOW", not "rule the input", and it rides #10129's rebase rather than fighting it.** Ratified so
  the rebase is mechanical: **`deploys_failing` at rank 5** (a measured, customer-visible outcome outranks a
  leading indicator and a measurement gap) and **`unmetered` tone = `warn`** — forced, because main's
  tone-hole guard now makes `tone:""` illegal and the landed sibling silence `unreported` already ships
  attention/warn/`?`. Also ruled: the rebase must UNION `semrole.go`, never take-theirs (that deletes
  `strained`/`filling`/`unreported` and reds 11 assertions), and the six conflicts are Go/JSON fixtures only —
  `deploy_ledger.ex` and `router.ex` auto-merge clean.
- **D203 — MAIN'S REQUIRED ELIXIR GATE IS RED ON A FLAKE THIS EPIC AUTHORED, AND MAIN IS NOT REGRESSED.**
  `b00d793c` shows exactly two non-green check-runs of 33: `Test (Elixir 1.18.1 / OTP 27.0)` and its
  fail-closed rollup. One test of 13,561: `site_deploy_controller_test.exs:158`, "an unanswered trigger is its
  OWN 503", expected 503 got 202. Proven a flake by BYTE-IDENTITY, not assertion —
  `git diff d73c5b526 b00d793c` over `deploy_runner.ex`, `site_deploy_controller.ex` and the test file is
  EMPTY, and the same test passed on #10015's head. The test pins `trigger_call_timeout_ms: 1` against the
  REAL Runner and asserts the door outruns a 1ms budget: **its green side is luck.** By the standing test's own
  logic this is a guard that loses at random inside a required gate — worse than one that cannot lose, because
  it teaches the fleet to re-run reds. It is dr-w8-s2's test; this epic fixes it.
- **D204 — THE CLOSABLE SET IS 38, NOT 31, AND D187 UNDER-COUNTS BY 23% FOR THE EPIC'S OWN FAVOURITE REASON.**
  A literal-substring census over `MERGE-GATED (the LEAD closes this)` misses the six other ways the same gate
  was authored across waves 1–12 (`…(the LEAD closes this one)` ×5, `…(the lead closes this)` ×5,
  `…(lead closes)` ×2, `…(the LEAD closes this one, not the builder)` ×2, `PR merged. Closed by the lead.`,
  `PR merged and the migration applied cleanly…`). A bespoke check over hand-authored prose lied — in this
  epic's own ledger, about this epic's own rows. **31 close outright** (28 plain-merge, all shas ancestors of
  origin/main with all four required contexts green; plus 3 whose migration clause is discharged on cloud-db-1
  at head 20260807150000). **+2 the moment #10245 and #10246 merge** — both CLEAN and fully green right now,
  which makes merging them the highest-leverage act available for two clicks. **+3 after two five-minute
  second-reviews** (#9827 and #9887 each carry an "AFTER an independent second review" clause and each has
  literally ZERO reviews and ZERO comments) **and one end-of-wave census re-run** (`dr-w11-s7`'s clause is a
  FUTURE condition, dischargeable only once this wave has filed its tasks — closing it today would be the
  false-done class this epic already reopened 11 rows for). Two method traps recorded: every one of the 38
  rows is UNHELD (37 with a swept lease, one with a claim stamp and no lease), so each needs
  `bp task claim` before `bp task close` — a stale epoch is a LOUD 409 `fenced_off`, not a silent no-op; and
  `gh pr list --search` run from a non-git cwd dies on stderr and prints an EMPTY result on stdout, which
  manufactured a uniform, plausible, entirely fabricated "no PR references this task" for all 38 rows on the
  first sweep. **A uniform zero across a heterogeneous population is the tell.**
- **D205 — #10246 DISCHARGES D183; FILE NO SLICE AGAINST THE ESCAPE FLOOR.** Four independent scanner
  blindings written before reading the PR — drop the `__DIR__` resolution base, drop the `mix test` cwd base,
  stop walking `api/lib`, stop scanning `.ex` files — ALL exit **0** on main (census 29→29/25/27/27, each
  printing "OK"), and ALL exit **1** under #10246, each naming the blind door by tag. Its self-test is
  **127 passed, 0 failed** and carries the two cases whose absence made the old floor uncertifiable. It
  touches only two script files and neither declared path set, so nothing orders behind it. **Merge it; a
  wave-13 slice against `scripts/elixir-path-escape-check.sh` would clobber a merge-ready 281-line rewrite.**
  One method note worth keeping: the first blinding harness reported "census 0, exit 1" for every mutation and
  looked like a refutation — the mutated copies sat at the worktree ROOT, so `dirname/..` resolved `REPO_ROOT`
  to an empty tree. Quoting that run would have cleared #10246 as unnecessary. **An instrument pointed at the
  wrong root reports defect-shaped prose for "I could not look" — the standing test's sixth clause, caught in
  our own harness.**
- **D206 — DEMAND REDUCTION STAYS FILED, AND THE SEQUENCING ARGUMENT FOR IT IS NOW WEAKER, NOT STRONGER.**
  Demand is 100% self-inflicted and confirmed: five demo webhooks, all `types={paper}` on ONE shared
  `production` dataset, one paper publish = five site rebuilds ALWAYS (11 of 13 publish instants are exactly
  5 rows / 5 distinct sites), 9.75 attempts per real publish, 98.4% of attempts on five demo sites, six sites
  at zero. **And no instrument could report a regression if we cut it**: `deployments.trigger`/`source` is
  **99.06% one pair** (`content-auto`/`box-build`, 2,415 of 2,438 rows), so there is no label separating
  customer demand from platform churn — D3's vacuous green in its purest form. The survey's mechanism argument
  (Oban holds zero retryable/available/executing `site_deploy` work, so the re-queue is delivered by the next
  webhook and cutting the amplifier could make time-to-web WORSE) is real but is downgraded by D192 to a
  hypothesis. **Both stay filed. The label must exist BEFORE the cut, not after.**
- **D207 — TWO CHARTER FACTS ARE NOW FALSE AND ARE CLOSED BY RULING, NOT RE-SURVEYED.** D11's "an EXISTING
  COLUMN nobody sets" is dead: all five `site-autodeploy-*` webhooks carry `types={paper}`. And D169f/D181's
  "the 03:46:11Z delivery-leak stop has no commit and no deploy to explain it — cause NOT established" is
  dead: the five rows' `updated_at` are 03:43:23.234Z, 03:43:23.553Z, 03:43:23.894Z, 03:43:24.567Z and
  **03:46:27.036Z**, bracketing the stop. **The cause is the filter repair itself** (`dr-w1-s4` /
  `dr-w9-s4` landing on live rows), and the stop has held seven consecutive hours at 15–35 deliveries/hour,
  every hour an exact multiple of five. Additionally: `dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures`
  is re-titled — its title asserts a premise D196 disproves three ways, and leaving it open is an active
  source of the wrong fix being re-attempted.
- **D208 — THE WINDOW DEFECT IS REAL AND NARROWER THAN THE DIRECTION SAID; THE CALENDAR-VS-ROLLING 26x IS NOT
  A CODE DEFECT.** Censused every reachable surface by RUNNING it: **no shipped surface takes a calendar-day
  window at all.** Exactly ONE prints a window — `bp cloud deployments`, which pins it client-side, re-prints
  it on `--days`/`--from`/`--to`, and refuses honestly ("Nothing was read: this is NOT a fleet with zero
  failures") — and it 403s for every account. The reachable defects are different and worse: `bp cloud status`
  has **no deploy arm at all** (`grep deploys_failing internal/cli/*.go` = zero); `bp cloud site status` prints
  `status live` / `time to web 31s` / six green ticks on a site whose reachable 200-row window is **74%
  deferred** and names no window over which anyone could contest it; the SPA prints a **ROW COUNT** ("the 12
  most recent deployments") and calls it recency, which on a hot site is minutes and on a cold site is weeks;
  the SPA has **no deferral vocabulary whatsoever** (proven by running the shipped IIFE: `freshnessModel` on a
  deferred row falls to the generic else and returns `dot:"unknown"`, and `siteStatusChip` shows a green
  **Live** chip while the publish waits); and the agent beat reads an envelope carrying `window_s` and DROPS
  the label. **The 26x disagreement is a hazard of the ad-hoc SQL this epic's own leads run, plus a 7-day CLI
  default that straddles D179. It is a discipline defect, not a shipped-code defect, and this charter is where
  it gets fixed.**
- **D209 — THE AFTER NUMBER, TAKEN. It is a CONVENTION-MATCHED PAIR ON ONE PINNED WINDOW, REPORTED PER
  REGIME, NEVER BLENDED.** Guerrilla, production, `2026-08-06T10:00:00Z <= inserted_at < 2026-08-07T10:00:00Z`,
  2,446 attempts, all settled (0 queued/building, 0 preview), cross-checked under a second timestamp column
  (<1% drift). The window STRADDLES the boundary, so it is reported per side and the blend is refused:
  **BEFORE 927 attempts — 433 failed / 217 live / 277 deferred — terminal failure 66.62%, published attempt
  rate 46.71%. AFTER 1,519 attempts — 19 failed / 381 live / 1,119 deferred — terminal failure 4.75%, published
  attempt rate 1.25%.** Held to ONE convention on both ends, **two answers disagree**: the settled-failure rate
  fell **61.87 points**, while the OLD convention that counts a box refusal as a failure fell **1.67 points**
  (76.59% → 74.92%). The entire gap is re-bucketing. **Wave 6's ruling required a convention-matched pair and
  could only report that the two disagree in SIGN; wave 13 is the first wave that can BREAK the tie
  empirically** — a refusal costs a median of 3m32s and loses nothing (D190), so "refusal = failure" is the
  wrong convention and the 61.87-point fall is real. Publish BOTH rows anyway; the 1.67-point row is the
  honesty guard. Dilution is **19.91 points** before the boundary and **3.50** after. The alarm fired 456
  `deployment_failed` deliveries against 452 failed rows (435 pre / 21 post) and **zero** for 1,119 deferrals.
  Demand is computable only from 08:15:26Z (the first `content_publishes` row): **the 24h demand denominator
  DOES NOT EXIST and is not estimated.** Per D3 the absolute collapse (2,394 → 18) is NOT quoted as
  improvement. **This discharges the wave-12 review's "what the next wave should take" — thirteen waves, and
  the AFTER measurement is now on the record.**
- **D210 — WAVE 13 IS ALL OPUS; TWO SLICES ARE HIGH-FLIP-RISK.** Fable remains unavailable fleet-wide, so
  every slice is `opus` at medium and difficulty is expressed in scope. **HIGH-FLIP-RISK: S3** — whether the
  deferral columns can reach the wire without redding the payload census, given that `deployment_json/1` is
  NOT in `@pairs` but `site_deployment_json/3` PIPES THROUGH IT (`router.ex:10836`), so the censused pair sees
  the new keys and the Go tags must ride in the same PR; and whether the column-first read is safe on the
  98.75% of deferred rows whose columns are NULL. **S5** — whether a per-site publish clock is reachable
  without admin AND meaningful for a site the control plane cannot verify has a trigger (D201). Both are owed
  an INDEPENDENT second reviewer before merge; this workflow spawns one, so that dispatch is a manual lead
  step.
- **D211 — WHAT THIS WAVE DELIBERATELY DOES NOT BUILD, WITH REASONS.** (a) **The notification category
  split** — D193 says it is the right ~20-line change over a proven guard, but it crosses CCH wave 45's fence
  (`cloud/priv/static/__app.test.mjs` runs the bidirectional notification census, and `@events` requires the
  producer, both renderer arms and the console vocabulary in ONE PR) and #10019 conflicts on
  `notifications/render.ex`. Filed, not built. (b) **A WAITING alert** — D164 ruled it and `dr-w11-s5` is open
  at 0/9, but post-D179 its population is **empty** (zero uncensored rows waiting an hour). Do not scope an
  alert against a population of zero. (c) **The SPA's deferral vocabulary** — the sharpest site-owner defect
  in D208, and `cloud/priv/static/app.js` is CCH's fence this hour. Filed with the exact anchors. (d) **A
  `bp cloud deployments` renderer for the after-number** — building a reader for a surface that 403s for every
  account is this epic's own disease; it waits on `PLATFORM_ADMIN_EMAILS`. (e) **The escape floor** —
  discharged by #10246 (D205).

### Wave 13 plan — 7 slices, 4 in round 1, file sets disjoint within a round

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | `CLOUD_PATHS` declares the node engine, unblocking #10014 and half of #10155 | `dr-w13-s1-cloud-paths-declares-node-engine` | `scripts/**` | small | opus |
| 2 | 1 | The 503 names the box's own code word instead of blaming the box | `dr-w13-s2-503-names-its-code-word` | `cloud/lib/**` ledger | medium | opus |
| 3 | 1 | The deferral columns reach the wire, with their decoders | `dr-w13-s3-deferral-columns-reach-the-wire` | `cloud/lib/**` router + `internal/cloudclient/**` | medium | opus |
| 4 | 1 | The 503-honesty test stops losing at random inside a required gate | `dr-w13-s4-runner-503-test-stops-flaking` | `api/test/**` | small | opus |
| 5 | 2 | The CLI reads the columns and `site status` names its window and its deferral share | `dr-w13-s5-cli-reads-columns-and-names-its-window` | `internal/cli/**` | medium | opus |
| 6 | 2 | The publish clock gets its first caller, on a surface a site owner reaches | `dr-w13-s6-publish-clock-first-caller` | `cloud/lib/**` clock + router | large | opus |
| 7 | 2 | The census names its residue, and stops being blind to its own per-site rows | `dr-w13-s7-census-residue-and-per-site-blindness` | `cloud/lib/**` ledger + `internal/cloudclient/**` | medium | opus |

**Round 2 dependencies.** S5 AFTER S3 (its column reader is dead code until the serializer emits the keys —
proven: a Go column arm built against a payload that carries no columns is unreachable end-to-end). S6 AFTER
S3 (same handler region in `router.ex`, and S3 settles the payload-census question S6 inherits). S7 AFTER S2
(both edit `deploy_ledger.ex`) **and after #10014 merges** (which supplies `live`/`terminal_failure_rate`/
`basis`, leaving S7 only the residue).

**Merge ordering the lead owns.** Merge #10245, #10246, #9976, #10069 now — all CLEAN, all four required
contexts green, and merging the first two converts two blocked ledger rows into closable ones. Then S1 lands
the `CLOUD_PATHS` line, after which #10014 needs only its three `@known_open` row deletions plus a rebase over
S2. #10155 needs `report-main-failure` added to both aggregators' `needs:` — its own ratchet is correctly
refusing the invariant the PR itself created. #10133 and #10173 need `task-fb4fb869490b4213` re-claimed and a
PUSH (a re-run cannot clear a lease-lapse verdict), and #10173 additionally rebases its charter half over
#10208. #10019 rebases last, over #10200's `render.ex`. Then close the 31 satisfied merge-gated children per
D204 — claim, then close on the NEW epoch, one row at a time.

### Wave 2026-08-07 (wave 13) — REVIEWED · Paper `deploy-reliability-wave-13-2026-08-07` · grade **A−**

**All four round-1 slices built, reviewed, gate-green on their final state, PUSHED and PR'd. Nothing merged — the lead merges.**
Slices 5–7 are round 2 and were not built this run BY DESIGN (sequenced-rounds law).

| Slice | Task | Final branch | PR | Gate on final state |
|---|---|---|---|---|
| `CLOUD_PATHS` declares the node engine | `dr-w13-s1-cloud-paths-declares-node-engine` | `…node-engine-so--0-r` | [#10299](https://github.com/FRIKKern/barkpark/pull/10299) | escape rc=0 (6 reads) · harness 124 passed / 0 failed |
| The 503 names the box's own code word | `dr-w13-s2-503-names-its-code-word` | `…own-code-word-so-1` (unchanged) | [#10300](https://github.com/FRIKKern/barkpark/pull/10300) | 119 tests, 0 failures |
| The deferral columns reach the wire | `dr-w13-s3-deferral-columns-reach-the-wire` | `…reach-the-wire-with-2` (unchanged) | [#10301](https://github.com/FRIKKern/barkpark/pull/10301) | 176 tests, 0 failures · go build/vet/test ok |
| The runner-503 honesty test stops flaking | `dr-w13-s4-runner-503-test-stops-flaking` | `…test-stops-losing-3` (unchanged) | [#10302](https://github.com/FRIKKern/barkpark/pull/10302) | 30 tests, 0 failures · 15 further seeds, 0 failures |

**What landed.** The wave is squarely on the wish's two live clauses — *still mis-reported* and *make the
reporting able to lose*. S2 retires the epic's largest surviving lie: `BOX_UNAVAILABLE_503` had exactly ONE
distinct `failure_reason` in its whole life (265 rows, all `feature_not_configured`, all written by a box that
was demonstrably UP), and it now splits on the box's own code word into `BOX_DEPLOY_DISABLED_503` /
`BOX_RUNNER_UNAVAILABLE_503`, with an unnamed 503 deliberately NOT promoted. S3 gives the wave-12 deferral
writer its first reader — the three columns reach the wire from the sole base serializer AND land in
`cloudclient.SiteDeployment` as pointers, so a wait becomes data instead of English a regex must guess at, and
`nil` stays `nil` rather than becoming a false "deferred zero times". S4 removes a guard that lost AT RANDOM
inside a required gate: the 1ms-budget race against the real Runner is replaced by a door that cannot answer,
so the assertion can only fail for the right reason. S1 unblocks #10014's Cloud gate with the one line the
ratchet itself named.

**What did NOT land.** Nothing is merged, so no AFTER number moved this wave — and S2's class is DORMANT
(zero rows since 2026-08-07 03:19:21Z), which the PR body states rather than dressing the traffic drop as the
fix. The CLI still parses English for a deferral's depth until S5 lands. And the reviewer's own mutation
confirmed S1's declaration is currently UNEXERCISED by the census half of the ratchet on `main` (the read that
demands it lives on #10014) — the proof is #10014's gate after the rebase, not this branch.

**Review fixes made in place.** One, on S1's `-r` branch: case 1 of `cloud-path-escape-check.test.sh` asserted
`-ge 4` with the parenthetical "measured population is 4" while `CLOUD_ESCAPE_MIN` has been 6 — a
weaker-than-the-floor assertion carrying a stale number. Re-pinned to the measured 6. S2, S3 and S4 needed no
fix; their branches are pushed unchanged.

**Independent re-derivations the reviewer ran** (not re-reads of builder reasoning): renaming S3's Go tag REDS
the payload census with "new phantom … deferral_depth_MUT", proving the census genuinely walks
`site_deployment_json/3 → deployment_json/1` and that both halves must ship together; probing `@go_tag_floor`
reports **218** tags, so the new floor is measured equality, not slack; and commenting out S4's interceptor
REDS with a 202, proving both that the door is load-bearing and that this box wins the race the old test bet
on losing.

**What the next wave should take.** Round 2, in dependency order as each dep merges: S5 (`dr-w13-s5`) and S6
(`dr-w13-s6`) once S3 (#10301) is in; S7 (`dr-w13-s7`) once S2 (#10300) and #10014 are in. Then the residue
this wave surfaced and refused to swallow: `dr-w13-followup-poll-phase-refusal-unclassified` — POLL-phase box
refusals write "refused the build poll", which matches NEITHER anchor, so an entire producer phase classifies
UNCLASSIFIED at both 409 and 503. That is the wish's "still silent" in its purest form and it is now the
largest known blind spot in the taxonomy.

## Wave 14 — the owner's own numbers, and a gauge that can lose (2026-08-07)

Wave 13's PRs all merged (#10268, #10299, #10300, #10301, #10302); #10014 is CLOSED; #10129 alone is still
open. `origin/main` = `77cf2060c` at Decide time. **The provenance hazard wave 14 opened with is
DISCHARGED**: D190–D211 are charter law on `main`, not a claim on a branch. Every one this wave leans on was
re-git-shown and read for coverage before it reached a slice.

The binding constraint moved twice this wave, and the second move was the one that mattered. It is no longer
"terminal deploys fail" — post-boundary terminal failure is **1.27% on 2026-08-07 (18 of 1,423)** against
**52.99% pre-boundary**. It is that every number this epic produced is trapped behind an admin gate, that the
one owner-facing paragraph a site owner can actually run is **denominator-free and, in one clause,
affirmatively false**, and that the taxonomy certifying all of it **cannot see a wrong name** — proven by
mutation, on `main`, today.

Three verification results reframed the wave before a single slice was cut. They are the wave's spine.


### The three that reframed it

**The abandonment is BENIGN SUPERSESSION, and the crux the digest called "the single highest-value unknown"
is settled.** Restrict the chain census to SETTLED chains (last row older than 30 minutes) and it collapses:
`227 abandoned_settled | 227 with_later_live | 0 without_later_live`. The two chains that appeared to have no
later live row were **in flight** — both went live with the SAME `content_rev` within two minutes of the first
read (astro-search 12:31:47Z, live-auto 12:30:46Z), and the raw count drifted 230→229→228→227 across
successive queries in one `psql` session. Anyone measuring that table without a settling clause measures their
own query latency. The pre/post comparison that motivated the alarm is **invalid by construction**: there are
ZERO deferred rows before the boundary (first ever 2026-08-05 21:27:11), so a "5.8% → 34.4% rise across the
repair" measures a status that did not exist before the repair. Pre-boundary every 409 settled `failed`
(8,081 rows over 19 days); post-boundary the same population splits **1,934 `deferred` / 7 `failed`**. The
repair did not trade terminal failures for silent abandonment — it converted terminal failures into deferrals
that then went live.

**The provenance label is REFUTED, and the attack that won the direction debate turned out to name an axis
that does not exist.** 27 teams; 13 sites; **exactly ONE team owns any site**. A label saying "customer vs
platform" would assert an ownership distinction the `teams` table refutes — the same error class as calling an
UP box unavailable. The measurable axis is AMPLIFIED vs UNIQUE and it is derivable today by query
(`content_rev` + `site_id`, no column, no migration, 0 of 30,819 rows have a null `site_id`) — but it **does
not separate populations**: AFTER the boundary, UNIQUE rows fail at 2.20% (n=91), FANOUT siblings at 0.00%
(n=318), RETRY siblings at 1.80% (n=1,112). The churn is not a different failure population; it is the same
population counted 14.6 times.

**The gauge earns its keep as a ROT-GUARD, not as a detector — and the proof is that main's own suite stays
green while wave 13's repair is destroyed.** Set `BOX_DEPLOY_DISABLED_503`'s label to the collapse sentence
("the box refused with a 503 it did not name a cause for") and run `origin/main`'s OWN `deploy_ledger_test.exs`
byte-identical from `git show`: **50 tests, 0 failures. GREEN.** The class names still differ, the classifier
arms still fire, `refute label(...) =~ "unavailable"` still passes — and the operator now reads the same
causeless sentence for a switched-off deploy flag as for a 503 nobody could name. The 265-row disease was
never "the class name was wrong"; it was "the SENTENCE was wrong", and nothing on `main` guards sentences.


### Decisions

- **D212 — THE 148-CHAIN ABANDONMENT IS BENIGN SUPERSESSION; MOVEMENT 5 IS A NAME, NOT A LOSS REMEDY.**
  Settled-chain census: 227 abandoned / 227 with a later live row on the same site / **0 without**. `content_rev`
  is a **state hash of the site's currently-published projection**, not a per-publish revision
  (`content_rev_probe/2` sha256s `[doc_type, published_count, published_events]`), and `defer/3` calls
  `requeue_rebuild(site.id)` — site_id and nothing else — so a re-queued deferral does not inherit its parent's
  rev, it re-probes it. `(site_id, content_rev)` is a COINCIDENCE key that holds while content is unchanged and
  breaks the instant a new publish lands, which IS supersession. 0 of 228 abandoned chains ever see their own
  rev go live; 225 of 229 see a DIFFERENT, NEWER rev go live — and because the projection is cumulative, the
  newer rev *contains* what the deferred attempt would have carried. The fence corpus (7 rows all-time,
  D174 re-derived exactly) and the "abandoned chain" corpus overlap by **zero BY CONSTRUCTION** — the chain
  query requires `failed_rows = 0`, so a fence row's chain can never be one. **RULING: no loss remedy, no new
  alert, no notification-category split this wave.** The owner-facing defect that survives is the CLI clause in
  D213, and it is worth more than the alarm would have been.

- **D213 — THE SINGLE MOST REASSURING CLAUSE IN THE OWNER PARAGRAPH IS THE ONE THE DATA CONTRADICTS.**
  `cloud_site_cmd.go:1559`/`:1561` assert `(a rebuild is already re-queued)` **unconditionally** on any deferred
  newest row, and the source comment says so out loud: "the difference being that this one is re-queued, not
  lost". The CLI cannot verify that. On site `search`, **47 of 523 `content_rev` chains** across its full
  2,000-row history are deferred-only with no live and no failed row, and `bp cloud site status search -o table`
  prints a fully green paragraph whose `grep -icE "abandon|supersed|chain"` returns **0**. **RULING: the clause
  is CONDITIONAL or it is deleted.** Assert a re-queue only where the read page shows one, and say what the page
  can and cannot see otherwise. This is owner-facing, reachable today, and provably wrong — a better anchor for
  movement 5 than the notification arm ever was.

- **D214 — D200's PERCENTILE BAN IS SCOPED TO THE PUBLISH CLOCK'S LATERAL AND DOES NOT REACH THE
  DEFERRAL-WAIT MEDIAN.** D200's warrant is one measured defect — `PublishClock`'s `LEFT JOIN LATERAL` is
  bounded below and not above (`dr-w12-rv-publish-clock-match-ceiling`), so an unbounded cross-table match
  enters a per-site percentile as a real 20-day measurement — and `grep -n 'D200'` over this charter returns
  **exactly one line, its own**: no decision narrows or widens it, and D190/D191/D201 are each scoped to
  time-to-web. A deferral wait is a different quantity with a different key: D142's journey — "a maximal run
  over `(site_id ORDER BY inserted_at)` terminated by the next live/failed row" — is already ruled BUILDABLE
  and already published as a median (fleet TTL p50 0.0 s, contended p50 183 s), bounded above by a row the
  reader has already read. **RULING: `bp cloud site status` MAY print a deferral-wait median, under three
  conditions D200's own remedy supplies — (a) segmented by RUN, never by rev group (D142); (b) the still-open
  newest chain, any chain the page truncated, and every abandoned chain are NOT dropped but reported as a
  censored `waiting >= Xs` lower bound beside a page-ran-out marker (D163; `main` already ships this shape as
  `latest_waiting_seconds_at_least`); (c) it carries window + unit + denominator (D191, D3). D142's and D174's
  refusal of any chain-derived RATE stands unchanged — no key may contain `rate` or `percent`. D200's
  `MUST NOT SHIP PERCENTILES` continues to bind every publish→web figure without exception.**

- **D215 — D200's THREE SQL CONSTANTS ARE TWO, AND THREADING THE THIRD IS ACTIVELY DANGEROUS.** Measured:
  `@live_sites_sql` is consumed ONLY as `MapSet.member?(live_sites, row.site_id)` in `classify/3` — a
  membership test keyed on the row's own site, so a set containing other sites cannot change any row's bucket.
  Proven at run: site D (a publish, never live) with site E live in the same window classified
  `site_never_live=1` **identically** in the fleet census and in D's own per-site census. Scoping it while the
  guard is `became_live_at >= from` risks collapsing the `never_delivered` / `site_never_live` distinction —
  the one distinction that bucket exists to protect. **RULING: thread `@census_sql` (semantic, required) and
  `@live_deploys_sql` (kills the fabrication D200 names); leave `@live_sites_sql`, `@seek_bound_sql` and
  `@recorder_since_sql` fleet-wide.** Three mechanical facts a builder will otherwise discover the hard way:
  threading reds `publish_clock_test.exs:114` on **parameter arity, not the pin** (`ArgumentError: parameters
  must be of length 3`) — a one-line fix, `[naive(@from), naive(@to), nil]`; raw `Repo.query!` rejects a
  site-id string (`DBConnection.EncodeError: Postgrex expected a binary of 16 bytes`) so the builder must
  `Ecto.UUID.dump!/1` at the boundary; and D200's parting sentence is true of the pin and MISLEADING about the
  suite.

- **D216 — THE PINNED-SQL TEST IS A HALF GUARD, AND THE HALF IT IS MISSING IS THE HALF THIS WAVE EXERCISES.**
  Three mutations settle it. Appending the harmless `AND p.doc_type = 'paper'` → **11 tests, 0 failures**.
  Appending `AND p.doc_type = 'zzz-no-such-type'`, which DESTROYS the query's answer → **6 of 11 behavioral
  tests red, and the pin test is NOT among the six** — it stayed green while the query it certifies returned
  nothing. Deleting `AND dd.inserted_at >= p.received_at` → 2 of 11 red, one of them the pin (reproducing this
  charter's own line 3690). **The pin catches REMOVAL of a pinned string and is structurally blind to ADDITION
  of anything.** It is not a vacuous guard; it is a HALF guard, and it is the epic's own disease in the narrow
  sense. **RULING: whoever threads `@census_sql` strengthens the pin in the same PR, with an equality-shaped
  assertion (normalized-whitespace equality, or an assertion that the WHERE clause's predicate LIST is exactly
  what is expected) — never another `=~`.**

- **D217 — THE LABEL-CONSISTENCY GAUGE IS A ROT-GUARD, NOT A DETECTOR, AND IT IS JUSTIFIED ON THAT.** Both
  assertions are GREEN on `origin/main` today (53 tests, 0 failures) — the taxonomy IS label-consistent, so
  the movement dies if the question is "does a lie survive today?". It does not die on the real question. The
  decisive proof: `main`'s own 50-test file stays GREEN while `BOX_DEPLOY_DISABLED_503` wears the collapse
  sentence, i.e. **wave 13's repair is one careless label edit from being undone silently**. And rebuilding the
  pre-#10300 tree from `git show f89140090^` reds ASSERTION B with the exact 265-row sentence:
  `start/503: BOX_UNAVAILABLE_503 ("the box was unavailable (HTTP 503)") claims "unavailable" — but also holds
  deploy_runner_unavailable and 5 other cause(s)`. Four design facts are LAW for the builder, each of which
  cost a red or a false positive to find: **(a) the vocabulary must NOT come from the classifier** — scraping
  `{:code, "…"}` out of `deploy_ledger.ex` is vacuous by construction, because a mutation that deletes the arm
  deletes the literal too; scrape from the PRODUCER's own test file (`sites_deploy_test.exs`, `"code" => "…"`),
  which is the box's proven wire vocabulary and which no classifier edit can shrink. **(b) probe only
  producer-writable (phase, status) shapes** — `Sites.Deploy` DEFERS every 409 (`deploy.ex:678`), so a terminal
  plain 409 is a row that cannot exist and probing it manufactures a finding against `BOX_BUSY_409` no operator
  will ever see. **(c) tokens, not substrings** — `BOX_500`'s "the box **errored**" was read as claiming
  `internal_error`. **(d) "generic" is DERIVED from `@labels` at runtime, never hand-listed** — a hand-list is
  a third place someone must remember to edit. Two live findings fall out with the declaration list empty:
  `internal_error` is correctly unnamed (the authorless crash constant), `runner_start_failed` is NOT — nobody
  ever decided that, and the gauge's value is that it forces the decision to be WRITTEN.

- **D218 — THE POLL 409 IS UNREACHABLE, `deploy.ex:1418` IS NOT DEAD CODE, AND THE FIX IS THE ANCHOR.** Two
  independent proofs that no poll-phase 409 can arrive: the CONSUMER has no 409 arm and no `defer/3` call
  anywhere in `poll/4` (`deploy.ex:894-960`) — a 409 falls to the catch-all and goes terminal, verified by
  programming one into `FakeBoxRelay` (row settles `failed`, `classify/1` = `UNCLASSIFIED`); and the PRODUCER
  cannot emit one — `SiteDeployController.status/2` answers only 200/400/404, both `put_status(:conflict)`
  sites are in `trigger/2`, and `git log -S':conflict'` returns exactly the two commits that added them. **But
  the phase split is LIVE**: a persistent UNTYPED 500 exhausts `site_deploy_poll_grace` (45 in prod) and falls
  out of the guarded arm into the same catch-all, reproduced at run — reason `"the instance refused the build
  poll (HTTP 500): internal_error … (after tolerating 3 transient box 5xx…)"`, `classify/1` = `UNCLASSIFIED`.
  Both `@refusal` (`:284`) and `@deferral_prefix` (`:450`) anchor on "refused the deploy", so the poll caption
  matches NEITHER — doubly blind. **RULING: widen the anchors to accept the poll phase and keep the phase in
  the class; do NOT delete the split, and do NOT claim rows are mis-reported today (zero poll rows all-time,
  D208 stands).** And `sites_deploy_test.exs:1360-1382` — the one test exercising the poll caption — produces
  it by programming a poll answer of **503 `feature_not_configured`, which the real box cannot emit** (unlike
  `trigger/2`, `status/2` has no `DeployRunner.enabled?()` gate). Re-shape it onto the reachable
  5xx-grace-exhaustion path, or the taxonomy gains a green from a case the producer cannot make.

- **D219 — THE OWNER'S READ IS SESSION-ONLY, AND THAT IS PINNED THIS WAVE, NOT FIXED.** `GET
  /v1/sites/:id/deployments` and `GET /v1/sites/:id` are role-BLIND by construction — the list route is wrapped
  in the 2-arity `with_team_site` which defaults to `:session` (`router.ex:11065`) and NEVER consults a role;
  `resolve_team/2` requires only MEMBERSHIP. A plain `member` gets **200** from both (proven at run). But a read
  PAT gets **401** from both, while the single-deployment poll `GET /v1/sites/:id/deployments/:dep_id`
  (`{:ability, "read"}`) returns **200** on the same real row — a credential-class refusal, not a role one.
  Consequence: **no CI or automation credential can ever compute the owner's number**, because `bp cloud site
  status` reads the ledger through the session-only list route. **RULING: no acceptance criterion anywhere in
  this epic may be phrased as "a CI job / automation proves the number". The member reachability gets a guard
  that can LOSE this wave — mutation-proven, since prepending `Auth.require_team_admin` reds ONLY a new probe
  while all 101 pre-existing tests stay green (`user_with_team/0` hardcodes `owner`). Re-tiering the list route
  to `{:ability, "read"}` is INSIDE cloud-console-hardening's auth fence and needs a cross-epic ruling, not a
  builder decision — it is filed, not built.**

- **D220 — THE FORMAT TRAP: SEVENTEEN REPORTS NEVER QUOTED THE OWNER PARAGRAPH BECAUSE IT IS INVISIBLE TO
  EVERY NON-INTERACTIVE CALLER.** `internal/cli/output.go:74-80`: an explicit `-o` wins, otherwise
  `isTTY ? "table" : "json"`. Every piped, `tee`'d or agent-captured run of `bp cloud site status` gets raw
  JSON. **RULING: every proof, every builder run and every acceptance criterion in this epic that quotes the
  human paragraph uses `bp cloud site status <site> -o table`.** A test capturing stdout without it asserts
  against JSON and passes while the paragraph it claims to fix is untouched — a live vacuous-green hazard for
  every reader slice. This is the seventh standing-test clause wearing a new coat: a guard fed an envelope its
  producer never emits.

- **D221 — THE READER KEEPS ITS PROSE FALLBACK, AND THE CENSUS IS A SIBLING NODE, NOT A `staleness` KEY.**
  `deferral_depth`/`bound`/`cause` are populated on **116 of 1,934 post-boundary deferred rows (6.0%)**, first
  stamped 2026-08-07 10:12:35Z — the #10268 deploy — so the boundary is a hard step function (NULL ⟺ the row
  predates that instant), not a partial mush. A column-first reader over a pre-boundary window is 100% NULL,
  not diluted. Two guard shapes decided by mutation, both narrower than the digest stated: `cloud_site_cmd_test.go`
  bans envelope keys containing the substrings `"rate"` or `"percent"` — **`"share"` contains neither**, so
  s5's phrase collides only if the builder spells it `deferral_rate`; and the `deferral_depth` ban is a
  **substring scan over the whole serialized JSON stdout**, so it constrains ANY new node, not just
  `siteStalenessMap`. `renderKV` sorts alphabetically and pads to the widest key, so census counts as KV rows
  would scatter among unrelated site metadata AND widen every row. **RULING: the census renders as its own
  block after the KV table (the shape `stages:` already uses) and as its own JSON sibling
  (`payload["window"]`); the typed arm treats `depth < 1` or `bound < 1` as no-chain rather than falling back
  to a regex that would contradict the column. And note that NO Go test enforces D200/D214 today — a builder
  resolving the median wrong will not be caught by the guards the survey pinned, so the median ships with its
  own new guard or it does not ship.**

- **D222 — THE PER-SITE SAMPLE FLOOR IS CLEARED TODAY AND THAT IS THE WRONG THING TO BUILD AGAINST.** All five
  publishing sites read 22–23 delivered inside the recorder's first 4h11m — every one clears `@min_sample` 20,
  refuting the premise that the refusal branch is the only branch. But the prior ledger recipe measured 13–14
  two hours earlier: the population moved 60% in under two hours, so **any slice hard-coding today's answer is
  wrong within a shift**. What decides the refusal is the WINDOW, and the margin is 3: 1h → n=7 (refused),
  6h/24h → n=23 (passes). And the five samples are not five samples — 22 of 24 publish bursts are exactly five
  rows in one second, so every site sees the SAME 23 human publishes fanned out 5x. **RULING: the node COMPUTES
  the refusal, never assumes it either way; it NAMES its window beside the sample; and D201's refusal
  population is **8 of 13 sites, not 5** — seven carry no content-webhook secret at all and `auto-proof`
  carries a secret with no guerrilla webhook, so for all eight "we cannot verify your publish trigger from
  here" is the ONLY branch and it is PERMANENT. Drive that refusal from the site's own secret presence, not
  from "zero rows this window" — a webhook-bound site that had a quiet day deserves a different sentence.**

- **D223 — THE PROVENANCE LABEL IS NOT BUILT, AND MOVEMENT 4 CLOSES BY RULING.** D206 rules the demand cut
  FILED and makes the label a PRECONDITION of that cut — it does not authorise building it, so the label needed
  a fresh wave-14 ruling and this is it. There is no customer/platform axis (one team owns all 13 sites; 26 of
  27 teams own zero). The AMPLIFIED/UNIQUE axis is derivable at query time and does **not** separate
  populations. The three denominators over D209's own pinned window: ATTEMPT 452/2,446 = **18.48%**, CHAIN
  125/653 = **19.14%**, UNIQUE PUBLISH 16/163 = **9.82%** — and the unique-publish denominator of 163 is
  **below `@min_sample` 200**, so it structurally cannot publish as a rate at 24h; 72h (386) is the first width
  that clears the floor and it straddles D179. Amplification decomposes cleanly: 3.64x retry × 4.01x fan-out =
  14.60, against a measured 14.59, cross-checked by a second method (`content_publishes` has exactly 5 distinct
  `site_id`s ever). **RULING: no label, no column, no migration. Publish the ATTEMPT rate — the only one that
  clears the floor at 24h — bound to a caveat naming the fan-out, the retry factor, the distinct-revision count
  and the refusal:** *"N of M build attempts failed between <from> and <to>. Those attempts carry only R
  distinct content revisions across S auto-publishing sites — A attempts per revision (Fx fan-out to sibling
  sites, Rx retry within a site) — so this is a rate of ATTEMPTS, not of publishes. Per revision it is P%,
  which we do not publish as a rate because R is below our 200-sample floor."* Every clause computes from the
  row set the arm already reads. **A caveat naming tenancy would be the same error class as calling an UP box
  unavailable.** One genuine finding survives for the backlog: under the unique-publish unit, 8 of 163
  publishes (4.91%) end with neither a live nor a failed row — a population the attempt unit structurally
  cannot see, and right-censored at the window edge, so it is an UPPER bound.

- **D224 — #10129's MERGED LADDER IS THIRTEEN RUNGS WITH `unmetered` AT 9, AND ITS CLEAN ELIXIR AUTO-MERGE IS
  SEMANTICALLY BROKEN.** D202's mechanical prediction reproduced EXACTLY at L1: six conflicts, all Go/JSON;
  `deploy_ledger.ex` and `router.ex` auto-merge. All six resolve by UNION — `semrole.go` in particular KEEPS
  `strained`/`filling`/`unreported`, which take-theirs would delete. `unmetered` at rank 9 is an EXTENSION of
  D202 (which fixes only `deploys_failing`=5 and `unmetered`'s tone), ruled here on two grounds: bucket
  contiguity is restored (attention becomes the unbroken run 1–10, where the PR broke it for the first time),
  and tone monotonicity is preserved (`semrole.go`'s own comment makes non-monotone tone the forbidden
  outcome). **And the clean auto-merge is BROKEN BY IT**: `main` landed the 503 split into `@classes` after
  #10129 branched, while #10129's `@agency` map knows only the retired `BOX_UNAVAILABLE_503` — 19 classes
  against 17 agency keys. Git had no textual conflict to raise (one side added to a list, the other added a
  map). `deploy_ledger_test.exs:1881` reds on both new classes; **had that guard not existed, both would have
  fallen to `:ambiguous`, shrinking the box-caused numerator in D148's forbidden direction over precisely the
  265-row population D196 is about.** That is the strongest argument for this epic's own thesis, found inside
  this epic's own PR: a merge that conflicts nowhere, builds, and passes the Go suite can still degrade a
  number, and the only thing that catches it is a guard asserting a PROPERTY rather than a value. **RULING:
  `unmetered` = rank 9; `@agency` gains both new classes as `:box`; a name-filtered `go test -run 'Attention'`
  is FORBIDDEN as proof — it reports GREEN against a corrupted `expected_order` because the consumer is
  `TestRankBarkparksFixture`. Run the full package.**

- **D225 — THE CLOSABLE SET IS 54, NOT 38, AND THE 409 IS THE HOLDER GATE, NOT THE FENCE.** 232 `dr-*` rows,
  218 open, **54 one-short** (D204's 38 is superseded; wave 12's own order to sweep is itself still open and
  unclaimed, and the backlog grew by 16 rows in the two waves since). Split: **39 cleanly closable** (sole
  unmet criterion is the merge gate and a PR whose body ends `Task: <slug>` is MERGED), **3 merge-satisfied but
  blocked** (`dr-w3-s5` + `dr-w5-s1` demand "an independent second review" and #9827/#9887 each report
  `reviews=0 comments=0`; `dr-w11-s7` demands an end-of-wave census re-run), **2 behind an OPEN PR**, **10
  correctly open**. The 409 characterisation in the direction was wrong three ways: there are **2** fenced
  holds, not 16 (both held by `dr-w6-s3-ledger-repair`, both carrying a claim map with no lease-expiry key at
  all); the refusal is the HOLDER gate and it fires on **43 of 54**, because `close_holder/2` treats
  `claim.previous_worker` as the holder when `claim.worker` is nil — a REAPED claim refuses a fresh worker name
  too, WITH the correct epoch (proven at run: `409 not_holder:epic-builder-the-runner-503-honesty-test-stops-losing`);
  and they are recoverable, because the refusal names its own remedy in prose. **RULING: the sweep is a LEAD
  act, not a builder slice** (merge-gated criteria are the lead's by contract) — re-claim for a fresh epoch,
  stamp, close as holder for the 42 reaped rows; `--set holder_override="…"` for the 2 live-held rows, which
  have no re-claim path at all (`bp task release` is holder-gated with no override). Two rows are invisible to
  a slug-join and need a criterion-TEXT read (`dr-w12-s1-unblock-10192-allowlist-row`, `dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures`).
  Two instrument defects fall out and are filed: the wrong-epoch 409 is a **bare `{"ok":false,"reason":"fenced_off"}`
  with no message, no current epoch and no remedy** while `not_holder` carries a 60-word remedy — an
  asymmetry that is itself a reporting-cannot-lose defect in this epic's own tooling; and
  `api/lib/barkpark/plugins/tasks.ex:774` still serves *"Unmet criteria never block a close (soft warning
  only)."*, which is false for `done` and already recorded as D78 in the mobile charter since 2026-07-28.

- **D226 — TWO METHOD TRAPS THAT MANUFACTURED CLEAN, UNIFORM, ENTIRELY FALSE ANSWERS THIS WAVE.**
  `gh search prs "<slug>"` matches TOKENS, not the slug: it returned a plausible, title-similar PR for 44 of 54
  rows, and verifying the body verbatim (`gh api search/issues -f q='… "<slug>" in:body'`) reduced that to 42
  real links and turned 2 into honest zeroes. And **`gh pr view` from a non-git cwd exits 1 on stderr and
  prints NOTHING to stdout** — a first pass run from the scratchpad reported "0 of 44 PRs name their slug", a
  clean uniform refutation that was fabricated by the tool's silence. This is the same bug D204 recorded for
  `gh pr list --search`, in a second verb. **RULING: a uniform-looking result across a heterogeneous population
  is a TELL, not a finding. Any `gh` call in this epic runs from inside the repo and is cross-checked by a
  second method before it reaches a number.**

- **D227 — WAVE 14 IS ALL OPUS; THREE SLICES ARE HIGH-FLIP-RISK.** Fable remains unavailable fleet-wide, so
  every builder is `opus` at medium regardless of the two-axis rule — recorded so the model column is read as a
  constraint, not a judgment. High-flip-risk, each stated in its own brief and re-derived independently by the
  reviewer: **S1** (whether a deferred row's rebuild is genuinely re-queued — the judgment D213 turns on),
  **S2** (reachability without admin, and meaningfulness for a site whose trigger the control plane cannot
  verify), **S4** (tenancy/auth reachability of the owner's own read). An INDEPENDENT second reviewer is
  warranted on all three before merge; this workflow spawns one reviewer, so that dispatch is a MANUAL LEAD
  step.

- **D228 — WHAT WAVE 14 DELIBERATELY DOES NOT BUILD, WITH REASONS.** (a) **The provenance label** — D223, the
  axis is refuted. (b) **A WAITING alert or any abandonment alarm** — D212, the population self-heals in every
  observed instance and D164 already forbade a failure alert; alert copy asserting the publish was lost would
  be false on 7 of 7 and unfalsifiable on 0 of 7. (c) **The notification-category split** — D212 removes its
  justification, and it remains a five-surface atomic commit behind `__app.test.mjs`'s unconditional
  bidirectional census. (d) **Re-tiering the list route for PATs** — D219, inside CCH's auth fence. (e)
  **Raising `@build_slot_capacity`** — D180 stands. (f) **Cutting the webhook amplifier** — D206/D223; the cut
  is filed and its precondition is now ruled unbuildable, so the cut needs a fresh argument, not a label. (g)
  **`cloud/priv/static/app.js`, `web/auth.ex`, `router.ex`'s auth region** — CCH's fence. (h) **The
  `newest-failed-over-an-older-live` case** — the population is EMPTY across all 13 sites, so a slice claiming
  to fix it has no live specimen and a builder given that criterion would fabricate a pass; it is re-scoped to
  a fixture proof or not asserted at all.


### Wave 14 plan — 6 slices, 4 in round 1, file sets disjoint within a round

Round 1 file sets are disjoint by construction: S1 owns `internal/cli/cloud_site_cmd*`, S2 owns
`publish_clock*` plus `router.ex`'s `/v1/sites/:id/deployments` handler region, S3 owns `deploy_ledger.ex`
plus the two producer/ledger test files, S4 owns two `cloud/test/**/web/` files. S5 and S6 are round 2 and are
NOT built this run (sequenced-rounds law) because both write `deploy_ledger.ex` behind S3.

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | The CLI names its window, reads the columns, and stops promising a rebuild it cannot see | `dr-w13-s5-cli-reads-columns-and-names-its-window` | `internal/cli/**` | large | opus |
| 2 | 1 | The publish clock gets a per-site caller, and stops quoting the fleet's denominator at one site's zero | `dr-w13-s6-publish-clock-first-caller` | `cloud/lib/**` clock + router | large | opus |
| 3 | 1 | The gauge sees a wrong NAME, and the POLL phase stops writing prose no anchor can match | `dr-w14-s3-gauge-sees-a-wrong-name` | `cloud/lib/**` ledger + tests | medium | opus |
| 4 | 1 | The owner's own read gets a guard that can lose, and the PAT refusal is pinned as contract | `task-75c2447b6b1eccb9` | `cloud/test/**/web/` | small | opus |
| 5 | 2 | #10129 lands: thirteen rungs, `@agency` exhaustive, the fleet window PINNED and the amplification named | `dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window` | `internal/cli/**` + `cloud/lib/**` | large | opus |
| 6 | 2 | The census names its residue and stops being blind to its own per-site rows | `dr-w13-s7-census-residue-and-per-site-blindness` | `cloud/lib/**` ledger + `internal/cloudclient/**` | medium | opus |

**Round 2 dependencies.** S5 AFTER S2 and S3 merge — S3 rewrites `deploy_ledger.ex`'s anchors and S5's
`@agency` repair lands in the same module, and S2 owns the other region of `router.ex`. S6 AFTER S5 — both
write `deploy_ledger.ex` and `internal/cloudclient/client.go`.

**The lead's own acts this wave, which no builder can do.** Merge #10129 after S5 rebases it. Then the D225
sweep: 39 cleanly closable rows, re-claim → stamp → close as holder; `holder_override` for the two live-held
rows; a criterion-TEXT read for the two rows a slug-join cannot see; and DO NOT stamp the 25 rows whose
criterion demands "green on the MERGE COMMIT" until that wording is reworded to the satisfiable
`statusCheckRollup` form — `gh` reports the HEAD commit, so those 25 closes would be stamped against a proxy.

**The measurement discipline this wave adds to the standing list.** A live table settles: any census over
`deployments` carries `last_at < now() - interval '30 minutes'` or it measures its own query latency (proven —
the count drifted 230→227 inside one session). A rate names its window or it is not a rate (proven — the same
population reads 25.56% over the full post-boundary window and 1.27% on 2026-08-07, and the OLD convention
reads 74.52% post-boundary against 77.81% pre, i.e. it is structurally blind to the entire repair). And a
human-facing CLI paragraph is read with `-o table` or it is not read at all (D220).

## Wave 15 — a rate cannot see an incident, and the incident was never there

Wave 15's thesis was CAPABILITY / CAUSE / EPISODE with the BOX as the unit. Verification killed one leg
outright, resized a second by a factor of 138, and left the third standing on a charter ruling that was made
in wave 8 and never merged. What follows is what the evidence said, not what the direction wanted.

- **D229 — THE REFUSAL VOCABULARY CHANGED ON 2026-08-05, SO NO FAILURE-RATE COMPARISON MAY SPAN IT.**
  `@statuses` gained `deferred` at `2154e695f` (2026-08-05, `#9615`); exactly two commits ever touched the
  token in `deployment.ex`; and production has ZERO `deferred` rows before `2026-08-05 21:27:11.41321`.
  Before that date the schema COULD NOT EXPRESS A REFUSAL, so every refusal was written `failed`. Therefore
  the epic's headline `66.62% → 4.75%` compares two different label systems, and no amount of
  convention-matching repairs it — the convention itself changed. Exactly one quantity survives intact:
  **`live`-per-attempt**, because its numerator and denominator are both independent of how a refusal is
  labelled. Measured, daily: 08-01 **12.81%** → 08-06 **25.67%** → 08-07 **26.17%**, and 08-06's absolute
  live count (566) is DOUBLE 08-01's (284) at identical attempt volume (2,205 vs 2,217), so it is neither a
  denominator artefact nor a demand artefact. **The epic's real achievement is that `live`-per-attempt
  DOUBLED, and it is being mis-sold as a 61-point failure fall.** LAW: any number in this charter, in
  `bp cloud deployments`, or in a wave Paper that compares failure rates across 2026-08-05 is void.

- **D230 — D179's RECOVERY ATTRIBUTION IS CORRECTED; D209's CONVENTION RULING SURVIVES.** Across D179's own
  `2026-08-06 22:19:52Z` boundary, re-derived over three different windows and two aggregations (a daily
  census never bucketed to hours, plus a single boundary split over a window that is NOT D209's), failed-per-
  attempt falls **45.09 points** while live-per-attempt falls **3.92** — BEFORE 1,171 att / 349 live / 543
  failed / 279 deferred; AFTER 1,797 / 465 / 23 / 1,308. **520 rows changed their label; approximately zero
  additional sites reached the web.** D209's ruling that a refusal is not a failure is SUPPORTED by this data
  and must not be reopened; the correction is one of ATTRIBUTION only. The real live-output step sits at
  `08-05 21:00Z → 08-06 04:00Z` (hourly live_pct 10.6 → 32.8 → 39.8 → … → 72.1), coincident with the first
  deferred row. That is LOCATION, not cause: several things merged that day and none was isolated. Crediting
  `2154e695f` for the doubling would repeat D179's own attribution error one commit over.

- **D231 — THERE IS NO EPISODE TO DETECT. LEG 3 IS KILLED AS DESIGNED.** Four independent refutations, any
  one sufficient. (a) **No quiet baseline exists.** 2026-08-01→08-04 ran **87.11% failed over 82 hours**
  (5,836 att / 5,084 failed / 752 live) with live throughput flat at ~12.9% and NO interior transition — the
  window IS the regime, and the same 11-18% live band runs unbroken back through 07-28. The direction's
  "twelve-hour episode" (08-06 08:00-20:00, max hourly failure 83.0%) is a regime TAIL: 08-06's own
  00:00-03:00Z hours ran 94.1/91.6/85.7/66.0%, HIGHER than any hour of it. (b) **The obvious fixture is a
  trap.** That window contains 11 zero-live hours which look exactly like an outage signature; **all eleven
  carry `att = 1`** (overnight heartbeats). A detector without a per-bucket volume floor manufactures eleven
  fake episodes and calls itself validated. (c) **`@min_sample` makes an hourly rate detector silent by
  construction.** The floor is 200; every one of the twelve hourly buckets of the alleged episode is below it
  on BOTH denominators (max attempts 168, max settled 88). On this corpus a rate-based detector needs ≥4 h
  buckets, which is coarser than the thing it was meant to resolve. (d) **It is a standing decline.** D159(e)
  refused automatic regime segmentation and D170(g) restated it with a fifth confirmation; an episode
  detector IS time-axis regime segmentation. **As of this wave the ledger contains no positive episode
  specimen at all**, so replay-first is not available from history, and shipping on negative fixtures alone
  would be the standing test's "fixture cannot produce the defect" clause, self-inflicted. FILED, not built:
  `dr-w15-bl-episode-unit-needs-a-specimen`.

- **D232 — THE ALERT RAIL IS AN EXACT 1:1 SHADOW OF `failed`, AND SUPPRESSION IS NOT OURS.** Re-derived by a
  SECOND method on `inserted_at`, which is never rewritten (`updated_at` drifts: median 65.2 s, max 2,269.9 s,
  4.1% of failed rows cross an hour boundary, and `record_stage/2` writes a `RETIRE skipped` console entry
  onto rows that are already `failed`). Daily: 446/446, 629/625, 866/870, 18/18. Hourly: **100.0% in each of
  30 consecutive hours.** All-time **2,299** `deployment_failed` emails, ALL to one recipient and one team —
  though the log as a whole has 22 recipients, so the claim is scoped to the event, not generalised.
  `suppressed` has NEVER been written: enumerating every `(event, status)` pair that exists returns nine rows
  whose only statuses are `sent` (2,995) and `failed` (5) — strictly stronger than a filter returning zero.
  Suppression is fenced twice (D15, and CCH D363 + D349(e)/(f)), and adding a `Withhold` reason is guarded by
  a derived AST test. **This epic reports ON the rail; it never changes how loudly it sends** (D14, D164).

- **D233 — A PER-ROW JOIN BETWEEN `deployments` AND THE DELIVERY LOG IS STRUCTURALLY IMPOSSIBLE, FOREVER.**
  `notification_deliveries` has twelve columns and none references a deployment: no `deployment_id`, no
  `site_id`, no payload. Every 1:1 claim about the alert rail is aggregate-only, for anyone, always. This
  caps the evidentiary strength of every future claim about it and should be quoted whenever one is made.

- **D234 — `/v1/capabilities` CANNOT ANSWER "CAN THIS BOX DEPLOY SITES", AND MUST NOT BE MADE TO.** Live at
  ADMIN tier against guerrilla: `site_deploy` absent, `SITE_DEPLOY` absent, seven root keys, 25 nouns with no
  `site`, 150 commands with none matching site/deploy — not a tier-projection artefact, since `auth_tier`
  came back `admin` and admin nouns like `fleet` ARE present. MUTATION-PROVED with the repo's own parser: the
  LIVE manifest plus one added root key makes `manifest.Parse` return `parse manifest: json: unknown field
  "site_deploy"`, because `internal/manifest/manifest.go:168` calls `DisallowUnknownFields()`. **Every
  released `bp` binary in the field would fail to parse the manifest — a whole-CLI outage.** Two further
  reasons even if the brick were solved: it is a CONTRACT manifest whose only runtime-varying input is the
  plugin registry (site-deploy is core, not a plugin), and per D65 it rides `pipeline :api` behind
  `AssignDefaultScope`'s three uncached DB round-trips on the 3rd most-500'd path — sourcing "can this box
  deploy" from the path most likely to 500 when the box is unhealthy is exactly backwards.

- **D235 — THE CAPABILITY FACT IS A FOUR-FIELD RECORD, SOURCED FROM THE SAME EXPRESSION THE 503 BRANCHES ON,
  AND IT MAKES NO `GenServer.call`.** `configured` = `DeployRunner.enabled?/0` (`deploy_runner.ex:318`, a pure
  `Application.get_env` read and LITERALLY the expression `site_deploy_controller.ex:72` branches on to emit
  `feature_not_configured`) — so the field can never contradict the refusal, which is the anti-false-statement
  property and the whole reason to prefer it. `runner_alive` = `Process.whereis/1` (the Runner is
  UNCONDITIONALLY in the tree, `application.ex:271`, so `nil` means crashed, never "off"). `runner_queue_len`
  = `Process.info(pid, :message_queue_len)`, established prior art at `listen_controller.ex:244` and
  `studio_chat/runtime.ex:227`. `build_slots` = `build_slot_capacity/0`. **A probe that calls the Runner
  re-imports D113's bug into the instrument built to report it** — that constraint is non-negotiable.
  REJECTED PRODUCERS, each on its own sufficient ground: the `.slots/<slot>.env` grep (D113 is a 75-minute
  proof that the file and the BEAM disagree; `runtime.exs:963` fixes the value at BOOT so a post-boot edit
  lies the other way; on guerrilla `/opt/barkpark/.env` OVERRIDES the slot file because `api/start.sh` sources
  it with `set -a` AFTER systemd's `EnvironmentFile`, making the whole carry machinery moot on the box that
  produced the rows; and a file cannot see a WEDGED runner, which is the class that produced D113's
  failures); and `GET /v1/admin/site-deploy` (its `status` action has NO `enabled?` guard and answered
  `HTTP 200 {"state":"idle"}` live for a slug that has never existed — **today you must SPEND a deploy to
  learn whether the box can deploy**, which is the silence LEG 1 closes, stated exactly).

- **D236 — LEG 1's SIZE IS CORRECTED FROM 138 TO ZERO, AND IT SHIPS ANYWAY AS A PREVENTIVE FACT.**
  `feature_not_configured` rows after `d73c5b526` (`#10015`, merged 2026-08-07 06:52Z) = **0**;
  `runner_unavailable`-shaped rows = **0**; all 265 all-time rows are pre-fix and the LAST one is
  `2026-08-07 03:19:21`, three and a half hours BEFORE the fix. The 212-on-08-06 / 3-on-08-07 split is the
  fix's merge time, not a capability loss. The active slot was verified before measuring (blue `active`,
  `blue.sha` == `/opt/barkpark` HEAD == `8e770a08`, `d73c5b526` an ancestor of both slot SHAs, BEAM entered
  14:02:33Z today) so no slot flipped mid-measurement. CAVEAT, stated because it is confounded: the quiet
  regime began ~22:00Z on 08-06, about nine hours BEFORE the merge, so "0 post-fix rows" is consistent with
  the fix working AND with the regime having already turned. **The un-confounded statement, which is the one
  this charter quotes: the last `feature_not_configured` row predates the fix, and the class has produced
  nothing since.** The slice therefore argues itself as prevention, never as a response to a live signal.

- **D237 — THE 30,000 ms TRIGGER BUDGET IS UNPINNED, AND `status/1` STILL CARRIES THE 5,000 ms DEFAULT.**
  `git grep trigger_call_timeout_ms origin/main` is exhaustive at seven hits: three in `deploy_runner.ex`,
  ONE in a test — `site_deploy_controller_test.exs:217`, which OVERRIDES it to 25 ms — and two in prose.
  **Nothing observes the 30,000 default, so a regression to 5,000 (the exact defect that produced 265 rows)
  ships green.** Separately, `safe_call/3`'s default is still `5_000` (`deploy_runner.ex:437`) and `status/1`
  (`:426`) takes that default with an `idle_status(slug)` fallback, so a Runner wedged for >5 s answers the
  status path `state: :idle` — a silent WRONG answer on precisely the read a capability fact will sit beside.
  Both are closed in the same slice as the capability route: a capability fact next to a still-firing timeout
  is the false adjacency D113 rejected. HONEST LIMIT, to be written into the slice: `runner_queue_len`
  distinguishes a BACKED-UP runner, not one whose single in-flight `systemctl` is slow with an empty mailbox;
  it narrows the false-statement surface, it does not close it.

- **D238 — THE `DOC_ID_EMPTY` SPLIT IS D108-D112's OWN RULING, NEVER MERGED, AND IT MUST TOUCH BOTH ARMS.**
  `git grep -c CONTENT_API origin/main -- cloud/` exits 1; `deploy_ledger.ex:249` is still the bare
  `String.contains?(reason, "bp-doc-id marker is empty")` with the status thrown away. So LEG 2 is not new
  design — it is a charter ruling with a completed proof that never landed, and it may be CITED rather than
  re-argued. Population, re-measured: **277** graph-coded rows — `500`/HEALTH 132, `0`/HEALTH 62, `503`/HEALTH
  62, `500`/BUILD 10, `403`/HEALTH 8, `403`/BUILD 3. **Every BUILD row is `astro-search-starter` and every
  HEALTH row is `search-starter`**, and the mechanism is a template dialect: search-starter's
  `fetchCorpusGraph` DEGRADES and records the cause through the `bp-corpus-status` marker (→ HEALTH exit 14),
  while astro's `graphCorpus` THROWS (→ BUILD exit 12, ANSI-escaped, with an Astro stack trace). **A
  HEALTH-only split therefore leaves the ENTIRE astro/static fleet's corpus failures wearing `BUILD_FAILED`.**
  D110's ten rows are re-measured as thirteen and RE-RULED: same cause, same class, both arms.

- **D239 — `graph 403` IS NOT `:site`, AND `@corpus_403` MUST NOT BE WIDENED.** The eleven graph-403 rows span
  **three sites and two templates inside a single 20-minute window** on 2026-08-05 (20:53:17.32 → 21:13:25.46),
  with two different sites' first rows **0.25 seconds apart**. That is a fleet-wide API-side visibility
  condition (`public_read.ex:134`, "public-read tokens may only read published public documents"), not a
  misconfigured per-site token; assigning `:site` on this data would be D148's error pointed the other way.
  And the existing `FORBIDDEN_403`'s regex `@corpus_403 = ~r/fetch failed:\s*403\b/` matches **ZERO** of the
  eleven while matching **1,095 of 1,575** exit-12 rows — widening it would re-key a 1,095-row class's agency
  by implication from an eleven-row fix, which is D224's shape exactly. `graph 403` gets its OWN class at
  `:ambiguous`; `FORBIDDEN_403` and its regex are left byte-identical. D109's ruling is superseded on this
  point, with its reason recorded rather than silently dropped.

- **D240 — THE COVERAGE NUMBER IS 99.6%, NOT 6.8%.** All-time only 264 of 3,884 `DOC_ID_EMPTY` rows carry a
  code — but the corpus-status producer shipped ~2026-08-05 21:00Z, and by day the split is: 08-07 **0
  uncoded / 5 coded**, 08-06 **1 / 259**, 08-05 109 / 13, 08-04 200 / 0, 08-03 332 / 0, and every earlier day
  200-755 / **zero**. Going forward the split covers **264/265 = 99.6%**. A slice criterion quoting 6.8%
  understates it ~15× and reads as not-worth-doing. The 3,620 uncoded rows are NOT an opaque tail: they split
  cleanly into 3,617 "the SSR rendered no content document" and 3 "the build rendered no content document",
  with zero residue — they predate the producer, and per D112 `DOC_ID_EMPTY` becomes the honest "the cause
  went unrecorded" bucket and must be RE-WORDED to say so.

- **D241 — THE `@classes` BAN IS A PHANTOM WEARING A NUMBER; D43 IS THE REAL CONSTRAINT.** D163 is entirely
  the censored-percentile estimator ruling and contains no mention of `@classes`; D170's seven declined items
  (a)-(g) mention it nowhere either. The ONLY two charter lines forbidding it — 3125 and 3370 — are the
  WAVE-10 and WAVE-11 per-slice file fences, which expired with their waves and explicitly granted the
  regions to a sibling slice afterwards ("S2 owns exactly those regions afterwards"). **Citing D163/D170
  against an `@classes` ADD is a phantom citation and is retired here.** The durable constraint is D43:
  `UNCLASSIFIED` lives in `@classes` and `@classes` rows ARE the failure numerator, so an ADD moves the
  published rate. That is why this split must PARTITION `DOC_ID_EMPTY` — the coded rows LEAVE it — rather
  than add a class beside it, and why the agency key must land in the same commit as the class.

- **D242 — `@agency` IS MINTED BY THIS WAVE, NOT INHERITED; #10129's GO ARM DOES NOT REBASE.** `@agency`
  exists NOWHERE on origin/main (grep: zero hits in `cloud/` and `internal/`); it is introduced solely by
  unmerged `#10129`. Merged against today's main, `#10129` REDS on its OWN exhaustiveness assertion —
  `BOX_DEPLOY_DISABLED_503 has no agency — the map is not exhaustive`, 73 tests / 1 failure — and a full
  mutation ladder (add one key → reds on the second BY NAME; add both → 73/0) proves that assertion is able
  to lose, able to win, and diagnostic. `deploy_ledger.ex` AUTO-MERGES CLEAN in that merge, which is D224
  verbatim: main's 18 classes and the PR's 17 agency keys land together with nobody noticing. BUT the Go arm
  is a RE-DO, not a rebase: main ships an ELEVEN-rung ladder (D69, `c2eecb66d` / `#9887`, landed AFTER
  `#10129` was cut) while `#10129` is TEN rungs that structurally DELETE `strained`, `filling` and
  `unreported`; taking main's side on the three ladder files leaves `go build ./...` clean and
  `go test ./internal/cli/` `ok` with **zero** occurrences of `deploys_failing`. Re-ranking a 13-rung ladder
  and re-deciding `unmetered`'s tone (its fixture row is now ILLEGAL on main independent of rank, per the
  tone-hole guard at `cloud_status_cmd_test.go:404`) is a fresh amendment to D69, and D170(c) reserves it to
  the lead. **THEREFORE: this wave MINTS `@agency` with the enum-keyed assertion `for class <- classes() ++
  not_attempted_classes()`, and `#10129` remains lead-owned debt.** A hand-listed key set instead of the enum
  would reproduce D224 with a green. SECOND, INDEPENDENT TRIPWIRE found in the same merge and worth keeping:
  `#10129` raises `barkpark_json/4 → /5` and `PayloadKeySetCensusTest` catches it with its anti-vacuity floor
  firing "only 47 emitted key(s) collected, floor is 103 — the EXTRACTOR is broken, not the payload shrunk" —
  do NOT let anyone "fix" that by lowering `@emitted_floor`.

- **D243 — THE NAMING GAUGE REACHES 11 OF 21 CLASSES, AND `DOC_ID_EMPTY` IS ONE OF THE TEN IT CANNOT SEE.**
  Proven by RUNNING, twice, on a clean `origin/main` worktree. Relabelling `DOC_ID_EMPTY` "the site owner's
  build produced no content" — the exact wrong-blame sentence LEG 2 exists to prevent — gives **60 tests, 0
  failures**. Relabelling it with `BOX_RUNNER_UNAVAILABLE_503`'s label VERBATIM gives **60 tests, 0 failures**;
  the gauge cannot even catch a class wearing another class's sentence word for word, and
  `sites_deploy_test.exs` is green under the same mutation (70/0). THE CONTROL, which makes this a finding and
  not a broken harness: mutating `BOX_DEPLOY_DISABLED_503`'s label reds ASSERTION A immediately by name. The
  blindness is CLASS-SCOPED. Mechanism, instrumented rather than reasoned: `@probe_matrix` drives only
  `{:start,·} → classify("PLAN",·)`, `{:poll,·} → classify("BUILD",·)` and two 409 chains, while the
  `DOC_ID_EMPTY` arm is guarded on `stage == "HEALTH"` — so `label/1` is never called on it. The ten it never
  reaches: `BOX_BUSY_409`, `BOX_UNREACHABLE`, `BUILD_FAILED`, `DEPLOY_TIMEOUT`, `DOC_ID_EMPTY`,
  `FORBIDDEN_403`, `HEALTH_GATE_FAILED`, `PROCESS_DIED`, `SOURCE_UNFETCHABLE`, `STALE_LEASE`. **Whatever this
  wave names inherits the same blindness unless `@probe_matrix` grows a STAGE axis** — so the split and the
  gauge extension are ONE slice, and its acceptance is a MUTATION, not an assertion. Independently confirmed:
  a code-conditioned split mutation reds NOTHING today (75 tests, 0 failures across the ledger, payload-census
  and head-fence suites), so the split as designed would otherwise ship with zero coverage.

- **D244 — THE GRAPH STATUS SET IS DECLARED, NOT SCRAPED.** The honest scrape target,
  `templates/search-starter/lib/markers.corpus-status.test.ts`, yields exactly `graph 0/200/401/403/500` — it
  MISSES `503`, which is 62 live rows and the second-largest status. `CorpusUnavailableError` (`graph.ts:92`)
  and the astro edition (`bp.ts:94`) both interpolate a pass-through HTTP `res.status`, so graph statuses are
  an UNBOUNDED vocabulary and a scrape cannot fail closed the way `sites_deploy_test.exs`'s snake_case scrape
  does. The gauge extension therefore DECLARES its status set with the live per-status counts pinned beside
  it. Note also that `markers.ts`'s `graph 200: … carried N node(s)` branch has NEVER fired in production
  (zero rows), and the shell fallback "no bp-corpus-status marker" has never been written either.

- **D245 — TWO READERS ARE BUILT AND UNREACHABLE, AND THE FIX IS TO EMIT THEM, NOT TO ADD A THIRD.**
  `DeployLedger.delivery/3` and `DeployLedger.refusal_phase/1` have ZERO callers in `cloud/lib`, proven by
  MUTATION rather than by grep: renaming either and running `MIX_ENV=dev mix compile --force` prints
  `Generated barkpark_cloud app` — the entire control plane compiles with the function gone — and the rename
  kills exactly ONE of 60 tests. An ExUnit assertion on a new ledger function measures the assertion, not the
  system. `refusal_phase/1` is doubly dead: **0** poll-phase rows all-time against **14,848** start-phase, so
  its `:poll` arm has never seen a real row. The codebase already knows: `payload_key_set_census_test.exs:562`
  carries `delivery` as a `:phantom` KNOWN-OPEN row tracked by `dr-w11-s4-followup-emit-delivery-on-route`,
  and `renderDeployDelivery`'s `d == nil` arm prints "NOT MEASURED — this control plane sends no delivery
  census" to every operator, forever, as the only arm it has ever executed. Both follow-up tasks are OPEN,
  UNCLAIMED, and already carry END-TO-END acceptance criteria. **THE REACHABILITY RULE THIS WAVE ADOPTS: a
  new ledger reader's acceptance is a run through the CLI or the route, never an ExUnit assertion on the
  function. A repeatable check exists — rename the new public function, `MIX_ENV=dev mix compile`, and the
  compile MUST FAIL.**

- **D246 — THE ONLY SITE-SERVING BOX IS EXCLUDED FROM THE FLEET'S OWN STALENESS SCAN.** Guerrilla is
  `mode='self_hosted'` and owns **30,901 of 30,956** all-time deployment rows (jarl 55; no other box has any).
  `Registry.stale_online_barkparks/1` (`registry.ex:757`) gates on `b.mode in ["managed","byo"]`; running that
  EXACT predicate against production returns 4 rows with the filter and 5 without, and the delta is Guerrilla.
  The subscription join is NOT the cause — its team is `active`/`forever`. So `unreachable_notification_sent`,
  the alert-exactly-once latch this epic keeps citing as prior art, has NEVER had the box that produces the
  traffic as a candidate. Fourteen waves never recorded it (`grep 'self_hosted\|stale_online\|mode in'` over
  the charter returns zero hits). **LAW: any per-box scan this epic adds composes `checkable_scope/1`
  (host set + not suspended, which DOES include Guerrilla and is documented as "the lone definition of
  checkable"), NEVER `stale_online_barkparks/1`.** Reusing the mode-gated scan would be dark on the only box
  that matters — a vacuous green of exactly the shape this epic exists to kill. Two other mode-gated scans
  are dark BY DESIGN and are correct: `suspend_team_barkparks/2` and `retryable_provision_state?/1`.

- **D247 — `deployments` HAS NO BOX KEY, SO "PER-BOX" COSTS A JOIN THE LEDGER HAS NEVER MADE.**
  `\d deployments` has exactly ONE foreign key, `deployments_site_id_fkey → sites(id)` — no `barkpark_id`, no
  `host`, no box column. `sites.barkpark_id` (NOT NULL, indexed) is the only path. And `deploy_ledger.ex` has
  ZERO references to the `Barkpark` schema: it aliases `Site` and never joins it, and every query keys on
  `d.site_id`. A per-box rate or a per-box episode needs the ledger's FIRST-EVER join to `sites`/`barkparks`.
  That is a new seam, not a parameter, and it is not this wave.

- **D248 — THE FAILURE ALERT CARRIES NO IDENTITY, AND CLOSING THAT IS THE CHEAPEST STEP TOWARD THE
  KINSTA/VERCEL BAR.** `registry.ex:6891` emits `%{detail: failure_reason || ""}` and `dispatch_site_event/3`
  adds only `:name`, so the email is a site name plus a humanized cause: **no deployment id, no commit, no
  timestamp, no duration, no link, no next action.** Both vendors' failure notifications are roughly 90%
  identity-and-link; ours is 100% cause, and a customer receiving three in an hour cannot tell whether that is
  three attempts at one push or three different pushes. The widening is ONE signature change and THREE call
  sites (`:5487` born-failed, `:6884` transition edge, `:6903` reaper) — two already hold the whole
  `%Deployment{}`, and the third SELECTS the id at `registry.ex:6859` and discards it as `_id`. **The gap is
  one character wide.** It is OUTSIDE CCH's fence: `NOTIF_PRODUCER_IDIOMS` (`__app.test.mjs:13757`) is four
  regexes that capture the event ATOM and never parse a payload, unlike the blocked category split
  (D211(a)/D228(c)) — but the census matches per LINE with a floor of 1, so `:deployment_failed` must stay
  literal on the same line as `dispatch_site_event(`. CONSTRAINTS, both load-bearing: **no link** (there is no
  console base URL anywhere in the notifications layer — the only `base_url` in `cloud/lib` is `oauth.ex:349`,
  OAuth-scoped — so carry the deployment id, which `GET /v1/sites/:id/deployments/:dep_id` already makes
  actionable), and **no fabricated duration** (`deployments` has NO `started_at`/`finished_at`, and
  `became_live_at` is NULL on every failed row, so timestamps ship under their real names `inserted_at` /
  `updated_at` or not at all). `render_test.exs:56` and `:85` assert body EQUALITY — a payload widening passes
  them, an added body line reds them, and that is the correct place for it to red.

- **D249 — `FailureCopy` HAS NO CLASS CONCEPT, SO AGENCY IS ZERO-DELIVERED TO THE CUSTOMER — AND THAT IS
  CORRECT FOR NOW.** `grep -cEw 'agency|fault|blame'` over `failure_copy.ex` returns **0** across 835 lines
  (the tempting hits are the substring inside "default"). The stronger fact: its `classify/1` is PRIVATE and
  returns a SENTENCE, and `humanize/1` is String → String, so **no class token crosses the boundary at all**.
  A class gaining an `@agency` key in `deploy_ledger.ex` cannot reach the customer even in principle. Building
  that seam is materially larger than the identity widening and touches a file five subsystems read; it is
  FILED, not bundled (`dr-w15-bl-failure-copy-has-no-agency`). ALSO CORRECTED: LEG 2's stated motivation
  ("stops blaming the site owner") DIES — the site owner IS us (D250) — so **LEG 2 is re-argued as classifier
  CORRECTNESS: a class that discards a machine-readable code its own row already holds is wrong regardless of
  who reads it.**

- **D250 — THE POPULATION IS A TOY, WHICH IS EXACTLY WHY THE UNIT CHANGED.** 27 teams, 27 users, 13 sites —
  and ALL 13 sites belong to ONE team whose sole membership row is the operator; 26 of 27 teams own zero.
  Five webhook sites carry **98.99%** of 30,938 all-time deploys and **98.18%** of the trailing 24 h; all 150
  `content_publishes` come from those same five; the 24 h trigger/source mix is `content-auto`/`box-build`
  2,286 and `template-auto`/`box-build` 23, i.e. **ZERO user-initiated deploys**. And `@min_sample 200` means
  exactly those five clear the per-site floor (sixth-busiest: 41) — **the guard against small-n lying is what
  pins the instrument to the toy.** DECLARED DEAD by this wave, on measurement: a per-owner deploy number
  (n = 1 owner), population statistics over `sites` (13 rows, 12 of them proofs), and any fleet rate argued as
  "the fleet's reliability" — it is one team's cron churn. SURVIVING because they hold at n = 1: the per-box
  capability fact (D235), the per-row cause split (D238), and `live`-per-attempt (D229).

- **D251 — SILENT RESIDUE, MEASURED AND RANKED: IT DOES NOT COMPETE, AND IT IS TRIPWIRE-GRADE.** All four
  suspects are ZERO all-time, and the zeros are real — an anti-vacuity control shows the same `LIKE` machinery
  matching `%(exit %` 5,264, `%BUILD failed%` 1,580, `%HEALTH gate%` 3,688, `%unreachable%` 126. (a) The
  reaper-text mismatch has no population AND no mechanism: all 126 unreachable rows are ONE string containing
  `is unreachable`, which `BOX_UNREACHABLE`'s anchor matches. (b) Production has EVER produced exactly three
  exit codes — 14 (3,688), 12 (1,575), 10 (1) — so **11 of `exit_label/1`'s 14 templates have never fired**,
  including exit 15, whose label the charter records an elaborate two-producer rewrite of. (c) `cancelled` is
  **0 rows** despite three live producers, so the CONFIRMED mechanism (`classify(%{status: _other}) -> nil`
  lands the row inside `volume` and outside the numerator, i.e. scored as a SUCCESS) changes no denominator
  this epic has ever quoted. (d) 0 non-terminal rows. The true UNCLASSIFIED residue is **5 rows all-time, 0 in
  7 d, 0.027%** of 18,622 failures, against `DOC_ID_EMPTY`'s 3,884 — one micro-gap is real (`build_class`
  keys on `String.starts_with?(reason, "BUILD failed (exit")`, so the EM-DASH variant misses; 2 rows). **These
  belong as assertions inside an EXISTING census test, never as new slices** — a tripwire over an empty
  population is a test that rots unnoticed (D8).

- **D252 — THE DEFERRAL COHORT IS NOW THE MAJORITY AND NOTHING REPORTS ITS VOLUME.** On 2026-08-07,
  **1,109 of 1,527 attempts (72.63%) settled `deferred`** against 18 `failed`. All 2,006 deferred rows carry a
  `failure_reason` and exactly two causes (`box_at_capacity` 1,306, `already_running` 698); the cohort did not
  exist before `2026-08-05 21:27:11`. **0 of 2,006 ever set `became_live_at`** — deferral is terminal FOR THE
  ROW — but no site is stranded (latest production deploy per site: 10 live, 2 failed, 0 deferred), so the
  honest claim is **"the deferral loop burns ~3.2 attempts per live deploy and reports nothing"**, NOT
  "deploys are silently lost". The failure rate can therefore approach zero while three quarters of attempts
  produce no live site, and the alert rail is blind to it BY CONSTRUCTION because it shadows `failed` (D232).
  The ledger's own copy is defensible (D43/D44 put deferrals inside `volume`, outside the numerator, on their
  own line); the VOLUME is what nothing reports, and that is why `live`-per-attempt becomes a co-equal
  headline rather than a footnote. 1,818 of 2,006 carry a NULL `deferral_cause` while holding the 409 code —
  FILED as `dr-w15-bl-deferral-cause-null-audit`, NOT called a classifier bug, because the `deferral_*`
  migration is dated the same day and the NULLs are probably pre-migration residue. That must be settled
  before anyone builds on it.

- **D253 — WHAT WAVE 15 DELIBERATELY DOES NOT BUILD, WITH REASONS.** (a) **An episode detector** — D231, no
  specimen exists and `@min_sample` silences it hourly. (b) **Alert suppression of any kind** — D232, fenced
  twice. (c) **A `/v1/capabilities` capability key** — D234, it bricks every released `bp`. (d) **A rebase of
  `#10129`** — D242, its Go arm is a re-do and the ladder is the lead's per D170(c). (e) **A widening of
  `@corpus_403`** — D239, an 11-row fix must not re-key 1,095 rows. (f) **A shell repair in
  `deploy/instance-deploy.sh`** — the carry-forward already ships (site-spawner D38, Case 14 pins survival),
  the residual holes are different and smaller, and on guerrilla `.env` overrides the slot file anyway
  (D235); `deploy/` is the site-spawner charter's. (g) **`failure_copy.ex`** — D249, a class-identity seam,
  filed. (h) **Raising `@build_slot_capacity`** — D180 stands, and D252 shows the deferral loop is not losing
  deploys. (i) **A per-box ledger join** — D247, a new seam. (j) **`cloud/priv/static/app.js`, `web/auth.ex`
  and `router.ex`'s auth region** — the CCH fence, which this wave could only bound and not cite (see below).

- **D254 — THE CCH WAVE-47 FENCE COULD NOT BE CITED, ONLY BOUNDED — AND THE CONSOLE LADDER HAS ALREADY
  DRIFTED.** `bp paper view cloud-console-hardening-wave-47-2026-08-07` still returns 422 `semantic_empty`;
  `bp search query "cch-w47"` returns count=1 whose sole hit is OUR OWN wave-15 paper; zero `cch-w47` tasks
  are filed and zero slice branches exist on origin. Wave 47's rulings (D523-D534, incl. its 6-slice roster)
  live only on OPEN PR `#10355`, so its fence is PR-authority: `app.js`, `index.html`, `__app.test.mjs`,
  `scenarios.mjs`, `smoke.mjs`, `breakpoint-sweep.test.mjs:583-592`, and the binding census — it does NOT name
  `attention_order.json` and does NOT edit `router.ex`. **Wave 15 has no file collision with it.** SEPARATE
  FINDING, filed rather than fixed because it is inside that fence: `app.js`'s `ATTENTION_RANK` is still NINE
  rungs with no `strained` and no `filling`, and `app.js` contains ZERO references to `attention_order` — the
  "canonical cross-surface vocabulary" fixture is consumed only by Go. **A box over the D67 load fence or at
  ≥90% disk reads `strained`/`filling` in `bp cloud status` and reads `ok` in the console, green, today, on
  origin/main.** D32's "both surfaces implement the charter verbatim" is already false.
  (`dr-w15-bl-console-ladder-is-nine-rungs`.)

- **D255 — `#10304` CANNOT BE UNBLOCKED BY ANY EVENT THIS WAVE CAN EMIT, SO WAVE 15's CHARTER PR CARRIES
  D212-D228 FORWARD.** `#10304` is MERGEABLE / BLOCKED on one failing required context, "PR references an
  active task", whose own log reads: *the claim by `epic-cycle-decide-w13` had ALREADY lapsed 3469s before
  this PR was opened*. The gate re-fires on `edited` as well as `synchronize` (the workflow says `edited` is
  load-bearing precisely so a corrected PR is not sticky-red), but the lease predicate is PR-RELATIVE against
  `github.event.pull_request.created_at`, which the workflow documents as IMMUTABLE across
  synchronize/edited/reopened. **Re-claiming now makes the claim live at T > created_at, while the predicate
  asks whether it was live AT open — so no push, no edit, no re-run and no close+reopen clears it.** The armed
  paths are a FRESH PR opened under a live claim, or break-glass. This wave's charter PR is that fresh PR:
  it is opened under a live claim on `task-fb4fb869490b4213` and carries D1-D228 plus D229-D255, superseding
  `#10304`, which the lead should close.

### Wave 15 plan — 6 slices, 4 in round 1, file sets disjoint within a round

Round-1 file sets are disjoint by construction: S1 owns `api/**` only; S2 owns `cloud/lib/**/deploy_ledger.ex`
plus its own test file; S3 owns `cloud/lib/**/web/router.ex`'s CENSUS and `deployment_json` regions plus
`payload_key_set_census_test.exs`; S4 owns `cloud/lib/**/registry.ex`'s dispatch region plus the two
notification renderers and their test. S5 and S6 are round 2 and are NOT built this run (sequenced-rounds
law): S5 writes `router.ex`'s `barkpark_json` region and the SAME payload census file S3 edits, and needs S1's
route to exist; S6 writes the same `deploy_ledger.ex` S2 rewrites and the same census floors S3 bumps.

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | The instance answers "can I deploy sites" without spending a deploy, and the 30 s budget gets a guard | `dr-w15-s1-instance-answers-can-i-deploy` | `api/**` | medium | opus |
| 2 | 1 | The content API's own status stops being thrown away, and the gauge learns to look at HEALTH and BUILD | `dr-w15-s2-graph-code-split-and-agency` | `cloud/lib/**` ledger + its test | large | opus |
| 3 | 1 | Two built readers stop being unreachable: `delivery/3` reaches the route and `refusal_phase/1` reaches the row | `dr-w15-s3-emit-the-two-corpses` | `cloud/lib/**` router + census test | medium | opus |
| 4 | 1 | The failure alert says WHICH deployment failed | `dr-w15-s4-alert-carries-deployment-identity` | `cloud/lib/**` registry + notifications | medium | opus |
| 5 | 2 | The box's capability and its code age reach `bp cloud status` | `dr-w15-s5-capability-reaches-bp-cloud-status` | `internal/**` + `cloud/lib/**` | large | opus |
| 6 | 2 | `live`-per-attempt becomes a co-equal headline and the 08-05 boundary is declared | `dr-w15-s6-live-per-attempt-headline` | `cloud/lib/**` ledger + `internal/cli/**` | medium | opus |

**Round-2 dependencies.** S5 AFTER S1 (it probes S1's route) AND AFTER S3 (both edit
`payload_key_set_census_test.exs`, and S5 bumps the EXACT-equality `@barkpark_family_keys 56`). S6 AFTER S2
(both write `deploy_ledger.ex`) AND AFTER S3 (both move the census floors). Both carry the dependency as an
"AFTER `<task_id>` merges" line at the top of their brief.

**HIGH-FLIP-RISK slices, per E2.** S1: the judgment that `Process.info(:message_queue_len)` actually RISES
during a D113-shaped wedge is a DESIGN, not a measurement — nobody has shown it, and a builder must
mutate-prove it (block the Runner behind a sleep, read the queue) or the field becomes another
stamped-but-structurally-blind gauge. S2: the `graph 403` agency assignment (D239) is a `:box`→`:site`
question decided on eleven rows across a 20-minute window. Both warrant a genuinely INDEPENDENT second
reviewer before merge; the wave reviewer names it, the lead dispatches it.

**The lead's own acts this wave, which no builder can do.** Close `#10304` and let this wave's charter PR
supersede it (D255). Decide the 13-rung ladder and re-cut `#10129`'s Go arm, or close it (D242). Dispatch S5
and S6 after their deps merge. Then the D225 sweep residue, unchanged.

**The measurement discipline this wave adds to the standing list.** `docker exec … psql -f <path>` resolves
the path INSIDE the container, so a `scp` to the host then `-f` fails with `No such file or directory` — pipe
the file on stdin. Bare `CC=clang` breaks the cgo build on this host (`error: unknown option '-E'`) even
though `which clang` is `/usr/bin/clang`; use the absolute path. The primary checkout is ~594 commits behind
origin/main and `cloud/lib/barkpark_cloud/deploy_ledger.ex` DOES NOT EXIST in it — every `git grep` for this
epic must name `origin/main`, and a bare-worktree grep will report a real file as absent. And a rate over a
pinned window is structurally blind to an incident: by the time it is bad the incident is over, by the time it
is good it is washed out — which is the wave's thesis surviving even though its detector did not.

### Wave 2026-08-07 (wave 15) — REVIEWED · Paper `deploy-reliability-wave-15-2026-08-07` · grade **A−**

**Four of six slices built, reviewed, gate-green on the reviewed state, PUSHED and PR'd. Nothing merged — the
lead merges.** S5 and S6 were round-2 by design (sequenced-rounds law), not stalls: both wait on round-1 merges.

| Slice | Task | Final branch | PR | Gate re-run by the reviewer |
|---|---|---|---|---|
| The instance answers "can I deploy sites" | `dr-w15-s1-instance-answers-can-i-deploy` | `…can-i-deploy-sites--0` (unchanged) | [#10399](https://github.com/FRIKKern/barkpark/pull/10399) | 39 tests, 0 failures · format clean |
| The content API's own status stops being thrown away | `dr-w15-s2-graph-code-split-and-agency` | `…own-status-stops-being-1` (unchanged) | [#10400](https://github.com/FRIKKern/barkpark/pull/10400) | 145 tests, 0 failures · format clean |
| Two built readers stop being unreachable | `dr-w15-s3-emit-the-two-corpses` | `…stop-being-unreachable-2` (unchanged) | [#10401](https://github.com/FRIKKern/barkpark/pull/10401) | 71 Elixir + Go `TestCloudDeployments` ok · format/gofmt clean |
| The failure alert says WHICH deployment | `dr-w15-s4-alert-carries-deployment-identity` | `…says-which-deployment--3` (unchanged) | [#10402](https://github.com/FRIKKern/barkpark/pull/10402) | 125 tests, 0 failures · JS 972/0 · **full cloud suite 3,118/0** |

**What landed.** The wave hits all three clauses of the wish on the same day.
SILENT → REPORTED: an instance can now answer "can I deploy sites?" over one authed GET without spending a
deploy (D235), and none of its four fields makes a `GenServer.call`, so the instrument survives the exact wedge
it exists to report. MIS-REPORTED → NAMED: 277 rows carrying a fully readable content-API status stop wearing
`DOC_ID_EMPTY` / `BUILD_FAILED` and get their own four classes in BOTH template dialects (D238) — the astro arm
is what stops the ledger blaming a site owner for an instance-side condition. UNREACHABLE → REACHED: two built
readers (`delivery/3`, `refusal_phase/1`) had zero callers in `cloud/lib`, so `bp cloud deployments` had printed
"NOT MEASURED" to every operator forever off the only arm it ever executed; the census route now emits both.
AND THE ALERT GREW A SUBJECT: `deployment_failed` names the deployment id, the stage and one real code identity
on all three producer paths and both rails (D248) — no link, no fabricated duration, no invented column.

**The reporting can lose, and that was checked, not accepted.** The reviewer re-ran three independent
mutations rather than re-reading the builders' pasted ones: dropping one `@agency` key reds S2 by name (75/2);
replacing S3's `Map.put(:delivery, …)` reds the payload census as a Go phantom (11/2); both restore green. S1's
budget pins are the wave's sharpest guard — `trigger_call_timeout_ms/0` is public *so the default can be
observed without an override*, which is precisely the hole through which a 5,000 ms regression once shipped
green and produced 265 wrong `feature_not_configured` rows.

**What did NOT land.** Nothing is merged, so the AFTER number does not exist yet — again. `refusal_phase` is
emitted and read by nobody (`bp cloud site status` still cannot show it); the follow-up is filed. The reaper's
alert names the id only, because its four sweep `select:` clauses are `{d.id, d.site_id}`; filed as
`dr-w15-bl-reaper-alert-identity-is-id-only`. `runner_queue_len` sees a BACKED-UP runner, not one whose single
in-flight `systemctl` is slow with an empty mailbox — the moduledoc says so rather than overclaiming. And
`build_slots` is capacity, not free slots, which is the field an operator would actually want.

**The one judgement a second reviewer is owed before merge (D239, S2).** `CONTENT_API_403` is mapped
`:ambiguous` per the ruling. Re-derived independently: 11 rows across 3 sites and 2 templates inside one
20-minute window, two sites' first rows 0.25 s apart, is a *correlated fleet event* whose correlating variable
is the API side's own visibility policy — which is the same ground on which 500/503/0 are mapped `:box`.
`:ambiguous` is the direction that keeps those rows OUT of a box numerator. Eleven rows, no rate moves, one
line either way — but the direction is doctrine, so it should be a human's call, not a builder's.

**What the next wave takes.** Merge round 1 in dependency order, then dispatch the two deferred slices as their
deps land: `dr-w15-s5-capability-reaches-bp-cloud-status` after #10399 **and** #10401 (it probes S1's route and
both edit `payload_key_set_census_test.exs`), and `dr-w15-s6-live-per-attempt-headline` after #10400 **and**
#10401 (both write `deploy_ledger.ex` / move the census floors). Then D252 is the epic's next real frontier:
72.63% of 2026-08-07's attempts settled DEFERRED against 18 failed, so the failure rate can approach zero while
three quarters of attempts produce no live site — and the alert rail is blind to it BY CONSTRUCTION because it
shadows `failed` 1:1 (D232). S6 is the first instrument that can see it; the wave after should make that
cohort's VOLUME, not just its rate, something a person is told about.

---

## Wave 17 — the instrument nobody can reach, and the denominator nobody counted

**NUMBERING NOTE, read before citing anything below.** The charter on `origin/main` topped out at **D255**
when this wave opened (verified: `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md`).
**D256-D273 belong to wave 16's charter PR `#10407`, which is OPEN and unmerged** — they are PR authority, not
charter law, and this wave does NOT renumber or restate them. Wave 17 therefore numbers from **D274** so the
two charter PRs union-merge on a disjoint number space. Wave 16's *code* is a different matter: it is merged
AND deployed (D274).

### What wave 16 actually landed — the crown finding of wave 17's own brief is FALSE

- **D274 — WAVE 16's LEG 1 IS MERGED, DEPLOYED, AND CORRECT TO THE ROW; THE MEASUREMENT PROBLEM IS SOLVED AND
  THE EPIC MUST STOP RE-SOLVING IT.** `DeployLedger.census/3` on `origin/main` emits `live`, `in_flight`,
  `cancelled`, `residual` and `live_rate`, with `live` read POSITIVELY (`Enum.filter(settled, &(&1.status ==
  "live"))`) and never by subtraction, and `internal/cloudclient/client.go:1973` carries `LivePerAttempt
  *DeployRate \`json:"live_rate"\``. Merged as `#10440` / `#10442` / `#10443`. **And it is LIVE**: an `rpc` on
  the running prod release `cloud-control_plane_green-1` returned those keys. **The instrument also agrees
  with the database.** `census/3`'s query shape re-run as one SQL statement in a single REPEATABLE READ
  snapshot on `cloud-db-1`, and `census/3` itself run via `rpc` on the live node, agree for 2026-08-07:
  volume 1705 · failed 18 · deferred 1227 · live 460 · in_flight 0 · cancelled 0 · **residual 0** ·
  failure_rate 1.06% · live_rate 26.98%. The only number that moved between the two runs is one `building` row
  settling to `live` — volume constant, live +1, in_flight −1, which is a consistency proof, not an error bar.
  **The headline's problem was never arithmetic.**

- **D275 — WHAT IS LEFT IS OLDER AND WORSE: NOTHING THAT WAS BUILT CAN BE READ BY A HUMAN, AND THAT IS NOW
  PROVED LIVE, NOT INFERRED.** With one real non-admin session, in the same minute:
  `GET /v1/operator/deploy-ledger/census` → **HTTP 403** `{"error":"forbidden","scope":"platform","required":
  "platform_operator"}`; `GET /v1/sites` → **HTTP 200**, 13 sites. The census route (`router.ex:3536`) is gated
  by exactly one predicate, `Auth.require_platform_operator`, whose entire decision is membership of
  `Notifications.platform_admin_emails/0` — which resolves configured emails against REGISTERED USERS and is
  `[]` on prod both because the env is unset and because an unresolvable email is rejected. The operator
  population is **zero by construction**, and `auth.ex:319-323` says so itself. Alongside it,
  `git grep LivePerAttempt origin/main` returns ONE definition and ZERO uses. **It is not one dead field but
  four** — `LivePerAttempt`, `InFlight`, `Cancelled` and `Residual` all have zero readers in
  `internal/cli/cloud_deploy_census_cmd.go`. Sixteen waves of instrument; 403 for every account that exists,
  and the fields that did ship decode to nobody.

### Leg 1 — reachability, and the four decisions that were driven rather than argued

- **D276 — LEG 1 IS SMALL, NOT A NEW AUTHORIZATION PATH; THE HIGH-FLIP-RISK FLAG IS DOWNGRADED BUT NOT
  RETIRED.** Three in-repo precedents settle it: `PublishClock.census/3` (`publish_clock.ex:362`) already
  scopes ONE census by an opt via `site_bound/1` **without forking a second entry point** and emits its own
  `scope:` key; `GET /v1/barkparks` (`router.ex:1902`) is a no-path-id team read; `Registry.list_sites_for_team/1`
  (`registry.ex:4907`) is the canonical listing. The team-scoped population is byte-identical to the platform
  one TO THE ROW today — `GROUP BY s.team_id` over `sites LEFT JOIN deployments` returns a SINGLE row,
  `506f035e-…` | 13 sites | 31,137 rows. **The one real hazard survives**: `deployments` has NO `team_id`
  column (`registry/deployment.ex:98-160` carries only `belongs_to :site`; `registry.ex:6977` states the
  Site→team hop as an invariant), so scope must hop through `sites.team_id` and a caller-supplied `site_ids`
  list is an IDOR unless it is an INTERSECTION. **The IDOR was EXHIBITED, not argued**: mutating one clause
  (`Enum.filter(owned, &(&1 in list))` → `list`) reds three tests, including a wire-level one that printed
  team B's `site_id` and its 7 `failed` rows inside team A's response body. Correct derivation: 12/12 green.

- **D277 — THE CREDENTIAL IS `require_user_or_pat` + `require_ability("read")`, NOT `:session`. THIS OVERTURNS
  `dr-w16-s6`'s OWN CRITERION 2.** `with_team_site`'s `:session` default (`router.ex:11148`) is PAT-dead per
  D219, whose stated consequence is *"no CI or automation credential can ever compute the owner's number"* —
  shipping leg 1 session-only would reproduce, on the new route, the exact defect leg 1 exists to end. Both
  in-repo precedents (`router.ex:1910`, `:6319`) use ability-read. DRIVEN: a read PAT gets 200 with volume 5,
  and a read PAT naming a foreign site id still gets volume 0.

- **D278 — A TEAMLESS CALLER GETS `422 {"error":"no_team"}`.** Census of all 55 nil-team arms in `router.ex`:
  31× `404 not_found`, 13× `422 no_team`, 1× `403 forbidden`, plus three empty-200s. **Every one of the 404s
  belongs to `with_team_site`'s PATH-ID routes**, where 404 correctly conflates "wrong team" with "no such id".
  This route has no path id, so a 404 would lie about a route that exists, and a 403 would assert an authority
  no grant could supply. CCH D433 records that the inline 422 `no_team` emitters stay 422 by design.

- **D279 — THE SCOPE PREDICATE LIVES IN THE QUERY. A POST-FILTER ON THE RENDERED `sites` NODE IS WRONG TWICE,
  MEASURED.** With `site_limit: 3`, one own site (3 rows) against three louder foreign sites (20 rows each):
  the post-filter design leaves every fleet total untouched (volume 63, failed 60, instead of 3 / 0) **AND the
  caller's own site is entirely ABSENT from the node**, because `site_rows/2` (`deploy_ledger.ex:786-810`)
  sorts by volume and takes `site_limit` BEFORE any filter could run. Query-scoped: volume 3, `sites == [own]`.

- **D280 — THE INTERSECTION IS COMPUTED IN ELIXIR, NEVER IN SQL — AN UNFILED SECOND-ORDER DEFECT.**
  `sites.id` / `deployments.site_id` are `binary_id`. A client-supplied non-UUID reaching either column raises
  `Ecto.Query.CastError` → a **500**, i.e. a NEW silent-failure surface on the route this epic built to end
  silent failures. MEASURED BOTH SHAPES: the Elixir-side intersection drops junk before any query and the route
  answers `200 volume=0` for `?site_ids=nope`; an SQL-side `where s.id in ^["nope"]` RAISES. A builder writing
  the "obvious" single-query version ships a 500.

- **D281 — THREE MERGE-GATE GUARDS RED ON THE ROUTE ADDITION AND MUST MOVE IN THE SAME COMMIT; ONE OF THEM IS
  WAVE 16's OWN INSTRUMENT FORBIDDING LEG 1.** Proved by mutation — the same three files are 21/21 GREEN with
  the lib edits stashed and 3-failing with them applied. (a) `router_head_fence_census_test.exs:140-143`
  `@baseline_total 65 → 66`, `@baseline_session 46 → 47`; the route is a pure read, so it needs a baseline move
  and a reason line, NOT a `side_effecting_get?/1` clause. (b) `router_moduledoc_table_test.exs:97` — a route
  row in `router.ex`'s `@moduledoc` table. (c) **`deploy_ledger_reachability_test.exs:619` asserts
  `[%{arity: 2}] = callers[{:census, 3}].external`** — an exact single-element match pinning `census/3` to
  exactly ONE external caller, so wave 16's reachability guard STRUCTURALLY FORBIDS the second caller leg 1
  exists to add. Widen it deliberately to admit arity 2 AND arity 3; never loosen it into vacuity, and re-prove
  the widened form still fails under the file's own broken-walker harness at `:595`.
  **AND: `dr-w16-s6`'s criterion 8 pinned only `mix test .../deploy_ledger_test.exs`, which PASSES while all
  three of these red — a vacuous-green hole in the slice's own acceptance. Corrected to the directory.**

- **D282 — THE SCOPE MUST PRINT THE TEAM SLUG AND ITS SITE COUNT MUST NAME ITS POPULATION.** The route holds
  the full `%Team{}` in `conn.assigns.current_team`, so the slug is free; a UUID cannot render
  `team guerrilla · 13 sites`. And the denominator is FOUR numbers, not two: `sites` = 13 rows;
  `count(DISTINCT site_id)` in `deployments` = 12 (site `auto-proof` has never deployed); the D252 cohort has
  12 members; and `sites.current_deployment_id` yields `live 10 / NULL 3`, silently dropping the two failed
  sites into the same bucket as the never-deployed one. A cohort built by grouping `deployments` disagrees with
  "13 sites" by one FOREVER. Build it as `sites LEFT JOIN deployments` with never-deployed rendered as its own
  outcome, and say which population any count is over.

### Leg 2 — the site unit, and the finding that reconciles two "irreproducible" measurements

- **D283 — THE SITE-OUTCOME COHORT NEEDS NO SERVER CHANGE AND NO CENSUS: IT IS ALREADY ON A PAYLOAD A REAL
  NON-ADMIN RECEIVES.** `GET /v1/sites` (`router.ex:6318-6336`) is `require_user_or_pat` + `require_ability("read")`,
  team-scoped, and ALREADY embeds the latest PRODUCTION deployment per site via
  `Registry.latest_deployment_status_map/1` (`registry.ex:2277`: `where d.environment == "production"`,
  `distinct: d.site_id`, `order_by desc inserted_at, desc id`) — exactly D252's unit. **`deferred` is a real
  observed value in that embed**: site `search` was caught at `{"status":"deferred","trigger":"content-auto"}`,
  so the kill-condition ("a deferred attempt never writes a production row") is FALSE. The COST half is
  reachable too, contrary to the wave's own digest: `GET /v1/sites/:id/deployments` is team-scoped, returns 200
  to the same token, and carries `became_live_at`, `deferral_depth`, `deferral_cause`, `deferral_bound`,
  `failure_class` — the full cost vocabulary. Its limit is paging (200-row cap, live `next_cursor`), not auth.
  Filed as `dr-w17-bl-per-site-cost-needs-paging`.

- **D284 — D252 IS NOT MIS-DERIVED AND IT IS NOT DRIFT: THE COHORT IS TIME-VARYING, AND THAT RECONCILES EVERY
  CONTRADICTORY MEASUREMENT THIS EPIC HAS PRODUCED.** Two identical calls five minutes apart returned
  `{live 8, failed 2, deferred 1, building 1, absent 1}` and `{live 10, failed 2, absent 1}` — the second being
  EXACTLY D252's 10/2/0, the first matching the surveyors who "could not reproduce" it at 7-8 live / 2-3
  deferred. Independently: the same `DISTINCT ON (site_id)` query replayed at 30-minute cutoffs over 48 h gives
  **22 distinct (live, failed, deferred) triples over 97 samples**, with 10/2/0 the modal state at only
  **19.6%** and `live` ranging 4..10. Every mis-derivation hypothesis is refuted — dropping the `environment`
  filter and ordering by `became_live_at DESC NULLS LAST` both give the identical 10/2. **The cause is that
  `deferred` and `building` are transient IN-FLIGHT states that a latest-per-site query reports as if they were
  OUTCOMES.** RULING: D252 is re-classed from a standing property ("no site is stranded") to a **volatile
  instantaneous sample**; any site cohort MUST carry a settled/in-flight split, and its acceptance must assert
  SHAPE, never VALUES. Pinning 10/2/0 is pinning the weather. D252's *other* half re-derives TRUE at the new N:
  **0 of 2,124 deferred rows ever set `became_live_at`**. And the honest deferral framing is now measurable —
  **1,837 of 2,124 (86.5%) are followed by a same-site live within one hour**, so deferral is terminal for the
  ROW and usually transient for the SITE. D253(h) leaned on D252 to justify NOT raising `@build_slot_capacity`;
  that ruling now rests on a volatile sample and should be re-taken on the windowed form.

- **D285 — THE THREE NUMBERS DISAGREE, AND THAT DISAGREEMENT IS THE REPORT.** On 2026-08-07 the failure rate
  reads **1.1%**, live-per-attempt reads **26.8%**, and the site-outcome rate reads **58%** (7 of 12). A wave
  that ships only one of these ships a lie regardless of which one it picks. And D252's cost figure is
  UNDERSTATED, not overstated: attempts-per-live by day is 4.66 / 8.64 / 8.58 / 7.81 / 8.17 / 7.66 / 6.51 /
  7.02 / 3.90 / **3.71** — "~3.2" is reproduced nowhere in the window, and today is the BEST day.

- **D286 — THE D24 EMBED HAS NO GO READER EITHER: THE CROWN PATTERN RECURS ON THE SURFACE THE WAVE CALLED
  "ALREADY REACHABLE".** `internal/cli/sites_cmd.go:110-119` walks every site with `latestDeployment(client,
  s.ID)` → `ListDeployments(siteID, Limit:1)` — a deliberate, commented N+1 — and `siteRow()` (`:265-271`)
  emits `{id, status, image_tag, inserted_at}` while the server embed emits `{status, trigger, inserted_at,
  updated_at}`. Two keysets from two data paths. Both are production-filtered so the POPULATIONS agree, but
  wave 15's embed is decoded by nobody, and the CLI pays 13 extra round trips to recompute what the list route
  already sent — during which each site's status is read at a DIFFERENT INSTANT, compounding D284. **The
  stronger slice is not "compute the cohort" but "give the embed its first reader and make the cohort
  settled-honest".** (Naming: `bp cloud sites` DOES NOT EXIST — the fleet verb is `bp sites`; and bare
  `bp sites` piped emits JSON by design, `output.go:70-76`, not by defect.)

### Leg 3 — continuity, and the denominator nobody counted

- **D287 — THE CONTINUITY BOUNDARY IS AN INSTANT, NOT A DATE, AND D229's SENTENCE IS ALREADY WRONG BY 21.5
  HOURS.** `min(inserted_at) where status='deferred'` = **2026-08-05 21:27:11.41321**, matching the charter to
  the microsecond — but that is 21h27m INTO the day, and 2026-08-05 holds 629 `failed` rows before the instant
  and 124 `deferred` rows after it. **A comparison confined to 2026-08-05 straddles the vocabulary change and
  PASSES D229's sentence.** Worse, DERIVATION METHOD CHANGES THE ANSWER BY 37 HOURS: the same boundary derived
  as `min(inserted_at) where deferral_cause IS NOT NULL` is **2026-08-07 10:12:35**. So "record the derivation
  method" is not hygiene — it is the difference between two answers. And the boundary SLIDES CHEAPLY: its first
  hour holds 4 rows, its first three hours 124, and there is no reaper for `deployments`, so the day retention
  lands the derived boundary moves forward and every cross-boundary refusal quietly stops refusing.

- **D288 — THE RENAME SPECIMEN IS VISIBLE IN THE CENSUS'S OWN ARITHMETIC, AND THE GAUGE IS THE ONLY BACKSTOP
  THERE IS.** Per day, failure rate 88.33 / 87.19 / 87.76 / 86.95 / 84.63 / 71.64 / 39.27 / **1.06** while
  deferred goes 0 / 0 / 0 / 0 / 0 / 124 / 773 / 1227 and volume HOLDS (2,708 → 1,705). The `already_running`
  FAILED class went **1,261/day to zero** while deferred capacity went 0 → 1,214. That is a class going to zero
  while its cohort volume holds — a RENAME, not a repair — and D265's correction stands: the denominator must
  be `census.volume`. **`deployments` carries ZERO CHECK constraints** (`pg_constraint` `contype='c'` returns
  0 rows), so nothing in the database prevents a silent status rename and the gauge is the only guard.

- **D289 — THE FILED RESIDUAL MUTATION DOES NOT ESCAPE; A DIFFERENT ONE DOES, AND IT LEAVES 3,131 TESTS
  GREEN.** `dr-w16-bl-residual-cannot-go-negative` claims that adding `live` to `@in_flight_statuses` drives
  residual negative "while every test stays green". RUN: it REDS THREE TESTS. The real escape is the DEFERRED
  cohort, which is split out of `attempted` by CLASS while live/in_flight/cancelled are filtered by STATUS: a
  new cohort keyed on `status == "deferred"` over `attempted` overlaps it invisibly, and adding exactly such a
  term to the subtraction at `deploy_ledger.ex:679` left the **ENTIRE CLOUD SUITE — 3,131 tests — GREEN, 0
  failures**, while driving residual to −3 on a probe fixture (−2,124 on prod). Cause: only FOUR residual
  assertions exist (`deploy_ledger_test.exs:1252/:1295/:1324/:1368`) and **NOT ONE of their fixtures contains a
  deferred row** — the standing test's fourth clause, aimed at this file. THE GUARD is an accounting-identity
  test over a fixture with one row of every status: `residual >= 0` **AND** `failed + Σdeferred + live +
  in_flight + cancelled + residual == volume`. `residual >= 0` alone is insufficient (an overlap smaller than
  the residue stays positive); computing residual POSITIVELY would make negativity impossible but could not
  detect the double count at all. Proved green clean, RED under the mutant **with the 62 existing ledger tests
  green in the same run**. Note D98 already ruled this clamp — for the DISK residual; the census residual,
  built nine waves later, never inherited it.

- **D290 — `cancelled` HAS NEVER EXISTED, CONFIRMED AT THE DATABASE THREE WAYS, SO WAVE 16's COHORT IS A BUCKET
  OVER AN EMPTY POPULATION.** 0 of 31,137 rows all-time, both spellings, since 2026-07-14. The lifetime status
  vocabulary is exactly three values: failed 18,622 / live 10,391 / deferred 2,124. Two producers exist
  (`registry.ex:5750`, `auto_deploy_worker.ex:188`) and neither has ever fired. Consequences: `deploy_ledger_test.exs:1251`'s
  `assert census.cancelled == 0` is vacuous BY CONSTRUCTION (its fixture inserts no cancelled row);
  `dr-w16-s5`'s criterion *"`cancelled` renders when non-nil — paste both renders"* is **an arm that can never
  fire on prod data**, and is RE-SCOPED to "render when non-nil, proved on a synthetic envelope, with the
  zero-population fact stated in the same commit". D251(c) already recorded the population and already ruled
  that *a tripwire over an empty population is a test that rots unnoticed (D8)*; wave 16 built the cohort
  anyway. **The Go side already carries the invariant the Elixir side lacks** — `cloud_site_cmd.go:2013` states
  "THE BUCKETS SUM TO Rows, AND THAT IS A CONTRACT", enforced at `cloud_site_cmd_test.go:2942`.

### The denominator nobody counted — the wave's largest new finding

- **D291 — THE ROW UNIT IS PROVABLY LOSSY IN A LOAD-DEPENDENT WAY, SO LIVE-PER-ATTEMPT IS A CEILING, NOT A
  FLOOR — IT FLATTERS.** `live_rate` is `rate(live, volume)` where `volume` is a ROW COUNT, and
  `grep -c coalesced` over `deploy_ledger.ex` is **0**. But a large population of real attempts mints NO ROW:
  comparing `AutoDeployWorker` Oban jobs to `trigger='content-auto'` deployment rows, per day —
  **08-01 gap 0 · 08-02 0 · 08-03 0 · 08-04 0 · 08-05 171 · 08-06 1,584 · 08-07 106**. These are publishes
  whose worker job COMPLETED having minted no row, because the `(site_id, environment)` active-deployment index
  refuses a second concurrent production build and `drive/2` either re-drives the in-flight row or defers onto
  it; `Registry.create_deployment/2` (`registry.ex:5145`) is a plain insert with no coalescing branch, so the
  gap can only originate in those two arms. **Every excluded attempt is non-live, so including them LOWERS the
  rate: 2026-08-06 goes 25.67% → 14.94%, a 42% relative cut, on a day when the excluded population was 71.8% of
  the counted one.** A row-based rate therefore silently changes MEANING with publish load. `record_coalesced_attempt/1`
  landed today as `#10248` and is PROVEN DISCRIMINATING — it has fired exactly once, 6 attempts, and the
  independently derived 10:00Z hourly gap is EXACTLY 6 — but `coalesced_attempts` is a column on the ROW and is
  NOT in the census envelope, so the denominator still excludes them and no reader can see them. RULING: the
  headline must NAME ITS BASIS as rows-not-attempts (free, this wave), and the census must emit
  `coalesced_attempts` beside `volume`, never folded into it (`dr-w17-s8`, round 4). HONEST LIMIT: the gap is
  DERIVED from two independent counts with no key linking a job to the row it did not mint — the DAILY figures
  are the robust ones.

### Render economics — measured, and D271 is understated in both directions

- **D292 — THE FREE/EXPENSIVE BOUNDARY OF THE HEADLINE, BY MUTATION.** FREE (fail-set byte-identical to
  baseline): PREPENDING live-per-attempt on the SAME line; DEMOTING the failure rate to a labelled sibling;
  moving the cohort parenthetical onto the live term — **nothing pins the headline's leading term or order**,
  which makes "the failure rate becomes a sibling" a zero-cost correction. EXPENSIVE: live on its OWN line
  breaks `TestCloudDeploymentsBothConventions`, because `censusLineContaining` (`cloud_deploy_census_cmd_test.go:406-415`)
  returns the FIRST matching line despite a docstring claiming "the single rendered line" — **that is the naive
  implementation, and the trap sits one line above the fence.** DISPLACEMENT costs **TWO** tests, not D271's
  one: with `live_rate` on one fixture it breaks one; add it to `censusTodayEnvelope` as well — which any real
  control plane does — and `TestCloudDeploymentsTodayPayload` AND `TestCloudDeploymentsBothConventions` both
  fail on `missing "832 failed"`. **Brief the two-test number.** And `793 deferred` ALREADY prints in three
  places today (headline parenthetical, per-site column, deferrals section), so "the deferral volume prints
  beside it" is met the moment the live term lands next to it — do not invent a fourth deferral surface.

- **D293 — THE PREPEND MUST BE APPLIED IN BOTH BRANCHES OF `deployCensusHeadline`, OR THE `@min_sample` GUARD
  IS VACUOUS.** Three-way mutation: ok-branch-only prepend + a DISHONEST live node (`refused:false, pct:25.0`
  at sample 12) is **GREEN** — the thin envelope takes the REFUSED branch, the live term is never rendered, and
  the existing `pctRe` guard cannot fire; both-branch + the same node is **RED** (`a refused rate must print NO
  percentage anywhere`); both-branch + `refused:true` is GREEN. The guard discriminates in both directions
  ONLY under the both-branch implementation. A builder who prepends in one branch ships a headline that
  silently drops the live rate whenever the failure rate is refused, and passes its own criterion vacuously.

- **D294 — A `--- FAIL` GREP IS NOT ACCEPTABLE GO EVIDENCE: IT REPORTS A CLEAN FAIL-SET ON A BUILD FAILURE.**
  Measured live: `go test ./internal/cli/ | grep '^--- FAIL'` produced an EMPTY fail-set while the package did
  NOT COMPILE (`undefined: lead`), because Go emits `FAIL <pkg> [build failed]` and never `--- FAIL`. Any
  acceptance phrased as "the fail-set diff is empty" is satisfiable by a package that does not build. **Every
  Go gate in this epic must read the EXIT CODE and the `ok <pkg>` tail.** This is the standing test's third
  clause — a guard that cannot lose is a sentence with an exit code — found in the epic's own gate wording.

### Merge reality, and two branches adjudicated

- **D295 — `#10401` IS LAND-READY MECHANICALLY, AND THE ROW MOVE IS PROVED NECESSARY *AND* SUFFICIENT — BUT IT
  HAS ONE CONFLICTED FILE, NOT THREE.** `git merge` reports exactly one `CONFLICT (content)` —
  `payload_key_set_census_test.exs`, three hunks — while `router.ex` (+48/−1) and the Go test auto-merge clean.
  Merging onto main takes `deploy_ledger_reachability_test.exs` from 10/0 to **10 tests / 3 failures**, with the
  designed tripwire firing verbatim (*"delivery/3: declared :unreachable, measured :reachable … It GAINED a
  caller … This is the good direction"*). **MOVING** `{:delivery, 3}` and `{:refusal_phase, 1}` to `:reachable`
  with reasons over the file's own 60-byte floor returns it to 10/0; **DELETING** them instead reds differently
  (`new public, UNDECLARED`), so the move is the only patch that passes. `@publics_floor 16` needs NO raise
  (measured 16 on both trees). `@call_sites_floor` should go **14 → 19**, and the reason is bigger than this PR:
  pristine `origin/main` measures **17** call sites against a floor of 14, so **main is already slack by 3**,
  which the file's own convention forbids — state that split in the PR body or the arithmetic reads padded.
  The resolved census floors are MEASURED on the merged tree at **110 / 221**, not summed from the two diffs.
  Whoever lands it must carry the floors and the row move in the SAME commit or main reds on the second merge
  (the stale-green window). **HONEST LIMIT, and it matters**: a `:reachable` row proves only that a caller
  exists in `cloud/lib` — the file's own moduledoc says *"It does NOT prove any route returns 200"* — and the
  route these two now reach is the one that 403s for everybody. `#10401` converts two functions from "compiles
  into nothing" to "reachable by nobody". It is a PREREQUISITE for leg 1, never a substitute.

- **D296 — `#10129` IS CLOSED AND RE-CUT, NOT LANDED: AS BUILT IT WOULD PUT THE WRONG HEADLINE ON THE ONE
  REACHABLE SURFACE, FASTER.** Trial rebase: 6 conflicted paths / 17 hunks. The Elixir auto-merge D224 called
  "semantically broken" is now WORSE than stated — `deploy_ledger_test.exs:2417` calls
  `DeployLedger.not_attempted_classes/0`, which **`dr-w16-s3` (#10443) DELETED from main on the stated ground
  that it had ZERO callers**; `#10129` is its one caller and was invisible to that census, which measured main
  only. Wave 16's newest guard and wave 10's newest branch shot each other. **That crash MASKS a still-live
  D224 defect**: probe-patching it away fires `BOX_DEPLOY_DISABLED_503 has no agency — the map is not
  exhaustive`, so a builder who "fixes the crash" restores green while leaving two classes at `:ambiguous`
  (D148's forbidden direction). Plus three UNDECLARED publics reding wave 16's reachability guard — one of
  which, `agency_map/0`, is genuinely dead — and four Go reds including `TestRunCloudStatusJSON` (`rank 13,
  want 11`), an end-to-end assertion no prior ledger names, and a tone-hole red that fires at ANY rank
  (`unmetered` ships `tone:""`, which main forbids outright). **DECISIVE**: `box_rates/3` FORKS the denominator
  (`rate(failed, failed + live)` vs `census/3`'s `rate(failed, volume)` with deferred included) and **NEVER
  EMITS `live`**. On guerrilla's live 24 h fold (failed 127 · live 572 · deferred 1,521 · volume 2,220) the
  surfaces read census-failure 5.72% · census-live 25.77% · box_rate **18.17%** · absorption 68.51%. 18.17% is
  BELOW the hardcoded `deployFailingFencePct = 20.0`, so guerrilla renders **`ok`** — the exact string the PR
  was written to abolish — on a box that turned 25.77% of its attempts into a live site. The fence cannot be
  moved to rescue it: `deployRateOf` reads ONLY `node.Rate.Pct`; `Absorption` and `BoxCaused` are decoded and
  printed as prose but can never move the verdict, so the one field naming the real problem is decorative BY
  CONSTRUCTION. Its own 46.28% justification is dead — the daily series crossed 20.0 between 08-06 and 08-07,
  and before the D287 boundary the two denominators were EXACTLY equal (zero deferred rows). Close citing
  D185/D202/D224; re-cut on `volume`, emitting `live`, with the rung reading `absorption`
  (`dr-w17-bl-close-and-recut-10129`).

### Two silent-failure classes adjudicated, one built and one demoted

- **D297 — `Deploy.start/1` IS DELETED, AND THERE ARE FOUR BLIND CALLERS, NOT THREE.** `deploy.ex:563-567` is
  `_ = start_reported(deployment); :ok` — spec'd `:: :ok`, so every `:ok = Deploy.start(...)` in the tree is a
  match that CANNOT FAIL. The fourth caller, omitted by `dr-followup-start-reported-callers`, is
  `resume_orphaned/0` (`deploy.ex:1691`), and it is the worst: its return value IS the reaper's recovery metric
  (`stale_deployment_reaper.ex:50` puts it in the Oban job meta as `resumed`), and it returned `length(orphans)`
  — the count of rows FOUND. **A sweep in which every rescue was refused reported success.** THE ASSIGNMENT'S
  OWN PREMISE IS FALSE AT BOTH ROUTER SITES: the `json(conn, 201, …)` is DOWNSTREAM of the start call in both
  arms (`:11397-11402`, `:12992-12996`), so no byte has been sent and both routes CAN answer
  `503 deploy_not_started` — which reaches a human, because both Go entry points route a non-2xx through
  `cloudError` (`client.go:304-327`), which renders `error: detail`. That false premise is inherited from the
  wrapper's OWN DOCSTRING, which describes call sites it does not have. **RETRY-COPY TRAP**: "re-POST the
  artifact" is a LIE — `settle_deployment_artifact/5` answers a same-sha re-POST `200 already_uploaded` and
  explicitly does NOT re-start the driver; the honest instruction is "mint a NEW prebuilt deployment", and the
  PR must state that the refused prebuilt row is then a DEAD END (`queued`, `claim_epoch = 0`, covered by no
  reaper pass) — a visible dead end is strictly better than a silent lie, but it is not a repair. Built and run
  green this wave: **3,131 tests / 0 failures**, `mix compile --force --warnings-as-errors` exit 0, and a
  mutation witness that fails and discriminates. `dr-followup-start-reported-callers`'s criterion-1 line numbers
  (11240 / 12782) are stale against the real 11391 / 12985 — **the second time that row has gone stale**.

- **D298 — THE MAP-TEMPLATE FAIL-OPEN IS LATENT, NOT LIVE; IT MOVES THE REPORTED RATE BY 0.00 pp; AND ITS FILED
  TASK STATES THE DEFECT BACKWARDS.** `dr-bl-map-landing-empty-marker` says the map landing can "emit an empty
  bp-doc-id and fail the deploy gate closed". IT CANNOT: `listings.ts:178-186` returns the 13-row
  `SAMPLE_LISTINGS` on an unset `LISTINGS_TYPE`, on ANY exception, AND on an empty live result, so
  `listings[0].id` is never empty and the gate can never refuse. The defect is the OPPOSITE — **fail-OPEN**. Its
  criterion 1 targets the `catch`, but the live path is the `!LISTINGS_TYPE` early return ABOVE the `try`, so
  that fix would land as dead code on the managed path. UNREACHABLE at three layers (deploy payload's literal
  7-key env → API's closed 8-key allowlist → shell's 6-key `RUNTIME_ALLOW`), confirmed at the LIVE
  POST-CONDITION: **11 running Next slots on guerrilla, zero `NEXT_PUBLIC_*` and zero `LISTINGS_TYPE` in any
  `/proc/<pid>/environ`** — independently reproducing bp-search-template D75. Zero `place-directory` sites, zero
  of 31,137 rows; all 13 sites curled and no served page carries a `SAMPLE_LISTINGS` id. THE FIX IS THREE
  PARTS: (iii) distinguish unconfigured from empty from upstream-failed — the enabling part, without which (i)
  never executes; (i) carry the status out of `catch`, mirroring `lib/graph.ts:273-283`; (ii) emit
  `bp-corpus-status` via `markers.corpusStatusMarkerValue`. RULING: correctness hardening on a dead limb — do
  NOT rank it above the reachability legs, and do NOT budget it as a reliability win. ADJACENT, UNFILED:
  `templates.ex:84` advertises `place-directory` in the LIVE PUBLIC CATALOG with `NEXT_PUBLIC_FINDER_LANDING`
  in its `env_keys` — a key the payload structurally cannot carry.

- **D299 — THE ETERNAL-QUEUED CLASS IS REAL IN CODE AND UNEXHIBITED ON PROD, AND THE OBAN ZERO THAT SEEMS TO
  CONFIRM IT IS SEVEN-DAY WINDOWED.** The code argument stands: a refused spawn on a `static`-with-`bootstrap_dataset`
  or `node` site leaves `queued` / `claim_epoch = 0`, and no reaper pass covers it. But TWO independent prod
  measurements found ZERO specimens — no `queued` or `building` row at ANY age, only three statuses exist, and
  all 7 `claim_epoch = 0` rows are settled-`failed`. So `in_flight` as a census cohort is empty on prod and any
  acceptance asserting a non-empty one is vacuous-green, the same shape as D290. And `AutoDeployWorker` has
  zero cancelled / zero discarded / zero retried Oban jobs — but `Oban.Plugins.Pruner, max_age: 7 days`
  (`config.exs:262`) and the oldest retained row is EXACTLY seven days old, so that zero is windowed, not
  all-time. Restate `task-c4c9a54cd073e011`'s evidence level and build a detector rather than waiting to catch
  a specimen by hand.

### Fence, re-derived at Decide rather than inherited

- **D300 — CCH's FENCE IS NARROWER THAN THIS EPIC ASSUMED, AND WAVE 48's REGIONS ARE ALREADY SPENT.** The w48
  charter branch adds ZERO new fence text — `grep -c '^+\*\*Wave-48'` over its charter diff is **0**, and the
  fence line is BYTE-IDENTICAL on main and on the branch (`**In fence:** cloud/, api/lib/barkpark_web/live/`).
  All six w48 build slices MERGED at 17:44 (`origin/main` HEAD `9af98373d` IS `#10450`). `attention_order`
  appears ZERO times in the w48 charter and DR D57 claims it as ours; `api/lib/barkpark_web/router.ex` is
  EXPLICITLY out of CCH's fence (CCH D357). **The cloud router's census region is claimed by NO CCH PR.**
  BARRED regardless: `cloud/priv/static/app.js` (D53 + CCH D379, which fences the region to THIS epic's own
  `task-54326937e919e2cf` by id), `cloud/lib/**/web/auth.ex` (LIVE claim — open CCH PR `#9956` edits it today),
  `console-harness.yml`, `__preview__/**`, `__app.test.mjs`. CLEAR: `deploy_ledger.ex`, the cloud router's
  census region, `internal/**` entirely, `templates/**`, `deploy/**`. Note `internal/cloudclient/client.go` is a
  SHARED file with open CCH PR `#10086` at a disjoint region — coordinate, do not assume.

- **D301 — THE CONSOLE STAYS DARK THIS WAVE BY DECISION, AND ITS READ-SET IS PRE-DERIVED SO THE NEXT WAVE
  NEED NOT REDISCOVER IT.** `app.js` fetches EXACTLY FOUR `/v1/operator/*` endpoints — `/autoupdate` (+halt/resume),
  `/fleet`, `/warm-pool`, `/deliveries` — and `deploy-ledger/census` is not among them; all five `census`
  matches in the file are comments about the test harness, and `failure_class` appears nowhere under
  `cloud/priv/static/`. What an operator sees in a browser is one status word per row, on ONE site's page, over
  the last 12 rows; the "needs attention" queue reads no deployment data at all, exactly mirroring the CLI's
  `attentionStatus`. Filed onto `task-54326937e919e2cf` (`dr-w17-bl-console-cannot-read-the-census`). A live
  three-way drift is recorded there too: `app.js`'s `ATTENTION_RANK` is NINE rungs against the Go ladder's
  eleven and the fixture's eleven, with nothing gating it.

### Wave 17 plan — 8 slices, 5 in round 1, sequenced on one contended map

**THE CONTENDED REGION IS `census/3`'s RETURN MAP** (plus `@pairs` and the Go `DeployCensus` family). Four
slices want it — leg 1's scope key, the per-site `live`, the boundary node, and the coalesced-attempt basis —
and they are MUTUALLY EXCLUSIVE in every ordering, so they are a CHAIN: rounds 1 → 2 → 3 → 4. Everything else
is disjoint by construction. Round 1's five file sets: S1 owns `deploy_ledger.ex`'s opts + the router's CENSUS
region + three gate files; S2 owns `cloud_deploy_census_cmd.go(+test)`; S3 owns `sites_cmd.go(+test)` + a
minimal `cloudclient` decode; S4 owns ONE NEW test file and edits nothing else; S5 owns `sites/deploy.ex`,
`template_freshness_worker.ex`, the router's TWO DEPLOY arms and one worker test. S1 and S5 share `router.ex`
at regions ~8,000 lines apart — rebase, never resolve by choosing sides.

| # | Round | Slice | task | Surface | Size | Model |
|---|---|---|---|---|---|---|
| 1 | 1 | The census reaches a real non-admin operator, team-scoped, fail-closed | `dr-w16-s6-team-scoped-census-returns-200` | `cloud/lib` ledger+router, 3 gate tests | large | opus |
| 2 | 1 | Live-per-attempt becomes a co-equal headline and the basis stops lying | `dr-w16-s5-live-per-attempt-co-equal-headline` | `internal/cli` census cmd | medium | opus |
| 3 | 1 | The site-outcome cohort reaches a human, settled-honest, off an already-reachable payload | `dr-w17-s3-site-outcome-cohort-reaches-bp-sites` | `internal/cli/sites_cmd.go` + client decode | medium | opus |
| 4 | 1 | The census cohorts PARTITION volume, and a double-counting cohort reds | `dr-w17-s4-census-cohorts-partition-volume` | one new `cloud/test` file | small | opus |
| 5 | 1 | `Deploy.start/1` is deleted and four blind callers answer honestly | `dr-w17-s5-deploy-start-stops-laundering-refusals` | `cloud/lib` deploy+worker+router arms | medium | opus |
| 6 | 2 | The per-site row names its producer and learns to count `live` | `dr-w16-s4-per-site-row-named-producer` | `deploy_ledger.ex` site rows + census pairs | medium | opus |
| 7 | 3 | The boundary becomes data and the class-continuity gauge can lose | `dr-w16-s7-boundary-and-continuity-gauge` | `deploy_ledger.ex` + census pairs + CLI | large | opus |
| 8 | 4 | The census emits the attempts it excludes, so the rate stops flattering | `dr-w17-s8-census-names-its-basis-rows-not-attempts` | ledger + census pairs + client + CLI | medium | opus |

**HIGH-FLIP-RISK: slice 1's tenancy derivation.** It is DOWNGRADED from the direction's framing by D276 — the
mechanism is precedented three ways and is not a new authorization path — but it remains the one judgement in
this wave that a genuinely independent second re-derivation is owed on before merge, because the defect it
guards against **cannot be exhibited by any fixture drawn from production**: 26 of 27 teams own zero sites, so
every production-shaped fixture is green by construction and the slice's fixture must MANUFACTURE a second
team. A re-read of the builder's reasoning does not count.

**Retired, re-scoped and held.** `dr-w15-s6-live-per-attempt-headline` is RETIRED as ~100% superseded — its
AC1 and AC7 are DONE on main via `#10442`, AC2 is `dr-w16-s5`, AC4 is `dr-w16-s7`. `dr-w13-s7-census-residue-and-per-site-blindness`
is RE-SCOPED to its `deferred_total` half only: its criterion 4 duplicates `dr-w16-s4` verbatim and its AC8
sends a builder after `@go_tag_floor` slack that `#10442` already closed (both floors now sit at ZERO slack,
108 / 221, and both are `>=` only — so a forgotten bump is GREEN and the floor is a convention obligation, not
a red that will catch you). `dr-w15-s5-capability-reaches-bp-cloud-status` is HELD: its dep `dr-w15-s3` is
`#10401`, unmerged and CONFLICTING — and a conflicted PR runs NO workflows at all, so its greens are stale by
construction.

### Wave 2026-08-07 (wave 17) — REVIEWED · Paper `deploy-reliability-wave-17-2026-08-07` · grade **A**

**All five round-1 slices built, reviewed, gate-green on their final state, PUSHED and PR'd. Nothing merged —
the lead merges.** The three round-≥2 slices were withheld BY DESIGN (sequenced-rounds law): they contend
`census/3`'s return map, `@pairs` and the Go `DeployCensus` family, and are mutually exclusive in every ordering.

| Slice | Task | Final branch | PR | Gate re-run on final state |
|---|---|---|---|---|
| Team-scoped census a non-admin can read | `dr-w16-s6-team-scoped-census-returns-200` | `…real-non-admin-oper-0` | [#10472](https://github.com/FRIKKern/barkpark/pull/10472) | 3121 tests, 0 failures |
| Live-per-attempt leads the headline | `dr-w16-s5-live-per-attempt-co-equal-headline` | `…co-equal-head-1` | [#10473](https://github.com/FRIKKern/barkpark/pull/10473) | build 0 · vet 0 · `ok internal/cli` |
| Site-outcome cohort on `bp sites` | `dr-w17-s3-site-outcome-cohort-reaches-bp-sites` | `…reaches-a-human--2-r` | [#10474](https://github.com/FRIKKern/barkpark/pull/10474) | build 0 · vet 0 · `ok internal/cli` |
| The census cohorts PARTITION volume | `dr-w17-s4-census-cohorts-partition-volume` | `…partition-volume-and--3` | [#10475](https://github.com/FRIKKern/barkpark/pull/10475) | 66 tests, 0 failures |
| `Deploy.start/1` deleted, four blind callers | `dr-w17-s5-deploy-start-stops-laundering-refusals` | `…all-four-b-4-r` | [#10476](https://github.com/FRIKKern/barkpark/pull/10476) | full cloud suite 3135/0 · `--warnings-as-errors` exit 0 |

**The number that moved: the census stopped being unreadable, and the deploy route stopped reporting a build
it never started.** Wave 16 proved the instrument correct to the row and simultaneously proved it 403s for
every account that exists. Leg 1 gives it a team-scoped twin on a credential a CI token can hold, fail-closed
by an Elixir-side intersection over the team's OWN site ids, with a `scope` line that names its population
(13 registered vs 12 ever-deployed) instead of leaving an operator to explain the discrepancy away.
`Deploy.start/1` — `_ = start_reported(row); :ok`, spec'd `:: :ok` — is deleted, so the MatchError meant to
signal a refused driver spawn stops being structurally unreachable; both router arms answer `503
deploy_not_started`, the freshness sweep counts `:failed`, and `resume_orphaned/0`'s `resumed:` metric stops
counting rows FOUND. That last one is the wave's sharpest find: the reaper's own recovery metric reported
success on a sweep in which every rescue was refused.

**Reviewer fixes, in place.** (a) `bp sites -h` never mentioned the new cohort or the breaking list-view
`last_deployment` keyset change — both now documented. (b) A refused driver spawn skipped its
`push_event("deployments"/"audit")`, so the 503 left a real committed `queued` row the live console never heard
about; both router sites now announce before attempting the start. (c) `auto_deploy_worker.ex:38` stopped
naming the deleted `Deploy.start/1` (the builder correctly obeyed its FILES fence and filed it; the reviewer is
not fenced).

**Independently re-derived, not re-read.** The high-flip-risk tenancy judgement: `sites.team_id` is
`validate_required` on the Site changeset and `GET /v1/sites` (`router.ex:6425`) scopes by the identical
`Registry.list_sites_for_team(conn.assigns.current_team)` hop under the identical credential — the derivation
is precedented, not novel. The reviewer also re-ran slice 4's deferred-overlap mutation from scratch: 66 tests
/ 2 failures, both the new guard's, with all 62 existing ledger tests green in the same run. **A genuinely
independent SECOND reviewer on the tenancy route is still owed before merge — that dispatch is a manual lead
step**, because no production-drawn fixture can exhibit the IDOR (26 of 27 teams own zero sites).

**What the lead must close on merge.** Every slice leaves its merge-gated criterion open by design.
`dr-w16-s6` additionally leaves criterion 10 an honest `--miss`: the live 200 needs the deploy that merging
causes (`cloud/**` auto-deploys), and the post-merge curl — paired with the `403` on the operator route that
makes the 200 mean something — is stamped in the task's miss note. `dr-w17-s3` ships a **breaking** JSON
change: `bp sites -o json` list rows no longer carry `last_deployment.id` / `.image_tag`, because the wire
does not carry them.

**What is still silent, named honestly.** The basis line's coalesced-attempt numbers are hardcoded dated prose
and nothing reds when they age — `dr-w17-s8` is the fix. A refused PREBUILT row is now a VISIBLE dead end
(`queued`, `claim_epoch` 0, covered by no reaper pass) rather than a silent lie — visible is better, and it is
not a repair (`task-c4c9a54cd073e011`). The partition guard proves the census is self-consistent; it still
cannot lose on UNDER-collection, because every count comes from the same grouped query. And `site_rows/2`
runs the same three-cohort split per site with no partition guard at all.

**What the next wave should take.** The dispatch order is fixed by the map: merge round 1, then
`dr-w16-s4-per-site-row-named-producer` (needs `dr-w16-s6` merged), then `dr-w16-s7-boundary-and-continuity-gauge`
(needs s4), then `dr-w17-s8-census-names-its-basis-rows-not-attempts` (needs s7) — four slices contend
`census/3`'s return map and s8 is the last link. S8 is the one that matters most to the wish: it turns the
hardcoded ceiling into an emitted `coalesced_attempts`, moving 2026-08-06 from 25.67% to 14.94%. Beside them,
the per-site partition guard and the still-unrepaired prebuilt dead end are the two unclaimed silences.

## Wave 20 — the platform is blind to itself, and the harm changed its name again (2026-08-08)

Epic task `task-fb4fb869490b4213` · Wave 20 Paper `deploy-reliability-wave-20-2026-08-08`

**NUMBERING NOTE.** This wave numbers from **D337**. `origin/main` tops out at D301; D302–D321 (wave 18)
and D322–D336 (wave 19) are claimed by two charter PRs that are still unmerged. Every charter fact this
wave cites was read with `git show origin/main:` — the primary checkout's copy of this file is a stale
stump and must never be read as the charter. **D320 is not in this charter at all** (it is an
`overflow-wrap: anywhere` ruling in the console-hardening charter); neither `59.3` nor `50.3` appears here.

### Decisions (wave 20)

- **D337 — DEPLOYS ARE NOT BEING LOST. "MERGED = LIVE" HOLDS, MEASURED, AND `UNCOVERED` CANNOT BE THE
  HONESTY GAUGE.** Over a pinned 30-day window (2026-07-09..08-08), applying `deploy.yml`'s `on.push.paths`
  **era-locally** (the filter grew three times mid-window: `connectors/**` 07-14, `templates/**` 07-16,
  `cmd/**` 07-24), 790 cp-target and 1,172 instance-target commits are ALL covered by a successful run —
  **100.0000%, UNCOVERED = 0, both targets**. And a merge that never got a run does not occur: 2,264 pushes
  to main, 1,373 path-matching, 1,373 with a run, **0 missing**, with a second independent oracle over
  2026-07-28..08-07 agreeing exactly (641 / 394 / 394 / 0). *Why:* the wish's word "fail" has expired; this
  epic sells on cost, service degradation and BLINDNESS, never on lost deploys. And UNCOVERED is pinned at 0
  **by construction** — a deploy ships the whole tree, so any later success covers every ancestor — so it can
  only fire on the last minutes of history. The gauge that moved is **time-to-coverage**: cp p99 46.8 h /
  max 49.5 h, instance p99 36.3 h / max 49.5 h, and over cancelled runs p50 9.1 min / p95 33.3 h / **max
  49.96 h**. Nothing measures it. Filed: `dr-w20-bl-time-to-coverage-is-the-gauge-that-can-move`.

- **D338 — THE 46% CANCELLED COHORT IS QUEUE EVICTION, AND THE REPORTER IGNORING IT IS CORRECT BY DESIGN.**
  All 94 cancelled runs since 2026-08-01 report `jobs=0` — no job was ever created, so nothing was
  interrupted — and lifetimes agree from the other side (cancelled `updated−created` p50 8 s / p95 52 s / max
  192 s against success p50 322 s / p95 668 s). `concurrency: {group: deploy-production, cancel-in-progress:
  false}` keeps exactly one PENDING slot; a third arrival evicts the pending run before it starts. 0 of 348
  cancelled runs across 30 days is uncovered by a later successful descendant. `cch-w42` reached the identical
  structural conclusion from the opposite epic. **Stop re-litigating cancelled runs.**

- **D339 — THE 84-FAILURE MASS IS ONE INCIDENT WITH ONE CAUSE, AND ITS ONLY MITIGATION IS MEASURED AT
  0-FOR-65.** 2026-07-21T07:59:48Z..07-23T08:46:54Z: 121 runs, 84 failure, 37 cancelled, ZERO success. Full
  census (not a sample): 82 of 84 are exit 13 and the same docker-compose network recreate race in two
  phrasings — 65 with `network cloud_default has active endpoints (name:"cloud-control_plane_green-1"
  id:"9a7aab2dba5b")` + `FAILED twice`, 15 with the sibling daemon message `is not connected to the network
  cloud_default` + `SLOT BOOT FAILED`, 2 with both, 2 exit 255. **The endpoint id is byte-identical across 27
  hours**: one wedged endpoint re-hit by every merge, not 84 races. In **83 of the 84 the INSTANCE job
  SUCCEEDED** — guerrilla deployed throughout, which is why the epic narrated a control-plane outage as a
  deploy outage. The #5584 retry (5866f3b90) was live for the final 27 h; 66 of 84 failures postdate it and
  65 of those carry `FAILED twice`. **A slice sold as "harden the retry" would be selling a lever measured at
  zero.**

- **D340 — THE RACE IS LATENT, ITS FIX LIVES ONLY IN MUTABLE BOX STATE, AND WAVE 20 FILES IT RATHER THAN
  ALARMING ON IT.** Zero occurrences across 323 successful runs (232 of which ran the CP job) and 171
  cancelled runs since 2026-07-24, with a **positive control** proving the detector fires on blackout run
  29992317636 — and that control reads the OLDEST log in scope, so the zero is not a retention artifact. But
  `cp-deploy.sh` has had no commit since 5866f3b90; there is no stale-endpoint detection, no `docker network
  disconnect`, no prune, and no docker version pin anywhere under `deploy/`; `instance-deploy.sh` has zero
  race handling at all. The blackout ended by a manual act with **no commit in the gap**. *Why filed, not
  built:* an alarm over an unexhibited class is this epic's own standing test failing on itself.
  `dr-w20-bl-cp-deploy-cannot-clear-a-wedged-endpoint`. **Re-derivation trap, mandatory:** run the census with
  `-R FRIKKern/barkpark`; from a non-repo cwd `gh` dies, every fetch returns empty, and the pipeline prints a
  clean, comforting ZERO at exit 0.

- **D341 — THE CONTROL-PLANE SERVING-SHA VITAL IS A CLOCK, NOT AN ALARM, AND WAVE 20 BUILDS IT.** Drift was
  measured at **0** at three independent layers — the box checkout equals `origin/main`; the running image was
  built 33 s after the pull; and the RUNNING BEAM's compiled code (`rpc FailureCopy.domain_stage_remediation`
  returning HEAD's sentence, not its parent's) plus the served `app.js` md5 both match HEAD. Merge to live was
  ~2m54s. *Why a clock:* an alarm keyed on `drift > 0` would be unfalsifiable in the window we can observe —
  the exact shape this epic has already refuted twice (the eternal-queued reaper at n=0, `already_running` at
  zero occurrences). The instrument always emits `git_sha` + `serving_since`, so a future non-zero reading is a
  CHANGE in a number already on screen. **Absent means `nil`** — never `"unknown"`, never `0`.

- **D342 — THE SHA RIDES `/health`, NOT A NEW ROUTE AND NOT THE AGENT.** `cp-deploy.sh` never installs
  `barkpark-agent` (`git grep -n agent origin/main -- deploy/cp-deploy.sh` is EMPTY), so an agent-borne CP sha
  needs a new systemd unit AND a new credential. `/health` is already 200, already unauthenticated, already
  smoke-tested. `send_health/1` passes the map through whole, so **no router change is needed**. **THE EXPORT
  IS THE LOAD-BEARING LINE:** `cp-deploy.sh` exports nothing today, and compose's bare-`KEY` form passes a
  variable only when the invoking shell has it — so shipping the reader and the compose line WITHOUT
  `export BARKPARK_GIT_SHA="$NEW"` (placed after the `.env` source, sourced from `$NEW`, never a second
  `rev-parse`) yields `git_sha: null` forever and looks built. Honest limit: the container leg is proved by
  document, not by run — this host has Docker 29.6.1 with no compose plugin, and the repo already records
  (`notifications_platform_admin_env_test.exs:21-23`) that no Elixir test can observe it. The vital is L4
  until a post-merge `curl … | jq -r .git_sha` is quoted.

- **D343 — THE CUSTOMER-BOX "FRESHNESS RAIL" IS A RELEASE RAIL, NOT A SHA RAIL. NOBODY HAS A SHA READER.**
  This CORRECTS the direction this wave inherited. `Registry.refresh_update_status/1` computes nothing — it
  GETs the instance's own `/v1/admin/self-update` and MIRRORS its `check` block; `git_commit` appears nowhere
  in that path, and `bp cloud status` carries no `git_commit` and no `version` key at all. So `update_state`
  is a release-catalogue verdict the box grades ITSELF on, and `behind` means "a tag exists I am not on",
  never "code was merged that I am not running". Measured today: all six prod boxes read `current` at
  `0.2.25 == 0.2.25`, while their reported commits sit **0 / 213 / 578 / 872 / 2,454 behind** and one is NULL.
  Three of the stale ones additionally read `bucket: healthy, status: ok`. The serving-sha vital is therefore
  the product's **first**, not a port. Filed: `dr-w20-bl-instance-target-has-no-serving-sha`; the unearned
  green itself remains `dr-bl-w6-update-state-current-is-an-unearned-green`, unfixed and aged.

- **D344 — `deploy.yml`'s CP SMOKE IS THE UNBACKSTOPPED ONE, NOT `cp-deploy.sh`'s.** This CORRECTS the digest.
  `cp-deploy.sh:129-141` already requires a bad-creds `POST /v1/auth/login` to answer 401, with a comment
  naming the 16 h outage the `/` gate slept through. `deploy.yml:114-120` accepts `200|301|302|404` with no DB
  probe — and `/` is `send_dashboard` → `send_file(200, priv/static/index.html)` with **zero Repo in the
  path**, so it is structurally incapable of failing on a DB-dead box. Demonstrated live without harming prod:
  `https://barkpark.cloud/definitely-not-a-route-xyz` → 404, which the regex ACCEPTS. The fix is a copy of a
  backstop that already exists 80 lines away in the same repo; `deploy.yml:156-158`'s hard `test "$code" =
  "200"` on the instance job is the counterexample proving the asymmetry is a defect. Honest bound: a FULLY
  dead CP already fails (Caddy 502 is rejected); this closes the PARTIAL-death class — the one that happened.

- **D345 — THE ARM-ROUTE SILENCE IS NOT ZERO: ONE LIVE SITE HAS BEEN A PUBLIC 404 FOR 208 DEPLOYS WHILE
  REPORTING `SWITCH ok` AND `exit 0`.** 9 markers against 10 site dirs on guerrilla; `/sites/search/` returns
  404 while the other nine return 200. `search` is a strict PREFIX of `search-capstone` and `search-ember`,
  and both matchers match the bare substring — `grep -q "$marker"` (site-deploy.sh:2227, :1861;
  site-deploy-node.sh:263) and `active_caddy_port`'s awk `index($0, m)`. Chain, each link measured:
  `active_caddy_port` → 8506 (the sibling's port) → `active_slot` matches neither PORT_A 8404 nor PORT_B 8405
  → `CUR_SLOT=""` → the "first deploy" ARM branch → the already-armed guard matches the SIBLING and returns 0
  **without writing anything** → `emit SWITCH ok` → exit 0. All 208 runs are first deploys (206 `for slot a`,
  zero slot b, no `.previous`), so blue/green rollback for this site is silently absent too. **The cause is the
  marker PREDICATE, not the global sed the code comment blames — and `grep -qw` does NOT fix it** (`-` is a
  non-word character, so `…:search` still word-matches `…:search-capstone`). Both engines' self-tests pass
  today (128/128, 108/108) and neither ever arms a prefix slug: the whole class is outside both oracles.

- **D346 — THE ARM DECISION HAS NO DURABLE CHANNEL AT ALL, WHICH IS WHY ITS ZERO LOOKED LIKE HEALTH.**
  `leaving Caddy untouched`, `skipping /sites/` **and** `route already armed` all appear ZERO times across
  1,178 durable `.log` files — and the third MUST fire on every re-deploy of an already-armed site
  (astro-search alone has 244). `.log` carries raw child output only; `.status` carries `BPSTAGE` lines only;
  every `log()` line dies on stdout. So route-arm incidence is currently **unmeasurable through the intended
  channel**, and any new alarm would be as invisible as the old one. The channel exists and is free: `emit
  ROUTE` is already a BPSTAGE line held DELIBERATELY outside `DeployRunner`'s `@stage_names`
  (site-deploy.sh:2279-2283, self-test-pinned at :1486-1489), so it is durable in the fold and cannot flip a
  verdict. Wave 20 emits ROUTE on the SUCCESS path too, in both engines. **No exit code changes** — D327's
  report-don't-fail posture stands, and `dr-w19-bl-arm-route-incidence-then-fatal` still owns the fatal
  question; this wave makes it answerable.

- **D347 — THE COST DECOMPOSITION IS RE-DERIVED, AND NOTHING RETRIES.** Live post-boundary: APL **3.71 = 2.62×
  per-site repetition × 1.42× sites-not-reaching-live**, with fan-out CONFIRMED and refined 4.01 → **4.10
  sites per publish**. Oban `avg(attempt) = 1.000`, max 3, **6 of 12,644 jobs ever exceeded attempt 1** — so
  D223's "3.64× retry" factor is **MISNAMED**. It is debounce-cycle plus deferral-chain repetition, and calling
  it retry is what pointed this epic at the wrong mechanism twice. The deciding split: (site, content_rev)
  pairs that never deferred carry **1.26** rows; pairs that deferred carry **4.04** (856 vs 818 pairs). All
  amplification above the cadence floor is the deferral RE-QUEUE CHAIN (`Deploy`'s defer arm →
  `requeue_rebuild/1` → `enqueue/1`, minting another job 60 s out), at observed depths 1..6 =
  184/143/102/59/21/4. Fan-out explains VOLUME, not the ratio.

- **D348 — THE AMPLIFICATION IS A QUEUEING-OVERLOAD ARTIFACT, AND IT IS A THRESHOLD, NOT A GRADIENT.** Supply
  is 1 build slot / p50 63.2 s ≈ **0.95 builds/min**; demand is 5 sites × 1 build/61.0 s cycle ≈ **4.9
  builds/min** — 5.3× oversubscribed, which is why **68.3%** of post-boundary attempts defer and each refusal
  re-queues. At fixed supply, volume and ratio are not separable: any lever that drops demand under ~0.95
  builds/min collapses the chain toward the ~1.26 cadence floor, and any lever that does not cross it barely
  moves the number. **W = 90 or W = 120 would be an expensive nothing.** Stated as a model, not a measurement —
  nobody has run this system above W = 60, and the cheapest reversible test of it is
  `dr-w20-bl-debounce-window-live-experiment`.

- **D349 — LEG B's RULING, ON THE MERITS, FOR THE FIRST TIME: NOBODY EVER RULED, AND THE DEMAND CUT IS THE
  OWNER'S CALL.** Read literally on `origin/main`: **D206** FILES the cut and conditions it ("The label must
  exist BEFORE the cut, not after"); **D223** rules that label unbuildable ("RULING: no label, no column, no
  migration"); **D228(f)** says the cut therefore "needs a fresh argument, not a label". So the fence everyone
  has cited is a **stalled filing whose only gate was demolished by the very next wave**, and wave 20 must not
  pretend to "overrule D206" — it issues the first merits ruling REQUEST. What a cut cannot touch: `jarl.no` /
  `www.jarl.no` ride barkpark `9fb839d6`, **not guerrilla**; 12 of 13 sites carry zero custom domains, one team
  owns every site, 26 of 27 teams own none. What a cut DOES cost, said out loud: five sites carry ~99% of all
  deploys ever, so every rate, cohort and percentile this epic has built is calibrated on those rows — cutting
  sites shrinks the epic's own test population. "Working as designed, and the only lever is fewer demo sites"
  is a legitimate outcome. Filed as a human gate: `dr-w20-hg-demand-cut-is-the-owners-call`.

- **D350 — THE FRESH ARGUMENT IS SEARCH LATENCY, AND IT IS LIVE, NOT HISTORICAL. THIS OVERTURNS WAVE 19'S
  VERDICT *AND THIS WAVE'S OWN SURVEY*.** Both engines ARE niced (`nice -n 19` + `ionice -c3`,
  site-deploy.sh:2126-2128 and site-deploy-node.sh:1678-1680, landed together in de7d4783d), ionice is
  installed, and idle-class inheritance was proven on a live running build. **It did not fix it.** 4,280
  POST-nicing `documents-api` search events, bucketed by build concurrency reconstructed from every run's own
  `started_at`/`finished_at`: p50 **1,246 ms at 0 builds → 3,585 ms at 1 → 8,631 ms at ≥2** — a **6.9×**
  blow-up at exactly the condition the code comment names. The confound runs the wrong way for the null: the
  concurrency-0 bucket carries the HEAVIEST queries (median 1,621 results vs 674) and is still fastest, and the
  effect survives banding on `result_count` in 3 of 4 bands. ≥2 concurrent builds hold **12.03% of wall
  time**, ≥3 hold 8.02%, peak 6. **Nothing caps cross-site build concurrency:** `site_deploy: 1` serialises
  only the START (`start_and_report` returns on `{:ok, :started}`) and the box flock is PER-SLUG. The unfenced
  resource is **MEMORY, not CPU** — nicing bounds CPU share and IO priority, not page cache, and Postgres runs
  `shared_buffers=128MB` with `effective_cache_size=4GB` on a 3,819 MB swapping box at a 98.527% hit ratio over
  1.11 bn block reads, while `npm ci` evicts exactly that cache. **Do NOT quote the pre/post-nicing aggregate
  (1,147 → 3,161 ms): it is mix-confounded by ~16× corpus and traffic growth.** The load-bearing number is the
  within-period concurrency correlation, which is observational, not an intervention — a clean A/B needs a
  deliberate build storm on a quiet box. Also: the survey's "30-60× below the claim" was taken under ONE niced
  build on a quiet host, which is precisely the condition the comment does NOT name.

- **D351 — THE "8 s COLD SEARCH" IS NOT A COLD PATH.** Five never-issued queries returned in 77-92 ms on an
  idle box; repeat-vs-novel showed no cold penalty. The 8,022 ms reading and the 8,631 ms p50 at concurrency ≥2
  are the same number. **Leg B must never be revived on a cold-search story.**

- **D352 — THE BACKOFF LEVER IS REACHABLE, IS BUILT THIS WAVE, AND ITS CEILING IS STATED.** The question as
  filed contains a category error — `@unique states` are `[:available, :scheduled]`, so a conflicting sibling is
  one of those BY CONSTRUCTION and the DB cannot be asked (a coalesced insert leaves no row). The measurable
  form: the Oban job does **not** hold `:executing` during the build (p50 `completed_at−attempted_at` = 0.30 s
  against a p50 build of 63.2 s — the `:executing` sliver is **0.49%** of a 61.0 s cycle) because `perform/1`
  spawns a supervised driver and returns. So the defer path never sees a conflict and a longer window inserts
  verbatim. Consequence worth recording: the moduledoc's claim that dropping `:executing` is what mints the
  trailing rebuild is **inoperative in production** — the trailing rebuild is delivered by the job having
  COMPLETED. Constraints unchanged: cap ≤ 240 s **or** `timestamp: :scheduled_at`, never `replace:`. Honest
  ceiling: this collapses the CHAIN toward ~1.26 only if aggregate demand crosses under supply (D348), it does
  **not** make a publish go live faster, and `@schedule_in_default` is GLOBAL — it slows any real customer site
  on this control plane too.

- **D353 — DO NOT RE-FILE THE NULL `deferral_cause` MASS AS A CLASSIFIER HOLE.** 1,818 of 2,331 deferred rows
  carry a NULL cause and a `detail` reading `already_running`, which looks exactly like a 78% classifier gap.
  It is a clean column-writer DEPLOY BOUNDARY: NULL rows end 2026-08-07 10:01:54 and non-NULL begin 10:12:35.
  The real, smaller observation is that post-boundary **all 513 classified deferrals are
  `BOX_AT_CAPACITY_DEFERRED` and zero are `BOX_BUSY_DEFERRED`** — a two-arm taxonomy running on one arm.
  Relatedly, any series crossing **2026-08-05 21:27:11** must be split or it compares a failure count to a
  deferral count (pre: 0 deferred / ~17 k failed; post: 1,413 deferred / 18 failed).

- **D354 — THE RAW-CAPTURE LEAK IS LIVE ON MAIN AND IS REPAIRED THIS WAVE.** `failure_copy.ex`'s own moduledoc
  (:184-187) rules that any path rendering a raw capture without classifying must be `strip_ansi() |> scrub()`
  — "measured 2000/2000 leaked under `scrub |> strip_ansi` and 0/2000 under `strip_ansi |> scrub`" — while
  `notifications/event_email.ex:214` and `:250` both call bare `FailureCopy.scrub(d)`. A colourised
  `client_secret=…` still ships to an operator's inbox. `dr-w20-s4` carries the ~3-line fix plus the boundary
  test; #10019 is RE-CUT, not rebased (D355), and cited as prior art.

- **D355 — THE OPEN-PR DISPOSITIONS, MEASURED WITH `git merge-tree --write-tree`, NOT `mergeStateStatus`.**
  **#10518 is MERGED** (1c85657dd, 2026-08-07T23:35:24Z) — leg A item (4) is already done, `dr-w19-s5` and
  `dr-w19-s7` are round 1 for this wave, and **five wave-19 rows are one lead-close from done** (`dr-w19-s1`
  7/8, `dr-w18-s1` 8/9, `dr-w19-s2` 7/8, `dr-w19-s3` 7/8, `dr-w19-s4` 8/9), each blocked solely on its verbatim
  "MERGE-GATED (the LEAD closes this)" criterion. **#10518 pays TWO of them — count the PR once.** `dr-w19-s3`
  carries no PR number in its row; stamp #10563 when closing or the link is lost again. Dispositions:
  **#10400 REBASE AND FIX** (18 behind, ZERO conflicts, four reds all its own table/exhaustiveness pins — but
  re-derive them on today's main, since its base predates #10519's rewrite of the same file; porting is the
  stale-green shape); **#10129 CLOSE** (95 behind, 6 conflicts including both files leg A must open, asserts a
  TEN-rung ladder against main's thirteen — this EXECUTES D242's standing ruling, unexecuted since wave 13);
  **#10086 RE-CUT small**, sequenced after `dr-w19-s7`'s `DeployCensusSite` edit; **#10019 RE-CUT tiny**
  (D354). Filed: `dr-w20-bl-open-pr-disposition-10129-10086-10400-10019`.

- **D356 — `dr-w18-s5` IS CLOSED AS SUPERSEDED BY `dr-w19-s7`, NOT MERGED INTO IT.** Zero work lost (0/14).
  Two independent reasons: its calibration terms `settled_absorption` and `hard_failure` **do not exist
  anywhere in the tree** (`git grep -c … origin/main -- cloud internal api` exits 1 with no output), a full
  wave after the slice meant to ship them merged; and the two rows are **contradictory, not overlapping** — s5
  demands a new attention rung, a K-of-N sustain device and an 11→12 rung ladder move, while s7's criterion 2
  forbids all three. Its hourly framing is also dead on measurement (`@min_sample 200` reached by 6 of 432
  hourly buckets, 0 of 20 post-cut, against 20 of 21 daily). Its one surviving item — the `go-tests.yml`
  fixture-path fix — is carried forward as `dr-w20-bl-w18-s5-fixture-path-survives-its-supersession`.

- **D357 — `dr-w19-s7`'s CRITERION 5 IS RE-CUT: THE SERVER ALREADY EMITS PER-SITE `live`, THE GO DECODER DROPS
  IT, AND NOTHING REDS.** `site_row/2` emits `live` positively — landed in #10519 at 2026-08-07 23:38, AFTER
  s7 was written — with a comment forbidding `volume − failed − deferred` because "a subtraction would fold
  in-flight and cancelled rows into `live`". The live wire carries it (a real 200 on a team credential returned
  `{"failed":1,"live":109,"deferred":325,"volume":435}`; 109+325+1 = 435 exactly). `DeployCensusSite`
  (client.go:1953) has six fields and **no `Live`**, so the per-site `live` decodes to nothing. And nothing
  catches it: D260's per-struct pin (payload_key_set_census_test.exs ~:874) iterates the cohort keys against
  `Go.struct_tags(src, "DeployCensus")` ONLY, while its UNREAD arm compares against a FILE-GLOBAL tag union in
  which `live` already appears — **D260's own documented blind spot, reproduced one struct over, on this
  epic's own new key**. Re-cut to three clauses: `Live *int` (POINTER, so a CP predating #10519 renders
  UNMETERED and never zero-live); the rate read POSITIVELY off the wire with the subtraction forbidden in the
  PR body; and the D260 assertion EXTENDED to `DeployCensusSite` with fail-before pasted. Do **not** re-cut it
  to "fleet-level with the absence named" — the absence is a two-line decoder gap, and naming it as a missing
  capability would ship a false statement.

- **D358 — THE FLIP NO-OP AND THE FOREIGN-VHOST CLOBBER: ONE REFUTED, ONE SECOND-ORDER, NEITHER BUILT — AND
  THE POST-FLIP CURL BELONGS TO ANOTHER EPIC.** Foreign-vhost clobbering by `instance-deploy.sh` is REFUTED on
  both live Caddyfiles (guerrilla: exactly ONE `localhost:400[01]`, one vhost, 9 site routes all on
  4010/4020/85xx-98xx, and running the real grep+sed against a copy changes only line 82; the CP's Caddyfile is
  three lines). The class IS real on the site RUNTIME writer, already repaired as
  `runtime-caddy-preserves-foreign-vhosts` (#8198) — a different writer on a different box. The `FLIP_FROM`
  fallback no-op is reachable only through a Caddyfile that has ALREADY lost its slot upstream: mechanically
  proven (a byte-identical file passes `caddy validate`, reload succeeds, the probe is print-only, exit 0) and
  never observed — sell it as a second-order amplifier or not at all. **The post-flip health curl finding is
  ALREADY OPEN in the PDS epic** as `pds-bl-w49-post-flip-curl-only-logged` (#9644), citing
  instance-deploy.sh:258/:793 and cp-deploy.sh:155 and declaring `deploy/**` IN-FENCE for PDS — wave 20 does
  **not** re-file it, and any deploy-reliability slice touching those lines needs an owner-level cross-epic
  negotiation. The residues that ARE unfiled: `cp-deploy.sh:194`'s unchecked `systemctl restart
  barkpark-provisioner` under a script with no `set -e`, and `cp-deploy_test.sh`'s total silence on the flip
  (66 lines, 7 checks, all the dwb-16 control-url pin) where the static engine's harness asserts it. Filed:
  `dr-w20-bl-provisioner-restart-cannot-fail-the-deploy`, `dr-w20-bl-arm-and-flip-paths-with-no-selftest-row`.

### Wave 20 plan — 8 slices, 7 in round 1, file sets disjoint within the round

All builders are **opus** this wave: Fable is unavailable (lead standing note), so the model axis carries no
information here and every brief is written to be buildable at opus depth. Two slices carry a
**HIGH-FLIP-RISK** line for the reviewer; a third inherits one.

| # | Slice | Task | Surface | Round | Flip-risk |
|---|---|---|---|---|---|
| 1 | The control plane states its own sha (a clock on `/health`) | `dr-w20-s1-control-plane-states-its-own-sha` | `cloud/…/health.ex` + test, `cloud/docker-compose.yml`, `deploy/cp-deploy.sh` | 1 | REACHABILITY — the container leg is proved by document, not by run |
| 2 | The CP smoke stops accepting a 404 | `dr-w20-s2-cp-smoke-can-fail-on-a-dead-box` | `.github/workflows/deploy.yml`, `scripts/check-deploy-smoke.sh` | 1 | — |
| 3 | The site route marker stops prefix-colliding; ROUTE becomes durable | `dr-w20-s3-site-route-marker-stops-colliding` | `deploy/site-deploy.sh`, `deploy/site-deploy-node.sh` | 1 | BLAST RADIUS — the predicate governs every live site's public route |
| 4 | The raw capture strips ANSI before scrubbing | `dr-w20-s4-raw-capture-strips-ansi-before-scrub` | `cloud/…/notifications/event_email.ex` + new boundary test | 1 | — |
| 5 | `bp cloud status` reads the deploy verdict (criterion 5 re-cut, D357) | `dr-w19-s7-status-reads-the-deploy-verdict` | `internal/cli/cloud_status_cmd.go`, `internal/cloudclient/client.go`, `payload_key_set_census_test.exs` | 1 | — |
| 6 | The fleet digest gets a real audience; the brake is ruled | `dr-w19-s5-digest-audience-and-brake-ruling` | `cloud/…/notifications.ex` + 2 tests | 1 | TENANCY (inherited) — a fleet-wide digest is a cross-team disclosure question |
| 7 | Depth-derived refusal backoff on the defer paths | `dr-w20-refusal-backoff-depth-derived` | `cloud/…/sites/auto_deploy_worker.ex`, `sites/deploy.ex` + test | 1 | — |
| 8 | The deploy smoke asserts the serving sha | `dr-w20-s8-deploy-smoke-asserts-the-serving-sha` | `.github/workflows/deploy.yml`, `scripts/check-deploy-smoke.sh` | **2** — after slices 1 **and** 2 merge | — |

Slice 8 is round 2 for two reasons, both hard: it reads the `/health` key slice 1 creates, and it edits the
exact smoke step slice 2 rewrites. Dispatching it beside either produces a BLOCKED report or a guaranteed
conflict. Within round 1 every file set is disjoint — note in particular that slice 4 owns
`notifications/event_email.ex` while slice 6 owns `notifications.ex`, and slice 1 owns `deploy/cp-deploy.sh`
while slice 3 owns `deploy/site-deploy*.sh`.

**What the lead owes on merge, beyond the eight merge-gates:** close the five wave-19 rows that are one
lead-close from done (D355), stamping #10563 onto `dr-w19-s3`, and counting #10518 once.

**Coverage.** Both fleets reported in full — no survey deficit and no verify deficit. Every premise this
wave builds on was smoke-tested against `origin/main` before it reached a brief: `health.ex` and
`send_health/1`, `cp-deploy.sh`'s `.env` source and `$NEW`, `deploy.yml`'s smoke and diff-base blocks, both
engines' marker predicates and `active_caddy_port`, `event_email.ex`'s two bare `scrub` sites,
`FailureCopy.strip_ansi/1`, and `emit ROUTE`'s position outside `@stage_names`. Three cited authorities were
read for COVERAGE and found not to cover what they were cited for: D206 (files, does not authorise), D320
(not in this charter), and the direction's "#10518 is open" (merged).


## Wave 21 — exit 0 must mean the outcome happened (2026-08-08)

Epic task `task-fb4fb869490b4213` · Wave 21 Paper `deploy-reliability-wave-21-2026-08-08`

**NUMBERING NOTE.** This wave numbers from **D359**. `origin/main` now carries D337–D358 (wave 20, merged);
D302–D336 are still stranded on six unmerged charter/wave-log PRs (#10522, #10496, #10612, #10407, #10173,
#10133) and this wave cites none of them. Filed as `dr-w21-bl-charter-prs-strand-d302-d336`. Every charter
fact below was read with `git show origin/main:`; the primary checkout's copy of this file is an 813-line
stump and must never be read as the charter — **and must never be committed over it**, which is why this
wave's charter edit was made in a worktree cut from `origin/main`, not in the primary checkout.

### Decisions (wave 21)

- **D359 — THE ANCESTOR RULE. EQUALITY BETWEEN `github.sha` AND THE SERVED SHA IS REFUSED, BY TWO
  INDEPENDENT MECHANISMS.** `cp-deploy.sh:44-58` does `git pull --ff-only origin main` and sets
  `NEW=$(git rev-parse HEAD)`, exporting `BARKPARK_GIT_SHA="$NEW"` — **tip-at-pull-time, never the run's
  headSha** — so a run fired for one sha routinely delivers a DESCENDANT. Mechanism one, eviction: run
  31235286567 fired for `7f5f10b8d`, five siblings were evicted as cancelled, and the box was already
  serving `2673eb0`. Mechanism two, and far more common: `572d51e13` and `695a485ce` are **DOCS-ONLY**
  commits matching none of `deploy.yml`'s paths, so they had **no deploy run at all** — yet production
  serves `572d51e13`, delivered by a run fired for `6383ab46e`. Compare says `ahead 10 / behind_by 0`.
  **RULING: the smoke asserts `git_sha` non-null AND `${{ github.sha }}` is an ANCESTOR of (or identical to)
  the served sha. Equality would red ten healthy merges and teach the lead to ignore the gate.** This
  RE-CUTS `dr-w20-s8` criterion 2 verbatim; that row is superseded by `dr-w21-s1` and the lead closes it
  cancelled.

- **D360 — THE ORACLE IS THE GITHUB COMPARE API, NOT `git merge-base`, ON FOUR INDEPENDENT COUNTS.**
  `gh api repos/:repo/compare/${{ github.sha }}...$served --jq .status` → PASS on `ahead|identical`, FAIL on
  `behind|diverged`. (a) **It needs no checkout.** `deploy.yml:99`'s control-plane checkout is a bare
  `actions/checkout@v4` — depth 1 — and the served descendant's object is simply absent; simulated on a real
  shallow clone, `git merge-base --is-ancestor` dies `fatal: Not a valid commit name`, **RC=128**. (b)
  **`fetch-depth: 0` alone is not the fix**, and neither is depth-1-plus-a-fetch: a plain in-step
  `git fetch origin main` **does not deepen** a shallow clone — RC stayed 128. The merge-base recipe costs
  two coupled config changes AND a full-history clone on the deploy hot path. (c) **RC=128 is not RC=1**, and
  the natural `if git merge-base …; then` form collapses "object absent" and "not an ancestor" into one
  branch — reporting a CONFIGURATION failure as "the box is behind". Compare's failure modes are HTTP-typed.
  (d) It **fail-closes on the jq-null trap for free**: `jq -r .git_sha` on `{"git_sha":null}` prints the
  literal four characters `null`, and feeding that to compare returns **HTTP 404**. `contents: read` is
  already granted at `deploy.yml:35` and `gh` is preinstalled. Belt-and-braces: assert the key explicitly
  with `jq -er '.git_sha // empty'` first, so the message names the missing key rather than "Not Found".
  Accepted cost: a network dependency on api.github.com in the deploy gate; a flaky red is the correct
  failure direction here, a vacuous green is not.

- **D361 — THE TRIPWIRE IS STRUCTURALLY BLIND TO THE ASSERTION THIS WAVE ADDS, AND ITS OWN `--selftest` HAS
  ZERO CALLERS. MUTATION-PROVED.** `extract_cp_smoke` (`scripts/check-deploy-smoke.sh:52-60`) prints only
  lines inside the control-plane step literally named `/Smoke test/`. A mutated `deploy.yml` carrying a new
  `- name: Assert serving sha` step with a full `git_sha` + compare assertion matched **0** extractor lines,
  and `check-deploy-smoke.sh` printed `OK` with **RC=0**. So the most natural implementation of the wave's
  crown slice ships a green guard over a completely unguarded invariant. Compounding: `deploy.yml:91` runs
  the guard **bare** and nothing repo-wide runs `--selftest`, while **nineteen** sibling scripts do run
  theirs in CI. **RULING: extract the whole control-plane job's `run:` bodies (a second literal step name
  goes blind again on the next rename), add a positive assertion that the comparison exists AND is the
  ancestor form, plant four negatives including "move the assertion to a differently-named step", and change
  `deploy.yml:91` to `--selftest`.**

- **D362 — THE INSTANCE ALREADY STATES ITS SERVING COMMIT. D343's HEADLINE AND `dr-w20-s8`'s CRITERION 6 ARE
  FALSE, AND LEG TWO MOVES FROM CAPABILITY TO CONSUMPTION.** `GET /status.json` emits `commit`,
  unauthenticated, at `api/lib/barkpark_web/router.ex:1583` (`pipe_through(:api)` only), shipped 2026-07-28
  in `c73f22a0b` (#6422). Live at 2026-08-08T03:44Z guerrilla returned `commit = "2673eb009"` — a **nine**-
  character short sha — and the compare API accepts it verbatim (`ahead / 4 / 0`). So the instance leg of the
  sha assertion is buildable TODAY and rides `dr-w21-s1`, not a future slice.
  **The self-report has an exact silent-failure population, and it is the wrong one:** `commit` is present on
  3 of 6 cloud boxes, and the three that omit the key entirely — dooodo `e221e7dd5`, muscle-1, Gyldendal
  `c80168100` — are **exactly** the boxes whose serving code predates `c73f22a0b`, 5-for-5 by
  `git merge-base --is-ancestor`. The field is absent precisely on the boxes stale enough to need it.
  `Status.commit/1` documents "never nil, never absent … renders `unknown`", and that guarantee binds only
  code that already contains it — which is the whole trap. **The registry's agent-derived `git_commit`
  (5 of 6) is therefore the better oracle for a fleet verdict**, and `/status.json` is the right oracle for a
  deploy-time assertion against the one box CI just moved.

- **D363 — COMMIT DISTANCE IS COMPUTED ON THE CONTROL PLANE, OVER THE PUBLIC UNAUTHENTICATED COMPARE API,
  INTO SEPARATE COLUMNS — NEVER A FIFTH `@update_states` RUNG.** This is the ruling that finally pays
  `dr-bl-w6-update-state-current-is-an-unearned-green`, open since wave 6.
  **The mechanism, by line:** `Registry.refresh_update_status/1` (`registry.ex:3710`) GETs the instance's
  `/v1/admin/self-update` and persists its `check` block verbatim; `git_commit` appears nowhere in it. The
  plane holds a commit for five of six boxes and grades freshness on a release TAG the box awards itself, so
  2,468 commits of drift render as the same string `0.2.25`.
  **Route 1, agent-side `rev-list --count HEAD..origin/main`, is REJECTED on truth grounds, not capability
  grounds** (production really does wire a checkout, `cmd/barkpark-agent/main.go:103-105`): the only
  `git fetch origin` on an instance lives INSIDE the update run (`instance-deploy.sh:301-302`,
  `scripts/self-update.sh:41-42`) — nothing on a cron, nothing on the beat — so `origin/main` is frozen at
  the last successful update and the 2,468-behind box would report ~0. It is most optimistic exactly where it
  is most wrong: the unearned green with extra steps.
  **Route 2, a CP-side ordered main-sha ledger, is REJECTED because it does not exist**: `deployments` is the
  SITE build table whose `git_ref` is the customer CONTENT sha (`registry.ex:5509/:5673`), no migration under
  `cloud/priv/repo/migrations` creates a commit index, and a ledger with a gap reports distance 0 — fail-OPEN.
  **Route 3 is ADOPTED.** One call, `GET /repos/:repo/compare/<served>...main` with the BRANCH NAME as head
  so GitHub resolves the tip server-side, answers ancestry AND distance: `identical` → current, `ahead` with
  `ahead_by: N` → N behind and provably an ancestor, `behind`/`diverged` → a box serving code that is not on
  main, which is its own loud row and has no reporter today. Verified live: identical → `identical 0 0`;
  unknown sha → **404**, so a garbage or null commit fails CLOSED. Anonymous budget 60/h/IP. This copies a
  decision the repo already made one layer down — `api/lib/barkpark/self_update/client/github.ex` calls this
  exact endpoint and its own moduledoc rules the budget sufficient for an hourly check. Do **not** route it
  through `BarkparkCloud.GitHub.Real`: `config.exs:95-96` defaults to `GitHub.Fake` and `runtime.exs:147`
  swaps in `Real` only under an App credential its own moduledoc says has never existed. Use a new narrow
  module over `Billing.HttpClient` (`:httpc`, verified TLS), client injected.
  **THE SEPARATE-COLUMN RULING IS PROVED, NOT ASSERTED.** `@update_states` is
  `~w(unknown current behind disabled)` (`registry/barkpark.ex:76`) with six live consumers, three of them
  control flow. A scratch ExUnit run measured a fifth rung: the rollout candidate query (`registry.ex:3874`,
  `where: b.update_state == "behind"`) returns the row for `"behind"` and **nil** for `"stale_commit"` — a
  box graded by commit distance would be permanently excluded from the rollout that would fix it; and **one**
  staging box in the new rung flips `staging_gate_open?()` (`registry.ex:4102-4114`) from **true to false**,
  freezing every prod advancement, **fail-CLOSED**; and the settle check
  (`autoupdate_rollout_worker.ex:86`) never fires, so the grace timer expires and the box is paused for
  investigation. So: `commit_distance` + `commit_ancestry` + `commit_distance_checked_at`, a new narrow
  changeset, no gate touched.
  **THE NULL RUNG IS THE POINT.** muscle-1 reports `agent_status: offline`, `health_status: unknown`,
  `git_commit: ""` — and still self-certifies `update_state: current` with a fresh `update_checked_at`,
  because `refresh_update_status/1` reaches the box directly and never asks whether the row is otherwise
  alive. A NULL sha, a 404 and a rate-limit refusal must ALL land `unknown` / `nil` and render UNMETERED,
  **sorted to the TOP** — `ORDER BY commit_distance NULLS LAST` would bury exactly the boxes the leg exists
  to surface, re-minting D343 in a fresh column on the box already lying hardest.
  **The population, re-taken 2026-08-08T03:05Z against tip `572d51e13`, three oracles agreeing to the unit**
  (`git rev-list --count`, positional index in `git log`, compare `ahead_by`): Guerrilla `2673eb009` **4** ·
  gyl `f3ee2984d` **227** · jarl `952106581` **592** · dooodo `e221e7dd5` **886** · Gyldendal `c80168100`
  **2,468** · muscle-1 **NULL**. All six read `current` at `0.2.25 == 0.2.25`, and **four** — not three, as
  D343 says — also read `bucket: healthy, status: ok`. Every reported sha is an ancestor of main, so distance
  is well-defined for all of them. Gyldendal additionally reads `health_status: down` in the registry while
  its own `/status.json` answers `"status":"operational"`: three verdicts, no two consistent.

- **D364 — THE `≥2`-CONCURRENT-BUILD REGIME WAS CLOSED BY A SHIPPED FIX, NOT BY A LULL — AND THAT FIX IS THIS
  EPIC'S LARGEST UNREPORTED WIN. D350's MEASUREMENT STANDS; ITS MECHANISM CLAUSE IS FALSE AS WRITTEN.**
  D350 reproduces to the digit on its own window (n=4,456: p50 1,101 ms at 0 builds → 3,487 at 1 → **8,631**
  at ≥2 → 8,429 / 7,959 / 8,374; ≥2 held 12.01% of wall; peak concurrency 6), and its confound check runs the
  wrong way for the null — the concurrency-0 bucket carries the HEAVIEST queries (result_count p50 687 vs
  674-679) and banding to `result_count>=21` preserves the whole gradient.
  **But "nothing caps cross-site build concurrency" conflates RUN concurrency with COMPILE concurrency, and
  two caps exist.** The box-side fd-7 fleet flock (`site-deploy-common.sh:282 BUILD_GATE_SLOTS=1`,
  fleet-wide on `/var/lock/barkpark-site-build.lock`) landed `3e27a4915` on 2026-07-30, a week before the
  storm, and *structurally cannot* produce the observed signature — a flock lets all N units START and blocks
  them inside `npm ci`, so parallel `started_at` persists. What stops starts is an ADMISSION DOOR:
  `ef77af274` (#9827) added `@build_slot_capacity 1` to `api/lib/barkpark/sites/deploy_runner.ex`, a
  GenServer-serialized refusal before a unit exists. **Its first refusal fired at 2026-08-06T22:29:27Z**,
  matching the concurrency step to the second (last parallel fan-out: five runs started 22:20:44-49; first
  sequential run 22:29:26, two sites refused one second later). From 2026-08-06T23Z through 2026-08-08T03Z
  **every** hour has max concurrency exactly 1 and **0.00%** of wall at ≥2.
  **Demand did not cool — it rose 5.5×**: runs/hour 35-41 → 48-51, and counting REQUESTS (runs + refusals)
  2026-08-07T01Z carried 50 runs + 174 refusals = **224 requests/h** against 41 at 08-06T16Z. 1,757 door
  refusals since, all logged at `[info]`.
  **THE NUMBER: search p50 8,314 ms → 781 ms across the door** (n=2,572 pre / 3,029 post, split on
  22:29:27Z) — a **10.6×** improvement in the largest customer-visible harm this epic has ever measured,
  confirmed live at three novel queries (733 / 737 / 678 ms). Deploy success rose **197/351 (56%) → 657/666
  (98.6%)** over the same boundary. **And nothing reported any of it.** `avgDurationMs` is emitted from
  24,832 crystals (`search/intelligence.ex:961`) and rendered by nobody; `build_slots` / `runner_queue_len`
  are served (`instance_site_deploy_controller.ex:64`) and consumed by nobody — and `build_slots` is a module
  attribute, a constant, not a measurement. Concurrency is reconstructible only post-hoc from a **rotating
  ~40-hour** `terminal.json` corpus, so if the door ever fails open the 8.3 s regime returns silently.
  **D351's "77-92 ms idle floor" is REFUTED** — eight novel queries return **587-721 ms**. Its conclusion (no
  cold path) survives; its number is 8× optimistic and must never become a baseline.
  **Two measurement traps, both hit live:** the migration is named `create_media_search_events` and the PK is
  still `media_search_events_pkey`, but the live relation is `search_intel_events` — querying the migration's
  name returns `ERROR: relation "media_search_events" does not exist`, a FALSE "no data" if trusted; and the
  table mixes `source=documents-api` (n=6,087, p50 5,695) with `source=federated` (n=982, p50 23), so any
  unbanded p50 blends two populations. **D350's 6.9× ratio must not be re-used in any form.**
  **CONSEQUENCE FOR D349.** D350 was the "fresh argument" D228(f) demanded for the demand cut. It has been
  **discharged by a fix, not by a cut.** The packet ships with its harm marked REMEDIATED, in the PAST tense
  with the cause named — never "dead since 08-06T22Z", which reads as a lull and invites its return — and the
  concurrency lever struck as ALREADY PULLED rather than unavailable. It never quotes 8,631 ms or 6.9× as
  today's customer experience. `dr-w21-hg-demand-cut-packet-regime-remediated`.

- **D365 — THE FLEET BUILD CAP'S FAIL-OPEN IS STRUCTURALLY SILENT AND MEASURED AT ZERO: FILED, NOT BUILT.
  THIS IS THIS EPIC'S FIFTH REFUSAL OVER AN EMPTY SET, AND THAT IS THE POINT.** `build_gate_acquire`
  (`site-deploy-common.sh:311-341`) fails OPEN in three branches — no `flock(1)`, an undeletable lock dir
  (falling back to a TMPDIR path, so two engines can resolve DIFFERENT paths and not serialize at all), an
  unopenable lock file — each `return 0`, each reporting via `log()` (`:36`, stdout prose) and never `emit()`
  (`:55`, the BPSTAGE protocol the plane parses at `sites/deploy.ex:1863`). The ONLY consumer of
  `admission gate is OPEN` repo-wide is a `--self-test` assertion at `site-deploy.sh:1936`. So the box's only
  cross-site cap can be entirely OFF while the plane reports exit 0.
  **All three strings return `-- No entries --` over guerrilla's FULL journal retention** (back to
  2026-07-29T16:49:38Z, 3.7 G — essentially the gate's whole life), as does the 900 s lapse refusal
  `FLEET BUILD SLOT`, so **D38's honest bound still holds and did not silently expire**. The branches are
  structurally unreachable today (`/usr/bin/flock` present, `/var/lock` `drwxrwxrwt`, lock file live with a
  moving mtime), and the deployed script is byte-identical to `origin/main`
  (sha256 `525f2ba9d0244…02825`), so the mechanism is not accidentally true via staleness.
  **What IS non-empty is the queue**: 4,529 busy events in 7 days against 4,525 drains, paired by PID —
  mean wait 94.8 s, **max 319 s** against a 900 s budget. Real headroom, and a gauge nothing reads: that is
  `dr-w12-bl-build-clock-has-no-reader`, and the `log`→`emit` change belongs there as a rider.
  **Re-derivation trap, mandatory:** `journalctl -g` prints `-- No entries --` on no match — ONE LINE — so
  `| wc -l` reads 1 and is indistinguishable from a real hit. Print the matches; never count them.

- **D366 — THE DELIVERY GAUGE IS DARK IN PRODUCTION, AND ITS TEST ASSERTS THE ONE ARM PRODUCTION NEVER
  RUNS.** `bp cloud deployments -o table` against the live control plane renders, to every real operator:
  `delivery — how long content waited to reach the web / NOT MEASURED — this control plane sends no delivery
  census.` Cause, two live curls in one minute: the CLI reads `GET /v1/deploy-ledger/census` (the TEAM route,
  `router.ex:3610`), which `Map.put`s only `:scope`; the `:delivery` node is added ONLY by
  `deploy_census_json/2` (`:9523`), reachable ONLY from `GET /v1/operator/deploy-ledger/census` (`:3556`),
  gated by `require_platform_operator` → **403** `{"error":"forbidden","scope":"platform",
  "required":"platform_operator"}` to a real account token. **Wave 15's slice 3 shipped a reader onto a route
  nobody can reach, and waves 16 and 18 pointed the human verb at a route that does not carry it.** And the
  test carries the false belief in a comment — `cloud_deploy_census_cmd_test.go:871-876`: *"The route emits it
  now … so an envelope that CARRIES the node must never render the sentence that says it doesn't"* — asserted
  against a fixture it built itself. Textbook vacuous green, on this epic's own instrument.
  **THE TENANCY TRAP, and it is why this is HIGH-FLIP-RISK:** `DeployLedger.delivery/3`
  (`deploy_ledger.ex:1257`) accepts only `:site_limit` and `:as_of`; its query filters `inserted_at` and
  `environment == "production"` and **nothing else** — it is FLEET-WIDE. A naive `Map.put(:delivery,
  delivery(from, to))` onto the team route would put other teams' `site_id`s into a team-scoped body. The fix
  threads `:site_ids` through, mirroring `census/3`. This pays `dr-w18-bl-team-census-has-no-delivery-node`,
  which predicted the mechanism to the line number; no sibling row is filed.

- **D367 — THE ARM DECISION IS NOW DURABLE AND STILL REACHES NO PLANE AT ALL, AND THE CHEAP PATH DOES NOT
  EXIST.** Production launches transient systemd units and reconstructs status from files
  (`deploy_runner.ex` `reconstruct/2`, ~:1290) — the in-process Port path whose `ingest_line` comment is
  usually cited is NOT what prod uses. Neither of its two channels carries ROUTE. (1) **ZERO of 1,226 `.log`
  files on guerrilla contain a `name=ROUTE` line**, and a known ROUTE-emitting run's log contains ZERO
  `BPSTAGE` lines of any kind — because `emit()` writes to stdout and `$BARKPARK_SITE_STATUS_FILE`, never to
  `$BARKPARK_SITE_LOG_FILE`, which only `log()` writes. The log tail structurally cannot carry a stage line.
  (2) `fold_status_file` reads the file that DOES have ROUTE and discards it through
  `parse_stage_line/2`'s `name in @stage_names` guard (`:278`). And the cloud plane has nothing either:
  `deployments` has **no `log_tail` column at all**, and of **19,327** rows carrying `console` entries, **0**
  contain "ROUTE" and **0** contain "BPSTAGE". So the reporting slice is strictly LARGER than hoped — a
  sibling channel must be built, or ROUTE admitted to `@stage_names` (a D346 doctrine change, which must also
  move the ExUnit pin D368 installs).
  **Incidence today is 0 of 10, and the zero is five hours old.** 15 ROUTE emissions since the engines gained
  it at 2026-08-08T02:36:09Z, all `status=ok`: 14 `already armed`, 1 `armed` — that one being
  `search`/`37cf23399bde8804`, **D345's 208-deploy public 404, repaired and witnessed**. Coverage is 6/6 as a
  clean step function at the engine mtime (the three non-emitting runs are each explained by timing, not by a
  gap). All 10 live sites carry an identity-matched marker and serve 200; the six `proof-20260718-*` 404s
  have **zero-byte** status files and fail the criterion's own predicate. But this is a POST-REPAIR zero
  against D345's pre-fix n=208, and no new site has been created since — so it bounds "is anything broken
  now" (no) and does **not** bound "how often does arming fail on a new site's first deploy".
  **`dr-w19-bl-arm-route-incidence-then-fatal` therefore CANNOT honestly close as "counted, not fatal" until
  a counter exists** — a verdict resting on a report that does not exist is the exact silence this epic is
  about. The two rulings are coupled. Filed: `dr-w21-bl-route-decision-reaches-no-plane`. **Pre-loaded
  vacuous-green trap:** dev/CI/macOS fall back to the in-process Port, where ROUTE WOULD land in `run.log` —
  a test asserting "ROUTE reaches the log tail" passes in CI and is vacuous against prod.

- **D368 — THREE DEFECTS IN THE GUARD FAMILY THIS EPIC LEANS ON HARDEST, AND A PREMISE CORRECTION.**
  **The correction first: nothing removed assertion rows.** `git log --oneline 2514084d9..origin/main --
  deploy/` is EMPTY — #10607 is still `deploy/`'s tip — so its 322/177 claim is honest. The 320/176 reading
  is produced by the recipe: `git archive origin/main deploy | tar -x` omits the one file three rows are
  guarded on (`site-deploy.sh:1544-1550`, `if [ -f "$RUNNER_EX" ]` over
  `api/lib/barkpark/sites/deploy_runner.ex`). Add that one file and both totals land exactly on 322/322 and
  177/177.
  **(1) THE SKIP IS SILENT AND GREEN.** Delete `deploy_runner.ex` and the self-test prints
  `320/320 checks passed` / `PASS` / exit 0 — no SKIP banner, no count assertion. Every OTHER conditional in
  the file prints `[selftest] SKIP` AND is hard-failed by `BARKPARK_SELFTEST_REQUIRE_E2E=1`. This is the one
  conditional that can disappear without saying so. Latent, not active.
  **(2) THE GUARD RIDES THE WRONG PATH FILTER, AND THIS ONE IS ACTIVE.** `deploy-harnesses.yml` triggers on
  `paths: ["deploy/**", …]` — `api/**` is not there. A PR adding `ROUTE` to `@stage_names` — the exact D346
  violation these rows exist to catch — touches no `deploy/**` path, so the only assertion protecting the
  doctrine **never fires on it**. The assertion works perfectly: mutating `@stage_names` reds exactly those
  two rows (`310/322 FAILED (2)`). It is simply unreachable from the change that would break it. There is no
  twin on a required lane (`git grep stage_names origin/main -- api/test` is EMPTY), and
  **`Deploy harnesses` is not a required context** — the set is exactly
  `["Elixir gate","PR references an active task","Cloud gate","Console gate"]`. **RULING: the durable fix is
  an ExUnit pin on the required Elixir lane; the path-filter widening is belt-and-braces.**
  **(3) THE NODE ENGINE'S HARDENING IS MUTATION-INVISIBLE.** #10607's review fix was applied verbatim in both
  engines, but only the STATIC engine has rows that tell the two predicates apart: reverting the node
  engine's `site_route_marker_re` from `([^a-z0-9-]|$)` to `([[:space:]]|$)` leaves it at **177/177 PASS**,
  while the same mutation on the static engine reds exactly the two delimiter rows. The six direct-predicate
  rows (`site-deploy.sh:1656-1667`) exist only in the static engine. An L4 claim in an L1 costume, in the
  file governing every live site's public route.
  **METHOD TRAP, MANDATORY:** do NOT mutate `site_route_marker_re` with `perl -pi -e` — the replacement
  contains `$)`, which perl interpolates as the GID list variable, silently producing a garbage regex that
  reds ~20 unrelated rows and looks exactly like a devastating finding. Use an exact-string replace in
  python3.

- **D369 — THE INSTANCE SMOKE COVERS THE DEAD-POOL CLASS AND NOTHING ELSE. D344 IS NARROWED, NOT
  RETRACTED.** The narrow claim is TRUE and has FIRED: `/api/schemas` → `LegacyController.schemas/2` →
  `Content.list_schemas/2` → `Repo.all()` (`content/schema.ex:104`), no cache anywhere, and run
  30686555528 (2026-08-01T05:49:12Z) logged `guerrilla /api/schemas = 500` and failed the step. **But that
  run's job list is `changes/success, instance/failure, control-plane/success` — no `report-deploy-failure`
  job existed yet. The oracle's only true positive in repo history reported to nobody.** It is 1 of 115
  failed runs across 2,054 runs, and over the 100 most recent runs it reached a conclusion on only 21 of 49
  instance jobs — ~43% exposure.
  **What it cannot lose on:** an EMPTY catalog (mutation-proved — the verbatim predicate passes on a 200 with
  body `[]`; `legacy_controller.ex:109-123` has no emptiness check); the ENTIRE authenticated stack (the
  route pipes through `[:api, LegacyDeprecation]` only, deliberately un-token-gated, live 200 with no
  Authorization header); stale code; a deploy that exits 0 without moving (`instance-deploy.sh:311-315`
  coalesces); a flip lost onto a live SIBLING slot serving old code (only a flip onto a DEAD port is caught).
  **And one survey claim is also wrong:** the outer smoke does NOT duplicate the inner health gate — the
  inner gate probes `http://localhost:${TARGET_PORT}/api/schemas` PRE-FLIP, direct to the slot, no Caddy, no
  TLS, no DNS; the outer traverses public HTTPS through Caddy. The true duplicate is
  `instance-deploy.sh:793-794`, which only LOGS. So the workflow smoke is the only place that public-path
  predicate is ever asserted — a reason to strengthen it, not dismiss it.
  Cheap wins available and filed: the bad-creds 401 probe transplants **unchanged** (live 401 on
  `POST /v1/auth/login` with an invalid address, no credential introduced); a non-empty-body assertion is one
  `jq length` away; `check-deploy-smoke.sh` has NO instance-side coverage by construction (`job ==
  "control-plane"`); and the smoke step declares `GUERRILLA_HOST` as `env:` and never uses it, hardcoding the
  URL. `dr-w21-bl-instance-smoke-cannot-fail-on-an-empty-catalog`.

- **D370 — THE PDS FENCE IS FILE-SCOPED, NOT TREE-SCOPED, AND WAVE 20 CROSSED IT ON EXACTLY ONE FILE.**
  Read from **PDS-D716** (`bp-pds-charter.md:15029-15046`, the last fence adjudication), not from the
  paraphrase in `pds-bl-w49-post-flip-curl-only-logged`, which quotes the superseded wave-36 enumeration.
  D716 rules `deploy/instance-deploy.sh` and `deploy/cp-deploy.sh` **IN-FENCE for PDS**, and in the same
  breath **"FENCED OUT THIS WAVE, MEASURED: … `deploy/site-deploy*` … (deploy-reliability wave 1)"** — PDS
  has already ceded `site-deploy*` to this epic by name. So `deploy/**` is split down the middle. Wave 20's
  #10607 and #10563 touched ceded ground; **only `7f5f10b8d` (#10605) edited `cp-deploy.sh`, and that is the
  single unnegotiated crossing** — already merged, uncontested, disclosed here rather than reverted (the
  serving-sha clock this wave's crown depends on is inside it). Also load-bearing and re-confirmed: **any
  `deploy/**` byte deploys BOTH production hosts** (`deploy.yml:79` `^(cloud|deploy|internal|cmd)/` → cp,
  `:86` `^(api|internal|deploy|connectors|templates)/` → instance). And **#9644 is a GitHub ISSUE, not a PR**
  (`gh api …/pulls/9644` → 404) — nothing was ever merged through it; reasoning that treats it as landed work
  is reading a backlog row as a shipped fix.
  The two cp-deploy silences D358 names are re-measured and **both are n=0**: across 150 successful
  `deploy.yml` runs (118 with a CP job, the full ~7-day log-retention window), **118 `provisioner: active`**
  and **118 `image-bake timer: enabled`**, with no other value ever; live CP shows `NRestarts=0`,
  `Result=success`, and zero `Failed to start|entered failed state` in 30 days. A naive
  `grep -ci failed` over that unit **over-counts 26-to-0** — every hit is an application-level warm-refresh
  WARNING. Not built. (Note the filed row's line cites are 8 lines stale, drifted by #10605's own edit.)

- **D371 — MERGE-TO-SERVING LAG IS MEASURABLE FOR THE FIRST TIME, NOTHING RECORDS IT, AND `serving_since` IS
  THE WRONG KEY TO RECORD.** `Health.serving/0` computes `serving_since` live from `:erlang.monotonic_time/0`
  against `:erlang.system_info(:start_time)`; `git grep serving_since origin/main -- cloud` outside tests
  returns ONLY `health.ex`. No table, no column, no worker, no scrape — every read is a point sample the next
  container replacement destroys. Live at 2026-08-08T03:14Z: #10616 merged 02:42:39Z as `572d51e13`,
  `/health` reported that sha with `serving_since` 02:45:42.628915Z — **3m03.6s**. A 147-merge proxy over
  ~55 h gives min 153 s / **p50 446 s** / p90 621 s / max 20,020 s, and the proxy OVERSTATES by ~55 s against
  the one directly-observed pair, so the true p50 is ~6.5 min. **This does not contradict D337's cp p99 of
  46.8 h** — that is time-to-coverage over long quiet periods; this is lag at merge cadence. Both are true
  and a gauge must state its window.
  **Two traps.** (a) `health.ex:54-58` says in its own docstring that `serving_since` answers "how long has
  this PROCESS been up", NOT "how long has this SHA been live" — a bare `docker restart` resets it and makes
  the lag read SMALLER than the truth: a gauge a restart can improve. Record `(sha, first_seen_at)`. (b) The
  20,020 s outlier (run 31121348964) is **5h24m47s of GitHub runner QUEUE** before the first job's first
  step; the deploy itself took 8m52s, no sibling deploy run existed in the window, and 99 unrelated workflows
  created in the same ten minutes shared the starvation (median 3h25m). A single number will blame the deploy
  pipeline for CI capacity: split merge→run-start from run-start→serving.
  **Where it surfaces:** the deploy census is the only surface whose vocabulary already meets this epic's
  honesty bar (refusal-capable quantiles, mandatory population, window, as-of, `STILL WAITING >= X`), and it
  must be a SECOND block — the existing one's clock is `deployment row: inserted_at → became_live_at` over
  SITE CONTENT. But the census AWAITS a command; `digest_email` is the only PUSHED surface and it renders
  `Registry.Barkpark` rows only — **the control plane is not a row on any human surface** (`bp cloud status`
  returns six rows, all customer boxes). `dr-w21-bl-merge-to-serving-lag-has-no-recorder`.

- **D372 — D354's MERGED FIX COVERS ONE OF SIX DISPLAY BOUNDARIES, AND THE LEAK IS LIVE ON MAIN TODAY,
  MUTATION-PROVED.** #10608 (`d8126c1ef`) fixed exactly the two sites D354 named (`event_email.ex:226`,
  `:280-281`). Booting main's `FailureCopy` and A/B-ing seven PTY shapes with a **non-prefixed** 14-character
  secret: `scrub |> strip_ansi` leaks in **5 of 7**, `strip_ansi |> scrub` in **1 of 7**, and **`humanize/1`
  as shipped on main leaks in 5 of 7** — including `\e[31mapi_key=…`, `pass\e[1mword=…` and `Bea\e[0mrer …`.
  `humanize/1` is `classify |> scrub |> strip_ansi` (`failure_copy.ex:382`) and its unclassified
  pass-through arm IS a raw capture by D354's own definition; it reaches a customer's chat channel through
  `render.ex:205` and the API through `router.ex:11024`. Separately `router.ex:11043` still ships
  `failure_reason_raw: … |> scrub() |> strip_ansi()` — **the leaky order on a field literally named raw.**
  **Main is internally inconsistent:** `failure_copy.ex:176` rules that raw captures must be
  `strip_ansi |> scrub` and says `humanize` "MUST stay that way", while five of its own raw paths do the
  opposite. **THE FIXTURE IS THE TRAP:** a first probe using an `sk_live_` value found NO leak, because the
  #9731 provider-prefix clause catches those order-independently — a prefixed fixture makes the WRONG order
  look safe, exactly as `failure_copy_test.exs:909-975` warns. #10019 still carries the unmerged remainder
  (`FailureCopy.raw/1`, the `humanize/1` reorder with `classify` still first, `router.ex:11043`, and an
  8-test HTTP/API boundary suite at a DIFFERENT path from main's 5-test email suite — neither covers the
  other); it is 131 behind with 3 conflicts, all in notification/router plumbing, while `failure_copy.ex`
  auto-merges CLEAN. **One residual hole neither fix closes:** the OSC shape (`\e]0;t\ain` + `api_key=`)
  leaks under BOTH orders — stripping leaves `inapi_key=` and the `(?<![A-Za-z0-9])` lookbehind is blocked by
  the `n`. `dr-w21-bl-raw-capture-order-still-leaks-on-five-boundaries`, priority 1.

- **D373 — THE DEPTH-DERIVED BACKOFF IS DELIVERED AND THE OUTCOME IS FLAT, AND
  `dr-w20-refusal-backoff-after-census` CANNOT CLOSE ON TONIGHT'S WINDOW.** #10611 merged 02:35:41Z but the
  honest boundary is the first row on the new code, **02:39:14Z** — the containers both postdate the first
  rung job, so container start time is not the live-since bound. **The mechanism is proved:** pairing every
  post-boundary deferral to its AutoDeployWorker job on its own `site_id`, depths 1→9/9, 2→8/8, 3→5/5,
  4→3/3, 5→3/3 matched `least(60*depth, 240)` exactly, **collapsed_to_60 = 0** — the Oban `site_id` unique
  did not eat the longer delay, and the depth-3 gap is **121.0 s, min = max**, against a flat ~60 s at every
  depth 2-9 before. Coalescing holds at the cap: zero overlapping pending pairs per site.
  **But the outcome is FLAT and it was already flat.** attempts-per-live is **3.15 before and 3.15 after** on
  the identical query; mean deferral depth went slightly UP (2.26 → 2.41). The apparent improvement the task
  would credit (its stated BEFORE of 3.83) **predates the backoff** — a 3.15 was already measured on
  pre-backoff code. Report FLAT; the criterion explicitly licenses it.
  **Three hard bounds.** The AFTER window is 32 minutes, n=27 rows, 5 sites, right-censored — it structurally
  cannot contain a long chain, so its apparent collapse is an artifact. Depths ≥4 (the 180 s and 240 s rungs)
  are UNEXERCISED post-merge; the cap is unproven by run. And the abandonment question has **no base rate**:
  all-time max depth is 9 against a bound of 12, only two rows ever exceeded 7, and 24 h of abandonment-shaped
  failure reasons returns zero — so "no regression" here means "no power to detect one".
  **A real semantics finding, and it undermines the framing every measurement in this epic has used:**
  `defer/3` computes `prior = consecutive_deferrals(site, cause)` — keyed on **site + cause, not
  content_rev** — so depth is a per-site consecutive-refusal streak that CROSSES publishes and resets only on
  a success (observed live: one site ran depth 3 at one rev, depth 4 at another, went live at a third, then
  reset to 1). Every "rows per (site, content_rev)" metric, **including D347's own baseline**, therefore
  splits one real chain across several groups — and longer gaps make it worse. Re-take at ≥12 h.
  **Unmeasurable by design, and worth a row:** when a plain 60 s publish enqueue conflicts with a pending
  240 s defer job, Oban returns the existing job and writes NO row — so "a fresh publish inherits up to 240 s
  of someone else's backoff" cannot be counted from `oban_jobs` at all.

- **D374 — WHAT WAVE 21 REFUSED, AND WHY THE REFUSALS ARE THE POINT.** Four candidate slices died on
  measurement, and each death is recorded so a later wave does not re-derive it from the same wish:
  the build-gate fail-open (n=0 over the full journal, preconditions unreachable — D365); the cross-site
  concurrency cap (already exists, already at its floor N=1, and the lever was already pulled — D364); the
  two `cp-deploy.sh` silences (0 of 118 control-plane deploys — D370); and an arm-route fatal ruling (0 of 10
  live sites, but a five-hour-old post-repair zero with no counter to make "counted" meaningful — D367). Set
  against them, the three sets this wave DID build on are all measured non-empty: six boxes reading `current`
  at 4 / 227 / 592 / 886 / 2,468 behind plus one NULL; a delivery gauge rendering `NOT MEASURED` to every
  real operator on a 403-gated route; and a tripwire mutation-proved to print `OK` RC=0 over an unguarded
  invariant. **This epic's discipline is not that it finds problems — it is that it can tell an empty set
  from a full one, and says which out loud.**

### Wave 21 plan — 6 slices, 5 in round 1, file sets disjoint within the round

| # | Slice | Task id | Files | Round | Flip-risk |
|---|---|---|---|---|---|
| 1 | Both targets assert the served commit (ancestor rule, compare API), and the tripwire can see it | `dr-w21-s1-both-targets-assert-the-served-commit` | `.github/workflows/deploy.yml`, `scripts/check-deploy-smoke.sh` | 1 | **HIGH — the oracle choice (ancestor vs equality) and the extractor's proved blindness** |
| 2 | The plane grades freshness by COMMIT DISTANCE, in its own columns | `dr-w21-s2-plane-grades-freshness-by-commit-distance` | migration + `registry/barkpark.ex`, `registry.ex`, `workers/update_status_worker.ex`, new `github/commit_distance.ex` + test | 1 | **HIGH — the NULL rung must render UNMETERED and sort to the TOP, never 0** |
| 3 | `bp cloud status` stops dropping the commit the plane already stores | `dr-w21-s3-cloud-status-carries-the-commit` | `internal/cli/cloud_status_cmd.go` + test | 1 | — |
| 4 | The commit-distance verdict reaches `/v1/barkparks` and `bp cloud status` | `dr-w21-s4-commit-distance-reaches-humans` | `web/router.ex` (`barkpark_json/4`), `cloud_status_cmd.go` + test | **2** — after slices 2 **and** 3 merge | — |
| 5 | The deploy self-tests stop skipping silently; `@stage_names` gains a required-lane gate | `dr-w21-s5-deploy-selftests-stop-skipping-silently` | `deploy/site-deploy.sh`, `deploy/site-deploy-node.sh`, `deploy-harnesses.yml`, new api ExUnit pin | 1 | — |
| 6 | The delivery gauge stops being dark: the TEAM census route carries a scoped delivery node | `dr-w21-s6-delivery-gauge-stops-being-dark` | `web/router.ex` (census region), `deploy_ledger.ex`, new test, one Go test comment | 1 | **HIGH — TENANCY: `delivery/3` is fleet-wide and a naive port leaks other teams' `site_id`s** |

Slice 4 is round 2 for two hard reasons: it reads the three columns slice 2 creates, and it edits the exact
projection slice 3 rewrites. Within round 1 every file set is disjoint — note in particular that slice 2 owns
`registry*` while slice 6 owns `web/router.ex`'s deploy-ledger census region, and that slice 4's later edit to
`barkpark_json/4` lands in the same file as slice 6 but a different region, so it rebases onto slice 6 rather
than racing it. Every builder is Opus (Fable unavailable this run).

**HIGH-FLIP-RISK, named for the reviewer:** slices 1, 2 and 6 each carry a judgment a second independent
re-derivation should re-take before merge — the sha oracle, the UNMETERED rung, and the delivery node's
tenancy scoping. The wave spawns ONE reviewer, so dispatching a genuinely independent second reviewer on
those three is a manual lead step; review's job is to NAME when independence is owed.

**Filed, not built (the visible backlog this wave seeded):**
`dr-w21-bl-merge-to-serving-lag-has-no-recorder` · `dr-w21-bl-build-gate-fail-open-is-silent` ·
`dr-w21-bl-route-decision-reaches-no-plane` · `dr-w21-bl-instance-smoke-cannot-fail-on-an-empty-catalog` ·
`dr-w21-hg-demand-cut-packet-regime-remediated` ·
`dr-w21-bl-raw-capture-order-still-leaks-on-five-boundaries` (priority 1 — a live secret leak) ·
`dr-w21-bl-charter-prs-strand-d302-d336`.

**What the lead owes on merge, beyond the six merge-gates.** Close the eight rows that are one lead-close
from done, all of them on PRs verified green (zero FAILURE/CANCELLED/TIMED_OUT checks, all four blocking
gates SUCCESS on each): `dr-w18-s1` and `dr-w19-s1` on **#10518** — the same PR, **counted once** —
`dr-w19-s2`/#10562, `dr-w19-s3`/**#10563** (the link D355 warned would otherwise be lost),
`dr-w19-s4`/#10564, `dr-w19-s5`/#10610, `dr-w20-s1`/#10605, `dr-w20-s4`/#10608. Three further rows
(`dr-w20-s2`, `dr-w20-s3`, `dr-w19-s7`) each need one line added to a **merged** PR body — an owner ruling,
not a mechanical fix, because back-filling evidence into a merged body is the shape this epic distrusts.
Close `dr-w20-s8` as **cancelled** (superseded by `dr-w21-s1`, D359/D362). And D355's open-PR dispositions,
re-derived on today's main: **#10129** CLOSE (118 behind, 6 conflicts, and its clean half sits in a file
`#10519` rewrote); **#10400** its reds are NOT stale-green — the rebase reproduces CI exactly (4 failures: a
test calling `DeployLedger.not_attempted_classes/0`, which exists on no branch, plus three reachability reds
for two new publics with zero callers), so "rebase and fix" needs a real fix, and a close is equally
defensible; **#10086** RE-CUT, exactly 1 conflict (`internal/cloudclient/client.go`); **#10019** RE-CUT but
**not tiny** — now 3 conflicts because it collides with its own merged sibling #10608, and D372 shows two
thirds of it is NOT superseded.

**Coverage.** Both fleets reported in full — no survey deficit and no verify deficit. Every premise this wave
builds on was smoke-tested against `origin/main` before it reached a brief: `router.ex:1583`'s `/status.json`
route, `deploy_runner.ex:278`'s `@stage_names`, `registry/barkpark.ex:76`'s `@update_states`,
`registry.ex:3710`, `health.ex`, `deploy_ledger.ex`, `billing/http_client.ex`,
`self_update/client/github.ex`, both deploy engines, `check-deploy-smoke.sh`, `deploy.yml` and
`deploy-harnesses.yml` — fifteen files, all present. Three inherited premises were read for COVERAGE and
found NOT to cover what they were cited for: **D343**'s "nobody has a sha reader" (false since #6422 —
D362), **D350**'s "nothing caps cross-site build concurrency" (false as written, and false by the time it was
published — D364), and **#9644 as a merged PR** (it is an open ISSUE — D370). Two further inherited numbers
were refuted outright: **D351**'s 77-92 ms idle floor (measured 587-721 ms) and the assignment premise that
three deploy self-test rows had been removed (they were never removed — D368).

---

## Wave 22 — THE PLATFORM CAN REMEMBER

**The wish's word "fail" has expired, and this wave says so in its own first paragraph.** Wave 21 re-derived
it and wave 22's survey proved it harder: **0 of 493 path-matching merges in 14 days failed to reach a
successful deploy**; UNCOVERED = 0 on two independent oracles over 790 cp + 1,172 instance commits; 2,264
pushes, 1,373 path-matching, 1,373 with a run, 0 missing. The failure numerator is **FROZEN at 18,622 since
2026-08-07T10:02:55Z** — the last failed deployment row in the entire table — and the four sites that carried
89% of all failures all went live on 2026-08-08. **This wave sells on COST, DEGRADATION and BLINDNESS. Never
on lost deploys.**

### Decisions

**D375 — THE LIFETIME FAILURE RATE IS RETIRED BY NAME, because it cannot lose.** Its numerator has not moved
since 2026-08-07T10:02:55Z; 2026-08-08 carries 259 rows and **0 failed**. A rate whose numerator is dead can
only fall by dilution: it reads "improving" every day regardless of what the platform does, and needs 42,789
more clean rows (~165 days at today's rate) merely to reach 25%. It is a monument, not an instrument, and it
fails this epic's own standing test. **Replacement: live-per-row over a PINNED window with volume beside it,
and the deferral share printed as a co-equal.**

**D376 — THE 98.6% HEADLINE IS ILLEGAL UNDER D3 AND MAY NOT BE PRINTED BARE.** Post-door (since
2026-08-06T22:29:27Z) the population is **2,510 rows — 698 live (27.8%), 1,792 deferred (71.4%), 20 failed
(0.8%)**. Success-among-{live,failed} is 97.2%, the shape of the 657/666 the direction opened with — computed
over a denominator that DROPS 71.4% of rows. The D3-legal comparison is **live-per-row 14.9% (pre-door 7d,
n=11,530) → 27.8% (post-door, n=2,510), 1.87x**. The live census already resolves this honestly and prints the
CEILING caveat on its basis line. In the wave that sells on honesty, printing 98.6% bare would break the
epic's own law.

**D377 — THE DOOR IS NOT LEAKING. THE RECONCILIATION IS EXACT, ON THREE AXES.** Post-migration window
2026-08-07 10:02:23 → 2026-08-08 08:30:33: DB `BOX_AT_CAPACITY_DEFERRED` = **684**; box journal
`REFUSED … the box's build slot is in use` = 310 (blue) + 374 (green) = **684**. Identical across all 19 hourly
buckets and all 6 slugs. Full wish window: box 1,810 = DB 1,804 deferred + 6 failed. **Leg 3's "make the door
counted" half is DONE end to end, and is now EMPIRICAL rather than source-read.**

**D378 — THE UNIT-NAME TRAP, recorded because it inverts the answer.** `journalctl -u barkpark` on guerrilla
returns `-- No entries --` for EVERY string: **`barkpark.service` does not exist on that box** — it runs
blue/green as `barkpark-slot@blue.service` / `barkpark-slot@green.service`, and BOTH slots must be summed (a
single-slot grep undercounts 45%). Following the obvious command literally produces "the box refuses and logs
nothing" → a phantom fail-open. **Any gate or ledger row that greps a unit name must pin
`barkpark-slot@<slot>` and carry a positive control.**

**D379 — A 0.33% UNDERCOUNT IS BAKED INTO THE OBVIOUS DOOR QUERY.** Six box-capacity refusals settled `failed`,
not `deferred`; they hold the 409 code in `failure_reason` but `deferral_cause` is NULL, because that column is
written only inside `Sites.Deploy.defer/3`. **The honest predicate for "times the door refused" is
`failure_reason LIKE '%409%box_at_capacity%'` across ALL statuses**, never `status='deferred' AND
deferral_cause=…`. Any refusal-rate reader that keys on the cause column inherits this denominator bug.

**D380 — `dr-w15-bl-deferral-cause-null-audit` IS SETTLED: PURE RESIDUE, not a writer bug.** 1,121 of 1,805
deferred rows in the wish window (62.1%) carry a NULL cause; every one is pre-migration, and the boundary is a
clean step at 2026-08-07 10:00 with ZERO nulls after. `min(inserted_at)` where the cause is non-null =
2026-08-07 10:12:35.033826, independently corroborating dr-w16-s7.

**D381 — `BOX_BUSY_DEFERRED` HAS NEVER BEEN WRITTEN TO THE COLUMN.** All 684 column-era rows are
`BOX_AT_CAPACITY_DEFERRED`; exactly one `already_running` deferral exists in the whole 34-hour window and it
predates the migration. A "refusal rate BY CAUSE" reader would render a one-row chart forever. **A gate built
on this reconciliation must key on the ARM, not on the log phrase** — the busy arm is emitted by a different
code path and `grep 'build slot is'` would silently stop covering it.

**D382 — THE RUN-STATE DIR IS NOT BEING WIPED. The charter's "rotating ~40-hour `terminal.json` corpus"
(origin:5750) is REFUTED.** The corpus is 44.8 h old because that is the AGE OF THE FEATURE (#9727 landed
2026-08-06 11:31:45 UTC; the oldest record is a retention TOMBSTONE minted six minutes later, one of exactly 8
born in the same second). Five independent disproofs: 1,056 records against a **count-only**
`@default_max_terminal_records 10_000`; `prune_terminal_records/2` carries no age term; `*.log` files reach
back to 2026-08-04, OLDER than the oldest record; the dir's birth time is 2026-07-17; and zero references to it
in hooks, units, crontabs, tmpfiles.d, or any `git clean` in any deploy surface. **Runway at today's 23.6
records/h is ~424 h ≈ 17.7 days.** A durable recorder CAN be sited there — and journald (10 days,
volume-bounded at 3.6 G under ~10k lines/h/slot) is strictly WORSE, so leg 1 must not be sited in a log grep.

**D383 — THE LAG BIMODALITY IS OURS, NOT GITHUB'S. This overturns the direction's own justification for the
split, and the split survives for the opposite reason.** Full population, n=314 successful `deploy.yml` runs
over 14 days, 0 runs missing jobs: leg A (merge → first job start) is p50 9.0 s / p90 370.4 s / p95 490.5 s /
max 19,486 s, with **exactly zero runs in [600 s, 1800 s)**. Splitting by concurrency-group occupancy:
**GROUP OCCUPIED n=117 → p50 204.0 / p90 504.2; GROUP FREE n=197 → p50 4.0 / p90 10.0.** Of the 111 runs with
leg A ≥ 60 s, **107 (96.4%) were created into an occupied `deploy-production` group** and started a median
**3.0 s** after the predecessor run ended. **GitHub's true pickup latency is p50 4 s / p90 10 s.** The digest's
"p90 488 s GitHub queue" reproduces exactly — as the *instance* job's start latency relative to
`run.created_at`, which contains our own serialization plus the `changes` job's runtime. **The number is right;
the label on it was wrong.** Over 314 runs, leg A is 8.7 h of 35.4 h of wall clock excluding the outlier —
**~a quarter of all deploy latency is queueing behind ourselves, and nothing records it.**

**D384 — `run_started_at` IS UNUSABLE AS THE SPLIT POINT, POPULATION-WIDE.** `run_started_at == created_at` on
**509 of 509** runs in the window — not just on the 19,486 s outlier. A builder reaching for the field whose
name means "run start" gets leg A = 0 s on every row and dumps the entire 5h24m outlier into the "us" leg. **The
split point MUST be `min(job.started_at)` from `/actions/runs/{id}/jobs`.** And the gauge needs **THREE legs**
(merge → group free → first job → serving), or two legs with leg A named for OUR OWN queue: a two-leg
merge→run-start / run-start→serving split labelled "GitHub capacity" commits the exact misattribution it was
built to prevent, on 107 of 111 slow rows. **`dr-w21-bl-merge-to-serving-lag-has-no-recorder`'s criterion 2
is hereby superseded** and must be rewritten before a builder claims it.

**D385 — 36.5% OF MATCHING MERGES WERE DELIVERED BY SOMEONE ELSE'S RUN, AND NOTHING RECORDS WHICH.** 180 of
493; 179 deploy runs were evicted as `cancelled` from the `deploy-production` concurrency group. Carried
commits are not slower (p50 276 s vs 289 s overall) — batching helps them. But if you ask the platform "did my
commit deploy?", the honest answer for one merge in three is "not on its own run, and I cannot tell you which
run carried it." **Therefore the recorder's key is `(sha, delivering_run_id, first_seen_at)`** — recording
`(sha, first_seen_at)` alone reproduces the bug for the 180 carried commits, whose own run does not exist to
write the row.

**D386 — THE SECRET LEAK IS 3 UNCOVERED BOUNDARIES BEHIND ONE LINE, PLUS A GATE THAT CANNOT LOSE.** Proved by
RENDERED HTTP BYTES, not by reading: `GET /v1/barkparks` → `provision_console[].line` (router.ex:9228) and
`provision_steps[].detail` (:9218), and `GET /v1/sites/:id/deployments/:id` → `deployment.console[].line`
(:11132) all returned the colourised secret **byte-identical to input**. All three funnel through
`scrub_entry/2`'s single bare `FailureCopy.scrub(value)` at **router.ex:9243** — no strip at all, so they ship
the secret AND raw 0x1B. **One line closes all three**, and the FULL cloud suite is 3255 tests / 0 failures with
it applied. Covered by NEITHER #10608 (merged, event_email only) NOR #10019 (open, conflicting).
**AND `humanize/1` (failure_copy.ex:382, `classify |> scrub |> strip_ansi`) leaks 2000/2000 on the key-prefixed
CSI shape — in CLEAN CLEARTEXT, because the trailing strip removes the evidence — and NOTHING in the suite pins
its order: flipping it to `classify |> strip_ansi |> scrub` leaves the suite 3255/0, identical.** The order is
asserted only in a COMMENT (failure_copy.ex:176, "MUST stay that way"). This is the epic's own
make-the-check-able-to-fail doctrine failing in the file that preaches it.

**D387 — THE LEAK'S SHAPE IS NARROWER THAN "ANY COLOURISED SECRET", AND THE WRONG FIXTURE GIVES A FALSE
ALL-CLEAR.** Only the **key-prefixed** CSI shape leaks (`\e[31mapi_key=<s>`) — 2000/2000 under bare scrub,
0/2000 under `strip_ansi |> scrub`. A CSI in the VALUE position (`api_key=\e[31m<s>`) is safe under BOTH orders
0/2000, because the value class eats the escape bytes. So is a provider-PREFIXED token (`sk-…`). **A verifier
or builder who picks the value-position or prefixed fixture gets a false green.** The OSC shape
(`\e]0;t\ain api_key=`) leaks under BOTH orders and the one-line fix does NOT reach it — any PR must say so out
loud. Separately measured over 154,931 real captured lines on cloud-db-1: **zero OSC sequences exist**, and
only ONE line matches the key alphabet at all (instructional prose with a `<your-key>` placeholder). **The
boundary hole is real and proven; a live exploitation is NOT measured, and the PR body must not claim one.**

**D388 — THE COALESCE COUNTER IS MIS-SITED, AND THE REAL GAUGE IS ALREADY BUILT WITH NO READER.** Insert-seam
coalescing is material — **89 of 345 `content_publishes` rows (25.8%) in 19.5 h, 125 of 460 (27.2%) all-time** —
while the perform-seam `deployments.coalesced_attempts` is **15 over 31,697 rows on exactly 2 rows (0.0063%)**,
a 4,300x difference in hit rate. `dr-w19-bl-coalesced-counter-reads-a-confident-zero`'s premise "reads ZERO" is
**REFUTED**: it reads 15, both rows post-migration, so the increment path IS reachable and the honest
disposition is to mark the term unrenderable, not to fix a counter. **`PublishClock.coalesced_node/1` already
counts the right population, already rides `GET /v1/sites/:id/deployments` as `publish_clock` (router.ex:6760)
— and `git grep publish_clock origin/main -- internal/ cloud/priv/static` returns NOTHING.** Recorder +
envelope, zero human readers: the wave's own rule violated one layer up, already filed as
`dr-w14-s6-followup-site-deployments-envelope-unread`.

**D389 — `content_publishes.enqueued` CONFLATES A COALESCE WITH A FAILED INSERT, so "89 coalesced" is not an
honest sentence.** `ContentPublish.enqueued?/1` has a CATCH-ALL `enqueued?(_other), do: false` beside the
genuine `%{conflict?: true}` arm; the persisted boolean cannot separate them afterwards, and
`coalesced_node/1`'s own copy already asserts the coalesce reading for rows it cannot prove. Either split the
column at the stamp site, or the renderer says "did not enqueue a build of its own" and NEVER "coalesced".
**Also: 345 is per-site DELIVERIES (5 webhook-bound sites × exactly 69 each), not 69 publishes** — printing
"89 coalesced publishes" repeats the 5x amplification error the charter already names.

**D390 — NULL-SORT RULING: MECHANISM B IS LAW.** Two shipped precedents disagree and no gate reds on the
divergence. `cloud_usage.go:327-338 usageStateSeverity` has `default: return 0` = "live" = the floor:
**fail-OPEN on an unknown token**. `cloud_status_cmd.go:246-297` separates sort rank (unknown sorts last,
benign) from the healthy boundary, which is a MEMBERSHIP switch defaulting to `attention`: **fail-CLOSED**. The
decisive reason is testability, not taste: `cloud_status_cmd_test.go:128` pins
`attentionBucket("some_future_rung") == "attention"`, while every `usageStateSeverity` assertion names only the
four KNOWN orderings — **A's default arm is exercised by no test anywhere.** Stated honestly: A's fail-open is
today **LATENT**, because `usageStateToken` can only emit the five tokens A cases — and it goes LIVE the instant
a sixth token is added, which is exactly what this wave's CLOCK/RATE vocabulary does. Fix is one line plus one
mirrored test. **Every wave-22 surface with a healthy boundary states it as a membership switch defaulting to
the attention side.**

**D391 — `internal/cli/**` AND ANY NEW TOP-LEVEL DIRECTORY TRIP ZERO REQUIRED GATES. MEASURED LIVE, not read.**
A throwaway PR (#10653, closed unmerged, branch deleted) published **Elixir gate / Cloud gate / Console gate /
PR references an active task all `success` with every expensive leaf `skipped`** — on a head touching only
`dr-w22-gate-probe/README.md`, and again after adding `internal/cli/dr_w22_gate_probe.go`, at which point
`gh pr view` reported `mergeStateStatus: CLEAN`. The Elixir matrix rendered under its **uninterpolated template
name** (`Test (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})`) — the shim's own tell — versus the
interpolated `Test (Elixir 1.18.1 / OTP 27.0)` on api-touching heads. **CONSEQUENCE: the wave's law "recorder
AND reader in one PR, proved by a test that reads RENDERED BYTES" is UNENFORCEABLE BY CI for any slice sited in
`internal/cli/**`.** The remedy's precedent is already in-tree — `CONSOLE_PATHS` declares the exact file
`internal/agent/report.go` and `__app.test.mjs:18939` reads that Go file's bytes inside the REQUIRED Console
gate — but `__app.test.mjs` is cloud-console-hardening's fence, so widening is a round-2 act. **Until then this
wave states out loud that its CLI readers are enforced by review, not by a gate.** One correction to D32's
readable implication: `go-tests.yml` DOES have a `pull_request` trigger on `**/*.go` and did run and pass — the
defect is that the Go signal cannot BLOCK, not that it is absent.

**D392 — THE FENCE, RE-DERIVED AT BUILD TIME, IS 138 PATHS — AND THE NAIVE COUNT OVER-FENCES 6.6x.** Three
counting methods, only the third sound: `git branch --no-merged` returns 2,502 (worthless — everything is
squash-merged); blob inequality returns 207 refs (overcounts: 400+ branches "differ" on `health.ex` only
because they are BEHIND main); **three-dot `git diff --name-only origin/main...ref` plus ALIAS-AWARE PR
liveness returns 16 refs / 11 slices / 138 paths.** THE ALIAS TRAP: a slice branch and its `-r`/`-rv` retry
alias are the same slice and the PR is usually opened on the ALIAS — checking only the base ref reports **106
refs "built and never pushed"**; checking `{base, -r, -rv, -r2}` collapses it to 16. **FREE for round 1:**
`cloud/lib/barkpark_cloud/health.ex`, `api/lib/barkpark/sites/deploy_runner.ex`,
`api/lib/barkpark_web/controllers/instance_site_deploy_controller.ex`, `internal/cli/cloud_cmd.go`,
`internal/agent/**`, and every new-module prefix. **LOCKED:** `cloud/lib/barkpark_cloud/web/router.ex` (6
holders — the most contested file in the tree), `internal/cloudclient/client.go` (4),
`cloud/lib/barkpark_cloud/deploy_ledger.ex` (5), `internal/cli/cloud_status_cmd.go` (3),
`cloud/lib/barkpark_cloud/registry.ex` (2), `cloud/lib/barkpark_cloud/failure_copy.ex` (PR #10019).

**D393 — "WAVE 21'S SIX SLICES ARE BUILT AND NOT ON ORIGIN" IS FALSE, and the evidence that produced it is a
search artifact.** `gh pr list --search dr-w21` returns `[]` — reproduced exactly — because the PRs exist under
`loop-epic/*` head refs, never under a `dr-w21*` ref. **8 wave-21-era PRs MERGED 2026-08-08T02:35–02:42Z
(#10605–#10615) plus the wave-21 charter #10643 at 04:31:53Z**, and `origin/main`'s charter is already 6,044
lines carrying the wave-21 slice table at :5997. **Only FIVE slices are genuinely unpushed** —
`dr-w21-s1/s2/s3/s5/s6`. **That check can only ever return empty and must never be used again as the
unpushed-work oracle.**

**D394 — ALL FIVE UNPUSHED WAVE-21 SLICES REBASE CLEAN ONTO TODAY'S MAIN AND THEIR NAMED GATES RUN GREEN.**
s1 `--selftest` OK on both tips; s2 full cloud suite **3275/0** plus its migration applying forward clean on a
fresh DB, `format` rc=0, `warnings-as-errors` rc=0; s3 `go build`/`vet`/`test` green (26.77 s); s5 both engines'
self-tests **322/322** and **183/183** including the node engine's mutation proof, plus its api ExUnit 4/0; s6
full cloud suite **3263/0** after auto-merging `router.ex` against main's #10646/#10647. **The five are pairwise
file-disjoint, so no merge order is forced among them.** Push the **`-r` tips** for s1 and s2 (they carry real
review fix commits 281f8f5f9 / 8838ade94); s3's `-r` is the identical sha; s5 and s6 have no review branch.
**Two honest defects, neither blocking:** s6's claim note says "8/9, c4 missed" but the published doc reads
**7/9** and the missed rows are c5 and c9 (wrong count AND wrong criterion) — c5 wants a live BEFORE reading
that verification produced verbatim; and s5's new api test file fails `mix format --check-formatted` (rc=1,
first read hid it behind a pipe), which reds only elixir.yml's explicitly-ADVISORY Format job. **THE
HIGHEST-LEVERAGE ACT OF THIS WAVE IS A PUSH, NOT A BUILDER.**

**D395 — THE CONTROL PLANE'S CENSUS REFUSES A FAILURE RATE TODAY, AND WILL UNTIL ~2026-08-12T21:13Z.**
`bp cloud deployments -o table` prints `failure NO RATE — the control plane refused a percentage: the window
STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z`. Anything hung off "the failure rate the
census prints" has no number to hang off for four more days, and **any criterion asserting `failure NO RATE` in
rendered bytes will silently flip to asserting a percentage after that date — criteria must pin `--from/--to`,
never rely on the `--days` default.** The same render proves `delivery — NOT MEASURED — this control plane
sends no delivery census`, which is exactly the BEFORE reading `dr-w21-s6`'s unmet criterion 5 asks for, as-of
2026-08-08T08:29:51Z. The team route answers **200** to a real cloud PAT while the operator sibling answers
**403 `{"error":"forbidden","scope":"platform","required":"platform_operator"}`** to that identical token in
the same minute — the reachability proof this wave needed.

**D396 — `bp cloud` IS NOT MANIFEST-DRIVEN, and the installed binary cannot run this epic's own instrument.**
`bp capabilities -o json` is the CONTENT server's manifest (150 rows, 26 verbs); the strings `"cloud"`,
`"deploy-ledger"` and `"deployments"` appear **zero** times. The real registry is an 18-arm hard-coded switch at
`internal/cli/hetzner_cmd.go:94-138`. And `/Users/pelle/.local/bin/bp` answers `unknown cloud command
"deployments"` because the primary checkout is **659 commits behind origin/main** and lacks
`cloud_deploy_census_cmd.go` entirely. **Any brief that says "run `bp cloud deployments`" MUST carry the
fresh-build recipe (`git archive origin/main` + `CGO_ENABLED=0 go build`, since the `cc` alias breaks cgo) or it
will manufacture a false negative.**

**D397 — `coalesced_attempts` IS READABLE ONLY IN THE FORMAT D220 FORBIDS AS PROOF.** `-o json` is a verbatim
passthrough of the server body, so the key reaches a human there; but `cloudclient.DeployCensus` has **no
`Coalesced` field** (grep for "oalesced" across `internal/cloudclient` returns zero), so `-o table` can never
print it — the CLI's own comment at `cloud_deploy_census_cmd.go:538` admits it. D220 rules every proof must use
`-o table` because a piped run silently returns JSON. **So this is a recorder with a reader that no legal proof
may quote** — the cheapest true instance of the wave's rule in the tree, ~15 lines of Go. Its live value is
honest (`{"value":null,"refused":true,"since":"2026-08-07T10:02:23Z"}`); the fix is purely reader-side.

**D398 — THE PLATFORM ALREADY HAS 14 DAYS OF `(sha, timestamp)` AND A READER THAT CAN REACH 3 HOURS OF IT.**
`barkparks.git_commit` IS populated on the live guerrilla row (`2673eb009f…`, `last_seen_at` fresh,
`agent_status online`); 5 of 6 rows carry a sha and the one null is a box that has never beat. Every 60 s beat
is inserted append-only by `Registry.record_event(barkpark, "health", report)` with the FULL report — sha
included — and `AgentRetentionWorker` keeps **14 days**. But the only reader,
`GET /v1/barkparks/:id/events`, runs `parse_limit(…, 50, 200)`: a live `limit=5000` returned exactly **200 rows
spanning 3 h 06 m**. **This is the wave's law with the polarity flipped — not a recorder without a reader, but a
recorder with a reader that cannot reach it.** So `(sha, first_seen_at)` is a DERIVED read or a cheap
first-appearance stamp, **not greenfield**. Note the auth asymmetry: `/v1/barkparks` is PAT-reachable, while
`/events` and `/telemetry` are `require_user` ONLY — a reader sited on the events route inherits a strictly
narrower caller than the surface it completes.

**D399 — THE SERVED `git_commit` IS THE CHECKOUT'S HEAD, NOT THE RUNNING BEAM'S.** `internal/agent/report.go`
computes it as `git rev-parse HEAD` in the checkout; guerrilla's `/opt/barkpark` HEAD is byte-identical to the
served field, while `barkpark-slot@blue` entered active 64 s earlier on a different clock. Since **`git pull`
IS the deploy**, the sha flips at pull time, minutes before the new code serves — so the field **OVER-REPORTS
during the pull→compile→restart window** and answers "what is checked out", never "what is live". Any delivery
gauge keyed on it silently measures git.

**D400 — `dirty_tree` IS A GAUGE THAT CAN NEVER SAY CLEAN.** It is NOT on the fleet row (`barkpark_json` serves
`git_commit`/`last_seen_at`/`version` and no `dirty_tree`); it is served on `GET /v1/barkparks/:id/telemetry`
and reads **true** for guerrilla — and all 9 dirty entries are **untracked** (`bp`, `bp.pre-task07`, `sites/`,
`.claude/worktrees/`, `.env.bak-*`). The agent computes it as `git status --porcelain` non-empty. **A hygiene
gauge pinned true forever cannot say the wrong thing** — the exact failure class this wave sells against, and
the cheapest fix in the epic: one flag, `--untracked-files=no`.

**D401 — THE SEAL RULING, because a 22nd wave owes its owner an answer to "when is this done."** No seal
criteria exist in either charter (grep over both on origin/main returns one incidental hit about a *wave's*
definition of done). **S0 (precondition): the charter is ON ORIGIN** — an epic cannot seal on decisions that
live only on unmerged PRs. **S1: the named harm is retired BY NAME** — a written ruling that "deployments fail"
is closed (numerator frozen; the four 89%-carrier sites live), that the lifetime rate is retired as incapable
of regression (D375), and that live-per-row over a pinned window with the deferral share as a co-equal replaces
it (D376). **S2: MEMORY — for an arbitrary merged sha the platform answers what went live, at what instant, how
long after merge, split by the three legs of D384, durably enough to survive a container replacement.**
**S3: NO RECORDER WITHOUT A READER — a closed, enumerated list of every instrument this epic built, each with a
named non-admin human caller and a test that reads RENDERED BYTES** (known violators still open: the fleet
digest audience, the machine-only rollout brake, `build_slots` served to nobody, `avgDurationMs` rendered by
nobody, `publish_clock` decoded by nobody, `coalesced_attempts` unrenderable in `-o table`). **S4: THE EPIC'S
OWN LEDGER IS HONEST** — 388 children, 66 done, 6 cancelled, 316 open, of which **269 (85%) have ZERO criteria
met**, 41 partial (32 of them one-short), 7 unscoreable, 2 UNPUBLISHED DRAFTS invisible to `bp task ready`, and
**ZERO open rows with all criteria met** (so dr-w19-s6's sweep left no trivially-closable residue, and
duplication is a rounding error — a Jaccard ≥ 0.5 scan over all 316 found exactly one near-dup pair). Exactly
**one false-done** exists: `dr-followup-start-reported-callers`, lifecycle done at 0/4. The blocker is not
duplication, it is **ABANDONMENT** — filed 22/99/233/34 per day against done 4/20/42/0, ~2.7x file-over-burn,
with 254 of the 269 zeros (94%) filed in the last three days. **Seal is therefore stated on the 41 PARTIALS
reaching met==total or being re-scoped in writing; the 269 are RE-PARENTED to a successor epic, never
bulk-cancelled.** **S5: A TRIPWIRE THAT CAN LOSE** — live-per-row below a pinned floor, or the deferral share
above its band, reported by a named surface over a pinned window, refusing below its minimum sample. **S6: DO
NOT WRITE A SEAL PREDICATE** — `cloud/priv/static/__preview__/seal-predicate.mjs` already ships and its
historical fail-open is CLOSED (`EMPTY-ROSTER` refusal at :1274 beside `EMPTY-DEFECT-REGISTER` at :1179), so
draining the roster by cancellation triggers a refusal rather than a SEAL. Adopt it; do not mint a ninth
instrument.

**D402 — "CLOUD-CONSOLE-HARDENING WAVE 53" DOES NOT EXIST.** The console charter on origin/main tops out at
**Wave 52 — THE SILENT REGISTER**, and two of the three fenced files the direction named
(`cloud/lib/**/web/auth.ex`, "router.ex's auth region") are touched by no in-flight console branch. The fence
that IS real: `cloud/priv/static/app.js` + `__app.test.mjs` + `__preview__/*` (ceded to console by BOTH
charters, twice by name), `notifications.ex`, `notifications/email_settings.ex`, `daily_digest_worker.ex`,
`accounts/audit_event.ex`. **A citation you did not read for coverage is a phantom wearing a number**, and this
is the second one this epic has caught in two waves.

**D403 — PDS-D716 RE-READ FOR COVERAGE AND IT HOLDS, VERBATIM.** `deploy/instance-deploy.sh` and
`deploy/cp-deploy.sh` **ARE IN-FENCE for PDS** — so the sha recorder may NOT be sited in `cp-deploy.sh` — while
`deploy/site-deploy*` is **ceded to this epic BY NAME**. It also states the production consequence in PDS's own
words, independently re-derived from `deploy.yml:79`/`:87`: **`deploy/` is in BOTH the cp regex and the
instance regex, so merging any `deploy/**` byte deploys BOTH production hosts.** (Note the local PDS charter is
466 lines behind origin and the cited line range is EMPTY in it — brief from origin, always.)

**D404 — THE DIRECTION'S BLIND-SPOT (1) IS HALF-DISCHARGED, AND WAVE 22 MUST NOT REPEAT ITS DEAD HALF.**
PR **#10605 merged 2026-08-08T02:35:02Z**: `origin/main:cloud/lib/barkpark_cloud/health.ex:47` now serves
`git_sha` from `BARKPARK_GIT_SHA` at call time, live-verified at 07:58:32Z. **"The platform cannot say WHAT
COMMIT is live" is FALSE and must not appear in this wave's prose.** What survives verbatim is the other half:
`serving_since` is still `:erlang.monotonic_time/0`-derived (`:54`, `:68`) — a PROCESS point sample a bare
`docker restart` **improves**. Leg 1 is re-scoped to "since when + how long", never "what commit".

### Wave 22 plan — 7 slices, 4 in round 1, file sets disjoint within the round

| # | Slice | Task id | Files | Round | Flip-risk |
|---|---|---|---|---|---|
| 1 | The three bare-scrub boundaries stop shipping the secret, and the gate can lose on `humanize/1` | `dr-w22-s1-scrub-entry-boundaries-stop-leaking` | `cloud/.../web/router.ex` (`scrub_entry/2` only), `failure_copy.ex`, `failure_copy_test.exs`, new HTTP boundary test | 1 | **HIGH — SECURITY: the fixture shape decides the verdict (D387)** |
| 2 | The box stops reporting a constant and starts remembering: observed concurrency, an honest refusal count, and a serving clock a restart cannot improve | `dr-w22-s2-the-box-remembers` | `api/lib/barkpark/sites/deploy_runner.ex`, `api/lib/barkpark_web/controllers/instance_site_deploy_controller.ex`, new `serving_memory.ex`, api tests | 1 | **HIGH — the recorder must survive a BEAM restart via the run-state dir (D382), not journald** |
| 3 | `dirty_tree` becomes a gauge that can say clean | `dr-w22-s3-dirty-tree-can-say-clean` | `internal/agent/report.go` + test | 1 | — |
| 4 | The null-sort law: `usageStateSeverity` fails CLOSED, mirroring the pinned `attentionBucket` precedent | `dr-w22-s4-null-sort-fails-closed` | `internal/cli/cloud_usage.go` + test | 1 | — |
| 5 | The census stops undercounting the door, and `coalesced_attempts` reaches `-o table` | `dr-w22-s5-census-door-denominator-and-coalesce-reader` | `deploy_ledger.ex`, `internal/cloudclient/client.go`, `cloud_deploy_census_cmd.go` + tests | **2** — after `dr-w21-s6` merges | — |
| 6 | The lag gauge gets three legs, from job-level timestamps | `dr-w22-s6-three-leg-lag-gauge` | `.github/workflows/deploy.yml`, `scripts/` | **2** — after `dr-w21-s1` merges | **HIGH — D383/D384: the obvious field and the obvious label are both wrong** |
| 7 | The control plane's serving clock reaches a human on a PAT-reachable route | `dr-w22-s7-platform-node-on-the-fleet-envelope` | `cloud/.../web/router.ex` (`/v1/barkparks` envelope), `health.ex` | **2** — after `dr-w21-s6` and `dr-w22-s2` merge | **HIGH — TENANCY: an identity-free `platform` node on the `step_estimates` precedent, NEVER a `barkparks` row (D398)** |

Round 1's four file sets are pairwise disjoint and every one of them is in D392's FREE set except slice 1's
`router.ex`, whose edit is confined to `scrub_entry/2` at :9240-9247 — a region no wave-21 branch and no open PR
touches, and one that git auto-merged in verification. Rounds 5-7 all sit on files with 3-6 live holders and are
returned as deferrals for the lead to dispatch after merging their deps. Every builder is Opus (Fable
unavailable this run).

**The lead's first act is not a builder.** Push the five wave-21 branches — the `-r` tips for s1 and s2 — and
open their PRs; D394 proved all five rebase clean and gate green, and four of them unblock rounds 5-7. Push
before dispatching round 2.

**Coverage.** Both fleets reported in full — no survey deficit and no verify deficit. Eight inherited citations
were git-shown on origin/main and PASS; **three FAILED coverage and are corrected above**: "cloud-console
wave 53" does not exist (D402), "wave 21's six slices are built and not on origin" is a search artifact (D393),
and "the platform cannot say what commit is live" was discharged by #10605 before this wave started (D404).
Two further inherited numbers were refuted outright: the "~40-hour rotating corpus" (D382, actually 17.7 days)
and the "p90 488 s GitHub queue" as an attribution (D383, actually our own concurrency group at 96.4%).

**Charter PR:** #10654 (docs-only). Epic task claimed by `epic-cycle-decide-w22` at epoch 55.

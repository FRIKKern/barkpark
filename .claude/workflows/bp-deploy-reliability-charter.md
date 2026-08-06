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

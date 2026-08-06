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

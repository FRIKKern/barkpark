<!-- doc-tier: agent | canonical-for: merge-gates | budget: 16000tok -->
# Merge Gates (Phase 2 onward)

> Why a PR cannot be merged until every gate below is green, and how to run
> them locally before pushing.

## Pre-merge gates (as of Phase 2)

A PR targeting `main` must clear:

1. **Static audit** — Reviewer reads the diff for logic, security, and
   architectural fit. Catches most defects but not all (see lessons-learned
   below).
2. **`format` CI job** — `.github/workflows/elixir.yml`, runs
   `mix format --check-formatted` through `scripts/format-check.sh`. Its own
   dedicated, fast job (~30s, no DB, no full compile) so drift is visible in
   <60s. **Blocking since task-e31b816b4b416db6, and DIFF-SCOPED**: it dropped
   `continue-on-error` and joined `elixir-gate`'s `needs:`, so it blocks
   transitively like every other upstream (SUBSUMED, below). What it enforces is
   NOT "is the tree formatted" — it fails only when a file **the PR's own diff
   touches** is unformatted (`scripts/format-diff-scope.sh`); inherited drift in
   untouched files is printed and stays neutral, because a gate that reds
   everyone over someone else's merge is the advisory-red problem with a merge
   button attached. On `push:main` there is no PR diff, so nothing is
   diff-scoped: the standing debt is printed and the job is green — main is
   where the debt is VISIBLE, the PR that touches the file is where it is
   enforced. The order matters and is guarded: `continue-on-error` had to go
   BEFORE the job could enter `needs:`, because `needs.<job>.result` reads
   `success` for a FAILED continue-on-error job
   (`scripts/elixir-path-escape-check.test.sh`, `coe_in_needs`).
3. **`mix-prod-compile` CI job** — same workflow, gated only by the `changes`
   dispatcher (`needs: [changes]` under the `mix-prod-compile:` job key in
   elixir.yml — there is **no** edge to `mix-test`; the "NO needs: mix-test"
   comment directly beneath it records why it was removed, and a reader who
   plans around a test→compile ordering is planning around an edge that no
   longer exists. Cited by JOB KEY, not by line, and the reason is measured:
   this sentence pinned bare line numbers until the job moved past them twice,
   the second time mid-session ([history](merge-gates-history.md#the-line-numbers-this-page-pinned-and-lost)).
   A line number in a doc is correct exactly once; `grep -n '^  mix-prod-compile:'`
   is correct always). Cleans `api/_build/prod`, force-recompiles deps,
   then runs `MIX_ENV=prod mix compile --warnings-as-errors`. **This is the
   gate** — and it stops a merge transitively, as an upstream `needs:` of the
   required `Elixir gate`.
4. **`validation-perf` CI job** — same workflow, independent of `mix-test`.
   Runs the synthetic 200-field / 100-rule bench, takes the median of 5 timed
   runs, fails if the median exceeds 100ms. A hard gate, and mechanically
   enforced: it too is an upstream `needs:` of the required `Elixir gate`, so a
   red bench reds the required context and the merge button stays grey.
5. **`plugin-node` CI job** — `.github/workflows/plugin-node.yml`. Discovers
   plugins under `api/priv/plugins/` whose `plugin.json` declares a top-level
   `"node"` object and runs `npm ci` + lint + typecheck per plugin. Emits a
   no-op success when no plugin declares Node, so the check is always
   *present on the PR*. Present is not required: it **cannot stop a merge** —
   it is none of the four required contexts and no required aggregator lists
   it in `needs:`, which is the same reading §"Blocking, required, and the
   difference" gives it below ("blocking nothing today").
6. **`vendored-assets` CI job** — `.github/workflows/vendored-assets.yml`,
   path-triggered on `deploy.sh` / `internal/cli/setup/assets/**`. Runs
   `make cli-assets-check` so the go:embedded deploy.sh copy can never drift
   from the root copy again (it diverged both ways on main, fixed 2026-07-02).
   Edit the ROOT deploy.sh, then `make cli-assets-sync`. It carries a
   workflow-level `on: … paths:` filter, is none of the four required
   contexts, and is in no required aggregator's `needs:`, so a red one **does
   not block merge**. It is on this list because a PR that trips it is broken,
   not because the merge button waits for it.

7. **`pr-task-gate` CI job** — `.github/workflows/pr-task-gate.yml`. **Claim the
   row BEFORE you open the PR**: this gate reads the LEDGER, not the diff, so a
   correct `Task:` trailer on a row that was never claimed FAILS. And no gate
   here — this one included — ever opens `acceptance_criteria`, so a `met:true`
   is worth exactly what the person who stamped it made it worth; a criterion
   should therefore name a check a reader can RE-RUN, not a state someone once
   observed. Enforces
   task-obsession layer 1: every PR must carry a `Task: <doc_id>` trailer in its
   description naming a task that is task-backed on the ledger-of-record
   (guerrilla). No task / task not found / task unowned → the check fails. The
   pure ledger decision is the unit-tested `scripts/pr-task-gate.sh`
   (`bash scripts/pr-task-gate.test.sh`, hermetic, and run in CI by this same
   workflow's **`PR task gate self-test`** job — deliberately not in
   `shell-harnesses.yml`, which is paths-filtered and so can never carry a
   required name). The `PR task gate self-test` job does not carry a required
   name either and **cannot block a merge**; it lives in this path-unfiltered
   workflow so that it runs on the same trigger as the gate it tests. The only
   name this workflow contributes to the required set is
   `PR references an active task`, the job described in this item; the workflow
   itself only plumbs PR context in. Four designed behaviours:
   **merge-base cutoff, three-state** — the base COMMIT is resolved first; base
   resolves + this workflow absent = grandfathered (so turning the gate on did
   not red the open-PR fleet), base resolves + present = enforced, base
   **unresolvable = a loud red**, never grandfathered. A guard that cannot tell
   must fail, not wave the PR through: the two-state version reported SUCCESS
   having skipped every downstream step;
   **hotfix lane — ARMED SINCE 2026-08-25, and nothing on this page said so
   until 2026-09-01** — a `hotfix!` label waives the gate AND auto-files an
   override task, because the record is the CONDITION of the bypass. This item
   read "DISARMED … it **reds**; it does not pass" on the ground that
   `BARKPARK_TASK_TOKEN` was **not provisioned**. That ground is GONE:
   `gh secret list` shows the secret created **2026-08-25T11:00:10Z**. With it
   set, `hotfix_record` skips its empty-token `exit 1` arm, POSTs the override
   task, and **exits 0 on a 200/201** — every evaluating step then skips
   (`if: … hotfix != '1'`), the job succeeds, and the required context
   `PR references an active task` goes GREEN. `scripts/pr-task-gate.test.sh`
   pins exactly that arm (`record_case "hotfix record: filed passes" "tok"
   "$REC_BASE" 0`). So the label is a real bypass of a merge-blocking required
   context, gated only on the ledger accepting the write — treat applying it as
   a merge-authority decision, not a retry. Two things did NOT change: the lane
   is circular during a guerrilla outage (it files its record on the ledger that
   is down), and fork PRs get no secret, so there the empty-token red stands.
   **WHY NO GATE CAUGHT THIS**: the census in `pr-task-gate.test.sh` runs the
   `hotfix_record` body with a hard-coded `TASK_TOKEN=""`, so it measures a
   synthetic no-token refusal and is blind to the repo's real secret state — it
   cannot notice provisioning. **The other armed override is break-glass** — see
   [Break-glass](branch-protection-and-overrides.md#break-glass-the-armed-override);
   **lapsed-claim rule — "live when this PR opened"** (charter D58; the
   `LAPSE_GRACE_SECONDS` wall-clock grace it replaced is GONE, and there is no
   tunable left to set). The claim lease (~45min) is shorter than PR dwell, so
   the TTL sweeper reaps claims out from under PRs that were green when they
   opened (11 of the gate's last 15 reds). A task that is `open` because its
   claim was **reaped** passes iff `claim.expired_at ≥ pull_request.created_at`
   — the claim was still live at the instant the PR was opened — read straight
   off the document's `claim.previous_worker` / `claim.expired_at` and the PR's
   own `created_at` (plumbed as `PR_OPENED_AT`; absent or unparseable is a
   **refusal**, never a fall-open). The verdict is therefore fixed for a given
   PR: the same unchanged PR can no longer go green in the morning and red in
   the afternoon merely by sitting. A task that was never claimed, whose claim
   was voluntarily **released** (`released_at ≥ expired_at`), whose
   `expired_at` is in the FUTURE (a reap cannot stamp one; −300s of skew slack),
   or that had ALREADY lapsed before the PR was opened, still fails. Stated
   cost: a PR opened under a live claim stays backed however long it then sits —
   the gate certifies how the PR started, not that work continued;
   **ledger outage = a red that says so** — a 5xx / unreachable ledger is
   retried (3 attempts) and then **fails** with "task backing UNVERIFIED …
   re-run this check once the ledger is up". It does not pass. A `2xx` whose
   `result` envelope carries **no document** is the same UNCHECKED state (D59),
   not an accusation: a task that genuinely does not exist answers `404`, which
   reds definitively, so the old "task does not exist" message on the empty
   envelope could only ever have been false. GitHub has no
   `neutral` conclusion for exit codes, so the only alternative to red would be
   a green check that verified nothing (the old `exit 0` handler was, in fact,
   unreachable dead code under GitHub's `bash -e`, and every outage already red
   — under a misleading label).
   Optional `.github/pr-task-workers.json` (`{ "<gh-login>": "<worker>" }`)
   tightens the check to require the task be claimed by the author's mapped
   worker (matched against the lapsed claim's `previous_worker` when the
   lapsed-claim rule applies). The file does not exist today. **This gate is
   BINDING**: `PR references an active task` is required-by-name on `main` as of
   2026-07-28 — see *Making `pr-task-gate` binding (required-by-name)* in
   [branch-protection-and-overrides.md](branch-protection-and-overrides.md).

8. **`reland-check` CI job** — `.github/workflows/reland-check.yml`. **Advisory
   only** (`continue-on-error: true`): flags when a PR changes files a
   recently-closed task already landed. Each task's `content.landed.files`
   digest is written at close (the land-digest close path); the check diffs the
   PR's changed files against every closed task's digest. Two dampers keep it
   readable (both in the unit-tested `tooling/task-obsession/reland_check.py`,
   `bash tooling/task-obsession/reland_check.test.sh`): **hot-file
   down-weighting** (files in a large fraction of digests + a seed list carry no
   signal) and **dependency-edge suppression** (a finding against a task the
   PR's own task depends on is dropped — reverts/follow-ups are expected;
   best-effort, needs `BARKPARK_TASK_TOKEN` to read edges). Ledger unreachable →
   no findings. Surfaces as a `::warning::` + job summary; never blocks — add a
   `blocks` edge to the prior task to silence an intentional overlap.

The **`mix-test` CI job** (`.github/workflows/elixir.yml`) — dev-mode
`mix compile --warnings-as-errors` + `mix test` against Postgres — is
**blocking** (no `continue-on-error`). The test-infra remediation was
completed 2026-06-10 (`continue-on-error` dropped at that point); a failing
test suite now prevents merge. Its job **id** is `mix-test`; the check that
shows up on the PR is its display name, `Test (Elixir 1.18.1 / OTP 27.0)`,
inside the workflow named `elixir`. There is no check called "Elixir Test" —
that name is folklore, and searching for it finds nothing. **The name a reader
looking for "the Elixir gate" actually wants is `Elixir gate`**: the `elixir`
workflow's `elixir-gate` aggregator, which is un-matrixed (so its check-run name
is exactly that string), runs `if: always()`, and fails when any upstream job
lands outside its allow-set. That is the one name branch protection is meant to
require — `Test (Elixir 1.18.1 / OTP 27.0)` is a job underneath it.

**Gate ORDER inside `mix-test` is load-bearing** (task-openapi-drift-chronic).
The two generated-artifact freshness gates — `OpenAPI drift check` and
`Paper-component golden-parity freshness` — plus the `Plugins-off boot
invariant` step run **after** `mix test`, under an `if:` that ignores the TEST
result but still requires the `build` and `db` steps to have succeeded (so a
broken compile does not cascade into a bogus "stale artifact" red). They used to
run before it. Because a failed step
aborts the rest of the job, one stale byte in `docs/openapi.json` on `main`
meant every open PR reported **zero** test results — a generated-file nit
masking the real suite, twice in one afternoon on 2026-07-13. Order is the whole
fix: both gates are still merge-blocking and unchanged in strength, and
`!cancelled()` means a red suite and a stale artifact are now reported
**independently** rather than each hiding the other. **Do not move a freshness
gate back above `mix test`.** The drift failure names its own remedy
(`cd api && mix barkpark.openapi`), and
`api/test/barkpark/api/openapi_test.exs` carries the asserts that make that
remedy fair: generation is byte-deterministic (so a reported diff is the
author's own change, never run-to-run jitter), and a new route or an edited
help string provably moves the artifact bytes (so the gate has teeth).

**`main` IS protected — as of 2026-07-28.** The long-standing "no branch
protection" reading (verified 2026-06-21, re-checked 2026-07-01) is **dead**;
do not plan from it. Re-derived 2026-08-04 (the two-context body this block
printed until then was stale — `Cloud gate` and `Console gate` became required
after it was written):

```
$ gh api repos/FRIKKern/barkpark/branches/main/protection \
    -q '{contexts:.required_status_checks.contexts,strict:.required_status_checks.strict,enforce_admins:.enforce_admins.enabled}'
{"contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"],"enforce_admins":true,"strict":false}
$ gh api repos/FRIKKern/barkpark/rulesets -q 'length'   # 0
```

**Rulesets are still `[]` — that reading is TRUE and the wrong place to look.**
Protection on this repo lives in the *branch protection* API, not rulesets;
anyone who checks only `/rulesets` gets an accurate empty list and the wrong
conclusion. `.github/required-checks.json` on `origin/main` now carries
`"enforced": true` (it is applied state, no longer a proposal).

Exactly **four** contexts are required — `Elixir gate`, `PR references an active
task`, `Cloud gate`, `Console gate`, byte-matching the four `app_id: 15368`
entries in `.github/required-checks.json`. `strict: false` means a PR is not
forced to be up-to-date with `main` before merge. To make another check binding,
add its context to `.github/required-checks.json` and apply — never hand-PUT.

### A pull request runs the IMPACTED ExUnit set; main runs all of it

`Test (Elixir …)` may run less than the whole suite on a pull request. A
step before it, `Which tests does this pull request need?`, computes the
impacted subset with `scripts/elixir-impacted-tests.sh`; the `Test` step reads
that answer from a file and runs either the list or the whole suite.

**Nothing about a push to main changed.** The dispatcher already emits every path
set `true` on a non-pull_request event, and the selection step returns `ALL` on
one, so every merge is still measured at its own sha, and `elixir-nightly.yml`
still runs the whole suite with the excluded tags. That is what makes narrowing
the PR side survivable: a PR-time selector reads compile-time edges and cannot
see a runtime-only caller, so main-per-sha plus the nightly is the net under it.

**The fail-safe is a polarity, not a list.** Exactly two path shapes can narrow —
`api/lib/**/*.ex` and `api/test/**/*_test.exs`. Everything else selects `ALL`,
along with an empty diff, an unresolvable `HEAD^1`, a failed `mix xref`, a lib
file with no module in it, and a missing or empty selection file. Nothing is
enumerated, so a new kind of path can only ever make this run more. Since an
empty `xref` graph is legitimate for a leaf and catastrophic from a broken
instrument, a probe runs first: a hub (`lib/barkpark/plugin.ex`) and a leaf
(`lib/barkpark/tasks/landed.ex`) must get different closures, or the run logs
`narrowing unavailable: running ALL`. On today's toolchain they do not (#20217),
so an `api/lib` PR runs everything until a direct-edge closure lands (#20219).

**The ALWAYS set** rides every narrowed selection — the tests a compile closure
structurally cannot reach. Source-scanning censuses are DERIVED from the tree on
every run, so one added tomorrow is in the net tomorrow; the runtime-registry
tests (plugin registry, plugin routes, capabilities manifest, the route and
authz censuses) are pinned with a reason each, and `--check-pins` reds when one
is renamed rather than letting the net shrink silently.

**Proof it can still catch.** `--selftest`, 47 cases, runs on the unfiltered
`path-escape` job. Its section 4 replays nine real merged fixes: feeding the
selector only the lib file each one touched selects the test that proves the
fix, with the compile closure DISABLED — so the convention and by-name mappers
alone are enough for them.

**When it is wrong, something says so.** `elixir-main-red-attribution.yml` fires
on a red `elixir` run on main, reconstructs the pull request's file set from the
merge commit, re-runs the selector, and files a routed row through
`scripts/file-ci-failure-issue.sh` naming the merge sha when a failing test is
outside the answer. Its reconstruction runs without a build, so it under-reports
what the pull request ran: a `COVERED` verdict is certain, a `SKIPPED` verdict is
a candidate worth a look. Every selection is uploaded as an artifact — the only
record of what a given sha actually executed.

### Blocking, required, and the difference

**"Not required" and "cannot stop a merge" are different properties, and this
page conflated them until 2026-08-07.** Everything on a PR that is not one of
the four required contexts falls into one of two classes, and only one of them
is harmless:

- **SUBSUMED — blocking transitively.** The mechanism, in one sentence: a
  required aggregator declares upstream jobs in `needs:` and fails closed over
  their results, so a red upstream reds the required context and blocks the
  merge exactly as if it had been required itself. `Elixir gate` is
  `needs: [changes, mix-test, mix-prod-compile, validation-perf, path-escape, format]`
  (the `elixir-gate` job's `needs:` line in elixir.yml), so all six block. Driven rather than read off the topology:
  its `Decide` body, extracted and run with every upstream `success`, exits 0;
  re-run with only the prod-compile result set to `failure` it exits 1; re-run
  with only the perf-bench result set to `failure` it exits 1, printing
  "Elixir gate: at least one upstream job is not in the allow-set … This is the
  required context; it is RED on purpose." `Cloud gate` and `Console gate`
  subsume their own upstreams the same way. They are held out of the required
  list because requiring a leaf of a required aggregator re-implements the
  aggregator at leaf granularity and pins its internals as a contract — which is
  why `.github/required-checks.json` files each of them under **S3 SUBSUMED**,
  not as a claim that they are harmless.
- **ADVISORY — structurally unable to block.** A job carrying
  `continue-on-error: true` that no required aggregator lists in `needs:`. Both
  halves are load-bearing, and this is why: for a `continue-on-error` job
  `needs.<job>.result` reads `success` even when it failed, so an advisory job
  wired into an aggregator's `needs:` would launder its own red into a green
  required context. Today the class holds `reland-check`, `sobelow`,
  `boundary-gate`, `lighthouse`, `gofmt` and `required-checks-drift` — a red run
  of any of them cannot stop a merge. `format` **left this class on 2026-09-04**
  (#15971): it dropped `continue-on-error` FIRST, precisely so the laundering
  above could not happen, and only then joined `elixir-gate`'s `needs:`, where it
  is now SUBSUMED (the `elixir-gate` job's `needs:` comment block records it, and
  item 2 above has the diff scope). `plugin-node` is a third case again: blocking
  nothing today, and relevant only when the PR touches `api/priv/plugins/**`.

- **A NAME THAT SAYS `(blocking)` AND HAS NO MERGE AUTHORITY AT ALL.**
  `gofmt drift ceiling (blocking)` (`.github/workflows/go-format.yml`) is a real,
  working guard: it reds by name on any new off-roster gofmt drift and fails
  closed on a vacuous scan (`OK: 838 Go files scanned; 0 off-roster drift`). It
  is not required, not `needs:`-ed by any required aggregator, and structurally
  ineligible to be required because go-format.yml is paths-filtered (the venue
  rule below). Its `(blocking)` means *blocking inside its own workflow*,
  the same sense as doc-gates' `(fails this job)` steps below (that label
  replaced `(blocking)` there in #12631). It is now filed under
  **S4 PATHS-FILTERED**, and until 2026-08-08 it appeared in **neither**
  `.github/required-checks.json` nor this page. `required-checks.json` is
  GENERATED from names observed on sampled heads, so **every paths-filtered
  workflow is invisible to that census by construction**, and the same mechanism
  drops rows the other way with no report. Read an absence from that file as
  "the sample did not see it", never as "no such gate exists". That concession
  no longer covers a name that can BLOCK a merge: `scripts/blocking-name-census.py`
  (a step of `Elixir path-escape ratchet`, so it reds `Elixir gate`) walks each
  required aggregator's `needs:` closure statically and reds on any job in it
  that neither list names. Its output is the only source for census counts; `--at
  <rev>` re-derives the wave-56 residue recipe at any commit. History, with the
  four names it lost and the regeneration that now carries this row:
  [merge-gates-history.md](merge-gates-history.md#the-generator-merge-that-lost-25-exclusion-rows).
- **ADDING A BLOCKING JOB TO `security.yml` COSTS A SIXTH PLACE, and forgetting
  it reds the spec gate on every open PR.** #14073 paid the five its own message
  enumerates (the job, the aggregator's `needs`, its decide binding, every
  `env -i` simulator of that step body, the spec-authority marker) and stopped
  there. The sixth is the `ACK_EX` list in §14 of
  `scripts/required-checks.test.sh`: the hermetic suite drives the generator over
  a FROZEN fixture pair, so a job added after that freeze can never render there
  and the exclusion row it needs is permanently unrenderable ON THAT WINDOW — the
  generator then refuses every emit until the name is acknowledged. Re-sampling
  is not the escape hatch (D130 freezes the pair); typing the name into `ACK_EX`
  is. History: [merge-gates-history.md](merge-gates-history.md#the-2026-08-spec-gate-deadlock).

§19 of `scripts/required-checks.test.sh` derives both lists from source — the
aggregators' `needs:` from `.github/workflows/`, the required contexts from
`.github/required-checks.json` — and reds if ANY agent/human-tier doc describes a
transitive upstream of a required aggregator as unable to stop a merge.

### Where a guard that must BLOCK lives

**A guard can be mutation-proven and still stop nothing, because of the file it
was put in.** A workflow-level `on: pull_request: paths:` filter emits no run and
no check run on a PR that misses the paths, and an absent required context reads
`expected` forever (D18). `.github/required-checks.json` is the truth about the
required set, and its **S4 PATHS-FILTERED** rows (`go-format.yml`,
`doc-gates.yml`, `architecture.yml`, …) are that disqualification. The false step is the next: that a path-scoped guard therefore
has no home with merge authority.

**It has one, and the repo built it four times.** On origin/main 58092344b all
four required contexts live in workflows whose `pull_request:` arm carries NO
`paths:` key — elixir.yml, cloud.yml, console-harness.yml, pr-task-gate.yml — so
each starts on every PR and saves cost inside: one cheap dispatcher job
publishes the path decision as an output, and every expensive job carries a
**job-level `if:`** on it (four such jobs in elixir.yml, five in
console-harness.yml, three in cloud.yml — cloud.yml:572 is the reader-corpus
census, #17522). A job-level `if:` renders the check SKIPPED where a `paths:`
filter renders nothing: **skipped is a verdict, absent is not.** That is the
rule. A `push:`-arm filter is a separate question and is allowed
(console-harness.yml:103): protection gates merges INTO main and never sees a
push-to-main run.

**The dispatcher pays for it.** Every PR starts the workflow, so it must be cheap
and must never publish a silent `false`: two exits, no third — FAIL on an
unresolvable base, dispatch TRUE and run everything on an empty changed-file set
(console-harness.yml:313, cloud.yml:185 and elixir.yml's dispatcher each print
"a skip here would green a required context nothing measured", priced). A run
that dispatched nothing must then DISCLOSE that it evaluated nothing — NOT
APPLICABLE below, worked at pr-task-gate.yml:227. A guard kept out of
this shape must record that choice and its reason where it is documented
(`docs/contracts/canonical-impl-markers.md` is the worked example). What the rule
forbids is advisory while read as blocking.

### The required set governs the MERGE, not main's health afterwards

**These are two different properties and nothing above distinguishes them.** The
section you just read settles what can *stop a merge*. It says nothing about what
*turns main red once the merge lands* — and it is not the same set.

History: [merge-gates-history.md](merge-gates-history.md#the-2026-08-24-merge-that-left-main-red).

**The mechanism is the trigger block, not the required list.** A workflow with a
`push:` arm re-runs against the merge commit, so a red one on the PR is a red one
on main — required or not. **RE-DERIVE these counts; do not quote them.** The
2026-08-24 measurement over 55 workflows was stale within a day, and this block
still read "41 of 55" a week later. The figures are the 2026-09-01 re-derivation:

```bash
# workflows that re-run on main after a merge — 42 of 57 on 2026-09-01
for f in .github/workflows/*.yml; do
  awk '/^on:/{f=1} f{print} f&&/^[a-z]/&&!/^on:/{exit}' "$f" \
    | grep -q '^  push:' && echo "$f"
done | wc -l
```

- **42 carry a `push:` arm** (40 of them scoped to `branches: [main]`) — every one
  runs again on the merge commit.
- **37 of those 42 also run on `pull_request`.** These are the ones the incident
  is about: you saw the red before merging, it had no merge authority, and it
  moved onto main anyway.
- **5 are push-only** — `cli-release`, `deploy`, `release-artifact`, `release`,
  `scaffy-catalog-drift`. They can red main with **no pre-merge signal at all**,
  because they never appear on a PR to be read.
- **9 are `pull_request`-only and never run on main**: `pr-task-gate`,
  `reland-check`, `architecture`, `twoslash`, `search-template-gates`,
  `deploy-harnesses`, `weekly-changelog`, `chronicle-paper`, and
  `main-gate-watch` itself. A red
  there **cannot** red main, because nothing re-runs it there.

So the question to ask of a red check is never "is it required?" but
**"does its workflow have a `push:` arm?"**

**The worked example is a check this page already dissects.**
`gofmt drift ceiling (blocking)` is documented above as having *no merge
authority at all* — not required, not `needs:`-ed by any required aggregator,
structurally ineligible to be required because it is paths-filtered. All true,
and all about the merge. `go-format.yml` also carries `push: branches: [main]`,
so a red drift ceiling **merges cleanly and then reds main**. "Cannot block a
merge" and "cannot hurt you" are not the same sentence.

**And the post-merge watcher does not cover this.** `main-gate-watch.yml` reads
the required set **live from branch protection** and watches only those contexts
on main's tip, so a red NON-required context on main has *no* watcher: main
carries a red check while `main-gate-watch` stays green, correctly — that context
was never in its scope. The second scream is scoped to the first scream's list.

**Operationally:** four required greens are a *merge* predicate, not a
main-health predicate. Before merging — especially from automation — read the
full check list and treat any red whose workflow has a `push:` arm as a red you
are about to move onto main: nothing stops it, and nothing catches it after.

#### Changing branch protection taxes the watcher — read this first

`main-gate-watch.yml` derives its watched set **live from branch protection**,
never from the committed spec, so it cannot go stale against the live rule. The
price: **adding a required context reds the watcher until a human classifies
it** by name in `scripts/main-gate-watch.sh` (`WATCHED_CONTEXTS` /
`EXCLUDED_CONTEXTS`). One that is neither is a CONFIGURATION FAULT; guessing is
refused, because a PR-scoped context guessed as watched false-reds forever and a
post-merge one guessed as excluded is silently unwatched. **If you add a
required context, classify it in the same change.**

Two check-run names, two owners — they are split so a broken watcher does not
read like a red main (`cch-w59-bl-main-gate-watch-has-no-notification-egress`):

| Red check run | What it means | Who acts |
|---|---|---|
| **Main gate watch** | main's tip is genuinely not green on a watched required context (RED, or never judged) | whoever owns the red context; re-run or fix main |
| **Main gate watch configuration fault** | the watcher has no authority — `BREAKGLASS_TOKEN` rotated/removed, or protection names a context nobody classified | whoever changed protection or the secret. **Main gate watch is SKIPPED for that run — main's state is UNKNOWN, not green.** |

Neither is softened with `|| true`; neither is a required context. Getting a red
here *to a human* is a separate concern, owned by
`cch-w42-s4-main-push-gate-failures-find-a-human` — this split only makes the
two facts distinguishable once someone looks.

### A green gate does not prove the branch was rebased

`pull_request` gate runs test the **ephemeral merge commit** (`refs/pull/N/merge`
— the PR merged into `main` at dispatch time), never the branch tip in
isolation: every test job keeps the default checkout on purpose ("they must
test the merged result, not the head in isolation" — the checkout comment in
`elixir.yml`; only the path-DISPATCH jobs pin `pull_request.head.sha`, for
diff honesty, D34). And live protection sets
`required_status_checks.strict: false`, so a branch never has to be up to date
with `main` to merge. Together these are why wave 2's four branches merged with
tips that were never rebased — soundly, by mechanism, not by luck. A red
ADVISORY check (see above) leaves `mergeStateStatus: UNSTABLE`, which does not
block; unmet REQUIRED contexts render `BLOCKED` instead. Re-derive rather than
trust:

```bash
git merge-base <branch> origin/main    # where the tip actually forked
gh api repos/FRIKKern/barkpark/branches/main/protection \
  -q .required_status_checks.strict    # false → up-to-date not required
```

(The wave-2 record's version of this posture rests on a claim retired as false
since 2026-07-28; §18 of `scripts/required-checks.test.sh` censuses every
unpinned restatement. The conclusion survives on `strict: false` alone.)


### NOT APPLICABLE — the required green that ran nothing

The two classes above are both about whether a **red** can block. There is a
third class, and it is the one a merger meets on most PRs: **a required
aggregator that is PATH-GATED concludes GREEN when the diff touched none of its
declared path sets.** That green means **NOT APPLICABLE to this diff** — never
"the suite passed". Nothing was compiled, nothing was tested, no job was
dispatched, and the check-run still reads `pass` next to the merge button.

`gh pr checks <N>` prints `Cloud gate  pass` and stops there — the disclosure is
one API call or one UI click further on, which is why this page has to tell you
it exists. Measured on merged PRs:
[merge-gates-history.md](merge-gates-history.md#the-path-gated-green-measured-on-merged-prs).

Each path-gated aggregator emits the disclosure itself, as a `::notice`
annotation on its own check-run. §21 of `scripts/required-checks.test.sh` holds
both sides of the roster below; `—` means that gate does not emit, because it is
not path-gated at all.

| Gate | Emits `gate: green — nothing ran` from | Required context |
| --- | --- | --- |
| `Cloud gate` | `.github/workflows/cloud.yml` | yes |
| `Console gate` | `.github/workflows/console-harness.yml` | yes |
| `Elixir gate` | `.github/workflows/elixir.yml` | yes |
| `Security gate` | `.github/workflows/security.yml` | no |
| `Compose smoke` | `.github/workflows/compose-smoke.yml` | no |
| `Go gate` | `.github/workflows/go-tests.yml` | no |
| `Web gate` | `.github/workflows/ci.yml` | no |
| `PR references an active task` | — | yes |

So three of the four required contexts can go green having dispatched nothing.
The fourth, `PR references an active task`, is **exempt by construction** in the
path-gating sense: its workflow carries no `paths:` filter and no `changes`
dispatcher, so it executes on every PR. `Security gate`, `Compose smoke`, `Go
gate` and `Web gate` emit the same notice but are not required — a red one of the
four cannot block a merge and never could, so those greens are the weakest on
this roster. `Web gate` is ci.yml's aggregator, added 2026-09-11
(pds-bl-w48-web-gate-cannot-block-and-greens-vacuously) when that workflow's
`pull_request` paths filter was deleted: until then its one real job,
`web/ typecheck + unit tests + lint`, was ABSENT on a non-web head and could not
be required at all. Registering `Web gate` (the aggregator, never that leaf)
takes the required set 4 -> 5 and is a separate, deliberate act.
`Go gate` is step 2 of
go-tests.yml's header sequence; step 3 (register `Go gate`, never the leaf
`go vet + test`) has not landed. If `Compose smoke` or `Go gate` is ever
promoted to a required context, its `no` above must flip to `yes` in the same PR:
clause 3 of §21 parses the required set from `.github/required-checks.json` and
reds on any disagreement in either direction.

**The fourth had its own vacuous green, by a different mechanism, and until
2026-08-08 it disclosed nothing.** `pr-task-gate.yml` grandfathers a PR whose
base commit predates the gate, and every evaluating step below carries
`if: enforced == '1'` — so a grandfathered run concludes SUCCESS having verified
no task at all, byte-identical on the check-run API to a proven live claim. It
now emits its own annotation on that path,
`::notice title=PR task gate: green — nothing evaluated::` ("NO TASK WAS CHECKED
on this PR … Read it as 'no task check ran', never as 'this PR is task-backed'").
It is deliberately **not** worded `nothing ran` and stays a `—` row in the table
above: this green is not path-gating and that roster is for path-gated
aggregators. History: [merge-gates-history.md](merge-gates-history.md#the-pr-task-gate-grandfather-branch-and-the-39-of-39-re-derivation).

The annotation says it in its own words. `Cloud gate`, verbatim from
`cloud.yml`:

```
NOTHING CLOUD RAN on this head.
Cloud gate is green because this diff touched none of its declared path sets,
NOT because anything was tested.
Not dispatched: <the job list>
Green here means NOT APPLICABLE to this diff. Read it as 'no Cloud job
executed', never as 'the Cloud suite passed'.
```

**Where a merger reads it.** The GitHub check-run page shows the annotation
inline. From a terminal, `gh pr checks <pr>` will not show it — resolve the
head SHA's check-run id and read its annotations:

```bash
gh api "repos/FRIKKern/barkpark/commits/$(gh pr view <pr> --json headRefOid -q .headRefOid)/check-runs" \
  -q '.check_runs[] | select(.name|test("gate$")) | "\(.name)\t\(.conclusion)\tann=\(.output.annotations_count)\t\(.id)"'
gh api repos/FRIKKern/barkpark/check-runs/<id>/annotations \
  -q '.[] | "\(.annotation_level)\t\(.title)\t\(.message)"'
```

`ann=0` on a green gate means it really ran; `ann=1` with that title means it
ran nothing. The emission is pinned by
`scripts/gate-announces-skips.test.sh`, which runs inside the `Elixir gate`
aggregator's own `needs:` graph and asserts the DELIVERED annotation title, so a
gate that quietly stopped disclosing reds a required context.

History: [merge-gates-history.md](merge-gates-history.md#what-a-docs-and-scripts-pr-actually-clears).

### PRESENT BUT STALE — the green that ran, and then stopped being true

The three classes above are all about a check that is **absent** or **ran
nothing**. There is a fourth, and it is the only one where the check really did
execute the suite: **a CONFLICTING pull request keeps asserting the verdict it
earned on a head main has since passed, and it re-dispatches nothing to refresh
it.** GitHub dispatches on push. A conflicted PR cannot be merged and nobody
pushes to it, so its runs are frozen at the instant they were created and the
checks API answers SUCCESS forever.

History: [merge-gates-history.md](merge-gates-history.md#the-stale-verdict-population-measured-2026-08-09).

`.github/workflows/stale-verdict-watch.yml` is the level check that says so:
`*/30` cron, no `continue-on-error` anywhere, `if: github.event_name !=
'pull_request'` so its name can never enter the required set. It reds while any
conflicted PR asserts a green whose `completedAt` predates a commit on main, and
that red cannot clear itself — only a rebase, a push, or a close clears it.

Two counting traps it avoids, both lying in the comforting direction:

- **Count ALL-OF-PRESENT, never occurrences-of-SUCCESS.** A required context can
  render twice on one head, once FAILURE and once SUCCESS; counting SUCCESS
  occurrences launders the failing one out of the report. A context is green
  only when it rendered and *every* entry carrying its name concluded SUCCESS.
- **`mergeable` is LAZILY COMPUTED, and UNKNOWN is a warning row.** The first
  `gh pr list` after a quiet period answers UNKNOWN for most rows and settles
  seconds later. A naive `select(.mergeable == "CONFLICTING")` drops those rows
  and prints a calmer number. Re-poll, and print whatever is still UNKNOWN as a
  warning row. Both traps are measured on the history page linked above.

Being merely **behind** main is not in this class and is never reported: main is
`strict: false`, so a MERGEABLE PR behind main is what the merge policy permits.
Only a conflicted one is stuck. All four behaviours are mutation-proved over
fixtures in `scripts/stale-verdict-watch.test.sh`.

### SELF-CAMOUFLAGING — the fix that narrates itself in the vocabulary it removed

The four classes above are about a CHECK that reads green. There is a fifth, and
its victim is the **search** an author uses to re-derive what is left to do: **a
change that documents itself in the vocabulary of the thing it removes makes its
own prose indistinguishable from the remaining work.** The codebase's own search
key stops discriminating, and it stops discriminating in the comforting
direction — the fix looks like the biggest remaining cluster.

Measured, not inferred, on #16888:
[merge-gates-history.md](merge-gates-history.md#the-16888-sweep-that-counted-its-own-explanations).

When a fix narrates the pattern it deleted, describe that pattern in prose —
name the statuses, not the numerals — rather than reproducing a greppable
literal. Then anchor the sweep grep on `status` before the bracket, so an
assertion and a sentence about one stop matching the same expression; that
strict form is invariant across the reword, which is how you prove the reword
removed only phantoms.

The non-vacuity arm is the acceptance criterion that matters: re-run the loose
sweep after the reword and confirm it still returns the same number of LIVE-CODE
sites. A fix that silences false positives by blinding the search has made the
artifact worse than the noise it removed.

### PARSED BUT NOT RUN — the static check that cannot see an expansion-time error

Those five are about a CHECK that reads green; the sixth is the hand check
an author runs on a gate script: **`sh -n script.sh` answers 0 on a script that
then exits 0 having compared NOTHING.** A capture that fails at RUN time leaves
its operand EMPTY, the assignment discards the status, and emptiness reads as "no
differences". Measured 2026-09-13, `scripts/sunset-route-consumers.test.sh`
under `sh`: exit 0, `---- 0 failure(s), 32 pass(es)`, and four swallowed
`command substitution: … syntax error` lines on stderr.

**THE TRIGGER IS PLATFORM-SHAPED; THE SHAPE IS NOT.** That was bash 3.2 (macOS),
which refuses process substitution in POSIX mode and parses command
substitutions LAZILY — the refusal lands at expansion time. bash 5.2.21 (ubuntu
24.04, CI) ALLOWS it: same fixture, exit 2, both comparisons red
(2026-09-15). **The vacuous variant is what a macOS developer sees; CI sees the
loud one.**

**Verify a gate script by RUNNING it under the interpreter in question.**
`scripts/posix-vacuous-green-census.sh` says so in its RED remedy line: its
`sh-n-blindness` arms re-measure it on any interpreter; its
`procsub-under-posix` arms DETECT which world they are in, then assert what that
world owes — vacuous where refused, loud where allowed, CANNOT READ where
neither, never a skip.

## Security gates (Sobelow + mix_audit)

`.github/workflows/security.yml` (filed by `task-a41fc4590b2c2eb1`) adds two
Elixir security gates, path-triggered on `api/**` — items **9 (`sobelow`)** and
**10 (`mix-audit`)** of this page's roster. Their policy of record moved out to
[security-gates.md](security-gates.md) under its own `canonical-for`: the
reviewed `api/.sobelow-skips` baseline, the amended flip precondition and the
unannotatable floor, the `Security gate` aggregator's shape and why
`sobelow` is deliberately not in its `needs:`, and the single esaml
`--ignore-advisory-ids` suppression. Nothing was retired — the split was made
because this page was 5 bytes under its 64000B cap and the remedy for overflow
is to split, never to raise the cap. Read the two gates' strengths there, not
from memory.

## Platform checks (not ours — GitHub App checks)

Two checks on every PR are posted by an external GitHub App, not by any
workflow in `.github/`. They are not in the roster above because we do not
run them, cannot run them locally, and cannot fix them in a PR.

11. **`Vercel – barkpark` / `Vercel – demo`** — deployment checks from the
    Vercel GitHub App (projects `guerrilla/barkpark` and `guerrilla/demo`).
    **Advisory** — and advisory here means *ignored*, not *tolerated*: there
    is no `continue-on-error` to set, because these are not our jobs. The
    classification rests on measurement: both report `fail` on **every** open
    and recently-merged PR repo-wide, including PRs that change zero `cloud/`
    files, and a check red identically on disjoint diffs is not reading the
    diff. **The root cause is NOT diagnosed** — "platform-side" is an inference
    from the failure *pattern*; nobody has run the `npx vercel inspect
    dpl_<id> --logs` the check surfaces. So treat these two as carrying no
    information about the PR under review, and do not cite this entry as
    evidence that Vercel is *healthy*. Diagnosis is owned by
    **`hg-bl-vercel-legacy-statuses-red-repo-wide`** (it absorbed
    `gr-blk-vercel-checks-ungoverned`, cancelled as a duplicate — do not
    re-file either); when it lands, this entry gets a real classification.

    History: [merge-gates-history.md](merge-gates-history.md#provenance-of-the-vercel-advisory-classification).

**Registration and the two armed overrides** — how a context becomes required-by-name, break-glass, and the recorded override moved to [branch-protection-and-overrides.md](branch-protection-and-overrides.md); this page stays the gate roster.

## Local pre-merge check

Run this before pushing — it mirrors the CI gate exactly:

```bash
make precheck
# or, equivalently:
cd api && rm -rf _build/prod && MIX_ENV=prod mix deps.get && \
  MIX_ENV=prod mix deps.compile --force && \
  MIX_ENV=prod mix compile --warnings-as-errors
```

### Why a partial clean is not enough

Owned by `CLAUDE.md` golden rule #1 and "Past Mistakes" #1: a subset clean
leaves stale `.beam` artifacts and the bug surfaces only after a prod deploy.
**Always `rm -rf _build/prod` first.**

### Why dev-mode `mix compile` is insufficient

`MIX_ENV=dev` enables compile-time leniency that `:prod` does not — notably some
macro-vs-function ambiguities in `runtime.exs` `when` guards — and `:test` is
similarly lenient. Only `MIX_ENV=prod mix compile` rejects the PR #42 bug class.

## Lessons-learned: PR #42 macro-in-guard (2026-04-25)

History: [merge-gates-history.md](merge-gates-history.md#lessons-learned-pr-42-macro-in-guard-2026-04-25).

**When to override** — the recorded `mix-prod-compile` bypass, and the task that is its durable record, moved to [branch-protection-and-overrides.md](branch-protection-and-overrides.md#when-to-override).

## Documentation review rules (doc-gates)

PRs touching `*.md` **or any source file** (`.ex`, `.exs`, `.go`, `.ts`,
`.tsx`) also run `.github/workflows/doc-gates.yml` — code changes trigger it
because `@canonical capability:` markers in source files must be re-checked
when a code rename rots a marker. The workflow also fires on changes to the
gate scripts themselves and to the workflow file.

### The doc-gates roster (it is not two scripts)

`doc-gates` is a single job (`Doc budgets + anchors`) whose name badly
undersells it: it runs **30 steps labelled `(fails this job)`** plus the
`(tripwire)` self-tests that prove a scanner still reds on a planted defect. A
PR touching one `.ex` file runs all of them.

History: [merge-gates-history.md](merge-gates-history.md#the-doc-gates-step-label-blocking-became-fails-this-job).

The deciding structure, not the naming: `.github/workflows/doc-gates.yml`
publishes exactly ONE check-run context — the job name `Doc budgets + anchors`
— and `.github/required-checks.json` files that context as an **S4
PATHS-FILTERED** exclusion row, one of 26, not one of the four required
contexts (`Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active
task`). The workflow also carries a workflow-level `on: … paths:` filter, so on
a PR touching none of those paths the check is simply ABSENT. Said negatively,
which is the phrasing that cannot be read as a promise: a red step reds THIS
JOB on the PRs where it runs, and that red is visible on the PR; **none of it
stops a merge**, and `doc-gates` **cannot block a merge** by itself. That is the
whole of its authority.

(The count read 17 until 2026-08-07, two steps short; it read 26 until #18707
added the doc-drift pair, and 28 until #19266 added the charter adoption
census. The current count is derived by
running, not transcribed:

```bash
grep -cE '^[[:space:]]*- name: .*\(fails this job\)' .github/workflows/doc-gates.yml
grep -cE '^[[:space:]]*- name: .*\(tripwire\)'        .github/workflows/doc-gates.yml
```

§20 CLAUSE
11 of `scripts/required-checks.test.sh` reds if the prose count, the table rows
below, and the workflow drift apart, and it counts the UNION of both labels so a
revert to the old name is still counted rather than read as zero. RESIDUE, named
rather than left to be tripped over: the unanchored `grep -c '(fails this job)'`
returns MORE, because `.github/workflows/doc-gates.yml` quotes both labels
inside its own corrective header — anchor on `- name:`, as above. §20 CLAUSE
11's pass message also still spells the label `(blocking)`; it compares NUMBERS,
so its verdict is unaffected.) In workflow order:

| # | Step | Runs |
|---|------|------|
| 1 | Doc byte budgets | `scripts/check-doc-budgets.sh` (byte caps + the 7-card cap) |
| 2 | Doc anchors + headers | `scripts/docs-anchors-check.sh` (routing/INDEX targets, card Code anchors, G1 doc-tier headers, `canonical-for` uniqueness, `@canonical capability:` slug uniqueness + public-entry-point placement, ARCHIVED banners) |
| 3 | Connectors DDL drift | `scripts/connectors-ddl-drift-check.sh` (+ `--selftest`) |
| 4 | Connectors catalog drift | `scripts/connectors-catalog-drift-check.sh` (+ `--selftest`) |
| 5 | Never-cancel-main concurrency ratchet | `scripts/never-cancel-main-check.sh` (+ `--selftest`) |
| 6 | Deploy paths↔filters drift | `scripts/check-deployyml-filters.sh` (+ `--selftest`) |
| 7 | Control-plane smoke can-fail | `scripts/check-deploy-smoke.sh` (+ `--selftest`) |
| 8 | Paper-editor style mirror | `scripts/paper-editor-mirror-check.sh` |
| 9 | Status manifest drift | `scripts/status-manifest-check.sh` |
| 10 | Preview parity + no-oEmbed | `scripts/preview-parity-check.sh` |
| 11 | Design-token drift | `node design/validate.mjs` · `design/check.mjs` · `derive.test.mjs` · `theme-emit.test.mjs` |
| 12 | Studio literal-color | `scripts/studio-literal-check.sh` |
| 13 | Studio link/path | `scripts/studio-link-lint.sh` (+ `--selftest`) |
| 14 | Web literal-color | `scripts/web-literal-check.sh` |
| 15 | Go literal-color | `scripts/go-literal-check.sh` (+ `--selftest`) |
| 16 | Code-comment citation guard | `tooling/doc-truth/acceptance-code-comments.mjs` · `retired-terms.mjs` · `lineref-sweep.mjs` (`--selftest`, then the sweep) |
| 17 | New file:line citations in comments | `scripts/new-lineref-check.sh` (+ `--selftest`) |
| 18 | Tenant fail-open read baseline | `scripts/tenant-scope-check.sh` (+ `--selftest`) |
| 19 | Nil-polarity fail-closed gate | `scripts/nil-polarity-check.sh` (+ `--selftest`) |
| 20 | Preview-env isolation | `scripts/preview-env-isolation-check.sh` (+ `--selftest`) |
| 21 | PortableDoc render parity | `scripts/pd-parity-completeness.sh` |
| 22 | Scaffy anchor drift | `bp scaffy validate` over `scaffy/commands/` (+ `--selftest`) |
| 23 | Dependabot root drift | `scripts/dependabot-roots-check.sh` |
| 24 | Silencer growth ratchet | `scripts/silencer-growth-ratchet.sh` |
| 25 | repo-papers snapshot freshness | `node scripts/repo-papers-freshness.mjs` (+ its `(tripwire)` self-test step; added by #17151, 2026-09-09) |
| 26 | Paper dialect ratchet | `scripts/paper-dialect-ratchet.sh` (+ its `(tripwire)` self-test step; shrink-only counts of text-keyed inline leaves and malformed widget items per in-repo paper corpus, with a non-vacuity floor that REFUSES rather than greens) |
| 27 | Doc drift — links, routes, placeholders, runnable examples | `scripts/doc-drift-check.sh` (+ its `(tripwire)` self-test step; diff-scoped, landed by #18707 — see *When your PR touches a doc* below) |
| 28 | Charter-corpus marker hygiene | `scripts/charter-corpus-hygiene-check.sh` (`--selftest`, then the check) over the `.claude/workflows/*-charter.md` corpus |
| 29 | Charter adoption census | `deploy/charter-adoption-check.sh` (`--selftest`, then the check; the deploy-reliability charter's declared adoption set vs the set derived from `.github/workflows/`, red in both directions — D620) |
| 30 | bp-command doc parse over docs/cli | `node tooling/doc-truth/verify-bp-commands.mjs` (`--selftest`, then the gate over `docs/cli/*.md`; the step carries its own glob FLOOR of 3 files, so a glob that expands to nothing FAILS and can never read as a pass) |

Run any of them locally with the same command CI uses — they are ordinary
scripts, not workflow-only steps. `docs-anchors-check.sh` runs clean in ~50s
on a contended checkout (an older caution to avoid running it locally is
retired; it was fixed in #4473).

### What step 1 covers under `docs/ops/` — and what this page's own header means

`scripts/check-doc-budgets.sh` gates a hand-written byte table (pinned by
`CAPS_ROWS_EXPECTED` — re-derive the row count from the script, it moves), the 7
`docs/cards/*.md`, the pinned `docs/setup/CODEX.md` onramp span, **and every
other spine doc by HEADER DISCOVERY**: a declared `budget: Ntok` is enforced as
`N * 4` bytes. Under `docs/ops/` the hand-written table names three files —
`docs/ops/PROD_OPS.md`, this page, and
`docs/ops/branch-protection-and-overrides.md`; the rest are capped by their own
headers, which is why `docs/ops/security-gates.md` needed no new table row. The
older reading — that a `docs/ops/` header outside the table is a declaration no
gate reads — is DEAD: discovery closed that hole, and the `budget:` figure in a
header is now the cap.

History: [merge-gates-history.md](merge-gates-history.md#the-budget-header-that-enforced-nothing). The registration / break-glass / recorded-override runbook
moved out to `docs/ops/branch-protection-and-overrides.md` under its own
`canonical-for`, which brought this page back under the 16000tok it declares;
then both files were given a BINDING row in the CAPS table — 64000B here (the
declared 16000tok at the repo's ~4B/tok convention) and 10400B there. The header
is now a ceiling the file is held to, and the headroom is deliberately thin: the
next section that does not fit reds `Doc budgets + anchors` and must be split or
retired, never capped upward. Measure with `wc -c`, never from this paragraph —
a byte figure typed here has no producer and goes stale in its own commit. Dropping the header figure
was never an option — G1 in `scripts/docs-anchors-check.sh` requires
`budget: [0-9]+tok` on every active doc. Adding a page to the CAPS table remains
a deliberate two-line `scripts/` edit: the row, plus the `CAPS_ROWS_EXPECTED`
bump.

### When your PR touches a doc — three contributor rules

These are the rules a reviewer applies to the DOC half of an ordinary PR. They
are enforced, where they are enforced at all, by `scripts/doc-drift-check.sh`
(step 27 of the roster above, wired into `.github/workflows/doc-gates.yml` on
both the `push` and `pull_request` arms) — reviewed and landed in **PR #18707**.

1. **A new durable fact goes into its CANONICAL OWNER.** `canonical-for` in the
   G1 header is unique repo-wide, so every topic has exactly one document that
   owns it; adding the fact to a second doc is how one topic ends up with two
   answers that disagree, and the reader has no way to tell which is current.
   `scripts/docs-anchors-check.sh` enforces the uniqueness of the topic, not the
   placement of the fact — that part is a reviewer's job. If the owner is at its
   byte ceiling, **split it or retire content** (this page's own Security-gates
   section was split out to `docs/ops/security-gates.md` for exactly that
   reason); writing the fact somewhere else instead is the failure this rule
   exists to stop, and raising the cap is not an option.
2. **An INDEPENDENT READER reviews the doc change, not just the code change.** A
   second reader asks a different question: the author already knows what the
   sentence was meant to say, so the author cannot be the one who checks that it
   says it. Name what you want checked — that the route in the link is the one
   you meant, that the example is the one you actually ran. No gate can do this,
   and none pretends to; it is a review rule, not a check.
3. **RE-RUN the supported startup paths a doc names.** If your change touches a
   file an allowlisted example depends on, declare it —
   put an HTML comment reading `doc-exec: allowlisted deps=path/one,path/two`
   on the line above the fence (spelled out rather than reproduced here: the
   checker matches that literal LINE-WISE, so a marker quoted in prose with no
   fence under it is itself a red) — and the drift check
   re-runs that example on YOUR PR instead of leaving it to rot until someone
   else's. Unmarked fences are never run, so an example you want PROTECTED has
   to say so.

**Actual check coverage — what is mechanised and what is not.** Rules 1 and 3
are partly mechanised; rule 2 is not mechanised at all.

| Rule | What a check actually does | Deliberately silent about |
|---|---|---|
| 1 · canonical ownership | `docs-anchors-check.sh` reds on a duplicate `canonical-for` topic and on a missing G1 header; `check-doc-budgets.sh` reds when an owner overflows its byte cap | whether a given FACT landed in the right owner — no gate reads meaning |
| 2 · independent reader | nothing | everything — this rule is carried by review alone |
| 3 · rerun startup paths | `doc-drift-check.sh` re-runs a fence carrying the `doc-exec: allowlisted` marker comment and reds on a non-zero exit, diff-scoped: yours when your diff touches the doc or a declared `deps=` file | every unmarked fence; cold-tier docs, `_attic/`, `fixtures/` trees and `tooling/grip/ledger/` are out of the corpus |
| (carried along) links + placeholders | `doc-drift-check.sh` reds on a relative link target that resolves nowhere, and on `FIXME` / `TBD` / `TODO:` / `<PLACEHOLDER>` / `REPLACE_ME` standing as prose | `http(s)`, absolute, anchor-only and templated targets; a bare extensionless route a `.md`, a directory or an `index.md` serves; the same placeholder words inside a fence or code span, which are quotation, not assertion |

**The strength of that coverage, said negatively.** Every one of those checks
runs inside the single `Doc budgets + anchors` job, which is an S4
paths-filtered exclusion in `.github/required-checks.json` and **cannot block a
merge** — a red is visible on the PR and nothing more. So rules 1–3 are
REVIEW rules with partial mechanical assistance, never a merge wall. Run them
yourself before pushing: `bash scripts/doc-drift-check.sh` (scoped to
`origin/main...HEAD`) and `bash scripts/doc-drift-check.test.sh` for its twelve
regression arms. Mechanism detail lives in `tooling/doc-truth/README.md`.

### Touching `api/lib/barkpark_web/layouts/root.html.heex`

The Studio shell is the single most gate-dense file in the repo — **four**
of the steps above read it, and no card names them all, which is how a
one-line CSS edit turns into three surprise reds:

- **12 · `scripts/studio-literal-check.sh`** — no new hand-stamped hex/hsl
  colour in Studio chrome; `var(--…)` only.
- **11 · `design/check.mjs` Part E** — the exemption **ratchet**. It counts
  colour literals per file against a frozen baseline in
  `design/exemptions.json` (`root.html.heex` is entry #1).
- **8 · `scripts/paper-editor-mirror-check.sh`** — the reader→editor style
  mirror. When the surface legitimately changes, re-stamp it with
  `bash scripts/paper-editor-mirror-check.sh --write` in the same diff.
- **13 · `scripts/studio-link-lint.sh`** — no hand-built, interpolated
  scope/dataset Studio URL literal; build paths through
  `StudioLive.Paths`.

**D53 — the inverse blind spot (the expensive one).** Steps 10 and 9 do *not*
cover the same thing; each is blind exactly where the other bites:

- `rgba(0,0,0,.55)` **passes** the literal gate (it does not scan `rgb()`/
  `rgba()` function values at all) and **fails** Part E (which counts any
  `rgb()/rgba()/hsl()` whose first argument is not `var(`).
- An inline `lit-allow:` comment silences the literal gate and gives Part E
  **zero** cover — there is no such mechanism in `check.mjs`. This has already
  shipped a red: #2273 added one print-reset `#fff` under a `lit-allow`
  without raising the baseline.
- Part E fails on **shrink** as hard as on growth: tokenizing a literal is
  good, and the baseline must be lowered *in the same diff*, or a stale-high
  number leaves slack for a future regression to hide in.

So: any colour change to `root.html.heex` is a two-file diff —
the shell *and* `design/exemptions.json`.

Reviewer rules on top of the scripts:

a. A new top-level feature requires a routing-table row or a card update in
   the **same PR**.
b. A new card requires retiring or merging one (G2 — hard cap at 7 cards;
   enforced as a count in `check-doc-budgets.sh`).
c. A PR touching a file that a card anchors must update the card, or the
   anchor check fails.
d. Golden Rules and Past Mistakes in root `CLAUDE.md` are verbatim-exempt —
   any edit to them requires explicit owner sign-off.
e. Retired docs are deleted, not archived in-tree; git history is the
   archive, and recovering one is a `git checkout <rev> -- <path>`.

On byte-cap overflow: split to the owning contract/runbook or retire
content — never raise the cap.

## Quick reference

| Need to do                 | Command                                        |
|----------------------------|------------------------------------------------|
| Run the gate locally       | `make precheck`                                |
| Run the dev test suite     | `cd api && mix test`                           |
| Run the plugin matrix test | `bash api/test/scripts/test-plugin-node-matrix.sh` |
| Lint the workflows         | `actionlint .github/workflows/*.yml`           |

`actionlint` is not installed here by default (`brew install actionlint`, or
`go install github.com/rhysd/actionlint/cmd/actionlint@latest`) and CI does not
run it; add it as a separate workflow if drift becomes common.

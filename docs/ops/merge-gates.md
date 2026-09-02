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
   `mix format --check-formatted`. Currently **advisory** (`continue-on-error:
   true`; the job is named "Format … advisory"). Its own dedicated, fast job
   (~30s, no DB, no full compile) so drift is visible in <60s. It was split out
   of the `mix-test` job to *become* a blocking gate once format drift is
   cleared. Today a red `format` check still does not block merge, and it is the
   only job on this list that genuinely cannot: it carries
   `continue-on-error: true` and is deliberately absent from every required
   aggregator's `needs:` (see §"Blocking, required, and the difference" below).
3. **`mix-prod-compile` CI job** — same workflow, gated only by the `changes`
   dispatcher (`needs: [changes]` under the `mix-prod-compile:` job key in
   elixir.yml — there is **no** edge to `mix-test`; the "NO needs: mix-test"
   comment directly beneath it records why it was removed, and a reader who
   plans around a test→compile ordering is planning around an edge that no
   longer exists. Cited by JOB KEY, not by line, and the reason is measured:
   this sentence pinned bare line numbers (510, 515) until 2026-09-01, by which
   time the job had moved past line 760 — and it moved AGAIN during the very
   session that fixed it, when an unrelated merge landed in the same workflow.
   A line number in a doc is correct exactly once; `grep -n '^  mix-prod-compile:'`
   is correct always). Cleans `api/_build/prod`, force-recompiles deps,
   then runs `MIX_ENV=prod mix compile --warnings-as-errors`. **This is the
   gate** — and it stops a merge transitively, as an upstream `needs:` of the
   required `Elixir gate`.
4. **`validation-perf` CI job** — same workflow, independent of `mix-test`.
   Runs the synthetic 200-field / 100-rule bench, takes the median of 5 timed
   runs, fails if the median exceeds 100ms. A hard gate, and mechanically
   enforced: it too is an upstream `needs:` of the required `Elixir gate`, so a
   red bench reds the required context and the merge button stays grey. (Until
   2026-08-07 this item ended by denying that any mechanism enforced it — false
   since the aggregator became a required context.)
5. **`plugin-node` CI job** — `.github/workflows/plugin-node.yml`. Discovers
   plugins under `api/priv/plugins/` whose `plugin.json` declares a top-level
   `"node"` object and runs `npm ci` + lint + typecheck per plugin. Emits a
   no-op success when no plugin declares Node, so the check is always
   *present on the PR*. Present is not required: it **cannot stop a merge** —
   it is none of the four required contexts and no required aggregator lists
   it in `needs:`, which is the same reading §"Blocking, required, and the
   difference" gives it below ("blocking nothing today"). Until 2026-08-07
   this item ended "…so the workflow is always present in the required-status
   list", contradicting that section 380 lines further down the same page.
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

### Blocking, required, and the difference

**"Not required" and "cannot stop a merge" are different properties, and this
page conflated them until 2026-08-07.** Everything on a PR that is not one of
the four required contexts falls into one of two classes, and only one of them
is harmless:

- **SUBSUMED — blocking transitively.** The mechanism, in one sentence: a
  required aggregator declares upstream jobs in `needs:` and fails closed over
  their results, so a red upstream reds the required context and blocks the
  merge exactly as if it had been required itself. `Elixir gate` is
  `needs: [changes, mix-test, mix-prod-compile, validation-perf, path-escape]`
  (the `elixir-gate` job's `needs:` line in elixir.yml), so all five block. Driven rather than read off the topology:
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
  `continue-on-error: true` that no required aggregator lists in `needs:`. Here
  that is `format`: a red `format` does not block merge, and PR #123 merged with
  it red. The `continue-on-error` half alone is not enough — for such a job
  `needs.<job>.result` reads `success` even when it failed, so an advisory job
  wired into an aggregator's `needs:` would launder its own red into a green
  required context. `format` is deliberately kept out of that list for exactly
  this reason (see the `elixir-gate` job's `needs:` comment block, which spells out why `format` is excluded). `plugin-node` is a third case again: blocking
  nothing today, and relevant only when the PR touches `api/priv/plugins/**`.

- **A NAME THAT SAYS `(blocking)` AND HAS NO MERGE AUTHORITY AT ALL.**
  `gofmt drift ceiling (blocking)` (`.github/workflows/go-format.yml`) is a real,
  working guard: it reds by name on any new off-roster gofmt drift and fails
  closed on a vacuous scan (`OK: 838 Go files scanned; 0 off-roster drift`). It
  is not required, not `needs:`-ed by any required aggregator, and — because
  go-format.yml carries a workflow-level `on: pull_request: paths:` filter — it
  is structurally ineligible to be required, since an absent context reports
  `expected` forever. Its `(blocking)` means *blocking inside its own workflow*,
  the same sense as doc-gates' 22 `(fails this job)` steps below (that label
  replaced `(blocking)` there in #12631). Until 2026-08-08 it
  appeared in **neither** `.github/required-checks.json` nor this page:
  `grep -c gofmt` was 0 in both. That was not an oversight anyone could have
  caught by re-reading — `required-checks.json` is GENERATED from names observed
  on sampled heads, and its own `_readme` concedes "EXCLUSIONS ARE WHAT THE
  SAMPLE SAW, never a complete census", so **every paths-filtered workflow is
  invisible to that census by construction**. The same mechanism loses rows in
  the other direction with no report: four names once enumerated there
  (`PR task gate self-test`, `Re-land advisory`, `Filebase aesthetics gate`,
  `Boundary gate`) have silently left the list on regeneration. Read an absence
  from that file as "the sample did not see it", never as "no such gate exists";
  the ceiling is now filed there under **S4 PATHS-FILTERED** with that mechanism
  written into its reason. **That hand-added row now survives a regeneration,
  and until 2026-08-09 it did not.** What stood here — "re-add it by hand after
  any `required-checks-generate.sh` run" — was a guard that could not lose,
  because a human remembering is not a mechanism: the generator's MERGE covered
  `_readme` and the check LIST (a base-first union) but emitted `exclusions:`
  from the array it had just derived, never reading the committed one, and a
  paths-filtered name cannot enter that array because stage 2 iterates only
  names that rendered on the sampled main heads. Measured over the frozen
  fixture pair, that took **25 exclusion rows in and wrote 18 out, exit 0, with
  nothing on stderr**. `scripts/required-checks-generate.sh` now emits
  `.exclusions` as the same base-first union (the *derived* reason winning where
  both sides carry a row), **and** refuses by name when a run cannot re-derive a
  committed exclusion — acknowledged one name at a time with
  `--expect-unrendered '<name>'`, the same flag the check list already uses — so
  the carry can never be silent. A committed exclusion the run instead SELECTS
  as required is a contradiction rather than an absence — carrying it would emit
  one context on both lists — so it refuses separately and takes
  `--expect-promoted '<name>'`, which DROPS the committed row instead of
  carrying it. Both arms are mutation-proven in §14b of
  `scripts/required-checks.test.sh`.
- **ADDING A BLOCKING JOB TO `security.yml` COSTS A SIXTH PLACE, and forgetting
  it reds the spec gate on every open PR.** #14073 paid the five its own message
  enumerates (the job, the aggregator's `needs`, its decide binding, every
  `env -i` simulator of that step body, the spec-authority marker) and stopped
  there. The sixth is the `ACK_EX` list in §14 of
  `scripts/required-checks.test.sh`: the hermetic suite drives the generator
  over a FROZEN fixture pair, a job added after that freeze can never render
  there, and the committed exclusion row it needs is therefore permanently
  unrenderable ON THAT WINDOW — so the generator refuses every emit until the
  name is acknowledged. Re-sampling is not the escape hatch (D130 freezes the
  pair on purpose); typing the rendered name into `ACK_EX` is. Main was red on
  exactly this from **2026-08-24T21:59Z to 2026-08-31T20:14Z** — 6d22h elapsed,
  eight calendar dates — and every open PR carried the red with it. During that
  window this gate was decorative, so a "merged on 4/4 green" in it records a
  convention rather than a gate.

§19 of `scripts/required-checks.test.sh` derives both lists from source — the
aggregators' `needs:` from `.github/workflows/`, the required contexts from
`.github/required-checks.json` — and reds if this page ever again describes a
transitive upstream of a required aggregator as unable to stop a merge.

### The required set governs the MERGE, not main's health afterwards

**These are two different properties and nothing above distinguishes them.** The
section you just read settles what can *stop a merge*. It says nothing about what
*turns main red once the merge lands* — and it is not the same set.

Reported 2026-08-24 by the lead running the merge automation: a PR was merged on
the strength of four green required contexts **while a fifth, non-required check
was failing**, and main stayed red for every lane until a follow-up landed. The
merge was correct by the rule the automation applies. The rule is the gap.

**The mechanism is the trigger block, not the required list.** A workflow with a
`push:` arm re-runs against the merge commit, so a red one on the PR is a red one
on main — required or not. **RE-DERIVE these counts; do not quote them.** They
were measured 2026-08-24 over 55 workflows and were stale within a day — three
workflows landed 2026-08-24/25 (`research-coverage-suite`, `hundesteder`,
`chronicle-paper`) and this block still read "41 of 55" on 2026-09-01. The
figures below are the 2026-09-01 re-derivation:

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
on main's tip. A red NON-required context on main therefore has *no* watcher:
main carries a red check while `main-gate-watch` stays green — correctly, since
that context was never in its scope. The second scream is scoped to the first
scream's list.

**Operationally:** four required greens are a *merge* predicate, not a
main-health predicate. Before merging — and especially from automation — read the
full check list and treat any red whose workflow has a `push:` arm as a red you
are about to move onto main. It is not blocked, and it will not be caught
afterwards either.

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

(The wave-2 record explained this posture with the exact claim the
Security-gates topology note above retires as **false since 2026-07-28**. It is
deliberately not re-quoted here — §18 of `scripts/required-checks.test.sh`
censuses every unpinned restatement, and one pinned copy is enough. The
conclusion survives on `strict: false` alone.)


### NOT APPLICABLE — the required green that ran nothing

The two classes above are both about whether a **red** can block. There is a
third class, and it is the one a merger meets on most PRs: **a required
aggregator that is PATH-GATED concludes GREEN when the diff touched none of its
declared path sets.** That green means **NOT APPLICABLE to this diff** — never
"the suite passed". Nothing was compiled, nothing was tested, no job was
dispatched, and the check-run still reads `pass` next to the merge button.

Measured on merged PRs, not inferred: on #10565 (head `bb15f596d`, a single
ledger `.md`) the per-commit check-runs read `Cloud control-plane (compile +
format) | skipped`, `Cloud control-plane (test) | skipped`, `Cloud gate |
success` with one annotation. #10450 (head `5a43bf893`) is the same shape.
`gh pr checks 10565` prints `Cloud gate  pass  4s` and stops there — the
disclosure is one API call or one UI click further on, which is why this page
has to tell you it exists.

Each path-gated aggregator emits the disclosure itself, as a `::notice`
annotation on its own check-run. The roster below is the contract §21 of
`scripts/required-checks.test.sh` holds both sides of; `—` in the second column
means that gate does not emit, because it is not path-gated at all.

| Gate | Emits `gate: green — nothing ran` from | Required context |
| --- | --- | --- |
| `Cloud gate` | `.github/workflows/cloud.yml` | yes |
| `Console gate` | `.github/workflows/console-harness.yml` | yes |
| `Elixir gate` | `.github/workflows/elixir.yml` | yes |
| `Security gate` | `.github/workflows/security.yml` | no |
| `Compose smoke` | `.github/workflows/compose-smoke.yml` | no |
| `PR references an active task` | — | yes |

So three of the four required contexts can go green having dispatched nothing.
The fourth, `PR references an active task`, is **exempt by construction** in the
path-gating sense: its workflow carries no `paths:` filter and no `changes`
dispatcher, so it executes on every PR. `Security gate` and `Compose smoke` emit
the same notice but are not required — a red one of either cannot block a merge,
so those two greens are the weakest on this roster. If `Compose smoke` is ever
promoted to a required context, its `no` above must flip to `yes` in the same PR:
clause 3 of §21 parses the required set from `.github/required-checks.json` and
reds on any disagreement in either direction.

**The fourth had its own vacuous green, by a different mechanism, and until
2026-08-08 it disclosed nothing.** `pr-task-gate.yml` grandfathers a PR whose
base commit predates the gate, and every evaluating step below carries
`if: enforced == '1'` — so a grandfathered run concludes SUCCESS having verified
no task at all, byte-identical on the check-run API to one where a live claim was
proven. It now emits its own annotation on that path,
`::notice title=PR task gate: green — nothing evaluated::` ("NO TASK WAS CHECKED
on this PR … Read it as 'no task check ran', never as 'this PR is task-backed'").
It is deliberately **not** worded `nothing ran` and stays a `—` row in the table
above: this green is not path-gating, and the roster that table holds is about
path-gated aggregators. Two things bound the exposure. The grandfather test used
to be a hard-coded literal path to the workflow's OWN file, so a rename would
have silently grandfathered the entire open-PR fleet — and the renaming PR
itself, whose base still had the old path; the cutoff now self-checks that path
at HEAD and **fails closed** when it is absent, rather than certifying PRs on a
predicate that no longer points at this gate
(`scripts/pr-task-gate.test.sh`: `step cutoff: renamed gate fails closed`). And
the grandfather branch is structurally unreachable for main-targeting PRs: a PR
to `main` takes main's current head as its base, and the gate has been on main
since 2026-07-07 (`9189854eb`). Re-derived 2026-08-08 over all 39 open PRs
(including the one based on a `loop-epic/` branch): 39 of 39 base commits carry
`.github/workflows/pr-task-gate.yml`, 0 missing, 0 unresolvable.

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

**Where a merger reads it.** The check-run page in the GitHub UI shows the
annotation inline. From a terminal, `gh pr checks <pr>` will not show it —
resolve the check-run id for the head SHA and read the annotations:

```bash
gh api "repos/FRIKKern/barkpark/commits/$(gh pr view <pr> --json headRefOid -q .headRefOid)/check-runs" \
  -q '.check_runs[] | select(.name|test("gate$")) | "\(.name)\t\(.conclusion)\tann=\(.output.annotations_count)\t\(.id)"'
gh api repos/FRIKKern/barkpark/check-runs/<id>/annotations \
  -q '.[] | "\(.annotation_level)\t\(.title)\t\(.message)"'
```

`ann=0` on a gate that reports green means it really ran; `ann=1` with that
title means it ran nothing. The emission is pinned by
`scripts/gate-announces-skips.test.sh`, which runs inside the `Elixir gate`
aggregator's own `needs:` graph and asserts the DELIVERED annotation title, so a
gate that quietly stopped disclosing reds a required context.

**This page's own change pays that cost.** A diff confined to `scripts/` and
`docs/` scores `CLOUD:false CONSOLE:false COMPILE:false TEST:false`, so the PR
carrying this very section merges under four greens that ran none of it. One
check does execute on it: `Required-check spec gate` is path-unfiltered and runs
`scripts/required-checks.test.sh` on every PR — but it is in no required
aggregator's `needs:` and carries no required name, so it cannot block a merge.
Four greens plus one unenforced green is the real coverage of a docs-and-scripts
PR; read it that way rather than as five gates agreeing.

### PRESENT BUT STALE — the green that ran, and then stopped being true

The three classes above are all about a check that is **absent** or **ran
nothing**. There is a fourth, and it is the only one where the check really did
execute the suite: **a CONFLICTING pull request keeps asserting the verdict it
earned on a head main has since passed, and it re-dispatches nothing to refresh
it.** GitHub dispatches on push. A conflicted PR cannot be merged and nobody
pushes to it, so its runs are frozen at the instant they were created and the
checks API answers SUCCESS forever.

Measured, not inferred. Every workflow run on #10944's head was created at the
push instant `2026-08-08T14:31:22Z` with `run_attempt=1`, and 49 commits have
landed on main since. #10129's twelve runs all carry `2026-08-07T05:57:05Z` with
100+ commits since, and the API still reports all four required contexts green.
Re-derived 2026-08-09 over the live population: **22 CONFLICTING of 40 open**,
of which **8 assert a full 4-of-4 green required set**, plus #6057 and #6086 at
**1-of-1** — three of the four required contexts never rendered on them at all,
a worse class the 4-of-4 framing hides entirely.

`.github/workflows/stale-verdict-watch.yml` is the level check that says so:
`*/30` cron, no `continue-on-error` anywhere, `if: github.event_name !=
'pull_request'` so its name can never enter the required set. It reds while any
conflicted PR asserts a green whose `completedAt` predates a commit on main, and
that red cannot clear itself — only a rebase, a push, or a close clears it.

Two counting traps it exists to avoid, both of which lie in the comforting
direction:

- **Count ALL-OF-PRESENT, never occurrences-of-SUCCESS.** #10722 and #10720
  render FIVE required-named rollup entries, because `PR references an active
  task` appears twice on one head: once FAILURE, once SUCCESS. Counting SUCCESS
  occurrences still reaches 4, so the failing required context is laundered out
  of the report. Occurrence-counting says TEN; all-of-present says EIGHT — a 25%
  over-report. A context is green only when it rendered and *every* entry
  carrying its name concluded SUCCESS.
- **`mergeable` is LAZILY COMPUTED, and UNKNOWN is a warning row.** On
  2026-08-09 the first `gh pr list` after a quiet period answered 39 UNKNOWN of
  40 open; the second, 12 seconds later, answered 22 CONFLICTING / 18 MERGEABLE.
  A naive `select(.mergeable == "CONFLICTING")` silently drops those rows and
  prints a smaller, calmer number. Re-poll, and print whatever is still UNKNOWN
  as a warning row rather than omitting it.

Being merely **behind** main is not in this class and is never reported: main is
`strict: false`, so a MERGEABLE PR behind main is exactly what the merge policy
permits. Only a conflicted one is stuck. All four behaviours are mutation-proved
over self-written fixtures in `scripts/stale-verdict-watch.test.sh`.

## Security gates (Sobelow + mix_audit)

`.github/workflows/security.yml` (filed by `task-a41fc4590b2c2eb1`) adds two
Elixir security gates, path-triggered on `api/**`:

9. **`sobelow` job** — Phoenix-aware static analysis (XSS.Raw / SendResp,
   SQL injection, unsafe `String.to_atom`, missing CSRF/CSP, hardcoded secrets,
   `binary_to_term`, directory traversal…). **Advisory** (`continue-on-error:
   true`) because the reviewed baseline is not drained — see the amended flip
   verdict below. The rationale this line used to give ("fingerprints are not
   stable across Elixir toolchains") is **REFUTED** and must not be reused:
   felix-pristine **D140** measured byte-identical 51-finding sets across
   1.18.1/OTP27 and 1.19.5/OTP28, a wider gap than the pinned pair, and
   `Finding.fingerprint/1` is `:erlang.phash2/1` over AST from
   `Code.string_to_quoted`, not compiler output. What *is* unstable is the
   **line number**, which is inside the hash: a pure renumber invalidates every
   waiver in the file. That is a reason to migrate waivers to AST-bound inline
   annotations, not a reason to stay advisory.
   `mix sobelow --skip --exit Low` reads the reviewed `api/.sobelow-skips`
   baseline and reds on a fresh unskipped finding. CI also runs a pinned
   Elixir 1.18.1/OTP27 reconcile in the only safe order: `--clear-skip`, then
   `--mark-skip-all`; it uploads the regenerated baseline and diff as an
   artifact for human review. CI never auto-commits it, and a developer-box
   regeneration must never be committed. After review, a separate change may
   update the tracked baseline. The fresh-finding guard plants a non-controller
   `String.to_atom` call and requires Sobelow to exit 1, preventing blanket
   suppression while the job remains advisory.

   **Flip verdict 2026-07-21 — STAY ADVISORY**, and **amended 2026-07-28 (D139)**
   because the precondition as first written was unsatisfiable. The original
   text gated the flip on the baseline's `file:line` entries reaching **0**, and
   quoted **137** entries. Both numbers are corrected below.

   **Live count — RE-DERIVE, never quote.** The count is drained by every
   annotation wave, so any number written here is stale on arrival. Run:

   ```
   $ grep -c '^[A-Za-z]' api/.sobelow-skips
   $ grep '^[A-Za-z]' api/.sobelow-skips | sed 's/:.*//' | sort | uniq -c | sort -rn
   ```

   Last derivation, 2026-07-29 on `origin/main` @ `606fefd15`: **89 rows** —
   54 `Traversal.FileModule`, 11 `DOS.StringToAtom`, 6 `SQL.Query`,
   6 `Config.CSRF`, 3 `XSS.Raw`, 2 `SQL.Stream`, and one each of
   `XSS.SendResp`, `XSS.ContentType`, `Traversal.SendFile`, `RCE.CodeModule`,
   `Config.HTTPS`, `Config.Headers`, `CI.System`. (It read 108 on 2026-07-28.)
   Wave 24 slice S3 then deleted **32 dead rows** — entries that were no longer
   the thing suppressing any finding, proven by running Sobelow with the
   baseline emptied — taking it to **57**. Which is why the paragraph above
   says derive, not quote.

   **Amended precondition — the floor is 9, not 0.** The flip is gated on the
   baseline holding **ONLY entries that provably cannot carry an inline
   `# sobelow_skip` annotation**, enumerated by type and count. The floor is a
   property of sobelow 0.14.1's architecture, not of the baseline's size: it is
   **9** today, out of a baseline of 41 rows
   (`grep -c '^[A-Za-z]' api/.sobelow-skips`), in two mechanical classes.
   Derive both numbers rather than quoting this paragraph — it said **10** and
   **8** until 2026-09-01, having predicted its own decay two paragraphs down
   and never been re-derived after the fix landed:

   | Class | Count | Entries | Why no annotation can ever reach it |
   |---|---|---|---|
   | `Sobelow.Config.*` | **7** | 6 `Config.CSRF` + 1 `Config.HTTPS` (`config/prod.exs:0`) | `sobelow.ex` calls `Config.fetch(project_root, routers, endpoints)` and only *then* does `allowed = allowed -- [Config, Vuln]`. Config findings are produced outside the `def_funs |> combine_skips()` pipeline, so `@sobelow_skip` is never consulted. `config/prod.exs:0` has no function to annotate at all. |
   | `.heex` `XSS.Raw` | **2** | `layouts/bulldocs.html.heex:95`, `layouts/quiz.html.heex:21` | `Parse.get_meta_template_funs/1` builds the template AST with `EEx.compile_string(File.read!(filepath))`. It bypasses `Parse.read_file/1`, the reader that rewrites `# sobelow_skip [...]` into `@sobelow_skip [...]` when `--skip` is set, so a template's source never sees the substitution. |

   The `Config.Headers` row in `router.ex` that made this class 8 is **gone** —
   wave 24 slice S2 fixed the underlying code, exactly as the paragraph below
   said it would. The `.heex` line numbers are part of each row's fingerprint,
   so read them off `api/.sobelow-skips`, never from memory: this table carried
   `bulldocs.html.heex:67` for the row that is really at `:95`.

   The third `XSS.Raw` entry (`controllers/error_html.ex:25`) is a normal `.ex`
   function and **is** annotatable — it is not part of the floor. Re-evaluate
   the flip when the baseline contains nothing but those 9; do not re-evaluate
   on "reaches 0", which cannot happen.

   **The floor holds only while the findings still exist.** It is a count of
   *unannotatable* findings, not of *unfixable* ones — fixing the underlying
   code removes a row from the floor. Wave 24 slice S2 did exactly that to the
   single `Config.Headers` finding in `router.ex`, taking the floor **10 → 9**;
   the table above lagged that landing by weeks. Re-derive the floor from
   `api/.sobelow-skips` after any such fix; it is never a constant.

   **Topology: the S4 objection is DEAD as of wave 10 — one blocker remains.**
   This entry used to conclude "no `security.yml` check can be required", on two
   successive arguments that are both now retired. The first rested on "`main`
   has no branch protection" — **false since 2026-07-28**: protection is live
   with `enforce_admins: true` and the tracked file carries `"enforced": true`.
   (Trap worth keeping: `gh api …/rulesets` → `[]` is a TRUE reading that
   produces the WRONG conclusion, because this repo's protection is not a
   ruleset.) The second rested on **S4**, and wave 10 paid it:

   - `security.yml` **no longer carries a workflow-level `paths:` key** on either
     trigger, so it renders a check run on every head. Path decisions moved to
     JOB level behind an always-running `changes` dispatcher — the elixir.yml /
     console-harness.yml shim, transplanted. A job skipped by a job-level `if:`
     still publishes a `skipped` check run, and GitHub counts `skipped` as
     satisfying a required context.
   - The registrable name is **`Security gate`**: unmatrixed, `if: always()`, and
     it ASSERTS over every upstream result rather than echoing them.
   - `sobelow` is deliberately **NOT in that aggregator's `needs`**. Measured: a
     `continue-on-error: true` job that exits 1 concludes FAILURE and renders a
     RED check run while `needs.<job>.result` reads `success` — byte-identical to
     a genuine pass, and undecomposable, because the information is destroyed
     before the aggregator's shell starts. There is no honest "tolerate sobelow"
     branch to write, so its own red check run is the only truthful signal it
     has. `scripts/security-gate-shape.test.sh` forces this shape (deriving the
     continue-on-error set FROM the workflow, so it self-corrects the day Sobelow
     becomes blocking), and the unfiltered `gate-shape` job runs it on every head.
   - **The remaining blocker is not topology, and it is no longer a live red
     either — it is that `mix-audit` reads a LIVE advisory database.** This
     bullet said "`mix-audit` is red on main … the dep bump that clears it is
     open as #8222" until 2026-09-01. Both halves are dead: 95ace3150 landed the
     req bump 2026-07-31 from outside that epic, `Security gate` and its
     `Dependency CVE audit` leaf both conclude **success** on main head today,
     and #8222 is **CLOSED with `mergedAt: null`** (`gh pr view 8222 --json
     state,mergedAt`) — so "once it merges" was a trigger that could never fire.
     `.github/required-checks.json` re-grounded this on 2026-07-31 and this page
     never followed. The standing ground is forward-looking: a CVE published
     tomorrow reds `Security gate` on every open PR with no change to this repo,
     a permanently correct red no PR can clear, which is what branch protection
     must never pin. Registering it needs its own wave — a written policy for
     who clears a fleet-wide advisory red, plus a fresh
     `scripts/registration-deadlock-sweep.sh` — not a silent promotion by the
     next regeneration.

   So flipping `continue-on-error: true` → `false` on `sobelow` now DOES change
   the picture: the shape ratchet immediately demands it be added to the
   aggregator's `needs`, and from then on a Sobelow regression reds `Security
   gate`. That is a consequence to intend, not a side effect to discover.

   **Sobelow's greenness therefore is not a branch-protection concern — it is
   still a real one.** A permanently-red regression gate cannot report a
   regression: while it is red for residue, a genuinely new insecure pattern is
   indistinguishable from an old one. That is the reason to drain it, and the
   only honest one.

   **Provenance: D75 is a dangling citation.** "D75" has no defining charter
   entry. It is cited at `bp-felix-pristine-charter.md:904` and `:2158` and at
   this file's flip verdict, but the felix charter's own **D75** (`:1163`,
   "Fresh-eyes last corner honestly clean") is a different subject entirely.
   This paragraph — introduced by `34b9b25d3` (#5474) — is D75's only extant
   text. Cite *this section*, not the number.

10. **`mix-audit` job** — dependency CVE scan (`mix deps.audit`, the `mix_audit`
    dep) over `mix.lock`. **Blocking** (no `continue-on-error`). The 8
    pre-existing CVEs were remediated by a version bump (task-726cab56d9a84551),
    NOT by accepting them: mint 1.7.1→1.9.1 (×4 advisories), postgrex
    0.22.0→0.22.3, phoenix 1.8.5→1.8.9, decimal 2.3.0→3.1.1 (the last needed
    ecto 3.13.5→3.13.6 + ex_json_schema 0.11.2→0.11.5 to relax decimal to
    `~> 3.0`). The 8th — **esaml GHSA-4g2h-vm7x-747c** (XXE, local-file
    disclosure/SSRF) — has **no upstream fix** (every release ≤ 4.6.0 is
    affected), so it is the single `--ignore-advisory-ids GHSA-4g2h-vm7x-747c`
    suppression in the audit step, justified because OTP 27+ neutralises the XXE
    (xmerl disables external entities by default) and both CI (OTP 27.0) and
    prod run OTP 27+. Every OTHER CVE must be fixed by a bump — never ignored.
    Protective proof: `mix deps.audit` exits 1 on the pre-bump lock and on any
    new CVE; drop the esaml id the moment upstream ships a patch. To suppress
    additional accepted advisories, mix_audit also takes `--ignore-file <path>`
    (advisory IDs, one per line).

Both deps are `only: [:dev, :test], runtime: false` in `api/mix.exs` — analysis
tooling that never ships in the release.

## Platform checks (not ours — GitHub App checks)

Two checks on every PR are posted by an external GitHub App, not by any
workflow in `.github/`. They are not in the roster above because we do not
run them, cannot run them locally, and cannot fix them in a PR.

11. **`Vercel – barkpark` / `Vercel – demo`** — deployment checks from the
    Vercel GitHub App (projects `guerrilla/barkpark` and `guerrilla/demo`).
    **Advisory** — and advisory here means *ignored*, not *tolerated*: there
    is no `continue-on-error` to set, because these are not our jobs. The
    classification rests on measurement, not on preference. Both report
    `fail` on **every** open and recently-merged PR repo-wide, including PRs
    that touch neither `cloud/` nor the console nor any front-end file (of
    the six most recently merged PRs, all six carry both failures and five
    change zero `cloud/` files), and PR #4732 merged carrying both. A check
    that is red identically on PRs with disjoint diffs is not reading the
    diff — the breakage is platform-side integration, not a defect in PR
    code. **The root cause is NOT diagnosed.** The check surfaces
    `Deployment has failed — npx vercel inspect dpl_<id> --logs`; nobody has
    run that and read the build log, so "platform-side" is an inference from
    the failure *pattern*, not a diagnosis. Until someone does, treat these
    two as carrying no information about the PR under review — and do not
    cite this entry as evidence that Vercel is *healthy*. Diagnosis is owned
    by **`hg-bl-vercel-legacy-statuses-red-repo-wide`** (it absorbed
    `gr-blk-vercel-checks-ungoverned`, which was cancelled as a duplicate —
    do not re-file either); when it lands, this entry gets
    replaced by a real classification (fix it, or turn the integration off —
    a permanently-red check trains reviewers to ignore red).

    *Provenance (this entry is being established, not restated):* before it,
    `grep -in vercel docs/ops/merge-gates.md` returned nothing. Merges past
    these checks had been justified as "the repo's standing advisory
    classification" while no such classification existed anywhere in the
    repo. This paragraph is that correction; the rule starts here.

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

`CLAUDE.md` golden rule #1 and "Past Mistakes" #1: cleaning only
`_build/prod/lib/barkpark` (or any subset) leaves stale `.beam` artifacts for
HEEx templates and dependent modules. The compiler is happy with the
existing artifacts and does not re-evaluate the module graph; the bug then
surfaces only on the production server after a fresh deploy. **Always
`rm -rf _build/prod` first.**

### Why dev-mode `mix compile` is insufficient

`MIX_ENV=dev` enables compile-time leniency that `:prod` does not — most
notably, certain macro-vs-function ambiguities in `runtime.exs` `when`
guards. `mix test` runs under `:test` and is similarly lenient. Only
`MIX_ENV=prod mix compile` exercises the prod compiler; only the prod
compiler rejects the PR #42 bug class.

## Lessons-learned: PR #42 macro-in-guard (2026-04-25)

PR #42 (Phase 1 — Oban + plugin_settings + Cloak encryption) introduced a
`when`-guard in `config/runtime.exs` that referenced a macro instead of a
plain function. The construct compiled cleanly under `:dev` and `:test`,
the test suite passed, and the Reviewer's static audit did not flag it.
The defect surfaced only on the production server during the rebuild
that followed merge: `MIX_ENV=prod mix compile` failed, the systemd
service failed to restart, and PR #43 (`966fcd98 fix(api): move
config_env() out of when-guard`) was filed the same day as a hotfix.

What the new gate catches:

- **Macro-vs-function misuse in `when`-guards** that the prod compiler
  rejects but `:dev`/`:test` accept.
- **Missing or stale `_build/prod` artifacts** that a partial clean would
  hide on a developer's machine.
- **Forgotten `--warnings-as-errors`** drift across config branches.

What it does **not** catch (still requires Reviewer + tests):

- Logic errors that compile cleanly in every environment.
- Schema/data migrations that compile but fail at runtime.
- Anything that requires the database, the BEAM runtime, or external
  services to be active.

**When to override** — the recorded `mix-prod-compile` bypass, and the task that is its durable record, moved to [branch-protection-and-overrides.md](branch-protection-and-overrides.md#when-to-override).

## Documentation review rules (doc-gates)

PRs touching `*.md` **or any source file** (`.ex`, `.exs`, `.go`, `.ts`,
`.tsx`) also run `.github/workflows/doc-gates.yml` — code changes trigger it
because `@canonical capability:` markers in source files must be re-checked
when a code rename rots a marker. The workflow also fires on changes to the
gate scripts themselves and to the workflow file.

### The doc-gates roster (it is not two scripts — it is twenty-two)

`doc-gates` is a single job (`Doc budgets + anchors`) whose name badly
undersells it: it runs **22 steps labelled `(fails this job)`** plus 6
`(tripwire)` self-tests that prove a scanner still reds on a planted defect. A
PR touching one `.ex` file runs all of them.

**THIS PARAGRAPH USED TO SAY `(blocking)`, AND THE SENTENCE AFTER IT TAUGHT THE
WORD.** Until 2026-08-19 the count line above ended in the words "labelled
`(blocking)`" and the next line read "**`(blocking)` there means blocking
inside the job, not on the merge**" — the canonical page on merge authority,
naming steps that have none with the vocabulary of steps that do, and then
teaching that vocabulary as current. #12631 had already renamed all 21 step
names in `.github/workflows/doc-gates.yml` to `(fails this job)`; only this page
still spelled the old label. The old words are quoted here rather than deleted,
so a reader who greps `(blocking)` lands on the correction instead of on
nothing.

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

(The count read 17 until 2026-08-07 — `Never-cancel-main concurrency ratchet`
and `Nil-polarity fail-closed gate` were missing from the table below. The 22 is
derived by running, not transcribed:

```bash
grep -cE '^[[:space:]]*- name: .*\(fails this job\)' .github/workflows/doc-gates.yml   # → 22
```

That replaces the command this page cited until 2026-08-19, `grep -c
'(blocking)' .github/workflows/doc-gates.yml`, which returns **1** on `main`
today — the page was naming a derivation that refuted its own number. §20 CLAUSE
11 of `scripts/required-checks.test.sh` reds if the prose count, the table rows
below, and the workflow drift apart, and it counts the UNION of both labels so a
revert to the old name is still counted rather than read as zero. RESIDUE, named
rather than left to be tripped over: the unanchored `grep -c '(fails this job)'`
returns **23**, because `.github/workflows/doc-gates.yml` quotes both labels
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

Run any of them locally with the same command CI uses — they are ordinary
scripts, not workflow-only steps. `docs-anchors-check.sh` runs clean in ~50s
on a contended checkout (an older caution to avoid running it locally is
retired; it was fixed in #4473).

### What step 1 covers under `docs/ops/` — and what this page's own header means

`scripts/check-doc-budgets.sh` gates a fixed 31-row byte table (pinned by
`CAPS_ROWS_EXPECTED`), the 7 `docs/cards/*.md`, and the pinned
`docs/setup/CODEX.md` onramp span — nothing else. Under `docs/ops/` that table
now names **three** files of the twenty-one: `docs/ops/PROD_OPS.md`, this page,
and `docs/ops/branch-protection-and-overrides.md`. Every other `docs/ops/*.md`
carries a G1 `budget:` figure that **no gate reads** — on those files the header
is a declaration, not a cap.

**This page was one of them until this section was written, and it is not any
more.** The header claimed `budget: 800tok` until 2026-08-23 while the file was
~59KB (~15k tok) — a 50x-false figure nothing could red, precisely because the
page sat outside the CAPS table (filed as
`cch-w49-bl-merge-gates-budget-header-enforces-nothing`). Restating it as
`16000tok` did not fix that: on 2026-09-01 the file measured *past* its own
declaration and, still outside the table, nothing reded. Both halves are closed
now, in that order. The registration / break-glass / recorded-override runbook
moved out to `docs/ops/branch-protection-and-overrides.md` under its own
`canonical-for`, which brought this page back under the 16000tok it declares;
then both files were given a BINDING row in the CAPS table — 64000B here (the
declared 16000tok at the repo's ~4B/tok convention) and 10400B there. The header
is now a ceiling the file is held to, and the headroom is deliberately thin: the
next section that does not fit reds `Doc budgets + anchors` and must be split or
retired, never capped upward. Measure with `wc -c`, never from this paragraph —
a byte figure typed here has no producer and goes stale in its own commit; this
sentence has already carried three of them ("~61KB", then a count that was
already wrong by ~3.6KB the moment the correcting commit landed, because writing
the correction grew the file). It carries none now. Dropping the header figure
was never an option — G1 in `scripts/docs-anchors-check.sh` requires
`budget: [0-9]+tok` on every active doc. Adding a page to the CAPS table remains
a deliberate two-line `scripts/` edit: the row, plus the `CAPS_ROWS_EXPECTED`
bump.

### Touching `api/lib/barkpark_web/layouts/root.html.heex`

The Studio shell is the single most gate-dense file in the repo — **four**
of the steps above read it, and no card names them all, which is how a
one-line CSS edit turns into three surprise reds:

- **10 · `scripts/studio-literal-check.sh`** — no new hand-stamped hex/hsl
  colour in Studio chrome; `var(--…)` only.
- **9 · `design/check.mjs` Part E** — the exemption **ratchet**. It counts
  colour literals per file against a frozen baseline in
  `design/exemptions.json` (`root.html.heex` is entry #1).
- **6 · `scripts/paper-editor-mirror-check.sh`** — the reader→editor style
  mirror. When the surface legitimately changes, re-stamp it with
  `bash scripts/paper-editor-mirror-check.sh --write` in the same diff.
- **11 · `scripts/studio-link-lint.sh`** — no hand-built, interpolated
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

`actionlint` is not installed by default in this repo's environment. To add
it locally: `brew install actionlint` (macOS) or
`go install github.com/rhysd/actionlint/cmd/actionlint@latest`. CI does not
currently run `actionlint`; add it as a separate workflow if drift becomes
common.

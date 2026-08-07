<!-- doc-tier: agent | canonical-for: merge-gates | budget: 800tok -->
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
   dispatcher (`needs: [changes]` at elixir.yml:510 — there is **no** edge to
   `mix-test`; the in-file comment at :515 records why it was removed, and a
   reader who plans around a test→compile ordering is planning around an edge
   that no longer exists). Cleans `api/_build/prod`, force-recompiles deps,
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

7. **`pr-task-gate` CI job** — `.github/workflows/pr-task-gate.yml`. Enforces
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
   **hotfix lane — DISARMED, and applying the label makes things WORSE** — a
   `hotfix!` label was designed to pass the gate AND auto-file an override task,
   because the record is the CONDITION of the bypass. `BARKPARK_TASK_TOKEN` is
   **not provisioned** (repo secrets are `BREAKGLASS_TOKEN CP_HOST
   DEPLOY_SSH_KEY GUERRILLA_HOST HETZNER_DNS_TOKEN NPM_TOKEN`), so
   `hotfix_record` **exits 1** — and it is the only step that still runs once
   the lane engages, since every evaluating step carries `if: … hotfix != '1'`.
   The label itself **does exist**, so applying it today converts a
   merge-blocking required context from "evaluate the PR" into a guaranteed
   red. It **reds**; it does not pass. `scripts/pr-task-gate.test.sh` pins that
   red (`ok hotfix record: no token REDS (exit 1)`), and even with the token the
   lane is circular during a guerrilla outage: it files its record on the same
   ledger that is down. **The armed override is break-glass** — see
   [Break-glass](#break-glass-the-armed-override), below;
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
   2026-07-28 — see *Making `pr-task-gate` binding (required-by-name)* below.

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
  (elixir.yml:667), so all five block. Driven rather than read off the topology:
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
  this reason (elixir.yml:655). `plugin-node` is a third case again: blocking
  nothing today, and relevant only when the PR touches `api/priv/plugins/**`.

§19 of `scripts/required-checks.test.sh` derives both lists from source — the
aggregators' `needs:` from `.github/workflows/`, the required contexts from
`.github/required-checks.json` — and reds if this page ever again describes a
transitive upstream of a required aggregator as unable to stop a merge.

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

   **Amended precondition — the floor is 10, not 0.** The flip is gated on the
   baseline holding **ONLY entries that provably cannot carry an inline
   `# sobelow_skip` annotation**, enumerated by type and count. The floor is a
   property of sobelow 0.14.1's architecture, not of the baseline's size: it is
   **10** today (so 79 of the 89 rows above are annotatable), in two mechanical
   classes. Derive the denominator with the command above rather than quoting
   this paragraph's:

   | Class | Count | Entries | Why no annotation can ever reach it |
   |---|---|---|---|
   | `Sobelow.Config.*` | **8** | 6 `Config.CSRF` + 1 `Config.Headers` (`router.ex`) + 1 `Config.HTTPS` (`config/prod.exs:0`) | `sobelow.ex` calls `Config.fetch(project_root, routers, endpoints)` and only *then* does `allowed = allowed -- [Config, Vuln]`. Config findings are produced outside the `def_funs |> combine_skips()` pipeline, so `@sobelow_skip` is never consulted. `config/prod.exs:0` has no function to annotate at all. |
   | `.heex` `XSS.Raw` | **2** | `layouts/bulldocs.html.heex:67`, `layouts/quiz.html.heex:21` | `Parse.get_meta_template_funs/1` builds the template AST with `EEx.compile_string(File.read!(filepath))`. It bypasses `Parse.read_file/1`, the reader that rewrites `# sobelow_skip [...]` into `@sobelow_skip [...]` when `--skip` is set, so a template's source never sees the substitution. |

   The third `XSS.Raw` entry (`controllers/error_html.ex:25`) is a normal `.ex`
   function and **is** annotatable — it is not part of the floor. Re-evaluate
   the flip when the baseline contains nothing but those 10; do not re-evaluate
   on "reaches 0", which cannot happen.

   **The floor is 10 only while the findings still exist.** It is a count of
   *unannotatable* findings, not of *unfixable* ones — fixing the underlying
   code removes a row from the floor. Wave 24 slice S2 does exactly that to the
   single `Config.Headers` finding in `router.ex`, taking the floor **10 → 9**.
   Re-derive the floor from the table above after any such fix; do not treat 10
   as a constant.

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
   - **The remaining blocker is not topology — it is that `mix-audit` is red on
     main.** Registering `Security gate` today would install a permanently
     CORRECT red. The dep bump that clears it is open as #8222. Once it merges
     and the name has rendered on qualifying heads (`scripts/registration-sample.sh`
     is the instrument), `Security gate` is registrable.

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
   entry. It is cited at `bp-felix-pristine-charter.md:904` and `:2165` and at
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

### Making `pr-task-gate` binding (required-by-name)

**This gate is now BINDING** — `PR references an active task` is one of the four
required contexts live on `main` (2026-07-28; see *Pre-merge gates*; it read
"two" until 2026-08-07, stale since `Cloud gate` and `Console gate` were
registered, and contradicting this page's own count 100 lines earlier). The
bootstrap below is kept as the account of how a context becomes required, not
as pending work. A check becomes binding only when added to the
required-status-checks list **by name**. Required-by-name is load-bearing (D3):
a workflow that silently never runs on a conflicting PR must read as
"not satisfied", not as an absent/passing check.

**Bootstrap is a `PUT` on `protection` itself — there is no `PATCH` route.**
This file previously prescribed
`gh api -X PATCH .../branches/main/protection/required_status_checks`; run
verbatim against this repo **before protection existed** (measured pre-2026-07-28)
it returned `{"message":"Branch not protected","status":"404"}`, because
`required_status_checks` is a **child** of protection and cannot create its
parent. `gh api -X PATCH .../branches/main/protection` is a plain
`404 Not Found` — that route does not exist at all. The only bootstrap verb is
`PUT /branches/main/protection`, carrying the **whole** protection object: all
four required-and-nullable keys must be sent explicitly (omit one and the PUT
422s), and because `PUT` **replaces** rather than merges, every later edit must
re-send the full body too — a partial re-PUT silently drops the keys it omits.

```bash
# One-time, needs repo admin. Creates branch protection on `main` with
# pr-task-gate in the required-checks list.
# app_id 15368 is GitHub Actions. The pin is load-bearing: GitHub validates
# NEITHER the context string nor the app id (a typo'd id reads back as
# `app_id: null`, i.e. "any app may satisfy this context"), and Vercel's app
# 8329 already publishes check runs on this repo — an unpinned context is
# therefore spoofable by anything holding `checks:write`.
# The context string must be COPIED from a check run observed on a real PR,
# never hand-typed: GitHub appends unconsumed matrix values to a job's display
# name, so a typed name matches no check, sits Pending forever, and deadlocks
# the branch. The example below is illustrative — the AUTHORITY is
# `.github/required-checks.json`, which is GENERATED from observed check runs
# by `scripts/required-checks-generate.sh` and applied by
# `scripts/required-checks-apply.sh --confirm`. Prefer those to hand-running
# this curl; they also verify the read-back and detect a deadlock by set
# difference, which no refusal message will tell you (charter D38).
# Sent as a JSON body, not `-f checks[][…]` flags: those build the array
# positionally and can split one check into two half-specified entries.
gh api -X PUT repos/:owner/:repo/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [{"context": "PR references an active task", "app_id": 15368}]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
# `strict: false` — do not require the branch to be up to date with main; that
# is a serialization tax, not a correctness gate.
# `enforce_admins: true` — the admin bypass is refused server-side, so it is no
# longer a merge protocol. THE MERGE VERB IS `scripts/bp-merge.sh`: argument-
# free, run from the PR branch's worktree, deadlock pre-flight first, then a
# plain `gh pr merge --squash --delete-branch` once the required set is green.
# `enforce_admins: false` would have been bypassed by 100% of the fleet's
# merges — a gate that cannot block.
# Verify by round-tripping the read back: the context must match byte for byte
# and app_id must be 15368, never null.
gh api repos/:owner/:repo/branches/main/protection/required_status_checks \
  --jq '.checks[] | select(.context == "PR references an active task")'
gh api repos/:owner/:repo/branches/main/protection --jq '.enforce_admins.enabled'
```

Two human-provisioned prerequisites before flipping it on:
- **`BARKPARK_TASK_TOKEN`** repo secret — a guerrilla write token, so the
  `hotfix!` lane can auto-file its override task. It is **not provisioned**, and
  without it the lane **reds**: `hotfix_record` exits 1, and because every
  evaluating step carries `if: … hotfix != '1'` that failing step is the only
  one left, so the label turns a required context into a guaranteed red. The
  token is not a record-keeping nicety — it is what the lane needs to exist at
  all. Provisioning it is a lead call (a guerrilla WRITE credential in CI), and
  even then the lane cannot rescue a guerrilla outage, because it writes its
  record to guerrilla.
- Optionally `BARKPARK_LEDGER_BASE` repo **variable** to point the gate at a
  different ledger instance (defaults to `https://guerrilla.barkpark.cloud`).

## Break-glass — the armed override

When a required context must be lowered, the mechanism that actually works is
**not** the `hotfix!` lane (see above: it reds). It is `scripts/breakglass.sh`,
run by a repo admin from a checkout:

```
scripts/breakglass.sh --open  --reason "…" --task <task-id> [--total]
# … merge …
scripts/breakglass.sh --close --reason "…" --task <task-id>
```

It refuses without both `--reason` and `--task`, writes an attributable record
to `docs/ops/break-glass-log.md` and reads it back off disk **before** it
touches protection (a crash leaves a record with no open glass — a false
positive, which is recoverable; the reverse ordering would leave a silent open).
`--open` without `--total` drops only `enforce_admins`, so required checks still
apply to non-admins. `.github/workflows/breakglass-watch.yml` polls live
protection every 30 minutes on `BREAKGLASS_TOKEN` and hard-fails on a credential
fault, so an unarmed watcher cannot read as "all clear". `scripts/breakglass.sh
--status` and `scripts/breakglass.test.sh` are the read-only entry points.

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

## When to override

The `mix-prod-compile` gate may be bypassed only by an explicit Boss
decision **recorded as a task in the task system** (dogfood it — the task
*is* the durable decision record; do not write to `.doey/plans/`, that
directory is retired). Capture the reason and the follow-up
to remove the override on the task itself:

A task is a `type:"task"` document created through the standard mutate
endpoint (`content.kind` must equal `"task"`); there is no bespoke
`POST /v1/tasks` create verb — the `bp task` verbs are read/lifecycle/progress
only (`ls`, `ready`, `prime`, `get`, `events`, `claim`, `release`, `next`,
`move`, `stage`, `pulse`, `stamp`, `close`). Run `bp task <verb> --help` for
the current contract of any one of them.

**Write to the ledger of record, not to a dev box.** The commands below target
`https://guerrilla.barkpark.cloud` — the instance every gate and board reads.
The older form of this runbook pointed at `http://localhost:4000` with
`barkpark-dev-token`, so an agent following it at 3am recorded the override
into a database that does not exist and left the merge unjustified. Use your
own guerrilla token (`bp login`, or the same write token CI uses as
`BARKPARK_TASK_TOKEN`); the `curl` here is the no-`bp` fallback — with the CLI
on hand, `bp doc create task … && bp doc publish task <task_id>` is the shorter
path, and boards read only the **published** ledger.

```bash
LEDGER=https://guerrilla.barkpark.cloud
TOKEN=<your guerrilla write token>   # never barkpark-dev-token

# 1. Record the override decision as a task. Pick a stable doc id (<task_id>).
curl -sS -X POST "$LEDGER/v1/data/mutate/production" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{
        "_id": "merge-gate-override-<pr>",
        "_type": "task",
        "title": "merge-gate override: mix-prod-compile bypassed for <PR #>",
        "content": {
          "kind": "task",
          "lifecycle_status": "open",
          "decision": "Boss approved bypassing the mix-prod-compile gate.",
          "reason": "<why>",
          "follow_up": "<remove the override: what + when>",
          "merge_sha": "<sha>",
          "labels": ["merge-gate-override", "ops"]
        }
      }}]}'
# → the create lands as drafts.merge-gate-override-<pr>; the doc id you chose
#   is <task_id> below. Publish it — a draft override is invisible to every
#   board and to the pr-task-gate:
#   bp doc publish task merge-gate-override-<pr> --yes
```

Optionally attach a written paper (a Bulldocs paper the task references) when
the rationale needs prose longer than a task body — author it through the
Bulldocs ingest API, then link it:

```bash
curl -sS -X POST "$LEDGER/v1/tasks/<task_id>/papers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"add": ["merge-gate-override-<pr>"]}'
```

Any merge that lands without the gate green must be reverted within 24h
unless that override task exists.

## Documentation review rules (doc-gates)

PRs touching `*.md` **or any source file** (`.ex`, `.exs`, `.go`, `.ts`,
`.tsx`) also run `.github/workflows/doc-gates.yml` — code changes trigger it
because `@canonical capability:` markers in source files must be re-checked
when a code rename rots a marker. The workflow also fires on changes to the
gate scripts themselves and to the workflow file.

### The doc-gates roster (it is not two scripts — it is nineteen)

`doc-gates` is a single job (`Doc budgets + anchors`) whose name badly
undersells it: it runs **19 steps labelled `(blocking)`** plus 6 `(tripwire)`
self-tests that prove a scanner still reds on a planted defect. A PR touching
one `.ex` file runs all of them. **`(blocking)` there means blocking inside the
job, not on the merge**: this workflow carries a workflow-level `on: … paths:`
filter, so on a PR touching none of those paths the check is simply ABSENT —
which is why `.github/required-checks.json` files `Doc budgets + anchors` under
**S4 PATHS-FILTERED** and why `doc-gates` is not a required context and **cannot
block a merge** by itself. A red step reds the job on the PRs where it runs;
that is the whole of its authority. (The count read 17 until 2026-08-07 —
`Never-cancel-main concurrency ratchet` and `Nil-polarity fail-closed gate` were
missing from the table below; the number is now derived by
`grep -c '(blocking)' .github/workflows/doc-gates.yml` and §20 of
`scripts/required-checks.test.sh` reds if the two drift apart.) In workflow
order:

| # | Step | Runs |
|---|------|------|
| 1 | Doc byte budgets | `scripts/check-doc-budgets.sh` (byte caps + the 7-card cap) |
| 2 | Doc anchors + headers | `scripts/docs-anchors-check.sh` (routing/INDEX targets, card Code anchors, G1 doc-tier headers, `canonical-for` uniqueness, `@canonical capability:` slug uniqueness + public-entry-point placement, ARCHIVED banners) |
| 3 | Connectors DDL drift | `scripts/connectors-ddl-drift-check.sh` (+ `--selftest`) |
| 4 | Connectors catalog drift | `scripts/connectors-catalog-drift-check.sh` (+ `--selftest`) |
| 5 | Never-cancel-main concurrency ratchet | `scripts/never-cancel-main-check.sh` (+ `--selftest`) |
| 6 | Paper-editor style mirror | `scripts/paper-editor-mirror-check.sh` |
| 7 | Status manifest drift | `scripts/status-manifest-check.sh` |
| 8 | Preview parity + no-oEmbed | `scripts/preview-parity-check.sh` |
| 9 | Design-token drift | `node design/validate.mjs` · `design/check.mjs` · `derive.test.mjs` · `theme-emit.test.mjs` |
| 10 | Studio literal-color | `scripts/studio-literal-check.sh` |
| 11 | Studio link/path | `scripts/studio-link-lint.sh` (+ `--selftest`) |
| 12 | Web literal-color | `scripts/web-literal-check.sh` |
| 13 | Go literal-color | `scripts/go-literal-check.sh` (+ `--selftest`) |
| 14 | Code-comment citation guard | `tooling/doc-truth/acceptance-code-comments.mjs` · `retired-terms.mjs` |
| 15 | Tenant fail-open read baseline | `scripts/tenant-scope-check.sh` (+ `--selftest`) |
| 16 | Nil-polarity fail-closed gate | `scripts/nil-polarity-check.sh` (+ `--selftest`) |
| 17 | Preview-env isolation | `scripts/preview-env-isolation-check.sh` (+ `--selftest`) |
| 18 | PortableDoc render parity | `scripts/pd-parity-completeness.sh` |
| 19 | Scaffy anchor drift | `bp scaffy validate` over `scaffy/commands/` (+ `--selftest`) |

Run any of them locally with the same command CI uses — they are ordinary
scripts, not workflow-only steps. `docs-anchors-check.sh` runs clean in ~50s
on a contended checkout (an older caution to avoid running it locally is
retired; it was fixed in #4473).

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

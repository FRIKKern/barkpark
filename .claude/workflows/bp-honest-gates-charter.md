# Honest Gates — epic charter

Epic task: `auth-totp-tests-are-time-boundary-flaky` (priority 0)
Founding wave Paper: `gates-tell-the-truth-wave-2026-07-20`

## Vision

A gate must be **able to be green**, **able to be red**, and must **red for exactly one reason — the thing it claims to measure**.

Every defect this epic exists to remove is the same shape: a predicate contaminated by a variable irrelevant to its claim — wall clock, scheduler seed, worker liveness, toolchain version, runner contention. A contaminated gate teaches readers to dismiss it, and a dismissed gate is how a one-character CSS defect survived five waves in production while three gates certified it green.

`continue-on-error: true` is not a third option. It is the terminal stage of the disease: the gate stops being able to fail, so its population grows instead of holding (measured: 87 → 91 → 92 → 94 unformatted Elixir files in 48h; 12 → 30 unformatted Go files under gofmt's advisory).

**Every slice lands in three parts, and a slice missing part three is not done.**
1. **THE CAUSE** — remove the contaminating variable. Never retry around it.
2. **THE POPULATION** — migrate every sibling instance, not the sample that failed.
3. **THE RATCHET** — a tripwire that fails CI if the hazardous shape reappears, plus an affordance that makes the safe path the easy one.

## Decisions

- **D1. The law above is the acceptance bar for every slice.** Cause + population + ratchet; a fix without a ratchet regrows, and the repo contains the proof twice over (the async seam guard, and api/test's `application_env_isolation_test.exs`, are two independent sample-scope fixes for the same hazard, neither aware of the other, both already decayed).
- **D2. A retry wrapper is never a fix.** It hides the race and preserves the lie. Every fix must be proven ABLE TO FAIL by forcing the failure condition and showing the OLD path breaks where the NEW one does not.
- **D3. Exit code can NEVER discriminate a dep error from a real verdict.** Measured live: exit 1 in all four of {dep-missing format, real format drift, dep-missing test, real test failure}. Only stdout text discriminates — `Unknown dependency` / `Unchecked dependencies`. Any harness that reads `$?` alone certifies a dep error as a verdict on the real work.
- **D4. TOTP is fixed in the TEST, never in the server.** `enable_totp/3` (accounts.ex:598) is a bare `NimbleTOTP.valid?(secret, code)` on purpose: `disable_totp/1` does not clear `last_totp_at`, so passing `totp_opts` there converts a disable→re-enable cycle into a permanent enrolment lockout (proven by mutation, and the suite stayed 61/0 green under it). Adding NimbleTOTP's own moduledoc-prescribed grace window to `valid_totp?/2` or `verify_totp/2` **doubles** the live acceptance window on two internet-facing endpoints — and the careful variant that preserves `since:` also passes silently. A prose fence is therefore insufficient: the fence must be enforced by protective tests, because api/test generates **zero** off-period TOTP codes and is structurally blind to window width.
- **D5. The async-global-seam ratchet DERIVES nothing — it bans the shape.** `mix xref` structurally cannot see test files (`elixirc_paths(:test)` excludes `*_test.exs`; zero `*_test.exs` beams in `_build`), and a text scan cannot see transitive reads (2 of 4 documented `:site_box_relay` readers contain zero textual mention of it). A hand-maintained key list also mis-matches both ways: it misses the fully-qualified form and false-positives on `OAuthStub` by prefix. The only predicate the source text can answer correctly is **"is there an `Application.put_env` inside an `async: true` test module?"** — measured cost of enforcing it: +1.6s on 2138 tests, zero failures.
- **D6. The seam ratchet runs over BOTH `cloud/test` and `api/test`.** The current guard's wildcard is relative to `cloud/`, so it structurally cannot see api/test's two swappers — that directory-scope gap is why the same hazard was rediscovered independently a second time.
- **D7. The pr-task-gate's invariant is "this change is task-backed", not "someone is actively typing right now".** A task closed on met acceptance criteria is the SUCCESS case. `done` passes **only when `claim.closed_by` is present** — proof it went through the claim/close engine rather than being hand-flipped. `landed.prs` would be the stronger link but is dead data (0 of 400 done tasks populated) and the Go CLI's close body is pinned by `assertExactKeys`, so gating on it today yields a gate that can never be green.
- **D8. The 404 branch stays definitive, always.** It correctly caught an invented task id (`cloud-gui-remake-epic`) the same day. A predicate change that makes the gate unable to red is the same disease pointing the other way.
- **D9. Fixtures land BEFORE any predicate change.** Deleting the gate's central `in_progress` check leaves `scripts/pr-task-gate.test.sh` **9/9 green** — the fixture set has zero (non-`in_progress` × worker-present) cases, so the lifecycle and worker checks are indistinguishable on it. A builder given both at once will write the predicate first and read a green harness as validation.
- **D10. The format gate is FIXED then PROMOTED — never deleted, never promoted to force the fix.** Deleting it destroys the only signal that makes promotion verifiable; requiring it today (10/10 failure on main, no paths filter, runs on every PR) would block 100% of merges repo-wide. `cloud.yml` runs the identical command BLOCKING and green on the identical pinned toolchain — the live proof that blocking is affordable once the population is clean, and the counter-example to version skew being the whole cause.
- **D11. A partially-clean population still gets a ratchet: the drift ceiling.** Where a full migration collides with live cycles, the count of drifted files becomes a committed baseline that CI forbids increasing. The population can then only shrink. A stated deferral with its reason is itself a truth-telling act; a silent declaw is not.
- **D12. `cancelled` is a non-pass.** The 2026-06-10 never-cancel-main guard was applied at sample scope: `elixir.yml`, `go-tests.yml`, `js-tests.yml`, `security.yml`, `pr-task-gate.yml` got it; `cloud.yml` and `doc-gates.yml` never did. 20 of 30 main pushes today concluded `cancelled`.
- **D13. Nothing in this repo is required-by-name.** `branches/main/protection` → 404, `rulesets` → `[]`, re-confirmed live and independently recorded by three prior tasks that never actioned it. Part three of the law is not finished until branch protection carries the check — and it cannot, because only 2 of 34 workflows run unconditionally on every PR; a required paths-filtered check sits Pending forever and deadlocks the repo. **Protection is wave-2 work with a path-filter skip-shim as its first step, not a settings toggle.**
- **D14. Adopt, never re-file.** `cloud-oauth-replay-test-is-seed-flaky` and `pr-task-gate-contradicts-close-on-criteria` were already filed, root-caused and fix-speced before this wave existed. Re-deriving filed work is the documentation dimension of the same sample-scope disease.
- **D15. Measure the thing, not a proxy.** A pure-`NimbleTOTP` proxy put the same-process straddle risk at 1-in-1,034,483 and would have licensed dismissal; measuring the real `Accounts.enable_totp/3` path put it at 1-in-31,561 per site — 1 in ~1,973 suite runs across 16 sites. The proxy is what makes "unobserved" read as "safe".
- **D16. `--repeat-until-failure` is the wrong loop for concurrency races.** It shares one VM (mix's own docs warn leftover global state confounds later repetitions — a near-exact description of the defect being proven) and empirically caught the confirmed OAuth race **0 times in 92 repeats**, while a fresh-VM external loop caught it on the first 30. It also cannot even complete on `auth_controller_test.exs`: repetition 3 dies at HTTP 429 on the whole-node `:barkpark_rate_limiter` ETS table. Deflake loops boot a fresh VM per iteration and pin `--max-cases` to CI's value (local default is 20 on a 10-core box vs CI's 8 — a 2.5× concurrency difference that changes the race window).

## Roadmap

### Wave 1 (2026-07-20) — the founding wave, all round 1

| # | Slice | Surface | Size | Task |
|---|---|---|---|---|
| S1 | TOTP window-stable helper — all 25 sites + two protective fence tests + raw-generator ratchet | `api/test/` | large | `hg-w1-totp-window-stable-population` |
| S2 | Async global-state: ban `put_env` in `async: true`, flip all 10 swappers, population scanner over both roots | `cloud/test/`, `api/test/` | large | `hg-w1-async-seam-ban-and-scanner` |
| S3 | pr-task-gate: fixtures first, then task-backed predicate, then `edited` re-fire | `scripts/`, `.github/workflows/pr-task-gate.yml` | medium | `hg-w1-pr-task-gate-task-backed` |
| S4 | Format: migrate the 50 conflict-free files, install the drift ceiling, rename the job honestly | `api/lib/`, `api/test/`, `.github/workflows/elixir.yml` | medium | `hg-w1-format-drift-ceiling` |
| S5 | `cancelled` is a non-pass: never-cancel-main population fix | `.github/workflows/cloud.yml`, `doc-gates.yml` | small | `hg-w1-never-cancel-main-population` |

### Wave 2 (candidate, ordered)

1. **Branch protection** — path-filter skip-shims for the 7 Tier-2 checks, then enable protection with Tier 1 (`Test`, `Prod compile gate`) on day one. Owner sign-off required. Without it every ratchet this epic builds is advisory.
2. **`Quiz.Bridge` sandbox cascade** — a boot-time PubSub-subscribed singleton doing implicit-shared-connection Ecto reads; masked 1310 failures in one run. Third distinct hazard shape, uncovered by either existing fix.
3. **The `:barkpark_rate_limiter` ETS seam** — whole-node, never sandboxed, shared by 14 async ConnCase files; two files defend themselves, the rest do not.
4. **Sobelow** — second red-under-green on main, in a security gate, filed twice and unfixed.
5. **Format completion + promotion** — the remaining ~42 files once the live cycles release them, then drop `continue-on-error` and rename the job.
6. **`bp task close --landed`** — populate `landed.prs` so the pr-task-gate can carry a real positive PR↔task link.
7. **`disable_totp/1` leaves `last_totp_at` stale** — the two MFA-wipe paths disagree; a disable→re-enrol cycle can reject a valid code.

## Wave log

### Wave 2026-07-20 (1) — the founding wave, all 5 slices built and reviewed, grade A

**All five landed green and integrate cleanly together** (five-way merge of the `-r` branches onto `origin/main`: no conflicts, cloud 2150/0, api gate suites 0 failures, all four ratchets green in one tree).

| Slice | Final branch | Verdict |
|---|---|---|
| S1 TOTP window-stable | `…totp-window-stable-helper-across-all-25--0-r` | 25/25 sites migrated, 0 raw generators left; FENCE B independently re-proven by the reviewer (the careful grace-window mutation reds `accounts_test.exs:432` and **nothing else**) |
| S2 async seam ban | `…ban-application-put-env-inside-async-tru-1-r` | 9 swappers isolated (population was 9, not the filed 10 — the brief's census was itself a naive text scan); `@shared_seam_keys` deleted; shape ban over both roots |
| S3 pr-task-gate | `…pr-task-gate-close-the-fixture-hole-firs-2-r` | fixtures-first order respected and the mutation hole proven closed; 9 → 20 fixtures |
| S4 format drift ceiling | `…migrate-the-50-conflict-free-api-format--3-r` | 92 → 42, shrink-only ceiling BLOCKING in its own job |
| S5 never-cancel-main | `…cancelled-is-a-non-pass-give-cloud-yml-a-4-r` | population 0 bare `true`; ratchet + selftest |

**What the reviewer fixed in place** — five defects, every one of them *the epic's own disease inside the gates built to cure it*:

1. **S5's ratchet went silent exactly when it could not run.** `set -e` aborted at `RESULT="$(scan …)"`, so a missing PyYAML exited 2 with a **completely empty log** — the D3 discriminating text was captured and discarded by the script that cites D3. Verified empty before, speaks now.
2. **S5's predicate under-detected.** It read only a literal `branches: [main]`, so `push:` with no filter, a glob (`ma*n`), and a non-main `branches-ignore` all fired on main yet passed as harmless NOTEs. Now fnmatch-resolved; 4 new fixtures.
3. **S1's ratchet could pass vacuously.** A wrong `@test_root` → `Path.wildcard` returns `[]` → empty offender list → green having measured nothing. S2's sibling guard defended this; S1's did not. Now asserts >100 files scanned and that the allowlisted helper is among them.
4. **S2's predicate missed wrapped `use` declarations and `put_all_env`.** `mix format` splits a long `use …, async: true` across two lines and the per-line match saw neither half. Both closed, 4 fixtures, mutation-proven.
5. **S3 read its parser output whitespace-split.** A `claim.worker` containing a space shifted every later field and the gate returned a confident verdict from the wrong values — including a **false PASS** (`EXPECTED_WORKER=fable` matching a task claimed by `fable tob`). Now tab-separated with separator-forging blocked at the emitter.

**The version-skew risk on S4 is materially smaller than filed, but still open.** New measurement: the whole `cloud/` tree is format-clean under local 1.19.5 *and* `cloud.yml` runs the identical check BLOCKING and green on the pinned 1.18.1 — a project's worth of Elixir on which the two formatters agree byte-for-byte. That does not cover the 50 migrated files' specific constructs, so **the lead must still read the PR's own `format-ceiling` job**. If it reds on untouched files, regenerate `.format-drift-ceiling` on the pin — never add `continue-on-error` to the ceiling job.

**S1 × S4 interaction, settled by running it:** S1's builder warned the two slices could disagree by up to 8 files. A real merge shows the ceiling **passes at 39/42** and names exactly S1's three roster files with the lower-the-baseline notice. Shrink-only does the right thing; no red. The lead should lower `count:` to 39 and drop those three lines after both merge.

**What stalled:** nothing. Two criteria are honestly unproven at builder scope and stamped `--miss` with reasons — S4's toolchain skew and S5's "the PR's own checks CONCLUDE" — both needing a real CI run. Every slice left `lifecycle: in_progress` with its merge-gated criterion open for the lead.

**Filed this wave:** 11 backlog children, plus `hg-bl-pr-task-gate-expected-worker-actor-drift` (filed by the reviewer on the S3 builder's own disclosure — `EXPECTED_WORKER` now compares against `closed_by` for done tasks, zero impact today because no author map exists, a false red the day one does).

**Next wave takes branch protection (wave-2 item 1) first.** D13 is the load-bearing gap: nothing here is required-by-name, so every ratchet this wave built is advisory. The path-filter skip-shim is its first step, and it now has four real ratchets worth protecting.

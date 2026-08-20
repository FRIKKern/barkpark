# Check-name spec generation — 2026-07-27 (Honest Gates wave 2 verifier: check-name-spec-generation)

Baseline: `origin/main` @ `071d228d7846db00ed6a531af6660c0863f11a8c`. All API reads against
`FRIKKern/barkpark`. Every row below is re-derivable by the command in its last column.

## 1. Harvest — 12 merged PRs across 12 distinct top-level path shapes

| PR | path shape (top-level dirs) | head sha |
|---|---|---|
| 6336 | `api` | `d4ebcf5df` |
| 6368 | `.claude` (docs-only) | `2d73a142a` |
| 6367 | `templates` | `2f418cdd9` |
| 6329 | `apps` (mobile/expo) | `859eaf2dc` |
| 6231 | `internal` (go) | `571867c39` |
| 6116 | `scripts` | `dcb7852f4` |
| 6276 | `cloud,internal` | `c303622de` |
| 6277 | `.github,cloud,scripts` | `68ed57dd6` |
| 6114 | `js,scaffy` | `03db08eae` |
| 6275 | `api,js,templates,web` | `993d41776` |
| 6071 | `cmd,internal` (go) | `a35370a58` |
| 6360 | `.claude,tooling` | `8bcdb8526` |

Re-derive the whole harvest:

```sh
for sha in d4ebcf5df748d26c34aa7c8d0da017e3a8b7497a 2d73a142ae41c78f8338bd165026e2926001e5e0 \
  2f418cdd95c7116a94b2a94002ce7194609e3359 859eaf2dc69c3dcd81458ad13e7b4ef1dd406446 \
  571867c39aeda7e30fd1d8a5d6eb941cb40d96c9 dcb7852f4eeb49a8337b42a58da263386d3d0209 \
  c303622de88fe594eb869193a95cb103c1d0e2fe 68ed57dd6881d95cec6dc6f30986e8c88b510214 \
  03db08eae12b0011c24252fe8ca78b9733586f7f 993d41776adc5c4da8e401a995cb28f261228e23 \
  a35370a581ff6dce753bef5c7d8a0c1b32c8c339 8bcdb8526bf08abb8aabd13b3ee3695017b24fa0; do
  gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs" --paginate \
    --jq '.check_runs[]|"\(.name)\t\(.conclusion)\tapp=\(.app.id)"'
done | cut -f1 | sort | uniq -c | sort -rn
```

## 2. Rendered-name presence census (32 distinct names, 163 check runs)

| rendered name | shapes /12 | app | able to fail? |
|---|---|---|---|
| `Vercel Preview Comments` | 12 | 8329 | external app |
| `Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)` | 12 | 15368 | YES — no `continue-on-error` |
| `Test (Elixir 1.18.1 / OTP 27.0)` | 12 | 15368 | YES |
| `Re-land advisory (already-landed overlap)` | 12 | 15368 | YES at check level (observed `failure` on 6114) |
| `Prod compile gate (Elixir 1.18.1 / OTP 27.0)` | 12 | 15368 | YES |
| `PR references an active task` | 12 | 15368 | YES |
| `Format (mix format --check-formatted, advisory) (27.0, 1.18.1)` | 12 | 15368 | **RED on 12/12 and on main** |
| `Filebase aesthetics gate (advisory)` | 12 | 15368 | YES at check level |
| `Doc budgets + anchors` | 10 | 15368 | YES — CONDITIONAL, deadlock hazard |
| `Boundary gate (advisory)` | 7 | 15368 | conditional |
| `go vet + test` | 5 | 15368 | conditional |
| `gofmt drift ceiling (blocking)` / `gofmt -l (advisory)` | 3 | 15368 | conditional |
| `Sobelow static analysis (…) (27.0, 1.18.1)` | 2 | 15368 | **RED where present**, conditional |
| `Dependency CVE audit (…) (27.0, 1.18.1)` | 2 | 15368 | conditional |
| 18 further names | 1–2 | 15368 | conditional |

## 3. Decisive findings

| # | Finding | Re-derivation command |
|---|---|---|
| F1 | `continue-on-error` does NOT make a check advisory to branch protection: the CHECK RUN still reports `conclusion=failure`. `Format (…advisory)` is `failure` on 12/12 PR shapes and on main. Requiring any "advisory" name = permanent block. | `gh api repos/FRIKKern/barkpark/commits/2d73a142ae41c78f8338bd165026e2926001e5e0/check-runs --jq '.check_runs[]\|"\(.name)\t\(.conclusion)"'` |
| F2 | Cancelled-run literal: a job cancelled BEFORE it starts publishes its uninterpolated `name:` verbatim as a check-run name. `Prod compile gate (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})` — a generator sampling this sha commits a name that can never report. Its sibling `Test (Elixir 1.18.1 / OTP 27.0)` DID interpolate on the same cancelled run (it had started). | `gh api repos/FRIKKern/barkpark/actions/runs/30281430656/jobs --jq '.jobs[].name'` |
| F3 | Legacy commit statuses `Vercel – barkpark` and `Vercel – demo` (EN DASH) are `failure` on every sha checked; combined `/status` state is `failure` repo-wide. `required_status_checks.contexts` covers statuses AND check runs — either name in the spec deadlocks main forever. | `gh api repos/FRIKKern/barkpark/commits/993d41776adc5c4da8e401a995cb28f261228e23/status --jq '.state,(.statuses[]\|"\(.context)\t\(.state)")'` |
| F4 | NO name collision: zero duplicated rendered names within any sha, and zero duplicated job `name:` values across all 40 workflow files. | `for f in .github/workflows/*.yml; do git show origin/main:$f \| grep -E '^\s{4}name: '; done \| sort \| uniq -d` |
| F5 | Census reconciled to **4**, not D13's 2, not 4-of-39, not grep's 9, not the survey's 3. Unfiltered + failure-capable + non-advisory-by-intent: `Test`, `Prod compile gate`, `Validation perf bench`, `PR references an active task`. The survey's 3 omitted **Validation perf bench**. | see §2 |
| F6 | A job-level `if:` skip DOES publish a check run with `conclusion=skipped` — observed live, twice. Refutes the digest's "zero check runs carried skipped". | `gh api repos/FRIKKern/barkpark/commits/717c7734ecac644646cc9722a61dd293dd41bfba/check-runs --jq '.check_runs[]\|"\(.name)\t\(.conclusion)"'` |
| F7 | The skip-shim dispatcher already exists in-repo: `deploy.yml` has a `changes` job emitting outputs consumed by `if: needs.changes.outputs.cp == 'true'`. Not a novel pattern here — only the `if: always()` aggregator is new. | `git show origin/main:.github/workflows/deploy.yml \| sed -n '40,95p'` |
| F8 | Main-green: `Test`, `Prod compile gate`, `Validation perf bench` all `success` on `fe1e4501a`; `Format` `failure`. `PR references an active task` has ZERO main history (`pull_request`-only, no `push:` trigger). | `gh api repos/FRIKKern/barkpark/commits/fe1e4501a138f685e12837657dcb6f9a2872d359/check-runs --jq '.check_runs[]\|"\(.name)\t\(.conclusion)"'` |

## 4. Candidate required-check spec (GENERATED, not typed)

```json
{
  "$generated_from": "check-run harvest over 12 merged PRs of distinct path shapes @ 2026-07-27",
  "$generator_rules": [
    "sample only check runs whose parent run conclusion != 'cancelled' (F2 literal-name trap)",
    "reject any candidate name containing '${{' (F2 belt-and-braces)",
    "reject names from app.id != 15368 (F3: vercel 8329 publishes here)",
    "reject legacy commit-status contexts entirely (F3)",
    "a name is REQUIRABLE only if present on 12/12 sampled shapes (F5) AND green on main (F8)",
    "advisory-by-intent (continue-on-error: true) names are EXCLUDED by policy, not by mechanism (F1)"
  ],
  "app_id": 15368,
  "strict": true,
  "enforce_admins": true,
  "required": [
    { "context": "Test (Elixir 1.18.1 / OTP 27.0)", "app_id": 15368, "shapes": "12/12", "main_green": true },
    { "context": "Prod compile gate (Elixir 1.18.1 / OTP 27.0)", "app_id": 15368, "shapes": "12/12", "main_green": true },
    { "context": "Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)", "app_id": 15368, "shapes": "12/12", "main_green": true },
    { "context": "PR references an active task", "app_id": 15368, "shapes": "12/12", "main_green": "N/A — pull_request-only, zero main history" }
  ],
  "excluded": [
    { "context": "Format (mix format --check-formatted, advisory) (27.0, 1.18.1)", "reason": "RED on 12/12 and on main (F1); requirable only after the S4 reland" },
    { "context": "Filebase aesthetics gate (advisory)", "reason": "advisory by intent (D10); check-level failure still possible (F1)" },
    { "context": "Re-land advisory (already-landed overlap)", "reason": "advisory by intent; observed failure on PR 6114 (F1)" },
    { "context": "Doc budgets + anchors", "reason": "10/12 — conditional, sits Pending forever on the 2 shapes that omit it" },
    { "context": "Vercel Preview Comments", "reason": "app 8329, not ours" },
    { "context": "Vercel – barkpark", "reason": "legacy status, FAILURE on every sha (F3)" },
    { "context": "Vercel – demo", "reason": "legacy status, FAILURE on every sha (F3)" }
  ],
  "post_shim_required": [
    { "context": "<aggregator name, TBD by slice 1>", "note": "if elixir.yml gains path filtering, Test/Prod compile gate/Validation perf bench STOP being 12/12 and MUST be replaced in this list by the if:always() aggregator — otherwise the required name goes Pending and deadlocks main (D13 hazard)." }
  ]
}
```

**Ordering constraint this spec imposes on the wave:** the three Elixir names above are requirable
TODAY only because elixir.yml is unfiltered. Slice 1 (the skip-shim) invalidates them by construction.
Protection must therefore be applied ONCE, after the shim, against a regenerated spec — never applied
first and edited later.

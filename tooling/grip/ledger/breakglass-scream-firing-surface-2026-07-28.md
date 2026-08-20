# Re-derivation: the break-glass scream — does a red guard reach a human? (honest-gates wave 4 verify)

Measured 2026-07-28 against live GitHub and the working checkout at `/Volumes/SATECHI/github/barkpark`.
Lane: `breakglass-scream`. The claim under test: *"while the glass is open the required-checks
verify guard reds in CI, so the repo itself screams until it is closed."*

VERDICT: the SCRIPT screams. The WORKFLOW does not — but not for the reason the assignment assumed.
`continue-on-error` does NOT hide the check run (it concludes `failure`); it hides the *workflow run*
(concludes `success`), which is what suppresses notification and what `gh run list` reports. The larger
hole is that the workflow fires on ~5% of PRs and has no level trigger at all.

| # | Claim | Command |
|---|---|---|
| 1 | All four verify modes exit 0 on a clean tree (guard is healthy, not vacuous — deadlock detector runs in every mode) | `for m in "" --ci --deadlock --selftest; do bash scripts/required-checks-verify.sh $m >/dev/null 2>&1; echo "[${m:-full}] EXIT=$?"; done` |
| 2 | With `enforced=true` and main unprotected the guard reds: `FAIL: branch main of FRIKKern/barkpark is NOT PROTECTED`, exit 1 | `jq '.enforced=true' .github/required-checks.json > /tmp/e.json && bash scripts/required-checks-verify.sh --spec /tmp/e.json --ci; echo EXIT=$?` |
| 3 | GLASS-OPEN simulation (`enforce_admins.enabled:false` read back against `enforced=true`) reds with a named clause: `DRIFT enforce_admins.enabled = false (spec: true)`, exit 1 — every other clause `ok` | `printf '%s' '{"required_status_checks":{"strict":false,"checks":[{"context":"Elixir gate","app_id":15368},{"context":"PR references an active task","app_id":15368}]},"enforce_admins":{"enabled":false},"required_linear_history":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},"block_creations":{"enabled":false},"required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}' > /tmp/rb.json && bash scripts/required-checks-verify.sh --spec /tmp/e.json --readback /tmp/rb.json --ci; echo EXIT=$?` |
| 4 | JOB-level `continue-on-error: true` yields CHECK RUN conclusion `failure` while the parent WORKFLOW RUN concludes `success` — the rollup lies, the check run does not | `cr=$(gh api repos/FRIKKern/barkpark/commits/27352d8c1/check-runs --paginate -q '.check_runs[]\|select(.name\|test("Format"))\|.id'); gh api repos/FRIKKern/barkpark/check-runs/$cr -q '[.conclusion,.details_url]\|@tsv'; gh api repos/FRIKKern/barkpark/actions/runs/30355751013 -q .conclusion` |
| 5 | `gh pr checks` renders an advisory job's result honestly (it is `gh run list` / run-rollup polling that hides it) | `gh pr checks 6414` |
| 6 | required-checks-drift.yml: `continue-on-error: true` at JOB level (:51), paths-filtered on BOTH triggers, no `schedule:`, no `workflow_dispatch:` | `grep -n 'continue-on-error\|schedule\|workflow_dispatch\|paths' .github/workflows/required-checks-drift.yml` |
| 7 | All 6 historical drift runs are genuinely green at JOB level — so "6/6 success" is NOT rollup masking; no failing report has ever existed to observe | `for id in $(gh run list --workflow=required-checks-drift.yml --limit 6 --json databaseId --jq '.[].databaseId'); do gh api repos/FRIKKern/barkpark/actions/runs/$id/jobs -q '.jobs[]\|[.conclusion,.name]\|@tsv'; done` |
| 8 | THE REAL HOLE: only 3 of the last 60 merged PRs touch `.github/**`, so the paths filter silences the guard on ~95% of merges | `y=0;n=0; for p in $(gh pr list --state merged --limit 60 --json number --jq '.[].number'); do n=$((n+1)); gh pr diff $p --name-only \| grep -q '^\.github/' && y=$((y+1)); done; echo "$y of $n"` |
| 9 | Only 9 of 34 workflows are path-unfiltered; the drift guard is not one of them | `for f in .github/workflows/*.yml; do grep -q '^\s*paths' "$f" \|\| echo "UNFILTERED: $(basename $f)"; done` |
| 10 | Repo owner is a **User**, not an org: no audit log exists at any endpoint; `/activity` exists but records only `branch_creation, branch_deletion, pr_merge, push` — never a protection change | `gh api repos/FRIKKern/barkpark -q '[.owner.login,.owner.type]\|@tsv'; for e in orgs/FRIKKern/audit-log users/FRIKKern/audit-log repos/FRIKKern/barkpark/audit-log; do gh api "$e" >/dev/null 2>&1 && echo OK \|\| echo FAIL; done; gh api "repos/FRIKKern/barkpark/activity?per_page=100" -q '[.[].activity_type]\|unique'` |
| 11 | PREMISE DRIFT: `allow_auto_merge` now reads **true** (the charter/digest premise "false" is stale as of this run); protection still 404 and rulesets still `[]` | `gh api repos/FRIKKern/barkpark --jq '.allow_auto_merge'; gh api repos/FRIKKern/barkpark/branches/main/protection; gh api repos/FRIKKern/barkpark/rulesets` |
| 12 | `branch_protection_rule` appears NOWHERE in this repo's workflows, and the public events feed carries no such type — the trigger is UNPROVEN here and cannot be proven without installing protection | `grep -rn 'branch_protection_rule' .github/ scripts/; gh api repos/FRIKKern/barkpark/events -q '[.[].type]\|unique'` |
| 13 | `required-checks-verify.sh` has NO narrow protection-only mode (`--ci` also reads `/check-runs` and `/pulls`), so a blip-resistant watch job needs a new mode built | `sed -n '30,40p' scripts/required-checks-verify.sh` |
| 14 | `required-checks-apply.sh --disable` removes ALL protection; the narrow enforce_admins break-glass exists only as two raw `gh api` lines in a comment header (:49-53) — no reason, no task id, no ledger write | `grep -n 'glass\|enforce_admins\|--confirm\|DELETE' scripts/required-checks-apply.sh` |
| 15 | "Required-check spec drift (advisory)" is NOT in the spec's exclusions list — it was never sampled, because the paths filter kept it off the generator's heads | `jq -r '.exclusions[].context' .github/required-checks.json` |

## Ruling recorded here

FIRING SURFACE: **(a) + (b) together, in a SEPARATE workflow file** — a `breakglass-watch` workflow on
`schedule: cron` + `workflow_dispatch` + `push: branches:[main]`, one job, **no `continue-on-error`**,
running a new narrow `required-checks-verify.sh --glass` (protection read only, 3× retry/backoff, red
only on an authoritative 200/404). It is deliberately absent from `pull_request`, so it renders no name
on any PR head and can therefore never be sampled into the required set — the API-blip fragility the
drift header warns about is confined to a job that gates nothing.

REJECTED: (c) a committed marker file — opening the glass would require a merge through the very
protection being bypassed; (d) `on: branch_protection_rule` — an EDGE trigger (fires once on the change,
silent thereafter) where a left-open glass needs a LEVEL trigger; unproven on a User-owned repo, and
usable only as a bonus second record after the flip.

CRITERION 8 must become: attributability is satisfied by the **ledger record the break-glass script
writes before the DELETE** (script refuses without `--reason` and `--task`), plus the `workflow_dispatch`
actor on the close-out watch run — never "checked in the org audit log", which cannot exist here.
Do NOT swap to rulesets for their self-attributing `/rulesets/{id}/history`: deleting the ruleset destroys
that history, and the swap abandons the mutation-proven classic-protection scripts on flip day.

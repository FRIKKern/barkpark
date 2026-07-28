# PDS wave 23 — fence & concurrency map (re-derivation recipe)

Verifier assignment `v10-fence-and-concurrency`, 2026-07-28. Every row below is a
single command that re-derives the fact from scratch. Authority level noted per row.

## (a) Is `origin/loop-epic/r3b-trusted-proxies-deploy` live, or squash-landed?

SQUASH-LANDED AND STALE. Not an ancestor (squash), but its content is on main and
main has since moved PAST it.

```sh
git merge-base --is-ancestor origin/loop-epic/r3b-trusted-proxies-deploy origin/main; echo $?   # 1 — not an ancestor
git show origin/main:deploy/instance-deploy.sh | grep -c TRUSTED_PROXIES                        # 9
git show origin/loop-epic/r3b-trusted-proxies-deploy:deploy/instance-deploy.sh | grep -c TRUSTED_PROXIES  # 9 — content landed
git diff --stat origin/main:deploy/instance-deploy.sh origin/loop-epic/r3b-trusted-proxies-deploy:deploy/instance-deploy.sh
# 1 insertion, 21 deletions — main→branch DELETES the D291 slot-sha ordering fix, i.e. the branch is BEHIND
git log origin/main --format='%h %ad %s' --date=short -3 -- deploy/instance-deploy.sh
# c80130fb3 2026-07-28  (#6421, PDS wave 22 itself)
# ea3849a5e 2026-07-26  (#6241, the r3b squash landing)
```

Ruling: `deploy/instance-deploy.sh` is NOT contended by r3b. Its only recent writer is
PDS's own wave 22 (#6421).

## (b) Is an Honest Gates wave running RIGHT NOW?

YES. Wave 3 round 1 merged 04:18–04:22 UTC today; rounds 2 and 3 are pending.

```sh
gh pr list --state merged --limit 40 --json number,title,mergedAt,headRefName \
  | jq -r '.[] | select(.mergedAt > "2026-07-28T04:00:00Z") | "\(.number) \(.mergedAt) \(.headRefName)"'
gh pr list --state open --json number,title,updatedAt,headRefName --limit 30   # #6509 hgw3-wave-log, #6414 release-scan (open, red)
sed -n '111,131p' .claude/workflows/bp-honest-gates-charter.md                 # wave 3 roadmap, 8 slices, 3 rounds
```

Surfaces it owns THIS WAVE: `.github/workflows/elixir.yml`, `scripts/release-scan*.sh`,
`.github/workflows/shell-harnesses.yml`, `.github/required-checks.json`,
`scripts/required-checks-*.sh`, `.format-drift-ceiling`, `scripts/format-drift-ceiling.sh`,
`docs/ops/merge-gates.md`, `.claude/workflows/bp-loop-ledger.md`,
`.claude/workflows/bp-epic-cycle.workflow.js`.

## (c) Does the Honest Gates charter already carry the guard design?

Partly — cite, do not rebuild. Load-bearing decisions for PDS's census/guard track:

| Decision | What it already settles |
|---|---|
| D26 | `shell-harnesses.yml` has ONE tenant (`doctor.test.sh`) behind a paths filter — a harness nobody runs is not a ratchet |
| D46 | Precedent for an UNFILTERED job with allow-set gate `NEVER` (`elixir.yml:172-177`), measured 27s |
| D36 | `needs_without_decide` — mutation-proven in four directions; the fourth vacuous pass found inside the epic's own guards |
| D19 | `if: always()` buys the right to decide, it does not decide — the aggregator must ASSERT on every upstream result |
| D18 | A required name may NEVER sit behind a workflow-level `on: paths:` filter |
| D39 | Protection REJECTS direct `git push` to main — epic-cycle Decide's charter+ledger commit dies the day S8 lands |

```sh
wc -l .claude/workflows/bp-honest-gates-charter.md    # 211 (assignment said 210)
gh api repos/:owner/:repo/branches/main/protection    # 404 Branch not protected — S8 has NOT landed yet
gh api repos/:owner/:repo/rulesets                    # []
```

## Guard surface: which lanes give PDS a free ride?

```sh
git show origin/main:.github/workflows/go-tests.yml | sed -n '15,50p'
# push AND pull_request, paths: "**/*.go" — a Go test under internal/cli/ rides free
git show origin/main:.github/workflows/shell-harnesses.yml | sed -n '10,22p'
# paths pinned to scripts/doctor.sh, scripts/doctor.test.sh, the workflow itself — NO free ride for a shell harness
```

## (d) Correct filter shape for live foreign claims

`bp task ls --status open` does NOT exist. There is NO status/lifecycle flag on `ls` or
`ready` — only `--limit`, `--offset`, `--all`.

```sh
bp task ls --status open              # {"error":{"code":"usage","message":"unknown flag --status for task ls"},"ok":false}
bp task ls --help                     # flags: --limit, --offset  (pagination: --all)
bp task prime -o json | jq '{counts, in_progress: [.in_progress[] | {doc_id, claim: .claim.worker}]}'
bp task ls --all -o json > /tmp/alltasks.json   # 3415 rows; filter client-side
```

TRAP (cost me a wrong answer once): filtering on `claim.expired_at > now` returns ZERO.
A live claim has `worker` non-null and NO `expired_at` — `expired_at` is stamped by the
REAP. The honest predicate is `claim.worker != null AND lifecycle_status == "in_progress"`,
or just read `bp task prime`.

Live foreign claims at 2026-07-28 ~06:20 UTC: exactly ONE —
`mob-rt-s7-stable-emitter` held by `epic-builder-emitter` (mobile live-document epic).
Zero pds-* rows carry claim activity in the last 24h.

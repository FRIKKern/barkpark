# `Security gate` is red for ONE reason: mix-audit. Not Sobelow.

Re-derivation recipes. Anchor head: `e3403110465e094d8ff06f4cc68c2c3ee342dfdd` (origin/main, 2026-07-31).

## 1. The live verdict lines from the newest main head

```sh
HEAD=$(git rev-parse origin/main)
JID=$(gh api "repos/FRIKKern/barkpark/commits/$HEAD/check-runs?per_page=100" \
        --jq '.check_runs[]|select(.name=="Security gate")|.id')
gh api repos/FRIKKern/barkpark/actions/jobs/$JID/logs | grep -E '^\S+Z   (ok|FAIL) '
```

Observed (job `91035245955`): FOUR verdicts, ONE fail.

```
  ok      changes (dispatcher): success
  ok      gate-shape: success
  ok      sobelow-inline-overlap: success
  FAIL    mix-audit: failure
```

## 2. Sobelow is not in `needs` and cannot be

```sh
git show origin/main:.github/workflows/security.yml | sed -n '452,476p'
```

`needs: [changes, gate-shape, sobelow-inline-overlap, mix-audit]` — hand-authored header
explains a `continue-on-error: true` job that exits 1 renders a RED check run while
`needs.<job>.result` reads `success`, so aggregating it would LAUNDER a red.

## 3. What mix-audit actually fails on — req 0.5.17, exactly #8222's fix

```sh
gh api repos/FRIKKern/barkpark/actions/jobs/91034964372/logs \
  | grep -nE 'Name:|Version:|URL: https://github.com/advisories|Vulnerabilities found'
```

`Name: req / Version: 0.5.17` twice — GHSA-655f-mp8p-96gv and GHSA-px9f-whj3-246m.
(The earlier `bandit/cowboy/cowlib/esaml/mint/req/swoosh VULNERABLE!` block is Hex's
`deps.get` chatter from a DIFFERENT step; `mix-audit` has exactly one step.)

On #8222's head `6a188e5a06f7186c60cc2ca979bc2e28a4a61226`, `Dependency CVE audit` = success
with `req 0.6.3`.

## 4. Why #6057 is off the path — the ratchet's own derivation

```sh
git show origin/main:scripts/security-gate-shape.test.sh | sed -n '118,124p;205,213p'
bash scripts/security-gate-shape.test.sh      # from a worktree cut at origin/main
```

`blocking = {jobs where continue-on-error is not True} - {aggregator}`; sobelow IS
continue-on-error, so it never enters `blocking` and `blocking_not_in_needs` never demands it.
Run on origin/main: `68 passed, 0 failed`, `coe_jobs='sobelow'`, `coe_in_needs=''`,
`blocking_not_in_needs=''`, `blocking_count=4`, `needs_count=4`.

The day `felix-w24-s7-continue-on-error-flip` drops `continue-on-error`, sobelow moves into
`blocking`, `blocking_not_in_needs` becomes `sobelow`, and the ratchet DEMANDS it be added to
`needs` — self-correcting by construction. Only then does #6057's baseline become load-bearing.

## 5. Stale rows this settles

- felix-w24-s7 criterion 5 asserts "security.yml is workflow-level paths-filtered … S4 excludes
  this check from ever being required". FALSE since #8255: the shape test asserts
  `workflow_paths False` and passes; `on:` is `pull_request` + `push: branches:[main]`.
- `felix-w24-bl-close-6057-superseded` already argues #6057 should be CLOSED, not merged.

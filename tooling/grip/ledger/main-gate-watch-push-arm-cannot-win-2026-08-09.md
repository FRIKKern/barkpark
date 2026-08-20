# main-gate-watch's push arm cannot win — re-derivation recipe (cch wave 60 verify)

Origin/main pinned at `026c5b1d78ac8afc8be45fd7177d8324874a6b45`.
All commands below run from the repo root; the local worktree may be behind
origin/main, so read the script out of `origin/main`, never off disk.

    S=/tmp/mgw && mkdir -p $S
    git show origin/main:scripts/main-gate-watch.sh      > $S/mgw.sh
    git show origin/main:scripts/main-gate-watch.test.sh > $S/mgw.test.sh
    git show origin/main:.github/workflows/main-gate-watch.yml > $S/mgw.yml

## 1. The same sha, the same script, two opposite verdicts

    # settled: green
    sh $S/mgw.sh --repo FRIKKern/barkpark --branch main; echo "rc=$?"
    #   ok       Elixir gate / Cloud gate / Console gate   → rc=0

    # 19 seconds after the push, on that IDENTICAL sha: MISSING x3 → exit 1
    gh run view 31297530145 --log | grep -E "main-gate-watch — tip|MISSING  "

The gap is not seconds. Check-run creation on that tip:

    gh api "repos/FRIKKern/barkpark/commits/026c5b1d78ac8afc8be45fd7177d8324874a6b45/check-runs" \
      --paginate -X GET -f per_page=100 \
      -q '.check_runs[]|[.name,.status,.conclusion,.started_at]|@tsv' \
      | grep -E "^(Cloud gate|Console gate|Elixir gate)"
    # Console gate 05:56:56 (+7m15s) · Cloud gate 05:59:33 (+9m52s) · Elixir gate 06:15:08 (+25m27s)
    # push was 05:49:41; the watch evaluated at 05:50:00.

WAITING (exit 2) is keyed on `.status` of an EXISTING row. During that 7–25
minute window the rows do not exist, so the script takes the MISSING branch,
which is exit 1 by construction. Push arm: 2 of 2 runs failed.

    gh run list --workflow=main-gate-watch.yml --limit 20 \
      --json conclusion,event,headSha,createdAt -q '.[]|[.event,.conclusion,.headSha[0:8],.createdAt]|@tsv'

## 2. rc=1 and rc=3 are the same check run

`.github/workflows/main-gate-watch.yml` lines 108-117: both `1)` and `3)` end
in `exit 1`, inside ONE job named `Main gate watch`. Replay the arm:

    printf '#!/bin/sh\nexit 1\n' > $S/r1.sh; printf '#!/bin/sh\nexit 3\n' > $S/r3.sh
    for f in $S/r1.sh $S/r3.sh; do rc=0; bash $f || rc=$?; \
      case "$rc" in 1|3) echo "rc=$rc -> exit 1";; esac; done

Prove rc=3 is reachable from the real script:

    echo '{"required_status_checks": null}' > $S/prot-empty.json
    bash $S/mgw.sh --sha 026c5b1d --protection-file $S/prot-empty.json \
      --check-runs-file /dev/null; echo "rc=$?"   # → 3

## 3. The harness has no fixture for "the check run does not exist yet"

    grep -n '^section ' $S/mgw.test.sh          # 13 sections, none for a fresh push
    grep -n 'check_runs": \[\]' $S/mgw.test.sh  # no match — no empty-check-runs fixture
    sed -n '113,122p' $S/mgw.test.sh            # the WAITING fixture: all three rows PRESENT

Section 3 (`a5260f609`) pins absent-required-context → exit 1 as CORRECT. There
is no case anywhere that distinguishes "absent because never judged" from
"absent because not created yet".

## 4. The already-filed row does NOT cover this

    bp task get cch-w59-bl-main-gate-watch-has-no-notification-egress -o json

Its two named residuals are (1) exit 3 vs exit 1 at the run level and (2) the
undocumented branch-protection tax. The push-arm race is named nowhere.

    bp task get cch-w59-s3-mains-tip-carries-a-verdict-or-screams -o json

Criterion 4 is stamped met and reads "…so a fresh push to main does not
false-red the watch." The two push runs above refute it.

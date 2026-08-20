# crown-reconcile rc=2: measured false-positive rate, and the alarm that is loud AND blind

Wave 32 verifier `v8-rc2-false-positive-count`. Every number below re-derives from the
commands in it. Repo `FRIKKern/barkpark`; all runs are 2026-08-09 (the workflow is one
day old). Fix commit under test: `6f8a70167410b16ab8bd7046cf76443d2e203c09` (#11365),
merged 2026-08-09T17:31:52Z.

## 1. rc=2 firings, ever: SIX. Since 6f8a7016: ZERO.

Classify every non-cancelled run by the verdict it actually emitted (not by its
conclusion, which the pre-fix rc=2 arm forced to success):

```sh
for id in $(gh run list --workflow=crown-reconcile.yml --limit 40 \
              --json databaseId,conclusion -q '.[] | select(.conclusion!="cancelled") | .databaseId'); do
  L=$(gh run view "$id" --log 2>/dev/null)
  printf '%s | rc2=%s | ok=%s | rc1=%s\n' "$id" \
    "$(printf '%s' "$L" | grep -oE '##\[warning\]the reconciler COULD NOT READ' | head -1)" \
    "$(printf '%s' "$L" | grep -oE 'RECONCILED: all [0-9]+' | head -1)" \
    "$(printf '%s' "$L" | grep -oE '##\[error\]THE CROWN DOES NOT MATCH' | head -1)"
done
```

rc=2 rows: 31316144030, 31316187416, 31316233833, 31316266634, 31317650969, 31321844876.
All six are **before** 6f8a7016. The five post-merge runs (31326639727, 31326759338,
31326781884, 31326831089, 31326850574) emit **none** of the three verdicts.

## 2. The reason line of each rc=2

```sh
for id in 31316144030 31316187416 31316233833 31316266634 31317650969 31321844876; do
  echo "=== $id"
  gh run view "$id" --log 2>/dev/null | grep -v '\[36;1m' \
    | grep -iE 'GRACE|s old|unreadable|COULD NOT FULLY READ' | cut -c1-260
done
```

| run | UTC | reason |
|---|---|---|
| 31316144030 | 13:35 | SERVING GRACE — `4c8314c9…` no cp row, process **-3s** old (negative age) |
| 31316187416 | 13:36 | same sha, 53s old |
| 31316233833 | 13:37 | same sha, 105s old |
| 31316266634 | 13:38 | same sha, 200s old |
| 31317650969 | 14:09 | `COULD NOT FULLY READ: 2 sha(s) unreadable` — **never named** (pre-#11365 script set UNREADABLE without a reason) |
| 31321844876 | 15:42 | SERVING GRACE — `1d577255…`, 10s old, first seen 15:42:58Z |

**5 of 6 = the benign in-flight serving grace. 0 of 6 = a real crown mismatch.**
Measured false-positive rate of the rc=2 arm: **83.3%** (5/6), or **100%** if the
unnamed read failure is counted non-actionable too. The workflow's own header concedes
`1d577255…` got its cp row 65s later.

## 3. Has file-ci-failure-issue.sh filed for a benign grace? NO — it filed for the HARNESS.

The scream is `if: failure() && github.event_name != 'pull_request'`
(`.github/workflows/crown-reconcile.yml:228`). All six rc=2 runs exited 0 pre-fix, so no
issue was ever filed for a grace. But since 6f8a7016 it has commented on **#11217 five
times in five minutes**, each body asserting *"The platform's delivery record does not
match what was deployed"* — while the comparison never ran:

```sh
for id in 31326639727 31326759338 31326781884 31326831089 31326850574; do
  gh run view "$id" --json jobs -q '.jobs[] | select(.name=="Crown reconcile") | .steps[]
    | select(.name|test("Prove the verdict|Does the crown match|File the failure"))
    | "   \(.name): \(.conclusion)"'
done
# Prove the verdict …: failure / Does the crown match …: skipped / File the failure …: success   (×5)
gh issue view 11217 --json comments -q '.comments[].createdAt'
```

## 4. Why the harness is red in CI and green everywhere else

```sh
cd "$(mktemp -d)" && git -C /path/to/barkpark archive origin/main scripts .github | tar -x
bash scripts/crown-reconcile.test.sh; echo "rc=$?"
# crown-reconcile.test.sh: 137 passed, 0 failed   rc=0
```

CI prints `136 passed, 1 failed`. The single failure is
`scripts/crown-reconcile.test.sh:490`:

```
FAIL the run gets PAST reader selection and only then fails on a tool this harness removed
     — the output never said: gh is required
     | could not list deploy.yml runs: gh: To use GitHub CLI in a GitHub Actions workflow,
       set the GH_TOKEN environment variable.
```

Line 484 sets `PATH="$NOTOOLS:/usr/bin:/bin:/usr/sbin:/sbin"` to remove `gh`. On a GitHub
runner `gh` **is** `/usr/bin/gh`, so it is never removed; the script reaches it and dies
on GH_TOKEN instead of on "gh is required". Locally `gh` is `/Users/pelle/bin/gh`, off
that PATH, so the assertion passes. **The harness is green on the author's machine and
red on the platform it gates**, and its redness skips the product step.

## 5. The next run pages by construction

```sh
ssh -i ~/.ssh/barkpark_indx -o BatchMode=yes root@barkpark.cloud \
  'hostname; ls -la /var/lib/crown-reconcile/'
# barkpark-cp
# -rw-r--r-- 1 root root 12 Aug  9 16:10 probe      <- a probe file, nothing else
# graced.txt: No such file or directory
```

`crown-reconcile.sh:405-406` sets `STATE_STATE=ABSENT` and calls `reason(…)`; `reason()`
is the only site that sets `UNREADABLE=1` (:357-363); `:972-985` exits 2 on
`UNREADABLE != 0`; the workflow's rc=2 arm (`:190`) now `exit 1`. So the first run that
gets past the harness rc=2s on the absent list and comments on #11217 — teaching the
operator on day one that the alarm is noise.

## 6. The push trigger makes the grace race systematic

`schedule: "5 */6 * * *"` **plus** `push: branches:[main]`. Five reconcile runs fired in
4m41s (17:31:52 → 17:36:33), each one reconciling against a fleet mid-deploy. Four of the
six historical rc=2s are the *same sha* graced four times in four minutes.

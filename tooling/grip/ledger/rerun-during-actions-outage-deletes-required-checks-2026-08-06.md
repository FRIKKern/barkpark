# Re-derivation: a Chrome-refusal re-run is a COIN FLIP, and requesting it deletes the required check first

Wave 7 verifier assignment `chrome-rerun-actually-clears`. Measured 2026-08-06 22:47Z -> 23:37Z UTC
(50 minutes, continuous polling). Subject: `ef77af2748ceda54fdd6e078f71a6e6044b55439` (origin/main
head), PR #9887 head `aa19dcca3`, PR #9889 head `479ebb86f`.

## Claim (three parts, all witnessed)

1. **A re-run CAN clear the DevToolsActivePort refusal — first witnessed flip.** main's console-harness
   run 31121349053 went attempt 1 `failure` -> attempt 2 `success`, all 7 jobs green including the
   required `Console gate`. Elapsed 22:47:13Z -> ~23:07Z (~21 min).
2. **A re-run CAN ALSO fail identically.** #9889's run 31120872857 attempt 2 completed `failure` at
   23:15:41Z: `Overflow guard (rendered)` hit the SAME `Chrome never wrote DevToolsActivePort` exit 2,
   and `Console gate` went red again. Two completed re-runs, one flip, one repeat. It is a retry
   against a flaky environment, not a repair.
3. **Requesting the re-run DELETES the check-runs first, and the gap is unbounded.** From the moment
   `gh run rerun --failed` is accepted until attempt 2 reports, every check-run of that workflow is
   REMOVED from the commit and the required context `Console gate` reads **absent**, not red.
   #9887's run 31120806862 sat at `attempt=1 queued`, zero jobs, `Console gate` absent, for the full
   **50 minutes** of observation and had still not started.

## Re-derive

    # 0. is Actions healthy? (note: the API's in_progress counter read 0 while main's rerun was
    #    demonstrably executing — trust job records, not this counter)
    curl -s https://www.githubstatus.com/api/v2/components.json \
      | python3 -c "import json,sys;[print(c['status'],c['name']) for c in json.load(sys.stdin)['components'] if c['name']=='Actions']"

    # 1. BEFORE snapshot
    gh api "repos/FRIKKern/barkpark/commits/<SHA>/check-runs?per_page=100" \
      --jq '.check_runs[]|"\(.conclusion//"-")\t\(.status)\t\(.name)"' | sort > /tmp/before.txt

    # 2. request
    gh run rerun --failed <RUN_ID>

    # 3. the deletion window
    gh api "repos/FRIKKern/barkpark/commits/<SHA>/check-runs?per_page=100" \
      --jq '.check_runs[]|"\(.conclusion//"-")\t\(.status)\t\(.name)"' | sort > /tmp/after.txt
    diff /tmp/before.txt /tmp/after.txt
    gh run view <RUN_ID> --json attempt,status --jq '"attempt="+(.attempt|tostring)+" "+.status'
    gh api "repos/FRIKKern/barkpark/actions/runs/<RUN_ID>/jobs?per_page=100" --jq '.jobs|length'

    # 4. required-context PRESENCE test — the only test that separates cleared from deleted
    for c in "Cloud gate" "Console gate" "Elixir gate" "PR references an active task"; do
      got=$(gh api "repos/FRIKKern/barkpark/commits/<SHA>/check-runs?per_page=100" \
            --jq ".check_runs[]|select(.name==\"$c\")|(.conclusion//.status)" | paste -sd, -)
      echo "$c => ${got:-<<ABSENT>>}"
    done

    # 5. outcome, once attempt 2 lands
    gh api "repos/FRIKKern/barkpark/actions/runs/<RUN_ID>/jobs?per_page=100" \
      --jq '.jobs[]|"\(.conclusion//.status)\t\(.name)"'
    gh run view <RUN_ID> --log-failed | grep -iE '!!|##\[error\]|DevTools|Service Unavailable'

## Measured values (2026-08-06)

- main head check-runs: **36 -> 29 -> 36**. The 7 that vanished and returned are exactly the
  console-harness set: `Console gate`, `Overflow guard (rendered)`, `Billing tier floor (rendered)`,
  `CSSOM parity (authored CSS vs browser)`, `Console client unit harness`,
  `Console path-escape ratchet`, `Dispatch (console paths)`. Combined status during the gap: `pending`.
- Which Chrome job refuses is NOT stable. On main attempt 1 the refusals were `Billing tier floor`
  and `CSSOM parity` while `Overflow guard` PASSED; on #9889 attempt 2 only `Overflow guard` refused.
  Naming "the Overflow guard failure" as the epic's red is therefore wrong — the failing job is drawn
  fresh each run from the three Chrome-driven jobs.
- Re-run latency under this outage: ~21 min (main), ~28 min (#9889), **>50 min and unstarted** (#9887).

## Two traps this recipe exists to defuse

1. **`gh pr checks <n>` renders the deletion as silence.** During the gap #9887's `gh pr checks`
   listed no failing rows at all — the failed names simply disappear from the table. Reading that
   alone yields "the reds cleared." Only the step-4 presence test tells cleared from absent.
2. **Not every red on these PRs is Chrome.** #9887's `Console path-escape ratchet` failure
   (job 92680886331, 6m29s) never launched a browser — its log ends
   `Failed to resolve action download info. Error: Service Unavailable`. That is the Actions outage,
   a third red class, and assuming one cause per PR hides it.

## What is NOT established

The flip RATE. n=2 completed re-runs (1 clear, 1 repeat) is not a probability. A merge plan that
budgets "one re-run per PR" is unsupported by this measurement; budget retries, or fix the Chrome
bring-up.

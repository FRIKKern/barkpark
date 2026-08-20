# dr-w35 — crown quiescence ruling: re-derivation recipes (2026-08-17)

Every load-bearing number in the wave-35 crown-quiescence ruling, with the one
command that re-derives it. Derived by the crown-quiescence-ruling-brief
verifier; committed by Decide.

## The red streak and the green that ended it

- 8 consecutive red runs (6 schedule + 2 push, plus 1 cancelled push), then the
  newest scheduled run is GREEN:

      gh run list --workflow crown-reconcile.yml --limit 12 \
        --json databaseId,event,conclusion,createdAt

  Reads: 32003613747 (2026-08-17T06:55Z, schedule, success) above failures
  32002029369, 32002021092 (push), 31984449932, 31964690964, 31947602615,
  31931938592, 31919266338, 31901232051 (schedule).

- The reds are EMPTY-POPULATION, manufactured by a quiet main, window arithmetic
  exact: last delivering push 2026-08-14T13:01Z; the 08-15T12:37 schedule run
  (23.6h later) was green, the 08-15T18:28 run (29.5h later) opened the streak.
  Verify the newest completed red's own verdict:

      gh run view 31984449932 --log | grep -E 'POPULATION|COULD NOT VERIFY'
  → "POPULATION: 0 successful deploy.yml run(s) on main in the window" →
  → "COULD NOT VERIFY: the population was EMPTY — 0 successful run(s) …" exit 2.

- The green's verdict (this is also the "close #11217" trigger per the
  workflow's own contract):

      gh run view 32003613747 --log | grep -E 'RECONCILED|POPULATION'
  → "RECONCILED: all 2 delivering run(s) … the serving sha 4b5d802a… is
     recorded … re-ask list … PRESENT-EMPTY".

## What the empty-population red has ALREADY verified before it exits 2

- The exit-1 verdict (BEHIND/WRONG/SERVING/GRACED) is evaluated BEFORE the
  `DELIVERING -eq 0` exit-2 arm — so a red-on-empty run has already passed the
  serving-sha check and the graced-list re-read:

      git show origin/main:scripts/crown-reconcile.sh | sed -n '1117,1129p'

- In the empty state the reverse (WRONG) direction is REFUSED for lack of an
  alibi source (this is the one thing quiescence-green must condition on):

      git show origin/main:scripts/crown-reconcile.sh | grep -n -B4 'no alibi source'

## D570 residual (3) is refuted on run ids

- "The schedule arm has NEVER run the reconcile (0/2)" — now 19 scheduled
  successes + 13 scheduled failures, and the failures fail AT the verdict, not
  at the harness:

      gh run list --workflow crown-reconcile.yml --limit 200 --json event,conclusion \
        --jq '[.[] | select(.event=="schedule")] | group_by(.conclusion) | map({c:.[0].conclusion,n:length})'
  → [{"c":"failure","n":13},{"c":"success","n":19}]

## #11217 lifecycle

- Contract is close-on-reconcile, close is HUMAN (no auto-close path exists):

      git show origin/main:scripts/file-ci-failure-issue.sh | grep -n -i 'close'
  → only "the next failure opens a fresh one" prose; no close call.

- State: OPEN, 41 comments, all github-actions, 2026-08-09 → 2026-08-17T06:32Z:

      gh issue view 11217 --json state,comments --jq '{state,n:(.comments|length)}'

- D590 makes the open thread structurally unrouted: the COMMENT path mentions
  and assigns nobody; only the new-issue path routes. Closing #11217 is what
  flips the alarm's next firing onto the routed path.

## Ledger row dr-w33-bl-crown-schedule-has-never-run-the-reconcile

- OPEN, p1, 4 criteria 0 met; criteria are "watch a scheduled run produce a
  verdict", "diagnose if not", "close #11217 on reconcile", "record the
  postgres-fallback reader state":

      bp task get dr-w33-bl-crown-schedule-has-never-run-the-reconcile -o json

  Disposition: CLOSE WITH EVIDENCE (run ids above satisfy 1/2/4; the #11217
  close satisfies 3). Cancel would misrecord: the premise was true when filed
  and the row's job — watch one — was done.

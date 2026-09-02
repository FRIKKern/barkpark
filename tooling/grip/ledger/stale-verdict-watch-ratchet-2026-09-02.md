# stale-verdict-watch: a red that could not warn, and the pin that gives it back its voice

Written 2026-09-02 for `cchi-w68-bl-stale-verdict-watch-is-a-red-that-cannot-warn`.
Everything below re-derives from `gh` against `FRIKKern/barkpark` and from the
two scripts in the fence. No server, no database.

## 1. The measurement — the run was red, and the red was constant

    gh run list --workflow stale-verdict-watch.yml --event schedule --limit 10

8 of the 10 most recent scheduled runs concluded `failure` (one `cancelled`,
one is this window's edge), continuously back through 2026-08-08. What the
failing runs actually said, pulled with `gh run view <id> --log-failed`:

| run | at | open | CONFLICTING | reported | named |
|---|---|---|---|---|---|
| 33551454561 | 2026-09-01T19:46Z | 7 | 1 | 1 | #11766 |
| 33534255072 | 2026-09-01T16:50Z | 3 | 1 | 1 | #11766 |
| 33507654004 | 2026-09-01T12:26Z | 17 | 1 | 1 | #11766 |
| 33478450882 | 2026-09-01T06:38Z | 5 | 1 | 1 | #11766 |
| 33457348627 | 2026-09-01T01:05Z | 14 | 1 | 1 | #11766 |
| 33441974881 | 2026-08-31T21:33Z | 19 | 2 | 2 | #11766 + 1 |
| 33413355600 | 2026-08-31T16:18Z | 23 | 5 | 4 | #14040, #14086 … |

Every one of those runs printed `TREND: … (moved +0 since the last READ run)`
and then `##[error] … it will keep failing every 30 minutes.` The trend line
(#13310) is real information; it is not a ratchet, because a `+0` trend on a
failing run is still a failing run and the conclusion never moves.

The consequence is the whole finding: on 2026-08-31T16:18Z the population held
**four** reported rows including two that were NOT #11766 — a genuinely new
fact — and the run's conclusion was identical to the run before it and the run
after it. A new stale verdict changed one line in a log nobody had reason to
open.

## 2. What the filing got wrong

The task row says "19 CONFLICTING PRs asserting stale green required verdicts"
and proposes driving that population to zero. Two things had changed by
2026-09-02:

* the population was never a stable 19. It churned: 4 → 2 → 1 over four days,
  as conflicted PRs got rebased, merged or closed by their authors. Most of
  the rows were transient and self-clearing.
* the durable row — #11766, whose four required contexts passed at
  2026-08-17T10:0*Z and which had been in every red for fifteen days — was
  **closed at 2026-09-01T21:26:58Z**, before this task was worked:

      gh pr view 11766 --json state,updatedAt
      → {"state":"CLOSED","updatedAt":"2026-09-01T21:26:58Z"}

So "drive the population to zero" was already true by the time the work
started, and driving it to zero was never the fix anyway: it is a state, not a
mechanism, and it lasts exactly until the next conflicted PR ages a day.

## 3. The live population, measured

The GraphQL rollup query times out from this host (three consecutive
`HTTP 504` on `gh pr list --json …statusCheckRollup` over 75 open PRs), so the
payload was assembled from a cheap list plus per-row rollups for the only rows
that can be reported (the CONFLICTING ones) and fed through `--fixture`:

    gh pr list --state open --limit 100 --json number,mergeable,… → 75 open
    → CONFLICTING: [14874, 14825]

    scripts/stale-verdict-watch.sh --fixture … --commits … (300 main commits)
    → 75 open · 2 CONFLICTING · 73 MERGEABLE · 0 UNKNOWN
    → all-of-present: 0 conflicted PR(s) assert a full 4-of-4 green
    → ok — no CONFLICTING pull request is asserting a green required verdict
    → rc=0

Both conflicted rows carry FRESH verdicts. The reported population is 0.

## 4. The mechanism, and the four arms it has to get right

`scripts/stale-verdict-watch.baseline` pins the standing set as
`<number> <head-oid-prefix> <YYYY-MM-DD> <reason>`, and the verdict became a
delta:

| arm | condition | rc |
|---|---|---|
| NOVEL | a reported row no line covers | 1 |
| KNOWN | a reported row a line covers exactly | 0 — printed, counted, trended |
| HEALED | a pinned line whose row stopped reporting | 8 |
| UNREAD | a pinned line whose row answered UNKNOWN | neither |

The HEALED arm is the difference between a ratchet and an allowlist. The file
may only shrink on its own: the moment a pin heals, the run fails and names the
exact line to delete. Growing it costs a commit and a written reason the parser
refuses to accept as blank (`rc 3`, not a warning).

Two decisions worth stating because their opposites are the obvious ones:

* **the pin is keyed on (number, head prefix), not the number.** A pinned PR
  that gets a push has a new head and a freshly-dispatched verdict — a
  different fact about a different tree. It reds as NOVEL rather than
  inheriting the old line's cover.
* **an UNKNOWN row is never HEALED.** GitHub computes mergeability lazily; a
  poll that answers UNKNOWN would otherwise look exactly like a pin that
  cleared, and a flaky read would delete the debt.

## 5. The baseline ships EMPTY, on purpose

Nothing is owed on 2026-09-02, so nothing is pinned. With zero entries every
stale verdict is NOVEL and the watch behaves exactly as it did before — this
change cannot launder anything today. It is the lever for the next #11766, and
the HEALED arm is what stops the lever from being left down afterwards.

## 6. Proof, on the live 75-row population

A stale verdict was planted into the real payload and the four arms walked:

    M1  plant + empty committed pin   → NOVEL 1 — #14999           rc=1
    M2  plant removed (real payload)  → NOVEL 0, "ok — no CONFLICTING…"  rc=0
    M3  same plant, PINNED            → KNOWN 1 — #14999, "WARN …"  rc=0
    M4  plant gone, line still pinned → HEALED 1 — #14999, "DELETE its line…"  rc=8

`scripts/stale-verdict-watch.test.sh` → **129 passed, 0 failed** (was 97).
`scripts/stale-verdict-watch.sh --selftest` → **24 passed, 0 failed**, and it
LOSES under each of `SVW_MUTATE=pin-any` (6 fails), `never-healed` (5 fails),
`head-blind` (2 fails). Each mutation refuses to run if its `sed` matched
nothing, so a reflow of the jq turns a silently-vacuous mutant into a loud one.
The switch is honoured only inside a selftest child: an ambient
`SVW_MUTATE=pin-any` on a normal run over a red fixture still exits 1, and the
same variable with `SVW_SELFTEST_CHILD=1` exits 0 — which is what proves the
guard probe is testing the guard and not a no-op.

## 7. Residuals

* `.github/workflows/stale-verdict-watch.yml` is owned by another lane. Two
  hunks belong there and neither is required for correctness: an `8)` arm so
  BASELINE DRIFT gets its own sentence instead of the `*)` catch-all (which
  still FAILS the run — safe, just generic), and
  `scripts/stale-verdict-watch.baseline` in the `pull_request:` paths filter,
  so a PR editing ONLY the baseline still runs the harness that governs it.
* the delta is written to `$GITHUB_STEP_SUMMARY`, which the runner sets for
  every step — no workflow change needed for that.
* a run that classifies nothing (rc 5) is still evaluated BEFORE the healed
  arm: a blind run must not issue a verdict about a population it could not
  read.

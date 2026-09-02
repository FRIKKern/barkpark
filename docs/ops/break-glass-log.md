<!-- doc-tier: agent | canonical-for: break-glass | budget: 1600tok -->
# Break-glass — the runbook and the log

This file is **both**: the procedure at the top, the append-only record at the
bottom. One file, because a record kept somewhere else is a record somebody
forgets to commit.

## The one command, down and back

```bash
# DOWN — refuses without both flags, before it touches the API
scripts/breakglass.sh --open  --reason "guerrilla is 500ing; the task gate cannot resolve" --task hg-bl-…
git add docs/ops/break-glass-log.md && git commit -m "chore: break-glass open" && git push

# BACK — the moment the merge lands
scripts/breakglass.sh --close --reason "merged #6414; gate restored" --task hg-bl-…
git add docs/ops/break-glass-log.md && git commit -m "chore: break-glass closed" && git push
```

`--dry-run` prints the ordered trace and touches nothing. `--status` prints the
open records and the live state, and exits 2 when a glass is open.

### What the narrow glass actually restores — read this before you push

That command lowers **only** `enforce_admins`. Required status checks still
apply to everyone; **admins bypass them**, and that includes `git push`. This
was measured (honest-gates D39): with `enforce_admins: false`, an admin push
straight to `main` **succeeds**, and git prints

```
remote: Bypassed rule violations for refs/heads/main:
```

So the `git push` in the runbook above lands *because the glass is open*, not in
spite of it. Do not reach for the total hammer just to push the record.

The bigger scope is `--total`, which removes the protection object entirely —
no required checks, no review rule, no force-push block for anyone:

```bash
scripts/breakglass.sh --open --total --reason "…" --task …
# equivalently, and it now delegates to exactly the line above:
scripts/required-checks-apply.sh --disable --confirm --reason "…" --task …
```

`--close` reads the record's `scope` back off disk and restores accordingly: a
`narrow` record is closed by POSTing `enforce_admins`, a `total` record by
PUTting the **full** committed spec (`.github/required-checks.json`). Closing a
total glass with the narrow POST would leave main with no required checks at all
while the log said "closed" — a new lie, so the script refuses to guess.

## Why the record is written before the delete

The ordering is the whole mechanism.

1. refuse without `--reason` **and** `--task` — before any API call at all
2. read the actor (`gh api user`: login **and** id)
3. read the **pre-state**, so an already-open glass is detected, not doubled
4. **write the record and read its acknowledgement back off disk**
5. only then `DELETE …/branches/main/protection/enforce_admins`

A crash between 4 and 5 leaves a record for a glass that never opened — a false
positive, which the watch screams about and a human clears in seconds. The
reverse order leaves a **silent open**. False positives are recoverable;
silence is not.

`--close` inverts it deliberately: it POSTs, verifies the read-back, and only
then writes the close record. A crash mid-close leaves the log still saying
OPEN while the glass is actually shut — over-reporting again, never under.

## Why here and not an audit log

There is none to read. The owner is a User, so no org audit log can exist:
`orgs/…/audit-log`, `users/…/audit-log` and `repos/…/audit-log` all 404,
`/activity` carries only branch/push/merge, there are zero webhooks, and the
protection object itself carries no actor and no timestamp. Rulesets *are*
self-attributing — and are refused, because deleting the ruleset destroys the
history that justified choosing it.

Not the `bp` ledger either: `bp task create` was measured returning HTTP 500
deterministically, after 17–20s, during exactly the outage a break-glass exists
for (honest-gates D49).

## The scream

`.github/workflows/breakglass-watch.yml` runs `scripts/breakglass-watch.sh`
every 30 minutes, on `workflow_dispatch`, and on every push to main. It reads
**one** endpoint — `branches/main/protection` — and the committed log above it.
No `continue-on-error` anywhere in that file, so the **workflow run** fails, not
just a check run: job-level `continue-on-error` renders a red check while
laundering the run to success, and the run conclusion is what notifications and
`gh run list` read.

## The claim, bounded

**Bounded claim.** Every way *this repository* can lower `main`'s admin gate —
`breakglass.sh` in either scope, `required-checks-apply.sh --disable`, or a raw
`gh api` by hand — is either **refused** before it touches the API or
**observed** afterwards, and no open glass survives more than one watch interval
without a **FAILING** workflow run.

It is bounded, not absolute, and the boundaries are the six residuals below.
The claim covers this repository's tooling and this repository's watch. It does
not cover a human with admin rights and a browser: GitHub's settings UI can turn
protection off with no record, and nothing repo-side can see that until the next
watch interval reads the live object.

## The residual, in numbers

Six gaps, stated rather than papered over (three named at build, two added by
the wave-4 review, one by wave 5 — an incomplete residual list is itself a
residual):

- **A 30-minute observation window.** A glass opened at 14:01 can go unseen
  until 14:31, and GitHub queues scheduled runs under load — treat it as
  30–45 minutes. Pushing the record closes this to seconds, because `push:main`
  is also a trigger; the window is only for a glass opened without the script.
- **An Actions outage silences it entirely.** No runner, no scream, for the
  duration. Mitigated but not removed by writing the record first: the record
  exists on disk and in the diff even when nothing can run. Not mitigated at
  all if the glass was opened by hand.
- **GitHub auto-disables a scheduled workflow after 60 days** of no repository
  activity. This repo merges dozens of PRs a day, so it will not trigger today —
  but a dormant fork inherits a watch that is off, and nothing announces it.
  `workflow_dispatch` is the manual re-arm.
- **The record is only an authority once it is COMMITTED AND PUSHED.** Between
  the local append and the push, the offline authority is blind and only the
  live-protection read can see the glass — i.e. the 30-minute window plus a
  token dependency. `breakglass.sh` prints "commit and push … NOW" and cannot
  enforce it. It deliberately does not commit for you: a tool that commits
  mid-incident is one surprise too many, and it could not push to a protected
  main anyway until the glass is down.
- **The live-protection authority depends on `BREAKGLASS_TOKEN` staying valid —
  and it says so out loud.** Reading branch protection needs repo-admin
  scope, which `GITHUB_TOKEN` never carries and no workflow `permissions:` key
  can grant (`administration` is not an accepted scope — writing it makes the
  whole workflow file invalid, so the scream would never run;
  `scripts/breakglass.test.sh` 6.8b pins that). That read 403s with *"Resource
  not accessible by integration"*. Until wave 5 it collapsed into **UNKNOWN**,
  the workflow mapped UNKNOWN to exit 0, and the run concluded **SUCCESS** — a
  watch with no live authority reporting green. A 401/403 is now a
  **configuration fault**: not retried, exit 3, and the workflow **fails the
  run**. This bullet read "until the secret is provisioned this workflow reds
  every 30 minutes" until 2026-09-01; `BREAKGLASS_TOKEN` has existed since
  **2026-07-28** (`gh secret list`) and `gh run list --workflow=breakglass-watch.yml`
  shows the watch concluding **success**. The residual is therefore not the
  secret's absence but its **expiry or revocation**: on the day it lapses this
  reds every 30 minutes, which is the honest state of a watch that cannot read
  what it watches — not a false alarm to silence. A 5xx, a timeout, or a **403 rate limit** keeps
  the old treatment — three attempts, then a `::warning`; a rate limit clears on
  its own and reding main every 30 minutes for one would be the fatigue this
  epic refuses.
- **A red run only screams if it REACHES a human.**
  There are **zero webhooks on this repository** and no notification
  integration, so a failing scheduled run is visible in the Actions tab and in
  `gh run list` and nowhere else. Nobody is
  paged at 03:00. Routing scheduled-gate failures somewhere a human actually
  looks is already filed as bp task `pt-w1-scheduled-gate-alerting` — prior art,
  not re-filed here. Until it lands, treat the Actions tab as the alerting
  channel and check it after any break-glass.

An unreadable protection API after three attempts — a 5xx or a timeout, *not* a
401/403 — is reported as **UNKNOWN** and warns rather than reds. That is
deliberate: a GitHub blip that reds main every 30 minutes trains the fleet to
dismiss the check, which is the disease. The committed-log authority runs
offline and covers the case that matters.

## Records

Appended by `scripts/breakglass.sh`. Do not hand-edit a block — append a new
one. A record whose `event: open` has no matching `- closes:` line is an OPEN
glass, and the watch reds until it does.

<!-- BEGIN RECORDS -->

### BG-20260731-RETRO
- event: open
- utc: 2026-07-31 (exact instant UNRECORDED — see provenance)
- actor: UNRECORDED — the pre-b4ba2bdb1a `--disable` printed the login to the operator's own terminal and wrote nothing to disk
- task: cch-w11-bl-breakglass-blind-to-stale-checkout
- repo: FRIKKern/barkpark
- branch: main
- scope: total
- command: scripts/required-checks-apply.sh --disable --confirm
- pre-state: UNRECORDED (the pre-b4ba2bdb1a --disable read no pre-state)
- provenance: RETROSPECTIVE, hand-written on 2026-09-01, NOT written by scripts/breakglass.sh. The tree it was run from was 131 commits behind origin/main and predates both breakglass.sh (557b5af40a, #6686) and the record-first delegation (b4ba2bdb1a, #6928), so no script in that checkout could have written this block at the time.
- reason: a wave-11 verifier ran this runbook's own documented rollback string from the PRIMARY checkout to clear a blocked merge; that copy's whole --disable block was one --confirm check, an echo and a bare `gh api -X DELETE`, with no --reason/--task refusal and no record write

### BG-20260731-RETRO-close
- event: close
- closes: BG-20260731-RETRO
- utc: 2026-07-31 (~74 seconds after the open)
- actor: UNRECORDED — same tree, same reason
- task: cch-w11-bl-breakglass-blind-to-stale-checkout
- repo: FRIKKern/barkpark
- branch: main
- scope: total
- command: (repaired by hand, then independently re-verified field-for-field)
- post-state: protection restored and verified field-for-field; `scripts/required-checks-verify.sh` agreed
- provenance: RETROSPECTIVE, hand-written on 2026-09-01. Recorded as CLOSED because it is: protection is up and was independently re-verified. Writing the open row without this one would leave the committed-log authority reading a standing OPEN glass and reding main every 30 minutes for an outage that ended in 2026-07-31.
- reason: the merge landed; protection was put back and re-verified. Nothing landed while the glass was down — proved non-vacuously, the since/until commit query returns ZERO rows on main for the window while a deliberately widened control over the surrounding period returns 13.

<!-- The blocks above are the ONLY hand-written records in this file, and they
     exist because the failure they describe is precisely a tree too old to run
     the recorder. `scripts/breakglass.sh` now refuses --open and --close from
     any checkout that does not carry b4ba2bdb1a's record-first apply.sh, naming
     the commit and the remedy (cut a worktree from origin/main). That guard is
     bounded and the bound is this incident: a checkout old enough to lack
     breakglass.sh itself still reaches the API with nothing repo-side to stop
     it, which is why this row had to be written by hand rather than replayed.
     scripts/breakglass.test.sh §11 pins the guard, both legs, in both
     directions. -->

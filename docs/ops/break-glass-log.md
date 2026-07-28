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

This lowers **only** `enforce_admins`: required checks still apply to everyone,
admins may bypass them. It is not `required-checks-apply.sh --disable`, which
removes protection entirely and also restores direct `git push` to main.

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

## The residual, in numbers

Three gaps, stated rather than papered over:

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

An unreadable protection API after three attempts is reported as **UNKNOWN** and
warns rather than reds. That is a deliberate fourth gap: a GitHub blip that reds
main every 30 minutes trains the fleet to dismiss the check, which is the
disease. The committed-log authority runs offline and covers the case that
matters.

## Records

Appended by `scripts/breakglass.sh`. Do not hand-edit a block — append a new
one. A record whose `event: open` has no matching `- closes:` line is an OPEN
glass, and the watch reds until it does.

<!-- BEGIN RECORDS -->

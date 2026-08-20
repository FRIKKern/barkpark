<!-- doc-tier: human | canonical-for: deploy-reliability-exit-reading-2026-08-17 | budget: 3000tok -->

# Deploy-Reliability Exit Reading — 2026-08-17 (second reading)

This is the second dated reading through the same committed runner as
scripts/deploy-reliability-exit-2026-08-10.md, taken to prove that file's whole point: the
reading is re-runnable by someone who was not there. It came back a refusal, and a refusal
quoted honestly IS an honest exit (deploy-reliability charter, D565): the runner withheld the
number instead of printing it under a warning, and this file quotes the withholding verbatim
rather than substituting a stale number for it.

## The run

Taken 2026-08-17T07:38:17Z, on the owner's machine, through the committed runner. The rc was
captured WITHOUT a pipe — `bash scripts/deploy-reliability-exit-run.sh >out 2>err; echo $?` —
because the piped form (`cmd | tail`) printed 0 for an exit-2 run twice this epic and is banned
from every capture here. stderr, then stdout, then the rc, verbatim:

    deploy-reliability-exit-run: calling the census over [2026-07-01T00:00:00Z .. 2026-08-09T00:00:00Z] — observed cost band 39-57s, client cap 90s applied absolutely with no retry.

    deploy-reliability-exit-run: INFRA FAULT (exit 2) — no reading was taken.
      the producer exited 3 after 0s (client cap is 90s, applied absolutely, no retry).
      the route named its own refusal: unauthorized|could not read the deploy census for your team for 2026-07-01T00:00:00Z → 2026-08-09T00:00:00Z (39 days) — the control plane did not recognise this session (401 unauthorized). Nothing was read: this is NOT a population with zero failures. Run `bp login` and try again.
      a timeout at ~90s is a SLOW PLANE, not a broken gauge — and the route emits no request id,
      so a failed reading has no correlator. Re-run before concluding anything.

    rc=2

**The session state, named:** the credential refused is the owner's cloud session in
`~/.config/barkpark/config.json`, last written 2026-07-17T07:34:18Z — a month before this run —
and the control plane answers 401 to it. This is INFRA FAULT (exit 2), not a fleet number: no
population was read, so nothing here says the fleet is healthy or unhealthy. The cure is the
owner-approval packet at the bottom of this file, and the runner is one command away once the
session is refreshed.

## The producer is vouched

Unlike 2026-08-10 — when the PATH `bp` was built from `0789ab90a`, off-history, and the runner
refused it — today's PATH `bp` is on-history:

    producer   commit=e7379a38b3  build=2026-08-17T06:29:45Z  (bp version)
    ancestry   git merge-base --is-ancestor e7379a38b3 origin/main   → rc=0
    distance   git rev-list --left-right --count e7379a38b3...origin/main   → 0 ahead / 3 behind

The divergence story in the deploy-reliability charter's D581 is superseded WITH A DATE: as of
2026-08-17 the owner's PATH binary is an ancestor of `origin/main`, three doc-only commits
behind, zero ahead. The refusal above is therefore purely a SESSION fault, not a producer fault
— the runner got past the vouching gate and was refused by the control plane, which is exactly
the order the taxonomy promises (producer vouched first, route answers second).

## Why a re-run of this file is honest

`as_of` is the window's `to`, PINNED, never `utc_now()` — the construction lives at
cloud/lib/barkpark_cloud/deploy_ledger.ex:1330. So a default-window re-run of the runner
re-prints `as_of 2026-08-09T00:00:00Z`, and because coverage is bounded on the LEFT only (a
live build minted after `to` still covers its site), the ONLY digit that can move between the
2026-08-10 reading and a post-login re-run of the same window is `never_covered` — and it can
only FALL from the committed 5 (production 3 + preview 2). The week's delta IS the story.
Population movement is a different question and requires an explicitly moved `--to`; asking it
by accident is the defect the pin exists to end.

## The whoami oracle defect

`bp whoami` prints `cloud.logged_in: true` on the same machine, at the same instant, that every
control-plane call 401s. The producer is internal/cli/builtins.go:183-192: `cloudLoggedIn` is
set from `cfg.HasCloudToken()` — token PRESENCE alone, no probe — while the very same function
probes the CONTENT server to decide `active`. That asymmetry is the defect, the test suite
enshrines it, and 29 non-test references gate on `HasCloudToken` (grep over `internal/`,
2026-08-17; 38 counting tests). State it plainly: **`logged_in` is
never a session-validity precondition.** The only oracle for session validity is a
control-plane call's own status. Filed: dr-w35-bl-whoami-presence-oracle.

## What moved in the week

Every number below carries its reader and its window. None of them is the exit reading — that
stays withheld until the session is refreshed — but all of them are witnesses that fired
without this epic pushing.

- **Fleet: 277 rows across 8 sites** — reader: the control plane's `deployments` table; window
  2026-08-10 to 2026-08-17. 133 live; 141 deferred, every one BOX_AT_CAPACITY at queue depth
  ≤ 5 against a bound of 12; 3 failed, all inside one 86-second self-healed blip on
  2026-08-12; 0 failures in the ~117 hours since; two genuinely idle days.
- **Digest: 9 of 9 mornings** — reader: `notification_deliveries` (the durable witness; 06:00Z
  tick, 4 rows per day); window 2026-08-09 to 2026-08-17. `oban_jobs` is pruned to ~7 days and
  is NOT a liveness witness — reading it manufactures phantom skipped days.
- **Crown schedule: 19 success / 13 failure lifetime** — reader: the crown-reconcile run
  record; window all-time, as of 2026-08-17. The old "scheduled trigger never succeeded"
  residual is refuted. The replacement residual (charter D597) is worse for a wind-down: since
  2026-08-15 every scheduled run reds on EMPTY POPULATION (no delivering deploy in the 24h
  window) and comments issue #11217 every six hours by construction — D597's named-deferral
  ruling is this wave's cure, built in its own slice.
- **Open-ledger partition: 191 / 189 / 184** — as_of 2026-08-17, origin/main head
  `4b5d802a1d`. 191 is the bp roster (reader: `bp task get task-fb4fb869490b4213`,
  `lifecycle_status` over 332 children); 189 is the exit predicate's own roster (reader: the
  runner's clause-(a) population; the gap is exactly two `drafts.*` rows); 184 is D587's
  deduction arithmetic (−7 zero-criteria, −0 at-100%-criteria). Three different questions,
  three different readers — quoting any of them bare is the defect the partition rule exists
  to end.

## The owner-approval packet

The whole human cost is ONE browser approval within 600 seconds. Everything else is
scriptable.

1. **Device-link login.** `bp login --device-start` mints one device-authorization code and
   emits `verification_uri_complete`, `user_code`, `interval`, `expires_in` (600 — the
   server-side TTL constant in cloud/lib/barkpark_cloud/device_auth.ex). The owner opens
   `verification_uri_complete` and approves — that is the one irreducible human act. Then
   `until bp login --device-poll <device_code>; do sleep 5; done` — an approved poll persists
   the session itself (config written 0600, byte-identical to the password path). No token is
   ever pasted.
2. **The one-command reading.**

       bash scripts/deploy-reliability-exit-run.sh >/tmp/exit.out 2>/tmp/exit.err; echo rc=$?

   Quote `/tmp/exit.out` verbatim beside the rc. If it is a READING (exit 0): window with both
   edges printed, a single `as_of`, the never-covered sites NAMED, and the split
   (production/preview, too_young/pending/unreadable) printed BESIDE `never_covered`, never
   inside it. If `failure_rate` is refused, quote the refusal — the window still straddles the
   2026-08-05T21:13:50Z taxonomy boundary and the refusal is the correct answer.
3. **The --days 22 raw-status retest.** After login, re-run
   `bp cloud deployments --days 22 -o json` and capture the RAW status. Auth is adjudicated
   BEFORE the window, so today's 401 masks the historical server-side 500 at that width —
   whether it still exists is currently unknowable and becomes testable only once the session
   is valid.

## Provenance

Refusal taken 2026-08-17T07:38:17Z through scripts/deploy-reliability-exit-run.sh by a vouched
binary (`e7379a38b3`, ancestor of `origin/main`, 0 ahead / 3 behind). Harness:
scripts/deploy-reliability-exit-run.test.sh (fixture-driven, offline, refusals proven by
mutation). Byte cap: this file's own line in scripts/check-doc-budgets.sh, because that gate is
a hardcoded heredoc and does not scan `scripts/` — a first cap SET, beside the 2026-08-10
file's untouched line, never a raise. The `canonical-for` slug above is new and unique;
scripts/docs-anchors-check.sh section 5 reaches `scripts/*.md` and fails on a duplicate.
Section 3c does not reach here, so this file names documents as bare paths in prose and
carries no relative links at all. The 2026-08-10 sibling is left byte-untouched: two dated
readings side by side ARE the record.

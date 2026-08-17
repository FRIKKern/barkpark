<!-- doc-tier: human | canonical-for: deploy-reliability-exit-reading | budget: 3400tok -->

# Deploy-Reliability Exit Reading — 2026-08-10

Wave 33 ruled WIND DOWN THE FLEET, NOT YET ON THE INSTRUMENT: the fleet's numbers are boring,
but the number reporting them read 0, 3 or 5 depending on where two dates went, and the law
governing that was pinned by nothing. This file is the pin. It records the exit reading, the
exact command that reproduces it, and — deliberately at the same weight — the list of things
in it that were NOT re-derived.

**This is not a grip ledger row.** That schema rejects a stored value by design ("a stored
value is an assertion with a timestamp on it"). So nothing here is presented as a standing
fact: every number is quoted beside the command that re-takes it, and a re-run that disagrees
is the file being wrong, not the reader.

## The command

    bash scripts/deploy-reliability-exit-run.sh --bp <a bp built from a commit on origin/main>

That is the whole interface. Defaults are `--from 2026-07-01T00:00:00Z --to 2026-08-09T00:00:00Z`,
`--repo` the script's own checkout, `--bp` the `bp` on PATH. It refuses rather than answers when
the binary it was handed cannot be vouched for, and a refusal WITHHOLDS the number instead of
printing it under a warning. Exit codes are `scripts/seal-run.sh`'s ratified taxonomy, reused:
0 reading, 1 negative, 2 infra fault, 3 shallow, 4 drift, 5 off-history producer, 6 ancestry or
rows unreadable, 7 unusable input. Mutation proofs: `bash scripts/deploy-reliability-exit-run.test.sh`.

**It refuses on the owner's machine today, and that is correct.** The `bp` on PATH is built from
`0789ab90a`, which is not an ancestor of `origin/main` (`git merge-base --is-ancestor` answers
rc=1), and it does not carry the census command at all — `bp cloud deployments` returns
`unknown cloud command` with rc=2. The remedy the runner prints is two steps in order:
`git pull --rebase` **then** `make cli-install`. `make cli-install` alone rebuilds the same
diverged checkout and hands back the same refusal — that is the loop `make doctor` currently prints.

## The reading

Taken 2026-08-09, through the committed runner, by a binary stamped at `45e2611552` (the tip of
`origin/main` at the time), verbatim:

    ==============================================================================
    DEPLOY-RELIABILITY EXIT READING
    ==============================================================================
      window        [2026-07-01T00:00:00Z .. 2026-08-09T00:00:00Z]   (pinned, both edges explicit; never --days)
      as_of         2026-08-09T00:00:00Z   (coverage is bounded on the LEFT only — a later live build still counts)
      population    volume=32191  live=10725  failed=18633  in_flight=0  cancelled=0  sites=12 of 13 registered

      live_rate     33.32%   (10725 live of 32191 attempted)
      never_covered 5   (rows still not followed by a later live build on their site, past the 86400s maturity fence)
      split         production=3  preview=2
      beside it     too_young=0  pending=5  unreadable=0   (counted BESIDE never_covered, never inside it)

      failure_rate  REFUSED — the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z
                    (method: schema_commit, source: #9615) — the same box refusal is written `failed` before it
                    and `deferred` after it, so this is a blend of two taxonomies, not a measurement
      completeness  audited=32198 accounted=32198 unaccounted=0 balanced=true

      producer      commit=45e2611552  ancestry=current vs origin/main (tip 45e261155)
      cost          41s   (observed band 39-57s; client cap 90s, absolute, no retry, no request id)

    deploy-reliability-exit-run: READING (exit 0) — quotable.

Two runs of that command, five minutes apart, produced byte-identical numbers (cost 39s then 41s).

**No fleet failure percentage appears above, and none will.** `failure_rate` is refused by the
route at every window width from 7 to 45 days, because all of them straddle the deferred-settle
boundary. A non-straddling window needs `from` after 2026-08-05T21:13:50Z — a width under about
four days — and under 9.8 days `never_covered` reads 0. The window that makes the rate a
measurement and the window that makes coverage non-zero are DISJOINT. `live_rate` is not refused:
both its numerator and its denominator are label-independent.

## Why the window is explicit, and never `--days`

A `--days N` window's right edge is `now`, and there is no `--as-of` flag, so two runs of the same
command minutes apart are two different windows. The number moves with the width: at the command's
own built-in default of 7 days `never_covered` reads 0; at 14 and 21 it reads 2; at 23, 24 and 26
it reads 3; at 27, 30 and 45 it reads 5 and saturates. Every one of those is a correct answer to a
different question and none of them is re-runnable, so the runner refuses `--days` outright.

## What this number does not measure

- It is a **stuck-site detector**. It cannot distinguish an abandoned site from a stuck one.
- The **preview arm is uncoverable by construction** — 2 of the 5 sit there.
- **Coverage is bounded on the left only**: a later live build minted after the window's `to`
  still counts, because refusing to see it would manufacture pending rows at the reader's own
  boundary. So this answers "is this site stuck NOW", never "was it stuck back then".
- `too_young` is decided against the maturity fence measured from the pinned `to`, so moving `to`
  by a day can move a row across the too_young / never-covered line with no row of the population
  changing.
- **At the command's own default width the same number reads 0.** Quoting it without its window
  is the defect this file exists to end.

## Cost, and how to read a timeout

`FleetDeployCensusTimeout` is a CLIENT constant of 90s (`internal/cloudclient/client.go`), applied
absolutely with no retry, and there is no server-side route budget at all. Measured serial cost:
44.2 / 45.4 / 49.1 / 56.7s at a 27-day width on a loaded host, and 39s / 41s for this runner's
39-day read on a quieter one — a 39-57s band under a 90s cap. A timeout is therefore a SLOW PLANE,
not a broken gauge. The route emits no request id, so a failed reading has no correlator: re-run
before concluding anything from one.

## Remaining work

**165**, and never bare — it is `319 children / 172 live (172 open, 0 in_progress) / -7
zero-criteria / -0 at-100%-criteria`. That partition was measured twice, 140 seconds apart, to
byte-identical JSON. `at-100%-criteria` is **0**: nothing is sitting finished-but-open on criteria.

The one live `drafts.*` row is **named, not excluded**: `drafts.dr-w26-hg-gyldendal-operator-packet-corrected`,
blocked by `dr-w27-bl-gyldendal-packet-409s-on-the-dedup-wall` (the packet 409s on the dedup wall).
It has no published twin — the claim that it does is refuted; the six published/draft pairs on the
roster are all cancelled on the draft side.

**PR-merged-but-open = 24, labelled L4 / inherited** — not re-derived this wave, tracked by
`dr-w32-fu-24-landed-rows-need-eyes`, which itself stands at 0 of 2 criteria.

Re-derived at this file's writing instant, the same partition reads **335 children / 188 live
(183 open, 5 in_progress) / -7 zero-criteria / -0 at-100% = 181**. The delta is this wave's own
rows: its slices were filed after the 165 reading and five are in flight as this is written, and a
second live `drafts.*` row has appeared since — `drafts.dr-w34-bl-5658-blocks-its-own-routing-fix`.
Both numbers are true of their own instant; neither is "the" backlog.

    bp task get task-fb4fb869490b4213 -o json   # then partition children by lifecycle_status + criteria_progress

## What this file does not do

It does not close the epic, and it quotes no ladder verdict. The ladder predicate cannot even print
an orphan count here: pointed at `--epic task-fb4fb869490b4213` it refuses NO-SUCCESSOR, and with
`--successor TERMINAL` it refuses TERMINAL-CLAIM-REFUTED. Its clause (b) is a live readout of the
CLOUD-CONSOLE epic's frozen CCH-D1..CCH-D6 ladder, and its bucket (c) is three hardcoded ids
parented to that epic with `in-epic-roster=false`. Both carry **zero deploy-reliability
information**: a verdict taken from them would certify another epic's defects under this epic's
name.

## UNVERIFIED

Everything below was NOT re-derived for this file. It is printed here, at the same weight as the
reading, with the command that would settle it. Promoting any of it to a plain statement is the
exact level-skip this epic exists to cure.

- **The three production sites behind `never_covered=3` are unnamed.** The census route publishes
  `never_covered_by_environment` as counts only, with no site ids attached — the runner says so in
  its own output rather than guessing. Naming them on the wire is `dr-w34-s1`'s row; until it
  merges the only source is operator-side SQL against the control plane, which was not run here.
  Re-run: `bash scripts/deploy-reliability-exit-run.sh` after `dr-w34-s1` lands, and compare.
- **The wave's four residual sentences.** A verifier's host ran out of disk mid-run, so four
  sentences in the wave record were never proved. Re-run: the verification commands in the wave
  Paper `deploy-reliability-wave-34-2026-08-10`, on a host with disk.
- **The two saved-publish revisions `947c0dbd0de8` and `91284be29666`.** They appear nowhere
  except the sentence being audited — a self-citation, not evidence. Checked here only that they
  are not git objects in this repository (`git cat-file -t` answers `Not a valid object name` for
  both), which rules out the reading that they are commits and rules in nothing.
  Re-run: `bp doc get <the audited doc> -o json` and look for the revs in its own history.
- **PR-merged-but-open = 24** — inherited from wave 32, not re-counted here.
  Re-run: `bp task get task-fb4fb869490b4213 -o json` cross-referenced against merged PRs.

## Provenance

Reading taken 2026-08-09 through `scripts/deploy-reliability-exit-run.sh` by a binary stamped
`45e2611552`, ancestry `current` against `origin/main`. Harness:
`scripts/deploy-reliability-exit-run.test.sh` (fixture-driven, offline, every refusal proven by
mutation). Byte cap: an explicit line in `scripts/check-doc-budgets.sh`, because that gate is a
hardcoded heredoc plus `docs/cards/*.md` and does not scan `scripts/` — without the line the
`budget:` header above would be decorative. The `canonical-for` slug is the one invariant this
location does buy: `scripts/docs-anchors-check.sh` section 5 reaches `scripts/*.md` and fails on a
duplicate slug. Section 3c does not reach here, so this file names documents in prose and carries
no relative links at all.

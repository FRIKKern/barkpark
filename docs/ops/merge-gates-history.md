<!-- doc-tier: cold | canonical-for: merge-gates-history | budget: 6000tok -->
# Merge Gates — historical record

> HISTORICAL RECORD (2026-09-02) — every measurement, count, figure and command
> below was recorded on the date its own paragraph names and is NOT current state.
> Re-run the commands to re-derive; never quote the recorded output as today's
> answer. The live contract is [merge-gates.md](merge-gates.md), which keeps
> `canonical-for: merge-gates`; this file owns only the narrative that page shed.

`docs/ops/merge-gates.md` is capped at 64000 B by `scripts/check-doc-budgets.sh`,
and the cap is never raised — on overflow the doctrine is "split to the owning
contract/runbook or retire content". What follows is the narrative history, the
dated measurement logs and the incident stories that had accumulated on that
page. Every sentence a gate reads stayed behind on it. The text below is
verbatim; only the headings, and this preamble, are new.

## The generator merge that lost 25 exclusion rows

What stood here — "re-add it by hand after
any `required-checks-generate.sh` run" — was a guard that could not lose,
because a human remembering is not a mechanism: the generator's MERGE covered
`_readme` and the check LIST (a base-first union) but emitted `exclusions:`
from the array it had just derived, never reading the committed one, and a
paths-filtered name cannot enter that array because stage 2 iterates only
names that rendered on the sampled main heads. Measured over the frozen
fixture pair, that took **25 exclusion rows in and wrote 18 out, exit 0, with
nothing on stderr**. `scripts/required-checks-generate.sh` now emits
`.exclusions` as the same base-first union (the *derived* reason winning where
both sides carry a row), **and** refuses by name when a run cannot re-derive a
committed exclusion — acknowledged one name at a time with
`--expect-unrendered '<name>'`, the same flag the check list already uses — so
the carry can never be silent. A committed exclusion the run instead SELECTS
as required is a contradiction rather than an absence — carrying it would emit
one context on both lists — so it refuses separately and takes
`--expect-promoted '<name>'`, which DROPS the committed row instead of
carrying it. Both arms are mutation-proven in §14b of
`scripts/required-checks.test.sh`.

## The 2026-08 spec-gate deadlock

Main was red on
exactly this from **2026-08-24T21:59Z to 2026-08-31T20:14Z** — 6d22h elapsed,
eight calendar dates — and every open PR carried the red with it. During that
window this gate was decorative, so a "merged on 4/4 green" in it records a
convention rather than a gate.

## The 2026-08-24 merge that left main red

Reported 2026-08-24 by the lead running the merge automation: a PR was merged on
the strength of four green required contexts **while a fifth, non-required check
was failing**, and main stayed red for every lane until a follow-up landed. The
merge was correct by the rule the automation applies. The rule is the gap.

## The pr-task-gate grandfather branch, and the 39-of-39 re-derivation

Two things bound the exposure. The grandfather test used
to be a hard-coded literal path to the workflow's OWN file, so a rename would
have silently grandfathered the entire open-PR fleet — and the renaming PR
itself, whose base still had the old path; the cutoff now self-checks that path
at HEAD and **fails closed** when it is absent, rather than certifying PRs on a
predicate that no longer points at this gate
(`scripts/pr-task-gate.test.sh`: `step cutoff: renamed gate fails closed`). And
the grandfather branch is structurally unreachable for main-targeting PRs: a PR
to `main` takes main's current head as its base, and the gate has been on main
since 2026-07-07 (`9189854eb`). Re-derived 2026-08-08 over all 39 open PRs
(including the one based on a `loop-epic/` branch): 39 of 39 base commits carry
`.github/workflows/pr-task-gate.yml`, 0 missing, 0 unresolvable.

## What a docs-and-scripts PR actually clears

**This page's own change pays that cost.** A diff confined to `scripts/` and
`docs/` scores `CLOUD:false CONSOLE:false COMPILE:false TEST:false`, so the PR
carrying this very section merges under four greens that ran none of it. One
check does execute on it: `Required-check spec gate` is path-unfiltered and runs
`scripts/required-checks.test.sh` on every PR — but it is in no required
aggregator's `needs:` and carries no required name, so it cannot block a merge.
Four greens plus one unenforced green is the real coverage of a docs-and-scripts
PR; read it that way rather than as five gates agreeing.

## The stale-verdict population, measured 2026-08-09

Measured, not inferred. Every workflow run on #10944's head was created at the
push instant `2026-08-08T14:31:22Z` with `run_attempt=1`, and 49 commits have
landed on main since. #10129's twelve runs all carry `2026-08-07T05:57:05Z` with
100+ commits since, and the API still reports all four required contexts green.
Re-derived 2026-08-09 over the live population: **22 CONFLICTING of 40 open**,
of which **8 assert a full 4-of-4 green required set**, plus #6057 and #6086 at
**1-of-1** — three of the four required contexts never rendered on them at all,
a worse class the 4-of-4 framing hides entirely.

## The Sobelow flip precondition, as first written

The original
text gated the flip on the baseline's `file:line` entries reaching **0**, and
quoted **137** entries. Both numbers are corrected below.

## Sobelow baseline and floor derivations (2026-07-28 onward)

Last derivation, 2026-07-29 on `origin/main` @ `606fefd15`: **89 rows** —
54 `Traversal.FileModule`, 11 `DOS.StringToAtom`, 6 `SQL.Query`,
6 `Config.CSRF`, 3 `XSS.Raw`, 2 `SQL.Stream`, and one each of
`XSS.SendResp`, `XSS.ContentType`, `Traversal.SendFile`, `RCE.CodeModule`,
`Config.HTTPS`, `Config.Headers`, `CI.System`. (It read 108 on 2026-07-28.)
Wave 24 slice S3 then deleted **32 dead rows** — entries that were no longer
the thing suppressing any finding, proven by running Sobelow with the
baseline emptied — taking it to **57**. Which is why the paragraph above
says derive, not quote.

The `Config.Headers` row in `router.ex` that made this class 8 is **gone** —
wave 24 slice S2 fixed the underlying code, exactly as the paragraph below
said it would.

Wave 24 slice S2 did exactly that to the
single `Config.Headers` finding in `router.ex`, taking the floor **10 → 9**;
the table above lagged that landing by weeks.

## The mix-audit blocker, retracted

This
bullet said "`mix-audit` is red on main … the dep bump that clears it is
open as #8222" until 2026-09-01. Both halves are dead: 95ace3150 landed the
req bump 2026-07-31 from outside that epic, `Security gate` and its
`Dependency CVE audit` leaf both conclude **success** on main head today,
and #8222 is **CLOSED with `mergedAt: null`** (`gh pr view 8222 --json
state,mergedAt`) — so "once it merges" was a trigger that could never fire.
`.github/required-checks.json` re-grounded this on 2026-07-31 and this page
never followed.

## Provenance: D75 is a dangling citation

**Provenance: D75 is a dangling citation.** "D75" has no defining charter
entry. It is cited at `bp-felix-pristine-charter.md:904` and `:2158` and at
this file's flip verdict, but the felix charter's own **D75** (`:1163`,
"Fresh-eyes last corner honestly clean") is a different subject entirely.
This paragraph — introduced by `34b9b25d3` (#5474) — is D75's only extant
text. Cite *this section*, not the number.

## Provenance of the Vercel advisory classification

*Provenance (this entry is being established, not restated):* before it,
`grep -in vercel docs/ops/merge-gates.md` returned nothing. Merges past
these checks had been justified as "the repo's standing advisory
classification" while no such classification existed anywhere in the
repo. This paragraph is that correction; the rule starts here.

## Lessons-learned: PR #42 macro-in-guard (2026-04-25)

PR #42 (Phase 1 — Oban + plugin_settings + Cloak encryption) introduced a
`when`-guard in `config/runtime.exs` that referenced a macro instead of a
plain function. The construct compiled cleanly under `:dev` and `:test`,
the test suite passed, and the Reviewer's static audit did not flag it.
The defect surfaced only on the production server during the rebuild
that followed merge: `MIX_ENV=prod mix compile` failed, the systemd
service failed to restart, and PR #43 (`966fcd98 fix(api): move
config_env() out of when-guard`) was filed the same day as a hotfix.

What the new gate catches:

- **Macro-vs-function misuse in `when`-guards** that the prod compiler
rejects but `:dev`/`:test` accept.
- **Missing or stale `_build/prod` artifacts** that a partial clean would
hide on a developer's machine.
- **Forgotten `--warnings-as-errors`** drift across config branches.

What it does **not** catch (still requires Reviewer + tests):

- Logic errors that compile cleanly in every environment.
- Schema/data migrations that compile but fail at runtime.
- Anything that requires the database, the BEAM runtime, or external
services to be active.

## The doc-gates step label: `(blocking)` became `(fails this job)`

**THIS PARAGRAPH USED TO SAY `(blocking)`, AND THE SENTENCE AFTER IT TAUGHT THE
WORD.** Until 2026-08-19 the count line above ended in the words "labelled
`(blocking)`" and the next line read "**`(blocking)` there means blocking
inside the job, not on the merge**" — the canonical page on merge authority,
naming steps that have none with the vocabulary of steps that do, and then
teaching that vocabulary as current. #12631 had already renamed all 21 step
names in `.github/workflows/doc-gates.yml` to `(fails this job)`; only this page
still spelled the old label. The old words are quoted here rather than deleted,
so a reader who greps `(blocking)` lands on the correction instead of on
nothing.

That replaces the command this page cited until 2026-08-19, `grep -c
'(blocking)' .github/workflows/doc-gates.yml`, which returns **1** on `main`
today — the page was naming a derivation that refuted its own number.

## The budget header that enforced nothing

**This page was one of them until this section was written, and it is not any
more.** The header claimed `budget: 800tok` until 2026-08-23 while the file was
~59KB (~15k tok) — a 50x-false figure nothing could red, precisely because the
page sat outside the CAPS table (filed as
`cch-w49-bl-merge-gates-budget-header-enforces-nothing`). Restating it as
`16000tok` did not fix that: on 2026-09-01 the file measured *past* its own
declaration and, still outside the table, nothing reded. Both halves are closed
now, in that order.

; this
sentence has already carried three of them ("~61KB", then a count that was
already wrong by ~3.6KB the moment the correcting commit landed, because writing
the correction grew the file). It carries none now.

## Corrections this page used to carry inline

(Until
2026-08-07 this item ended by denying that any mechanism enforced it — false
since the aggregator became a required context.)

Until 2026-08-07
this item ended "…so the workflow is always present in the required-status
list", contradicting that section 380 lines further down the same page.

The rationale this line used to give ("fingerprints are not
stable across Elixir toolchains") is **REFUTED** and must not be reused:
felix-pristine **D140** measured byte-identical 51-finding sets across
1.18.1/OTP27 and 1.19.5/OTP28, a wider gap than the pinned pair, and
`Finding.fingerprint/1` is `:erlang.phash2/1` over AST from
`Code.string_to_quoted`, not compiler output.


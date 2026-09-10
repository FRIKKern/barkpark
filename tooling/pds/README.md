<!-- doc-tier: human -->

# tooling/pds — is a stored reason re-derivable, or is it just distinct?

The PDS ledger census (`scripts/pds-ledger-census.sh`) asserts that every live
adjudicated row carries a **byte-distinct** `disposition_reason`. Wave 27 made
that clause green for the first time in 27 waves — and its own reviewer named
the hole in the same breath:

> the round's correctness now rests on committed prose recipes rather than on
> anything an instrument can re-check: clause 1 asserts md5-distinctness and
> nothing more, so a STALE, INVENTED or PARTIAL reason passes exactly as well as
> a re-derived one.

This directory is the instrument that can tell them apart, and — just as
importantly — that **names and counts the reasons it cannot**.

```
node tooling/pds/rerun-adjudicate.test.mjs      # the gate: 117 checks, prints its count
node tooling/pds/rerun-adjudicate.mjs           # the verdict line over the committed corpus
node tooling/pds/rerun-adjudicate.mjs --fetch   # …over the live board instead
node tooling/pds/rerun-adjudicate.mjs --budget-ms 100   # refuses to start
```

## It is an adapter, not a second engine

`tooling/grip` already carries the fact record
`{subject, quantity, claim, evidence, rerun, level, observed_at, deps[]}`, and a
PDS ledger row **is** that record under other names:

| PDS ledger field | grip field | authority |
| --- | --- | --- |
| `disposition_reason` | `evidence` | **L6 by construction** — never parsed, never levelled |
| `disposition_rerun` | `rerun` | the only field the level grammar reads |
| `title` | `claim` | scanned for path-less refs |
| `pds/<doc_id>` | `subject` | the conflict key, verbatim |

So admission, levelling, safety screening, family-dispatched silence and
absence admissibility are all grip's shipped modules, imported **read-only**.
Zero bytes under `tooling/grip/` are changed by this tree, and nothing here is
coupled to grip's suite or its seal.

**No exit code is ever read.** grip's engine modules never terminate the
process; only its CLI does. This tree imports the engine and reads the
structured ruling, because scoring grip's `rc` would commit the epic's own
violation — *no verb may report success on an exit code alone* — inside the
instrument built to enforce it.

## The three rules that make a verdict mean something

**1. BINDING (`binding.mjs`) — the falsifiability seam.** A rerun is evidence
for a claim only when the two are *bound*: every term the recipe declares
(`ref`, `path`, `token`, `sha`, `predicate`) must occur **literally** in both
the command and the claim prose. That single rule is what makes a mutation test
possible at all — *mutate the claim, keep the command byte-identical, and the
harness reds*. Binding says the command is **about** the claim; it says nothing
about whether the claim is true. Both binding and execution are required before
anything is reported RE-DERIVED.

**2. VARIANCE-SKIP, not strict polarity (`variance.mjs`).** Only 1.65% of this
repo's real reruns are strictly-polarised predicates, so a strict screen refuses
98.3% of honest work and teaches authors to write prose instead. The rule is
grip's LEVEL-SKIP rotated one axis: *the command's variance set is a ceiling on
the claim class*. Only over-claims are refused — `VARIANCE-SKIP`,
`PIPE-MASKED-RC`, `UNCOMPARED-COUNT`. Anything that does not classify is
**demoted to L6, never rejected**.

**2b. A COUNT NOBODY GRADED ASSERTS NOTHING (`variance.mjs`, 2026-09-10).** The
rule is stated on the **act**, not on a list of spellings: `wc`, `grep -c`,
`grep -vc`, `git grep -c` and `git rev-list --count` all PRINT a quantity, and
all are `UNCOMPARED-COUNT` unless the pipeline **ends in an equality grade**
(`… | grep -qx <n>`), which is the one shape where the number becomes something
an exit code moves on (axis `QUANTITY`, claim class `quantity`). Until this rule
existed only `| wc` and an ungraded `--count` were named, so the same population
claim was **refused** when spelled `wc` and **paid in full** when spelled
`grep -c` — the screen refused the honest author and admitted the other one. The
refusal names its substitute rather than only saying no. The other half is
`binding.mjs`'s **`quantity` term**: a claimed number must occur literally in the
command *and* in the claim, so mutating the number while holding the command
byte-identical reds the row (`rerun-adjudicate.test.mjs` §12).

**3. ABSENCE IS FIRST-CLASS (`adjudicate.mjs`).** Four of five FAILED verdicts in
the real sample were *true* reasons whose rerun exits nonzero because the claim
**is** an absence. The discriminator is grip's shipped `admitsAbsenceClaim`,
never `verdict == ADMITTED`.

## Where a rerun comes from: the row first, the sidecar second

A rerun reaches this instrument two ways, and they are **not** equal.

1. **The row's own `content.disposition_rerun`** — the fourth durable key
   `bp task stage --rerun` writes. This is the author's record, on the ledger,
   and it **wins**.
2. **`recipes.json`** — a repo file somebody re-typed by hand. It is the
   explicit **fallback**, used when the row carries nothing. When a row carries
   both, the shadowed recipe is reported by name, never silently dropped.

Wave 28 shipped both halves and never joined them: `corpus.mjs` normalised
`disposition_rerun` off every row, and `toFact()` read the sidecar and nothing
else, so a row that carried a stored rerun was reported `PROSE-ONLY / NO-RERUN`
— *"asserted by nobody"* — about a row somebody had asserted. The verdict line
now prints **how many rows carry a stored rerun**, including when that number is
zero, because the way a disconnect survives a whole wave is that nobody prints
the number.

A stored rerun gets **no free pass**. It goes through `forbiddenSpelling`,
`bindClaim` and `overClaim` in that order and is levelled by `deriveLevel`,
exactly like a sidecar recipe. Two things it does not get:

- **A claim class.** Nobody declared one, so it is adjudicated at the *floor*
  class `existence` — paid for by `EXISTENCE` or `CONTENT` and nothing else.
  Reading the class out of the command's own variance set would make the
  variance screen vacuous; reading it out of the prose is the scanner grip
  already refuted at precision 0.67. `absence` is deliberately **not** the floor
  despite being paid for by more axes: absence is a *polarity*, and guessing an
  author's polarity is the one thing this epic may not do.
- **An author's terms.** They are *derived from the command* — the pattern of a
  `git grep`, the path of a `git show <ref>:<path>` or a `-- <pathspec>` — and
  then checked against the row's **title**, which is the claim `toFact()` hands
  grip. That is not circular: the check that fails is *does the row's own claim
  literally name what this command reads*. A path binds by **basename**, which
  is a weaker binding than an authored full-pathspec one, and the note says so.
  A command whose subject cannot be named binds nothing and is `REFUSED`
  `MISSING-TERMS` — fail closed, never silently admitted unbound.

Measured on the live board 2026-09-10: three rows carry a stored rerun; one
re-derives, two are `REFUSED UNBOUND-CLAIM` because the command greps for an
expression the row's title never names. Those three rows are captured verbatim
in `fixtures/stored-rerun-rows-2026-09-10.json`; the shipped 172-row
`live-corpus-2026-07-31.json` snapshot carries **zero**, which is why it can
only prove the absence.

## Two things this tree deliberately does not hide

- **The behaviour class is mostly un-re-derivable here, and `variance.mjs`
  advertises more than the executor will run.** `variance.mjs` classifies nine
  heads onto `BEHAVIOUR` — `go mix npm pnpm bash sh zsh node python3` — because
  that is what their *exit codes mean*, which is the only question that table
  answers. grip's caller-boundary screen answers a different one — *will this
  census run it* — and fails closed. Measured 2026-09-10 against
  `screenCommand()`, **seven of the nine are unreachable**, by two layers:
  `bash`, `sh`, `zsh`, `node` and `python3` are refused at the HEAD (they
  execute arbitrary programs, correctly refused); `npm` and `pnpm` are
  allowlisted heads whose behaviour-paying sub-verbs (`test`, `run`) are not on
  the read-only sub-verb allowlist. Only `go` (`test`, `vet` — not `build`) and
  `mix` (`test`) survive. The two lists are NOT aligned on purpose: pruning
  `variance.mjs` down to the executor would make it lie about the shell. So a
  reason that can only be checked by *running* one of the seven is reported
  `REFUSED` with that named reason, and counted. Making that class visible and
  bounded is the honest move; green-lighting it by construction would be the
  vacuous green one level up.

  <!-- pds-stated-limit: executor-unreachable-behaviour-heads = bash node npm pnpm python3 sh zsh -->

  That comment is not decoration: section 10 of `rerun-adjudicate.test.mjs`
  parses it, re-runs every head's probe through the live screen, and reds if
  the prose, the constant in `variance.mjs`, and grip's screen ever disagree.
- **Two polarised predicates go mute.** `git cat-file -e <ref>:<path>` and
  `… | grep -qx 0` are polarised at the shell and admitted by grip's screen, but
  grip's `classifySilence` rules both NULL-READ because they answer silently by
  design. PDS does not patch grip for this (filed as
  `pds-w28-bl-grip-silent-predicate-null-read`); it recommends the `-t` and `-x`
  spellings, which keep the polarity **and** print.

## What the verdict line may never say

No sentence in `verdict.mjs` may mean *"these reasons are true."* The strongest
statement available is that **one bound sub-claim** of a reason re-derived at
HEAD just now — not the rest of the reason, and not that anyone ever ran the
command. `bannedWordingIn()` is run over the rendered text by the gate, so the
rule is enforced rather than intended.

The remainder — every reason with no rerun attached — is printed **by name**, not
summarised. A remainder that is only counted is still unauditable.

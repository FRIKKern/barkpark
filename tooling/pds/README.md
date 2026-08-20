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

**3. ABSENCE IS FIRST-CLASS (`adjudicate.mjs`).** Four of five FAILED verdicts in
the real sample were *true* reasons whose rerun exits nonzero because the claim
**is** an absence. The discriminator is grip's shipped `admitsAbsenceClaim`,
never `verdict == ADMITTED`.

## Two things this tree deliberately does not hide

- **The behaviour class cannot be re-derived here.** grip's caller-boundary
  screen refuses every script runner (`bash`, `sh`, `node`), correctly — they
  execute arbitrary programs. So a reason that can only be checked by *running*
  something is reported `REFUSED` with that named reason, and counted. Making
  that class visible and bounded is the honest move; green-lighting it by
  construction would be the vacuous green one level up.
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

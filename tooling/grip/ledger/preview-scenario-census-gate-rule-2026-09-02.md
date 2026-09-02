# The files-to-instruments rule for the preview scenario corpus — the choice, and why

Row: `task-d5c2ffba2ce7b562` (cch-instruments epic). Measured on `origin/main@9e04f46fb0`.

## 1. Fail-first, on the CLASS

A slice-shaped change was constructed: **one scenario added to
`cloud/priv/static/__preview__/scenarios.mjs`, nothing else** —
`probe-failfirst-scenario`, `deepLink: "#overview"`, no expectation, no residue
entry. Then every instrument in the preview tree was run bare.

| instrument | rc | what it said |
|---|---|---|
| `node --check cloud/priv/static/__preview__/scenarios.mjs` | 0 | — |
| `node cloud/priv/static/__preview__/smoke.mjs` | **1** | `CENSUS: 1 committed scenario(s) have NO expectation and were never run` |
| `node cloud/priv/static/__preview__/breakpoint-sweep.mjs` | **2** | `UNLISTED scenario "probe-failfirst-scenario" (family hash:#overview)` |
| `node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs` | **1** | 5 failing, incl. `the census reconciles: 117 scenarios…` |
| `node cloud/priv/static/__preview__/member-authority-sweep.mjs` | **1** | `the committed corpus grew to 117 scenario(s), pinned at 116` |
| `node --test cloud/priv/static/__app.test.mjs` | 0 | 1200 pass |
| `node cloud/priv/static/__me_envelope_census.mjs` | 0 | PASS |
| `node cloud/priv/static/__agent_event_vocabulary_census.mjs` | 0 | OK |
| `node cloud/priv/static/__preview__/modal-oracle.mjs` | 0 | ORACLE PASS |

Before this branch, nothing in the repo told that author any of it. The file's
own header (`scenarios.mjs:1-6`) named exactly two consumers — `mock.js` and
`smoke.mjs` — and never stated that anything keeps a census over it. No
files-to-gate rule existed anywhere under `scripts/`. The Console gate was the
first thing to say so, exactly as on cch-w21-s3 and the wave-20 sweep.

**The row undercounted.** It names two census owners; the measurement found
**four**. `breakpoint-sweep.test.mjs` and `member-authority-sweep.mjs`
(`PIN_TOTAL_SCENARIOS`) red on the same one-scenario addition, and covering the
row's two would still have been half a fix.

Not measured, so absent from the table as an *unmeasured absence*, not a proof:
`overflow-guard.mjs` (needs a browser) and `seal-predicate.test.mjs` (exceeded a
2-minute budget).

## 2. The choice, with its reason

The row lists three homes and says *pick by measurement, do not assume*.

**(c) — a header on `scenarios.mjs` naming every census owner: ADOPTED.** The
row's argument holds and the measurement confirms its premise: the builder who
breaks this rule is editing `scenarios.mjs`, which they must open, and the
charter is a file they may never open. The header now states the rule, names all
four owners by path with the run command and the exit code each produces, and
says which edits require none of them.

**(b) — a committed check: ADOPTED, because (c) alone has a ceiling that cannot
be argued away.** A comment cannot fail on the change it warns about. It can be
skimmed, and it rots silently. `scripts/preview-census-gate-check.mjs` closes
both: given a changed-file list and a base version it computes the census delta
and prints the instruments the slice's own gate must run; with `--gate` it reads
the slice's proposed gate and **exits 1** on any omission — a red that arrives
before the Console gate rather than from it.

**(a) — a line in the charter's gate-authoring rules: REJECTED as the home,
adopted in effect.** Two reasons, one of them structural. It reaches only the
DECIDE author, and DECIDE is precisely where the omission happened twice; and
this row's fence excludes the charter. What (a) was for — a rule a gate author
can be held to — is delivered by (b)'s `--gate` arm, which is mechanical and
does not depend on anyone having read a document. The exact `console-harness.yml`
hunk that would wire it is in the PR body; no workflow file is touched here.

The two adopted halves are wired to each other: the check's `verifyHeader` arm
**reads the header** and reds if the rule marker or any owner path is deleted
from it. That is what makes the documentation option falsifiable — not on the
addition it warns about, but on its own removal.

## 3. The trigger is the census DELTA, not "the file changed"

"`scenarios.mjs` is in the diff" is the over-broad rule the row's negative arm
warns about: it would drag four instruments into every slice that retunes one
label. Measured, on the real corpus:

| mutation | smoke | sweep | sweep.test | member-authority |
|---|---|---|---|---|
| add one scenario | 1 | 2 | 1 | 1 |
| change one `label` | **0** | **0** | **0** | **0** |
| move `fleet-cruel-content` `#fleet`→`#activity` | 1 | 2 (`DRIFTED`) | — | — |

So the trigger is what the censuses actually key on: an **added** name, a
**removed** name, or a **family drift**. `familyOf` is imported from
`breakpoint-sweep.mjs` itself, never re-typed, so the family half of the trigger
cannot drift away from the instrument that owns it.

## 4. Honest ceiling

- The check does not *run* the instruments; it says which must run. `--gate`
  proves a gate **names** an instrument, not that it runs it successfully.
- The owner table is measured, not derived. A fifth owner added later is invisible
  until someone measures again — which is why `verifyTable` refuses (exit 3) the
  moment a listed owner stops existing, stops reading the corpus, or loses its
  census literal, rather than quietly answering with a shorter list.
- The header cannot red on an added scenario. Only the check can.
- Nothing here re-pays cch-w21-s3's instance: its expectation was written by the
  wave-21 reviewer and merged. This buys the rule.

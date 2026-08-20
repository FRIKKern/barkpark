# cch-w25 — cssom / E14 / app.test instrument baseline, re-derived 2026-08-02

Subject tree: `origin/main` @ `5444aa5e1ea8bc643ba8c7a100f9173413c688a4`
(`docs(pds): wave-41 charter … (#9175)`), measured in a detached scratch worktree, never in the
primary checkout — the primary checkout was **356 commits behind** at measure time and its
`__css_check.mjs` carries **no E14 at all**, so every number taken there is a different file's number.

    git worktree add --detach <scratch> 5444aa5e1
    cd <scratch>/cloud/priv/static

## The four instruments and the one question each owns

| instrument | today's number | what it CAN see | what it CANNOT |
|---|---|---|---|
| `__preview__/cssom-parity.mjs` | `authored rule heads 1284 (baseline 1284)`, `flattened 1232/1232`, `MISSES 0`, PARITY PASS | a RULE HEAD added/removed/swallowed | a comma member — heads stay 1284 |
| `__css_check.mjs` (default) | `E14 5 wrapper-scoped .status-pill wrap copy(ies)`, `0 error(s)` | core DIVERGENCE in any copy; a MISSING copy among the 4 `WRAP_REQUIRED_HOSTS` | losing `.detail-title-row` — it is counted, not required |
| `__css_check.mjs --wrap-parity-check <file>` | app.css → `5 wrapper-scoped wrap copy(ies) … 0 E14 error(s)`, rc 0 | the same, against ONE named file | ditto |
| `__app.test.mjs` | `# tests 776 / # pass 776 / # fail 0` | the same-file COUNT pin (`5`) and the per-host loop that DOES include `.detail-title-row` | nothing in this class |

## Re-derivation commands

    node __preview__/cssom-parity.mjs                       # rc 0, PARITY PASS 1284
    node __css_check.mjs                                    # rc 0, prints the E14 inventory of 5
    node __css_check.mjs --wrap-parity-check app.css        # rc 0, 5 copies, 0 E14 errors
    node __app.test.mjs                                     # 776/776
    grep -cE '^[0-9]+$' __preview__/cssom-heads.baseline    # exactly 1 (line 498 of 498)

`app.css` identity at measure time: sha256 `e1b869749043f0e931f4081068bfed14ff4f7b1948c1c82e442c0809a82f1613`, 304277 B.

## Wrong-sentinel recipe (D158/D202/D230), verified live

`HEADS_BASELINE` is a **PATH, not an integer** — `HEADS_BASELINE=9999` produces
`!! GUARD (exit 2): no authored-head baseline sidecar at …/9999`, an environment refusal that
is easy to misread as a pass. Write a throwaway sidecar instead:

    printf '# wrong sentinel\n9999\n' > /tmp/sentinel.baseline
    HEADS_BASELINE=/tmp/sentinel.baseline node __preview__/cssom-parity.mjs   # rc 1
    # → "!! BASELINE MISMATCH: 1284 authored rule heads, sidecar baseline is 9999 (−8715)."

Read **1284** out of the tool's own failure text; never compute it from deltas.

## Mutation proof — the 5→4 blindness is real, not argued

Deleting the fifth wrap copy (`.detail-title-row .status-pill`, a comma member of the
`.instance-card-head` prelude at `app.css:6230-6231`) from a copy of the stylesheet:

* `cssom-parity` on the mutated file: `authored rule heads 1284` — **unchanged**, still equals the
  sidecar; flattened moves 1232 → 1231 but flattened is not baselined. **BLIND.**
* `__css_check --wrap-parity-check <mutated>`: `4 wrapper-scoped wrap copy(ies) … 0 E14 error(s)`, rc **0**. **BLIND.**
* `__app.test.mjs` over a mutated copy of the whole static dir:
  `not ok 72 - cch-w19-s4: E14 greens app.css's OWN bytes and sees all five copies there`. **SEES IT.**

Recipe:

    awk 'NR==6230{print ".instance-card-head .status-pill {"; next} NR==6231{next} {print}' app.css > /tmp/mut.css

## Standing facts for Decide

* `WRAP_REQUIRED_HOSTS` (`__css_check.mjs:646`) is still **four**:
  `.attention-row .detail-rail .fleet-status .instance-card-head` — `.detail-title-row` omitted,
  deliberately, per the comment block in `__app.test.mjs` and the filed row
  `cch-w24-bl-detail-title-row-not-a-required-wrap-host`.
* The ownership rule is already WRITTEN, in `__app.test.mjs`'s own comment above the
  app.css leg. Quote it; do not mint a new one.
* `node __css_check.mjs --wrap-parity-check` with **no file argument** dies on an uncaught
  `TypeError [ERR_INVALID_ARG_TYPE]` and exits **1** — the same code as a real E14 defect.
  Any gate that runs it bare cannot tell a crash from a finding.
* Baseline holder: **D291 already ruled it — NO CSSOM HOLDER, unconditionally; every app.css
  slice abstains by hard criterion** (its diff's file list must not contain
  `__preview__/cssom-heads.baseline`). Confirmed today: heads still 1284, sidecar still 1284.
  D291's *flattened* number (1229 at app.css 296581 B) has since moved to **1232 at 304277 B** with
  heads flat — three grouped-selector additions, exactly the shape a head count cannot see.

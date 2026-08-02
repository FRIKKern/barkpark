# cch-w25 — WHICH INSTRUMENT OWNS WHICH QUESTION

Paste this block into every `app.css`-touching fence. Measured on `origin/main`
= `5444aa5e1`, 2026-08-02. Every row was RUN (see
`cch-w25-gate-reach-proof-2026-08-02.md` R6), not read.

| Instrument | Question it owns | What it counts / measures | Blind to | In a workflow? |
|---|---|---|---|---|
| `__app.test.mjs` | app.js behaviour + **same-file source pins** over app.css | **WRAP COPIES** — wrapper-scoped copies of a recipe, incl. comma members; `data-state` paint rules; region-scoped source assertions | browser geometry; anything needing a layout | yes — `console-harness.yml:225` (`console-unit`) |
| `__preview__/cssom-parity.mjs` | did every authored selector reach the CSSOM | **RULE HEADS** (1284, baseline-pinned) + flattened selectors | a comma member added to an existing prelude (delta-heads 0); `data-state` | yes — `console-harness.yml:363` (`cssom-parity`) |
| `__css_check.mjs` | does every emitted class/token EXIST, contrast, wrap-host parity (E14) | 870 classes, 95 tokens, 576 contrast pairs; `--wrap-parity-check` | `setAttribute("data-state", …)` emissions (E2 scans `.className=` / `classList.*` only) | yes — `console-harness.yml:302` |
| `__preview__/overflow-guard.mjs` | **BOXES** in a real browser: does anything paint outside its box or drag the page sideways | per-cell box geometry across widths/themes; carries the 78-char cruel-host cell | anything it has no cell for; page-level residuals it prints but does not assert | yes — `console-harness.yml:511` (`overflow-guard`) |
| `__preview__/breakpoint-sweep.mjs` | is the WIDTH AXIS itself covered | 25 @media preludes → 6 breakpoints → 18 boundary widths; screen/scenario/theme coverage | yield — it proves coverage, not absence of defects (says so itself) | yes — `console-harness.yml:291,294,438` |
| `__preview__/modal-oracle.mjs` | modal/dialog positioning + scroll reachability | `pos/overflow-y/card px/root px/hit` per state | **nothing runs it in CI** | **NO** |
| `__preview__/font-pin.mjs` | which typeface actually resolved | `document.fonts` faces/weights vs `EXPECTED_FACES` | — | **NO workflow**, but IMPORTED by overflow-guard, breakpoint-sweep, modal-oracle. Running it standalone prints nothing and exits 0 — a library, not a gate. |
| `__preview__/smoke.mjs` | do all 101 scenarios render at all | scenario render census | geometry, CSS | yes — `console-harness.yml:237` |
| `__preview__/seal-predicate.test.mjs` | the seal predicate's own arithmetic | 49 tests | — | yes — `console-harness.yml:253` |

## The ownership rule is already written in the repo — quote it, don't mint it

`cloud/priv/static/__app.test.mjs:1934-1942`:

> cch-w24-s2 BUMPED IT 4 -> 5 … it is still a fifth wrapper-scoped copy with
> its own blast radius. THE COUNT IS WHAT NOTICED: nothing else in the wave's
> gates moved, and the slice's own gate (guard + `__css_check` + cssom-parity)
> did not include this harness. **A comma member is invisible to a rule-head
> count and visible to this one, which is the whole point of keeping both.**

## The fence line that follows from R1-R4

> Your PR's `Console gate` / `Cloud gate` are GREEN-BUT-NOT-REQUIRED: live
> branch protection requires only `Elixir gate` + `PR references an active
> task`, and `elixir.yml` contains zero occurrences of `cloud`. A cloud-only PR
> therefore has NO blocking technical gate. Run every instrument in your fence
> LOCALLY and paste its exit code and last lines into the task. A green PR page
> is not evidence.

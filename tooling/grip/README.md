<!-- doc-tier: human -->

# tooling/grip — the source-of-truth grip layer

Every wrong value the parent session produced was a **level-skip**: reading at
one authority level and claiming at a higher one. This module is the substrate
that makes that structurally impossible before any fact is stored durably.
Charter: `.claude/workflows/bp-truth-grip-charter.md`.

## The fact record

```js
{ subject, quantity, claim, evidence, rerun, level, observed_at, deps: [] }
```

Two fields carry all the authority machinery, and they are deliberately
asymmetric:

- **`rerun`** — ONE literal shell command string. The level grammar reads this
  and nothing else.
- **`evidence`** — free prose. **L6 by construction.** It is never parsed and
  can never raise a level. A prose scanner was built first and refuted: L1/L2
  precision 0.67 on 60 hand-labelled real strings — it stamped L1 on a string
  beginning "OPEN — requires a run against the deployed build". Markers fire on
  mention; the grammar levels only the invocation.

## The ladder

| Level | Derived from the `rerun` command when… |
|---|---|
| L1 | `ssh …@host` (flags allowed between `ssh` and the `@`) or `curl`/`wget` to a non-loopback host |
| L2 | `git show origin/…:path` (any remote ref) or `gh api` |
| L3 | local read, scoped grep, local test run, `node <script>`, loopback curl |
| L4 | a read whose target is a known generated artifact (`docs/openapi.json`, `*.golden.json`, …) |
| L6 | no command, or a shape the grammar cannot classify — **demoted, never rejected** |

The derived level is a **ceiling**. A record claiming a level above it is
rejected with `LEVEL-SKIP` naming both levels; equal or below is accepted — an
author may honestly under-claim.

## Other rejections

- `PATHLESS-REF` — a `path:line` reference with no directory component
  (`notifications.ex:389-397` sent a verifier to `api/lib`; the file was in
  `cloud/lib`). Checked in `subject`/`claim`/`quantity`, never in `evidence`.
- `INADMISSIBLE-CONTINUOUS` — a continuous quantity (float + time unit, or a
  `t_total`-family observable) with no declared threshold predicate.
  Re-derivation of such a quantity yields a distribution and conflict
  detection would fire forever on noise.

## What this certifies — and what it does not

The grammar certifies **re-derivability**: that the recorded command, run
again, is the kind of command that answers at the recorded level. It never
certifies **authorship** — a syntactically perfect curl the author never ran
passes this grammar. Re-execution is the executor slice's job, and even its
verdict is "re-derived just now", nothing stronger.

## Use

```js
import { deriveLevel, checkCeiling, classifyRef, isDiscretePredicate } from "./level.mjs";
import { admitFact } from "./record.mjs";
```

Named ESM exports, `node:` builtins only (currently zero imports), no side
effect on import. Tests: `node --test tooling/grip/test/level.test.mjs`.

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

## Writing a fact into the store

`node tooling/grip/ledger.mjs write <facts.json> [dir]`. The full write path —
the fact shape, the fields that are dropped, the required mint, the
all-or-nothing rule and the `.ok`-not-`.safe` trap — is documented beside the
write target in [`ledger/README.md`](./ledger/README.md#how-to-write-a-row).

## The node refusal — a reach bound this epic CHOOSES, stated honestly

`screen.mjs` refuses every command whose head is `node`, with the reason string
*"node executes arbitrary JavaScript (including fs writes)"*. **The refusal
stands. That reason string is not the principle, and this README will not let
it pretend to be one.**

What the screen already admits, verified by running it:

| command | verdict |
|---|---|
| `mix test test/foo_test.exs` | **admitted** |
| `go test ./internal/cli/...` | **admitted** |
| `node --test tooling/grip/test/ledger.test.mjs` | refused |
| `node tooling/grip/ledger.mjs --selftest` | refused |

`mix test` and `go test` execute arbitrary repo code. Not "could in principle" —
this repo's own ExUnit files call `System.cmd("python3", ["-c", …])`
(`api/test/barkpark/epic_fleet/benchmark_test.exs:626` and `:1203`). A screen
that admits those and refuses `node` is not enforcing "no arbitrary execution".
It is drawing a **reach** line, and the honest name for it is a reach line.

It was, until this same wave, defeated **below its own grammar**. An assignment
prefix in front of an admitted head passed straight through:

```
NODE_OPTIONS=--require=/tmp/evil.js mix test   → admitted   (before wave 5)
                                               → refused    (now)
```

— arbitrary JavaScript, loaded by node, through a head the screen allowed. The
environment-assignment prefix is now screened against an inert allowlist rather
than stripped and discarded, so that form is closed. **This does not restore
"no arbitrary execution" as a principle**, and nothing below changes: the two
rows in the table above still admit `mix test` and `go test`, which is the whole
argument. A reach line that got one hole plugged is still a reach line.

The residual that replaced it is smaller and the same SHAPE: an unquoted
parameter expansion (`grep -n $PATTERN .`) is still admitted, so the environment
decides what the command means. Expansion yields DATA rather than the output of
a command that ran, which is why it is smaller — and it is filed as
`tgw5-screen-param-expansion` rather than left implicit here.

**Why the refusal stands anyway.** The yield of relaxing it is near zero,
measured over the frozen 651-command corpus in `fixtures/evidence-corpus.json`
rather than asserted: **0** commands are the narrow whole-string form
`node --test <path>`. Five (0.77%) contain the token pair `node --test` at all,
and every one of those is wrapped in a pipeline, a `cd … &&`, or a `printf >>`
write shape that the screen refuses on other grounds regardless. So carving out
a `node --test` exception buys at most one storable recipe and costs a hole in
the simplest rule the screen has.

**The cost, named out loud.** Grip's own proof commands are unstorable in grip's
own ledger: `node --test tooling/grip/test/*.test.mjs` and
`node tooling/grip/ledger.mjs --selftest` can never become rows. This repo's
whole JS test idiom is out of the store's reach. That is a real hole in the
index and it is a choice, not an achievement.

## The grep wrapper WAS blind to `census.mjs` — every negative resting on it is still VOID

**Fixed in this same wave; the method ruling outlives the fix.** `census.mjs`
carried a literal NUL byte at offset 8398 — a raw `0x00` written into a mask
expression where a `\0` escape was meant — so `file` reported it as *binary
data* and the shell's `grep` wrapper, which skips binaries, printed nothing and
exited 1. That reads exactly like "no matches":

```
$ grep -c 'census' tooling/grip/census.mjs            → (no output), exit 1     ← before
$ /usr/bin/grep -ac 'census' tooling/grip/census.mjs  → 30, exit 0
```

The byte is gone (`file` now reports UTF-8 text and the wrapper returns hits),
but that does **not** restore any conclusion drawn while it was there:

> **METHOD RULING.** Any negative anywhere in this epic that rests on grepping
> `census.mjs` through the wrapper is **VOID** and must be re-derived with
> `/usr/bin/grep -a`. An absence measured by a tool that could not see the file
> is not an absence, and repairing the file does not retroactively make the
> measurement have happened.

This is the epic's own disease inside the epic's own instrument, and it is kept
here after the fix precisely because the fix is the least interesting part of
it: one verifier read the empty result and concluded the census never screens at
all — the exact opposite of the truth — and caught itself only by accident.

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

## The vacuous-green trap in `node --test` — the precise mechanism

Cite this precisely or not at all; this epic's own artifacts have cited it
imprecisely, which is how a green that proved nothing got believed.

A missing file **alone** is a hard error:

```
$ node --test tooling/grip/test/DOES-NOT-EXIST.test.mjs
Could not find 'tooling/grip/test/DOES-NOT-EXIST.test.mjs'
```

A missing file **alongside an existing one is silently skipped**, and the run
exits **0** with a clean `# fail 0`:

```
$ node --test tooling/grip/test/ledger.test.mjs tooling/grip/test/DOES-NOT-EXIST.test.mjs
# tests 60
# pass 60
# fail 0
EXIT=0
```

No line names the file that was not run. So a gate written as
`node --test tooling/grip/test/a.test.mjs tooling/grip/test/b.test.mjs` goes
green forever after `b` is renamed or was never written. A glob
(`test/*.test.mjs`) does not have this failure mode, because the shell expands
it to what exists — but it also silently shrinks, so it proves "the files that
exist pass", never "the files that should exist pass".

**Two live instances in this module.** `tooling/grip/test/record.test.mjs`
**does not exist** — any prior artifact citing a `record.test.mjs` pass is
vacuous green. And `admitFact`, which carries this epic's central ceiling law,
has **no suite of its own**: it is exercised only incidentally inside
`adjudicate.test.mjs` (5 references) and `level.test.mjs` (17), where the
subject under test is something else.

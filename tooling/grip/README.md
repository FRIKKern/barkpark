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

## Reading the store back — three shapes, and the scope that is not a pin

`tooling/grip/ledger/` is a **shared append-only commons**: four epics write
into it, most of them by hand, and none of them may delete another's file. So a
reader has to say which population it is reading. `readLedgerRuns` names three
file shapes and the fold prints all of them on **every** run, pass included
(`[grip-fold] …` on stderr; `stats.not_a_run` / `stats.malformed_run` in the
JSON):

| shape | what it is |
|---|---|
| `NOT-A-RUN` | carries neither `run_id` nor `recipes` — a foreign note parked here. Never a run file, so never a defect report. |
| `MALFORMED-RUN` | claims the run shape (`run_id` or `recipes` present) and fails it. A real defect report. |
| a run | `recipes[]` present. A `run_id` string makes it grip-**owned**; without one it is a foreign `{claim, rerun}` row set. |

`node ledger.mjs fold [dir] [--scope=all|owned|attested]` narrows by **shape**,
never by filename. `attested` is the strongest: `writeLedgerRun` names every
file it writes `<run_id>-<digest of its own serialised bytes>.json`, so a file
whose name reproduces that digest **demonstrably came out of the write path**,
which means every row in it crossed `admitRecipe`. That is the population the
D89 control asserts folds clean, and it grows automatically — every honestly
written run attests itself.

**Why not a pinned file list.** Re-pointing the mint regression floor at
`binding.test.mjs`'s three census files turns "307 of 631 rows moved" into
"0 of 62" and passes: 9.8% of the rows carrying 0.0% of the drift, invisible
because the counts only ever printed inside the failure message while the test
name still promised "every committed ledger row". Scoped tests here therefore
**print what they walked on PASS** and assert growth with `>=`, never `===`.

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

## A missing binary is not a rotted recipe — read the census's tool header

`census.mjs` used to map exit **127** (the shell's "command not found") to
`PATH-GONE`, which sits in the **DECAYED** set. So the census scored the
operator's own toolbox as decay *in the ledger*. Re-derived over one unchanged
tree and one unchanged corpus, with nothing but `PATH` differing:

| run | decisive | decayed | rate | PREDICTION 3 verdict |
|---|---|---|---|---|
| full `PATH` | 193 | 39 | 20.2% | **CONSISTENT** |
| `PATH` without `bp`, `gh`, `go` | 197 | 61 | 31.0% | **CONTRARY** |

37 of that second 61 were pure rc-127. The verdict flipped on which tools
happened to be installed.

Two things changed, and both are load-bearing:

- **`TOOL-ABSENT`** is an outcome *outside* the DECAYED set. rc 127 lands there
  and leaves **both** rates — the same rule `WRONG-CWD` and `REF-GONE` already
  followed: a fault that measures **this host** never measures the ledger. A
  genuinely gone *path* is still `PATH-GONE` and still decay.
- **A tool-availability header** is printed on every run, naming which command
  heads were **present** and which **ABSENT**, and **no rate is printed without
  it** — the human banner, the rate block and the `--json` `decisive` figures are
  all withheld when no probe ran. Availability is **probed** (a walk of the same
  `PATH` the child shells inherit, plus the POSIX builtins) — it spawns nothing,
  so the census's execution set stays exactly what `screenCommand` admitted.

Post-fix the same three runs read 39/194 (20.1%), 24/160 (15.0%) and, with `npm`
also stripped, 24/159 (15.1%) — all **CONSISTENT**, with `bp`, `gh`, `go` (then
`npm`) named on the ABSENT line. **A decay rate from this census is conditional
on that list: quote them together or not at all.**

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
# tests 78
# pass 78
# fail 0
EXIT=0
```

Re-derived 2026-07-28 in a clean git worktree at origin/main `072978af0` plus
`tgw9-s1`. **The `78` is not the point and will move** — the carrier file grows
as the suite does, and this block last read `60/60` from a day when
`ledger.test.mjs` was both smaller and RED, so a reader re-deriving it got
`77/76/1` and `EXIT=1` and could reasonably have concluded the trap did not
exist. The point is the pair of facts that do NOT move: **`EXIT=0`**, and **no
line anywhere in the output names `DOES-NOT-EXIST.test.mjs`** (`node --test … |
grep -c DOES-NOT-EXIST` → `0`). Take the exit code from `node` itself, never
from the tail of a pipe: `cmd | grep …; echo $?` reports *grep's* status and
prints a cheerful `EXIT=0` for a failing `node`.

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

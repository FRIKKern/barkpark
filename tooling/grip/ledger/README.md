<!-- doc-tier: human -->

# tooling/grip/ledger — the recipe store

Every `*.json` beside this file is **one immutable run file**. Written once,
never modified, never deleted by tooling. The store is read by folding all of
them together: `node tooling/grip/ledger.mjs fold`.

## What a row is — and what it is not

```json
{
  "subject": "api/lib/barkpark/plugin.ex",
  "quantity": "callback count",
  "rerun": "grep -c 'def ' api/lib/barkpark/plugin.ex",
  "derived_level": "L3",
  "deps": ["api/lib/barkpark/plugin.ex"],
  "observed_at": "2026-07-20T12:00:00Z"
}
```

**There is no `value` field, and there never will be** (charter D26). A row
records *how to re-derive* a fact, not the fact. `observed_at` means **when
this recipe last ran** — never "when this was true".

A writer that supplies `value` (or `result`, `measured`, `answer`, …) is
**rejected** with `VALUE-STORED`, not silently trimmed. Unknown keys are
rejected too (`UNKNOWN-FIELD`): a store that quietly discards what it does not
understand lets a writer believe it recorded something it did not — half of
D10's trap, and exactly what `tooling/research-coverage`'s `record()` does.

**Why values cannot work, so nobody re-opens it.** This repo's own
`MemAvailable` fact went false because BEAM uptime moved, and uptime is in the
content hash of *nothing the fact names*. No content-hash invalidation can
catch that: the invalidation signal is not in the fact. A stored value is an
assertion with a timestamp on it. The ratified anti-goal — *the ledger is an
INDEX OF HOW TO VERIFY FAST, never a substitute for verification* — stops being
a discipline someone has to remember and becomes a property of the schema.

## Why one file per run

Two writers staggered inside an ~11s window against a single shared JSON file
silently lost one contribution entirely — proven, and D10's reason this store
was blocked. Here the lost-write class is **impossible**, not managed:

- each write creates exactly one new file, named `<run_id>-<digest>.json`;
- the digest is over the file's own bytes, so two writers sharing a `run_id`
  cannot collide, and a colliding path means identical content
  (`ALREADY-RECORDED`, idempotent);
- writes use the `wx` flag — the immutability is enforced by the syscall;
- git merges the directory **add/add clean** across concurrent worktrees.

And this directory is **not gitignored** — verified by the slice's gate, and
deliberately unlike `tooling/research-coverage/research-ledger.json`, which is.
That single line of `.gitignore` is why the same command at the same commit
reported 50.1% in one checkout and 0% in another.

## Rival methods are observed, not decided — and they are the product

There is no write order here, so nothing may be resolved by one. Two **rival**
recipes over one `(subject, quantity)` — different `rerun` commands for the
same property — are **both kept and both flagged** `RIVAL-METHOD` by the fold.
Read the flag as *"this key has more than one cheap check; run them and compare
what they answer now"*. It is the store delivering what it promises, not a
report that something is wrong: rival methods that **agree** are the most
valuable rows here. The same command recorded twice is **corroboration** and is
not flagged; a flag that fires on ordinary repetition gets ignored within a wave.

The flag is deliberately **not** called `CONFLICT`, because `adjudicate.mjs`
already has a `CONFLICT` verdict that fires on the *opposite* input. This fold
fires on ≥2 distinct `rerun` **command strings** and has no value field to
compare at all; `detectConflicts` fires on ≥2 distinct claim **values** and
never reads `rerun`. A 2x2 probe ran all four cells: on `wc -l /abs/path` vs
`wc -l rel/path` (both verified to answer `544`) this fold flags and
`detectConflicts` returns 0; on a genuine 544-vs-999 disagreement
`detectConflicts` returns 2 and this fold sees nothing. One name for two
opposite meanings would send a reviewer hunting a disagreement the firing
mechanism cannot detect.

## Honest-row checks are injected

`admitRecipe(input, { now, screen })` takes two optional bounds. Both exist
because every earlier check was a **shape** check, and a well-shaped forgery
passed all of them — rows dated 2031 and 2087 for commands never executed were
admitted, written and folded back as authoritative.

- **`now`** — an ISO-8601 **UTC** instant. A row whose `observed_at` is later
  is rejected `FUTURE-OBSERVED-AT`. Not read from a clock (see below).
- **`screen`** — `(rerun) => true | false | { ok, message }`. A refused command
  is rejected `REFUSED-COMMAND`; a screen that throws is `SCREEN-FAILED`, never
  an admission. `systemctl stop …` and `rm -rf …` were admissible recipes
  before this, and a recipe is a standing invitation to re-run something often.

Both are **injected, not imported** — nothing here depends on `screen.mjs`. Both
are **optional, and omitting them admits**, so on their own they are a mechanism
rather than a sealed seam; the CLI write verb is what supplies `date -u` and a
screen on every real write. A malformed `now` or a non-function `screen` is
rejected `BAD-OPTION` rather than silently disabling the check it belongs to.

`observed_at` must end in **`Z`** (`OFFSET-OBSERVED-AT` otherwise). Every
ordering here is a string comparison, and that is only true ordering at one
offset — `2026-07-21T02:00:00+02:00` sorts after `2026-07-21T01:00:00Z` while
being an hour earlier. Fractional widths are normalised for the same reason:
raw lexical order puts `…00.001Z` *before* `…00Z`.

## No clock

`ledger.mjs` never calls `Date.now()`, `new Date()` or `Math.random()`.
`observed_at` and `run_id` are required caller-supplied arguments. The workflow
host hard-refuses non-deterministic scripts ("breaks resume", D19), and the
writer of these rows is one phase away from a workflow file — so the module
stays callable from a phase that has no clock at all.

## Use

```bash
node tooling/grip/ledger.mjs fold            # fold this directory to JSON
node tooling/grip/ledger.mjs fold <dir>      # fold another store
node tooling/grip/ledger.mjs --selftest      # prove the controls can fire (exit 3 = a control stayed silent)
node --test tooling/grip/test/ledger.test.mjs
```

```js
import { admitRecipe, writeLedgerRun, foldLedger } from "../grip/ledger.mjs";

writeLedgerRun({ run_id: "wf-0d2d3629", recipes: [row], /* dir defaults here */ });
const { entries, rival_methods, unreadable } = foldLedger();
```

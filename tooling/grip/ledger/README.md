<!-- doc-tier: human -->

# tooling/grip/ledger — the recipe store

Every `*.json` beside this file is **one immutable run file**. Written once,
never modified, never deleted by tooling. The store is read by folding all of
them together: `node tooling/grip/ledger.mjs fold`.

**If you came here to write a row, jump to [How to write a row](#how-to-write-a-row).**
You do not hand-author these files. There is a verb, and this README predated
it long enough that a verifier needed nine independent discovery steps to write
one row through it. Every one of those nine is answered below.

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

## How to write a row

```bash
node tooling/grip/ledger.mjs write <facts.json> [dir]
```

That is the whole write path. There is no other supported way in; hand-editing
a `*.json` here bypasses every honesty bound below and the fold will happily
read your forgery back as authoritative.

**The third positional `dir` is where the run file lands.** Omit it and the
write goes to `DEFAULT_LEDGER_DIR`, which is `fileURLToPath(new URL("./ledger/",
import.meta.url))` — resolved relative to `ledger.mjs`'s **own module location**,
not to your cwd. So from anywhere in this checkout, omitting it is correct and
lands here. Pass `dir` when you are running the module from outside the repo, or
when you want a scratch store you are not committing (every command in this
README was proven against a scratch dir for exactly that reason).

### You must materialise `facts.json` yourself

Nothing writes it for you. Not the workflow host, not `cli.mjs`, not `mint.mjs`.
The file is either a bare JSON array of facts, or `{ "facts": [ … ] }` — both
shapes load, matching `cli.mjs`'s loader exactly. Anything else exits 2 with
`must be a JSON array of facts, or an object with a "facts" array`.

### The fact shape — and the two fields that are DROPPED

A fact carries exactly three keys:

```json
[
  {
    "claim":    "free prose — what you think is true",
    "evidence": "free prose — how you came to think so",
    "rerun":    "grep -c 'export function' tooling/grip/screen.mjs"
  }
]
```

**`claim` and `evidence` are DROPPED by the mint and never reach the store.**
This is not a bug and not a trim you can opt out of. A ledger row's
`RECIPE_FIELDS` is a frozen six-key allowlist — `{subject, quantity, rerun,
derived_level, deps, observed_at}` — and the two schemas share **no field at
all**. Only `rerun` survives, and `subject`/`quantity` are minted **out of the
rerun command**, never out of your prose. Write your `rerun` as if it were the
only thing you were saying, because it is.

Why the command and not the prose: subjects minted from claim prose were
measured perfectly injective over 119 facts — 119 distinct keys for 119 facts,
so the fold's `(subject, quantity)` key could never collide, `RIVAL-METHOD`
could never fire, and nothing in the index was ever a lead to anything else. A
dead index that looks full. The rerun's path token gave 51 keys for the same
119 facts: it **clusters**, which is the entire point of an index.

### `mint` is a REQUIRED intermediate, not an optimisation

Do not try to feed facts to `admitRecipe` directly. Every raw fact
**quadruple-rejects**: `UNKNOWN-FIELD` on `claim`, `UNKNOWN-FIELD` on
`evidence`, `MISSING-SUBJECT`, `MISSING-QUANTITY`. `mint.mjs` is a
**transformer**, never a pass-through. The `write` verb runs it for you — that
is most of what the verb is.

### The write is ALL-OR-NOTHING — prescreen first

One refused row loses the **whole batch**. Nothing is written, including the
rows that passed:

```
REJECTED — nothing was written (all-or-nothing: a file holding only the rows that
happened to pass IS the silent-strip defect at file granularity)
  REFUSED-COMMAND x1
  row 1: REFUSED-COMMAND: "node --test …" was refused by the injected safety screen …
```

That rule is right — a run file holding only the survivors *is* the silent-strip
defect at file granularity — but you should not have to lose a batch to learn
it. So **rehearse the write first**:

```bash
node tooling/grip/ledger.mjs prescreen <facts.json>
```

It mints through the same loader `write` uses, screens every row, prints the
screen's own reason verbatim, and **writes nothing** — no run file, no
directory. It exits `1` exactly when `write` would refuse the file, so a script
can gate on it. A real run over a two-fact file, one good and one refused:

```
$ node tooling/grip/ledger.mjs prescreen /tmp/facts.json
ledger prescreen — /tmp/facts.json
  WRITES NOTHING: this is a rehearsal of `write`, not a partial write (charter D64)

  facts read       2
  mintable         2
  screen admits    1
  screen refuses   1

  ADMIT  [0] tooling/grip/screen.mjs
         $ grep -c 'export function' tooling/grip/screen.mjs
         admitted: within the host bound, allowlisted head and sub-verb, no write shape
  REFUSE [1] tooling/grip/test/screen.test.mjs
         $ node --test tooling/grip/test/screen.test.mjs
         not allowlisted: node executes arbitrary JavaScript (including fs writes)

  `write` WOULD REFUSE THIS FILE and store nothing: 1 of 2 rows are refused,
  and the write is all-or-nothing on purpose. Fix or drop those rows, then re-run prescreen.
```

> **Provenance, because this paragraph was wrong once.** The slice that wrote
> this README measured `prescreen` as NOT EXISTING and said so, correctly: it
> did not exist on the base that slice branched from. It ships in the SAME wave,
> from `tgw3-leads-verb`, and this section was rewritten in review against the
> merged tree with the output above pasted from a real run. The failure mode
> being avoided is the one this whole epic is about — a doc is an L5 claim about
> L2, and quoting a verb across a round boundary is a level-skip in either
> direction.

### `screenCommand` returns `.ok`, NOT `.safe` — and the mistake reads as its own opposite

This is the single most expensive trap on the write path, because it fails in
the direction that looks like diligence. `screenCommand` returns
`{ ok, reason }`. It has no `safe` key. Read `.safe` and you get `undefined`,
which is falsy, so **every row scores refused** — and the `reason` string on an
admitted command still reads `"admitted: …"`, so your own output says the
opposite of your own verdict:

```
r.ok     = true
r.safe   = undefined    <-- the trap
r.reason = admitted: within the host bound, allowlisted head and sub-verb, no write shape
verdict if you read .safe: REFUSED — admitted: within the host bound, allowlisted head and sub-verb, no write shape
```

A careful agent pre-screening its batch this way concludes its commands are all
inadmissible, scores 0 out of 40, and is looking at the word "admitted" while it
does so. The `.safe` key belongs to `rerun.mjs`'s `classifySafety`, a different
module with a different reach — that is why the mistake is available at all.

### The clock is the shell's

`observed_at` is **not** read from your `facts.json`. The CLI reads `date -u`
once and supplies both `observed_at` and the `run_id` (sanitised — `RUN_ID`
rejects the colons in the raw `date` string). Forging a timestamp takes editing
`ledger.mjs`, not editing a payload. Stated honestly: a forger who controls the
caller controls the bound. This stops accidents and staleness, not a determined
forger.

### A real run, end to end

```
$ node tooling/grip/ledger.mjs write /tmp/facts.json /tmp/demo-ledger
ledger write — now 2026-07-21T06:32:08Z (read from `date -u`, never from the input)
  facts read           1
  minted               1
  subject from PATH    1 (100% of minted) ← the coverage number
  subject from cmd:    0 (0% of minted) ← a FLOOR, not coverage; never add these together and call it yield
  distinct subjects    1

wrote  /tmp/demo-ledger/grip-20260721T063208Z-7936031f4366151d.json
  run_id grip-20260721T063208Z — sanitised from the `date -u` stamp; the raw form carries colons and RUN_ID rejects it
  1 rows admitted, 0 rejected
```

Exit codes: `0` written (or `already recorded` — the write is idempotent), `1`
rejected or nothing mintable, `2` usage/IO.

### Your checkout may not have the verb

`write` landed in wave 3. If `node tooling/grip/ledger.mjs write …` prints the
usage line instead of running, you are on a checkout that predates it — that is
an L3-is-a-claim-about-L2 problem, not a bug. Pull.

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
  The screen refuses **every** `node` command, so grip's own `node --test …` and
  `node tooling/grip/ledger.mjs --selftest` recipes can never be stored here.
  That refusal is a reach bound this epic chooses, not a security invariant —
  read the honest statement of it in `../README.md`, "The node refusal".

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
node tooling/grip/ledger.mjs write <facts.json> [dir]   # THE WRITE PATH — see above
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

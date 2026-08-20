# The crown stamp recipe

**Stamping the crown is a scripted operation now. Use `scripts/pds-crown-stamp.sh`.
Do not type a criterion into a shell.**

When the climb greens, twelve criteria get stamped by hand at the end of a long
run. A mangled stamp arriving after a successful climb is unrecoverable in the
moment: the rung is spent, the operator is tired, and the failure mode is a
shell-quoting bug buried in a 2490-character string nobody wants to re-read.

This file is the why. The script is the how.

---

## The one command

```sh
scripts/pds-crown-stamp.sh stamp pds-w1-crown-proof <N> <worker> <epoch> \
  --evidence "…"
```

It fetches criterion `N`'s exact stored wording to a file, prints the remaining
evidence budget, stamps, and then **reads the row back** to prove `met` flipped.
`N` is **zero-based** — the crown's twelve are `0..11`.

Read the table first:

```sh
scripts/pds-crown-stamp.sh census pds-w1-crown-proof
```

---

## Step zero — CLAIM THE CROWN. It is unclaimed, and nothing else says so.

`pds-w1-crown-proof` sits `lifecycle: open`, `claim.worker: null` (released
2026-07-20T04:47:25Z by `reopen-prober`, epoch 15). **A stamp against an
unclaimed task is rejected.** Do this first, before the first criterion:

```sh
bp task claim pds-w1-crown-proof <worker>     # → epoch resets to 1
```

There is no D139 catch-22 to work around: `claim.worker` is already null and
`execution_class` is `executable`, so a plain claim works.

**Measured**, on throwaway `pds-w15-throwaway-a`:

| | command | result |
|---|---|---|
| **unclaimed** | `bp task stamp …` | stderr `bp: not_in_progress:open`, **exit 6** (was `2` before PDS-D371 split the vocabulary) |
| **unclaimed** | the same through this script | **exit 6**, nothing written — `criteria_progress` unchanged |
| **claimed first** | the *identical* script stamp | **exit 0**, read-back `CONFIRMED … now at 2/2` |

### Why this one strands you rather than stopping you

The script's rejection block does not name `not_in_progress:open`. It names
`fenced_off` — labelled *"THE LIKELY ONE"* — and tells you to go re-read the
current epoch. Follow that advice against an unclaimed task and you get `15`
back, re-stamp with `15`, and fail **identically**. The advice is correct for
the failure it was written for and actively misleading for this one. **If the
reason string is `not_in_progress:open`, the epoch is not your problem — the
claim is. Stop reading epochs.**

Since PDS-D371 the exit code says which of the two it is without reading the
message: **6** = the lease/state moved (re-claim, then retry) · **5** = the
payload is wrong (`criteria_mismatch`, `criterion_text_required`, …; retrying it
verbatim can never work) · **2** is now only a genuinely malformed command line.
Canonical mapping: `docs/cli/error-exit-table.md`.

### Claiming is also what re-arms the auto-close (PDS-D140)

The crown has **TWELVE** criteria, `0..11` — not eleven. (PDS-D140's prose is
written in the older 11-criterion numbering; read it as 11/12 and *all twelve*.)
Once the twelfth reads `met`, the cmux Stop hook **closes the task with nobody
typing it**. Claiming is what puts that hook back in the loop, so:

- claim before the first stamp, not after the eleventh;
- never stamp a criterion speculatively ahead of a green rung — the last met-flip
  is a live trigger, not a bookkeeping entry.

---

## Why fetch-to-file, and why for all twelve

Both halves of this were proven live before the script existed.

| | what was done | what happened |
|---|---|---|
| **Control** | criterion 6 pasted **inline** into a double-quoted string | backticks ran as command substitution → server rejected `criteria_mismatch`, **exit 5** (`2` when this was measured, pre-PDS-D371), **nothing written** |
| **Recipe** | identical 2490 chars via `--criterion-text "$(cat c6.txt)"` | **exit 0**, clean stamp |

Re-proven in this slice against a disposable scratch task carrying text of
comparable length and character mix (1145 chars, 24 backticks, 21 single
quotes): inline → rejected, `EXIT=2` as measured then (a `criteria_mismatch`
exits `5` since PDS-D371), `criteria_progress` unchanged at `0/3`.
The same text through the script → `EXIT=0`, read-back `CONFIRMED`.

### The law is uniform fetch-to-file for all twelve (PDS-D226)

No per-criterion judgement. That is the whole point.

```
  N  met     chars  btick  quote    budget  hazard
  5  yes       846      0      6      8985  single quotes (6)
  6  no       2490      8     16      7197  BACKTICKS (8) + quotes (16)
 11  no       1248      0      1      8580  single quotes (1)     ← the dangerous one
```

Criterion 6 is the only one unsafe in a double-quoted string, and it fails
**loudly**. Criterion 11 is the one that will actually bite you:

- it carries **exactly one single quote in 1248 characters** — invisible on inspection;
- it is stamped **last and alone**, at maximum fatigue;
- its met-flip **removes the final brake** on the cmux Stop-hook auto-close.

The uniform law exists precisely so nobody eyeballs c11, sees no backticks,
concludes "this one is fine", and types it inline.

### A signal you cannot trust

`command` is a **zsh builtin**. Of criterion 6's four backtick pairs, only three
emit `command not found` — the fourth mangles **silently**.

In this slice's control it was worse: all four backtick payloads existed, so zsh
printed **nothing at all** to stderr while mangling 24 backticks. And an earlier
draft of that control, whose backticks happened to contain `mix run --no-start`,
**started a real Elixir compile**. Inline paste does not merely mangle text — it
executes it.

**The shell's stderr is not a mangling detector. The only reliable signal is the
server's `criteria_mismatch`.** The script never treats a quiet shell as a clean
stamp; it reads the row back.

### Never a here-doc, never an echo

Both put the shell back on the byte path. A here-doc also appends a trailing
newline that command substitution then strips.

The recipe is safe today only because **0 of the 12 criteria carry trailing
whitespace** — safe by luck of the data, not by construction. The script closes
that: `criterion_to_file()` writes the raw JSON field byte-for-byte and
**refuses** if the stored text ends in a newline, the one shape `$(cat …)` would
quietly alter. Luck becomes a checked precondition.

---

## The URL ceiling is a non-risk

Said out loud rather than guarded heavily.

The circulated **"8900–9002 bytes" figure is wrong.** Re-derived by bisection to
a single byte, 3/3 reproducible each side: total request target **10016 OK /
10017 FAIL** — a *total*-bytes limit, not per-parameter. The mechanism is
Bandit's unconfigured `max_request_line_length` default of 10000:

```
"POST " + target + " HTTP/1.1" + CRLF  =  5 + 9984 + 9 + 2 = 10000
```

Over `--http1.1` direct to `:4000` with Caddy bypassed, the same byte returns a
legible `414`.

> **Durable law: request target ≤ 9984 bytes.**

Per-criterion evidence budgets run **7197** (c6, tightest) to **9759** (c3). A
proven c6 stamp spent **69** of its 7197. You are not going to hit this.

Worker and epoch ride the **body**, not the URL, and cost budget nothing.

The budget is **measured, never modelled**: the script asks `bp task stamp
--dry-run` for the exact request line it would send and counts the bytes of its
target. It does not reimplement the CLI's percent-encoder, so it cannot drift
from it. Demonstrated at the boundary — budget 8625, evidence of exactly 8625
gives `headroom after this stamp: 0 bytes`; 8626 gives:

```
REFUSED: evidence overruns the request-target ceiling by 1 bytes.
Nothing was sent. The server is fail-closed here — an oversized stamp writes NOTHING —
so the recovery is simply: shorten the evidence and re-run. Never a half-write to reconcile.
```

An oversized stamp is fail-closed server-side (a 9000-byte sentinel wrote
nothing), so recovery is always *retry shorter*, never *reconcile a half-write*.

---

## Re-stamping a criterion that ALREADY reads met

Nine of the crown's twelve (`0,1,2,3,4,5,7,8,9`) already read `met: true`, and
`pds-w14-crown-collect-stamp` orders criterion 0 **re-evidenced** because its
stored evidence is stale in substance. Every rehearsal before this one only ever
flipped `false → true`, so `true → true` was unmeasured.

**Measured: it LANDS. The evidence field is overwritten. There is no silent
no-op and no error, so no workaround is needed.**

| | before | after |
|---|---|---|
| draft `pds-w15-throwaway-a` c1 | `met=True`, `'STALE-EVIDENCE-ORIGINAL-do-not-keep'` | exit 0, new rev `28cf73bf` → `'CASE2-NEW-EVIDENCE-should-replace-the-stale-one'` |
| **published** `pds-w15-throwaway-b` c0 | `met=True`, `'STALE-B-ORIGINAL-do-not-keep'` | exit 0 → `'CASE2b-NEW-EVIDENCE-published-shape'` |

The published case matters because the crown is published and boards read the
published ledger. `GET /v1/data/query/production/task` returned the new evidence
with `_draft: false` and **no re-publish step**. Stamping writes through.

### But the read-back does not prove it. Diff the evidence yourself.

The script confirms on `met == true` (`pds-crown-stamp.sh:408`). On a `met → met`
re-stamp that was **already true before the write**, so `CONFIRMED: criterion N
reads met` would print identically whether the evidence landed or was dropped on
the floor. It is a true statement that answers the wrong question.

For any criterion already reading `met`, verify the **string**, not the flag:

```sh
N=0   # the criterion you just re-stamped
bp task get pds-w1-crown-proof -o json 2>/dev/null | python3 -c '
import json,sys
print(repr(json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"][int(sys.argv[1])]["evidence"]))' "$N"
```

Run it **before** the re-stamp too, and compare the two strings. A single after-read
tells you what is stored, not that your write is what put it there — and on a
`met → met` re-stamp those are exactly the two things worth separating.

(The document `rev` changing is a second, weaker signal — weaker because a
concurrent pulse also moves it.)

---

## Before you collect: drop stray control databases

`scripts/pds-secret-scan.sh control` creates `pds_secret_scan_ctl_$$` and drops
it from a `trap cleanup EXIT` (`:469`). A trap does not run on `SIGKILL`, and
`--keep` skips the drop deliberately, so a control killed mid-run leaves the
database behind. One is harmless; PDS-D250 expects the climb to be **re-armed
repeatedly**, and they accumulate.

Check and drop on the collect path:

The suffix **is** the owning process's PID, so the liveness check is `ps -p` and the
snippet does it for you rather than trusting you to remember. Dropping a database out
from under a live control turns a clean rung 4 into an unattributable failure:

```sh
psql postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname LIKE 'pds_secret_scan_ctl_%'" \
| while read -r db; do
    [ -n "$db" ] || continue
    pid="${db##*_}"
    if ps -p "$pid" >/dev/null 2>&1; then
      echo "SKIP $db — pid $pid is LIVE (a control is running; wait it out)"
    else
      psql postgres -q -c "DROP DATABASE IF EXISTS \"$db\"" && echo "dropped $db"
    fi
  done
```

Empty output is the healthy state. `ps -p`, never `pgrep` (PDS-D135). Note the PID
space wraps in ~15–20 minutes on this host, so a `SKIP` on a very old stray can be a
false positive — re-run later rather than forcing it, since the cost of one leftover
database is nil and the cost of dropping a live one is a burnt export attempt.

---

## Rehearsing

Rehearse against a **disposable scratch task**, never against
`pds-w1-crown-proof`. Stamping works on an **unpublished draft**, so the publish
wall is not a prerequisite — this slice's scratch target read `status: draft`
throughout and stamped fine.

```sh
bp doc create task --yes --set _id=<scratch-id> … --set "acceptance_criteria:=$(cat ac.json)"
bp task claim <scratch-id> rehearsal-worker
scripts/pds-crown-stamp.sh stamp <scratch-id> 0 rehearsal-worker 1 --evidence "rehearsal"
bp doc delete task <scratch-id> --yes
bp task get <scratch-id>            # must be not_found
```

Delete it afterwards and prove it gone. `pds-w1-crown-proof` stays **read-only**
throughout — `census` and `budget` only ever issue `bp task get` and `--dry-run`,
neither of which writes.

---

## Exit status

| code | meaning |
|---|---|
| `0` | the stamp landed **and** the read-back confirms `met: true` |
| `1` | refused locally **before any write** — budget, trailing newline, bad index |
| `2` | the operation failed — network, auth, or server rejection (nothing written) |

A `2` on a stamp means nothing was written. **Do not retype the criterion
inline** to "work around" it — re-run the script. The file path is the fix.

### Reading a `2`: the reason string tells you which fix applies

The script prints two candidate causes. There are three, and picking the wrong
one costs you the night. **Read the `bp:` line above the block, not the block.**

| reason string | what is actually wrong | the fix |
|---|---|---|
| `not_in_progress:open` | the task is **unclaimed** — the epoch is irrelevant | `bp task claim <task> <worker>`, then re-run with the epoch it returns. **This is the crown's state today.** |
| `fenced_off` | your epoch is stale — a `pulse` bumped it | re-read the current epoch and pass that. Re-read after **every** pulse. |
| `criteria_mismatch` | the text sent did not match the stored row | re-run the script; never retype inline |

Chasing epochs on a `not_in_progress:open` is an infinite loop: every re-read
returns the same number and every re-stamp fails the same way.

---

## Two defects the gate caught, kept as warnings

Both were found by `bash -n` / `shellcheck -S warning` on this very script, and
both are the kind that survive a casual read:

1. **A literal backtick inside a heredoc nested in `$(…)`** passes `shellcheck`
   but **fails `bash -n`** with `unexpected EOF while looking for matching`.
   Bash's command-substitution parser still scans the heredoc body for a closing
   backtick. Spelled `chr(96)` in the Python now. A script about quoting hazards
   does not get to have one.
2. **A per-function `trap … RETURN`** stays armed after the function returns, so
   the next return re-fires it against an out-of-scope `$tmp` and, under
   `set -u`, prints `tmp: unbound variable` **on an otherwise successful run**.
   Replaced with one `PDS_SCRATCH` directory and a single `EXIT` trap.

Gate:

```sh
bash -n scripts/pds-crown-stamp.sh && shellcheck -S warning scripts/pds-crown-stamp.sh
```

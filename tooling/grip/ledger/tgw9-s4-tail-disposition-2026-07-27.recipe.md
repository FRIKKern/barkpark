# Recipe — wave-10 tail disposition: the blocking-set lens, the close-by-content adjudications, the prune

Builder: `tgw9-s4-tail-disposition` (truth-grip wave 10, 2026-07-27).
Baseline at run time: `origin/main = 3f55de3f1` (`fix(astro-search): the open row highlights…` #6345).
Sample instants are NAMED, never carried: the ready pool moved **864 → 810** across this run.

Every recipe below is a re-DERIVATION, not a citation. The row exists so the next reader spends
minutes, not a wave — it is an index of how to verify fast, never a substitute for verifying.

## R1 — the blocking set (D110's two-lens rule, executed)

```
# 1. offset-walk the pool; never trust --all's silent 1000-row cap
bp task ready --limit 500 --offset 0  -o json
bp task ready --limit 500 --offset 500 -o json          # walk until a short page
# 2. build the transitive parent_id closure from the FULL task index
bp task ls --limit 500 --offset <0,500,…> -o json       # 3,322 rows on this date
# 3. BLOCKING = closure(truth-grip-epic) minus the root, INTERSECTED with the walked pool
```

Measured 2026-07-27T14:46:03Z→14:46:57Z: `--all` 864 == walk 864 (500+364) == dedupe-on-`doc_id` 864;
published-only **849** (15 drafts sit in the live pool — D110's hazard, reproduced). Closure **146**
= 1 root + 129 depth-1 + 16 depth-2. **BLOCKING = 86.** The id-prefix lens saw **85** and missed
`task-a965c4fbfe3710f5`; the closure-invisible prefix set was empty. Two traps worth keeping:

- `bp task ready` rows carry **no `status` field** — publishedness must be joined from `task ls`,
  or a naive `status == "published"` filter silently returns ZERO and the intersection reads empty.
- `bp task get <id>` prints `help:` lines AFTER the JSON. Parse the last line starting with `{`,
  and read the **state back**, never the exit code — six stamps in this slice reported "FAILED"
  from a mis-parse while every one of them had landed.

## R2 — close-by-content, adjudicated by RUNNING origin/main's own modules

`git log --oneline` proves nothing about content (squash-merge erases ancestry, D40). Run the module:

```
node -e "import('./tooling/grip/screen.mjs').then(m=>console.log(m.screenCommand('git log --output=/tmp/x -1')))"
node -e "import('./tooling/grip/rerun.mjs').then(m=>console.log(m.classifySafety('grep -n \"a > b\" f')))"
```

| claim under test | re-derived verdict on `origin/main` |
|---|---|
| `tgw9-s6` finding 1 — `git --output` write | REFUSED, both spellings ("WRITES git's output to a file rather than stdout") |
| `tgw9-s6` finding 2 — go write flags | REFUSED by flag name: `go test -coverprofile=/tmp/x`, `go test -c` |
| `tgw9-s6` finding 3 — probeHttp shell string | argv form (`spawnArgv` + curl vector), `rerun.mjs:414`; landed `8e3c9fbb7` (#5350) |
| quote-blindness (`0f3a881b5`, #4983) | `grep -n "a > b" f` → `{safe:true}`; `sh -c "rm -rf /tmp/y"` → `{safe:false}` |
| the "stale 240" comment | `screen.mjs:41-46` is a LABELLED delta; `screen.test.mjs:631-632` pin 240→254, `:648` asserts it |

All five closed. **The one that did NOT close is the reason this recipe exists.**

## R3 — the near-miss: a close-by-content that would have laundered a live hole

`tgw4-screen-git-global-option-audit` looked closed by content — `rerun.mjs` now refuses all three
shapes the row reproduced:

```
node -e "import('./tooling/grip/rerun.mjs').then(m=>['git -C /tmp/repo push origin main',
 'git -C /tmp/repo commit -m x','git --no-pager reset --hard origin/main']
 .forEach(c=>console.log(c,m.classifySafety(c))))"      # all three: write-shaped verb: git write verb
```

Then the same question was put to the OTHER gate, and it answered the opposite way:

```
node -e "import('./tooling/grip/screen.mjs').then(m=>['git -C log push origin main',
 'git -C show commit -m x','git --git-dir log push','git -c log=1 push origin main']
 .forEach(c=>console.log(c,m.screenCommand(c).reason)))"
```

- `git -C log push origin main` → **ADMITTED** ("allowlisted head and sub-verb, no write shape")
- `git -C show commit -m x` → **ADMITTED**
- `git --git-dir log push` → **ADMITTED**
- `git -c log=1 push origin main` → refused (`sub-verb "log=1"` not allowlisted)

The global option's **value** is read as the sub-verb; when that value collides with the read-only
allowlist, the write verb behind it is never examined. New specimen, filed on the row, which stays
**open**. Two gates, one command, opposite rulings — the same shape
`tgw9-bl-prescreen-adjudicate-disagree` and `tgw10-bl-screencommand-bypass-census` already name.

**The rule this row exists to record: a close-by-content is only as wide as the module you ran.
Run every gate that guards the capability, not the first one that agrees with you.**

INDEPENDENTLY RE-DERIVED AT REVIEW (2026-07-27, wave-10 reviewer, this worktree, not a re-read of
the above): `screenCommand('git -C log push origin main')` → `ok=true`, reason `admitted: within the
host bound, allowlisted head and sub-verb, no write shape`; same for `git --git-dir log push`;
`git -c log=1 push origin main` → refused on `sub-verb "log=1"`. The hole is real and the refusal to
close the row is correct.

## R4 — evidence that has DECAYED (do not close on it)

`tgw9-bl-d28-verify-floor-has-fired` cites a run record for "the VERIFY fan-out floor has fired":

```
ls -d .claude/worktrees/e2-review-w17/.claude          # -> no `subagents` directory
find .claude/worktrees/e2-review-w17 -name 'wf_5fb8ba2e*'   # -> nothing
```

The record is gone. `tgw2-bl-throw-liveness-observation` was one step from closing on it and did
NOT: it is parked with the decay recorded, and D28 may not be amended until the firing is
re-observed. Also beware the false zero — a wide `grep -r … .claude 2>/dev/null` under a `timeout`
returns silence when it is KILLED, not when it finds nothing. Control every wide sweep with a
string you know is present.

## R5 — prune safety, re-derived AT prune time (TWO-dot only)

A three-dot diff manufactures phantom insertions; use `..` everywhere.

```
git show origin/main:.claude/workflows/bp-truth-grip-charter.md \
  | grep -oE '^- \*\*D[0-9]+' | grep -oE 'D[0-9]+' | sort -u > /tmp/main_d.txt
for b in docs/truth-grip-wave-8 docs/truth-grip-wave-8-charter-r tgw2-charter-amendment \
         truth-grip/wave5-decide truth-grip/wave6-decide-charter tgw4-round0-land; do
  git show origin/$b:.claude/workflows/bp-truth-grip-charter.md \
    | grep -oE '^- \*\*D[0-9]+' | grep -oE 'D[0-9]+' | sort -u > /tmp/br_d.txt
  echo -n "$b decisions-missing-from-main: "; comm -13 /tmp/main_d.txt /tmp/br_d.txt | tr '\n' ' '; echo "[END]"
  git ls-tree -r --name-only origin/$b tooling/grip | sort > /tmp/br_grip.txt   # and tooling/grip/ledger
  comm -13 <(git ls-tree -r --name-only origin/main tooling/grip | sort) /tmp/br_grip.txt
  gh pr list --state open --limit 300 --json headRefName | grep "$b"            # must be empty
done
```

2026-07-27 result: main carries **120** decisions; `comm -13` is **EMPTY for all six** (branch
decision counts 92 / 92 / 28 / 72 / 83 / 55); no branch carries a `tooling/grip` or
`tooling/grip/ledger` file main lacks; **zero** of the 12 open PRs has any of the six as its head.
`tgw4-round0-land` specifically: `level.mjs`, `test/level.test.mjs` and `test/inloop-gate.test.mjs`
are byte-identical blobs (`git rev-parse origin/main:<path> origin/tgw4-round0-land:<path>` →
`32f54601b…`, `9b7248727…`, `61c398c9c…`), and its only branch-unique symbol `normaliseCurlArgv`
(branch `screen.mjs:322`) is on main at `screen.mjs:479`, generalised into `normaliseArgv` (`:437`).
Deleted with `git push origin --delete`; `git ls-remote origin refs/heads/<each>` now returns
nothing. **The head SHAs are recorded here so the deletion is reversible** (`git push origin
<sha>:refs/heads/<name>` from any clone that still has the object):

| ref (deleted) | head |
|---|---|
| `docs/truth-grip-wave-8` | `4969d2ff6801dd33f7791885bf55049a4129e89b` |
| `docs/truth-grip-wave-8-charter-r` | `85eebd1d279283afe773ba996e9b6363a0d6deb4` |
| `tgw2-charter-amendment` | `70b9ef34ba3a2ea8ff8fbdf4fc2c67b6f62d2c2a` |
| `tgw4-round0-land` | `eaca91ecbb14e1a2ae4e0cb3ff85724da33ad6ff` |
| `truth-grip/wave5-decide` | `c2935ecc5dda2ed00054cd1bd943695196410012` |
| `truth-grip/wave6-decide-charter` | `6fb2f2552016717938cb49753080732b9a6da17a` |

`git worktree prune` was NOT run (D119) and `git worktree list | wc -l` = **1454** before and after.

## R6 — the disposition itself, and how to re-derive the drop

86 rows read one at a time → **10 closed** (each `close_reason` names the commit, charter line or
live probe), **45 parked** `considering`, **26 left open** as demoted children under D117 (each patched with
`disposition` / `disposition_owner` / `disposition_reason`, then republished), **5 live wave-10
slices untouched**. Mechanics worth keeping:

```
bp task stage <id> considering --note "…" --worker <w> --object research --yes   # park (reversible)
bp task close <id> <worker> <epoch> cancelled "<reason>" --yes                   # claim first
bp task close task-a965c4fbfe3710f5 <any-worker> 2 done "…" --set observed_rev=<rev> --yes
bp doc patch task <id> --set disposition_owner=… --yes && bp doc publish task <id> --yes
```

- `bp doc patch` writes a **DRAFT** and answers `{"results":[…],"transactionId":…}` with **no `ok`
  key** — treating a missing `ok` as failure leaves an unpublished draft, and drafts DO appear in
  the ready pool. Always follow with `doc publish`, then re-read the published row.
- A TTL-reaped claim fences on the **epoch** with a null worker: close with `observed_epoch=2` and
  any worker id, and pin `observed_rev` or the work-digest guard 409s.
- `in_progress → considering` is refused; release the claim first.
- The server was mid-deploy for part of this run (`Back in a moment` HTML, then `500`s). Every
  mutation loop needs retry-on-transient **and** an idempotent skip that re-reads state first.

## R7 — CORRECTION, added at review (2026-07-27): the 45 park REASONS did not persist

The row above originally claimed each parked task carried "a row-specific reason plus a named
REACTIVATE trigger" in `content.engagement.note`. **Re-derived at review, that is false.** Of the 46
`considering` rows in the namespace, **0 carry a note**:

```
bp task ls --all -o json                       # filter lifecycle_status == "considering"
bp task get <id> -o json                       # read content.engagement.note on each
# 2026-07-27 result: 46 considering, 43 read clean + 2 parse-fails, 0 with a non-empty note
```

The mechanism is NOT broken — it was not used. A control proves it:

```
bp task stage tgw2-bl-throw-liveness-observation considering --object research \
  --worker wave10-reviewer --note "…" --yes
bp task get tgw2-bl-throw-liveness-observation -o json   # content.engagement.note is there, verbatim
```

So the parks are real and reversible (`bp task stage <id> open`), but **44 of the 45 justifications
exist nowhere durable** — the disposition survived and its reasoning did not. That is this epic's own
disease inside this epic's own disposition row: a claim stored at the author's word, refuted the
first time a program went and looked. The one recoverable reason (`tgw2-bl-throw-liveness-observation`,
recoverable only because §R4 wrote it down here) was restored at review. The rest are re-adjudication
work, filed as `tgw10-bl-park-reasons-not-durable`.

**BEFORE 86 (14:46Z) → AFTER 32 (15:18Z).** Attribution is exact: 86 − 10 − 45 = 31 survivors, all
31 present, plus exactly one row a sibling slice filed mid-run
(`tgw9-bl-class-coverage-hyphen-blind-spot`). Gate: `pool 810 ns 33 ns_minus_root 32`, zero drafts
in the namespace. Re-derive the whole census with R1 — never quote these numbers.

## R8 — CORRECTION to R7, added 2026-09-02: R7's own CONTROL named a field that has no writer

R7 above is right that the 45 park reasons did not persist, and wrong about why. Both of its
commands read `content.engagement.note`, and its control asserts — verbatim —

> `bp task get tgw2-bl-throw-liveness-observation -o json   # content.engagement.note is there, verbatim`

**That sentence is false, and was false when it was written.** `bp task stage --note` has never
written `content.engagement.note`. It writes `content.disposition_reason`, and `task.staged` carries
the key it used as `staged.note_key`. `content.engagement` is an EPHEMERAL LEASE —
`{object, holder, ts, lapse_ttl_seconds, lapses_at}`, no `note` member — that `Tasks.TtlSweeper`
deletes WHOLESALE past `task_engagement_ttl_seconds` (900 s).

So R7's census was a **pass-shaped absence**: reading a key nothing writes returns 0 on every row,
whether or not a reason was ever recorded. "0 of 46 carry a note" could not have come out any other
way. The observation was correct; the diagnosis attributed a real gap to the wrong mechanism, and
then offered a control that certified the wrong mechanism as working.

Re-derive it against the durable key instead:

```
bp task get <id> -o json     # read content.disposition_reason  (durable; no sweeper owns it)
                             # content.engagement is a lease and has no note member at all
```

The gap R7 measured is nonetheless real and was paid: the 40 `considering` children of
`truth-grip-epic` were re-adjudicated under `tgw10-bl-park-reasons-not-durable`, each carrying a
reason on `content.disposition_reason` plus a `reopen_trigger`, and the row now reads 36 considering
against 164 children with a control re-read on `tgw2-bl-throw-liveness-observation` showing
`content.engagement` null and the reason present in full.

The trap generalises past this file, which is why it is written here rather than only on the row: a
criterion that measures a field NOTHING WRITES cannot fail, so it reads as a clean pass and hides the
thing it was written to catch. Filed as `task-650b487285603d2d`; the durable/ephemeral split itself is
`PDS-D306`, and the contract now states it in
[docs/contracts/task-claim-lifecycle.md](../../../docs/contracts/task-claim-lifecycle.md) under the
`Stage` verb. This ledger is append-only: R7 stays exactly as written, and this row supersedes it.

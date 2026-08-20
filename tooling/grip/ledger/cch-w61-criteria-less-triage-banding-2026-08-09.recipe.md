# cch-w61 — the 38 criteria-less rows: banding, re-derivation recipe (2026-08-09)

Verifier lane `criteria-less-triage-banding`. Every number below is re-derivable by the
command printed beside it. Nothing here was read off a prior wave's prose.

## 0. The population (exact, and the two ways to slip it)

```sh
bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
# the 38:
jq -r '[.children[]|select(.lifecycle_status=="open" and ((.criteria_progress.total//0)==0))]|length' /tmp/epic.json
# => 38
# the 44 (do NOT quote this as the triage population):
jq -r '[.children[]|select((.criteria_progress.total//0)==0)]|group_by(.lifecycle_status)|map({s:.[0].lifecycle_status,n:length})' /tmp/epic.json
# => cancelled 5, done 1, open 38
# roster at first read:
jq -r '[.children[]]|group_by(.lifecycle_status)|map({s:.[0].lifecycle_status,n:length})' /tmp/epic.json
# => cancelled 61, considering 1, done 341, open 426  (child_count 829)
```

## 1. The field name trap

There is **no** `description` field on a task doc. `jq '.doc.description'` returns `null`
for all 38. The authored body is `.doc.content.description` (619–2607 chars, all 38
non-empty) and the structured body is `.doc.content.brief.blocks`.

```sh
bp task get <id> -o json | jq -r '(.doc.content.description//"")|length'
```

A triage pass that reads `.doc.description` will measure every row as empty and
conclude all 38 are wishes. That is the destructive failure mode.

## 2. The brief's four-move shape is NOT there

```sh
while read id; do grep -l "THE FIX (one of)" rows/"$id".json; done < ids38.txt | wc -l
# => 1     (not 37)
while read id; do grep -l "THE FIX" rows/"$id".json; done < ids38.txt | wc -l
# => 5
```
Only `cch-w56-bl-exclusions-are-overwritten-not-merged` carries the literal
`THE FIX (one of)`. 4 rows carry an `(a)`/`(b)` option pair. 14 mention a remedy word.
Specificity instead comes from file paths: **31 of 38** name at least one source file,
**14** name a `file:line`, **6** name no file at all.

## 3. Coin flip A — modal-oracle: nothing invokes it (row is LIVE, not shipped)

```sh
D=$(mktemp -d) && git archive origin/main | tar -x -C $D && cd $D
~/.nvm/versions/node/v20.20.2/bin/node --test cloud/priv/static/__app.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)'
# tests 1020 / pass 1020 / fail 0
mv cloud/priv/static/__preview__/modal-oracle.mjs /tmp/mo.bak
~/.nvm/versions/node/v20.20.2/bin/node --test cloud/priv/static/__app.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)'
# tests 1020 / pass 1020 / fail 0   ← IDENTICAL: the harness does not invoke it
grep -rn "modal-oracle" .github/ scripts/ Makefile --include=package.json .
# => no invocation anywhere; every non-self hit is a PROSE COMMENT
```
Verdict: the finding is TRUE and unpaid. Do **not** close it as shipped. It is however a
**duplicate** — `cch-w22-s1-residue-modal-oracle-uninvoked` (open, 5 criteria) and
`cch-w13-bl-overflow-guard-and-modal-oracle-ungated` (open, 3) already carry it under
`cch-instruments-epic`, and `cchi-w20-bl-modal-oracle-runs-nowhere` was already cancelled
as a forward. Cancel-as-duplicate with a pointer: nets cch −1, destroys nothing.

## 4. Coin flip B — the wave-57 exclusions arm covers the paths-filtered case IN FULL

The suite refuses to run on a `git archive` extract (it needs a git object database), so
run it from a worktree:

```sh
git worktree add --detach /tmp/wt origin/main && cd /tmp/wt
bash scripts/required-checks.test.sh
```
Section **14b** passes 11/11, including the two decisive lines:
- `…and EVERY committed exclusion context survives, 'gofmt drift ceiling (blocking)' included (26 in, 26 out)`
- `…and without it the IDENTICAL run drops the seeded row and emits 18 of 26 (mutation-proven able to fail)`

Mechanism: `required-checks-generate.sh:569` reads `committed_excluded` base-first, and the
loss loop at `:882-912` iterates the **committed** set, not stage 2's intersection — so a
paths-filtered name that never entered the intersection is still named `LOST` and exits 1.
Union emit at `:1034`. The row's second claim is answered by construction.
Verdict: **fully** superseded, not "in part". Closable.

Side finding from the same run: `required-checks: 180 passed, 1 failed` on origin/main
(`c2de1e51c`) — `merge-gates.md` and the workflows disagree: `MISSING Compose smoke`.
That is a live red on main, unrelated to this lane, and unfiled.

## 5. Coin flip C — task-ed706f4e1c616f89 IS shipped

```sh
grep -n 'outranked\|cannot_grant_higher_role' cloud/priv/static/app.js
# 292:  outranked: "You can only act on members whose role is below your own, …"
# 293:  cannot_grant_higher_role: "You can't grant a role above your own — …"
grep -c 'outranked\|cannot_grant_higher_role' cloud/priv/static/__app.test.mjs   # => 21
```
Both sentences authored, 21 test mentions. Closable as done.

## 6. Standing Law 0 is the real lever, and it costs no findings

Charter `.claude/workflows/bp-cloud-console-hardening-charter.md:29-31`:
*"every gate, generator, harness, required-checks or ledger-hygiene row belongs to
`cch-instruments-epic` … file with `parent_id: cch-instruments-epic` AT CREATE TIME
(a create, never a re-parent)."*

Banding the 38 by the files each row's body names:
- **16 rows are instrument / ledger-hygiene**, i.e. not this epic's by law. Because the law
  forbids re-parenting, the compliant move is cancel-here + create-there.
- **~20 rows are console-surface** and are the ones whose criteria are transcribable from
  the authored body.
- **2 rows close outright** (§4, §5).

Net on cch's open count: **−18 with zero findings destroyed**. Authoring criteria on the
~20 survivors does not change the count.

## 7. The durable finding: the regression is dated, and it already stopped

```sh
jq -r '[.children[]|select(.lifecycle_status=="open")]|group_by(.inserted_at[0:10])
  |map({d:.[0].inserted_at[0:10],open:length,nocrit:([.[]|select((.criteria_progress.total//0)==0)]|length)})
  |.[]|[.d,.open,.nocrit]|@tsv' /tmp/epic.json
```
```
2026-08-05  open=27   nocrit=0
2026-08-06  open=51   nocrit=3
2026-08-07  open=151  nocrit=29
2026-08-08  open=80   nocrit=6
2026-08-09  open=45   nocrit=0
```
**Zero** criteria-less open rows exist before 2026-08-06, and **zero** on 2026-08-09.
33 of the 38 carry the `-bl-` slug. So this is a bounded three-day authoring regression in
the backlog-filing step — and it is **not currently reproducing**. A builder told to "fix
it upstream" must first re-derive whether the bug still exists; today's 45 rows say it does
not, and building a guard against a bug that stopped reproducing is the epic's own thesis
violation. The honest instrument is a *census* that reds if any future published row lands
with zero criteria, not a fix to a filing step that is currently behaving.

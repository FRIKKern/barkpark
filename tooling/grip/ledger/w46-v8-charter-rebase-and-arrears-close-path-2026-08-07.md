# w46-v8 — charter rebase (#10256) and the lapsed-claim close path

Re-derivation recipes. Every row was RUN, not read. `origin/main` at time of run = `77cf2060cf5e69c13da2837c678ae6e9ea47d7e6`
(the briefed `0cb4300a4` was already stale — main moved during the wave).

## 1. The conflict is real and is exactly two hunks

```
git fetch origin
git merge-tree --write-tree --name-only origin/main \
  origin/epic-charter/cloud-console-hardening-w45-20260807T104544Z; echo "RC=$?"
```
→ `RC=1`, `CONFLICT (content): Merge conflict in .claude/workflows/bp-cloud-console-hardening-charter.md`.
Only that one path conflicts; the nine `tooling/grip/ledger/cch-w45-*` files merge clean.

Reconstruct the three stages and see the markers without touching the repo:

```
git merge-tree --write-tree --name-only origin/main origin/epic-charter/cloud-console-hardening-w45-20260807T104544Z
# prints the three-stage table: 1=base 2=ours(main) 3=theirs(w45)
git cat-file -p 0b5837285473e8a0dc9207b927e09e2f484b34f5 > base.md      # stage 1
git cat-file -p a01f1e225f54a928cd1c2f71cae7d99eff0c8fab > ours-main.md # stage 2
git cat-file -p 4117640c1e6b631c69738d8c9a68f5a23ab56255 > theirs-w45.md# stage 3
cp ours-main.md merged.md
git merge-file -L main -L base -L w45 merged.md base.md theirs-w45.md   # rc 2
grep -n '<<<<<<<\|^=======$\|>>>>>>>' merged.md
```
→ hunk 1 at the decision table (`main` D492–D498 vs `w45` D499–D510);
  hunk 2 at `## Wave log` (`main` wave-44 block vs `w45` wave-45 block).

## 2. HUNK 2 IS NOT A CLEAN APPEND — the w45 branch CLOBBERED the wave-43 heading

This is the row that matters. A naive keep-both ships a content regression to main.

```
git show f2e47c733 -- .claude/workflows/bp-cloud-console-hardening-charter.md \
  | grep -n '^[-+]### \|^[-+] (3/3'
```
→
```
-### 2026-08-07 — wave 43 REVIEW (3/3 round-1 slices built, … — grade A)
+### 2026-08-07 — wave 45 REVIEW (4/4 round-1 slices built, … — grade A)
+ (3/3 round-1 slices built, gated, reviewed, PUSHED and PR'd; 3 round-2 slices deferred … — grade A)
```
The wave-45 review commit **overwrote** the wave-43 `###` heading line and re-emitted its tail as a
headless fragment. Wave 43's BODY survives; its heading does not. Confirm by enumeration:

```
awk '/^## Wave log/,0' theirs-w45.md | grep '^### ' | head -3
```
→ wave 45, then **wave 42** — wave 43's heading is gone from the w45 side entirely.
`grep -n '^ (3/3 round-1 slices' theirs-w45.md` → `2211:` the orphan fragment.

**RESOLUTION RULE.** Keep-both, but hunk 2 must RESTORE the wave-43 heading (take it from `main`/base,
which both still carry it) and DROP the headless fragment. Correct final order: 45 → 44 → 43 → 42 → 41 → 40.

## 3. The now-false sentence to strike

w45's wave-45 entry, item 4 under "WHAT THE NEXT WAVE MUST KNOW":
`4. **The wave-44 log entry is missing from this charter.** Wave 45's is the first entry above wave 43's. …`
It is false the moment wave 44's block (already on main) sits above wave 43. Strike all three lines.

## 4. Lossless-resolution proof

```
comm -23 <(sort -u ours-main.md) <(sort -u resolved.md) | grep -c .   # → 0  (nothing lost from main)
comm -23 <(sort -u theirs-w45.md) <(sort -u resolved.md)              # → exactly 4 lines:
                                                                      #   the 3-line false item 4 + the headless fragment
grep -c '<<<<<<<\|>>>>>>>\|^=======$' resolved.md                     # → 0
grep -o '^| D[45][0-9][0-9] ' resolved.md | tr -d '| '                # → D480…D510 contiguous, no gap, no dupe
```

## 5. D499–D510 are ABSENT from main (no D-number above D498 is citable)

```
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
  | grep -oE '^\| D(49[0-9]|5[0-9][0-9]) '
```
→ `D490 D491 D492 D493 D494 D495 D496 D497 D498` and stops. Per-row counts on main:
`D499=0 D501=0 D504=0 D505=0 D508=0 D510=0`.

## 6. #10054's six ledger files are orphaned — they exist in ONE commit repo-wide

```
for f in cch-w40-roster-and-seal-denominator-rederive cch-w40-v1-members-outranked-inversion \
         cch-w40-v10-failure-copy-auth-arm cch-w40-v11-unswept-corners \
         cch-w40-v3-s2-live-target-set v8-no-team-wire-break; do
  git cat-file -e origin/main:tooling/grip/ledger/$f-2026-08-07.md 2>/dev/null \
    && echo "$f ON-MAIN" || echo "$f MISSING"
done
```
→ **all six MISSING**. `git log --all --oneline --diff-filter=A -- <path>` returns **1** commit for each.

`gh pr view 10054` → OPEN, branch `epic-charter/cloud-console-hardening-w40-20260807T032621Z`,
head `6e5be3f71f50fbdc06ef2a203d035acd70bd950c`, 7 files (charter + the six ledgers).

**The charter half of #10054 is genuinely a duplicate and worse:**
`git diff --stat origin/main 6e5be3f7 -- .claude/workflows/bp-cloud-console-hardening-charter.md`
→ `451 deletions` — the branch's charter is 451 lines BEHIND main, and main already carries the
wave-40 log entry (`grep -c 'wave 40 REVIEW'` → 1). So closing #10054 as a duplicate is the right
instinct about the charter and **kills the six ledgers**. Rescue them FIRST — they are on disk
untracked in the primary checkout, so `git add` of the six paths on a fresh branch is the whole fix.

Broader orphan surface (local checkout is 585 behind / 49 ahead of origin/main, which inflates any
naive untracked count — measure by set difference, not by `git status`):
```
comm -23 <(git ls-files --others --exclude-standard tooling/grip/ledger/|sort) \
         <(git ls-tree -r --name-only origin/main tooling/grip/ledger/|sort) | wc -l
```
→ **47** true orphans on disk (includes all six of #10054's and all nine of w45's).

## 7. THE MECHANICAL CLOSE PATH FOR A LAPSED CLAIM (the arrears blocker)

**The shape of the arrears.** A lapsed row reads `claim.worker = null` with `claim.epoch` still set and
`claim.previous_worker` preserved. `bp task close <id> <worker> <epoch>` cannot be called — there is no
worker to pass. Repo-wide census:

```
bp task ls --limit 600 -o json   # → {"docs":[…]}; the handle is doc.doc_id (the slug), NOT doc.id (a uuid)
# filter: lifecycle_status=="open" AND claim.worker is null AND claim.epoch is not null
```
→ **99 lapsed-claim open rows**, **72 of them exactly one criterion short**. (The brief said "twelve"
for wave 42–45; the true repo-wide arrears is an order of magnitude larger.)

**The mechanism that creates it:** ten of the cch rows carry `previous_worker: "epic-decide-w45"` —
the DECIDE phase re-claims shipped rows to perfect their briefs, then its claim lapses, overwriting
the builder's claim. Sweeps then re-claim and lapse again instead of closing.

**THE PATH (verified end-to-end on `cch-w43-s1-corpus-mints-the-account-the-server-mints`).**
A lapsed claim is directly re-claimable — no `bp task release` needed:

```
# 0. VERIFY THE MERGE-GATED CRITERION IS ACTUALLY PAID (never skip; this is the honesty step)
gh pr list --search "<slug>" --state all --json number,state,mergedAt,mergeCommit
git merge-base --is-ancestor <mergeCommit> origin/main && echo ANCESTOR
gh api repos/FRIKKern/barkpark/commits/<headRefOid>/check-runs \
  --paginate -q '.check_runs[] | "\(.conclusion)\t\(.name)"' | grep -i 'console gate\|cloud gate'

# 1. RE-CLAIM (bumps epoch, restores worker)
bp task claim <doc_id> <worker> --yes -o json          # → claim.epoch = old+1, worker set

# 2. STAMP the criterion — close CANNOT flip it (see the two guards below)
bp task stamp <doc_id> <worker> <epoch> --criterion N --met --merge-gated \
  --criterion-text "<verbatim stored wording>" --evidence "<run proofs>" --yes

# 3. CLOSE on the NEW epoch
bp task close <doc_id> <worker> <epoch> done "<summary>" --yes
```

**TWO SERVER GUARDS THAT CAN LOSE, both hit for real on the way through — record them so the next
sweep does not mistake them for breakage:**

1. Closing with `--set 'criteria:=[…]'` flipping an unmet row is **REFUSED**:
   `criteria_unmet:11 — "criteria flipped in this very close command do not count — that would be the
   closer grading its own homework."` The flip must be a separate prior `stamp`.
2. Stamping a criterion whose text carries the `MERGE-GATED` marker is **REFUSED** without an explicit
   override: `merge_gated_criterion — "that row is the lead's to close (a builder flipping it fabricates
   a done before the PR exists). Pass --merge-gated to override only if you are the lead closing the gate."`

Both are exactly the epic's own doctrine enforced by the server. Neither is a bug.

**PROOF IT WORKED.** `bp task get cch-w43-s1-corpus-mints-the-account-the-server-mints`:
before → `open`, `claim.worker null`, `epoch 10`, `11/12`;
after  → `lifecycle_status: done`, `criteria_progress {met:12,total:12}`,
`closed_by: epic-verify-w46-v8-arrears at 2026-08-07T12:27:25Z`.
Its criterion 11 was paid by PR **#10199** (MERGED 2026-08-07T08:28:26Z, merge commit `d2a721ba…`,
ancestor of origin/main; Console gate **success** on head `d1d6de55…`).

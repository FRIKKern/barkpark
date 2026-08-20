# Ledger arrears — cch wave 54 slice s7, 2026-08-08

Twenty-five merged-but-open rows paid, eight spared, one phantom cancelled. This row
exists so the NEXT arrears sweep does not re-walk the traps below a third time: every
number here is re-derivable by the command printed beside it, and every instrument
correction is one that produced a *confident wrong answer* before it was caught.

Worker: `epic-builder-the-ledger-arrears-pays-twenty-five-merg`.
Tree: clean worktree at `origin/main` = `2e38228b0048901b166d915d222cfc47f6f470d6`.

## Census — before and after

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys,collections; \
d=json.load(sys.stdin); p=[c for c in d['children'] if not str(c['doc_id']).startswith('drafts.')]; \
k=collections.Counter(c['lifecycle_status'] for c in p); \
print('published',len(p),dict(k),'live',k['open']+k['considering']+k['in_progress'])"
```

| | children | drafts | published | open | done | cancelled | considering | in_progress | **live** |
|---|---|---|---|---|---|---|---|---|---|
| decide-time (quoted in the brief) | 717 | 15 | 702 | 364 | 292 | 45 | 1 | 0 | **365** |
| before this sweep (re-derived) | 737 | 18 | 719 | 374 | 292 | 45 | 1 | 7 | **382** |
| after this sweep | 740 | 18 | 722 | 352 | 317 | 45 | 1 | 7 | **360** |

The decide-time numbers were already stale by 17 live rows when the build started —
concurrent wave-54 sessions file while a slice runs. **Quote no census you did not
just derive.** The before/after diff contains exactly 25 transitions, all
`open -> done`, all mine; three rows are NEW since the before-census
(`cch-w54-bl-other-admin-token-backed-paths-ignore-suspension`,
`cch-w54-r1-seal-predicate-refuses-an-absent-object-database`,
`cch-w53-s6-fu-origin-label-for-oauth-plus-two-factor`) and none vanished:

```sh
bp task get cloud-console-hardening-epic -o json > after.json   # before.json taken pre-sweep
python3 -c "import json; b={c['doc_id']:c['lifecycle_status'] for c in json.load(open('before.json'))['children']}; \
a={c['doc_id']:c['lifecycle_status'] for c in json.load(open('after.json'))['children']}; \
print('new',[k for k in a if k not in b]); print('moved',[(k,b[k],a[k]) for k in a if k in b and a[k]!=b[k]])"
```

The slice's live target of `<= 340` was set against the 365 baseline (365-25). Against
the real 382 baseline the floor available to a sweep authorised to close 25 rows is
357, so the target is arithmetically unreachable and is recorded as a MISS on the
slice, not flipped. **A live-count criterion in a concurrent wave must be a delta
(`live drops by >= N`), never an absolute floor.**

## The population

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys; \
d=json.load(sys.stdin); \
print([c['doc_id'] for c in d['children'] if c['lifecycle_status']=='open' \
and c.get('criteria_progress',{}).get('total',0)>0 \
and c['criteria_progress']['met']==c['criteria_progress']['total']-1])"      # 33 rows
```

33 = **25 paid** + **4 stranded** + **4 never-claimed**. The naive `met == total-1`
sweep false-closes the last four. Exclude on `claim.epoch != null` — and note the
shape trap: the claim is at `.doc.claim`, **not** `.claim`; reading `.claim` returns
null for every row and reads as "no builder notes exist."

### Paid (25) — each re-verified, not closed on the list

Every row: carrier `state == MERGED`, its slug present in the carrier's **title+body**,
the **merge commit** an ancestor of `origin/main`, and all four required contexts
`success` on the carrier **head**.

| row | PR | row | PR | row | PR |
|---|---|---|---|---|---|
| cch-w37-s1 | #9917 | cch-w49-s3 | #10510 | cch-w51-s3 | #10614 |
| cch-w37-s2 | #9918 | cch-w49-s4 | #10511 | cch-w51-s4 | #10648 |
| cch-w37-s4 | #9920 | cch-w49-s5 | #10512 | cch-w51-s5 | #10615 |
| cch-w37-s6 | #9922 | cch-w50-s1 | #10557 | cch-w51-s6 | #10649 |
| cch-w39-s1 | #10005 | cch-w50-s2 | #10559 | cch-w52-s1 | #10646 |
| cch-w39-s5 | #10008 | cch-w50-s3 | #10560 | cch-w52-s2 | #10647 |
| cch-w46-s7 | #10561 | cch-w51-s1 | #10613 | cch-w53-s2 | #10726 |
| cch-w49-s1 | #10508 | cch-w51-s2 | #10650 | cch-w53-s5 | #10728 |
| cch-w49-s2 | #10509 | | | | |

22 of the 25 carried a non-empty `claim.now`; all 22 notes are quoted verbatim in
their close reason, with `previous_worker`. The three empty ones
(`cch-w37-s1`, `cch-w49-s2`, `cch-w51-s3` — also the three thinnest mappings) say so
in the reason rather than implying a note existed. Spot-checked by reading the carrier
diffs: #9917 moves `friendly()` in `cloud/priv/static/app.js` to read `data.details`
before the curated `ERRORS` map; #10509 adds
`Billing.checkout_capability/0 :: available|unconfigured|unverifiable` plus a derived
`priced_plans/0`; #10614 adds `site.rolled_back` to the closed `@actions` list in
`accounts/audit_event.ex`.

### Spared — 4 stranded (merge work, not close work)

| row | PR | state | why |
|---|---|---|---|
| cch-w38-s2 | #9956 | OPEN MERGEABLE/BLOCKED | Cloud gate FAILURE, Console gate FAILURE |
| cch-w39-s2 | #10006 | OPEN MERGEABLE/BLOCKED | Console gate FAILURE |
| cch-w40-s3 | #10085 | OPEN CONFLICTING/DIRTY | 4/4 green but **stale** — a conflicted PR never re-runs its gates |
| cch-w40-s4 | #10086 | OPEN CONFLICTING/DIRTY | same |

`mergeable` is computed lazily: the first read returns `UNKNOWN` for all four, and a
single-shot read records a state GitHub had not yet computed. Poll until it settles:

```sh
for n in 9956 10006 10085 10086; do
  for _ in 1 2 3 4 5 6; do
    gh pr view $n --repo FRIKKern/barkpark --json state,mergeable,mergeStateStatus </dev/null
    sleep 4
  done
done
```

### Spared — 4 never-claimed (`claim == null`, all 0/1 backlog rows)

`task-79aa75e4be7a0067`, `cch-notif-enqueue-failure-unprovable`,
`cch-w36-bl-new-flow-role-truth`, `cch-prod-limit-override-seam-unmirrored`.
Read back after the sweep: all four still `open`, still `claim=None`.

### Cancelled — the phantom

`task-d2f255f7f3b8b5dd` asserted `scripts/required-checks.test.sh --hermetic` is RED
on `origin/main` with two failures. Refuted by running it in this clean worktree at
`2e38228b0`: **166 passed, 0 failed, exit 0** (hermetic — the 4 live GitHub-API
clauses of §10/§11 are skipped by design). Both accused clauses pass by name. Nothing
in flight cited it (0 of 37 open PRs in title/body/branch; `gh search prs` empty;
`grep -rln d2f255f7f3b8b5dd .` empty). The real defect stays filed as
`cch-w51-bl-required-checks-suite-runs-outside-a-checkout-and-reports-defect-shaped-prose`.

```sh
bash scripts/required-checks.test.sh --hermetic; echo "EXIT=$?"
```

## Instrument corrections

Seven. Five inherited from the sweep that found them; **(6) and (7) are new here**, and
(6) produced a confident wrong answer *inside this sweep* — it marked a merged,
fully-green carrier red.

**(1) The required set is four, and `Security gate` is not one of them.** Asserting on
a context that cannot block, while missing one that can, is a guard that cannot lose.

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection/required_status_checks </dev/null
# contexts: ["Elixir gate","PR references an active task","Cloud gate","Console gate"]
```

**(2) `gh api repos/:owner/:repo/...` silently 422s outside a git cwd** — and with
`2>/dev/null` it returns a *uniform* `[0/4] ABSENT` for every row, which is
indistinguishable from "the gates never ran." Use the literal `FRIKKern/barkpark` and
never swallow stderr.

**(3) `gh api` eats stdin inside `while read ... done < pairs.txt`** — the loop
consumes one line and exits. Always `</dev/null` (or `stdin=subprocess.DEVNULL`).

**(4) Ancestry belongs to the MERGE COMMIT, not the head sha.** Every carrier lands as
a single-parent squash, so the head is on no branch that reaches main:
`merge_is_ancestor` is True for all 25 while `head_is_ancestor` is False for all 25.
Read the merge commit for ancestry, the head for checks.

```sh
m=$(gh pr view 10614 --repo FRIKKern/barkpark --json mergeCommit -q .mergeCommit.oid </dev/null)
git merge-base --is-ancestor "$m" origin/main && echo ancestor
```

**(5) One head sha can carry two PRs' check runs.** `4a99cbcc7`, `0792f2bb6` and
`6368d7e14` return 64-72 runs because stale duplicate PRs #10719/#10721/#10723/#10724
were opened 09:52-09:54Z on 2026-08-08, hours after the originals merged at 04:32Z.

**(6) NEW — `.pull_requests[]` is EMPTY on most check runs, so it cannot disambiguate
them.** This is the correction that broke: trusting (5)'s remedy, the sweep treated an
empty `pull_requests[]` as "mine", took the latest run per context, and read
`cch-w52-s2` / #10647 as `PR references an active task = failure` — a merged carrier
marked red. On that sha *all eight* runs carry `pull_requests: []`; the four that
matter completed 04:18-04:21Z and the four that lie completed 09:52-09:58Z. **The
instrument that works is the merge timestamp: a run that completed after `mergedAt`
cannot be a check the merge cleared.**

```sh
head=$(gh pr view 10647 --repo FRIKKern/barkpark --json headRefOid -q .headRefOid </dev/null)
gh api "repos/FRIKKern/barkpark/commits/$head/check-runs?per_page=100" --paginate --slurp </dev/null \
  | python3 -c "import json,sys; [print(r['name'],r['conclusion'],r['completed_at'],[p['number'] for p in (r.get('pull_requests') or [])]) \
      for pg in json.load(sys.stdin) for r in pg['check_runs']]"
# mergedAt = 2026-08-08T04:32:07Z — keep only runs completed at or before it
```

The four duplicates are now closed (#10719/#10721 already were; #10723/#10724 closed
by this sweep), so they stop re-firing against shas already on main.

**(7) NEW — the phantom was never in the roster it was said to top.** The brief called
`task-d2f255f7f3b8b5dd` "the epic's HIGHEST-PRIORITY open row", but its `parent_id` is
`cch-instruments-epic`, not `cloud-console-hardening-epic`. It appears in no
`bp task get cloud-console-hardening-epic` child list, so closing it moved this census
by exactly zero. **Confirm parentage before crediting a close to an epic's count.**

```sh
bp task get task-d2f255f7f3b8b5dd -o json | python3 -c "import json,sys; \
print([json.loads(l)['doc']['parent_id'] for l in sys.stdin if l.startswith('{')][0])"   # cch-instruments-epic
```

## Two guards that correctly refused this sweep

Worth recording because both are guards that *can* lose, and both fired:

- `bp task close --set 'criteria:=[...]'` is rejected — "that would be the closer
  grading its own homework." Criteria must be stamped as a **separate write** before
  the close.
- `bp task stamp --met` on a criterion whose text carries the `MERGE-GATED` marker is
  rejected — "a builder flipping it fabricates a done before the PR exists." The
  override `--merge-gated` exists for the lead closing the gate, and is used here only
  after the merge is verified (MERGED + merge-commit ancestor + 4/4 green).

One more, learned the hard way: **`bp task pulse` bumps the claim epoch**, so an epoch
cached from the claim response goes stale mid-run and the next stamp returns
`fenced_off`. Re-read `.doc.claim.epoch` before each write.

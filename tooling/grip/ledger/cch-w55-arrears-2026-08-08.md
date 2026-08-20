# Ledger arrears — cch wave 55 slice s5, 2026-08-08

Eight rows examined. **Six closed**, **two spared**. The spare is the point of this
receipt: two of the eight look identical to the other six from the outside (merged
carrier, `met == total - 1`, last criterion says MERGE-GATED) and are nevertheless
*not closable*, because their last criterion demands something a merge sha cannot
supply. Closing them would have stamped a criterion whose actual condition was never
met — the false-done class this epic exists to prevent.

Worker: `epic-builder-the-ledger-arrears-six-shipped-but-open-`, task
`cch-w55-s5-the-wave-54-arrears-pays-eight-rows`.
Tree: worktree at `origin/main` = `4b0a8a5d3d72848373d18c3aeb19efb913356351`.

## The eight `claim.now` notes, captured verbatim BEFORE the first mutation

A re-claim **wipes** `claim.now`. All eight notes below were read and recorded in a
single pass over `bp task get <id> -o json` before any claim, stamp, or close was
issued in this slice; they are the only surviving record of what each builder said it
did. The field is at `.doc.claim.now.text` — **not** `.claim.now`.

| # | row | `claim.now.text` (verbatim) |
|---|---|---|
| 1 | `cch-w54-s2-suspension-closes-the-three-mint-and-reveal-paths` | REVIEWED. Final branch ...-studi-1-r, PR #10848. Reviewer fix: the three 409 details said 'until the subscription is current' — false on the quota_exceeded axis, the same lie s1 removes from the banner. All three now say 'until the suspension is cleared'; pin widened to the closed set of three. Guard proven able to lose. Gate: mix test test/barkpark_cloud/web -> 1164/0. Criteria 6+7 stamped; merge-gated #8 left for the lead. |
| 2 | `cch-w54-s6-decommission-sweeps-dns-by-value-not-by-name` | REVIEWED. Final branch ...-by--4-r, PR #10851. Reviewer fix on the risk the builder named first: the identity scan break'd on first match, so a co-tenant at a shared IP went unnoticed and the by-value sweep would delete its LIVE A record. Scan now completes and NARROWS the DNS step (exclusiveIP -> by-name at a shared address). New test covers both orders; dropping the narrowing reds both. Gate: build+vet+test ok, gofmt clean. |
| 3 | `cch-w54-s7-the-ledger-arrears-pays-twenty-five-rows` | DONE (builder side): 25 rows closed + 8 spared + phantom cancelled + 4 dup PRs closed; receipt committed 23614d5cc on loop-epic/the-ledger-arrears-pays-twenty-five-merg-5; 8/10 met, c7 honest MISS, c9 merge-gated for the lead |
| 4 | `cch-w54-s8-the-guard-suite-refuses-an-absent-object-database` | done: 64ed912a6 committed, 7/8 stamped (8th is merge-gated for the lead); residue filed as cch-w54-r1 (seal-predicate.test.mjs) |
| 5 | `cch-w49-bl-required-checks-drift-calls-its-own-job-blocking` | header corrected + hermetic green; riding cch-w53-s5's branch, lead closes on merge |
| 6 | `cch-w51-bl-two-factor-and-identity-changes-leave-no-audit-trail` | All 4 criteria stamped against cch-w53-s3 (commit 71a288c49, branch loop-epic/the-audit-census-stops-excusing-four-ver-2-r). Lifecycle stays in_progress: the work is MERGE-GATED — the lead closes this row when that PR merges. |
| 7 (SPARED) | `cch-w53-s4-sign-out-everywhere-ends-the-live-stream` | built + gated + committed 6e82406ca on loop-epic/sign-out-everywhere-ends-the-live-stream-2; 10/11 criteria stamped, merge-gated one left open for the lead |
| 8 (SPARED) | `cch-w53-s6-oauth-exchange-stops-skipping-two-factor` | committed 05bfc62d8 on loop-epic/oauth-exchange-stops-skipping-two-factor-3 (not pushed); 9/11 criteria stamped, criterion 10 is merge-gated for the lead; filed follow-up cch-w53-s6-fu-origin-label-for-oauth-plus-two-factor |

Note that row 8's own note says "9/11 stamped" while the ledger reads 10/11 — the note
was written before its last stamp landed. **A note is a builder's claim, the ledger is
the record; where they disagree the ledger wins.**

## Census — before and after

```sh
bp task get cloud-console-hardening-epic -o json > epic.json
python3 -c "import json,collections; d=json.load(open('epic.json')); \
p=[c for c in d['children'] if not str(c['doc_id']).startswith('drafts.')]; \
k=collections.Counter(c['lifecycle_status'] for c in p); \
print('published',len(p),dict(k),'live',k['open']+k['considering']+k['in_progress'])"
```

| | published | open | done | cancelled | considering | in_progress | **live** |
|---|---|---|---|---|---|---|---|
| quoted in the brief (stale) | 725 | 362 | 317 | 45 | 1 | 2 | **363** |
| before this sweep (re-derived) | 737 | 369 | 317 | 45 | 1 | 5 | **375** |
| after this sweep (re-derived) | 737 | 363 | 323 | 45 | 1 | 5 | **369** |

The brief's own numbers were already stale by 12 live rows when this slice started —
as the brief itself predicted. **Quote no census you did not just derive.**

The before/after diff contains **exactly six transitions, all `open -> done`, all
mine**; no row was created and none vanished during the window, so the −6 is entirely
this sweep and nothing is hiding under a concurrent filing:

```sh
python3 -c "import json; \
b={c['doc_id']:c['lifecycle_status'] for c in json.load(open('epic_before.json'))['children']}; \
a={c['doc_id']:c['lifecycle_status'] for c in json.load(open('epic_after.json'))['children']}; \
print('new',[k for k in a if k not in b]); print('gone',[k for k in b if k not in a]); \
print('moved',[(k,b[k],a[k]) for k in a if k in b and a[k]!=b[k]])"
# new [] · gone [] · moved: the six rows below, each open -> done
```

Minutes later the slice gate re-derived the same census and read **published 738, live
370** — one row filed by a concurrent session in the gap. That is the drift this
receipt keeps warning about, observed inside its own run: the after-census is a
timestamp, not a standing fact. The **−6 is still exact**, because it is measured by
the row-level diff above, not by subtracting two totals taken at different moments.

Honest net effect on the epic: **live 375 → 369 from the closes, −6**, and then **+1**
for the one row this slice filed itself — `cch-bl-merge-gated-override-cannot-tell-a-
lead-from-a-builder` (see below) — for a **true net of −5**. Counting only the closes
would be the same flattery this receipt exists to refuse. The wave's total is whatever
the other slices file on top; a wave stays ahead of Standing Law 0 only on the
arithmetic of the whole roster, never on one slice's closes alone.

## Carrier verification — the same four checks on every row

Required contexts are read from branch protection, not assumed:

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection/required_status_checks -q '.contexts[]'
# Elixir gate · PR references an active task · Cloud gate · Console gate
```

and read **on the PR HEAD**, never on the merge commit, with `--paginate`:

```sh
gh api --paginate "repos/FRIKKern/barkpark/commits/<HEAD>/check-runs?per_page=100" \
  -q '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" \
      or .name=="PR references an active task")|.name+"="+.conclusion' | sort -u
```

| row | PR | merged | merge sha | `--is-ancestor` | HEAD | 4 contexts on HEAD |
|---|---|---|---|---|---|---|
| `cch-w54-s2-…` | #10848 | MERGED | `4a26d181b8e24c4ea7c7c99e20581202e64e8187` | exit 0 | `325a0d789` | 4/4 success |
| `cch-w54-s6-…` | #10851 | MERGED | `981ee6f5130f8d8d565bd0ec5ed5727101d9eb62` | exit 0 | `247abffb2` | 4/4 success |
| `cch-w54-s7-…` | #10852 | MERGED | `9b8e75f5546711dceca578c5dd929726b76aef4d` | exit 0 | `23614d5cc` | 4/4 success |
| `cch-w54-s8-…` | #10853 | MERGED | `5d07f73e80a5b9494166f10d96163839ad5432bd` | exit 0 | `64ed912a6` | 4/4 success |
| `cch-w49-bl-…` | #10728 | MERGED | `7907b78e9653852116212bef41b7ae035490c200` | exit 0 | `7802bb2d5` | 4/4 success |
| `cch-w51-bl-…` | #10727 | MERGED | `8af8c2adf27c7e3103b114f6a9c096b739c5a148` | exit 0 | `017170cd0` | 4/4 success |

24 of 24 required contexts `success`. Rows 3 and 4 corroborate independently: the HEAD
shas `23614d5cc` and `64ed912a6` are the exact commits those rows' own `claim.now`
notes name, so the carrier and the builder's story agree.

### The ancestor test goes on the MERGE sha, not the HEAD

This repo squash-merges. A PR HEAD is therefore **never** an ancestor of `main`:

```sh
git merge-base --is-ancestor 325a0d789 origin/main ; echo $?   # 1 — head of #10848, MERGED
git merge-base --is-ancestor 4a26d181b origin/main ; echo $?   # 0 — its merge sha
```

An arrears sweep that ancestor-tests the HEAD concludes that every merged PR is
unmerged and pays nothing. Test the **merge** sha; read the contexts on the **HEAD**.

### `cch-w51-bl-…` is stamped against `8af8c2adf`, never `71a288c49`

Its `claim.now` (row 6 above) cites `71a288c49`. That sha is a **real commit in this
repo** and **not** an ancestor of `origin/main`:

```sh
git cat-file -t 71a288c49                                       # commit
git merge-base --is-ancestor 71a288c49 origin/main ; echo $?    # 1 — NOT an ancestor
git merge-base --is-ancestor 8af8c2adf origin/main ; echo $?    # 0
```

It is a stale pre-rebase branch sha. This is the nastiest shape in the set: the object
resolves, so `git cat-file`, `git show`, and a human eye all say "that commit exists" —
only the ancestor test says it never reached `main`. The close reason records both the
sha used and the sha refused.

## The six closes

Six of the eight carried a **lapsed** claim (`claim.worker` null, `claim.previous_worker`
preserved). Closing on the printed epoch fails the CAS **silently**. Recipe, per the
already-filed `cch-w47-bl-four-merged-round-1-rows-all-need-a-re-claim-not-just-one`:
re-claim on `claim.previous_worker`, **read the new epoch back from the re-claim
response**, issue the close **adjacent** (leases lapse on ~15 minutes).

Every epoch below was read back. **Not one matched the epoch printed in the brief** —
which is exactly why no close may quote a brief:

| row | previous_worker | epoch in brief / at read | epoch read back | closed |
|---|---|---|---|---|
| `cch-w54-s2-…` | `epic-builder-a-suspended-instance-stops-minting-studi` | 5 / 6 | **7** | done 9/9 |
| `cch-w54-s6-…` | `epic-builder-decommission-sweeps-dns-by-value-not-by-` | 5 / 6 | **7** | done 9/9 |
| `cch-w54-s7-…` | `epic-builder-the-ledger-arrears-pays-twenty-five-merg` | 6 | **7** | done 9/10 |
| `cch-w54-s8-…` | `epic-builder-the-guard-suite-refuses-an-absent-object` | 7 | **9** | done 8/8 |
| `cch-w49-bl-…` | `epic-builder-the-guard-suite-stops-exiting-green-afte` | 3 | **4** | done 2/2 |
| `cch-w51-bl-…` | `wave-53-reviewer` | 4 | **5** | done 4/4 |

The brief described rows 1 and 2 as holding **live** claims closable directly. By the
time this slice read them both had lapsed to `worker: null`. The brief was not wrong;
it was **stale by one lease**. Re-read state, never trust a liveness claim written
minutes ago.

`cch-w54-s8` jumped 7 → **9**, not 8: its first re-claim returned
`{"error":{"code":"internal_error",…,"request_id":"GMnad42OoXWhcrwAHxAy"}}` and the
retry incremented again. A sweep that assumed "epoch + 1" after a failed call would
have closed on a dead epoch. **Read it back; never compute it.**

### Two guards that refused this sweep, correctly

Both fired on `cch-w54-s2` and neither was worked around blindly:

1. **Close-time flips are refused.** `bp task close … --set criteria:=[{…met:true…}]`
   answered: *"acceptance criteria 8 (0-BASED) are not met on the task AS STORED, and
   criteria flipped in this very close command do not count — that would be the closer
   grading its own homework."* The flip had to be a separate, stored `stamp`.
2. **A builder may not flip a MERGE-GATED criterion.** The stamp then answered
   `{"error":{"code":"merge_gated_criterion",…"that row is the lead's to close (a
   builder flipping it fabricates a done before the PR exists). Pass --merge-gated to
   override only if you are the lead closing the gate."}}`.

`--merge-gated` was passed **only** for rows whose carrier PR was verified MERGED, its
merge sha an ancestor of `origin/main`, and all four contexts green on its HEAD — the
condition the criterion actually names. That is this sweep acting as the lead on a gate
that has already closed, not a builder pre-declaring a merge. These are guards that can
lose, and on the two spared rows below they **do** lose.

And guard 2 has a hole worth naming, since this slice walked straight through it: the
override is a **bare flag with no authority check**. Any worker that hits the refusal
can re-issue the identical command with `--merge-gated` and the flip lands — nothing
verifies the PR is merged, that its merge sha is reachable from `main`, or that the
caller is the lead. The guard stops an *accident*; it does not stop the failure it
names. Everything that made this sweep's override legitimate was the worker's own
verification, not the guard's requirement. Filed as
`cch-bl-merge-gated-override-cannot-tell-a-lead-from-a-builder`, with the cheapest fix
being: require an accompanying merge sha and refuse one the server cannot confirm
reachable from `main`.

### `cch-w54-s7` criterion 7 closes as an honest MISS

Criterion 7 reads: *"The live-row count DROPS: the after-census shows live at or below
340…"*. That floor was set against a **365** baseline (365 − 25) while the true
pre-sweep baseline was **382**, so the lowest a sweep authorised to close 25 rows could
reach was **357**. The target is arithmetically unreachable — a defect in the
criterion, not in the work. It was recorded with `--miss --note` and **never flipped**:

```sh
bp task stamp cch-w54-s7-… <worker> 7 --criterion 7 --miss --note "HONEST MISS, never flipped. …"
# → epoch=7 rev=8c065add9a5dd159021d33c02b4b316c
```

Verified after close: `lifecycle done`, `criteria_progress {met: 9, total: 10}`,
`acceptance_criteria[7].met == False`. The close carries
`--set criteria_override="…"`, and `bp` printed the honest advisory
`warning: acceptance_criteria: 9/10 met — closed done with unmet criteria`. The row is
done and the ledger still says which part was not. The shape fix is filed as
`cch-bl-live-count-criteria-must-be-deltas-not-absolute-floors`: **a live-count
criterion in a concurrent wave must be a delta (`live drops by >= N`), never an
absolute floor.**

## The two SPARED rows — left open, on purpose

| row | PR | ledger | why not closed |
|---|---|---|---|
| `cch-w53-s4-sign-out-everywhere-ends-the-live-stream` | #10849 merged | open 10/11 | criterion 11 is not a bare merge gate |
| `cch-w53-s6-oauth-exchange-stops-skipping-two-factor` | #10850 merged | open 10/11 | criterion 11 is not a bare merge gate |

Their criterion 11, verbatim:

> **s4** — MERGE-GATED — the lead closes this. The PR is merged to main. HIGH-FLIP-RISK:
> the SESSION-REVOCATION SCOPE judgment (which token contexts the widened sweep may
> touch, and that the per-ticket burn is untouched) warrants a genuinely INDEPENDENT
> second reviewer before merge — widening one row too far reproduces the D28 eviction
> storm.

> **s6** — MERGE-GATED — the lead closes this. The PR is merged to main. HIGH-FLIP-RISK:
> the REFUSAL-SHAPE judgment (pending-challenge rather than hard-refuse, resting on the
> constructibility of the permanently-locked-out OAuth-born class) warrants a genuinely
> INDEPENDENT second reviewer before merge — if that class is judged negligible,
> hard-refuse becomes defensible and simpler.

Each criterion is a **conjunction**: merged **and** independently reviewed on a named
judgment. The merge half is satisfied; the second half is a human act on a specific
question — *which token contexts the sweep may touch*, *whether the locked-out class is
constructible* — and no sha demonstrates it. Stamping these on the merge alone would
record an independent review that never happened, on precisely the two judgments the
authors flagged as most likely to be wrong.

They are left **open at 10/11** for the lead. Sparing them is the deliverable, not an
omission: the cost of a wrong spare is one row of visible debt; the cost of a wrong
close is a fabricated safety review on session revocation.

## What a later sweep should carry forward

1. **`met == total - 1` is a candidate filter, never a close criterion.** Read the last
   criterion's *text*. Two of eight here matched the arithmetic and were not closable.
2. **Ancestor-test the merge sha; read contexts on the HEAD.** Squash-merge makes the
   HEAD a non-ancestor of `main` on every merged PR.
3. **A sha that `git cat-file` resolves may still never have reached `main`.** Only
   `merge-base --is-ancestor` distinguishes them (`71a288c49` here).
4. **Read every epoch back from the re-claim response.** Six of six differed from the
   printed value, and a failed call bumped one twice.
5. **Capture `claim.now` before the first mutation.** A re-claim wipes it, and it is the
   only record of what the builder said.
6. **Live-count criteria must be deltas.** Concurrent sessions file continuously; an
   absolute floor written at decide time is stale before the builder claims.

## Scope

One file added under `tooling/grip/` — this one:

```sh
git status --porcelain tooling/grip/
# ?? tooling/grip/ledger/cch-w55-arrears-2026-08-08.md
```

# PDS w46 — tiering predicate: re-derivation recipes (base origin/main 683c2f00a5f809851f6f3ee2bdd341158349d525)

Verifier lane `tiering-predicate-or-refusal`. Every command below is run from a pristine
materialisation of origin/main, NOT from a worktree:

```sh
D=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C "$D"; cd "$D"
```

## R1 — the 20 rows and the 4 doors, computed not transcribed

```sh
bash scripts/pds-door-census.sh --check
```
Expected: `THROUGH a required gate : 4 of 20  (WITH-HARNESSES)`, ERRORS 0, and the four
door names `pds-door-census.sh pds-elixir-receipt-census.exs pds-record-parity.test.sh
pds-status-only-residue.exs`. Exactly the four rows print `legA=yes legB=true`; all 16
others print `no / false`.

## R2 — no numeric CPU threshold exists anywhere

```sh
grep -nEi 'threshold|tier|budget|too expensive|MAX_CPU|CPU_(CAP|LIMIT|BUDGET)' scripts/pds-door-census.sh
grep -nEi 'CPU (threshold|cap|budget|limit)|tier(ing)? (threshold|predicate|rule)' .claude/workflows/bp-pds-charter.md
grep -niE 'threshold|tier|budget|cpu' docs/ops/merge-gates.md
grep -rniE 'threshold|MAX_CPU|CPU_(CAP|LIMIT|BUDGET|MAX)' scripts/pds-*
```
Expected: census returns ONE line (:165, the word "tiering" inside a ledger literal);
charter returns NOTHING; merge-gates returns only doc-budget/byte-cap lines; the
`scripts/pds-*` sweep returns only MiB memory thresholds (PDS-D221's 1048.16) and
`auth_tier` in `pds-live-bp-write-receipt.sh:166-170`. No CPU threshold, anywhere.

## R3 — the price literals

```sh
git show origin/main:scripts/pds-door-census.sh | grep -oE 'CPU=[0-9.]+\+[0-9.]+=[0-9.]+s' \
  | sed -E 's/.*=([0-9.]+)s/\1/' | sort -g
```
Expected: `0.16 0.82 3.32 4.45 8.91 40.33`. Note 0.16 is door-census's own `--selftest`
sub-price inside another row's evidence, not a 6th row.

## R4 — the original class assignment, which is NON-MONOTONE in cost

```sh
git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '2832,2836p'
```
Expected to contain: `pds-elixir-receipt-census.exs` **THROUGH this wave** (~37 s) and
`pds-scratch-target_test.sh` PRICE **4.30 s**. A 37 s row ruled THROUGH beside a 4.30 s
row ruled PRICE — max(THROUGH) > min(PRICE) at the moment of assignment, so no threshold
at any value reproduces it.

## R5 — separability, today

Take the four THROUGH rows and the two PRICE rows off R1's output. A threshold exists iff
`max(THROUGH cost) < min(PRICE cost)`. With the 4th door priced from the charter's ~37 s
gated arm: `37.0 < 8.91` is FALSE. Dropping the 4th door (its census price is the literal
string `UNMEASURED-LOCAL`) is the ONLY way the interval `(4.45, 8.91]` appears — the
interval is an artefact of excluding a door from its own denominator.

## R6 — load normalisation inverts the disputed pair

load1 stamps are in the evidence strings. `8.91/79.23 = 0.1125` (PRICE) normalises BELOW
`4.45/26.44 = 0.1683` (THROUGH). Load ratio `79.23/26.44 = 3.00` exceeds cost ratio
`8.91/4.45 = 2.00`, so any correction proportional to load1 inverts the pair.

## R7 — PDS-D221's actual scope

```sh
git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '1930,1941p'
```
The sentence "no threshold is derived from it, and none may be invented at the close"
attaches to the **RSS control leg, n = 1**, of the MemAvailable contamination check. The
same decision DERIVES a numeric threshold (1048.16 MiB) from 390 samples. D221 is
authority-by-analogy on sample size, not a general prohibition on thresholds.

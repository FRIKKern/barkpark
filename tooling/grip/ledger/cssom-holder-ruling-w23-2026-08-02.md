# cssom holder ruling — wave 23 (2026-08-02) · re-derivation recipe

VERDICT: **SEAT NO HOLDER.** Measured, not reasoned. Eleven synthetic hunks built off
`origin/main` app.css (sha256 `32ea8050ff89…`, 287650 B), Chrome 150.0.7871.187, node v22.22.0.

## 0. the measurement rig (the local checkout is 327 commits behind origin/main)

`cloud/priv/static/__preview__/cssom-heads.baseline` reads **1235** in this worktree and
**1284** on `origin/main`. Never measure in the worktree. Build the rig:

```sh
cd /Volumes/SATECHI/github/barkpark
S=$(mktemp -d)/rig; mkdir -p $S/__preview__
git show origin/main:cloud/priv/static/app.css                            > $S/app.css
git show origin/main:cloud/priv/static/__preview__/cssom-parity.mjs       > $S/__preview__/cssom-parity.mjs
git show origin/main:cloud/priv/static/__preview__/cssom-heads.baseline   > $S/__preview__/cssom-heads.baseline
node $S/__preview__/cssom-parity.mjs        # 1284 heads / 1284 CSSOM / 1229 flattened / MISSES 0, exit 0
```

## 1. the measured cost table — Δ(heads)/Δ(flattened), exit

| # | shape | Δheads | Δflat | exit |
|---|---|---|---|---|
| 1 | declaration folded into an existing TOP-LEVEL prelude (`.cred-remediation` :1294) | 0 | 0 | 0 |
| 2 | declaration folded into a prelude INSIDE an existing `@media` band (`.detail-grid` @899 :2370) | 0 | 0 | 0 |
| 7 | **a NEW `@media` wrapper containing ZERO heads** | **0** | **0** | **0** |
| 3 | new head re-declaring an ALREADY-AUTHORED selector, top level | +1 | 0 | 1 |
| 10 | new head w/ an already-authored selector inside an EXISTING band | +1 | 0 | 1 |
| 4 | new head with a NEW selector, top level, no band | +1 | +1 | 1 |
| 9 | **NEW `@media` band + 1 new head** — identical to #4 | **+1** | **+1** | 1 |
| 8 | ONE comma-group head carrying THREE new selectors | **+1** | **+3** | 1 |
| 5 | NEW `@media` band + 2 already-authored selectors | +2 | 0 | 1 |
| 6 | NEW `@media` band + 2 new selectors | +2 | +2 | 1 |
| 11 | the realistic integrated wave-23 tree: 4 unconditional folds (`.am-name`, `.cred-remediation`, `.fleet-meta`, `.instance-card-name`) | **0** | **0** | **0** |

Rebuild #1–#11 and re-price:

```sh
for f in $S/cand/*.css; do echo "== $f"; CSS=$f node $S/__preview__/cssom-parity.mjs 2>&1 | tail -6; done
```

## 2. the fact D246 does not state — THE `@media` WRAPPER IS FREE

`#7` (empty new band) is Δ0/Δ0, exit 0. `#9` (new band + one new head) is +1/+1 — **exactly equal
to `#4`, the same head with no band at all.** Cost = the number of new `{` PRELUDES, and nothing
else. Band-existence is irrelevant to price. Structurally: `authoredHeads()` puts `media` in
`GROUPING_AT` and DESCENDS without pushing the prelude; the CSSOM side keys on
`typeof r.selectorText === "string"`, which `CSSMediaRule` fails. Both sides ignore the wrapper.

Corollary D246 also does not state: **the sidecar counts HEADS, not selectors.** `#8` prices one
comma group of three NEW selectors at **+1**, the same as one selector. A remedy needing N
selectors with identical declarations is authorable at +1.

D246's `+1/0` = scoped re-declaration vs `+1/+1` = new family is CONFIRMED (`#3` vs `#4`).
D246's `.set-row-name` "+2 for the band" was +2 because the remedy needed TWO heads, not because
the band cost anything.

## 3. no wave-23 candidate remedy moves a head

Every named floor family already owns a top-level base prelude on `origin/main`, and every named
remedy is UNCONDITIONAL (fold), or touches no CSS at all:

| row | files | CSS anchor on origin/main | shape |
|---|---|---|---|
| `cchi-w22-bl-am-name-unbounded-every-width` | (none listed) | `.am-name` **:5631** (row cites :5530 — 101 lines stale) | fold, "EVERY width" |
| `cch-w21-bl-cred-remediation-scrolls-above-the-viewport` | app.js, app.css | `.cred-remediation` :1294 | fold (its own row: the fix is a scroll gesture) |
| `cch-w21-bl-status-pill-detail-fed-by-uncapped-error` | provision_job.ex, failure_copy.ex, app.js, app.css | `.status-pill-detail` :3144 | server cap + fold |
| `cchi-w22-bl-guard-selector-conversion-instances-grid` | overflow-guard.mjs ONLY | — | no CSS |
| `cch-w22-bl-attention-sibling-never-measured` | (none) | — | measurement only |
| `cch-w22-bl-chip-guard-blind-below-721` | (none) | `CHIP_WIDTHS` overflow-guard.mjs:**383** (row cites :382, a comment line) | guard constants |

The "structural head-mover shape" is NOT "a family with no band" — `.cred-remediation`,
`.instance-card*`, `.status-pill-detail` and `.am-name` are ALL band-less and ALL fold at Δ0. The
head-mover shape is "a remedy that cannot be expressed as declarations inside an existing prelude."

## 4. a NEEDLESS SEAT DOES NOT WASTE A SEAT — IT REDS MAIN WITH A PHANTOM #4592

```sh
printf '1285\n' > $S/bogus.baseline
HEADS_BASELINE=$S/bogus.baseline CSS=$S/cand/cand11-integrated-four-folds.css \
  node $S/__preview__/cssom-parity.mjs; echo "exit=$?"
```

```
   authored rule heads   1284 (baseline 1285 ← BELOW)
   MISSES                0
!! BASELINE MISMATCH: 1284 authored rule heads, sidecar baseline is 1285 (−1).
   1. A stray `/*` opener commented out a live region — a real defect, of the same family as #4592.
exit=1
```

A holder seated on a Δ0 wave bumps `1284 → 1285`, the merged tree still measures 1284, and the
gate reds on the **BELOW** branch — whose own failure text tells the next reader to hunt an
orphan-comment swallow that does not exist.

## 5. THE ABSTENTION CRITERION FOR A Δ0 SLICE (D232 is unsatisfiable here)

D232's form — assert `exit 1` + `BASELINE MISMATCH … (+N)` + `MISSES 0` — is written for an
abstainer that ADDS a head. A Δ0 slice CANNOT satisfy it: it exits **0** with `PARITY PASS`.
The Δ0 abstention criterion is a conjunction, and both legs are load-bearing:

> On the integrated tree, `node cloud/priv/static/__preview__/cssom-parity.mjs` exits **0** and
> prints `authored rule heads   1284 (baseline 1284)` and `MISSES  0` — quote both lines verbatim —
> **AND** `git diff --name-only origin/main…HEAD` does not contain
> `cloud/priv/static/__preview__/cssom-heads.baseline`.

Leg 1 alone is satisfied by a slice that touched no CSS at all; leg 2 alone permits a bump that
leg 1 would then contradict. NULL HOLDER is the wave's explicit, stated procedure — untested
before this run, and a lead script that "seats a holder" by default produces §4.

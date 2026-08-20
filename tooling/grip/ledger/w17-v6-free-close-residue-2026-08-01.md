# Re-derivation recipes — cloud-console-hardening W17 verify, v6-free-close-residue (2026-08-01)

Baseline for every recipe: the MERGED bytes of #8818 @ `17ec78adc3b9c2abd6441c5fc0a4692914430888`.
Nothing here reads the local checkout.

## R0 — export #8818's merged static tree

```bash
D=$(mktemp -d); git archive 17ec78adc cloud/priv/static | tar -x -C $D
cd $D/cloud/priv/static/__preview__
```

PORT WARNING, hit live: `OVERFLOW_GUARD_PORT=4741` was squatted by a foreign
worktree's server (`/app.css served 233681 B, disk holds 237836 B`) and the
guard REFUSED to measure — correctly. Pick a port `lsof -nP -iTCP:<p> -sTCP:LISTEN`
reports free. Do NOT pipe the guard to `tail` inside an `&&` chain: `rc=$?` then
reads tail's status, not the guard's.

## R1 — the two committed legs, on merged bytes

```bash
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  OVERFLOW_GUARD_PORT=4841 node overflow-guard.mjs --defect W13-detail-route-band
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  OVERFLOW_GUARD_PORT=4842 node overflow-guard.mjs --defect W15-fleet-row-text-bounded
```
W13: `108 / 108 cells clean across 721-1024` + `36 .detail-rail .status-pill(s)
measured on both axes, 0 outside their own chip`.
W15: `90 / 90 cells clean (330 fleet rows measured, 0 known-row cells itemised:
none) across 320/360/390/430/620/721/769/800/830/860/899/900/940/983/1000`.

## R2 — is the FLEET_KNOWN allowlist entry gone, or merely unreported?

```bash
git show 17ec78adc^:cloud/priv/static/__preview__/overflow-guard.mjs | grep -n -A6 'const FLEET_KNOWN'
git show 17ec78adc:cloud/priv/static/__preview__/overflow-guard.mjs  | grep -n -A2 'const FLEET_KNOWN'
git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs | grep -n 'FLEET_KNOWN'
```
Parent: a populated array whose one entry exempts
`fleet-support-failed / .status-pill-detail / [721,769]`.
Merged and origin/main: `const FLEET_KNOWN = [];` at line 234. GONE, and the
cells it exempted are judged — R1's W15 line prints them as measured with
`0 known-row cells itemised`.

## R3 — the bespoke rail probe (the widths no committed leg drives)

Driver: `v6-rail-probe.mjs` (CDP over Node 22 native `fetch`/`WebSocket`, zero
deps; asserts served-bytes == disk-bytes first, per GR125(a)). Five routes
(`site-states`, `rollback`, `site-binding-bound`, `site-binding-unknown`,
`site-binding-mismatch` — deepLink taken from `SCENARIOS`, never a bare
`?scen=`, see GR125(d)), x 2 themes, judging `scrollWidth <= clientWidth` on the
pill AND every descendant.

```bash
node v6-rail-probe.mjs $D/cloud/priv/static/__preview__ 4843     # WIDTHS = [390,620,901,1440]
```
`cells=40 rail_pills_measured=40 descendants=80 offending_cells=0`.

## R4 — the mutation that proves R3 can lose

```bash
D2=$(mktemp -d); cp -R $D/cloud $D2/
cd $D2/cloud/priv/static && python3 -c "
lines=open('app.css').readlines()
assert lines[5256].startswith('.detail-rail .status-pill {')
assert lines[5266].startswith('.detail-rail .status-pill-label')
open('app.css','w').writelines(lines[:5256]+['/* MUTATION */\n']+lines[5267:])"
node v6-rail-probe.mjs $D2/cloud/priv/static/__preview__ 4845
```
`offending_cells=20` of 40, rc=1. Every 901 and 1440 cell reds:
`No content binding` +38, `Read token stored` +30, `Binding unknown` +16,
`Binding mismatch` +23. 390 and 620 stay clean on the MUTANT — they are NOT
discriminating widths for this row.

## R5 — the true pre-fix band (widen the axis, both trees)

Edit `WIDTHS` to `[320,360,375,430,620,768,800,899,900]` and run R3/R4 again.

| tree | result |
|---|---|
| mutant (pre-fix) | `offending_cells=16` of 90 — only 320 and 900 |
| merged | `offending_cells=0` of 90 |

Pre-fix magnitudes, driven: `No content binding` +10 @320, +38 @>=900;
`Read token stored` +2 @320, +30 @>=900; clean 360-899 on both. The filed row's
title ("at 900 and above only") UNDERSTATES the band — 320 is red too, which the
#8818 body already says (+8.52) and this run corroborates at integer precision.
The filed `+10.31` for "Read token stored" is a third basis (rail-relative
right-edge delta, the false-clean oracle the commit's THE METRIC section names);
on the pill-vs-chip metric it is +2/+30. PAID either way: merged reads 0.00 at
all nine widths.

## R6 — criterion 3, the census (99 scenarios x 320/1440, merged bytes)

```bash
node v6-census.mjs $D/cloud/priv/static/__preview__ 4848
```
230 `.status-pill` instances measured over 198 scenario-route cells.

| wrapper | instances |
|---|---|
| `OUTSIDE:detail-title-row` | 48 |
| `OUTSIDE:instance-card-head` | 40 |
| `OUTSIDE:update-panel-head` | 26 |
| `OUTSIDE:overview-ok` | 24 |
| `detail-rail` (remedied) | 22 |
| `fleet-status` (remedied) | 20 |
| `OUTSIDE:set-row-side` | 18 |
| `OUTSIDE:attention-row` | 10 |
| `OUTSIDE:site-status` | 10 |
| `OUTSIDE:wh-card-head` | 6 |
| `OUTSIDE:op-gate` | 6 |

REMEDY-SCOPED 42 / OUTSIDE 188. Nine unremedied host wrappers, seven of them
never named by any filed row. 16 pill instances still overflow on merged bytes:
8 in `.instance-card-head`, 4 in `.attention-row` (both the filed
`cch-w16-bl-attention-pill-detail-truncated-front-screen` host family — child
`.status-pill-detail` truncating, pill box itself clean), 3 in `.op-gate`
(UNFILED), 1 more `.instance-card-head` at 1440.

## R7 — the UNFILED third wrapper: `.op-gate`

```bash
node v6-opgate.mjs $D/cloud/priv/static/__preview__ 4849
```
`.op-gate { display: flex }` (app.css:5046) with no `min-width: 0` / `flex: 0 0
auto` on its `.status-pill` child (emitted by `operatorPillHtml`, app.js:6969,
called at app.js:7002). The pill BOX is squeezed below its own content, so the
dot + "Gate" paint outside the capsule (`.status-pill-label` computes
`overflow: visible`). Same defect CLASS as `cch-w14-bl-status-pill-label-overflows-rail`,
third wrapper, no remedy, no guard leg.

| scenario | 320 | 360 | 390 | 430 | 620 | 768 | 900 | 1440 |
|---|---|---|---|---|---|---|---|---|
| operator-console | +13 (11.56px painted out) | +10 | +7 | +4 | clean | clean | clean | clean |
| operator-halted | +15 (13.45px) | +12 | +10 | +7 | clean | clean | clean | clean |
| operator-zero-staging | +17 (15.81px) | +15 | +13 | +10 | clean | +4 | clean | clean |

No overflow-guard leg drives `operator-*` at all:
`grep -n 'operator-console\|operator-halted\|operator-zero' overflow-guard.mjs`
returns nothing.

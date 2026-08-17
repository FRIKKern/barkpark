# pe-w3 rig-fresh-pixels — drift map, fresh measurements, schema gaps (D12)

Verifier lane `rig-fresh-pixels`, Paper Excellence wave 3. Purpose: make the wish's
measured-pixels mandate bindable — refetch drifted fixtures, run the hermetic rig at
1280/1920 on the four proof papers, record per-cell numbers, and name exactly which
device measurements the report schema still cannot supply.

Run at HEAD `17b3aabf45` (origin/main, wave-2 fully merged). The shared checkout was
18 commits behind and its `git pull` was blocked by other agents' untracked ledger
files, so the rig ran in an isolated detached worktree at `17b3aabf45`; `api/deps`
symlinked to the primary checkout (mix.lock IDENTICAL). All numbers below are from the
real `PortableDoc.Render` + bulldocs layout under `MIX_ENV=test mix run --no-start`.

## 1. Instrument proven BEFORE any refetch (`gate.sh --check` vs committed baselines)

Every committed fixture reproduces its baseline exactly — the report-diff oracle
(#11760) can lose and did not:

| fixture | measured values compared | differences |
|---|---|---|
| heggemsnes-act | 375 | 0 |
| eight-minute-erasure | 671 | 0 |
| hobby-hardening-capstone | 971 | 0 |
| portabledoc-showcase | 967 | 0 |

(4 image byte counts ignored per fixture — encoder noise, never an oracle.)

## 2. Fixture drift map — THREE of four were stale, not one

Live `_rev` (`bp doc get paper <slug> -o json`) vs committed fixture `source_rev`:

| fixture | fixture source_rev | live _rev | state |
|---|---|---|---|
| eight-minute-erasure | dc35c4a9…dc027576cf1c9bac8a6 | 9e2998c8…401b9d7de0b62c | DRIFTED |
| heggemsnes-act | 2a89cadb…412bea0dc051a47 | 2a89cadb…412bea0dc051a47 | fresh |
| hobby-hardening-capstone | 3c69d2b9…cbd7a9a9d40b4 | 8fab184e…54717d5b40bb | DRIFTED |
| portabledoc-showcase | a6dc3654…077f3e67750f7 | ba2b7e47…c7065b72c22 | DRIFTED |

The direction flagged only eight-minute-erasure. hobby-hardening-capstone (live-updated
2026-08-15) and portabledoc-showcase (2026-08-15) were ALSO stale. Root cause for
eight-minute-erasure specifically: it is NOT in `fetch-fixtures.sh`'s default slug list,
so a bare refresh never touches it.

Refetched all three in the worktree (`fetch-fixtures.sh eight-minute-erasure
hobby-hardening-capstone portabledoc-showcase`); all three `source_rev` now equal live.

## 3. The drift was geometrically INERT — the committed baselines were already accurate

Old committed baseline vs fresh-fetched, `__light__1280` (identical across all cells):

| measure | e-m-e OLD→FRESH | hobby OLD→FRESH | pdoc OLD→FRESH |
|---|---|---|---|
| proseCpl | 71.9 → 71.9 | 71.6 → 71.6 | 71.7 → 71.7 |
| paragraphs | 21 → 21 | 27 → 27 | 32 → 32 |
| sectionBeats | 7 → 7 | 11 → 11 | 13 → 13 |
| bandRows | 9 → 9 | 12 → 12 | 11 → 11 |
| rules.total | 40 → 40 | 150 → 150 | 207 → 207 |
| rules.heavy | 6 → 6 | 11 → 11 | 10 → 10 |

Every rig measurement is byte-identical old vs new. The refetch buys PROVENANCE
(source_rev now certifiably matches live) but NOT changed pixels. Consequence for
Decide: the numbers the rig CAN measure are stable and were never wrong — Decide is not
blind on them. The measured-pixels blocker is schema coverage (§5), not staleness.

## 4. Fresh per-cell measurements (1280 vs 1920, light/dark identical per cell)

columnWidth=660 / columnContentWidth=580 / maxWidth=660px on ALL cells, both widths.
evidenceBand widens 1040px @1280 → 1240px @1920 on ALL fixtures (viewport-responsive,
zero media queries) — this is the width-as-hierarchy signal.

| fixture | proseCpl | sectionBeats | bandRows(stats) | rules.total / heavy | note |
|---|---|---|---|---|---|
| eight-minute-erasure | 71.9 | 7 (1 UNSIZED container head @16px/1px) | 9 (1 stats) | 40 / 6 | 46 blocks |
| heggemsnes-act | 67.7 | 5 | 1 (1 stats) | 14 / 5 | 19 blocks, fresh already |
| hobby-hardening-capstone | 71.6 | 11 | 12 (1 stats) | 150 / 11 | 97 blocks |
| portabledoc-showcase | 71.7 | 13 (3 UNSIZED container heads @16px/1px) | 11 (1 stats) | 207 / 10 | 106 blocks |

Sized section beats measure gap=92px over a 2px rule, ruleGap=16px on every fixture.

## 5. What the report schema CANNOT supply — the D12 key-adds Decide needs

Per-shot keys present: `columnWidth, columnContentWidth, maxWidth, proseCpl,
sectionBeats[], bandRows[], evidenceBand, rules{total,heavy,byWeight,heavyRules},
doubledRules, nestedH2s, paragraphs, blockedRequests`.

ABSENT at HEAD 17b3aabf45 (grepped shoot.mjs + census.mjs + gate.sh — no arm exists):

- **ingress ratio (D6)** — no `ingress`/ratio key; no canonical-text ratio arm. The
  charter's 0.783 ± 0.01 lives ONLY in charter D6 text, not in the instrument. Must be
  built AND keyed before D6 can bind to pixels.
- **tone / verdict-color (D5)** — no tone key. (`'tone'` in the JSON is the substring
  in "caps**tone**ne"; `'ratio'` is "Decla**ratio**n" — both content, not measurements.)
- **h2 rendered px** — sectionBeats records gap/rule/ruleGap only; NO font-size.
- **stat-strip grid track count (D3)** — bandRows records width/offCentre/left/right/
  inkWidth; NO computed grid-template-columns track count. `statRows` counts stats
  BANDS (always 1 here), not tracks.

Current stats-grid baseline for D3 (paper-surface.css:1340, worktree = origin/main):
`.bp-paper-surface .bp-stats { display: grid; grid-template-columns: repeat(auto-fit,
minmax(140px, 1fr)); gap: 10px; ... }` — already auto-fit minmax, but gap 10px (not the
1px hairline over rule-color the crown's D3 device specifies), so the device is
genuinely unbuilt. Track-count math at current 140px/10px: band 1040px → up to 7 tracks,
band 1240px → up to 8 tracks (capped by item count), so a 1280→1920 density change is
achievable once ≥8 stat items exist.

## 6. Deliverables / reproducer

Refreshed fixtures left in the worktree (carve-out forbids writing fixtures to the
shared checkout): `<scratchpad>/wt-origin/tooling/paper-excellence/rig/fixtures/`.
Decide/builders reproduce fresh fixtures deterministically from live:

```sh
# from a checkout at origin/main (>= 17b3aabf45):
bash tooling/paper-excellence/rig/gate.sh --panel --check          # prove instrument (0 diffs)
bash tooling/paper-excellence/rig/fetch-fixtures.sh \
     eight-minute-erasure hobby-hardening-capstone portabledoc-showcase
SHOT_WIDTHS=1280,1920 bash tooling/paper-excellence/rig/gate.sh fixtures/<slug>.json <out>
python3 -c "import json;d=json.load(open('<out>/shots/<slug>.report.json'));[print(s['cell'],s['columnWidth'],s['proseCpl'],len(s['sectionBeats']),s['rules']['total']) for s in d['shots']]"
bp doc get paper <slug> -o json   # live _rev vs fixture source_rev
```

Note: `fetch-fixtures.sh` default slug list omits `eight-minute-erasure` — pass it
explicitly or it silently never refreshes (this is why it drifted).

## 7. Reconciliation with wave-2 probe ledgers (the numbers exist, but off-instrument)

`device-fixture-measures-h2-scale-and-ingress-ratio-2026-08-17.md` and
`ingress-ratio-arm-mutation-and-instrument-divergence-2026-08-17.md` already MEASURED
h2 (27px / 600 weight / 1.5x body, display leg present but 25% short + weight-inverted vs
the artifact's 2.0x/400) and the ingress→body canonical CPL ratio (0.783, tight; own-text
0.759–0.821 is sampling noise). Those came from ONE-OFF Playwright `getComputedStyle`
probes, NOT from the committed `report.json`. So the D5/D6/h2 numbers are known, but they
live outside the schema the `--check` oracle guards — until §5's keys are added, those
device criteria cannot be REGRESSION-gated by the rig, only cited from a probe. That gap,
not fixture staleness, is what §5 asks Decide to close.

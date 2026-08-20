# Wave 44 — THE ONE TRUE BASELINE (console instruments on clean origin/main)

Tree: `origin/main = ba712a4b2` (app.js newest at `d2a721ba2`, 3 commits behind head).

## Re-derive the baseline

```sh
cd /tmp && rm -rf omv2 && mkdir omv2 \
  && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud internal deploy | tar -x -C omv2 \
  && cd omv2 \
  && node --check cloud/priv/static/app.js \
  && node --test cloud/priv/static/__app.test.mjs 2>&1 | tail -8 \
  && node cloud/priv/static/__preview__/smoke.mjs 2>&1 | tail -3 \
  && node cloud/priv/static/__preview__/breakpoint-sweep.mjs 2>&1 | tail -5 \
  && node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs 2>&1 | tail -6 \
  && node cloud/priv/static/__binding_census.mjs 2>&1 | tail -3 \
  && node cloud/priv/static/__me_envelope_census.mjs 2>&1 | tail -3
```

THE NUMERALS (measured, never carried):

| instrument | numeral | rc |
|---|---|---|
| `__app.test.mjs` | `# pass 943` / `# fail 0` (`1..943`) | 0 |
| `smoke.mjs` | `all 106 scenarios rendered` | 0 |
| `breakpoint-sweep.mjs` | `106 scenarios · 25 distinct covered by 26 cells · 81 residue over 13 families` | 0 |
| `breakpoint-sweep.test.mjs` | `# pass 51` / `# fail 0` | 0 |
| `__binding_census.mjs` | `all 79 console write call sites … 40 elevated … 18 unpredicated` | 0 |
| `__me_envelope_census.mjs` | `22 key paths, no MISSING, no INVENTED` | 0 |

STALE numerals in circulation, all refuted here: 919 / 925 / 931 / 104 / 105 / 79-scenarios.
`__binding_census.mjs:602 EXPECT = {total: 79, …}` is a WRITE-CALL-SITE pin (see its own
`(2b) PIN SELF-CONSISTENCY` header), **not** a scenario counter. Strike that sentence from every brief.

## The contradiction, settled

```sh
grep -nE '\b(104|105|106|79|80|81)\b' \
  cloud/priv/static/__preview__/breakpoint-sweep.test.mjs
```

The literals EXIST. `breakpoint-sweep.test.mjs`:
- `:573` test TITLE string — `"the census reconciles: 106 scenarios, 25 distinct covered by 26 cells, 81 residue over 13 families"`
- `:576` `assert.equal(r.total, 106);`
- `:579` `assert.equal(r.residue, 81, "81 is the RESIDUE, not the census");`
- `:582` `assert.equal(Object.keys(SCENARIO_RESIDUE).length, 81, "the COMMITTED literal, counted from the committed bytes");`

The surveyor who reported "grep returns NOTHING" is REFUTED.

## The cost of one scenario — mutation-measured, both paths

Guards that DO NOT move: `__app.test.mjs` (943/943), `__binding_census.mjs` (rc 0),
`__me_envelope_census.mjs` (rc 0; its scenario tally 94→95 is derived, unpinned).

REFUSES FIRST — `smoke.mjs` `assertCensus`, rc 1, before any scenario boots:

```
CENSUS: 1 committed scenario(s) have NO expectation and were never run — a fixture
nothing asserts on is a green that means nothing:
  wave44-probe

census guard failed — every scenario needs an expectation, both ways
```

SECOND — `breakpoint-sweep.mjs` rc **2**:
`UNLISTED scenario "wave44-probe" (family hash:#overview) — no cell renders it and SCENARIO_RESIDUE does not carry it.`

THIRD — `breakpoint-sweep.test.mjs` rc 1, **4 of 51 fail**: `not ok 17` (coverageReport clean),
`not ok 21` (THE IMPORT PROOF), `not ok 44` (`expected: 106 / actual: 107`),
`not ok 47` (the 101st-scenario mutation proof — `r.unlisted` gains a second name).

CLOSED EDIT SET = **3 files**. Both paths driven to full green:

- RESIDUE path: `scenarios.mjs` (+scenario) · `smoke.mjs` (+EXPECTATIONS entry) ·
  `breakpoint-sweep.mjs` (+SCENARIO_RESIDUE row) · `breakpoint-sweep.test.mjs` (title + `r.total` +
  `r.residue` + `Object.keys(...)` = **4 numerals incl. the title string**).
  Result: `all 107 scenarios rendered`, `107 · 25 distinct / 26 cells · 82 residue`, `# pass 51 # fail 0`.
- CELL path (likely S1 — the members screen already has cells at `breakpoint-sweep.mjs:305-306`):
  `breakpoint-sweep.mjs` gains a CELL instead of a residue row; test numerals become
  `r.total 107`, `r.cells 27`, `r.distinctCovered 26`, residue stays 81.
  Result: `107 scenarios · 26 distinct covered by 27 cells · 81 residue`, `# pass 51 # fail 0`.

A residue-path scenario in an EXISTING family costs no new `RESIDUE_FAMILY_REASONS` prose;
a new family would additionally demand a written reason >60 chars (`test` at `:596`).

## Charter consequences

- **D483 is stale IN FACT.** Its ruling ("the members-row slice ships ZERO new scenarios … NO census
  literal, NO residue entry") rests on #10005 and #9955 being *"BOTH OPEN and MERGEABLE"*. Both are
  MERGED (`gh pr view 10005/9955` → `2026-08-07T08:28:18Z` / `08:08:34Z`, commits `c488e127f` /
  `dab78af2c`), which is exactly the 104→106 / 79→81 move measured above. `gh pr list --state open`
  filtered to `breakpoint-sweep|scenarios.mjs` returns **nothing** — no open PR contends those lines,
  so the three-way race D483 dodged is not live. D483 remains a live D-row; Decide owes an overriding
  D-row in its own words, or S1 contradicts its charter.
- **D482 already rules S1's two-predicate law**, derived BY RUN:
  `canRemove = actor === "owner" || rank(actor) > rank(target)`;
  `canChangeRole = rank(actor) > rank(target)`. The direction cites D448 for this; D448 is the
  BILLING row. Brief D482, never D448.
- `scenarios.mjs:2419-2424` corroborates the label lie: `"members-populated"` is labelled
  `"Members (admin) …"` while its `me(…, "owner")` mints an OWNER actor.

Written by the wave-44 verifier `the-one-true-baseline`; not committed by this phase.

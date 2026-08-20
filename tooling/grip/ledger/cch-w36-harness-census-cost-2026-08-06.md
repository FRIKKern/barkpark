# cch-w36 — harness census cost of the `activity-denied` fixture (re-derivation recipe)

Verifier lane `harness-census-cost`, wave 36. Every row below was RUN, not read.
Ground truth: `origin/main` 070c7584b. The primary checkout was 490 commits BEHIND
origin/main and does not contain `breakpoint-sweep.mjs` at all — run everything
from an extraction, never from the worktree.

## 0. Build the ground-truth tree (REQUIRED FIRST STEP)

    cd /Volumes/SATECHI/github/barkpark
    git rev-list --count HEAD..origin/main          # 490 — the worktree is stale
    git ls-tree -r --name-only HEAD | grep -c breakpoint      # 0
    git ls-tree -r --name-only origin/main | grep -c breakpoint # 2
    S=$(mktemp -d); git archive origin/main cloud/ | tar -x -C "$S"

Extract the WHOLE `cloud/` tree. Extracting `cloud/priv/static` alone reds 15
tests as an extraction artefact (census tests read `cloud/lib`).

## 1. Baseline — all five harnesses green on untouched bytes

    cd "$S"
    node cloud/priv/static/__preview__/breakpoint-sweep.mjs        # exit 0
    node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs  # exit 0, 51 pass
    node cloud/priv/static/__preview__/smoke.mjs                   # exit 0, "all 103 scenarios rendered"
    node --test cloud/priv/static/__app.test.mjs                   # exit 0, 887 pass
    node cloud/priv/static/__css_check.mjs                         # exit 0

Sweep census line: `103 scenarios · 25 distinct covered by 26 cells · 78 residue over 13 families`.

## 2. MUTATING THE EXISTING 403 BODY IS FREE (zero census cost)

    perl -0pi -e 's/if \(d\.auditDenied\) return \{ status: 403, body: \{ error: "forbidden" \} \};/if (d.auditDenied) return { status: 403, body: { error: "forbidden", required: "admin", scope: "primary_team" } };/' \
      cloud/priv/static/__preview__/scenarios.mjs

Re-run all five: **all exit 0, byte-identical counts (887 pass, 103 scenarios).**
`scope` is `primary_team`, NOT `team` — re-derive from `auth.ex`, never guess:

    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n 'forbidden(conn,'

## 3. ADDING A SCENARIO REDS THREE INDEPENDENT CENSUSES

Insert a new `"activity-denied"` key into `SCENARIOS` in `scenarios.mjs`, then:

| harness | exit | message |
|---|---|---|
| `breakpoint-sweep.mjs` | 2 | `UNLISTED scenario "activity-denied" (family hash:#activity)` |
| `breakpoint-sweep.test.mjs` | 1 | 4 fails, incl. hard-pinned `103 … 78 residue over 13 families` |
| `smoke.mjs` | 1 | `CENSUS: 1 committed scenario(s) have NO expectation and were never run` |

`__app.test.mjs` and `__css_check.mjs` stay green.

### 3b. The SECOND-ORDER refusal nobody has written down

Adding only the `SCENARIO_RESIDUE` entry does NOT clear it — `hash:#activity` is
a FOURTEENTH family and `RESIDUE_FAMILY_REASONS` has 13 keys:

    !! BREAKPOINT SWEEP (exit 2): UNEXPLAINED residue family hash:#activity

So the full cost is FOUR literal edits across THREE files:
1. `scenarios.mjs` — the new key
2. `breakpoint-sweep.mjs` — `SCENARIO_RESIDUE` entry
3. `breakpoint-sweep.mjs` — `RESIDUE_FAMILY_REASONS` entry (**>60 chars**, pinned by test 46)
4. `breakpoint-sweep.test.mjs` — test 44 (`total 103 → 104`, `residue 78 → 79`,
   `families 13 → 14`, `Object.keys(SCENARIO_RESIDUE).length 78 → 79`) and test 46
   (`used.size 13 → 14`)

plus a `smoke.mjs` EXPECTATIONS entry.

## 4. cssom-heads.baseline is 1305, confirmed in a live browser

    git show origin/main:cloud/priv/static/__preview__/cssom-heads.baseline | grep -vE '^#|^$'   # 1305 (541-line file, 1 payload line)
    CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" node cloud/priv/static/__preview__/cssom-parity.mjs
    # authored rule heads 1305 (baseline 1305) · CSSOM 1305 · MISSES 0 · PARITY PASS · exit 0

## 5. The fixture body IS unvalidated end to end

`mock.js:141` — `if (res) return jsonResponse(res.status, snapshot(res.body));`.
No key filter, no schema. `grep -n "allowedKeys\|validateBody\|BODY_SCHEMA"` over
`scenarios.mjs`, `smoke.mjs`, `mock.js` = zero hits. Evidence keys reach
`friendly()` intact.

Client side, the evidence is discarded today:

    git show origin/main:cloud/priv/static/app.js | grep -nE '\.required\b|\.scope\b'
    # 2 hits, both unrelated (webhook scope :17913, support dataset :19535)

## 6. Stale anchors re-derived (standing law: briefs carry greps, not line numbers)

| cited in cch-w35-s4 | actual on origin/main 070c7584b |
|---|---|
| `loadActivity` app.js:13883 | **14015** |
| `newLaunch` "Plan limit reached" 15860 | **16018** |
| `scenarios.mjs:4295` auditDenied | **4342** |
| brief's "873/873 and 102/102" | **887/887 and 103/103** |
| brief's census bump "102→103, 77→78" | **103→104, 78→79** |

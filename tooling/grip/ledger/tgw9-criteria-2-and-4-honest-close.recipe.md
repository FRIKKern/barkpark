# tgw9 — criteria 2 and 4: how to re-derive the honest close

Wave 9 verifier `criteria-2-and-4-honest-close`, 2026-07-27, against `origin/main` @ `3651da6cf`.
This is an INDEX OF HOW TO VERIFY FAST, not a store of truth. Every row re-runs in seconds.

## Criterion 2 — "Every rejection class is demonstrated FIRING by mutation against a frozen
## adversarial fixture, and a control that does not fire is its own third outcome class"

| # | What to re-derive | Command | Expected | Level |
|---|---|---|---|---|
| 1 | clause B (third outcome class) EXISTS | `git show origin/main:tooling/grip/cli.mjs \| grep -n 'CONTROL_INVALID'` | `33:const EXIT = { OK: 0, GUARD_FAILURE: 1, USAGE: 2, CONTROL_INVALID: 3 };` and `212:    return EXIT.CONTROL_INVALID;` | L2 |
| 2 | clause B FIRES (mutation) | copy `tooling/grip/` to a scratch dir; in `cli.mjs` change the LEVEL-SKIP control's clean twin `rerun` from `git show origin/main:tooling/grip/record.mjs` to `cat tooling/grip/record.mjs`; `node cli.mjs --selftest; echo $?` | banner `CONTROL DID NOT BEHAVE AS A CONTROL (1)` and exit **3** (unmutated: exit 0) | L3 (local run) |
| 3 | the two selftests today | `node tooling/grip/cli.mjs --selftest; node tooling/grip/ledger.mjs --selftest` | `all 15 controls fired as designed` (exit 0); `selftest: 19/19 controls fired` (exit 0) — 34 total | L3 |
| 4 | the frozen fixture's own suite | `node tooling/grip/acceptance.mjs; echo $?` | `6/6 ratified specimens adjudicate as expected · 1 declared divergence(s)` / `ACCEPTANCE: PASS`, exit 0. Specimen 4 is ADMITTED-by-design (UNCAUGHT, D12); specimen 5 is caught by R1 not R3 (declared divergence, `tgw4-r3-has-no-adjudicator-check`) | L3 |
| 5 | rejection classes with NO control anywhere | `for f in record adjudicate ledger level mint screen rerun; do git show origin/main:tooling/grip/$f.mjs \| grep -oE '"[A-Z][A-Z0-9]+(-[A-Z0-9]+)+"'; done \| tr -d '"' \| sort -u > /tmp/c.txt; while read c; do grep -rq -- "$c" tooling/grip/test/ \|\| echo "$c"; done < /tmp/c.txt` | 41 classes; exactly **3** unreferenced: `NO-QUANTITY` (mint.mjs:482), `NOT-A-REF` (level.mjs:579,583), `WRITE-FAILED` (ledger.mjs:652) | L2/L3 mix |
| 6 | the mutation controls are NOT built from the frozen fixture | `git show origin/main:tooling/grip/cli.mjs \| sed -n '43,49p'` | an inline synthetic `CLEAN` object, not a read of `fixtures/level-skip-specimens.json` | L2 |
| 7 | `screen.mjs` has no class vocabulary | `git show origin/main:tooling/grip/screen.mjs \| grep -oE '"[A-Z][A-Z0-9]+(-[A-Z0-9]+)+"' \| sort -u` | `"HEAD"`, `"PWNED"` only — refusals are free-text `reason` strings (`screen.mjs:135`) | L2 |
| 8 | screen's controls DO fire (named sets, not classes) | `node -e "import('./tooling/grip/screen.mjs').then(m=>console.log(JSON.stringify(m.runNamedSets())))"` | `{"falsePermissions":[],"falseRefusals":[]}` | L3 |
| 9 | the criterion's own owner-task is open at 0/7 | `bp task get tgw2-acceptance-suite -o json` | `lifecycle_status: open`, priority 0, parent `tgw1-workflow-gate-wiring`, 0/7 criteria met; criterion 1 = "Every one of the ten verdict classes has a fail-before plant that trips it AND a never-cry-wolf near-miss that does not" | L1 (server) |
| 10 | the charter refuses to close its parent because of it | `git show origin/main:.claude/workflows/bp-truth-grip-charter.md \| sed -n '759,769p'` | D71: "…including `tgw2-acceptance-suite` at 0/7, so closing it would orphan real work behind a closed parent." | L2 |

## Criterion 4 — "Wave 1 stores NOTHING durably — the anti-goal held, verified by the absence of
## any new persisted corpus"

| # | What to re-derive | Command | Expected | Level |
|---|---|---|---|---|
| 11 | **D13 governs, not D26 — the L2 refutation** | `gh api repos/FRIKKern/barkpark/commits/2162ecc1c3e8b26a40a5813f948eed040795efd1 --jq '.files[] \| "\(.status) \(.filename)"'` | `added tooling/grip/fixtures/evidence-corpus.json` / `added tooling/grip/fixtures/level-skip-specimens.json` / `added tooling/grip/harvest.mjs` — a tgw1 commit whose message opens "Ships the quarry … DATA and a HARVESTER only (charter D13, D12)" | **L2** (forge read) |
| 12 | wave 1 had NO ledger dir at all → D26 is out of scope | `git ls-tree -r --name-only 1514f52cb tooling/grip/` | 9 files, no `ledger/`; `ledger/` first appears in wave 2 (`9e1192c03`) | L3 |
| 13 | D13 authorises the corpus, in the SAME charter as D10 | `git show origin/main:.claude/workflows/bp-truth-grip-charter.md \| sed -n '95,99p;112,114p'` | D10 "NOTHING is stored durably this wave" and D13 "The evidence corpus is snapshotted INTO `tooling/grip/fixtures/`" | L2 |
| 14 | the SUBSTANCE held — wave-1 `record.mjs` never touches fs | `git show 1514f52cb:tooling/grip/record.mjs \| grep -n 'writeFileSync\|appendFileSync\|mkdirSync\|createWriteStream\|node:fs'` | no output. (`grep 'fs'` returns 2 lines, both false positives: `findRefs` at :33 and `for (const ref of …)` at :75) | L3 |
| 15 | wave 1 DID ship the writer | `git show 1514f52cb:tooling/grip/harvest.mjs \| grep -n 'writeFileSync'` | `38:import { readFileSync, writeFileSync, …}` / `238:  writeFileSync(CORPUS, …)` — byte-identical to `origin/main` today | L3 |
| 16 | D10's real concern was gitignored irreproducibility | `git show origin/main:.claude/workflows/bp-truth-grip-charter.md \| sed -n '95,99p'` | "…reports 50.1% in the main checkout and 0% in a clean worktree because `research-ledger.json` is gitignored" — the corpus is COMMITTED, so it re-derives identically in a clean worktree | L2 |

## Level ceilings — why "make every criterion L2" is not achievable, and why forcing it is the disease

`level.mjs:184` — `GIT_SHOW_REMOTE = /\bgit\s+show\s+(?:['"]?)(?:refs\/remotes\/|origin\/|upstream\/)\S*:/`
and the comment at `:180-183`: "`git show HEAD:…` or a local branch is a read of the local checkout's
object store — **L3**." Measured through grip's own `deriveLevel`:

    L3 <- git ls-tree -r --name-only 1514f52cb tooling/grip/
    L3 <- git show 1514f52cb:tooling/grip/record.mjs
    L3 <- node tooling/grip/cli.mjs --selftest
    L2 <- git show origin/main:.claude/workflows/bp-truth-grip-charter.md
    L2 <- gh api repos/…/commits/2162ecc1c…

Rerun: `node -e "import('./tooling/grip/level.mjs').then(m=>['<cmd>'].forEach(c=>console.log(m.deriveLevel(c),c)))"`

Consequence: criterion 4 is a claim about **history**, and grip's L2 is "what the remote holds **now**".
The ONLY L2 route to a historical commit is the forge (`gh api …/commits/<sha>`) — row 11. Rewriting
row 12 as `git show origin/main:…` to buy L2 would silently change the question from "what did wave 1
commit" to "what does main hold today". Criterion 2 is a claim about **local execution** and has no L2
route at all; its honest ceiling is L3.

## Live blocker the seal must not paper over

`node --test tooling/grip/test/ledger.test.mjs tooling/grip/test/mint.test.mjs` is **RED on
`origin/main`**, from shared-store contamination written by OTHER epics:

* `ledger.test.mjs:1281` (the D89 CONTROL) — 3 `MALFORMED-RUN`: `grip-20260721T190000Z-pds-w20-floor-value.json`,
  `grip-20260722T000000Z-ae-seal-descope-mechanics.json`, `grip-20260722T060000Z-v-w17-delivery-fk-reachability.json`
  have no `recipes[]` array. Rerun their provenance: `git log --oneline -1 -- tooling/grip/ledger/<file>`
  → PRs #5514 (pds), #5603 (ae), #6131 (deep-investigation).
* `mint.test.mjs:549` — `277 of 601 committed rows moved subject/deps` (`from [null,null]`).

No seal sentence may quote "the store folds clean".

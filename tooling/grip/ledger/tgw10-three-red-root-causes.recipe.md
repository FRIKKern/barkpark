# tgw10 — the three red tests: how to re-derive the ACTUAL root causes

Wave 10 verifier `three-red-root-causes`, 2026-07-27. `tooling/grip/**` is BYTE-IDENTICAL between
the primary checkout at `33f07aadf` and `origin/main` at `90ba3dcce` (only three `*.recipe.md` files
differ), so every number below is an origin/main number — re-derive with the commands as written.
This is an INDEX OF HOW TO VERIFY FAST, not a store of truth.

## The verdict D99 got wrong

D99: "All three failures share one root cause … a file without `recipes[]` … earns its own named,
counted `NOT-A-RUN` class." **Measured: the discriminator fixes ONE of three.**

| # | What to re-derive | Command | Expected | Level |
|---|---|---|---|---|
| 1 | the store has THREE shapes, not two | `node -e 'const fs=require("fs"),p=require("path");const d="tooling/grip/ledger";let a=0,b=0,c=0;for(const f of fs.readdirSync(d).filter(x=>/^grip-.*\.json$/.test(x))){const r=JSON.parse(fs.readFileSync(p.join(d,f),"utf8"));if(!Array.isArray(r.recipes))a++;else if(!("run_id" in r))b++;else c++}console.log({noRecipes:a,recipesNoRunId:b,gripOwned:c})'` | `{ noRecipes: 9, recipesNoRunId: 26, gripOwned: 38 }` — 73 total. The **26** are `{claim, rerun}` verifier notes; D99 never names this shape | L3 |
| 2 | binding: 63/62/1 — the ONE the discriminator fixes | `node --test tooling/grip/test/binding.test.mjs 2>&1 \| grep -E '^# (tests\|pass\|fail)\|^not ok'` | `not ok 55` / `# tests 63` `# pass 62` `# fail 1`; error `run.recipes is not iterable` at `binding.test.mjs:57` | L3 |
| 3 | binding goes GREEN under `?? []` (simulated, no repo edit) | `node -e 'import("./tooling/grip/binding.mjs").then(B=>{const fs=require("fs"),p=require("path"),d="tooling/grip/ledger";const rows=[];for(const f of fs.readdirSync(d).filter(n=>n.endsWith(".json")))rows.push(...(JSON.parse(fs.readFileSync(p.join(d,f),"utf8")).recipes??[]));const reg=new Set(B.BINDING_RULES.map(e=>e.rule));let bad=0;for(const v of B.classifyAll(rows).verdicts){if(!reg.has(v.rule)){bad++;continue}if(v.binding_class===null){if(v.rule!=="NO-COMMAND")bad++;continue}if(!B.BINDING_CLASSES.includes(v.binding_class))bad++;if(v.portable_scope!==B.PORTABLE_SCOPES[v.binding_class])bad++;if(typeof v.exit_masked!=="boolean")bad++}console.log("rows",rows.length,"violations",bad)})'` | `rows 601 violations 0` | L3 |
| 4 | ledger: 77/76/1 and the FULL unreadable breakdown today | `node -e 'import("./tooling/grip/ledger.mjs").then(async L=>{const S=await import("./tooling/grip/screen.mjs");const f=L.foldLedger(L.DEFAULT_LEDGER_DIR,{now:new Date().toISOString().replace(/\.\d+Z$/,"Z"),screen:S.screenCommand});const by={};for(const u of f.unreadable)by[u.reason]=(by[u.reason]\|\|0)+1;console.log(f.unreadable.length,JSON.stringify(by),"level_restated",f.stats.level_restated)})'` | `371 {"MALFORMED-RUN":9,"MALFORMED-ROW":202,"LEVEL-SKIP":60,"UNKNOWN-FIELD":45,"REFUSED-COMMAND":48,"VALUE-STORED":7} level_restated 1` — **exactly D99's numbers; the corpus has NOT moved** | L3 |
| 5 | 160 of the 371 survive ANY run-shape discriminator | cross-tab reason × `run_id` presence (same fold, group by `"run_id" in file`) | `NO_RUNID/MALFORMED-RUN 9`, `NO_RUNID/MALFORMED-ROW 202`, **`RUNID/LEVEL-SKIP 60`, `RUNID/UNKNOWN-FIELD 45`, `RUNID/REFUSED-COMMAND 48`, `RUNID/VALUE-STORED 7`** = 160 in grip-OWNED runs | L3 |
| 6 | ledger has a SECOND failing assertion nobody reaches | same fold as #4, read `stats.level_restated` | `1` — row in `grip-20260726T000000Z-v-corpus-identity-call.json`, `stored_level L4` → `derived_level L2` (`git show origin/main:internal/cli/cloud_site_cmd.go \| grep -n …`). A grip-owned file: **survives the discriminator** | L3 |
| 7 | mint: 38/37/1, and the discriminator is a NO-OP for it | `sed -n '556p' tooling/grip/test/mint.test.mjs` | `    for (const row of run.recipes ?? []) {` — the test ALREADY skips the nine. D99's literal fix moves mint by **zero** rows (D99 says line 558; actual 556) | L2 |
| 8 | the 277 split — the number that decides "honest vs softening" | `node -e '…mintRecipe over every grip-*.json; bucket moved rows by ("subject" in row)…'` (full one-liner in the wave-10 verifier report) | `{files:73, rows:601, moved:277, nokey:202, nullsubj:0, rederived:75}` — **stored `subject:null` count is ZERO**; D99's "202 from a stored `subject: null`" is imprecise: the key is ABSENT | L3 |
| 9 | the 202 and the 75 are perfectly separated by `run_id` | same script, cross-tab by `"run_id" in file` | `{runid_nokey:0, runid_rederived:75, norunid_nokey:202, norunid_rederived:0}` — 42 moving files split 26 all-nokey / 16 all-rederived, no file mixed | L3 |
| 10 | the 75 are REAL mint drift in grip-owned runs | inspect samples | e.g. `grip-20260721T150000Z-v2-tickets-idor-fixshape.json`: stored `api/test/…/keys_test.exs` → re-derived `test/…/keys_test.exs` (a `cd api &&` resolution difference). This is the class a rescoping could HIDE | L3 |
| 11 | pinning to `CENSUS_RUN_FILES` would hide all 75 | the three pinned files are `grip-20260721T034616Z-…`, `…054733Z-…`, `…054846Z-…`; none appears in the 16 rederived files | the regression floor becomes vacuous w.r.t. every moving grip-owned row | L3 |

## The tally a builder needs

A `recipes[]`-presence discriminator (D99's literal wording) fixes **binding only** — mint already
guards, and the ledger fold already emits `MALFORMED-RUN` for exactly those 9 (`ledger.mjs:684-685`);
renaming it `NOT-A-RUN` moves 9 of 371. A `run_id`-presence discriminator fixes binding, removes
211/371 from ledger (**160 remain**, plus `level_restated 1`) and 202/277 from mint (**75 remain**).
**S1's criterion 1 (`# fail 0`) is NOT reachable from criteria 2-5.**

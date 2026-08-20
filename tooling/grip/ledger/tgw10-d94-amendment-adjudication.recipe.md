# tgw10 — the D94 amendment: how to re-derive the seal predicate's two defects

Wave 10 verifier `d94-amendment-adjudication`, 2026-07-27, against `origin/main` @ `8ba4af1c3`.
INDEX OF HOW TO VERIFY FAST, not a store of truth. Every row re-runs in seconds.

## Defect 1 — clause (b) ∧ clause (c) is unsatisfiable: the root is in its own ready pool

| # | What to re-derive | Command | Expected | Level |
|---|---|---|---|---|
| 1 | the root is a claimable row in the live pool | `bp task ready --all -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['docs'];g=[x for x in d if x['doc_id'].startswith('tgw') or x['doc_id'].startswith('truth-grip')];print('pool',len(d),'ns',len(g),'root',any(x['doc_id']=='truth-grip-epic' for x in g))"` | `pool 861 ns 80 root True` — namespace-minus-root is 79 | L1 (server) |
| 2 | the root's own lifecycle | `bp task get truth-grip-epic -o json` | `lifecycle_status: open`, `criteria 0/4`, `child_count 119` | L1 |
| 3 | D94 verbatim (both clauses in one read) | `git show origin/main:.claude/workflows/bp-truth-grip-charter.md \| sed -n '1073,1090p'` | (b) "ZERO rows in the `tgw*`/`truth-grip*` namespace carry a claimable lifecycle … verified by intersecting the namespace with a live `bp task ready --all`"; (c) "the root closes LAST" | L2 |
| 4 | `--all` does not truncate (no FALSE ZERO) | `bp task ready --all -o json \| grep -c '"doc_id"'; bp task ready --limit 2000 -o json \| grep -c '"doc_id"'; bp task ready --offset 855 --limit 50 -o json \| grep -c '"doc_id"'; bp task ready --offset 900 --limit 50 -o json \| grep -c '"doc_id"'` | `861 / 861 / 6 / 0` — the offset walk lands exactly on 861, so clause (b) cannot report a false zero at this pool size | L1 |
| 5 | prior-art seal predicate excludes the root BY CONSTRUCTION | `git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs \| sed -n '125,140p'` | `const children = fixture ? fixture.children : fetchRoster(EPIC)` — it evaluates the ROSTER, never the epic row; the root is structurally outside its own predicate | L2 |
| 6 | …but its roster method is the one D94 forbids | `git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs \| sed -n '119,120p'` | `fetchRoster = (parentId) => q([['filter[parent_id]', parentId] …` — direct children only; D94 forbids a `child_count`-derived census because 7 `tgw*` rows hang under `tgw1-workflow-gate-wiring` | L2 |
| 7 | no server-side pre-close hook exists to evaluate (b) "at the instant of close" | `git show origin/main:api/lib/barkpark/tasks/close.ex \| grep -n 'before_publish\|def close'` | one `def close/3` at :36 and no hook — an "instant of close" evaluation can only be a client-side check run immediately before `bp task close`, i.e. root-exclusion plus an ordering assertion | L2 |

## Defect 2 — an absence-shaped fact adjudicates as FAILED and does not stand

| # | What to re-derive | Command | Expected | Level |
|---|---|---|---|---|
| 8 | the executor's own rule | `git show origin/main:tooling/grip/rerun.mjs \| sed -n '588,590p'` | `if (exit === 1) return ok(VERDICT.FAILED, "ran fine and matched nothing — a genuine no-match");` | L2 |
| 9 | FAILED is not a standing verdict | `git show origin/main:tooling/grip/adjudicate.mjs \| sed -n '81,86p'` | `const STANDING = new Set([VERDICTS.ADMITTED, VERDICTS.DEMOTED]);` — FAILED is absent | L2 |
| 10 | **criterion 4's own charter evidence reds** | `node -e "import('/ABS/tooling/grip/adjudicate.mjs').then(async m=>{const r=m.adjudicate({subject:'truth-grip-epic:criterion-4',claim:'wave 1 record.mjs persists nothing',evidence:'D98',rerun:\"git show 1514f52cb:tooling/grip/record.mjs \| grep -n 'writeFileSync\\\\\|node:fs'\",level:'L3'},{});console.log(r.verdict,m.stands(r.verdict))})"` (run from the repo root — `opts.root` does NOT set the child cwd) | `FAILED false` — D98's ratified criterion-4 evidence cannot be stamped under an unamended D94(a) | L3 |
| 11 | grip ALREADY ships the right predicate | `git show origin/main:tooling/grip/rerun.mjs \| sed -n '843,847p'` | `export function admitsAbsenceClaim(result) { … return result.verdict === VERDICT.FAILED \|\| result.verdict === VERDICT.WRONG_ROUTE; }` | L2 |
| 12 | **"just accept FAILED" is a SOFTENING — the four-case proof** | run `screenedRerun` over: `git show origin/main:.claude/workflows/wild-bulk-cycle.workflow.js \| grep -c gateFactProvenance` · `curl -sS --max-time 4 http://127.0.0.1:59999/nope` · `diff tooling/grip/rerun.mjs tooling/grip/screen.mjs` · `grep -n` | `FAILED/absence=true` · `HOST-UNREACHABLE/false` · `FAILED/false (131489 bytes — "a DIFFERENCE, never an absence")` · `NULL-READ/false`. A bare `verdict === FAILED` test admits the 131KB diff as proof of absence | L3 |
| 13 | `adjudicate()` DROPS the polarity | `git show origin/main:tooling/grip/adjudicate.mjs \| sed -n '253,265p'` | `ruling({...})` returns `{verdict,label,reasons,rejections,fact,level,rerun,note,conflict}` — no `admits`, no raw result. A seal check built on `adjudicate()` alone **cannot** adjudicate an absence-shaped fact | L2 |
| 14 | the criteria that are absence-shaped | `bp task get truth-grip-epic -o json` | criterion 4 is literally "verified by the **absence** of any new persisted corpus"; criterion 3's clause (b) is absence-shaped too (`grep -c VERIFY_SCHEMA` → 0, D97) | L1 |

## The gotcha that ate two runs

`opts.root` is NOT a cwd. `rerun.mjs:359` spawns `/bin/sh -c` and `:652` only uses `root` for scope
classification. Running the probe from a scratch dir turned every `git` rerun into
`exited 128: fatal: not a git repository` — including the POSITIVE control, which then read FAILED
and looked like the very defect under test. Any seal check must assert its own cwd or pass `cwd`
explicitly. (`git show origin/main:tooling/grip/rerun.mjs | sed -n '355,362p;650,654p'`)

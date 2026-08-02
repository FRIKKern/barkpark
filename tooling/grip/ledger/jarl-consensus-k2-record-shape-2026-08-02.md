# jarl-innleggene · consensus K=2 + ratings record shape — re-derivation recipes

Tree: local `/Users/frikkjarl/Documents/GitHub/barkpark`, `tooling/lib/consensus.mjs`
unchanged since 2026-07-24 01:18. Server probed: `https://guerrilla.barkpark.cloud`
(admin tier, workspace/project `default`, dataset `production`), 2026-08-01T23:07–23:14Z.

## 1. consensus.mjs at K=2 — contested is BLIND on a small rubric scale

```
node -e 'import("/Users/frikkjarl/Documents/GitHub/barkpark/tooling/lib/consensus.mjs").then(({numericConsensus:n,categoricalConsensus:c})=>{
for (const v of [[4,4],[4,5],[3,5],[1,5]]) console.log("band25",JSON.stringify(v),JSON.stringify(n(v)));
for (const v of [[4,4],[4,5],[3,5],[1,5]]) console.log("band1 ",JSON.stringify(v),JSON.stringify(n(v,{band:1})));
for (const v of [["PASS","FAIL"],["FAIL","PASS"]]) console.log("cat   ",JSON.stringify(v),JSON.stringify(c(v)));})'
```

Expect, on the DEFAULT `band = 25` (consensus.mjs:49 — tuned for criticality 0–100,
registered as the cody binding `consensus_band`, `tooling/cody/bindings.json:8`):
`[1,5]` (maximally opposite verdicts on a 1–5 rubric) returns
`{"value":3,"agreement":0.92,"contested":false}`. **`contested` NEVER fires on a
1–5 scale at the default band** — the maximum possible sd is 2, so
`1 − sd/25 ≥ 0.92`, and `spread ≤ 4 < 25`.

With `band:1` the flag behaves: `[3,5]` and `[1,5]` → `contested:true`; `[4,5]` →
`agreement 0.5, contested:false` (the test is `agreement < 0.5`, strict).

`categoricalConsensus` is the K=2-safe half (consensus.mjs:71: `share <= 0.5`):
any 2-way split → `contested:true`. But the winner is `ranked[0]` after a stable
sort on a plain object, so a 1–1 tie resolves to the FIRST-INSERTED label —
`["PASS","FAIL"] → "PASS"`, `["FAIL","PASS"] → "FAIL"`. **Judge order decides the
verdict on every tie unless a reconcile rule overrides.**

Rounding bias (consensus.mjs:57, `Math.round(median(xs))`; median of two = mean):
```
node -e 'import("/Users/frikkjarl/Documents/GitHub/barkpark/tooling/lib/consensus.mjs").then(({numericConsensus:n})=>{for(const v of [[3,4],[4,5],[1,2]])console.log(JSON.stringify(v),n(v).value)})'
```
Expect `[3,4]→4`, `[4,5]→5`, `[1,2]→2`: every 1-apart disagreement rounds UP.
Half a point of free inflation on every split pair — the same failure family as
GRADE-CRITIQUE's false-100.

## 2. Custom `ratings` field survives the task schema — verified live, then deleted

```
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -s -X POST "https://guerrilla.barkpark.cloud/w/default/p/default/v1/data/mutate/production" \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"mutations":[{"create":{"type":"task","kind":"task","lifecycle_status":"open","title":"PROBE","ratings":[{"judge":"a","slug":"polyflor-ordre","dims":{"sprak":4,"kilde":3},"note":"x"}],"probe_scalar":42}}]}'
bp doc get task drafts.<id> --perspective raw -o json
bp task get drafts.<id> -o json
curl -s -X POST "…/v1/data/mutate/production" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"mutations":[{"delete":{"id":"drafts.<id>","type":"task"}}]}'
```

Expect: create 200, and `ratings` (array of objects, with a NESTED `dims` map)
round-trips byte-identical through `--perspective raw` AND appears inside
`doc.content.ratings` on the `/v1/tasks` view (`bp task get`). Unknown scalars
(`probe_scalar:42`) survive too. **No field-stripping — a top-level `ratings`
array is a legal record shape.**

Gotchas that cost real time:
- `bp doc create task` alone ALWAYS fails `validation_failed` — it does not inject
  the required `kind:"task"` / `lifecycle_status:"open"`. Use `bp task create`
  (which injects them) or raw `/v1/data/mutate` with both fields set.
- `bp`'s HTTP client timeout is ~30s (`bp task create … → context deadline
  exceeded` at 30.17s wall) while guerrilla creates take 4–11s normally and were
  measured at 23s once. Raw curl with `--max-time 120` is the reliable path for a
  40-write rating round.
- One create out of seven returned `internal_error` / HTTP 500 after 23.4s and
  succeeded on retry with the identical body. **Retry-once is mandatory** in any
  batch rating script.
- `delete` takes the `drafts.` id. The bare published id 404s while the doc is an
  unpublished draft.
- Deletes must be issued ONE PER REQUEST: a single atomic batch of 7 deletes
  returned `not_found` and rolled all of them back.

## 3. Append is lock-free — the K=2 independent-judge primitive

`api/lib/barkpark/content/mutations.ex:288-305` accepts Phase-1B patch ops
`setIfMissing / unset / inc / dec / append / prepend`. (There is NO Sanity-style
`insert`/`after` op — sending one returns HTTP 400 `malformed`.)

```
curl -s -X POST "…/v1/data/mutate/production" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"mutations":[{"patch":{"id":"drafts.<id>","type":"task","append":{"ratings":[{"judge":"b","dims":{"sprak":1}}]}}}]}'
```

Expect 200 in ~0.2–1.0s with the appended element present and the prior elements
intact — no `ifRevisionID`, no read-modify-write. Two judges can each append their
own record to the same task concurrently without clobbering. `type` is REQUIRED in
the patch body.

## 4. Publish is walled — keep rating records as DRAFTS

```
bp doc publish task drafts.<id> -o json
```

Expect `{"error":{"code":"label_spine", … "Give the document a non-trivial
description and 1-12 weighted tags — [{tag, strength 1-100 (all distinct),
rationale}]"}}`. A bare ratings task cannot be published. Drafts are fully
readable via `--perspective raw` and via `bp task get`, so the rating round should
never publish.

## 5. Known side effect — the GitHub mirror leaks probe tasks

After the first `append` patch the probe doc grew
`"github":{"issue":9002,"repo":"FRIKKern/barkpark","state":"synced"}`. Deleting the
bp doc did NOT close the issue.

```
gh issue list --repo FRIKKern/barkpark --search "PROBE in:title" --state open --json number,title --limit 20
```

Expect a long tail of orphaned `probe` issues from earlier sessions (8915, 8121,
8120, 8119 … 5268). #9002 was closed manually at the end of this run. A 20-post ×
2-judge rating round filed as tasks will mint ~20 GitHub issues; budget for the
cleanup or file the ratings on documents that are not task-typed.

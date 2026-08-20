# cch-w63 — Law-0 close list: re-derivation recipe (2026-08-09T16:54:49Z)

Verifier v5-law0-closes. Every number below re-derives from these commands. No number is
quoted from `bp task get` (drafts-inflated) or from the checkout's stale seal predicate.

## 1. The denominator (published query, limit=1000)

```
bp doc query task --filter 'parent_id == "cloud-console-hardening-epic"' \
  --fields '_id,lifecycle_status' --limit 1000 -o json
```
2026-08-09T16:54:49Z → total 826 · open 416 · done 345 · cancelled 64 · considering 1
· in_progress 0. LIVE (open+in_progress) = **416**.

## 2. The candidate population (single unmet criterion, merge/lead-gated)

```
bp doc query task --filter 'parent_id == "cloud-console-hardening-epic"' \
  --fields '_id,title,lifecycle_status,acceptance_criteria' --limit 1000 -o json \
| python3 -c 'import json,sys,re
docs=json.load(sys.stdin)["documents"]
for r in docs:
  if r["lifecycle_status"] not in ("open","in_progress"): continue
  acs=r.get("acceptance_criteria") or []
  u=[a for a in acs if not a.get("met")]
  if acs and len(u)==1 and re.search(r"MERGE-GATED|LEAD-GATED",u[0]["criterion"]):
    print(r["_id"], f"{len(acs)-1}/{len(acs)}")'
```
→ **16** rows.

## 3. Row → PR, derived from the PR's own branch name (never from criteria prose)

Branches are `loop-epic/<slugified row TITLE>-<n>[-r]`. Recipe:

```
gh pr list --state all --limit 900 \
  --json number,headRefName,state,mergeCommit \
  --jq '.[]|[.number,.state,.headRefName,(.mergeCommit.oid//"-")]|@tsv' > prs_all.tsv
# then difflib-match slugify(row.title) against the branch tail
```

Confirmation leg — the PR's own body must name the row's full slug:

```
gh pr view <n> --json body,title --jq '.title+" "+.body' | grep -oE 'cch-w[0-9]+[a-z0-9-]*' | sort -u
```

## 4. Ancestry

```
for sha in <merge shas>; do echo "$sha $(gh api repos/FRIKKern/barkpark/compare/$sha...main --jq .status)"; done
```
All 13 checked shas → `ahead`. NOTE: PR branch-tip shas return `diverged` (squash merge);
only the `mergeCommit.oid` is ancestor-checkable.

## 5. Required contexts on the PR head

```
sha=$(gh api repos/FRIKKern/barkpark/pulls/<n> --jq .head.sha)
gh api repos/FRIKKern/barkpark/commits/$sha/check-runs \
  --jq '.check_runs[]|select(.name|test("^(Cloud|Console|Elixir|Security) gate$"))|[.name,.conclusion]|@tsv' | sort -u
```

## 6. The criteria-less live row

```
… --fields '_id,title,lifecycle_status,acceptance_criteria' … | python3 -c 'import json,sys
for r in json.load(sys.stdin)["documents"]:
  if r["lifecycle_status"] in ("open","in_progress") and not r.get("acceptance_criteria"): print(r["_id"], r["_createdAt"], r["title"])'
```
→ exactly one: `task-22709a64d614d119`, created 2026-08-09T16:22:07Z, empty description too.
`gh api repos/FRIKKern/barkpark/pulls/11292 --jq .merged_at` → 2026-08-09T14:08:36Z, i.e. the
row post-dates cch-w61-s3's "criteria-less open 0" close by 2h13m. Not a survivor — a regression.

## 7. cch-w58-s2's true score

```
git show origin/main:cloud/lib/barkpark_cloud/workers/autoupdate_rollout_worker.ex | grep -n '202\|409\|mark_autoupdate_triggered'
```
`:170 {:ok, 409, _body} ->` / `:171 _ = Registry.mark_autoupdate_triggered(bp)` — a 409 DOES
stamp. Criteria 0,1,2,3 all carry the identical WITHDRAWN notice and are all false against
shipped bytes. The row is **3/8**, not D745's 6/8.

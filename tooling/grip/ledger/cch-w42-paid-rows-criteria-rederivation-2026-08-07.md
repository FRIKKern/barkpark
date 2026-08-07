# Re-derivation recipes — wave 42 verifier [paid-rows-criteria]

Every integer and every verdict below has the one command that regenerates it.
Ledger note only. No repo behaviour depends on this file.

## 1. The twelve rows' unmet criteria (the assignment's MUST RUN, widened to twelve)

```
for t in cch-w37-s1-invalid-precedence-details-win \
         cch-w37-s2-six-refusals-name-their-authority \
         cch-w37-s4-binding-census-add-and-remove \
         cch-w37-s6-operator-console-stops-checking-forever \
         cch-w39-s4-the-registration-sweep-stops-greening-on-a-candidate-it-never-examined \
         cch-w39-s5-the-spec-gate-packet-is-refreshed-and-the-ledger-is-disposed \
         cch-w40-s1-the-refusal-default-inverts-and-three-authored-causes-converge \
         cch-w40-s5-the-route-table-stops-documenting-a-tier-seven-routes-do-not-enforce \
         cch-w40-s6-the-failure-classifier-stops-naming-a-party-and-a-remedy-it-never-determined \
         cch-w41-s1-the-two-server-authority-predicates-are-proved-single \
         cch-w41-s2-v1-me-states-the-team-authority-the-gate-will-enforce \
         cch-w41-s3-the-admin-limb-gets-a-guard-that-can-lose ; do
  bp task get "$t" -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];ac=d["content"]["acceptance_criteria"];print(d["doc_id"],"lifecycle="+str(d.get("lifecycle_status")),"met=%d/%d"%(sum(1 for c in ac if c.get("met")),len(ac)));[print("  UNMET",i,c["criterion"][:300]) for i,c in enumerate(ac) if not c.get("met")]'
done
```

Expected shape: eleven rows read exactly one UNMET; `cch-w39-s4` reads TWO
(index 8 = a PR-body severity statement, NOT a merge gate; index 9 = the merge gate).

## 2. Three of the merge criteria are COMPOUND — they name a companion row

`cch-w40-s1` → `task-ed706f4e1c616f89` · `cch-w40-s5` → `task-78c7fdb9783e3459` ·
`cch-w40-s6` → `task-fda5b6f19f1e06c9`.

```
for t in task-ed706f4e1c616f89 task-78c7fdb9783e3459 task-fda5b6f19f1e06c9; do
  bp task get $t -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];ac=(d["content"] or {}).get("acceptance_criteria") or [];print(d["doc_id"],d.get("lifecycle_status"),"met=%d/%d"%(sum(1 for c in ac if c.get("met")),len(ac)),d.get("parent_id"))'
done
```

`task-fda5b6f19f1e06c9`'s parent is `cch-instruments-epic`, NOT the console epic —
it is outside the live-row denominator below.

## 3. The live-row denominator, from `.children`

```
bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
python3 -c '
import json,collections
d=json.load(open("/tmp/epic.json"))
ch=d["children"]
pub=[c for c in ch if not c["doc_id"].startswith("drafts.")]
print("children",len(ch),"child_count",d.get("child_count"))
print("published by lifecycle:",collections.Counter(c["lifecycle_status"] for c in pub))
print("LIVE open+in_progress =",sum(1 for c in pub if c["lifecycle_status"] in ("open","in_progress")))
'
```

Derived 2026-08-07: 525 children (== `child_count`), 512 published-doc + 13 draft-doc.
Published: 257 done / 210 open / 41 cancelled / 3 in_progress / 1 considering.
**213 = 210 open + 3 in_progress** — the survey's number, and it EXCLUDES the single
`considering` row (`cloud-console-operator-audit-log`). Including it gives 214.
Closing the twelve takes 213 → 201.

## 4. Draft twins: the disposal precedent is CANCEL, and it is 9-for-9

```
python3 -c '
import json
d=json.load(open("/tmp/epic.json")); ids={c["doc_id"] for c in d["children"]}
for c in d["children"]:
    i=c["doc_id"]
    if i.startswith("drafts."):
        print("%-72s %-11s twin=%s"%(i,c["lifecycle_status"],i[7:] in ids))
'
```

Ten draft rows have a published twin; nine are `cancelled`. The tenth is
`drafts.cch-w41-s3-the-admin-limb-gets-a-guard-that-can-lose`, still `in_progress`.

Proof it is the SAME document, not an independently-scoped row:

```
bp task get drafts.cch-w41-s3-the-admin-limb-gets-a-guard-that-can-lose -o json > /tmp/d41.json
bp task get cch-w41-s3-the-admin-limb-gets-a-guard-that-can-lose -o json > /tmp/p41.json
python3 -c '
import json,hashlib
for f in ("/tmp/d41.json","/tmp/p41.json"):
    d=json.load(open(f))["doc"]; c=d["content"]
    b=str(c.get("body") or "")
    print(d["doc_id"], d.get("status"), "body_sha", hashlib.sha1(b.encode()).hexdigest()[:12],
          "criteria", len(c["acceptance_criteria"]), "assignee", d.get("assignee"))
'
```

Identical `body_sha 57d1cd888814`, identical 10 criteria, identical assignee.
→ CANCEL. Closing it credits PR #10126 twice.

## 5. Merge + named-gate verification for all twelve

```
git fetch origin main
for s in d5bbd6c36 7b5e54b5d 9e39c60c0 62b5847ed 64a1f5969 3df1c0830 \
         209ec49fb 8be3dedea c7c3b803a f020b0741 f85b944c4 a476352a4; do
  printf "%s " "$s"; git merge-base --is-ancestor $s origin/main && echo ON || echo OFF
done

for n in 9917 9918 9920 9922 10007 10008 10083 10087 10088 10124 10125 10126; do
  sha=$(gh pr view $n --json headRefOid -q .headRefOid)
  echo "== #$n ${sha:0:9}"
  gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" \
    -q '.check_runs[] | "   \(.name) => \(.conclusion)"' | grep -Ei "console gate|cloud gate|spec gate"
done
```

All twelve merge commits are ancestors of `origin/main`; all twelve PR heads carry
`Console gate`, `Cloud gate` and `Required-check spec gate` = `success`.

## 6. The pairing trap this file exists to record

```
for n in 9917 9918 9920 9922 10007 10008 10083 10087 10088 10124 10125 10126; do
  printf "#%s -> " $n; gh pr view $n --json body -q .body | grep -iE "^Task: " | head -1
done
```

Eleven PRs name their row. **#9917 names `cch-w36-s6-invalid-precedence-details-win`**,
a row that is `published` + `cancelled` at 0/13 — the predecessor slug. The row of
record `cch-w37-s1-invalid-precedence-details-win` is paired by its OWN stamped
evidence, not by the PR's `Task:` line:

```
bp task get cch-w37-s1-invalid-precedence-details-win -o json | python3 -c \
 'import sys,json,re;print(sorted(set(re.findall(r"#(\d{4,5})",json.dumps(json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"])))))'
```

→ `['9917']`. A `Task:`-line-only pairing script would have missed this row entirely.

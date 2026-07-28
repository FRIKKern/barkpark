# deadlock-detector-live — re-derivation recipes (2026-07-28)

Verifier slice `deadlock-detector-live`, honest-gates wave 4. Every row is one
literal command that re-derives the fact from scratch. Repo checkout at
`b43f5d7ff`; all reads are live against `FRIKKern/barkpark`.

## R1 — enforced=true spec (the input every other row uses)

```
cd /Volumes/SATECHI/github/barkpark && jq '.enforced=true' .github/required-checks.json > /tmp/e.json
```

## R2 — detector returns EXIT 3 and NAMES the missing context on a frozen head

```
for n in 5754 6055; do S=$(gh pr view $n --json headRefOid -q .headRefOid); \
  bash scripts/required-checks-verify.sh --spec /tmp/e.json --sha $S --deadlock; echo "EXIT=$?"; done
```
Expect: `DEADLOCK: ... missing: Elixir gate` on stderr, `EXIT=3`.

## R3 — detector returns EXIT 0 on a head rendering both required names

```
S=$(gh pr view 6414 --json headRefOid -q .headRefOid)
bash scripts/required-checks-verify.sh --spec /tmp/e.json --sha $S --deadlock; echo "EXIT=$?"
```
Expect: `ok every required context appears in the 16 name(s) ...`, `EXIT=0`.

## R4 — a required context in state `cancelled` still returns EXIT 0 (live)

```
S=5ea4cb4f493ad9c01d4b53c98d50bf2042c53996   # PR #6651 head, branch hgw4-probe-topic
gh api "repos/FRIKKern/barkpark/commits/$S/check-runs?per_page=100" \
  --jq '.check_runs[]|select(.name=="PR references an active task")|"\(.name) :: \(.conclusion)"'
bash scripts/required-checks-verify.sh --spec /tmp/e.json --sha $S --deadlock; echo "EXIT=$?"
```
Expect: `PR references an active task :: cancelled` and `EXIT=0` — the detector's
output is byte-shaped identically to R3 apart from the name count.

## R5 — `Elixir gate` never concludes `cancelled` (census, post-shim)

```
gh run list --workflow elixir.yml --limit 100 \
  --json databaseId,conclusion,createdAt,headSha \
  -q '.[]|select(.createdAt > "2026-07-27T22:44:48Z")|"\(.databaseId) \(.conclusion) \(.headSha)"' > /tmp/postshim.txt
while read id concl sha; do \
  j=$(gh api repos/FRIKKern/barkpark/actions/runs/$id/jobs --jq '[.jobs[]|select(.name=="Elixir gate")|.conclusion]|join(",")'); \
  echo "$id run=$concl gate=[$j]"; done < /tmp/postshim.txt
```
Expect: zero `gate=[cancelled]`; every `run=cancelled` row carries `gate=[]`
(the aggregator is last in the DAG and is cancelled before it starts, so no
check-run is created at all).

## R6 — cancelled runs are overwhelmingly `push`, not `pull_request`

```
gh run list --workflow elixir.yml --limit 100 --json conclusion,createdAt,event \
  -q '.[]|select(.createdAt > "2026-07-27T22:44:48Z" and .conclusion=="cancelled")|.event' | sort | uniq -c
```
Expect (2026-07-28): `31 push`, `1 pull_request`.

## R7 — the detector discards the conclusion it already collects

```
sed -n '210,215p;240,250p' scripts/required-checks-verify.sh
```
`rendered_names` emits `name<TAB>conclusion`; `deadlock_check` matches against
`cut -f1 <<<"$names"` only. The conclusion column is computed and thrown away —
a conclusion-classifying exit row is a local change, not new plumbing.

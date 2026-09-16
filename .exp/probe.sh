#!/usr/bin/env bash
set -u
O=FRIKKern; N=barkpark
mk(){ printf 'query($o:String!,$n:String!,$f:Int!,$a:String){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:$f,after:$a,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{ %s }}}}' "$1"; }
F_CTRL='number mergeable mergeStateStatus updatedAt headRefOid isDraft'
F_NOMSS='number mergeable updatedAt headRefOid isDraft'
walk(){ # label fields pagesize
  local lab="$1" Q after="" page=0 total=0 unk=0 t0 t1 out rc nr u T0 T1
  Q="$(mk "$2")"; T0=$(date +%s.%N)
  while :; do
    page=$((page+1)); t0=$(date +%s.%N)
    if [ -n "$after" ]; then out="$(gh api graphql -f query="$Q" -F o=$O -F n=$N -F f="$3" -F a="$after" 2>&1)"; rc=$?
    else out="$(gh api graphql -f query="$Q" -F o=$O -F n=$N -F f="$3" 2>&1)"; rc=$?; fi
    t1=$(date +%s.%N)
    if [ $rc -ne 0 ]; then printf '  %s page %s rc=%s %6.2fs ERR=%s\n' "$lab" "$page" "$rc" "$(echo "$t1-$t0"|bc)" "$(head -1 <<<"$out"|cut -c1-60)"; return 1; fi
    nr=$(jq '.data.repository.pullRequests.nodes|length' <<<"$out")
    u=$(jq '[.data.repository.pullRequests.nodes[]|select(.mergeable=="UNKNOWN")]|length' <<<"$out")
    total=$((total+nr)); unk=$((unk+u))
    printf '  %s page %s rc=0 %6.2fs rows=%s unknown=%s\n' "$lab" "$page" "$(echo "$t1-$t0"|bc)" "$nr" "$u"
    [ "$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"$out")" = "true" ] || break
    after="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"$out")"
    [ "$page" -lt 40 ] || break
  done
  T1=$(date +%s.%N)
  printf '  %s TOTAL rows=%s unknown=%s wall=%.1fs\n' "$lab" "$total" "$unk" "$(echo "$T1-$T0"|bc)"
}
echo "=== A: control fields (mergeable+mergeStateStatus) size 25 ==="; walk CTRL25 "$F_CTRL" 25 || true
echo "=== B: control fields size 10 ==="; walk CTRL10 "$F_CTRL" 10 || true
echo "=== C: control fields size 5 ==="; walk CTRL5 "$F_CTRL" 5 || true
echo "=== D: NO mergeStateStatus, size 25 (cheap but does it answer?) ==="; walk NOMSS25 "$F_NOMSS" 25 || true
echo "=== E: per-PR mergeable+mergeStateStatus+rollup, 8 PRs ==="
Q1='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){ number mergeable mergeStateStatus updatedAt headRefOid isDraft }}}'
nums="$(gh api graphql -f query="$(mk "$F_NOMSS")" -F o=$O -F n=$N -F f=8 -q '.data.repository.pullRequests.nodes[].number' 2>/dev/null)"
T0=$(date +%s.%N)
for num in $nums; do
  t0=$(date +%s.%N); out="$(gh api graphql -f query="$Q1" -F o=$O -F n=$N -F num="$num" 2>&1)"; rc=$?; t1=$(date +%s.%N)
  printf '  #%-6s rc=%s %6.2fs mergeable=%s mss=%s\n' "$num" "$rc" "$(echo "$t1-$t0"|bc)" "$(jq -r '.data.repository.pullRequest.mergeable' <<<"$out" 2>/dev/null)" "$(jq -r '.data.repository.pullRequest.mergeStateStatus' <<<"$out" 2>/dev/null)"
done
T1=$(date +%s.%N); printf '  per-PR 8 rows wall=%.1fs\n' "$(echo "$T1-$T0"|bc)"

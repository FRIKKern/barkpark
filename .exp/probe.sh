#!/usr/bin/env bash
set -u
O=FRIKKern; N=barkpark
Q_LIGHT_FIXED='query($o:String!,$n:String!,$f:Int!,$a:String){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:$f,after:$a,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{ number mergeable updatedAt headRefOid isDraft }}}}'
Q_ONE='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){ number mergeStateStatus commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{name conclusion completedAt status} ... on StatusContext{context state createdAt}}}}}}} }}}'
echo "=== full walk with the FIXED light query (page size 25) ==="
after=""; page=0; total=0
while :; do
  page=$((page+1)); t0=$(date +%s.%N)
  if [ -n "$after" ]; then out="$(gh api graphql -f query="$Q_LIGHT_FIXED" -F o=$O -F n=$N -F f=25 -F a="$after" 2>&1)"; rc=$?
  else out="$(gh api graphql -f query="$Q_LIGHT_FIXED" -F o=$O -F n=$N -F f=25 2>&1)"; rc=$?; fi
  t1=$(date +%s.%N)
  if [ $rc -ne 0 ]; then printf 'page %s rc=%s %.2fs ERR=%s\n' "$page" "$rc" "$(echo "$t1-$t0"|bc)" "$(head -1 <<<"$out"|cut -c1-80)"; break; fi
  nr=$(jq '.data.repository.pullRequests.nodes|length' <<<"$out"); total=$((total+nr))
  unk=$(jq '[.data.repository.pullRequests.nodes[]|select(.mergeable=="UNKNOWN")]|length' <<<"$out")
  printf 'page %s rc=0 %6.2fs rows=%s unknown=%s\n' "$page" "$(echo "$t1-$t0"|bc)" "$nr" "$unk"
  [ "$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"$out")" = "true" ] || break
  after="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"$out")"
  CONF="$CONF $(jq -r '[.data.repository.pullRequests.nodes[]|select(.mergeable=="CONFLICTING")|.number]|.[]' <<<"$out" | tr '\n' ' ')"
done 2>/dev/null
echo "TOTAL rows=$total"
echo "=== per-PR query WITH mergeStateStatus + rollup, 6 PRs ==="
for num in $(gh api graphql -f query="$Q_LIGHT_FIXED" -F o=$O -F n=$N -F f=25 -q '.data.repository.pullRequests.nodes[].number' 2>/dev/null | head -6); do
  t0=$(date +%s.%N)
  out="$(gh api graphql -f query="$Q_ONE" -F o=$O -F n=$N -F num="$num" 2>&1)"; rc=$?
  t1=$(date +%s.%N)
  printf '  #%-6s rc=%s %6.2fs mss=%s\n' "$num" "$rc" "$(echo "$t1-$t0"|bc)" "$(jq -r '.data.repository.pullRequest.mergeStateStatus' <<<"$out" 2>/dev/null)"
done

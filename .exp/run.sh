set -u
Q_FULL='query($o:String!,$n:String!,$f:Int!,$a:String){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:$f,after:$a,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{ number mergeable mergeStateStatus updatedAt headRefOid isDraft }}}}'
Q_NOMERGE='query($o:String!,$n:String!,$f:Int!,$a:String){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:$f,after:$a,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{ number mergeStateStatus updatedAt headRefOid isDraft }}}}'
run() { # label query first after
  local t0 t1 rc out
  t0=$(python3 -c 'import time;print(time.time())')
  out="$(gh api graphql -f query="$2" -F o=FRIKKern -F n=barkpark -F f="$3" ${4:+-F a="$4"} 2>&1)"; rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  printf '%-28s rc=%s  %.1fs  ' "$1" "$rc" "$(python3 -c "print($t1-$t0)")"
  if [ $rc -eq 0 ]; then
    printf 'rows=%s hasNext=%s\n' "$(jq '.data.repository.pullRequests.nodes|length' <<<"$out")" "$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"$out")"
    printf '%s' "$out" | jq -r '.data.repository.pullRequests.pageInfo.endCursor' > .exp/cursor_$1
  else
    printf 'ERR=%s\n' "$(printf '%s' "$out" | head -2 | tr '\n' ' ' | cut -c1-140)"
  fi
}

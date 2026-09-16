#!/usr/bin/env bash
set -u
O=FRIKKern; N=barkpark
q() { # <fields>
  printf 'query($o:String!,$n:String!,$f:Int!,$a:String){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:$f,after:$a,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{ %s }}}}' "$1"
}
F_CTRL='number mergeable mergeStateStatus updatedAt headRefOid isDraft'
F_NOMSS='number mergeable updatedAt headRefOid isDraft'
F_NOMRG='number mergeStateStatus updatedAt headRefOid isDraft'
F_NEITHER='number updatedAt headRefOid isDraft'
one() { # label query first after -> prints; sets CUR
  local t0 t1 rc out lab="$1" Q="$2" FIRST="$3" AFT="${4:-}"
  t0=$(date +%s.%N)
  if [ -n "$AFT" ]; then
    out="$(gh api graphql -f query="$Q" -F o=$O -F n=$N -F f="$FIRST" -F a="$AFT" 2>&1)"; rc=$?
  else
    out="$(gh api graphql -f query="$Q" -F o=$O -F n=$N -F f="$FIRST" 2>&1)"; rc=$?
  fi
  t1=$(date +%s.%N)
  CUR=""
  if [ $rc -eq 0 ]; then
    CUR="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"$out")"
    printf '%-26s first=%-3s rc=0 %6.2fs rows=%s\n' "$lab" "$FIRST" "$(echo "$t1-$t0"|bc)" "$(jq '.data.repository.pullRequests.nodes|length' <<<"$out")"
  else
    printf '%-26s first=%-3s rc=%s %6.2fs ERR=%s\n' "$lab" "$FIRST" "$rc" "$(echo "$t1-$t0"|bc)" "$(head -1 <<<"$out" | cut -c1-90)"
  fi
  return 0
}
variant() { # label fields first
  local lab="$1" Q c1
  Q="$(q "$2")"
  one "$lab p1" "$Q" "$3"; c1="$CUR"
  if [ -z "$c1" ] || [ "$c1" = "null" ]; then echo "  $lab: no page-1 cursor, skipping page 2"; return; fi
  local i
  for i in 1 2 3; do one "$lab p2/$i" "$Q" "$3" "$c1"; done
}
echo "=== (c) CONTROL: full light query, first=25 ==="
variant CONTROL "$F_CTRL" 25
echo "=== (b1) mergeStateStatus REMOVED, first=25 ==="
variant NO_MSS "$F_NOMSS" 25
echo "=== (b2) mergeable REMOVED, first=25 ==="
variant NO_MERGEABLE "$F_NOMRG" 25
echo "=== (b3) BOTH removed (pure enumeration), first=25 ==="
variant ENUM_ONLY "$F_NEITHER" 25
echo "=== (a1) control at first=10 ==="
variant CTRL10 "$F_CTRL" 10
echo "=== (a2) control at first=5 ==="
variant CTRL5 "$F_CTRL" 5
echo "=== (b4) pure enumeration at first=100 ==="
variant ENUM100 "$F_NEITHER" 100
echo "=== per-PR mergeable probe (5 numbers from page 2 region) ==="

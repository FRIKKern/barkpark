<!-- doc-tier: cold | canonical-for: idor-barkparks-id-census-rederivation | budget: 800tok -->

# Re-derivation: /v1/barkparks/:id object-level-authz census (origin/main @64b5a69)

Wave: api-read-path-security-sweep IDOR wave. Assignment: enum-reanchor-census.
Verdict: 30 routes, 0 UNCLASSIFIED, offenders == []. Every route carries exactly
one of the 3+1 team-scoped signals; none resolves `:id` globally.

## Re-derive the enumeration + classification

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/r.ex
    awk -f /tmp/census.awk /tmp/r.ex     # script below; prints startln, signal, header

census.awk classifies each `/v1/barkparks/:id*` route body against, in order:
`resolve_team_barkpark(`, `proxy_instance_webhook(`, `recent_events_for_team(`,
inline `tid == team.id`. Any body matching none prints `UNCLASSIFIED` (== an offender).

```awk
/^  (get|post|put|patch|delete) "\/v1\/barkparks\/:id/ { if(inroute)flush(); inroute=1;startln=NR;hdr=$0;body="";next }
/^  (get|post|put|patch|delete) "/ { if(inroute){flush();inroute=0} }
{ if(inroute) body=body "\n" $0 }
END { if(inroute) flush() }
function flush(  sig){ sig="UNCLASSIFIED";
  if(body~/resolve_team_barkpark\(/)sig="resolve_team_barkpark";
  else if(body~/proxy_instance_webhook\(/)sig="proxy_instance_webhook";
  else if(body~/recent_events_for_team\(/)sig="recent_events_for_team";
  else if(body~/tid == team\.id/)sig="inline tid==team.id";
  printf "%-6d %-28s %s\n",startln,sig,substr(hdr,3,60) }
```

## Signal tally (30 routes)

| Signal | Count | Routes |
|---|---|---|
| inline `tid == team.id` (keyed on `conn.assigns.current_team`) | 14 | delete :id 2223, retry 2594, credentials 2762, studio-link 2830, app-token POST 2925 / DELETE 3019, push-relay 3145, site-url 3249, self-update 3357, rollback 3535, autoupdate 3688, domain 4196, bootstrap 4309, vercel-deploy 4357 |
| `resolve_team_barkpark/2` (router.ex:11053 — extracted inline guard) | 5 | verify 2662, metrics 8670, usage 8718, usage/history 8749, domain-status 8806 |
| `proxy_instance_webhook/2` (router.ex:11029 → resolve_team_barkpark) | 9 | api/webhooks* 4527-4563 |
| `recent_events_for_team/3` (registry.ex — matches `%Barkpark{team_id: ^tid}`) | 2 | events 8585, telemetry 8620 |

## Anchors (drifted from survey's 11031/11020)

- `defp resolve_team_barkpark(team, id)` @ **router.ex:11053** — `%Barkpark{team_id: tid} = bp when tid == team.id -> bp ; _ -> nil`
- `defp proxy_instance_webhook(conn, capability)` @ **router.ex:11029** — require_user → current_team → resolve_team_barkpark(team, path_params["id"])
- `def recent_events_for_team(team, barkpark_id, limit)` @ registry.ex — `case ... Repo.get(Barkpark, barkpark_id) do %Barkpark{team_id: ^tid} = bp -> recent_events(bp,limit) ; _ -> nil`

## Adjacent note (not this assignment's finding, corroborated)

credentials@2762 first case is `%Barkpark{team_id: tid, suspended: true} when tid == team.id` (suspended→409).
bootstrap@4309 has NO suspended clause — goes straight to reveal. Intra-team suspension
inconsistency (digest's bootstrap candidate), ownership still enforced.

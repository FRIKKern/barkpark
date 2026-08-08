# Re-derivation recipes — audit vocabulary census (cch wave 52 verify)

Tree: `git archive origin/main cloud` extracted into a scratch dir. All paths below
are relative to that extract root.

```sh
cd $(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x
```

## R1 — PRODUCED (51), with BOTH indirection layers resolved

The briefed one-liner's third clause matches ZERO because the atoms are QUOTED
(`:"webhook.create"`, not `:webhook_create`). Corrected:

```sh
grep -rhoE 'action: "[a-z0-9_.]+"' cloud/lib | sed 's/action: "//;s/"//' | sort -u > /tmp/A.txt   # 37 (one is comment prose)
grep -rhoE 'audit_lifecycle_trigger\(conn, team, [a-z.]+, "[a-z0-9_.]+"' cloud/lib \
  | grep -oE '"[a-z0-9_.]+"' | tr -d '"' | sort -u > /tmp/B.txt                                    # 9
grep -oE 'instance_mutation_action\(:"[a-z_.]+"\), do: "[a-z0-9_.]+"' cloud/lib/barkpark_cloud/web/router.ex \
  | sed 's/.*do: "//;s/"//' | sort -u > /tmp/C.txt                                                 # 6
cat /tmp/A.txt /tmp/B.txt /tmp/C.txt | sort -u | grep -v '^advance$' > /tmp/P.txt && wc -l < /tmp/P.txt   # 51
```

`advance` is prose inside `# POST /v1/onboarding {action: "advance"|...}` at
`cloud/lib/barkpark_cloud/web/router.ex:1579`. Verify it is not a producer:

```sh
grep -rn 'action: "advance"' cloud/lib     # only the comment line
```

## R2 — DECLARED (55) and the four producerless verbs

```sh
awk '/@actions ~w\(/{f=1;next} f&&/^  \)/{f=0} f' cloud/lib/barkpark_cloud/accounts/audit_event.ex \
  | tr -s ' \n' '\n' | grep -E '^[a-z]' | sort -u > /tmp/D.txt && wc -l < /tmp/D.txt   # 55
comm -23 /tmp/D.txt /tmp/P.txt    # email.verified oauth.linked twofa.disabled twofa.enabled
comm -13 /tmp/D.txt /tmp/P.txt    # empty — every real producer is declared
```

55, not the 54 in cch-w51-s4's brief: `site.rolled_back` landed with s3 (#10613-15).

## R3 — LABELS (19) and unlabelled (32)

```sh
awk 'f&&/^  \};/{f=0} f&&/"/{gsub(/^ *"/,"");sub(/".*/,"");print} /ACTION_LABELS *= *\{/{f=1}' \
  cloud/priv/static/app.js | sort -u > /tmp/L.txt && wc -l < /tmp/L.txt   # 19
comm -13 /tmp/P.txt /tmp/L.txt    # empty — every label has a producer
comm -23 /tmp/P.txt /tmp/L.txt | wc -l                                   # 32
```

## R4 — the discard idiom is LINE-WRAPPED; the one-line grep is a false all-clear

```sh
grep -rn '_ = Accounts.record_audit' cloud/lib          # ZERO hits, exit 1
grep -rn -B1 'Accounts.record_audit(%{' cloud/lib | grep -c '_ ='   # 8
```

Eight discard sites, all in `cloud/lib/barkpark_cloud/web/router.ex`:
4450, 6587, 6678, 6914, 11481, 11553, 12652, 13198 (the `_ =` line; the call opens
on the next line). The other four call sites (2378, 5547, 8563, 10578) `case` on the
result and `Logger.error` the changeset. 12 total in `cloud/lib`.

Beware: `cloud/test/barkpark_cloud/web/router_sites_test.exs:1880` contains the
literal string `_ = Accounts.record_audit(…)` inside a COMMENT — a scan over
`cloud/` rather than `cloud/lib` hits it and reads as a live producer.

## R5 — fleet controls write no audit row, and structurally cannot

```sh
sed -n '3426,3560p' cloud/lib/barkpark_cloud/web/router.ex | grep -c record_audit   # 0
sed -n '3709,3740p' cloud/lib/barkpark_cloud/web/router.ex | grep -c record_audit   # 0
sed -n '20,26p'  cloud/priv/repo/migrations/20260701120600_create_audit_events.exs  # team_id null: false
```

`POST /v1/admin|operator/autoupdate/halt|resume` and
`PATCH /v1/admin/barkparks/:id/channel` are cross-team, teamless operator levers;
`audit_events.team_id` is `null: false` and `AuditEvent.changeset/2`
`validate_required([:action, :team_id])`. Attributing them requires a MIGRATION,
not a call-site addition. The console heading is scoped —
`cloud/priv/static/app.js:15298` reads "The team's append-only audit trail" — so
the scope claim is narrower than "an append-only audit trail" suggests.

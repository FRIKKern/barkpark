# Re-derivation recipes — audit action vocabulary, two directions (wave 51 verify)

Pinned tree: `git archive origin/main` @ `ca5bc542941e23591b1c84a0840f2145595b40eb`.
Every recipe below runs inside `cd $(mktemp -d) && git -C <repo> archive origin/main | tar -x`.

## R1 — Declared audit vocabulary (54 verbs)

```
sed -n '44,69p' cloud/lib/barkpark_cloud/accounts/audit_event.ex \
  | sed '1d;$d' | tr -s ' \n' '\n' | grep -E '^[a-z]' | sort -u > /tmp/declared.txt
wc -l < /tmp/declared.txt      # 54
```

## R2 — Naively-produced set (37 literals; 36 real, `advance` is a comment)

```
grep -rhoE 'action: "[a-z0-9_.]+"' cloud/lib | sed 's/action: //;s/"//g' | sort -u > /tmp/produced.txt
wc -l < /tmp/produced.txt      # 37
grep -rn 'action: "advance"' cloud/lib   # router.ex:1579 — a COMMENT, not a producer
```

## R3 — The two indirection layers a literal grep misses

```
grep -rn 'instance_mutation_action\|audit_lifecycle_trigger' cloud/lib
```
- `instance_mutation_action/1` (router.ex:10559-10568) mints 6: `webhook.{created,updated,deleted,rotated,replayed,test_sent}`.
- `audit_lifecycle_trigger/5` (def router.ex:2362) has 9 call sites (2407, 2508, 2628, 2700, 3110, 3259, 3936, 8756, 12518) minting 9 `barkpark.*` verbs.
- No THIRD layer: the only other non-literal `action:` bindings are router.ex:2366 (the helper's own param) and router.ex:9416 (a read/render):
```
grep -rnE 'action: [^"]' cloud/lib | grep -vE 'action: :|action: nil'
```

## R4 — Set-difference with indirection resolved → exactly 4 zero-producer verbs

```
printf '%s\n' webhook.created webhook.updated webhook.deleted webhook.rotated \
  webhook.replayed webhook.test_sent barkpark.retry_requested barkpark.verify_requested \
  barkpark.studio_link_minted barkpark.app_token_minted barkpark.self_update_triggered \
  barkpark.rollback_triggered barkpark.vercel_deploy_triggered barkpark.resurrected \
  barkpark.app_token_revoked > /tmp/resolved.txt
sort -u /tmp/produced.txt /tmp/resolved.txt > /tmp/produced_full.txt   # 52
comm -23 /tmp/declared.txt /tmp/produced_full.txt
# email.verified / oauth.linked / twofa.disabled / twofa.enabled
```

## R5 — The INVERSE direction: a produced verb the vocabulary rejects

```
comm -13 /tmp/declared.txt /tmp/produced.txt         # advance (comment), site.rolled_back
sed -n '6889,6903p' cloud/lib/barkpark_cloud/web/router.ex   # live Accounts.record_audit, `_ =` swallowed
grep -c 'site.rolled_back' cloud/lib/barkpark_cloud/accounts/audit_event.ex   # 0 — not in @actions
grep -n 'site.rolled_back' cloud/priv/static/app.js          # 15308 — ACTION_LABELS HAS a label
sed -n '76,82p' cloud/test/barkpark_cloud/accounts_audit_test.exs  # proves out-of-vocab → {:error, cs}
```

## R6 — 2FA reachability: zero audit calls in the route region

```
sed -n '1480,1560p' cloud/lib/barkpark_cloud/web/router.ex | grep -cE 'Accounts.audit|record_audit'   # 0
sed -n '/def start_two_factor_enrollment/,/def two_factor_enabled?/p' \
  cloud/lib/barkpark_cloud/accounts.ex | grep -c 'record_audit'                                        # 0
grep -rn 'oauth\.linked\|email\.verified\|twofa\.enabled\|twofa\.disabled' cloud/
# ONLY audit_event.ex:67-68 — declaration and nothing else, anywhere
```

## R7 — team_id is NON-NULL in BOTH the changeset and the DB

```
grep -n 'validate_required' cloud/lib/barkpark_cloud/accounts/audit_event.ex   # [:action, :team_id]
sed -n '18,26p' cloud/priv/repo/migrations/20260701120600_create_audit_events.exs  # team_id ... null: false
```

## R8 — ACTION_LABELS cross-check (19 labels, all produced, one unstorable)

```
sed -n '15295,15316p' cloud/priv/static/app.js | grep -oE '"[a-z0-9_.]+":' | tr -d '":' | sort -u > /tmp/labels.txt
wc -l < /tmp/labels.txt                       # 19
comm -23 /tmp/labels.txt /tmp/produced_full.txt   # EMPTY — every label has a producer
comm -23 /tmp/labels.txt /tmp/declared.txt        # site.rolled_back — label for a verb the schema refuses
```

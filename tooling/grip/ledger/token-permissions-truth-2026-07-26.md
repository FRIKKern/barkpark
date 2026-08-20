# Re-derivation recipes — shipped site token permissions (W10 verify)

Read server-side on guerrilla (157.180.90.121), 2026-07-26. No HTTP introspection endpoint exists.

## 1. The shipped search-ember token's permissions column

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql barkpark_prod -x -c \"select id,label,permissions,workspace_id,owner_user_id,kind,share_scope,revoked_at,paused_at,expires_at from api_tokens where label='site-read-search-ember';\""

Expected: `permissions | {public-read}` (exactly one element), `revoked_at` empty,
`workspace_id | 03e3d6d9-d123-4557-9c06-ae4382a20626`, `owner_user_id` empty.

## 2. Prove that row IS the token the live site ships (hash identity, both legs)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "pid=\$(systemctl show -p MainPID --value barkpark-site@search-ember__b.service); tr '\0' '\n' < /proc/\$pid/environ | grep BARKPARK_TOKEN"
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "printf %s '<that value>' | sha256sum"
    # browser leg, baked into the Next build:
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "cd /opt/barkpark/sites/search-ember/src && python3 -c \"import json,hashlib; e=json.load(open('.next/required-server-files.json'))['config']['env']; print(hashlib.sha256(e['NEXT_PUBLIC_BARKPARK_WS_TOKEN'].encode()).hexdigest())\""

Both must equal `api_tokens.token_hash` for `site-read-search-ember`
(= 9db618dacec8a9ed4ef00ae0dc3729f7cb01b4bb43b9b545d5ecb860acce9f34).
Hashing algorithm: api/lib/barkpark/auth/api_token.ex:101 — sha256, lowercase hex.
NOTE: the SSR leg and the browser leg are the SAME secret.

## 3. Fleet-wide permissions census + the ["public-read","read"] escape hatch

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql barkpark_prod -At -c \"select permissions::text, count(*) from api_tokens group by 1 order by 2 desc;\""
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql barkpark_prod -c \"select id,label,permissions,revoked_at from api_tokens where permissions @> ARRAY['public-read','read']::varchar[];\""

Second query returning `(0 rows)` means no token today carries the pair — but
TokenController @allowed_permissions (api/lib/barkpark_web/controllers/token_controller.ex:30)
permits minting it, so an exact-list pin `perms == ["public-read"]` is escapable.

## 4. W7 verifier tokens still live?

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql barkpark_prod -c \"select label,permissions,revoked_at,paused_at,expires_at from api_tokens where label in ('stw7-verify-public-read','ws-live-query-proof-verifier');\""

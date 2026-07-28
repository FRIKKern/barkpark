# Re-derivation recipe — PDS w23 v13: can Seeds.Clean.seed/1 run under MIX_ENV=prod from cmd_up?

Verified 2026-07-28 against origin/main a99127cad. Repo root: /Volumes/SATECHI/github/barkpark

## 1. runtime.exs prod branch does NOT raise given cmd_up's assembled env

Reproduce the exact env cmd_up holds after `ensure_secrets` + `load_env`
(ensure_secrets tops up MISSING keys every run, so BARKPARK_KEK and
BARKPARK_RELEASE_CAPTURE_HMAC_SECRET are present on a real box even if an
older ~/.barkpark/.env predates them):

```sh
cd api && set -a && . ~/.barkpark/.env && set +a \
 && export MIX_ENV=prod PHX_SCHEME=http PHX_HOST=localhost PORT=4000 \
 && export DATABASE_URL="$(../bin/barkpark-pg url)" \
 && export BARKPARK_KEK="$(openssl rand -base64 32)" \
 && export BARKPARK_RELEASE_CAPTURE_HMAC_SECRET="$(openssl rand -base64 48)" \
 && mix run --no-start -e 'IO.puts("PROD_RUNTIME_OK " <> inspect(function_exported?(Barkpark.Seeds.Clean, :seed, 1)))'
```

Expected: `PROD_RUNTIME_OK true`.
Omit BARKPARK_RELEASE_CAPTURE_HMAC_SECRET and it raises at runtime.exs:44 —
that is the ONLY prod raise a stale env file trips first.

## 2. The seed needs the app STARTED (Repo); --no-start is not enough

`mix run --no-start` proves config-load only. The real step is
`MIX_ENV=prod BARKPARK_SEED_PROFILE=clean mix run priv/repo/seeds.exs`.
No port conflict: runtime.exs only sets `server: true` under PHX_SERVER
(`git show origin/main:api/config/runtime.exs | sed -n '19,21p'`).

## 3. Idempotence + the revoke trap

```sh
git show origin/main:api/lib/barkpark/seeds/clean.ex | sed -n '/admin_token_present?/,/end/p'
grep -rn 'unique_index(:api_tokens' api/priv/repo/migrations/
```

`admin_token_present?/1` requires `is_nil(revoked_at)`. After a revoke it is
false, so an unconditional re-`up` RE-MINTS. With a fixed
BARKPARK_SEED_ADMIN_TOKEN that is a token_hash unique-constraint violation →
`{:ok, _} = Auth.create_token(...)` MatchError → `up` dies under `set -e`.

## 4. Duplicate cluster (4 rows, one body of work)

```sh
for t in pds-bl-owner-walk-reaches-the-mint pds-bl-admin-token-mint-path \
         pds-bl-personal-local-doc-staleness task-5c4f2673778d5ff0; do
  bp task get $t -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];c=d['content'];print(d['doc_id'],c['lifecycle_status'],c.get('disposition_owner'))"
done
```

## 5. Doc-row premises are partly STALE on main

```sh
git show origin/main:docs/setup/personal-local.md | sed -n '15,22p;80,92p'
```
BARKPARK_KEK + BARKPARK_RELEASE_CAPTURE_HMAC_SECRET are already in the
generated-secrets prose; MEDIA_DIR + ALLOW_BUNDLE_IMPORT are already in the
Overrides table. Still absent: any statement of how to obtain an admin token,
and KEK as an Overrides-table row.

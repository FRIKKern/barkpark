# Re-derivation recipe — owner-token-mint-path (PDS wave 22 verify)

Claim: a fresh `bin/barkpark up` prod-mode box has ZERO api_tokens and ZERO users,
but a FIRST-PARTY mint path DOES exist on origin/main (clean-profile seed).

## 1. Boot an isolated scratch box (WARM api/_build/prod ≈ 30s; COLD-PROD ≈ 156s)
    cd /Volumes/SATECHI/github/barkpark
    mkdir -p /tmp/pds-w22-verify
    PDS_SCRATCH_POINTER=/tmp/pds-w22-verify/pointer.last \
      BARKPARK_HOME=/tmp/pds-w22-verify/root \
      scripts/pds-scratch-target.sh up
    # last banner line: "barkpark: server up (pid N) — http://localhost:<PORT>/studio"

## 2. Census the fresh box (substitute the printed PG port)
    export BARKPARK_HOME=/private/tmp/pds-w22-verify/root BARKPARK_PG_PORT=<pgport>
    bin/barkpark-pg psql --quiet --no-align -c \
      "SELECT count(*) FROM api_tokens; SELECT count(*) FROM users; SELECT count(*) FROM documents"
    # expect 1 (harness-inserted only) / 0 / 0

## 3. The anonymous owner walk
    curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" http://localhost:<PORT>/studio
    curl -sL -o /tmp/login.html -w "%{url_effective}\n" http://localhost:<PORT>/studio
    grep -o '<label[^>]*>[^<]*</label>' /tmp/login.html    # Email / Password / API token
    for p in /register /signup /users/register; do curl -s -o /dev/null -w "$p %{http_code}\n" http://localhost:<PORT>$p; done

## 4. Prove the first-party mint (delete the harness token first — the seed is idempotent)
    bin/barkpark-pg psql --quiet --no-align -c "DELETE FROM api_tokens"
    set -a; . $BARKPARK_HOME/.env; set +a
    export DATABASE_URL="$(bin/barkpark-pg url)"
    cd api && MIX_ENV=prod BARKPARK_SEED_PROFILE=clean CC=/usr/bin/clang \
      mix run priv/repo/seeds.exs 2>&1 | grep -A6 "Admin token"
    # prints the shown-once bp_admin_<32> banner

## 5. Prove the token works
    curl -s -H "Authorization: Bearer bp_admin_…" http://localhost:<PORT>/v1/capabilities | head -c 40
    # {"auth_tier":"admin", …
    # Studio paste-token door:
    curl -s -c cj -o p.html http://localhost:<PORT>/login
    CSRF=$(grep -o 'csrf-token" content="[^"]*"' p.html | sed 's/.*content="//;s/"//')
    curl -s -b cj -c cj -o /dev/null -w "%{http_code} %{redirect_url}\n" -X POST http://localhost:<PORT>/login \
      --data-urlencode "_csrf_token=$CSRF" --data-urlencode "token=bp_admin_…"
    # 302 -> /studio ; then GET /studio -L lands on /w/default/p/default/d/production/studio (200)

## 6. Refute the cloud device-link as a local path
    bp login --device-start --url http://localhost:<PORT> -o json; echo $?
    # {"ok":false,… "not_found"} exit 1 — /v1 device-link is a Cloud control-plane route

## 7. Teardown (always)
    PDS_SCRATCH_POINTER=/tmp/pds-w22-verify/pointer.last \
      BARKPARK_HOME=/private/tmp/pds-w22-verify/root scripts/pds-scratch-target.sh teardown

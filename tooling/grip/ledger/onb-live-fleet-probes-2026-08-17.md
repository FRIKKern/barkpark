<!-- doc-tier: cold | canonical-for: onb-live-fleet-probes-rederivation | budget: 1200tok -->
# Onboarding wave — live-fleet-probes re-derivation (2026-08-17)

Read-only live proofs for the onboarding-composition wave verifier lane. All commands re-derive the fact from live hosts / the working tree; no writes.

## (a) Unpinned QUICKSTART install delivers a working bp

    D=$(mktemp -d) && BARKPARK_BIN_DIR=$D sh scripts/install-cli.sh && $D/bp version

Expected: resolves newest `cli-v*` via the GitHub API (install-cli.sh:32-44, the #2797 fix), downloads `bp-darwin-arm64` from `releases/download/cli-v1.17.0`, checksum OK, `bp version` prints `{"cli_version":"1.17.0","commit":"8fae26f",...}`. Journey leg 1 GREEN. The wallclock's stale install-404 headline stays refuted.

## (b) Fleet base_url / name census (isProd name-check + gyldendal backfill)

Fleet API is auth-gated; local cloud session token is EXPIRED (`bp barkparks -o json` -> `{"error":{"code":"auth",...run bp login...}}`; `curl -H "Authorization: Bearer $cloud_token" https://api.barkpark.cloud/v1/barkparks` -> `{"error":"unauthorized"}`). Managed-fleet enumeration NOT reachable read-only. Fall back to config known_servers + live probe:

    for h in https://guerrilla.barkpark.cloud https://gyldendal.barkpark.cloud https://api.barkpark.cloud; do
      echo "== $h"
      curl -s --max-time 12 "$h/v1/capabilities" | python3 -c 'import json,sys;d=json.load(sys.stdin);s=d["server"];print(s.get("base_url"),"|",s.get("name"))'
      curl -s --max-time 12 "$h/login" | grep -c data-cloud-login
    done

Live results:
- guerrilla: base_url=`https://guerrilla.barkpark.cloud`, name=`barkpark`, data-cloud-login=1 (correctly backfilled)
- gyldendal: base_url=`http://localhost:4000`, name=`barkpark`, data-cloud-login=0 (UN-BACKFILLED — confirmed live today)
- api.barkpark.cloud: control plane, `/v1/capabilities` -> HTTP 404 `{"error":"not_found"}` (not a content instance)
- golive-test / a / h / x / mine / prod .barkpark.cloud: HTTP 000 (DNS/conn fail — dead config artifacts, not live)

Two findings: (1) gyldendal is the only live un-backfilled content instance among reachable hosts. (2) EVERY live host emits `server.name = "barkpark"` (generic default) — isProd's name-based check catches NO live prod host; the name is not distinguishing, so the isProd miss is real on the fleet, not hypothetical.

## (c) deploy.sh secret-backfill loop — idempotent hook for BARKPARK_CLOUD_URL

    sed -n '168,203p' deploy.sh

deploy.sh:187-203 is an append-only idempotent loop: `for _var in BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_KEK BARKPARK_RELEASE_CAPTURE_HMAC_SECRET; do if ! grep -q "^${_var}=" .env; then ... echo "${_var}=$_val" >> .env; fi; done`. It does NOT start fresh — grep-guard preserves existing values. The idempotent SLOT for a BARKPARK_CLOUD_URL backfill exists (add to the list), BUT the loop generates a RANDOM secret per var (`openssl rand` / `phx.gen.secret`); BARKPARK_CLOUD_URL is a known value, so the slice needs a `case` branch deriving `$PHX_SCHEME://$DOMAIN` (both already computed above) instead of a random secret, plus a matching line in the fresh-install heredoc (168-179), which currently omits it.

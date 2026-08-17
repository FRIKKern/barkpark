<!-- doc-tier: cold | canonical-for: onb-w5-backfill-provisioner-inputs-recipe | budget: 800tok -->
# onb-w5 backfill provisioner inputs — re-derivation recipe

Verifier: backfill-provisioner-inputs. Closes the fleet-backfill Half-B input question.

## Q1 — does bp setup thread BARKPARK_CLOUD_URL through the ssh env prefix like BARKPARK_PLUGINS?

NO on the deploy.sh path. Re-derive:

    grep -n 'BARKPARK_PLUGINS\|BARKPARK_CLOUD_URL\|+x' internal/cli/setup/assets/deploy.sh
    # BARKPARK_PLUGINS guard at deploy.sh:233; BARKPARK_CLOUD_URL count = 0
    grep -c 'BARKPARK_CLOUD_URL' internal/cli/setup/assets/deploy.sh   # => 0
    sed -n '49,64p;236,244p' internal/cli/setup/deploy.go
    # both envParts blocks = DOMAIN, PHX_SCHEME, BARKPARK_SEED_PROFILE, [ADMIN_TOKEN], [BARKPARK_PLUGINS]
    # BARKPARK_CLOUD_URL absent from BOTH ssh env prefixes

An existing writer DOES exist, but on the Caddy/go-live chain, not deploy.sh:

    grep -n 'BARKPARK_CLOUD_URL' internal/cli/setup/caddy.go   # => 143
    # caddy.go:143 setEnvVarStep("...", "BARKPARK_CLOUD_URL", "https://barkpark.cloud")
    # setEnvVarStep (caddy.go:249) is the SAME idempotent grep-then-sed .env pattern

Verdict: a NEW provisioner input is required to mirror PLUGINS on the deploy.sh path
(env-prefix entry in deploy.go + a `${BARKPARK_CLOUD_URL+x}` set-ness guard block in
deploy.sh). OR a builder reuses caddy.go's setEnvVarStep for a backfill step.

## Q2 — the ${VAR+x} guard pattern to mirror (verbatim, deploy.sh:228-240)

    if [ -n "${BARKPARK_PLUGINS+x}" ]; then
      ... sed -i replace OR echo >> "$APP_DIR/.env"
    fi
    # comment 229-232: set-ness tested with ${VAR+x} — NEVER ${VAR:-} (empty is the kill switch)

## Q3 — canonical control-plane origin value, fleet-wide

`https://barkpark.cloud` — CONFIRMED fleet-wide constant. Re-derive:

    curl -s https://guerrilla.barkpark.cloud/login | grep -o 'href="[^"]*" data-cloud-login'
    # => href="https://barkpark.cloud/#/instance-login?url=https%3A%2F%2Fguerrilla.barkpark.cloud"

Origin = https://barkpark.cloud; instance host rides as ?url= query param.
D31's `PHX_SCHEME://DOMAIN` derivation REFUTED — that yields the self-referential
https://guerrilla.barkpark.cloud (wrong). Matches hardcoded caddy.go:143 value.

## Q4 — leak still live at verify time (2026-08-17)

    curl -s https://gyldendal.barkpark.cloud/v1/capabilities | python3 -c "import sys,json;print(json.load(sys.stdin)['server']['base_url'])"
    # => http://localhost:4000   (PHX_HOST/base_url leak — distinct defect)
    curl -s https://gyldendal.barkpark.cloud/login | grep -c 'data-cloud-login'
    # => 0   (backfill defect: BARKPARK_CLOUD_URL unset, button never renders)

Two distinct defects confirmed live on gyldendal, matching D31's split.

## Q5 — no cloud/ path touched

    grep -rln 'cloud/' internal/cli/setup/deploy.go internal/cli/setup/caddy.go internal/cli/setup/assets/deploy.sh
    # => no matches. All slice files under internal/cli/setup/. In fence.

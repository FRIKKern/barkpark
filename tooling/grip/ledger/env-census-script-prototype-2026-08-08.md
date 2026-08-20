# Re-derivation recipes — env-census script prototype (self-host-blessing W1/S1)

Verifier lane `census-script-prototype`, 2026-08-08. All inputs are `origin/main`
blobs at `5cc5aca31` — never the local worktree (which is 600+ commits stale on
some paths). Every row re-derives from scratch.

## 0. Build the origin/main tree the script runs against

    cd <repo> && git fetch origin main -q
    T=$(mktemp -d)
    git archive origin/main api/config/runtime.exs api/lib \
        cloud/config/runtime.exs cloud/lib \
        docker-compose.yml cloud/docker-compose.yml api/Dockerfile | tar -x -C "$T"

Script prototype: `tooling/grip/ledger/_env_census.py` is NOT committed here — the
prototype lived at
`<scratchpad>/env_census.py` during wave 1 verify and becomes S1's deliverable
(proposed home `scripts/env-census.py`, stdlib-only, no pip step in CI).

## 1. Canonical denominator — 130 (api root), 55 (cloud root)

    python3 scripts/env-census.py --tree "$T" --root api   --no-compose   # CENSUS = 130, exit 0
    python3 scripts/env-census.py --tree "$T" --root cloud --no-compose   # CENSUS = 55,  exit 0

Decomposition (api): 114 unique double-quoted literals at non-comment call sites
+ 16 names recovered from 7 hand-declared dynamic sites = 130.
`api/config/runtime.exs` alone contributes 109 (99 literal + 10 recovered).

## 2. Why the three surveyor numbers disagreed

    # 116 = the naive grep, which counts 2 COMMENTED-OUT phantoms
    grep -rhoE 'System\.(get_env|fetch_env!?)\("[A-Za-z_][A-Za-z0-9_]*"' \
      "$T/api/config/runtime.exs" "$T/api/lib" | sed 's/.*("//;s/"//' | sort -u | wc -l
    # 101 = same naive grep, runtime.exs only  (99 real + 2 phantoms)
    grep -oE 'System\.(get_env|fetch_env!?)\("[A-Za-z_][A-Za-z0-9_]*"' \
      "$T/api/config/runtime.exs" | sed 's/.*("//;s/"//' | sort -u | wc -l
    # the 2 phantoms:
    grep -nE '^\s*#.*System\.(get_env|fetch_env)' "$T/api/config/runtime.exs"
    # -> 1003/1004: SOME_APP_SSL_KEY_PATH / SOME_APP_SSL_CERT_PATH, commented Phoenix example

111 = 109 + the 2 phantoms (runtime.exs scope). 116 = 114 + the 2 phantoms
(api root scope, dynamic sites unresolved). 129 = 130 minus one name (unpinned;
most likely `PATH`, the obvious pre-emptive exemption).

## 3. Fail-closed mutation proof (the script's own tripwire)

    cp -R "$T" "$T.mut"
    printf '\nvar = "SOME_NEW_KNOB"\n_probe = System.get_env(var)\n' >> "$T.mut/cloud/config/runtime.exs"
    python3 scripts/env-census.py --tree "$T.mut" --root cloud --no-compose; echo "EXIT=$?"
    # -> "1 (1 UNDECLARED)" ... "cloud/config/runtime.exs:432 arg='var'" ... EXIT=1
    # baseline on the unmutated tree: RESULT: PASS, EXIT=0

Detector-coverage proof (all 7 known api dynamic sites red when resolutions are
stripped — run with `RESOLUTIONS.clear(); CALLER_PATTERNS.clear()` injected):
runtime.exs:32/452/895, build_info.ex:42, settings.ex:178,
deploy_runner.ex:1059, tmux_console.ex:141.

## 4. Compose diff (scoped — this scoping is load-bearing)

    python3 scripts/env-census.py --tree "$T" --root api     # 10 passed, 5 exempt-absent, 115 MISSING
    python3 scripts/env-census.py --tree "$T" --root cloud   # 28 passed, 0 exempt-absent, 27 MISSING

Cloud diff anchors on `^x-control-plane:`, NOT the whole file. Proof the scoping
matters — the `postfix` service carries 5 env names, 3 of which no Elixir ever
reads and would otherwise appear as diff noise:

    python3 - <<'PY'
    import env_census as E
    print(E.compose_env_block("<T>/cloud/docker-compose.yml", r'^  postfix:'))
    PY
    # -> DKIM_SELECTOR, MAIL_DOMAIN, MAIL_HOSTNAME (never read) + SMTP_USERNAME, SMTP_PASSWORD (read)

## 5. The script independently rediscovers the epic's headline trap

    python3 scripts/env-census.py --tree "$T" --root api | grep 'WARN'
    # -> WARN `:-` default on a read knob (3): BARKPARK_SEED_PROFILE, PHX_HOST, SECRET_KEY_BASE

## 6. Dockerfile-shadow check (proposed 4th assertion, not yet in the prototype)

    grep -nE '^\s*ENV\s+[A-Z_]+=' "$T/api/Dockerfile"
    # 45 PHX_SERVER=true | 46 PHX_HOST=localhost | 47 PORT=4000
    # 48 DATABASE_URL=ecto://postgres:postgres@db/barkpark_prod
    # 49 SECRET_KEY_BASE=placeholder_will_be_overridden   (30 bytes — under Plug's 64 floor)

## 7. Where the refusal actually fires in a container

    git show origin/main:api/entrypoint.sh
    # `set -e`; line 5 is `bin/barkpark eval "Barkpark.Release.migrate()"`, which
    # LOADS runtime.exs. A boot raise therefore exits the container at migrate,
    # before `start` — fail-closed, never a half-serving box.

## 8. pdf-bl-limit-env-passthrough absorption check

    bp task get pdf-bl-limit-env-passthrough -o json | python3 -m json.tool | grep -A2 criterion
    git show origin/main:cloud/docker-compose.yml | grep -c LIMIT   # 0
    git show origin/main:cloud/.env.example      | grep -c LIMIT    # 0
    git show origin/main:.claude/workflows/bp-self-host-blessing-charter.md | grep -c 'cloud/.env.example'  # 0

AC1 names `cloud/.env.example`, which the charter fence does NOT list — closing
pdf-bl inside S1 requires a numbered fence widening for that file.

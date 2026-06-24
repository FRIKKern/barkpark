#!/usr/bin/env bash
# bp-vercel-quick-setup — stand up a new Barkpark-backed site and ship it to Vercel
# in one shot. This is the scripted form of the "deploy a new site" golden path;
# the eventual `bp vercel quick-setup` subcommand will absorb it (see
# templates/DEPLOYING.md → "Folding into the CLI").
#
# What it does, in order:
#   1. Create a Barkpark workspace (→ default project + production dataset)
#   2. Apply a content schema (scoped URL — NOT the flat alias)
#   3. Seed + PUBLISH content (publish needs {id,type})
#   4. Provision a read-only, workspace-scoped public-read token (server-side)
#   5. Create/link a Vercel project, set env, deploy to production
#   6. Print the live URL
#
# Every step is logged and (re-)runnable: workspace create / schema apply /
# publish are idempotent, so a half-finished run is safe to repeat.

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
SERVER="barkpark"                 # bp saved-server name or full URL
DATASET="production"
PROJECT_SLUG="default"            # Barkpark project slug under the new workspace
SITE=""
SCHEMA=""
SEED=""
PUBLISH_TYPE=""
APP_DIR=""
VERCEL_TEAM=""
VERCEL_PROJECT=""                 # defaults to $SITE
TOKEN_SSH=""                      # host to mint the read token on, e.g. root@1.2.3.4
TOKEN_REMOTE_DIR="/opt/barkpark/api"
READ_TOKEN=""                     # supply directly to skip minting
ADMIN_TOKEN="${BARKPARK_ADMIN_TOKEN:-}"  # admin token for provisioning (else taken from bp config)
DEPLOY=1
STATIC=""                         # static mode: a dir or single .html — skip ALL Barkpark steps

usage() {
  sed -n '2,18p' "$0"
  cat <<'EOF'

Usage:
  bp-vercel-quick-setup.sh --site <slug> --app-dir <path> [options]

Required:
  --site <slug>           workspace + dataset name (e.g. hundesteder)
  --app-dir <path>        the Next.js app folder to deploy

Barkpark options:
  --server <name|url>     bp saved server or URL            (default: barkpark)
  --dataset <name>        dataset                           (default: production)
  --schema <file.json>    schema to apply (flat schema object)
  --seed <file.json>      seed mutations {"mutations":[...]}
  --publish-type <type>   publish all seeded docs of this type after seeding
  --admin-token <tok>     admin token for provisioning (default: from bp config)

Read token (pick one; needed because non-Default workspaces 403 anonymous reads):
  --token-ssh <host>      ssh host to mint a scoped public-read token on
  --read-token <tok>      use this token, skip minting

Static mode (no Barkpark backend):
  --static <path>         deploy a dir as-is, or a single .html file (staged as
                          index.html, with an adjacent assets/ or public/ copied);
                          skips ALL Barkpark steps and sets NO BARKPARK_* env

Vercel options:
  --vercel-team <slug>    Vercel team/scope (e.g. guerrilla)
  --vercel-project <name> project name                      (default: --site / --static basename)
  --no-deploy             provision Barkpark only, skip Vercel

Examples:
  bp-vercel-quick-setup.sh --site hundesteder --app-dir apps/hundesteder \
    --schema templates/place-directory/schemas/place.json \
    --seed  templates/place-directory/seed-places.json \
    --publish-type place --token-ssh root@89.167.28.206 --vercel-team guerrilla
EOF
}

# ── args ────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --site) SITE="$2"; shift 2;;
    --server) SERVER="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    --schema) SCHEMA="$2"; shift 2;;
    --seed) SEED="$2"; shift 2;;
    --publish-type) PUBLISH_TYPE="$2"; shift 2;;
    --app-dir) APP_DIR="$2"; shift 2;;
    --admin-token) ADMIN_TOKEN="$2"; shift 2;;
    --token-ssh) TOKEN_SSH="$2"; shift 2;;
    --token-remote-dir) TOKEN_REMOTE_DIR="$2"; shift 2;;
    --read-token) READ_TOKEN="$2"; shift 2;;
    --vercel-team) VERCEL_TEAM="$2"; shift 2;;
    --vercel-project) VERCEL_PROJECT="$2"; shift 2;;
    --static) STATIC="$2"; shift 2;;
    --no-deploy) DEPLOY=0; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage; exit 2;;
  esac
done

log()  { printf '\n\033[1;33m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# Disable Vercel deployment protection (ssoProtection) on the linked project so
# the public *.vercel.app URL doesn't 302 to SSO login. Shared by both modes.
disable_protection() { # <app-dir>
  local app_dir="$1" PRJ_ID ORG_ID VC_AUTH VC_TOKEN
  PRJ_ID="$(jq -r '.projectId' "$app_dir/.vercel/project.json" 2>/dev/null)"
  ORG_ID="$(jq -r '.orgId' "$app_dir/.vercel/project.json" 2>/dev/null)"
  for p in \
    "$HOME/Library/Application Support/com.vercel.cli/auth.json" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/com.vercel.cli/auth.json" \
    "$HOME/.vercel/auth.json"; do
    [ -f "$p" ] && VC_AUTH="$p" && break
  done
  VC_TOKEN="$(jq -r '.token // empty' "$VC_AUTH" 2>/dev/null || true)"
  if [ -n "$PRJ_ID" ] && [ -n "$VC_TOKEN" ]; then
    curl -s -X PATCH "https://api.vercel.com/v9/projects/$PRJ_ID?teamId=$ORG_ID" \
      -H "Authorization: Bearer $VC_TOKEN" -H 'Content-Type: application/json' \
      --data '{"ssoProtection": null}' >/dev/null && ok "deployment protection off (public)"
  else
    printf '  \033[1;33m!\033[0m could not auto-disable protection — do it in Settings → Deployment Protection\n'
  fi
}

# ── STATIC mode ───────────────────────────────────────────────────────────────
# A plain static site with NO Barkpark backend. Skip every Barkpark step
# (workspace/schema/seed/publish/token) and run ONLY the Vercel half. --site and
# the Barkpark flags are ignored here; no BARKPARK_* env is set.
if [ -n "$STATIC" ]; then
  need vercel; need jq; need curl
  [ -e "$STATIC" ] || die "--static '$STATIC' not found"

  if [ -d "$STATIC" ]; then
    DEPLOY_DIR="$STATIC"
    BASENAME="$(basename "${STATIC%/}")"
    CLEANUP=""
  else
    case "$STATIC" in
      *.html|*.HTML) ;;
      *) die "--static '$STATIC' must be a directory or a .html file";;
    esac
    DEPLOY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bp-vercel-static.XXXXXX")"
    CLEANUP="$DEPLOY_DIR"
    trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
    cp "$STATIC" "$DEPLOY_DIR/index.html"
    # Copy an adjacent assets/ or public/ dir alongside the page, if present.
    SRC_PARENT="$(cd "$(dirname "$STATIC")" && pwd)"
    for sub in assets public; do
      [ -d "$SRC_PARENT/$sub" ] && cp -R "$SRC_PARENT/$sub" "$DEPLOY_DIR/$sub"
    done
    BASENAME="$(basename "$STATIC")"; BASENAME="${BASENAME%.*}"
  fi

  VERCEL_PROJECT="${VERCEL_PROJECT:-$BASENAME}"
  [ -n "$VERCEL_PROJECT" ] || die "could not derive a vercel project name — pass --vercel-project"
  SCOPE_FLAG=(); [ -n "$VERCEL_TEAM" ] && SCOPE_FLAG=(--scope "$VERCEL_TEAM")

  log "Static deploy '$VERCEL_PROJECT' (no Barkpark backend)"
  ( cd "$DEPLOY_DIR" && vercel link --yes --project "$VERCEL_PROJECT" "${SCOPE_FLAG[@]}" >/dev/null 2>&1 ) \
    || die "vercel link failed (is the project name free / team correct?)"
  ok "linked $DEPLOY_DIR → $VERCEL_PROJECT"

  disable_protection "$DEPLOY_DIR"

  log "Deploy to production"
  URL="$( cd "$DEPLOY_DIR" && vercel deploy --prod --yes "${SCOPE_FLAG[@]}" 2>/dev/null | tail -1 )"
  [ -n "$URL" ] || die "deploy produced no URL"
  ok "deployed: $URL"
  printf '\n\033[1;32m🚀 %s is live → %s\033[0m\n' "$VERCEL_PROJECT" "$URL"
  exit 0
fi

[ -n "$SITE" ] || { echo "error: --site is required" >&2; exit 2; }
VERCEL_PROJECT="${VERCEL_PROJECT:-$SITE}"

need bp; need curl; need jq

# Resolve the API base URL for $SERVER (named server → its URL, or a literal URL).
resolve_base() {
  case "$SERVER" in
    http://*|https://*) echo "$SERVER";;
    *) bp -s "$SERVER" whoami --json 2>/dev/null | jq -r '.server';;
  esac
}
API_URL="$(resolve_base)"
[ -n "$API_URL" ] && [ "$API_URL" != "null" ] || die "could not resolve server '$SERVER' (run: bp servers)"

# Admin token: explicit flag wins, else pull the saved token for this server.
if [ -z "$ADMIN_TOKEN" ]; then
  ADMIN_TOKEN="$(jq -r --arg s "$SERVER" '
    (.known_servers[]? | select(.name==$s) | .token) // .token // empty
  ' "${HOME}/.config/barkpark/config.json" 2>/dev/null || true)"
fi
[ -n "$ADMIN_TOKEN" ] || die "no admin token (pass --admin-token or run: bp use $SERVER)"

SCOPED="$API_URL/w/$SITE/p/$PROJECT_SLUG"   # the workspace-scoped prefix — ALWAYS use this, not the flat alias

# ── 1. workspace ────────────────────────────────────────────────────────────
log "1/6  Workspace '$SITE' on $API_URL"
WS_ID="$(bp -s "$SERVER" workspace create "$SITE" --json 2>/dev/null | jq -r '.workspace.id // empty' || true)"
if [ -z "$WS_ID" ]; then
  WS_ID="$(bp -s "$SERVER" workspace ls --json 2>/dev/null | jq -r --arg s "$SITE" '.workspaces[]? | select(.slug==$s) | .id' | head -1)"
fi
[ -n "$WS_ID" ] || die "could not create or find workspace '$SITE'"
ok "workspace id $WS_ID  (project=$PROJECT_SLUG dataset=$DATASET)"

# ── 2. schema ───────────────────────────────────────────────────────────────
if [ -n "$SCHEMA" ]; then
  [ -f "$SCHEMA" ] || die "schema file not found: $SCHEMA"
  log "2/6  Apply schema $(basename "$SCHEMA")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SCOPED/v1/schemas/$DATASET" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    --data-binary @"$SCHEMA")"
  case "$code" in 200|201) ok "schema applied (HTTP $code)";; *) die "schema apply failed (HTTP $code)";; esac
else
  log "2/6  (no --schema — skipping)"
fi

# ── 3. seed + publish ───────────────────────────────────────────────────────
if [ -n "$SEED" ]; then
  [ -f "$SEED" ] || die "seed file not found: $SEED"
  log "3/6  Seed content from $(basename "$SEED")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SCOPED/v1/data/mutate/$DATASET" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    --data-binary @"$SEED")"
  [ "$code" = "200" ] || die "seed mutate failed (HTTP $code)"
  ok "seeded (createOrReplace lands as drafts)"

  if [ -n "$PUBLISH_TYPE" ]; then
    # publish needs BOTH id AND type, else 400 malformed.
    PUB="$(jq -c --arg t "$PUBLISH_TYPE" '{mutations: [
      .mutations[] | (.createOrReplace._id // .create._id) | select(.) | {publish:{id:., type:$t}}
    ]}' "$SEED")"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SCOPED/v1/data/mutate/$DATASET" \
      -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' --data "$PUB")"
    [ "$code" = "200" ] || die "publish failed (HTTP $code)"
    n="$(echo "$PUB" | jq '.mutations | length')"
    ok "published $n document(s) of type '$PUBLISH_TYPE'"
  fi
else
  log "3/6  (no --seed — skipping)"
fi

# ── 4. read token ───────────────────────────────────────────────────────────
log "4/6  Public-read token (read-only, member of '$SITE')"
if [ -z "$READ_TOKEN" ] && [ -n "$TOKEN_SSH" ]; then
  # Mint server-side: start only Repo (no endpoint → no :4000 clash), bind the
  # token to THIS workspace so it passes the tenancy membership gate.
  read -r -d '' MINT <<EOF || true
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Barkpark.Repo.start_link()
raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
{:ok, _} = Barkpark.Auth.create_token(raw, "public-read-$SITE", "$DATASET", ["public-read"], "$WS_ID")
IO.puts("MINTED=" <> raw)
EOF
  REMOTE="set -a; [ -f ../.env ] && source ../.env; set +a; export MIX_ENV=prod; \
export PATH=/root/.asdf/bin:/root/.asdf/shims:\$PATH; [ -f /root/.asdf/asdf.sh ] && . /root/.asdf/asdf.sh; \
cd $TOKEN_REMOTE_DIR; mix run --no-start /tmp/.bpqs_mint.exs"
  echo "$MINT" | ssh "$TOKEN_SSH" 'cat > /tmp/.bpqs_mint.exs'
  READ_TOKEN="$(ssh "$TOKEN_SSH" "bash -lc '$REMOTE'" 2>/dev/null | sed -n 's/^MINTED=//p' | tail -1)"
  ssh "$TOKEN_SSH" 'rm -f /tmp/.bpqs_mint.exs' || true
  [ -n "$READ_TOKEN" ] || die "token mint produced no output (check ssh + prod env)"
  ok "minted public-read-$SITE"
elif [ -n "$READ_TOKEN" ]; then
  ok "using supplied --read-token"
else
  die "need a read token: pass --token-ssh <host> to mint, or --read-token <tok>"
fi

# verify: reads work, writes are refused
rc="$(curl -s -H "Authorization: Bearer $READ_TOKEN" "$SCOPED/v1/data/query/$DATASET/${PUBLISH_TYPE:-place}?filter[status]=published" | jq -r '.result.count // 0')"
wc="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SCOPED/v1/data/mutate/$DATASET" \
  -H "Authorization: Bearer $READ_TOKEN" -H 'Content-Type: application/json' --data '{"mutations":[]}')"
ok "read token sees $rc published doc(s); write returns HTTP $wc (want 403)"

# ── 5 + 6. Vercel ───────────────────────────────────────────────────────────
if [ "$DEPLOY" = "1" ]; then
  need vercel
  [ -n "$APP_DIR" ] && [ -d "$APP_DIR" ] || die "--app-dir '$APP_DIR' not found"
  SCOPE_FLAG=(); [ -n "$VERCEL_TEAM" ] && SCOPE_FLAG=(--scope "$VERCEL_TEAM")

  log "5/6  Vercel project '$VERCEL_PROJECT'"
  ( cd "$APP_DIR" && vercel link --yes --project "$VERCEL_PROJECT" "${SCOPE_FLAG[@]}" >/dev/null 2>&1 ) \
    || die "vercel link failed (is the project name free / team correct?)"
  ok "linked $APP_DIR → $VERCEL_PROJECT"

  # Make the production site PUBLIC. Many teams default to "Vercel Authentication"
  # (ssoProtection), which SSO-walls the *.vercel.app URLs → a public site 302s to
  # vercel.com/sso-api. There is no CLI flag, so PATCH the project over the API.
  disable_protection "$APP_DIR"

  set_env() { # name value
    ( cd "$APP_DIR"
      for env in production preview development; do
        vercel env rm "$1" "$env" --yes "${SCOPE_FLAG[@]}" >/dev/null 2>&1 || true
        printf '%s' "$2" | vercel env add "$1" "$env" "${SCOPE_FLAG[@]}" >/dev/null 2>&1 || true
      done )
  }
  set_env BARKPARK_API_BASE  "$SCOPED"
  set_env BARKPARK_DATASET   "$DATASET"
  set_env BARKPARK_API_TOKEN "$READ_TOKEN"
  ok "env set (BARKPARK_API_BASE, BARKPARK_DATASET, BARKPARK_API_TOKEN — server-only)"

  log "6/6  Deploy to production"
  URL="$( cd "$APP_DIR" && vercel deploy --prod --yes "${SCOPE_FLAG[@]}" 2>/dev/null | tail -1 )"
  [ -n "$URL" ] || die "deploy produced no URL"
  ok "deployed: $URL"
  printf '\n\033[1;32m🚀 %s is live → %s\033[0m\n' "$SITE" "$URL"
else
  log "5/6  (--no-deploy — Barkpark provisioned, skipping Vercel)"
  printf '\nRead API: %s/v1/data/query/%s/<type>?filter[status]=published\n' "$SCOPED" "$DATASET"
  printf 'Read token (server-only env BARKPARK_API_TOKEN): %s\n' "$READ_TOKEN"
fi

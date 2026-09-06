#!/usr/bin/env bash
# compose-smoke — the self-host compose stack's gate (self-host-blessing S6).
#
# The FIRST CI gate that has ever built api/Dockerfile (charter D1). Driven by
# .github/workflows/compose-smoke.yml; each subcommand's exit code IS the gate
# (create-quickstart-smoke idiom: one script, one final status, no partial green).
#
# Subcommands:
#   refusal        REFUSAL ARM (D20). Compose up with a SHORT SECRET_KEY_BASE and
#                  otherwise-valid generated secrets. The api container must EXIT
#                  NON-ZERO at the migrate step and its logs must carry the anchor
#                  line from runtime.exs's boot refusal. NEVER an HTTP probe:
#                  Plug's 64-byte floor is LAZY — a short secret serves
#                  /api/schemas 200 and only 500s on /login — so an HTTP probe of
#                  /api/schemas is structurally blind to the trap (measured).
#   green          GREEN ARM (D20). Generated secrets → compose up → healthcheck
#                  healthy → IN-CONTAINER `docker compose exec api wget` of
#                  /api/schemas AND /login (the session route — the one Plug's
#                  floor actually protects), both must succeed. Never a host-port
#                  curl: a host beam.smp already bound to :4000 produced a
#                  measured false 200.
#   census         scripts/env-census.py over BOTH runtime roots (api + cloud);
#                  any drift between code's env reads and the compose passthrough
#                  allowlists is a failure (charter D14/D15).
#   blessing-grep  D23: no blessing language on the self-host surface before the
#                  W2 runbook exists. The hedge word is "experimental".
#
# The D17 skip-the-image escape hatch is FORBIDDEN here and in the workflow —
# by name, which is why this file never spells it: vix builds fine on musl with
# no libvips (measured), and skipping the image build would be the D4
# anti-pattern inside the D1 gate.
#
# Timeouts: local measures are order-of-magnitude only (cold build 114s, boot
# 25s on a warm laptop). Ceilings below are derived for a cold shared runner:
# health wait defaults to 600s (first boot runs migrations + seeds behind a
# start_period of 300s); override with COMPOSE_SMOKE_HEALTH_TIMEOUT for slower
# hosts. The workflow's job-level timeout-minutes bounds everything else.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The refusal's first line in api/config/runtime.exs (S1c, PR #10953). The
# "(#{got})" suffix varies; this prefix does not.
ANCHOR='SECRET_KEY_BASE must be at least 64 bytes'

note() { printf '»» %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

# ── shared plumbing ──────────────────────────────────────────────────────────

PROJECT=""

compose() { docker compose -p "$PROJECT" "$@"; }

cleanup() {
  local rc=$?
  if [ -n "$PROJECT" ]; then
    note "cleanup: docker compose -p $PROJECT down"
    docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -f "${PROJECT}-probe" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

# Every secret the compose file hard-requires (`:?`), minted fresh per run with
# the same commands .env.example teaches. SECRET_KEY_BASE is deliberately NOT
# set here — each arm sets its own (that difference IS the experiment).
export_common_env() {
  BARKPARK_CLOAK_KEY="$(openssl rand -base64 32)"
  BARKPARK_KEK="$(openssl rand -base64 32)"                        # decodes to exactly 32 bytes (D12)
  PREVIEW_JWT_SECRET="$(openssl rand -base64 32)"
  BARKPARK_RELEASE_CAPTURE_HMAC_SECRET="$(openssl rand -base64 32)" # >= 32 bytes required
  PHX_HOST=localhost
  export BARKPARK_CLOAK_KEY BARKPARK_KEK PREVIEW_JWT_SECRET \
    BARKPARK_RELEASE_CAPTURE_HMAC_SECRET PHX_HOST
}

# ── refusal arm ──────────────────────────────────────────────────────────────

arm_refusal() {
  PROJECT=bp-smoke-refusal
  trap cleanup EXIT

  export_common_env
  # 27 bytes — the same class as the old docker-compose.yml:23 pseudo-default
  # (26-byte `$(openssl rand -base64 48)` literal) that booted clean and 500'd
  # the first session. Under the S1c refusal this must now die AT BOOT.
  export SECRET_KEY_BASE='deliberately-short-27-bytes'

  note "refusal arm: building the image (api/Dockerfile, repo-root context)"
  compose build api

  note "refusal arm: starting db and waiting for healthy"
  compose up -d --wait db

  local log rc
  log="$(mktemp -t compose-smoke-refusal.XXXXXX)"
  note "refusal arm: running the api container (entrypoint = migrate → seed → serve)"
  set +e
  compose run --no-deps --name "${PROJECT}-probe" api >"$log" 2>&1
  rc=$?
  set -e
  # Belt and braces: the attached run output IS the container's log stream, but
  # grep the daemon-side log too in case the attach dropped bytes.
  docker logs "${PROJECT}-probe" >>"$log" 2>&1 || true

  echo "── container output ──"
  cat "$log"
  echo "──────────────────────"

  if [ "$rc" -eq 0 ]; then
    die "refusal arm: api container exited 0 with a ${#SECRET_KEY_BASE}-byte SECRET_KEY_BASE — the boot refusal did not fire"
  fi
  pass "api container exited non-zero (rc=$rc) at the migrate step — it never reached serving"

  # The assertion is the LOG ANCHOR, never an HTTP probe (see header).
  if ! grep -F -q "$ANCHOR" "$log"; then
    die "refusal arm: container logs do not contain the anchor line '$ANCHOR'"
  fi
  pass "container logs carry the anchor: '$ANCHOR'"
  rm -f "$log"
}

# Re-inspect the container's liveness and, when it has MOVED, fail with the
# container-state cause rather than the caller's cause.
#
# THE DEFECT THIS CLOSES. The health-wait loop below inspects Running /
# RestartCount / Health.Status every 5s and dies with a precise container-state
# message — but it `break`s the moment health reads healthy, and nothing
# re-inspected those two signals ever again. The very next statement was the
# in-container wget. So a container that died, restarted, or lost its listener
# in the window between the last health probe and the exec was reported as
# "in-container wget /api/schemas failed": an HTTP probe failure, when what
# actually happened was a boot crash. Measured twice (#12879, #12889); it sent
# two investigations at the diff instead of at the boot.
#
# Called after the loop breaks AND on every probe failure, so an exec that
# cannot connect always answers "is the container still there?" before blaming
# the request. When the container IS still cleanly running this is a no-op and
# the caller's own probe-failure message stands (that is the negative arm).
assert_container_alive() { # assert_container_alive <cid> <where>
  local cid="$1" where="$2" running restarts status
  running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo unknown)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo unknown)"
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
  if [ "$running" = "true" ] && [ "$restarts" = "0" ]; then
    return 0
  fi
  note "green arm: container re-inspected at ${where} — it is no longer cleanly running"
  echo "── api container logs ──"
  docker logs --tail 100 "$cid" 2>&1 || true
  echo "────────────────────────"
  die "green arm: api container is not cleanly running (running=$running restarts=$restarts health=$status) — with valid generated secrets a boot must never crash or restart"
}

# ── green arm ────────────────────────────────────────────────────────────────

arm_green() {
  PROJECT=bp-smoke-green
  trap cleanup EXIT

  export_common_env
  export SECRET_KEY_BASE="$(openssl rand -base64 64)"   # 88 chars — margin above the 64-byte floor

  note "green arm: building the image (api/Dockerfile, repo-root context)"
  compose build

  note "green arm: docker compose up -d"
  compose up -d

  local cid
  cid="$(compose ps -q api)"
  [ -n "$cid" ] || die "green arm: no api container after up -d"

  local timeout="${COMPOSE_SMOKE_HEALTH_TIMEOUT:-600}"
  local waited=0 status running restarts
  note "green arm: waiting up to ${timeout}s for the api healthcheck (first boot = migrations + seeds)"
  while :; do
    running="$(docker inspect -f '{{.State.Running}}' "$cid")"
    restarts="$(docker inspect -f '{{.RestartCount}}' "$cid")"
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    if [ "$restarts" != "0" ] || { [ "$running" != "true" ] && [ "$status" != "healthy" ]; }; then
      echo "── api container logs ──"
      docker logs "$cid" 2>&1 | tail -n 100
      echo "────────────────────────"
      die "green arm: api container is not cleanly running (running=$running restarts=$restarts health=$status) — with valid generated secrets a boot must never crash or restart"
    fi
    if [ "$status" = "healthy" ]; then
      break
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "── api container logs ──"
      docker logs "$cid" 2>&1 | tail -n 100
      echo "────────────────────────"
      die "green arm: healthcheck not healthy after ${timeout}s (status=$status)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  pass "api healthcheck healthy after ~${waited}s"

  # The loop can only have broken on health=healthy. That is a PAST observation;
  # re-read the present before the probes attribute anything to HTTP.
  assert_container_alive "$cid" "after the health-wait loop"

  # IN-CONTAINER probes via exec, verbatim the charter D20 commands. busybox
  # wget exits non-zero on any HTTP error status, so exit 0 asserts the 200.
  note "green arm: in-container probe /api/schemas"
  if ! compose exec -T api wget -q -O /dev/null http://localhost:4000/api/schemas; then
    assert_container_alive "$cid" "the failed /api/schemas probe"
    die "green arm: in-container wget /api/schemas failed"
  fi
  pass "/api/schemas serves in-container"

  # /login is the SESSION route — the only probe Plug's lazy 64-byte floor can
  # actually fail. /api/schemas alone is structurally blind to a short secret.
  note "green arm: in-container probe /login (session route)"
  if ! compose exec -T api wget -q -O /dev/null http://localhost:4000/login; then
    assert_container_alive "$cid" "the failed /login probe"
    die "green arm: in-container wget /login failed — the session route is the one a bad SECRET_KEY_BASE breaks"
  fi
  pass "/login serves in-container — session key derivation works"
}

# ── env census (both roots) ──────────────────────────────────────────────────

arm_census() {
  note "census: scripts/env-census.py --root api"
  python3 scripts/env-census.py --root api
  note "census: scripts/env-census.py --root cloud"
  python3 scripts/env-census.py --root cloud
  pass "env census green on both runtime roots"
}

# ── blessing-word grep (D23) ─────────────────────────────────────────────────

arm_blessing_grep() {
  # The banned vocabulary, assembled by concatenation so this file can be
  # scanned by its own gate without matching itself. Hedge word: experimental.
  local words
  words='sup''ported|ble''ssed|production[- ]ready|offi''cial'

  # The self-host surface: the charter fence files that exist plus the install-
  # adjacent docs. docs/setup/SELF-HOST.md joins automatically when W2 lands it.
  local files=(
    docker-compose.yml
    .env.example
    cloud/docker-compose.yml
    cloud/.env.example
    api/Dockerfile
    api/Dockerfile.dockerignore
    api/entrypoint.sh
    scripts/env-census.py
    scripts/compose-smoke.sh
    .github/workflows/compose-smoke.yml
    deploy.sh
    README.md
    deploy/README.md
    docs/ops/PROD_OPS.md
    docs/setup/SETUP.md
    docs/setup/GO-LIVE.md
    docs/setup/SELF-HOST.md
  )

  local f allow hits bad=0
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      note "blessing-grep: $f absent (ok — joins the scan when it lands)"
      continue
    fi
    # Per-file allowlist of KNOWN false positives (charter D23), pinned to the
    # exact phrase so new blessing prose in the same file still reds.
    case "$f" in
      deploy/README.md)     allow='not_sup''ported' ;;
      docs/ops/PROD_OPS.md) allow='offi''cial ARM64 binary' ;;
      README.md)            allow='offi''cial home' ;;
      *)                    allow='' ;;
    esac
    hits="$(grep -inE "$words" "$f" || true)"
    if [ -n "$allow" ] && [ -n "$hits" ]; then
      hits="$(printf '%s\n' "$hits" | grep -ivE "$allow" || true)"
    fi
    if [ -n "$hits" ]; then
      printf 'FAIL  blessing language in %s (the runbook does not exist yet — the hedge word is "experimental"):\n%s\n' "$f" "$hits" >&2
      bad=1
    fi
  done

  [ "$bad" -eq 0 ] || exit 1
  pass "no blessing language on the self-host surface"
}

# ── dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  refusal)       arm_refusal ;;
  green)         arm_green ;;
  census)        arm_census ;;
  blessing-grep) arm_blessing_grep ;;
  *)
    echo "usage: $0 refusal|green|census|blessing-grep" >&2
    exit 2
    ;;
esac

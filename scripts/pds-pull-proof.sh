#!/usr/bin/env bash
#
# pds-pull-proof.sh — THE PDS CROWN PROOF, WRITTEN AS AN EXECUTABLE SPECIFICATION.
#
#   scripts/pds-pull-proof.sh --plan        print every step, its precondition and
#                                           whether it is runnable today. NO side
#                                           effects, always exit 0.
#   scripts/pds-pull-proof.sh --all         run the whole ladder.
#   scripts/pds-pull-proof.sh --only 0a,7   run a subset (same rules).
#   scripts/pds-pull-proof.sh --help
#
# WHY THIS EXISTS BEFORE THE ENGINES DO (PDS-D39, "the proof is the program").
# Wave 2 ended with a headline claim nobody had paid for. A proof written last,
# blind, against a live 3.8 GB box is how that happens. So the ladder is authored
# FIRST: roughly half of it passes today against live guerrilla with zero new
# code, and the rest ABORTS by name. A partial transcript with named ABORTs is a
# real artifact; a green one that skipped is not.
#
# THE THREE OUTCOMES — there is no fourth, and there is no silent skip:
#   PASS   the step ran and every assertion held, printed with the numbers it
#          DERIVED at run time. Never a number pasted from a survey.
#   ABORT  the step cannot run yet. It names the exact bp task whose merge
#          unblocks it (or the exact command an operator must run). It is not a
#          failure and it is not a pass.
#   FAIL   the step ran and an assertion did NOT hold. That is the interesting
#          case; it is never downgraded to an ABORT.
#
# Exit: 0 = every selected step PASSed. 1 = at least one FAIL. 2 = no FAILs but
# at least one ABORT (blocked, honestly). 3 = usage/environment error.
#
# ANTI-VACUITY (PDS-D20). Every green here must be one a broken build could not
# also produce. That is why step 0b refuses to assert `/status.json` migration
# health (a stale build prints the identical green), why step 2 refuses
# `/v1/data/counts` (it hard-codes the published perspective and hides every
# draft row), and why step 4's clean scan is only ever reported next to a control
# that FIRES.
#
# COST DISCIPLINE (PDS-D31/D44). This script takes exactly ONE export and it is
# the DEV profile (~51 MB, ~7 s). It never takes a full-fidelity export: that one
# budgeted attempt belongs to pds-w1-crown-proof, and an export that DIES still
# pays ~2.65 GiB on a 3819 MB box.
#
# It does NOT reimplement its two siblings — it CONSUMES them:
#   scripts/pds-scratch-target.sh   boots/tears down the personal-local target
#   scripts/pds-secret-scan.sh      the value-based scan and its control
#
# Environment (all optional; every default is printed by --plan):
#   PDS_SOURCE_BASE      default https://guerrilla.barkpark.cloud
#   PDS_SOURCE_TOKEN     default: the `token` for PDS_SOURCE_BASE in
#                        ~/.config/barkpark/config.json. Never printed.
#   PDS_SOURCE_WORKSPACE default default          PDS_SOURCE_DATASET default production
#   PDS_SOURCE_SSH       default root@157.180.90.121 (read-only provenance +
#                        scan ammo; set empty to refuse SSH entirely)
#   PDS_SOURCE_SSH_KEY   default ~/.ssh/barkpark_indx
#   PDS_SOURCE_PG_DB     default barkpark_prod
#   PDS_NO_SSH_AMMO=1    do not pull scan ammo over SSH (step 4 then ABORTs for
#                        want of ammo rather than scanning with none)
#   PDS_CONTROL_PG       maintenance conninfo for `pds-secret-scan.sh control`
#   BARKPARK_HOME        the scratch target's root. PINNED per run (PDS-D54).
#   PDS_SCRATCH_POINTER  pinned per run — it is ONE global path and two
#                        concurrent PDS runs clobber each other.
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
API_DIR="$REPO_ROOT/api"
SCRATCH_SCRIPT="$SCRIPT_DIR/pds-scratch-target.sh"
SCAN_SCRIPT="$SCRIPT_DIR/pds-secret-scan.sh"

# ── source under proof ───────────────────────────────────────────────────────

SOURCE_BASE="${PDS_SOURCE_BASE:-https://guerrilla.barkpark.cloud}"
SOURCE_WS="${PDS_SOURCE_WORKSPACE:-default}"
SOURCE_DS="${PDS_SOURCE_DATASET:-production}"
SOURCE_SSH="${PDS_SOURCE_SSH-root@157.180.90.121}"
SOURCE_SSH_KEY="${PDS_SOURCE_SSH_KEY:-$HOME/.ssh/barkpark_indx}"
SOURCE_PG_DB="${PDS_SOURCE_PG_DB:-barkpark_prod}"

# ── per-run pinning (PDS-D54) ────────────────────────────────────────────────
#
# BARKPARK_HOME must be short (barkpark-pg's unix socket is capped at 103 bytes
# and pds-scratch-target.sh enforces an 85-byte root cap), and it must live on
# /tmp rather than under an agent scratchpad — see that script's TRAP 3.
# PDS_SCRATCH_POINTER is ONE global path; two concurrent PDS runs sharing it
# tear down each other's target. This wave runs beside two other cycles.

RUN_ID="${PDS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_TAG="$(printf '%s' "$RUN_ID" | cksum | awk '{printf "%x", $1}')"
export BARKPARK_HOME="${BARKPARK_HOME:-/tmp/pds-proof.$RUN_TAG}"
export PDS_SCRATCH_POINTER="${PDS_SCRATCH_POINTER:-/tmp/pds-scratch.$RUN_TAG.last}"
ART_DIR="${PDS_PROOF_ARTIFACTS:-/tmp/pds-proof-art.$RUN_TAG}"
MAX_HOME_LEN=85

# ── output helpers ───────────────────────────────────────────────────────────

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }

RESULTS=""          # one "id<TAB>outcome<TAB>blocker<TAB>detail" line per step
N_PASS=0; N_ABORT=0; N_FAIL=0

record() { # id outcome blocker detail
  RESULTS="$RESULTS$1	$2	$3	$4
"
}

pass() { # id detail
  N_PASS=$((N_PASS + 1))
  printf '  PASS   %-4s %s\n' "$1" "$2"
  record "$1" PASS "-" "$2"
}

abort() { # id blocker detail
  N_ABORT=$((N_ABORT + 1))
  printf '  ABORT  %-4s waits on %s\n' "$1" "$2"
  printf '         %s\n' "$3"
  record "$1" ABORT "$2" "$3"
}

fail() { # id detail
  N_FAIL=$((N_FAIL + 1))
  printf '  FAIL   %-4s %s\n' "$1" "$2"
  record "$1" FAIL "-" "$2"
}

head_step() { # id title
  printf '\n'
  rule
  printf 'STEP %s — %s\n' "$1" "$2"
  rule
}

# ── temp hygiene ─────────────────────────────────────────────────────────────

TMP_FILES=""
TMP_DIRS=""
cleanup() {
  local f d
  for f in $TMP_FILES; do [ -f "$f" ] && rm -f "$f"; done
  for d in $TMP_DIRS; do [ -d "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

mktmp() { # -> path, tracked
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/pds-proof.XXXXXX")"
  TMP_FILES="$TMP_FILES $f"
  printf '%s\n' "$f"
}

# ── source token: resolved, never printed ────────────────────────────────────

SOURCE_TOKEN=""
resolve_source_token() {
  if [ -n "${PDS_SOURCE_TOKEN:-}" ]; then
    SOURCE_TOKEN="$PDS_SOURCE_TOKEN"
    return 0
  fi
  local cfg="$HOME/.config/barkpark/config.json"
  [ -r "$cfg" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  SOURCE_TOKEN="$(BASE="$SOURCE_BASE" python3 - "$cfg" <<'PY' || true
import json, os, sys
base = os.environ["BASE"].rstrip("/")
cfg = json.load(open(sys.argv[1]))
cands = [cfg] + list(cfg.get("known_servers") or [])
for c in cands:
    if str(c.get("server", "")).rstrip("/") == base and c.get("token"):
        print(c["token"])
        break
PY
)"
  [ -n "$SOURCE_TOKEN" ]
}

curl_src() { # path [curl args…] — GET with the admin token, never echoing it
  local path="$1"; shift
  curl -sS --max-time "${PDS_HTTP_TIMEOUT:-120}" \
    -H "Authorization: Bearer $SOURCE_TOKEN" "$SOURCE_BASE$path" "$@"
}

jqp() { # python "field extractor": jqp '<python expr over d>' <<< json
  python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(eval(sys.argv[1]))' "$1"
}

# ── SSH: read-only provenance + scan ammo ────────────────────────────────────
#
# Guerrilla's Postgres is NOT reachable externally, and `/status.json` carries a
# marketing version string, not a sha. SSH is the only run-time source of both
# the deployed sha and the scan's ammo. It is used read-only and the ammo values
# are never printed — pds-secret-scan.sh masks them to length + sha256 prefix.

SSH_OK=""
ssh_available() {
  [ -n "$SSH_OK" ] && { [ "$SSH_OK" = yes ]; return; }
  SSH_OK=no
  if [ -n "$SOURCE_SSH" ] && [ -r "$SOURCE_SSH_KEY" ] && command -v ssh >/dev/null 2>&1; then
    if ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 \
         -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" true >/dev/null 2>&1; then
      SSH_OK=yes
    fi
  fi
  [ "$SSH_OK" = yes ]
}

ssh_src() { # command string, run on the source box
  ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" "$1" 2>/dev/null
}

src_psql() { # sql — read-only. The SQL travels on ssh's STDIN (psql -f -) rather
             # than in the remote command line, so no layer of shell quoting on
             # either side can mangle or re-split it.
  printf '%s\n' "$1" | ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" \
    "sudo -u postgres psql -d '$SOURCE_PG_DB' -At -f -" 2>/dev/null
}

# ── cross-step state (derived at RUN time, never from a snapshot) ────────────

DEPLOYED_SHA=""
DEPLOYED_VERSION=""
DEV_BUNDLE=""
AMMO_FILE=""

# ═════════════════════════════════════════════════════════════════════════════
# THE PLAN
# ═════════════════════════════════════════════════════════════════════════════

plan_row() { # id | title | precondition | today
  printf '  %-4s %s\n' "$1" "$2"
  printf '       precondition: %s\n' "$3"
  printf '       today:        %s\n\n' "$4"
}

cmd_plan() {
  rule
  say "PDS CROWN PROOF — PLAN (no side effects; this mode never touches a network,"
  say "a database, or a filesystem outside its own stdout)"
  rule
  say "source:        $SOURCE_BASE  workspace=$SOURCE_WS  dataset=$SOURCE_DS"
  say "scratch root:  $BARKPARK_HOME  (${#BARKPARK_HOME} bytes, cap $MAX_HOME_LEN)"
  say "pointer:       $PDS_SCRATCH_POINTER"
  say "artifacts:     $ART_DIR"
  say "siblings:      $(basename "$SCRATCH_SCRIPT") $([ -x "$SCRATCH_SCRIPT" ] && echo present || echo MISSING) · $(basename "$SCAN_SCRIPT") $([ -x "$SCAN_SCRIPT" ] && echo present || echo MISSING)"
  say "tooling:       curl $(command -v curl >/dev/null 2>&1 && echo yes || echo NO) · python3 $(command -v python3 >/dev/null 2>&1 && echo yes || echo NO) · psql $(command -v psql >/dev/null 2>&1 && echo yes || echo NO) · ssh $(command -v ssh >/dev/null 2>&1 && echo yes || echo NO) · bp $(command -v bp >/dev/null 2>&1 && echo yes || echo NO)"
  say ""
  say "OUTCOMES: PASS (ran, assertions held, numbers derived at run time) ·"
  say "ABORT (cannot run yet — names the bp task or command that unblocks it) ·"
  say "FAIL (ran, an assertion did not hold). There is no silent skip."
  say ""
  rule

  plan_row 0a "SOURCE FRESHNESS — believe nothing about a differential until the source is pinned" \
    "the source answers /status.json; the dev export dialect (profile+dataset) is DEPLOYED, not merely merged" \
    "RUNNABLE. Takes the one budgeted DEV export (~51 MB, ~7 s) and asserts the manifest's additive profile/dataset/source_* fields. FAILS with 'guerrilla is running older code than main' and the sha it actually served if the dialect is absent."

  plan_row 0b "DEPLOY-PROVENANCE — NOT schema_migrations parity (PDS-D47)" \
    "0a resolved a deployed sha; this worktree is a git checkout" \
    "RUNNABLE. There is NO schema_migrations HTTP surface anywhere and the source's Postgres is unreachable externally; /status.json's migrations component is a boolean over the RUNNING BINARY's own migration files, so a stale build prints the identical green — the vacuous green PDS-D20 forbids. The assertion is instead: the deployed sha EQUALS OR IS AN ANCESTOR OF the worktree the target migrated from."

  plan_row 0c "SENTINELS — Catalog.assert_partition!/1 + assert_dev_partition!/1" \
    "a reachable Repo (the booted scratch target's DB)" \
    "CONDITIONAL. Runs when a scratch target is up; otherwise ABORTS naming the exact command. A NEW tenant table RAISES the fail-closed sentinel — that is reported honestly as a FAIL, never bypassed."

  plan_row 1 "THE PULL — export + import + scrub through one front door" \
    "\`bp dev pull\` exists (pds-w1-pull-cli) and a scratch target is up" \
    "ABORTS naming pds-w1-pull-cli. Mode is PINNED :merge (PDS-D33). The step probes for the verb at run time, so it goes green by itself the moment that CLI merges."

  plan_row 2 "RAW-PERSPECTIVE CENSUS — per-type ?perspective=raw&count=true" \
    "step 1 imported into a target" \
    "SOURCE HALF RUNNABLE (live per-type raw + published totals, schema count, media count). TARGET HALF ABORTS naming pds-w1-pull-cli. NEVER /v1/data/counts/:dataset — it hard-codes perspective=published and ignores ?perspective, hiding every draft row. The bare-slug E3 shortfall (PDS-D45) is PRE-DECLARED and those tables are EXCLUDED from the parity assertion."

  plan_row 3 "TICKET-DENY BYTE-SCAN — bytes at ROW grain, never a count diff" \
    "a dev bundle (0a) plus a full-fidelity bundle for the FIRING control" \
    "HALF RUNNABLE. doc_id and row uuid are RE-DERIVED at run time (the two surveys disagree on the uuid — trust the run). The assertion is at ROW grain — no ticket-carrying member, and zero rows in documents.copy whose own doc_id/type/id fields identify the ticket, with column positions read from the manifest — because the ticket's identifiers are QUOTED IN PROSE by other documents and a naive byte-absence assertion fires on a bundle where the deny held perfectly. Byte hits are still printed and each is classified by its containing document. The step ABORTS naming pds-w1-crown-proof: a zero with no control that fires is the vacuous green PDS-D20 forbids, and the one budgeted full export is crown-proof's."

  plan_row 4 "VALUE-BASED SECRET SCAN — consumes scripts/pds-secret-scan.sh" \
    "run-time ammo (the source's webhook secrets) + a bundle + the target DB" \
    "HALF RUNNABLE. Ammo is pulled at run time; the dev bundle is scanned and the instrument's own control is run when a maintenance PG is configured. The TARGET-DB half ABORTS naming pds-w1-pull-cli and the 8-webhook control on a FULL bundle ABORTS naming pds-w1-crown-proof. Any UNSCANNED table count is surfaced, never silenced."

  plan_row 5 "SERVED ASSET — an imported asset path returns HTTP 200 with a matching content-length" \
    "step 1 imported blobs into the scratch target" \
    "ABORTS naming pds-w1-pull-cli."

  plan_row 6 "CONVERGENCE — two pulls with a REBOOT between them, byte-identical (PDS-D23)" \
    "step 1, plus the provenance guard whose behaviour convergence MEASURES" \
    "ABORTS naming pds-w1-provenance-guard. The Bootstrap clobber fires only on boot, so a convergence proof without a restart proves nothing."

  plan_row 7 "THE NEGATIVE GUARD — import against the SOURCE is refused 403 bundle_import_disabled" \
    "the source answers HTTP" \
    "RUNNABLE, and it PASSES. Re-derived at RUN time on purpose: this is a blue/green box and a deploy could land between the survey and the run. The single point of failure is anyone appending BARKPARK_ALLOW_BUNDLE_IMPORT=1 to an env source."

  rule
  say "Run it:  $0 --all      (or --only 0a,0b,7)"
  rule
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# THE BANNER — the transcript opens by bounding every claim it is about to make
# ═════════════════════════════════════════════════════════════════════════════

banner() {
  local worktree_sha worktree_desc
  worktree_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  worktree_desc="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

  rule
  say "PDS CROWN PROOF — run $RUN_ID"
  rule
  say "HONESTY BANNER — what this transcript does and does not claim."
  say ""
  say "  SOURCE          $SOURCE_BASE (workspace=$SOURCE_WS dataset=$SOURCE_DS)"
  say "  SERVED          resolved live in step 0a and printed there — version AND"
  say "                  git sha. Auto-deploy has been observed NOT firing, so the"
  say "                  box may be running older code than main; if it is, the"
  say "                  transcript says so in step 0a/0b rather than blaming a slice."
  say "  PLANE           the proof runs on THIS host against a disposable"
  say "                  personal-local target ($BARKPARK_HOME), booted by"
  say "                  scripts/pds-scratch-target.sh. Nothing is written to the"
  say "                  source: every source call here is a GET, a read-only psql,"
  say "                  or the import POST of step 7 whose whole point is being REFUSED."
  say "  WORKTREE        $worktree_sha ($worktree_desc)"
  say ""
  say "  SCOPE OF EVERY CLAIM BELOW:"
  say "   · Profile scope — the pull and its scans are the DEV profile. A clean dev"
  say "     scan proves the carrying TABLES ARE ABSENT (:deny), never that a field"
  say "     was scrubbed: @dev_scrub is genuinely empty (PDS-D25)."
  say "   · Convergence scope — content-and-presence convergence of the imported"
  say "     rows, not byte-identity of two independently produced tar files."
  say "   · Census scope — raw-perspective row counts per type. Bare-slug E3 tables"
  say "     are EXCLUDED and the shortfall is pre-declared in step 2 (PDS-D45)."
  say "   · Deploy scope — step 0b asserts DEPLOY PROVENANCE, not migration parity."
  say "     No schema_migrations HTTP surface exists; a stale build prints the same"
  say "     /status.json green (PDS-D47)."
  say ""
  say "  THE SCAN'S OWN LIMITS, VERBATIM (they bound every 'clean' below):"
  say "   1. VERBATIM-VALUE-BASED ONLY. It matches the exact bytes it was given. It"
  say "      does NOT detect derived material — base64/hex re-encodings, prefix"
  say "      slices, HMACs, hashes, or values inside compressed members."
  say "   2. ABSENCE-OF-GIVEN-VALUES ONLY. A clean result proves the target is free"
  say "      of the values you ENUMERATED — never that it is free of secrets nobody"
  say "      enumerated."
  rule
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0a — SOURCE FRESHNESS
# ═════════════════════════════════════════════════════════════════════════════

step_0a() {
  head_step 0a "SOURCE FRESHNESS — pin the source before believing any differential"

  local status code version uptime
  status="$(mktmp)"
  code="$(curl -sS -o "$status" -w '%{http_code}' --max-time 30 "$SOURCE_BASE/status.json" || echo 000)"
  if [ "$code" != "200" ]; then
    fail 0a "GET $SOURCE_BASE/status.json -> $code (the source is not answering; nothing downstream is believable)"
    return 0
  fi
  version="$(jqp 'd["version"]' <"$status" || echo unknown)"
  uptime="$(jqp 'd.get("uptime_seconds","?")' <"$status" || echo '?')"
  DEPLOYED_VERSION="$version"
  info "status.json     status=$(jqp 'd["status"]' <"$status" || echo '?') version=$version uptime_seconds=$uptime"

  # The sha, three ways — the version string above is NOT one (it is a marketing
  # number and two different builds print it identically).
  if ssh_available; then
    DEPLOYED_SHA="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"
    info "deployed sha    $DEPLOYED_SHA  (source of truth: the box's own git HEAD over SSH)"
  else
    info "deployed sha    UNRESOLVED over SSH ($SOURCE_SSH, key $SOURCE_SSH_KEY)"
  fi
  if command -v gh >/dev/null 2>&1; then
    local last_deploy
    last_deploy="$(gh run list --workflow deploy.yml --branch main --limit 1 \
      --json headSha,conclusion,createdAt -q '.[]|"\(.headSha[0:9]) \(.conclusion) \(.createdAt)"' 2>/dev/null || true)"
    info "last deploy run ${last_deploy:-none visible (auto-deploy may not be firing — see task-85eb87a30db908ec)}"
  fi

  # The one budgeted export: DEV profile. Never :full here (PDS-D31/D44).
  mkdir -p "$ART_DIR"
  local bundle hdr t0 t1 bytes elapsed fname
  bundle="$ART_DIR/dev-$SOURCE_WS-$SOURCE_DS.tar"
  hdr="$(mktmp)"
  t0="$(date +%s)"
  code="$(curl_src "/api/workspaces/$SOURCE_WS/export?profile=dev&dataset=$SOURCE_DS" \
            -D "$hdr" -o "$bundle" -w '%{http_code}' || echo 000)"
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  bytes="$(wc -c <"$bundle" 2>/dev/null | tr -d ' ' || echo 0)"
  fname="$(grep -i '^content-disposition:' "$hdr" | sed -n 's/.*filename=\"\{0,1\}\([^\";]*\).*/\1/p' | tr -d '\r' || true)"
  info "dev export      HTTP $code · $bytes bytes · ${elapsed}s · filename=${fname:-none}"

  if [ "$code" != "200" ] || [ "$bytes" -lt 1024 ]; then
    fail 0a "dev export returned HTTP $code / $bytes bytes — guerrilla is running older code than main (served sha ${DEPLOYED_SHA:-unresolved}, version $version)"
    return 0
  fi

  local mdir profile dataset src_ws src_ds has_src_server members
  mdir="$(mktemp -d "${TMPDIR:-/tmp}/pds-manifest.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $mdir"
  if ! tar -xf "$bundle" -C "$mdir" manifest.json 2>/dev/null; then
    fail 0a "the export is not a bp-export-v1 bundle — no manifest.json member"
    return 0
  fi
  members="$(tar -tf "$bundle" | wc -l | tr -d ' ')"
  profile="$(jqp 'd.get("profile")' <"$mdir/manifest.json" || echo None)"
  dataset="$(jqp 'd.get("dataset")' <"$mdir/manifest.json" || echo None)"
  src_ws="$(jqp 'd.get("source_workspace")' <"$mdir/manifest.json" || echo None)"
  src_ds="$(jqp 'd.get("source_dataset")' <"$mdir/manifest.json" || echo None)"
  has_src_server="$(jqp '"source_server" in d' <"$mdir/manifest.json" || echo False)"
  info "manifest        format=$(jqp 'd.get("format")' <"$mdir/manifest.json") members=$members"
  info "                profile=$profile dataset=$dataset source_workspace=$src_ws source_dataset=$src_ds source_server_key=$has_src_server"

  if [ "$profile" != "dev" ] || [ "$dataset" != "$SOURCE_DS" ] || [ "$has_src_server" != "True" ]; then
    fail 0a "the manifest lacks the additive dev dialect (profile=$profile dataset=$dataset source_server_key=$has_src_server) — guerrilla is running older code than main; served sha ${DEPLOYED_SHA:-unresolved}, version $version"
    return 0
  fi

  DEV_BUNDLE="$bundle"
  pass 0a "source pinned: version=$version sha=${DEPLOYED_SHA:-unresolved}; dev dialect LIVE (HTTP 200, $bytes bytes, ${elapsed}s, $members members, profile=$profile dataset=$dataset, source_* present)"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0b — DEPLOY-PROVENANCE, NOT schema_migrations PARITY (PDS-D47)
# ═════════════════════════════════════════════════════════════════════════════

step_0b() {
  head_step 0b "DEPLOY-PROVENANCE — the assertion schema_migrations parity cannot make"

  say "  WHY NOT MIGRATION PARITY: there is NO schema_migrations HTTP surface"
  say "  anywhere in this API, and the source's Postgres is not reachable"
  say "  externally. /status.json's migrations component is a boolean computed by"
  say "  the RUNNING BINARY over its OWN migration files, so a stale build prints"
  say "  an identical green. That is a green a broken build could also produce, and"
  say "  PDS-D20 forbids it. The assertion made here instead is DEPLOY PROVENANCE:"
  say "  the deployed sha EQUALS OR IS AN ANCESTOR OF the worktree the target"
  say "  migrated from."
  say ""

  if [ -z "$DEPLOYED_SHA" ]; then
    abort 0b "env:deployed-sha-unresolved" \
      "no run-time source of the deployed sha. /status.json carries a version string, not a sha. FIX: make SSH reachable (PDS_SOURCE_SSH=$SOURCE_SSH, key $SOURCE_SSH_KEY) or export PDS_DEPLOYED_SHA=<sha> from an authenticated source. Asserting on the version string alone would be exactly the vacuous green this step exists to refuse."
    return 0
  fi

  local worktree_sha ahead code_ahead docs_ahead
  worktree_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo)"
  if [ -z "$worktree_sha" ]; then
    fail 0b "this is not a git checkout — the worktree the target migrated from cannot be named"
    return 0
  fi
  info "deployed  $DEPLOYED_SHA (version $DEPLOYED_VERSION)"
  info "worktree  $worktree_sha"

  if ! git -C "$REPO_ROOT" cat-file -e "$DEPLOYED_SHA^{commit}" 2>/dev/null; then
    fail 0b "the deployed sha $DEPLOYED_SHA is not an object in this checkout — the box is serving code this worktree has never seen"
    return 0
  fi

  if [ "$DEPLOYED_SHA" = "$worktree_sha" ]; then
    pass 0b "deployed sha EQUALS the worktree the target migrated from ($worktree_sha)"
    return 0
  fi

  if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$DEPLOYED_SHA" "$worktree_sha"; then
    fail 0b "the deployed sha $DEPLOYED_SHA is NOT an ancestor of the worktree $worktree_sha — the source is serving code this worktree does not contain, so a schema differential against it is unsound"
    return 0
  fi

  ahead="$(git -C "$REPO_ROOT" rev-list --count "$DEPLOYED_SHA..$worktree_sha")"
  code_ahead="$(git -C "$REPO_ROOT" rev-list "$DEPLOYED_SHA..$worktree_sha" -- api internal cloud js web | wc -l | tr -d ' ')"
  docs_ahead=$((ahead - code_ahead))
  info "worktree is $ahead commit(s) ahead: $code_ahead touching code (api/internal/cloud/js/web), $docs_ahead docs-only"
  git -C "$REPO_ROOT" log --oneline "$DEPLOYED_SHA..$worktree_sha" | sed 's/^/      · /'

  if [ "$code_ahead" -gt 0 ]; then
    info "NOTE: the box is behind on CODE, not only docs. Auto-deploy has been"
    info "observed not firing (task-85eb87a30db908ec). Every source-derived number"
    info "below describes the DEPLOYED build, not main."
  fi

  pass 0b "deploy provenance holds: the deployed sha $DEPLOYED_SHA IS AN ANCESTOR OF the worktree the target migrated from ($worktree_sha), $ahead commit(s) behind — $code_ahead code, $docs_ahead docs-only"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0c — THE FAIL-CLOSED SENTINELS
# ═════════════════════════════════════════════════════════════════════════════

step_0c() {
  head_step 0c "SENTINELS — Catalog.assert_partition!/1 and assert_dev_partition!/1"

  say "  A NEW tenant table RAISES these sentinels by design. If that happens the"
  say "  transcript reports it as a FAIL with the raise message intact — it is"
  say "  never bypassed, never downgraded, and never 'handled' by narrowing the"
  say "  assertion. An unclassified table is an unproven export."
  say ""

  local envf
  envf="$BARKPARK_HOME/scratch.env"
  if [ ! -f "$envf" ]; then
    abort 0c "env:scratch-target-not-booted" \
      "no Repo to run the sentinels against ($envf absent). FIX: BARKPARK_HOME=$BARKPARK_HOME PDS_SCRATCH_POINTER=$PDS_SCRATCH_POINTER $SCRATCH_SCRIPT up --verify   (budget one ~3.5 min cold compile per NEW worktree so a slow first boot is not mistaken for a hang)."
    return 0
  fi

  local out rc
  out="$(mktmp)"
  rc=0
  # shellcheck disable=SC1090
  ( set -a; . "$envf"; set +a
    cd "$API_DIR" && MIX_ENV=dev mix run -e '
      alias Barkpark.Tenancy.WorkspaceBundle.Catalog
      :ok = Catalog.assert_partition!(Barkpark.Repo)
      :ok = Catalog.assert_dev_partition!(Barkpark.Repo)
      IO.puts("SENTINELS OK")
    ' ) >"$out" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] && grep -q 'SENTINELS OK' "$out"; then
    pass 0c "both sentinels returned :ok against the scratch Repo — the live tenant-table membership matches the reviewed E1/E2/E3 partition AND every bundle-reachable table has a dev-partition classification"
  else
    info "$(tail -20 "$out" | sed 's/^/  /')"
    fail 0c "a sentinel RAISED (exit $rc) — see the message above. A new/unclassified tenant table must be classified, not bypassed."
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — THE PULL
# ═════════════════════════════════════════════════════════════════════════════

step_1() {
  head_step 1 "THE PULL — export + import + scrub through one front door (mode PINNED :merge)"

  if command -v bp >/dev/null 2>&1 && bp dev pull --help >/dev/null 2>&1; then
    info "\`bp dev pull\` is present — running it against the scratch target"
    local envf
    envf="$BARKPARK_HOME/scratch.env"
    if [ ! -f "$envf" ]; then
      abort 1 "env:scratch-target-not-booted" \
        "the pull front door exists but there is no target ($envf absent). FIX: BARKPARK_HOME=$BARKPARK_HOME $SCRATCH_SCRIPT up --verify"
      return 0
    fi
    local rc out
    out="$(mktmp)"
    rc=0
    # shellcheck disable=SC1090
    ( set -a; . "$envf"; set +a
      bp dev pull --from "$SOURCE_BASE" --workspace "$SOURCE_WS" --dataset "$SOURCE_DS" \
        --profile dev --mode merge --with-blobs --to "$PDS_SCRATCH_BASE" ) >"$out" 2>&1 || rc=$?
    sed 's/^/      /' "$out"
    if [ "$rc" -eq 0 ]; then
      pass 1 "bp dev pull exited 0 — see the per-file report above (a NON-ZERO exit on any blob failure is that CLI's own contract)"
    else
      fail 1 "bp dev pull exited $rc"
    fi
    return 0
  fi

  abort 1 "pds-w1-pull-cli" \
    "\`bp dev pull\` does not exist in this bp binary. This step probes for the verb at RUN time, so it goes green by itself the moment that slice merges — no edit to this script required. Everything downstream that needs a populated target (2 target half, 5, 6) aborts with it."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — RAW-PERSPECTIVE CENSUS
# ═════════════════════════════════════════════════════════════════════════════

# Bare-slug E3 tables, from api/lib/barkpark/tenancy/workspace_bundle/catalog.ex
# (@e3_dataset_keyed). Derived from the source at run time when it is readable;
# this fallback is only used to NAME the exclusion, never to assert a count.
E3_BARE_SLUG_FALLBACK="preview_token_jti shares"

src_total() { # type perspective -> integer (or empty)
  local t="$1" p="$2"
  curl_src "/v1/data/query/$SOURCE_DS/$t?perspective=$p&count=true&limit=0" \
    | jqp 'd["result"]["total"]' 2>/dev/null || true
}

step_2() {
  head_step 2 "RAW-PERSPECTIVE CENSUS — per-type ?perspective=raw&count=true"

  say "  CARRIER CHOICE: /v1/data/counts/:dataset is NOT used. It hard-codes"
  say "  perspective:\"published\" and ignores ?perspective (raw and default return"
  say "  byte-identical bodies), so every draft row is invisible to it. The per-type"
  say "  query route genuinely honours the parameter, and the raw-vs-published"
  say "  spread printed below is the proof that it does."
  say ""

  local types n_types schemas_json
  schemas_json="$(mktmp)"
  if ! curl_src "/v1/schemas/$SOURCE_DS" >"$schemas_json" 2>/dev/null; then
    fail 2 "GET /v1/schemas/$SOURCE_DS failed — the type roster cannot be derived, and a census over a hardcoded type list is exactly the snapshot this step refuses"
    return 0
  fi
  types="$(jqp '" ".join(sorted(s["name"] for s in d["schemas"]))' <"$schemas_json" 2>/dev/null || true)"
  if [ -z "$types" ]; then
    fail 2 "could not derive the type roster from /v1/schemas/$SOURCE_DS"
    return 0
  fi
  n_types="$(printf '%s\n' "$types" | wc -w | tr -d ' ')"

  # A type whose count call FAILS is NOT the same as a type with zero rows, and
  # collapsing the two is the silent skip this ladder forbids: a broken type
  # would simply vanish from the table and the totals would still look sane.
  # An unreadable count is NAMED in the table (ERR) and fails the step.
  local t raw pub total_raw=0 total_pub=0 drafts unreadable=""
  printf '      %-28s %10s %10s %10s\n' TYPE RAW PUBLISHED DRAFT-ONLY
  for t in $types; do
    raw="$(src_total "$t" raw)"
    pub="$(src_total "$t" published)"
    if [ -z "$raw" ] || [ -z "$pub" ]; then
      printf '      %-28s %10s %10s %10s\n' "$t" "${raw:-ERR}" "${pub:-ERR}" ERR
      unreadable="$unreadable $t"
      continue
    fi
    drafts=$((raw - pub))
    [ "$raw" -eq 0 ] && [ "$pub" -eq 0 ] && continue
    printf '      %-28s %10s %10s %10s\n' "$t" "$raw" "$pub" "$drafts"
    total_raw=$((total_raw + raw))
    total_pub=$((total_pub + pub))
  done
  printf '      %-28s %10s %10s %10s\n' TOTAL "$total_raw" "$total_pub" "$((total_raw - total_pub))"

  if [ -n "$unreadable" ]; then
    fail 2 "the census is INCOMPLETE — no count could be derived for:${unreadable}. A census missing a type is not a census; re-run once the source answers for every declared type rather than reading the totals above as complete."
    return 0
  fi

  local n_schemas n_media
  n_schemas="$(jqp 'len(d["schemas"])' <"$schemas_json" 2>/dev/null || echo '?')"
  n_media="$(curl_src "/v1/media/$SOURCE_DS?limit=1" | jqp 'd["result"]["count"]' 2>/dev/null || echo '?')"
  info "schemas=$n_schemas (GET /v1/schemas/$SOURCE_DS)  media=$n_media (GET /v1/media/$SOURCE_DS)  types with rows: counted above out of $n_types declared"

  if [ "$total_raw" -le "$total_pub" ]; then
    fail 2 "raw ($total_raw) is not greater than published ($total_pub) — either this dataset genuinely has zero drafts, or the perspective parameter is being ignored and this census is measuring the published view while claiming raw. Re-check the carrier before trusting any differential."
    return 0
  fi

  # ── the pre-declared shortfall (PDS-D45) ───────────────────────────────────
  say ""
  say "  *** PRE-DECLARED SHORTFALL — bare-slug E3, EXPECTED, NOT corruption ***"
  say "  :full is NOT lossless. The dataset slug '$SOURCE_DS' is owned by MORE THAN"
  say "  ONE workspace, so dataset_slugs_for/1 drops it under the D21 exclusivity"
  say "  rule and bare-slug E3 tables are exported with dataset = ANY('{}') — i.e."
  say "  nothing. tables/shares.copy is 0 BYTES in the full bundle for exactly this"
  say "  reason. Discovering it mid-run looks like data loss; it is a known,"
  say "  bounded ownership artifact."
  local bare_slug shares_rows owners
  bare_slug="$E3_BARE_SLUG_FALLBACK"
  if ssh_available; then
    shares_rows="$(src_psql "SELECT count(*) FROM shares WHERE dataset='$SOURCE_DS'" | tr -d '[:space:]' || true)"
    owners="$(src_psql "SELECT count(DISTINCT p.workspace_id) FROM datasets d JOIN projects p ON p.id=d.project_id WHERE d.slug='$SOURCE_DS'" | tr -d '[:space:]' || true)"
    info "derived live: shares rows at dataset='$SOURCE_DS' = ${shares_rows:-?} · workspaces owning the slug '$SOURCE_DS' = ${owners:-?} (>1 is what triggers the exclusivity drop)"
  else
    info "the shortfall's magnitude was NOT derived this run (source DB unreachable) — only the exclusion is asserted"
  fi
  info "EXCLUDED from every parity assertion in this step: $bare_slug"

  say ""
  abort 2 "pds-w1-pull-cli" \
    "the SOURCE census above is live and complete (raw $total_raw / published $total_pub across $n_types declared types, $n_schemas schemas, $n_media media). The TARGET half — the per-type diff that makes it a proof rather than a reading — needs a populated target, which needs the pull. Bare-slug E3 tables ($bare_slug) stay excluded when it runs."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — TICKET-DENY BYTE-SCAN
# ═════════════════════════════════════════════════════════════════════════════

step_3() {
  head_step 3 "TICKET-DENY BYTE-SCAN — bytes at ROW grain, never a count diff"

  say "  WHAT A RAW BYTE SCAN CANNOT DO ALONE, learned by running it. The ticket's"
  say "  doc_id and row uuid are DISCUSSED IN PROSE inside other documents (this"
  say "  wave's own papers and tasks quote them). A naive 'these bytes appear"
  say "  nowhere' assertion therefore FIRES on a bundle where the deny held"
  say "  perfectly — a false alarm that reads exactly like a leak. So the assertion"
  say "  is made at ROW grain: no ticket-carrying table member, and zero ROWS in"
  say "  documents.copy whose own doc_id/type/id fields identify the ticket. The"
  say "  byte hits are still printed — and each one is CLASSIFIED by the document"
  say "  that contains it, so a prose reference is never silently equated with the row."
  say ""

  if [ -z "$DEV_BUNDLE" ]; then
    abort 3 "step:0a" "no dev bundle to scan — step 0a did not produce one."
    return 0
  fi

  local doc_id row_uuid
  doc_id="$(curl_src "/v1/data/query/$SOURCE_DS/ticket?perspective=raw&limit=1" \
    | jqp 'd["result"]["documents"][0]["_id"]' 2>/dev/null || true)"
  if [ -z "$doc_id" ]; then
    fail 3 "no ticket row is visible on the source at the raw perspective — the deny leg has nothing to prove absent, so a clean scan below would be vacuous"
    return 0
  fi
  # The published id, if this is a draft (the source's sole ticket is one).
  local pub_id
  pub_id="${doc_id#drafts.}"
  info "ticket doc_id   $doc_id (published id: $pub_id) — RE-DERIVED this run"

  row_uuid=""
  if ssh_available; then
    row_uuid="$(src_psql "SELECT id FROM documents WHERE doc_id IN ('$doc_id','$pub_id') LIMIT 1" | tr -d '[:space:]' || true)"
    info "ticket row uuid $row_uuid — RE-DERIVED this run (the surveys disagree on it; the run is the arbiter)"
  else
    info "ticket row uuid NOT derivable (source DB unreachable) — the row assertion below falls back to doc_id and type"
  fi

  # (a) no ticket-carrying table member at all.
  local bdir ticket_members
  bdir="$(mktemp -d "${TMPDIR:-/tmp}/pds-bundle.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $bdir"
  tar -xf "$DEV_BUNDLE" -C "$bdir"
  ticket_members="$(tar -tf "$DEV_BUNDLE" | grep -i ticket | tr '\n' ' ' | sed 's/ *$//' || true)"
  if [ -n "$ticket_members" ]; then
    fail 3 "the dev bundle carries ticket-named member(s): $ticket_members"
    return 0
  fi
  info "members         no ticket-carrying table member in $(tar -tf "$DEV_BUNDLE" | wc -l | tr -d ' ') members"

  # (b) zero ROWS in documents.copy that ARE the ticket. Column positions come
  # from the manifest's own column list for `documents` — never a hardcoded
  # ordinal, which would silently mis-read after any column addition.
  local cols i_id i_docid i_type n_cols rows
  cols="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
t=[x for x in d["tables"] if x["name"]=="documents"]
if not t: sys.exit(1)
c=t[0]["columns"]
print(c.index("id")+1, c.index("doc_id")+1, c.index("type")+1, len(c))' "$bdir/manifest.json" 2>/dev/null || true)"
  if [ -z "$cols" ]; then
    fail 3 "the manifest does not describe a documents member — the row-grain assertion cannot be made, and a byte scan alone cannot distinguish the row from prose about it"
    return 0
  fi
  i_id="$(printf '%s' "$cols" | awk '{print $1}')"
  i_docid="$(printf '%s' "$cols" | awk '{print $2}')"
  i_type="$(printf '%s' "$cols" | awk '{print $3}')"
  n_cols="$(printf '%s' "$cols" | awk '{print $4}')"
  info "columns         documents: id=\$$i_id doc_id=\$$i_docid type=\$$i_type of $n_cols (from the manifest, this run)"

  # (b0) THE PARSE ITSELF IS AN ASSERTION. The row grammar below is Postgres
  # COPY TEXT — tab-separated, one row per line, embedded newlines escaped. If
  # the member is missing, empty, or ever moves to CSV/BINARY, a tab-split awk
  # reports zero ticket rows and step 3 goes FALSELY CLEAN — the exact failure
  # this step exists to catch. So refuse to trust the parse until it is shown to
  # BE that grammar: the member must exist, carry rows, and its first row must
  # split into exactly the number of fields the manifest declares.
  local docs_copy docs_rows first_fields
  docs_copy="$bdir/tables/documents.copy"
  if [ ! -s "$docs_copy" ]; then
    fail 3 "tables/documents.copy is absent or empty in the dev bundle — a zero ticket-row count over an empty member is vacuous, not clean"
    return 0
  fi
  docs_rows="$(grep -c . "$docs_copy" 2>/dev/null || echo 0)"
  first_fields="$(head -n 1 "$docs_copy" | awk -F'\t' '{print NF}')"
  if [ "${first_fields:-0}" -ne "$n_cols" ]; then
    fail 3 "tables/documents.copy is not the COPY TEXT grammar this assertion parses: its first row splits into ${first_fields:-0} tab-separated fields, the manifest declares $n_cols columns. A tab-split scan of a non-text dump silently finds nothing — refusing to report clean off an unparsed member."
    return 0
  fi
  info "grammar         COPY TEXT confirmed: $docs_rows row(s), first row = $first_fields fields = the manifest's $n_cols columns"

  rows="$(awk -F'\t' -v a="$doc_id" -v b="$pub_id" -v u="$row_uuid" \
            -v ii="$i_id" -v idc="$i_docid" -v it="$i_type" '
          $it == "ticket" || $idc == a || $idc == b || (u != "" && $ii == u) { n++ }
          END { print n + 0 }' "$docs_copy" 2>/dev/null || echo ERR)"
  if [ "$rows" = "ERR" ]; then
    fail 3 "could not read tables/documents.copy out of the dev bundle"
    return 0
  fi
  info "ticket ROWS in tables/documents.copy: $rows (asserted 0)"
  if [ "$rows" -ne 0 ]; then
    fail 3 "the DEV bundle CARRIES $rows ticket row(s) in documents.copy — the type deny did not cascade"
    return 0
  fi

  # (c) the byte scan, printed and CLASSIFIED.
  local args rc out
  out="$(mktmp)"
  args="--bundle $DEV_BUNDLE --profile dev --value $doc_id --value $pub_id"
  [ -n "$row_uuid" ] && args="$args --value $row_uuid"
  rc=0
  # shellcheck disable=SC2086
  "$SCAN_SCRIPT" scan $args >"$out" 2>&1 || rc=$?
  sed 's/^/      /' "$out"
  if [ "$rc" -gt 1 ]; then
    fail 3 "the scan could not run (exit $rc) — see above"
    return 0
  fi

  if [ "$rc" -eq 1 ]; then
    say ""
    info "CLASSIFYING every byte hit — which document CONTAINS it:"
    awk -F'\t' -v a="$doc_id" -v b="$pub_id" -v u="$row_uuid" \
        -v idc="$i_docid" -v it="$i_type" '
      { line = $0 }
      index(line, a) || index(line, b) || (u != "" && index(line, u)) {
        printf "        containing row: doc_id=%s type=%s  (a PROSE reference in this row'\''s own content, not the ticket row)\n", $idc, $it
      }' "$docs_copy" | sort -u | head -20
    info "None of the above IS the ticket row — the row-grain count is 0. This is the"
    info "false-alarm shape a naive byte scan produces for an identifier that other"
    info "documents talk about, and it is reported rather than suppressed."
  else
    info "dev bundle: zero byte hits as well (mechanism = type DENY cascading into documents)"
  fi

  abort 3 "pds-w1-crown-proof" \
    "the ROW-GRAIN zero above is real — and it is HALF a proof: a scan that has never fired on this ammo is not an instrument. The positive control — the same identifiers found in a FULL-fidelity bundle, minutes apart, same binary — needs the one budgeted full export, which is crown-proof's to spend (PDS-D31/D44: a full export peaks beam.smp at ~1.83 GB on a 3819 MB box, and one that DIES still pays ~2.65 GiB)."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — VALUE-BASED SECRET SCAN
# ═════════════════════════════════════════════════════════════════════════════

# Ammo resolution, in order. NEVER printed — pds-secret-scan.sh masks every value
# to length + sha256 prefix, and the file is mode 600 and removed on exit.
resolve_ammo() {
  if [ -n "${PDS_AMMO_FILE:-}" ] && [ -r "${PDS_AMMO_FILE}" ]; then
    AMMO_FILE="$PDS_AMMO_FILE"
    info "ammo            $(wc -l <"$AMMO_FILE" | tr -d ' ') value(s) from PDS_AMMO_FILE"
    return 0
  fi
  if [ "${PDS_NO_SSH_AMMO:-0}" = "1" ]; then
    return 1
  fi
  ssh_available || return 1
  local f n
  f="$(mktmp)"
  chmod 600 "$f"
  src_psql "SELECT secret FROM webhooks WHERE secret IS NOT NULL AND secret <> ''" >"$f" || true
  n="$(grep -c . "$f" 2>/dev/null || echo 0)"
  if [ "$n" -eq 0 ]; then
    return 1
  fi
  AMMO_FILE="$f"
  info "ammo            $n webhook secret(s) pulled read-only from the source DB this run; lengths $(awk '{print length($0)}' "$f" | sort -u | tr '\n' ',' | sed 's/,$//') bytes. Values are never printed."
  return 0
}

step_4() {
  head_step 4 "VALUE-BASED SECRET SCAN — consuming scripts/pds-secret-scan.sh"

  if [ ! -x "$SCAN_SCRIPT" ]; then
    fail 4 "$SCAN_SCRIPT is missing or not executable — this step consumes it and must never reimplement it"
    return 0
  fi

  if ! resolve_ammo; then
    abort 4 "env:no-ammo" \
      "no run-time ammo. The one real discriminator is webhooks.secret, which the HTTP API deliberately never re-exposes after creation, so ammo comes from the source DB (SSH, read-only) or from PDS_AMMO_FILE. A scan with no ammo is not a scan — it is refused rather than reported clean."
    return 0
  fi

  local rc out unscanned
  out="$(mktmp)"
  rc=0
  if [ -n "$DEV_BUNDLE" ]; then
    "$SCAN_SCRIPT" scan --bundle "$DEV_BUNDLE" --ammo-file "$AMMO_FILE" --profile dev >"$out" 2>&1 || rc=$?
    sed 's/^/      /' "$out"
    unscanned="$(grep -c 'UNSCANNED' "$out" 2>/dev/null || true)"
    info "UNSCANNED notices in the output above: ${unscanned:-0} (never silenced — an unscannable table is not a clean table)"
    if [ "$rc" -eq 1 ]; then
      fail 4 "the DEV bundle CARRIES enumerated secret values — the dev partition's table deny did not hold"
      return 0
    elif [ "$rc" -ne 0 ]; then
      fail 4 "the scan could not run against the dev bundle (exit $rc)"
      return 0
    fi
    info "dev bundle: CLEAN"
  else
    info "no dev bundle from step 0a — the bundle half of this step did not run"
  fi

  # The instrument's OWN control: a local throwaway fixture, no guerrilla export.
  if [ -n "${PDS_CONTROL_PG:-}" ]; then
    local crc cout
    cout="$(mktmp)"
    crc=0
    "$SCAN_SCRIPT" control --pg "$PDS_CONTROL_PG" >"$cout" 2>&1 || crc=$?
    sed 's/^/      /' "$cout"
    if [ "$crc" -eq 0 ]; then
      info "instrument control: PASSED — the scan FIRES on a full-shaped fixture and comes back clean on a deny-shaped one"
    else
      fail 4 "the scan's own control did not behave as a control (exit $crc) — every clean result above is therefore uninterpretable"
      return 0
    fi
  else
    info "instrument control: NOT RUN (set PDS_CONTROL_PG=<maintenance conninfo> to run \`$SCAN_SCRIPT control\` — it builds its own throwaway fixture and spends no guerrilla export)"
  fi

  abort 4 "pds-w1-crown-proof + pds-w1-pull-cli" \
    "two halves are still owed and neither is fakeable here. (a) THE CONTROL THAT MATTERS: the enumerated webhook secrets FOUND in a full-fidelity bundle of this very source, minutes apart, same binary, same ammo — that is crown-proof's one budgeted full export. (b) THE TARGET DB: scanning the imported rows (\`--db \$PDS_SCRATCH_DB\`) needs a populated target, which needs pds-w1-pull-cli. Until (a) lands, the clean result above proves the instrument was pointed at the bundle — not that the instrument can see."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEPS 5, 6 — blocked by name
# ═════════════════════════════════════════════════════════════════════════════

step_5() {
  head_step 5 "SERVED ASSET — an imported asset serves HTTP 200 with a matching content-length"
  local envf="$BARKPARK_HOME/scratch.env"
  if [ -f "$envf" ]; then
    info "a scratch target exists at $BARKPARK_HOME, but nothing has been imported into it"
  fi
  abort 5 "pds-w1-pull-cli" \
    "there is no imported asset to serve. When the pull lands, this step resolves an asset from the TARGET's own media index (never a path guessed from the source), GETs it, and compares the served content-length against the stored byte size — a 200 with a truncated body is the failure this must catch."
}

step_6() {
  head_step 6 "CONVERGENCE — two pulls with a REBOOT between them (PDS-D23)"
  say "  The Bootstrap clobber fires only on BOOT. A convergence proof that does not"
  say "  restart the target between the two pulls measures nothing: it re-runs an"
  say "  import against a process that never had the chance to overwrite anything."
  say "  A warm re-boot with the full verify suite measured ~14.6 s — the restart is"
  say "  essentially free, and skipping it is exactly the vacuous green PDS-D20 forbids."
  say ""
  abort 6 "pds-w1-provenance-guard" \
    "convergence is the guard's MEASUREMENT, not an independent property: what the second pull must find unchanged is the provenance stamp (source server/workspace/dataset, pulled_at, scrub profile) and the schemas the boot-time upsert would otherwise clobber. Running it before the guard exists would measure the clobber and call it convergence."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 — THE NEGATIVE GUARD (runs today, and passes)
# ═════════════════════════════════════════════════════════════════════════════

step_7() {
  head_step 7 "THE NEGATIVE GUARD — import against the SOURCE must be REFUSED"

  say "  Re-derived at RUN time on purpose. This is a blue/green box: a deploy could"
  say "  land between any survey and this run, and the single point of failure is"
  say "  anyone appending BARKPARK_ALLOW_BUNDLE_IMPORT=1 to an env source. A refusal"
  say "  proven yesterday is not a refusal proven now."
  say ""

  local body code
  body="$(mktmp)"
  code="$(curl_src "/api/workspaces/$SOURCE_WS/import?mode=merge" \
            -X POST -H 'Content-Type: application/octet-stream' \
            --data-binary 'pds-proof-probe' -o "$body" -w '%{http_code}' || echo 000)"
  local err
  err="$(jqp 'd["error"]["code"]' <"$body" 2>/dev/null || echo '')"
  info "POST /api/workspaces/$SOURCE_WS/import?mode=merge -> HTTP $code  code=${err:-none}"
  info "body: $(head -c 300 "$body")"

  if [ "$code" = "403" ] && [ "$err" = "bundle_import_disabled" ]; then
    pass 7 "the source REFUSES bundle import: HTTP 403 bundle_import_disabled, re-derived this run against $SOURCE_BASE (deployed sha ${DEPLOYED_SHA:-unresolved})"
  else
    fail 7 "the source did NOT refuse: HTTP $code code=${err:-none}. If this is a 2xx, a live content API is accepting bundle imports — check every env source (including .slots/*.env) for BARKPARK_ALLOW_BUNDLE_IMPORT."
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DRIVER
# ═════════════════════════════════════════════════════════════════════════════

ALL_STEPS="0a 0b 0c 1 2 3 4 5 6 7"

summary() {
  printf '\n'
  rule
  say "SUMMARY — run $RUN_ID"
  rule
  printf '%s' "$RESULTS" | while IFS="$(printf '\t')" read -r id outcome blocker _detail; do
    [ -n "$id" ] || continue
    if [ "$outcome" = "ABORT" ]; then
      printf '  %-6s %-4s waits on %s\n' "$outcome" "$id" "$blocker"
    else
      printf '  %-6s %-4s\n' "$outcome" "$id"
    fi
  done
  rule
  printf '  %d PASS · %d ABORT (blocked, named) · %d FAIL\n' "$N_PASS" "$N_ABORT" "$N_FAIL"
  rule
  if [ "$N_FAIL" -gt 0 ]; then
    say "RESULT: FAIL — an assertion did not hold. That is the finding; do not re-run until it is explained."
    return 1
  fi
  if [ "$N_ABORT" -gt 0 ]; then
    say "RESULT: BLOCKED — every step above either passed with run-time numbers or"
    say "named the merge it waits on. This is the honest partial artifact the wave"
    say "is supposed to carry; it is NOT a green."
    return 2
  fi
  say "RESULT: PASS — the whole ladder ran and held."
  return 0
}

run_steps() { # space-separated ids
  local s
  banner
  for s in $1; do
    case "$s" in
      0a) step_0a ;;
      0b) step_0b ;;
      0c) step_0c ;;
      1)  step_1 ;;
      2)  step_2 ;;
      3)  step_3 ;;
      4)  step_4 ;;
      5)  step_5 ;;
      6)  step_6 ;;
      7)  step_7 ;;
      *)  die "unknown step '$s' (known: $ALL_STEPS)" ;;
    esac
  done
}

preflight() {
  command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH (used to read JSON without a jq dependency)"
  command -v tar >/dev/null 2>&1 || die "tar not found on PATH"
  [ -x "$SCAN_SCRIPT" ] || die "$SCAN_SCRIPT missing — this harness consumes it, it does not reimplement it"
  if [ "${#BARKPARK_HOME}" -ge "$MAX_HOME_LEN" ]; then
    die "BARKPARK_HOME is ${#BARKPARK_HOME} bytes (cap $MAX_HOME_LEN): $BARKPARK_HOME
  Postgres caps the unix-socket path at 103 bytes and barkpark-pg puts the socket
  inside this root. Use a short root, e.g. BARKPARK_HOME=/tmp/pds.\$\$"
  fi
  resolve_source_token || die "no source token. Set PDS_SOURCE_TOKEN, or add $SOURCE_BASE to ~/.config/barkpark/config.json. (It is never printed by this script.)"
}

main() {
  case "${1:---plan}" in
    --plan|plan)
      cmd_plan
      exit 0
      ;;
    --all|all)
      preflight
      run_steps "$ALL_STEPS"
      summary
      exit $?
      ;;
    --only)
      [ $# -ge 2 ] || die "--only needs a comma-separated step list (e.g. --only 0a,0b,7)"
      preflight
      run_steps "$(printf '%s' "$2" | tr ',' ' ')"
      summary
      exit $?
      ;;
    -h|--help|help)
      sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'usage: %s {--plan|--all|--only <ids>|--help}\n' "$SELF" >&2
      exit 3
      ;;
  esac
}

main "$@"

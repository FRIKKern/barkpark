#!/usr/bin/env bash
#
# pdf-mvp0-journey-proof.sh — THE MVP-0 STRANGER-JOURNEY PROOF (Personal Dev
# Fleet, charter PDF-D83..D93; folds the stranded r3 harness dialect per D90 —
# extracted from git commit 6c24833a4:scripts/pdf-support-proof.sh). This is the
# SEAL of the MVP-0 wave (wave paper personal-dev-fleet-wave-mvp0-2026-07-24) and
# closes EPIC CRITERION 1 (the console stranger journey) per PDF-D33 — the lead
# stamps that from this transcript.
#
# THE INVERSION (PDF-D83): support provisioning is now a CONTROL-PLANE job. The
# journey DRIVER (this harness, standing in for the /new browser journey) speaks
# ONLY member-level HTTP to the control plane + the main. It carries NO
# fleet-project Hetzner token and NO SSH key for provisioning — the CP is the
# hands. Two NAMED exceptions to that credential-empty envelope, said plainly in
# the transcript wherever they fire: (a) the R4 model-key hand-off (PDF-D88 — the
# developer's own key, seeded over SSH as a visible step), and (b) R5 teardown
# (server-side support remove is backlog pdf-bl-support-remove-serverside, so the
# box delete needs the fleet-project provider credential — a NAMED credential,
# outside the journey envelope by design).
#
#   scripts/pdf-mvp0-journey-proof.sh --plan       print every rung, its assert
#                                                  and the online/timeout law. NO
#                                                  side effects, always exit 0.
#   scripts/pdf-mvp0-journey-proof.sh              the proof (LIVE): launches ONE
#                                                  main + ONE support ENTIRELY
#                                                  CP-side (real money, minutes,
#                                                  torn down), all names
#                                                  mvp0proof- prefixed, every
#                                                  write cleaned by its own
#                                                  teardown + the trap.
#   scripts/pdf-mvp0-journey-proof.sh --negctl     the negative control (NO box,
#                                                  no spend): the harness BEATS a
#                                                  phantom provisioning row and
#                                                  the "never onlines" assert must
#                                                  FIRE AS A FAILURE — a check
#                                                  that cannot fail proves nothing
#                                                  (PDS-D20 inherited).
#   scripts/pdf-mvp0-journey-proof.sh --scan-transcript <file>
#                                                  token-scan a transcript before
#                                                  it is committed: the guerrilla
#                                                  admin bearer, the cloud_token,
#                                                  any hcloud token, any sk-ant
#                                                  prefix — ZERO hits or no commit.
#   scripts/pdf-mvp0-journey-proof.sh --help
#
# THE THREE OUTCOMES (the pds-pull-proof ladder, verbatim — no fourth, no silent
# skip):
#   PASS   the rung ran and every assertion held.
#   ABORT  the rung cannot run (missing/route-shape/stale-deploy/entitlement/
#          capacity/ — a substrate problem, never a verdict on the thing under
#          test). R0 is ABORT-only by construction.
#   FAIL   the rung ran and an assertion did NOT hold.
# Exit: 0 = every rung PASSed (in --negctl: the never-onlines assert FIRED as a
# failure, that mode's pass). 1 = FAIL. 2 = ABORT. 3 = usage error.
#
# RUNGS (run mode; PDF-D83..D93):
#   0  PRECONDITION — ABORT-only: config bearers; the JOURNEY is credential-empty
#      (HCLOUD_TOKEN must NOT be in this shell — its presence ABORTS); PR #6038
#      merged (the CP-deploy filter fix — provisioner redeploys on internal/+cmd/;
#      GitHub API); the CP + provisioner + guerrilla routes answer their
#      contracted anon-401s (a 404 on POST /v1/fleet/supports ABORTS naming
#      pdf-wc-cp-network-recreate, PDF-D67; a 404 on the support-jobs claim ABORTS
#      naming a provisioner that never carried provision_support); and — the
#      MONEY-SAFETY GATE — the NAMED teardown credential resolves AND provably
#      addresses the CP's provisioning project (a CP-managed host must be visible
#      through it). NEVER create a box you cannot tear down (server-side support
#      remove is backlog).
#   1  CREATE-MAIN — CP HTTP only (the /new journey's calls): POST /v1/launch →
#      poll GET /v1/barkparks provision_steps → the main reads live (host set,
#      health up). A CP-provisioned MAIN is CP-DEPROVISIONABLE (DELETE
#      /v1/barkparks/:id → deprovision job), so R1's box teardown is credential-
#      empty by construction.
#   2  ADD-SUPPORT — POST /v1/fleet/supports {mode:provision} → 202 {barkpark,
#      job_id} → poll GET /v1/barkparks the SUPPORT row's provision_steps
#      (create→configure→content→verify→ready). ASSERT the support roster row
#      reads provisioning BEFORE the listener's first heartbeat and NEVER
#      online-before-beat; ONLINE asserted from the MAIN's roster only after the
#      listener's own beat (PDF-D89 — the server-side roster poll is the job's
#      verify step; the row truthfully reads idle|working|blocked WITH capacity).
#   3  NEGCTL stuck-provisioning — a withheld/broken-listener variant: publish a
#      short-TTL provisioning phantom row on the main and poll; the row FAILS at
#      its own timeout (ages to offline) and reads online at NO sample (honest,
#      never bills — PDF-D10). The R2 support stays online concurrently (the
#      one-box co-assert).
#   4  OFFLOAD — the NAMED KEY RUNG FIRST (PDF-D88): pre-seed ANTHROPIC_API_KEY on
#      the box via the EXACT one-liner (key from the harness env; this is the
#      visible BYO step, OUTSIDE the credential-empty envelope BY DESIGN and said
#      so). No key present → a NAMED SKIP and the order-execution leg then only
#      files+watches to claimed (a keyless box can never execute — every order is
#      an LLM turn). Then mint the member app token (POST /v1/barkparks/:id/app-
#      token), file the order app-token-direct on the MAIN
#      (POST {main}/v1/data/mutate/{dataset}), assert claim→working→done from the
#      roster + task truth, and run a MAIN-responsiveness parity probe DURING
#      execution.
#   5  TEARDOWN — bp cloud support remove (the NAMED teardown credential) + FOUR-
#      surface verify-gone census delta zero (PDF-D63): (1) the token 403→401
#      revocation probe on the admin-gated mint endpoint, (2) the box (provider
#      label scan), (3) the roster row, (4) the CP support row. THEN deprovision
#      the R1 main (DELETE /v1/barkparks/:id) and confirm it leaves. Census delta
#      zero at the end; the guerrilla parent + the operator's own instances SURVIVE.
#
# CREDENTIAL-EMPTY LAW: the journey driver's R1-R2-R4-filing legs run with NO
# HCLOUD_TOKEN and no provisioning SSH — asserted structurally (R0 ABORTS if
# HCLOUD_TOKEN is in the shell). The key rung and teardown are the two NAMED
# exceptions, each narrated where it fires.
#
# GATE: bash -n scripts/pdf-mvp0-journey-proof.sh &&
#       bash scripts/pdf-mvp0-journey-proof.sh --plan   (plan is provably
#       side-effect-free: no mktemp, no network, no config reads — it only prints).
#
# Environment (all optional unless said; --plan prints the defaults):
#   PDFJP_MAIN_BASE            default https://guerrilla.barkpark.cloud (the
#                             operator's ratified MAIN — R2 binds the support to
#                             the R1 main, NOT this; this is the roster host for
#                             the admin-bearer reads + R0 shape probes)
#   PDFJP_CP_BASE             default https://api.barkpark.cloud (the control
#                             plane; bearer = config.json .cloud_token)
#   PDFJP_DATASET             default production
#   ANTHROPIC_API_KEY         enables R4's key rung + order execution; else a
#                             NAMED SKIP (the file-and-watch-to-claimed arm)
#   PDFJP_TEARDOWN_HCLOUD_TOKEN   the NAMED fleet-project teardown token (else the
#                             hcloud context named below). Its ABSENCE with no
#                             usable fleet context ABORTS R0 before any create.
#   PDFJP_TEARDOWN_HCLOUD_CONTEXT default 'barkpark' — the hcloud context whose
#                             token addresses the CP's provisioning project.
#   PDFJP_SSH_KEY             default ~/.ssh/barkpark_indx (the R4 key-seed leg;
#                             absent → the key rung degrades to a narrated SKIP)
#   PDFJP_NEG_TTL             phantom row ttl_s (default 30 — NEVER 1800)
#   PDFJP_SKEW               client/server clock margin, s (default 10)
#   PDFJP_POLL_BUDGET        support online poll floor, s (default 900 — the
#                             server-side verify budget is ~10 min, PDF-D89)
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail
# set -m FIRST (PDF-D28): job control gives any backgrounded helper its OWN
# process group — the skeleton is transcribed from the donor proofs verbatim.
set -m

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

# ── fixtures (charter PDF-D83..D93 — transcribed, not explored) ───────────────

MAIN_BASE="${PDFJP_MAIN_BASE:-https://guerrilla.barkpark.cloud}"
CP_BASE="${PDFJP_CP_BASE:-https://api.barkpark.cloud}"
DATASET="${PDFJP_DATASET:-production}"
GH_REPO="FRIKKern/barkpark"
GH_API="https://api.github.com/repos/$GH_REPO"
CONFIG_JSON="$HOME/.config/barkpark/config.json"

TEARDOWN_HC_TOKEN="${PDFJP_TEARDOWN_HCLOUD_TOKEN:-}"
TEARDOWN_HC_CTX="${PDFJP_TEARDOWN_HCLOUD_CONTEXT:-barkpark}"
SSH_KEY="${PDFJP_SSH_KEY:-$HOME/.ssh/barkpark_indx}"
FLEET_LABEL="barkpark-fleet-support"
MANAGED_LABEL="barkpark-managed"

TS="$(date -u +%y%m%d%H%M%S)"
MAIN_NAME="mvp0proof-m-$TS"                     # slugified by the CP
SUPPORT_NAME="mvp0proof-s-$TS"                  # DNS-label; ≤63 by construction
PHANTOM_WORKER="mvp0proof-negctl-$TS"
PHANTOM_ROW_ID="listener-$PHANTOM_WORKER"
ORDER_ID="mvp0proof-order-$TS"

TTL_S="${PDFJP_NEG_TTL:-30}"                    # phantom ttl — NEVER the 1800
SKEW="${PDFJP_SKEW:-10}"
ONLINE_EDGE=$((TTL_S - SKEW))                   # below this: MUST provisioning
OFFLINE_EDGE=$((TTL_S + 1 + SKEW))              # at/after this: MUST offline
POLL_BUDGET="${PDFJP_POLL_BUDGET:-1800}"        # provision-poll ceiling (s) — the
                                                # support chain's own bound is 30
                                                # min (DefaultSupportProvisionTimeout);
                                                # polling less would FAIL a run the
                                                # worker later legitimately succeeds
NEG_BEAT_EVERY=5
PR_6038=6038                                    # the CP-deploy-filter fix

MODE="run"
TRANSCRIPT_TARGET=""
case "${1:-}" in
  "")                MODE="run" ;;
  --plan)            MODE="plan" ;;
  --negctl)          MODE="negctl" ;;
  --scan-transcript) MODE="scan"; TRANSCRIPT_TARGET="${2:-}" ;;
  -h|--help)         sed -n '3,120p' "$0"; exit 0 ;;
  *) printf '%s: unknown argument %s (try --help)\n' "$SELF" "$1" >&2; exit 3 ;;
esac

# ── output helpers (the pds-pull-proof dialect) ──────────────────────────────

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }

N_PASS=0; N_ABORT=0; N_FAIL=0
pass()  { N_PASS=$((N_PASS + 1));  printf '  PASS   %-3s %s\n' "$1" "$2"; }
abort() { N_ABORT=$((N_ABORT + 1)); printf '  ABORT  %-3s %s\n' "$1" "$2"; printf '         %s\n' "$3"; }
fail()  { N_FAIL=$((N_FAIL + 1));  printf '  FAIL   %-3s %s\n' "$1" "$2"; }

head_rung() { printf '\n'; rule; printf 'RUNG %s — %s\n' "$1" "$2"; rule; }

R_FAILS=0
efail() { R_FAILS=$((R_FAILS + 1)); say "      ASSERT-FAIL: $*"; }
rung_seal() { # n summary — FAIL+exit if any efail fired, else PASS and reset
  if [ "$R_FAILS" -gt 0 ]; then
    fail "$1" "$2 — $R_FAILS assertion(s) failed (see the ASSERT-FAIL lines above)"
    exit 1
  fi
  pass "$1" "$2"
}

# ── small tools (LC_ALL=C on the float helpers is load-bearing under a
# comma-decimal locale — a live-hit in the kill-listener proof; transcribed) ──

now_epoch() { python3 -c 'import time; print("%.3f" % time.time())'; }

iso_to_epoch() { # ISO8601 (with Z) -> epoch float
  python3 -c '
import sys
from datetime import datetime
s = sys.argv[1].strip().replace("Z", "+00:00")
print("%.6f" % datetime.fromisoformat(s).timestamp())' "$1"
}

fcmp() { # a op b — float comparison; true when it holds
  LC_ALL=C awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
    if (op == "<")  exit !(a <  b)
    if (op == "<=") exit !(a <= b)
    if (op == ">")  exit !(a >  b)
    if (op == ">=") exit !(a >= b)
    exit 1
  }'
}

fsub() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a - b}'; }

# ── bearer-curl helpers (the donor dialect; tokens never printed) ────────────

ADMIN_TOKEN=""; CLOUD_TOKEN=""; APP_TOKEN=""; BP=""

main_get() { # path -> body (guerrilla admin bearer)
  curl -sS --max-time 25 -H "Authorization: Bearer $ADMIN_TOKEN" "$MAIN_BASE$1"
}

main_post_code() { # path json-body outfile bearer -> http code
  curl -sS --max-time 25 -o "$3" -w '%{http_code}' -X POST "$1" \
    -H "Authorization: Bearer $4" -H 'Content-Type: application/json' \
    -d "$2" 2>/dev/null | tr -dc '0-9' | tail -c 3
}

anon_post_code() { # url -> http code, anonymous POST {} (probe: writes nothing)
  curl -sS --max-time 25 -o /dev/null -w '%{http_code}' -X POST "$1" \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null | tr -dc '0-9' | tail -c 3
}

cp_get() { # path -> body (cloud bearer)
  curl -sS --max-time 25 -H "Authorization: Bearer $CLOUD_TOKEN" "$CP_BASE$1"
}

cp_post_code() { # path json-body outfile -> http code (cloud bearer)
  curl -sS --max-time 30 -o "$3" -w '%{http_code}' -X POST "$CP_BASE$1" \
    -H "Authorization: Bearer $CLOUD_TOKEN" -H 'Content-Type: application/json' \
    -d "$2" 2>/dev/null | tr -dc '0-9' | tail -c 3
}

cp_delete_code() { # path outfile -> http code (cloud bearer)
  curl -sS --max-time 30 -o "$2" -w '%{http_code}' -X DELETE "$CP_BASE$1" \
    -H "Authorization: Bearer $CLOUD_TOKEN" 2>/dev/null | tr -dc '0-9' | tail -c 3
}

gh_get() { # repo-relative path -> body (public, unauthenticated)
  curl -sS --max-time 30 -H 'Accept: application/vnd.github+json' "$GH_API/$1"
}

curl_roster() { main_get "/v1/fleet/roster?dataset=$DATASET"; }

# The JOURNEY main (the R1 instance) — the support binds to IT, its roster is
# THE roster the support onlines on, and the offload data plane targets it.
# JMAIN_TOKEN is the R1 main's own admin token, revealed to the team admin by
# GET /v1/barkparks/:id/credentials (the /new journey's own surface) — header
# use only, never printed.
JMAIN_URL=""; JMAIN_TOKEN=""

# The FRESH JOURNEY TEAM (the brief's R0: "fresh journey team with auto-trial").
# The stranger registers via POST /v1/auth/register and drives EVERY journey leg
# with that session — the trial auto-starts at go-live (dwb-13), its ceiling of
# ONE main is saturated by R1, and add-support still succeeds because supports
# are quota-exempt (PDF-D86 — this run proves that decision live). The session
# token + password live only in-process, never printed.
JTEAM_TOKEN=""; JTEAM_ID=""

jcp_get() { # path -> body (journey-team session bearer)
  curl -sS --max-time 25 -H "Authorization: Bearer $JTEAM_TOKEN" "$CP_BASE$1"
}

jcp_post_code() { # path json-body outfile -> http code (journey-team session)
  curl -sS --max-time 30 -o "$3" -w '%{http_code}' -X POST "$CP_BASE$1" \
    -H "Authorization: Bearer $JTEAM_TOKEN" -H 'Content-Type: application/json' \
    -d "$2" 2>/dev/null | tr -dc '0-9' | tail -c 3
}

jcp_delete_code() { # path outfile -> http code (journey-team session)
  curl -sS --max-time 30 -o "$2" -w '%{http_code}' -X DELETE "$CP_BASE$1" \
    -H "Authorization: Bearer $JTEAM_TOKEN" 2>/dev/null | tr -dc '0-9' | tail -c 3
}

jroster() { # the R1 main's roster (the journey truth for R2-R5)
  curl -sS --max-time 25 -H "Authorization: Bearer $JMAIN_TOKEN" \
    "$JMAIN_URL/v1/fleet/roster?dataset=$DATASET"
}

row_of() { # worker; roster JSON on stdin -> that row as one-line JSON, or ""
  W="$1" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("documents") or []:
    if r.get("worker") == os.environ["W"]:
        print(json.dumps(r, sort_keys=True))
        break
'
}

field_of() { # key; row JSON on stdin -> value, or ""
  K="$1" python3 -c '
import json, os, sys
line = sys.stdin.read().strip()
if not line:
    sys.exit(0)
v = json.loads(line).get(os.environ["K"])
if isinstance(v, (dict, list)):
    print(json.dumps(v, sort_keys=True))
else:
    print("" if v is None else v)'
}

# online iff status in {idle,working,blocked} AND non-empty capacity map —
# BEHAVIOR, never a literal "online" string (PDF-D23/D89).
row_is_online() { # row JSON on stdin -> exit 0 iff online-with-capacity
  python3 -c '
import json, sys
line = sys.stdin.read().strip()
if not line:
    sys.exit(1)
r = json.loads(line)
cap = r.get("capacity")
sys.exit(0 if r.get("status") in ("idle", "working", "blocked")
            and isinstance(cap, dict) and len(cap) > 0 else 1)'
}

# ── mutate helpers on the MAIN (dataset-in-path, PDF-D44d) ───────────────────

mutate() { # base bearer json-mutations-array outfile -> http code
  main_post_code "$1/v1/data/mutate/$DATASET" "{\"mutations\":$3}" "$4" "$2"
}

delete_doc() { # base bearer id type — best-effort; census re-reads are the truth
  local out; out="${TMPDIR:-/tmp}/pdfjp-del.$$"
  mutate "$1" "$2" "[{\"delete\":{\"id\":\"$3\",\"type\":\"$4\"}}]" "$out" >/dev/null 2>&1 || true
  rm -f "$out"
}

# ── the teardown trap: installed BEFORE any write (D82(9)) ────────────────────
#
# Every write is cleaned by its own teardown; the trap is the always-runs
# backstop. The support box's last resort is `bp cloud support remove` under the
# NAMED teardown credential (server-side support remove is backlog); the main is
# CP-deprovisionable via DELETE /v1/barkparks/:id.

MAIN_CREATED=""; MAIN_REMOVED=""; MAIN_ID=""
SUPPORT_CREATED=""; SUPPORT_REMOVED=""; SUPPORT_ID=""
PHANTOM_PUBLISHED=""; PHANTOM_DELETED=""
ORDER_FILED=""; ORDER_DELETED=""
WORKDIR=""

# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
  set +e
  if [ -n "$ORDER_FILED" ] && [ -z "$ORDER_DELETED" ]; then
    say "cleanup: deleting order $ORDER_ID on the main"
    delete_doc "$MAIN_URL" "$APP_TOKEN" "$ORDER_ID" "task"
  fi
  if [ -n "$PHANTOM_PUBLISHED" ] && [ -z "$PHANTOM_DELETED" ]; then
    say "cleanup: deleting phantom roster row $PHANTOM_ROW_ID"
    if [ -n "$JMAIN_URL" ] && [ -n "$JMAIN_TOKEN" ]; then
      delete_doc "$JMAIN_URL" "$JMAIN_TOKEN" "$PHANTOM_ROW_ID" "listener"
    else
      delete_doc "$MAIN_BASE" "$ADMIN_TOKEN" "$PHANTOM_ROW_ID" "listener"
    fi
  fi
  if [ -n "$SUPPORT_CREATED" ] && [ -z "$SUPPORT_REMOVED" ]; then
    say ""
    say "cleanup: the run died before R5 — emergency support teardown of $SUPPORT_NAME"
    say "cleanup: server-side support remove is backlog (pdf-bl-support-remove-serverside);"
    say "cleanup: the box lives in the CP's provisioning project — remove it with the"
    say "cleanup: NAMED teardown credential:  bp cloud support remove $SUPPORT_NAME"
    if [ -n "$BP" ] && [ -x "$BP" ] && [ -n "$TEARDOWN_HC_TOKEN" ]; then
      # shellcheck disable=SC2015
      HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" BP_COLOR=none "$BP" ${JMAIN_URL:+-s "$JMAIN_URL"} ${JMAIN_TOKEN:+--token "$JMAIN_TOKEN"} cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" \
        && SUPPORT_REMOVED=1 \
        || say "cleanup: bp cloud support remove did not converge — remove $SUPPORT_NAME BY HAND (it is billing)"
      if [ -n "$SUPPORT_ID" ] && [ -n "$JTEAM_TOKEN" ]; then
        say "cleanup: deleting the CP support row (journey session)"
        local cpo; cpo="$WORKDIR/cleanup-cp-row.json"
        jcp_delete_code "/v1/fleet/supports/$SUPPORT_ID" "$cpo" >/dev/null 2>&1 || true
      fi
    else
      say "cleanup: NO named teardown credential in scope — support $SUPPORT_NAME may be BILLING; remove it by hand"
    fi
  fi
  if [ -n "$MAIN_CREATED" ] && [ -z "$MAIN_REMOVED" ] && [ -n "$MAIN_ID" ]; then
    say "cleanup: deprovisioning the R1 main $MAIN_NAME (DELETE /v1/barkparks/$MAIN_ID)"
    local out; out="$WORKDIR/cleanup-main-del.json"
    if [ -n "$JTEAM_TOKEN" ]; then
      jcp_delete_code "/v1/barkparks/$MAIN_ID" "$out" >/dev/null 2>&1 || true
    else
      cp_delete_code "/v1/barkparks/$MAIN_ID" "$out" >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}

MAIN_URL=""   # the R1 main's public URL (set at R1); the offload data plane host

# ═════════════════════════════════════════════════════════════════════════════
# --plan — every rung, its assert, the online/timeout law. Emitted BEFORE any
# substrate check; strictly side-effect-free (no mktemp, no network, no reads
# beyond this file).
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "plan" ]; then
  rule
  say "PDF MVP-0 JOURNEY PROOF — PLAN (no side effects: no mktemp, no network,"
  say "no config reads; this mode only prints)"
  rule
  say "tree:      $REPO_ROOT"
  say "main:      $MAIN_BASE (dataset $DATASET; admin bearer = config.json .token, read at run time, never printed)"
  say "cp:        $CP_BASE (bearer = config.json .cloud_token)"
  say "names:     main $MAIN_NAME · support $SUPPORT_NAME · phantom $PHANTOM_WORKER · order $ORDER_ID"
  say "           (every write mvp0proof- prefixed; every write cleaned by its own teardown)"
  say "cost:      ONE CP-provisioned MAIN + ONE CP-provisioned SUPPORT, minutes — authorized; both torn down"
  say "outcomes:  PASS / ABORT / FAIL — no silent skip. Exit 0/2/1 (+3 usage)."
  say ""
  say "THE ONLINE / TIMEOUT LAW (PDF-D89/D28 lineage, server-anchored):"
  say "  · the roster lives on the MAIN; beats go box→main directly (the CP is not in the data path)."
  say "  · a support's provision_support job VERIFY step polls the main's roster server-side until"
  say "    the row reads idle|working|blocked WITH a non-empty capacity map — else the job FAILS"
  say "    (terminal, honest; a stuck-provisioning support renders honestly and NEVER bills, PDF-D10)."
  say "  · online = status != offline, DERIVED (no literal 'online' string exists in the vocab)."
  say "  · negctl bracket (phantom row ttl_s=$TTL_S, skew ${SKEW}s):"
  say "      elapsed <  $ONLINE_EDGE       => row MUST read provisioning"
  say "      $ONLINE_EDGE <= elapsed < $OFFLINE_EDGE => margin band, UNASSERTED"
  say "      elapsed >= $OFFLINE_EDGE      => row MUST read offline, and STAY"
  say "      EVERY sample         => row NEVER reads idle/working/blocked (the core, skew-immune claim)"
  say ""
  say "RUNGS (run mode):"
  say "  0  PRECONDITION — ABORT-only, in order:"
  say "     · config.json carries .token + .cloud_token"
  say "     · CREDENTIAL-EMPTY LAW: HCLOUD_TOKEN must NOT be in this shell (its presence ABORTS —"
  say "       the journey is credential-empty; the CP is the hands)"
  say "     · PR #$PR_6038 MERGED (the CP-deploy filter fix so the provisioner redeploys on"
  say "       internal/+cmd/ changes) — via the public GitHub API"
  say "     · CP POST /v1/fleet/supports anon → 401 (404 ABORTS naming pdf-wc-cp-network-recreate, D67)"
  say "     · CP POST /v1/internal/support-jobs/claim anon → 401 (404 ABORTS — the provisioner never"
  say "       carried provision_support / the CP route is missing)"
  say "     · guerrilla POST /v1/fleet/support-tokens anon → 401 (mint route live)"
  say "     · guerrilla GET /v1/fleet/roster → 200 documents-envelope with the admin bearer"
  say "     · fresh bp builds from ./cmd/barkpark"
  say "     · MONEY-SAFETY GATE: the NAMED teardown credential (PDFJP_TEARDOWN_HCLOUD_TOKEN, else the"
  say "       hcloud '$TEARDOWN_HC_CTX' context) resolves AND provably addresses the CP's PROVISIONING"
  say "       project — a CP-managed host (label $MANAGED_LABEL) listed through it must match a"
  say "       CP-managed barkpark's host. NEVER create a box you cannot tear down (server-side"
  say "       support remove is backlog pdf-bl-support-remove-serverside). No proof → ABORT, no spend."
  say "  1  CREATE-MAIN — register the FRESH JOURNEY TEAM (POST /v1/auth/register — the brief's"
  say "     'fresh journey team with auto-trial'; the trial auto-starts at go-live, dwb-13), then"
  say "     POST /v1/launch {name:$MAIN_NAME} under THAT session → poll GET /v1/barkparks"
  say "     provision_steps until the row reads live (host set, health up). A CP MAIN is"
  say "     CP-DEPROVISIONABLE. The trial ceiling (1 main) then makes R2 prove PDF-D86 live"
  say "     (supports are quota-exempt)."
  say "  2  ADD-SUPPORT — POST /v1/fleet/supports {name:$SUPPORT_NAME, barkpark_id:<main>, mode:provision}"
  say "     → 202 {barkpark, job_id} → poll the SUPPORT row's provision_steps (create→configure→"
  say "     content→verify→ready). ASSERT: the support roster row reads provisioning BEFORE the first"
  say "     heartbeat; ONLINE only after the listener's own beat (idle|working|blocked WITH capacity)."
  say "  3  NEGCTL — publish the short-TTL phantom provisioning row; poll >= the offline edge: it"
  say "     ages to offline past its OWN ttl and reads online at NO sample; the R2 support stays online."
  say "  4  OFFLOAD — the NAMED KEY RUNG first (PDF-D88): pre-seed ANTHROPIC_API_KEY over SSH with the"
  say "     exact one-liner (key from env; NAMED exception, said plainly) or a NAMED SKIP. Then mint the"
  say "     member app token (POST /v1/barkparks/:id/app-token), file the order app-token-direct on the"
  say "     MAIN (POST {main}/v1/data/mutate/{dataset}), assert claim→working→done (keyed) or →claimed"
  say "     (keyless skip), with a MAIN-parity probe DURING execution."
  say "  5  TEARDOWN — bp cloud support remove (NAMED credential) + FOUR-surface census delta zero"
  say "     (token 403→401 probe, box label scan, roster row, CP row); then DELETE /v1/barkparks/:id"
  say "     for the R1 main. Census delta zero; the guerrilla parent + operator instances SURVIVE."
  say ""
  say "  --negctl (NO box, no spend): publish the phantom row, then BEAT it every ${NEG_BEAT_EVERY}s;"
  say "  the never-onlines assert must FIRE AS A FAILURE (the row DOES online) => NEGCTL OK, exit 0."
  say ""
  say "  --scan-transcript <file>: grep for the guerrilla admin bearer, the cloud_token, the named"
  say "  teardown token, and the Anthropic key prefix — ZERO hits or no commit."
  rule
  say "Run it:  $0            (the proof — LIVE, provisions + tears down a main + a support)"
  say "         $0 --negctl   (the control that must fire — free)"
  rule
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# --scan-transcript — the pre-commit token scan (local reads only, no network)
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "scan" ]; then
  [ -n "$TRANSCRIPT_TARGET" ] || die "--scan-transcript needs a file argument"
  [ -r "$TRANSCRIPT_TARGET" ] || die "cannot read $TRANSCRIPT_TARGET"
  command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"
  HITS=0
  scan_value() { # label value — grep -F the literal value; masked report
    local label="$1" v="$2" n
    [ -n "$v" ] && [ "${#v}" -ge 8 ] || return 0
    n="$(grep -cF -- "$v" "$TRANSCRIPT_TARGET" 2>/dev/null || true)"
    n="${n:-0}"
    if [ "$n" -gt 0 ]; then
      HITS=$((HITS + n))
      say "  HIT    $label (len ${#v}, ${v%"${v#????}"}…) appears $n time(s) — DO NOT COMMIT"
    else
      say "  clean  $label (len ${#v}) — 0 occurrences"
    fi
  }
  say "token-scan of $TRANSCRIPT_TARGET"
  scan_value "named teardown HCLOUD token (env)" "${PDFJP_TEARDOWN_HCLOUD_TOKEN:-}"
  scan_value "HCLOUD_TOKEN (env, should be empty here)" "${HCLOUD_TOKEN:-}"
  if [ -r "$CONFIG_JSON" ]; then
    scan_value "guerrilla admin bearer (config .token)" \
      "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token") or "")' "$CONFIG_JSON")"
    scan_value "cloud bearer (config .cloud_token)" \
      "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cloud_token") or "")' "$CONFIG_JSON")"
  fi
  HC_TOML="$HOME/.config/hcloud/cli.toml"
  if [ -r "$HC_TOML" ]; then
    while IFS= read -r tok; do
      scan_value "hcloud cli.toml context token" "$tok"
    done <<EOF
$(python3 -c '
import re, sys
try:
    text = open(sys.argv[1]).read()
except Exception:
    sys.exit(0)
for m in re.finditer(r"token\s*=\s*\"([^\"]+)\"", text):
    print(m.group(1))' "$HC_TOML")
EOF
  fi
  SKANT="$(grep -cE 'sk-ant' "$TRANSCRIPT_TARGET" 2>/dev/null || true)"; SKANT="${SKANT:-0}"
  if [ "$SKANT" -gt 0 ]; then
    HITS=$((HITS + SKANT))
    say "  HIT    sk-ant prefix appears $SKANT time(s) — DO NOT COMMIT"
  else
    say "  clean  sk-ant prefix — 0 occurrences"
  fi
  if [ "$HITS" -gt 0 ]; then
    say "TOKEN-SCAN: $HITS hit(s) — the transcript is NOT committable."
    exit 1
  fi
  say "TOKEN-SCAN: zero hits — the transcript is committable."
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# run / --negctl
# ═════════════════════════════════════════════════════════════════════════════

command -v curl    >/dev/null 2>&1 || die "curl not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

# The trap installs BEFORE any write — and in particular BEFORE the R1 launch /
# R2 create calls (D82(9)). Every later write flips its own flag for the trap.
trap cleanup EXIT

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pdfjp.XXXXXX")"

# The 3-line transcript header convention — self-carried so the tee'd transcript
# needs no hand-editing.
say "# pdf-mvp0-journey-proof — transcript"
say "# tree: $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)) · host: $(uname -s | tr '[:upper:]' '[:lower:]') · $(date -u +%Y-%m-%dT%H:%M:%SZ)"
CMD_SUFFIX=""; [ "$MODE" != "run" ] && CMD_SUFFIX=" --$MODE"
say "# command: scripts/pdf-mvp0-journey-proof.sh$CMD_SUFFIX"
say ""
rule
say "PDF MVP-0 JOURNEY PROOF — ${MODE} — run $RUN_ID"
rule
say "tree:        $REPO_ROOT"
say "worktree:    $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
say "main:        $MAIN_BASE (dataset $DATASET)"
say "cp:          $CP_BASE"
say "names:       main $MAIN_NAME · support $SUPPORT_NAME · phantom $PHANTOM_WORKER · order $ORDER_ID"
say "ttl bracket: ttl_s=$TTL_S · provisioning below $ONLINE_EDGE · offline from $OFFLINE_EDGE (skew ${SKEW}s) · support poll floor ${POLL_BUDGET}s"

# ── shared credential loads (local file reads; values never printed) ─────────

load_config_bearers() { # sets ADMIN_TOKEN/CLOUD_TOKEN; 1 + reason on miss.
  if [ ! -r "$CONFIG_JSON" ]; then CFG_REASON="no $CONFIG_JSON"; return 1; fi
  ADMIN_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token") or "")' "$CONFIG_JSON")"
  CLOUD_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cloud_token") or "")' "$CONFIG_JSON")"
  if [ -z "$ADMIN_TOKEN" ]; then CFG_REASON="config.json .token is empty"; return 1; fi
  if [ -z "$CLOUD_TOKEN" ]; then CFG_REASON="config.json .cloud_token is empty"; return 1; fi
  return 0
}
CFG_REASON=""

# ═════════════════════════════════════════════════════════════════════════════
# --negctl — no box, no spend: the never-onlines assert must FIRE
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "negctl" ]; then

  head_rung N0 "PRECONDITION — guerrilla serves the fleet routes (no CP, no Hetzner needed)"
  if ! load_config_bearers; then
    abort N0 "env:config-bearers" "$CFG_REASON — the negctl needs the guerrilla admin bearer (config.json .token)"
    exit 2
  fi
  ROSTER0="$(curl_roster || true)"
  if ! printf '%s' "$ROSTER0" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d.get("documents"),list) else 1)' 2>/dev/null; then
    info "roster body: $(printf '%s' "$ROSTER0" | head -c 200)"
    abort N0 "env:roster-unreachable" "GET $MAIN_BASE/v1/fleet/roster?dataset=$DATASET did not answer the documents envelope"
    exit 2
  fi
  pass N0 "guerrilla roster answers the documents envelope with the config bearer"

  head_rung N1 "PHANTOM ROW — publish provisioning, ttl_s=$TTL_S (the stepRosterRow shape)"
  PH_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  MUT_OUT="$WORKDIR/negctl-publish.json"
  PHANTOM_PUBLISHED=1
  CODE="$(mutate "$MAIN_BASE" "$ADMIN_TOKEN" "[{\"createOrReplace\":{\"_id\":\"$PHANTOM_ROW_ID\",\"_type\":\"listener\",\"_draft\":false,\"content\":{\"worker\":\"$PHANTOM_WORKER\",\"status\":\"provisioning\",\"last_seen\":\"$PH_STAMP\",\"ttl_s\":$TTL_S}}},{\"publish\":{\"id\":\"$PHANTOM_ROW_ID\",\"type\":\"listener\"}}]" "$MUT_OUT")"
  info "mutate createOrReplace+publish -> HTTP ${CODE:-000}"
  if [ "${CODE:-000}" -lt 200 ] || [ "${CODE:-000}" -ge 300 ]; then
    info "body: $(head -c 300 "$MUT_OUT" | tr -d '\n')"
    fail N1 "the phantom row publish did not land"
    exit 1
  fi
  ROW="$(curl_roster | row_of "$PHANTOM_WORKER")"
  say "      $PHANTOM_WORKER: ${ROW:-ABSENT}"
  [ -n "$ROW" ] || { fail N1 "the published phantom row is ABSENT from the roster"; exit 1; }
  pass N1 "phantom row published and returned by the roster (status $(printf '%s' "$ROW" | field_of status))"

  head_rung N2 "NEGCTL BRACKET — the harness BEATS the phantom; never-onlines must FIRE AS A FAILURE"
  info "beating $PHANTOM_WORKER every ${NEG_BEAT_EVERY}s (status idle, non-empty capacity) while polling —"
  info "if the never-onlines check cannot fail under that, it proves nothing (PDS-D20)."
  ANCHOR_EPOCH="$(iso_to_epoch "$PH_STAMP")"
  CEILING=$((TTL_S + 60))
  POLL=0; ONLINED=""; FIRST_ONLINE_ELAPSED=""; NEG_BEATS=0; NEG_BEAT_ERRS=0
  POLLS_PAST_EDGE=0; LAST_NEG_BEAT="0"
  while :; do
    TNOW="$(now_epoch)"
    ELAPSED="$(fsub "$TNOW" "$ANCHOR_EPOCH")"
    if fcmp "$(fsub "$TNOW" "$LAST_NEG_BEAT")" '>=' "$NEG_BEAT_EVERY"; then
      BEAT_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      NBOUT="$WORKDIR/negctl-beat.json"
      NBCODE="$(mutate "$MAIN_BASE" "$ADMIN_TOKEN" "[{\"createOrReplace\":{\"_id\":\"$PHANTOM_ROW_ID\",\"_type\":\"listener\",\"_draft\":false,\"content\":{\"worker\":\"$PHANTOM_WORKER\",\"status\":\"idle\",\"last_seen\":\"$BEAT_STAMP\",\"ttl_s\":$TTL_S,\"capacity\":{\"size_class\":\"light\",\"slots_total\":1,\"slots_free\":1}}}},{\"publish\":{\"id\":\"$PHANTOM_ROW_ID\",\"type\":\"listener\"}}]" "$NBOUT")"
      if [ "${NBCODE:-000}" -ge 200 ] && [ "${NBCODE:-000}" -lt 300 ]; then
        NEG_BEATS=$((NEG_BEATS + 1))
        say "      negctl beat #$NEG_BEATS at elapsed=${ELAPSED}s -> idle+capacity published (last_seen=$BEAT_STAMP)"
      else
        NEG_BEAT_ERRS=$((NEG_BEAT_ERRS + 1))
        say "      negctl beat FAILED at elapsed=${ELAPSED}s: HTTP ${NBCODE:-000} $(head -c 160 "$NBOUT" | tr -d '\n')"
      fi
      LAST_NEG_BEAT="$TNOW"
    fi
    POLL=$((POLL + 1))
    ROW="$(curl_roster | row_of "$PHANTOM_WORKER" || true)"
    S="$(printf '%s' "$ROW" | field_of status)"
    printf '  poll %2d  elapsed=%6ss  %s=%s\n' "$POLL" "$ELAPSED" "$PHANTOM_WORKER" "${S:-ABSENT}"
    if [ -n "$ROW" ] && printf '%s' "$ROW" | row_is_online; then
      [ -z "$ONLINED" ] && FIRST_ONLINE_ELAPSED="$ELAPSED"
      ONLINED=1
    fi
    fcmp "$ELAPSED" '>=' "$OFFLINE_EDGE" && POLLS_PAST_EDGE=$((POLLS_PAST_EDGE + 1))
    fcmp "$ELAPSED" '>=' "$CEILING" && break
    sleep 3
  done
  say ""
  info "negctl beats sent: $NEG_BEATS (errors: $NEG_BEAT_ERRS) · polls past the offline edge: $POLLS_PAST_EDGE"
  if [ "$NEG_BEATS" -lt 5 ] || [ "$NEG_BEAT_ERRS" -gt 0 ]; then
    fail N2 "the negctl cadence did not hold ($NEG_BEATS beats, $NEG_BEAT_ERRS errors) — the control is not a control"
    exit 1
  fi
  if [ "$POLLS_PAST_EDGE" -lt 2 ]; then
    fail N2 "only $POLLS_PAST_EDGE poll(s) landed past the offline edge — the bracket never really tested it"
    exit 1
  fi
  if [ -z "$ONLINED" ]; then
    fail N2 "NEGCTL BROKEN — a continuously-beaten row NEVER read online-with-capacity: the online detector is dead, and the main run's 'never onlines' would be vacuous"
    exit 1
  fi
  info "the never-onlines assert FIRED AS A FAILURE — the beaten row read online-with-capacity"
  info "from elapsed=${FIRST_ONLINE_ELAPSED}s. The check CAN fail, so the main run's green is not vacuous."
  pass N2 "NEGCTL OK — beats flip the row online (first at elapsed=${FIRST_ONLINE_ELAPSED}s); the withheld-row instrument demonstrably fires"

  head_rung N3 "TEARDOWN — delete the phantom row; roster re-read must be empty"
  delete_doc "$MAIN_BASE" "$ADMIN_TOKEN" "$PHANTOM_ROW_ID" "listener"
  PHANTOM_DELETED=1
  sleep 1
  ROW="$(curl_roster | row_of "$PHANTOM_WORKER" || true)"
  if [ -n "$ROW" ]; then
    fail N3 "the phantom row survived its delete: $ROW"
    exit 1
  fi
  pass N3 "phantom row deleted; roster no longer returns $PHANTOM_WORKER"

  say ""
  rule
  say "VERDICT — negctl: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
  say "NEGCTL OK — the online detector is a real instrument: kept beating, the row onlines;"
  say "withheld, the main run's never-onlines claim is therefore falsifiable."
  rule
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# THE LIVE RUN
# ═════════════════════════════════════════════════════════════════════════════

# ── RUNG 0 — PRECONDITION (ABORT-only) ────────────────────────────────────────

head_rung 0 "PRECONDITION — bearers, credential-empty law, PR #$PR_6038, CP+provisioner routes, teardown-capability (ABORT-only)"

# 0a. config bearers (local read)
if ! load_config_bearers; then
  abort 0 "env:config-bearers" "$CFG_REASON — bearers come from $CONFIG_JSON at run time (never hardcoded)"
  exit 2
fi
info "config bearers loaded (.token ${#ADMIN_TOKEN} bytes, .cloud_token ${#CLOUD_TOKEN} bytes — never printed)"

# 0b. CREDENTIAL-EMPTY LAW — the journey shell must NOT carry a fleet Hetzner
# token. Its presence means the driver could be doing the provisioning itself,
# which is exactly what the inversion (PDF-D83) removes; ABORT loudly.
if [ -n "${HCLOUD_TOKEN:-}" ]; then
  abort 0 "env:not-credential-empty" "HCLOUD_TOKEN is set in the journey shell — the MVP-0 journey is CREDENTIAL-EMPTY by law (the CP is the hands; PDF-D83). Unset it and re-run; the teardown credential is a SEPARATE named var (PDFJP_TEARDOWN_HCLOUD_TOKEN), never this."
  exit 2
fi
info "credential-empty law holds: no HCLOUD_TOKEN in the journey shell"

# 0c. PR #6038 merged (the CP-deploy filter fix — provisioner redeploys on
# internal/+cmd/ changes; without it the support chain never reaches prod).
PR_JSON="$(gh_get "pulls/$PR_6038" 2>/dev/null || true)"
PR_MERGED="$(printf '%s' "$PR_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("err"); sys.exit(0)
print("yes" if d.get("merged") is True or d.get("merged_at") else "no")' 2>/dev/null || echo err)"
PR_SHA="$(printf '%s' "$PR_JSON" | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("merge_commit_sha") or "")[:9])
except Exception:
    print("")' 2>/dev/null || echo "")"
info "GitHub PR #$PR_6038 merged: $PR_MERGED (merge sha ${PR_SHA:-?})"
if [ "$PR_MERGED" != "yes" ]; then
  abort 0 "env:pr-6038-not-merged" "PR #$PR_6038 (the CP-deploy filter fix) is not merged per the GitHub API — the provisioner binary carrying provision_support does not auto-redeploy until it lands (PDF-D90). Nothing created."
  exit 2
fi

# 0d. CP POST /v1/fleet/supports answers 401 anon; 404 = the recreate never ran.
CP_ANON="$(anon_post_code "$CP_BASE/v1/fleet/supports")"
info "anon POST /v1/fleet/supports (control plane) -> HTTP ${CP_ANON:-000}"
if [ "${CP_ANON:-000}" = "404" ]; then
  abort 0 "env:cp-fleet-supports-404" "the CP 404s /v1/fleet/supports — the one-time network recreate (pdf-wc-cp-network-recreate, PDF-D67) has not run; until it does R0 can only ABORT. Nothing created."
  exit 2
fi
if [ "${CP_ANON:-000}" != "401" ]; then
  abort 0 "env:cp-fleet-supports-shape" "the CP answered ${CP_ANON:-000} to an anonymous POST /v1/fleet/supports, want 401. Nothing created."
  exit 2
fi

# 0e. the provisioner queue answers auth-shaped (not 404) — proof the deployed CP
# carries the provision_support claim route (PDF-D83).
CLAIM_ANON="$(anon_post_code "$CP_BASE/v1/internal/support-jobs/claim")"
info "anon POST /v1/internal/support-jobs/claim (control plane) -> HTTP ${CLAIM_ANON:-000}"
if [ "${CLAIM_ANON:-000}" = "404" ]; then
  abort 0 "env:support-claim-404" "the CP 404s /v1/internal/support-jobs/claim — the deployed control plane never carried the provision_support claim route (PDF-D83). Nothing created."
  exit 2
fi
if [ "${CLAIM_ANON:-000}" != "401" ]; then
  abort 0 "env:support-claim-shape" "the support-jobs claim answered ${CLAIM_ANON:-000} to an anonymous POST, want 401 (worker-gated). Nothing created."
  exit 2
fi

# 0f. guerrilla mint route + roster (the R2 content-step mint + the roster reads).
MINT_ANON="$(anon_post_code "$MAIN_BASE/v1/fleet/support-tokens")"
info "anon POST /v1/fleet/support-tokens (guerrilla) -> HTTP ${MINT_ANON:-000}"
if [ "${MINT_ANON:-000}" != "401" ]; then
  abort 0 "env:mint-endpoint-shape" "the mint endpoint answered ${MINT_ANON:-000} to an anonymous POST, want 401 — a 404 means the token-exchange merge never deployed. Nothing created."
  exit 2
fi
ROSTER_TMP="$WORKDIR/roster-r0.json"
PRECODE="$(curl -sS -o "$ROSTER_TMP" -w '%{http_code}' --max-time 25 \
  -H "Authorization: Bearer $ADMIN_TOKEN" "$MAIN_BASE/v1/fleet/roster?dataset=$DATASET" 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
ENVELOPE_OK="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("no"); sys.exit(0)
print("yes" if isinstance(d.get("documents"), list) else "no")' "$ROSTER_TMP")"
info "GET /v1/fleet/roster?dataset=$DATASET -> HTTP ${PRECODE:-000}, documents-envelope: $ENVELOPE_OK"
if [ "${PRECODE:-000}" != "200" ] || [ "$ENVELOPE_OK" != "yes" ]; then
  info "body: $(head -c 300 "$ROSTER_TMP" | tr -d '\n')"
  abort 0 "env:roster-unreachable" "guerrilla did not serve the roster to the config bearer — wrong token or a stale deploy. Nothing created."
  exit 2
fi

# 0g. fresh bp from ./cmd/barkpark (teardown drives `bp cloud support remove`).
command -v go >/dev/null 2>&1 || { abort 0 "env:no-go" "go not on PATH — cannot build bp from ./cmd/barkpark (R5 teardown needs it)"; exit 2; }
BP="$WORKDIR/bp"
info "building bp: go build -o \$WORKDIR/bp ./cmd/barkpark …"
if ! (cd "$REPO_ROOT" && go build -o "$BP" ./cmd/barkpark) >"$WORKDIR/bp-build.log" 2>&1; then
  tail -20 "$WORKDIR/bp-build.log" | sed 's/^/      /'
  abort 0 "env:bp-build-failed" "go build ./cmd/barkpark failed — see above. Nothing created."
  exit 2
fi
info "bp built ($(wc -c < "$BP" | tr -d ' ') bytes)"

# 0h. MONEY-SAFETY GATE (the load-bearing R0 precondition of THIS proof) — a
# CP-provisioned support box lives in the CP's PROVISIONING Hetzner project.
# Server-side support remove is backlog (pdf-bl-support-remove-serverside), so
# the ONLY teardown is `bp cloud support remove`, which needs a provider
# credential ADDRESSING THAT PROJECT. Resolve the NAMED teardown credential and
# PROVE it reaches the CP's project — a CP-managed host (label barkpark-managed)
# listed through it MUST match a CP-managed barkpark's host. NEVER create a box
# you cannot tear down.
command -v hcloud >/dev/null 2>&1 || { abort 0 "env:no-hcloud" "hcloud CLI not on PATH — the teardown (bp cloud support remove) needs it; refusing to create a box that cannot be removed. Nothing created."; exit 2; }

# The set of CP-managed hosts the operator's control plane knows about — the
# ground truth the teardown credential's project must intersect.
CP_HOSTS="$(cp_get "/v1/barkparks?scope=all" | python3 -c '
import json, sys
try:
    rows = (json.load(sys.stdin) or {}).get("barkparks") or []
except Exception:
    rows = []
hosts = [ (r.get("host") or "").strip() for r in rows
          if r.get("mode") == "managed" and (r.get("host") or "").strip() ]
print("\n".join(sorted(set(hosts))))')"
CP_HOST_N="$(printf '%s' "$CP_HOSTS" | grep -c . 2>/dev/null || echo 0)"
info "control plane knows $CP_HOST_N managed host(s) (the teardown project must intersect these)"
if [ "$CP_HOST_N" -eq 0 ]; then
  abort 0 "env:no-cp-managed-host" "the control plane lists NO managed instance host to cross-check the teardown project against — cannot PROVE the teardown credential reaches the CP's provisioning project without risking a stranded box. Nothing created. (Provision a managed main first, or supply PDFJP_TEARDOWN_HCLOUD_TOKEN known-good for the CP project.)"
  exit 2
fi

# List the teardown-credential project's boxes and intersect with CP_HOSTS.
HC_SRC=""; TEARDOWN_PROJECT_OK=""
list_project_ips() { # runs hcloud under the named teardown credential
  if [ -n "$TEARDOWN_HC_TOKEN" ]; then
    HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" hcloud server list -o json 2>/dev/null
  else
    hcloud --context "$TEARDOWN_HC_CTX" server list -o json 2>/dev/null
  fi
}
if [ -n "$TEARDOWN_HC_TOKEN" ]; then
  HC_SRC="PDFJP_TEARDOWN_HCLOUD_TOKEN (env)"
else
  HC_SRC="hcloud '$TEARDOWN_HC_CTX' context"
fi
PROJ_JSON="$WORKDIR/teardown-project.json"
if ! list_project_ips >"$PROJ_JSON" 2>"$WORKDIR/teardown-project.err"; then
  head -3 "$WORKDIR/teardown-project.err" | sed 's/^/      /'
  abort 0 "env:teardown-credential-unusable" "the NAMED teardown credential ($HC_SRC) did not answer 'hcloud server list' — without a working fleet-project credential the support box could never be removed (server-side support remove is backlog). Set PDFJP_TEARDOWN_HCLOUD_TOKEN or an hcloud '$TEARDOWN_HC_CTX' context. Nothing created."
  exit 2
fi
PROJ_IPS="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1])) or []
except Exception:
    d = []
ips = []
for s in d:
    v4 = ((s.get("public_net") or {}).get("ipv4") or {}).get("ip") or s.get("ipv4") or ""
    if v4:
        ips.append(str(v4).strip())
print("\n".join(sorted(set(ips))))' "$PROJ_JSON")"
PROJ_N="$(printf '%s' "$PROJ_IPS" | grep -c . 2>/dev/null || echo 0)"
OVERLAP="$(python3 -c '
import sys
cp = set(l.strip() for l in sys.argv[1].splitlines() if l.strip())
pr = set(l.strip() for l in sys.argv[2].splitlines() if l.strip())
inter = sorted(cp & pr)
print(",".join(inter))' "$CP_HOSTS" "$PROJ_IPS")"
info "teardown project ($HC_SRC) lists $PROJ_N box(es); CP-managed ∩ teardown-project = ${OVERLAP:-<empty>}"
if [ -z "$OVERLAP" ]; then
  abort 0 "env:teardown-project-disjoint" \
    "the NAMED teardown credential ($HC_SRC) addresses a DIFFERENT Hetzner project than the CP provisions into: NOT ONE of the CP's $CP_HOST_N managed host(s) is visible through it. A CP-provisioned support box would land in the CP's project and be UNREACHABLE for teardown — and server-side support remove is backlog (pdf-bl-support-remove-serverside). REFUSING to create a box I cannot tear down. Nothing created. Remediation: supply PDFJP_TEARDOWN_HCLOUD_TOKEN for the CP's provisioning project, OR ship a CP-side support deprovision so the credential-empty journey can tear down its own support box."
  exit 2
fi
TEARDOWN_PROJECT_OK=1
info "teardown-capability PROVEN: the '$HC_SRC' credential reaches the CP's provisioning project (shared host $OVERLAP)"

pass 0 "bearers resolve; journey credential-empty (no HCLOUD_TOKEN); PR #$PR_6038 merged; CP + provisioner + guerrilla routes answer their contracted anon-401s; roster serves the documents envelope; bp fresh; and the NAMED teardown credential provably reaches the CP's provisioning project"

# ── RUNG 1 — CREATE-MAIN (CP HTTP only) ──────────────────────────────────────

head_rung 1 "CREATE-MAIN — POST /v1/launch → the /new journey's calls → the main reads live"

# 1a. THE FRESH JOURNEY TEAM (the brief's R0 pin): the stranger registers and
# every journey leg below rides THAT session, never the operator's. The trial
# auto-starts at go-live (dwb-13); its ceiling (1 main) is exactly what makes
# add-support's quota exemption (PDF-D86) load-bearing — this run proves it.
REG_EMAIL="bolla+$MAIN_NAME@jarl.no"
REG_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
REG_OUT="$WORKDIR/register.json"
say "  1a \$ POST $CP_BASE/v1/auth/register {email:$REG_EMAIL, team_name:$MAIN_NAME} (password random, never printed)"
RCODE="$(curl -sS --max-time 30 -o "$REG_OUT" -w '%{http_code}' -X POST "$CP_BASE/v1/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$REG_EMAIL\",\"password\":\"$REG_PASS\",\"team_name\":\"$MAIN_NAME\"}" 2>/dev/null | tr -dc '0-9' | tail -c 3)"
JTEAM_TOKEN="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("token") or "")
except Exception:
    print("")' "$REG_OUT")"
JTEAM_ID="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("team_id") or "")
except Exception:
    print("")' "$REG_OUT")"
info "register -> HTTP ${RCODE:-000}; journey team ${JTEAM_ID:-?} (session ${#JTEAM_TOKEN} bytes — never printed)"
if [ "${RCODE:-000}" != "201" ] || [ -z "$JTEAM_TOKEN" ]; then
  info "body: $(head -c 200 "$REG_OUT" | tr -d '\n')"
  abort 1 "env:register-failed" "the fresh journey team could not be registered (HTTP ${RCODE:-000}) — the stranger journey cannot start. Nothing billable created."
  exit 2
fi

LAUNCH_OUT="$WORKDIR/launch.json"
MAIN_CREATED=1   # BEFORE the call — a half-dead launch must still be reaped
# Template is REQUIRED for the journey: a template-less main has no
# bootstrap_workspace, and the provision_support claim payload carries the
# parent's bootstrap_workspace as the dataset-leg workspace — nil there fails
# validateSupportSpec before anything is written (an honest job failure, but
# not the journey under test).
TEMPLATE="${PDFJP_TEMPLATE:-astro-search-starter}"
say "  1b \$ POST $CP_BASE/v1/launch {name:$MAIN_NAME, template:$TEMPLATE}   (journey session; trial auto-starts, dwb-13)"
LCODE="$(jcp_post_code "/v1/launch" "{\"name\":\"$MAIN_NAME\",\"template\":\"$TEMPLATE\"}" "$LAUNCH_OUT")"
say "      receipt (HTTP ${LCODE:-000}):"
sed 's/^/      | /' "$LAUNCH_OUT"
case "${LCODE:-000}" in
  200|201|202) : ;;
  402) abort 1 "env:no-entitlement" "launch answered 402 no_active_subscription — the operator's CP team has no live entitlement/trial to launch a main. This is a substrate/account state, not a proof verdict. Nothing billable created."; exit 2 ;;
  403) abort 1 "env:launch-forbidden-or-quota" "launch answered 403 — either the caller is not team-admin or the plan's managed-instance ceiling is reached (limit_reached). A substrate/account state. Nothing billable created."; exit 2 ;;
  *)   fail 1 "POST /v1/launch answered ${LCODE:-000} — see the receipt above"; exit 1 ;;
esac
MAIN_ID="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
bp = d.get("barkpark") or d
print(bp.get("id") or "")' "$LAUNCH_OUT")"
if [ -z "$MAIN_ID" ]; then
  fail 1 "the launch receipt carried no barkpark id — cannot poll the main to live"
  exit 1
fi
info "main registered: id=$MAIN_ID (label $MANAGED_LABEL; CP-deprovisionable via DELETE /v1/barkparks/:id)"

# Poll GET /v1/barkparks for THIS main until it reads live (host set + health up).
DEADLINE_EPOCH="$(python3 -c "import time; print(int(time.time()) + $POLL_BUDGET)")"
MAIN_LIVE=""
while :; do
  ROW="$(jcp_get "/v1/barkparks?scope=all" | MID="$MAIN_ID" python3 -c '
import json, sys, os
mid = os.environ["MID"]
try:
    rows = (json.load(sys.stdin) or {}).get("barkparks") or []
except Exception:
    rows = []
for r in rows:
    if r.get("id") == mid:
        print(json.dumps({"host": r.get("host"), "health": r.get("health_status"),
                          "url": r.get("url"), "steps": r.get("provision_steps")}))
        break' 2>/dev/null || true)"
  HOST="$(printf '%s' "$ROW" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("host") or "")' 2>/dev/null || true)"
  HEALTH="$(printf '%s' "$ROW" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("health") or "")' 2>/dev/null || true)"
  STEPS="$(printf '%s' "$ROW" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); s=d.get("steps"); print(",".join("%s:%s"%(x.get("step"),x.get("status")) for x in s) if isinstance(s,list) else "")' 2>/dev/null || true)"
  printf '  main %-12s host=%-16s health=%-6s steps=%s\n' "$MAIN_NAME" "${HOST:-—}" "${HEALTH:-—}" "${STEPS:-—}"
  if [ -n "$HOST" ] && [ "$HEALTH" = "up" ]; then
    MAIN_URL="$(printf '%s' "$ROW" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("url") or "")' 2>/dev/null || true)"
    MAIN_LIVE=1
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; then
    fail 1 "the main did not reach live (host set + health up) within ${POLL_BUDGET}s — last host=${HOST:-none} health=${HEALTH:-none}"
    exit 1
  fi
  sleep 10
done
say "      LIVE MAIN: id=$MAIN_ID url=$MAIN_URL host=$HOST health=$HEALTH"

# The journey main's OWN admin token — the /new journey's credentials surface
# (GET /v1/barkparks/:id/credentials, team-admin-gated). All journey-side roster
# reads + the phantom row + the teardown legs run against THE JOURNEY MAIN with
# this bearer (the support's roster row lives THERE, never on guerrilla).
CRED_OUT="$WORKDIR/credentials.json"
CCODE="$(curl -sS --max-time 25 -o "$CRED_OUT" -w '%{http_code}' \
  -H "Authorization: Bearer $JTEAM_TOKEN" "$CP_BASE/v1/barkparks/$MAIN_ID/credentials" 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
JMAIN_TOKEN="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("admin_token") or "")
except Exception:
    print("")' "$CRED_OUT")"
JMAIN_URL="$(printf '%s' "$MAIN_URL" | sed 's:/*$::')"
case "$JMAIN_URL" in http*) : ;; *) JMAIN_URL="https://$JMAIN_URL" ;; esac
info "GET /v1/barkparks/:id/credentials -> HTTP ${CCODE:-000} (admin_token ${#JMAIN_TOKEN} bytes — never printed); journey main = $JMAIN_URL"
if [ "${CCODE:-000}" != "200" ] || [ -z "$JMAIN_TOKEN" ]; then
  fail 1 "the credentials surface did not reveal the journey main's admin token — the journey-side roster reads and teardown legs cannot run"
  exit 1
fi
JR_PROBE="$(jroster | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print("yes" if isinstance(d.get("documents"),list) else "no")
except Exception: print("no")' 2>/dev/null || echo no)"
info "journey-main roster GET -> documents-envelope: $JR_PROBE"
[ "$JR_PROBE" = "yes" ] || { fail 1 "the journey main does not serve /v1/fleet/roster to its own admin token — the instance build lacks the fleet routes"; exit 1; }
rung_seal 1 "create-main via CP HTTP only: $MAIN_NAME launched (template $TEMPLATE) → polled provision_steps → live (host set, health up) at $MAIN_URL; credentials surface revealed the instance admin token; the journey main serves its roster"

# ── RUNG 2 — ADD-SUPPORT (CP-provisioned; provisioning-before-beat) ──────────

head_rung 2 "ADD-SUPPORT — POST /v1/fleet/supports mode=provision → the support onlines only after its own beat (PDF-D89)"

ADD_OUT="$WORKDIR/add-support.json"
SUPPORT_CREATED=1   # BEFORE the call — a half-dead add must still be reaped
say "  \$ POST $CP_BASE/v1/fleet/supports {name:$SUPPORT_NAME, barkpark_id:$MAIN_ID, mode:provision}"
ACODE="$(jcp_post_code "/v1/fleet/supports" "{\"name\":\"$SUPPORT_NAME\",\"barkpark_id\":\"$MAIN_ID\",\"mode\":\"provision\"}" "$ADD_OUT")"
say "      receipt (HTTP ${ACODE:-000}):"
sed 's/^/      | /' "$ADD_OUT"
case "${ACODE:-000}" in
  202) : ;;
  409) abort 2 "env:no-admin-token-or-inflight" "add-support answered 409 — the parent main has no admin token yet (the claim payload's credential spine, PDF-D93) or a provision is already in flight. A substrate state. Nothing new billable."; exit 2 ;;
  *)   fail 2 "POST /v1/fleet/supports mode=provision answered ${ACODE:-000}, want 202 — see the receipt"; exit 1 ;;
esac
SUPPORT_ID="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
bp = d.get("barkpark") or {}
print(bp.get("id") or "")' "$ADD_OUT")"
JOB_ID="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("job_id") or "")
except Exception:
    print("")' "$ADD_OUT")"
info "support registered host-nil: id=${SUPPORT_ID:-?} job_id=${JOB_ID:-?} (the provision_support job the Go provisioner drains)"

# Poll the SUPPORT row's provision_steps AND the main roster. The core PDF-D89
# assert: the support roster row reads provisioning BEFORE the first heartbeat
# and reads ONLINE (idle|working|blocked WITH capacity) ONLY AFTER a real beat.
DEADLINE_EPOCH="$(python3 -c "import time; print(int(time.time()) + $POLL_BUDGET)")"
SAW_PROVISIONING_BEFORE_BEAT=""; SAW_ONLINE=""; ONLINE_ROW=""
while :; do
  SNAP="$WORKDIR/support-row.json"
  jcp_get "/v1/barkparks?scope=all" >"$SNAP" 2>/dev/null || true
  STEPS="$(SID="$SUPPORT_ID" python3 -c '
import json, sys, os
sid = os.environ["SID"]
try:
    rows = (json.load(open(sys.argv[1])) or {}).get("barkparks") or []
except Exception:
    rows = []
for r in rows:
    if r.get("id") == sid:
        s = r.get("provision_steps")
        print(",".join("%s:%s"%(x.get("step"),x.get("status")) for x in s) if isinstance(s,list) else "")
        break' "$SNAP" 2>/dev/null || true)"
  PSTATUS="$(SID="$SUPPORT_ID" python3 -c '
import json, sys, os
sid = os.environ["SID"]
try:
    rows = (json.load(open(sys.argv[1])) or {}).get("barkparks") or []
except Exception:
    rows = []
for r in rows:
    if r.get("id") == sid:
        print(r.get("provision_status") or "")
        break' "$SNAP" 2>/dev/null || true)"
  SROW="$(jroster | row_of "$SUPPORT_NAME" || true)"
  SSTATUS="$(printf '%s' "$SROW" | field_of status)"
  printf '  support steps=[%s]  roster=%s\n' "${STEPS:-—}" "${SSTATUS:-ABSENT}"
  # FAIL FAST on a failed chain — never burn the budget waiting on a job that
  # already reported terminal. Quote the job's own error + console (the honest
  # substrate evidence; the worker tears its half-built box down itself).
  if [ "$PSTATUS" = "failed" ] || printf '%s' "$STEPS" | grep -q ':failed'; then
    say "      SUPPORT JOB FAILED (provision_status=$PSTATUS; steps=[$STEPS]) — quoting the job's own evidence:"
    SID="$SUPPORT_ID" python3 -c '
import json, sys, os
sid = os.environ["SID"]
try:
    rows = (json.load(open(sys.argv[1])) or {}).get("barkparks") or []
except Exception:
    rows = []
for r in rows:
    if r.get("id") == sid:
        err = r.get("provision_error")
        if err:
            print("      provision_error: %s" % str(err)[:600])
        con = r.get("provision_console")
        if isinstance(con, list):
            # The WHOLE console (bounded): the evidence-carrying import step
            # echoes bp output + a journal tail — truncating to a short tail
            # cost round 6 its root cause. Cap generously, never at 14.
            for line in con[-220:]:
                if isinstance(line, dict):
                    line = line.get("line") or line.get("text") or json.dumps(line)
                print("      | %s" % str(line)[:400])
        break' "$SNAP" 2>/dev/null || true
    say "      the worker tears its half-built box down on chain failure (SupportProvisionWith.failStep);"
    say "      the provisioning roster row ages to offline honestly (PDF-D10)"
    fail 2 "the provision_support chain reported a FAILED step (steps=[$STEPS]) — a genuine substrate failure, quoted above"
    exit 1
  fi
  # The row exists and reads provisioning (or is still absent) BEFORE any beat.
  if [ -z "$SAW_ONLINE" ]; then
    if [ "$SSTATUS" = "provisioning" ]; then SAW_PROVISIONING_BEFORE_BEAT=1; fi
    # NEVER online-before-beat: an online read while we have not yet seen a beat
    # is only legitimate once capacity is present (that IS the beat).
    if [ -n "$SROW" ] && printf '%s' "$SROW" | row_is_online; then
      SAW_ONLINE=1; ONLINE_ROW="$SROW"
    fi
  fi
  [ -n "$SAW_ONLINE" ] && break
  if [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; then
    say "      last support roster row: ${SROW:-ABSENT}"
    fail 2 "the support never reached online-with-capacity on the main roster within ${POLL_BUDGET}s (the verify step should have driven it, PDF-D89) — last status=${SSTATUS:-absent}"
    exit 1
  fi
  sleep 8
done
say "      LIVE SUPPORT ROSTER ROW (quoted — the R2 evidence): $SUPPORT_NAME: $ONLINE_ROW"
[ -n "$SAW_PROVISIONING_BEFORE_BEAT" ] || efail "never observed the support row reading 'provisioning' before it onlined — the provisioning-before-beat ordering (PDF-D89) is unproven"
printf '%s' "$ONLINE_ROW" | row_is_online || efail "the support row is not online-with-capacity: $ONLINE_ROW"
rung_seal 2 "add-support CP-side: $SUPPORT_NAME provisioned entirely server-side; roster read provisioning before the first heartbeat and ONLINE (idle|working|blocked WITH capacity) only after the listener's own beat"

# ── RUNG 3 — NEGCTL stuck-provisioning ───────────────────────────────────────

head_rung 3 "NEGCTL — stuck-provisioning phantom (ttl_s=$TTL_S) never onlines; the R2 support stays online"

PH_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MUT_OUT="$WORKDIR/phantom-publish.json"
PHANTOM_PUBLISHED=1
CODE="$(mutate "$JMAIN_URL" "$JMAIN_TOKEN" "[{\"createOrReplace\":{\"_id\":\"$PHANTOM_ROW_ID\",\"_type\":\"listener\",\"_draft\":false,\"content\":{\"worker\":\"$PHANTOM_WORKER\",\"status\":\"provisioning\",\"last_seen\":\"$PH_STAMP\",\"ttl_s\":$TTL_S}}},{\"publish\":{\"id\":\"$PHANTOM_ROW_ID\",\"type\":\"listener\"}}]" "$MUT_OUT")"
info "phantom publish on the JOURNEY main (createOrReplace+publish, the stepRosterRow shape) -> HTTP ${CODE:-000}, ttl_s=$TTL_S (NEVER the production 1800)"
if [ "${CODE:-000}" -lt 200 ] || [ "${CODE:-000}" -ge 300 ]; then
  info "body: $(head -c 300 "$MUT_OUT" | tr -d '\n')"
  fail 3 "the phantom row publish did not land"
  exit 1
fi
ANCHOR_EPOCH="$(iso_to_epoch "$PH_STAMP")"
CEILING="$OFFLINE_EDGE"
fcmp "$((TTL_S + 60))" '>' "$CEILING" && CEILING=$((TTL_S + 60))
info "T_anchor = $PH_STAMP · bracket: provisioning below ${ONLINE_EDGE}s · offline from ${OFFLINE_EDGE}s · ceiling ${CEILING}s"

POLL=0; PH_WENT_OFFLINE=""; FIRST_OFFLINE_ELAPSED=""; POLLS_PAST_EDGE=0
while :; do
  TNOW="$(now_epoch)"
  ELAPSED="$(fsub "$TNOW" "$ANCHOR_EPOCH")"
  POLL=$((POLL + 1))
  ROSTER="$(jroster || true)"
  PROW="$(printf '%s' "$ROSTER" | row_of "$PHANTOM_WORKER")"
  SROW="$(printf '%s' "$ROSTER" | row_of "$SUPPORT_NAME")"
  PS="$(printf '%s' "$PROW" | field_of status)"
  SS="$(printf '%s' "$SROW" | field_of status)"
  printf '  poll %2d  elapsed=%6ss  phantom=%-12s support=%-8s\n' "$POLL" "$ELAPSED" "${PS:-ABSENT}" "${SS:-ABSENT}"

  # THE CORE, SKEW-IMMUNE CLAIM: the withheld row NEVER reads online.
  if [ "$PS" = "idle" ] || [ "$PS" = "working" ] || [ "$PS" = "blocked" ]; then
    efail "the phantom row reads '$PS' at elapsed=${ELAPSED}s — a withheld listener's row must NEVER online"
  fi
  if [ -z "$PROW" ]; then
    efail "the phantom row is ABSENT from the roster — it must return it (as offline once stale), never drop it"
  else
    if [ "$PS" = "offline" ]; then
      [ -z "$PH_WENT_OFFLINE" ] && FIRST_OFFLINE_ELAPSED="$ELAPSED"
      PH_WENT_OFFLINE=1
      if fcmp "$ELAPSED" '<' "$ONLINE_EDGE"; then
        efail "the phantom reads offline at elapsed=${ELAPSED}s — BEFORE its own ttl_s=$TTL_S (minus the ${SKEW}s skew margin)"
      fi
    else
      if fcmp "$ELAPSED" '>=' "$OFFLINE_EDGE"; then
        efail "the phantom reads '${PS:-ABSENT}' at elapsed=${ELAPSED}s — past its OWN offline boundary ($OFFLINE_EDGE)"
      fi
      if [ -n "$PH_WENT_OFFLINE" ]; then
        efail "the phantom FLAPPED back to '${PS:-?}' after reading offline at ${FIRST_OFFLINE_ELAPSED}s — offline must STICK"
      fi
    fi
    fcmp "$ELAPSED" '>=' "$OFFLINE_EDGE" && POLLS_PAST_EDGE=$((POLLS_PAST_EDGE + 1))
  fi

  # The concurrency co-assert: the R2 support is ONLINE at every sample.
  if [ -z "$SROW" ] || ! printf '%s' "$SROW" | row_is_online; then
    efail "the R2 support $SUPPORT_NAME does not read online-with-capacity at elapsed=${ELAPSED}s (status '${SS:-ABSENT}') — the concurrent-online co-assert broke"
  fi

  fcmp "$ELAPSED" '>=' "$CEILING" && break
  sleep 8
done

[ "$POLLS_PAST_EDGE" -lt 2 ] && efail "only $POLLS_PAST_EDGE poll(s) landed past the offline boundary — the bracket never really tested it"
[ -z "$PH_WENT_OFFLINE" ] && efail "the phantom never read offline by the ${CEILING}s ceiling — it must age to offline past its OWN ttl"

# In-rung teardown.
delete_doc "$JMAIN_URL" "$JMAIN_TOKEN" "$PHANTOM_ROW_ID" "listener"
PHANTOM_DELETED=1
sleep 1
PROW="$(jroster | row_of "$PHANTOM_WORKER" || true)"
[ -z "$PROW" ] || efail "the phantom row survived its delete: $PROW"
info "a withheld listener's row never onlines — provisioning while fresh, offline from"
info "elapsed=${FIRST_OFFLINE_ELAPSED:-?}s (its OWN ttl_s=$TTL_S), never idle/working/blocked; the R2 support stayed online throughout."
rung_seal 3 "stuck-provisioning phantom: provisioning fresh → offline past its OWN ttl (first at ${FIRST_OFFLINE_ELAPSED:-?}s), online at NO sample across ${CEILING}s; R2 support concurrently online at all $POLL polls; row torn down"

# ── RUNG 4 — OFFLOAD (the named key rung first; app-token-direct) ────────────

head_rung 4 "OFFLOAD — the NAMED key rung (PDF-D88), then an app-token-direct order claim→working→done"

# The box IP for the key-seed leg + the parity target.
SUP_IP="$(jcp_get "/v1/barkparks?scope=all" | SID="$SUPPORT_ID" python3 -c '
import json, sys, os
sid = os.environ["SID"]
try:
    rows = (json.load(sys.stdin) or {}).get("barkparks") or []
except Exception:
    rows = []
for r in rows:
    if r.get("id") == sid:
        print(r.get("host") or "")
        break' 2>/dev/null || true)"
info "support box host: ${SUP_IP:-unknown}"

# 4a. THE NAMED KEY RUNG (PDF-D88) — OUTSIDE the credential-empty envelope BY
# DESIGN. The provider key is the developer's OWN; the provisioner never writes
# it. Seed it over SSH with the EXACT one-liner. Key from the harness env; if
# absent (or SSH unavailable) → a NAMED SKIP, said plainly, and the order below
# can only reach 'claimed' (a keyless box can never EXECUTE an LLM turn).
KEY_SEEDED=""
say "  4a NAMED KEY RUNG (PDF-D88) — the model key is the developer's own; this leg is OUTSIDE the credential-empty envelope BY DESIGN."
if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -n "$SUP_IP" ] && [ -f "$SSH_KEY" ]; then
  say "      \$ ssh root@$SUP_IP \"printf 'ANTHROPIC_API_KEY=<your-key>\\n' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener\"   (key elided)"
  if ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20 -i "$SSH_KEY" "root@$SUP_IP" \
       "printf 'ANTHROPIC_API_KEY=%s\n' '$ANTHROPIC_API_KEY' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener" >/dev/null 2>&1; then
    KEY_SEEDED=1
    info "model key seeded on the box (never echoed); the listener restarted — the box can now EXECUTE orders"
  else
    info "key-seed SSH failed (box unreachable / key missing) — the order leg degrades to file-and-watch-to-claimed"
  fi
else
  say ""
  say "      SKIP (NAMED): the key rung — ANTHROPIC_API_KEY is not present in the harness env at run"
  say "      time (or no SSH key / box IP). Per PDF-D88 this is the honest contingency: a keyless box"
  say "      can never execute (every order is an LLM turn), so the order leg below files the order and"
  say "      watches it to 'claimed' only, NEVER asserting a fabricated 'done'."
fi

# 4b. mint the member app token (POST /v1/barkparks/:id/app-token) — the browser's
# exact call; the offload data plane is app-token-direct (PDF-D87).
APP_OUT="$WORKDIR/app-token.json"
say "  4b \$ POST $CP_BASE/v1/barkparks/$MAIN_ID/app-token   (mint the member token; talk straight to the main)"
APCODE="$(jcp_post_code "/v1/barkparks/$MAIN_ID/app-token" "{}" "$APP_OUT")"
APP_TOKEN="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("token") or "")
except Exception:
    print("")' "$APP_OUT")"
info "app-token mint -> HTTP ${APCODE:-000} (token ${#APP_TOKEN} bytes — never printed)"
if [ "${APCODE:-000}" != "200" ] || [ -z "$APP_TOKEN" ]; then
  info "body: $(head -c 200 "$APP_OUT" | tr -d '\n')"
  fail 4 "app-token mint did not return a member token — the app-token-direct data plane (PDF-D87) is unavailable"
  exit 1
fi

# 4c. file the order app-token-direct on the MAIN (createOrReplace OPEN → publish).
ORDER_TITLE="mvp0proof-$TS offload order"
ORDER_DESC="MVP-0 journey offload probe (PDF-D87): an app-token-direct order routed to support $SUPPORT_NAME; filed and watched by scripts/pdf-mvp0-journey-proof.sh and deleted by the same run. Reply with exactly: pong"
MUT_OUT="$WORKDIR/order-publish.json"
ORDER_FILED=1
ORDER_JSON="$(python3 - "$ORDER_ID" "$ORDER_TITLE" "$SUPPORT_NAME" "$ORDER_DESC" <<'PY'
import json, sys
i, t, w, d = sys.argv[1:5]
doc = {"_id": i, "_type": "task", "kind": "task", "lifecycle_status": "open",
       "title": t, "description": d, "assignee": w, "priority": 2}
print(json.dumps([{"createOrReplace": doc}, {"publish": {"id": i, "type": "task"}}]))
PY
)"
CODE="$(mutate "$MAIN_URL" "$APP_TOKEN" "$ORDER_JSON" "$MUT_OUT")"
info "order publish app-token-direct on the MAIN ($MAIN_URL) -> HTTP ${CODE:-000}"
if [ "${CODE:-000}" = "422" ] && grep -qiE 'label_spine|unknown_tag' "$MUT_OUT"; then
  info "the fresh main's publish wall wants a seeded tag — seeding the 'order' tag and retrying (PDF-D42 precedent)"
  SEED_OUT="$WORKDIR/order-tagseed.json"
  mutate "$MAIN_URL" "$APP_TOKEN" '[{"createOrReplace":{"_id":"order","_type":"tag","title":"order"}},{"publish":{"id":"order","type":"tag"}}]' "$SEED_OUT" >/dev/null 2>&1 || true
  ORDER_JSON="$(python3 - "$ORDER_ID" "$ORDER_TITLE" "$SUPPORT_NAME" "$ORDER_DESC" <<'PY'
import json, sys
i, t, w, d = sys.argv[1:5]
doc = {"_id": i, "_type": "task", "kind": "task", "lifecycle_status": "open",
       "title": t, "description": d, "assignee": w, "priority": 2,
       "tags": [{"tag": "order", "strength": 80,
                "rationale": "fleet order routed to the support listener by the MVP-0 journey proof"}]}
print(json.dumps([{"createOrReplace": doc}, {"publish": {"id": i, "type": "task"}}]))
PY
)"
  CODE="$(mutate "$MAIN_URL" "$APP_TOKEN" "$ORDER_JSON" "$MUT_OUT")"
  info "order re-publish (tagged) -> HTTP ${CODE:-000}"
fi
if [ "${CODE:-000}" -lt 200 ] || [ "${CODE:-000}" -ge 300 ]; then
  info "body: $(head -c 400 "$MUT_OUT" | tr -d '\n')"
  fail 4 "the order publish did not land app-token-direct — see the body"
  exit 1
fi
say "      ORDER FILED app-token-direct: $ORDER_ID (assignee $SUPPORT_NAME) — the fleet-listener claims by matching its worker name"

# 4d. watch filed → claimed → working → done off the task + roster, with a
# MAIN-parity probe each poll.
if [ -n "$KEY_SEEDED" ]; then
  WATCH_TARGET="done"; WATCH_BUDGET="$POLL_BUDGET"
else
  WATCH_TARGET="claimed"; WATCH_BUDGET=120
fi
info "watch target: $WATCH_TARGET (budget ${WATCH_BUDGET}s) — the NAMED KEY RUNG governs whether execution can complete"
DEADLINE_EPOCH="$(python3 -c "import time; print(int(time.time()) + $WATCH_BUDGET)")"
STAGE=""; PARITY_OK=1; PARITY_N=0
while :; do
  TASK_JSON="$(curl -sS --max-time 20 -H "Authorization: Bearer $APP_TOKEN" "$MAIN_URL/v1/tasks/$ORDER_ID" 2>/dev/null || true)"
  LC="$(printf '%s' "$TASK_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
doc = d.get("doc") or d
c = doc.get("content") or {}
print(doc.get("lifecycle_status") or c.get("lifecycle_status") or "")' 2>/dev/null || true)"
  SROW="$(jroster | row_of "$SUPPORT_NAME" || true)"
  SS="$(printf '%s' "$SROW" | field_of status)"
  # MAIN-parity probe DURING execution: the JOURNEY main answers its roster read
  # fresh while the support works — offloading must not degrade the main.
  PARITY_N=$((PARITY_N + 1))
  PCODE="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $JMAIN_TOKEN" "$JMAIN_URL/v1/fleet/roster?dataset=$DATASET" 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
  [ "${PCODE:-000}" = "200" ] || PARITY_OK=""
  # Derive the stage: task lifecycle is authoritative; roster adds live 'working'.
  case "$LC" in
    done)      STAGE="done" ;;
    cancelled) STAGE="failed" ;;
    blocked)   STAGE="blocked" ;;
    in_progress) if [ "$SS" = "working" ]; then STAGE="working"; else STAGE="claimed"; fi ;;
    *)         STAGE="filed" ;;
  esac
  printf '  watch  task=%-12s support=%-8s stage=%-8s main-parity=%s\n' "${LC:-—}" "${SS:-—}" "$STAGE" "${PCODE:-000}"
  if [ "$STAGE" = "done" ]; then break; fi
  if [ "$STAGE" = "failed" ] || [ "$STAGE" = "blocked" ]; then
    efail "the order reached a terminal '$STAGE' — the offload did not complete cleanly"
    break
  fi
  if [ "$WATCH_TARGET" = "claimed" ] && { [ "$STAGE" = "claimed" ] || [ "$STAGE" = "working" ]; }; then break; fi
  if [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; then
    if [ "$WATCH_TARGET" = "done" ]; then
      efail "the order did not reach 'done' within ${WATCH_BUDGET}s (last stage $STAGE) — a keyed box should have executed it"
    else
      efail "the order did not even reach 'claimed' within ${WATCH_BUDGET}s (last stage $STAGE) — the listener did not pick it up"
    fi
    break
  fi
  sleep 6
done
[ -n "$PARITY_OK" ] || efail "the MAIN-parity probe went non-200 during execution ($PARITY_N samples) — the main was not responsive throughout the offload"
info "the key rung is NAMED in this transcript (${KEY_SEEDED:+seeded}${KEY_SEEDED:-a NAMED SKIP}); the main answered its roster read at all $PARITY_N parity samples during execution"

# In-rung teardown of the order.
delete_doc "$MAIN_URL" "$APP_TOKEN" "$ORDER_ID" "task"
ORDER_DELETED=1
rung_seal 4 "offload app-token-direct: member token minted, order filed on the MAIN, watched to '$STAGE' (target $WATCH_TARGET; key rung ${KEY_SEEDED:+seeded — full claim→working→done}${KEY_SEEDED:-a NAMED SKIP — file→claimed}); MAIN-parity green across $PARITY_N samples"

# ── RUNG 5 — TEARDOWN → FOUR-SURFACE CENSUS DELTA ZERO ───────────────────────

head_rung 5 "TEARDOWN — bp cloud support remove (NAMED credential) → four-surface census delta zero + main deprovision"

# BEFORE the remove: arm the REAL 403→401 revocation probe. The CP-provisioned
# chain never reports the support's minted token id back to the CP row
# (fleet_token_id stays nil — a custody gap, filed as its own defect), so the
# remove's own token leg can only say "no token id on record". The harness
# therefore proves the D57 revocation MECHANISM live with a stand-in: mint a
# support token on the JOURNEY main, hold its raw value in-process (never
# printed), probe the admin-gated mint endpoint with it (want 403:
# authenticated-but-not-admin), revoke it by id, re-probe (want 401). The
# support's OWN ledger token dies with the main's deprovision below (the
# instance IS its token store) — said plainly, never upgraded to "revoked".
PROBE_NAME="mvp0proof-probe-$TS"
PROBE_OUT="$WORKDIR/probe-mint.json"
PMCODE="$(main_post_code "$JMAIN_URL/v1/fleet/support-tokens" "{\"name\":\"$PROBE_NAME\"}" "$PROBE_OUT" "$JMAIN_TOKEN")"
PROBE_SECRET="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("token") or "")
except Exception:
    print("")' "$PROBE_OUT")"
PROBE_ID="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("token_id") or "")
except Exception:
    print("")' "$PROBE_OUT")"
PROBE_BEFORE=""
if [ -n "$PROBE_SECRET" ]; then
  PROBE_BEFORE="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST "$JMAIN_URL/v1/fleet/support-tokens" \
    -H "Authorization: Bearer $PROBE_SECRET" -H 'Content-Type: application/json' -d '{"name":""}' 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
  info "probe token minted on the journey main (HTTP ${PMCODE:-000}; ${#PROBE_SECRET} bytes, never printed); pre-revoke probe on the admin-gated mint endpoint -> HTTP ${PROBE_BEFORE:-000} (want 403)"
else
  info "probe-token mint answered ${PMCODE:-000} without a token — the 403→401 leg will degrade to the remove receipt, narrated"
fi

RM_OUT="$WORKDIR/remove-stdout.json"
RM_ERR="$WORKDIR/remove-progress.log"
say "  \$ HCLOUD_TOKEN=<named teardown credential> bp -s $JMAIN_URL --token <journey admin> cloud support remove $SUPPORT_NAME --dataset $DATASET -o json"
say "      (server-side support remove is backlog pdf-bl-support-remove-serverside; the box lives in"
say "       the CP's provisioning project, so the box delete needs the NAMED fleet credential — a"
say "       DELIBERATE, narrated exception to the credential-empty envelope. -s/--token point the"
say "       roster/token legs at the JOURNEY main, whose roster the support actually lives on.)"
RM_RC=0
if [ -n "$TEARDOWN_HC_TOKEN" ]; then
  HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" BP_COLOR=none "$BP" -s "$JMAIN_URL" --token "$JMAIN_TOKEN" cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" -o json \
    >"$RM_OUT" 2>"$RM_ERR" || RM_RC=$?
else
  HCLOUD_CONTEXT="$TEARDOWN_HC_CTX" BP_COLOR=none "$BP" -s "$JMAIN_URL" --token "$JMAIN_TOKEN" cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" -o json \
    >"$RM_OUT" 2>"$RM_ERR" || RM_RC=$?
fi
sed 's/^/      | /' "$RM_ERR"
say "      receipt:"
sed 's/^/      | /' "$RM_OUT"
if [ "$RM_RC" -ne 0 ]; then
  fail 5 "bp cloud support remove exited $RM_RC — residue named above; the trap will re-attempt under the named credential"
  exit 1
fi
SUPPORT_REMOVED=1

say "      FOUR-SURFACE CENSUS (this harness's own re-reads — delete receipts prove nothing):"

# 1. TOKEN — the REAL 403→401 revocation probe (PDF-D57/D63), on the stand-in
#    minted above: revoke it by id on the JOURNEY main, then the SAME bearer
#    that read 403 (authenticated-but-not-admin) must read 401. Narrated
#    honestly: the SUPPORT's own ledger token id was never on the CP row
#    (custody gap, filed) — it dies with the main's deprovision below.
if [ -n "$PROBE_SECRET" ] && [ -n "$PROBE_ID" ]; then
  RVOUT="$WORKDIR/probe-revoke.json"
  RVCODE="$(curl -sS --max-time 20 -o "$RVOUT" -w '%{http_code}' -X DELETE "$JMAIN_URL/v1/fleet/support-tokens/$PROBE_ID" \
    -H "Authorization: Bearer $JMAIN_TOKEN" 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
  PROBE_AFTER="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST "$JMAIN_URL/v1/fleet/support-tokens" \
    -H "Authorization: Bearer $PROBE_SECRET" -H 'Content-Type: application/json' -d '{"name":""}' 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
  info "1. token probe (admin-gated mint endpoint, journey main): ${PROBE_BEFORE:-?} before revoke, DELETE -> ${RVCODE:-000}, ${PROBE_AFTER:-000} after — want 403 → 401"
  [ "${PROBE_BEFORE:-000}" = "403" ] || efail "the pre-revoke probe read ${PROBE_BEFORE:-000}, want 403 — the revocation probe proved nothing"
  [ "${PROBE_AFTER:-000}" = "401" ] || efail "the probe token still authenticates after revoke: ${PROBE_AFTER:-000}, want 401"
  info "   the support's OWN ledger token id was never recorded on the CP row (fleet_token_id nil — custody"
  info "   gap, filed as a defect); it dies with the journey main's deprovision below — said plainly, not upgraded"
else
  info "1. token probe: DEGRADED — no stand-in token was minted; the remove receipt is the only token evidence"
  efail "the 403→401 token probe could not be armed (mint answered ${PMCODE:-000})"
fi

# 2. BOX — the provider label scan through the NAMED teardown credential.
if [ -n "$TEARDOWN_HC_TOKEN" ]; then
  SRV_AFTER="$(HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" hcloud server list -l "$FLEET_LABEL=$SUPPORT_NAME" -o json 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin) or []
except Exception: d=[]
print(",".join(s.get("name") or "" for s in d))')"
else
  SRV_AFTER="$(hcloud --context "$TEARDOWN_HC_CTX" server list -l "$FLEET_LABEL=$SUPPORT_NAME" -o json 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin) or []
except Exception: d=[]
print(",".join(s.get("name") or "" for s in d))')"
fi
info "2. hcloud label scan $FLEET_LABEL=$SUPPORT_NAME: ${SRV_AFTER:-empty}"
[ -z "$SRV_AFTER" ] || efail "box(es) still carry the label: $SRV_AFTER (BILLING)"

# 3. ROSTER — the stepOnline read (on the JOURNEY main) must return no support row.
SROW="$(jroster | row_of "$SUPPORT_NAME" || true)"
info "3. roster row for $SUPPORT_NAME: ${SROW:-none}"
[ -z "$SROW" ] || efail "roster row still present: $SROW"

# 4. CP SUPPORT ROW — deleted LAST among the support surfaces (PDF-D68), under
#    the JOURNEY session: `bp cloud support remove`'s CP legs ride the bp-login
#    (operator) session, which cannot see the journey team's row — so the row
#    delete + re-read run here with the journey bearer.
if [ -n "$SUPPORT_ID" ]; then
  CPDEL_OUT="$WORKDIR/cp-row-delete.json"
  CPDCODE="$(jcp_delete_code "/v1/fleet/supports/$SUPPORT_ID" "$CPDEL_OUT")"
  info "DELETE /v1/fleet/supports/$SUPPORT_ID (journey session) -> HTTP ${CPDCODE:-000}: $(head -c 120 "$CPDEL_OUT" | tr -d '\n')"
fi
CP_AFTER="$(jcp_get "/v1/barkparks?scope=all" | python3 -c '
import json, sys
try:
    rows = (json.load(sys.stdin) or {}).get("barkparks") or []
except Exception:
    rows = []
sup = [r.get("name") or "" for r in rows if r.get("fleet_role") == "support" and (r.get("name") or "").startswith("mvp0proof-")]
print(",".join(sup) if sup else "none")')"
info "4. CP support rows (fleet_role=support) with mvp0proof- names: $CP_AFTER"
[ "$CP_AFTER" = "none" ] || efail "CP support row residue: $CP_AFTER"

# Now deprovision the R1 main (CP-deprovisionable — the credential-empty half).
say "      \$ DELETE $CP_BASE/v1/barkparks/$MAIN_ID   (deprovision the R1 main — CP-side, credential-empty)"
MDEL_OUT="$WORKDIR/main-delete.json"
MDCODE="$(jcp_delete_code "/v1/barkparks/$MAIN_ID" "$MDEL_OUT")"
info "main deprovision -> HTTP ${MDCODE:-000}: $(head -c 160 "$MDEL_OUT" | tr -d '\n')"
case "${MDCODE:-000}" in
  200|202) MAIN_REMOVED=1 ;;
  *) efail "the main deprovision answered ${MDCODE:-000}, want 200/202 — the R1 main may still be billing (the trap re-attempts)" ;;
esac

rung_seal 5 "remove → census delta zero on all four surfaces (token 403→401, provider label scan, roster row, CP row); the R1 main deprovisioned; the guerrilla parent + operator instances survive"

# ── verdict ──────────────────────────────────────────────────────────────────

say ""
rule
say "VERDICT — $MODE: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
say "The MVP-0 stranger journey, driven ONLY through CP + main HTTP, client credential-empty:"
say "create-main → add-support (provisioned entirely server-side; provisioning-before-beat,"
say "online only after the listener's own beat) → a withheld row never onlines while the support"
say "stays online → offload app-token-direct (the model key a NAMED step) → teardown with census"
say "delta zero across four surfaces."
say ""
say "BEFORE COMMITTING THE TRANSCRIPT:"
say "  $0 --scan-transcript <transcript-file>"
say "must print ZERO hits — the guerrilla admin bearer, the cloud_token, the named teardown token"
say "and any sk-ant prefix. Zero hits or no commit."
rule
exit 0

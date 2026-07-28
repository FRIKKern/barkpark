#!/usr/bin/env bash
#
# pdf-p1-refire.sh — THE MONEY-SAFE LIVE-FIRE INSTRUMENT (Claude-ready servers
# wave 1, charter PDF-D94..D106; wave paper claude-ready-servers-wave-2026-07-28).
# ONE Guerrilla-parented provision_support fired at the control plane, watched to
# a terminal state, the CP row's fleet_token_id + provision_steps READ (never
# inferred), then torn down in PDF-D68 order with a FIVE-surface census
# (PDF-D101). This is the P1 birth + P3 death instrument: it exists to learn
# whether c65f517e2's reset+re-mint bracket repaired the chain — a RED run is a
# FIRST-CLASS RECORDED FINDING, never an abort-and-forget.
#
# WHY NOT THE JOURNEY-PROOF HARNESS (PDF-D98): pdf-mvp0-journey-proof.sh's R1
# always registers a fresh CP team and launches a fresh astro-search-starter
# main (no PDFJP_MAIN_ID reuse knob exists). A template-launched main pins the
# provision claim's workspace to the TEMPLATE slug, and both chains gate the
# c65f517e2 bracket on exactly workspace == "default" — so the harness would
# skip the fix under test AND pay for a second main. Guerrilla is template-less
# (GET /v1/barkparks/<parent>/bootstrap → 404 no_bootstrap, which
# Registry.reveal_bootstrap emits ONLY when bootstrap_workspace AND the read
# token are both nil), so a Guerrilla-parented claim pins workspace "default"
# via the 928e37a38 fallback (router.ex:9471) and the bracket RUNS.
#
#   scripts/pdf-p1-refire.sh --plan      print every rung, the credential laws,
#                                        the teardown order and the census. NO
#                                        side effects — the plan block exits
#                                        BEFORE the trap install and mktemp, so
#                                        it is side-effect-free BY CONSTRUCTION.
#   scripts/pdf-p1-refire.sh             THE FIRE (LIVE): one CP-provisioned
#                                        support box under the Guerrilla parent
#                                        (real money, minutes, torn down).
#   scripts/pdf-p1-refire.sh --scan-transcript <file>
#                                        token-scan a transcript before commit:
#                                        the guerrilla admin bearer, the
#                                        cloud_token, any hcloud token, any
#                                        sk-ant prefix — ZERO hits or no commit.
#   scripts/pdf-p1-refire.sh --help
#
# THE THREE OUTCOMES (the pds-pull-proof ladder — no fourth, no silent skip):
#   PASS   the rung ran and every assertion held.
#   ABORT  the rung cannot run (substrate/credential/entitlement — never a
#          verdict on the thing under test). R0 is ABORT-only by construction.
#   FAIL   the rung ran and an assertion did NOT hold.
# Exit: 0 = the instrument completed and every census leg held (whatever the
# P1 COLOR — green, lawful red, red — the color is the FINDING, not the exit).
# 1 = FAIL (an instrument assertion broke — e.g. census residue, watch budget
# exhausted). 2 = ABORT. 3 = usage error.
#
# THE P1 COLOR (recorded, first-class — printed in the verdict):
#   GREEN       provision_status "succeeded" — the c65f517e2 bracket ran and
#               the chain converged. The first green refire post-c65f517e2.
#   LAWFUL RED  the chain failed AND the evidence carries
#               workspace_slug_conflict — the PDS-D9 fail-closed refuse
#               (bp-pds-charter.md:86): the box's seeded "default" workspace
#               was not provably empty (0 documents, 0 media_files). A correct
#               refusal, DISTINCT from a broken chain — it must NOT be misread
#               as "c65f517e2 did not take" (PDF-D99).
#   RED         the chain failed for any other reason — a real defect finding,
#               quoted from the job's own provision_error + console.
#
# RUNGS:
#   0  PRECONDITION — ABORT-only: config bearers; the CREDENTIAL-EMPTY LAW
#      (HCLOUD_TOKEN must NOT be in this shell — see below); CP route answers
#      its contracted anon-401; the MONEY-SAFETY GATE (the NAMED teardown
#      credential provably addresses the CP's provisioning project); the
#      TEMPLATE-LESS-PARENT GATE (GET /v1/barkparks/<parent>/bootstrap must
#      answer 404 no_bootstrap — NEVER read from the /v1/barkparks listing,
#      which does not serialise bootstrap_workspace at all: a missing key
#      there is an ABSENT KEY and a false proof); and the parent credentials
#      surface answers 200 (else the enqueue 409s no_admin_token).
#   1  THE FIRE (P1 birth) — exactly ONE POST /v1/fleet/supports
#      {name, barkpark_id:<guerrilla>, mode:"provision"}, bearer = config.json
#      .cloud_token (proven sufficient: a bogus-parent probe returned 404
#      not_found, NOT 403). Success is 202 {barkpark, job_id}; the job_id is
#      sealed into the transcript. NOTE the blast radius: the CP registers the
#      host-nil support row BEFORE enqueueing (do_fleet_provision_support/3),
#      so a RED leaves a live CP row REGARDLESS; a failure at/past the content
#      mint leaks a live parent-side ledger token AND a published roster row;
#      and the chain's own DNS teardown is FAIL-OPEN (a stderr warning only,
#      internal/provisioner/support.go:527-540). Assume nothing cleans itself.
#   2  WATCH — poll the CP row's provision_steps to a TERMINAL state
#      (succeeded / failed / budget). A RED terminal is RECORDED and CLASSIFIED
#      (lawful PDS-D9 refuse vs broken chain) and the run CONTINUES — the D102
#      read and the teardown still fire. Budget exhaustion is an instrument
#      FAIL, but teardown still runs (money before verdicts).
#   3  THE D102 READ — after terminal, re-READ the CP row and print its
#      fleet_token_id and provision_steps VERBATIM. fleet_token_id is the
#      discriminator for task-b9c0f988cd0019d4 (PDF-D102: the silent-nil seam —
#      support.go:622 makes an empty token fatal but never checks the empty
#      token ID at :630, and three downstream layers tolerate the nil). It must
#      be READ from the row, never inferred from the job's exit.
#   4  TEARDOWN (P3 death) — PDF-D68 order IS LAW: the CP row was READ FIRST
#      (rung 3); the ledger token is revoked FIRST among deletes (DELETE
#      /v1/fleet/support-tokens/:id on the parent main — idempotent, so bp's
#      own token leg tolerates it); then `bp cloud support remove` (freshly
#      built — itself under test this wave) runs the box/roster/DNS legs; then
#      the RAW LABEL REAPER (list-then-delete on barkpark-fleet-support=<name>;
#      `hcloud server delete` has NO --selector) as the last resort; the CP row
#      is deleted LAST (sole durable token-id holder — deleting it earlier
#      bakes an unrecoverable orphan-token window).
#   5  FIVE-SURFACE CENSUS (PDF-D101) — re-reads, never receipts: (1) TOKEN
#      (the revoke receipt + idempotent re-probe; honestly narrated when
#      fleet_token_id was nil — you cannot revoke what the ledger never
#      recorded), (2) BOX (provider label scan through the teardown
#      credential), (3) ROSTER row on the guerrilla main, (4) CP row, (5) DNS
#      swept BY VALUE against the box IP (never by name — muscle-1 and
#      muscle-1-506f035e both point at one IP, PDF-D101). Every leg reports
#      honestly, including "skipped, and why".
#
# TWO TEARDOWN CREDENTIALS, NOT ONE (PDF-D101/D97): boxes live under the FLEET
# hcloud project (context 'barkpark'), but the barkpark.cloud DNS zone lives
# under the GUERRILLA project (context 'main') — the fleet token returns
# "zones": []. The DNS census leg rides BARKPARK_DNS_HCLOUD_TOKEN (matching
# instDNSClient's precedence), else the guerrilla hcloud context.
#
# CREDENTIAL-EMPTY LAW (inherited from the journey proof, and SAID LOUDLY
# because this epic habitually exports HCLOUD_TOKEN per PDF-D75): the fire is
# driven with HTTP bearers only. HCLOUD_TOKEN in this shell ABORTS R0 — the
# teardown credential is the SEPARATE named var PDFP1_TEARDOWN_HCLOUD_TOKEN
# (or the hcloud context), NEVER the ambient HCLOUD_TOKEN.
#
# GATE: bash -n scripts/pdf-p1-refire.sh &&
#       bash scripts/pdf-p1-refire.sh --plan
#
# Environment (all optional; --plan prints the defaults):
#   PDFP1_CP_BASE                  default https://api.barkpark.cloud
#   PDFP1_MAIN_BASE                default https://guerrilla.barkpark.cloud
#                                  (the Guerrilla parent main — roster reads +
#                                  the token-revoke leg; admin bearer =
#                                  config.json .token)
#   PDFP1_PARENT_ID                default b2b81e69-c79c-4eff-b6d7-84507d15b925
#                                  (team Guerrilla's barkpark — template-less,
#                                  PDF-D98)
#   PDFP1_DATASET                  default production
#   PDFP1_TEARDOWN_HCLOUD_TOKEN    the NAMED fleet-project teardown token (else
#                                  the hcloud context below). Teardown works on
#                                  EITHER path.
#   PDFP1_TEARDOWN_HCLOUD_CONTEXT  default 'barkpark' — the hcloud context
#                                  addressing the CP's provisioning project.
#   BARKPARK_DNS_HCLOUD_TOKEN      the guerrilla-project token for the DNS
#                                  census leg (the fleet token sees ZERO zones).
#   PDFP1_DNS_HCLOUD_CONTEXT       default 'main' — the guerrilla hcloud
#                                  context, used when the token var is absent.
#   PDFP1_DNS_ZONE                 default barkpark.cloud
#   PDFP1_POLL_BUDGET              watch ceiling, s (default 1800 — the chain's
#                                  own bound is 30 min)
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail
# set -m FIRST (PDF-D28): job control gives any backgrounded helper its OWN
# process group — the skeleton is transcribed from the donor proofs verbatim.
set -m

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

# ── fixtures (charter PDF-D94..D106 — transcribed, not explored) ──────────────

CP_BASE="${PDFP1_CP_BASE:-https://api.barkpark.cloud}"
MAIN_BASE="${PDFP1_MAIN_BASE:-https://guerrilla.barkpark.cloud}"
PARENT_ID="${PDFP1_PARENT_ID:-b2b81e69-c79c-4eff-b6d7-84507d15b925}"
DATASET="${PDFP1_DATASET:-production}"
CONFIG_JSON="$HOME/.config/barkpark/config.json"

TEARDOWN_HC_TOKEN="${PDFP1_TEARDOWN_HCLOUD_TOKEN:-}"
TEARDOWN_HC_CTX="${PDFP1_TEARDOWN_HCLOUD_CONTEXT:-barkpark}"
DNS_HC_TOKEN="${BARKPARK_DNS_HCLOUD_TOKEN:-}"
DNS_HC_CTX="${PDFP1_DNS_HCLOUD_CONTEXT:-main}"
DNS_ZONE="${PDFP1_DNS_ZONE:-barkpark.cloud}"
FLEET_LABEL="barkpark-fleet-support"
MANAGED_LABEL="barkpark-managed"

TS="$(date -u +%y%m%d%H%M%S)"
SUPPORT_NAME="p1refire-$TS"                     # DNS-label; ≤63 by construction
POLL_BUDGET="${PDFP1_POLL_BUDGET:-1800}"

MODE="run"
TRANSCRIPT_TARGET=""
case "${1:-}" in
  "")                MODE="run" ;;
  --plan)            MODE="plan" ;;
  --scan-transcript) MODE="scan"; TRANSCRIPT_TARGET="${2:-}" ;;
  -h|--help)         sed -n '3,160p' "$0"; exit 0 ;;
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
rung_seal() { # n summary — FAIL if any efail fired (NO exit — money before
              # verdicts: teardown always runs), else PASS; reset the counter.
  if [ "$R_FAILS" -gt 0 ]; then
    fail "$1" "$2 — $R_FAILS assertion(s) failed (see the ASSERT-FAIL lines above)"
  else
    pass "$1" "$2"
  fi
  R_FAILS=0
}

# ── bearer-curl helpers (the donor dialect; tokens never printed) ────────────

ADMIN_TOKEN=""; CLOUD_TOKEN=""

cp_get() { # path -> body (cloud bearer)
  curl -sS --max-time 25 -H "Authorization: Bearer $CLOUD_TOKEN" "$CP_BASE$1"
}

cp_get_code() { # path outfile -> http code (cloud bearer)
  curl -sS --max-time 25 -o "$2" -w '%{http_code}' \
    -H "Authorization: Bearer $CLOUD_TOKEN" "$CP_BASE$1" 2>/dev/null | tr -dc '0-9' | tail -c 3
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

main_delete_code() { # path outfile -> http code (guerrilla admin bearer)
  curl -sS --max-time 25 -o "$2" -w '%{http_code}' -X DELETE "$MAIN_BASE$1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null | tr -dc '0-9' | tail -c 3
}

anon_post_code() { # url -> http code, anonymous POST {} (probe: writes nothing)
  curl -sS --max-time 25 -o /dev/null -w '%{http_code}' -X POST "$1" \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null | tr -dc '0-9' | tail -c 3
}

curl_roster() { # the guerrilla main's roster (admin bearer)
  curl -sS --max-time 25 -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$MAIN_BASE/v1/fleet/roster?dataset=$DATASET"
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

# The CP support row by id — the D102/D68 read surface. GET /v1/barkparks
# serialises fleet_token_id (router.ex barkpark_json — deliberately NOT a
# secret: it is the opaque revocation id) plus provision_steps/status/error/
# console (merge_provision_steps / merge_provision_console).
cp_row_json() { # barkpark-id -> that row as one-line JSON, or ""
  cp_get "/v1/barkparks?scope=all" | BID="$1" python3 -c '
import json, os, sys
bid = os.environ["BID"]
try:
    rows = (json.load(sys.stdin) or {}).get("barkparks") or []
except Exception:
    rows = []
for r in rows:
    if r.get("id") == bid:
        print(json.dumps(r, sort_keys=True))
        break
'
}

row_field() { # key; row JSON on stdin -> value ("" for null/absent)
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

row_steps_brief() { # row JSON on stdin -> "step:status,step:status,…"
  python3 -c '
import json, sys
line = sys.stdin.read().strip()
if not line:
    sys.exit(0)
s = json.loads(line).get("provision_steps")
if isinstance(s, list):
    print(",".join("%s:%s" % (x.get("step"), x.get("status")) for x in s))'
}

# ── the teardown credential seam: EITHER path (PDF-D75/D101 lesson) ──────────
#
# The named token wins; else the hcloud context. NEVER the ambient HCLOUD_TOKEN
# (rung 0 aborts if it is set at all).

hc_teardown() { # hcloud … under the NAMED teardown credential (token OR context)
  if [ -n "$TEARDOWN_HC_TOKEN" ]; then
    HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" hcloud "$@"
  else
    hcloud --context "$TEARDOWN_HC_CTX" "$@"
  fi
}

hc_dns() { # hcloud … under the DNS (guerrilla-project) credential
  if [ -n "$DNS_HC_TOKEN" ]; then
    HCLOUD_TOKEN="$DNS_HC_TOKEN" hcloud "$@"
  else
    hcloud --context "$DNS_HC_CTX" "$@"
  fi
}

teardown_cred_name() {
  if [ -n "$TEARDOWN_HC_TOKEN" ]; then
    printf 'PDFP1_TEARDOWN_HCLOUD_TOKEN (env)'
  else
    printf "hcloud '%s' context" "$TEARDOWN_HC_CTX"
  fi
}

# PDF-D75 raw last resort, regained: list-then-delete by the fleet label.
# `hcloud server delete` has NO --selector, so scan first, then delete each id.
# `bp cloud support remove` is itself under test this wave — the reaper must
# not depend on it.
reap_box_by_label() { # -> 0 always; sets BOX_REAPED=<n> when boxes were deleted
  BOX_REAPED=0
  if ! command -v hcloud >/dev/null 2>&1; then
    say "      raw reaper: hcloud not on PATH — CANNOT scan $FLEET_LABEL=$SUPPORT_NAME; a surviving box is BILLING, delete it by hand"
    return 0
  fi
  local ids id
  ids="$(hc_teardown server list -l "$FLEET_LABEL=$SUPPORT_NAME" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin) or []
except Exception:
    d = []
print("\n".join(str(s.get("id")) for s in d if s.get("id")))' || true)"
  if [ -z "$ids" ]; then
    say "      raw reaper: label scan $FLEET_LABEL=$SUPPORT_NAME through $(teardown_cred_name) → no boxes (nothing to reap)"
    return 0
  fi
  for id in $ids; do
    if hc_teardown server delete "$id" >/dev/null 2>&1; then
      say "      raw reaper: hcloud server delete $id (label $FLEET_LABEL=$SUPPORT_NAME) — DELETED"
      BOX_REAPED=$((BOX_REAPED + 1))
    else
      say "      raw reaper: hcloud server delete $id FAILED — the box is BILLING; delete it by hand"
    fi
  done
  return 0
}

# ── trap state + cleanup: the always-runs backstop ───────────────────────────
#
# do_fleet_provision_support/3 registers the host-nil CP row BEFORE enqueueing,
# so ANY post-fire death leaves at least a CP row; a death at/past the content
# mint also leaves a live parent-side ledger token + a roster row + a billing
# box. The trap covers all of it, in PDF-D68 order, on EITHER credential path.

SUPPORT_FIRED=""; SUPPORT_ID=""; JOB_ID=""; BOX_IP=""
FLEET_TOKEN_ID=""; TOKEN_REVOKED=""; BOX_GONE=""; CP_ROW_GONE=""
TEARDOWN_RAN=""
WORKDIR=""
BP=""

emergency_teardown() { # PDF-D68 order: token first among deletes, CP row LAST
  # (the CP row was read at the D102 rung; in an early death, re-read it here
  # so the token id is not lost with the row.)
  if [ -n "$SUPPORT_ID" ] && [ -z "$FLEET_TOKEN_ID" ]; then
    FLEET_TOKEN_ID="$(cp_row_json "$SUPPORT_ID" 2>/dev/null | row_field fleet_token_id || true)"
  fi
  if [ -n "$FLEET_TOKEN_ID" ] && [ -z "$TOKEN_REVOKED" ]; then
    say "cleanup: revoking ledger token $FLEET_TOKEN_ID on the parent main (FIRST among deletes, PDF-D68)"
    local tko; tko="${TMPDIR:-/tmp}/pdfp1-token-del.$$"
    main_delete_code "/v1/fleet/support-tokens/$FLEET_TOKEN_ID" "$tko" >/dev/null 2>&1 || true
    rm -f "$tko"
    TOKEN_REVOKED=1
  elif [ -z "$FLEET_TOKEN_ID" ]; then
    say "cleanup: no fleet_token_id on the CP row — cannot revoke what the ledger never recorded"
    say "cleanup: (if the chain reached its mint, a live token is ORPHANED on the parent main — the D102 wound, task-b9c0f988cd0019d4)"
  fi
  if [ -z "$BOX_GONE" ]; then
    if [ -n "$BP" ] && [ -x "$BP" ]; then
      say "cleanup: bp cloud support remove $SUPPORT_NAME (box/roster/DNS legs; teardown credential = $(teardown_cred_name))"
      if [ -n "$TEARDOWN_HC_TOKEN" ]; then
        HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" BP_COLOR=none "$BP" cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" \
          && BOX_GONE=1 \
          || say "cleanup: bp cloud support remove did not converge — falling through to the raw reaper"
      else
        HCLOUD_CONTEXT="$TEARDOWN_HC_CTX" BP_COLOR=none "$BP" cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" \
          && BOX_GONE=1 \
          || say "cleanup: bp cloud support remove did not converge — falling through to the raw reaper"
      fi
    else
      say "cleanup: bp is not built in this run — going straight to the raw label reaper"
    fi
    if [ -z "$BOX_GONE" ]; then
      reap_box_by_label
      [ "${BOX_REAPED:-0}" -gt 0 ] && BOX_GONE=1
    fi
  fi
  if [ -n "$SUPPORT_ID" ] && [ -z "$CP_ROW_GONE" ]; then
    say "cleanup: DELETE /v1/fleet/supports/$SUPPORT_ID (CP row LAST, PDF-D68)"
    local cpo; cpo="${TMPDIR:-/tmp}/pdfp1-cp-del.$$"
    cp_delete_code "/v1/fleet/supports/$SUPPORT_ID" "$cpo" >/dev/null 2>&1 || true
    rm -f "$cpo"
    CP_ROW_GONE=1
  fi
  return 0
}

# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
  set +e
  if [ -n "$SUPPORT_FIRED" ] && [ -z "$TEARDOWN_RAN" ]; then
    say ""
    say "cleanup: the run died before the P3 teardown rung — emergency teardown of $SUPPORT_NAME"
    emergency_teardown
  fi
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# --plan — the whole instrument, printed. Emitted BEFORE the trap install and
# BEFORE mktemp — strictly side-effect-free BY CONSTRUCTION (no temp dir, no
# network, no config reads; this block only prints and exits).
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "plan" ]; then
  rule
  say "PDF P1 REFIRE — PLAN (no side effects: no trap, no mktemp, no network,"
  say "no config reads; this mode only prints)"
  rule
  say "tree:      $REPO_ROOT"
  say "cp:        $CP_BASE (fire bearer = config.json .cloud_token, read at run time, never printed)"
  say "parent:    $PARENT_ID (team Guerrilla — TEMPLATE-LESS, PDF-D98: the claim pins workspace"
  say "           'default' via the 928e37a38 fallback, so the c65f517e2 bracket RUNS)"
  say "main:      $MAIN_BASE (dataset $DATASET; roster + token-revoke legs; admin bearer = config.json .token)"
  say "name:      $SUPPORT_NAME (one box; every write torn down by rung 4 + the trap)"
  say "cost:      ONE CP-provisioned SUPPORT box, minutes — authorized; torn down in-run"
  say "outcomes:  PASS / ABORT / FAIL — no silent skip. Exit 0/2/1 (+3 usage)."
  say ""
  say "THE P1 COLOR (the finding, recorded first-class — distinct from the exit code):"
  say "  GREEN       provision_status succeeded — the first green refire post-c65f517e2."
  say "  LAWFUL RED  workspace_slug_conflict in the job's evidence — the PDS-D9 fail-closed"
  say "              refuse (bp-pds-charter.md:86): the box's seeded 'default' workspace was not"
  say "              provably empty. A CORRECT refusal — never misread as 'c65f517e2 did not"
  say "              take' (PDF-D99)."
  say "  RED         any other chain failure — a defect finding, quoted from provision_error +"
  say "              the job console."
  say ""
  say "CREDENTIAL LAWS:"
  say "  · CREDENTIAL-EMPTY: HCLOUD_TOKEN must NOT be in this shell — R0 ABORTS on it. This"
  say "    epic habitually exports HCLOUD_TOKEN explicitly (PDF-D75 Darwin context-blindness):"
  say "    for THIS instrument the teardown credential is the SEPARATE named var"
  say "    PDFP1_TEARDOWN_HCLOUD_TOKEN (or the hcloud '$TEARDOWN_HC_CTX' context) — unset"
  say "    HCLOUD_TOKEN before firing."
  say "  · TWO TEARDOWN CREDENTIALS (PDF-D101): boxes live under the FLEET project"
  say "    ($(teardown_cred_name)); the $DNS_ZONE zone lives under the GUERRILLA project —"
  say "    the fleet token sees ZERO zones. DNS census rides BARKPARK_DNS_HCLOUD_TOKEN, else"
  say "    the hcloud '$DNS_HC_CTX' context."
  say "  · MONEY-SAFETY GATE: R0 ABORTS unless the teardown credential provably addresses the"
  say "    CP's provisioning project (a CP-managed host must be visible through it). NEVER"
  say "    create a box you cannot tear down."
  say ""
  say "RUNGS:"
  say "  0  PRECONDITION — ABORT-only: config bearers (.token + .cloud_token); the"
  say "     credential-empty law; CP POST /v1/fleet/supports anon → 401; the money-safety"
  say "     gate; the TEMPLATE-LESS-PARENT gate — GET /v1/barkparks/$PARENT_ID/bootstrap"
  say "     must answer 404 no_bootstrap (Registry.reveal_bootstrap emits that ONLY when"
  say "     bootstrap_workspace AND the read token are both nil; the /v1/barkparks listing"
  say "     does NOT serialise the field, so a null THERE is an absent key and a FALSE proof);"
  say "     and GET /v1/barkparks/$PARENT_ID/credentials → 200 (else the enqueue 409s"
  say "     no_admin_token); bp builds fresh from ./cmd/barkpark (the rung-4 teardown verb)."
  say "  1  THE FIRE — exactly ONE POST $CP_BASE/v1/fleet/supports"
  say "     {name:$SUPPORT_NAME, barkpark_id:$PARENT_ID, mode:provision}, bearer .cloud_token."
  say "     Want 202 {barkpark, job_id}; the job_id is sealed into the transcript. The CP"
  say "     registers the host-nil row BEFORE enqueueing — a RED leaves a live CP row"
  say "     REGARDLESS, and the chain's own DNS teardown is FAIL-OPEN. Nothing cleans itself."
  say "  2  WATCH — poll the CP row's provision_steps to a terminal state (budget ${POLL_BUDGET}s)."
  say "     A RED terminal is RECORDED + CLASSIFIED (lawful PDS-D9 refuse vs broken chain) and"
  say "     the run CONTINUES to the read + teardown. Budget exhaustion FAILs the instrument"
  say "     but teardown still runs — money before verdicts."
  say "  3  THE D102 READ — re-READ the CP row; print fleet_token_id + provision_steps"
  say "     VERBATIM (never inferred from the job's exit). fleet_token_id nil on a green run"
  say "     IS the task-b9c0f988cd0019d4 finding (the silent-nil seam, support.go:622 vs :630)."
  say "  4  TEARDOWN (P3) — PDF-D68 order: CP row already READ first; revoke the ledger token"
  say "     FIRST among deletes (DELETE $MAIN_BASE/v1/fleet/support-tokens/:id); then"
  say "     bp cloud support remove (box/roster/DNS — itself under test); then the RAW LABEL"
  say "     REAPER (list-then-delete on $FLEET_LABEL=$SUPPORT_NAME — hcloud server delete has"
  say "     no --selector); CP row deleted LAST (sole durable token-id holder)."
  say "  5  FIVE-SURFACE CENSUS (PDF-D101) — re-reads, never receipts:"
  say "     (1) token: revoke receipt + idempotent re-probe (honest narration when the id was"
  say "         nil — cannot revoke what the ledger never recorded);"
  say "     (2) box: provider label scan $FLEET_LABEL=$SUPPORT_NAME through the teardown"
  say "         credential — must be empty;"
  say "     (3) roster: the guerrilla main's roster must not return $SUPPORT_NAME;"
  say "     (4) CP row: the listing must not return the support id;"
  say "     (5) DNS BY VALUE: zero A rrsets in $DNS_ZONE resolving to the box IP — by VALUE,"
  say "         never by name (muscle-1 and muscle-1-506f035e share one IP, PDF-D101); under"
  say "         the GUERRILLA DNS credential; skipped-with-reason when no DNS credential or"
  say "         the box never got an IP."
  say "     Every leg reports honestly, including 'skipped, and why'."
  say ""
  say "  --scan-transcript <file>: grep for the guerrilla admin bearer, the cloud_token, the"
  say "  named teardown token, any hcloud cli.toml token, and the sk-ant prefix — ZERO hits"
  say "  or no commit."
  rule
  say "Run it:  $0            (THE FIRE — LIVE: provisions + tears down ONE support box)"
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
  scan_value "named teardown HCLOUD token (env)" "${PDFP1_TEARDOWN_HCLOUD_TOKEN:-}"
  scan_value "DNS HCLOUD token (env)" "${BARKPARK_DNS_HCLOUD_TOKEN:-}"
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
# THE LIVE RUN
# ═════════════════════════════════════════════════════════════════════════════

command -v curl    >/dev/null 2>&1 || die "curl not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

# The trap installs BEFORE any write — in particular BEFORE the rung-1 fire.
# Every later write flips its own flag for the trap.
trap cleanup EXIT

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pdfp1.XXXXXX")"

# The 3-line transcript header convention — self-carried so the tee'd
# transcript needs no hand-editing.
say "# pdf-p1-refire — transcript"
say "# tree: $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)) · host: $(uname -s | tr '[:upper:]' '[:lower:]') · $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "# command: scripts/pdf-p1-refire.sh"
say ""
rule
say "PDF P1 REFIRE — run $RUN_ID"
rule
say "tree:     $REPO_ROOT"
say "worktree: $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
say "cp:       $CP_BASE"
say "parent:   $PARENT_ID (template-less Guerrilla, PDF-D98)"
say "main:     $MAIN_BASE (dataset $DATASET)"
say "name:     $SUPPORT_NAME · watch budget ${POLL_BUDGET}s"

# ── RUNG 0 — PRECONDITION (ABORT-only) ───────────────────────────────────────

head_rung 0 "PRECONDITION — bearers, credential-empty law, CP route, money-safety, template-less parent (ABORT-only)"

# 0a. config bearers (local read).
if [ ! -r "$CONFIG_JSON" ]; then
  abort 0 "env:config-bearers" "no $CONFIG_JSON — the fire bearer (.cloud_token) and the parent-main admin bearer (.token) come from there at run time (never hardcoded)"
  exit 2
fi
ADMIN_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token") or "")' "$CONFIG_JSON")"
CLOUD_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cloud_token") or "")' "$CONFIG_JSON")"
if [ -z "$CLOUD_TOKEN" ]; then
  abort 0 "env:config-bearers" "config.json .cloud_token is empty — the fire bearer is missing (re-mint via bp login; PDF-D97: the session token expires ~30 days from mint)"
  exit 2
fi
if [ -z "$ADMIN_TOKEN" ]; then
  abort 0 "env:config-bearers" "config.json .token is empty — the parent-main admin bearer drives the roster reads and the token-revoke leg"
  exit 2
fi
info "config bearers loaded (.token ${#ADMIN_TOKEN} bytes, .cloud_token ${#CLOUD_TOKEN} bytes — never printed)"

# 0b. CREDENTIAL-EMPTY LAW — said LOUDLY, because this epic's own habit is to
# export HCLOUD_TOKEN explicitly (PDF-D75 Darwin context-blindness). That habit
# and this instrument collide head-on: the fire is HTTP-bearer-only, and the
# teardown credential is a SEPARATE NAMED var.
if [ -n "${HCLOUD_TOKEN:-}" ]; then
  abort 0 "env:not-credential-empty" "HCLOUD_TOKEN is set in this shell — the fire is CREDENTIAL-EMPTY by law (the CP is the hands). This epic habitually exports HCLOUD_TOKEN explicitly (PDF-D75); for THIS instrument that habit is the trap: unset HCLOUD_TOKEN and pass the teardown credential as the SEPARATE named var PDFP1_TEARDOWN_HCLOUD_TOKEN (or rely on the hcloud '$TEARDOWN_HC_CTX' context). Nothing created."
  exit 2
fi
info "credential-empty law holds: no HCLOUD_TOKEN in this shell (teardown = $(teardown_cred_name))"

# 0c. the CP fleet-supports route answers its contracted anon-401 (writes
# nothing; 404 would mean the route itself is gone).
CP_ANON="$(anon_post_code "$CP_BASE/v1/fleet/supports")"
info "anon POST /v1/fleet/supports (control plane) -> HTTP ${CP_ANON:-000}"
if [ "${CP_ANON:-000}" != "401" ]; then
  abort 0 "env:cp-fleet-supports-shape" "the CP answered ${CP_ANON:-000} to an anonymous POST /v1/fleet/supports, want 401 (404 = the route is gone, pdf-wc-cp-network-recreate territory). Nothing created."
  exit 2
fi

# 0d. TEMPLATE-LESS-PARENT GATE (PDF-D98) — the claim pins workspace "default"
# (and therefore RUNS the c65f517e2 bracket) ONLY for a template-less parent.
# The discriminator is GET /v1/barkparks/:id/bootstrap → 404 {"error":
# "no_bootstrap"}, which Registry.reveal_bootstrap emits ONLY when
# bootstrap_workspace AND the read token are BOTH nil. NEVER read this from the
# /v1/barkparks listing: it does not serialise bootstrap_workspace or template
# at all, so a null there is an ABSENT KEY and a FALSE proof.
BOOT_OUT="$WORKDIR/bootstrap.json"
BOOT_CODE="$(cp_get_code "/v1/barkparks/$PARENT_ID/bootstrap" "$BOOT_OUT" || true)"
BOOT_ERR="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("error") or "")
except Exception:
    print("")' "$BOOT_OUT")"
info "GET /v1/barkparks/$PARENT_ID/bootstrap -> HTTP ${BOOT_CODE:-000} error=${BOOT_ERR:-<none>}"
if [ "${BOOT_CODE:-000}" != "404" ] || [ "$BOOT_ERR" != "no_bootstrap" ]; then
  info "body: $(head -c 200 "$BOOT_OUT" | tr -d '\n')"
  abort 0 "env:parent-not-template-less" "the parent's /bootstrap answered ${BOOT_CODE:-000} '${BOOT_ERR:-}' — want 404 no_bootstrap, the ONLY valid template-less proof (PDF-D98). A templated parent pins the claim's workspace to the template slug and the c65f517e2 bracket under test would be SKIPPED: a green would prove nothing. Nothing created."
  exit 2
fi
info "template-less parent PROVEN: 404 no_bootstrap → the claim pins workspace 'default' (router.ex:9471) and the bracket RUNS"

# 0e. the parent holds an admin token — else the enqueue 409s no_admin_token
# (the claim payload's credential spine).
CRED_OUT="$WORKDIR/parent-credentials.json"
CRED_CODE="$(cp_get_code "/v1/barkparks/$PARENT_ID/credentials" "$CRED_OUT" || true)"
CRED_HAS="$(python3 -c '
import json, sys
try:
    print("yes" if (json.load(open(sys.argv[1])).get("admin_token") or "") else "no")
except Exception:
    print("no")' "$CRED_OUT")"
info "GET /v1/barkparks/$PARENT_ID/credentials -> HTTP ${CRED_CODE:-000}, admin_token present: $CRED_HAS (value never printed)"
if [ "${CRED_CODE:-000}" != "200" ] || [ "$CRED_HAS" != "yes" ]; then
  abort 0 "env:parent-no-admin-token" "the parent's credentials surface did not reveal an admin token (HTTP ${CRED_CODE:-000}) — the enqueue would 409 no_admin_token. Nothing created."
  exit 2
fi

# 0f. the guerrilla roster answers the documents envelope (the census leg 3
# surface + the token-revoke host).
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
info "GET $MAIN_BASE/v1/fleet/roster?dataset=$DATASET -> HTTP ${PRECODE:-000}, documents-envelope: $ENVELOPE_OK"
if [ "${PRECODE:-000}" != "200" ] || [ "$ENVELOPE_OK" != "yes" ]; then
  info "body: $(head -c 300 "$ROSTER_TMP" | tr -d '\n')"
  abort 0 "env:roster-unreachable" "the guerrilla main did not serve the roster to the config bearer — wrong token or a stale deploy. Nothing created."
  exit 2
fi

# 0g. fresh bp from ./cmd/barkpark (rung 4 drives `bp cloud support remove` —
# the verb under test this wave; the trap uses the same binary).
command -v go >/dev/null 2>&1 || { abort 0 "env:no-go" "go not on PATH — cannot build bp from ./cmd/barkpark (the rung-4 teardown verb)"; exit 2; }
BP="$WORKDIR/bp"
info "building bp: go build -o \$WORKDIR/bp ./cmd/barkpark …"
if ! (cd "$REPO_ROOT" && go build -o "$BP" ./cmd/barkpark) >"$WORKDIR/bp-build.log" 2>&1; then
  tail -20 "$WORKDIR/bp-build.log" | sed 's/^/      /'
  abort 0 "env:bp-build-failed" "go build ./cmd/barkpark failed — see above. Nothing created."
  exit 2
fi
info "bp built ($(wc -c < "$BP" | tr -d ' ') bytes)"

# 0h. MONEY-SAFETY GATE (transcribed from the journey proof) — the box lands in
# the CP's PROVISIONING project; PROVE the teardown credential reaches it: a
# CP-managed host listed through it must match a CP-managed barkpark's host.
# NEVER create a box you cannot tear down.
command -v hcloud >/dev/null 2>&1 || { abort 0 "env:no-hcloud" "hcloud CLI not on PATH — both the raw reaper and the census box scan need it; refusing to create a box that cannot be removed. Nothing created."; exit 2; }
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
  abort 0 "env:no-cp-managed-host" "the control plane lists NO managed instance host to cross-check the teardown project against — cannot PROVE the teardown credential reaches the CP's provisioning project without risking a stranded box. Nothing created."
  exit 2
fi
PROJ_JSON="$WORKDIR/teardown-project.json"
if ! hc_teardown server list -o json >"$PROJ_JSON" 2>"$WORKDIR/teardown-project.err"; then
  head -3 "$WORKDIR/teardown-project.err" | sed 's/^/      /'
  abort 0 "env:teardown-credential-unusable" "the NAMED teardown credential ($(teardown_cred_name)) did not answer 'hcloud server list' — without a working fleet-project credential the support box could never be removed. Set PDFP1_TEARDOWN_HCLOUD_TOKEN or an hcloud '$TEARDOWN_HC_CTX' context. Nothing created."
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
info "teardown project ($(teardown_cred_name)) lists $PROJ_N box(es); CP-managed ∩ teardown-project = ${OVERLAP:-<empty>}"
if [ -z "$OVERLAP" ]; then
  abort 0 "env:teardown-project-disjoint" "the NAMED teardown credential ($(teardown_cred_name)) addresses a DIFFERENT Hetzner project than the CP provisions into: NOT ONE of the CP's $CP_HOST_N managed host(s) is visible through it. A CP-provisioned support box would be UNREACHABLE for teardown. REFUSING to create a box I cannot tear down. Nothing created."
  exit 2
fi
info "teardown-capability PROVEN: $(teardown_cred_name) reaches the CP's provisioning project (shared host $OVERLAP)"

# 0i. DNS census credential — informational only (leg 5 reports honestly).
if [ -n "$DNS_HC_TOKEN" ]; then
  info "DNS census credential: BARKPARK_DNS_HCLOUD_TOKEN (env) — leg 5 will sweep $DNS_ZONE by value"
elif hcloud context list 2>/dev/null | grep -q "^$DNS_HC_CTX\$\|[[:space:]]$DNS_HC_CTX\$\|^$DNS_HC_CTX[[:space:]]\|\*$DNS_HC_CTX\$"; then
  info "DNS census credential: hcloud '$DNS_HC_CTX' context — leg 5 will sweep $DNS_ZONE by value"
else
  info "DNS census credential: NONE resolved (no BARKPARK_DNS_HCLOUD_TOKEN, no '$DNS_HC_CTX' context) — leg 5 will be a NAMED SKIP (the fleet token sees zero zones, PDF-D101)"
fi

pass 0 "bearers resolve; credential-empty (no HCLOUD_TOKEN); CP route answers its anon-401; template-less parent PROVEN via 404 no_bootstrap; parent admin token present; roster serves the envelope; bp fresh; and the teardown credential provably reaches the CP's provisioning project"

# ── RUNG 1 — THE FIRE (P1 birth) ─────────────────────────────────────────────

head_rung 1 "THE FIRE — exactly ONE POST /v1/fleet/supports {mode:provision} under the Guerrilla parent"

FIRE_OUT="$WORKDIR/fire.json"
SUPPORT_FIRED=1   # BEFORE the call — a half-dead fire must still be reaped
say "  \$ POST $CP_BASE/v1/fleet/supports {name:$SUPPORT_NAME, barkpark_id:$PARENT_ID, mode:provision}"
FCODE="$(cp_post_code "/v1/fleet/supports" "{\"name\":\"$SUPPORT_NAME\",\"barkpark_id\":\"$PARENT_ID\",\"mode\":\"provision\"}" "$FIRE_OUT")"
say "      receipt (HTTP ${FCODE:-000}):"
sed 's/^/      | /' "$FIRE_OUT"
case "${FCODE:-000}" in
  202) : ;;
  409) abort 1 "env:no-admin-token-or-inflight" "the fire answered 409 — the parent has no admin token or a provision is already in flight. A substrate state, not a P1 color. The host-nil CP row (if registered) is reaped by the trap."; exit 2 ;;
  *)   fail 1 "POST /v1/fleet/supports mode=provision answered ${FCODE:-000}, want 202 — see the receipt above"; exit 1 ;;
esac
SUPPORT_ID="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
bp = d.get("barkpark") or {}
print(bp.get("id") or "")' "$FIRE_OUT")"
JOB_ID="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("job_id") or "")
except Exception:
    print("")' "$FIRE_OUT")"
if [ -z "$SUPPORT_ID" ]; then
  fail 1 "the 202 receipt carried no barkpark id — cannot watch or tear down by id (the trap falls back to the label reaper)"
  exit 1
fi
say "      SEALED: support_id=$SUPPORT_ID job_id=${JOB_ID:-<missing>} (the provision_support job the Go provisioner drains)"
pass 1 "one fire, 202 accepted: support row registered host-nil (id $SUPPORT_ID), job ${JOB_ID:-?} enqueued"

# ── RUNG 2 — WATCH to a terminal state ───────────────────────────────────────

head_rung 2 "WATCH — poll the CP row's provision_steps to terminal (a RED is a recorded finding, not an abort)"

P1_COLOR=""          # GREEN | LAWFUL-RED | RED | TIMEOUT — the finding
DEADLINE_EPOCH="$(python3 -c "import time; print(int(time.time()) + $POLL_BUDGET)")"
LAST_ROW=""
while :; do
  LAST_ROW="$(cp_row_json "$SUPPORT_ID" || true)"
  PSTATUS="$(printf '%s' "$LAST_ROW" | row_field provision_status)"
  STEPS="$(printf '%s' "$LAST_ROW" | row_steps_brief)"
  HOST_NOW="$(printf '%s' "$LAST_ROW" | row_field host)"
  [ -n "$HOST_NOW" ] && BOX_IP="$HOST_NOW"
  printf '  watch  status=%-10s host=%-16s steps=[%s]\n' "${PSTATUS:-—}" "${BOX_IP:-—}" "${STEPS:-—}"
  if [ "$PSTATUS" = "succeeded" ]; then
    P1_COLOR="GREEN"
    break
  fi
  if [ "$PSTATUS" = "failed" ] || printf '%s' "$STEPS" | grep -q ':failed'; then
    # Terminal RED — quote the job's own evidence, then CLASSIFY it.
    say "      CHAIN TERMINAL RED (provision_status=${PSTATUS:-?}; steps=[$STEPS]) — quoting the job's own evidence:"
    printf '%s' "$LAST_ROW" | python3 -c '
import json, sys
line = sys.stdin.read().strip()
r = json.loads(line) if line else {}
err = r.get("provision_error")
if err:
    print("      provision_error: %s" % str(err)[:600])
con = r.get("provision_console")
if isinstance(con, list):
    # The WHOLE console (bounded): the evidence-carrying steps echo bp output
    # + a journal tail — truncating short cost a prior round its root cause.
    for line in con[-220:]:
        if isinstance(line, dict):
            line = line.get("line") or line.get("text") or json.dumps(line)
        print("      | %s" % str(line)[:400])' 2>/dev/null || true
    # CLASSIFY: the PDS-D9 fail-closed refuse is a LAWFUL red — the merge
    # engine rolls back {:workspace_slug_conflict, …} when the box's seeded
    # "default" workspace is not provably empty (0 documents, 0 media_files).
    # That is the engine doing its job (bp-pds-charter.md:86), and it must
    # NEVER be misread as "c65f517e2 did not take" (PDF-D99).
    if printf '%s' "$LAST_ROW" | grep -q 'workspace_slug_conflict'; then
      P1_COLOR="LAWFUL-RED"
      say ""
      say "      CLASSIFICATION: LAWFUL RED (PDS-D9 fail-closed refuse) — the evidence carries"
      say "      workspace_slug_conflict: the box's 'default' workspace was NOT provably empty, and"
      say "      the merge engine correctly REFUSED rather than silently replace it. This is the"
      say "      engine's law holding, DISTINCT from a broken chain — the finding is about the"
      say "      image seed / reset bracket, not about the merge engine."
    else
      P1_COLOR="RED"
      say ""
      say "      CLASSIFICATION: RED (chain defect) — no workspace_slug_conflict in the evidence;"
      say "      the failure above is a real defect finding for the wave ledger."
    fi
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; then
    P1_COLOR="TIMEOUT"
    fail 2 "the job reached NO terminal state within ${POLL_BUDGET}s (last status=${PSTATUS:-none}, steps=[$STEPS]) — an instrument failure; teardown still runs (money before verdicts)"
    break
  fi
  sleep 8
done
if [ "$P1_COLOR" = "GREEN" ]; then
  pass 2 "terminal GREEN: provision_status succeeded (host ${BOX_IP:-?}) — the c65f517e2 bracket ran under workspace 'default' and the chain converged"
elif [ "$P1_COLOR" = "LAWFUL-RED" ] || [ "$P1_COLOR" = "RED" ]; then
  pass 2 "terminal $P1_COLOR reached and RECORDED first-class (evidence quoted above) — the instrument continues to the D102 read + teardown"
fi

# ── RUNG 3 — THE D102 READ (never inferred) ──────────────────────────────────

head_rung 3 "THE D102 READ — the CP row's fleet_token_id + provision_steps, READ after terminal"

# Re-READ the row AFTER the terminal state — the discriminator must come from
# the row itself, never from the job's exit (PDF-D102).
D102_ROW="$(cp_row_json "$SUPPORT_ID" || true)"
if [ -z "$D102_ROW" ]; then
  efail "the CP row for $SUPPORT_ID is ABSENT at the post-terminal read — the fire registered it, so an absent row is itself a finding"
else
  FLEET_TOKEN_ID="$(printf '%s' "$D102_ROW" | row_field fleet_token_id)"
  D102_STEPS="$(printf '%s' "$D102_ROW" | row_field provision_steps)"
  HOST_NOW="$(printf '%s' "$D102_ROW" | row_field host)"
  [ -n "$HOST_NOW" ] && BOX_IP="$HOST_NOW"
  say "      CP row (read, verbatim fields — the discriminator for task-b9c0f988cd0019d4):"
  say "      fleet_token_id:  ${FLEET_TOKEN_ID:-NIL}"
  say "      provision_steps: ${D102_STEPS:-NIL}"
  say "      host:            ${BOX_IP:-NIL}"
  if [ "$P1_COLOR" = "GREEN" ] && [ -z "$FLEET_TOKEN_ID" ]; then
    say ""
    say "      FINDING (PDF-D102): a GREEN provision with fleet_token_id NIL — the silent-nil seam"
    say "      fired (support.go:622 makes an empty token fatal but never checks the empty token ID"
    say "      at :630; the worker, fleet_token_id_opts and maybe_put_fleet_token_id all tolerate"
    say "      the nil). The minted ledger token is now an ORPHAN on the parent main — exactly the"
    say "      window PDF-D68 was written to close. This is task-b9c0f988cd0019d4, live."
  fi
fi
rung_seal 3 "D102 read done: fleet_token_id=${FLEET_TOKEN_ID:-NIL} read from the row (never inferred); provision_steps printed verbatim"

# ── RUNG 4 — TEARDOWN (P3 death), PDF-D68 order ──────────────────────────────

head_rung 4 "TEARDOWN — PDF-D68 order: row already read; token FIRST among deletes; box/roster/DNS; CP row LAST"

# 4a. TOKEN — FIRST among deletes (PDF-D68). Idempotent for bp's own token leg
# (its revoke treats 404 as already-gone).
TOKEN_DEL_CODE=""
if [ -n "$FLEET_TOKEN_ID" ]; then
  say "  4a \$ DELETE $MAIN_BASE/v1/fleet/support-tokens/$FLEET_TOKEN_ID   (revoke the ledger token — FIRST among deletes)"
  TKO="$WORKDIR/token-revoke.json"
  TOKEN_DEL_CODE="$(main_delete_code "/v1/fleet/support-tokens/$FLEET_TOKEN_ID" "$TKO" || true)"
  info "revoke -> HTTP ${TOKEN_DEL_CODE:-000}: $(head -c 160 "$TKO" | tr -d '\n')"
  if [ "${TOKEN_DEL_CODE:-000}" = "200" ]; then
    TOKEN_REVOKED=1
  else
    efail "the token revoke answered ${TOKEN_DEL_CODE:-000}, want 200 — the ledger token may still authenticate (bp remove's token leg re-attempts below)"
  fi
else
  say "  4a token revoke: SKIPPED — fleet_token_id is NIL on the CP row (the D102 wound,"
  say "      task-b9c0f988cd0019d4). If the chain reached its mint, a live ledger token is now"
  say "      ORPHANED on the parent main with no recorded id to revoke it by — said plainly,"
  say "      never upgraded to 'revoked'."
fi

# 4b. BOX/ROSTER/DNS — `bp cloud support remove` (the verb under test; it runs
# its own D68 ladder: cp-read → locate → token → box → roster → cp-row). Runs
# on EITHER teardown-credential path. A failure here is a first-class finding —
# the raw reaper below still guarantees the box dies.
say "  4b \$ bp cloud support remove $SUPPORT_NAME --dataset $DATASET   (teardown credential = $(teardown_cred_name))"
RM_OUT="$WORKDIR/remove-stdout.json"
RM_ERR="$WORKDIR/remove-progress.log"
RM_RC=0
if [ -n "$TEARDOWN_HC_TOKEN" ]; then
  HCLOUD_TOKEN="$TEARDOWN_HC_TOKEN" BP_COLOR=none "$BP" cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" -o json \
    >"$RM_OUT" 2>"$RM_ERR" || RM_RC=$?
else
  HCLOUD_CONTEXT="$TEARDOWN_HC_CTX" BP_COLOR=none "$BP" cloud support remove "$SUPPORT_NAME" --dataset "$DATASET" -o json \
    >"$RM_OUT" 2>"$RM_ERR" || RM_RC=$?
fi
sed 's/^/      | /' "$RM_ERR"
say "      receipt:"
sed 's/^/      | /' "$RM_OUT"
if [ "$RM_RC" -eq 0 ]; then
  BOX_GONE=1
  CP_ROW_GONE=1   # the verb's own last step is the CP-row delete; census re-reads verify
  info "bp cloud support remove exited 0 — census re-reads (rung 5) are the truth, not this receipt"
else
  efail "bp cloud support remove exited $RM_RC (the verb is itself under test this wave) — falling through to the raw reaper"
fi

# 4c. RAW LABEL REAPER — the PDF-D75 last resort, regained: list-then-delete on
# the fleet label through the teardown credential (either path).
if [ -z "$BOX_GONE" ]; then
  say "  4c raw label reaper (list-then-delete; hcloud server delete has no --selector):"
  reap_box_by_label
  [ "${BOX_REAPED:-0}" -gt 0 ] && BOX_GONE=1
else
  say "  4c raw label reaper: not needed (bp remove converged) — rung 5's label scan re-verifies anyway"
fi

# 4d. CP ROW — LAST (PDF-D68: the sole durable token-id holder dies last).
# bp remove's own last step already deletes it on success; this direct DELETE
# is the fallback for the raw-reaper path, and idempotent otherwise.
if [ -n "$SUPPORT_ID" ]; then
  say "  4d \$ DELETE $CP_BASE/v1/fleet/supports/$SUPPORT_ID   (CP row LAST)"
  CPDEL_OUT="$WORKDIR/cp-row-delete.json"
  CPDCODE="$(cp_delete_code "/v1/fleet/supports/$SUPPORT_ID" "$CPDEL_OUT" || true)"
  info "CP row delete -> HTTP ${CPDCODE:-000}: $(head -c 160 "$CPDEL_OUT" | tr -d '\n')"
  case "${CPDCODE:-000}" in
    200|202|204|404) CP_ROW_GONE=1 ;;   # 404 = bp remove already took it
    *) efail "the CP row delete answered ${CPDCODE:-000} — the row may survive (rung 5 re-reads)" ;;
  esac
fi
TEARDOWN_RAN=1
rung_seal 4 "teardown ran in PDF-D68 order: token ${FLEET_TOKEN_ID:+revoked (HTTP ${TOKEN_DEL_CODE:-?})}${FLEET_TOKEN_ID:-skipped (nil id — the D102 wound)}; bp remove rc=$RM_RC; CP row deleted last"

# ── RUNG 5 — FIVE-SURFACE CENSUS (PDF-D101) ──────────────────────────────────

head_rung 5 "FIVE-SURFACE CENSUS — re-reads, never receipts: token, box, roster, CP row, DNS-by-value"

# 1. TOKEN — the revoke receipt + the idempotent re-probe. Honest bounds: this
#    instrument never held the raw secret (it lives only on the box), so the
#    403→401 live probe is not available — the receipt + a second DELETE
#    (already-gone) is the strongest read we can make, and it says so.
if [ -n "$FLEET_TOKEN_ID" ]; then
  TK2="$WORKDIR/token-reprobe.json"
  TK2CODE="$(main_delete_code "/v1/fleet/support-tokens/$FLEET_TOKEN_ID" "$TK2" || true)"
  info "1. TOKEN: revoke read ${TOKEN_DEL_CODE:-?} → re-DELETE reads ${TK2CODE:-000} (already-gone wanted: non-200)"
  if [ "${TOKEN_DEL_CODE:-000}" = "200" ] && [ "${TK2CODE:-000}" != "200" ]; then
    info "   revoked-and-stays-revoked; NOTE the raw secret was never held by this instrument, so"
    info "   this leg attests the ledger row, not a live 403→401 bearer probe"
  else
    efail "token leg inconclusive: revoke=${TOKEN_DEL_CODE:-?} re-probe=${TK2CODE:-?}"
  fi
else
  info "1. TOKEN: SKIPPED — fleet_token_id was NIL on the CP row (task-b9c0f988cd0019d4): there is"
  info "   no recorded id to revoke or re-probe. If the chain minted, that token is an ORPHAN on"
  info "   the parent main — a leak this census cannot close, only name."
fi

# 2. BOX — the provider label scan through the teardown credential.
SRV_AFTER="$(hc_teardown server list -l "$FLEET_LABEL=$SUPPORT_NAME" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin) or []
except Exception:
    d = []
print(",".join(s.get("name") or "" for s in d))' || true)"
info "2. BOX: hcloud label scan $FLEET_LABEL=$SUPPORT_NAME ($(teardown_cred_name)): ${SRV_AFTER:-empty}"
[ -z "$SRV_AFTER" ] || efail "box(es) still carry the label: $SRV_AFTER (BILLING)"

# 3. ROSTER — the guerrilla main must no longer return the support row.
SROW="$(curl_roster | row_of "$SUPPORT_NAME" || true)"
info "3. ROSTER: row for $SUPPORT_NAME on $MAIN_BASE: ${SROW:-none}"
[ -z "$SROW" ] || efail "roster row still present: $SROW"

# 4. CP ROW — the listing must no longer return the support id.
CP_AFTER="$(cp_row_json "$SUPPORT_ID" || true)"
info "4. CP ROW: /v1/barkparks row for $SUPPORT_ID: ${CP_AFTER:+STILL PRESENT}${CP_AFTER:-gone}"
[ -z "$CP_AFTER" ] || efail "CP support row survives: $(printf '%s' "$CP_AFTER" | head -c 200)"

# 5. DNS BY VALUE (PDF-D101) — zero A rrsets in the zone resolving to the box
#    IP. BY VALUE, never by name: muscle-1 (ttl=60, the support chain's writer)
#    and muscle-1-506f035e (the main go-live writer) both point at one IP — a
#    name-derived delete removes one and leaves the other while a name census
#    still reads delta zero. Needs the GUERRILLA credential: the fleet token
#    sees zero zones.
if [ -z "$BOX_IP" ]; then
  info "5. DNS: SKIPPED — the box never recorded a host IP on the CP row (the chain died before"
  info "   create finished), so there is no VALUE to sweep by. The chain's own DNS write happens"
  info "   after the IP exists, so no rrset can point at a box that never got one."
elif [ -z "$DNS_HC_TOKEN" ] && ! hcloud context list 2>/dev/null | grep -q "$DNS_HC_CTX"; then
  info "5. DNS: SKIPPED — no DNS credential in scope (no BARKPARK_DNS_HCLOUD_TOKEN, no hcloud"
  info "   '$DNS_HC_CTX' context). The FLEET teardown credential cannot see the zone (zones: [],"
  info "   PDF-D101) — a one-token census fails this leg silently, so it is named instead. The"
  info "   box IP to sweep by hand: $BOX_IP (hcloud zone rrset list $DNS_ZONE, type A, value match)."
  efail "DNS leg could not run — records pointing at $BOX_IP are UNVERIFIED (the chain's own DNS teardown is FAIL-OPEN)"
else
  DNS_HITS="$(hc_dns zone rrset list "$DNS_ZONE" -o json 2>/dev/null | IP="$BOX_IP" python3 -c '
import json, os, sys
ip = os.environ["IP"]
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
rrsets = d.get("rrsets") if isinstance(d, dict) else d
hits = []
for rr in rrsets or []:
    if (rr.get("type") or "").upper() != "A":
        continue
    for rec in rr.get("records") or []:
        val = rec.get("value") if isinstance(rec, dict) else rec
        if str(val).strip() == ip:
            hits.append(rr.get("name") or "?")
print(",".join(hits))' || true)"
  info "5. DNS: A rrsets in $DNS_ZONE resolving to $BOX_IP (by VALUE): ${DNS_HITS:-none}"
  if [ -n "$DNS_HITS" ]; then
    efail "DNS residue: A record(s) [$DNS_HITS] still point at the box IP $BOX_IP — the chain's fail-open DNS teardown (support.go:527-540) leaked; the A-record wound task-688ebffc4b0aa50a, live"
  fi
fi
rung_seal 5 "five-surface census: token ${FLEET_TOKEN_ID:+revoked+re-probed}${FLEET_TOKEN_ID:-skipped (nil id, named)}; box label scan; roster row; CP row; DNS swept by VALUE against ${BOX_IP:-<no ip>}"

# ── verdict ──────────────────────────────────────────────────────────────────

say ""
rule
say "VERDICT — instrument: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
say "P1 COLOR (the finding, first-class): ${P1_COLOR:-UNKNOWN}"
case "$P1_COLOR" in
  GREEN)      say "  → the first green provision_support refire post-c65f517e2. fleet_token_id=${FLEET_TOKEN_ID:-NIL}"
              [ -z "$FLEET_TOKEN_ID" ] && say "    (NIL on green = task-b9c0f988cd0019d4 CONFIRMED live — see the rung-3 finding)" ;;
  LAWFUL-RED) say "  → the PDS-D9 fail-closed refuse fired (workspace_slug_conflict): the box's seeded"
              say "    'default' workspace was not provably empty. The merge engine's law HELD; the finding"
              say "    is about the image seed / reset bracket — NOT 'c65f517e2 did not take' (PDF-D99)." ;;
  RED)        say "  → the chain failed for a non-PDS-D9 reason — the defect evidence is quoted in rung 2." ;;
  TIMEOUT)    say "  → no terminal state within ${POLL_BUDGET}s — an instrument failure, not a chain color." ;;
esac
say ""
say "BEFORE COMMITTING THE TRANSCRIPT:"
say "  $0 --scan-transcript <transcript-file>"
say "must print ZERO hits — the guerrilla admin bearer, the cloud_token, the named teardown"
say "token, any hcloud cli.toml token, and any sk-ant prefix. Zero hits or no commit."
rule
if [ "$N_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

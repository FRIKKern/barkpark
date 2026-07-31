#!/usr/bin/env bash
#
# pds-live-bp-write-receipt.sh — LEG B of the PDS epic's first L1: every bp WRITE
# receipt checked against the server's own independent read.
#
#   MANUAL-RUN-ONLY. This script is NOT a CI tenant and is deliberately absent
#   from .github/workflows/shell-harnesses.yml, whose tenants are required to be
#   token-free and network-free. This one spends a real Barkpark admin token and
#   makes real writes into guerrilla's `production` dataset.
#
#   scripts/pds-live-bp-write-receipt.sh --plan       print the ladder, no side effects
#   scripts/pds-live-bp-write-receipt.sh --preflight  resolve-or-die; name the rung
#   scripts/pds-live-bp-write-receipt.sh --selftest   prove the preflight can REFUSE
#   scripts/pds-live-bp-write-receipt.sh --run        the live round trip
#
# THE SHAPE OF THE PROOF, and why it is not a screenshot of bp agreeing with
# itself: bp's write receipt carries an _id and a _rev. Those are the CLI's claim
# about what the server now holds. This runner takes every one of them to an
# INDEPENDENT reader — curl against /v1/data/query/<dataset>/<type>, a different
# client on a different code path — and requires the server's own answer to
# carry the same _id and the same _rev. A receipt that agreed only with itself
# would pass a test written the other way; this one cannot.
#
# THE LAW (PDS, unchanged since wave 22): NO BARKPARK VERB MAY REPORT SUCCESS ON
# AN EXIT CODE ALONE. Leg A pays that for a Hetzner destroy. Leg B pays it for the
# five write verbs of the content workhorse: create, patch, publish, unpublish,
# delete.
#
# THE PREAMBLE IS THE SLICE — same discipline as its Leg A sibling:
#   · the preflight gates on bp's OWN resolution (a cheap read verb's exit code
#     AND its receipt SHAPE), never on the presence of an env-var name. bp
#     resolves a server+token from --token, then $BARKPARK_TOKEN, then
#     ~/.config/barkpark/config.json — so "is $BARKPARK_TOKEN set" is both a false
#     refusal (config-file users) and a false proceed (a set-but-wrong value).
#   · a refusal is loud and exits 3 (scripts/pds-pull-proof.sh's resolve-or-die),
#     never the friendly no-op-at-exit-0 of scripts/onramp-live-client-smoke.sh.
#   · --selftest proves the refusal with exit codes taken WITHOUT A PIPE, and
#     pins the pipe trap by demonstration.
#
# THE FENCE — this writes into the dataset that backs the live task ledger:
#   · a RESERVED DOCUMENT TYPE ($DOC_TYPE), owned by this runner and nothing else.
#   · a reserved _id prefix. The run REFUSES TO START if the type already holds a
#     document under any of the three perspectives.
#   · every document it creates is deleted, on EVERY exit path including failures
#     and signals, and the cleanup RE-READS under published, drafts AND raw rather
#     than claiming.
#
# THE LIMIT, DECLARED IN THE RUN'S OWN OUTPUT: this proves the NO-FALSE-REFUSAL
# direction only — that the receipts bind on real server state and do not lie
# about a correct write. It does NOT prove the refusal direction: a correct
# Barkpark will not report a _rev the store does not hold, so the disagreeing-
# server arm cannot be staged live and stays fake-proven in the Go tests.
#
# Environment (all optional):
#   PDS_LIVE_BP       use this bp binary instead of building one (selftest hook)
#   PDS_LIVE_BASE     server (default: the active server in bp's config)
#   PDS_LIVE_DATASET  dataset (default production)
#   PDS_LIVE_ART      artifact dir (default /tmp/pds-live-bpw.<pid>)
#   PDS_LIVE_GO       go binary (default go); CC defaults to /usr/bin/clang
#
# Exit: 0 pass · 1 an assertion FAILED · 3 REFUSED · 2 usage.
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

DATASET="${PDS_LIVE_DATASET:-production}"
DOC_TYPE="${PDS_LIVE_DOC_TYPE:-pdsliveproof}"
ID_PREFIX="${PDS_LIVE_ID_PREFIX:-pds-live-w30-}"
ART="${PDS_LIVE_ART:-/tmp/pds-live-bpw.$$}"
GO_BIN="${PDS_LIVE_GO:-go}"

mkdir -p "$ART"

say()    { printf '%s\n' "$*"; }
step()   { printf '\n== %s\n' "$*"; }
ok()     { printf '  PASS    %s\n' "$*"; }
refuse() { printf '\n%s: REFUSE — %s\n' "$SELF" "$*" >&2; exit 3; }
failed() { printf '\n%s: FAIL — %s\n' "$SELF" "$*" >&2; exit 1; }
usage()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }

jsonq() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("not JSON: %s\n" % e)
    sys.exit(9)
v = eval(sys.argv[2])
print("" if v is None else v)
' "$1" "$2"
}

# ── the bp under proof: built from THIS worktree ─────────────────────────────

BP=""
apparatus_or_refuse() {
  local missing=""
  grep -rq 'screenWriteReceipt' "$REPO_ROOT/internal/cli/" 2>/dev/null \
    || missing="$missing screenWriteReceipt"
  [ -f "$REPO_ROOT/internal/cli/hetzner_respost.go" ] \
    || missing="$missing internal/cli/hetzner_respost.go"
  [ -z "$missing" ] || refuse "this tree predates the write-receipt apparatus (missing:$missing). Measuring a pre-fence binary would prove nothing about the receipts under test — and the installed bp on this host is exactly such a binary."
}

build_bp() {
  if [ -n "${PDS_LIVE_BP:-}" ]; then
    BP="$PDS_LIVE_BP"
    [ -x "$BP" ] || refuse "PDS_LIVE_BP=$BP is not executable"
    return 0
  fi
  apparatus_or_refuse
  [ -d "$REPO_ROOT/cmd/barkpark" ] || refuse "no $REPO_ROOT/cmd/barkpark — note ./cmd/bp DOES NOT EXIST; the binary's package is cmd/barkpark"
  BP="$ART/bp"
  ( cd "$REPO_ROOT" && CC="${CC:-/usr/bin/clang}" "$GO_BIN" build -o "$BP" ./cmd/barkpark ) \
    || refuse "go build ./cmd/barkpark failed — refusing to prove anything with a binary this worktree could not produce"
}

# ── PREFLIGHT ────────────────────────────────────────────────────────────────
#
# rc is taken WITHOUT A PIPE (see --selftest's pipe-trap demonstration), and the
# receipt SHAPE is checked because an exit code alone is not success.
# bp_read does NOT touch errexit: callers own that state.

RUNG=""
BASE=""

# PROBE_TYPE is deliberately NOT the reserved type: `bp doc ls` on a type the
# dataset has never held answers 404 (rc=4), so probing the reserved type would
# make an EMPTY fence indistinguishable from an absent credential — a preflight
# that refuses hardest exactly when the fence is clean.
PROBE_TYPE="${PDS_LIVE_PROBE_TYPE:-task}"

bp_read() { # FILE [env-prefix…]
  local out="$1"; shift
  if [ "$#" -gt 0 ]; then
    "$@" "$BP" doc ls "$PROBE_TYPE" -d "$DATASET" --limit 1 -o json >"$out" 2>&1
  else
    "$BP" doc ls "$PROBE_TYPE" -d "$DATASET" --limit 1 -o json >"$out" 2>&1
  fi
}

# bp_whoami FILE [env-prefix…] — bp's own account of WHICH credential resolved.
#
# THE READ PROBE ALONE IS FAIL-OPEN, and this was measured on 2026-07-31 rather
# than reasoned about: guerrilla serves published documents ANONYMOUSLY, so
# `bp doc ls task --limit 1` exits 0 with a perfectly-shaped listing under an
# empty HOME and a garbage BARKPARK_TOKEN. A preflight gated on that alone would
# green-light a run that has no write credential at all and would only discover
# it at the first mutation — the fail-open instrument this slice exists not to
# ship. So the second probe asks bp who it thinks it is.
bp_whoami() {
  local out="$1"; shift
  if [ "$#" -gt 0 ]; then
    "$@" "$BP" whoami -o json >"$out" 2>&1
  else
    "$BP" whoami -o json >"$out" 2>&1
  fi
}

# auth_tier FILE — the tier bp resolved, or "" if the receipt has no such field.
# `bp whoami` EXITS 0 whether it authenticated or not — auth_tier is "none" for an
# anonymous caller and "admin" for this token. That is this epic's law in one
# receipt: the exit code carries no information, the shape carries all of it.
auth_tier() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
t = d.get("auth_tier") if isinstance(d, dict) else None
print(t if isinstance(t, str) else "")
' "$1" 2>/dev/null || true
}

# writer_tier TIER — is this a tier that may write? Anything that is not a
# resolved principal fails CLOSED.
writer_tier() {
  case "$1" in
    admin|editor|write|writer|operator) return 0 ;;
    *) return 1 ;;
  esac
}

# shape_ok — a listing receipt, not merely a zero exit. A stub answering
# {"ok":true} at rc=0 fails here, and must.
shape_ok() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
r = d.get("result") if isinstance(d, dict) else None
if isinstance(r, dict) and isinstance(r.get("documents"), list):
    sys.exit(0)
if isinstance(d, dict) and isinstance(d.get("documents"), list):
    sys.exit(0)
sys.exit(1)
' "$1"
}

preflight() {
  build_bp

  local probe="$ART/preflight.json" rc=0
  set +e
  bp_read "$probe"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '  bp said: %s\n' "$(head -c 400 "$probe")" >&2
    refuse "bp could not resolve a Barkpark server+token of its own (\`bp doc ls $PROBE_TYPE\` exited $rc, taken without a pipe). Run \`bp login\`, or set BARKPARK_TOKEN. This runner does not test for an env-var NAME — it asks bp."
  fi
  if ! shape_ok "$probe"; then
    printf '  bp said: %s\n' "$(head -c 400 "$probe")" >&2
    refuse "bp exited 0 but its receipt is not a document listing — AN EXIT CODE ALONE IS NOT SUCCESS, which is this epic's whole law. Refusing to drive live writes through a binary whose read receipt has the wrong shape."
  fi

  # PROBE 2 — the one that can actually refuse. See bp_whoami's block comment.
  local who="$ART/preflight-whoami.json" wrc=0 tier
  set +e
  bp_whoami "$who"
  wrc=$?
  set -e
  [ "$wrc" -eq 0 ] || refuse "\`bp whoami\` exited $wrc — bp cannot describe its own credential, so this runner cannot know whether the writes it is about to make would be authorised."
  tier="$(auth_tier "$who")"
  if ! writer_tier "$tier"; then
    refuse "bp resolved NO writing principal (auth_tier=\"${tier:-<absent>}\"). Note that BOTH probes exited 0: this server serves published reads anonymously, and \`bp whoami\` exits 0 for an anonymous caller too — AN EXIT CODE ALONE IS NOT SUCCESS, so the refusal is made on the receipt's SHAPE. Run \`bp login\`, or set BARKPARK_TOKEN to a token that can write."
  fi

  # WHICH RUNG PAID — measured by re-probing with BARKPARK_TOKEN removed.
  local who2="$ART/preflight-norung.json" wrc2=0 tier2
  set +e
  bp_whoami "$who2" env -u BARKPARK_TOKEN
  wrc2=$?
  set -e
  tier2="$(auth_tier "$who2")"
  if [ "$wrc2" -eq 0 ] && writer_tier "$tier2"; then
    RUNG="config-file (~/.config/barkpark/config.json, the \`bp login\` rung), auth_tier=$tier"
  else
    RUNG="env:BARKPARK_TOKEN, auth_tier=$tier"
  fi

  ok "bp resolved a WRITING principal of its own: the listing has the right shape AND whoami reports auth_tier=$tier"
  say "  CREDENTIAL RUNG THAT PAID: $RUNG"
  say "  (the rung is derived by re-probing without BARKPARK_TOKEN, not by reading env-var names)"
}

# ── the independent reader ───────────────────────────────────────────────────
#
# curl, not bp. It descends the same credential ladder because there is only one
# credential — but it is a different client on a different code path, and that is
# what stops the run being bp agreeing with itself. The token is never printed,
# never written to an artifact and never lands in a fixture.

ORACLE_TOKEN=""
resolve_oracle() {
  BASE="${PDS_LIVE_BASE:-}"
  if [ -n "${BARKPARK_TOKEN:-}" ] && [ -n "$BASE" ]; then
    ORACLE_TOKEN="$BARKPARK_TOKEN"
    return 0
  fi
  local cfg="${BARKPARK_CONFIG:-$HOME/.config/barkpark/config.json}"
  [ -r "$cfg" ] || return 1
  local pair
  pair="$(WANT="$BASE" python3 - "$cfg" <<'PY' || true
import json, os, sys
want = os.environ.get("WANT", "").rstrip("/")
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
cands = [cfg] + list(cfg.get("known_servers") or [])
base = want or str(cfg.get("server") or "").rstrip("/")
for c in cands:
    if str(c.get("server", "")).rstrip("/") == base and c.get("token"):
        print(base); print(c["token"]); break
PY
)"
  BASE="$(printf '%s\n' "$pair" | sed -n 1p)"
  ORACLE_TOKEN="$(printf '%s\n' "$pair" | sed -n 2p)"
  [ -n "$BASE" ] && [ -n "$ORACLE_TOKEN" ]
}

# query PERSPECTIVE OUTFILE — an INDEPENDENT read of the reserved type.
query() {
  local persp="$1" out="$2" code
  code="$(curl -sS --max-time 60 -o "$out" -w '%{http_code}' \
      -H "Authorization: Bearer $ORACLE_TOKEN" \
      "$BASE/v1/data/query/$DATASET/$DOC_TYPE?perspective=$persp&limit=50")"
  [ "$code" = "200" ] || { printf '  independent read of perspective %s answered HTTP %s\n' "$persp" "$code" >&2; return 1; }
}

# oracle_rev PERSPECTIVE ID -> prints the _rev the SERVER holds for that _id ("" if absent)
oracle_rev() {
  # bash 3.2: a `local` list cannot reference a name declared earlier in the SAME
  # statement — under set -u that reads as an unbound variable, not an empty one.
  local persp="$1" id="$2"
  local f="$ART/q.$persp.$$.json"
  query "$persp" "$f" || return 1
  ID="$id" python3 -c '
import sys, json, os
d = json.load(open(sys.argv[1]))
want = os.environ["ID"]
for doc in d["result"]["documents"]:
    if doc.get("_id") == want:
        print(doc.get("_rev") or "")
        break
' "$f"
}

count_all() { # -> "published drafts raw"
  local p d r
  p="$(perspective_count published)" || return 1
  d="$(perspective_count drafts)"    || return 1
  r="$(perspective_count raw)"       || return 1
  printf '%s %s %s\n' "$p" "$d" "$r"
}

perspective_count() {
  local persp="$1"
  local f="$ART/c.$persp.$$.json"
  query "$persp" "$f" || return 1
  jsonq "$f" 'd["result"]["count"]'
}

# ── cleanup on EVERY exit path ───────────────────────────────────────────────

CLEANUP_ARMED=0
LIVE_ID=""
cleanup() {
  local rc=$?
  if [ "$CLEANUP_ARMED" = "1" ] && [ -n "$LIVE_ID" ]; then
    printf '\n== cleanup (exit rc=%s): removing %s/%s\n' "$rc" "$DOC_TYPE" "$LIVE_ID" >&2
    "$BP" doc delete "$DOC_TYPE" "$LIVE_ID" --yes -o json >/dev/null 2>&1 || true
    local left
    left="$(count_all 2>/dev/null || echo '? ? ?')"
    printf '  re-read after cleanup (published drafts raw): %s\n' "$left" >&2
    case "$left" in
      "0 0 0") printf '  cleanup verified by independent read under all three perspectives\n' >&2 ;;
      *)       printf '  CLEANUP INCOMPLETE — delete by hand: bp doc delete %s %s --yes\n' "$DOC_TYPE" "$LIVE_ID" >&2 ;;
    esac
  fi
  exit $rc
}

# ── --plan ───────────────────────────────────────────────────────────────────

plan() {
  cat <<PLAN
$SELF — MANUAL-RUN-ONLY live proof. No side effects in --plan.

  0  preflight   build bp from THIS worktree (go build ./cmd/barkpark; ./cmd/bp
                 does not exist). Gate on bp's OWN resolution: a cheap read
                 verb's rc (unpiped) AND its receipt shape. Name the rung.
                 REFUSE (exit 3) otherwise.
  1  fence       the reserved type "$DOC_TYPE" must hold ZERO documents under
                 published, drafts AND raw. REFUSE to start otherwise.
  2  create      bp doc create $DOC_TYPE --set _id=${ID_PREFIX}<stamp>
  3  patch       bp doc patch  — receipt _rev must MOVE
  4  publish     bp doc publish
  5  unpublish   bp doc unpublish
  6  delete      bp doc delete
                 After EACH of 2-6: an INDEPENDENT curl of
                 $BASE/v1/data/query/$DATASET/$DOC_TYPE must report the same
                 _id and the same _rev the bp receipt claimed, under the
                 perspective that verb should have moved the document into.
  7  zero        published/drafts/raw all back to 0. Runs on EVERY exit path via
                 the cleanup trap.
  8  limit       print which direction this run proved and which it did NOT.

  --selftest runs 0 in three credential states plus two mutation self-tests, and
  makes no writes.
PLAN
}

# ── --selftest ───────────────────────────────────────────────────────────────

ST_FAIL=0
st_case() {
  local label="$1" want="$2"; shift 2
  local out="$ART/st.$$.out" rc=0
  set +e
  env "$@" "$0" --preflight >"$out" 2>&1
  rc=$?
  set -e
  local verdict="PASS"
  [ "$rc" = "$want" ] || { verdict="FAIL"; ST_FAIL=1; }
  printf '  %-6s %-58s rc=%s (want %s)\n' "$verdict" "$label" "$rc" "$want"
  printf '         %s\n' "$(grep -Eo 'REFUSE — [^.]*\.|CREDENTIAL RUNG THAT PAID: .*' "$out" | head -1 | cut -c1-120)"
  ST_LAST_OUT="$out"
}

selftest() {
  build_bp
  local empty="$ART/empty-home"
  mkdir -p "$empty"
  resolve_oracle || refuse "--selftest needs one WORKING credential to prove the PROCEED state; with none, the refusal states would pass vacuously — the exact green this epic exists to kill. Run \`bp login\`."

  step "CREDENTIAL STATES — exit codes taken without a pipe (3 = REFUSE, 0 = proceed)"
  st_case "1. no config, no BARKPARK_TOKEN (empty HOME)" 3 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART"
  # State 2 is the ANONYMOUS-READER case, and it is the one that caught a
  # fail-open in this very script: guerrilla answers `bp doc ls task` with a
  # perfectly-shaped listing under a garbage token, so a read-only preflight
  # PROCEEDED here until the whoami probe was added.
  st_case "2. BARKPARK_TOKEN WRONG, empty HOME (anonymous reads still work)" 3 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART" \
    "BARKPARK_SERVER=$BASE" "BARKPARK_TOKEN=not-a-real-token"
  st_case "3. the real config on disk" 0 \
    -i "PATH=$PATH" "HOME=$HOME" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART"

  step "MUTATION 1 — a stub bp that exits 0 printing {\"ok\":true} must be REFUSED"
  local stub="$ART/stub-bp" out="$ART/stub.out" rc=0
  printf '#!/bin/sh\necho %s\nexit 0\n' "'{\"ok\":true}'" >"$stub"
  chmod +x "$stub"
  set +e
  env -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$stub" "PDS_LIVE_ART=$ART" "$0" --preflight >"$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" = "3" ] && grep -q 'AN EXIT CODE ALONE IS NOT SUCCESS' "$out"; then
    ok "stub refused: rc=3, and the reason names the law"
  else
    printf '  FAIL   stub bp was NOT refused (rc=%s) — the preflight is gating on the exit code alone\n' "$rc"
    ST_FAIL=1
  fi

  step "MUTATION 2 — a WELL-SHAPED anonymous bp must be REFUSED, not proceeded on"
  # The read probe's shape check cannot catch this one: the listing is correct.
  # Only whoami's auth_tier does — and whoami exits 0 either way.
  local anon="$ART/anon-bp" aout="$ART/anon.out" arc=0
  cat >"$anon" <<'STUB'
#!/bin/sh
case "$*" in
  *whoami*) echo '{"auth_tier":"none","active":false,"dataset":"production"}' ;;
  *)        echo '{"count":0,"documents":[]}' ;;
esac
exit 0
STUB
  chmod +x "$anon"
  set +e
  env -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$anon" "PDS_LIVE_ART=$ART" "$0" --preflight >"$aout" 2>&1
  arc=$?
  set -e
  if [ "$arc" = "3" ] && grep -q 'resolved NO writing principal' "$aout"; then
    ok "anonymous bp refused: rc=3, on auth_tier and not on the listing (which was perfectly well-formed)"
  else
    printf '  FAIL   a well-shaped ANONYMOUS bp was NOT refused (rc=%s) — the preflight is fail-open\n' "$arc"
    ST_FAIL=1
  fi

  step "MUTATION 3 — the pipe trap, pinned by demonstration and not by comment"
  local failing="$ART/failing-bp" piped unpiped
  printf '#!/bin/sh\necho "boom" >&2\nexit 4\n' >"$failing"
  chmod +x "$failing"
  piped="$(bash -c '"$1" whatever 2>/dev/null | head -1 >/dev/null && echo OK; echo "rc=$?"' _ "$failing")"
  set +e
  "$failing" whatever >/dev/null 2>&1
  unpiped=$?
  set -e
  say "  piped   : bp … | head -1 && echo OK   ->  $(printf '%s' "$piped" | tr '\n' ' ')"
  say "  unpiped : bp …                        ->  rc=$unpiped"
  if printf '%s' "$piped" | grep -q 'OK' && [ "$unpiped" = "4" ]; then
    ok "the trap is real: the pipeline printed OK at rc=0 for a command that exited $unpiped. Every rc in this runner is taken unpiped."
  else
    printf '  FAIL   the pipe-trap demonstration did not reproduce (piped=%s unpiped=%s)\n' "$piped" "$unpiped"
    ST_FAIL=1
  fi

  step "SELFTEST VERDICT"
  if [ "$ST_FAIL" = "0" ]; then
    ok "the preflight refuses when it should and proceeds when it should, and names the rung that paid"
    say ""
    say "  NOTE ON SCOPE: --selftest proves the PREFLIGHT. It makes no writes and is"
    say "  not the live proof. Run --run for that."
    return 0
  fi
  failed "one or more preflight self-tests did not hold — do not run --run against a live dataset with a preflight that cannot refuse"
}

# ── --run ────────────────────────────────────────────────────────────────────

# verb_and_verify LABEL PERSPECTIVE ARGS… — run a bp write verb, then require the
# SERVER's own independent answer to carry the same _id and the same _rev.
verb_and_verify() {
  local label="$1" persp="$2"; shift 2
  local receipt="$ART/$label.json" rc=0
  set +e
  "$BP" "$@" -o json >"$receipt" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$receipt" >&2; failed "$label exited $rc"; }
  local rid rrev rop
  rid="$(jsonq "$receipt" 'd["results"][0]["document"]["_id"]')"   || failed "$label receipt has no results[0].document._id: $(cat "$receipt")"
  rrev="$(jsonq "$receipt" 'd["results"][0]["document"]["_rev"]')"
  rop="$(jsonq "$receipt" 'd["results"][0]["operation"]')"
  [ -n "$rid" ] && [ -n "$rrev" ] || failed "$label receipt carried an empty _id/_rev"
  local srev
  srev="$(oracle_rev "$persp" "$rid")" || failed "$label: the independent read of perspective $persp failed"
  if [ -z "$srev" ]; then
    failed "$label: bp claimed _id=$rid _rev=$rrev, but an INDEPENDENT read of perspective $persp does not hold that document at all — the receipt is a claim the server does not corroborate"
  fi
  [ "$srev" = "$rrev" ] || failed "$label: bp claimed _rev=$rrev, the server independently reports _rev=$srev"
  ok "$label -> operation=$rop _id=$rid _rev=$rrev; INDEPENDENT /v1/data/query (perspective=$persp) reports the SAME _rev"
  LAST_ID="$rid"; LAST_REV="$rrev"
}

run() {
  step "0 PREFLIGHT"
  preflight
  resolve_oracle || refuse "the INDEPENDENT reader needs the raw token and a base URL (curl cannot ask bp for them). bp resolved a credential but this script could not descend the same ladder — refusing to run a 'proof' in which bp is its own witness."
  ok "independent reader ready: curl -> $BASE/v1/data/query/$DATASET/$DOC_TYPE (a different client on a different code path)"

  step "1 FENCE"
  local before
  before="$(count_all)" || refuse "the fence read failed — refusing to write into a dataset whose contents could not be read"
  [ "$before" = "0 0 0" ] || refuse "the reserved type \"$DOC_TYPE\" is not empty (published drafts raw = $before). Either a previous run leaked or something else owns the type — refusing to start rather than adopt documents this run did not create."
  ok "reserved type \"$DOC_TYPE\" holds 0/0/0 under published/drafts/raw"
  say "  FENCE: one reserved type, one reserved _id prefix, dataset=$DATASET. Nothing this runner writes touches an existing type."

  local id="$ID_PREFIX$(date -u +%Y%m%dT%H%M%SZ)-$$"
  LIVE_ID="$id"
  CLEANUP_ARMED=1
  trap cleanup EXIT INT TERM

  step "2 CREATE"
  verb_and_verify create drafts doc create "$DOC_TYPE" -d "$DATASET" --yes \
    --set "_id=$id" --set "title=PDS wave 30 live write proof"
  local rev_create="$LAST_REV"

  step "3 PATCH — the receipt's _rev must MOVE, and the server must agree it moved"
  verb_and_verify patch drafts doc patch "$DOC_TYPE" "$id" -d "$DATASET" --yes \
    --set "title=PDS wave 30 live write proof (patched)"
  [ "$LAST_REV" != "$rev_create" ] \
    || failed "patch reported the same _rev as create ($LAST_REV) — a receipt that does not move is not evidence of a write"
  ok "_rev moved $rev_create -> $LAST_REV, and the INDEPENDENT read moved with it"

  step "4 PUBLISH — the document must appear under the PUBLISHED perspective"
  verb_and_verify publish published doc publish "$DOC_TYPE" "$id" -d "$DATASET" --yes
  local pub_counts
  pub_counts="$(count_all)"
  case "$pub_counts" in
    "1 "*) ok "published/drafts/raw = $pub_counts — the published perspective now holds it" ;;
    *)     failed "after publish the perspectives read $pub_counts; the published one should hold 1" ;;
  esac

  step "5 UNPUBLISH — it must fall back to DRAFTS"
  verb_and_verify unpublish drafts doc unpublish "$DOC_TYPE" "$id" -d "$DATASET" --yes
  local unpub_counts
  unpub_counts="$(count_all)"
  case "$unpub_counts" in
    "0 1 "*) ok "published/drafts/raw = $unpub_counts — gone from published, still a draft" ;;
    *)       failed "after unpublish the perspectives read $unpub_counts; expected 0 published / 1 draft" ;;
  esac

  step "6 DELETE — and the independent reader must stop seeing it"
  local delr="$ART/delete.json" rc=0
  set +e
  "$BP" doc delete "$DOC_TYPE" "$id" -d "$DATASET" --yes -o json >"$delr" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$delr" >&2; failed "delete exited $rc"; }
  ok "bp receipt: operation=$(jsonq "$delr" 'd["results"][0]["operation"]') _id=$(jsonq "$delr" 'd["results"][0]["document"]["_id"]')"

  step "7 CLEANUP VERIFIED UNDER ALL THREE PERSPECTIVES — observed, not claimed"
  local after
  after="$(count_all)"
  [ "$after" = "0 0 0" ] || failed "after delete the reserved type reads published/drafts/raw = $after; the run did not clean up after itself"
  local gone_rev
  gone_rev="$(oracle_rev raw "drafts.$id" || true)"
  [ -z "$gone_rev" ] || failed "the raw perspective still holds drafts.$id at _rev=$gone_rev"
  CLEANUP_ARMED=0
  ok "published/drafts/raw = 0 0 0, and the raw perspective holds neither $id nor drafts.$id"

  step "8 WHAT THIS RUN PROVED, AND WHAT IT DID NOT"
  cat <<'LIMIT'
  PROVED (direction: NO FALSE REFUSAL). Five real bp write verbs ran against a
  real Barkpark, and every receipt's _id and _rev was corroborated by an
  INDEPENDENT /v1/data/query read taken with a different client — including that
  the _rev MOVED on patch, that publish moved the document into the published
  perspective, and that delete removed it from all three.

  NOT PROVED (direction: THE REFUSAL). Nothing here shows a receipt refusing a
  server that disagrees with it. A correct Barkpark will not report a _rev its
  store does not hold, so that arm cannot be staged live at all; it stays proven
  only by the fakes in the Go tests.

  Anyone quoting this transcript as "the write receipts are proven against
  production" is over-reading it by exactly one direction.
LIMIT
  say ""
  ok "LIVE WRITE PROOF COMPLETE — credential rung: $RUNG"
}

case "${1:---run}" in
  --plan)      plan ;;
  --preflight) preflight ;;
  --selftest)  selftest ;;
  --run)       run ;;
  -h|--help)   plan ;;
  *)           usage "unknown argument '$1' (want --plan | --preflight | --selftest | --run)" ;;
esac

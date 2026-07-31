#!/usr/bin/env bash
#
# pds-live-hetzner-placement-group.sh — THE PDS EPIC'S FIRST L1.
#
#   MANUAL-RUN-ONLY. This script is NOT a CI tenant. It is deliberately absent
#   from .github/workflows/shell-harnesses.yml, whose tenants are required to be
#   token-free and network-free. This one is neither: it spends a real Hetzner
#   Cloud credential and makes real writes against api.hetzner.cloud.
#
#   scripts/pds-live-hetzner-placement-group.sh --plan       print the ladder, no side effects
#   scripts/pds-live-hetzner-placement-group.sh --preflight  resolve-or-die; name the rung
#   scripts/pds-live-hetzner-placement-group.sh --selftest   prove the preflight can REFUSE
#   scripts/pds-live-hetzner-placement-group.sh --run        the live round trip
#
# WHY THIS EXISTS
# ---------------
# Twenty-nine waves of post-conditions, fences and receipts, and not one of them
# had been driven against a real server: every proof was a fake, a fixture or a
# static read. This runner is the epic's first L1 — a Barkpark verb making a real
# round trip, its receipt compared against the same API's own SECOND, INDEPENDENT
# answer taken with a different client (curl), not against the fixture that
# generated it.
#
# THE ARTIFACT IS A RUNNER, NOT A TRANSCRIPT, because a proof that cannot re-run
# is a ceremony. A transcript is what this prints; the residue it leaves in the
# repo is internal/cli/testdata/pds_live_hetzner_*.json — real harvested bytes
# that ride CI forever after the credential goes away.
#
# THE PREAMBLE IS THE SLICE
# -------------------------
# The whole value of a live proof rests on a preflight that is ABLE TO REFUSE. A
# runner that degrades to a quiet pass when the credential is missing is one more
# fail-open instrument, and this epic exists to remove those. So:
#
#   · The preflight gates on bp's OWN RESOLUTION — a cheap read verb's exit code
#     AND its receipt SHAPE — never on the presence of an env-var name.
#     internal/hetzner/client.go's ResolveToken has a THIRD rung
#     (TokenFromCLIContext, reading $HCLOUD_CONFIG else <UserConfigDir>/hcloud/
#     cli.toml) that authenticates with BOTH env vars unset. Testing for
#     "$HCLOUD_TOKEN is set" would therefore refuse a perfectly credentialed run
#     on Linux/CI, and — worse — a test for "some token-ish env var is set" would
#     PROCEED on HETZNER_API_TOKEN, a name bp never reads.
#     Measured on macOS 2026-07-31: os.UserConfigDir() resolves to
#     ~/Library/Application Support, so the bare-cli.toml rung is accidentally
#     DEAD there and LIVE wherever UserConfigDir is ~/.config. The preflight does
#     not care which is true today; it asks bp.
#   · A refusal is loud and exits 3 (the resolve-or-die of scripts/pds-pull-proof.sh),
#     explicitly NOT the shape of scripts/onramp-live-client-smoke.sh, which
#     prints a friendly no-op and exits 0. There is no fourth outcome and no
#     quiet no-op here: PASS, REFUSE, FAIL.
#     A CLEANUP THAT COULD NOT VERIFY ITSELF IS A FAIL, not a fourth outcome and
#     not a pass with a warning: the run exits NON-ZERO even if every step passed,
#     because "I could not read the project" is not "the project is clean".
#   · EVERY read of the project — the fence's, the cleanup's, the final one — is
#     gated on its receipt SHAPE as well as its exit code. A read that did not
#     answer is never spelled as an empty project.
#   · --selftest proves the refusal in FOUR credential states plus one state per
#     degraded read shape, with every exit code taken WITHOUT A PIPE, and
#     additionally pins the pipe trap itself.
#
# THE FENCE — this project holds FIVE RUNNING PRODUCTION SERVERS, including
# barkpark-cms (89.167.28.206) and guerrilla (157.180.90.121):
#
#   · PLACEMENT GROUPS ONLY. Never a server, network, volume, load balancer,
#     floating IP, certificate or zone — nothing that routes or holds data. A
#     placement group is free, inert and attaches to nothing.
#   · A RESERVED NAME PREFIX ($PG_PREFIX). The run REFUSES TO START if anything
#     in the project already matches it.
#   · CLEANUP ON EVERY EXIT PATH, including failures and signals, and the cleanup
#     itself re-reads: the run does not claim a clean project, it observes one.
#
# THE LIMIT, DECLARED IN THE RUN'S OWN OUTPUT (not in a paragraph a reader may
# scroll past): a live run against a CORRECT API proves exactly one direction —
# NO FALSE REFUSAL, that the predicate binds on real bytes and does not red an
# honest verb. It does NOT prove the refusal direction: a real Hetzner will not
# keep handing back a resource it has deleted, so the lying-API arm stays
# fake-proven in hetzner_respost_test.go. Nothing here may be read as "the
# destroy apparatus is proven against production".
#
# Environment (all optional):
#   PDS_LIVE_BP        use this bp binary instead of building one (selftest hook)
#   PDS_LIVE_GO        go binary (default: go); CC defaults to /usr/bin/clang
#   PDS_LIVE_ART       artifact dir (default: /tmp/pds-live-w30.<pid>)
#   PDS_LIVE_HARVEST   dir to write harvested fixture bytes into (default: none)
#   HCLOUD_TOKEN / HCLOUD_CONFIG / HCLOUD_CONTEXT — read by bp, never by name here
#
# Exit: 0 every selected step passed AND the cleanup verified itself by re-read ·
#       1 an assertion FAILED, or the cleanup could not be verified · 3 REFUSED
#       (environment/credential/apparatus/unreadable project) · 2 usage.
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

HZ_API="${PDS_LIVE_HZ_API:-https://api.hetzner.cloud/v1}"
PG_PREFIX="${PDS_LIVE_PG_PREFIX:-pds-live-w30-}"
ART="${PDS_LIVE_ART:-/tmp/pds-live-w30.$$}"
GO_BIN="${PDS_LIVE_GO:-go}"

mkdir -p "$ART"

# ── vocabulary ───────────────────────────────────────────────────────────────
#
# Three outcomes, and the refusal is a first-class one. "REFUSE" is the word; a
# quiet no-op has no spelling in this script on purpose.

say()    { printf '%s\n' "$*"; }
step()   { printf '\n== %s\n' "$*"; }
ok()     { printf '  PASS    %s\n' "$*"; }
refuse() { printf '\n%s: REFUSE — %s\n' "$SELF" "$*" >&2; exit 3; }
failed() { printf '\n%s: FAIL — %s\n' "$SELF" "$*" >&2; exit 1; }
usage()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }

# jsonq FILE EXPR — evaluate a python expression over the parsed body `d`.
# Exits non-zero if the body is not JSON at all, which is itself an assertion.
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

# ── the bp under proof ───────────────────────────────────────────────────────
#
# BUILT FROM THIS WORKTREE, never the installed binary. /Users/pelle/.local/bin/bp
# was f59aaf717 on 2026-07-31 and contains neither internal/cli/hetzner_respost.go
# nor screenWriteReceipt — a live run through it would exercise pre-fence code and
# prove nothing about the apparatus this epic built. So the runner refuses a tree
# that predates the apparatus rather than measuring the wrong program.

BP=""

# The check is on the SYMBOLS, searched across internal/cli — never on one file
# path holding one spelling. The first draft grepped the literal `func
# hzResDestroyed` inside internal/cli/hetzner_respost.go and survived only by
# accident (hzResDestroyedDeclared shares the prefix). Two renames have since
# happened around it: hzResObserved — the post-read this epic now prefers,
# because hcloud-go v2.44 swallows a 404 into (nil, resp, nil) — landed in a
# DIFFERENT file (hetzner_respost_mutation.go). A path-pinned, spelling-pinned
# check turns any later rename into a loud REFUSE that bricks BOTH L1 runners
# and that nobody connects back to the rename. So: either post-read symbol,
# anywhere under internal/cli, satisfies "this tree has the apparatus".
apparatus_or_refuse() {
  local missing=""
  grep -rEq 'func hzRes(Destroyed|Observed)' "$REPO_ROOT/internal/cli/" 2>/dev/null \
    || missing="$missing hzResDestroyed-or-hzResObserved"
  grep -rq 'screenWriteReceipt' "$REPO_ROOT/internal/cli/" 2>/dev/null \
    || missing="$missing screenWriteReceipt"
  [ -z "$missing" ] || refuse "this tree predates the destroy apparatus (missing:$missing). A live run through pre-fence code proves nothing about the receipt under test."
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

# ── PREFLIGHT: gate on bp's OWN resolution, never on an env-var name ──────────
#
# rc is captured WITHOUT A PIPE. `bp … | head -1 && echo OK` prints OK at rc=0 on
# a command that failed — the pipeline's status is head's. --selftest pins that
# trap with a live demonstration rather than trusting this comment.

RUNG=""

# hz_read FILE [env-prefix…] — the cheap read verb, rc returned, never piped.
#
# It does NOT touch errexit. An early draft restored `set -e` inside the function
# and then `return $rc`, which under errexit terminates the caller mid-preflight —
# the probe that was MEANT to answer "which rung paid" instead killed the run with
# a silent exit 3. Callers own the errexit state; this function only reports.
hz_read() {
  local out="$1"; shift
  if [ "$#" -gt 0 ]; then
    "$@" "$BP" cloud hetzner placement-group list -o json >"$out" 2>&1
  else
    "$BP" cloud hetzner placement-group list -o json >"$out" 2>&1
  fi
}

# shape_ok FILE — the receipt SHAPE, which is the half an exit code cannot carry.
# A stub answering {"ok":true} at rc=0 fails here, and must.
shape_ok() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and isinstance(d.get("placement_groups"), list) else 1)
' "$1"
}

preflight() {
  build_bp

  local probe="$ART/preflight.json" rc=0
  set +e
  hz_read "$probe"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '  bp said: %s\n' "$(head -c 400 "$probe")" >&2
    refuse "bp could not resolve a Hetzner credential of its own (\`bp cloud hetzner placement-group list\` exited $rc, taken without a pipe). Set HCLOUD_TOKEN, or point HCLOUD_CONFIG at an hcloud cli.toml with an active context. This runner does not test for an env-var NAME — it asks bp."
  fi
  if ! shape_ok "$probe"; then
    printf '  bp said: %s\n' "$(head -c 400 "$probe")" >&2
    refuse "bp exited 0 but its receipt is not a placement-group listing — AN EXIT CODE ALONE IS NOT SUCCESS, which is this epic's whole law. Refusing to drive a live write through a binary whose read receipt has the wrong shape."
  fi

  # WHICH RUNG PAID — measured, not guessed. Re-probe with HCLOUD_TOKEN removed:
  # if that still resolves, the on-disk hcloud CLI context is what authenticated.
  local probe2="$ART/preflight-norung2.json" rc2=0
  set +e
  hz_read "$probe2" env -u HCLOUD_TOKEN
  rc2=$?
  set -e
  if [ "$rc2" -eq 0 ] && shape_ok "$probe2"; then
    RUNG="hcloud-cli-context (\$HCLOUD_CONFIG else <UserConfigDir>/hcloud/cli.toml)"
  else
    RUNG="env:HCLOUD_TOKEN"
  fi

  ok "bp resolved a credential of its own: rc=0 AND the receipt is a placement_groups list"
  say "  CREDENTIAL RUNG THAT PAID: $RUNG"
  say "  (the rung is derived by re-probing without HCLOUD_TOKEN, not by reading env-var names)"
}

# ── the independent oracle ───────────────────────────────────────────────────
#
# A second client, the same API. This is the only thing that makes the run a
# proof rather than a screenshot of bp agreeing with itself. It needs the raw
# token, so it descends the SAME ladder bp does — and the value is never printed,
# never written to an artifact, and never lands in a fixture.

# default_hcloud_config — where Go's os.UserConfigDir() puts hcloud's cli.toml on
# THIS platform. It is ONE function because two spellings of it drift: an earlier
# draft hard-coded ~/.config here and Darwin's ~/Library/Application Support in
# the oracle, so --selftest state 4 looked for the file in a place macOS never
# writes it and reported the third rung UNPROVEN on a host that has it.
default_hcloud_config() {
  if [ "$(uname -s)" = "Darwin" ]; then
    printf '%s\n' "$HOME/Library/Application Support/hcloud/cli.toml"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/hcloud/cli.toml"
  fi
}

ORACLE_TOKEN=""
resolve_oracle_token() {
  if [ -n "${HCLOUD_TOKEN:-}" ]; then
    ORACLE_TOKEN="$HCLOUD_TOKEN"
    return 0
  fi
  local cfg="${HCLOUD_CONFIG:-}"
  [ -n "$cfg" ] || cfg="$(default_hcloud_config)"
  [ -r "$cfg" ] || return 1
  ORACLE_TOKEN="$(CTX="${HCLOUD_CONTEXT:-}" python3 - "$cfg" <<'PY' || true
import os, re, sys
active, want = "", os.environ.get("CTX", "").strip()
ctxs, cur, section = [], {}, ""
for raw in open(sys.argv[1]):
    line = raw.strip()
    if line.startswith("[[") and line.endswith("]]"):
        if cur: ctxs.append(cur)
        section = line[2:-2].strip(); cur = {}
        continue
    if line.startswith("[") and line.endswith("]"):
        if cur: ctxs.append(cur); cur = {}
        section = line[1:-1].strip()
        continue
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"(.*)"\s*$', line)
    if not m: continue
    k, v = m.group(1), m.group(2)
    if section == "" and k == "active_context": active = v
    elif section == "contexts": cur[k] = v
if cur: ctxs.append(cur)
want = want or active
for c in ctxs:
    if c.get("name") == want and c.get("token"):
        print(c["token"]); break
PY
)"
  [ -n "$ORACLE_TOKEN" ]
}

# oracle GET-PATH OUTFILE -> prints "<http_code> <content_type> <bytes>"
oracle() {
  local path="$1" body="$2" meta
  meta="$(curl -sS --max-time 60 -o "$body" \
            -w '%{http_code} %{content_type} %{size_download}' \
            -H "Authorization: Bearer $ORACLE_TOKEN" "$HZ_API$path")"
  printf '%s\n' "$meta"
}

# ── the two project reads: SHAPE-CHECKED, and a failed read is not an answer ──
#
# EVERY read in this runner passes through shape_ok, not just the preflight's.
# Until wave 31 it was applied at exactly two places (both inside preflight) and
# the two functions BELOW — which the fence, the cleanup and the final assertion
# all judge the project by — checked only hz_read's exit code. Consequences,
# reproduced with a stub bp before this was written:
#   · the FENCE failed closed on rc!=0 and on non-JSON but fail-OPEN on valid
#     JSON without a placement_groups key — `d.get(...) or []` yields no names,
#     so it printed the all-clear and would have CREATED in the live project;
#   · cleanup printed "cleanup verified by re-read: zero groups match …" in all
#     three degraded shapes while a planted orphan survived, and exited 0.
# The distinction the return code now carries: 1 = the read FAILED, 2 = the read
# succeeded but its receipt is NOT a placement-group listing. Both mean the same
# thing to a caller — YOU DO NOT KNOW WHAT IS IN THE PROJECT — and neither may
# ever be read as "empty".

# reserved_names — names in the live project matching the reserved prefix.
# rc 0 = answered (the names, possibly none) · 1 = read failed · 2 = wrong shape.
reserved_names() {
  local f="$ART/list.$$.json"
  hz_read "$f" || return 1
  shape_ok "$f" || return 2
  PREFIX="$PG_PREFIX" python3 -c '
import sys, json, os
d = json.load(open(sys.argv[1]))
p = os.environ["PREFIX"]
for g in d.get("placement_groups") or []:
    n = str(g.get("name") or "")
    if n.startswith(p):
        print(n)
' "$f"
}

# pg_count — same contract, same three return codes.
pg_count() {
  local f="$ART/count.$$.json"
  hz_read "$f" || return 1
  shape_ok "$f" || return 2
  jsonq "$f" 'len(d.get("placement_groups") or [])'
}

# read_failure_reason RC — the sentence that names WHICH half went wrong.
read_failure_reason() {
  case "$1" in
    2) printf '%s' "bp exited 0 but its receipt is not a placement_groups listing — AN EXIT CODE ALONE IS NOT SUCCESS" ;;
    *) printf '%s' "the \`bp cloud hetzner placement-group list\` read exited non-zero (see the artifact dir $ART for what bp said)" ;;
  esac
}

# ── the fence — ONE implementation, called by --run and driven by --selftest ──
#
# --selftest drives THIS function through a stub bp rather than restating it, so
# the selftest proves the production path instead of mirroring it.
fence_or_refuse() {
  local existing frc=0
  set +e
  existing="$(reserved_names)"
  frc=$?
  set -e
  [ "$frc" -eq 0 ] || refuse "the fence read did not answer: $(read_failure_reason "$frc"). Refusing to create anything in a project whose contents could not be read — an unreadable project is NOT an empty one."
  if [ -n "$existing" ]; then
    refuse "the reserved prefix \"$PG_PREFIX\" already matches: $existing. Either a previous run leaked or something else owns the name — refusing to start rather than adopt a resource this run did not create."
  fi
}

# ── cleanup: EVERY exit path, and it re-reads rather than claiming ───────────
#
# The re-read has THREE possible answers, not two: clean, dirty, and COULD NOT
# TELL. The third one used to be spelled as the first (`$(reserved_names || true)`
# collapses a failed read to the empty string, which reads as "nothing left").
# It is now its own outcome, it says so on stderr with the hand-check command,
# and it forces a NON-ZERO exit so a leaking run cannot exit 0.
#
# SIGNALS, MEASURED (bash 3.2.57(1)-release, Darwin arm64, 2026-08-01): with
# `trap … EXIT INT TERM`, killing the script with TERM, HUP and QUIT each ran the
# handler; SIGKILL ran nothing. HUP and QUIT are listed below anyway as cheap
# portability insurance — that is NOT a fix, because they already worked here.
# SIGKILL is the only true signal gap and it is deliberately NOT fixed: it CANNOT
# be. Its blast radius is measured instead — see the trap site in run().

CLEANUP_ARMED=0
CLEANUP_UNVERIFIED=0

# cleanup_unverified WHY — the third answer, spelled out loudly, once.
cleanup_unverified() {
  printf '  CLEANUP UNVERIFIED — the re-read FAILED (%s); reserved-prefix groups MAY survive. Check by hand: bp cloud hetzner placement-group list\n' "$1" >&2
  CLEANUP_UNVERIFIED=1
}

# cleanup_delete NAME — delete one leftover and READ ITS RECEIPT. The receipt is
# the whole point of the apparatus this runner exists to prove; discarding it
# with `>/dev/null 2>&1 || true` silenced the epic's own refusal machinery
# inside the epic's own instrument.
cleanup_delete() {
  local n="$1" delr="$ART/cleanup-delete.$$.json" drc=0 gone=""
  set +e
  "$BP" cloud hetzner placement-group delete "$n" --yes -o json >"$delr" 2>&1
  drc=$?
  gone="$(jsonq "$delr" 'd.get("confirmed_gone")' 2>/dev/null)"
  set -e
  if [ "$drc" -ne 0 ]; then
    printf '  delete of %s exited %s — the receipt REFUSED the claim (that is the apparatus working; the group may still exist): %s\n' \
      "$n" "$drc" "$(head -c 300 "$delr" | tr '\n' ' ')" >&2
    cleanup_unverified "a delete refused"
    return 1
  fi
  if [ "$gone" != "True" ]; then
    printf '  delete of %s exited 0 but its receipt does NOT carry confirmed_gone=true (got %s) — an exit code alone is not success: %s\n' \
      "$n" "${gone:-<absent>}" "$(head -c 300 "$delr" | tr '\n' ' ')" >&2
    cleanup_unverified "a delete receipt did not confirm the group was gone"
    return 1
  fi
  printf '  deleted %s (receipt: confirmed_gone=true)\n' "$n" >&2
  return 0
}

cleanup() {
  local rc=$?
  if [ "$CLEANUP_ARMED" = "1" ]; then
    local leftovers crc=0
    set +e
    leftovers="$(reserved_names)"
    crc=$?
    set -e
    if [ "$crc" -ne 0 ]; then
      printf '\n== cleanup (exit rc=%s): the project could NOT be read\n' "$rc" >&2
      cleanup_unverified "$(read_failure_reason "$crc")"
    elif [ -n "$leftovers" ]; then
      printf '\n== cleanup (exit rc=%s): reserved-prefix groups still present\n' "$rc" >&2
      local n
      for n in $leftovers; do
        printf '  deleting %s\n' "$n" >&2
        cleanup_delete "$n" || true
      done
      set +e
      leftovers="$(reserved_names)"
      crc=$?
      set -e
      if [ "$crc" -ne 0 ]; then
        cleanup_unverified "$(read_failure_reason "$crc")"
      elif [ -n "$leftovers" ]; then
        printf '  CLEANUP INCOMPLETE — still present: %s. Delete by hand: bp cloud hetzner placement-group delete <name> --yes\n' "$leftovers" >&2
        CLEANUP_UNVERIFIED=1
      else
        printf '  cleanup verified by re-read: zero groups match %s\n' "$PG_PREFIX" >&2
      fi
    fi
  fi
  # A run that could not verify its own cleanup is a FAIL, never a pass. There
  # is no fourth outcome in this script: PASS, REFUSE, FAIL.
  if [ "$CLEANUP_UNVERIFIED" = "1" ] && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  exit $rc
}

# ── --plan ───────────────────────────────────────────────────────────────────

plan() {
  cat <<PLAN
$SELF — MANUAL-RUN-ONLY live proof. No side effects in --plan.

  0  preflight   build bp from THIS worktree (go build ./cmd/barkpark; ./cmd/bp
                 does not exist) and refuse a tree without hzResDestroyed /
                 screenWriteReceipt. Then gate on bp's OWN resolution: a cheap
                 read verb's rc (taken without a pipe) AND its receipt shape.
                 Name the rung that paid. REFUSE (exit 3) otherwise.
  1  fence       list placement groups; REFUSE to start if any name already
                 begins with "$PG_PREFIX". Record the baseline count.
  2  create      bp cloud hetzner placement-group create --name ${PG_PREFIX}<stamp> --type spread
  3  observe     bp cloud hetzner placement-group get <resolved id>
  4  ORACLE      curl GET $HZ_API/placement_groups/<id> with a DIFFERENT client;
                 assert 200 and that id/name/type equal bp's receipt.
  5  delete      bp cloud hetzner placement-group delete <id> --yes; assert the
                 receipt carries confirmed_gone=true (hzResDestroyed's clean arm).
  6  gone        curl the same id again; assert 404, application/json, error.code
                 = not_found. Measure the byte count; harvest the body.
  7  zero        independent list read: zero reserved-prefix groups, count back
                 to the baseline. Runs on EVERY exit path via the cleanup trap.
                 A re-read that FAILS or comes back the wrong shape is neither
                 "clean" nor ignorable: it prints CLEANUP UNVERIFIED and the run
                 exits NON-ZERO.
  8  limit       print which direction this run proved and which it did NOT.

  --selftest runs 0 in four credential states, plus four mutation self-tests —
  the last of which drives the fence and the cleanup through a stub bp in ten
  states (three degraded read shapes x two paths, two refusing deletes, and two
  HEALTHY positive controls — one on the verified re-read, one on the delete
  receipt). It makes no writes and needs no network.
PLAN
}

# ── --selftest: prove the preflight can REFUSE ───────────────────────────────
#
# Four states, every exit code taken WITHOUT A PIPE. States 1 and 2 point HOME at
# an EMPTY directory so the on-disk rung genuinely has nothing to find — the
# result is then a property of bp, not of whether this host happens to be a Mac.

ST_FAIL=0
DR_STUB=""
DR_EMPTY=""
DR_N=0

# write_degraded_stub PATH — a stub bp for the DEGRADED-READ states.
#
# It answers the first $STUB_HONEST_READS list reads honestly (one
# reserved-prefix group present) and degrades every read after that — which is
# exactly the shape of a 429 or a proxy error arriving BETWEEN the delete and
# the verify. Its deletes emit a real receipt, so the whole cleanup path is
# driven end to end with no credential, no network and not one live write.
write_degraded_stub() {
  cat >"$1" <<'STUB'
#!/bin/sh
C="${STUB_STATE:-/dev/null}"
n=$(cat "$C" 2>/dev/null || echo 0)
case "$*" in
  *"placement-group list"*)
    n=$((n+1)); echo "$n" >"$C"
    if [ "$n" -le "${STUB_HONEST_READS:-1}" ]; then
      printf '{"placement_groups":[{"id":42,"name":"%sORPHAN","type":"spread"}]}\n' "$STUB_PREFIX"
      exit 0
    fi
    case "${STUB_MODE:-clean}" in
      nonjson) echo '<html>504 Gateway Time-out</html>'; exit 0 ;;
      nokey)   echo '{"ok":true}'; exit 0 ;;
      rcfail)  echo 'bp: hetzner: rate limited (429)' >&2; exit 1 ;;
      *)       echo '{"placement_groups":[]}'; exit 0 ;;
    esac
    ;;
  *"placement-group delete"*)
    case "${STUB_DELETE:-confirm}" in
      refuse)    echo '{"ok":false,"error":"placement group still present after delete"}'; exit 1 ;;
      noconfirm) echo '{"ok":true,"action":"delete"}'; exit 0 ;;
      *)         echo '{"ok":true,"action":"delete","confirmed_gone":true}'; exit 0 ;;
    esac
    ;;
esac
exit 0
STUB
  chmod +x "$1"
}

# dr_case LABEL PROBE WANT-RC NEEDLE STUB-ENV… — drive ONE production path
# (fence_or_refuse or the cleanup trap) through the degraded stub. WANT-RC is a
# number or the word "nonzero". Exit codes taken WITHOUT A PIPE, as everywhere.
dr_case() {
  local label="$1" probe="$2" want="$3" needle="$4"; shift 4
  DR_N=$((DR_N + 1))
  local out="$ART/degraded.$DR_N.out" rc=0
  set +e
  env -i "PATH=$PATH" "HOME=$DR_EMPTY" "PDS_LIVE_BP=$DR_STUB" "PDS_LIVE_ART=$ART" \
      "STUB_STATE=$ART/degraded.$DR_N.counter" "STUB_PREFIX=$PG_PREFIX" "$@" \
      "$0" --selftest-probe "$probe" >"$out" 2>&1
  rc=$?
  set -e
  local verdict="PASS"
  case "$want" in
    nonzero) [ "$rc" -ne 0 ] || verdict="FAIL" ;;
    *)       [ "$rc" = "$want" ] || verdict="FAIL" ;;
  esac
  grep -q "$needle" "$out" || verdict="FAIL"
  [ "$verdict" = "PASS" ] || ST_FAIL=1
  printf '  %-6s %-58s rc=%s (want %s)\n' "$verdict" "$label" "$rc" "$want"
  printf '         %s\n' "$(grep -F "$needle" "$out" | head -1 | sed 's/^ *//' | cut -c1-130)"
  return 0
}

st_case() { # label expect-rc env… -- (runs $0 --preflight)
  local label="$1" want="$2"; shift 2
  local out="$ART/selftest.$$.out" rc=0
  set +e
  env "$@" "$0" --preflight >"$out" 2>&1
  rc=$?
  set -e
  local verdict="PASS"
  [ "$rc" = "$want" ] || { verdict="FAIL"; ST_FAIL=1; }
  printf '  %-6s %-58s rc=%s (want %s)\n' "$verdict" "$label" "$rc" "$want"
  printf '         %s\n' "$(grep -Eo 'REFUSE — [^.]*\.|CREDENTIAL RUNG THAT PAID: .*' "$out" | head -1 | cut -c1-120)"
  ST_LAST_OUT="$out"
  return 0
}

selftest() {
  build_bp
  local empty="$ART/empty-home"
  mkdir -p "$empty"

  # A correct token for states 2 and 3, taken from whichever rung this host has.
  # Never printed, never written to an artifact.
  resolve_oracle_token || refuse "--selftest needs one WORKING credential to prove the PROCEED states (2 states of 4 are refusals and would pass with none, which is exactly the vacuous green this epic exists to kill). Set HCLOUD_TOKEN or HCLOUD_CONFIG."

  step "FOUR CREDENTIAL STATES — exit codes taken without a pipe (3 = REFUSE, 0 = proceed)"
  st_case "1. no HCLOUD_TOKEN, no HETZNER_API_TOKEN, empty HOME" 3 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART"
  st_case "2. HETZNER_API_TOKEN set to a CORRECT token (bp never reads it)" 3 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART" "HETZNER_API_TOKEN=$ORACLE_TOKEN"
  st_case "3. HCLOUD_TOKEN correct" 0 \
    -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART" "HCLOUD_TOKEN=$ORACLE_TOKEN"
  local cfg="${HCLOUD_CONFIG:-}"
  [ -n "$cfg" ] || cfg="$(default_hcloud_config)"
  if [ -r "$cfg" ]; then
    st_case "4. HCLOUD_CONFIG -> real cli.toml, no env token" 0 \
      -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_BP=$BP" "PDS_LIVE_ART=$ART" "HCLOUD_CONFIG=$cfg"
    grep -q 'hcloud-cli-context' "$ST_LAST_OUT" \
      || { printf '  FAIL   state 4 proceeded but did not NAME the cli-context rung\n'; ST_FAIL=1; }
  else
    printf '  FAIL   state 4 needs an hcloud cli.toml at %s (this host has none, so the third rung is UNPROVEN here — that is a gap, not a pass)\n' "$cfg"
    ST_FAIL=1
  fi

  step "MUTATION 1 — a stub bp that exits 0 printing {\"ok\":true} must be REFUSED"
  local stub="$ART/stub-bp"
  printf '#!/bin/sh\necho %s\nexit 0\n' "'{\"ok\":true}'" >"$stub"
  chmod +x "$stub"
  local out="$ART/stub.out" rc=0
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

  step "MUTATION 2 — the pipe trap, pinned by demonstration and not by comment"
  local failing="$ART/failing-bp"
  printf '#!/bin/sh\necho "boom" >&2\nexit 4\n' >"$failing"
  chmod +x "$failing"
  local piped unpiped
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

  step "MUTATION 3 — a tree that PREDATES the apparatus must be refused, not measured"
  # The installed /Users/pelle/.local/bin/bp was f59aaf717 on 2026-07-31 and holds
  # neither hetzner_respost.go nor screenWriteReceipt. Rather than assert that from
  # a comment, this stages the same condition: a tree whose internal/cli carries a
  # command file but no apparatus, and the runner must refuse to build from it.
  local pre="$ART/pre-apparatus"
  rm -rf "$pre"
  mkdir -p "$pre/scripts" "$pre/internal/cli" "$pre/cmd/barkpark"
  cp "$0" "$pre/scripts/$SELF"
  printf 'package cli\n\n// pre-apparatus stand-in: a hetzner command file with no post-read.\n' \
    >"$pre/internal/cli/hetzner_lb_cmd.go"
  printf 'package main\n\nfunc main() {}\n' >"$pre/cmd/barkpark/main.go"
  local pout="$ART/pre.out" prc=0
  set +e
  env -i "PATH=$PATH" "HOME=$empty" "PDS_LIVE_ART=$ART/pre-art" "$pre/scripts/$SELF" --preflight >"$pout" 2>&1
  prc=$?
  set -e
  if [ "$prc" = "3" ] && grep -q 'predates the destroy apparatus' "$pout"; then
    ok "pre-apparatus tree refused: rc=3, and the reason names the missing files ($(grep -o 'missing:[^)]*' "$pout" | head -1))"
  else
    printf '  FAIL   a tree without hzResDestroyed/screenWriteReceipt was NOT refused (rc=%s)\n' "$prc"
    ST_FAIL=1
  fi

  step "MUTATION 4 — A DEGRADED READ IS A REFUSAL, NEVER AN ALL-CLEAR"
  # Before wave 31 every row below was a LIE, reproduced from the merged script
  # with this same stub: the three fence rows printed "FENCE PASSED
  # (existing=<empty>)" or died unlabelled, and all three cleanup rows printed
  # "cleanup verified by re-read: zero groups match" at exit 0 while the planted
  # orphan survived. The rows drive fence_or_refuse() and cleanup() THEMSELVES —
  # the functions --run uses — not a restatement of them.
  DR_STUB="$ART/degraded-bp"
  DR_EMPTY="$empty"
  write_degraded_stub "$DR_STUB"

  say "  fence: the read that decides whether it is safe to CREATE in this project"
  dr_case "1. fence, list exits non-zero"            fence 3 "REFUSE" \
    "STUB_MODE=rcfail"  "STUB_HONEST_READS=0"
  dr_case "2. fence, list returns non-JSON at rc=0"  fence 3 "AN EXIT CODE ALONE IS NOT SUCCESS" \
    "STUB_MODE=nonjson" "STUB_HONEST_READS=0"
  dr_case "3. fence, valid JSON, NO placement_groups key" fence 3 "AN EXIT CODE ALONE IS NOT SUCCESS" \
    "STUB_MODE=nokey"   "STUB_HONEST_READS=0"

  say "  cleanup: the re-read that decides whether the project was left clean"
  dr_case "4. cleanup re-read exits non-zero"        cleanup nonzero "CLEANUP UNVERIFIED" \
    "STUB_MODE=rcfail"  "STUB_HONEST_READS=1"
  dr_case "5. cleanup re-read returns non-JSON"      cleanup nonzero "CLEANUP UNVERIFIED" \
    "STUB_MODE=nonjson" "STUB_HONEST_READS=1"
  dr_case "6. cleanup re-read has no placement_groups key" cleanup nonzero "CLEANUP UNVERIFIED" \
    "STUB_MODE=nokey"   "STUB_HONEST_READS=1"
  dr_case "7. delete REFUSES (receipt says still present)" cleanup nonzero "REFUSED the claim" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=9" "STUB_DELETE=refuse"
  dr_case "8. delete exits 0 WITHOUT confirmed_gone"  cleanup nonzero "does NOT carry confirmed_gone=true" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=9" "STUB_DELETE=noconfirm"

  say "  the positive control — WITHOUT IT the eight rows above would all pass on a"
  say "  script that simply refused everything, which is the same vacuity inverted:"
  dr_case "9. healthy: orphan deleted, re-read clean -> PASS at rc=0" cleanup 0 "cleanup verified by re-read" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=1" "STUB_DELETE=confirm"
  # …and row 9 alone does NOT prove the delete ran: this stub answers by READ
  # COUNT, so the second read comes back clean whether or not anything was
  # deleted. Row 10 is the same healthy state asserted on the DELETE receipt, so
  # a cleanup that silently stopped deleting could not pass the control.
  dr_case "10. healthy: the delete receipt CONFIRMED the group was gone" cleanup 0 "receipt: confirmed_gone=true" \
    "STUB_MODE=clean"   "STUB_HONEST_READS=1" "STUB_DELETE=confirm"

  step "SELFTEST VERDICT"
  if [ "$ST_FAIL" = "0" ]; then
    ok "the preflight refuses when it should and proceeds when it should, and names the rung that paid"
    say ""
    say "  NOTE ON SCOPE: --selftest proves the PREFLIGHT. It makes no writes and is"
    say "  not the live proof. Run --run for that."
    return 0
  fi
  failed "one or more preflight self-tests did not hold — do not run --run against a live project with a preflight that cannot refuse"
}

# ── --run: the live round trip ───────────────────────────────────────────────

run() {
  step "0 PREFLIGHT"
  preflight
  resolve_oracle_token || refuse "the INDEPENDENT oracle needs the raw token (curl cannot ask bp for it). bp resolved one but this script could not descend the same ladder — refusing to run a 'proof' in which bp is its own witness."
  ok "an independent oracle client is available (curl -> $HZ_API), so bp will not be its own witness"

  step "1 FENCE"
  local baseline brc=0
  fence_or_refuse
  set +e
  baseline="$(pg_count)"
  brc=$?
  set -e
  [ "$brc" -eq 0 ] || refuse "the baseline count read did not answer: $(read_failure_reason "$brc"). Refusing to create anything without a baseline to return the project to."
  CLEANUP_ARMED=1
  trap cleanup EXIT INT TERM HUP QUIT
  ok "zero placement groups match \"$PG_PREFIX\"; project baseline = $baseline group(s); cleanup trap armed on EXIT/INT/TERM/HUP/QUIT"
  say "  SIGKILL IS NOT TRAPPABLE and is not pretended to be. A kill -9 here leaks at"
  say "  most ONE placement group — free, inert, attached to nothing, routing nothing."
  say "  IT CANNOT ACCUMULATE: the fence above REFUSES TO START (exit 3) on any name"
  say "  matching \"$PG_PREFIX\", so the next run hard-stops until a human deletes it."
  say "  Deleting by NAME (not by id) is what makes that reap possible at all — a"
  say "  create whose receipt is unparseable never yields an id, so id-only deletion"
  say "  was REJECTED as a regression, not adopted as a tightening."
  say "  THE ONE LIMIT OF THAT GUARANTEE, STATED: it holds while the prefix holds. A"
  say "  run started with a DIFFERENT PDS_LIVE_PG_PREFIX cannot see an orphan left"
  say "  under the old one, so overriding the prefix retires the reap for that name."
  say "  FENCE: placement groups ONLY. This project holds five running production servers; nothing this runner touches routes traffic or holds data."

  step "2 CREATE (the real verb, the real API)"
  local name receipt rc=0
  name="$PG_PREFIX$(date -u +%Y%m%dT%H%M%SZ)-$$"
  receipt="$ART/create.json"
  set +e
  "$BP" cloud hetzner placement-group create --name "$name" --type spread -o json >"$receipt" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$receipt" >&2; failed "create exited $rc"; }
  local id rname
  id="$(jsonq "$receipt" 'd["placement_group"]["id"]')"   || failed "create receipt has no placement_group.id: $(cat "$receipt")"
  rname="$(jsonq "$receipt" 'd["placement_group"]["name"]')"
  [ -n "$id" ] || failed "create receipt carried an empty id"
  ok "bp receipt: ok=$(jsonq "$receipt" 'd.get("ok")') action=$(jsonq "$receipt" 'd.get("action")') id=$id name=$rname type=$(jsonq "$receipt" 'd.get("type")')"

  step "3 OBSERVE (bp's own read-back)"
  local getr="$ART/get.json"
  set +e
  "$BP" cloud hetzner placement-group get "$id" -o json >"$getr" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$getr" >&2; failed "get exited $rc"; }
  ok "bp get id=$(jsonq "$getr" 'd["placement_group"]["id"]') name=$(jsonq "$getr" 'd["placement_group"]["name"]')"

  step "4 ORACLE — an INDEPENDENT client asks the same API the same question"
  local obody="$ART/oracle-200.json" ometa ocode octype obytes
  ometa="$(oracle "/placement_groups/$id" "$obody")"
  ocode="$(printf '%s' "$ometa" | awk '{print $1}')"
  octype="$(printf '%s' "$ometa" | awk '{print $2}')"
  obytes="$(printf '%s' "$ometa" | awk '{print $3}')"
  [ "$ocode" = "200" ] || { cat "$obody" >&2; failed "the oracle read of placement group $id answered HTTP $ocode, not 200"; }
  local oid oname otype
  oid="$(jsonq "$obody" 'd["placement_group"]["id"]')"
  oname="$(jsonq "$obody" 'd["placement_group"]["name"]')"
  otype="$(jsonq "$obody" 'd["placement_group"]["type"]')"
  [ "$oid" = "$id" ]      || failed "ORACLE DISAGREES on id: bp said $id, the API says $oid"
  [ "$oname" = "$rname" ] || failed "ORACLE DISAGREES on name: bp said $rname, the API says $oname"
  ok "HTTP $ocode $octype $obytes bytes; id/name/type match bp's receipt ($oid / $oname / $otype)"
  say "  THIS is the line that makes the run a proof: the receipt was checked against the server's own SECOND answer, taken by a different client, not against the fixture that generated it."
  if [ -n "${PDS_LIVE_HARVEST:-}" ]; then
    mkdir -p "$PDS_LIVE_HARVEST"
    cp "$obody" "$PDS_LIVE_HARVEST/pds_live_hetzner_placement_group_200.json"
    say "  harvested: $PDS_LIVE_HARVEST/pds_live_hetzner_placement_group_200.json ($obytes bytes)"
  fi

  step "5 DELETE (hzResDestroyed's confirming read fires against the real API)"
  local delr="$ART/delete.json"
  set +e
  "$BP" cloud hetzner placement-group delete "$id" --yes -o json >"$delr" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$delr" >&2; failed "delete exited $rc — the receipt refused the claim (that is the apparatus working; the resource may still exist)"; }
  local gone
  gone="$(jsonq "$delr" 'd.get("confirmed_gone")')"
  [ "$gone" = "True" ] || { cat "$delr" >&2; failed "the delete receipt did not carry confirmed_gone=true (got '$gone') — this run cannot claim the clean arm fired"; }
  ok "bp receipt: ok=$(jsonq "$delr" 'd.get("ok")') action=delete confirmed_gone=true — hzResDestroyed's (nil,nil) arm fired against a REAL 404, not a fixture"

  step "6 THE GONE PREDICATE'S GROUND TRUTH — the real 404, measured"
  local gbody="$ART/oracle-404.json" gmeta gcode gtype gbytes
  gmeta="$(oracle "/placement_groups/$id" "$gbody")"
  gcode="$(printf '%s' "$gmeta" | awk '{print $1}')"
  gtype="$(printf '%s' "$gmeta" | awk '{print $2}')"
  gbytes="$(printf '%s' "$gmeta" | awk '{print $3}')"
  [ "$gcode" = "404" ] || failed "the deleted group answered HTTP $gcode, not 404"
  case "$gtype" in
    application/json*) : ;;
    *) failed "the 404 content-type is $gtype, not application/json — PDS-D401's load-bearing production assumption does NOT hold, and hcloud-go's errorFromBody would return a transport error instead of the clean gone arm" ;;
  esac
  local gcodefield
  gcodefield="$(jsonq "$gbody" 'd["error"]["code"]')"
  [ "$gcodefield" = "not_found" ] || failed "the 404 body's error.code is '$gcodefield', not not_found"
  ok "HTTP 404 $gtype $gbytes bytes error.code=not_found — PDS-D401 confirmed at L1 for the placement-group kind"
  say "  body: $(cat "$gbody")"
  if [ -n "${PDS_LIVE_HARVEST:-}" ]; then
    cp "$gbody" "$PDS_LIVE_HARVEST/pds_live_hetzner_placement_group_404.json"
    local sbody="$ART/oracle-404-server.json" smeta
    smeta="$(oracle "/servers/999999999" "$sbody")"
    cp "$sbody" "$PDS_LIVE_HARVEST/pds_live_hetzner_server_404.json"
    say "  harvested: the placement-group 404 ($gbytes bytes) and the SERVER 404 ($(printf '%s' "$smeta" | awk '{print $3}') bytes) — different kinds, different lengths, so no assertion may pin a universal byte count"
  fi

  step "7 THE PROJECT IS LEFT AS IT WAS — observed, not claimed"
  local after leftovers lrc=0 arc=0
  set +e
  leftovers="$(reserved_names)"
  lrc=$?
  after="$(pg_count)"
  arc=$?
  set -e
  [ "$lrc" -eq 0 ] || failed "the final read did not answer: $(read_failure_reason "$lrc"). This run CANNOT claim it left the project as it found it — the cleanup trap is still armed and will say so."
  [ "$arc" -eq 0 ] || failed "the final count read did not answer: $(read_failure_reason "$arc")."
  [ -z "$leftovers" ] || failed "reserved-prefix groups survive the run: $leftovers"
  [ "$after" = "$baseline" ] || failed "the project holds $after placement group(s), baseline was $baseline"
  CLEANUP_ARMED=0
  ok "independent list read: zero groups match \"$PG_PREFIX\"; count back to the baseline ($after)"

  step "8 WHAT THIS RUN PROVED, AND WHAT IT DID NOT"
  cat <<'LIMIT'
  PROVED (direction: NO FALSE REFUSAL). A real Barkpark verb made a real round
  trip against api.hetzner.cloud; its receipt agreed with the same API's own
  independent second answer; and hzResDestroyed's confirming read bound on REAL
  404 bytes — clean JSON, error.code=not_found — and did not red an honest
  destroy. Until this run, PDS-D401's "production always returns a JSON 404" was
  an assumption the whole apparatus rested on.

  NOT PROVED (direction: THE REFUSAL). This run did NOT show the receipt refusing
  a lying API. A correct Hetzner will not keep handing back a resource it has
  deleted, so the hzResStillThere arm cannot be staged live at all; it stays
  proven only by the LYING-FAKE cases in internal/cli/hetzner_respost_test.go.
  Nor is the object-storage "declared" arm touched here.

  NOT REACHABLE AT ALL from the CLI: the 204 carve-out. `bp chat approve` exits
  rc=2, so that path cannot be driven from this surface by any live run.

  Anyone quoting this transcript as "the destroy apparatus is proven against
  production" is over-reading it by exactly one direction.
LIMIT
  say ""
  ok "LIVE PROOF COMPLETE — credential rung: $RUNG"
}

# --selftest-probe fence|cleanup — INTERNAL, spawned only by --selftest. It runs
# ONE production path (the real fence_or_refuse, the real cleanup trap) against
# $PDS_LIVE_BP, so the degraded-read states prove the code --run executes rather
# than a copy of it that could drift away from it silently.
selftest_probe() {
  [ -n "${PDS_LIVE_BP:-}" ] || usage "--selftest-probe is internal to --selftest and requires PDS_LIVE_BP"
  BP="$PDS_LIVE_BP"
  case "${1:-}" in
    fence)
      fence_or_refuse
      say "  FENCE PASSED (existing=<empty>) -> the run would now CREATE in this project"
      ;;
    cleanup)
      CLEANUP_ARMED=1
      trap cleanup EXIT INT TERM HUP QUIT
      exit 0
      ;;
    *) usage "--selftest-probe wants 'fence' or 'cleanup'" ;;
  esac
}

case "${1:---run}" in
  --plan)           plan ;;
  --preflight)      preflight ;;
  --selftest)       selftest ;;
  --selftest-probe) selftest_probe "${2:-}" ;;
  --run)            run ;;
  -h|--help)        plan ;;
  *)                usage "unknown argument '$1' (want --plan | --preflight | --selftest | --run)" ;;
esac

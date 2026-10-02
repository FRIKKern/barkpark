#!/usr/bin/env bash
# cmux-smoke.sh — the committed live E2E proof of the CMUX × Barkpark bridge
# (cmux-bridge epic, wave 2, task cb-live-smoke). It replaces the unrecorded
# Jul 6-7 hand smokes with one repeatable run that drives the FULL pane
# lifecycle against the REAL guerrilla server — install → claim → renew → honest
# leave-claimed → close → the cardinal dead-server fail-safe row — and proves the
# bridge never touches the operator's real config.
#
# WHY a bash harness (not a Go test): the loop only exists across real processes
# (a fresh `bp cmux hook` per event, keyed on env, no persisted epoch between
# SessionStart and Stop — cmux_hook.go), against a real task document with a real
# lease/epoch/CAS. A unit test with an injected client proves the branches; only
# this proves the wiring.
#
# MANUAL RUN ONLY — NEVER wire into CI (same stance as scripts/claude-chat-e2e.sh,
# scripts/media-smoke.sh, scripts/idp-interop.sh). It writes to the live guerrilla
# task ledger. It is self-cleaning (creates AND closes its own throwaway tasks,
# labeled `smoke`), but a crashed run can leave two `smoke` tasks briefly claimed
# until their lease expires.
#
#   Invocation (from anywhere; it cd's to the repo root itself):
#     ./scripts/cmux-smoke.sh
#   Requires: bp on PATH (or BP=/path/to/bp), python3, shasum, and a working
#   ~/.config/barkpark/config.json whose ACTIVE server is guerrilla. Cost: ~4
#   throwaway task writes + a handful of claims on guerrilla; seconds to run.
#
# GATE (cb-live-smoke): `bash -n scripts/cmux-smoke.sh && bash scripts/cmux-smoke.sh`
# must end in a PASS summary with 0 failures; paste the output (incl. both shasum
# proofs + the dead-server assertions) as task evidence.
#
# PRINCIPAL GATE (task-d9a297da227cd39e, 2026-09-11). Until this slice the ONLY
# thing standing between `bash scripts/cmux-smoke.sh` and four REAL ledger writes
# was `command -v bp`. The `bp task get cmux-bridge-goal` preflight below is a
# REACHABILITY check, not an authority check: it says a document resolved, never
# WHICH server answered nor at WHAT tier — a prod config with a still-valid token
# passes it and every write then lands on prod. So before the FIRST write the run
# now asserts, off one `bp whoami -o json` receipt (`bp` reads the same env this
# script exports, so the receipt describes the principal the writes will use):
#
#   * auth_tier is a WRITING tier (writer_tier: admin/editor/write/writer/operator).
#     An anonymous or read-only caller is refused BY NAME — `bp whoami` exits 0
#     either way, so the refusal is made on the receipt's SHAPE, never on its rc
#     (the stance of scripts/pds-live-bp-write-receipt.sh's preflight(), and of
#     scripts/demo-living-values.sh's `"auth_tier":"admin"` check off
#     GET /v1/capabilities).
#   * the resolved server's HOST equals the host this smoke DECLARES
#     ($CMUX_SMOKE_EXPECT_HOST, default guerrilla.barkpark.cloud). What used to
#     be `WARNING: … proceeding anyway` is now a refusal.
#
#   ./scripts/cmux-smoke.sh --selftest   prove both refusals + the positive
#                                        control, offline, with a fake bp on PATH.
#
# EXIT: 0 pass · 1 an assertion FAILED · 2 usage · 3 REFUSED (principal gate) ·
#       4 CANNOT READ (the whoami receipt could not be taken or parsed).

set -euo pipefail
cd "$(dirname "$0")/.."

SELFTEST=0
case "${1:-}" in
  --selftest) SELFTEST=1 ;;
  "") : ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac

# --- the principal gate's refusals, named -----------------------------------------
refuse()     { printf 'REFUSED: %s\n' "$*" >&2; exit 3; }
cannot_read(){ printf 'CANNOT READ: %s\n' "$*" >&2; exit 4; }

# writer_tier TIER — may this tier write? Anything that is not a resolved writing
# principal fails CLOSED. (Same table as pds-live-bp-write-receipt.sh:writer_tier.)
writer_tier() {
  case "$1" in
    admin|editor|write|writer|operator) return 0 ;;
    *) return 1 ;;
  esac
}

# =================================================================================
# --selftest — the principal gate, proven OFFLINE (task-d9a297da227cd39e).
#
# Three arms, each a full re-exec of THIS script against a FAKE bp that records
# every argv it is given to a file. The assertion that matters is not the exit
# code alone: it is the exit code BESIDE the recorded argv. A gate that refuses
# after issuing a write would show rc!=0 and a write in the log, and that is the
# failure this harness exists to catch — so arms 1 and 2 assert ZERO lines in the
# log matching a ledger write verb, and arm 3 (the positive control) asserts the
# opposite, that `task create` IS reached. Without arm 3 a script that refused
# unconditionally would pass arms 1 and 2.
#
# No network, no token, no real config: the child gets a scratch HOME carrying a
# synthetic ~/.config/barkpark/config.json, which is also why its shasum
# isolation proof has something to read.
# =================================================================================
selftest() {
  local root fake_home fake_bin log out rc st_pass=0 st_fail=0
  root="$(pwd)"
  st_ok()  { echo "  ✓ $1"; st_pass=$((st_pass + 1)); }
  st_bad() { echo "  ✗ $1"; st_fail=$((st_fail + 1)); }

  # writes_in LOG → the number of recorded argv lines that are a LEDGER WRITE.
  # `task get`, `cmux …` and `whoami` are reads and must not count; counting them
  # would make every arm look like it wrote and the harness would prove nothing.
  writes_in() {
    /usr/bin/grep -cE '^(task (create|close|claim|stamp)|doc (patch|publish))\b' "$1" 2>/dev/null || true
  }

  # arm LABEL TIER CFG_SERVER WHOAMI_SERVER EXPECT_WRITES(yes|no) EXPECT_RC(zero|nonzero) GATE_REACHED(yes|no)
  #
  # CFG_SERVER and WHOAMI_SERVER are separate on purpose: the config names the
  # server the run was POINTED at, whoami names the one bp actually RESOLVED, and
  # the two disagreeing (env override, stale active set) is precisely the case a
  # single check would miss.
  arm() {
    local label="$1" tier="$2" cfg_server="$3" who_server="$4" want_writes="$5" want_rc="$6" gate_reached="$7" n
    fake_home="$(mktemp -d)"; fake_bin="$(mktemp -d)"
    log="$fake_bin/argv.log"; out="$fake_bin/run.out"
    : >"$log"
    mkdir -p "$fake_home/.config/barkpark"
    printf '{"server":"%s","token":"fake-token","workspace":"w","project":"p","dataset":"production"}\n' \
      "$cfg_server" >"$fake_home/.config/barkpark/config.json"

    # THE FAKE bp. It records first and answers second, so an argv that reaches it
    # is in the log even when the answer is a failure.
    cat >"$fake_bin/bp" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$1 \$2" in
  "whoami -o") printf '{"auth_tier":"%s","server":"%s","name":"fake","dataset":"production"}\n' "$tier" "$who_server" ;;
  "task get")  exit 0 ;;
  "task create") printf '{"id":"fake-T-\$RANDOM"}\n' ;;
  *) : ;;
esac
exit 0
FAKE
    chmod +x "$fake_bin/bp"

    rc=0
    env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$fake_home" \
        XDG_CONFIG_HOME="$fake_home/.config" \
        CMUX_SMOKE_EXPECT_HOST=guerrilla.barkpark.cloud \
        BP="$fake_bin/bp" \
        bash "$root/scripts/cmux-smoke.sh" >"$out" 2>&1 || rc=$?

    n="$(writes_in "$log")"
    case "$want_rc" in
      nonzero) if [ "$rc" -ne 0 ]; then st_ok "$label: exit $rc (non-zero)"; else st_bad "$label: exit 0 — the gate did NOT refuse"; fi ;;
      zero)    st_ok "$label: exit $rc (the fake bp cannot complete the live smoke; the write-reached assertion below is this arm's subject)" ;;
    esac
    case "$want_writes" in
      no)  if [ "$n" -eq 0 ]; then st_ok "$label: ZERO ledger-write argv recorded (read back from the fixture's own log)"; else st_bad "$label: $n ledger write(s) recorded — the refusal came TOO LATE"; fi ;;
      yes) if [ "$n" -gt 0 ]; then st_ok "$label: $n ledger-write argv recorded — the first write IS reached on a good principal"; else st_bad "$label: ZERO writes recorded — the gate refuses unconditionally, so the refusing arms prove nothing"; fi ;;
    esac
    # The refusal must name itself, not merely exit non-zero.
    if [ "$want_rc" = nonzero ]; then
      if /usr/bin/grep -q '^REFUSED: ' "$out"; then st_ok "$label: refusal is named on stderr (REFUSED:)"; else st_bad "$label: exited non-zero with no REFUSED: line"; fi
    fi
    # THE PRECONDITION, asserted rather than assumed: a child that died before it
    # ever reached the gate would ALSO record zero writes — a vacuous pass.
    case "$gate_reached" in
      yes) if /usr/bin/grep -q '^whoami -o json$' "$log"; then st_ok "$label: fixture reached the whoami gate (argv recorded)"; else st_bad "$label: whoami never ran — the child died earlier, so this arm measured nothing"; fi ;;
      no)  if /usr/bin/grep -q '^whoami -o json$' "$log"; then st_bad "$label: whoami ran — this arm is supposed to refuse on the CONFIG host, before any probe"; else st_ok "$label: refused on the config host before any bp probe (no whoami argv)"; fi ;;
    esac
    rm -rf "$fake_home" "$fake_bin"
  }

  echo "=== cmux-smoke --selftest: the principal gate, offline ==="
  echo ""
  echo "--- arm 1: WRONG TIER (auth_tier=none, declared host everywhere) ---"
  arm "wrong-tier" "none"  "https://guerrilla.barkpark.cloud" "https://guerrilla.barkpark.cloud" no  nonzero yes
  echo ""
  echo "--- arm 2: WRONG HOST as bp RESOLVED it (config says guerrilla, whoami says api) ---"
  arm "wrong-host-resolved" "admin" "https://guerrilla.barkpark.cloud" "https://api.barkpark.cloud" no  nonzero yes
  echo ""
  echo "--- arm 3: WRONG HOST in the active config (refused before any bp probe) ---"
  arm "wrong-host-config"   "admin" "https://api.barkpark.cloud"       "https://api.barkpark.cloud" no  nonzero no
  echo ""
  echo "--- arm 4: POSITIVE CONTROL (auth_tier=admin, declared host) ---"
  arm "good-principal"      "admin" "https://guerrilla.barkpark.cloud" "https://guerrilla.barkpark.cloud" yes zero yes
  echo ""
  echo "=== SELFTEST: $st_pass passed, $st_fail failed ==="
  [ "$st_fail" -eq 0 ]
}

if [ "$SELFTEST" = "1" ]; then
  selftest
  exit $?
fi

# --- resolve bp or REFUSE (idp-interop.sh stance: no silent skip) ----------------
BP_BIN="${BP:-bp}"
if ! command -v "$BP_BIN" >/dev/null 2>&1; then
  echo "REFUSE: bp binary not found (looked for '${BP_BIN}'; set BP=/path/to/bp)." >&2
  echo "        This harness proves the LIVE bridge — it must not run without bp." >&2
  exit 1
fi
BP="$(command -v "$BP_BIN")"
for tool in python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "REFUSE: '$tool' not found." >&2; exit 1; }
done

# --- pass/fail counters (media-smoke.sh style) -----------------------------------
pass=0
fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }
die() { echo "FATAL: $1" >&2; exit 1; }

# small JSON readers over stdin-piped `bp ... -o json` payloads
# sfield "<json>" a.b.c → the dotted value ('' when any hop is absent/null)
sfield() {
  printf '%s' "$1" | python3 -c '
import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)
' "$2"
}
# has_key "<json>" key → yes|no (top-level key presence, distinct from null value)
has_key() {
  printf '%s' "$1" | python3 -c '
import json,sys
print("yes" if sys.argv[1] in json.load(sys.stdin) else "no")
' "$2"
}

# url_host URL → the hostname, '' when the URL has none. Compared against the
# DECLARED host: a substring match ('*guerrilla*') would accept
# https://guerrilla.evil.example and reject a legitimate port/path spelling.
url_host() {
  printf '%s' "$1" | python3 -c '
import sys
from urllib.parse import urlparse
print(urlparse(sys.stdin.read().strip()).hostname or "")
'
}

# =================================================================================
# 1. Capture the REAL guerrilla creds + untouched-config shasums BEFORE any
#    reassignment or any bp write. Everything after this runs in a scratch HOME.
# =================================================================================
REAL_HOME="$HOME"
REAL_CONFIG_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}"
REAL_CONFIG="$REAL_CONFIG_DIR/barkpark/config.json"
REAL_SETTINGS="$REAL_HOME/.claude/settings.json"

[ -f "$REAL_CONFIG" ] || die "no real config at $REAL_CONFIG — guerrilla creds unknown."

# Active-server creds straight off the config's top level (the `bp use` active set).
read_cfg() { python3 -c "import json;print(json.load(open('$REAL_CONFIG')).get('$1',''))"; }
G_SERVER="$(read_cfg server)"
G_TOKEN="$(read_cfg token)"
G_WORKSPACE="$(read_cfg workspace)"
G_PROJECT="$(read_cfg project)"
G_DATASET="$(read_cfg dataset)"
[ -n "$G_SERVER" ] && [ -n "$G_TOKEN" ] || die "config missing server/token."
# The host this smoke DECLARES. Overridable so a local/staging box can be named
# explicitly — but never silently: an unset override means guerrilla, and a
# mismatch is a refusal, not the WARNING this line used to print.
EXPECT_HOST="${CMUX_SMOKE_EXPECT_HOST:-guerrilla.barkpark.cloud}"
CFG_HOST="$(url_host "$G_SERVER")"
[ "$CFG_HOST" = "$EXPECT_HOST" ] || refuse "the active bp config names server '$G_SERVER' (host '$CFG_HOST'), but this smoke declares host '$EXPECT_HOST'. It writes REAL rows — it will not write them to a server it was not pointed at. Run \`bp use\` to select the right server, or set CMUX_SMOKE_EXPECT_HOST deliberately."


# The isolation proof: both real targets, byte-for-byte, before and after.
sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "ABSENT"; }
BEFORE_SETTINGS="$(sha_of "$REAL_SETTINGS")"
BEFORE_CONFIG="$(sha_of "$REAL_CONFIG")"

echo "=== cmux bridge live smoke — guerrilla: $G_SERVER ==="
echo "captured real-config shasum + real-settings shasum (isolation baseline)"

# =================================================================================
# 2. Scratch HOME + XDG (BOTH: install --merge targets os.UserHomeDir()/.claude;
#    hook state roots at os.UserConfigDir which IGNORES XDG on macOS). Guerrilla
#    creds via explicit env (env beats config, cli.go envContext). Tier-2 worker:
#    BARKPARK_WORKER_ID stays UNSET so `cmux-<surface>` is what we prove.
# =================================================================================
SCRATCH="$(mktemp -d)"
export HOME="$SCRATCH"
export XDG_CONFIG_HOME="$SCRATCH/.config"
export BARKPARK_API_URL="$G_SERVER"
export BARKPARK_API_TOKEN="$G_TOKEN"
export BARKPARK_WORKSPACE="$G_WORKSPACE"
export BARKPARK_PROJECT="$G_PROJECT"
export BARKPARK_DATASET="$G_DATASET"
export CMUX_SURFACE_ID="smoke-$$-$RANDOM"
unset BARKPARK_WORKER_ID || true      # tier-2 (cmux-<surface>) is the proof target
WORKER="cmux-$CMUX_SURFACE_ID"

T1=""
T2=""
# trap: close throwaway tasks (best-effort, same worker = renew→close) + nuke scratch.
cleanup() {
  local rc=$?
  set +e
  for t in "$T1" "$T2"; do
    [ -n "$t" ] || continue
    local cl ep
    cl=$(BARKPARK_TASK="$t" "$BP" task claim "$t" "$WORKER" 2>/dev/null)
    ep=$(printf '%s' "$cl" | grep -oE 'epoch=[0-9]+' | head -1 | cut -d= -f2)
    [ -n "$ep" ] && "$BP" task close "$t" "$WORKER" "$ep" done "smoke cleanup" >/dev/null 2>&1
  done
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  return $rc
}
trap cleanup EXIT

# state-dir roots (both platforms) — nuked in scenario C to beat the 60s throttle.
CMUX_STATE_XDG="$XDG_CONFIG_HOME/barkpark/cmux"
CMUX_STATE_MAC="$HOME/Library/Application Support/barkpark/cmux"

# hook runner: captures rc + EXACT stdout byte count (command-subst would strip a
# trailing newline, masking a byte-empty violation — so we go through a file).
OUTFILE="$SCRATCH/hook.out"
run_hook() {  # run_hook <stdin-json> <event> [VAR=VAL ...]
  local stdin="$1" event="$2"; shift 2
  printf '%s' "$stdin" | env "$@" "$BP" cmux hook "$event" >"$OUTFILE" 2>/dev/null \
    && HOOK_RC=0 || HOOK_RC=$?
  HOOK_BYTES=$(wc -c <"$OUTFILE" | tr -d ' ')
}
status_of() {  # status_of <task> [VAR=VAL ...] → STATUS
  local task="$1"; shift
  STATUS=$(env BARKPARK_TASK="$task" "$@" "$BP" cmux status -o json 2>/dev/null)
}
new_smoke_task() {  # → prints the created task id
  "$BP" task create "cmux smoke $1 $(date +%s)" --publish --yes \
    --set 'labels:=["smoke"]' \
    --set 'acceptance_criteria:=[{"criterion":"smoke","met":false}]' \
    -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'
}

# =================================================================================
# PRINCIPAL GATE (mandatory, and FIRST — see the header block). One
# `bp whoami -o json` receipt, taken under the scratch HOME + the exported env,
# i.e. through the exact credential ladder every write below will descend.
# Nothing has written yet at this point: the first ledger write is
# new_smoke_task's `bp task create` in scenario B.
# =================================================================================
echo ""
echo "--- principal gate: writing tier + declared host, BEFORE the first write ---"
WHO="$SCRATCH/whoami.json"
WHO_RC=0
"$BP" whoami -o json >"$WHO" 2>/dev/null || WHO_RC=$?
[ "$WHO_RC" -eq 0 ] || cannot_read "\`bp whoami -o json\` exited $WHO_RC — bp cannot describe the credential it resolved, so this run cannot know whose ledger it is about to write. Nothing has been written."
WHO_TIER="$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
print(d.get("auth_tier") or "" if isinstance(d, dict) else "")
' "$WHO" 2>/dev/null)" || cannot_read "the \`bp whoami -o json\` receipt is not parseable JSON. Nothing has been written."
WHO_SERVER="$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
print(d.get("server") or "")
' "$WHO" 2>/dev/null)" || cannot_read "the \`bp whoami -o json\` receipt is not parseable JSON. Nothing has been written."
WHO_HOST="$(url_host "$WHO_SERVER")"

writer_tier "$WHO_TIER" || refuse "bp resolved auth_tier=\"${WHO_TIER:-<absent>}\", which is not a writing tier. Note that \`bp whoami\` EXITS 0 for an anonymous caller too, and that the reachability preflight below would also pass — so this refusal is made on the receipt's SHAPE. Nothing has been written."
[ "$WHO_HOST" = "$EXPECT_HOST" ] || refuse "bp resolved server '$WHO_SERVER' (host '${WHO_HOST:-<absent>}'), but this smoke declares host '$EXPECT_HOST'. The reachability preflight cannot see this: a live prod server answers \`bp task get\` perfectly well. Nothing has been written."
ok "principal gate: auth_tier=$WHO_TIER (writing) and host=$WHO_HOST == declared $EXPECT_HOST"

# =================================================================================
# PREFLIGHT (mandatory): a known task must resolve on guerrilla. Under an isolated
# HOME a missing scope var silently falls to the baked localhost:4000/dev-token
# floor — every scenario would then fake a dead server. This is the tripwire.
# =================================================================================
echo ""
echo "--- preflight: guerrilla reachable under isolated HOME ---"
if "$BP" task get cmux-bridge-goal >/dev/null 2>&1; then
  ok "preflight: bp task get cmux-bridge-goal succeeds (env creds reach guerrilla)"
else
  die "preflight FAILED — bp task get cmux-bridge-goal did not resolve. Isolated HOME likely fell to the localhost floor; refusing to run (every scenario would fake dead-server)."
fi

# =================================================================================
# A. install --merge writes the scratch settings with our hook command.
# =================================================================================
echo ""
echo "--- A. install --merge into scratch HOME ---"
"$BP" cmux install --merge --yes >/dev/null 2>&1 || true
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q 'bp cmux hook' "$SETTINGS"; then
  ok "install --merge wrote $SETTINGS containing 'bp cmux hook'"
else
  bad "install --merge did NOT wire 'bp cmux hook' into $SETTINGS"
fi

# =================================================================================
# B. Healthy claim: SessionStart claims T1 as cmux-<surface>, exit 0, empty stdout.
# =================================================================================
echo ""
echo "--- B. SessionStart claims a throwaway task ---"
T1="$(new_smoke_task T1)"
[ -n "$T1" ] || die "could not create throwaway task T1."
echo "  T1=$T1"
run_hook '{"session_id":"smoke"}' SessionStart BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "SessionStart rc==0" || bad "SessionStart rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "SessionStart stdout byte-empty" || bad "SessionStart wrote $HOOK_BYTES stdout bytes (must be 0)"

status_of "$T1"
CW="$(sfield "$STATUS" claim_worker)"
HC="$(sfield "$STATUS" has_claim)"
E1="$(sfield "$STATUS" claim_epoch)"
[ "$CW" = "$WORKER" ] && ok "claim_worker == $WORKER (tier-2, BARKPARK_WORKER_ID unset)" || bad "claim_worker='$CW' expected '$WORKER'"
[ "$HC" = "True" ] && ok "has_claim true" || bad "has_claim='$HC' (expected True)"
case "$E1" in ''|*[!0-9]*) bad "claim_epoch not an integer: '$E1'";; *) ok "claim_epoch E1=$E1";; esac

# =================================================================================
# C. Renew bumps epoch, same worker. Nuke the state dir first to beat the 60s
#    throttle (renewDue fails OPEN; never compute sha1 stamp filenames).
# =================================================================================
echo ""
echo "--- C. PreToolUse renews (epoch bumps, worker unchanged) ---"
rm -rf "$CMUX_STATE_XDG" "$CMUX_STATE_MAC"
run_hook '{"tool_name":"Bash"}' PreToolUse BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "PreToolUse rc==0" || bad "PreToolUse rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "PreToolUse stdout byte-empty" || bad "PreToolUse wrote $HOOK_BYTES stdout bytes (must be 0)"

status_of "$T1"
E2="$(sfield "$STATUS" claim_epoch)"
CW2="$(sfield "$STATUS" claim_worker)"
case "$E2" in ''|*[!0-9]*) bad "renewed claim_epoch not an integer: '$E2'";; *)
  if [ "$E2" -gt "$E1" ]; then ok "claim_epoch bumped $E1 → $E2"; else bad "claim_epoch $E2 not > $E1"; fi ;;
esac
[ "$CW2" = "$WORKER" ] && ok "claim_worker unchanged ($WORKER)" || bad "claim_worker changed to '$CW2'"

# =================================================================================
# D. Honest non-close: Stop with an UNMET criterion leaves the task claimed —
#    lifecycle != done, still claimed, and NO breadcrumb (leave-claimed is honest,
#    not an error).
# =================================================================================
echo ""
echo "--- D. Stop with unmet criterion leaves claimed (no breadcrumb) ---"
run_hook '{}' Stop BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "Stop rc==0" || bad "Stop rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "Stop stdout byte-empty" || bad "Stop wrote $HOOK_BYTES stdout bytes (must be 0)"
status_of "$T1"
LC="$(sfield "$STATUS" lifecycle)"
HC="$(sfield "$STATUS" has_claim)"
[ "$LC" != "done" ] && ok "lifecycle != done (leave-claimed): '$LC'" || bad "lifecycle == done — closed on unmet criteria!"
[ "$HC" = "True" ] && ok "has_claim still true" || bad "has_claim='$HC' (expected still True)"
[ "$(has_key "$STATUS" last_error)" = "no" ] && ok "no last_error breadcrumb (honest leave is not an error)" || bad "last_error present after an honest leave-claimed"

# =================================================================================
# E. Close with evidence: flip the criterion met:=true, Stop again → observed_rev
#    CAS close → lifecycle == done. The patch alone lands in a `drafts.<id>`
#    overlay that guerrilla's `?perspective=drafts` doc read (the exact endpoint
#    the hook uses, apiclient.GetPerspectiveResult) does NOT surface for the base
#    id — so we PUBLISH the flip, which is what makes met:true visible to the
#    hook's acceptance gate. (The charter assumed the patch alone suffices; the
#    live server needs the publish. Verified against guerrilla.)
# =================================================================================
echo ""
echo "--- E. met-flip (patch + publish) then Stop closes the task ---"
"$BP" doc patch task "$T1" --yes \
  --set 'acceptance_criteria:=[{"criterion":"smoke","met":true}]' >/dev/null 2>&1 \
  || bad "doc patch (met-flip) failed"
"$BP" doc publish task "$T1" --yes >/dev/null 2>&1 \
  || bad "doc publish (met-flip) failed"
run_hook '{}' Stop BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "Stop rc==0" || bad "Stop rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "closing Stop stdout byte-empty (branch-heaviest hook path)" || bad "closing Stop wrote $HOOK_BYTES stdout bytes (must be 0)"
status_of "$T1"
LC="$(sfield "$STATUS" lifecycle)"
[ "$LC" = "done" ] && ok "lifecycle == done (observed_rev CAS close)" || bad "lifecycle='$LC' (expected done after met-flip)"

# =================================================================================
# F. CARDINAL fail-safe row: a dead server must NOT harm the agent. SessionStart
#    against a connection-refused port → exit 0 + byte-empty stdout; then, with
#    guerrilla restored, the honest breadcrumb surfaces via `bp cmux status`.
# =================================================================================
echo ""
echo "--- F. dead server: exit 0, empty stdout, honest breadcrumb (NOT fail-invisible) ---"
T2="$(new_smoke_task T2)"
[ -n "$T2" ] || die "could not create throwaway task T2."
echo "  T2=$T2"
run_hook '{}' SessionStart BARKPARK_TASK="$T2" BARKPARK_API_URL="http://127.0.0.1:1"
[ "$HOOK_RC" = "0" ] && ok "dead-server SessionStart rc==0 (agent unharmed)" || bad "dead-server rc=$HOOK_RC (fail-safe VIOLATED)"
[ "$HOOK_BYTES" = "0" ] && ok "dead-server stdout byte-empty" || bad "dead-server wrote $HOOK_BYTES stdout bytes (fail-safe VIOLATED)"

status_of "$T2"
LE_EVENT="$(sfield "$STATUS" last_error.event)"
LE_ERR="$(sfield "$STATUS" last_error.error)"
[ "$LE_EVENT" = "SessionStart" ] && ok "last_error.event == SessionStart (breadcrumb stamped)" || bad "last_error.event='$LE_EVENT' (expected SessionStart)"
case "$LE_ERR" in
  *claim*) ok "last_error.error names the claim failure: \"$LE_ERR\"" ;;
  *) bad "last_error.error does not mention claim failure: '$LE_ERR'" ;;
esac

# =================================================================================
# G. Cleanup + isolation proof: close T1/T2 on guerrilla; the REAL config +
#    settings must be byte-for-byte identical to the baseline.
# =================================================================================
echo ""
echo "--- G. close throwaway tasks + isolation shasum proof ---"
for t in "$T1" "$T2"; do
  cl=$(BARKPARK_TASK="$t" "$BP" task claim "$t" "$WORKER" 2>/dev/null || true)
  ep=$(printf '%s' "$cl" | grep -oE 'epoch=[0-9]+' | head -1 | cut -d= -f2 || true)
  [ -n "$ep" ] && "$BP" task close "$t" "$WORKER" "$ep" done "smoke closed by harness" >/dev/null 2>&1 || true
done
# VERIFY the closes landed (T1 closed in scenario E; T2 by the loop above) — an
# ||-guarded loop must not report green while leaving a claimed smoke task behind.
status_of "$T2"
[ "$(sfield "$STATUS" lifecycle)" = "done" ] && ok "throwaway tasks closed on guerrilla (T2 lifecycle==done; T1 closed in E)" || bad "T2 lifecycle='$(sfield "$STATUS" lifecycle)' — throwaway task left unclosed on guerrilla"

AFTER_SETTINGS="$(sha_of "$REAL_SETTINGS")"
AFTER_CONFIG="$(sha_of "$REAL_CONFIG")"
echo "  real settings: before=$BEFORE_SETTINGS after=$AFTER_SETTINGS"
echo "  real config  : before=$BEFORE_CONFIG after=$AFTER_CONFIG"
[ "$AFTER_SETTINGS" = "$BEFORE_SETTINGS" ] && ok "real ~/.claude/settings.json UNTOUCHED (shasum byte-equal)" || bad "real settings shasum CHANGED — isolation breached!"
[ "$AFTER_CONFIG" = "$BEFORE_CONFIG" ] && ok "real ~/.config/barkpark/config.json UNTOUCHED (shasum byte-equal)" || bad "real config shasum CHANGED — isolation breached!"

# =================================================================================
echo ""
echo "=== SMOKE: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

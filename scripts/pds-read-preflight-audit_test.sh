#!/usr/bin/env bash
# pds-read-preflight-audit_test.sh — the selftest for the read-preflight audit
# and for the auth_tier preflight it put in front of scripts/pds-crown-stamp.sh.
#
# Every arm is a PAIR: the mutation that must be caught, beside a control that
# must NOT be. An arm with only the catching half proves the detector fires; it
# does not prove the detector discriminates, and a detector that fires on
# everything is the same as no detector.
#
# NOTHING HERE TOUCHES A SERVER. The crown-stamp arms drive a STUB bp, so a
# fail-open that would have sent a real `bp task stamp` is caught by the stub
# recording the call — never by a row moving on the live ledger.
#
#   bash scripts/pds-read-preflight-audit_test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$HERE/pds-read-preflight-audit.sh"
STAMP="$HERE/pds-crown-stamp.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ── a minimal tree the census can be pointed at ──────────────────────────────
mk_tree() {
  local root="$1"
  mkdir -p "$root/scripts"
  cp "$AUDIT" "$root/scripts/pds-read-preflight-audit.sh"
  # a script whose ONLY bp write verbs live inside operator-facing MESSAGE TEXT.
  # This is the pr-task-gate.sh / branch-owner.sh shape, and it must NOT be a
  # candidate: a grep that cannot tell a message from a command turns the
  # census into noise, and a noisy census gets muted.
  cat >"$root/scripts/talker.sh" <<'EOS'
#!/usr/bin/env bash
fail() { echo "$1" >&2; exit 1; }
[ "$1" = ok ] || fail "the lifecycle was flipped by hand rather than closed through the engine (bp task close ${TASK_ID} <worker> <epoch>)"
[ "$2" = ok ] || fail "that state comes from editing lifecycle_status directly (bp doc patch) instead of going through the claim/close engine"
echo fine
EOS
}

echo "=== arm 1: the census ratchet ==="
mk_tree "$TMP/clean"
PDS_AUDIT_ROOT="$TMP/clean" bash "$TMP/clean/scripts/pds-read-preflight-audit.sh" census >"$TMP/clean.out" 2>&1
CLEAN_RC=$?
# CONTROL: a tree with a message-text-only script is CLEAN. If this reds, the
# predicate is matching prose and everything below it is noise.
if [ "$CLEAN_RC" -eq 0 ] && grep -q 'undispositioned: 0' "$TMP/clean.out"; then
  ok "control: a script that only QUOTES 'bp task close' / 'bp doc patch' in messages is not a candidate"
else
  bad "control: the message-text-only script was flagged (rc=$CLEAN_RC) — the predicate cannot tell prose from a command"
  sed -n '1,20p' "$TMP/clean.out"
fi

cp -R "$TMP/clean" "$TMP/dirty"
cat >"$TMP/dirty/scripts/newcomer.sh" <<'EOS'
#!/usr/bin/env bash
# a brand-new harness that writes to the ledger and was never audited
probe="$(bp doc ls task --limit 1 -o json)" || exit 1
bp task create "something" --publish --yes
EOS
PDS_AUDIT_ROOT="$TMP/dirty" bash "$TMP/dirty/scripts/pds-read-preflight-audit.sh" census >"$TMP/dirty.out" 2>&1
DIRTY_RC=$?
if [ "$DIRTY_RC" -ne 0 ] && grep -q 'UNDISPOSITIONED: scripts/newcomer.sh' "$TMP/dirty.out"; then
  ok "a NEW script that writes after a read probe is caught as UNDISPOSITIONED (rc=$DIRTY_RC)"
else
  bad "the census passed a brand-new unaudited writer (rc=$DIRTY_RC) — the ratchet does not hold"
  sed -n '1,20p' "$TMP/dirty.out"
fi

echo
echo "=== arm 2: the census is stable across runs (the pipefail/SIGPIPE trap) ==="
# `grep -v … | grep -q …` under `set -o pipefail` returns 141 when -q matches
# early enough to SIGPIPE the -v side, and 141 reads as "no match". That made
# the census drop a DIFFERENT set of candidates on each run. Three runs that
# agree is the cheapest assertion that the pipeline is gone.
A="$(PDS_AUDIT_ROOT="$HERE/.." bash "$AUDIT" census 2>&1 | grep -c '^  disposition')"
B="$(PDS_AUDIT_ROOT="$HERE/.." bash "$AUDIT" census 2>&1 | grep -c '^  disposition')"
C="$(PDS_AUDIT_ROOT="$HERE/.." bash "$AUDIT" census 2>&1 | grep -c '^  disposition')"
if [ "$A" = "$B" ] && [ "$B" = "$C" ] && [ "$A" -gt 0 ]; then
  ok "three consecutive censuses of the real tree agree ($A rows each)"
else
  bad "the census is not deterministic: $A / $B / $C rows — a SIGPIPE is eating candidates"
fi

echo
echo "=== arm 3: pds-crown-stamp.sh refuses a NON-WRITING principal ==="
# THE STUB. It answers `task get` with a real-shaped task (so the read probe
# and the criterion fetch both succeed, exactly as they do against guerrilla
# for a caller with no write credential), answers `whoami` with the tier the
# arm is testing, and RECORDS any `task stamp` it is asked to send.
mk_stub() {
  local dir="$1" tier="$2"
  mkdir -p "$dir"
  cat >"$dir/bp" <<EOS
#!/usr/bin/env bash
case "\$1 \$2" in
  "whoami "*|"whoami") printf '{"auth_tier":"$tier","token_present":true}\n'; exit 0 ;;
esac
case "\$1" in
  whoami) printf '{"auth_tier":"$tier","token_present":true}\n'; exit 0 ;;
  task)
    case "\$2" in
      get) printf '%s\n' '{"doc":{"content":{"acceptance_criteria":[{"criterion":"a criterion","met":false}]},"criteria_progress":{"met":0,"total":1}}}'; exit 0 ;;
      stamp) printf 'STAMP %s\n' "\$*" >> "$dir/stamp.log"; printf 'POST /v1/tasks/x/stamp\n'; exit 0 ;;
    esac ;;
esac
exit 0
EOS
  chmod +x "$dir/bp"
}

for tier in none read; do
  D="$TMP/stub-$tier"; mk_stub "$D" "$tier"
  BP="$D/bp" bash "$STAMP" stamp some-task 0 worker 1 --evidence "probe" >"$TMP/out-$tier" 2>&1
  RC=$?
  if [ ! -f "$D/stamp.log" ] && [ "$RC" -ne 0 ] && grep -q 'NO writing principal' "$TMP/out-$tier"; then
    ok "auth_tier=$tier: REFUSED (rc=$RC) and no stamp was sent"
  else
    bad "auth_tier=$tier: rc=$RC, stamp.log $( [ -f "$D/stamp.log" ] && echo EXISTS || echo absent ) — the fail-open is live"
    sed -n '1,12p' "$TMP/out-$tier"
  fi
done

# CONTROL: the same script, the same stub, a WRITING tier. It must get through
# to the stamp. Without this arm, a preflight that refuses EVERYTHING would
# score a clean green above — the "control that flips was never a control".
D="$TMP/stub-admin"; mk_stub "$D" "admin"
BP="$D/bp" bash "$STAMP" stamp some-task 0 worker 1 --evidence "probe" >"$TMP/out-admin" 2>&1
if [ -f "$D/stamp.log" ] && grep -q 'task stamp some-task' "$D/stamp.log"; then
  ok "control: auth_tier=admin reaches the stamp — the preflight discriminates, it does not just refuse"
else
  bad "control: auth_tier=admin did NOT reach the stamp — the new preflight refuses everything, so arm 3 proves nothing"
  sed -n '1,20p' "$TMP/out-admin"
fi

echo
echo "=== arm 4: onramp-live-client-smoke.sh does not report a silent skip as clean ==="
# The accounting block is EXTRACTED FROM THE REAL FILE — from the `=== summary`
# line to the end — and run as-is under both states. Retyping it here would test
# a copy; a grep for the new wording would test the wording. This runs the bytes
# that ship.
ONRAMP="$HERE/onramp-live-client-smoke.sh"
if [ ! -f "$ONRAMP" ]; then
  bad "arm 4: $ONRAMP is missing"
else
  sed -n '/^echo "=== summary:/,$p' "$ONRAMP" >"$TMP/summary.sh"
  for state in measured skipped; do
    {
      echo 'pass=3; fail=0'
      if [ "$state" = skipped ]; then
        echo 'skipped=1; SKIPPED_WHAT="the bp mcp serve JSON-RPC handshake (no manifest-capable token)"'
      else
        echo 'skipped=0; SKIPPED_WHAT=""'
      fi
      cat "$TMP/summary.sh"
    } >"$TMP/run-$state.sh"
    bash "$TMP/run-$state.sh" >"$TMP/sum-$state" 2>&1
  done
  if grep -q 'NOT MEASURED BY THIS RUN' "$TMP/sum-skipped" \
     && grep -q 'PASSED IN PART' "$TMP/sum-skipped" \
     && ! grep -q 'answers a real JSON-RPC handshake' "$TMP/sum-skipped"; then
    ok "a skipped handshake is named in the summary and does NOT claim the handshake answered"
  else
    bad "a skipped handshake still prints a clean PASS — the silent-green skip is live"
    cat "$TMP/sum-skipped"
  fi
  # CONTROL: with nothing skipped, the full claim must still be made. A banner
  # that hedges unconditionally would pass the arm above and say nothing.
  if grep -q 'answers a real JSON-RPC handshake' "$TMP/sum-measured" \
     && ! grep -q 'NOT MEASURED' "$TMP/sum-measured"; then
    ok "control: with nothing skipped the run still makes the full claim"
  else
    bad "control: the banner hedges even when nothing was skipped — arm 4 proves nothing"
    cat "$TMP/sum-measured"
  fi
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
#
# branch-owner.test.sh — the harness for the adopt/do-not-adopt verdict.
#
# FULLY HERMETIC. `git`, `gh` and `bp` are stubs on PATH driven by files in
# $STUB. Nothing reaches the network, the bp server, or the real repo.
#
# THE CASES THAT MATTER are the ones where a naive reading says "free":
#
#   * no readable signal must be UNKNOWN, never POSSIBLY-STALE (case 4) —
#     "I could not see anyone" is not "nobody is there"
#   * a LIVE bp claim must hold the branch even when the last push is ancient
#     (case 7), because that is exactly the mid-compile agent this rule exists
#     to protect
#   * the claim must be read FLAT at .claim; a fixture whose content.claim is
#     null while .claim is held must still read OWNED-LIVE (case 8)
#   * bp missing must SKIP the claim signal and say so, never fake an absence
#     (case 6)
#   * every non-stale verdict must end with the adoption sentence (cases 2,4)
#
#   scripts/branch-owner.test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/branch-owner.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/branch-owner-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "-- $* --"; }

# D37: never read the status of `producer | grep -q`. Here-strings only.
has() { grep -qF -- "$2" <<<"$1"; }
first_line() { head -1 <<<"$1"; }

ADOPT_LINE="Do NOT adopt unless the owner is confirmed unreachable."

BIN="$TMP/bin"; mkdir -p "$BIN"

# A CURATED child PATH. Prepending $BIN is not enough: the real bp/gh/git are
# still further down the real PATH, so "remove the stub" would silently fall
# through to the live tool and the bp-is-absent case would test nothing.
SYS="$TMP/sys"; mkdir -p "$SYS"
for t in bash basename dirname date grep head tail tr cut sort cat sed python3; do
  real="$(command -v "$t" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$SYS/$t"
done
CHILD_PATH="$BIN:$SYS"

# ── the git stub ─────────────────────────────────────────────────────────────
# $STUB/push-age-min holds "how many minutes ago was the last push". The stub
# converts it to a real %ct at call time, so the test never has to freeze time.

cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  fetch) exit 0 ;;
  rev-parse)
    [ -f "$STUB/push-age-min" ] || exit 1
    exit 0 ;;
  log)
    age="$(cat "$STUB/push-age-min" 2>/dev/null || echo 0)"
    ct=$(( $(date +%s) - age * 60 ))
    case "$*" in
      *%ct*) printf '%s\n' "$ct" ;;
      *)     printf '2026-08-31T10:00:00+02:00\t%s\tsome commit subject\n' \
               "$(cat "$STUB/pusher" 2>/dev/null || echo 'Some Agent')" ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/git"

# ── the gh stub ──────────────────────────────────────────────────────────────

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  [ -f "$STUB/gh.fail" ] && { echo "error: HTTP 403" >&2; exit 1; }
  cat "$STUB/pr-line.txt" 2>/dev/null || true
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  cat "$STUB/pr-body.txt" 2>/dev/null || true
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"

# ── the bp stub ──────────────────────────────────────────────────────────────

cat > "$BIN/bp" <<'STUB'
#!/usr/bin/env bash
[ -f "$STUB/bp.fail" ] && exit 1
cat "$STUB/task-raw.json" 2>/dev/null || exit 1
exit 0
STUB
chmod +x "$BIN/bp"

fresh_world() {
  STUB="$TMP/w-$1"
  rm -rf "$STUB"
  mkdir -p "$STUB"
  export STUB
}

run() {
  OUT="$(PATH="$CHILD_PATH" "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

# claim_json <worker> <minutes-ago> — a raw bp task row whose content.claim is
# NULL (as the server always returns it) and whose real claim is FLAT.
claim_json() {
  local worker="$1" mins="$2" ts
  ts="$(python3 -c "
import datetime, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=$mins)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
  cat <<JSON
{"doc":{"id":"task-aaaabbbbccccdddd","type":"task",
 "content":{"claim":null,"title":"a row"},
 "claim":{"worker_id":"$worker","epoch":3,"claimed_at":"$ts"}}}
JSON
}

echo "== branch-owner.sh — silence is not abandonment =="

# ═══ usage ══════════════════════════════════════════════════════════════════

section "1  usage errors exit 2 and print no verdict"
fresh_world usage
run
if [ "$RC" = 2 ]; then ok "1a no branch -> exit 2"; else bad "1a got exit $RC"; fi
run one two
if [ "$RC" = 2 ]; then ok "1b two branches -> exit 2"; else bad "1b got exit $RC"; fi
run --stale-after abc br
if [ "$RC" = 2 ]; then ok "1c non-numeric --stale-after -> exit 2"; else bad "1c got exit $RC"; fi
run --frobnicate br
if [ "$RC" = 2 ]; then ok "1d unknown flag -> exit 2"; else bad "1d got exit $RC"; fi
run --help
if [ "$RC" = 0 ]; then ok "1e --help -> exit 0"; else bad "1e got exit $RC"; fi
case "$(first_line "$OUT")" in
  OWNED-LIVE|POSSIBLY-STALE|UNKNOWN) bad "1f --help opened with a verdict" ;;
  *) ok "1f --help does not open with a verdict" ;;
esac

# ═══ the three verdicts ═════════════════════════════════════════════════════

section "2  a recent push alone is OWNED-LIVE"
fresh_world live_push
echo 5 > "$STUB/push-age-min"
echo 'Busy Agent' > "$STUB/pusher"
run --no-fetch feature-x
if [ "$(first_line "$OUT")" = "OWNED-LIVE" ]; then ok "2a verdict OWNED-LIVE"; else bad "2a first line: $(first_line "$OUT")"; fi
if [ "$RC" = 1 ]; then ok "2b exit 1 (so 'if branch-owner.sh' is the SAFE shape)"; else bad "2b got exit $RC (want 1)"; fi
if has "$OUT" "$ADOPT_LINE"; then ok "2c ends with the adoption sentence"; else bad "2c adoption sentence missing"; fi
AGE="$(grep -oE '[0-9]+ minutes ago' <<<"$OUT" | grep -oE '^[0-9]+' || true)"
# Integer division floors, so a 5-minute-old push reads as 4 or 5.
if [ "${AGE:-x}" = "4" ] || [ "${AGE:-x}" = "5" ]; then
  ok "2d reports the push age ($AGE minutes)"
else
  bad "2d push age was '${AGE:-<none>}' (want 4 or 5)"
fi

section "3  an old push alone is POSSIBLY-STALE, and still not a green light"
fresh_world stale_push
echo 400 > "$STUB/push-age-min"
run --no-fetch feature-x
if [ "$(first_line "$OUT")" = "POSSIBLY-STALE" ]; then ok "3a verdict POSSIBLY-STALE"; else bad "3a first line: $(first_line "$OUT")"; fi
if [ "$RC" = 0 ]; then ok "3b exit 0"; else bad "3b got exit $RC (want 0)"; fi
if has "$OUT" "confirm they are unreachable before you launch an adopter"; then
  ok "3c even the stale verdict demands confirmation, never says 'go'"
else
  bad "3c the stale verdict read as a green light"
fi

section "4  no readable signal is UNKNOWN, never POSSIBLY-STALE"
fresh_world blind
# No push-age-min file => origin/<branch> does not exist. No PR. No task.
run --no-fetch ghost-branch
if [ "$(first_line "$OUT")" = "UNKNOWN" ]; then ok "4a verdict UNKNOWN"; else bad "4a first line: $(first_line "$OUT")"; fi
if [ "$RC" = 3 ]; then ok "4b exit 3"; else bad "4b got exit $RC (want 3)"; fi
if has "$OUT" "$ADOPT_LINE"; then ok "4c ends with the adoption sentence"; else bad "4c adoption sentence missing"; fi
if has "$OUT" "evidence the instrument is blind"; then
  ok "4d names the blindness rather than implying abandonment"
else
  bad "4d silence was dressed up as absence"
fi

section "5  --stale-after moves the boundary, and only the boundary"
fresh_world boundary
echo 100 > "$STUB/push-age-min"
run --no-fetch feature-x
if [ "$(first_line "$OUT")" = "OWNED-LIVE" ]; then ok "5a 100 min < default 120 -> OWNED-LIVE"; else bad "5a $(first_line "$OUT")"; fi
run --no-fetch --stale-after 60 feature-x
if [ "$(first_line "$OUT")" = "POSSIBLY-STALE" ]; then ok "5b --stale-after 60 -> POSSIBLY-STALE"; else bad "5b $(first_line "$OUT")"; fi
if has "$OUT" "(stale-after: 60 min)"; then ok "5c the threshold in force is printed"; else bad "5c threshold not printed"; fi

# ═══ the bp claim signal ════════════════════════════════════════════════════

section "6  bp absent SKIPS the claim signal and SAYS so — never fakes it"
fresh_world nobp
echo 400 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
printf 'body\n\nTask: task-aaaabbbbccccdddd\n' > "$STUB/pr-body.txt"
cp "$BIN/bp" "$TMP/bp.saved"
rm -f "$BIN/bp"
run --no-fetch feature-x
if has "$OUT" "bp is not on PATH - the claim signal was SKIPPED, not evaluated"; then
  ok "6a the missing claim signal is declared SKIPPED"
else
  bad "6a bp's absence was not disclosed"
fi
if ! has "$OUT" "held by"; then
  ok "6b no claim was invented"
else
  bad "6b a claim was reported with bp absent"
fi
cp "$TMP/bp.saved" "$BIN/bp"

section "7  a LIVE claim owns the branch even when the push is ancient"
fresh_world live_claim
echo 5000 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
printf 'PR body\n\nTask: task-aaaabbbbccccdddd\n' > "$STUB/pr-body.txt"
claim_json "hunt-share-mint" 4 > "$STUB/task-raw.json"
run --no-fetch feature-x
if [ "$(first_line "$OUT")" = "OWNED-LIVE" ]; then
  ok "7a a fresh claim beats a 3-day-old push"
else
  bad "7a first line: $(first_line "$OUT")"
fi
if has "$OUT" "held by hunt-share-mint (epoch 3)"; then
  ok "7b names the holder and the epoch"
else
  bad "7b holder/epoch not reported"
fi
if has "$OUT" "task-aaaabbbbccccdddd"; then
  ok "7c the Task: trailer was parsed out of the PR body"
else
  bad "7c the task trailer was not parsed"
fi

section "8  the claim is read FLAT — content.claim is null in every fixture"
if has "$(cat "$STUB/task-raw.json")" '"claim":null'; then
  ok "8a the fixture really does carry content.claim=null (the trap is armed)"
else
  bad "8a fixture does not arm the content.claim trap"
fi
# Case 7 passed against exactly this fixture, so the reader cannot have been
# looking at content.claim.
if has "$OUT" "held by hunt-share-mint"; then
  ok "8b OWNED-LIVE was produced from the FLAT .claim, not content.claim"
else
  bad "8b the flat claim was not read"
fi

section "9  a stale claim plus a stale push is POSSIBLY-STALE"
fresh_world stale_claim
echo 400 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
printf 'Task: task-aaaabbbbccccdddd\n' > "$STUB/pr-body.txt"
claim_json "gone-agent" 900 > "$STUB/task-raw.json"
run --no-fetch feature-x
if [ "$(first_line "$OUT")" = "POSSIBLY-STALE" ]; then ok "9a verdict POSSIBLY-STALE"; else bad "9a $(first_line "$OUT")"; fi
if has "$OUT" "held by gone-agent"; then ok "9b the holder is still named"; else bad "9b holder not named"; fi

section "10 a claim with NO timestamp is treated as LIVE, not as stale"
fresh_world untimed_claim
echo 5000 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
printf 'Task: task-aaaabbbbccccdddd\n' > "$STUB/pr-body.txt"
cat > "$STUB/task-raw.json" <<'JSON'
{"doc":{"id":"task-aaaabbbbccccdddd","content":{"claim":null},
 "claim":{"worker_id":"mystery","epoch":9}}}
JSON
run --no-fetch feature-x
if [ "$(first_line "$OUT")" = "OWNED-LIVE" ]; then
  ok "10a held-but-undateable resolves to LIVE (held beats unknown)"
else
  bad "10a first line: $(first_line "$OUT")"
fi
if has "$OUT" "age UNKNOWN, treated as LIVE"; then
  ok "10b the assumption is stated out loud"
else
  bad "10b the assumption was silent"
fi

section "11 a FAILED bp read is UNREAD, not 'no claim'"
fresh_world bp_fail
echo 400 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
printf 'Task: task-aaaabbbbccccdddd\n' > "$STUB/pr-body.txt"
touch "$STUB/bp.fail"
run --no-fetch feature-x
if has "$OUT" "the claim signal is UNREAD, not absent"; then
  ok "11a a failed bp read is labelled UNREAD"
else
  bad "11a a failed bp read was rendered as an absent claim"
fi

section "12 a failed gh read is UNREAD, not 'no open PR'"
fresh_world gh_fail
echo 400 > "$STUB/push-age-min"
touch "$STUB/gh.fail"
run --no-fetch feature-x
if has "$OUT" "UNREAD: gh pr list failed"; then
  ok "12a the PR signal says UNREAD and quotes gh"
else
  bad "12a a failed gh read was rendered as 'none open'"
fi
if ! has "$OUT" "none open"; then
  ok "12b it does NOT claim there is no open PR"
else
  bad "12b an unread PR signal was reported as 'none open'"
fi

section "13 the Task: TRAILER wins over a task id quoted in prose"
# Measured on this script's own PR: a body-wide `grep -o | head -1` returned a
# task id from a USAGE EXAMPLE and read a stranger's claim.
fresh_world trailer_precedence
echo 5000 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
cat > "$STUB/pr-body.txt" <<'BODY'
Some prose. For example you would run:

    scripts/already-fixed.sh --task task-deadbeefdeadbeef

and read the verdict.

Task: task-aaaabbbbccccdddd
BODY
claim_json "right-owner" 3 > "$STUB/task-raw.json"
run --no-fetch feature-x
if has "$OUT" "task task-aaaabbbbccccdddd (from Task: trailer)"; then
  ok "13a the TRAILER id was used, not the example id"
else
  bad "13a picked the wrong task id: $(grep -F 'task task-' <<<"$OUT" || echo none)"
fi
if ! has "$OUT" "task-deadbeefdeadbeef"; then
  ok "13b the prose id never reached the claim read"
else
  bad "13b a task id quoted in prose was resolved as the owner"
fi

section "14 with NO trailer it still falls back, but LABELS the guess"
fresh_world no_trailer
echo 5000 > "$STUB/push-age-min"
printf '4242\thttps://x/4242\t2026-08-31T09:00:00Z\tsomeone\n' > "$STUB/pr-line.txt"
printf 'No trailer here, only a mention of task-aaaabbbbccccdddd inline.\n' > "$STUB/pr-body.txt"
claim_json "fallback-owner" 3 > "$STUB/task-raw.json"
run --no-fetch feature-x
if has "$OUT" "(from a bare mention in the body (NO Task: trailer))"; then
  ok "14a the fallback is DISCLOSED as a bare mention, not passed off as a trailer"
else
  bad "14a the fallback was not labelled"
fi

echo
echo "branch-owner.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

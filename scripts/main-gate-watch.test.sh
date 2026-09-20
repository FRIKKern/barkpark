#!/usr/bin/env bash
# main-gate-watch.test.sh — the both-ways proofs for the main-tip watch.
#
# Nothing here asserts "the script ran". Every verdict is proven against
# RECORDED fixtures from four real shas, and the two ways it could lose are
# proven separately:
#
#   * it must SCREAM on a RED tip                    (0e9246447, Cloud gate = failure)
#   * it must SCREAM on a tip with NO verdict at all (a5260f609, cancelled: three
#     check runs total, none of them a required context) — the case a watch
#     phrased as "find a failing required row" reports GREEN on
#   * it must PASS on two independent known-green shas (f4abf4369, 0239dd4ee)
#   * WAITING must be NEITHER                        (synthetic: status != completed)
#   * it must NOT scream on a tip that is still being judged (2e72d2948, the
#     recorded production red of run 31312071143: 36 rows, `Elixir gate` absent
#     because the elixir run on the tip had not finished) — and it must scream on
#     the SAME 36 rows once every workflow run on that tip is terminal
#
# The exclusion is proven by MUTATION rather than by reading the source: the
# script is copied with EXCLUDED_CONTEXTS blanked, and the known-green sha is
# watched turning RED on the PR-scoped context. That is what makes the exclusion
# load-bearing rather than decorative.
#
# FULLY OFFLINE. `gh` is replaced by a stub that fails loudly, so any accidental
# network path in the script under test shows up as a failing case rather than
# as a hidden dependency on GitHub being up.
#
#   sh scripts/main-gate-watch.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$REPO_ROOT/scripts/main-gate-watch.sh"
WF="$REPO_ROOT/.github/workflows/main-gate-watch.yml"
SPEC="$REPO_ROOT/.github/required-checks.json"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

# ═══ no network, ever ════════════════════════════════════════════════════════
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: this test is offline and must never call the network (args: $*)" >&2
exit 97
STUB
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"; export PATH

# ═══ recorded fixtures ═══════════════════════════════════════════════════════
# Protection, recorded 2026-08-09 from repos/FRIKKern/barkpark/branches/main:
# four required contexts, one of which is PR-scoped.
FX="$TMP/fx"; mkdir -p "$FX"

cat > "$FX/protection.json" <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"app_id": 15368, "context": "Elixir gate"},
      {"app_id": 15368, "context": "PR references an active task"},
      {"app_id": 15368, "context": "Cloud gate"},
      {"app_id": 15368, "context": "Console gate"}
    ]
  },
  "enforce_admins": {"enabled": true}
}
JSON

# f4abf4369 — known-green. Note what is NOT here: "PR references an active
# task" never rendered post-merge. That absence is why the exclusion exists.
cat > "$FX/f4abf4369.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"},
  {"name": "Security gate","status": "completed", "conclusion": "success"},
  {"name": "Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)", "status": "completed", "conclusion": "failure"}
]}
JSON

# 0239dd4ee — second independent known-green sha.
cat > "$FX/0239dd4ee.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

# 0e9246447 — main's tip at survey time. Cloud gate RED.
cat > "$FX/0e9246447.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

# a5260f609 — a `cancelled` main sha. THREE check runs in total, and not one of
# them is a required context. Recorded verbatim: this is the whole point.
cat > "$FX/a5260f609.json" <<'JSON'
{"check_runs": [
  {"name": "go vet + test",       "status": "completed", "conclusion": "success"},
  {"name": "Break-glass harness", "status": "completed", "conclusion": "skipped"},
  {"name": "Break-glass watch",   "status": "completed", "conclusion": "success"}
]}
JSON

# Synthetic: a fresh push to main, Cloud gate still running. Nobody could
# observe this live at probe time (no in-flight run existed), so it is TESTED
# rather than assumed — it is exactly the shape that gets a watch muted.
cat > "$FX/waiting.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed",  "conclusion": "success"},
  {"name": "Cloud gate",   "status": "in_progress","conclusion": null},
  {"name": "Console gate", "status": "queued",     "conclusion": null}
]}
JSON

# Waiting AND red together: the scream must win.
cat > "$FX/waiting-and-red.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed",  "conclusion": "failure"},
  {"name": "Cloud gate",   "status": "in_progress","conclusion": null},
  {"name": "Console gate", "status": "completed",  "conclusion": "success"}
]}
JSON

# A re-run: the same name twice, the LATEST row deciding.
cat > "$FX/rerun-green-last.json" <<'JSON'
{"check_runs": [
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 2},
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

cat > "$FX/rerun-red-last.json" <<'JSON'
{"check_runs": [
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T02:00:00Z", "id": 2},
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

# Protection carrying a context nobody classified.
cat > "$FX/protection-unclassified.json" <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"app_id": 15368, "context": "Elixir gate"},
      {"app_id": 15368, "context": "PR references an active task"},
      {"app_id": 15368, "context": "Cloud gate"},
      {"app_id": 15368, "context": "Console gate"},
      {"app_id": 15368, "context": "Brand new gate"}
    ]
  }
}
JSON

# A 403 body, as `gh` actually emits it.
cat > "$FX/protection-forbidden.json" <<'JSON'
gh: Resource not accessible by integration (HTTP 403)
JSON

# ── the THIRD authority: the workflow runs on the tip (cch-w61) ──────────────
# Recorded from repos/FRIKKern/barkpark/actions/runs?head_sha=a5260f609aa2bfe…
# All NINE runs are `completed`. This is what makes a5260f609 a genuinely
# never-judged tip rather than a young one, and it must keep screaming.
cat > "$FX/a5260f609-runs.json" <<'JSON'
{"total_count": 9, "workflow_runs": [
  {"id": 31290083952, "name": "doc-gates",             "status": "completed", "conclusion": "cancelled"},
  {"id": 31290083984, "name": "elixir",                "status": "completed", "conclusion": "cancelled"},
  {"id": 31290083959, "name": "security",              "status": "completed", "conclusion": "cancelled"},
  {"id": 31290084004, "name": "cloud",                 "status": "completed", "conclusion": "cancelled"},
  {"id": 31290084003, "name": "required-checks-drift", "status": "completed", "conclusion": "cancelled"},
  {"id": 31290083960, "name": "Deploy (production)",   "status": "completed", "conclusion": "cancelled"},
  {"id": 31290083978, "name": "console-harness",       "status": "completed", "conclusion": "cancelled"},
  {"id": 31290083964, "name": "breakglass-watch",      "status": "completed", "conclusion": "success"},
  {"id": 31290083966, "name": "go-tests",              "status": "completed", "conclusion": "success"}
]}
JSON

# 2e72d2948's runs AS OF 11:57:32Z, from the same endpoint: three of the
# thirteen had not reached a terminal state yet (updated_at later than the
# evaluation instant), and one of those three is `elixir` — run 31311871968,
# created 11:52:33Z, terminal only at 11:59:07Z, whose `/jobs` returns
# total_count: 0. No `Elixir gate` row COULD exist at 11:57:32Z.
cat > "$FX/2e72d2948-runs.json" <<'JSON'
{"total_count": 13, "workflow_runs": [
  {"id": 31312071143, "name": "main-gate-watch",       "status": "in_progress", "conclusion": null},
  {"id": 31312064644, "name": "breakglass-watch",      "status": "completed",   "conclusion": "success"},
  {"id": 31311887504, "name": "crown-reconcile",       "status": "completed",   "conclusion": "failure"},
  {"id": 31311871953, "name": "crown-reconcile",       "status": "completed",   "conclusion": "failure"},
  {"id": 31311871959, "name": "console-harness",       "status": "completed",   "conclusion": "success"},
  {"id": 31311871966, "name": "cloud",                 "status": "completed",   "conclusion": "success"},
  {"id": 31311871946, "name": "required-checks-drift", "status": "completed",   "conclusion": "failure"},
  {"id": 31311871947, "name": "security",              "status": "in_progress", "conclusion": null},
  {"id": 31311871963, "name": "compose-smoke",         "status": "in_progress", "conclusion": null},
  {"id": 31311871968, "name": "elixir",                "status": "queued",      "conclusion": null},
  {"id": 31311871996, "name": "breakglass-watch",      "status": "completed",   "conclusion": "success"},
  {"id": 31311871955, "name": "stale-verdict-watch",   "status": "completed",   "conclusion": "failure"},
  {"id": 31311871972, "name": "doc-gates",             "status": "completed",   "conclusion": "success"}
]}
JSON

# The SAME tip, one counterfactual away: every run terminal. Nothing is coming,
# so an absent required row is a tip that was never judged.
sed 's/"in_progress"/"completed"/g; s/"queued"/"completed"/g' \
  "$FX/2e72d2948-runs.json" > "$FX/2e72d2948-runs-terminal.json"

# A fresh merge tip whose workflows have all only just been created.
cat > "$FX/runs-all-inflight.json" <<'JSON'
{"total_count": 3, "workflow_runs": [
  {"id": 900001, "name": "elixir", "status": "queued",      "conclusion": null},
  {"id": 900002, "name": "cloud",  "status": "queued",      "conclusion": null},
  {"id": 900003, "name": "console-harness", "status": "in_progress", "conclusion": null}
]}
JSON

# A tip with no workflow run at all — nothing is in flight, so nothing is coming.
cat > "$FX/runs-none.json" <<'JSON'
{"total_count": 0, "workflow_runs": []}
JSON

# A 403 from the runs endpoint, as `gh` emits it, and a body that is not JSON.
cat > "$FX/runs-forbidden.json" <<'JSON'
gh: Resource not accessible by integration (HTTP 403)
JSON
printf 'not json at all\n' > "$FX/runs-garbage.json"

OUT="$TMP/out.txt"
run_watch() { # sha, check-runs fixture, [protection fixture], [script], [workflow-runs fixture]
  # THE FIFTH ARGUMENT IS THE POINT (cch-w61). Before this slice run_watch()
  # passed only --sha/--protection-file/--check-runs-file, so a fix that read a
  # THIRD authority and defaulted it to today's behaviour passed all 56
  # assertions in this file unchanged while the production red persisted. Every
  # new-behaviour case below drives its runs payload THROUGH this function, so
  # the new input is exercised rather than merely available.
  local sha="$1" runs="$2" prot="${3:-$FX/protection.json}" script="${4:-$WATCH}" wfruns="${5:-}"
  if [ -n "$wfruns" ]; then
    bash "$script" --sha "$sha" --protection-file "$prot" --check-runs-file "$runs" \
      --runs-file "$wfruns" > "$OUT" 2>&1
  else
    bash "$script" --sha "$sha" --protection-file "$prot" --check-runs-file "$runs" \
      > "$OUT" 2>&1
  fi
  echo $?
}

# ═══ 1. the two known-green shas PASS ════════════════════════════════════════
section "1. PASS on the known-green shas"

rc="$(run_watch f4abf4369 "$FX/f4abf4369.json")"
if [ "$rc" = "0" ]; then ok "f4abf4369 -> PASS (exit 0)"; else bad "f4abf4369 -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
grep -q "f4abf4369" "$OUT" && ok "f4abf4369 output names the sha" || bad "f4abf4369 output does not name the sha"
grep -q "skipped (named exclusion): PR references an active task" "$OUT" \
  && ok "f4abf4369 output names the exclusion it applied" \
  || bad "f4abf4369 output does not name the exclusion"

rc="$(run_watch 0239dd4ee "$FX/0239dd4ee.json")"
if [ "$rc" = "0" ]; then ok "0239dd4ee -> PASS (exit 0)"; else bad "0239dd4ee -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
grep -q "0239dd4ee" "$OUT" && ok "0239dd4ee output names the sha" || bad "0239dd4ee output does not name the sha"

# ═══ 2. RED screams ══════════════════════════════════════════════════════════
section "2. FAIL/RED on 0e9246447 (Cloud gate = failure)"

rc="$(run_watch 0e9246447 "$FX/0e9246447.json")"
if [ "$rc" = "1" ]; then ok "0e9246447 -> FAIL/RED (exit 1)"; else bad "0e9246447 -> expected exit 1, got $rc"; cat "$OUT" >&2; fi
grep -q "RED      Cloud gate" "$OUT" && ok "0e9246447 names Cloud gate as the red row" || bad "0e9246447 does not name Cloud gate"
grep -q "conclusion=failure" "$OUT" && ok "0e9246447 reports the actual conclusion" || bad "0e9246447 does not report the conclusion"
grep -q "0e9246447" "$OUT" && ok "0e9246447 output names the sha" || bad "0e9246447 output does not name the sha"

# ═══ 3. THE PRESENCE ASSERTION — no verdict at all screams ═══════════════════
section "3. FAIL/MISSING x3 on the cancelled sha a5260f609"

# The runs fixture is passed on purpose (cch-w61): all NINE workflow runs on
# this sha are terminal, so the run-status discriminator has nothing to wait for
# and the scream must survive the fix intact.
rc="$(run_watch a5260f609 "$FX/a5260f609.json" "$FX/protection.json" "$WATCH" "$FX/a5260f609-runs.json")"
if [ "$rc" = "1" ]; then ok "a5260f609 -> FAIL/MISSING (exit 1), WITH its real runs payload (9 runs, all completed)"; else bad "a5260f609 -> expected exit 1, got $rc"; cat "$OUT" >&2; fi
if ! grep -q "WAITING" "$OUT"; then
  ok "a5260f609 is never softened to WAITING — nothing on that tip is in flight, so nothing is coming"
else
  bad "a5260f609 was softened to WAITING; the run-status rule is muting the never-judged case"
fi
n="$(grep -c "MISSING  " "$OUT")"
if [ "$n" = "3" ]; then ok "a5260f609 reports MISSING on all THREE watched contexts"; else bad "a5260f609 expected 3 MISSING rows, got $n"; cat "$OUT" >&2; fi
for c in "Cloud gate" "Console gate" "Elixir gate"; do
  grep -q "MISSING  $c" "$OUT" && ok "a5260f609 names $c as MISSING" || bad "a5260f609 does not name $c as MISSING"
done
# The mutation this whole design turns on: an absence-of-failure watch finds
# ZERO failing rows here and reports green.
if ! grep -q "RED      " "$OUT"; then
  ok "a5260f609 carries NO red row at all — an 'is any required row failing?' watch would report GREEN here"
else
  bad "a5260f609 unexpectedly produced a RED row; the fixture no longer proves the vacuous-green case"
fi
grep -q "a5260f609" "$OUT" && ok "a5260f609 output names the sha" || bad "a5260f609 output does not name the sha"

# ── 3b. THE EMPTY PAYLOAD — a tip nothing has registered on YET (cch-w61) ────
# The fixture arrived in wave 60 and PINNED the conflation instead of fixing it:
# on `{"check_runs": []}` the script printed MISSING x3 and exited 1, byte-
# identical to the a5260f609 case above — a tip that really was judged and never
# produced a required row. Wave 60's prose motivated the pin with the `push:`
# trigger that has since been DELETED (§11), and asserted that the vocabulary
# "does NOT distinguish absent-yet from never-judged". Both statements are now
# false, and the assertions below are the INVERSION of the ones that pinned it,
# not extra cases beside them.
#
# WHAT THIS SECTION REPORTS NOW: absence is read against a THIRD authority, the
# workflow runs on the tip. Same empty payload, two opposite verdicts —
#   * a run on the tip still in flight -> WAITING, exit 2 (rows may still appear)
#   * every run on the tip terminal     -> MISSING, exit 1 (nothing is coming)
# The empty payload alone decides nothing, which is the whole repair.
section "3b. an EMPTY check-runs payload, judged against the tip's workflow runs"

cat > "$FX/empty-payload.json" <<'JSON'
{"check_runs": []}
JSON

if grep -q '"check_runs": \[\]' "$FX/empty-payload.json"; then
  ok "empty-payload fixture is a literal {\"check_runs\": []} — the shape a fresh merge tip really has"
else
  bad "empty-payload fixture is not a literal empty check_runs array"
fi

rc="$(run_watch 026c5b1d7 "$FX/empty-payload.json" "$FX/protection.json" "$WATCH" "$FX/runs-all-inflight.json")"
if [ "$rc" = "2" ]; then
  ok "empty payload + a run still in flight -> WAITING (exit 2) — INVERTS wave 60's pinned exit 1"
else
  bad "empty payload + in-flight run -> expected exit 2 (WAITING), got $rc"; cat "$OUT" >&2
fi
if [ "$rc" != "1" ]; then
  ok "empty payload is NOT a scream while the tip is still being judged — the false red is gone"
else
  bad "empty payload still screams while a workflow run on the tip is in flight"
fi
n="$(grep -c "MISSING  " "$OUT")"
if [ "$n" = "0" ]; then
  ok "empty payload + in-flight run reports ZERO MISSING rows — INVERTS the pinned '3 MISSING rows'"
else
  bad "empty payload + in-flight run expected 0 MISSING rows, got $n"; cat "$OUT" >&2
fi
if grep -q "no check run row YET" "$OUT"; then
  ok "the WAITING row says YET, and names the in-flight workflow run that justifies it"
else
  bad "the WAITING row does not distinguish 'not yet' from 'never'"; cat "$OUT" >&2
fi
if ! grep -qE "^  ok       " "$OUT"; then
  ok "empty payload produces no green row at all — WAITING is not a pass"
else
  bad "empty payload produced a green row — a payload with zero rows cannot green anything"
fi
# ...and the other direction, on the SAME payload: nothing running, nothing
# coming. This is what stops WAITING from becoming the new vacuous green.
rc="$(run_watch 026c5b1d7 "$FX/empty-payload.json" "$FX/protection.json" "$WATCH" "$FX/runs-none.json")"
if [ "$rc" = "1" ]; then
  ok "SAME empty payload, every run terminal -> MISSING/scream (exit 1) — emptiness alone excuses nothing"
else
  bad "empty payload with no in-flight run -> expected exit 1, got $rc"; cat "$OUT" >&2
fi
n="$(grep -c "MISSING  " "$OUT")"
if [ "$n" = "3" ]; then
  ok "empty payload with nothing in flight still reports MISSING on all THREE watched contexts"
else
  bad "empty payload with nothing in flight expected 3 MISSING rows, got $n"; cat "$OUT" >&2
fi
if grep -q "MAIN'S TIP DOES NOT CARRY A GREEN VERDICT" "$OUT"; then
  ok "the scream survives for a tip nothing is still judging"
else
  bad "the scream no longer reaches the MISSING verdict"
fi

# ── 3c. THE PRODUCTION RED, RECORDED (cch-w61) ───────────────────────────────
# Scheduled run 31312071143 (2026-08-09T11:57:21Z) failed on tip 2e72d2948 with
# `MISSING Elixir gate` / `ok Cloud gate` / `ok Console gate` while main was in
# fact fine. The tip was 5m02s old (committed 11:52:30Z) and carried THIRTY-SIX
# check-run rows — the failure shape is PARTIAL ROWS, not an empty payload, so
# §3b alone could never have caught it. Recorded verbatim from
# repos/FRIKKern/barkpark/commits/2e72d294860ac5750f2b3ed711e163ec90bbed98/check-runs,
# truncated to rows started at or before 11:57:32Z, with rows that completed
# after that instant restored to `in_progress`.
section "3c. the recorded production red: 36 rows, Elixir gate absent (2e72d2948)"

cat > "$FX/2e72d2948.json" <<'JSON'
{"check_runs": [
  {"name": "Crown reconcile harness", "status": "completed", "conclusion": "skipped", "started_at": "2026-08-09T11:52:33Z", "id": 93240791246},
  {"name": "Stale verdict harness", "status": "completed", "conclusion": "skipped", "started_at": "2026-08-09T11:52:33Z", "id": 93240791311},
  {"name": "Break-glass harness", "status": "completed", "conclusion": "skipped", "started_at": "2026-08-09T11:52:33Z", "id": 93240791420},
  {"name": "Doc budgets + anchors", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:52:35Z", "id": 93240791074},
  {"name": "Crown reconcile", "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T11:52:36Z", "id": 93240791029},
  {"name": "Break-glass watch", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:52:36Z", "id": 93240791039},
  {"name": "Stale verdict watch", "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T11:52:36Z", "id": 93240791093},
  {"name": "Dispatch (console paths)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:52:48Z", "id": 93240810397},
  {"name": "Console path-escape ratchet", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:52:48Z", "id": 93240810427},
  {"name": "Billing tier floor (rendered)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:53:06Z", "id": 93240840686},
  {"name": "Overflow guard (rendered)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:53:07Z", "id": 93240840680},
  {"name": "CSSOM parity (authored CSS vs browser)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:53:07Z", "id": 93240840688},
  {"name": "Console client unit harness", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:53:13Z", "id": 93240840705},
  {"name": "Dispatch (cloud paths)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:53:46Z", "id": 93240911117},
  {"name": "Cloud path-escape ratchet", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:53:47Z", "id": 93240911082},
  {"name": "Required-check spec drift (advisory)", "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T11:53:59Z", "id": 93240931789},
  {"name": "Required-check spec gate", "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T11:54:00Z", "id": 93240931862},
  {"name": "Cloud control-plane (compile + format) (27.0, 1.18.1)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:54:03Z", "id": 93240937258},
  {"name": "Cloud control-plane (test) (27.0, 1.18.1)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:54:04Z", "id": 93240937262},
  {"name": "Crown reconcile harness", "status": "completed", "conclusion": "skipped", "started_at": "2026-08-09T11:54:12Z", "id": 93240956214},
  {"name": "Crown reconcile", "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T11:54:14Z", "id": 93240955993},
  {"name": "Console gate", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:54:45Z", "id": 93241009571},
  {"name": "Dispatch (compose-smoke paths)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:54:59Z", "id": 93241034142},
  {"name": "Green arm (build, boot, in-container probes)", "status": "in_progress", "conclusion": null, "started_at": "2026-08-09T11:55:14Z", "id": 93241057932},
  {"name": "Refusal arm (short SECRET_KEY_BASE refuses at boot)", "status": "in_progress", "conclusion": null, "started_at": "2026-08-09T11:55:14Z", "id": 93241057949},
  {"name": "Dispatch (security paths)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:55:29Z", "id": 93241083329},
  {"name": "Security gate shape ratchet", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:55:30Z", "id": 93241083264},
  {"name": "Sobelow baseline does not swallow its own inline waivers (blocking)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:55:43Z", "id": 93241106504},
  {"name": "Dependency CVE audit (mix_audit over mix.lock, blocking) (27.0, 1.18.1)", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:55:43Z", "id": 93241106517},
  {"name": "Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)", "status": "in_progress", "conclusion": null, "started_at": "2026-08-09T11:55:43Z", "id": 93241106526},
  {"name": "Cloud gate", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:56:30Z", "id": 93241185015},
  {"name": "Break-glass harness", "status": "completed", "conclusion": "skipped", "started_at": "2026-08-09T11:57:13Z", "id": 93241262064},
  {"name": "Break-glass watch", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T11:57:15Z", "id": 93241261642},
  {"name": "Main gate watch harness", "status": "completed", "conclusion": "skipped", "started_at": "2026-08-09T11:57:22Z", "id": 93241277275},
  {"name": "Main gate watch", "status": "in_progress", "conclusion": null, "started_at": "2026-08-09T11:57:24Z", "id": 93241276860},
  {"name": "Security gate", "status": "in_progress", "conclusion": null, "started_at": "2026-08-09T11:57:32Z", "id": 93241288929}
]}
JSON

n="$(jq '.check_runs | length' "$FX/2e72d2948.json")"
if [ "$n" = "36" ]; then ok "2e72d2948 fixture carries 36 check-run rows — PARTIAL, not empty"; else bad "2e72d2948 fixture should carry 36 rows, carries $n"; fi
if ! jq -e '[.check_runs[].name] | index("Elixir gate")' "$FX/2e72d2948.json" >/dev/null 2>&1; then
  ok "2e72d2948 fixture has NO 'Elixir gate' row — the one absent required context"
else
  bad "2e72d2948 fixture grew an 'Elixir gate' row; it no longer reproduces run 31312071143"
fi

# THE VERDICT UNDER THE FIX. Same 36 rows, and the elixir run on this tip is not
# terminal, so the absent row is WAITING rather than a scream.
rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$WATCH" "$FX/2e72d2948-runs.json")"
if [ "$rc" = "2" ]; then
  ok "2e72d2948 (young tip, elixir run in flight) -> WAITING (exit 2) — production run 31312071143 would not have red"
else
  bad "2e72d2948 -> expected exit 2 (WAITING), got $rc"; cat "$OUT" >&2
fi
if ! grep -q "MISSING  Elixir gate" "$OUT"; then
  ok "'Elixir gate' is no longer called MISSING on a tip whose elixir run has not finished"
else
  bad "'Elixir gate' is still MISSING on 2e72d2948 — the production red is NOT fixed"; cat "$OUT" >&2
fi
grep -q "elixir #31311871968 (status=queued)" "$OUT" \
  && ok "the output names the elixir run 31311871968 as still in flight — the actual reason the row is absent" \
  || bad "the output does not name the in-flight elixir run"
grep -q "WAITING  Elixir gate" "$OUT" && ok "Elixir gate is reported WAITING by name" || bad "Elixir gate is not reported WAITING"
grep -q "ok       Cloud gate" "$OUT" && ok "Cloud gate is still read as green on 2e72d2948" || bad "Cloud gate is no longer green on 2e72d2948"
grep -q "ok       Console gate" "$OUT" && ok "Console gate is still read as green on 2e72d2948" || bad "Console gate is no longer green on 2e72d2948"

# THE COUNTERFACTUAL, which is what keeps this from being a mute button: the
# SAME 36 rows with every run on the tip terminal is a tip that finished being
# judged without an Elixir verdict, and it must scream.
rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$WATCH" "$FX/2e72d2948-runs-terminal.json")"
if [ "$rc" = "1" ]; then
  ok "2e72d2948 with every run terminal -> MISSING/scream (exit 1) — partial rows are not an excuse by themselves"
else
  bad "2e72d2948 with all runs terminal -> expected exit 1, got $rc"; cat "$OUT" >&2
fi
grep -q "MISSING  Elixir gate" "$OUT" && ok "the terminal counterfactual names Elixir gate as MISSING" || bad "the terminal counterfactual does not name Elixir gate"

# THE GUARD MUST BE ABLE TO LOSE. Revert the discriminator in a specimen copy —
# blank the in-flight accumulator — and the WAITING verdict above must collapse
# back to the production red.
sed 's/^    \[ "\$rstatus" = "completed" \] && continue$/    continue/' "$WATCH" > "$TMP/no-discriminator.sh"
if ! cmp -s "$WATCH" "$TMP/no-discriminator.sh"; then
  ok "specimen built: the run-status accumulator is neutralised (the sed CHANGED the source)"
else
  bad "the revert specimen is byte-identical to the shipped script — this mutation proves nothing"
fi
rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$TMP/no-discriminator.sh" "$FX/2e72d2948-runs.json")"
if [ "$rc" = "1" ] && grep -q "MISSING  Elixir gate" "$OUT"; then
  ok "without the discriminator 2e72d2948 reds again (exit 1, MISSING Elixir gate) — the fix is load-bearing"
else
  bad "reverting the discriminator changed nothing (exit $rc); the run-status arm is decorative"; cat "$OUT" >&2
fi

# ── 3d. THE THIRD AUTHORITY CANNOT FAIL OPEN ─────────────────────────────────
# More endpoints is more ways to be blind. A runs read that cannot be trusted
# must reach the SAME exit-3 vocabulary as an unreadable protection object,
# never fall through to a verdict.
section "3d. an unreadable runs payload is a CONFIGURATION FAULT, not a verdict"

rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$WATCH" "$FX/runs-garbage.json")"
if [ "$rc" = "3" ]; then ok "a non-JSON runs body -> exit 3 (UNREADABLE), not a verdict"; else bad "garbage runs body -> expected exit 3, got $rc"; cat "$OUT" >&2; fi
grep -q "CONFIGURATION FAULT" "$OUT" && ok "the runs fault is labelled CONFIGURATION FAULT" || bad "the runs fault is not labelled"

rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$WATCH" "$FX/runs-forbidden.json")"
if [ "$rc" = "3" ]; then ok "a recorded 403 body from the runs endpoint -> exit 3, not a verdict"; else bad "403 runs body -> expected exit 3, got $rc"; cat "$OUT" >&2; fi

# ADDED IN REVIEW (cch-w61). This is the one predictable way the new read fails
# after merge: GH_TOKEN is `secrets.BREAKGLASS_TOKEN || github.token`, and a
# fine-grained PAT without Actions: read 403s HERE while branch protection and
# check-runs keep reading fine. Exit 3 is honest; a fault that recurs every 30
# minutes and does not say how to clear itself is how a watch gets muted. So the
# FORBIDDEN arm must name the credential AND the permission, not just complain.
#
# Asserted ON THE SOURCE, and that limitation is the point rather than a dodge:
# the hermetic harness cannot reach `gh`, so the recorded 403 BODY above lands in
# the UNREADABLE arm (a file body is not JSON), never in FORBIDDEN. Scanning the
# FORBIDDEN block itself is the strongest hermetic statement available — the same
# discipline §3d already uses for the 401/403 classifier and §7 uses for
# protection. A live 403 is still unproven here; it is proven only by the
# workflow running.
# Anchored on the RUNS case block by name — there is an earlier `FORBIDDEN)` arm
# on the protection reader, and a bare /FORBIDDEN)/ match lands on that one.
forbidden_block="$(awk '/case "\$tip_runs" in/{f=1} f{print} f && /^  esac$/{exit}' "$WATCH" \
  | awk '/^    FORBIDDEN\)$/{f=1} f{print} f && /return 3 ;;/{exit}')"
if grep -q "Actions: read" <<<"$forbidden_block"; then
  ok "the FORBIDDEN arm names the PERMISSION that clears it (Actions: read)"
else
  bad "the FORBIDDEN arm does not name Actions: read — the operator is told there is a fault, not how to fix it"
fi
if grep -q "GH_TOKEN" <<<"$forbidden_block" && grep -q "BREAKGLASS_TOKEN" <<<"$forbidden_block"; then
  ok "the FORBIDDEN arm names the CREDENTIAL that needs it, and the secret that overrides the default"
else
  bad "the FORBIDDEN arm does not name GH_TOKEN / BREAKGLASS_TOKEN"
fi
# The specimen must be a real extraction, not an empty string that greps false
# in both directions and quietly turns two assertions into noise.
if [ "$(printf '%s\n' "$forbidden_block" | wc -l)" -ge 5 ]; then
  ok "the FORBIDDEN block was actually extracted ($(printf '%s\n' "$forbidden_block" | wc -l | tr -d ' ') lines) — the two assertions above scanned something"
else
  bad "the FORBIDDEN block extraction is empty or truncated; the assertions above prove nothing"
fi
# ...and it is not boilerplate pasted onto every fault: the UNREADABLE arm is a
# different diagnosis (the endpoint answered garbage) and must NOT claim a
# permission fix would help.
rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$WATCH" "$FX/runs-garbage.json")"
if ! grep -q "Actions: read" "$OUT"; then
  ok "the UNREADABLE arm does NOT prescribe the permission remedy — a wrong remedy is worse than none"
else
  bad "the permission remedy leaked onto the UNREADABLE arm, which is not a credential fault"; cat "$OUT" >&2
fi

rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$WATCH" "$FX/does-not-exist.json")"
if [ "$rc" = "3" ]; then ok "a runs file that does not exist -> exit 3"; else bad "missing runs file -> expected exit 3, got $rc"; cat "$OUT" >&2; fi

# The live arm classifies a credential failure as FORBIDDEN with the same
# patterns the protection reader uses — asserted on the source because the
# hermetic path cannot reach `gh`.
# Materialised, not piped (honest-gates D37): `awk … | grep -q` under pipefail
# can report the producer's SIGPIPE 141 instead of grep's 0, which reads here as
# "there is no FORBIDDEN arm".
watch_forbidden_arm="$(awk '/^read_workflow_runs\(\)/{f=1} f && /HTTP 401\|HTTP 403/{print "yes"; exit} f && /^}/{exit}' "$WATCH")"
if [ "$watch_forbidden_arm" = yes ]; then
  ok "read_workflow_runs classifies 401/403 as FORBIDDEN, like the protection reader"
else
  bad "read_workflow_runs has no FORBIDDEN arm — an Actions 403 would not be distinguishable"
fi
# ...and prove the exit-3 routing can LOSE: delete the case that catches those
# tokens and the garbage body stops being a fault.
sed '/^  case "\$tip_runs" in$/,/^  esac$/d' "$WATCH" > "$TMP/runs-fault-swallowed.sh"
if ! cmp -s "$WATCH" "$TMP/runs-fault-swallowed.sh"; then
  ok "specimen built: the runs-fault case block is deleted (the sed CHANGED the source)"
else
  bad "the runs-fault specimen is byte-identical — this mutation proves nothing"
fi
rc="$(run_watch 2e72d2948 "$FX/2e72d2948.json" "$FX/protection.json" "$TMP/runs-fault-swallowed.sh" "$FX/runs-garbage.json")"
if [ "$rc" != "3" ]; then
  ok "without that case block an unreadable runs payload stops being a fault (exit $rc) — the routing is load-bearing"
else
  bad "deleting the runs-fault case block changed nothing; the exit-3 routing is decorative"
fi

# ═══ 4. WAITING is neither a pass nor a scream ═══════════════════════════════
section "4. WAITING (keyed on .status, conclusion null)"

rc="$(run_watch deadbeef1 "$FX/waiting.json")"
if [ "$rc" = "2" ]; then ok "in-flight tip -> WAITING (exit 2)"; else bad "in-flight tip -> expected exit 2, got $rc"; cat "$OUT" >&2; fi
[ "$rc" != "0" ] && ok "WAITING is NOT a pass (exit != 0)" || bad "WAITING was treated as a pass"
[ "$rc" != "1" ] && ok "WAITING is NOT a scream (exit != 1)" || bad "WAITING was treated as a scream"
grep -q "WAITING  Cloud gate" "$OUT" && ok "WAITING names the in-flight context" || bad "WAITING does not name the in-flight context"
if ! grep -q "MISSING  Cloud gate" "$OUT"; then
  ok "an in-flight context is NOT misread as MISSING (the false-red every fresh push would produce)"
else
  bad "an in-flight context was misread as MISSING"
fi

rc="$(run_watch deadbeef2 "$FX/waiting-and-red.json")"
if [ "$rc" = "1" ]; then ok "waiting + red -> the scream wins (exit 1)"; else bad "waiting + red -> expected exit 1, got $rc"; cat "$OUT" >&2; fi

# ═══ 5. the exclusion is load-bearing, proven by MUTATION ════════════════════
section "5. mutation: blank the exclusion and the known-green sha turns RED"

sed 's/^EXCLUDED_CONTEXTS=.*/EXCLUDED_CONTEXTS=""/' "$WATCH" > "$TMP/no-exclusion.sh"
if grep -q 'EXCLUDED_CONTEXTS=""' "$TMP/no-exclusion.sh"; then
  ok "specimen built (EXCLUDED_CONTEXTS blanked)"
else
  bad "could not build the no-exclusion specimen — EXCLUDED_CONTEXTS is no longer a named constant on its own line"
fi
rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection.json" "$TMP/no-exclusion.sh")"
# Without the exclusion, "PR references an active task" is unclassified: the
# roster assertion catches it (exit 3) rather than letting it false-red as
# MISSING. Either way the specimen must NOT report green on the known-green sha.
if [ "$rc" != "0" ]; then
  ok "without the exclusion the KNOWN-GREEN sha stops being green (exit $rc) — the exclusion is load-bearing"
else
  bad "blanking the exclusion changed nothing; the exclusion is decorative"
fi

# ═══ 6. the roster assertion ═════════════════════════════════════════════════
section "6. an unclassified required context is a CONFIGURATION FAULT"

rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection-unclassified.json")"
if [ "$rc" = "3" ]; then ok "unclassified required context -> exit 3"; else bad "unclassified required context -> expected exit 3, got $rc"; cat "$OUT" >&2; fi
grep -q "Brand new gate" "$OUT" && ok "the fault names the unclassified context" || bad "the fault does not name the unclassified context"
grep -q "CONFIGURATION FAULT" "$OUT" && ok "the fault says CONFIGURATION FAULT" || bad "the fault is not labelled"

# ═══ 7. no authority is never green ══════════════════════════════════════════
section "7. unreadable / forbidden protection reds, even on a green sha"

rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection-forbidden.json")"
if [ "$rc" = "3" ]; then ok "403 on protection -> exit 3 even though the sha is green"; else bad "403 on protection -> expected exit 3, got $rc"; cat "$OUT" >&2; fi

echo '{"required_status_checks": null}' > "$FX/protection-empty.json"
rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection-empty.json")"
if [ "$rc" = "3" ]; then ok "protection with no required_status_checks -> exit 3, not an empty green"; else bad "empty protection -> expected exit 3, got $rc"; cat "$OUT" >&2; fi

# ═══ 8. the required set is read LIVE, not from the committed spec ═══════════
section "8. the watched set comes from protection, not .github/required-checks.json"

if grep -qE 'required_status_checks\.checks\[\]\.context' "$WATCH"; then
  ok "the required set is derived from the protection object"
else
  bad "the required set is not derived from the protection object"
fi
if grep -qE '\.github/required-checks\.json' "$WATCH" && ! grep -qE 'jq .* required_status_checks.*"\$SPEC"' "$WATCH"; then
  ok "the committed spec is used only for repo/branch identity, never for the watched contexts"
else
  bad "the committed spec appears to feed the watched contexts (it would go stale silently)"
fi

# ═══ 9. re-runs: the LATEST row decides ══════════════════════════════════════
section "9. a re-run's latest row decides the verdict"

rc="$(run_watch cafe0001 "$FX/rerun-green-last.json")"
if [ "$rc" = "0" ]; then ok "red-then-green re-run -> PASS"; else bad "red-then-green re-run -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
rc="$(run_watch cafe0002 "$FX/rerun-red-last.json")"
if [ "$rc" = "1" ]; then ok "green-then-red re-run -> SCREAM"; else bad "green-then-red re-run -> expected exit 1, got $rc"; cat "$OUT" >&2; fi

# ── 9b. THE PAGINATED STREAM (added in review, cch-w59) ──────────────────────
# `gh api --paginate` on an OBJECT endpoint emits one JSON DOCUMENT PER PAGE,
# not one merged object. A dedup that groups per document lets an older re-run
# row on page 1 decide a context whose LATEST row is on page 2 — a permanent
# stale FALSE RED, which is exactly how a watch gets muted. The reader slurps
# the whole stream before grouping; these two fixtures are multi-document on
# purpose and would have failed the pre-review reader.
cat > "$FX/paged-rerun-green-last.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T01:00:00Z", "id": 2}
]}
{"check_runs": [
  {"name": "Console gate", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 3},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 4}
]}
JSON

cat > "$FX/paged-rerun-red-last.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 2}
]}
{"check_runs": [
  {"name": "Console gate", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 3},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T02:00:00Z", "id": 4}
]}
JSON

rc="$(run_watch cafe0003 "$FX/paged-rerun-green-last.json")"
if [ "$rc" = "0" ]; then ok "PAGED red-then-green re-run (rows on two pages) -> PASS"; else bad "PAGED red-then-green -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
rc="$(run_watch cafe0004 "$FX/paged-rerun-red-last.json")"
if [ "$rc" = "1" ]; then ok "PAGED green-then-red re-run (rows on two pages) -> SCREAM"; else bad "PAGED green-then-red -> expected exit 1, got $rc"; cat "$OUT" >&2; fi

# ═══ 10. it is offline ═══════════════════════════════════════════════════════
section "10. offline: the hermetic path makes no API call"

# The stub exits 97 and prints to stderr. If any case above had reached it, the
# exit codes would not have matched — but assert it directly too.
rc="$(run_watch f4abf4369 "$FX/f4abf4369.json")"
if ! grep -q "this test is offline" "$OUT"; then
  ok "no gh invocation on the hermetic path"
else
  bad "the script called gh despite --protection-file and --check-runs-file"
fi

# ═══ 11. the workflow can never enter the required set ═══════════════════════
section "11. workflow structure (the four breakglass-watch properties)"

[ -f "$WF" ] && ok "workflow exists: .github/workflows/main-gate-watch.yml" || bad "workflow missing"
grep -q "cron:" "$WF"                       && ok "schedule trigger"        || bad "no schedule trigger"
grep -q "workflow_dispatch:" "$WF"          && ok "workflow_dispatch"       || bad "no workflow_dispatch"

# THERE MUST BE NO push: TRIGGER (cch-w60, D721). It fired ~19s after a merge,
# reached the empty-payload case pinned in §3b, and red by construction: 2 of 2
# production push runs failed on tip 026c5b1d78 while main was in fact green.
# Comments are stripped first — this workflow's prose argues about push at
# length and a naive grep would red on its own explanation.
#
# The stripped text is MATERIALISED, never piped — honest-gates D37, the same
# rule the continue-on-error check below already follows. `sed … "$WF" | grep
# -qE …` is a PIPELINE: grep exits at its first match, sed takes SIGPIPE on its
# next write, and `pipefail` reports sed's 141 instead of grep's 0. Here that
# false 141 flowed into the ELSE branch of the MUTANT check below and reported
# the no-push check vacuous on a mutant that did carry push: — 1 of 84 failing
# on every macOS run while CI stayed green.
wf_nocomment="$(sed 's/#.*//' "$WF")"
if grep -qE '^[[:space:]]*push:' <<<"$wf_nocomment"; then
  bad "the workflow carries a push: trigger — it reds by construction on every merge (see 3b)"
else
  ok "no push: trigger at all — the merge-time false red cannot recur"
fi
# ...and prove that check can LOSE rather than trusting a grep that may simply
# never match anything.
#
# The mutant is built with awk, not `sed 's/…/a\nb/'`. BSD sed has no `\n`
# escape in a REPLACEMENT: on macOS that form emits the literal letter `n` and
# collapses the three intended lines into one mangled `  push:n    branches:
# [main]n  workflow_dispatch:`. The old form therefore asserted on a mutant it
# had not actually built (mode 6) — and it "passed" only because that mangled
# line still happens to start with `push:`. Assert the mutant DIFFERS and
# carries a real, well-formed push: block before believing any verdict from it.
awk '/^  workflow_dispatch:/ && !done { print "  push:"; print "    branches: [main]"; done = 1 } { print }' \
  "$WF" > "$TMP/wf-push-readded.yml"
if cmp -s "$WF" "$TMP/wf-push-readded.yml"; then
  bad "the push: mutant was never BUILT (the anchor did not match) — the next assertion would prove nothing"
elif [ "$(grep -c '^  push:$' "$TMP/wf-push-readded.yml")" != 1 ] \
  || ! grep -q '^    branches: \[main\]$' "$TMP/wf-push-readded.yml"; then
  bad "the push: mutant is malformed — it does not carry exactly one well-formed push: trigger block"
else
  ok "the push: mutant BUILT: exactly one well-formed 'push:' + 'branches: [main]' the original does not have"
fi
wf_mutant_nocomment="$(sed 's/#.*//' "$TMP/wf-push-readded.yml")"
if grep -qE '^[[:space:]]*push:' <<<"$wf_mutant_nocomment"; then
  ok "the no-push check catches a re-added push: trigger (it can lose)"
else
  bad "the no-push check did not catch a re-added push: trigger — it is vacuous"
fi

grep -q "if: github.event_name != 'pull_request'" "$WF" \
  && ok "watch job carries if: github.event_name != 'pull_request'" \
  || bad "watch job is missing the pull_request guard"

# The pull_request trigger must be paths-filtered — belt and braces with the if:.
# Materialised, not piped: `awk … | grep -q` is the same SIGPIPE pipeline as
# above — the awk exits on its own `exit`, but pipefail can still surface a 141
# from the write that races grep's exit, and a 141 reads as "not paths-filtered".
wf_pr_paths="$(awk '/^  pull_request:/{f=1} f && /^    paths:/{print "yes"; exit}' "$WF")"
if [ "$wf_pr_paths" = yes ]; then
  ok "the pull_request trigger is paths-filtered"
else
  bad "the pull_request trigger is NOT paths-filtered"
fi

# Comments are stripped first: this file ARGUES about continue-on-error at
# length, and a naive grep would red on its own prose.
#
# The stripped text is materialised, never piped — honest-gates D37. `sed … "$WF"
# | grep -q …` looks like a file match but is a PIPELINE: `grep -q` exits at its
# first match, the `sed` takes SIGPIPE on its next write, and `set -o pipefail`
# reports the sed's 141 instead of grep's 0. The `if` below then takes the ELSE
# branch — printing "no continue-on-error in any directive" over a workflow that
# carries one. That is the same false green #12754 fixed in the sibling harness
# scripts/webhook-fanout-watch.test.sh, and this is the loudest place to lose it.
wf_stripped="$(sed 's/#.*//' "$WF")"
if grep -q "continue-on-error" <<<"$wf_stripped"; then
  bad "the workflow carries continue-on-error — it would launder the run conclusion to success"
else
  ok "no continue-on-error in any directive: the run conclusion IS the scream"
fi
# ...and prove that check can LOSE, rather than trusting a grep that may simply
# never match anything.
# Built with awk for the same reason as the push: mutant — BSD sed cannot put a
# newline in a replacement, so the sed form emitted `    continue-on-error:
# truen    runs-on: ubuntu-latest` on macOS: one mangled line that only matched
# because the substring `continue-on-error` survived the mangling. Build it
# properly and assert it BUILT before asserting on it.
awk '/^    runs-on: ubuntu-latest/ && !done { print "    continue-on-error: true"; done = 1 } { print }' \
  "$WF" > "$TMP/wf-laundered.yml"
if cmp -s "$WF" "$TMP/wf-laundered.yml"; then
  bad "the continue-on-error mutant was never BUILT (the anchor did not match) — the next assertions would prove nothing"
elif [ "$(grep -c '^    continue-on-error: true$' "$TMP/wf-laundered.yml")" != 1 ]; then
  bad "the continue-on-error mutant is malformed — no single well-formed 'continue-on-error: true' directive"
else
  ok "the continue-on-error mutant BUILT: exactly one well-formed directive the original does not have"
fi
wf_laundered_stripped="$(sed 's/#.*//' "$TMP/wf-laundered.yml")"
if grep -q "continue-on-error" <<<"$wf_laundered_stripped"; then
  ok "the continue-on-error check catches an injected specimen (it can lose)"
else
  bad "the continue-on-error check did not catch an injected specimen — it is vacuous"
fi
# ...and prove it survives the pipe-buffer condition that made the old pipeline
# form a coin flip: same planted specimen, padded past any pipe buffer.
# (the padding itself is generated by awk, not `yes | head` — that pipeline's
# own status is a 141 by construction and there is no reason to put one in a
# file whose subject is exactly that failure mode.)
{ cat "$TMP/wf-laundered.yml"
  awk 'BEGIN { for (i = 0; i < 3000; i++) print "        key: padding past the pipe buffer" }'
} > "$TMP/wf-laundered-padded.yml"
wf_padded_stripped="$(sed 's/#.*//' "$TMP/wf-laundered-padded.yml")"
if grep -q "continue-on-error" <<<"$wf_padded_stripped"; then
  ok "the continue-on-error check still catches it when the stripped text overruns the pipe buffer"
else
  bad "the continue-on-error check lost the specimen to a SIGPIPE race (pipefail read the producer's 141 as 'no match')"
fi

if grep -qE 'cancel-in-progress: true' "$WF"; then
  bad "cancel-in-progress is a literal true — a push to main would self-cancel the watch dark"
else
  ok "cancel-in-progress never self-cancels on main"
fi

# ═══ 12. the spec did not grow this workflow's names ═════════════════════════
section "12. the required-checks spec is unchanged by this slice"

if [ -f "$SPEC" ]; then
  if jq -e '[.protection.required_status_checks.checks[].context] | index("Main gate watch")' "$SPEC" >/dev/null 2>&1; then
    bad "'Main gate watch' entered the required set"
  else
    ok "'Main gate watch' is NOT in the required set"
  fi
  if jq -e '[.protection.required_status_checks.checks[].context] | index("Main gate watch harness")' "$SPEC" >/dev/null 2>&1; then
    bad "'Main gate watch harness' entered the required set"
  else
    ok "'Main gate watch harness' is NOT in the required set"
  fi
else
  bad "required-checks spec not found at $SPEC"
fi

# ═══ 13. the workflow is valid YAML ══════════════════════════════════════════
section "13. YAML parses"

if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))" >/dev/null 2>&1; then
    ok "main-gate-watch.yml parses as YAML"
  else
    bad "main-gate-watch.yml is not valid YAML"
  fi
else
  echo "  skip python3+pyyaml unavailable — YAML parse not checked here (CI parses it by running the workflow)"
fi


# ═══ 14. rc 3 and rc 1 red under DIFFERENT check-run names ═══════════════════
# cch-w59-bl-main-gate-watch-has-no-notification-egress, residual 1. The defect
# was that ONE step of ONE job mapped BOTH "main's tip is not green" (rc 1) and
# "this watch could not read branch protection" (rc 3) to `exit 1`, so a broken
# watcher rendered exactly like a red main.
#
# The proof has to FORCE BOTH, which is why the rc->outcome table lives in
# scripts/main-gate-watch-route.sh instead of in a `run:` block nobody can drive
# offline. Two halves, and BOTH are needed:
#   (a) the router: for every rc, exactly the right role reds.
#   (b) the wiring: the workflow actually gives the two roles two different job
#       NAMES, and actually skips the verdict job on rc 3. A perfect router
#       wired into one job proves nothing.
section "14. a CONFIGURATION FAULT and a red main red under different names"

ROUTE="$REPO_ROOT/scripts/main-gate-watch-route.sh"

if [ -f "$ROUTE" ]; then
  ok "the router exists: scripts/main-gate-watch-route.sh"
else
  bad "scripts/main-gate-watch-route.sh is missing — the two failure classes have no separate owner"
fi

# (a) FORCE EVERY rc THROUGH BOTH ROLES — as JOB OUTCOMES, not as raw exits.
# The run-level fact the residual is about is the PAIR of check-run conclusions,
# and the verdict job's conclusion on rc 3 is SKIPPED (its `if:` fences rc 3
# out), not an exit code. Modelling only the router's exits would score rc 3 as
# "both red" and miss that the split works. So the fence is modelled here, and
# the wiring half below proves the workflow really carries it.
route_rc() {  # role rc -> prints exit code, never dies
  local r=0
  bash "$ROUTE" "$1" "$2" >/dev/null 2>&1 || r=$?
  echo "$r"
}
# The fence, verbatim from the verdict job's `if:` in the workflow: rc '' or '3'
# -> the job never runs. Anything else -> the router decides.
verdict_job() {
  case "$1" in
    ''|3) echo skipped ;;
    *)    if [ "$(route_rc verdict "$1")" = 0 ]; then echo green; else echo RED; fi ;;
  esac
}
fault_job() {
  if [ "$(route_rc fault "$1")" = 0 ]; then echo green; else echo RED; fi
}
while read -r rc want_fault want_verdict note; do
  got_fault="$(fault_job "$rc")"
  got_verdict="$(verdict_job "$rc")"
  if [ "$got_fault" = "$want_fault" ] && [ "$got_verdict" = "$want_verdict" ]; then
    ok "rc=$rc: 'Main gate watch configuration fault' $got_fault, 'Main gate watch' $got_verdict ($note)"
  else
    bad "rc=$rc: fault job $got_fault (want $want_fault), verdict job $got_verdict (want $want_verdict) — $note"
  fi
done <<'TABLE'
0 green green green:-neither-check-run-screams
1 green RED red-main:-ONLY-'Main-gate-watch'-screams
2 green green waiting:-neither-check-run-screams
3 RED skipped CONFIGURATION-FAULT:-ONLY-the-fault-name-screams,-and-the-verdict-name-is-SKIPPED-(never-green)
TABLE

# The two rows that carry the whole residual, asserted AGAINST EACH OTHER rather
# than only against constants: the PAIR of check-run conclusions must DIFFER
# between a red main and a configuration fault, and in particular the name that
# screams must not be the same name. If a future edit fused the classes again,
# every row above could still be re-baselined one-by-one while this one could
# not be satisfied at all without a real split.
pair1="$(fault_job 1)/$(verdict_job 1)"
pair3="$(fault_job 3)/$(verdict_job 3)"
if [ "$pair1" != "$pair3" ] && [ "$(verdict_job 1)" = RED ] && [ "$(fault_job 3)" = RED ] \
   && [ "$(fault_job 1)" != RED ] && [ "$(verdict_job 3)" != RED ]; then
  ok "a red main (fault/verdict = $pair1) and a CONFIGURATION FAULT ($pair3) scream under DIFFERENT names"
else
  bad "a red main ($pair1) and a CONFIGURATION FAULT ($pair3) are not separated by name — the classes are fused"
fi

# And on a fault the verdict name must be SKIPPED, never green: "this watch has
# no authority" must not render as "main is fine". (A `|| true` softening would
# show up here as `green`.)
if [ "$(verdict_job 3)" = skipped ]; then
  ok "on a CONFIGURATION FAULT 'Main gate watch' is SKIPPED, not green — no authority, no verdict"
else
  bad "on a CONFIGURATION FAULT 'Main gate watch' renders $(verdict_job 3) — a watch with no authority must never report success"
fi

# The defensive arm: if the fence ever drifts and rc 3 DOES reach the verdict
# role, it must red as a routing error rather than answer a question it cannot.
if [ "$(route_rc verdict 3)" != 0 ]; then
  ok "if the fence drifts and rc=3 reaches the verdict role anyway, the router reds instead of guessing"
else
  bad "the verdict role passes on rc=3 — a drifted fence would render a green verdict with no authority behind it"
fi

# An rc the script does not define, and a MISSING rc (the shape an empty
# `needs.<job>.outputs.rc` takes when the upstream job died before writing
# GITHUB_OUTPUT), must never read as a pass in either role.
for bogus in 7 "" "x"; do
  bf="$(route_rc fault "$bogus")"; bv="$(route_rc verdict "$bogus")"
  if [ "$bf" != 0 ] && [ "$bv" != 0 ]; then
    ok "an undefined rc ('${bogus}') reds in both roles (fault=$bf verdict=$bv) — never a silent pass"
  else
    bad "an undefined rc ('${bogus}') passed a role (fault=$bf verdict=$bv)"
  fi
done

# ...and the router itself must be able to LOSE. Mutate the rc=3 fault arm to a
# pass in a scratch copy and assert the table above would have caught it.
sed 's|^        exit 1$|        exit 0|' "$ROUTE" > "$TMP/route-softened.sh"
if cmp -s "$ROUTE" "$TMP/route-softened.sh"; then
  bad "the softened-router mutant was never BUILT (no `exit 1` arm matched) — the next assertion would prove nothing"
else
  mr=0
  bash "$TMP/route-softened.sh" fault 3 >/dev/null 2>&1 || mr=$?
  if [ "$mr" = 0 ]; then
    ok "the router CAN lose: a softened copy passes on rc=3, and section 14a asserts it must not"
  else
    bad "the softened copy still reds on rc=3 — the mutation did not reach the arm, so 14a is unproven"
  fi
fi

# (b) THE WIRING. Two distinct job NAMES, each shelling its own role, and the
# verdict job fenced off rc 3. Parsed as YAML, not grepped: a `name:` is a
# structural fact and a grep over prose that ARGUES about these names would
# match its own explanation.
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  wiring="$(python3 - "$WF" <<'PYWIRE'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d.get("jobs") or {}
def job_with(role):
    hits = []
    for jid, j in jobs.items():
        for st in (j.get("steps") or []):
            if ("main-gate-watch-route.sh %s" % role) in (st.get("run") or ""):
                hits.append((jid, j.get("name") or jid, str(j.get("if") or "")))
    return hits
f, v = job_with("fault"), job_with("verdict")
problems = []
if len(f) != 1: problems.append("expected exactly 1 job shelling the router as `fault`, found %d" % len(f))
if len(v) != 1: problems.append("expected exactly 1 job shelling the router as `verdict`, found %d" % len(v))
if not problems:
    (fid, fname, fif), (vid, vname, vif) = f[0], v[0]
    if fid == vid:
        problems.append("both roles run in the SAME job `%s` — the failure classes still share one check-run name" % fid)
    if fname == vname:
        problems.append("both jobs render the SAME check-run name %r" % fname)
    if "!= '3'" not in vif.replace('"', "'"):
        problems.append("the verdict job `%s` is not fenced off rc 3 (if: %r) — a fault would red it as a red main" % (vid, vif))
    if "needs" not in (jobs[vid] or {}):
        problems.append("the verdict job `%s` does not `needs:` the job that produces the rc" % vid)
    if not problems:
        print("OK %s|%s" % (fname, vname))
if problems:
    print("BAD " + "; ".join(problems))
PYWIRE
)" || wiring="BAD the wiring reader itself failed"
  case "$wiring" in
    OK\ *) ok "the workflow wires the roles to two different check-run names: ${wiring#OK }" ;;
    *)     bad "workflow wiring: ${wiring#BAD }" ;;
  esac
else
  bad "python3+pyyaml unavailable — the wiring half of section 14 CANNOT READ, and an unread wiring is not a proven one"
fi

# ═══ 15. THE WATCH MUST NOT COUNT ITSELF AS A REASON TO WAIT ═════════════════
# RECORDED FROM PRODUCTION, not imagined. Scheduled run 35492442980
# (2026-09-20T05:44Z, tip 56e0dbca4) printed:
#
#     still in flight on this tip — a row that is absent may yet appear:
#       main-gate-watch #35492442980 (status=in_progress)
#     RED      Elixir gate — conclusion=failure
#     ok       Cloud gate
#     WAITING  Console gate — no check run row YET, and a workflow run on this
#              sha is still in flight: main-gate-watch #35492442980
#
# Its SOLE in-flight row was ITSELF. `Console gate` had never rendered on that
# sha and never did: re-running the identical script on the identical sha once
# that run went terminal prints `MISSING  Console gate` and exits 1. The watch
# is reading the tip WHILE RUNNING ON the tip, and it renders none of the
# watched contexts, so its own run can never be the run that makes an absent row
# appear. On that day only the unrelated `Elixir gate` red carried the run to a
# scream. With Elixir green — the fixture below — the MISSING row alone decided
# the verdict, and it read WAITING = exit 2 = green while a required context was
# absent from main's tip. That is a vacuous green in the repo's own
# MISSING-detector, which is the single thing this file exists to prevent.
section "15. a watch that counts its own run cannot report MISSING"

# 56e0dbca4's real rows, reduced to the three watched contexts, with Elixir gate
# flipped to success so the SELF-EXCLUSION is the only thing deciding the exit
# code. Console gate is absent because it genuinely never rendered on that sha.
cat > "$FX/self-inflight-checks.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate", "status": "completed", "conclusion": "success", "started_at": "2026-09-20T05:10:00Z", "id": 106029000001},
  {"name": "Cloud gate", "status": "completed", "conclusion": "success", "started_at": "2026-09-20T05:11:00Z", "id": 106029000002}
]}
JSON

# Every run on the tip terminal EXCEPT the watch's own run — the exact shape of
# the 05:44 read.
cat > "$FX/self-inflight-runs.json" <<'JSON'
{"workflow_runs": [
  {"name": "elixir", "status": "completed", "id": 35492000001},
  {"name": "cloud", "status": "completed", "id": 35492000002},
  {"name": "console-harness", "status": "completed", "id": 35492000003},
  {"name": "main-gate-watch", "status": "in_progress", "id": 35492442980}
]}
JSON

# DRIVEN THROUGH THE ENVIRONMENT, NOT A NEW FLAG (review of this slice). The
# first cut of this section passed `--self-run-id` on both arms. Against the
# pre-fix script that flag is an UNKNOWN ARGUMENT — exit 3 — so every
# RED-WITHOUT assertion reddened on argument rejection and measured nothing
# about the defect. GITHUB_RUN_ID is what GitHub Actions actually sets, the
# pre-fix script ignores it completely, and the same command line therefore
# exercises the real behavioural difference: identical argv, identical fixtures,
# one environment variable, two opposite verdicts.
self_watch() { # GITHUB_RUN_ID value ("" = unset)
  if [ -n "$1" ]; then
    env GITHUB_RUN_ID="$1" bash "$WATCH" --sha 56e0dbca4 \
      --protection-file "$FX/protection.json" \
      --check-runs-file "$FX/self-inflight-checks.json" \
      --runs-file "$FX/self-inflight-runs.json" > "$OUT" 2>&1
  else
    env -u GITHUB_RUN_ID bash "$WATCH" --sha 56e0dbca4 \
      --protection-file "$FX/protection.json" \
      --check-runs-file "$FX/self-inflight-checks.json" \
      --runs-file "$FX/self-inflight-runs.json" > "$OUT" 2>&1
  fi
  echo $?
}

# ── RED WITHOUT: no run id in the environment, so nothing is excluded — the
# pre-fix behaviour, and the behaviour of the FIXED script when it is not told
# which run is its own.
rc="$(self_watch "")"
if [ "$rc" = "2" ] && grep -q "WAITING  Console gate" "$OUT"; then
  ok "WITHOUT a self run id: MISSING Console gate is softened to WAITING, exit 2 — production run 35492442980's bug, reproduced"
else
  bad "WITHOUT a self run id: expected exit 2 + 'WAITING  Console gate', got exit $rc"; cat "$OUT" >&2
fi
if [ "$rc" != "1" ]; then
  ok "WITHOUT it the run does NOT scream — a required context absent from main's tip reads as green"
else
  bad "WITHOUT it the run screamed; the fixture no longer reproduces the defect"
fi
if grep -q "main-gate-watch #35492442980" "$OUT"; then
  ok "WITHOUT it the watch cites its OWN run as the reason a row may yet appear"
else
  bad "WITHOUT it the watch does not cite its own run; the fixture is not the production shape"
fi

# ── GREEN WITH: the SAME argv and the SAME fixtures, plus the GITHUB_RUN_ID
# that GitHub Actions sets on every run. Against the pre-fix script this arm is
# byte-identical to the one above and still exits 2 — which is precisely what
# makes it a mutation proof rather than an argument-parsing test.
rc="$(self_watch 35492442980)"
if [ "$rc" = "1" ]; then
  ok "WITH GITHUB_RUN_ID set: SAME argv, SAME payload -> scream (exit 1) — the fix is load-bearing"
else
  bad "WITH GITHUB_RUN_ID set: expected exit 1, got $rc"; cat "$OUT" >&2
fi
if grep -q "MISSING  Console gate" "$OUT"; then
  ok "WITH it Console gate is correctly named MISSING — no check run at all, every OTHER run terminal"
else
  bad "WITH it Console gate is still not reported MISSING"; cat "$OUT" >&2
fi
if ! grep -q "WAITING" "$OUT"; then
  ok "WITH it nothing is WAITING — the watch's own run was the entire in-flight set"
else
  bad "WITH it something is still WAITING"; cat "$OUT" >&2
fi
if grep -q "ignoring this watch's own run #35492442980" "$OUT"; then
  ok "the exclusion is STATED in the output, not silent — a reader can see why MISSING was reached"
else
  bad "the self-exclusion is silent; an unexplained verdict is how a watch gets distrusted"
fi

# ── the exclusion is keyed on the RUN ID, never the workflow NAME ────────────
# A name-keyed fix would delete every main-gate-watch run from the in-flight
# set, including a genuinely concurrent second one, and would break the moment
# the workflow is renamed. This arm fails against a name-keyed implementation.
cat > "$FX/self-inflight-runs-other.json" <<'JSON'
{"workflow_runs": [
  {"name": "elixir", "status": "completed", "id": 35492000001},
  {"name": "cloud", "status": "completed", "id": 35492000002},
  {"name": "main-gate-watch", "status": "in_progress", "id": 35492999999}
]}
JSON
rc="$(env GITHUB_RUN_ID=35492442980 bash "$WATCH" --sha 56e0dbca4 \
  --protection-file "$FX/protection.json" \
  --check-runs-file "$FX/self-inflight-checks.json" \
  --runs-file "$FX/self-inflight-runs-other.json" > "$OUT" 2>&1; echo $?)"
if [ "$rc" = "2" ] && grep -q "main-gate-watch #35492999999" "$OUT"; then
  ok "a DIFFERENT main-gate-watch run (#35492999999) still counts as in flight -> WAITING; the exclusion is id-keyed, not name-keyed"
else
  bad "a different main-gate-watch run was excluded too — the fix is name-keyed, got exit $rc"; cat "$OUT" >&2
fi

# ── the explicit flag exists too, for a caller that is not GitHub Actions ────
rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha 56e0dbca4 \
  --protection-file "$FX/protection.json" \
  --check-runs-file "$FX/self-inflight-checks.json" \
  --runs-file "$FX/self-inflight-runs.json" \
  --self-run-id 35492442980 > "$OUT" 2>&1; echo $?)"
if [ "$rc" = "1" ] && grep -q "MISSING  Console gate" "$OUT"; then
  ok "--self-run-id reaches the same verdict as the environment default"
else
  bad "--self-run-id does not reach the MISSING verdict, got exit $rc"; cat "$OUT" >&2
fi

# ── the live workflow must actually supply the id ────────────────────────────
# The script defaults SELF_RUN_ID from GITHUB_RUN_ID, which GitHub Actions sets
# on every run, so the live path needs no argument. Assert the default exists:
# without it the fix ships inert and this whole section measures nothing.
if grep -q 'SELF_RUN_ID="${GITHUB_RUN_ID:-}"' "$WATCH"; then
  ok "SELF_RUN_ID defaults from GITHUB_RUN_ID — the live scheduled run excludes itself with no workflow change"
else
  bad "SELF_RUN_ID does not default from GITHUB_RUN_ID; the fix is inert in production"
fi


# ═══ 16. NOT_OWED: the alarm is narrowed, and it is narrowed BOTH ways ═══════
# task-2253e13aba12fbe8. #19414 stopped this watch counting its own run as a
# reason to WAIT — correct — and thereby converted a MUTED problem into a LOUD
# false one: 42 of the last 50 main tips carry no `Console gate` check run at
# all, because .github/workflows/console-harness.yml is paths-filtered on its
# `push:` arm (and ONLY there — every PR head still renders the context).
#
# EVERY ARM BELOW IS DRIVEN BY A REAL SHA'S REAL FILE LIST, and the two
# directions are proven against each other, because the easy way to "fix" this
# is to make the MISSING arm unreachable — which silences the detector.
#
#   9980425e6  internal/cli/... only        -> NOT_OWED, exit 0
#   56e0dbca4  .claude/skills/... only      -> NOT_OWED, exit 0
#   a5260f609  cloud/lib/** (a WATCHED path) -> STILL MISSING x3, exit 1
section "16. NOT_OWED — a paths-declined context is silent, a touched one still screams"

CF="$TMP/changed"; mkdir -p "$CF"
printf '%s\n' 'internal/cli/manifest_declared_fact_guard_test.go' > "$CF/9980425e6.txt"
printf '%s\n' '.claude/skills/orchestrate-tasks/helpers/held-liveness.sh' > "$CF/56e0dbca4.txt"
cat > "$CF/a5260f609.txt" <<'FILES'
cloud/lib/barkpark_cloud/publish_clock.ex
cloud/lib/barkpark_cloud/web/router.ex
cloud/test/barkpark_cloud/deploy_ledger_reachability_test.exs
cloud/test/barkpark_cloud/publish_clock_test.exs
cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs
internal/cli/cloud_deploy_census_cmd.go
FILES

# The console-harness push arm really is the thing under test, so the fixture is
# the REPO'S OWN workflow directory and the REPO'S OWN manifest. A synthetic
# workflow would prove the matcher and nothing about the live filter.
WFDIR="$REPO_ROOT/.github/workflows"
MFST="$REPO_ROOT/.github/main-push-workflows.txt"

# The ground the whole section stands on. If console-harness.yml stops being
# CONDITIONAL, or its Console gate job is renamed, every arm below goes vacuous
# while still passing — so both are asserted, not assumed.
if grep -q '^\.github/workflows/console-harness\.yml	CONDITIONAL$' "$MFST"; then
  ok "PRECONDITION: console-harness.yml is CONDITIONAL in the committed manifest — the tier is read, not invented"
else
  bad "PRECONDITION FAILED: console-harness.yml is not CONDITIONAL in $MFST; section 16 measures nothing"
fi
if grep -q 'name: Console gate' "$WFDIR/console-harness.yml"; then
  ok "PRECONDITION: the job named 'Console gate' lives in console-harness.yml — the mapping is DERIVED from the tree"
else
  bad "PRECONDITION FAILED: no job named 'Console gate' in console-harness.yml; the context->workflow derivation is stale"
fi

# ── direction 1: a declined sha goes silent ─────────────────────────────────
# Fixture: the recorded 56e0dbca4 payload, whose Console gate row never existed,
# with NOTHING in flight. Before this change that is `MISSING Console gate`,
# exit 1 — proven by section 15's `--self-run-id` arm on this very payload.
for sha in 9980425e6 56e0dbca4; do
  rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha "$sha" \
    --protection-file "$FX/protection.json" \
    --check-runs-file "$FX/self-inflight-checks.json" \
    --runs-file "$FX/self-inflight-runs.json" \
    --self-run-id 35492442980 \
    --workflows-dir "$WFDIR" --manifest "$MFST" \
    --changed-files-file "$CF/$sha.txt" > "$OUT" 2>&1; echo $?)"
  if [ "$rc" = "0" ]; then
    ok "$sha touched no console path -> exit 0; the 84% false alarm is gone"
  else
    bad "$sha still exits $rc; the declined sha is not silent"; cat "$OUT" >&2
  fi
  if grep -q "NOT_OWED Console gate" "$OUT"; then
    ok "$sha names Console gate NOT_OWED — the silence is PRINTED, never merely absent"
  else
    bad "$sha does not print NOT_OWED; a silent subtraction is unauditable"; cat "$OUT" >&2
  fi
  if grep -q "MISSING  Console gate" "$OUT"; then
    bad "$sha still reports MISSING Console gate"
  else
    ok "$sha no longer reports MISSING Console gate"
  fi
done

# ── direction 2: THE NEGATIVE CONTROL. It must keep failing. ────────────────
# a5260f609 touched cloud/lib/** , which console-harness.yml's push arm watches,
# and STILL rendered no Console gate row. That is a genuinely unjudged tip and
# the whole reason the MISSING arm exists. If this arm ever passes at exit 0,
# the repair has silenced the detector wholesale and section 3 above is the only
# thing standing between that and production.
rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha a5260f609 \
  --protection-file "$FX/protection.json" \
  --check-runs-file "$FX/a5260f609.json" \
  --runs-file "$FX/a5260f609-runs.json" \
  --workflows-dir "$WFDIR" --manifest "$MFST" \
  --changed-files-file "$CF/a5260f609.txt" > "$OUT" 2>&1; echo $?)"
if [ "$rc" = "1" ]; then
  ok "a5260f609 touched cloud/lib/** and still rendered nothing -> STILL exit 1; the alarm is narrowed, not silenced"
else
  bad "a5260f609 exits $rc WITH its real file list; the MISSING arm has been made unreachable"; cat "$OUT" >&2
fi
n="$(grep -c "MISSING  " "$OUT")"
if [ "$n" = "3" ]; then
  ok "a5260f609 still reports MISSING on all THREE watched contexts, file list and all"
else
  bad "a5260f609 reports $n MISSING rows with its file list, expected 3"; cat "$OUT" >&2
fi
if grep -q "NOT_OWED" "$OUT"; then
  bad "a5260f609 produced a NOT_OWED row; a sha that TOUCHED a watched path was excused"; cat "$OUT" >&2
else
  ok "a5260f609 produces NO NOT_OWED row — owed-ness is decided by the file list, not by the tier alone"
fi

# ── the discriminator IS the file list, proven by swapping only it ──────────
# Same sha, same payloads, same argv — only the changed-files fixture differs.
# If the verdict does not move, the file list is decorative and both arms above
# are passing for a reason that has nothing to do with paths.
rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha a5260f609 \
  --protection-file "$FX/protection.json" \
  --check-runs-file "$FX/a5260f609.json" \
  --runs-file "$FX/a5260f609-runs.json" \
  --workflows-dir "$WFDIR" --manifest "$MFST" \
  --changed-files-file "$CF/9980425e6.txt" > "$OUT" 2>&1; echo $?)"
if [ "$rc" = "1" ] && grep -q "NOT_OWED Console gate" "$OUT" && [ "$(grep -c "MISSING  " "$OUT")" = "2" ]; then
  ok "swapping ONLY the file list moves Console gate from MISSING to NOT_OWED (3 MISSING -> 2 + 1 NOT_OWED) — the file list is the discriminator"
else
  bad "the file list did not move the verdict on a5260f609; it is decorative, got exit $rc"; cat "$OUT" >&2
fi
if grep -q "MISSING  Cloud gate" "$OUT" && grep -q "MISSING  Elixir gate" "$OUT"; then
  ok "...and the two ALWAYS-tier contexts are untouched by the swap — only the CONDITIONAL one moves"
else
  bad "an ALWAYS-tier context moved with the file list; the tier is not being read"; cat "$OUT" >&2
fi

# ── FAIL CLOSED: no file list must buy no silence ───────────────────────────
# Every pre-existing arm of this harness passes no --changed-files-file, so this
# is what keeps the other 109 measuring what they measured. Asserted directly
# rather than inferred from their totals.
rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha 56e0dbca4 \
  --protection-file "$FX/protection.json" \
  --check-runs-file "$FX/self-inflight-checks.json" \
  --runs-file "$FX/self-inflight-runs.json" \
  --self-run-id 35492442980 \
  --workflows-dir "$WFDIR" --manifest "$MFST" > "$OUT" 2>&1; echo $?)"
if [ "$rc" = "1" ] && grep -q "MISSING  Console gate" "$OUT"; then
  ok "with NO --changed-files-file the verdict is MISSING, exit 1 — unknown owed-ness fails CLOSED"
else
  bad "an unknown file list bought silence (exit $rc); the matcher fails OPEN"; cat "$OUT" >&2
fi

# ── FAIL CLOSED: an unreadable manifest must not excuse anything ────────────
rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha 9980425e6 \
  --protection-file "$FX/protection.json" \
  --check-runs-file "$FX/self-inflight-checks.json" \
  --runs-file "$FX/self-inflight-runs.json" \
  --self-run-id 35492442980 \
  --workflows-dir "$WFDIR" --manifest "$TMP/no-such-manifest.txt" \
  --changed-files-file "$CF/9980425e6.txt" > "$OUT" 2>&1; echo $?)"
if [ "$rc" = "1" ] && grep -q "MISSING  Console gate" "$OUT"; then
  ok "a missing manifest yields UNKNOWN -> OWED -> MISSING; the tier list cannot be deleted into silence"
else
  bad "a missing manifest silenced the watch (exit $rc)"; cat "$OUT" >&2
fi

# ── MUTATION: the tier must actually be READ from the manifest ──────────────
# A copy of the manifest with console-harness.yml demoted to ALWAYS must make
# the declined sha scream again. If it does not, the manifest read is inert and
# the script is deciding owed-ness some other way.
sed 's|^\.github/workflows/console-harness\.yml	CONDITIONAL$|.github/workflows/console-harness.yml	ALWAYS|' \
  "$MFST" > "$TMP/manifest-always.txt"
if grep -q '^\.github/workflows/console-harness\.yml	ALWAYS$' "$TMP/manifest-always.txt"; then
  rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha 9980425e6 \
    --protection-file "$FX/protection.json" \
    --check-runs-file "$FX/self-inflight-checks.json" \
    --runs-file "$FX/self-inflight-runs.json" \
    --self-run-id 35492442980 \
    --workflows-dir "$WFDIR" --manifest "$TMP/manifest-always.txt" \
    --changed-files-file "$CF/9980425e6.txt" > "$OUT" 2>&1; echo $?)"
  if [ "$rc" = "1" ] && grep -q "MISSING  Console gate" "$OUT"; then
    ok "MUTATION: demoting console-harness.yml to ALWAYS in the manifest restores the scream — the tier is genuinely read from the file"
  else
    bad "MUTATION SURVIVED: the manifest tier is inert (exit $rc); owed-ness is being decided elsewhere"; cat "$OUT" >&2
  fi
else
  bad "could not build the ALWAYS-mutant manifest; the mutation arm measured nothing"
fi

# ── MUTATION: the paths list must actually be READ from the workflow ────────
# A copy of the workflow tree whose console-harness push paths are replaced by a
# pattern matching 9980425e6's one file must flip it from NOT_OWED to MISSING.
MUTWF="$TMP/wf-mutant"; rm -rf "$MUTWF"; mkdir -p "$MUTWF"
cp "$WFDIR"/console-harness.yml "$MUTWF/" 2>/dev/null
python3 - "$MUTWF/console-harness.yml" <<'MUT'
import sys, re
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
# Replace the whole push-arm paths: block with a single pattern that matches
# internal/cli/**, which 9980425e6 touched and the real filter does not select.
out, seen, skipping = [], False, False
for line in src.splitlines(True):
    if not seen and re.match(r"^    paths:\s*$", line):
        out.append("    paths:\n"); out.append('      - "internal/cli/**"\n')
        seen, skipping = True, True
        continue
    if skipping:
        if re.match(r'^      - ', line):
            continue
        skipping = False
    out.append(line)
open(p, "w", encoding="utf-8").write("".join(out))
sys.stderr.write("mutated\n" if seen else "NOT MUTATED\n")
MUT
if grep -q 'internal/cli/\*\*' "$MUTWF/console-harness.yml"; then
  ok "built the paths-mutant workflow (push paths -> internal/cli/**)"
  rc="$(env -u GITHUB_RUN_ID bash "$WATCH" --sha 9980425e6 \
    --protection-file "$FX/protection.json" \
    --check-runs-file "$FX/self-inflight-checks.json" \
    --runs-file "$FX/self-inflight-runs.json" \
    --self-run-id 35492442980 \
    --workflows-dir "$MUTWF" --manifest "$MFST" \
    --changed-files-file "$CF/9980425e6.txt" > "$OUT" 2>&1; echo $?)"
  if [ "$rc" = "1" ] && grep -q "MISSING  Console gate" "$OUT"; then
    ok "MUTATION: a push paths: list that DOES select 9980425e6's file restores the scream — the glob is matched against the real workflow, not hardcoded"
  else
    bad "MUTATION SURVIVED: rewriting the workflow's paths: did not change the verdict (exit $rc); the matcher is not reading the file"; cat "$OUT" >&2
  fi
else
  bad "could not build the paths-mutant workflow; the mutation arm measured nothing"
fi

# The library is SOURCED, so a PR that changes only it changes this watch's
# verdict — and must dispatch this harness. An undispatched target is how a
# matcher gets edited with nothing measuring it.
if grep -q '"scripts/lib/main-push-owedness.sh"' "$WF"; then
  ok "the pull_request paths: filter lists scripts/lib/main-push-owedness.sh — a PR touching only the matcher still runs this harness"
else
  bad "scripts/lib/main-push-owedness.sh is not in $WF's paths: filter; editing the matcher dispatches nothing"
fi

bash -n "$REPO_ROOT/scripts/lib/main-push-owedness.sh" \
  && ok "scripts/lib/main-push-owedness.sh passes bash -n" \
  || bad "scripts/lib/main-push-owedness.sh has a syntax error"

# The sharing is the point: one manifest, read by BOTH instruments. Before this
# change `grep -c main-push-workflows scripts/main-gate-watch.sh` was 0 and the
# two answered differently on the same sha BY CONSTRUCTION.
if [ "$(grep -c 'main-push-workflows' "$WATCH")" -ge 1 ] \
   && [ "$(grep -c 'main-push-workflows' "$REPO_ROOT/scripts/main-verdict-presence.sh")" -ge 1 ]; then
  ok "both main-gate-watch.sh and main-verdict-presence.sh read .github/main-push-workflows.txt — one tier list, not two"
else
  bad "the two instruments do not share the tier manifest; a second hand-maintained list is back"
fi

# ═══ 17. AN ABBREVIATED SHA NEVER ANSWERS OFF AN EMPTY RUN FEED ══════════════
# task-0a44c3bc96baa8cc. The two endpoints disagree about prefixes and only one
# says so: `commits/<sha>/check-runs` accepts `a5260f609`; `actions/runs?head_sha=`
# matches the full oid ONLY and answers HTTP 200 with an EMPTY list. Every guard
# in read_workflow_runs() fires on transport or shape and NONE on that, so the
# in-flight set came back empty for the wrong reason and the watch screamed
# MISSING at a tip that was still running.
#
# MEASURED LIVE, 2026-09-20T13:36Z, on tip 769c39bd6959f1adb7428b72d9dde4237421640d
# with four runs in flight: the full oid printed WAITING and exited 2, while
# `--sha 769c39bd6` printed MISSING and exited 1. Same commit, same minute.
#
# THE STUB BELOW MODELS THAT ASYMMETRY AND NOTHING ELSE. It serves RAW payloads
# and lets the script apply its own jq — a stub that returned the finished
# answer would route around the code under test. The run-feed arm compares the
# `head_sha=` it was handed against the full oid and serves the recorded runs
# only on an exact match; anything shorter gets `{"total_count":0,...}`, which
# is precisely what GitHub does.
section "17. an abbreviated sha is widened before any head_sha= query"

S17="$TMP/s17"; mkdir -p "$S17/bin" "$S17/fx"
# A synthetic oid that is NOT an object in this checkout, so full_oid()'s local
# `git rev-parse` arm cannot resolve it and the API arm is the one measured.
S17_FULL="1234567890abcdef1234567890abcdef12345678"
S17_SHORT="1234567890a"
printf '%s' "$S17_FULL" > "$S17/fx/FULL"
cp "$FX/protection.json" "$S17/fx/protection.json"

cat > "$S17/bin/gh" <<STUB
#!/usr/bin/env bash
FXD="$S17/fx"
STUB
cat >> "$S17/bin/gh" <<'STUB'
args="$*"
full="$(cat "$FXD/FULL")"
head_sha=""
for a in "$@"; do case "$a" in head_sha=*) head_sha="${a#head_sha=}" ;; esac; done
case "$args" in
  *"/branches/"*"/protection"*)
    cat "$FXD/protection.json"; exit 0 ;;
  *"/actions/runs"*)
    # THE ASYMMETRY. Full oid -> the recorded feed. Anything else -> empty, 200.
    if [ "$head_sha" = "$full" ]; then cat "$FXD/runs.json"
    else echo '{"total_count": 0, "workflow_runs": []}'; fi
    exit 0 ;;
  *"/check-runs"*)
    # This endpoint ACCEPTS a prefix: same rows either way. That is why the bug
    # is invisible from the check-run side alone.
    cat "$FXD/checks.json"; exit 0 ;;
  *-q*files*)
    # changed-files read: unknown, so every paths-filtered context stays OWED.
    exit 1 ;;
  *"/commits/"*)
    s=""
    for a in "$@"; do case "$a" in */commits/*) s="${a##*/commits/}" ;; esac; done
    case "$full" in "$s"*) printf '{"sha": "%s"}\n' "$full"; exit 0 ;; esac
    echo '{"message": "No commit found for SHA"}' >&2; exit 1 ;;
esac
echo "gh stub: unrouted args: $args" >&2; exit 97
STUB
chmod +x "$S17/bin/gh"

s17_run() { # sha, script
  PATH="$S17/bin:$PATH" env -u GITHUB_RUN_ID bash "${2:-$WATCH}" \
    --sha "$1" --repo FRIKKern/barkpark --branch main > "$OUT" 2>&1
  echo $?
}

# ── 17a. the stub itself reproduces GitHub's asymmetry ──────────────────────
# Asserted BEFORE it is used to judge anything: a stub that served the same feed
# for both forms would make every arm below vacuously green.
cp "$FX/runs-all-inflight.json" "$S17/fx/runs.json"
cp "$FX/empty-payload.json"     "$S17/fx/checks.json"
a="$(PATH="$S17/bin:$PATH" gh api --paginate -X GET -f head_sha="$S17_FULL" -f per_page=100 repos/FRIKKern/barkpark/actions/runs | jq '.workflow_runs | length')"
b="$(PATH="$S17/bin:$PATH" gh api --paginate -X GET -f head_sha="$S17_SHORT" -f per_page=100 repos/FRIKKern/barkpark/actions/runs | jq '.workflow_runs | length')"
if [ "$a" = "3" ] && [ "$b" = "0" ]; then
  ok "the stub reproduces the real asymmetry: head_sha=<full> lists 3 runs, head_sha=<prefix> lists 0"
else
  bad "the stub does not reproduce the asymmetry (full=$a, prefix=$b); every arm below would be vacuous"
fi
c="$(PATH="$S17/bin:$PATH" gh api --paginate -X GET -f per_page=100 "repos/FRIKKern/barkpark/commits/$S17_SHORT/check-runs" | jq '.check_runs | length')"
if [ "$c" = "0" ]; then
  ok "the stub's check-runs arm answers a PREFIX (the endpoint that accepts one) — the bug is invisible from this side"
else
  bad "the stub's check-runs arm did not answer a prefix"
fi

# ── 17b. THE PARITY ASSERTION: both forms, one verdict ──────────────────────
rc_full="$(s17_run "$S17_FULL")"
if [ "$rc_full" = "2" ] && grep -q "WAITING " "$OUT"; then
  ok "full oid + 3 runs in flight -> WAITING (exit 2)"
else
  bad "full oid -> expected exit 2 WAITING, got $rc_full"; cat "$OUT" >&2
fi
rc_short="$(s17_run "$S17_SHORT")"
if [ "$rc_short" = "2" ] && grep -q "WAITING " "$OUT"; then
  ok "ABBREVIATED sha + the same 3 runs in flight -> WAITING (exit 2), the SAME verdict"
else
  bad "abbreviated sha -> expected exit 2 WAITING, got $rc_short"; cat "$OUT" >&2
fi
if [ "$rc_full" = "$rc_short" ]; then
  ok "the two sha forms agree (exit $rc_full = exit $rc_short) — INVERTS the measured 2-vs-1 split"
else
  bad "the two sha forms disagree: full=$rc_full short=$rc_short"
fi
if grep -q "resolved the sha argument '$S17_SHORT' to the full oid $S17_FULL" "$OUT"; then
  ok "the widening is PRINTED, naming both the argument and the oid it became"
else
  bad "the widening is silent; a reader cannot tell which sha was actually queried"; cat "$OUT" >&2
fi
if ! grep -q "MISSING  " "$OUT"; then
  ok "the abbreviated form reaches NO MISSING row — the failed-read-equals-zero answer is gone"
else
  bad "the abbreviated form still reports MISSING off an empty run feed"; cat "$OUT" >&2
fi

# ── 17c. THE CONTROL: a genuinely never-judged tip still screams, both ways ──
# a5260f609aa2bfe0e76a5983e6992a694776acef, recorded: 3 check runs (none of them
# a watched context) and 9 workflow runs, ALL terminal. If the fix worked by
# softening MISSING rather than by widening the sha, this arm reds.
cp "$FX/a5260f609.json"      "$S17/fx/checks.json"
cp "$FX/a5260f609-runs.json" "$S17/fx/runs.json"
rc_full="$(s17_run "$S17_FULL")"
n_full="$(grep -c "MISSING  " "$OUT")"
rc_short="$(s17_run "$S17_SHORT")"
n_short="$(grep -c "MISSING  " "$OUT")"
if [ "$rc_full" = "1" ] && [ "$n_full" = "3" ]; then
  ok "CONTROL full oid: 9 terminal runs, no watched row -> MISSING x3, exit 1"
else
  bad "CONTROL full oid: expected exit 1 with 3 MISSING rows, got exit $rc_full / $n_full rows"; cat "$OUT" >&2
fi
if [ "$rc_short" = "1" ] && [ "$n_short" = "3" ]; then
  ok "CONTROL abbreviated: the SAME scream survives the widening — MISSING x3, exit 1"
else
  bad "CONTROL abbreviated: expected exit 1 with 3 MISSING rows, got exit $rc_short / $n_short rows"; cat "$OUT" >&2
fi

# ── 17d. MUTATION: remove the widening and 17b reds ─────────────────────────
# The arms above are only load-bearing if they can fail. Neutralise full_oid()'s
# result at the one call site and the abbreviated form must fall back to MISSING
# while the full oid stays WAITING — i.e. exactly the split measured live.
MUT17="$TMP/main-gate-watch-noresolve.sh"
# shellcheck disable=SC2016  # the $ is LITERAL: these patterns match shell source
sed 's/^    full="\$(full_oid "\$sha")"$/    full="$sha"/' "$WATCH" > "$MUT17"
# shellcheck disable=SC2016  # likewise — grepping for the literal string full="$sha"
if ! cmp -s "$MUT17" "$WATCH" && grep -q 'full="\$sha"' "$MUT17"; then
  ok "built the no-widening mutant (full_oid's result replaced by the raw argument)"
  cp "$FX/runs-all-inflight.json" "$S17/fx/runs.json"
  cp "$FX/empty-payload.json"     "$S17/fx/checks.json"
  m_full="$(s17_run "$S17_FULL" "$MUT17")"
  m_short="$(s17_run "$S17_SHORT" "$MUT17")"
  if [ "$m_full" = "2" ] && [ "$m_short" = "1" ] && grep -q "MISSING  " "$OUT"; then
    ok "MUTATION SURVIVED NOTHING: without the widening the abbreviated form reds to MISSING/exit 1 while the full oid still WAITs at exit 2 — 17b measures the fix"
  else
    bad "MUTATION SURVIVED: the no-widening mutant answered full=$m_full short=$m_short; §17b would pass with the fix removed"; cat "$OUT" >&2
  fi
else
  bad "could not build the no-widening mutant; §17b measured nothing"
fi

# ── 17e. a prefix that resolves to nothing is REFUSED, not answered ──────────
rc="$(s17_run "deadbee")"
if [ "$rc" = "3" ]; then
  ok "an unresolvable prefix exits 3 (CONFIGURATION FAULT), not 1"
else
  bad "an unresolvable prefix -> expected exit 3, got $rc"; cat "$OUT" >&2
fi
if grep -q "the sha argument 'deadbee' is not a full 40-character commit oid" "$OUT"; then
  ok "the refusal NAMES the argument it refused"
else
  bad "the refusal does not name the argument"; cat "$OUT" >&2
fi
if ! grep -q "MISSING  " "$OUT"; then
  ok "the refusal never reaches a MISSING verdict — a query it could not satisfy answers nothing"
else
  bad "an unresolvable prefix still produced a MISSING verdict"; cat "$OUT" >&2
fi

# ── 17f. the hermetic fixture path is untouched by the gate ─────────────────
# Every arm above §17 drives an ABBREVIATED sha with --check-runs-file, and none
# of them issues a head_sha= query. The gate must therefore not fire there, or
# this whole file would red on a change that fixes nothing about it.
rc="$(run_watch a5260f609 "$FX/a5260f609.json" "$FX/protection.json" "$WATCH" "$FX/a5260f609-runs.json")"
if [ "$rc" = "1" ] && ! grep -q "is not a full 40-character commit oid" "$OUT"; then
  ok "the gate does not fire on the hermetic path — recorded payloads are keyed by the sha the harness names"
else
  bad "the gate fired on a fixture-fed run (exit $rc); the harness's own shas are not queried against any endpoint"; cat "$OUT" >&2
fi

bash -n "$WATCH" && ok "main-gate-watch.sh passes bash -n" || bad "main-gate-watch.sh has a syntax error"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

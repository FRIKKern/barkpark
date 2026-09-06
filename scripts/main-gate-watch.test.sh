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

bash -n "$WATCH" && ok "main-gate-watch.sh passes bash -n" || bad "main-gate-watch.sh has a syntax error"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Mutation proof that the re-land advisory FAILS LOUDLY instead of false-greening.
# Run: bash tooling/task-obsession/reland_loudfail.test.sh   (exit 0 = all green)
#
# Every assertion is on the PRINTED classification (RELAND_STATUS / RELAND_PAGES /
# RELAND_ZERO_DIGEST), never on an exit code of the CI job: `reland-check.yml`
# carries `continue-on-error: true` by design, so its job conclusion is
# meaningless as a signal and asserting on it would be a vacuous green.
#
# The three silent-green modes this pins (re-derived live 2026-08-17 —
# tooling/grip/ledger/arpss-w2-reland-check-falsegreen-rederivation-2026-08-17.md):
#   1. an HTTP error body read as an empty ledger  -> status=infra
#   2. limit=1000 with no offset walk (6212 tasks) -> pages >= 2 on a page_size+1 corpus
#   3. a healthy scan of a corpus with 0 digests   -> RELAND_ZERO_DIGEST=1
# Plus: an unparseable body is infra (not a crash swallowed by `|| true`), and a
# tokenless run refused by the ledger is `skipped`, distinct from a rotated
# token's 401, which is `infra`.

set -uo pipefail
cd "$(dirname "$0")"
FIX="fixtures"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'shipped.ex\n' > "$tmp/files.txt"

pass=0 fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf 'ok   %-52s (%s)\n' "$1" "$3"
  else fail=$((fail + 1)); printf 'FAIL %-52s want %s got %s\n' "$1" "$2" "$3"; fi
}

# The printed value of one machine line, from the check's stderr.
line() { # line <KEY> <tasks-json> [extra args...]
  local key="$1" tasks="$2"; shift 2
  python3 reland_check.py --files "$tmp/files.txt" --tasks "$tasks" \
    --out "$tmp/findings.json" "$@" 2>&1 >/dev/null \
    | sed -n "s/^${key}=//p" | head -1
}

echo "== 1. HTTP-error body is infra, not an empty ledger =="
check "live 404 envelope -> status"          infra "$(line RELAND_STATUS "$FIX/ledger-404-error.json" --strict)"
check "live 404 envelope -> findings"        0     "$(line RELAND_FINDINGS "$FIX/ledger-404-error.json" --strict)"
python3 reland_check.py --files "$tmp/files.txt" --tasks "$FIX/ledger-404-error.json" \
  --out "$tmp/f.json" --strict >/dev/null 2>&1
check "--strict exit code on infra"          2     "$?"
python3 reland_check.py --files "$tmp/files.txt" --tasks "$FIX/ledger-404-error.json" \
  --out "$tmp/f.json" >/dev/null 2>&1
check "tolerant (no --strict) still exits 0" 0     "$?"

echo "== 2. an unparseable body is infra, not a swallowed crash =="
check "502 HTML body -> status"              infra "$(line RELAND_STATUS "$FIX/ledger-unparseable.json" --strict)"

echo "== 3. the offset walk reaches page 2 on a page_size+1 corpus =="
pages="$(line RELAND_PAGES "$FIX/ledger-two-pages.json" --strict)"
check "committed two-page artifact -> pages" 2     "$pages"
check "two-page artifact -> status"          ok    "$(line RELAND_STATUS "$FIX/ledger-two-pages.json" --strict)"
check "page-2 doc IS scanned (finding)"      1     "$(line RELAND_FINDINGS "$FIX/ledger-two-pages.json" --strict)"

# …and the walk that produced it is real: a localhost stub serving 4 docs at
# page_size 3 must be walked to exhaustion by reland_fetch.py.
python3 - "$tmp" <<'PY'
import http.server, json, socketserver, sys, threading, urllib.parse
DOCS = json.load(open("fixtures/ledger-two-pages.json"))["result"]["documents"]
LIMIT = 3

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        off = int(q.get("offset", ["0"])[0]); lim = int(q.get("limit", ["1000"])[0])
        page = DOCS[off:off + min(lim, LIMIT)]
        inner = {"documents": page, "count": len(page)}
        if q.get("count") == ["true"]:
            inner["total"] = len(DOCS)
        body = json.dumps({"result": inner}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

srv = socketserver.TCPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
open(sys.argv[1] + "/stub_base", "w").write("http://127.0.0.1:%d" % srv.server_address[1])

import reland_fetch
meta, docs = reland_fetch.fetch(
    "http://127.0.0.1:%d" % srv.server_address[1], "production", "task",
    "stub-token", LIMIT, 20, 5.0)
srv.shutdown()
open(sys.argv[1] + "/walk.json", "w").write(json.dumps(meta))
PY
walk="$tmp/walk.json"
jget() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$walk" "$1"; }
check "live localhost walk -> pages"         2     "$(jget pages)"
check "live localhost walk -> docs"          4     "$(jget docs)"
check "live localhost walk -> total"         4     "$(jget total)"
check "live localhost walk -> truncated"     False "$(jget truncated)"
check "live localhost walk -> status"        ok    "$(jget status)"
# The committed fixture is not hand-waved: it matches what the real walk reports.
check "fixture pages == live walk pages"     "$(jget pages)" "$pages"

echo "== 4. a healthy scan with zero land digests is hollow, and says so =="
check "no-landed corpus -> status"           ok    "$(line RELAND_STATUS "$FIX/ledger-no-landed.json" --strict)"
check "no-landed corpus -> docs_scanned"     3     "$(line RELAND_DOCS_SCANNED "$FIX/ledger-no-landed.json" --strict)"
check "no-landed corpus -> digests_scanned"  0     "$(line RELAND_DIGESTS_SCANNED "$FIX/ledger-no-landed.json" --strict)"
check "no-landed corpus -> ZERO_DIGEST"      1     "$(line RELAND_ZERO_DIGEST "$FIX/ledger-no-landed.json" --strict)"
check "a real digest corpus -> ZERO_DIGEST"  0     "$(line RELAND_ZERO_DIGEST "$FIX/ledger-two-pages.json" --strict)"

echo "== 5. fork (no secret) is skipped; a rotated token is infra =="
python3 - "$tmp" <<'PY'
import http.server, json, socketserver, sys, threading
class Deny(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"error": {"code": "unauthorized", "message": "unauthorized"}}).encode()
        self.send_response(401); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

srv = socketserver.TCPServer(("127.0.0.1", 0), Deny)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % srv.server_address[1]
import reland_fetch
anon, _ = reland_fetch.fetch(base, "production", "task", "", 1000, 20, 5.0)
tok, _ = reland_fetch.fetch(base, "production", "task", "rotated", 1000, 20, 5.0)
srv.shutdown()
json.dump({"anon": anon, "tok": tok}, open(sys.argv[1] + "/auth.json", "w"))
PY
aget() { # aget <anon|tok> <field>
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])" \
    "$tmp/auth.json" "$1" "$2"
}
check "401 with NO token -> status"          skipped "$(aget anon status)"
check "401 with NO token -> auth"            anon    "$(aget anon auth)"
check "401 WITH a token -> status"           infra   "$(aget tok status)"
rotated_note="$(python3 -c "import json;print('rotated' in json.load(open('$tmp/auth.json'))['tok']['note'])")"
check "rotated-token note names rotation"    True    "$rotated_note"

echo "== 6. the WORKFLOW's own shell, run against a localhost stub ledger =="
# reland_workflow_sim.py extracts reland-check.yml's real `run:` blocks and
# executes them, so a shell edit that reintroduces a silent green reds here.
# The stub holds 1000+1 docs and the ONE task that landed the changed file sits
# at index 1000: a finding appears if and ONLY if the offset walk happened.
if python3 -c 'import yaml' 2>/dev/null; then
  # Plain files, not an associative array: this must run on bash 3.2 too.
  sim() { sed -n "s/^$2=//p" "$tmp/sim-$1.txt" | head -1; }
  scenarios="healthy short error rotated fork-refused fork-anon"
  for sc in $scenarios; do
    python3 reland_workflow_sim.py --scenario "$sc" --repo-root ../.. > "$tmp/sim-$sc.txt"
  done

  check "healthy: status"                      ok      "$(sim healthy SIM_STATUS)"
  check "healthy: pages walked (limit 1000)"   2       "$(sim healthy SIM_PAGES)"
  check "healthy: docs scanned"                1001    "$(sim healthy SIM_DOCS)"
  check "healthy: page-2 overlap IS found"     1       "$(sim healthy SIM_FINDINGS)"
  check "healthy: advisory posted"             1       "$(sim healthy SIM_ADVISORY_POSTED)"
  check "healthy: summary prints status"       1       "$(sim healthy SIM_SUMMARY_HAS_STATUS)"
  check "healthy: summary prints pages"        1       "$(sim healthy SIM_SUMMARY_HAS_PAGES)"
  check "healthy: summary prints digests"      1       "$(sim healthy SIM_SUMMARY_HAS_DIGESTS)"

  check "healthy: NOT flagged as truncated"    0       "$(sim healthy SIM_WARN_TRUNCATED)"

  check "total > reachable rows: status"        ok      "$(sim short SIM_STATUS)"
  check "total > reachable rows: PARTIAL warn"  1       "$(sim short SIM_WARN_TRUNCATED)"

  check "404 ledger: status"                   infra   "$(sim error SIM_STATUS)"
  check "404 ledger: says DID NOT RUN"         1       "$(sim error SIM_WARN_DID_NOT_RUN)"
  check "404 ledger: summary still printed"    1       "$(sim error SIM_SUMMARY_HAS_STATUS)"
  check "404 ledger: no advisory posted"       0       "$(sim error SIM_ADVISORY_POSTED)"

  check "rotated token (401+token): status"    infra   "$(sim rotated SIM_STATUS)"
  check "rotated token: names rotation"        1       "$(sim rotated SIM_NOTE_HAS_ROTATED)"
  check "rotated token: NOT the fork exemption" 0      "$(sim rotated SIM_WARN_ANON)"

  check "fork refused (401, no token): status" skipped "$(sim fork-refused SIM_STATUS)"
  check "fork refused: read as anon"           anon    "$(sim fork-refused SIM_AUTH)"
  check "fork refused: not DID NOT RUN"        0       "$(sim fork-refused SIM_WARN_DID_NOT_RUN)"

  check "fork anon read: status"               ok      "$(sim fork-anon SIM_STATUS)"
  check "fork anon read: LOUD anon notice"     1       "$(sim fork-anon SIM_WARN_ANON)"
  check "fork anon read: notice on advisory"   1       "$(sim fork-anon SIM_ADVISORY_ANON_NOTICE)"
  check "advisory step is gated on status"     1       "$(sim fork-anon SIM_ADVISORY_GATED_ON_STATUS)"

  for sc in $scenarios; do
    check "no ::error annotation ($sc)"        0       "$(sim "$sc" SIM_ERROR_ANNOTATION)"
  done
elif [ -n "${RELAND_REQUIRE_YAML:-}" ]; then
  # In CI a skipped section IS a vacuous green, so there it is a failure.
  check "PyYAML present for the workflow sim" 1 0
else
  printf 'SKIP %-52s (no PyYAML — workflow sim not run locally)\n' "workflow shell simulation"
fi

echo "== 7. the pre-existing damper suite still passes =="
if bash reland_check.test.sh >/dev/null 2>&1; then
  check "reland_check.test.sh" 0 0
else
  check "reland_check.test.sh" 0 1
fi

echo "---"; echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]

#!/usr/bin/env bash
#
# pdf-efficiency-proof.test.sh — the MUTATION PROOF for the raw-task census in
# scripts/pdf-efficiency-proof.sh.
#
# HERMETIC: no network, no scratch instance, no ledger. It extracts the
# CENSUS-WALK region VERBATIM from the proof script and drives that exact text
# against a stub HTTP server on 127.0.0.1 whose paging behaviour it controls.
#
# WHAT IT PROVES, in both directions (a check that cannot lose proves nothing —
# PDS-D20):
#   · a stub whose pages NEVER END makes the walk REFUSE by name
#     (CENSUS-PAGE-OVERRUN) instead of printing a count, and MECHANICALLY
#     deleting that one refusal line makes the IDENTICAL run print a census over
#     the rows it happened to reach;
#   · a stub that returns ONE SHORT PAGE while reporting a total of 5000 makes
#     the walk REFUSE (CENSUS-TRUNCATED), and deleting that one line makes the
#     identical run print a census of 3 — the old behaviour, exactly;
#   · every mutation is asserted to have APPLIED (its anchor matched EXACTLY
#     once, and the mutated text differs), so a no-op sed can never pass as a
#     catch.
#
# Usage: scripts/pdf-efficiency-proof.test.sh    (exit 0 = every check passed)
#
# bash 3.2 compatible (macOS system bash).

set -uo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/pdf-efficiency-proof.sh"

N_PASS=0
N_FAIL=0
ok()   { N_PASS=$((N_PASS + 1)); printf '  ok   %s\n' "$*"; }
nope() { N_FAIL=$((N_FAIL + 1)); printf '  FAIL %s\n' "$*"; }
note() { printf '       %s\n' "$*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdf-census-test.XXXXXX")"
STUB_PID=""
cleanup() {
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

printf '%s — mutation proof for the census walk in %s\n\n' "$SELF" "$(basename "$TARGET_SCRIPT")"

# ── 1. extract the region VERBATIM ───────────────────────────────────────────

BEGIN_N="$(grep -c '^# >>> CENSUS-WALK BEGIN' "$TARGET_SCRIPT" || true)"
END_N="$(grep -c '^# <<< CENSUS-WALK END' "$TARGET_SCRIPT" || true)"
if [ "$BEGIN_N" = "1" ] && [ "$END_N" = "1" ]; then
  ok "CENSUS-WALK markers appear exactly once each in $(basename "$TARGET_SCRIPT")"
else
  nope "CENSUS-WALK markers: $BEGIN_N begin / $END_N end (want 1 / 1) — the extraction anchor is ambiguous"
fi

REGION="$TMP/region.sh"
sed -n '/^# >>> CENSUS-WALK BEGIN/,/^# <<< CENSUS-WALK END/p' "$TARGET_SCRIPT" > "$REGION"
REGION_LINES="$(wc -l < "$REGION" | tr -d ' ')"
if [ "$REGION_LINES" -gt 40 ] && grep -q '^census_ours() {' "$REGION"; then
  ok "extracted $REGION_LINES lines of census walk, carrying census_ours()"
else
  nope "extracted region is $REGION_LINES lines and/or has no census_ours() — nothing to test"
  printf '\n%s: 0 passed, 1 failed (extraction)\n' "$SELF"; exit 0
fi

# The defect this replaced, asserted absent: a census taken from ONE capped read.
if grep -q 'perspective=raw&limit=1000"' "$TARGET_SCRIPT"; then
  nope "the single unpaginated 'perspective=raw&limit=1000' census read is STILL in the script"
else
  ok "the single unpaginated 'perspective=raw&limit=1000' census read is gone"
fi
for TOKEN in 'count=true' 'offset=$off' 'CENSUS-TRUNCATED' 'CENSUS-PAGE-OVERRUN'; do
  if grep -qF -- "$TOKEN" "$REGION"; then
    ok "region carries: $TOKEN"
  else
    nope "region is missing: $TOKEN"
  fi
done

# ── 2. the stub server ───────────────────────────────────────────────────────

cat > "$TMP/stub.py" <<'PY'
import json, os, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

MODE   = os.environ["STUB_MODE"]
TOTAL  = int(os.environ.get("STUB_TOTAL", "0"))
NMATCH = int(os.environ.get("STUB_MATCH", "0"))
PREFIX = os.environ.get("STUB_PREFIX", "")
LOG    = os.environ["STUB_LOG"]


def row(idx):
    i = (PREFIX + "row-%06d" % idx) if idx < NMATCH else "other-%06d" % idx
    return {"_id": i, "_type": "task"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/__quit":
            self.reply(b"bye", "text/plain")
            t = threading.Thread(target=srv.shutdown)
            t.daemon = True
            t.start()
            return
        limit = int(q.get("limit", ["100"])[0])
        offset = int(q.get("offset", ["0"])[0])
        with open(LOG, "a") as f:
            f.write("limit=%d offset=%d count=%s filter=%s\n"
                    % (limit, offset, q.get("count", [""])[0],
                       q.get("filter[_id][contains]", [""])[0]))

        if MODE == "garbage":
            return self.reply(b"<html>a proxy ate your JSON</html>", "text/html")

        if MODE == "never-ending":
            n = limit                       # every page full, for ever
        elif MODE == "truncated":
            n = 3 if offset == 0 else 0     # one short page, then nothing
        else:
            n = min(limit, max(0, TOTAL - offset))

        docs = []
        for k in range(n):
            idx = offset + k
            if MODE == "dup" and idx == limit:
                idx = 0                     # page 2 row 1 repeats page 1 row 1
            docs.append(row(idx))

        res = {"perspective": "raw", "documents": docs, "count": len(docs),
               "limit": limit, "offset": offset, "hasMore": n >= limit}
        if MODE != "no-total":
            res["total"] = TOTAL
        self.reply(json.dumps({"result": res}).encode(), "application/json")

    def reply(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
# a leaked stub self-heals rather than outliving the harness. DAEMON: a
# non-daemon Timer keeps the interpreter alive for its full delay after
# serve_forever() returns, which hangs the harness on every shutdown.
_wd = threading.Timer(60.0, lambda: os._exit(0))
_wd.daemon = True
_wd.start()
srv.serve_forever()
PY

STUB_LOG="$TMP/stub.log"
STUB_BASE=""
start_stub() { # mode total nmatch
  : >"$STUB_LOG"
  rm -f "$TMP/ready"
  mkfifo "$TMP/ready"
  ( STUB_MODE="$1" STUB_TOTAL="$2" STUB_MATCH="$3" STUB_PREFIX="pfx-" STUB_LOG="$STUB_LOG" \
      python3 "$TMP/stub.py" 2>"$TMP/stub.err" || echo STUBFAIL ) > "$TMP/ready" &
  STUB_PID=$!
  # A FIFO read blocks until the server has bound and printed its port — no
  # sleep, no poll, and no race that only shows up under load.
  STUB_PORT=""
  read -r STUB_PORT < "$TMP/ready" || true
  case "$STUB_PORT" in
    ""|STUBFAIL|*[!0-9]*)
      nope "stub server did not start: $(tr '\n' ' ' < "$TMP/stub.err" | cut -c1-160)"
      STUB_PID=""
      return 1 ;;
  esac
  STUB_BASE="http://127.0.0.1:$STUB_PORT"
}

stop_stub() { # ask the server to shut down, then reap it — never orphan python
  if [ -n "$STUB_BASE" ]; then
    curl -sS --max-time 5 "$STUB_BASE/__quit" >/dev/null 2>&1 || true
  fi
  if [ -n "$STUB_PID" ]; then
    wait "$STUB_PID" 2>/dev/null || true
  fi
  STUB_PID=""
  STUB_BASE=""
}

# ── 3. the driver: the extracted region, verbatim, plus a minimal shell ──────

build_driver() { # region_file out_file — the region VERBATIM, plus a bare shell
  cat > "$2" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
say() { printf '%s\n' "$*"; }
WORKDIR="${1:?workdir}"
TARGET_BASE="${2:?base}"
TARGET_TOKEN="stub-token"
OP="pfx"
DRV
  cat "$1" >> "$2"
  cat >> "$2" <<'DRV'
census_ours
printf 'CENSUS=%s\n' "$CENSUS"
DRV
}

run_driver() { # driver_file -> DRIVER_RC, DRIVER_OUT
  local d="$1" wd
  wd="$(mktemp -d "$TMP/wd.XXXXXX")"
  DRIVER_OUT="$(CENSUS_PAGE_LIMIT="$PAGE_LIMIT" bash "$d" "$wd" "$STUB_BASE" 2>&1)"
  DRIVER_RC=$?
}

DRIVER="$TMP/driver.sh"
build_driver "$REGION" "$DRIVER"

# ── 4. the honest walk: a complete corpus, three pages, count=true on each ───

PAGE_LIMIT=1000
if start_stub complete 2500 7; then
  run_driver "$DRIVER"
  stop_stub
  OFFSETS="$(cut -d' ' -f2 "$STUB_LOG" | tr '\n' ' ' | sed 's/ *$//')"
  COUNTS="$(cut -d' ' -f3 "$STUB_LOG" | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  CENSUS_LINE="$(printf '%s\n' "$DRIVER_OUT" | grep '^CENSUS=' || true)"
  if [ "$DRIVER_RC" -eq 0 ] && [ "$CENSUS_LINE" = "CENSUS=7" ]; then
    ok "complete corpus (total=2500, 7 rows carry the prefix): rc=0, '$CENSUS_LINE'"
  else
    nope "complete corpus: rc=$DRIVER_RC output '$(printf '%s' "$DRIVER_OUT" | tr '\n' '|')' (want rc=0, CENSUS=7)"
  fi
  WALKLINE="$(printf '%s\n' "$DRIVER_OUT" | grep 'census walk:' || true)"
  if printf '%s' "$WALKLINE" | grep -q '3 page(s) of 1000, 2500 row(s) read, server total=2500'; then
    ok "the walk states its own sample size: $(printf '%s' "$WALKLINE" | sed 's/^ *//')"
  else
    nope "the walk did not state 3 pages / 2500 rows / total=2500: '$WALKLINE'"
  fi
  if [ "$OFFSETS" = "offset=0 offset=1000 offset=2000" ]; then
    ok "the walk paged: requested $OFFSETS (an offset loop, not one capped read)"
  else
    nope "the walk requested offsets '$OFFSETS' (want 'offset=0 offset=1000 offset=2000')"
  fi
  if [ "$COUNTS" = "count=true" ]; then
    ok "every page asked for count=true"
  else
    nope "count= values across the walk: '$COUNTS' (want only count=true)"
  fi
  if grep -q 'filter=pfx-' "$STUB_LOG"; then
    ok "the read narrows server-side with filter[_id][contains]=pfx-"
  else
    nope "no filter[_id][contains] reached the server: $(head -1 "$STUB_LOG")"
  fi
fi

# ── 5. named refusals ────────────────────────────────────────────────────────

refuse_case() { # mode total nmatch page_limit expected_name label
  local mode="$1" total="$2" nmatch="$3" plimit="$4" want="$5" label="$6"
  PAGE_LIMIT="$plimit"
  start_stub "$mode" "$total" "$nmatch" || return 0
  run_driver "$DRIVER"
  stop_stub
  LAST_RC="$DRIVER_RC"; LAST_OUT="$DRIVER_OUT"
  if [ "$DRIVER_RC" -ne 0 ] && printf '%s' "$DRIVER_OUT" | grep -q "$want" \
     && ! printf '%s' "$DRIVER_OUT" | grep -q '^CENSUS='; then
    ok "$label -> rc=$DRIVER_RC, refuses by name ($want), reports NO census"
  else
    nope "$label -> rc=$DRIVER_RC, want non-zero + '$want' + no CENSUS= line; got: $(printf '%s' "$DRIVER_OUT" | tr '\n' '|')"
  fi
}

refuse_case never-ending 5000 12 1000 CENSUS-PAGE-OVERRUN "pages that never end"
OVERRUN_OUT="$LAST_OUT"; OVERRUN_RC="$LAST_RC"
refuse_case truncated   5000 12 1000 CENSUS-TRUNCATED     "one short page against total=5000"
TRUNC_OUT="$LAST_OUT"; TRUNC_RC="$LAST_RC"
refuse_case no-total    2500  7 1000 CENSUS-NO-TOTAL      "a server that ignores ?count=true"
refuse_case garbage     2500  7 1000 CENSUS-UNPARSEABLE   "a page that is not a documents envelope"
GARBAGE_TRIES="$(wc -l < "$STUB_LOG" | tr -d ' ')"
if [ "$GARBAGE_TRIES" = "6" ]; then
  ok "a non-envelope page was retried CENSUS_PAGE_TRIES=6 times before the refusal (an intermittent 500 is not a verdict; a persistent one is)"
else
  nope "a non-envelope page was fetched $GARBAGE_TRIES time(s), want 6 (CENSUS_PAGE_TRIES)"
fi
refuse_case dup            5  5    2 CENSUS-DUP-ROWS      "a page window that shifts mid-walk"

# ── 6. THE MUTATION: delete the refusal, keep everything else byte-identical ─

mutate_out() { # anchor out_file — delete the ONE line carrying the anchor
  local anchor="$1" out="$2" hits
  hits="$(grep -c -- "$anchor" "$REGION" || true)"
  if [ "$hits" != "1" ]; then
    nope "mutation anchor '$anchor' matched $hits line(s) in the region (want exactly 1) — a mutation that did not apply is not a catch"
    return 1
  fi
  grep -v -- "$anchor" "$REGION" > "$out"
  if cmp -s "$REGION" "$out"; then
    nope "mutation '$anchor' produced a byte-identical region — it did not apply"
    return 1
  fi
  ok "mutation applied: '$anchor' matched exactly 1 line and the region changed"
  return 0
}

mutant_run() { # anchor mode total nmatch page_limit label
  local anchor="$1" mode="$2" total="$3" nmatch="$4" plimit="$5" label="$6"
  local mregion="$TMP/region-mut.sh" mdriver="$TMP/driver-mut.sh"
  mutate_out "$anchor" "$mregion" || return 0
  build_driver "$mregion" "$mdriver"
  PAGE_LIMIT="$plimit"
  start_stub "$mode" "$total" "$nmatch" || return 0
  run_driver "$mdriver"
  stop_stub
  MUT_RC="$DRIVER_RC"; MUT_OUT="$DRIVER_OUT"
  MUT_OUT="$(printf '%s\n' "$DRIVER_OUT" | grep '^CENSUS=' || true)"
  if [ "$DRIVER_RC" -eq 0 ] && [ -n "$MUT_OUT" ]; then
    ok "$label -> with the refusal removed the IDENTICAL run prints '$MUT_OUT' (rc=0)"
  else
    nope "$label -> mutant rc=$DRIVER_RC out '$(printf '%s' "$DRIVER_OUT" | tr '\n' '|')' (want rc=0 and a CENSUS= number)"
  fi
}

mutant_run 'census_refuse CENSUS-PAGE-OVERRUN' never-ending 5000 12 1000 "pages that never end"
MUT_OVERRUN_OUT="$MUT_OUT"; MUT_OVERRUN_RC="$MUT_RC"
mutant_run 'census_refuse CENSUS-TRUNCATED'    truncated    5000 12 1000 "one short page against total=5000"
MUT_TRUNC_OUT="$MUT_OUT"; MUT_TRUNC_RC="$MUT_RC"

printf '\n  MUTATION PROOF — the two numbers, side by side\n'
note "pages never end, refusal PRESENT : rc=$OVERRUN_RC  $(printf '%s' "$OVERRUN_OUT" | grep -o 'CENSUS-PAGE-OVERRUN.*' | cut -c1-96)"
note "pages never end, refusal REMOVED : rc=$MUT_OVERRUN_RC  $MUT_OVERRUN_OUT   <- a census of a corpus it could not finish"
note "short page vs total=5000, PRESENT: rc=$TRUNC_RC  $(printf '%s' "$TRUNC_OUT" | grep -o 'CENSUS-TRUNCATED.*' | cut -c1-96)"
note "short page vs total=5000, REMOVED: rc=$MUT_TRUNC_RC  $MUT_TRUNC_OUT   <- 3 rows read of 5000, printed as the answer"

printf '\n%s: %d passed, %d failed\n' "$SELF" "$N_PASS" "$N_FAIL"
if [ "$N_FAIL" -gt 0 ]; then
  printf '%s: FAILING — the census walk does not behave as claimed\n' "$SELF"
  exit 1
fi
exit 0

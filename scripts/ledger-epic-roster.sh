#!/usr/bin/env bash
# ledger-epic-roster.sh — reads an epic's WHOLE task roster from the ledger
# WITHOUT `bp` and WITHOUT a credential, and prints it in the exact payload
# shape `scripts/epic-zero-criteria-census.sh` already classifies.
#
# WHY THIS EXISTS. The zero-criteria census (that script) is a ratchet that can
# never become a required context while it shells `bp task get`: `bp` is not on
# a GitHub runner, so PATH-stripped it prints "UNKNOWN: bp is not on PATH" and
# exits 2 — red on every PR, forever, for a reason that has nothing to do with
# the PR. The repo's own worked precedent for "a gate that needs a secret cannot
# be a required context" is the ~30-line header of
# .github/workflows/required-checks-drift.yml: that job rides BREAKGLASS_TOKEN,
# a broad human OAuth token that rotates when its owner re-logs in, and fork PRs
# receive no secret at all — so it STAYS ADVISORY. A gate whose greenness
# depends on a rotating human credential cannot block merges.
#
# This reader answers that precedent the only way that makes a promotion
# possible: it needs NO credential at all. Measured 2026-09-16 against
# https://guerrilla.barkpark.cloud with the token unset:
#
#   GET /v1/tasks/<id>                                   -> 401  (auth route)
#   GET /v1/data/doc/production/task/<id>                -> 200, but the epic
#                                                           document carries NO
#                                                           `children` key
#   GET /v1/data/query/production/task?filter=parent_id=="<id>"
#                                                        -> 200 UNAUTHENTICATED,
#                                                           full rows, with
#                                                           acceptance_criteria
#                                                           at the top level
#
# The third route is the one used here. It is the SAME family of read that
# `scripts/pr-task-gate.sh` — a LIVE REQUIRED CONTEXT — already makes
# (`/v1/data/doc/...` against LEDGER_BASE with bounded retries), so the shape of
# "curl + bounded exponential retry + an unreachable ledger is an explicitly
# worded RED, never a green" is copied from there rather than invented here.
#
# ── THE DENOMINATOR, PINNED (this reader's central claim) ───────────────────
# The row that commissioned this port recorded a delta: `bp` reported 204
# children where the public query route returned 203. A port that silently
# changes its denominator by one is exactly the class this epic hunts, so the
# delta was re-measured, not assumed. Measured 2026-09-16 on the same epic
# (task-fb4fb869490b4213) in the same minute:
#
#   bp task get task-fb4fb869490b4213 -o json   -> child_count 360
#   /v1/data/query ... parent_id=="<epic>"      -> count       359
#
#   set difference (only in bp): drafts.dr-w34-bl-5658-blocks-its-own-routing-fix
#   set difference (only in query): <empty>
#
# THE DELTA IS ENTIRELY DRAFTS, AND IT IS STRUCTURAL. That one row carries
# `"status": "draft"` and a `drafts.` id prefix. The unauthenticated query route
# serves the PUBLISHED perspective and only the published perspective: passing
# `perspective=drafts` or `perspective=raw` is ACCEPTED (an unknown value such
# as `previewDrafts` is rejected by name, which proves the parameter is parsed)
# and the answer still comes back `"perspective":"published"` with zero
# `drafts.` ids. A token-free reader therefore CANNOT see draft tasks, at all,
# by construction.
#
# So the population this reader counts is stated rather than implied, and the
# printed line says so: PUBLISHED task rows in the `production` dataset,
# descended to the bottom of the tree. That is the right population for this
# ratchet anyway — a draft task is not on anyone's board and cannot be claimed —
# but the point is that it is DECLARED. The delta is not eliminated; it is
# pinned, named, and re-measurable with `--explain-denominator`.
#
# ── DEPTH: WHY THIS READS THE CORPUS, NOT A PER-ROW PROBE ───────────────────
# `bp task get <epic>` renders ONE level, which is why the census had to descend
# with a per-sub-parent `bp task ls --parent`. The public query route carries no
# `child_count` on its rows, so "who is a parent" cannot be read off a row at
# all. Probing each of ~360 rows for children is ~360 requests, any one of which
# failing leaves an UNWALKED subtree — the exact state the census must refuse to
# call SILENT. So this reader pages the whole published `task` corpus once
# (`filter=_type=="task"`, ordered `_createdAt:asc`, limit 1000 per page) and
# builds the parent->children index locally. Depth is then MEASURED, every
# subtree is walked by construction, and the request count does not grow with
# the epic.
#
#   Paging integrity is not assumed either. `_createdAt` is immutable, so
#   offset paging over it cannot re-order under concurrent UPDATES, and rows
#   inserted mid-page append at the tail. A concurrent DELETE could still shift
#   a row past an offset boundary, and that is undetectable from inside the
#   paging loop — so the loop does not try. Instead the epic's DIRECT children
#   are read a second time, by the independent `parent_id=="<epic>"` query, and
#   the two sets are compared. A mismatch is a paging anomaly and exits 2
#   (UNKNOWN) rather than reporting a count off a corpus that lost a row. That
#   control also proves the corpus walk is actually finding the roster, so a
#   reader that silently returned an empty corpus cannot print a clean answer.
#
# ── EXIT CODES (the outage contract, copied from pr-task-gate.sh) ───────────
#   0  the roster was read; the payload is on stdout
#   2  UNCHECKED — the ledger could not be read after bounded retries, answered
#      a shape this reader does not recognise, or failed the paging control.
#      NEVER a green, NEVER an empty roster reported as "clean". The message
#      says "re-run once the ledger is up" and names the ledger.
#   3  the ledger REFUSED an unauthenticated read (401/403) on a route that is
#      public by contract. Never retried — a refusal is not a blip — and the
#      cure is not a re-run: the route's auth contract changed, which is a
#      finding about the LEDGER, not about the PR.
#   4  usage error.
#
# FORKS. There is no secret to be absent, so a fork PR reads exactly what a
# branch PR reads. That is the whole point of the port: this is the first shape
# of this gate that a fork contributor can go green on.
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#   scripts/ledger-epic-roster.sh <epic-task-id>
#   scripts/ledger-epic-roster.sh <epic-task-id> --explain-denominator
#   scripts/ledger-epic-roster.sh --self-test
#
#   env:
#     LEDGER_BASE            default https://guerrilla.barkpark.cloud
#     LEDGER_DATASET         default production
#     ROSTER_RETRIES         default 3   (attempts per request)
#     ROSTER_RETRY_DELAY     default 2   (base seconds; doubles, capped at 30)
#     ROSTER_PAGE_LIMIT      default 1000 (the server caps at 1000 SILENTLY:
#                            asking for 2000 returns limit 1000, so asking for
#                            more than the cap would page wrong)
#     ROSTER_FETCH_CMD       TEST SEAM. When set, it is invoked as
#                            `$ROSTER_FETCH_CMD <url>` and must print the HTTP
#                            status on line 1 and the body on the lines after.
#                            The self-test substitutes a stub here so every
#                            branch — including the outage and the refusal — is
#                            pinned with no network.
#
# STDOUT SHAPE (what epic-zero-criteria-census.sh classifies):
#   {"children":[ {doc_id, lifecycle_status, title, child_count,
#                  criteria_progress, content:{<the whole ledger row>}} ... ],
#    "_census":{"walked":[...],"depth":N,"source":"token-free",
#               "perspective":"published","denominator":{...}}}
# `content` is the ledger row itself, so `acceptance_criteria` ABSENT and
# `acceptance_criteria: []` stay DIFFERENT — the distinction the whole census
# exists to make. No per-row resolution pass is needed or performed.

set -uo pipefail

LEDGER_BASE="${LEDGER_BASE:-https://guerrilla.barkpark.cloud}"
LEDGER_DATASET="${LEDGER_DATASET:-production}"
RETRIES="${ROSTER_RETRIES:-3}"
RETRY_DELAY="${ROSTER_RETRY_DELAY:-2}"
PAGE_LIMIT="${ROSTER_PAGE_LIMIT:-1000}"
FETCH_CMD="${ROSTER_FETCH_CMD:-}"

EPIC=""
EXPLAIN=0
SELF_TEST=0

usage() { sed -n '2,135p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --explain-denominator) EXPLAIN=1; shift ;;
    --self-test)           SELF_TEST=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    --*)                   echo "unknown flag: $1" >&2; exit 4 ;;
    *)                     EPIC="$1"; shift ;;
  esac
done

case "$RETRIES" in ''|*[!0-9]*) echo "ROSTER_RETRIES must be a positive integer, got '${RETRIES}'" >&2; exit 4 ;; esac
[ "$RETRIES" -ge 1 ] || { echo "ROSTER_RETRIES must be >= 1, got '${RETRIES}'" >&2; exit 4; }
case "$RETRY_DELAY" in ''|*[!0-9]*) echo "ROSTER_RETRY_DELAY must be a non-negative integer, got '${RETRY_DELAY}'" >&2; exit 4 ;; esac
case "$PAGE_LIMIT" in ''|*[!0-9]*) echo "ROSTER_PAGE_LIMIT must be a positive integer, got '${PAGE_LIMIT}'" >&2; exit 4 ;; esac
[ "$PAGE_LIMIT" -ge 1 ] && [ "$PAGE_LIMIT" -le 1000 ] || {
  echo "ROSTER_PAGE_LIMIT must be 1..1000 — the ledger caps the page at 1000 SILENTLY (limit=2000 answers limit=1000), so a larger value pages wrong. Got '${PAGE_LIMIT}'." >&2
  exit 4
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "UNKNOWN: python3 is not on PATH, so the ledger cannot be parsed." >&2
  exit 2
fi

unchecked() { echo "UNKNOWN: $1" >&2; exit 2; }
refused()   { echo "REFUSED: $1" >&2; exit 3; }

# ---------------------------------------------------------------------------
# One request, bounded exponential retry. Only INDECISIVE answers are retried
# (5xx / 429 / a transport failure, which curl reports as 000). A 2xx and a 404
# are ANSWERS. A 401/403 is a refusal and is never retried: retrying an auth
# refusal is noise shaped exactly like a transient, which is the fault
# pr-task-gate.sh's header records as the 2026-09-01 "outage that was not an
# outage".
#
# Writes the body to $2. Prints nothing on success.
# ---------------------------------------------------------------------------
fetch() { # url outfile label
  local url="$1" out="$2" label="$3"
  local attempt=1 delay="$RETRY_DELAY" code last

  while :; do
    if [ -n "$FETCH_CMD" ]; then
      # shellcheck disable=SC2086  # the seam is a command + args, split on purpose
      local stubbed
      stubbed="$($FETCH_CMD "$url" 2>/dev/null)"
      code="$(printf '%s\n' "$stubbed" | head -1)"
      printf '%s\n' "$stubbed" | tail -n +2 >"$out"
      case "$code" in ''|*[!0-9]*) code="000" ;; esac
    else
      code="$(curl -sS -m 30 -o "$out" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
      case "$code" in ''|*[!0-9]*) code="000" ;; esac
    fi

    case "$code" in
      2*)
        return 0 ;;
      401|403)
        refused "the ledger answered HTTP ${code} to an UNAUTHENTICATED read of ${label} at ${LEDGER_BASE}. This route is public by contract (measured 2026-09-16: /v1/data/query/<dataset>/task answers 200 with no credential), so this is NOT an outage, NOT a missing secret, and RE-RUNNING WILL NOT CLEAR IT: the route's auth contract changed. Fix the ledger route or re-point this reader; see scripts/ledger-epic-roster.sh." ;;
      404)
        unchecked "the ledger answered HTTP 404 for ${label} at ${LEDGER_BASE}. The query route answers 200 with an empty document list for a type that exists and has no matches, so a 404 means the ROUTE is gone, not that the epic is empty. Refusing to report a count off a route that is not there." ;;
      *)
        last="the ledger returned HTTP ${code} for ${label}" ;;
    esac

    if [ "$attempt" -ge "$RETRIES" ]; then
      unchecked "${last} after ${RETRIES} attempts — the epic roster could not be read at all. This is NOT a finding about your change and NOT a clean census: re-run this check once the ledger is up (ledger: ${LEDGER_BASE})."
    fi
    echo "  ledger-epic-roster: attempt ${attempt}/${RETRIES} was indecisive (${last}); retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -le 30 ] || delay=30
  done
}

# urlencode a filter expression with python (no jq dependency, no bash quoting
# games around the `==` and the quotes the filter grammar requires).
urlenc() { python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

query_url() { # filter offset limit
  printf '%s/v1/data/query/%s/task?filter=%s&order=%s&offset=%s&limit=%s' \
    "${LEDGER_BASE%/}" "$LEDGER_DATASET" "$(urlenc "$1")" "$(urlenc '_createdAt:asc')" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Page a filter to exhaustion. Emits one JSON array of documents on stdout.
# Stops on hasMore == false. A page whose envelope is unreadable is UNKNOWN,
# not "the end of the data" — a truncated corpus silently reported as complete
# is the same fault as an empty read reported as clean.
# ---------------------------------------------------------------------------
page_all() { # filter label outfile
  local filter="$1" label="$2" outfile="$3"
  local offset=0 dir page more total=0
  dir="$(mktemp -d)"
  while :; do
    page="$dir/page-${offset}.json"
    fetch "$(query_url "$filter" "$offset" "$PAGE_LIMIT")" "$page" "$label (offset ${offset})" || exit $?
    more="$(python3 - "$page" <<'PY'
import json, sys
try:
    body = json.load(open(sys.argv[1]))
except Exception as exc:
    print("ERR not JSON (%s)" % exc); raise SystemExit(0)
res = body.get("result") if isinstance(body, dict) else None
if not isinstance(res, dict) or not isinstance(res.get("documents"), list):
    print("ERR the 2xx body carried no result.documents list"); raise SystemExit(0)
print("%s %d" % ("MORE" if res.get("hasMore") else "DONE", len(res["documents"])))
PY
)"
    case "$more" in
      ERR*) rm -rf "$dir"; unchecked "${label}: ${more#ERR } (ledger: ${LEDGER_BASE}). The ledger ANSWERED 2xx — this is not an outage and not a credential fault — but its payload is not the documented query envelope, so no count can be taken from it." ;;
    esac
    total=$((total + ${more#* }))
    case "$more" in
      DONE*) break ;;
    esac
    offset=$((offset + PAGE_LIMIT))
    if [ "$offset" -gt 200000 ]; then
      rm -rf "$dir"
      unchecked "${label}: paging passed 200000 rows without the ledger ever saying hasMore=false. Refusing to loop forever; this is a ledger paging fault."
    fi
  done
  PAGE_DIR="$dir" python3 - >"$outfile" <<'PY'
import json, os, sys
docs, seen = [], set()
d = os.environ["PAGE_DIR"]
for name in sorted(os.listdir(d), key=lambda n: int(n.split("-")[1].split(".")[0])):
    body = json.load(open(os.path.join(d, name)))
    for doc in body["result"]["documents"]:
        i = doc.get("_id")
        if i in seen:      # offset paging over a live collection can repeat a
            continue       # row; it must never DOUBLE-COUNT one.
        seen.add(i)
        docs.append(doc)
json.dump(docs, sys.stdout)
PY
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Self-test. The reader has to be able to LOSE, and that is proved by running
# it against corpora that SHOULD red — not by reading the code.
# ---------------------------------------------------------------------------
if [ "$SELF_TEST" = "1" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  fails=0
  check() { if [ "$2" = "$3" ]; then echo "  ok    $1 (exit $3)"; else echo "  FAIL  $1 — expected exit $2, got $3"; fails=$((fails + 1)); fi; }
  expect() { case "$2" in *"$3"*) echo "  ok    $1" ;; *) echo "  FAIL  $1 — expected to find: $3"; echo "$2"; fails=$((fails + 1)) ;; esac; }
  refute() { case "$2" in *"$3"*) echo "  FAIL  $1 — did NOT expect: $3"; echo "$2"; fails=$((fails + 1)) ;; *) echo "  ok    $1" ;; esac; }

  echo "self-test: ledger-epic-roster.sh"

  # A stub ledger: one bash script that answers any query URL from a corpus
  # file, honouring offset/limit/hasMore exactly as the real route does.
  cat >"$tmp/stub.sh" <<'STUB'
#!/usr/bin/env bash
url="$1"
code="${STUB_CODE:-200}"
echo "$code"
[ "$code" = "200" ] || { echo "${STUB_BODY:-{\"error\":\"stub\"}}"; exit 0; }
[ -n "${STUB_RAW:-}" ] && { printf '%s' "$STUB_RAW"; exit 0; }
FILTER="$(python3 -c '
import sys,urllib.parse as u
q=u.parse_qs(u.urlparse(sys.argv[1]).query)
print(q.get("filter",[""])[0]);print(q.get("offset",["0"])[0]);print(q.get("limit",["1000"])[0])' "$url")"
f="$(printf '%s\n' "$FILTER" | sed -n 1p)"; o="$(printf '%s\n' "$FILTER" | sed -n 2p)"; l="$(printf '%s\n' "$FILTER" | sed -n 3p)"
STUB_FILTER="$f" STUB_OFFSET="$o" STUB_LIMIT="$l" python3 - "$STUB_CORPUS" <<'PY'
import json, os, re, sys
rows = json.load(open(sys.argv[1]))
f = os.environ["STUB_FILTER"]
m = re.match(r'^parent_id=="(.*)"$', f)
if m:
    rows = [r for r in rows if r.get("parent_id") == m.group(1)]
elif f != '_type=="task"':
    rows = []          # an unsupported filter answers ZERO, exactly like the
                       # real route does for `in [...]` — the trap this
                       # harness must be able to reproduce.
off, lim = int(os.environ["STUB_OFFSET"]), int(os.environ["STUB_LIMIT"])
page = rows[off:off + lim]
print(json.dumps({"result": {"count": len(page), "offset": off, "limit": lim,
                             "perspective": "published", "documents": page,
                             "hasMore": off + lim < len(rows)}}))
PY
STUB
  chmod +x "$tmp/stub.sh"

  mkrow() { # id parent status criteria-json
    printf '{"_id":"%s","_type":"task","parent_id":%s,"lifecycle_status":"%s","title":"row %s"%s}' \
      "$1" "$2" "$3" "$1" "$4"
  }
  CRIT_HAS=',"acceptance_criteria":[{"criterion":"c","met":false}]'
  CRIT_EMPTY=',"acceptance_criteria":[]'
  CRIT_NONE=''

  # CLEAN corpus: epic + 2 children + 1 grandchild, every live row has a criterion.
  {
    printf '['
    mkrow "epic-1" 'null'       "open" "$CRIT_HAS"; printf ','
    mkrow "kid-a"  '"epic-1"'   "open" "$CRIT_HAS"; printf ','
    mkrow "kid-b"  '"epic-1"'   "open" "$CRIT_HAS"; printf ','
    mkrow "gkid-a" '"kid-a"'    "in_progress" "$CRIT_HAS"
    printf ']'
  } >"$tmp/clean.json"

  # DIRTY corpus: same, but the GRANDCHILD carries an empty criteria array.
  # A reader that only walked depth 1 would report this corpus CLEAN.
  {
    printf '['
    mkrow "epic-1" 'null'       "open" "$CRIT_HAS"; printf ','
    mkrow "kid-a"  '"epic-1"'   "open" "$CRIT_HAS"; printf ','
    mkrow "kid-b"  '"epic-1"'   "open" "$CRIT_HAS"; printf ','
    mkrow "gkid-a" '"kid-a"'    "open" "$CRIT_EMPTY"
    printf ']'
  } >"$tmp/dirty-empty.json"

  # ABSENT corpus: the grandchild has NO acceptance_criteria key at all.
  {
    printf '['
    mkrow "epic-1" 'null'       "open" "$CRIT_HAS"; printf ','
    mkrow "kid-a"  '"epic-1"'   "open" "$CRIT_HAS"; printf ','
    mkrow "gkid-a" '"kid-a"'    "open" "$CRIT_NONE"
    printf ']'
  } >"$tmp/dirty-absent.json"

  run() { # corpus extra-env...
    local corpus="$1"; shift
    env ROSTER_FETCH_CMD="$tmp/stub.sh" STUB_CORPUS="$corpus" ROSTER_RETRY_DELAY=0 \
        "$@" bash "$0" epic-1 2>&1
  }

  # 1. CLEAN corpus reads, and the roster is the whole tree (3 rows, depth 2).
  out="$(run "$tmp/clean.json")"; rc=$?
  check "clean corpus reads" 0 "$rc"
  expect "clean roster names the grandchild" "$out" '"doc_id": "gkid-a"'
  expect "clean roster states depth 2" "$out" '"depth": 2'
  expect "clean roster declares its perspective" "$out" '"perspective": "published"'

  # 2. THE VACUITY CONTROL. The whole reader is worthless if a zero-criteria row
  #    reads the same as a healthy one. The EMPTY row must survive the read with
  #    its empty array INTACT — not collapsed to "absent", not dropped.
  out="$(run "$tmp/dirty-empty.json")"; rc=$?
  check "dirty(empty) corpus reads" 0 "$rc"
  expect "the empty-criteria row is CARRIED, empty array intact" "$out" '"acceptance_criteria": []'

  # 3. ABSENT stays ABSENT: the key must not be manufactured by the reader.
  out="$(run "$tmp/dirty-absent.json")"; rc=$?
  check "dirty(absent) corpus reads" 0 "$rc"
  # Asserted on the ROW, not on the whole blob: a sibling in the same roster
  # legitimately carries the key, so a bare grep would pass vacuously either way.
  verdict="$(printf '%s' "$out" | python3 -c '
import json, sys
rows = {c["doc_id"]: c for c in json.load(sys.stdin)["children"]}
absent = "acceptance_criteria" not in rows["gkid-a"]["content"]
present = "acceptance_criteria" in rows["kid-a"]["content"]
print("ABSENT-KEPT" if absent else "KEY-MANUFACTURED",
      "SIBLING-KEPT" if present else "SIBLING-LOST")')"
  expect "the absent-criteria row did NOT gain a key" "$verdict" "ABSENT-KEPT"
  expect "and its healthy sibling did not LOSE one" "$verdict" "SIBLING-KEPT"

  # 4. OUTAGE: 503 is retried, then lands on an explicitly-worded RED. Never 0,
  #    never an empty roster reported as a clean one.
  out="$(run "$tmp/clean.json" STUB_CODE=503)"; rc=$?
  check "a 503 ledger is UNKNOWN, not clean" 2 "$rc"
  expect "the outage verdict says what to do" "$out" "re-run this check once the ledger is up"
  refute "the outage verdict does not blame the change" "$out" "SILENT"

  # 5. REFUSAL: 401 is NOT retried and does NOT wear the outage message. This is
  #    the 2026-09-01 fault pr-task-gate.sh's header records.
  out="$(run "$tmp/clean.json" STUB_CODE=401)"; rc=$?
  check "a 401 on a public route is its own verdict" 3 "$rc"
  expect "the refusal says a re-run will not clear it" "$out" "RE-RUNNING WILL NOT CLEAR IT"
  refute "the refusal is not retried" "$out" "attempt 1/3 was indecisive"
  refute "the refusal does not wear the outage message" "$out" "once the ledger is up"

  # 6. A 2xx CARRYING AN EMPTY ENVELOPE IS UNCHECKED, NOT AN ACCUSATION.
  out="$(run "$tmp/clean.json" STUB_RAW='{"ok":true}')"; rc=$?
  check "a 2xx with no result.documents is UNKNOWN" 2 "$rc"
  expect "the malformed verdict says the ledger answered" "$out" "The ledger ANSWERED 2xx"

  # 7. THE PAGING CONTROL. A corpus walk that loses the epic's direct children
  #    must refuse, not report a short roster. Simulated by a stub whose
  #    `_type=="task"` corpus is MISSING kid-b while the direct parent_id query
  #    still sees it.
  cp "$tmp/clean.json" "$tmp/lossy-corpus.json"
  python3 - "$tmp/lossy-corpus.json" <<'PY'
import json, sys
p = sys.argv[1]
rows = json.load(open(p))
json.dump(rows, open(p, "w"))
PY
  cat >"$tmp/stub-lossy.sh" <<STUB
#!/usr/bin/env bash
if printf '%s' "\$1" | grep -q 'filter=_type'; then
  STUB_CORPUS="$tmp/lossy-partial.json" exec "$tmp/stub.sh" "\$1"
fi
STUB_CORPUS="$tmp/clean.json" exec "$tmp/stub.sh" "\$1"
STUB
  chmod +x "$tmp/stub-lossy.sh"
  python3 - "$tmp/clean.json" "$tmp/lossy-partial.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
json.dump([r for r in rows if r["_id"] != "kid-b"], open(sys.argv[2], "w"))
PY
  out="$(env ROSTER_FETCH_CMD="$tmp/stub-lossy.sh" ROSTER_RETRY_DELAY=0 bash "$0" epic-1 2>&1)"; rc=$?
  check "a corpus that lost a direct child is UNKNOWN" 2 "$rc"
  expect "the paging verdict names the lost row" "$out" "kid-b"

  # 8. THE READER MUST ACTUALLY WALK. A stub whose corpus is EMPTY must not
  #    print a clean roster off nothing.
  echo '[]' >"$tmp/empty.json"
  out="$(run "$tmp/empty.json")"; rc=$?
  check "an empty corpus does not read as a clean roster" 2 "$rc"
  expect "the empty-corpus verdict says the epic was not found" "$out" "epic-1"

  # 9. --explain-denominator prints the pinned delta and does not need the net.
  out="$(bash "$0" --explain-denominator 2>&1)"; rc=$?
  check "--explain-denominator runs offline" 0 "$rc"
  expect "it names the drafts cause" "$out" "drafts"
  expect "it states the measurement date" "$out" "2026-09-16"

  echo
  if [ "$fails" -eq 0 ]; then echo "self-test: all checks passed"; exit 0; fi
  echo "self-test: ${fails} check(s) FAILED"; exit 1
fi

if [ "$EXPLAIN" = "1" ]; then
  sed -n '/THE DENOMINATOR, PINNED/,/re-measurable with/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

[ -n "$EPIC" ] || { echo "usage: $0 <epic-task-id> [--explain-denominator] | --self-test" >&2; exit 4; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

page_all '_type=="task"' "the published task corpus" "$work/corpus.json" || exit $?
page_all "parent_id==\"${EPIC}\"" "the direct children of ${EPIC}" "$work/direct.json" || exit $?

CORPUS="$work/corpus.json" DIRECT="$work/direct.json" EPIC_ID="$EPIC" \
  LEDGER_BASE="$LEDGER_BASE" LEDGER_DATASET="$LEDGER_DATASET" python3 - <<'PY'
import json, os, sys

corpus = json.load(open(os.environ["CORPUS"]))
direct = json.load(open(os.environ["DIRECT"]))
epic = os.environ["EPIC_ID"]
base = os.environ["LEDGER_BASE"]

by_id = {r.get("_id"): r for r in corpus if isinstance(r, dict) and r.get("_id")}

# THE PAGING CONTROL. Two independent reads must agree on the epic's direct
# children. They are produced by different filters over different page windows,
# so a row lost to a concurrent delete shifting an offset shows up HERE.
kids = {}
for r in corpus:
    p = r.get("parent_id")
    if p:
        kids.setdefault(p, []).append(r)

corpus_direct = {r.get("_id") for r in kids.get(epic, [])}
query_direct = {r.get("_id") for r in direct if isinstance(r, dict)}
missing = sorted(query_direct - corpus_direct)
extra = sorted(corpus_direct - query_direct)
if missing or extra:
    sys.stderr.write(
        "UNKNOWN: the two independent reads of %s disagree on its direct children — "
        "the corpus walk %s%s. Offset paging over a live collection can lose a row to a "
        "concurrent delete, and a short roster reported as a count is exactly the fault "
        "this control exists to catch. Refusing to report a census. Re-run (ledger: %s).\n"
        % (epic,
           ("MISSED " + ", ".join(missing)) if missing else "",
           (("; and CARRIES " + ", ".join(extra)) if extra else ""),
           base))
    raise SystemExit(2)

if epic not in by_id and not query_direct:
    sys.stderr.write(
        "UNKNOWN: %s is not in the published task corpus and has no direct children on "
        "the ledger, so there is no roster to census. An empty read is NOT a clean "
        "census — this refuses rather than printing a roster of nothing (ledger: %s).\n"
        % (epic, base))
    raise SystemExit(2)

# BFS to the bottom. Every node is walked by construction: the parent->children
# index came from the whole corpus, so there is no subtree left unexpanded and
# no `child_count` field to trust.
children, walked, seen = [], [], set()
frontier, depth = [epic], 0
while frontier:
    depth += 1
    nxt = []
    for parent in frontier:
        walked.append(parent)
        for row in kids.get(parent, []):
            rid = row.get("_id")
            if not rid or rid in seen:
                continue
            seen.add(rid)
            crit = row.get("acceptance_criteria")
            children.append({
                "doc_id": rid,
                "lifecycle_status": row.get("lifecycle_status"),
                "title": row.get("title"),
                "child_count": len(kids.get(rid, [])),
                # criteria_progress is the SUMMARY the census falls back on. It
                # is computed here, not read: the query route does not carry it.
                "criteria_progress": {
                    "total": len(crit) if isinstance(crit, list) else 0,
                    "met": sum(1 for c in crit if isinstance(c, dict) and c.get("met"))
                           if isinstance(crit, list) else 0,
                },
                # The whole row IS the content. ABSENT and [] stay different.
                "content": row,
            })
            nxt.append(rid)
    frontier = nxt
    if depth > 64:
        sys.stderr.write("UNKNOWN: the parent chain under %s is deeper than 64 levels or cyclic.\n" % epic)
        raise SystemExit(2)

json.dump({
    "children": children,
    "_census": {
        "walked": sorted(walked),
        "depth": max(depth - 1, 1),
        "source": "token-free",
        "perspective": "published",
        "denominator": {
            "population": "PUBLISHED task rows in dataset %s, descended to the bottom of the tree" % os.environ["LEDGER_DATASET"],
            "excludes": "draft rows (ids prefixed `drafts.`) — the unauthenticated query route serves the published perspective ONLY; ?perspective=drafts is accepted and still answers published",
            "pinned_delta_2026_09_16": "bp task get reported 360 direct children where this route returned 359; the single difference was drafts.dr-w34-bl-5658-blocks-its-own-routing-fix, status draft",
            "corpus_rows_read": len(corpus),
            "direct_children": len(query_direct),
            "roster_rows": len(children),
        },
    },
}, sys.stdout, indent=1)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

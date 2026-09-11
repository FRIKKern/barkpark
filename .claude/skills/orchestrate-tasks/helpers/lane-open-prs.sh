#!/usr/bin/env bash
# lane-open-prs.sh <branch-prefix>[,<prefix2>…] [held-rows-file] — DERIVE a lane's in-flight set
# at round start, from GitHub and the ledger, instead of reading it off a handoff table.
#
# SIBLINGS: lane-status.sh answers "what did each lead last WRITE"; held-liveness.sh answers "are
# my claims still mine"; pr-watch.sh answers "are my PRs moving". THIS one answers the question a
# successor lead asks before it dispatches anybody: "what is ALREADY OPEN for my lane?"
#
# WHY THIS FILE EXISTS. Measured 2026-09-11 (task-c65f16ac7eeb657a): lead-api-r9 wrote its handoff
# status.md at 06:35Z listing cch-w12 as "triaging" and cch-w65 as "untriaged". Its workers then
# opened draft PRs #17709 (06:55Z) and #17706 (06:51Z) for exactly those two rows — AFTER that
# write — and r9 died on the Fable cap before it could amend the table. The successor read the
# table, believed both rows unbuilt, and dispatched two duplicate workers; one shipped #17716,
# which CONTRADICTED the correct PR and had to be closed.
#
# Nothing was hidden. Both facts were readable at 08:2xZ from two places that are never stale:
#   * GitHub: an open PR whose head ref starts with the lane prefix, carrying `Task: <id>`.
#   * The ledger: the row's own `.doc.claim.lease_extension.pr`, written when the PR opened.
# A handoff table is a SNAPSHOT — true at the instant of the write and false by the next commit.
# The open-PR set is DERIVED, at round start, every round. That is what this helper does.
#
# WHAT IT PRINTS
#   1. One line per OPEN pull request whose head ref starts with any given prefix:
#        #<number> <draft|ready> head=<sha9> created=<iso> task=<Task: trailer|NONE> <ref> <title>
#      The `task=` field is the `Task:` trailer parsed out of the PR body; NONE means the PR
#      carries no trailer (it will also be failing the "PR references an active task" gate).
#   2. With a held-rows file (lines "<task-id> <worker>", the shape of $ORCH/<lane>/held-rN.txt):
#      one line per row with its `lifecycle_status` and its `claim.lease_extension.pr`, and a
#      CROSS verdict saying whether that PR is in the open set printed above.
#   3. A DISPATCH BLOCK section: every held row that already has an open PR or a lease PR. Those
#      rows are IN FLIGHT — dispatching a worker onto one manufactures the #17716 shape.
#
# RULES
#   * READ-ONLY. `gh api` GETs and `bp task get` with BARKPARK_TOKEN unset. No writes, ever.
#   * REST ONLY, and ONE call for the PR list: `gh api repos/<repo>/pulls?state=open&per_page=100`
#     with --paginate. NEVER `gh pr view` in a loop — that is GraphQL, and a 60-PR loop eats the
#     hourly point budget the merge sweep needs.
#   * Every failed read prints its own `CANNOT READ` line naming what could not be read, and the
#     run exits non-zero. A failed read is NEVER byte-identical to a zero (LEAD-BRIEF): a lane
#     with no open PRs prints `NO OPEN PRS matched …`, which no refusal can be mistaken for.
#   * A zero is always LABELLED. "Nothing matched" and "nothing was asked" are different lines.
#
# USAGE
#   lane-open-prs.sh api/                                   # just the open-PR set
#   lane-open-prs.sh api/,fix/api- "$ORCH/lead-api/held-r10.txt"
#   lane-open-prs.sh --selftest                             # hermetic; no network, no ledger
#
# FLAGS
#   --repo OWNER/NAME   default FRIKKern/barkpark
#   --bp CMD            ledger reader (default `bp`, always run under `env -u BARKPARK_TOKEN`)
#   --tee FILE          append every printed line here as well
#
# EXIT: 0 = everything asked for was read. 2 = bad arguments. 3 = at least one read REFUSED.
set -u
SELF="${BASH_SOURCE[0]}"

REPO="FRIKKern/barkpark"
BP="bp"
TEE=""

say() {
  printf '%s\n' "$*"
  [ -n "$TEE" ] && printf '%s %s\n' "$(date -u +%H:%MZ)" "$*" >> "$TEE" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- THE PARSING PATH -----------
# ONE implementation of the trailer regex and the prefix filter. The real run pipes `gh api`
# through it; --selftest pipes a fixture through it. Nothing in the selftest re-implements the
# parse, so a change to the regex that breaks the real run breaks the selftest too.
#
# Input: a stream of JSON arrays on stdin (what `gh api --paginate` emits — one array per page;
# `jq -s … add` flattens them, and a single-array fixture flattens the same way).
# Output: TSV — number, draft|ready, sha9, created_at, task-trailer, head-ref, title.
# shellcheck disable=SC2016  # this IS a jq program; $prefixes is jq's, not the shell's.
PR_JQ='
def trailer:
  (. // "")
  | [scan("(?im)^[ \t]*Task:[ \t]*([A-Za-z0-9][A-Za-z0-9_.:/-]*)[ \t]*$")]
  | if length > 0 then (.[-1][0]) else "NONE" end;
(add // [])
| ( $prefixes | split(",") | map(select(length > 0)) ) as $ps
| .[]
| select( .head.ref as $r | any($ps[]; . as $p | $r | startswith($p)) )
| [ (.number|tostring),
    (if .draft then "draft" else "ready" end),
    (.head.sha[0:9]),
    .created_at,
    (.body | trailer),
    .head.ref,
    (.title | gsub("[\t\n]"; " ")) ]
| @tsv
'

parse_prs() { # parse_prs <prefix-csv>   <stdin: gh api pulls JSON>
  jq -s -r --arg prefixes "$1" "$PR_JQ"
}

# ------------------------------------------------------------------ SELFTEST (no network) ----
# Feeds a FIXTURE through parse_prs — the same jq program the real run uses — and asserts the
# trailer regex and the prefix filter behave. Arms:
#   0 POSITIVE CONTROL: the fixture itself must be non-empty and must yield rows. An empty
#     fixture makes every "absent" arm below pass vacuously, so the selftest REFUSES on one.
#   1 prefix filter keeps api/ refs and drops console/ and apifoo/ (startswith, not substring)
#   2 trailer parsed from a multi-line body; the LAST Task: line wins
#   3 a body with no trailer reads NONE — and NONE is not an empty field
#   4 a null body does not crash the parse
#   5 draft flag rendered as draft/ready, sha truncated to 9
#   6 an EMPTY page (`[]`) yields zero rows — and the CALLER's zero is labelled, not silent
#   7 the held-row section's CANNOT READ line fires on a refusing ledger and never says "ok"
# MUTATIONS that must red it, both in arm 3 (#17700's body carries one specimen of each shape):
#   drop `^` from the trailer regex -> it accepts "See also Task: task-bogus-inline", a mid-line
#     mention that happens to END a line;
#   drop `$` -> it accepts the line "Task: see the tracking issue for the real id" and reports
#     the word "see" as a row id.
# Both were run against this fixture on 2026-09-11: each turns arm 3 red on its own.
selftest() {
  local d out rc fails=0 n
  _ind() { while IFS= read -r _l; do printf '      | %s\n' "$_l"; done; }
  _chk() { # _chk <label> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   $1"
    else echo "FAIL $1: got [$3], wanted [$2]"; fails=$((fails+1)); fi
  }
  d=$(mktemp -d) || return 1

  cat > "$d/pulls.json" <<'FIX'
[
 {"number":17709,"draft":true,"created_at":"2026-09-11T06:55:12Z",
  "head":{"ref":"api/cch-w12-mirror","sha":"1111111122223333444455556666777788889999"},
  "title":"fix(api): mirror syncs unpublished drafts",
  "body":"Some prose.\n\nTask: cch-w12-bl-mirror-syncs-unpublished-drafts\n"},
 {"number":17706,"draft":true,"created_at":"2026-09-11T06:51:03Z",
  "head":{"ref":"api/cch-w65-author","sha":"aaaaaaaabbbbccccddddeeeeffff000011112222"},
  "title":"feat(api): a task document has an author",
  "body":"Task: task-should-not-win\n\nmore prose\n\nTask: cch-w65-bl-a-task-document-has-no-author-field"},
 {"number":17700,"draft":false,"created_at":"2026-09-11T05:00:00Z",
  "head":{"ref":"api/no-trailer","sha":"cccccccc111122223333444455556666777788"},
  "title":"chore(api): no trailer",
  "body":"No Task: trailer here, just a mention mid-sentence.\nSee also Task: task-bogus-inline\nTask: see the tracking issue for the real id"},
 {"number":17690,"draft":false,"created_at":"2026-09-11T04:00:00Z",
  "head":{"ref":"api/null-body","sha":"dddddddd111122223333444455556666777788"},
  "title":"chore(api): null body","body":null},
 {"number":17555,"draft":false,"created_at":"2026-09-10T00:00:00Z",
  "head":{"ref":"console/other-lane","sha":"eeeeeeee111122223333444455556666777788"},
  "title":"other lane","body":"Task: task-other-lane"},
 {"number":17554,"draft":false,"created_at":"2026-09-10T00:00:00Z",
  "head":{"ref":"apifoo/not-a-prefix-match","sha":"ffffffff111122223333444455556666777788"},
  "title":"substring, not prefix","body":"Task: task-substring"}
]
FIX
  echo '[]' > "$d/empty.json"

  echo "== arm 0: POSITIVE CONTROL — the fixture must carry rows, or every absence below is vacuous"
  n=$(jq -s -r '(add // []) | length' < "$d/pulls.json")
  if [ "${n:-0}" -lt 3 ]; then
    echo "FAIL arm0: fixture holds ${n:-0} pull(s) — REFUSING to report a pass on an empty fixture."
    rm -rf "$d"; echo "lane-open-prs.sh selftest: 1 FAILED"; return 1
  fi
  echo "ok   arm0 (fixture holds $n pulls)"
  out=$(parse_prs "api/" < "$d/pulls.json")
  if [ -z "$out" ]; then
    echo "FAIL arm0: the parse yielded NOTHING from a non-empty fixture — the parsing path is dead."
    rm -rf "$d"; echo "lane-open-prs.sh selftest: 1 FAILED"; return 1
  fi

  echo "== arm 1: prefix filter is startswith, not substring"
  _chk "arm1 matches 4 api/ refs"        4 "$(printf '%s\n' "$out" | grep -c '	api/')"
  _chk "arm1 drops console/"             0 "$(printf '%s\n' "$out" | grep -c 'console/other-lane')"
  _chk "arm1 drops apifoo/ (substring)"  0 "$(printf '%s\n' "$out" | grep -c 'apifoo/')"
  _chk "arm1 two prefixes widen it"      5 "$(parse_prs "api/,console/" < "$d/pulls.json" | grep -c .)"

  echo "== arm 2: trailer parsed from a multi-line body; the LAST Task: line wins"
  _chk "arm2 #17709 trailer" "cch-w12-bl-mirror-syncs-unpublished-drafts" \
       "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17709"{print $5}')"
  _chk "arm2 #17706 takes the LAST trailer" "cch-w65-bl-a-task-document-has-no-author-field" \
       "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17706"{print $5}')"

  echo "== arm 3: a body that only MENTIONS Task: mid-sentence reads NONE"
  _chk "arm3 #17700 reads NONE" "NONE" \
       "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17700"{print $5}')"

  echo "== arm 4: a null body does not crash the parse"
  _chk "arm4 #17690 reads NONE" "NONE" \
       "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17690"{print $5}')"

  echo "== arm 5: draft flag and 9-char head sha"
  _chk "arm5 #17709 is draft" "draft" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17709"{print $2}')"
  _chk "arm5 #17700 is ready" "ready" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17700"{print $2}')"
  _chk "arm5 sha is 9 chars"  "111111112" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="17709"{print $3}')"

  echo "== arm 6: an empty page yields zero rows (the caller labels that zero, see arm 7's run)"
  _chk "arm6 empty page, zero rows" 0 "$(parse_prs "api/" < "$d/empty.json" | grep -c . | tr -d ' ')"

  echo "== arm 7: a refusing ledger prints CANNOT READ, exits 3, and says nothing reassuring"
  mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: answers only the pulls REST read, from $STUB_DIR/pulls.json.
case " $* " in *" repos/"*"/pulls"*) cat "$STUB_DIR/pulls.json"; exit 0;; esac
echo "stub gh: unexpected '$*'" >&2; exit 9
STUB
  cat > "$d/bin/bp" <<'STUB'
#!/usr/bin/env bash
# stub bp: every `task get` REFUSES — the shape a lane must never read as "no PR".
[ "$1" = task ] && [ "$2" = get ] || { echo "stub bp: unexpected '$*'" >&2; exit 9; }
echo "stub bp: read refused" >&2; exit 4
STUB
  chmod +x "$d/bin/gh" "$d/bin/bp"
  printf 'cch-w12-bl-mirror-syncs-unpublished-drafts lead-api-r9\n' > "$d/held.txt"
  out=$(cd "$d" && PATH="$d/bin:$PATH" STUB_DIR="$d" bash "$SELF" "api/" "$d/held.txt" 2>&1); rc=$?
  _chk "arm7 exits 3" 3 "$rc"
  _chk "arm7 names the unread row" 1 \
       "$(printf '%s\n' "$out" | grep -c '^CANNOT READ cch-w12')"
  _chk "arm7 never calls it ok" 0 "$(printf '%s\n' "$out" | grep -c 'lease-pr=none')"
  _chk "arm7 still printed the open PRs" 1 \
       "$(printf '%s\n' "$out" | grep -c '^#17709 ')"
  if [ "$fails" -gt 0 ]; then printf '%s\n' "$out" | _ind; fi

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "lane-open-prs.sh selftest: $fails FAILED"; return 1; fi
  echo "lane-open-prs.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ------------------------------------------------------------------ ARGUMENTS -----------------
PREFIXES=""; HELDFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2;;
    --bp)   BP="${2:-}"; shift 2;;
    --tee)  TEE="${2:-}"; shift 2;;
    -h|--help) sed -n '2,60p' "$SELF"; exit 0;;
    --*)    echo "lane-open-prs.sh: unknown flag '$1'" >&2; exit 2;;
    *)      if [ -z "$PREFIXES" ]; then PREFIXES="$1"
            elif [ -z "$HELDFILE" ]; then HELDFILE="$1"
            else echo "lane-open-prs.sh: too many arguments at '$1'" >&2; exit 2; fi
            shift;;
  esac
done
if [ -z "$PREFIXES" ]; then
  echo "lane-open-prs.sh: no branch prefix. usage: lane-open-prs.sh <prefix>[,<prefix2>] [held-rows-file]" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "lane-open-prs.sh: jq is required" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "lane-open-prs.sh: gh is required" >&2; exit 2; }
if [ -n "$HELDFILE" ] && [ ! -f "$HELDFILE" ]; then
  say "CANNOT READ held-rows file: $HELDFILE does not exist. No row was checked; this is NOT 'no rows are in flight'."
  exit 3
fi

REFUSALS=0
say "lane-open-prs: repo=$REPO prefixes=$PREFIXES held=${HELDFILE:-<none given>} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ------------------------------------------------------------------ 1. OPEN PRs ---------------
# ONE REST read, paginated. `gh pr view`/`gh pr list --json` are GraphQL; a loop over them burns
# the point budget the merge sweep needs.
PRJSON=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate 2>/dev/null) || PRJSON=""
if [ -z "$PRJSON" ]; then
  say "CANNOT READ open pulls: gh api repos/$REPO/pulls returned nothing. This is NOT 'no PRs are open' — re-run before you dispatch anyone."
  REFUSALS=$((REFUSALS+1))
  PRLINES=""
else
  if ! PRLINES=$(printf '%s' "$PRJSON" | parse_prs "$PREFIXES" 2>/dev/null); then
    say "CANNOT READ open pulls: gh answered, but the payload did not parse as a pulls array. This is NOT a zero."
    REFUSALS=$((REFUSALS+1)); PRLINES=""
  fi
fi

OPEN_COUNT=0
if [ -n "$PRLINES" ]; then
  while IFS=$'\t' read -r num draftflag sha created task ref title; do
    [ -n "$num" ] || continue
    OPEN_COUNT=$((OPEN_COUNT+1))
    say "#$num $draftflag head=$sha created=$created task=$task $ref — $title"
  done <<EOF
$PRLINES
EOF
fi
if [ "$OPEN_COUNT" = 0 ] && [ "$REFUSALS" = 0 ]; then
  say "NO OPEN PRS matched prefix(es) '$PREFIXES' — the read SUCCEEDED and returned zero. (A failed read says CANNOT READ instead.)"
fi

# ------------------------------------------------------------------ 2. HELD ROWS --------------
if [ -n "$HELDFILE" ]; then
  say "--- held rows from $HELDFILE (ledger: lifecycle_status + claim.lease_extension.pr)"
  ROWS=0; INFLIGHT=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line=$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | awk '{print $1}')
    filew=$(printf '%s' "$line" | awk '{print $2}')
    ROWS=$((ROWS+1))
    if ! json=$(env -u BARKPARK_TOKEN "$BP" task get "$id" -o json 2>/dev/null); then
      say "CANNOT READ $id: the ledger read failed. Its lease PR is UNKNOWN — that is not 'no PR', and it is not clearance to dispatch."
      REFUSALS=$((REFUSALS+1)); continue
    fi
    if ! parsed=$(printf '%s' "$json" | jq -r '[(.doc.content.lifecycle_status // .doc.lifecycle_status // "?"), (.doc.claim.lease_extension.pr // "none"), (.doc.claim.worker // "null")] | @tsv' 2>/dev/null); then
      say "CANNOT READ $id: the ledger answered, but not with parseable JSON. Its lease PR is UNKNOWN."
      REFUSALS=$((REFUSALS+1)); continue
    fi
    IFS=$'\t' read -r life leasepr ledgerw <<EOF
$parsed
EOF
    prnum=$(printf '%s' "$leasepr" | tr -dc '0-9')
    cross="lease-pr NOT in the open set above"
    if [ "$leasepr" = "none" ]; then
      cross="no lease PR recorded"
    elif [ -n "$prnum" ] && printf '%s\n' "$PRLINES" | awk -F'\t' -v n="$prnum" '$1==n{f=1} END{exit !f}'; then
      cross="lease-pr #$prnum IS open above — IN FLIGHT"
      INFLIGHT="$INFLIGHT $id"
    fi
    say "$id lifecycle=$life lease-pr=$leasepr ledger-worker=$ledgerw file-worker=${filew:-?} — $cross"
  done < "$HELDFILE"
  [ "$ROWS" = 0 ] && say "held rows: the file $HELDFILE lists NO rows. An empty list is not 'nothing is in flight'."

  # Rows a successor must NOT dispatch a worker onto: they already have a PR.
  say "--- DISPATCH BLOCK (a row here already has a PR; dispatching onto it manufactures a duplicate)"
  BLOCKED=0
  for id in $INFLIGHT; do BLOCKED=$((BLOCKED+1)); say "DO NOT DISPATCH $id — its lease PR is open."; done
  if [ -n "$PRLINES" ]; then
    while IFS=$'\t' read -r num _d _s _c task _r _t; do
      [ -n "${task:-}" ] || continue
      [ "$task" = NONE ] && continue
      case " $INFLIGHT " in *" $task "*) continue;; esac
      if grep -q -- "$task" "$HELDFILE" 2>/dev/null; then
        BLOCKED=$((BLOCKED+1))
        say "DO NOT DISPATCH $task — open PR #$num carries it as its Task: trailer (the ledger lease may not have caught up)."
      fi
    done <<EOF
$PRLINES
EOF
  fi
  [ "$BLOCKED" = 0 ] && say "dispatch block: EMPTY — no held row has an open PR. (Read the CANNOT READ lines above, if any, before trusting that.)"
fi

if [ "$REFUSALS" -gt 0 ]; then
  say "lane-open-prs: CANNOT READ — $REFUSALS read(s) refused. The in-flight set above is INCOMPLETE; do not dispatch off it."
  exit 3
fi
say "lane-open-prs: OK — $OPEN_COUNT open PR(s) on prefix(es) '$PREFIXES'."
exit 0

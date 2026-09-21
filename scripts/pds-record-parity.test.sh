#!/usr/bin/env bash
#
# MUTATION FIXTURES FOR THE PDS RECORD-PARITY ARM.
#
# THE SELFTEST IS THE DELIVERABLE, NOT A COURTESY. This arm's entire output is
# a success claim about the epic's own record, which makes it exactly the verb
# most able to lie — and every failure mode it exists to stop ALREADY exits 0
# when you get it wrong: a grace window as wide as its own sample greens over
# every divergent row in it; a `gh` with no credentials greens over a window it
# never read; a `$?` test on the trailer extractor greens over every PR that
# names no task at all. So a harness whose fixtures all PASS proves nothing: it
# proves the checker runs, which was never in doubt.
#
# EVERY FIXTURE BELOW PINS AN EXACT EXIT CODE, and the set is deliberately
# two-sided: the green fixtures catch a guard that degrades into ALWAYS-RED, the
# red ones catch a guard that degrades into ALWAYS-GREEN. Deleting either half
# leaves a harness that cannot tell a working arm from a broken one.
#
# NO NETWORK. Axis B runs through `--fixture-dir`, the arm's canned transport,
# which feeds the SAME extraction / status-scoring / disposition code the live
# run uses. Axis A runs through `--charter` + `--commits-file`. A fixture that
# bypassed that code would prove nothing about the live run.
#
# NO `timeout(1)` ANYWHERE — it does not exist on this darwin host, and inside
# an `&&` chain behind a pipe it printed EXIT=0 for a command that never ran.
#
# EXIT CODES UNDER TEST (from the arm)
#   0 PARITY    1 DIVERGENT    2 UNCHECKED / REFUSED    3 USAGE
#
# usage: bash scripts/pds-record-parity.test.sh   (exit 0 = all green)

set -uo pipefail

cd "$(dirname "$0")/.." || { echo "TEST HARNESS FAIL: cannot cd to the repo root" >&2; exit 99; }
ARM="scripts/pds-record-parity.sh"
[ -f "$ARM" ] || { echo "TEST HARNESS FAIL: $ARM not found from $PWD" >&2; exit 99; }
[ -f "scripts/pr-task-gate.sh" ] || { echo "TEST HARNESS FAIL: the canonical extractor is missing" >&2; exit 99; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pds-record-parity-selftest.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

CHECKS=0
FAILURES=0
LAST_OUT=""

# `run <expected-rc> <label> -- <args…>` — runs the arm hermetically and pins
# the exit code. The output is kept in LAST_OUT so a fixture can additionally
# assert on WHAT was said, not merely on the number: an arm that reds for the
# wrong reason is a different defect from an arm that reds.
run() { run_at "$ARM" "$@"; }

# `run_at <arm-path> <expected-rc> <label> -- <args…>` — the same, against a COPY
# of the arm planted in another repository. The shallow / off-HEAD-graft fixtures
# need this: the arm `cd`s to `dirname $0/..`, so the only way to point its
# default `git log` corpus at a fixture repo is to run the copy that lives there.
run_at() {
  local arm="$1" want="$2" label="$3"; shift 4
  CHECKS=$((CHECKS + 1))
  LAST_OUT="$(bash "$arm" "$@" 2>&1)"
  local got=$?
  if [ "$got" -ne "$want" ]; then
    FAILURES=$((FAILURES + 1))
    echo "FAIL  ${label}"
    echo "      expected exit ${want}, got ${got}"
    printf '      | %s\n' "$LAST_OUT" | head -40
    return 1
  fi
  echo "ok    ${label}  (exit ${got})"
  return 0
}

# `harness_fail <msg>` — a FIXTURE that did not come out in the shape it needs to
# be in proves nothing about the arm, and must never be scored as a pass.
harness_fail() {
  FAILURES=$((FAILURES + 1))
  CHECKS=$((CHECKS + 1))
  echo "FAIL  FIXTURE PRECONDITION: $1"
}

# `says <needle> <label>` — assert on the last run's output.
says() {
  local needle="$1" label="$2"
  CHECKS=$((CHECKS + 1))
  case "$LAST_OUT" in
    *"$needle"*) echo "ok    ${label}" ;;
    *) FAILURES=$((FAILURES + 1)); echo "FAIL  ${label}"; echo "      output did not contain: ${needle}" ;;
  esac
}

says_not() {
  local needle="$1" label="$2"
  CHECKS=$((CHECKS + 1))
  case "$LAST_OUT" in
    *"$needle"*) FAILURES=$((FAILURES + 1)); echo "FAIL  ${label}"; echo "      output WRONGLY contained: ${needle}" ;;
    *) echo "ok    ${label}" ;;
  esac
}

# ── fixture construction ─────────────────────────────────────────────────────

# `ledger <dir> <id> <http> <json>` — one canned ledger response. An id with NO
# file 404s, exactly as the live ledger answers for a task that does not exist.
ledger() {
  local dir="$1" id="$2" code="$3" body="$4"
  mkdir -p "$dir/task"
  { printf 'HTTP %s\n' "$code"; printf '%s' "$body"; } > "$dir/task/$id.http"
}

task_doc() { # task_doc <id> <lifecycle> <parent|->
  local id="$1" lc="$2" p="$3" pj="null"
  [ "$p" != "-" ] && pj="\"$p\""
  printf '{"result":{"_id":"%s","_type":"task","kind":"task","lifecycle_status":"%s","parent_id":%s}}' "$id" "$lc" "$pj"
}

# `prs <file> <spec…>` — a canned `gh pr list --json number,mergedAt,body,title`
# array. Each spec is `number|mergedAt|task-id-or-NONE`.
prs() {
  local out="$1"; shift
  local first=1
  printf '[' > "$out"
  local spec num when tid body
  for spec in "$@"; do
    IFS='|' read -r num when tid <<< "$spec"
    if [ "$tid" = "NONE" ]; then
      body="Some description with no trailer at all."
    elif [ "$tid" = "BACKTICK" ]; then
      # The exact shape an ad-hoc jq lens gets WRONG: a backtick-wrapped id.
      # The canonical extractor strips the backticks; a home-grown regex keeps
      # them and the ledger 404s on \`fixture-leaf-done\`, manufacturing a
      # NOT-FOUND that is an artifact of the reader.
      body=$'Summary line.\n\nTask: `fixture-leaf-done`\n'
    else
      body=$'Summary line.\n\nTask: '"$tid"$'\n\nMore prose after the trailer.\n'
    fi
    [ "$first" -eq 0 ] && printf ',' >> "$out"
    first=0
    jq -cn --argjson n "$num" --arg m "$when" --arg b "$body" --arg t "pr $num" \
      '{number:$n, mergedAt:$m, body:$b, title:$t}' >> "$out"
  done
  printf ']' >> "$out"
}

command -v jq >/dev/null 2>&1 || { echo "TEST HARNESS FAIL: jq is required to build fixtures" >&2; exit 99; }

echo "── pds-record-parity selftest ───────────────────────────────────────────"
echo

# ══ AXIS A ═══════════════════════════════════════════════════════════════════
echo "AXIS A — a commit may not cite an authority that does not exist"

CH="$TMP/charter.md"
cat > "$CH" <<'EOF'
# A charter

Some prose that mentions PDS-D999 in passing, which is a REFERENCE, not a
definition — a lens that counted it would call an undefined D defined. The same
goes for PDS-D555, mentioned here and nowhere else; 555 carries the assertion
because it is not on the arm's synthetic roster, and a roster number is PRINTED
in the run's own fixtures line where a says_not could not tell the two apart.

- **PDS-D1** the first decision.
* **PDS-D2** the second, with an asterisk bullet.
**PDS-D3** the third, with no bullet at all.

## PDS-D404 a decision defined as a HEADING

Nothing else defines a D.
EOF

CM_OK="$TMP/commits-ok.txt"
printf 'fix(x): do a thing per PDS-D1 and PDS-D2\n\nfeat(y): PDS-D3\n' > "$CM_OK"
CM_BAD="$TMP/commits-bad.txt"
printf 'fix(x): PDS-D1\n\nfeat(y): cites PDS-D888 which nothing defines\n' > "$CM_BAD"

# THE ROSTER FIXTURES. 777 is ON the arm's synthetic roster (scope :ad) and 9999
# is on it at axis-A scope (:a), so axis A must DROP both out of a commit corpus.
# 888 is deliberately NOT on the roster, which is why the red arm above plants
# it: an arm that skipped everything would green on 888 too, and the pair below
# is the only thing that tells the two apart.
CM_SENTINEL="$TMP/commits-sentinel.txt"
printf 'feat(pds): the fixtures are PDS-D777 and PDS-D9999, and PDS-D1 is real\n' > "$CM_SENTINEL"
grep -q '^PDS_SYNTHETIC_FIXTURES=' "$ARM" || harness_fail "the arm no longer declares PDS_SYNTHETIC_FIXTURES — the roster the two axes share"
case "$(grep '^PDS_SYNTHETIC_FIXTURES=' "$ARM")" in
  *888*) harness_fail "888 is ON the roster, so the axis A red arm below proves nothing" ;;
esac

CM_HEAD="$TMP/commits-heading.txt"
printf 'fix(z): per PDS-D404, which the charter defines as a HEADING and nothing else\n' > "$CM_HEAD"

run 0 "axis A greens when every cited D resolves" -- --axis a --charter "$CH" --commits-file "$CM_OK"
says "defined:    4 distinct PDS-D" "the union lens counts BOTH definition forms — three bold leads and one own-line heading"
says "unresolved: 0" "axis A reports zero unresolved"
says_not "PDS-D555" "a D merely MENTIONED in charter prose is not counted as defined"

# RULING 1, THE REGRESSION THAT SHIPPED SIX FALSE REDS. Before this wave the
# gate lens was bold-lead ONLY, and the charter had grown 24 numbers (D643–D673)
# defined as `### PDS-D### —` headings and nothing else. Six of them were cited
# in merged commits and the arm called all six phantom citations. This fixture
# is that exact shape: a D defined ONLY as a heading, cited by a commit.
run 0 "a D defined ONLY as a heading RESOLVES" -- --axis a --charter "$CH" --commits-file "$CM_HEAD"
says "unresolved: 0" "the heading-only definition resolves the citation"
says_not "UNRESOLVED-CITATION PDS-D404" "the arm no longer manufactures a phantom citation out of its own lens"

# THE RED SIDE. Without this the arm could hardcode `unresolved: 0`.
run 1 "axis A REDS on a commit citing an undefined D" -- --axis a --charter "$CH" --commits-file "$CM_BAD"
says "UNRESOLVED-CITATION PDS-D888" "the red names the offending citation"

# THE ROSTER, BOTH DIRECTIONS. The arm reddened its own main because the squash
# commit of the PR that added axis D described its own fixtures in its message
# and axis A — corpus `git log --format=%B` — read the sentence as a claim on an
# authority. A synthetic on the shared roster is now dropped from the corpus
# BEFORE resolving; anything else is not. The red arm directly above is the
# other half of this pair and must stay adjacent to it.
run 0 "axis A does NOT red on a commit message that merely MENTIONS a roster fixture" -- --axis a --charter "$CH" --commits-file "$CM_SENTINEL"
says "fixtures:   2 dropped before resolving, off a roster of 4" "the drop is COUNTED and PRINTED, so it cannot hide a growing skip list"
says "unresolved: 0" "prose about a fixture is not a claim on an authority"
says_not "UNRESOLVED-CITATION" "the sentinel citations are dropped, not reported"

# …and the roster is DERIVED from one declaration, not copied per axis: the same
# number axis A drops out of a commit message, axis D still reds on in a FILE
# when the declaration says so. That asymmetry is the point of the scope field,
# and the axis D phantom fixture further down is its proof.

# The heading arm of the union must be ANCHORED at the start of the heading
# text. A heading that merely MENTIONS a D in passing — the charter's wave
# banners do this constantly — is a reference, not a definition, and counting it
# would turn the repair into the opposite lie: every mentioned D "defined".
CH_MENTION="$TMP/charter-heading-mention.md"
cat > "$CH_MENTION" <<'EOF'
# A charter

## WAVE 46 — A TITLE THAT MENTIONS PDS-D640 IN PASSING

- **PDS-D1** the only real definition here.
EOF
CM_MENTION="$TMP/commits-mention.txt"
printf 'fix(x): PDS-D640\n' > "$CM_MENTION"
run 1 "a D merely MENTIONED inside a heading is NOT defined" -- --axis a --charter "$CH_MENTION" --commits-file "$CM_MENTION"
says "UNRESOLVED-CITATION PDS-D640" "the union lens anchors on the number at the START of the heading text"

# RULING 1 — the LOOSE heading lens is a LENS ARTIFACT, and the arm says so
# instead of gating on it. The fixture charter defines PDS-D1/PDS-D2/PDS-D3 as bullets and
# only PDS-D404 as a heading, so the loose lens loses all three bullet forms.
run 0 "--heading-lens does NOT fold its red into the exit code" -- --axis a --charter "$CH" --commits-file "$CM_OK" --heading-lens
says "defined:    1 distinct PDS-D" "the loose heading lens sees only the one heading-defined D"
says "unresolved: 3" "the loose heading lens reports every bullet-defined D as unresolved"
says "LENS ARTIFACT" "the loose heading lens labels its own red as an artifact"

# ══ AXIS A RESOLVES THE LETTERED SHAPE THE SAME WAY AXIS D DOES ══════════════
#
# A commit message cites clause (a) of a ruling as `PDS-D220a` exactly as a
# script does. An axis that reds on what its sibling greens is a lens artifact
# wearing a finding's clothes, so the rule here is the SAME rule, not a softer
# one: the base's definition block must carry the literal marker, and a letter
# that is a typo still reds.
CHLA="$TMP/charter-lettered-a.md"
cat > "$CHLA" <<'EOF'
# A charter with lettered rulings

- **PDS-D448 — THE BASE RULING.** A digits-only extractor credits every
  PDS-D448x citation to this entry.
- **PDS-D448a — A LETTERED RULING IN ITS OWN RIGHT.** Separately defined.
- **PDS-D220 — A RULING WITH CLAUSES.** (a) the first clause. (b) the second.

## PDS-D404 a decision defined as a HEADING

Nothing else defines a D.
EOF
CM_LET="$TMP/commits-lettered"
printf 'fix: per PDS-D448a and PDS-D220a and PDS-D220b
' > "$CM_LET"
run 0 "axis A resolves a real lettered ruling AND a clause reference" -- --axis a --charter "$CHLA" --commits-file "$CM_LET"
says "clauses:    2 lettered citation(s) resolved as a CLAUSE" "the clause path is PRINTED on axis A too"
says "unresolved: 0" "and nothing was left over"

printf 'fix: a lettered typo, per PDS-D448z
' > "$CM_LET"
run 1 "axis A REDS on a phantom lettered ruling whose base exists" -- --axis a --charter "$CHLA" --commits-file "$CM_LET"
says "UNRESOLVED-CITATION PDS-D448z" "the red names the phantom by its FULL name, not its numeric base"

printf 'fix: a letter its base has no clause for, per PDS-D220z
' > "$CM_LET"
run 1 "axis A does not let the clause path decay into a base path" -- --axis a --charter "$CHLA" --commits-file "$CM_LET"
says "UNRESOLVED-CITATION PDS-D220z" "220s block carries (a) and (b) and no (z)"

# A missing charter is UNCHECKED, never a pass — an arm that cannot read the
# charter has resolved exactly zero citations.
run 2 "a missing charter lands in UNCHECKED, never a silent PASS" -- --axis a --charter "$TMP/no-such-charter.md" --commits-file "$CM_OK"
says "UNCHECKED: charter not found" "the UNCHECKED names the missing charter"

echo

# ══ AXIS D — a PDS SCRIPT may not cite an authority that does not exist ══════
#
# The corpus axis A structurally cannot see. Every fixture below runs against a
# FIXTURE TREE via --citation-root, so the pins do not move when somebody edits
# a real comment in scripts/. The live tree gets one fixture of its own at the
# end, and it asserts a NUMBER as well as a code — a green over a corpus of
# zero files is exactly the vacuous pass this arm exists to refuse.
echo
echo "AXIS D — a PDS script may not cite an authority that does not exist"

DROOT="$TMP/droot"
mkdir -p "$DROOT/scripts" "$DROOT/tooling/pds"
printf '#!/usr/bin/env bash\n# per PDS-D1 and PDS-D404 this is fine\n' > "$DROOT/scripts/pds-clean.sh"
# A HARNESS in the fixture tree, carrying a planted phantom. It must be SKIPPED.
printf '#!/usr/bin/env bash\n# a planted fixture number: PDS-D9999\n' > "$DROOT/scripts/pds-clean.test.sh"
printf '{"note": "per PDS-D2"}\n' > "$DROOT/tooling/pds/clean.json"

run 0 "axis D greens when every cited D resolves" -- --axis d --charter "$CH" --citation-root "$DROOT"
says "files:      2 in scope" "the harness beside it is EXCLUDED — 3 files on disk, 2 in scope"
says "citations:  3 occurrence(s), 3 distinct PDS-D" "the scan read every occurrence, not just the first per file"
says "undefined:  0 firing" "the harness's planted PDS-D9999 does not red the axis"

# THE PHANTOM. This is the renumber defect in miniature: a comment carried
# forward onto a number the charter no longer (or does not yet) define.
printf '#!/usr/bin/env bash\n# stale after a rebase: PDS-D9999\n' > "$DROOT/scripts/pds-phantom.sh"
run 1 "axis D REDS on a script citing an undefined D" -- --axis d --charter "$CH" --citation-root "$DROOT"
says "UNDEFINED-CITATION   scripts/pds-phantom.sh:2 cites PDS-D9999" "the red names the FILE, the LINE and the number"
says "nearest defined: PDS-D404" "the red offers the nearest defined number, which is what a renumber repair needs"
says "undefined:  1 firing" "exactly one citation fired"

# …and removing it greens again. Without this half the red above is compatible
# with an arm that reds on everything.
rm "$DROOT/scripts/pds-phantom.sh"
run 0 "removing the phantom citation greens axis D again" -- --axis d --charter "$CH" --citation-root "$DROOT"
says_not "UNDEFINED-CITATION" "the red is gone with the citation, not sticky"

# THE SENTINELS. PDS-D777/PDS-D999/PDS-D1000 are this harness's own synthetic numbers and
# must never red — but they must be COUNTED, not silently dropped.
printf '#!/usr/bin/env bash\n# the fixtures PDS-D777 PDS-D999 PDS-D1000 are sentinels\n' > "$DROOT/scripts/pds-sentinel.sh"
run 0 "the synthetic sentinels do not red axis D" -- --axis d --charter "$CH" --citation-root "$DROOT"
says "sentinels:  3 occurrence(s) skipped" "the exclusion is PRINTED, so it cannot hide a growing skip list"
rm "$DROOT/scripts/pds-sentinel.sh"

# ══ THE LETTERED RULING — BOTH ARMS ══════════════════════════════════════════
#
# THE DEFECT THESE PIN. Every scan in the arm used to read the prefix followed
# by DIGITS ONLY, so `PDS-D448a` was extracted as `PDS-D448` — a different
# ruling. All 34 lettered rulings on main collide with a separately-defined
# numeric base, so the collapse was SILENT, and a lettered TYPO could not red at
# all: the base resolved on the phantom's behalf. Reproduced against this same
# fixture shape before the widening: the phantom exited 0 and printed PARITY,
# while a numeric phantom in the same tree exited 1.
#
# TWO ARMS, AND NEITHER IS SUFFICIENT ALONE. The phantom arm alone is satisfied
# by an arm that reds on every letter; the positive arm alone is satisfied by
# the old blind one. Together they say the lens discriminates.
CHL="$TMP/charter-lettered.md"
cat > "$CHL" <<'EOF'
# A charter with lettered rulings

- **PDS-D448 — THE BASE RULING.** It exists, which is the whole trap: a
  digits-only extractor credits every PDS-D448x citation to THIS entry.
- **PDS-D448a — A LETTERED RULING IN ITS OWN RIGHT.** Separately defined.
- **PDS-D220 — A RULING WITH CLAUSES.** (a) the first clause. (b) the second.

## PDS-D404 a decision defined as a HEADING

Nothing else defines a D.
EOF

LROOT="$TMP/lroot"
mkdir -p "$LROOT/scripts"

# ARM 1 — THE PHANTOM. A letter the charter does not carry, on a base it does.
printf '#!/usr/bin/env bash\n# a lettered typo the base used to absorb: PDS-D448z\n' > "$LROOT/scripts/pds-lettered.sh"
run 1 "a phantom LETTERED ruling REDS axis D" -- --axis d --charter "$CHL" --citation-root "$LROOT"
says "cites PDS-D448z" "the red names the phantom by its FULL name, not its numeric base"
says_not "cites PDS-D448
" "the red is not the numeric base wearing the phantom's place"
says "undefined:  1 firing" "exactly one citation fired"

# ARM 2 — THE POSITIVE CONTROL. A real lettered ruling must still resolve, and
# resolve QUIETLY: present-in-the-file is not fires-when-it-should, and an arm
# that reds on every letter would pass arm 1 on its own.
printf '#!/usr/bin/env bash\n# a REAL lettered ruling: PDS-D448a\n' > "$LROOT/scripts/pds-lettered.sh"
run 0 "a REAL lettered ruling resolves QUIETLY on axis D" -- --axis d --charter "$CHL" --citation-root "$LROOT"
says_not "UNDEFINED-CITATION" "the real lettered citation raises nothing"
says "citations:  1 occurrence(s), 1 distinct PDS-D" "it was READ — a green over an unread corpus is the vacuous pass"
says "undefined:  0 firing" "and it resolved"

# ARM 3 — THE CLAUSE. `PDS-D220a` names clause (a) inside PDS-D220 and resolves
# against the base's definition BLOCK carrying the literal `(a)`. This is the
# one path a letter may take through its base, and it is NOT "the base exists":
# arm 1's PDS-D448z has a defined base too and still reds.
printf '#!/usr/bin/env bash\n# a CLAUSE reference: PDS-D220a and PDS-D220b\n' > "$LROOT/scripts/pds-lettered.sh"
run 0 "a CLAUSE reference resolves through its base's (x) marker" -- --axis d --charter "$CHL" --citation-root "$LROOT"
says "clauses:    2 lettered citation(s) resolved as a CLAUSE" "the clause path is PRINTED, never a silent skip"
says_not "UNDEFINED-CITATION" "neither clause reds"

# ARM 3b — AND THE CLAUSE PATH IS NOT A BASE PATH. PDS-D220z shares 220's base,
# whose block carries (a) and (b) and no (z).
printf '#!/usr/bin/env bash\n# a letter its base has no clause for: PDS-D220z\n' > "$LROOT/scripts/pds-lettered.sh"
run 1 "a letter its base carries no clause marker for still REDS" -- --axis d --charter "$CHL" --citation-root "$LROOT"
says "cites PDS-D220z" "the clause lens did not become a base lens"
rm "$LROOT/scripts/pds-lettered.sh"

# ARM 4 — THE DEFINITION SIDE. The charter above defines PDS-D448 AND PDS-D448a
# as two rulings; a digits-only definition scan merges them into one.
printf '#!/usr/bin/env bash\n# every citation here resolves: PDS-D448 PDS-D448a PDS-D220 PDS-D404\n' > "$LROOT/scripts/pds-lettered.sh"
run 0 "the definition lens counts a lettered ruling SEPARATELY from its base" -- --axis d --charter "$CHL" --citation-root "$LROOT"
says "defined:    4 distinct PDS-D in the charter" "448, 448a, 220 and 404 — four, not the three a digits-only lens sees"
says "citations:  4 occurrence(s), 4 distinct PDS-D" "and the citing side kept 448 and 448a apart too"
rm "$LROOT/scripts/pds-lettered.sh"

# A corpus root with nothing in it is UNCHECKED. An arm that printed PARITY here
# would be certifying a corpus it never opened.
run 2 "an empty corpus root is UNCHECKED, never a green" -- --axis d --charter "$CH" --citation-root "$TMP/no-such-root"
says "UNCHECKED: the scope matched no file" "the UNCHECKED names the empty scope"

run 2 "axis D with a missing charter is UNCHECKED" -- --axis d --charter "$TMP/no-such-charter.md" --citation-root "$DROOT"
says "UNCHECKED: charter not found" "the UNCHECKED names the missing charter"

# THE LIVE TREE. The fixtures above prove the mechanism; this one proves the
# mechanism is pointed at the real corpus. It pins a FLOOR on the citation count
# rather than an exact number, because the real corpus grows.
run 0 "axis D is GREEN on this checkout's real scripts/pds-*.sh + tooling/pds/**" -- --axis d
LIVE_OCC="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^  citations:  \([0-9]*\) occurrence.*/\1/p')"
CHECKS=$((CHECKS + 1))
if [ "${LIVE_OCC:-0}" -ge 100 ]; then
  echo "ok    the live run read ${LIVE_OCC} citations (floor 100) — the green is over a real corpus"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  the live axis D green covered only ${LIVE_OCC:-0} citation(s) — a green over an empty corpus"
fi

# ══ AXIS A, UNIQUENESS LEG — one D-number, one finding ═══════════════════════
#
# The old definition set was `sort -u`'d, so a number defined TWICE read as
# resolved and the arm could not have noticed if it tried: it never counted.
# PDS-D664 names two unrelated findings on the live charter and a citation of it
# resolved against whichever copy the sort kept — a resolution certified against
# the wrong law.
#
# DELIBERATELY HERMETIC — these fixtures never read the epic's real charter.
# The pinned baseline goes stale the moment a wave lands a new collision (the
# mechanism recurs EVERY wave), and a stale baseline that RED A REQUIRED GATE
# would be "fixed" by deleting the baseline within the day. Staleness is a
# hand-run finding on purpose. What CI must protect is the arm's LOGIC, which is
# what these fixtures pin.
echo "AXIS A — the uniqueness leg (one D-number, one finding)"

CHD="$TMP/charter-dups.md"
cat > "$CHD" <<'EOF'
# A charter that allocated one number twice

### Wave 1 2026-01-01 — REVIEWED

### PDS-D110 — THE FIRST FINDING, ALLOCATED BY THE REVIEWER.

- **PDS-D111 — A SECOND, SINGLY-DEFINED FINDING.** Its body goes on to cite
  **PDS-D111** and **PDS-D111** again, because a decision's body cites decisions.
  A permissive grammar would score those bare bolds as re-definitions.

## WAVE 2 2026-01-02 — DECIDED

### PDS-D110 — A COMPLETELY UNRELATED FINDING, ALLOCATED BY THE DECIDER.

- **PDS-D112 — THE ONLY DEFINITION OF ONE-TWELVE.** This entry admits it at
  `:660` (CORRECTED, PDS-D112 — this entry read `:410-411`, which is an
  unrelated row), an inline parenthetical that is NOT a definition.
EOF

CM_DUP="$TMP/commits-dup.txt"
printf 'fix(x): per PDS-D110\n\nfeat(y): per PDS-D111 and PDS-D112\n' > "$CM_DUP"

# THE RED SIDE FIRST: an unbaselined duplicate is DIVERGENT, by name, with both
# lines printed. A foreign charter gets no excuses — nobody measured it.
run 1 "an UNBASELINED duplicate definition is DIVERGENT" -- --axis a --charter "$CHD" --commits-file "$CM_DUP"
# A NON-ZERO titled count, asserted before anything is concluded from it. The
# grammar lives in an awk pattern, and an awk that cannot parse it (mawk before
# 1.3.4 silently matches nothing for POSIX character classes) would report
# `titled: 0 / duplicated: 0` and GREEN — a vacuous pass from a leg that read
# nothing. Pinning the count makes that host a loud red instead of a quiet one.
says "titled:     4 definitions over 3 distinct PDS-D" "the titled grammar actually PARSED the charter (a zero here would green vacuously)"
says "duplicated: 1 number(s) defined more than once" "the leg COUNTS definitions instead of sort -u'ing them away"
says "DUPLICATE-DEFINITION PDS-D110 :5 :13" "the duplicate is named WITH both line numbers"
says "NOT IN THE BASELINE" "an unmeasured charter's duplicate is not excused"
says "baseline:   NONE" "the arm says plainly that this charter carries no measured baseline"

# THE FALSE-POSITIVE SIDE, which is the whole reason the uniqueness grammar is
# STRICTER than the resolution grammar: `**PDS-D111**` inside a body is how the
# charter CITES a decision. Counting it would have scored 65 collisions on the
# live charter where 20 exist.
says_not "DUPLICATE-DEFINITION PDS-D111" "a bare-bold CITATION inside a body is not a second definition"

# THE D559 SHAPE, BY NAME AND NOT BY THRESHOLD: an inline parenthetical
# `(CORRECTED …, PDS-D112 — …)` inside another decision's body. A naive
# `PDS-D### —` grep counts it; the titled grammar does not; and the arm
# re-derives that gap on every run and refuses to leave a member of it silent.
says_not "DUPLICATE-DEFINITION PDS-D112" "an inline parenthetical is not a definition (the D559 shape)"
says "UNNAMED-NAIVE-ONLY   PDS-D112" "the naive-vs-titled gap is re-derived per run and every member of it is surfaced"

# THE MECHANISM IS PRINTED, not just the symptom — a reader of a future
# duplicate has to be able to learn where duplicates come from.
says "REVIEW block and ONE in the NEXT wave's DECIDE block" "the arm records the allocation defect, not merely its symptom"

# A CITATION OF A DUPLICATED NUMBER RESOLVES TO NOTHING SINGLE, and the arm says
# so rather than quietly picking whichever definition survived a sort.
says "AMBIGUOUS-CITATION   PDS-D110" "a citation of a doubly-defined number is reported as ambiguous"
says_not "AMBIGUOUS-CITATION   PDS-D111" "a singly-defined cited number is not called ambiguous"

# THE GREEN SIDE: strip the second allocation and the leg goes quiet. Without
# this the leg could be hardcoded to red on any charter at all.
CHD_OK="$TMP/charter-dups-fixed.md"
sed '12,13d' "$CHD" > "$CHD_OK"          # drop the decider's second allocation
grep -c 'PDS-D110 —' "$CHD_OK" | grep -qx 1 \
  || harness_fail "charter-dups-fixed.md must define PDS-D110 exactly once, or its green proves nothing"
run 0 "the same charter with ONE allocation of PDS-D110 is PARITY" -- --axis a --charter "$CHD_OK" --commits-file "$CM_DUP"
says "duplicated: 0 number(s) defined more than once" "the leg reports zero when the charter allocates each number once"
says_not "DUPLICATE-DEFINITION" "nothing is named when nothing collides"

# THE BASELINE IS TWO-SIDED. A baseline that only ever FORGIVES decays into a
# suppression list nobody can prove still describes the corpus, so a baselined
# pair that has VANISHED reds too, by name. The fixture is named exactly
# `bp-pds-charter.md` because that basename is what arms the baseline.
BLDIR="$TMP/baselined"; mkdir -p "$BLDIR"
cat > "$BLDIR/bp-pds-charter.md" <<'EOF'
# A charter carrying the baselined basename and none of the baselined pairs

- **PDS-D1 — ONE FINDING, DEFINED ONCE.**
EOF
CM_BL="$TMP/commits-baselined.txt"
printf 'fix(x): PDS-D1\n' > "$CM_BL"
run 1 "a baselined pair that VANISHED is DIVERGENT (a stale baseline is a lie too)" -- --axis a --charter "$BLDIR/bp-pds-charter.md" --commits-file "$CM_BL"
says "STALE-BASELINE       PDS-D399" "the stale entry is named, so the baseline can be repaired instead of guessed at"
says "baseline:   PINNED for bp-pds-charter.md" "the baseline arms on the charter it was measured on"

echo

# ══ AXIS A, THE DEFAULT PATH — the `git log` corpus itself ═══════════════════
#
# EVERY fixture above hands the arm a `--commits-file`, which means the DEFAULT
# corpus — `git log` — had ZERO coverage, and that is exactly where the vacuous
# green lived: under `git clone --depth 1` the arm printed `cited: 0 /
# unresolved: 0` and PARITY at exit 0, the same verdict sentence a full checkout
# prints over 188 citations. actions/checkout@v4 is shallow BY DEFAULT.
#
# These fixtures are hermetic and NETWORK-FREE: a synthetic origin cloned over
# `file://` (a local transport — and the only one under which `--depth` is not
# silently ignored). Global/system git config is neutered so a host with, say,
# `commit.gpgsign = true` cannot break fixture construction.
echo "AXIS A — the default git-log corpus (truncated-walk guard)"

GITFX="$(cd "$TMP" && pwd -P)/gitfx"          # physical: GIT_CEILING_DIRECTORIES does not resolve symlinks
mkdir -p "$GITFX"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=pds GIT_AUTHOR_EMAIL=pds@example.invalid
export GIT_COMMITTER_NAME=pds GIT_COMMITTER_EMAIL=pds@example.invalid

# `plant <dir>` — put a copy of the arm where its own `cd $(dirname $0)/..`
# lands in the fixture repo.
plant() { mkdir -p "$1/scripts" && cp "$ARM" "$1/scripts/pds-record-parity.sh"; }

# ORIGIN: `main` cites PDS-D1..3 (all defined by $CH). An ORPHAN `sidecar`
# branch cites PDS-D9 and shares no ancestor with main — that disjointness is
# what makes the off-HEAD graft below genuinely off-HEAD.
ORIGIN="$GITFX/origin"
(
  set -e
  git init -q -b main "$ORIGIN"
  cd "$ORIGIN"
  for n in 1 2 3; do echo "$n" > "f$n"; git add -A; git commit -q -m "chore: per PDS-D$n"; done
  git checkout -q --orphan sidecar
  git rm -q -rf . >/dev/null 2>&1 || true
  echo s > s.txt; git add -A; git commit -q -m "chore: sidecar per PDS-D9"
  git checkout -q main
) >/dev/null 2>&1 || harness_fail "could not build the synthetic origin repo"

# ── (1) THE REAL CASE: a --depth 1 checkout ──────────────────────────────────
SHALLOW="$GITFX/shallow"
git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW" >/dev/null 2>&1 || harness_fail "could not build the --depth 1 clone"
plant "$SHALLOW"
SH_GRAFT="$(head -1 "$SHALLOW/.git/shallow" 2>/dev/null || true)"
SH_HEAD="$(git -C "$SHALLOW" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$SH_GRAFT" ] || [ "$SH_GRAFT" != "$SH_HEAD" ]; then
  harness_fail "the --depth 1 clone did not graft at HEAD (graft='${SH_GRAFT}' head='${SH_HEAD}') — the fixture would prove nothing"
fi

run_at "$SHALLOW/scripts/pds-record-parity.sh" 2 \
  "a --depth 1 checkout is UNCHECKED, never PARITY" -- --axis a --charter "$CH"
says "UNCHECKED: TRUNCATED WALK" "the refusal names the TRUNCATION"
says "$SH_GRAFT" "the refusal names the GRAFT it stopped at"
says "visible: 1 commit(s) reachable from HEAD" "the refusal states how much of the corpus it could see"
says "fetch-depth: 0" "the refusal names the CI fix"
says "git fetch --unshallow" "the refusal names the local fix"
says "--commits-file" "the refusal names the honest escape"
# The VERDICT SENTENCE, not the bare word: the refusal itself says the words
# "instead of printing PARITY at exit 0", and a needle that loose would red on
# the arm's own explanation of what it refused to do.
says_not "pds-record-parity: PARITY" "the truncated run does NOT print the parity verdict sentence"
says_not "unresolved: 0" "the truncated run does not report a citation tally it never computed"

# ── (2) THE ESCAPE STILL WORKS on that same shallow checkout ─────────────────
# Proves the guard is FENCED to the git-log path: --commits-file brings its own
# corpus, so the arm still runs — and can still RED.
run_at "$SHALLOW/scripts/pds-record-parity.sh" 0 \
  "the shallow checkout still RUNS when handed --commits-file" -- --axis a --charter "$CH" --commits-file "$CM_OK"
says "cited:      3 distinct PDS-D" "the escape reads the corpus it was handed, not the truncated walk"
run_at "$SHALLOW/scripts/pds-record-parity.sh" 1 \
  "the escape can still RED on a shallow checkout" -- --axis a --charter "$CH" --commits-file "$CM_BAD"
says "UNRESOLVED-CITATION PDS-D888" "the escape's red still names the offending citation"

# ── (3) THE OFF-HEAD GRAFT: store-shallow, HEAD complete ────────────────────
# THIS IS THE FIXTURE THAT PINS THE PREDICATE. One `--depth` fetch of an
# unrelated branch flips `--is-shallow-repository` to true for the whole
# repository while `git log HEAD` still reaches the root — the shape the shared
# checkout /Volumes/SATECHI/github/barkpark is in today (graft 360b675903, 5132
# commits, one root). A future builder who "simplifies" the predicate back to
# `--is-shallow-repository` reds HERE, by name.
OFFHEAD="$GITFX/offhead"
git clone -q "file://$ORIGIN" "$OFFHEAD" >/dev/null 2>&1 || harness_fail "could not build the full clone"
git -C "$OFFHEAD" fetch -q --depth 1 origin sidecar >/dev/null 2>&1 || harness_fail "could not plant the off-HEAD graft"
plant "$OFFHEAD"
OH_STORE="$(git -C "$OFFHEAD" rev-parse --is-shallow-repository 2>/dev/null || true)"
OH_GRAFT="$(head -1 "$OFFHEAD/.git/shallow" 2>/dev/null || true)"
git -C "$OFFHEAD" merge-base --is-ancestor "${OH_GRAFT:-HEAD}" HEAD >/dev/null 2>&1
OH_ANC=$?
if [ "$OH_STORE" != "true" ] || [ "$OH_ANC" -ne 1 ]; then
  harness_fail "the off-HEAD fixture is not in shape (is-shallow='${OH_STORE}' want true; is-ancestor rc=${OH_ANC} want 1) — it could pass for the wrong reason"
fi

run_at "$OFFHEAD/scripts/pds-record-parity.sh" 0 \
  "a store-shallow repo whose HEAD history is COMPLETE still RUNS" -- --axis a --charter "$CH"
says "cited:      3 distinct PDS-D" "the off-HEAD-graft repo's full corpus is read (3 commits, 3 citations)"
says "unresolved: 0" "the off-HEAD-graft repo greens on its real corpus"
says_not "TRUNCATED WALK" "a graft that is NOT an ancestor of HEAD does not truncate the walk"
says_not "WALK COMPLETENESS UNKNOWN" "an off-HEAD graft is a decided answer, not an unknown"

# ── (4) NOT A WORK TREE AT ALL — the pre-existing arm with zero coverage ────
# GIT_CEILING_DIRECTORIES stops git's upward search at the fixture root, so a
# host whose TMPDIR happens to sit inside a repository cannot make this pass
# (or fail) for the wrong reason. $GITFX is a PHYSICAL path for the same reason.
NOWT="$GITFX/nowt"
mkdir -p "$NOWT"
plant "$NOWT"
export GIT_CEILING_DIRECTORIES="$GITFX"
run_at "$NOWT/scripts/pds-record-parity.sh" 2 \
  "a directory that is not a work tree is UNCHECKED" -- --axis a --charter "$CH"
says "UNCHECKED: not inside a git work tree" "the UNCHECKED names the missing work tree"
says_not "TRUNCATED WALK" "the work-tree refusal is not mislabelled as a truncated walk"
unset GIT_CEILING_DIRECTORIES

unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

echo

# ══ AXIS B ═══════════════════════════════════════════════════════════════════
echo "AXIS B — a merged PR may not leave its task row open"

# One window, six PRs, spanning 100 hours so a 6h grace is legal against it.
FX="$TMP/fx"
mkdir -p "$FX"
prs "$FX/prs.json" \
  "101|2026-01-01T00:00:00Z|fixture-leaf-done" \
  "102|2026-01-02T00:00:00Z|fixture-leaf-open" \
  "103|2026-01-03T00:00:00Z|fixture-root-open" \
  "104|2026-01-04T00:00:00Z|fixture-cancelled" \
  "105|2026-01-05T04:00:00Z|NONE" \
  "106|2026-01-05T04:00:00Z|BACKTICK"
ledger "$FX" fixture-leaf-done  200 "$(task_doc fixture-leaf-done  done   fixture-root-open)"
ledger "$FX" fixture-leaf-open  200 "$(task_doc fixture-leaf-open  open   fixture-root-open)"
ledger "$FX" fixture-root-open  200 "$(task_doc fixture-root-open  open   -)"
ledger "$FX" fixture-cancelled  200 "$(task_doc fixture-cancelled  cancelled fixture-root-open)"

# NOW is pinned far past the window so nothing is graced by accident. A fixture
# whose verdict depends on the wall clock is a fixture that rots.
export PDS_RECORD_PARITY_NOW=1800000000

run 1 "axis B REDS on the one leaf slice merged over an open row" -- --axis b --fixture-dir "$FX"
says "DIVERGENT  fixture-leaf-open" "the red names the leaf row"
says "EPIC-ROOT-IN-FLIGHT  fixture-root-open" "an open epic ROOT is advisory, never redding"
says "LEAF slices (REDDING):          1" "exactly one leaf reds"
# THE REDDING COMPOSITION, arm 1 of 3. The headline counts TWO classes — a
# merge over an open row and a merge over an id the ledger does not carry —
# under a label that names only the first. Here the ghost half is 0, so the
# headline and the open half agree; that agreement is exactly what made the
# conflation invisible, and is why the split must be PRINTED, not inferred.
says "of which merged over an OPEN row:    1" "the redding headline prints its OPEN-row half"
says "of which merged over a MISSING id:   0" "…and its MISSING-id half, which is zero here"
says_not "DIVERGENT  fixture-leaf-done" "a done row is parity"
says_not "DIVERGENT  fixture-cancelled" "a cancelled row is terminal, not divergent"

# THE WINDOW HEADER — printed every run, or the denominator drifts in silence.
says "PR range:   #101 … #106" "the run prints the PR-number range it actually fetched"
says "span:       100.0 h" "the run prints the derived window span in hours"

# RULING 2, the OTHER direction: the root must not red merely because it is
# open, and the leaf must not be excused merely because its parent is.
says "terminal (done|cancelled):   2" "both terminal lifecycles are counted terminal"

# SHARP EDGE (a) — the extractor exits 0 with NO trailer and signals absence
# only by empty stdout. #105 has no trailer. If the arm tested `$?` it would
# read an empty task id as a successful extraction and then 404 on "".
says "no trailer: 1 PRs carry no Task: trailer" "a trailer-less PR is counted as such, not as an empty id"
says_not "NOT-FOUND  " "no NOT-FOUND is manufactured out of a trailer-less PR"

# REUSE, NOT A SECOND LENS — #106 wraps its id in backticks. The canonical
# extractor strips them; a home-grown jq regex keeps them and 404s.
says "task ids:   4 distinct across 6 PRs" "the backticked id resolves to the SAME task, via the canonical grammar"

# ── the vacuity assertion ────────────────────────────────────────────────────
# THE CENTRAL FIXTURE. A grace at least as wide as the window suppresses every
# divergent row in it and prints a green that proves nothing. The arm must
# REFUSE, not green.
run 2 "grace >= window span is REFUSED, not run vacuously" -- --axis b --fixture-dir "$FX" --grace-hours 168
says "REFUSED: grace (168 h) >= window span (100 h floor)" "the refusal names both numbers"
says_not "PARITY" "the refusal is not dressed up as a pass"

# The boundary, both sides. 100h span: 100 is refused, 99 runs.
run 2 "grace exactly equal to the span is refused (>=, not >)" -- --axis b --fixture-dir "$FX" --grace-hours 100
run 1 "grace one hour under the span still runs, and still reds" -- --axis b --fixture-dir "$FX" --grace-hours 99

# Grace DOES suppress an honestly-fresh row. Without this the arm could satisfy
# every fixture above by ignoring grace entirely.
FXG="$TMP/fxg"
mkdir -p "$FXG"
prs "$FXG/prs.json" \
  "201|2026-01-01T00:00:00Z|fixture-leaf-done" \
  "202|2026-01-05T04:00:00Z|fixture-leaf-open"
ledger "$FXG" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
ledger "$FXG" fixture-leaf-open 200 "$(task_doc fixture-leaf-open open fixture-root-open)"
# now = 2026-01-05T05:00:00Z → the open row's PR merged 1h ago.
# Set it as a PLAIN assignment, not as a command prefix: a variable assignment
# prefixed to a SHELL FUNCTION call persists in the shell after the call in
# bash, so the prefix form would silently leak this clock into every later
# fixture — the harness would then be testing a different arm than it thinks.
PDS_RECORD_PARITY_NOW=1767589200
run 0 "a leaf whose latest PR merged inside grace is suppressed" -- --axis b --fixture-dir "$FXG" --grace-hours 6
says "GRACE      fixture-leaf-open" "the suppression is PRINTED, never silent"
# …and the same row reds once grace is narrow enough not to cover it.
run 1 "the same row REDS with a 0h grace — grace is doing real work" -- --axis b --fixture-dir "$FXG" --grace-hours 0
PDS_RECORD_PARITY_NOW=1800000000

# ── UNCHECKED, in every direction ───────────────────────────────────────────
# A 404 from the ledger is an ANSWER: the PR merged over a task id that does
# not exist. That is a definitive red, not an outage.
FX404="$TMP/fx404"
mkdir -p "$FX404/task"
prs "$FX404/prs.json" \
  "301|2026-01-01T00:00:00Z|fixture-ghost" \
  "302|2026-01-05T04:00:00Z|fixture-leaf-done"
ledger "$FX404" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
run 1 "a merged PR naming a task the ledger does not carry is a definitive RED" -- --axis b --fixture-dir "$FX404"
says "NOT-FOUND  fixture-ghost" "the 404 row is named"
# ARM 2 of 3 — the MIRROR. One ghost, no open leaf: the headline is 1 again,
# but now it is the MISSING-id half that carries it. A single conflated
# counter prints an identical headline for arm 1 and arm 2; only the
# composition lines tell the two windows apart.
says "LEAF slices (REDDING):          1" "the ghost reds the headline"
says "of which merged over an OPEN row:    0" "no open-row leaf in this window"
says "of which merged over a MISSING id:   1" "the ghost is counted as the MISSING-id half"

# ARM 3 of 3 — BOTH AT ONCE, the independence proof. One merge over an open
# leaf and one over an id the ledger does not carry, in the same window: the
# headline must be 2 and each half must be 1. Compare against arms 1 and 2,
# where the same halves read 1/0 and 0/1 — each moves without the other.
FXMIX="$TMP/fxmix"
mkdir -p "$FXMIX"
prs "$FXMIX/prs.json" \
  "601|2026-01-01T00:00:00Z|fixture-ghost" \
  "602|2026-01-05T04:00:00Z|fixture-leaf-open"
ledger "$FXMIX" fixture-leaf-open  200 "$(task_doc fixture-leaf-open  open fixture-root-open)"
run 1 "a window carrying BOTH redding classes reds once and reports both" -- --axis b --fixture-dir "$FXMIX"
says "DIVERGENT  fixture-leaf-open" "the open-row leaf is named"
says "NOT-FOUND  fixture-ghost" "the ghost is named in the same run"
says "LEAF slices (REDDING):          2" "the headline is the SUM of the two classes"
says "of which merged over an OPEN row:    1" "the OPEN-row half moved independently"
says "of which merged over a MISSING id:   1" "the MISSING-id half moved independently"

# …but a DECLARED ABSENCE is not a ghost. #6371 on the live record says
# literally `Task: n/a`; the canonical grammar extracts `n/a` as an id and the
# ledger 404s on it. Reporting that as "merged over a task id the ledger does
# not carry" is a true statement wearing the wrong sentence, and it REDS where
# the structurally identical no-trailer case is advisory. Two-sided: the
# sentinel must be advisory AND the real ghost above must still red, or the
# disposition rule has degraded into a suppression switch.
FXNA="$TMP/fxna"
mkdir -p "$FXNA"
prs "$FXNA/prs.json" \
  "701|2026-01-01T00:00:00Z|n/a" \
  "702|2026-01-03T00:00:00Z|N/A" \
  "703|2026-01-05T04:00:00Z|fixture-leaf-done"
ledger "$FXNA" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
run 0 "a PR declaring \`Task: n/a\` is advisory, not a NOT-FOUND red" -- --axis b --fixture-dir "$FXNA"
says "declared none: 2 PRs declare a SENTINEL id" "both spellings of the sentinel are counted, case-insensitively"
says_not "NOT-FOUND  " "no ghost task is manufactured out of a declared absence"
says "task ids:   1 distinct across 3 PRs" "the sentinel never reaches the ledger sweep"

# A 2xx with no document in the envelope is an answer that answers NOTHING. It
# is not evidence the task is absent (absence answers 404) — UNCHECKED.
FXNULL="$TMP/fxnull"
mkdir -p "$FXNULL"
prs "$FXNULL/prs.json" \
  "401|2026-01-01T00:00:00Z|fixture-nulldoc" \
  "402|2026-01-05T04:00:00Z|fixture-leaf-done"
ledger "$FXNULL" fixture-nulldoc  200 '{"result":null}'
ledger "$FXNULL" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
run 2 "a 2xx with no task document is UNCHECKED, never a pass" -- --axis b --fixture-dir "$FXNULL"
says "with no task document in the envelope" "the UNCHECKED says what it saw"

# UNCHECKED OUTRANKS DIVERGENT. The worst-case fold, proven: a window carrying
# BOTH an unreadable row and a red row must exit 2, because "the rule could not
# be checked" is a bigger claim than "the rule was checked and broken".
FXBOTH="$TMP/fxboth"
mkdir -p "$FXBOTH"
prs "$FXBOTH/prs.json" \
  "501|2026-01-01T00:00:00Z|fixture-nulldoc" \
  "502|2026-01-05T04:00:00Z|fixture-leaf-open"
ledger "$FXBOTH" fixture-nulldoc  200 '{"result":null}'
ledger "$FXBOTH" fixture-leaf-open 200 "$(task_doc fixture-leaf-open open fixture-root-open)"
run 2 "UNCHECKED outranks DIVERGENT in the worst-case fold" -- --axis b --fixture-dir "$FXBOTH"
says "DIVERGENT  fixture-leaf-open" "the divergent row is still REPORTED, only outranked"

# An EMPTY window cannot falsify anything. Exiting 0 over it would be the exact
# vacuous green this arm exists to refuse.
FXEMPTY="$TMP/fxempty"
mkdir -p "$FXEMPTY"
printf '[]' > "$FXEMPTY/prs.json"
run 2 "an empty PR window is UNCHECKED, never a green" -- --axis b --fixture-dir "$FXEMPTY"
says "window is EMPTY" "the empty-window refusal says why"

# A transport that answers with something that is not an array answered without
# answering.
FXJUNK="$TMP/fxjunk"
mkdir -p "$FXJUNK"
printf '{"message":"Not Found"}' > "$FXJUNK/prs.json"
run 2 "a non-array PR list is UNCHECKED" -- --axis b --fixture-dir "$FXJUNK"

# A green window — no divergent leaves anywhere. Without this fixture an arm
# that had degraded into ALWAYS-RED would still pass every red fixture above.
FXOK="$TMP/fxok"
mkdir -p "$FXOK"
prs "$FXOK/prs.json" \
  "601|2026-01-01T00:00:00Z|fixture-leaf-done" \
  "602|2026-01-05T04:00:00Z|fixture-cancelled"
ledger "$FXOK" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
ledger "$FXOK" fixture-cancelled 200 "$(task_doc fixture-cancelled cancelled fixture-root-open)"
run 0 "a window whose every row is terminal is PARITY (exit 0)" -- --axis b --fixture-dir "$FXOK"
says "PARITY" "the green says PARITY"

# ── offline / credential-less ───────────────────────────────────────────────
# `gh` absent and `gh` present-but-credential-less both land in UNCHECKED. A
# PATH with no gh on it reproduces the first exactly; the second is reproduced
# by pointing gh's config at a directory that does not exist, which makes real
# gh exit 4.
echo
echo "OFFLINE — the arm must never green because it could not look"

# A PATH carrying EVERY tool the arm needs EXCEPT gh. A blanket
# PATH=/nonexistent would also remove jq and would therefore prove only that
# the jq guard fires — a fixture that passes for the wrong reason is not
# evidence about the branch it claims to cover.
SHIMBIN="$TMP/bin-no-gh"
mkdir -p "$SHIMBIN"
for t in bash dirname env jq curl base64 date sed grep awk head tail cut sort uniq wc tr mktemp sleep cat rm cp printf; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  ln -sf "$p" "$SHIMBIN/$t"
done
[ -x "$SHIMBIN/jq" ] || { echo "TEST HARNESS FAIL: could not shim jq into the no-gh PATH" >&2; exit 99; }
CHECKS=$((CHECKS + 1))
OUT="$(PATH="$SHIMBIN" bash "$ARM" --axis b 2>&1)"; RC=$?
case "$OUT" in
  *"\`gh\` is not installed"*)
    if [ "$RC" -eq 2 ]; then
      echo "ok    a PATH with jq but NO gh lands in UNCHECKED  (exit 2)"
    else
      FAILURES=$((FAILURES + 1)); echo "FAIL  a missing gh must exit 2, got ${RC}"
    fi ;;
  *)
    FAILURES=$((FAILURES + 1))
    echo "FAIL  a missing gh must be named as the reason for UNCHECKED"
    printf '      | %s\n' "$OUT" | head -10 ;;
esac

if command -v gh >/dev/null 2>&1; then
  # A REAL gh, failing for real, without ever reaching a real window. The repo
  # is deliberately unresolvable so this fixture cannot degrade into a live
  # 400-PR sweep on a host (or a CI runner) whose gh IS authenticated — a
  # "credential-less" fixture that quietly performs the full live run is not a
  # fixture, it is a second production invocation wearing a test's name.
  # Unauthenticated hosts take this branch with gh's exit 4 (NO CREDENTIALS);
  # authenticated ones take it with gh's repo-resolution failure. Both are the
  # contract under test: gh non-zero => UNCHECKED, never a silent PASS.
  CHECKS=$((CHECKS + 1))
  OUT="$(GH_CONFIG_DIR="$TMP/no-such-gh-config" GH_TOKEN="" GITHUB_TOKEN="" \
         PDS_RECORD_PARITY_REPO="FRIKKern/pds-record-parity-selftest-no-such-repo" \
         bash "$ARM" --axis b 2>&1)"; RC=$?
  case "$OUT" in
    *"UNCHECKED: \`gh pr list\` exited"*)
      if [ "$RC" -eq 2 ]; then
        echo "ok    a failing gh lands in UNCHECKED  (exit 2)"
      else
        FAILURES=$((FAILURES + 1)); echo "FAIL  a failing gh must exit 2, got ${RC}"
      fi ;;
    *)
      FAILURES=$((FAILURES + 1))
      echo "FAIL  a failing gh must be named as the reason for UNCHECKED"
      printf '      | %s\n' "$OUT" | head -10 ;;
  esac
fi

# ══ AXIS B, THE COUNT IDENTITY — a tally only over the whole id list ══════════
#
# WHY (task-d5485c04e0e63488). The axis B sweep reads the unique task id list on
# fd 0 and runs children in its body. A body child that reads stdin swallows the
# remaining ids: the loop ENDS EARLY with no error and no non-zero status, every
# tally is smaller, the divergent set is EMPTY, and the arm prints a GREEN AXIS B
# over 1 id of 4 in the same words it uses for 4 of 4. The failure direction is
# silence, which is the direction a parity check cannot afford.
#
# FOUR ARMS, and the middle two are the whole proof:
#   1  POSITIVE CONTROL — an unmutated copy over $FX still prints the full tally
#      with the SAME numbers as the in-tree run above. Without it the identity
#      could satisfy every arm below by refusing everything.
#   2  RED-WITHOUT — drain spliced in AND the identity block cut between its MUT
#      markers: the truncated sweep prints a green TALLY at exit 0.
#   3  GREEN-WITH — the same drain, identity intact: UNCHECKED naming BOTH
#      numbers, and NO TALLY on either stream.
#   4  the per-owner loop, whose own reconciliation is computed outside itself
#      and therefore cannot see its own truncation.
echo
echo "AXIS B — THE COUNT IDENTITY (a tally only over the whole id list)"

MUTROOT="$TMP/axisb-identity"
mkdir -p "$MUTROOT"
# The mutant copies live outside the repo, so their own `cd $(dirname $0)/..`
# lands in a plain directory with no scripts/pr-task-gate.sh. The extractor is
# handed to them by absolute path through the arm's own env hook — the SAME
# canonical extractor the in-tree runs use, never a second grammar.
export PDS_RECORD_PARITY_EXTRACTOR="$PWD/scripts/pr-task-gate.sh"
PDS_RECORD_PARITY_NOW=1800000000

mut_plant() { # mut_plant <name> — a pristine copy of the arm, returns its path
  mkdir -p "$MUTROOT/$1/scripts"
  cp "$ARM" "$MUTROOT/$1/scripts/pds-record-parity.sh"
  printf '%s\n' "$MUTROOT/$1/scripts/pds-record-parity.sh"
}

# `splice_drain <file> <marker>` — replace the arm's own no-op marker with a
# child that DRAINS fd 0. `cat >/dev/null` is the minimal honest stand-in for
# the realistic adversary (a `gh` with no `</dev/null`, a `psql`, an `ssh`).
splice_drain() {
  local f="$1" marker="$2" n
  n="$(grep -c "^ *: # MUT-BODY: ${marker}\$" "$f" | tr -d ' ')"
  if [ "$n" != "1" ]; then
    harness_fail "the ${marker} marker appears ${n} time(s) in the arm — the splice would mutate nothing or too much"
    return 1
  fi
  sed "s|^\\( *\\): # MUT-BODY: ${marker}\$|\\1cat >/dev/null # MUT-BODY: ${marker}|" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  if cmp -s "$f" "$ARM"; then
    harness_fail "splicing the drain at ${marker} changed nothing — the control arm would prove nothing"
    return 1
  fi
  return 0
}

# `cut_block <file> <name>` — delete everything between MUT-ANCHOR: <name> and
# MUT-END: <name>, inclusive. This is the REVERT half: it puts the arm back into
# the shape it had before this task, so arm 2 can show what that shape printed.
cut_block() {
  local f="$1" name="$2" n
  n="$(grep -c "MUT-ANCHOR: ${name}\$" "$f" | tr -d ' ')"
  if [ "$n" != "1" ]; then
    harness_fail "the ${name} MUT-ANCHOR appears ${n} time(s) — the revert would cut nothing or too much"
    return 1
  fi
  awk -v a="MUT-ANCHOR: ${name}" -v b="MUT-END: ${name}" '
    index($0, a) { skip = 1 } { if (!skip) print } index($0, b) { skip = 0 }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  return 0
}

# ── ARM 1: THE POSITIVE CONTROL ──────────────────────────────────────────────
# An unmutated copy, planted outside the repo, over the SAME $FX window as the
# in-tree axis B fixtures. Same red, same numbers. If this ever diverges from
# the in-tree run the mutants below are measuring the planting, not the splice.
MUT_OK="$(mut_plant intact)"
run_at "$MUT_OK" 1 "POSITIVE CONTROL — an intact planted copy still reds over the whole window" -- --axis b --fixture-dir "$FX"
says "task ids:   4 distinct across 6 PRs" "the intact copy enumerates all four ids"
says "AXIS B TALLY" "the intact copy PRINTS the tally"
says "terminal (done|cancelled):   2" "…with the same terminal count as the in-tree run"
says "LEAF slices (REDDING):          1" "…and the same redding headline"
says_not "UNCHECKED: axis B swept" "the identity does not fire on a complete sweep"

# ── ARM 2: RED-WITHOUT (the arm as it was before this task) ──────────────────
# Drain spliced AND the identity cut. The sweep dies after ONE id — `sort -u`
# puts `fixture-cancelled` first, which is terminal — so the arm prints a tally
# of 1 terminal, an EMPTY divergent set, and PARITY at exit 0. Four ids were
# enumerated; one was looked at; nothing in the output says so. This is the
# defect, executed.
MUT_RED="$(mut_plant red-without)"
if splice_drain "$MUT_RED" axis-b-loop-body && cut_block "$MUT_RED" axis-b-count-identity; then
  run_at "$MUT_RED" 0 "RED-WITHOUT — drained fd 0 + identity CUT greens a sweep of 1 id in 4" -- --axis b --fixture-dir "$FX"
  says "task ids:   4 distinct across 6 PRs" "the truncated run still ENUMERATED four ids"
  says "AXIS B TALLY" "…and still printed the tally"
  says "terminal (done|cancelled):   1" "…over ONE id (the in-tree run counts 2 terminal)"
  says "LEAF slices (REDDING):          0" "…with an EMPTY redding set, in a window that has one"
  says "pds-record-parity: PARITY" "…and a full-throated PARITY verdict over 1 of 4"
  says_not "UNCHECKED" "nothing in the pre-fix output says the sweep was short"
fi

# ── ARM 3: GREEN-WITH (the identity, doing the work) ─────────────────────────
# The SAME drain, identity intact. The only difference between arms 2 and 3 is
# the block this task added.
MUT_GREEN="$(mut_plant green-with)"
if splice_drain "$MUT_GREEN" axis-b-loop-body; then
  run_at "$MUT_GREEN" 2 "GREEN-WITH — the same drain is REFUSED, not greened" -- --axis b --fixture-dir "$FX"
  says "UNCHECKED: axis B swept 1 of 4 task id(s)" "the refusal names BOTH numbers"
  says "a loop-body child that reads" "the refusal names the mechanism, not just the mismatch"
  says_not "AXIS B TALLY" "the tally is WITHHELD — a partial sweep cannot print it"
  says_not "terminal (done|cancelled):" "no tally line survives the refusal"
  says_not "pds-record-parity: PARITY" "the refusal is not dressed up as a pass"
fi

# ── ARM 4: THE PER-OWNER LOOP ────────────────────────────────────────────────
# A window with TWO distinct owners, so a truncated grouping loop is visible as
# a missing block. The pre-existing reconciliation (`covering N of M`) is
# computed from the leaves FILE and the tally, both outside this loop, so it
# passes word for word on a truncated report; only the loop's own identity sees
# it. FXOWN gives two leaf reds under two different parents.
FXOWN="$TMP/fxown"
mkdir -p "$FXOWN"
# root-a carries TWO leaves and root-b one, so `sort -rn` on the owner counts is
# TOTALLY ordered: root-a is always first. A tie would make WHICH block survives
# the truncation an implementation detail of sort(1), and an assertion about it
# would be a coin flip wearing a proof's clothes.
prs "$FXOWN/prs.json" \
  "701|2026-01-01T00:00:00Z|fixture-leaf-a" \
  "702|2026-01-02T00:00:00Z|fixture-leaf-a2" \
  "703|2026-01-05T04:00:00Z|fixture-leaf-b"
ledger "$FXOWN" fixture-leaf-a  200 "$(task_doc fixture-leaf-a  open fixture-root-a)"
ledger "$FXOWN" fixture-leaf-a2 200 "$(task_doc fixture-leaf-a2 open fixture-root-a)"
ledger "$FXOWN" fixture-leaf-b  200 "$(task_doc fixture-leaf-b  open fixture-root-b)"
run_at "$MUT_OK" 1 "POSITIVE CONTROL — the intact copy prints BOTH owner blocks" -- --axis b --fixture-dir "$FXOWN"
says "OWNER fixture-root-a" "the first owner block is printed"
says "OWNER fixture-root-b" "the second owner block is printed"
says "owners:     2  covering 3 of 3 leaf red(s)" "the pre-existing reconciliation agrees"

MUT_OWN="$(mut_plant owner-drain)"
if splice_drain "$MUT_OWN" axis-b-owner-body; then
  run_at "$MUT_OWN" 2 "a drained per-owner loop is UNCHECKED, not a one-block report" -- --axis b --fixture-dir "$FXOWN"
  says "the per-owner report printed 1 of 2 owner block(s)" "the owner identity names both numbers"
  says "PREFIX of the report, not the report" "the refusal says what the blocks above actually are"
fi

# The same drain with the owner identity CUT: the truncated report passes the
# pre-existing `covering N of M` reconciliation word for word, which is the
# whole reason that check could not be the guard.
MUT_OWN_RED="$(mut_plant owner-red-without)"
if splice_drain "$MUT_OWN_RED" axis-b-owner-body && cut_block "$MUT_OWN_RED" axis-b-owner-identity; then
  run_at "$MUT_OWN_RED" 1 "RED-WITHOUT — a one-block report still passes the OLD reconciliation" -- --axis b --fixture-dir "$FXOWN"
  says "owners:     1  covering 3 of 3 leaf red(s)" "the old check sees 3 of 3 while ONE block was printed"
  says_not "OWNER fixture-root-b" "the second owner's block is missing and nothing says so"
fi

unset PDS_RECORD_PARITY_EXTRACTOR

# ══ THE TWO NEW MECHANISMS, REVERTED ONE AT A TIME ═══════════════════════════
#
# A fixture that passes against the SHIPPED arm proves the arm passes. It does
# not prove the arm's new code is what makes it pass — a fixture can be green
# because the mechanism works or because the mechanism is irrelevant to it, and
# those look identical from the outside. So each mechanism is REVERTED in a copy
# and re-run, and the harness asserts BOTH sides:
#   the reverted mechanism's fixture RED, and
#   the OTHER mechanism's fixture UNCHANGED.
# That second half is the one that matters: if reverting the heading lens also
# moved the uniqueness verdict, the two legs would be entangled and neither
# fixture would be evidence about the leg it names.
echo
echo "REVERT — each new mechanism is load-bearing, and independently so"

mutant() { # mutant <dir> <sed-expr…> — a copy of the arm with one leg reverted
  local dir="$1"; shift
  mkdir -p "$dir/scripts"
  sed "$@" "$ARM" > "$dir/scripts/pds-record-parity.sh"
}

# REVERT 1 — drop the heading arm of the union lens, i.e. go back to the
# bold-lead-only lens that shipped six false reds on the live charter.
# The heading arm carries an end-of-line `revert-marker` comment for exactly this
# purpose: a sed pattern that tried to match the regex ITSELF would need every
# bracket escaped twice and would silently match nothing the day the regex is
# reformatted — which is a fixture that greens by failing to mutate. The marker
# is asserted present BEFORE the mutant is trusted, so a deleted marker is a
# loud FIXTURE PRECONDITION failure, never a quiet pass.
NOHEAD="$TMP/mutant-nohead"
mutant "$NOHEAD" '/# revert-marker: heading-arm$/d'
if grep -q '# revert-marker: heading-arm' "$NOHEAD/scripts/pds-record-parity.sh"; then
  harness_fail "the NOHEAD mutant still contains the heading arm — the revert did not take, so its red would prove nothing"
else
  run_at "$NOHEAD/scripts/pds-record-parity.sh" 1 \
    "REVERTING the heading lens REDS the heading-only citation" -- --axis a --charter "$CH" --commits-file "$CM_HEAD"
  says "UNRESOLVED-CITATION PDS-D404" "the reverted lens manufactures exactly the phantom citation the repair removed"
fi

# …and reverting it leaves the uniqueness verdict EXACTLY where it was.
run_at "$NOHEAD/scripts/pds-record-parity.sh" 1 \
  "REVERTING the heading lens does NOT disturb the uniqueness leg" -- --axis a --charter "$CHD" --commits-file "$CM_DUP"
says "DUPLICATE-DEFINITION PDS-D110 :5 :13" "the uniqueness leg is unmoved by a resolution-lens revert"

# REVERT 2 — blind the uniqueness leg the way it was blind before this wave:
# the old code `sort -u`'d the definition set, so no count above one could ever
# be observed. `n[k] > 1` becomes a threshold nothing can reach.
NOUNIQ="$TMP/mutant-nouniq"
mutant "$NOUNIQ" 's/if (n\[k\] > 1)/if (n[k] > 99999)/'
if grep -q 'n\[k\] > 99999' "$NOUNIQ/scripts/pds-record-parity.sh"; then
  run_at "$NOUNIQ/scripts/pds-record-parity.sh" 0 \
    "REVERTING the uniqueness leg GREENS the duplicated charter (the old blindness)" -- --axis a --charter "$CHD" --commits-file "$CM_DUP"
  says "duplicated: 0 number(s) defined more than once" "the blinded leg reports zero over a charter that allocates PDS-D110 twice"
  says_not "DUPLICATE-DEFINITION" "the blinded leg names nothing — which is precisely what shipped before this wave"
else
  harness_fail "the NOUNIQ mutant did not take — its green would prove nothing"
fi

# …and blinding it leaves the resolution verdict EXACTLY where it was.
run_at "$NOUNIQ/scripts/pds-record-parity.sh" 0 \
  "REVERTING the uniqueness leg does NOT disturb the heading lens" -- --axis a --charter "$CH" --commits-file "$CM_HEAD"
says "unresolved: 0" "the heading-only citation still resolves with the uniqueness leg blinded"

# ── THE D-NUMBER ARBITER (one pointer, two allocators) ──────────────────────
#
# THE FIXTURE IS THE COLLISION, NOT A CALL. Two allocations with NO charter edit
# between them IS the concurrency this defect is made of: the REVIEW author and
# the DECIDE author both compute the next number from a charter neither has
# written to yet. Simulating it needs no second process and no clock — it needs
# the second caller to read the same unchanged charter the first one read, which
# is exactly what these two lines do.
#
# THE FIXTURE CHARTER'S HIGH-WATER IS 404 (`## PDS-D404 …`, the heading form),
# and it is ASSERTED rather than assumed: if a future edit to $CH adds a higher
# number, every expectation below shifts by one and would otherwise fail for a
# reason that has nothing to do with the arbiter.
echo
echo "AXIS A — the D-number arbiter (one pointer, two allocators)"

ALLOC_LED="$TMP/alloc-ledger.tsv"
rm -f "$ALLOC_LED"
CH_HIGH="$(grep -oE 'PDS-D[0-9]+' "$CH" | sed 's/PDS-D//' | sort -n | tail -1)"
CHECKS=$((CHECKS + 1))
if [ "$CH_HIGH" = "999" ]; then
  # 999 is the PROSE MENTION; the DEFINITION high-water is 404. Both facts are
  # asserted, because the arbiter's whole correctness rests on not confusing them.
  echo "ok    the fixture charter MENTIONS PDS-D999 in prose (the lens must not mint 1000)"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  FIXTURE PRECONDITION: expected PDS-D999 to be the highest MENTION in \$CH, got ${CH_HIGH}"
fi

run 0 "the REVIEW block mints the first number after the charter's DEFINED high-water" \
  -- --charter "$CH" --alloc-ledger "$ALLOC_LED" --allocate-d 1 --for "wN REVIEW"
says "PDS-D405" "it mints 405 — one past the HEADING-defined 404, NOT one past the prose-mentioned 999"
says_not "PDS-D1000" "the prose mention of PDS-D999 does not move the pointer"

# THE WHOLE ROW. The charter is UNCHANGED between these two runs; that is the
# point. Before the arbiter, the second caller read the same corpus and minted
# the same number — eighteen times, once per wave, for eighteen waves.
run 0 "the NEXT block allocates with the charter STILL unwritten" \
  -- --charter "$CH" --alloc-ledger "$ALLOC_LED" --allocate-d 2 --for "wN DECIDE"
says "PDS-D406" "the second allocator sees the RESERVATION and moves past it"
says "PDS-D407" "a multi-number allocation is contiguous"
says_not "PDS-D405" "it does NOT re-mint the number the REVIEW block already reserved"

# MUTUAL EXCLUSION. A held lock is a REFUSAL (exit 2), never a proceed — an
# arbiter that shrugs and allocates anyway is the pointer it replaced.
mkdir -p "$TMP/.d-alloc.lock"
run 2 "a HELD lock is UNCHECKED, never a silent proceed" \
  -- --charter "$CH" --alloc-ledger "$ALLOC_LED" --allocate-d 1 --for "wN INTRUDER"
says "the allocation lock" "the refusal names the lock"
rmdir "$TMP/.d-alloc.lock"

# --check-alloc: a number DEFINED above the seed that was never RESERVED is the
# bypass this arbiter exists to make visible after the fact.
CH_MINTED="$TMP/charter-minted.md"
cp "$CH" "$CH_MINTED"
printf '\n- **PDS-D406** minted through the arbiter.\n' >> "$CH_MINTED"
run 0 "--check-alloc greens when every number above the seed was reserved first" \
  -- --charter "$CH_MINTED" --alloc-ledger "$ALLOC_LED" --check-alloc
says "every charter number above the seed was reserved first" "the green says what it measured"

printf '\n- **PDS-D480** minted by reading the charter, not through the arbiter.\n' >> "$CH_MINTED"
run 1 "--check-alloc REDS on a number minted without a reservation" \
  -- --charter "$CH_MINTED" --alloc-ledger "$ALLOC_LED" --check-alloc
says "UNRESERVED-MINT      PDS-D480" "the bypass is named, by number"
says_not "UNRESERVED-MINT      PDS-D404" "a number at or below the SEED is not scored — it predates the arbiter"

run 2 "--check-alloc over a ledger with no SEED is UNCHECKED, never a green" \
  -- --charter "$CH" --alloc-ledger "$TMP/absent-ledger.tsv" --check-alloc

run 3 "--allocate-d 0 is a USAGE error" -- --charter "$CH" --alloc-ledger "$ALLOC_LED" --allocate-d 0
run 3 "--allocate-d with a non-number is a USAGE error" -- --charter "$CH" --alloc-ledger "$ALLOC_LED" --allocate-d two

# REVERT 3 — THE COLLISION MUST COME BACK. Delete the one line that folds the
# reservation high-water into the pointer and the arbiter IS the pre-arbiter
# pointer: `max(charter) + 1`, computed twice over one unchanged charter,
# answering 405 both times. A fix whose removal changes nothing was never the fix.
NORES="$TMP/mutant-nores"
mutant "$NORES" '/# revert-marker: arbiter-reserve-arm$/d'
if grep -q '# revert-marker: arbiter-reserve-arm' "$NORES/scripts/pds-record-parity.sh"; then
  harness_fail "the NORES mutant still consults the reservation ledger — the revert did not take, so its collision would prove nothing"
else
  MUT_LED="$TMP/alloc-ledger-mutant.tsv"
  rm -f "$MUT_LED"
  run_at "$NORES/scripts/pds-record-parity.sh" 0 \
    "REVERTED arbiter, first allocation" -- --charter "$CH" --alloc-ledger "$MUT_LED" --allocate-d 1 --for "wN REVIEW"
  says "PDS-D405" "the reverted pointer mints 405, same as the repaired one"
  run_at "$NORES/scripts/pds-record-parity.sh" 0 \
    "REVERTING the reservation arm MINTS THE SAME NUMBER TWICE (the collision returns)" \
    -- --charter "$CH" --alloc-ledger "$MUT_LED" --allocate-d 1 --for "wN DECIDE"
  says "PDS-D405" "the second allocator re-mints 405 — the exact defect that produced the eighteen pairs"
  says_not "PDS-D406" "the reverted pointer cannot see the reservation, so it cannot move past it"
fi

# ── THE SAME ARBITER OVER A SECOND CHARTER (--prefix) ───────────────────────
#
# The allocation arms were PDS-specific in exactly one token. The deploy
# charter had the same defect and paid for it on 2026-09-16 (two PRs, both
# correct readers, both minted D614), so that token is a parameter and there is
# still ONE implementation. These arms hold the parameter honest in BOTH
# directions: the non-default prefix must refuse an unreserved mint by NAME,
# and the default must stay byte-identical to what every existing caller sees.
echo
echo "AXIS A — one arbiter, a second charter (--prefix)"

PFX_CH="$TMP/deploy-charter.md"
PFX_LED="$TMP/deploy-ledger.tsv"
rm -f "$PFX_LED"
# Both numbering styles this charter family uses, PLUS the trap: a CROSS-CHARTER
# citation of a much higher number from the OTHER charter's namespace. The real
# deploy charter cites PDS-D716 six times while its own high-water is 615; a
# lens that counted citations as definitions would jump the pointer by a hundred.
{
  printf '## D613 — a decision, heading form.\n\nbody\n\n'
  printf -- '- **D614** a decision, bold-lead bullet form.\n\n'
  printf 'Prose that cites **PDS-D716** and PDS-D716 again, from the OTHER charter.\n'
} > "$PFX_CH"

PFX_HIGH="$(grep -oE 'D[0-9]+' "$PFX_CH" | sed 's/^D//' | sort -n | tail -1)"
CHECKS=$((CHECKS + 1))
if [ "$PFX_HIGH" = "716" ]; then
  echo "ok    the fixture charter CITES 716 from the other namespace (the lens must not mint 717)"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  FIXTURE PRECONDITION: expected 716 to be the highest bare-D token, got ${PFX_HIGH}"
fi

run 0 "--prefix D seeds and mints from the DEFINED high-water of the second charter" \
  -- --prefix D --charter "$PFX_CH" --alloc-ledger "$PFX_LED" --allocate-d 1 --for "deploy adoption"
says "D615" "it mints 615 — one past the DEFINED 614, across BOTH numbering styles"
says_not "D717" "the cross-charter PDS-D716 citation does not move the pointer"
says_not "PDS-D615" "the reservation carries the REQUESTED prefix, not the default one"

PFX_MINTED="$TMP/deploy-charter-minted.md"
cp "$PFX_CH" "$PFX_MINTED"
printf '\n## D615 — written into the charter after being reserved.\n' >> "$PFX_MINTED"
run 0 "--prefix D --check-alloc greens when the number above the seed was reserved first" \
  -- --prefix D --charter "$PFX_MINTED" --alloc-ledger "$PFX_LED" --check-alloc
says "every charter number above the seed was reserved first" "the green says what it measured"

printf -- '\n- **D620** minted by reading the charter, exactly as D614 was.\n' >> "$PFX_MINTED"
run 1 "--prefix D --check-alloc REDS on a number minted without a reservation" \
  -- --prefix D --charter "$PFX_MINTED" --alloc-ledger "$PFX_LED" --check-alloc
says "UNRESERVED-MINT      D620" "the bypass is named, by number, in the REQUESTED namespace"
says_not "UNRESERVED-MINT      D613" "a number at or below the SEED is not scored"

# THE DEFAULT MUST NOT MOVE. Every existing PDS caller, fixture and CI arm calls
# this script with no --prefix at all; if the parameter changed what they see,
# the reuse would have cost more than a second arbiter.
CHECKS=$((CHECKS + 1))
# Plain temp files, NOT process substitution: scripts/posix-vacuous-green-census.sh
# refuses an unguarded `<(…)` in this tree, and it is right to — under `sh` the
# construct is a syntax error and a harness that dies there can still exit 0.
bash "$ARM" --print-defs --charter "$CH" > "$TMP/defs-default.txt" 2>/dev/null
bash "$ARM" --print-defs --charter "$CH" --prefix PDS-D > "$TMP/defs-explicit.txt" 2>/dev/null
if [ -s "$TMP/defs-default.txt" ] && diff -q "$TMP/defs-default.txt" "$TMP/defs-explicit.txt" >/dev/null 2>&1; then
  echo "ok    the default prefix IS PDS-D — omitting --prefix and passing it explicitly agree ($(wc -l < "$TMP/defs-default.txt" | tr -d " ") defs)"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  the default prefix is not PDS-D (or the lens read nothing) — every existing caller's lens moved"
fi

run 3 "an empty --prefix is a USAGE error (it would match every bare integer)" \
  -- --prefix "" --charter "$CH" --alloc-ledger "$PFX_LED" --check-alloc
run 3 "a --prefix carrying a regex metacharacter is a USAGE error" \
  -- --prefix 'D.*' --charter "$CH" --alloc-ledger "$PFX_LED" --check-alloc

# ── the arm's own hygiene ───────────────────────────────────────────────────
echo
echo "HYGIENE"
CHECKS=$((CHECKS + 1))
# The needle is assembled at runtime so that this harness does not itself
# contain the string it is asserting the absence of — the criterion is a raw
# grep over both files, and a self-matching assertion would red forever.
NEEDLE='timeout'
N_TIMEOUT=$(grep -c "${NEEDLE} " "$ARM" "${BASH_SOURCE[0]}" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$N_TIMEOUT" -eq 0 ]; then
  echo "ok    neither file invokes ${NEEDLE}(1)"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  ${NEEDLE}(1) appears ${N_TIMEOUT}x — it does not exist on this host and reported EXIT=0 for a command that never ran"
fi

CHECKS=$((CHECKS + 1))
if [ "$(grep -c '# revert-marker: arbiter-reserve-arm$' "$ARM")" = "1" ]; then
  echo "ok    the arbiter's reservation arm carries exactly one revert-marker"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  the arbiter revert-marker is missing or duplicated — REVERT 3 would mutate nothing and pass"
fi

CHECKS=$((CHECKS + 1))
if grep -q 'bash "$EXTRACTOR" --extract-task-id' "$ARM"; then
  echo "ok    the task-id extractor is the canonical scripts/pr-task-gate.sh verb"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  the arm has grown a second copy of the trailer grammar"
fi

# THE PACE SLEEP MUST PRECEDE THE REQUEST IT PACES. It first shipped at the
# BOTTOM of the sweep loop, after every `continue` — so it fired only on rows
# that had already been fetched AND scored DIVERGENT, and paced nothing at all
# on a healthy ledger. Position is the whole behaviour here, and position is
# what this asserts: a wall-clock fixture over a canned transport that answers
# instantly could not tell the two placements apart.
CHECKS=$((CHECKS + 1))
PACE_LINE="$(grep -n 'sleep "\$PACE"' "$ARM" | head -1 | cut -d: -f1)"
FETCH_LINE="$(grep -n 'if ! ledger_fetch "\$tid"' "$ARM" | head -1 | cut -d: -f1)"
if [ -n "$PACE_LINE" ] && [ -n "$FETCH_LINE" ] && [ "$PACE_LINE" -lt "$FETCH_LINE" ]; then
  echo "ok    the PACE sleep sits BEFORE the ledger request it paces (${PACE_LINE} < ${FETCH_LINE})"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  the PACE sleep must precede ledger_fetch (pace=${PACE_LINE:-none} fetch=${FETCH_LINE:-none})"
  echo "      below the fetch it paces only rows already scored — i.e. nothing on a healthy ledger"
fi

# THE TRUNCATION GUARD MUST STAY FENCED INSIDE THE `git log` BRANCH. Every axis-B
# fixture in this harness runs through --fixture-dir inside THIS full checkout, and
# every axis-A fixture but the four above hands over a --commits-file — so a future
# edit that hoists `walk_truncation` to top level would UNCHECK `--axis b` on every
# shallow CI checkout and this harness would stay GREEN. Position is the behaviour,
# so position is what is asserted (the PACE-sleep idiom above, same reason).
# ══ THE ANTI-NARROWING PREDICATE ═════════════════════════════════════════════
#
# A PREDICATE OVER THE WHOLE FILE, NOT A LIST OF SITES. Widening eighteen
# regexes by hand is a snapshot; the next person adds a nineteenth. So the arm
# routes every D-number scan through a NAMED shape (D_NUM_RE / D_BASE_RE /
# D_NAIVE_NUM_RE) and this check asserts the only thing that keeps that true:
# a digit class must never appear beside the prefix again, in any quoting, in
# any tool. `scripts/pds-citation-expand.sh` carries the same arm (4b) for the
# same reason — this is that shape, not a new one.
CHECKS=$((CHECKS + 1))
NARROW="$(grep -nE '(PDS-D|\$\{D_PREFIX\})[^ ]{0,4}\[0-9\]' "$ARM" || true)"
if [ -z "$NARROW" ]; then
  echo "ok    no bare digit class survives beside the D prefix — every scan reads a named shape"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  a D-number scan was narrowed back to digits-only — this is the blind spot returning"
  echo "      a lettered ruling would be extracted as its numeric base, and a lettered typo could not red:"
  printf '%s\n' "$NARROW" | sed 's/^/        /'
fi

# …and the shapes themselves must still carry the suffix. The check above is
# satisfied by a constant redefined to '[0-9]+', which is the narrowing wearing
# the widening's clothes.
CHECKS=$((CHECKS + 1))
if grep -qE "^D_NUM_RE='\[0-9\]\+\[a-z\]\?'" "$ARM" && grep -qE "^D_BASE_RE='\[0-9\]\+'" "$ARM"; then
  echo "ok    D_NUM_RE still carries the optional letter suffix, and the allocation base still does not"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  the named shapes drifted — D_NUM_RE must be '[0-9]+[a-z]?' and D_BASE_RE '[0-9]+'"
  grep -nE "^D_(NUM|BASE|NAIVE_NUM)_RE=" "$ARM" | sed 's/^/        /'
fi

CHECKS=$((CHECKS + 1))
WT_CALLS="$(grep -cE '^[[:space:]]*walk_truncation$' "$ARM")"
WT_CALL="$(grep -nE '^[[:space:]]*walk_truncation$' "$ARM" | head -1 | cut -d: -f1)"
WT_WORKTREE="$(grep -n 'UNCHECKED: not inside a git work tree' "$ARM" | head -1 | cut -d: -f1)"
# Located by the PIPELINE, not by the citation regex: the regex is a named
# shape now (D_NUM_RE) and a locator spelled `PDS-D[0-9]+` would both go stale
# on a widening AND quietly re-pin the narrow shape it is not here to police.
WT_LOG="$(grep -nF 'git log --format=%B | grep -oE' "$ARM" | head -1 | cut -d: -f1)"
WT_AXISB="$(grep -n '^axis_b()' "$ARM" | head -1 | cut -d: -f1)"
if [ "$WT_CALLS" = "1" ] && [ -n "$WT_CALL" ] && [ -n "$WT_WORKTREE" ] && [ -n "$WT_LOG" ] &&
   [ -n "$WT_AXISB" ] && [ "$WT_WORKTREE" -lt "$WT_CALL" ] && [ "$WT_CALL" -lt "$WT_LOG" ] &&
   [ "$WT_LOG" -lt "$WT_AXISB" ]; then
  echo "ok    walk_truncation is called ONCE, inside axis A's git-log branch (${WT_WORKTREE} < ${WT_CALL} < ${WT_LOG} < ${WT_AXISB})"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  walk_truncation must be called exactly once, between the work-tree check and the git log walk"
  echo "      (calls=${WT_CALLS} call=${WT_CALL:-none} worktree=${WT_WORKTREE:-none} log=${WT_LOG:-none} axis_b=${WT_AXISB:-none})"
  echo "      hoisted out of that branch it UNCHECKS --axis b and --commits-file on every shallow checkout"
fi

# ── AXIS F — THE WINDOW BOUNDARY IS NOT READ OUT OF THE LEDGER IT GUARDS ──────
#
# THE DEFECT THESE FIXTURES EXIST TO REFUSE, STATED AS THE RUN THAT PASSED. The
# first cut derived the window anchor from the charter: the OLDEST harness-moving
# commit whose blob the charter recorded. So deleting that row did not make its
# commit unrecorded — it promoted the next row to anchor, made the deleted commit
# pre-doctrine and EXEMPT, shrank the window 20 -> 19 to match, and printed
# PARITY rc 0. Deleting the four oldest in one pass took it 20 -> 16, rc 0 every
# time. A guard whose expected value is read from the thing it guards cannot see
# that thing being erased from the bottom.
#
# THE MID-ROW CONTROL ALREADY PASSED THROUGHOUT, WHICH IS WHY THIS NEEDED ITS OWN
# FIXTURE. An arm that reds on a mid-row deletion and greens on an anchor-row
# deletion looks exactly like a working arm from the mid-row fixture alone. Both
# deletions are pinned below, and so is the count that must NOT move: under the
# pinned floor the window stays 21 on EVERY deletion. A deletion that shrank the
# window while still reporting some other row would be a different arm passing
# for the wrong reason.

CH_F=".claude/workflows/bp-pds-charter.md"
FLOOR_F="1f15017bf3d51ac85c34d3e4f5aa2f903a0815a6"

# THE STATIC HALF, which holds on any checkout including a shallow one: the floor
# must be a LITERAL in the arm, and the window loop must key off the derived
# boundary, never off the charter-read anchor. Position and provenance ARE the
# behaviour here (the PACE-sleep and walk_truncation idioms above, same reason):
# a future edit that pointed the loop back at $anchor would restore the defect
# with every dynamic fixture below still green on a full checkout.
CHECKS=$((CHECKS + 1))
if grep -q "^AXIS_F_FLOOR_COMMIT_DEFAULT=\"${FLOOR_F}\"" "$ARM"; then
  echo "ok    the axis-F window floor is a 40-hex literal in the arm, not a value read from the charter"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  AXIS_F_FLOOR_COMMIT_DEFAULT is missing or is no longer ${FLOOR_F}"
  echo "      a boundary the charter can supply is a boundary a charter edit can move forward"
fi

CHECKS=$((CHECKS + 1))
if [ "$(grep -c 'is-ancestor "\$sha" "\$boundary"' "$ARM")" = "1" ] &&
   ! grep -q 'is-ancestor "\$sha" "\$anchor"' "$ARM"; then
  echo "ok    axis F's window loop exempts against \$boundary, never against the charter-read \$anchor"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  axis F's exemption test must run against \$boundary — \$anchor is read out of the guarded charter"
fi

CHECKS=$((CHECKS + 1))
if grep -q 'the charter records no harness blob at all; every in-window thaw below is unrecorded' "$ARM"; then
  echo "ok    a charter recording NO harness blob now SCORES (every row unrecorded) instead of going UNCHECKED"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  an empty ledger must be scoreable now that the boundary no longer needs the charter to supply it"
fi

# A BOGUS FLOOR IS UNCHECKED, NOT A FALLBACK. This is the no-fallback rule as a
# run: if the arm ever answered this by reverting to the charter-derived anchor
# it would print PARITY here, which is precisely the silent hole. Holds on any
# checkout, shallow included.
CHECKS=$((CHECKS + 1))
LAST_OUT="$(AXIS_F_FLOOR_COMMIT=0000000000000000000000000000000000000000 bash "$ARM" --axis f --charter "$CH_F" 2>&1)"
AF_RC=$?
if [ "$AF_RC" = "2" ]; then
  echo "ok    an unreachable pinned floor is UNCHECKED (exit 2), never a fallback to the charter  (exit 2)"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  an unreachable pinned floor must exit 2; got ${AF_RC}"
  printf '      | %s\n' "$LAST_OUT" | head -20
fi
says "will NOT fall back to deriving the boundary from the" "the refusal NAMES the fallback it is declining to make"
says_not "PARITY" "an unreachable floor must never print PARITY"

run 2 "axis F with a missing charter is UNCHECKED" -- --axis f --charter "$TMP/no-such-charter.md"
says "UNCHECKED: no charter at" "the UNCHECKED names the missing charter"

# THE DYNAMIC HALF needs the real history: the floor commit and the 25 harness-
# moving commits. On a shallow checkout there is nothing here to measure, and a
# harness that silently skipped would be the vacuous green this file exists to
# refuse — so the skip is PRINTED and the reason is named.
# OPT-IN, AND THE REASON IS A REQUIRED-GATE ONE. Everything else in this file is
# hermetic: it runs in a mktemp -d that is not a git repo, reads no live ledger
# row and no real charter. This block is the exception — it reads THIS CHECKOUT'S
# charter and THIS CHECKOUT'S git history, so its verdict changes whenever main
# moves. api/test/barkpark/pds_record_parity_test.exs shells this file from the
# REQUIRED Elixir gate, and its moduledoc states the invariant this block breaks:
# "record-parity's harness is HERMETIC … so it gates the ARM's own logic against
# regression, NOT the epic's record", and warns that a live finding redding a
# required gate "would be repaired by deleting the baseline inside a day".
# That is not hypothetical. On 2026-09-20 commit 406978270 moved
# scripts/pds-pull-proof.sh with no PDS-D recording its blob — a CORRECT axis-F
# finding — and it redded the required Elixir gate on every open PR in two lanes
# at once, for authors who had touched none of this.
# So the dynamic half is now opt-in. The pds-harnesses leg sets
# PDS_PARITY_DYNAMIC=1; that leg is the REPORTER this file's own header says such
# reds belong to ("REPORTER, never a gate … must never carry a required check
# name"). Unset, the block SKIPS AND SAYS SO — never silently.
if [ "${PDS_PARITY_DYNAMIC:-0}" = "1" ] \
   && git rev-parse --verify --quiet "${FLOOR_F}^{commit}" >/dev/null 2>&1 && [ -f "$CH_F" ]; then

  run 0 "axis F is GREEN on this checkout's real charter" -- --axis f
  says "window boundary ....... 1f15017bf" "the live boundary is the pinned floor, not the oldest ledger row"

  # DERIVED, NOT PINNED. These counts were literals — 21 in-window and 0
  # unrecorded — and a literal here is a second, hand-maintained copy of a number
  # the subject computes from git. Every legitimate thaw of scripts/pds-pull-proof.sh
  # moves the in-window count by one and reds five arms that have nothing to do
  # with the change. That is what happened on 2026-09-20 (21 -> 22 via 406978270).
  # The PROPERTY these arms assert is not "the number is 21"; it is "the boundary
  # does NOT move when ledger rows are deleted" and "a deletion is counted once
  # per row". Both are relative, so derive the baseline and assert the DELTA.
  AF_WINDOW=""; AF_UNREC=""
  if [[ "$LAST_OUT" =~ IN\ WINDOW\ \.+\ ([0-9]+) ]]; then AF_WINDOW="${BASH_REMATCH[1]}"; fi
  if [[ "$LAST_OUT" =~ unrecorded\ \.+\ ([0-9]+) ]]; then AF_UNREC="${BASH_REMATCH[1]}"; fi
  CHECKS=$((CHECKS + 1))
  if [ -n "$AF_WINDOW" ] && [ -n "$AF_UNREC" ]; then
    echo "ok    baseline DERIVED from the subject: IN WINDOW ${AF_WINDOW}, unrecorded ${AF_UNREC}"
  else
    FAILURES=$((FAILURES + 1))
    echo "FAIL  could not derive the axis-F baseline from the subject's own output"
    echo "      An empty baseline would make every delta arm below compare against"
    echo "      nothing and pass vacuously — refusing instead."
    AF_WINDOW="__UNDERIVED__"; AF_UNREC="__UNDERIVED__"
  fi
  says "IN WINDOW ....... ${AF_WINDOW}" "the pinned floor puts the former anchor 58d1bd3a5 INSIDE the window"

  # THE REGRESSION ARM. Delete the row that used to BE the anchor. Under the old
  # derivation this printed `IN WINDOW 19 · unrecorded 0 · PARITY` rc 0.
  sed '/e219e97ccf7f33797c86a2b84d998d599b6bda31/d' "$CH_F" > "$TMP/f-anchor.md"
  run 1 "deleting the OLDEST ledger row REDS axis F (it used to print PARITY)" -- --axis f --charter "$TMP/f-anchor.md"
  says "58d1bd3a5" "the red NAMES the commit whose record was deleted"
  says "IN WINDOW ....... ${AF_WINDOW}" "the window did NOT shrink to absorb the deletion — that shrink WAS the defect"
  says "unrecorded .......................... $((AF_UNREC + 1))" "exactly one row went missing and exactly one MORE is reported"

  # ITERATED. One row could be a special case; four rows in one pass is the shape
  # of a charter split that drops the oldest block as historical noise.
  sed -e '/e219e97ccf7f33797c86a2b84d998d599b6bda31/d' \
      -e '/255c458ba2797321fcd2f2ac327bf87430a59d0e/d' \
      -e '/7a703fd641f77b906dcbd40f004f7639cdc9b2ae/d' \
      -e '/f99216471f9cd914064b9e6fc4bc3b6ee59a6da2/d' "$CH_F" > "$TMP/f-oldest4.md"
  run 1 "deleting the FOUR oldest ledger rows in one pass REDS axis F" -- --axis f --charter "$TMP/f-oldest4.md"
  says "unrecorded .......................... $((AF_UNREC + 4))" "all four deletions are counted, not just the newest of them"
  says "IN WINDOW ....... ${AF_WINDOW}" "four deletions did not move the boundary either"
  says "58d1bd3a5" "the oldest of the four is named"
  says "13c379bcd" "the newest of the four is named"

  # THE PRE-EXISTING CONTROL, RE-PINNED. The mid-row red must survive the change.
  sed '/97d9cbb86afe6910d7a49bd712ca3348084f4fb0/d' "$CH_F" > "$TMP/f-mid.md"
  run 1 "the mid-ledger control still REDS axis F" -- --axis f --charter "$TMP/f-mid.md"
  says "4d5a84001" "the mid-row red still names its commit"

  # THE QUIET SIDE OF THE SAME MUTATION SET. Without this, every red above is
  # compatible with an arm that reds on any --charter that is not the default.
  cp "$CH_F" "$TMP/f-verbatim.md"
  run 0 "a verbatim COPY of the charter is still PARITY — the reds are about content, not about --charter" -- --axis f --charter "$TMP/f-verbatim.md"
  says_not "DIVERGENT" "the copy does not red"
else
  CHECKS=$((CHECKS + 1))
  if [ "${PDS_PARITY_DYNAMIC:-0}" != "1" ]; then
    echo "ok    axis F's history fixtures SKIPPED — PDS_PARITY_DYNAMIC is not 1"
    echo "      This is the HERMETIC run. The dynamic half reads this checkout's real"
    echo "      charter and git history, so its verdict moves with main and cannot sit"
    echo "      under a required gate. The pds-harnesses leg sets PDS_PARITY_DYNAMIC=1"
    echo "      and is where an axis-F red belongs. Run it by hand the same way:"
    echo "          PDS_PARITY_DYNAMIC=1 bash scripts/pds-record-parity.test.sh"
    echo "      Everything above this line ran, and it is the arm's own logic."
  else
    echo "ok    axis F's history fixtures SKIPPED — ${FLOOR_F} is not in this checkout (shallow clone)"
    echo "      the static and no-fallback checks above still ran; only the 25-commit walk is unmeasurable here"
  fi
fi

run 3 "an unknown argument is a USAGE error (exit 3)" -- --nonsense
run 3 "a --grace-hours that is not a number is a USAGE error" -- --grace-hours six

echo
echo "─────────────────────────────────────────────────────────────────────────"
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS  ${CHECKS} checks, 0 failures"
  exit 0
fi
echo "FAIL  ${CHECKS} checks, ${FAILURES} failures"
exit 1

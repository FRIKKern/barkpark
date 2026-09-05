#!/usr/bin/env bash
#
# pds-draft-only-task-census.sh — name every DRAFT-ONLY `type:task` row the
# publish wall's 422 `duplicate_of` guard left stranded, and hand each one a
# disposition CANDIDATE: "ruled a duplicate of <published id>" or
# "differentiated — publish candidate".
#
# READ ONLY. This file contains no write verb, no publish, no discard, no
# patch, no mutate. It walks the ledger once and prints. The disposition itself
# is a LEAD's write, made per row off this list, and only after main rules
# criterion 4 of dr-w23-bl-discard-draft-deletes-draft-only-docs (what a refused
# publish should leave behind at all). A census that quietly started publishing
# would be answering a question nobody has ruled on. The selftest greps this
# file's own source for write verbs, so the day someone adds a publish loop
# "just for the differentiated ones", the selftest reds before the run does
# anything.
#
# WHY THIS EXISTS
# ---------------
# `bp doc publish` refuses a near-duplicate with 422 `duplicate_of`. The refusal
# leaves the DRAFT in place, and every canonical reader — `bp task ready`, the
# board, the epic roster — is published-first. So the wall manufactures rows
# that exist, hold real descriptions and real acceptance criteria, and are
# invisible to everything that looks for work. Worse, `bp doc discard-draft` on
# one of them is not a revert but an outright DELETE (that is criteria 1 and 2
# of this row, closed in internal/cli/discard_draft_guard.go). This script is
# criterion 3: the population, by id and by age, each row with a candidate call.
#
# WHAT A DRAFT-ONLY ROW IS, EXACTLY
#   A `drafts.<id>` document in the raw perspective whose bare `<id>` has NO
#   published document in the same walk. It is not "a draft" — 604 of today's
#   rows are drafts and most of them are TWINS over a published row (those are
#   scripts/pds-draft-twin-sweep.sh's population, not this one). A twin has a
#   published side to fall back to. A draft-only row IS the only copy.
#
# THE CANDIDATE CALL, AND WHY IT IS ONLY A CANDIDATE
#   The 422 refusal names a `duplicate_of` target, but that target is not stored
#   on the draft — the refusal is an API response, not a field. So the twin is
#   RE-DERIVED here from the corpus, in two passes, and the two are kept in
#   separate columns because they are not the same claim:
#     DUPLICATE-CANDIDATE  a PUBLISHED row carries the BYTE-IDENTICAL title.
#                          Strong: this is what the wall's near-duplicate guard
#                          keys on first, and a human reading the two rows side
#                          by side would see one title twice.
#     NEAR-TITLE-CANDIDATE no exact match, but a published row's title matches
#                          after lowercasing and collapsing whitespace. Weaker,
#                          and printed as its own verdict rather than folded in,
#                          because "differs only in case" is a judgement the
#                          lead makes, not one this script gets to make silently.
#     DIFFERENTIATED       no published row shares the title in either form.
#                          Nothing in the corpus says this row is a duplicate of
#                          anything, so the candidate is: PUBLISH it.
#   Every verdict here is a CANDIDATE for a lead's per-row ruling. The word
#   "candidate" is in the call string itself so it cannot be quoted out of this
#   file as a decision.
#
# THE INDEX IS BUILT FROM PUBLISHED ROWS ONLY, and that is load-bearing. If the
# title index were built over the whole walk, two draft-only rows that share a
# title would name EACH OTHER as the published twin they are duplicates of, and
# the table would read as two confident DUPLICATE-CANDIDATEs pointing at rows
# that do not exist on any board. The selftest pins this directly
# (`shared-title-a` / `shared-title-b`).
#
# FAIL CLOSED. `--all` is an offset walk over a LIVE collection; under campaign
# traffic it refuses with `pagination_shifted` and returns an ERROR OBJECT, not
# a short list. A zero-length `.documents` is therefore a FAILED WALK, and every
# count below it would be a lie — "0 draft-only rows" is exactly the answer
# criterion 3 warns about accepting without its query. So the shape is asserted
# before anything is classified, and a bad walk exits 1 having printed CANNOT
# READ and no table and no SUMMARY at all.
#
# USAGE
#   scripts/pds-draft-only-task-census.sh                  # live walk, census
#   scripts/pds-draft-only-task-census.sh --raw raw.json   # reuse a walk
#   scripts/pds-draft-only-task-census.sh --now 2026-09-04T22:00:00Z
#   scripts/pds-draft-only-task-census.sh --selftest       # offline fixtures
#
# EXIT STATUS
#   0  the census ran and printed a table plus a SUMMARY line
#   1  CANNOT READ — the walk was empty, malformed, or returned zero documents.
#      No table, no counts, no verdict. This is an absence of measurement, and
#      it is NEVER printed as "zero draft-only rows".
#   2  usage error
#   3  selftest RED — at least one arm failed
set -uo pipefail

DOC_TYPE="task"
BP="${PDS_DRAFT_ONLY_BP:-bp}"

# THE EXACT QUERY, held in ONE place and PRINTED in the summary. The criterion
# demands the query beside the count; a query retyped into a PR body by hand is
# a query nobody can re-run. This variable is what the walk actually executes
# and what the SUMMARY line quotes — they cannot drift apart.
THE_QUERY="env -u BARKPARK_TOKEN bp doc ls $DOC_TYPE --perspective raw --all --fields lifecycle_status,claim,close_reason,acceptance_criteria,title,description,brief,tags -o json"

usage() { sed -n '/^# USAGE/,/^# EXIT STATUS/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'pds-draft-only-task-census: %s\n' "$1" >&2; exit "${2:-2}"; }

pull_raw() {
  local out="$1"
  env -u BARKPARK_TOKEN "$BP" doc ls "$DOC_TYPE" --perspective raw --all \
    --fields lifecycle_status,claim,close_reason,acceptance_criteria,title,description,brief,tags \
    -o json 2>/dev/null | grep -v '^bp: ' > "$out"
}

# CANNOT READ vs a verdict. Every arm here prints the words CANNOT READ and
# exits 1; none of them can fall through into a count.
assert_raw() {
  local raw="$1" n
  [ -s "$raw" ] || die "CANNOT READ — the walk produced an EMPTY file; measured nothing" 1
  n="$(jq -r 'if (.documents|type) == "array" then (.documents|length) else "ERR:" + ((.error.message // .message // "unrecognised envelope")|tostring) end' "$raw" 2>/dev/null)"
  case "$n" in
    ERR:*) die "CANNOT READ — the walk did not return a document list: ${n#ERR:}" 1 ;;
    ''|*[!0-9]*) die "CANNOT READ — could not read a document count out of $raw" 1 ;;
  esac
  [ "$n" -gt 0 ] || die "CANNOT READ — the walk returned ZERO documents; that is a failed walk, not an empty ledger" 1
  printf '%s' "$n"
}

# ── classification ───────────────────────────────────────────────────────────
classify() {
  local raw="$1" now="$2"
  jq -r --arg now "$now" '
    def bare: sub("^drafts\\.";"");
    def norm: ((. // "") | tostring | ascii_downcase | gsub("[[:space:]]+"; " ")
               | sub("^ +";"") | sub(" +$";""));
    def epoch: ((. // "") | tostring | sub("\\.[0-9]+";"")
                | (try fromdateiso8601 catch null));
    def metcount: ((.acceptance_criteria // []) | map(select(.met == true)) | length);
    def totcount: ((.acceptance_criteria // []) | length);

    ($now | epoch) as $NOW
    | (.documents | map(select(._id | startswith("drafts.") | not))) as $pubs
    | ($pubs | map(._id)) as $pubids
    # BOTH indexes are built over $pubs and nothing else. See the header.
    | ($pubs | group_by((.title // "") | tostring)
             | map({key: ((.[0].title // "") | tostring), value: (map(._id) | sort)})
             | from_entries) as $by_title
    | ($pubs | group_by(.title | norm)
             | map({key: ((.[0].title | norm) | tostring), value: (map(._id) | sort)})
             | from_entries) as $by_norm
    | [ .documents[]
        | select(._id | startswith("drafts."))
        | select((._id | bare) as $x | ($pubids | index($x)) == null) ]
    | map(
        . as $d
        | ($d._id | bare) as $id
        | (($d.title // "") | tostring) as $title
        | (($by_title[$title] // []) | map(select(. != $id))) as $exact
        | (($by_norm[($title | norm)] // []) | map(select(. != $id))) as $near
        | ($d._createdAt | epoch) as $created
        | (if ($NOW != null and $created != null)
             then (($NOW - $created) / 86400 | floor) else -1 end) as $age
        | (if   ($title | length) == 0 then "NO-TITLE"
           elif ($exact | length) > 0  then "EXACT"
           elif ($near  | length) > 0  then "NEAR"
           else "DIFFERENTIATED" end) as $code
        | {
            id: $id,
            created: ($d._createdAt // "-"),
            age_days: $age,
            updated: ($d._updatedAt // "-"),
            status: ($d.lifecycle_status // "NULL"),
            met: "\($d | metcount)/\($d | totcount)",
            # ONE decision, read out three times: verdict, twin and call ALL
            # derive from $code, so a clause deleted from one cannot survive in
            # the others and quietly keep the table looking right.
            verdict: (
              if   $code == "EXACT"    then "DUPLICATE-CANDIDATE"
              elif $code == "NEAR"     then "NEAR-TITLE-CANDIDATE"
              elif $code == "NO-TITLE" then "NO-TITLE"
              else "DIFFERENTIATED" end),
            twin: (
              if   $code == "EXACT" then ($exact | join(","))
              elif $code == "NEAR"  then ($near  | join(","))
              else "-" end),
            call: (
              if   $code == "EXACT" then "RULED DUPLICATE OF \($exact | join(",")) (candidate)"
              elif $code == "NEAR"  then "near-title only, differs in case/space from \($near | join(",")) — lead rules (candidate)"
              elif $code == "NO-TITLE" then "the draft carries NO title — nothing to match on; read the row by hand"
              else "DIFFERENTIATED — publish candidate" end),
            title: ($title | gsub("[[:space:]]+"; " "))
          })
    | sort_by(.created)
    | .[]
    | [.id, .created, (.age_days | tostring), .updated, .status, .met,
       .verdict, .twin, .call, .title]
    | @tsv
  ' "$raw"
}

print_table() {
  printf 'id\tcreated\tage_days\tupdated\tstatus\tmet\tverdict\ttwin\tcall\ttitle\n'
  cat "$1"
}

summary_line() {
  local table="$1" docs="$2" pubs="$3" drafts="$4" now="$5"
  local n dup near diff notitle oldest
  n=$(grep -c '' "$table")
  dup=$(awk -F'\t' '$7=="DUPLICATE-CANDIDATE"' "$table" | grep -c '')
  near=$(awk -F'\t' '$7=="NEAR-TITLE-CANDIDATE"' "$table" | grep -c '')
  diff=$(awk -F'\t' '$7=="DIFFERENTIATED"' "$table" | grep -c '')
  notitle=$(awk -F'\t' '$7=="NO-TITLE"' "$table" | grep -c '')
  # The table is sorted by created ASC, so the oldest row is the first one.
  oldest=$(awk -F'\t' 'NR==1{printf "%s (%s, %s days)", $1, $2, $3}' "$table")
  [ -n "$oldest" ] || oldest="-"
  printf 'SUMMARY docs=%s published=%s drafts=%s DRAFT-ONLY=%s DUPLICATE-CANDIDATE=%s NEAR-TITLE-CANDIDATE=%s DIFFERENTIATED=%s NO-TITLE=%s oldest=%s now=%s\n' \
    "$docs" "$pubs" "$drafts" "$n" "$dup" "$near" "$diff" "$notitle" "$oldest" "$now"
  printf 'QUERY %s\n' "$THE_QUERY"
  printf 'A DRAFT-ONLY ROW is a drafts.<id> in that walk whose bare <id> has NO published document in the SAME walk.\n'
  printf 'EVERY VERDICT ABOVE IS A CANDIDATE. Nothing here was written; the per-row disposition is a lead call after main rules criterion 4.\n'
}

count_side() {
  jq -r --arg side "$1" '
    if $side == "pub" then [.documents[] | select(._id | startswith("drafts.") | not)] | length
    else [.documents[] | select(._id | startswith("drafts."))] | length end' "$2"
}

run_census() {
  local raw="$1" table="$2" now="$3" docs pubs drafts
  docs="$(assert_raw "$raw")" || exit 1
  pubs="$(count_side pub "$raw")"
  drafts="$(count_side drafts "$raw")"
  classify "$raw" "$now" > "$table"
  print_table "$table"
  printf '\n'
  summary_line "$table" "$docs" "$pubs" "$drafts" "$now"
}

# ── selftest (offline; no ledger, no network) ────────────────────────────────
# Synthetic fixture through the REAL classify/assert_raw/summary_line above.
# Each rule is shown REFUSING as well as passing — a rule only ever observed
# passing has not been tested.
selftest() {
  local tmp fails=0 out rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ok()  { printf '  ok   %s\n' "$1"; }
  bad() { printf '  FAIL %s\n         %s\n' "$1" "$2"; fails=$((fails + 1)); }

  cat > "$tmp/fixture.json" <<'JSON'
{"documents":[
 {"_id":"pub-alpha","_rev":"p1","_createdAt":"2026-07-01T00:00:00.000000Z","_updatedAt":"2026-08-01T00:00:00Z",
  "lifecycle_status":"open","title":"the wall refuses a near duplicate","acceptance_criteria":[{"met":true}]},
 {"_id":"drafts.dup-of-alpha","_rev":"d1","_createdAt":"2026-07-05T00:00:00.000000Z","_updatedAt":"2026-07-05T00:00:00Z",
  "lifecycle_status":"open","title":"the wall refuses a near duplicate","acceptance_criteria":[{"met":false},{"met":false}]},

 {"_id":"pub-beta","_rev":"p2","_createdAt":"2026-07-01T00:00:00.000000Z","_updatedAt":"2026-08-01T00:00:00Z",
  "lifecycle_status":"done","title":"A  Title   With Odd Spacing","acceptance_criteria":[]},
 {"_id":"drafts.near-of-beta","_rev":"d2","_createdAt":"2026-08-01T00:00:00.000000Z","_updatedAt":"2026-08-01T00:00:00Z",
  "lifecycle_status":"open","title":"a title with odd spacing","acceptance_criteria":[]},

 {"_id":"drafts.lonely-differentiated","_rev":"d3","_createdAt":"2026-08-20T12:00:00.000000Z","_updatedAt":"2026-08-20T12:00:00Z",
  "lifecycle_status":"open","title":"nothing in the corpus looks like this","acceptance_criteria":[{"met":false}]},

 {"_id":"drafts.shared-title-a","_rev":"d4","_createdAt":"2026-08-21T00:00:00.000000Z","_updatedAt":"2026-08-21T00:00:00Z",
  "lifecycle_status":"open","title":"two drafts one title","acceptance_criteria":[]},
 {"_id":"drafts.shared-title-b","_rev":"d5","_createdAt":"2026-08-22T00:00:00.000000Z","_updatedAt":"2026-08-22T00:00:00Z",
  "lifecycle_status":"open","title":"two drafts one title","acceptance_criteria":[]},

 {"_id":"drafts.no-title-row","_rev":"d6","_createdAt":"2026-08-23T00:00:00.000000Z","_updatedAt":"2026-08-23T00:00:00Z",
  "lifecycle_status":"open","acceptance_criteria":[]},

 {"_id":"ordinary-twin","_rev":"p3","_createdAt":"2026-07-02T00:00:00.000000Z","_updatedAt":"2026-08-01T00:00:00Z",
  "lifecycle_status":"done","title":"a twin over a published row","acceptance_criteria":[{"met":true}]},
 {"_id":"drafts.ordinary-twin","_rev":"d7","_createdAt":"2026-07-02T00:00:00.000000Z","_updatedAt":"2026-08-02T00:00:00Z",
  "lifecycle_status":"open","title":"a twin over a published row","acceptance_criteria":[{"met":true}]},

 {"_id":"pub-lonely","_rev":"p4","_createdAt":"2026-07-03T00:00:00.000000Z","_updatedAt":"2026-08-01T00:00:00Z",
  "lifecycle_status":"open","title":"a published row with no draft at all","acceptance_criteria":[]}
]}
JSON

  local NOW="2026-09-04T00:00:00Z"
  classify "$tmp/fixture.json" "$NOW" > "$tmp/table.tsv"

  field_of() { awk -F'\t' -v id="$1" -v c="$2" '$1==id{print $c}' "$tmp/table.tsv"; }
  expect_field() {
    local id="$1" col="$2" want="$3" label="$4" got; got="$(field_of "$id" "$col")"
    if [ "$got" = "$want" ]; then ok "$label"
    else bad "$label" "expected '$want', got '${got:-<absent from the table>}'"; fi
  }

  printf 'THE POPULATION — what a draft-only row IS\n'
  # NON-VACUITY: pin the shape directly. Six draft-only rows, and the two
  # documents that are NOT draft-only must be absent BY NAME, not merely
  # uncounted — an empty table would satisfy "uncounted" and nothing else here.
  if [ "$(grep -c '' "$tmp/table.tsv")" = "6" ]; then ok "exactly 6 draft-only rows in the fixture"
  else bad "population" "expected 6 rows, got $(grep -c '' "$tmp/table.tsv")"; fi
  if [ -z "$(field_of ordinary-twin 1)" ]; then ok "a draft WITH a published twin is out of scope (it has a fallback; that is the twin sweep's population)"
  else bad "twin-leak" "an ordinary twin entered the draft-only table — discarding one of those is a revert, not a delete"; fi
  if [ -z "$(field_of pub-lonely 1)" ]; then ok "a published row with no draft is out of scope"
  else bad "pub-leak" "a published-only row entered the table"; fi

  printf 'THE CANDIDATE CALL\n'
  expect_field dup-of-alpha 7 "DUPLICATE-CANDIDATE"  "a byte-identical published title -> DUPLICATE-CANDIDATE"
  expect_field dup-of-alpha 8 "pub-alpha"            "and it NAMES the published id it is a candidate duplicate of"
  expect_field near-of-beta 7 "NEAR-TITLE-CANDIDATE" "case/whitespace-only match is NEAR, kept separate from EXACT"
  expect_field near-of-beta 8 "pub-beta"             "and it names the near twin"
  expect_field lonely-differentiated 7 "DIFFERENTIATED" "no published title in either form -> DIFFERENTIATED"
  expect_field lonely-differentiated 8 "-"           "a differentiated row names NO twin"
  expect_field no-title-row 7 "NO-TITLE"             "a draft with no title cannot be title-matched and says so"
  # The CALL column is what a lead reads. Pin its wording, not just the verdict:
  # verdict and call derive from the same $code, so an arm on the verdict alone
  # cannot tell that the sentence beside it still says the right thing.
  case "$(field_of dup-of-alpha 9)" in
    "RULED DUPLICATE OF pub-alpha (candidate)") ok "the call sentence names the twin and says (candidate)" ;;
    *) bad "call-exact" "got: $(field_of dup-of-alpha 9)" ;;
  esac
  case "$(field_of lonely-differentiated 9)" in
    "DIFFERENTIATED — publish candidate") ok "a differentiated row's call is 'publish candidate'" ;;
    *) bad "call-diff" "got: $(field_of lonely-differentiated 9)" ;;
  esac

  printf 'THE INDEX IS BUILT FROM PUBLISHED ROWS ONLY\n'
  # THE ARM THAT CATCHES THE OBVIOUS WRONG IMPLEMENTATION. Build the title index
  # over the whole walk instead of over $pubs and these two rows become
  # confident DUPLICATE-CANDIDATEs naming EACH OTHER — two invisible drafts
  # vouching for one another, and a lead would "discard the duplicate" of a row
  # that is not on any board. Both must read DIFFERENTIATED.
  expect_field shared-title-a 7 "DIFFERENTIATED" "two draft-only rows sharing a title do NOT name each other (a)"
  expect_field shared-title-b 7 "DIFFERENTIATED" "two draft-only rows sharing a title do NOT name each other (b)"

  printf 'AGE\n'
  # Pinned against an explicit --now so the arm is not hostage to the clock.
  expect_field dup-of-alpha 3 "61" "age_days from _createdAt against --now (2026-07-05 -> 2026-09-04 = 61)"
  expect_field lonely-differentiated 3 "14" "and again on a second row (2026-08-20T12:00 -> 2026-09-04T00:00 = 14, floored)"
  # The fractional-second _createdAt the ledger actually returns must PARSE.
  # fromdateiso8601 rejects ".000000Z" outright; if the strip regressed, every
  # age would silently read -1 and the arms above would already be red — this
  # arm names the cause instead of leaving it to be guessed.
  if [ "$(field_of no-title-row 3)" = "12" ]; then ok "a fractional-second _createdAt parses (the .000000 strip is live)"
  else bad "age-fraction" "expected 12, got $(field_of no-title-row 3) — -1 means the timestamp did not parse"; fi
  # SORT ORDER is what makes the summary's `oldest=` field true.
  if [ "$(awk -F'\t' 'NR==1{print $1}' "$tmp/table.tsv")" = "dup-of-alpha" ]; then
    ok "the table is sorted oldest-first, which is what SUMMARY oldest= reads"
  else bad "sort" "expected dup-of-alpha first, got $(awk -F'\t' 'NR==1{print $1}' "$tmp/table.tsv")"; fi

  printf 'THE SUMMARY CARRIES THE QUERY AND THE COUNTS\n'
  out="$(summary_line "$tmp/table.tsv" 10 4 6 "$NOW")"
  case "$out" in
    *"DRAFT-ONLY=6"*"DUPLICATE-CANDIDATE=1"*"NEAR-TITLE-CANDIDATE=1"*"DIFFERENTIATED=3"*"NO-TITLE=1"*)
      ok "SUMMARY prints every bucket and they sum to the population (1+1+3+1=6)" ;;
    *) bad "summary-counts" "$out" ;;
  esac
  case "$out" in
    *"oldest=dup-of-alpha"*"61 days"*) ok "SUMMARY names the oldest row with its age" ;;
    *) bad "summary-oldest" "$out" ;;
  esac
  # THE CRITERION'S OWN CLAUSE: "a count of zero is acceptable only if the query
  # that produced it is shown". So the query must be in the output, and it must
  # be the query the script RUNS, not a retyped copy.
  case "$out" in
    *"--perspective raw --all"*) ok "SUMMARY prints the exact query that produced the count" ;;
    *) bad "summary-query" "the query is missing from the summary: $out" ;;
  esac
  if [ "$THE_QUERY" = "env -u BARKPARK_TOKEN bp doc ls task --perspective raw --all --fields lifecycle_status,claim,close_reason,acceptance_criteria,title,description,brief,tags -o json" ]; then
    ok "the printed query is the single THE_QUERY constant the walk executes"
  else bad "query-drift" "THE_QUERY has drifted from the walk in pull_raw: $THE_QUERY"; fi

  printf 'CANNOT READ vs a verdict\n'
  # THE FAILURE THIS SCRIPT EXISTS NOT TO COMMIT: a failed walk answering "0".
  : > "$tmp/empty.json"
  out="$(assert_raw "$tmp/empty.json" 2>&1)"; rc=$?
  case "$rc:$out" in 1:*"CANNOT READ"*) ok "an empty walk file is CANNOT READ, exit 1" ;; *) bad "cannot-read-empty" "rc=$rc out=$out" ;; esac
  printf '%s' '{"error":{"message":"pagination_shifted"}}' > "$tmp/shift.json"
  out="$(assert_raw "$tmp/shift.json" 2>&1)"; rc=$?
  case "$rc:$out" in 1:*"CANNOT READ"*pagination_shifted*) ok "a pagination_shifted error envelope is CANNOT READ, exit 1, and quotes the reason" ;; *) bad "cannot-read-shift" "rc=$rc out=$out" ;; esac
  printf '%s' '{"documents":[]}' > "$tmp/zero.json"
  out="$(assert_raw "$tmp/zero.json" 2>&1)"; rc=$?
  case "$rc:$out" in 1:*"failed walk, not an empty ledger"*) ok "ZERO documents is a failed walk, never 'the ledger is empty'" ;; *) bad "cannot-read-zero" "rc=$rc out=$out" ;; esac
  # And the whole run must not print a SUMMARY on top of that.
  out="$(run_census "$tmp/zero.json" "$tmp/t2.tsv" "$NOW" 2>&1)"; rc=$?
  case "$rc" in
    1) case "$out" in *SUMMARY*) bad "cannot-read-run" "a SUMMARY was printed off a failed walk: $out" ;; *) ok "run_census on a failed walk exits 1 and prints NO summary" ;; esac ;;
    *) bad "cannot-read-run" "expected exit 1, got rc=$rc: $out" ;;
  esac
  # A GOOD walk must still produce one — otherwise the arm above is vacuous.
  out="$(run_census "$tmp/fixture.json" "$tmp/t3.tsv" "$NOW" 2>&1)"; rc=$?
  case "$rc:$out" in 0:*SUMMARY*DRAFT-ONLY=6*) ok "a good walk DOES print a summary (the arm above is not vacuous)" ;; *) bad "good-run" "rc=$rc out=$out" ;; esac

  printf 'THIS FILE NEVER WRITES\n'
  # A grep over the CENSUS PATH's own source, comments excluded. The census
  # hands a lead a list; the day someone adds a publish loop "just for the
  # differentiated ones", this reds before the run does anything.
  #
  # THE SCANNED REGION IS EVERYTHING OUTSIDE `selftest()`, and that boundary is
  # not a convenience — the detector's own pattern is a literal string in this
  # function, so scanning the whole file makes the arm match ITSELF and red on a
  # clean tree. The stated cost: a write verb planted INSIDE selftest is not
  # seen by this arm. That is the right trade, because selftest never runs
  # during a census; the region that runs against the live ledger is exactly the
  # region scanned. The boundary markers are pinned by their own arm below, so
  # renaming the function cannot silently shrink the scan to nothing.
  census_path_source() {
    awk '/^selftest\(\) \{$/ {skip=1} /^# .. argv/ {skip=0} !skip {print NR ":" $0}' "$1"
  }
  local pat='doc (publish|patch|discard-draft|delete)|task (close|claim|create)|data/mutate'
  local writes
  writes="$(census_path_source "$0" | grep -E "$pat" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$writes" ]; then ok "no ledger write verb appears in the census path outside the comments"
  else bad "write-verb" "a write verb appears in executable source: $writes"; fi
  # NON-VACUITY, TWO WAYS. (1) the pattern must catch a literal planted write.
  printf '%s\n' 'bp doc publish task x' > "$tmp/planted.sh"
  if grep -E "$pat" "$tmp/planted.sh" >/dev/null; then
    ok "the write-verb pattern does catch a planted publish (the arm above is not vacuous)"
  else bad "write-verb-vacuous" "the pattern cannot see a literal 'bp doc publish' — it proves nothing"; fi
  # (2) the SCANNED REGION must be non-empty and must actually contain the live
  # code. A renamed selftest() or a moved argv banner would make the awk skip
  # the whole file, and the arm above would pass on a scan of nothing.
  local scanned
  scanned="$(census_path_source "$0" | grep -c '')"
  if [ "$scanned" -gt 100 ] && census_path_source "$0" | grep -q 'run_census "\$RAW"'; then
    ok "the scanned region is $scanned lines and contains the live census entry point"
  else bad "write-verb-region" "the scan covered $scanned lines and did not contain run_census — the markers have drifted"; fi

  printf '\n'
  if [ "$fails" = "0" ]; then printf 'SELFTEST GREEN — all arms passed\n'; return 0
  else printf 'SELFTEST RED — %s arm(s) failed\n' "$fails"; return 3; fi
}

# ── argv ─────────────────────────────────────────────────────────────────────
OUTDIR="${PDS_DRAFT_ONLY_OUTDIR:-$PWD}"
RAW=""
MODE="census"
NOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE="selftest" ;;
    --raw)      RAW="${2:-}"; shift ;;
    --outdir)   OUTDIR="${2:-}"; shift ;;
    --now)      NOW="${2:-}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument: $1" 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq is required" 1
[ -n "$NOW" ] || NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

[ "$MODE" = "selftest" ] && { selftest; exit $?; }

mkdir -p "$OUTDIR"
TABLE="$OUTDIR/draft-only-table.tsv"
if [ -z "$RAW" ]; then
  RAW="$OUTDIR/raw.json"
  pull_raw "$RAW"
fi
run_census "$RAW" "$TABLE" "$NOW"

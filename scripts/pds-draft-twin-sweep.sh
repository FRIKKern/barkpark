#!/usr/bin/env bash
#
# pds-draft-twin-sweep.sh — reconcile the accidental `drafts.<id>` twins that
# the draft-prefixing writer left behind on published type:task rows.
#
# WHY THIS EXISTS
# ---------------
# Content.Writer.upsert_document ALWAYS writes `drafts.<id>`, while every
# canonical reader is published-first. A mutate-patch on a bare id therefore
# forks the row: the published side keeps the close, the draft side keeps the
# pre-close snapshot, and the GitHub bridge only collapses a draft when it
# actually syncs that row — which it never does again for a sealed row. The
# census (cli3-w12, guerrilla / dataset production, 2026-09-03 21:52Z) measured
# 9052 type:task docs (8057 published + 995 drafts.*), 585 live twins, 438 of
# them diverging on lifecycle_status. 436 of those 438 drafts are strictly
# POORER than their published twin: fewer met acceptance criteria on 322, no
# close_reason on 362 while the published row carries the close.
#
# THE TRAP THIS SCRIPT REFUSES TO FALL INTO. The draft's `_updatedAt` is NEWER
# on 437 of 438 rows while its CONTENT is older — "newer" means *touched later
# by the fork*, not *more correct*. Ruling by `_updatedAt` alone inverts the
# right answer on ~436 rows. So the rule is not "newer wins", it is "was this
# draft written BEFORE the close?" — see GUARD 1.
#
# GUARD 1 (the discard rule, in code at classify_twin):
#   A draft is discarded ONLY when ALL of these hold:
#     (a) the published twin is SEALED — lifecycle_status is `done` or
#         `cancelled`. Anything else (open / in_progress / blocked / …) is a
#         live row and the draft may be a live edit -> LIST.
#     (b) the published twin carries a READABLE close timestamp
#         (`claim.closed_at`). 264 of the 5983 sealed published rows in the
#         census walk carry NO closed_at — for those the "before the close"
#         question is UNANSWERABLE, and an unanswerable question is not a yes.
#         The guard FAILS CLOSED: no timestamp -> LIST, never DISCARD.
#     (c) the draft's `_updatedAt` is STRICTLY EARLIER than that close
#         timestamp — the draft is a pre-close snapshot. A draft at or after
#         the close is a live edit someone made to a sealed row -> LIST.
#   LIST is not a soft DISCARD. Nothing on the LIST is ever written.
#
# WHAT THE FIRST DRY RUN MEASURED, AND WHY IT IS NOT A BUG IN THIS SCRIPT.
# On the live population (2026-09-04 02:27Z, 9077 docs, 598 twins, 452
# diverging) clause (c) yields **DISCARD=1, LIST=449, BY-HAND=2** — not the ~436
# main's ruling expected. The reason is mechanical: the fork is minted by a
# mutate-patch that lands AFTER the close, so the draft's `_updatedAt` is later
# than `claim.closed_at` on 425 of the 452, while its CONTENT is still the
# pre-close snapshot. Clause (c) reads the TOUCH; the finding is about the
# CONTENT. Guard 2 therefore refuses a `--expect 436` write (drift 435), which
# is the fence working, not failing. The content-shaped population is printed as
# a DIAGNOSTIC (see diagnostic_line) — 377 rows today. Which rule gates the
# write is main's ruling to make; this script implements the one main wrote and
# reports the number the other one would give.
#
# GUARD 2 (the count fence, in code at run_write):
#   Write mode needs BOTH `--yes` AND `--expect <N>`, and the MEASURED DISCARD
#   count must land within `--tolerance` of N. Out of tolerance REFUSES, prints
#   both numbers, and exits 3 having written nothing. The tolerance is a FLAG
#   with a printed default, never a hidden constant: the default is `auto`,
#   which measures the rows closed since the census instant
#   (published rows whose claim.closed_at is later than $CENSUS_AT) — because
#   that is exactly the drift main's ruling allowed for ("436 plus or minus the
#   rows closed since 21:52Z").
#
# THE TWO BY-HAND ROWS are NEVER in the bulk write. They are hard-coded by id,
# always classified BY-HAND, and excluded from the DISCARD count:
#   * task-2b7cbaf8265f6b4e — published `done` (claim epoch 77) holds ZERO
#     acceptance criteria while the draft holds 7 (6 met). Discarding the draft
#     destroys the only copy of that criteria block.
#   * cch-w37-bl-primary-team-gate-twins-are-one-gate — the published row is
#     still OPEN (0/3) and the DRAFT holds a cancel with a close_reason that
#     never published. Discarding it loses the cancel.
#
# WHAT THIS SCRIPT NEVER DOES
#   * It never writes anything without `--yes` AND `--expect`. The default mode
#     is a read: one raw walk, a per-id table, a summary line.
#   * It never reimplements the ledger client. Every read and every write goes
#     through `bp` (`bp doc ls`, `bp doc get`, `bp doc discard-draft`).
#   * It never discards a draft-only document. `bp doc discard-draft` on a
#     document with no published twin DELETES it (see
#     internal/cli/discard_draft_guard.go); this script only ever names ids that
#     it has just measured as having BOTH sides.
#
# USAGE
#   scripts/pds-draft-twin-sweep.sh                       # dry run, live pull
#   scripts/pds-draft-twin-sweep.sh --raw raw.json        # dry run, reuse a walk
#   scripts/pds-draft-twin-sweep.sh --yes --expect 436    # THE WRITE (lead only)
#   scripts/pds-draft-twin-sweep.sh --yes --expect 436 --tolerance 25
#   scripts/pds-draft-twin-sweep.sh --verify --discarded discarded.txt
#   scripts/pds-draft-twin-sweep.sh --selftest            # offline fixtures
#
# EXIT STATUS
#   0  the run did what it says (dry run printed; write completed; selftest green)
#   1  the run measured nothing it could trust — CANNOT READ, claim nothing
#   2  usage error
#   3  GUARD 2 REFUSED — the measured count is outside tolerance of --expect.
#      Nothing was written. This is a verdict, not a failure.
#   4  a write was attempted and at least one discard failed
set -uo pipefail

# ── knobs ────────────────────────────────────────────────────────────────────
# The census instant main's tolerance is measured FROM.
CENSUS_AT="${PDS_SWEEP_CENSUS_AT:-2026-09-03T21:52:00Z}"
# The doc type the sweep walks. Never widen this from the command line.
DOC_TYPE="task"
# The two rows that are ALWAYS BY-HAND. Hard-coded, not derived: a derived rule
# that happened to spare them today could stop sparing them tomorrow.
BY_HAND_IDS="task-2b7cbaf8265f6b4e cch-w37-bl-primary-team-gate-twins-are-one-gate"

BP="${PDS_SWEEP_BP:-bp}"

usage() {
  sed -n '/^# USAGE/,/^# EXIT STATUS/p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'pds-draft-twin-sweep: %s\n' "$1" >&2; exit "${2:-2}"; }

# ── the raw walk ─────────────────────────────────────────────────────────────
# ONE walk per run. `--all` is an offset walk over a LIVE collection: under
# campaign traffic it refuses with `pagination_shifted` and returns an ERROR
# OBJECT, not a short list. A zero-length `.documents` therefore means the walk
# FAILED, and every count downstream would be a lie. Assert the shape here or
# measure nothing at all.
pull_raw() {
  local out="$1"
  env -u BARKPARK_TOKEN "$BP" doc ls "$DOC_TYPE" --perspective raw --all \
    --fields lifecycle_status,claim,close_reason,acceptance_criteria,title \
    -o json 2>/dev/null | grep -v '^bp: ' > "$out"
}

assert_raw() {
  local raw="$1" n
  [ -s "$raw" ] || die "the walk produced an EMPTY file — measured nothing" 1
  n="$(jq -r 'if (.documents|type) == "array" then (.documents|length) else "ERR:" + ((.error.message // .message // "unrecognised envelope")|tostring) end' "$raw" 2>/dev/null)"
  case "$n" in
    ERR:*) die "the walk did not return a document list: ${n#ERR:}" 1 ;;
    ''|*[!0-9]*) die "could not read a document count out of $raw" 1 ;;
  esac
  [ "$n" -gt 0 ] || die "the walk returned ZERO documents — that is a failed walk, not an empty ledger" 1
  printf '%s' "$n"
}

# ── classification ───────────────────────────────────────────────────────────
# GUARD 1 lives here, in jq, applied uniformly to every diverging twin. The
# verdict column is computed from the data; no id-specific exception exists
# except the hard-coded BY-HAND list.
classify() {
  local raw="$1"
  jq -r --arg byhand "$BY_HAND_IDS" '
    def bare: sub("^drafts\\.";"");
    def metcount: ((.acceptance_criteria // []) | map(select(.met == true)) | length);
    def totcount: ((.acceptance_criteria // []) | length);

    ($byhand | split(" ")) as $BH
    | (.documents | map(select(._id | startswith("drafts.") | not))
                  | map({key: ._id, value: .}) | from_entries) as $pub
    | (.documents | map(select(._id | startswith("drafts.")))
                  | map({key: (._id|bare), value: .}) | from_entries) as $drf
    | [ $drf | keys[] | select($pub[.] != null) ] as $twins
    | $twins
    | map(. as $id
        | $pub[$id] as $p | $drf[$id] as $d
        | ($p.lifecycle_status // "NULL") as $ps
        | ($d.lifecycle_status // "NULL") as $ds
        | ($p.claim.closed_at // null) as $closed_at
        | (($ps == "done") or ($ps == "cancelled")) as $sealed
        | ($closed_at != null and ($closed_at|tostring) != "") as $has_close_ts
        | ($has_close_ts and (($d._updatedAt|tostring) < ($closed_at|tostring))) as $pre_close
        # ONE decision, read out twice. The verdict and the reason are both
        # derived from $code, so each clause of guard 1 has exactly ONE place it
        # can be deleted from — measured the hard way: when verdict and why were
        # two parallel if-chains, deleting clause (b) from the verdict chain
        # left the selftest fully GREEN, because the why chain still named it
        # and (c) happened to answer LIST too. A guard with two homes is a guard
        # a mutation cannot find.
        | (if   ($BH | index($id))  then "BY-HAND"
           elif ($sealed | not)     then "NOT-SEALED"
           elif ($has_close_ts|not) then "NO-CLOSE-TS"
           elif ($pre_close | not)  then "POST-CLOSE"
           else "PRE-CLOSE" end) as $code
        | {
            id: $id,
            diverging: ($ps != $ds),
            pub_status: $ps, draft_status: $ds,
            pub_rev: ($p._rev // "-"), draft_rev: ($d._rev // "-"),
            closed_at: ($closed_at // "-"),
            draft_updated: ($d._updatedAt // "-"),
            pub_met: "\($p|metcount)/\($p|totcount)",
            draft_met: "\($d|metcount)/\($d|totcount)",
            pub_close_reason: (if ($p.close_reason // null) != null then "yes" else "no" end),
            draft_close_reason: (if ($d.close_reason // null) != null then "yes" else "no" end),
            verdict: (
              if   $code == "BY-HAND"   then "BY-HAND"
              elif $code == "PRE-CLOSE" then "DISCARD"
              else "LIST" end),
            why: (
              if   $code == "BY-HAND"     then "named by main; never in the bulk write"
              elif $code == "NOT-SEALED"  then "published twin is NOT sealed (\($ps)) — a live row"
              elif $code == "NO-CLOSE-TS" then "published twin is sealed but carries NO readable close timestamp — guard 1 fails closed"
              elif $code == "POST-CLOSE"  then "draft _updatedAt (\($d._updatedAt)) is NOT before the close (\($closed_at)) — a live edit"
              else "pre-close snapshot of a sealed row" end)
          })
    | .[] | select(.diverging)
    | [.id,.pub_status,.draft_status,.closed_at,.draft_updated,.pub_rev,.draft_rev,
       .pub_met,.draft_met,.pub_close_reason,.draft_close_reason,.verdict,.why]
    | @tsv
  ' "$raw"
}

# Rows closed since the census instant — the honest default for GUARD 2's
# tolerance, because that is precisely the drift main's ruling allowed for.
measure_tolerance() {
  jq -r --arg at "$CENSUS_AT" '
    [ .documents[]
      | select(._id | startswith("drafts.") | not)
      | select((.claim.closed_at // "") > $at) ] | length
  ' "$1"
}

count_twins() {
  jq -r '
    def bare: sub("^drafts\\.";"");
    (.documents | map(select(._id|startswith("drafts.")|not) | ._id)) as $p
    | [ .documents[] | select(._id|startswith("drafts.")) | (._id|bare) ]
    | map(select(. as $x | $p | index($x))) | length
  ' "$1"
}

summary_line() {
  local table="$1" total_docs="$2" twins="$3" tol="$4"
  local d l b n
  d=$(awk -F'\t' '$12=="DISCARD"' "$table" | grep -c '' )
  l=$(awk -F'\t' '$12=="LIST"' "$table" | grep -c '' )
  b=$(awk -F'\t' '$12=="BY-HAND"' "$table" | grep -c '' )
  n=$(grep -c '' "$table")
  printf 'SUMMARY docs=%s twins=%s diverging=%s DISCARD=%s LIST=%s BY-HAND=%s tolerance=%s census_at=%s\n' \
    "$total_docs" "$twins" "$n" "$d" "$l" "$b" "$tol" "$CENSUS_AT"
}

# THE DIAGNOSTIC MAIN WILL NEED, AND WHY IT IS NOT A VERDICT.
#
# Guard 1 clause (c) rules by TIMESTAMP, and on the live population that clause
# LISTS almost everything: the fork is minted by a mutate-patch that happens
# AFTER the close, so the draft's `_updatedAt` is later than `claim.closed_at`
# on 425 of the 452 diverging twins — even though its CONTENT is the pre-close
# snapshot. The census said this in the other direction ("the draft is touched
# later, its content is older") and clause (c) reads the touch, not the content.
# The literal rule therefore yields ~1 DISCARD, not ~436, and guard 2 correctly
# refuses the write.
#
# This function measures the CONTENT-shaped rule instead — sealed published twin
# that carries a close_reason the draft lacks, with the draft holding no more
# met criteria than the published row — i.e. "the draft is strictly poorer".
# It is PRINTED and never acted on. Changing which rule gates the write is
# main's ruling, not this script's, and a diagnostic that quietly became a
# verdict is exactly the failure this file is built to avoid.
diagnostic_line() {
  awk -F'\t' '
    ($2=="done"||$2=="cancelled") && $10=="yes" && $11=="no" {
      split($8,p,"/"); split($9,d,"/");
      if (d[1]+0 <= p[1]+0) n++
    }
    END { printf "DIAGNOSTIC (recorded, NEVER gated) content-poorer drafts on sealed twins = %d\n", n+0 }
  ' "$1"
}

print_table() {
  printf 'id\tpub\tdraft\tclosed_at\tdraft_updated\tpub_rev\tdraft_rev\tpub_met\tdraft_met\tpub_cr\tdraft_cr\tverdict\twhy\n'
  cat "$1"
}

# ── modes ────────────────────────────────────────────────────────────────────
run_dry() {
  local raw="$1" table="$2" docs twins tol
  docs="$(assert_raw "$raw")" || exit 1
  twins="$(count_twins "$raw")"
  tol="$TOLERANCE"
  [ "$tol" = "auto" ] && tol="$(measure_tolerance "$raw")"
  classify "$raw" | sort > "$table"
  print_table "$table"
  printf '\n'
  if [ "$TOLERANCE" = "auto" ]; then
    printf 'tolerance=auto -> %s (published rows with claim.closed_at > %s)\n' "$tol" "$CENSUS_AT"
  else
    printf 'tolerance=%s (explicit --tolerance)\n' "$tol"
  fi
  diagnostic_line "$table"
  summary_line "$table" "$docs" "$twins" "$tol"
}

# GUARD 2. Runs BEFORE any write, on the count this run measured.
guard2() {
  local measured="$1" expect="$2" tol="$3" delta
  delta=$(( measured > expect ? measured - expect : expect - measured ))
  if [ "$delta" -gt "$tol" ]; then
    printf 'GUARD 2 REFUSED — nothing was written.\n' >&2
    printf '  measured DISCARD count : %s\n' "$measured" >&2
    printf '  --expect               : %s\n' "$expect" >&2
    printf '  drift                  : %s  (tolerance %s)\n' "$delta" "$tol" >&2
    printf '  Re-run the dry run and re-rule, or pass a tolerance you can defend.\n' >&2
    return 3
  fi
  printf 'GUARD 2 PASSED — measured=%s expect=%s drift=%s tolerance=%s\n' "$measured" "$expect" "$delta" "$tol"
  return 0
}

run_write() {
  local raw="$1" table="$2" docs twins tol measured rc=0
  [ -n "$EXPECT" ] || die "write mode needs --expect <N> as well as --yes" 2
  docs="$(assert_raw "$raw")" || exit 1
  twins="$(count_twins "$raw")"
  tol="$TOLERANCE"
  [ "$tol" = "auto" ] && tol="$(measure_tolerance "$raw")"
  classify "$raw" | sort > "$table"
  print_table "$table"
  printf '\n'
  diagnostic_line "$table"
  summary_line "$table" "$docs" "$twins" "$tol"
  measured=$(awk -F'\t' '$12=="DISCARD"' "$table" | grep -c '')
  guard2 "$measured" "$EXPECT" "$tol" || exit 3

  : > "$DISCARDED"
  local id
  while IFS=$'\t' read -r id _; do
    if env -u BARKPARK_TOKEN "$BP" doc discard-draft "$DOC_TYPE" "$id" --yes >/dev/null 2>&1; then
      printf '%s\n' "$id" >> "$DISCARDED"
      printf 'discarded %s\n' "$id"
    else
      printf 'FAILED    %s\n' "$id" >&2
      rc=4
    fi
  done < <(awk -F'\t' '$12=="DISCARD"{print $1}' "$table")
  printf 'discarded %s of %s; ids in %s\n' "$(grep -c '' "$DISCARDED")" "$measured" "$DISCARDED"
  exit "$rc"
}

# The post-sweep read-back (c4). Re-measures the population and samples three
# discarded ids' PUBLISHED rows — the point of the sweep is that the published
# side is untouched, so a sample that lost its sealed status or its close_reason
# is the failure this arm exists to catch.
run_verify() {
  local raw="$1" table="$2" docs twins
  docs="$(assert_raw "$raw")" || exit 1
  twins="$(count_twins "$raw")"
  classify "$raw" | sort > "$table"
  printf 'POST-SWEEP RE-MEASURE\n'
  summary_line "$table" "$docs" "$twins" "n/a"
  printf '\nExpected after a clean sweep: DISCARD=0 (only LIST and BY-HAND remain).\n\n'
  [ -s "$DISCARDED" ] || { printf 'no discarded-id list at %s — sample skipped\n' "$DISCARDED"; return 0; }
  printf 'SAMPLE OF THREE DISCARDED IDS (published side must be unchanged)\n'
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    env -u BARKPARK_TOKEN "$BP" doc get "$DOC_TYPE" "$id" -o json 2>/dev/null \
      | jq -r --arg id "$id" '
          (.result // .document // .) as $r
          | "\($id)\tstatus=\($r.lifecycle_status // "MISSING")\tclose_reason=\(($r.close_reason // "-")|tostring|.[0:40])\trev=\($r._rev // "-")\tdraft_gone=\(if ($r._id // "") | startswith("drafts.") then "NO" else "yes" end)"'
  done < <(head -3 "$DISCARDED")
}

# ── selftest (offline; no ledger, no network) ────────────────────────────────
# Every arm is a SYNTHETIC pair built in a temp dir, run through the REAL
# classify/guard2 above. The point is that each guard is shown refusing as well
# as passing: a guard only ever observed passing has not been tested.
selftest() {
  local tmp fails=0 out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ok()  { printf '  ok   %s\n' "$1"; }
  bad() { printf '  FAIL %s\n         %s\n' "$1" "$2"; fails=$((fails + 1)); }

  cat > "$tmp/fixture.json" <<'JSON'
{"documents":[
 {"_id":"pre-close-pair","_rev":"p1","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"done",
  "close_reason":"shipped","claim":{"epoch":3,"closed_at":"2026-09-01T09:00:00Z"},
  "acceptance_criteria":[{"met":true},{"met":true}]},
 {"_id":"drafts.pre-close-pair","_rev":"d1","_updatedAt":"2026-09-01T08:00:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[{"met":false},{"met":false}]},

 {"_id":"post-close-pair","_rev":"p2","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"done",
  "close_reason":"shipped","claim":{"epoch":3,"closed_at":"2026-09-01T09:00:00Z"},
  "acceptance_criteria":[{"met":true}]},
 {"_id":"drafts.post-close-pair","_rev":"d2","_updatedAt":"2026-09-01T11:30:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[{"met":false}]},

 {"_id":"no-close-ts-pair","_rev":"p3","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"cancelled",
  "close_reason":"dropped","claim":{"epoch":1},
  "acceptance_criteria":[{"met":true}]},
 {"_id":"drafts.no-close-ts-pair","_rev":"d3","_updatedAt":"2026-08-01T00:00:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[{"met":false}]},

 {"_id":"not-sealed-pair","_rev":"p4","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[{"met":false},{"met":false},{"met":false}]},
 {"_id":"drafts.not-sealed-pair","_rev":"d4","_updatedAt":"2026-08-01T00:00:00Z","lifecycle_status":"cancelled",
  "close_reason":"a cancel that never published","claim":{"epoch":1,"closed_at":"2026-08-01T00:00:00Z"},
  "acceptance_criteria":[{"met":false},{"met":false},{"met":false}]},

 {"_id":"task-2b7cbaf8265f6b4e","_rev":"p5","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"done",
  "close_reason":"closed","claim":{"epoch":77,"closed_at":"2026-09-01T09:00:00Z"},
  "acceptance_criteria":[]},
 {"_id":"drafts.task-2b7cbaf8265f6b4e","_rev":"d5","_updatedAt":"2026-08-01T00:00:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[{"met":true},{"met":true},{"met":true},{"met":true},{"met":true},{"met":true},{"met":false}]},

 {"_id":"cch-w37-bl-primary-team-gate-twins-are-one-gate","_rev":"p6","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[{"met":false},{"met":false},{"met":false}]},
 {"_id":"drafts.cch-w37-bl-primary-team-gate-twins-are-one-gate","_rev":"d6","_updatedAt":"2026-08-01T00:00:00Z","lifecycle_status":"cancelled",
  "close_reason":"twins are one gate","claim":{"epoch":1,"closed_at":"2026-08-01T00:00:00Z"},
  "acceptance_criteria":[{"met":false},{"met":false},{"met":false}]},

 {"_id":"agreeing-twin","_rev":"p7","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"done",
  "close_reason":"shipped","claim":{"epoch":1,"closed_at":"2026-09-01T09:00:00Z"},
  "acceptance_criteria":[{"met":true}]},
 {"_id":"drafts.agreeing-twin","_rev":"d7","_updatedAt":"2026-08-01T00:00:00Z","lifecycle_status":"done",
  "close_reason":"shipped","claim":{"epoch":1,"closed_at":"2026-09-01T09:00:00Z"},
  "acceptance_criteria":[{"met":true}]},

 {"_id":"lonely-published","_rev":"p8","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"done",
  "close_reason":"shipped","claim":{"epoch":1,"closed_at":"2026-09-01T09:00:00Z"},
  "acceptance_criteria":[{"met":true}]},
 {"_id":"drafts.lonely-draft","_rev":"d8","_updatedAt":"2026-09-01T10:00:00Z","lifecycle_status":"open",
  "claim":null,"acceptance_criteria":[]}
]}
JSON

  classify "$tmp/fixture.json" | sort > "$tmp/table.tsv"

  verdict_of() { awk -F'\t' -v id="$1" '$1==id{print $12}' "$tmp/table.tsv"; }
  expect_verdict() {
    local id="$1" want="$2" got; got="$(verdict_of "$id")"
    if [ "$got" = "$want" ]; then ok "$id -> $want"
    else bad "$id" "expected $want, got '${got:-<absent from the table>}'"; fi
  }

  printf 'GUARD 1 — the discard rule\n'
  expect_verdict pre-close-pair  DISCARD
  expect_verdict post-close-pair LIST
  expect_verdict no-close-ts-pair LIST
  expect_verdict not-sealed-pair LIST

  # THE VERDICT ALONE DOES NOT REACH CLAUSE (b). Both (b) and (c) answer LIST
  # for the missing-timestamp row, so an arm that only checks the verdict stays
  # GREEN when (b) is deleted — measured: deleting the `$has_close_ts` elif left
  # the whole selftest green, because `$pre_close` is false anyway. Pin the
  # REASON, so the arm fails when the row is listed for the wrong cause. (And
  # note why (b) is load-bearing at all: with a null `closed_at`, the string
  # compare in (c) reads `"2026-…" < "null"` as TRUE — lexicographic, digits
  # before letters — so without (b) the row would be DISCARDED.)
  # `case`, never `printf | grep -q`: grep -q exits on its first match, printf
  # takes SIGPIPE, and with `set -o pipefail` the pipeline reports 141. That
  # makes an arm fail at random under load — it did, once, in this very file.
  why_of() { awk -F'\t' -v id="$1" '$1==id{print $13}' "$tmp/table.tsv"; }
  expect_reason() {
    local id="$1" needle="$2" label="$3" got; got="$(why_of "$id")"
    case "$got" in
      *"$needle"*) ok "$label" ;;
      *) bad "$label" "expected a reason containing '$needle', got: ${got:-<empty>}" ;;
    esac
  }
  expect_reason no-close-ts-pair "NO readable close timestamp" "no-close-ts-pair is listed BY CLAUSE (b), not by accident"
  expect_reason post-close-pair  "NOT before the close"        "post-close-pair is listed BY CLAUSE (c)"
  expect_reason not-sealed-pair  "NOT sealed"                  "not-sealed-pair is listed BY CLAUSE (a)"
  printf 'THE TWO BY-HAND ROWS\n'
  expect_verdict task-2b7cbaf8265f6b4e BY-HAND
  expect_verdict cch-w37-bl-primary-team-gate-twins-are-one-gate BY-HAND

  printf 'THE POPULATION ITSELF\n'
  # NON-VACUITY: if the table were empty every expect_verdict above would still
  # have to have failed, but these two arms pin the population's shape directly.
  if [ "$(grep -c '' "$tmp/table.tsv")" = "6" ]; then ok "exactly 6 diverging twins in the fixture"
  else bad "population" "expected 6 diverging rows, got $(grep -c '' "$tmp/table.tsv")"; fi
  if [ -z "$(verdict_of agreeing-twin)" ]; then ok "a twin whose two sides AGREE is not in the population"
  else bad "agreeing-twin" "a non-diverging twin leaked into the table"; fi
  if [ -z "$(verdict_of lonely-published)" ] && [ -z "$(verdict_of lonely-draft)" ]; then
    ok "an unpaired published row and an unpaired draft are both out of scope"
  else bad "lonely" "an unpaired document entered the table — discard-draft on one of those DELETES it"; fi
  if [ "$(awk -F'\t' '$12=="DISCARD"' "$tmp/table.tsv" | grep -c '')" = "1" ]; then
    ok "exactly 1 DISCARD — the guards are not waving the fixture through"
  else bad "discard-count" "expected 1 DISCARD, got $(awk -F'\t' '$12=="DISCARD"' "$tmp/table.tsv" | grep -c '')"; fi

  printf 'GUARD 2 — the count fence\n'
  if out="$(guard2 10 10 0 2>&1)"; then ok "exact match passes (10 vs 10, tolerance 0)"
  else bad "guard2-exact" "$out"; fi
  if out="$(guard2 12 10 5 2>&1)"; then ok "inside tolerance passes (12 vs 10, tolerance 5)"
  else bad "guard2-inside" "$out"; fi
  if out="$(guard2 25 10 5 2>&1)"; then bad "guard2-refuse-high" "25 vs 10 tolerance 5 was ACCEPTED"
  else
    case "$out" in
      *"GUARD 2 REFUSED"*25*10*) ok "outside tolerance REFUSES and prints both numbers (25 vs 10)" ;;
      *) bad "guard2-refuse-high" "refused, but did not print both numbers: $out" ;;
    esac
  fi
  if out="$(guard2 2 436 5 2>&1)"; then bad "guard2-refuse-low" "2 vs 436 was ACCEPTED"
  else ok "a collapsed measurement REFUSES too (2 vs 436) — the fence is two-sided"; fi

  printf 'THE DIAGNOSTIC IS A DIAGNOSTIC\n'
  local diag
  diag="$(diagnostic_line "$tmp/table.tsv")"
  # THREE fixture twins are content-poorer sealed twins — pre-close-pair
  # (DISCARD), post-close-pair (LIST) and no-close-ts-pair (LIST). The
  # diagnostic must count all three while the verdict column DISCARDs one: a
  # diagnostic that agreed with the verdict would be measuring nothing new.
  if printf "%s" "$diag" | grep -q "content-poorer drafts on sealed twins = 3"; then
    ok "counts 3 content-poorer sealed twins while only 1 is DISCARD"
  else bad "diagnostic" "expected 3, got: $diag"; fi
  if printf '%s' "$diag" | grep -q 'NEVER gated'; then ok "labelled as never gated"
  else bad "diagnostic-label" "the diagnostic must say out loud that it gates nothing: $diag"; fi

  printf 'TOLERANCE MEASUREMENT\n'
  # Five published rows carry claim.closed_at 2026-09-01T09:00:00Z; the cutoff
  # below is set so that exactly those five count (the two with no closed_at at
  # all must NOT be counted — that is the arm that would go vacuous silently).
  local tol
  tol="$(CENSUS_AT=2026-08-31T00:00:00Z; measure_tolerance "$tmp/fixture.json")"
  if [ "$tol" = "5" ]; then ok "auto tolerance counts the 5 rows closed after the cutoff"
  else bad "tolerance" "expected 5, got $tol"; fi

  printf '\n'
  if [ "$fails" = "0" ]; then printf 'SELFTEST GREEN — all arms passed\n'; return 0
  else printf 'SELFTEST RED — %s arm(s) failed\n' "$fails"; return 1; fi
}

# ── argv ─────────────────────────────────────────────────────────────────────
OUTDIR="${PDS_SWEEP_OUTDIR:-$PWD}"
RAW=""
EXPECT=""
TOLERANCE="auto"
MODE="dry"
DISCARDED="${PDS_SWEEP_DISCARDED:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE="selftest" ;;
    --verify)   MODE="verify" ;;
    --yes)      MODE="write" ;;
    --expect)   EXPECT="${2:-}"; shift ;;
    --tolerance) TOLERANCE="${2:-}"; shift ;;
    --raw)      RAW="${2:-}"; shift ;;
    --outdir)   OUTDIR="${2:-}"; shift ;;
    --discarded) DISCARDED="${2:-}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument: $1" 2 ;;
  esac
  shift
done

[ "$MODE" = "selftest" ] && { selftest; exit $?; }

case "$TOLERANCE" in auto) ;; ''|*[!0-9]*) die "--tolerance takes 'auto' or a non-negative integer" 2 ;; esac
if [ -n "$EXPECT" ]; then
  case "$EXPECT" in ''|*[!0-9]*) die "--expect takes a non-negative integer" 2 ;; esac
fi
command -v jq >/dev/null 2>&1 || die "jq is required" 1

mkdir -p "$OUTDIR"
[ -n "$DISCARDED" ] || DISCARDED="$OUTDIR/discarded-ids.txt"
TABLE="$OUTDIR/twin-table.tsv"
if [ -z "$RAW" ]; then
  RAW="$OUTDIR/raw.json"
  pull_raw "$RAW"
fi

case "$MODE" in
  dry)    run_dry    "$RAW" "$TABLE" ;;
  write)  run_write  "$RAW" "$TABLE" ;;
  verify) run_verify "$RAW" "$TABLE" ;;
esac

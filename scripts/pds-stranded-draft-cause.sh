#!/usr/bin/env bash
#
# pds-stranded-draft-cause.sh — for every DRAFT-ONLY `type:task` row, name the
# gate of the publish wall that would refuse it TODAY, and name the RE-FILE:
# the newer row whose title says the filer gave up on the draft in hand and
# started again.
#
# READ ONLY. No publish, no patch, no discard, no tag registration, no close.
# The selftest greps this file's own live path for write verbs, so the day
# someone adds "and register the missing tag while we're here" it reds before
# the run touches anything. The repair is a LEAD's write, off this table.
#
# WHY THIS EXISTS — AND WHAT IT REFUSES TO ASSUME
# ------------------------------------------------
# task-802f054c2f455956 was filed claiming 398 stranded drafts have ONE cause:
# an unregistered tag, plus a filer who re-files instead of repairing. Its own
# author corrected it TWICE in writing: "one cause" is false (they counted at
# least four), the wall does NOT lie, and repair-in-place DOES work. This
# instrument exists to replace the guess with a count, so the row closes on
# what the population is rather than on what its title asserted.
#
# It is the companion of scripts/pds-draft-only-task-census.sh: that script
# says WHICH rows are stranded, this one says WHY each one is.
#
# THE CAUSE IS THE FIRST GATE THAT WOULD REFUSE, NOT ANY GATE THAT WOULD
# ---------------------------------------------------------------------
# api/lib/barkpark/content/authoring_wall.ex:enforce/5 runs its gates in a
# `with` chain, so the caller only ever SEES the first failure:
#
#     label spine (E1/E2) -> Epic Paper quality -> tag registry (E3) -> dedup (E4)
#
# A draft with a 19-character rationale AND three unregistered tags is refused
# `label_spine`, and its author never learns about the tags. Classifying it as
# UNKNOWN-TAG would be a cause nobody was ever told. So this script walks the
# same order and stops at the same place, and the class it prints is the class
# the filer would have READ.
#
# The Epic-Paper-quality gate is PAPER-ONLY and exact-tag-scoped
# (authoring_wall.ex, gate 2: "Tasks carrying the same taxonomy tag remain
# outside this gate"), so for a `type:task` population it can never fire and is
# not modelled here. That is a deliberate omission, stated rather than silent.
#
# THE SPINE RULES ARE MIRRORED FROM api/lib/barkpark/content/label_spine.ex
# validate/1, in ITS order (description, tags shape, tag count, per-entry
# tag/strength/rationale, distinct strengths, no duplicate tag):
#   description  >= 20 chars after trim          (@min_description 20)
#   tags         an array                        (check_tags_shape)
#   count        1..12                           (@min_tags/@max_tags)
#   tag          matches ^[a-z0-9-]+$
#   strength     integer 1..100                  (@min_strength/@max_strength)
#   rationale    >= 20 chars after trim          (@min_rationale 20)
#   strengths    all distinct
#   tag names    no duplicate
# A MIRROR IS NOT THE GUARD. This script cannot publish anything, so it cannot
# observe a refusal; it PREDICTS one. Every verdict below is therefore a
# PREDICTED cause, the word is in the column heading, and the lead's mutation
# proof (criterion 3 of the row) is what turns one of them into a fact.
#
# E3 READS PUBLISHED TAG DOCS ONLY, and only WEIGHTED entries reach it.
# tag_registry.ex:252 `weighted_tag_names/1` keeps `%{"tag" => name}` entries
# and drops everything else, and :269 `registered_subset/3` selects rows that
# are `type='tag' AND status='published'`. So a draft carrying flat STRING tags
# skips E3 entirely — it has already been refused by the spine's shape check —
# and a tag whose registry doc exists but is itself a DRAFT is UNREGISTERED.
# The registry read here filters `_draft`/`drafts.` for exactly that reason.
#
# THE RE-FILE HALF, AND THE ONE THING THE WALK CANNOT TELL US
# -----------------------------------------------------------
# The row's second claim is behavioural: the filer files a NEW row. A re-file
# is detected as a document created STRICTLY AFTER the draft whose title is
# near-identical to it, by one of two index-able keys:
#   EXACT   normalised titles are equal (lowercased, whitespace collapsed)
#   PREFIX  normalised titles share their first 40 characters
# Both are computed off group_by indexes, never a pairwise sweep, so the run is
# linear in the corpus and its cost does not explode with the board.
#
# THERE IS NO AUTHOR FIELD IN THE WALK. `bp doc ls task --perspective raw`
# returns no filer, so "the same filer" is a PROXY: the id's leading dash
# segment, which on this board is the lane/wave slug (`cch-w64-bl-…`, `dr-w34-…`,
# `lvw-…`). Hash ids (`task-<hex>`) carry no slug and their proxy is UNKNOWN.
# The column is named FILER-PROXY and a match is never reported as proof of
# authorship — it is reported as what it is.
#
# USAGE
#   scripts/pds-stranded-draft-cause.sh                     # live: walk + registry
#   scripts/pds-stranded-draft-cause.sh --raw raw.json --tags tags.json
#   scripts/pds-stranded-draft-cause.sh --sample 12         # sample size (default 12)
#   scripts/pds-stranded-draft-cause.sh --full              # every stranded row
#   scripts/pds-stranded-draft-cause.sh --selftest          # offline fixtures
#
# EXIT STATUS
#   0  the run classified the population and printed COUNTS + a sample + SUMMARY
#   1  CANNOT READ — the walk or the registry was empty, malformed, or zero-length.
#      No counts, no table, no verdict. An absence of measurement is never
#      printed as "no stranded drafts" or as "no unregistered tags".
#   2  usage error
#   3  selftest RED — at least one arm failed
set -uo pipefail

DOC_TYPE="task"
BP="${PDS_STRANDED_BP:-bp}"

# THE EXACT QUERIES, held in ONE place and PRINTED in the summary, so the query
# beside the count is the query that ran and not one retyped into a PR body.
THE_QUERY="env -u BARKPARK_TOKEN bp doc ls $DOC_TYPE --perspective raw --all --fields lifecycle_status,claim,close_reason,acceptance_criteria,title,description,brief,tags -o json"
THE_TAG_QUERY="env -u BARKPARK_TOKEN bp doc ls tag --all -o json"

usage() { sed -n '/^# USAGE/,/^# EXIT STATUS/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'pds-stranded-draft-cause: %s\n' "$1" >&2; exit "${2:-2}"; }

pull_raw() {
  env -u BARKPARK_TOKEN "$BP" doc ls "$DOC_TYPE" --perspective raw --all \
    --fields lifecycle_status,claim,close_reason,acceptance_criteria,title,description,brief,tags \
    -o json 2>/dev/null | grep -v '^bp: ' > "$1"
}

pull_tags() {
  env -u BARKPARK_TOKEN "$BP" doc ls tag --all -o json 2>/dev/null | grep -v '^bp: ' > "$1"
}

# CANNOT READ vs a verdict. Every arm prints the words CANNOT READ and exits 1;
# none of them can fall through into a count. A failed walk answering "0
# stranded drafts" is the exact fraud this file exists to refuse.
assert_docs() {
  local f="$1" what="$2" n
  [ -s "$f" ] || die "CANNOT READ — the $what walk produced an EMPTY file; measured nothing" 1
  n="$(jq -r 'if (.documents|type) == "array" then (.documents|length) else "ERR:" + ((.error.message // .message // "unrecognised envelope")|tostring) end' "$f" 2>/dev/null)"
  case "$n" in
    ERR:*) die "CANNOT READ — the $what walk did not return a document list: ${n#ERR:}" 1 ;;
    ''|*[!0-9]*) die "CANNOT READ — could not read a document count out of $f ($what)" 1 ;;
  esac
  [ "$n" -gt 0 ] || die "CANNOT READ — the $what walk returned ZERO documents; that is a failed walk, not an empty ledger" 1
  printf '%s' "$n"
}

# ── classification ───────────────────────────────────────────────────────────
# One jq pass. Emits TSV: id, created, age_days, cause, cause_detail,
# refile_id, refile_kind, refile_published, filer_proxy, filer_match, title.
classify() {
  local raw="$1" tags="$2" now="$3"
  jq -r --slurpfile reg "$tags" --arg now "$now" '
    def bare: sub("^drafts\\.";"");
    def norm: ((. // "") | tostring | ascii_downcase | gsub("[[:space:]]+"; " ")
               | sub("^ +";"") | sub(" +$";""));
    def epoch: ((. // "") | tostring | sub("\\.[0-9]+";"")
                | (try fromdateiso8601 catch null));
    def trimlen: ((. // "") | tostring | sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"") | length);
    # The lane slug standing in for a filer. Hash ids have none — say so.
    def filer: (if test("^task-[0-9a-f]+$") then "UNKNOWN"
                else (split("-") | .[0]) end);

    # THE REGISTRY: published tag docs only (tag_registry.ex:269 selects
    # type=tag AND status=published). A tag whose doc exists as a DRAFT is
    # unregistered, and folding it in here would hide the very cause we count.
    ( $reg[0].documents
      | map(select((._draft != true) and ((._id | startswith("drafts.")) | not)))
      | map(._id) ) as $registry
    | ($registry | length) as $regn

    # THE SPINE, mirrored from label_spine.ex validate/1 IN ITS ORDER.
    # Returns null when the spine passes, else [field, rule] for the FIRST
    # failing rule — the only one a caller would ever have been told about.
    | def spine($d):
        ($d.description | trimlen) as $dl
        | ($d.tags) as $t
        | if $dl < 20 then ["description","a description must be >= 20 chars (got \($dl))"]
          elif ($t | type) != "array" then ["tags","`tags` must be an array of {tag,strength,rationale} (got \($t|type))"]
          elif ($t | length) < 1 then ["tags","a published document needs at least 1 weighted tag (got 0)"]
          elif ($t | length) > 12 then ["tags","at most 12 tags (got \($t|length))"]
          else
            ( [ $t | to_entries[]
                | .key as $i | .value as $e
                | if ($e | type) != "object" then ["tags","entry #\($i) is not a {tag,strength,rationale} object"]
                  elif (($e.tag | type) != "string") then ["tag","entry #\($i) has no `tag` string"]
                  elif (($e.tag | test("^[a-z0-9-]+$")) | not) then ["tag","entry #\($i) tag \"\($e.tag)\" does not match ^[a-z0-9-]+$"]
                  elif (($e.strength | type) != "number") or (($e.strength|floor) != $e.strength) then ["strength","entry #\($i) strength is not an integer"]
                  elif ($e.strength < 1 or $e.strength > 100) then ["strength","entry #\($i) strength \($e.strength) is outside 1-100"]
                  elif (($e.rationale | type) != "string") then ["rationale","entry #\($i) has no `rationale` string"]
                  elif (($e.rationale | trimlen) < 20) then ["rationale","entry #\($i) rationale is \($e.rationale|trimlen) chars, minimum 20"]
                  else empty end ] ) as $entry_errs
            | if ($entry_errs | length) > 0 then $entry_errs[0]
              elif (([$t[].strength] | length) != ([$t[].strength] | unique | length))
                then ["strength","tied strengths — every tag needs a distinct strength"]
              elif (([$t[].tag] | length) != ([$t[].tag] | unique | length))
                then ["tags","the same tag name appears twice"]
              else null end
          end;

    # E3: only WEIGHTED entries reach the registry (tag_registry.ex:252).
    def unknown_tags($d; $registry):
      ( ($d.tags // []) | if type == "array" then . else [] end
        | map(select((type == "object") and ((.tag | type) == "string") and (.tag != "")) | .tag)
        | unique
        | map(select(IN($registry[]) | not)) );

    ($now | epoch) as $NOW
    | (.documents | map(select(._id | startswith("drafts.") | not))) as $pubs
    | ($pubs | map(._id)) as $pubids
    # The dedup twin is re-derived exactly as the census does it: a PUBLISHED
    # row carrying the byte-identical title. Built over $pubs ONLY, so two
    # stranded drafts sharing a title can never name each other.
    | ($pubs | group_by((.title // "") | tostring)
             | map({key: ((.[0].title // "") | tostring), value: (map(._id) | sort)})
             | from_entries) as $by_title
    # The RE-FILE indexes are built over the WHOLE walk — a re-file is often
    # itself another stranded draft (the retry ladder), so restricting to
    # published rows would hide the ladders this row was filed about.
    | (.documents | group_by(.title | norm)
             | map({key: ((.[0].title | norm) | tostring),
                    value: (map({id: ._id, created: ._createdAt}))})
             | from_entries) as $refile_exact
    | (.documents | group_by((.title | norm)[0:40])
             | map({key: (((.[0].title | norm)[0:40]) | tostring),
                    value: (map({id: ._id, created: ._createdAt}))})
             | from_entries) as $refile_prefix

    | [ .documents[]
        | select(._id | startswith("drafts."))
        | select((._id | bare) as $x | ($pubids | index($x)) == null) ]
    | map(
        . as $d
        | ($d._id | bare) as $id
        | (($d.title // "") | tostring) as $title
        | ($title | norm) as $ntitle
        | ($d._createdAt | epoch) as $created
        | (if ($NOW != null and $created != null)
             then (($NOW - $created) / 86400 | floor) else -1 end) as $age
        | (spine($d)) as $sp
        | (unknown_tags($d; $registry)) as $unk
        | (($by_title[$title] // []) | map(select(. != $id))) as $twins
        # ONE decision, in the wall`s own order, read out twice (class + detail)
        # so a clause deleted from one cannot survive in the other.
        | (if   $sp != null            then "SPINE"
           elif ($unk | length) > 0    then "UNKNOWN-TAG"
           elif ($twins | length) > 0  then "DUPLICATE-CANDIDATE"
           else "UNEXPLAINED" end) as $cause
        | (if   $cause == "SPINE"       then "\($sp[0]): \($sp[1])"
           elif $cause == "UNKNOWN-TAG" then "unregistered: \($unk | join(","))  (registry holds \($regn) published tags)"
           elif $cause == "DUPLICATE-CANDIDATE" then "a PUBLISHED row carries the byte-identical title: \($twins | join(","))"
           else "spine passes, every weighted tag is registered, no published title twin — this draft has no PREDICTED refusal" end) as $detail
        # THE RE-FILE: strictly newer, near-identical title, not this row.
        | ( [ (($refile_exact[$ntitle] // [])[] | . + {kind:"EXACT"}),
              (($refile_prefix[$ntitle[0:40]] // [])[] | . + {kind:"PREFIX"}) ]
            | map(select((.id | bare) != $id))
            | map(select(($created != null) and ((.created | epoch) != null)
                         and ((.created | epoch) > $created)))
            | sort_by((if .kind == "EXACT" then 0 else 1 end), (.created | epoch)) ) as $refiles
        | ($refiles[0] // null) as $rf
        | ($id | filer) as $fp
        | {
            id: $id,
            created: ($d._createdAt // "-"),
            age_days: $age,
            cause: $cause,
            detail: $detail,
            refile_id: (if $rf == null then "-" else ($rf.id) end),
            refile_kind: (if $rf == null then "NONE" else $rf.kind end),
            refile_published: (if $rf == null then "-"
                               elif (($rf.id | startswith("drafts.")) | not) then "published"
                               else "draft" end),
            filer_proxy: $fp,
            filer_match: (if $rf == null then "-"
                          elif $fp == "UNKNOWN" then "unknown"
                          elif (($rf.id | bare | filer) == $fp) then "same-lane"
                          else "different-lane" end),
            title: ($title | gsub("[[:space:]]+"; " "))
          })
    | sort_by(.created)
    | .[]
    | [.id, .created, (.age_days|tostring), .cause, .detail,
       .refile_id, .refile_kind, .refile_published, .filer_proxy, .filer_match, .title]
    | @tsv
  ' "$raw"
}

HEADER='id	created	age_days	predicted_cause	cause_detail	refile_id	refile_kind	refile_side	filer_proxy	filer_match	title'

counts_block() {
  local t="$1" c n
  printf 'PREDICTED CAUSE — the FIRST wall gate that would refuse, over the WHOLE stranded population\n'
  printf 'cause\tn\twith a re-file\n'
  for c in SPINE UNKNOWN-TAG DUPLICATE-CANDIDATE UNEXPLAINED; do
    n=$(awk -F'\t' -v c="$c" '$4==c' "$t" | grep -c '')
    r=$(awk -F'\t' -v c="$c" '$4==c && $7!="NONE"' "$t" | grep -c '')
    printf '%s\t%s\t%s\n' "$c" "$n" "$r"
  done
}

summary_line() {
  local t="$1" docs="$2" regn="$3" now="$4"
  local n spine unk dup unex refiled
  n=$(grep -c '' "$t")
  spine=$(awk -F'\t' '$4=="SPINE"' "$t" | grep -c '')
  unk=$(awk -F'\t' '$4=="UNKNOWN-TAG"' "$t" | grep -c '')
  dup=$(awk -F'\t' '$4=="DUPLICATE-CANDIDATE"' "$t" | grep -c '')
  unex=$(awk -F'\t' '$4=="UNEXPLAINED"' "$t" | grep -c '')
  refiled=$(awk -F'\t' '$7!="NONE"' "$t" | grep -c '')
  printf 'SUMMARY docs=%s registry=%s STRANDED=%s SPINE=%s UNKNOWN-TAG=%s DUPLICATE-CANDIDATE=%s UNEXPLAINED=%s WITH-REFILE=%s now=%s\n' \
    "$docs" "$regn" "$n" "$spine" "$unk" "$dup" "$unex" "$refiled" "$now"
  printf 'QUERY %s\n' "$THE_QUERY"
  printf 'QUERY %s\n' "$THE_TAG_QUERY"
  printf 'EVERY CAUSE ABOVE IS PREDICTED, not observed: this file cannot publish, so it cannot see a refusal. It mirrors authoring_wall.ex enforce/5 gate order and label_spine.ex validate/1 rule order, and stops where the wall stops.\n'
  printf 'FILER_PROXY is the id lane slug, NOT an author field — the raw walk carries none. same-lane is a hint, never proof of authorship.\n'
}

run_report() {
  local raw="$1" tags="$2" table="$3" now="$4" sample="$5" full="$6" docs regn
  docs="$(assert_docs "$raw" "task")" || exit 1
  regn="$(jq -r '[.documents[] | select((._draft != true) and ((._id|startswith("drafts."))|not))] | length' "$tags")"
  [ -n "$regn" ] && [ "$regn" != "0" ] || die "CANNOT READ — the tag registry walk yielded ZERO published tag docs; every tag would score UNREGISTERED" 1
  classify "$raw" "$tags" "$now" > "$table"
  [ -s "$table" ] || die "CANNOT READ — the classification produced no rows at all" 1

  counts_block "$table"
  printf '\n'
  if [ "$full" = "yes" ]; then
    printf 'EVERY STRANDED DRAFT\n%s\n' "$HEADER"
    cat "$table"
  else
    printf 'SAMPLE — the %s NEWEST stranded drafts (newest-first is deterministic and picks nobody; the counts above cover the population)\n' "$sample"
    printf '%s\n' "$HEADER"
    # newest LAST in the table (sorted by created ASC), reversed here so the
    # sample reads newest-first. awk, not `tail -r`: that flag is BSD-only and
    # a fallback that re-runs tail would print the block twice on GNU.
    tail -n "$sample" "$table" | awk '{ line[NR] = $0 } END { for (i = NR; i >= 1; i--) print line[i] }' 
  fi
  printf '\n'
  summary_line "$table" "$docs" "$regn" "$now"
}

# ── selftest (offline; no ledger, no network, no credential) ─────────────────
# A synthetic fixture through the REAL classify/assert_docs/summary_line above.
# Every rule is shown REFUSING as well as PASSING — a rule only ever observed
# passing has not been tested.
selftest() {
  local tmp fails=0 out rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ok()  { printf '  ok   %s\n' "$1"; }
  bad() { printf '  FAIL %s\n         %s\n' "$1" "$2"; fails=$((fails + 1)); }

  cat > "$tmp/tags.json" <<'JSON'
{"documents":[
 {"_id":"cloud","_draft":false,"title":"cloud"},
 {"_id":"studio","_draft":false,"title":"studio"},
 {"_id":"media","_draft":false,"title":"media"},
 {"_id":"drafts.env-census","_draft":true,"title":"env-census"},
 {"_id":"ci-gates","_draft":true,"title":"ci-gates"}
]}
JSON

  # R20 is exactly 20 chars, R19 exactly 19 — the off-by-one the row's own
  # correction turned on ("19 characters against a documented minimum of 20").
  cat > "$tmp/fixture.json" <<'JSON'
{"documents":[
 {"_id":"pub-alpha","_createdAt":"2026-07-01T00:00:00.000000Z","title":"the wall refuses a near duplicate","description":"a published incumbent with a perfectly adequate description","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-a-w1-spine-short-rationale","_createdAt":"2026-08-01T00:00:00.000000Z","title":"a spine failure hides the tag failure behind it","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"env-census","strength":50,"rationale":"nineteen chars here"}]},
 {"_id":"lane-a-w1-spine-short-rationale-refiled","_createdAt":"2026-08-02T00:00:00.000000Z","title":"a spine failure hides the tag failure behind it","description":"the re-file, published, byte-identical title","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-b-w2-unregistered-tag-only","_createdAt":"2026-08-03T00:00:00.000000Z","title":"a clean spine and one tag nobody registered","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"env-census","strength":50,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-c-w3-duplicate-of-alpha","_createdAt":"2026-08-04T00:00:00.000000Z","title":"the wall refuses a near duplicate","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-d-w4-nothing-explains-it","_createdAt":"2026-08-05T00:00:00.000000Z","title":"no gate models a refusal for this row at all","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"studio","strength":70,"rationale":"twenty chars exactly!"},{"tag":"media","strength":40,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-e-w5-tied-strengths","_createdAt":"2026-08-06T00:00:00.000000Z","title":"two tags one strength","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"cloud","strength":50,"rationale":"twenty chars exactly!"},{"tag":"studio","strength":50,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-f-w6-no-tags-at-all","_createdAt":"2026-08-07T00:00:00.000000Z","title":"no tags at all","description":"this description is comfortably longer than twenty characters","tags":[]},

 {"_id":"drafts.lane-g-w7-tags-as-a-string","_createdAt":"2026-08-08T00:00:00.000000Z","title":"tags written as a json string","description":"this description is comfortably longer than twenty characters","tags":"[{\"tag\":\"cloud\"}]"},

 {"_id":"drafts.lane-h-w8-short-description","_createdAt":"2026-08-09T00:00:00.000000Z","title":"description too short","description":"too short","tags":[{"tag":"cloud","strength":50,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-i-w9-prefix-refiled","_createdAt":"2026-08-10T00:00:00.000000Z","title":"a long title that shares its first forty characters with a later one AAAA","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"env-census","strength":50,"rationale":"twenty chars exactly!"}]},
 {"_id":"drafts.lane-i-w9-prefix-refiled-take-two","_createdAt":"2026-08-11T00:00:00.000000Z","title":"a long title that shares its first forty characters with a later one BBBB","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"cloud","strength":50,"rationale":"twenty chars exactly!"}]},

 {"_id":"drafts.lane-j-w0-older-twin-is-not-a-refile","_createdAt":"2026-08-12T00:00:00.000000Z","title":"an OLDER row with this title must not count as a re-file","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"env-census","strength":50,"rationale":"twenty chars exactly!"}]},
 {"_id":"lane-j-w0-the-older-one","_createdAt":"2026-07-15T00:00:00.000000Z","title":"an OLDER row with this title must not count as a re-file","description":"published BEFORE the draft, so it is a twin and not a re-file","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]},

 {"_id":"ordinary-twin","_createdAt":"2026-07-02T00:00:00.000000Z","title":"a twin over a published row","description":"a published row that also has a draft — NOT stranded","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]},
 {"_id":"drafts.ordinary-twin","_createdAt":"2026-07-02T00:00:00.000000Z","title":"a twin over a published row","description":"the draft side of a published row — NOT stranded","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]}
]}
JSON

  local NOW="2026-09-05T00:00:00Z"
  classify "$tmp/fixture.json" "$tmp/tags.json" "$NOW" > "$tmp/t.tsv"

  field_of() { awk -F'\t' -v id="$1" -v c="$2" '$1==id{print $c}' "$tmp/t.tsv"; }
  expect() {
    local id="$1" col="$2" want="$3" label="$4" got; got="$(field_of "$id" "$col")"
    if [ "$got" = "$want" ]; then ok "$label"
    else bad "$label" "expected '$want', got '${got:-<absent from the table>}'"; fi
  }
  expect_has() {
    local id="$1" col="$2" want="$3" label="$4" got; got="$(field_of "$id" "$col")"
    case "$got" in *"$want"*) ok "$label" ;;
      *) bad "$label" "expected a value containing '$want', got '${got:-<absent>}'" ;; esac
  }

  printf 'THE POPULATION — a stranded draft is a draft with NO published side\n'
  if [ "$(grep -c '' "$tmp/t.tsv")" = "11" ]; then ok "exactly 11 stranded drafts in the fixture"
  else bad "population" "expected 11 rows, got $(grep -c '' "$tmp/t.tsv")"; fi
  # ABSENCE BY NAME, not merely uncounted — an empty table satisfies "uncounted".
  if grep -q '^ordinary-twin	' "$tmp/t.tsv"; then bad "twin-excluded" "a draft WITH a published side was classified as stranded"
  else ok "a draft with a published side is absent by name (not stranded)"; fi
  if grep -q '^pub-alpha	' "$tmp/t.tsv"; then bad "pub-excluded" "a published row was classified as stranded"
  else ok "a published row is absent by name"; fi

  printf 'GATE ORDER — the cause is the FIRST gate that refuses, never any gate that would\n'
  # RED-WITHOUT/GREEN-WITH on the ordering itself: lane-a carries BOTH a
  # 19-char rationale AND the unregistered tag `env-census`. If the classifier
  # scored E3 first it would read UNKNOWN-TAG, which is a cause the filer was
  # never told. lane-b is the SAME tag with a clean spine and DOES read
  # UNKNOWN-TAG — so the pair proves the order, not just one branch.
  expect "lane-a-w1-spine-short-rationale" 4 "SPINE" "a spine failure MASKS the unregistered tag behind it"
  expect_has "lane-a-w1-spine-short-rationale" 5 "rationale is 19 chars" "and it names the 19-vs-20 off-by-one exactly"
  expect "lane-b-w2-unregistered-tag-only" 4 "UNKNOWN-TAG" "the SAME tag with a clean spine DOES read UNKNOWN-TAG (the arm above is not vacuous)"
  expect_has "lane-b-w2-unregistered-tag-only" 5 "env-census" "and it names the offending tag"

  printf 'THE REGISTRY IS PUBLISHED TAG DOCS ONLY\n'
  # env-census exists in the registry fixture as `drafts.env-census` AND
  # ci-gates exists with _draft true. Both must count as UNREGISTERED, or the
  # cause this row was filed about would silently disappear.
  if [ "$(field_of lane-b-w2-unregistered-tag-only 4)" = "UNKNOWN-TAG" ]; then
    ok "a tag doc that exists only as a DRAFT is UNREGISTERED"
  else bad "registry-drafts" "a draft tag doc was treated as registered"; fi
  expect "lane-d-w4-nothing-explains-it" 4 "UNEXPLAINED" "published tags DO register (the arm above is not vacuous)"

  printf 'THE SPINE RULES, each shown REFUSING\n'
  expect_has "lane-e-w5-tied-strengths"    5 "tied strengths"   "tied strengths refuse"
  expect_has "lane-f-w6-no-tags-at-all"    5 "at least 1"       "zero tags refuse"
  expect_has "lane-g-w7-tags-as-a-string"  5 "must be an array" "tags as a JSON string refuse"
  expect_has "lane-h-w8-short-description" 5 ">= 20 chars"      "a short description refuses"

  printf 'THE DEDUP TWIN IS RE-DERIVED FROM PUBLISHED ROWS ONLY\n'
  expect "lane-c-w3-duplicate-of-alpha" 4 "DUPLICATE-CANDIDATE" "a byte-identical PUBLISHED title is a duplicate candidate"
  expect_has "lane-c-w3-duplicate-of-alpha" 5 "pub-alpha" "and it names the twin"

  printf 'THE RE-FILE HALF\n'
  expect "lane-a-w1-spine-short-rationale" 7 "EXACT"     "an identical title created LATER is an EXACT re-file"
  expect "lane-a-w1-spine-short-rationale" 8 "published" "and the re-file side is reported"
  expect "lane-a-w1-spine-short-rationale" 10 "same-lane" "and the lane slug matches"
  expect "lane-i-w9-prefix-refiled" 7 "PREFIX" "a 40-char shared prefix is a PREFIX re-file"
  expect "lane-i-w9-prefix-refiled" 8 "draft"  "a re-file that is itself a stranded draft is reported as a draft (the retry ladder)"
  # DIRECTION IS LOAD-BEARING. An OLDER row with the same title is a dedup
  # TWIN, not evidence the filer gave up — scoring it as a re-file would
  # manufacture the row's behavioural claim out of the dedup population.
  expect "lane-j-w0-older-twin-is-not-a-refile" 7 "NONE" "an OLDER same-title row is NOT a re-file"
  expect "lane-d-w4-nothing-explains-it" 7 "NONE" "a row with no later twin has no re-file (the arms above are not vacuous)"

  printf 'FILER PROXY IS NAMED FOR WHAT IT IS\n'
  expect "lane-b-w2-unregistered-tag-only" 9 "lane" "the lane slug is the filer proxy"
  # A hash id must say UNKNOWN rather than inventing a lane out of "task".
  cat > "$tmp/hash.json" <<'JSON'
{"documents":[
 {"_id":"drafts.task-deadbeef01","_createdAt":"2026-08-01T00:00:00.000000Z","title":"a hash id has no lane slug","description":"this description is comfortably longer than twenty characters","tags":[{"tag":"env-census","strength":50,"rationale":"twenty chars exactly!"}]},
 {"_id":"task-deadbeef02","_createdAt":"2026-08-02T00:00:00.000000Z","title":"a hash id has no lane slug","description":"the later re-file, also a hash id","tags":[{"tag":"cloud","strength":80,"rationale":"twenty chars exactly!"}]}
]}
JSON
  classify "$tmp/hash.json" "$tmp/tags.json" "$NOW" > "$tmp/h.tsv"
  if [ "$(awk -F'\t' '$1=="task-deadbeef01"{print $9}' "$tmp/h.tsv")" = "UNKNOWN" ]; then
    ok "a hash id reports filer_proxy UNKNOWN, never a lane invented from 'task'"
  else bad "hash-filer" "got '$(awk -F'\t' '$1=="task-deadbeef01"{print $9}' "$tmp/h.tsv")'"; fi
  if [ "$(awk -F'\t' '$1=="task-deadbeef01"{print $10}' "$tmp/h.tsv")" = "unknown" ]; then
    ok "and its filer_match is 'unknown', never 'same-lane'"
  else bad "hash-match" "got '$(awk -F'\t' '$1=="task-deadbeef01"{print $10}' "$tmp/h.tsv")'"; fi

  printf 'CANNOT READ — an absence of measurement is never a count\n'
  for bad_shape in '' '{"error":{"message":"pagination shifted under the walk"}}' '{"documents":[]}' 'not json at all'; do
    printf '%s' "$bad_shape" > "$tmp/bad.json"
    out="$(run_report "$tmp/bad.json" "$tmp/tags.json" "$tmp/bt.tsv" "$NOW" 5 no 2>&1)"; rc=$?
    case "$rc:$out" in
      1:*CANNOT\ READ*) : ;;
      *) bad "cannot-read" "a bad walk (${bad_shape:0:30}) gave rc=$rc out=$out"; continue ;;
    esac
    case "$out" in *SUMMARY*) bad "cannot-read-summary" "a bad walk still printed a SUMMARY" ;; *) : ;; esac
  done
  ok "an empty / error / zero-length / malformed walk all exit 1 CANNOT READ with no SUMMARY"
  # AND AN EMPTY REGISTRY, which is the failure that would score EVERY tag as
  # unregistered and hand the lead a table confirming the row's title.
  printf '{"documents":[{"_id":"drafts.only-a-draft","_draft":true}]}' > "$tmp/emptyreg.json"
  out="$(run_report "$tmp/fixture.json" "$tmp/emptyreg.json" "$tmp/bt.tsv" "$NOW" 5 no 2>&1)"; rc=$?
  case "$rc:$out" in
    1:*CANNOT\ READ*ZERO\ published\ tag*) ok "a registry with no PUBLISHED tag doc exits 1 rather than scoring every tag unregistered" ;;
    *) bad "empty-registry" "rc=$rc out=$out" ;;
  esac
  # NON-VACUITY: a GOOD run must still print a summary, or every arm above is
  # satisfied by a script that never prints anything.
  out="$(run_report "$tmp/fixture.json" "$tmp/tags.json" "$tmp/gt.tsv" "$NOW" 5 no 2>&1)"; rc=$?
  case "$rc:$out" in
    0:*SUMMARY*STRANDED=11*) ok "a good run DOES print COUNTS and a SUMMARY (the arms above are not vacuous)" ;;
    *) bad "good-run" "rc=$rc out=$out" ;;
  esac
  case "$out" in *"SPINE	5"*) ok "the counts block tallies the classes it printed" ;;
    *) bad "counts" "the COUNTS block did not carry SPINE=5" ;; esac

  printf 'THIS FILE NEVER WRITES\n'
  # A grep over the LIVE PATH's own source, comments excluded. The scanned
  # region is everything outside selftest(), because the detector's pattern is
  # a literal string in THIS function and scanning the whole file would make
  # the arm match itself and red on a clean tree.
  live_path_source() {
    awk '/^selftest\(\) \{$/ {skip=1} /^# .. argv/ {skip=0} !skip {print NR ":" $0}' "$1"
  }
  local pat='doc (publish|patch|discard-draft|delete|create)|task (close|claim|create)|data/mutate'
  local writes
  writes="$(live_path_source "$0" | grep -E "$pat" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$writes" ]; then ok "no ledger write verb appears in the live path outside the comments"
  else bad "write-verb" "a write verb appears in executable source: $writes"; fi
  printf '%s\n' 'bp doc publish task x' > "$tmp/planted.sh"
  if grep -E "$pat" "$tmp/planted.sh" >/dev/null; then
    ok "the write-verb pattern does catch a planted publish (the arm above is not vacuous)"
  else bad "write-verb-vacuous" "the pattern cannot see a literal 'bp doc publish' — it proves nothing"; fi
  local scanned
  scanned="$(live_path_source "$0" | grep -c '')"
  if [ "$scanned" -gt 100 ] && live_path_source "$0" | grep -q 'run_report "\$RAW"'; then
    ok "the scanned region is $scanned lines and contains the live entry point"
  else bad "write-verb-region" "the scan covered $scanned lines and did not contain run_report — the markers have drifted"; fi

  printf '\n'
  if [ "$fails" = "0" ]; then printf 'SELFTEST GREEN — all arms passed\n'; return 0
  else printf 'SELFTEST RED — %s arm(s) failed\n' "$fails"; return 3; fi
}

# ── argv ─────────────────────────────────────────────────────────────────────
OUTDIR="${PDS_STRANDED_OUTDIR:-$PWD}"
RAW=""
TAGS=""
MODE="report"
NOW=""
SAMPLE=12
FULL="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE="selftest" ;;
    --raw)      RAW="${2:-}"; shift ;;
    --tags)     TAGS="${2:-}"; shift ;;
    --outdir)   OUTDIR="${2:-}"; shift ;;
    --now)      NOW="${2:-}"; shift ;;
    --sample)   SAMPLE="${2:-}"; shift ;;
    --full)     FULL="yes" ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument: $1" 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq is required" 1
case "$SAMPLE" in ''|*[!0-9]*) die "--sample takes a whole number" 2 ;; esac
[ -n "$NOW" ] || NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

[ "$MODE" = "selftest" ] && { selftest; exit $?; }

mkdir -p "$OUTDIR"
TABLE="$OUTDIR/stranded-cause-table.tsv"
if [ -z "$RAW" ]; then RAW="$OUTDIR/raw.json"; pull_raw "$RAW"; fi
if [ -z "$TAGS" ]; then TAGS="$OUTDIR/tags.json"; pull_tags "$TAGS"; fi
assert_docs "$TAGS" "tag registry" >/dev/null || exit 1
run_report "$RAW" "$TAGS" "$TABLE" "$NOW" "$SAMPLE" "$FULL"

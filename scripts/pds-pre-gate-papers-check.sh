#!/usr/bin/env bash
#
# pds-pre-gate-papers-check.sh — the grandfather register's ratchet.
#
# WHY THIS EXISTS
# ---------------
# `Barkpark.Content.Lifecycle` runs the Paper render-shape gate at the publish
# DOOR only. Nothing re-gates a row that is already published, so Papers
# published before the gate existed keep serving blocks the same gate refuses
# today. The 2026-09-02 ruling GRANDFATHERS that population: those rows stay
# readable, are never retroactively refused, and the next EDIT of each must
# satisfy the gate (pinned by
# api/test/barkpark/content/pds_w49_pre_gate_edit_rule_test.exs).
#
# A grandfather ruling with no ratchet is an open drain. This door recounts the
# LIVE published corpus through the gate's own predicate and REFUSES if any
# published Paper the gate would refuse is NOT already named in the register at
# tooling/pds/pre-gate-papers.json. The registered set can only SHRINK without a
# new ruling; a paper that heals is reported, never refused.
#
# WHAT THIS DOOR STRUCTURALLY CANNOT SEE
# --------------------------------------
# * It reads the corpus it FETCHES. The fetch must project `blocks,body` — the
#   two stored locations `Projection.read_blocks/1` reads. A projection that
#   drops them makes every paper look block-less and refuses nothing, silently.
#   The location census is printed on every run for exactly that reason: an
#   all-`none` census means the instrument went blind, not that the corpus is
#   clean. `--live` REFUSES a census in which no paper carries a block list.
# * It is a verdict on the corpus at fetch time, not on a diff. It cannot say
#   which commit introduced a refused paper — only that one exists unregistered.
# * A paper whose markdown-string body synthesises blocks at read time is out of
#   the gate's scope and out of this door's scope, by the gate's own choice.
#
# THE FETCH IS NOT THE VERDICT. `--live` needs the network AND a compiled
# `api/` tree, so it is an OPERATOR instrument, not a CI leg. The COMPARISON —
# refused-set vs register — is pure and offline, and `--selftest` exercises it in
# BOTH directions (a refused-and-registered id passes; a refused-and-unregistered
# id fails) so a copy-paste that guts the comparison reds in CI.
#
# USAGE
#   scripts/pds-pre-gate-papers-check.sh --live            # fetch + predicate + compare
#   scripts/pds-pre-gate-papers-check.sh --refused-file F  # compare a saved run
#   scripts/pds-pre-gate-papers-check.sh --selftest        # offline, no bp, no mix
#
# EXIT STATUS
#   0  every refused published Paper is named in the register
#   1  a refused published Paper is NOT in the register — needs a new ruling
#   2  usage error
#  99  a required tool is missing (jq; bp/mix for --live)

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTER="${PDS_PRE_GATE_REGISTER:-$REPO_ROOT/tooling/pds/pre-gate-papers.json}"
PREDICATE="$REPO_ROOT/scripts/pds-pre-gate-papers-predicate.exs"
PAGE_LIMIT="${PDS_PRE_GATE_PAGE_LIMIT:-100}"
PAGE_SLEEP="${PDS_PRE_GATE_PAGE_SLEEP:-2}"

die() { printf '%s\n' "$*" >&2; exit "${2:-2}"; }

need_jq() {
  command -v jq >/dev/null 2>&1 || die "pds-pre-gate-papers-check: jq is required" 99
}

# ── the COMPARISON — pure, offline, the part CI can run ──────────────────────
# $1 = a predicate-output JSON (has .refused[].id), $2 = a register JSON
# (has .papers[].id). Prints a verdict block; returns 0 clean, 1 unregistered.
compare_refused_to_register() {
  local refused_file="$1" register_file="$2" rc=0

  [ -r "$refused_file" ] || die "pds-pre-gate-papers-check: cannot read $refused_file"
  [ -r "$register_file" ] || die "pds-pre-gate-papers-check: cannot read $register_file"

  local refused_n registered_n
  refused_n="$(jq '.refused | length' "$refused_file")"
  registered_n="$(jq '.papers | length' "$register_file")"

  local unregistered healed
  unregistered="$(jq -r --slurpfile reg "$register_file" '
    ($reg[0].papers | map(.id)) as $known
    | .refused | map(select(.id as $i | ($known | index($i)) == null)) | .[].id
  ' "$refused_file")"
  healed="$(jq -r --slurpfile ref "$refused_file" '
    ($ref[0].refused | map(.id)) as $bad
    | .papers | map(select(.id as $i | ($bad | index($i)) == null)) | .[].id
  ' "$register_file")"

  printf 'register:   %s (%s papers)\n' "$register_file" "$registered_n"
  printf 'refused:    %s (%s papers)\n' "$refused_file" "$refused_n"

  if [ -n "$healed" ]; then
    printf 'HEALED (registered, no longer refused — report only, never a refusal):\n'
    printf '  %s\n' $healed
  fi

  if [ -n "$unregistered" ]; then
    printf 'UNREGISTERED REFUSAL — the grandfathered set GREW:\n'
    printf '  %s\n' $unregistered
    printf '\n'
    printf 'The 2026-09-02 ruling grandfathers a NAMED set. A published Paper the\n'
    printf 'gate refuses and the register does not name is new debt, and needs a new\n'
    printf 'ruling — not an append to the register. Adding the id here without one is\n'
    printf 'exactly the ratchet this door exists to prevent.\n'
    rc=1
  else
    printf 'VERDICT: OK — every refused published Paper is named in the register.\n'
  fi

  return "$rc"
}

# ── the LIVE arm — network + a compiled api/ tree ────────────────────────────
run_live() {
  need_jq
  command -v bp >/dev/null 2>&1 || die "pds-pre-gate-papers-check: bp is required for --live" 99
  command -v mix >/dev/null 2>&1 || die "pds-pre-gate-papers-check: mix is required for --live" 99
  [ -r "$PREDICATE" ] || die "pds-pre-gate-papers-check: missing $PREDICATE" 99

  local work
  work="$(mktemp -d)" || die "pds-pre-gate-papers-check: mktemp failed" 99
  printf 'work dir: %s\n' "$work"

  local total
  bp doc ls paper --perspective published --limit 1 --count --fields title -o json \
    > "$work/count.json" 2>"$work/count.err"
  total="$(jq -r '.total // empty' "$work/count.json")"
  [ -n "$total" ] || { cat "$work/count.err" >&2; die "pds-pre-gate-papers-check: no .total from bp --count" 99; }
  printf 'denominator (bp --count): %s published Papers\n' "$total"

  # ONE full pass, no retry loop: the prod ledger is a shared resource and a
  # retry storm is load, not diligence. A failed page is REPORTED and the run
  # refuses rather than reporting a count over a corpus with a hole in it.
  local off=0 pages=0 failed=0
  : > "$work/pages.log"
  while [ "$off" -lt "$total" ]; do
    if bp doc ls paper --perspective published --limit "$PAGE_LIMIT" --offset "$off" \
         --fields blocks,body -o json > "$work/p$off.json" 2>"$work/p$off.err"; then
      local n
      n="$(jq '.documents | length' "$work/p$off.json" 2>/dev/null)"
      if [ -z "$n" ]; then failed=$((failed + 1)); n="PARSE_FAIL"; fi
      printf 'offset=%s docs=%s\n' "$off" "$n" >> "$work/pages.log"
    else
      failed=$((failed + 1))
      printf 'offset=%s FETCH_FAILED\n' "$off" >> "$work/pages.log"
    fi
    pages=$((pages + 1))
    off=$((off + PAGE_LIMIT))
    sleep "$PAGE_SLEEP"
  done
  cat "$work/pages.log"
  printf 'pages=%s failed_pages=%s\n' "$pages" "$failed"
  [ "$failed" -eq 0 ] || die "pds-pre-gate-papers-check: $failed page(s) failed — a count over a holed corpus is not a count" 99

  # Slim to {_id, content{blocks, body-minus-html}}: body.html is megabytes of
  # rendered output the predicate never reads.
  jq -s '[ .[].documents[] ]
         | unique_by(._id)
         | map({_id: ._id,
                content: ( {}
                  + (if (.blocks | type) != "null" then {blocks: .blocks} else {} end)
                  + (if (.body  | type) == "object" then {body: (.body | del(.html))}
                     elif (.body | type) != "null"  then {body: .body}
                     else {} end) )})' \
     "$work"/p*.json > "$work/corpus.json" || die "pds-pre-gate-papers-check: slimming failed" 99

  local fetched
  fetched="$(jq 'length' "$work/corpus.json")"
  printf 'fetched unique ids: %s (denominator %s)\n' "$fetched" "$total"
  [ "$fetched" -eq "$total" ] || die "pds-pre-gate-papers-check: fetched $fetched of $total — incomplete corpus" 99

  ( cd "$REPO_ROOT/api" && MIX_ENV="test" mix run --no-start "$PREDICATE" \
      "$work/corpus.json" "$work/refused.json" ) || die "pds-pre-gate-papers-check: predicate run failed" 99

  # NON-BLINDNESS: an instrument that projected the wrong fields sees every
  # paper as block-less and refuses nothing. That reads exactly like a clean
  # corpus, so refuse it instead of reporting it.
  local with_blocks
  with_blocks="$(jq '[.by_location | to_entries[] | select(.key != "none") | .value] | add // 0' "$work/refused.json")"
  printf 'location census: %s\n' "$(jq -c '.by_location' "$work/refused.json")"
  [ "$with_blocks" -gt 0 ] || die "pds-pre-gate-papers-check: 0 papers carry a block list — the fetch went blind, not the corpus clean" 99

  printf '\n'
  compare_refused_to_register "$work/refused.json" "$REGISTER"
}

# ── selftest: the comparison, both directions, offline ───────────────────────
run_selftest() {
  need_jq
  local t rc fails=0
  t="$(mktemp -d)" || die "pds-pre-gate-papers-check: mktemp failed" 99

  cat > "$t/register.json" <<'JSON'
{"papers":[{"id":"paper-known-a"},{"id":"paper-known-b"}]}
JSON

  # CASE 1 — every refusal is registered: PASS expected.
  cat > "$t/clean.json" <<'JSON'
{"refused":[{"id":"paper-known-a"},{"id":"paper-known-b"}]}
JSON
  compare_refused_to_register "$t/clean.json" "$t/register.json" > "$t/clean.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then printf 'PASS case 1 (all registered -> exit 0)\n'
  else printf 'FAIL case 1: expected exit 0, got %s\n' "$rc"; cat "$t/clean.out"; fails=$((fails + 1)); fi
  if grep -q 'VERDICT: OK' "$t/clean.out"; then printf 'PASS case 1 verdict line present\n'
  else printf 'FAIL case 1: no VERDICT: OK line\n'; cat "$t/clean.out"; fails=$((fails + 1)); fi

  # CASE 2 — a refusal the register does not name: FAIL expected, and the id
  # must be PRINTED (a door that refuses without naming the row is unactionable).
  cat > "$t/grown.json" <<'JSON'
{"refused":[{"id":"paper-known-a"},{"id":"paper-brand-new"}]}
JSON
  compare_refused_to_register "$t/grown.json" "$t/register.json" > "$t/grown.out" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then printf 'PASS case 2 (unregistered refusal -> exit 1)\n'
  else printf 'FAIL case 2: expected exit 1, got %s\n' "$rc"; cat "$t/grown.out"; fails=$((fails + 1)); fi
  if grep -q 'paper-brand-new' "$t/grown.out"; then printf 'PASS case 2 names the offending id\n'
  else printf 'FAIL case 2: offending id not printed\n'; cat "$t/grown.out"; fails=$((fails + 1)); fi

  # CASE 3 — a registered paper that HEALED: reported, never refused.
  cat > "$t/healed.json" <<'JSON'
{"refused":[{"id":"paper-known-a"}]}
JSON
  compare_refused_to_register "$t/healed.json" "$t/register.json" > "$t/healed.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then printf 'PASS case 3 (healed paper -> exit 0)\n'
  else printf 'FAIL case 3: expected exit 0, got %s\n' "$rc"; cat "$t/healed.out"; fails=$((fails + 1)); fi
  if grep -q 'HEALED' "$t/healed.out"; then printf 'PASS case 3 reports the healed id\n'
  else printf 'FAIL case 3: no HEALED report\n'; cat "$t/healed.out"; fails=$((fails + 1)); fi

  # CASE 4 — the SHIPPED register parses and carries the fields the door reads.
  if [ -r "$REGISTER" ]; then
    if jq -e '.papers | type == "array" and length > 0' "$REGISTER" >/dev/null 2>&1 &&
       jq -e '[.papers[] | has("id") and has("reasons") and has("ruling")] | all' "$REGISTER" >/dev/null 2>&1; then
      printf 'PASS case 4 (shipped register has id/reasons/ruling on every row)\n'
    else
      printf 'FAIL case 4: shipped register %s is missing id/reasons/ruling\n' "$REGISTER"; fails=$((fails + 1))
    fi
  else
    printf 'FAIL case 4: shipped register %s not readable\n' "$REGISTER"; fails=$((fails + 1))
  fi

  printf '\nselftest failures: %s\n' "$fails"
  [ "$fails" -eq 0 ] || return 1
  return 0
}

case "${1:---selftest}" in
  --live) run_live ;;
  --selftest) run_selftest ;;
  --refused-file)
    need_jq
    [ $# -ge 2 ] || die "pds-pre-gate-papers-check: --refused-file needs a path"
    compare_refused_to_register "$2" "$REGISTER"
    ;;
  -h|--help) sed -n '1,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) die "pds-pre-gate-papers-check: unknown argument '$1' (use --live, --refused-file F, or --selftest)" ;;
esac

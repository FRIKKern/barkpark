#!/usr/bin/env bash
# Offline test for full_meta_ok() in scripts/pds-pull-proof.sh — drives the REAL
# predicate against fixture files on disk. No network, no ssh, no guerrilla, no
# scratch target: full_meta_ok reads ONE path ($FULL_TAR) and nothing else.
#
# WHAT IT PINS (PDS-D261 / pds-bl-w16-full-meta-permissive-default)
#
#   THE DEFECT, REPLAYED. full_meta_ok was `[ -s "$FULL_TAR" ]` plus
#   `case "$p" in ""|full) return 0`, with `$p` from manifest_field — which
#   prints the EMPTY STRING on every failure path it has. Measured against
#   origin/main at cd5d861da, these SEVEN shapes were all ACCEPTED as usable
#   full-fidelity bundles:
#
#     an HTML proxy error page (3096 bytes)      ACCEPT   profile=[]
#     a JSON error body (21 bytes)               ACCEPT   profile=[]
#     a gzip that is not a tar                   ACCEPT   profile=[]
#     a 512-byte truncated tar                   ACCEPT   profile=[]
#     a valid tar with no members                ACCEPT   profile=[]
#     a tar carrying manifest.json and no tables  ACCEPT   profile=[full]
#     a tar whose members are all zero bytes      ACCEPT   profile=[]
#
#   Only a 0-byte file and an explicitly non-full profile string were refused.
#   Every arm in the REFUSE group below is one of those shapes.
#
#   THE REASON IS NAMED, NOT SHRUGGED. A refusal must set $FULL_META_WHY to the
#   ONE expectation that failed. Each REFUSE arm asserts a distinctive phrase,
#   so a predicate that starts refusing everything for one blanket reason reds
#   here rather than passing as "stricter".
#
#   IT STILL ACCEPTS A REAL BUNDLE. Two ACCEPT arms: a genuine full-profile
#   bundle, and the LEGACY pre-profile engine (a manifest that parses and simply
#   carries no `profile` key). A predicate that went from always-accepting to
#   always-refusing is the same defect with a new mechanism, and the ACCEPT arms
#   are what make the REFUSE arms mean something.
#
#   NON-VACUITY. On every accept, $FULL_META_WHY must be EMPTY — a predicate
#   that returns 0 while holding a complaint is not deciding, it is guessing.
#
# HOW THE PREDICATE IS REACHED: the script is sourced with PDS_PROOF_LIB=1, its
# own documented library mode (it loads every rung and runs none). Nothing is
# stripped, redefined or copied — the function under test IS the shipped one.
# This harness lives in scripts/ so that the script's own `dirname $0`-derived
# SCRIPT_DIR resolves while sourced.
#
# Exit 0 = all arms pass. Any failure exits 1 and names the arm.
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF="$REPO_ROOT/scripts/pds-pull-proof.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
arms=0
ok()  { arms=$((arms + 1)); printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails + 1)); }

[ -f "$PROOF" ] || { printf 'pds-pull-proof_test: the gate is pointed at nothing — %s does not exist\n' "$PROOF" >&2; exit 1; }

# ── load the REAL script as a library ───────────────────────────────────────
# shellcheck source=scripts/pds-pull-proof.sh
PDS_PROOF_LIB=1 . "$PROOF"
# The script sets `-euo pipefail` at load, and that took effect in THIS shell.
# Leaving -e on would abort the harness at the first refusing arm — i.e. the
# arms would never run and the exit code would come from the predicate rather
# than from the assertions.
set +e
set -uo pipefail

if ! declare -f full_meta_ok >/dev/null 2>&1; then
  printf 'pds-pull-proof_test: full_meta_ok is not defined after sourcing %s — this harness would be testing nothing\n' "$PROOF" >&2
  exit 1
fi
# The predicate must be the SHIPPED one. If it ever stops reading $FULL_TAR this
# whole file becomes a fixture executed by the wrong function.
if ! declare -f full_meta_ok | grep -q 'FULL_TAR'; then
  printf 'pds-pull-proof_test: the sourced full_meta_ok does not mention $FULL_TAR — refusing to run arms against a function this harness cannot identify\n' >&2
  exit 1
fi

FIX="$TMP/fixtures"; mkdir -p "$FIX"

# ── fixture builders ────────────────────────────────────────────────────────
# mk_bundle <name> <manifest-body> [documents.copy body]
# Members are named EXPLICITLY, never `.`: a bundle built with `tar -c .` carries
# `./manifest.json`, and whether `tar -x <tar> manifest.json` matches that member
# differs between bsdtar and GNU tar. The shipped extractor asks for the bare
# names, so these fixtures carry the bare names — otherwise the arms would be
# measuring tar's matching rules on one platform rather than the predicate.
mk_bundle() {
  local name="$1" manifest="$2" docs="${3-}" d="$TMP/build-$1"
  rm -rf "$d"; mkdir -p "$d/tables"
  printf '%s' "$manifest" > "$d/manifest.json"
  if [ "$#" -ge 3 ]; then
    printf '%s' "$docs" > "$d/tables/documents.copy"
    tar -cf "$FIX/$name.tar" -C "$d" manifest.json tables 2>/dev/null
  else
    rmdir "$d/tables"
    tar -cf "$FIX/$name.tar" -C "$d" manifest.json 2>/dev/null
  fi
  printf '%s' "$FIX/$name.tar"
}

# non-tar bodies — exactly what a proxy, a gateway or a truncated download hands back
printf '<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body><h1>502 Bad Gateway</h1><p>%s</p></body></html>' \
  "$(head -c 2900 /dev/zero | tr '\0' 'x')" > "$FIX/html.tar"
printf '{"error":"forbidden"}' > "$FIX/json.tar"
printf 'this is not a tar at all, it is a gzipped sentence' | gzip > "$FIX/gz.tar"
: > "$FIX/zero.tar"

# A tar with NO members at all. `-T /dev/null` is the portable spelling (bsdtar
# and GNU tar both take it); `tar -c .` would carry a `./` entry and be a
# different fixture.
tar -cf "$FIX/no-members.tar" -T /dev/null 2>/dev/null

GOOD="$(mk_bundle good '{"profile":"full","served_sha":"cd5d861da"}' "$(printf 'id\ttype\tdoc_id\n1\tpost\tp1\n')")"
LEGACY="$(mk_bundle legacy '{"served_sha":"cd5d861da","format":"bp-export-v1"}' "$(printf 'id\ttype\tdoc_id\n1\tpost\tp1\n')")"
DEV="$(mk_bundle dev '{"profile":"dev"}' "$(printf 'id\ttype\n1\tpost\n')")"
NOTABLES="$(mk_bundle notables '{"profile":"full"}')"
EMPTYDOCS="$(mk_bundle emptydocs '{"profile":"full"}' '')"
EMPTYMAN="$(mk_bundle emptyman '' "$(printf 'id\n1\n')")"
BADJSON="$(mk_bundle badjson '<html>not json</html>' "$(printf 'id\n1\n')")"
ARRMAN="$(mk_bundle arrman '["profile","full"]' "$(printf 'id\n1\n')")"

head -c 512 "$GOOD" > "$FIX/truncated.tar"

# ── arms ────────────────────────────────────────────────────────────────────
# refuse <arm> <path> <phrase the reason must contain>
refuse() {
  local arm="$1" path="$2" phrase="$3" rc
  FULL_TAR="$path"; FULL_META_WHY="__unset__"
  full_meta_ok; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$arm" "full_meta_ok ACCEPTED $path as a usable FULL bundle. This is the pds-bl-w16 defect: a check that cannot fail on this shape greens the crown off it."
    return
  fi
  case "$FULL_META_WHY" in
    __unset__|"")
      bad "$arm" "refused, but named no expectation — \$FULL_META_WHY is empty. 'Invalid bundle' is a shrug, not a message." ;;
    *"$phrase"*) ok "$arm  — $FULL_META_WHY" ;;
    *) bad "$arm" "refused for the WRONG reason: expected a message containing '$phrase', got: $FULL_META_WHY" ;;
  esac
}

# accept <arm> <path>
accept() {
  local arm="$1" path="$2" rc
  FULL_TAR="$path"; FULL_META_WHY="__unset__"
  full_meta_ok; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$arm" "full_meta_ok REFUSED a bundle it must accept ($path): ${FULL_META_WHY:-<no reason>}. A predicate that went from always-accepting to always-refusing is the same defect with a new mechanism."
    return
  fi
  if [ -n "${FULL_META_WHY//__unset__/}" ]; then
    bad "$arm" "accepted while holding a complaint (\$FULL_META_WHY='$FULL_META_WHY') — a predicate that returns 0 with a reason set is not deciding."
    return
  fi
  ok "$arm"
}

printf 'pds-pull-proof_test: full_meta_ok — REFUSE arms (each was an ACCEPT on origin/main unless marked)\n'
refuse 'non-tar body: HTML 502 proxy page   [ACCEPTED before]' "$FIX/html.tar"      'does not read as a tar archive at all'
refuse 'non-tar body: JSON error payload    [ACCEPTED before]' "$FIX/json.tar"      'does not read as a tar archive at all'
refuse 'gzip that is not a tar (tar-layer)  [ACCEPTED before]' "$FIX/gz.tar"        'What is actually on disk'
refuse 'truncated tar (512 bytes)           [ACCEPTED before]' "$FIX/truncated.tar" 'does not read as a tar archive at all'
refuse 'valid tar, ZERO members             [ACCEPTED before]' "$FIX/no-members.tar" 'lists ZERO members'
refuse 'right names, empty manifest.json    [ACCEPTED before]' "$EMPTYMAN"          'no non-empty manifest.json member'
refuse 'manifest.json is not JSON           [ACCEPTED before]' "$BADJSON"           'not a JSON object'
refuse 'manifest.json is a JSON ARRAY       [ACCEPTED before]' "$ARRMAN"            'not a JSON object'
refuse 'full profile, NO tables member      [ACCEPTED before]' "$NOTABLES"          'no non-empty tables/documents.copy member'
refuse 'full profile, EMPTY documents.copy  [ACCEPTED before]' "$EMPTYDOCS"         'no non-empty tables/documents.copy member'
refuse '0-byte body                         [refused before]'  "$FIX/zero.tar"      'is 0 bytes'
refuse 'absent file                         [refused before]'  "$FIX/does-not-exist.tar" 'there is no file at'
refuse 'dev-profile bundle                  [refused before]'  "$DEV"               'not [full]'

# ── the refusal NAMES WHAT ARRIVED ──────────────────────────────────────────
# A byte count alone cannot separate a proxy error page from a truncated
# download: both are "some bytes that are not a tar". The refusal must carry
# file(1)'s identification AND the size, verbatim, so an operator reading a
# transcript knows which failure they are looking at.
names_what_arrived() { # <arm> <fixture>
  local arm="$1" f="$2" want_kind want_sz
  want_kind="$(file -b "$f" 2>/dev/null | tr -d '\n')"
  # An empty want_kind makes the `case ... *""*` below match ANYTHING — the arm
  # would pass while checking nothing. Fail loud instead of greening vacuously.
  if [ -z "$want_kind" ]; then
    bad "$arm" "file(1) produced no identification for $f, so this arm has nothing to assert against. A vacuous pass here is exactly the failure mode this harness exists to catch — install file(1) or delete this arm deliberately."
    return
  fi
  want_sz="$(wc -c <"$f" | tr -d ' ')"
  FULL_TAR="$f"; FULL_META_WHY=""
  if full_meta_ok; then bad "$arm" "accepted $f — cannot check a refusal that did not happen"; return; fi
  case "$FULL_META_WHY" in
    *"$want_kind"*) ;;
    *) bad "$arm" "the refusal does not name what file(1) sees ('$want_kind') — an operator cannot tell a proxy error page from a truncated download. Got: $FULL_META_WHY"; return ;;
  esac
  case "$FULL_META_WHY" in
    *"$want_sz bytes"*) ok "$arm  — names [$want_kind] at $want_sz bytes" ;;
    *) bad "$arm" "the refusal does not carry the byte count ($want_sz). Got: $FULL_META_WHY" ;;
  esac
}

printf 'pds-pull-proof_test: the refusal identifies WHAT arrived, not just THAT it was wrong\n'
names_what_arrived 'HTML error page is identified as such' "$FIX/html.tar"
names_what_arrived 'a gzip is identified as a gzip'        "$FIX/gz.tar"

# ── manifest_field's THREE return paths ─────────────────────────────────────
# The predicate above is only safe because its reader stopped collapsing two
# different answers into one empty string. Pinned directly, on its own.
mf() { # <arm> <tar> <key> <expected rc> <expected stdout>
  local arm="$1" tar="$2" key="$3" want_rc="$4" want_out="$5" out rc
  out="$(manifest_field "$tar" "$key")"; rc=$?
  out="$(printf '%s' "$out" | tr -d '\n')"
  if [ "$rc" != "$want_rc" ]; then
    bad "$arm" "manifest_field returned rc=$rc, expected $want_rc (stdout='$out'). Collapsing key-absent and unreadable into one code is the PDS-D261 conflation."
    return
  fi
  if [ "$out" != "$want_out" ]; then
    bad "$arm" "manifest_field printed '$out', expected '$want_out' — the stdout contract every existing caller reads must not have moved"
    return
  fi
  ok "$arm  (rc=$rc, stdout='$out')"
}

printf 'pds-pull-proof_test: manifest_field — the exit code distinguishes what the empty string could not\n'
mf 'key PRESENT       -> rc 0 + the value' "$GOOD"       profile 0 full
mf 'key ABSENT        -> rc 1 + empty'     "$LEGACY"     profile 1 ''
mf 'manifest NOT JSON -> rc 2 + empty'     "$BADJSON"    profile 2 ''
mf 'no manifest member-> rc 2 + empty'     "$FIX/no-members.tar" profile 2 ''
mf 'not a tar at all  -> rc 2 + empty'     "$FIX/html.tar"       profile 2 ''

printf 'pds-pull-proof_test: ACCEPT arms — the predicate must still say YES to a real bundle\n'
accept 'a genuine full-profile bundle' "$GOOD"
accept 'the LEGACY pre-profile engine (manifest parses, no profile key)' "$LEGACY"

# ── the reasons must DISCRIMINATE ───────────────────────────────────────────
# A "stricter" predicate that refuses everything with one message is no more
# auditable than one that accepts everything. Four distinct expectations are
# exercised above; four distinct reasons must come back.
reasons=""
# shellcheck disable=SC2034  # FULL_TAR is read by the sourced full_meta_ok
for f in "$FIX/html.tar" "$FIX/no-members.tar" "$BADJSON" "$NOTABLES"; do
  FULL_TAR="$f"; FULL_META_WHY=""
  full_meta_ok || true
  reasons="$reasons$FULL_META_WHY"$'\n'
done
n_distinct="$(printf '%s' "$reasons" | grep -c . )"
n_uniq="$(printf '%s' "$reasons" | sort -u | grep -c . )"
if [ "$n_uniq" -eq 4 ] && [ "$n_distinct" -eq 4 ]; then
  ok "four different malformed shapes yield four DIFFERENT named reasons"
else
  bad "reason-discrimination" "expected 4 distinct reasons across 4 distinct failure modes, got $n_uniq distinct out of $n_distinct"
fi

# ── step 1's TARGET LIFECYCLE-CHECK precondition ────────────────────────────
# (pds-bl-lifecycle-check-precondition)
#
# `grep -c lifecycle_status scripts/pds-pull-proof.sh` returned 0 on origin/main:
# nothing in the ladder asserted that the target's
# documents_task_lifecycle_status_check had been widened from 5 values to 7 by
# PDS-D32's migrations. A pre-widening target therefore died mid-import on a raw
# Postgrex CHECK violation that reads like an import-engine defect.
#
# THE FIXTURES ARE REAL pg_get_constraintdef OUTPUT, not the migration's source.
# Postgres does not echo the DDL back: the migration writes `IN ('open', …)` and
# the catalog prints `= ANY (ARRAY['open'::text, …])`. A matcher written against
# the migration file would look right and match nothing. Both strings below were
# taken verbatim from PostgreSQL 17 after applying the migration's up/0 and
# down/0 bodies to a throwaway database.
LC_WIDE="CHECK (((type <> 'task'::text) OR (NOT (content ? 'lifecycle_status'::text)) OR ((content ->> 'lifecycle_status'::text) = ANY (ARRAY['open'::text, 'in_progress'::text, 'blocked'::text, 'done'::text, 'cancelled'::text, 'considering'::text, 'researching'::text])))) NOT VALID"
LC_NARROW="CHECK (((type <> 'task'::text) OR (NOT (content ? 'lifecycle_status'::text)) OR ((content ->> 'lifecycle_status'::text) = ANY (ARRAY['open'::text, 'in_progress'::text, 'blocked'::text, 'done'::text, 'cancelled'::text]))))"

lc() { # <arm> <constraintdef> <expected missing list>
  local arm="$1" def="$2" want="$3" got
  got="$(lifecycle_missing_values "$def")"
  if [ "$got" = "$want" ]; then ok "$arm  (missing: '${got:-<none>}')"
  else bad "$arm" "lifecycle_missing_values printed '$got', expected '$want'"; fi
}

printf 'pds-pull-proof_test: lifecycle_missing_values — the step-1 precondition (fixtures are real pg_get_constraintdef output)\n'
if ! declare -f lifecycle_missing_values >/dev/null 2>&1; then
  bad 'lifecycle_missing_values is defined' "the sourced harness has no lifecycle_missing_values — step 1 cannot be asserting the target's lifecycle CHECK"
else
  lc 'WIDENED 7-value constraint (NOT VALID, as the migration leaves it) -> nothing missing' "$LC_WIDE"   ''
  lc 'PRE-WIDENING 5-value constraint                -> names BOTH thought states' "$LC_NARROW" 'considering researching'
  lc 'no lifecycle constraint text at all            -> names all seven'           'CHECK (true)' 'open in_progress blocked done cancelled considering researching'
  # THE QUOTES ARE LOAD-BEARING, and this arm is what proves it: an unquoted
  # substring search finds `open` inside `reopened_at` and reports a constraint
  # that does NOT accept 'open' as though it did. Mutating the matcher from
  # *"'$v'"* to *"$v"* reds exactly this arm and nothing else.
  lc 'substring trap: reopened_at must not read as open' \
     "CHECK ((NOT (content ? 'reopened_at'::text)) AND (content ->> 'lifecycle_status'::text) = ANY (ARRAY['in_progress'::text, 'blocked'::text, 'done'::text, 'cancelled'::text, 'considering'::text, 'researching'::text]))" \
     'open'
fi

# ── step 4's maintenance-PG discovery verdict ───────────────────────────────
# (pds-b-proof-instrument-control-auto)
#
# Step 4's positive control used to run only when an operator had exported
# PDS_CONTROL_PG, so the default transcript printed `instrument control: NOT RUN`
# beside a clean scan — the vacuous green PDS-D20 exists to refuse. Discovery
# accepts a candidate on the SERVER's answers, never on the conninfo string, and
# control_pg_verdict is that decision, isolated so every refusal can be driven
# here without a PostgreSQL (this harness stays hermetic: no network, no DB).
cpv() { # <arm> <probe line> <expected rc> <phrase the reason must contain, or '' on accept>
  local arm="$1" line="$2" want_rc="$3" phrase="$4" rc
  CONTROL_PG_WHY="__unset__"
  control_pg_verdict "$line"; rc=$?
  if [ "$rc" != "$want_rc" ]; then
    bad "$arm" "control_pg_verdict returned $rc, expected $want_rc (reason: ${CONTROL_PG_WHY})"
    return
  fi
  if [ "$want_rc" = 0 ]; then
    if [ -n "${CONTROL_PG_WHY//__unset__/}" ]; then
      bad "$arm" "accepted while holding a complaint (\$CONTROL_PG_WHY='$CONTROL_PG_WHY')"
    else ok "$arm"; fi
    return
  fi
  case "$CONTROL_PG_WHY" in
    __unset__|"") bad "$arm" "refused and named nothing — a silent refusal is the NOT RUN this task exists to remove" ;;
    *"$phrase"*)  ok "$arm  — $CONTROL_PG_WHY" ;;
    *) bad "$arm" "refused for the WRONG reason: expected a message containing '$phrase', got: $CONTROL_PG_WHY" ;;
  esac
}

printf 'pds-pull-proof_test: control_pg_verdict — discovery is local-or-nothing, and every refusal is named\n'
if ! declare -f control_pg_verdict >/dev/null 2>&1; then
  bad 'control_pg_verdict is defined' "the sourced harness has no control_pg_verdict — step 4's control is still gated on a hand-set PDS_CONTROL_PG"
else
  SOURCE_PG_DB="${SOURCE_PG_DB:-barkpark_prod}"
  # THE REAL-SHAPE ARM. Every fixture below was hand-written as `t`/`f`, and the
  # verdict passed all of them while REFUSING the only server anyone would point
  # it at: psql prints `boolean::text` as `true`, not `t`. This line is the
  # verbatim output of the shipped probe SQL against PostgreSQL 17 over a unix
  # socket. A fixture set that cannot say what the system actually emits is a
  # green with no subject.
  cpv 'REAL probe output, PostgreSQL 17 over a unix socket -> ACCEPT' 'unix 5432 true postgres' 0 ''
  cpv 'unix socket, may CREATE DATABASE, maintenance db  -> ACCEPT' 'unix 5432 t postgres'      0 ''
  cpv 'the server says false, spelled out                -> refuse' 'unix 5432 false postgres'  1 'cannot CREATE DATABASE'
  cpv 'loopback 127.0.0.1, same otherwise               -> ACCEPT' '127.0.0.1 5432 t postgres' 0 ''
  cpv 'a REMOTE server                                  -> refuse' '10.0.0.5 5432 t postgres'  1 'neither a unix socket nor loopback'
  cpv 'role cannot CREATE DATABASE                      -> refuse' 'unix 5432 f postgres'      1 'cannot CREATE DATABASE'
  cpv 'it landed in the SOURCE PRODUCTION database      -> refuse' "unix 5432 t $SOURCE_PG_DB" 1 'production'
  cpv 'a database merely NAMED like production          -> refuse' 'unix 5432 t app_production' 1 'production'
  cpv 'the probe answered in an unexpected shape        -> refuse' 'unix 5432 t'               1 '4-field shape'
  cpv 'the probe answered nothing at all                -> refuse' ''                          1 '4-field shape'
fi

# ── STEP 8'S CROSS-INVOCATION PIN TRIPLE ────────────────────────────────────
# (pds-bl-step8-cross-invocation-gap)
#
# Step 8's guarantee is PROCESS-LOCAL: DEPLOYED_SHA and DEPLOYED_UPTIME_0A are
# set only by an in-process step 0a, so a run can compare only its OWN 0a
# against its OWN 8. PDS-D101 makes a deferred 3/4 a SECOND full --all
# invocation, so a real transcript can span several, and contiguity ACROSS them
# was a check nothing emitted the inputs for. `pin_triple_line` emits them on
# ONE grep-able line.
#
# THE ARMS MEASURE THE CHAIN, NOT THE FORMAT. A line that prints the right seven
# keys with the WRONG sha bound to sha_8 would pass a field-presence check and
# still make a contiguous pair read as a break — so the last two arms build TWO
# invocations' lines and assert the contiguity verdict both directions.
printf 'pds-pull-proof_test: pin_triple_line — the (0a sha, 8 sha, run tag) triple step 8 emits\n'
if ! declare -f pin_triple_line >/dev/null 2>&1; then
  bad 'pin_triple_line is defined' "the sourced harness has no pin_triple_line — step 8 emits nothing a reader can chain across invocations"
else
  # field extractor over the emitted line, by key — never by position
  ptf() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

  RUN_ID='20260911T000000Z-1111'; RUN_TAG='aaaa1111'
  DEPLOYED_SHA='1111111111111111111111111111111111111111'
  DEPLOYED_SHA_SOURCE='ssh'; DEPLOYED_UPTIME_0A='100'
  line_a="$(pin_triple_line "$DEPLOYED_SHA" '420')"

  case "$line_a" in
    PDS-PIN-TRIPLE\ *) ok 'the line carries the PDS-PIN-TRIPLE prefix, so a reader can grep it out of a transcript' ;;
    *) bad 'the line carries the PDS-PIN-TRIPLE prefix' "got: $line_a" ;;
  esac

  missing=''
  for k in run_tag run_id sha_0a sha_8 uptime_0a uptime_8 pin_source; do
    [ -n "$(ptf "$line_a" "$k")" ] || missing="$missing $k"
  done
  if [ -z "$missing" ]; then ok 'all seven keys are present and non-empty'
  else bad 'all seven keys are present' "empty or absent:$missing — in: $line_a"; fi

  # THE TWO SHAS MUST DIVERGE IN THE FIXTURE, or the arm cannot tell them apart.
  # Every line above passes the SAME sha as both the 0a pin and the re-pin, so a
  # `pin_triple_line` that printed $1 twice would satisfy all of them. This arm
  # is the redeploy shape — step 8's own fail path — where they genuinely differ.
  line_moved="$(pin_triple_line '3333333333333333333333333333333333333333' '')"
  if [ "$(ptf "$line_moved" sha_0a)" = "$DEPLOYED_SHA" ] &&
     [ "$(ptf "$line_moved" sha_8)" = '3333333333333333333333333333333333333333' ]; then
    ok 'when the box redeployed mid-run the line keeps BOTH shas apart: sha_0a is the pin, sha_8 the re-pin'
  else bad 'sha_0a is step 0a'"'"'s pin and sha_8 the re-pin' "sha_0a=$(ptf "$line_moved" sha_0a) (expected $DEPLOYED_SHA), sha_8=$(ptf "$line_moved" sha_8) (expected 3333…)"; fi
  if [ "$(ptf "$line_a" run_tag)" = "$RUN_TAG" ]; then
    ok 'run_tag names the invocation, so the RSS artifact directory is addressable from the same line'
  else bad 'run_tag names the invocation' "run_tag=$(ptf "$line_a" run_tag), RUN_TAG=$RUN_TAG"; fi

  # UNRESOLVED, NOT EMPTY. A step 8 whose SSH re-pin failed must still emit a
  # chainable line; an empty value would collapse the field and shift every
  # later key if a reader ever split on position.
  if [ "$(ptf "$(pin_triple_line '' '')" sha_8)" = 'unresolved' ]; then
    ok 'an unread re-pin prints sha_8=unresolved rather than collapsing the field'
  else bad 'an unread re-pin prints sha_8=unresolved' "got: $(pin_triple_line '' '')"; fi

  # ── THE CONTIGUITY VERDICT, BOTH DIRECTIONS ───────────────────────────────
  # Invocation B starts where A closed: A.sha_8 == B.sha_0a is CONTIGUOUS.
  RUN_ID='20260911T001000Z-2222'; RUN_TAG='bbbb2222'
  DEPLOYED_SHA="$(ptf "$line_a" sha_8)"; DEPLOYED_UPTIME_0A='900'
  line_b="$(pin_triple_line "$DEPLOYED_SHA" '1200')"
  if [ "$(ptf "$line_a" sha_8)" = "$(ptf "$line_b" sha_0a)" ]; then
    ok 'two invocations off the same build chain: A.sha_8 == B.sha_0a'
  else bad 'two invocations off the same build chain' "A.sha_8=$(ptf "$line_a" sha_8) B.sha_0a=$(ptf "$line_b" sha_0a)"; fi

  # THE NEGATIVE CONTROL. A deploy landing in the gap BETWEEN invocations is
  # invisible to both runs' step 8 — and this is the comparison that sees it.
  DEPLOYED_SHA='2222222222222222222222222222222222222222'
  line_c="$(pin_triple_line "$DEPLOYED_SHA" '1200')"
  if [ "$(ptf "$line_a" sha_8)" != "$(ptf "$line_c" sha_0a)" ]; then
    ok 'a deploy in the gap between invocations SHOWS: A.sha_8 != C.sha_0a'
  else bad 'a deploy in the gap between invocations shows' "the chain read as contiguous across two different builds — A.sha_8=$(ptf "$line_a" sha_8) C.sha_0a=$(ptf "$line_c" sha_0a)"; fi
fi

# ── THE RSS PEAK BELONGS TO THE INVOCATION THAT MEASURED IT ─────────────────
# (pds-bl-step8-cross-invocation-gap, criterion 2)
#
# The peak lives in a per-invocation RUN_TAG-keyed artifact directory, so a
# REUSE invocation — 0 attempts, parked bundle — measured nothing at all. It
# used to print the parked .meta verbatim and set no RSS line, which lets a
# reader take the previous run's figure as this run's.
printf 'pds-pull-proof_test: rss_reuse_attribution — a reuse invocation has no RSS of its own\n'
if ! declare -f rss_reuse_attribution >/dev/null 2>&1; then
  bad 'rss_reuse_attribution is defined' "the sourced harness has no rss_reuse_attribution — a reusing invocation says nothing about whose RSS peak the transcript is showing"
else
  FULL_META="$TMP/reuse.meta"
  cat >"$FULL_META" <<'META'
served_sha:     1111111111111111111111111111111111111111
rss_peak_kb:    1638400
run_id:         20260911T000000Z-1111
META
  RUN_ID='20260911T001000Z-2222'; RUN_TAG='bbbb2222'
  att="$(rss_reuse_attribution)"
  case "$att" in
    *'measured NO RSS of its own'*) ok 'a reuse invocation says it measured none' ;;
    *) bad 'a reuse invocation says it measured none' "got: $att" ;;
  esac
  case "$att" in
    *'20260911T000000Z-1111'*) ok 'the sentence names the run that DID measure the peak' ;;
    *) bad 'the sentence names the measuring run' "the parked run_id is absent from: $att" ;;
  esac
  case "$att" in
    *'1638400 KB'*) ok 'the sentence carries the parked peak, so no reader has to open the sidecar' ;;
    *) bad 'the sentence carries the parked peak' "got: $att" ;;
  esac
  # THE ATTRIBUTION IS THE POINT: naming the peak is worthless if the sentence
  # also reads as though THIS run produced it.
  case "$att" in
    *"never to run $RUN_ID"*) ok 'it denies the peak to THIS run by name' ;;
    *) bad 'it denies the peak to this run by name' "got: $att" ;;
  esac
  # An absent sidecar must not print a bare empty figure that reads as 0 MB.
  FULL_META="$TMP/does-not-exist.meta"
  case "$(rss_reuse_attribution)" in
    *'(unknown KB)'*'by run unknown'*) ok 'an unreadable sidecar prints unknown, never an empty figure that reads as zero' ;;
    *) bad 'an unreadable sidecar prints unknown' "got: $(rss_reuse_attribution)" ;;
  esac
fi

# ── THE PROSE THE TRANSCRIPT IS JUDGED ON ───────────────────────────────────
# Three sentences the crown proof's honesty law requires, each pinned by the
# phrase a rewrite would have to keep. A grep, because the claim IS the wording.
printf 'pds-pull-proof_test: the honesty wording these tasks landed\n'
# pds-bl-rss-ambient-caveat: whole-process RSS, banner AND sidecar
if grep -q 'RSS scope — that peak is WHOLE-PROCESS beam.smp RSS over the export' "$PROOF"; then
  ok 'the honesty banner labels the peak WHOLE-PROCESS, not export-exclusive'
else
  bad 'the banner labels the peak WHOLE-PROCESS' "the same beam.smp serves the live content API throughout the export window; a peak printed without that caveat reads as the export's own cost"
fi
if grep -q '^rss_scope: .*WHOLE-PROCESS beam.smp RSS over the export window' "$PROOF"; then
  ok 'the .meta sidecar carries the same scope, so a parked bundle outlives the transcript that explained it'
else
  bad 'the .meta sidecar carries rss_scope' "the sidecar is what the NEXT run reads; a caveat that lives only in this run's banner does not travel with the figure"
fi
# pds-bl-step6-tag-exclusion-stale-comment: tag IS guarded, excluded for scope
if grep -q 'outside the guard$' "$PROOF" || grep -q 'outside the guard entirely' "$PROOF"; then
  bad 'the THE 34 block no longer says `tag` is outside the guard' "PDS-D125/D126 put TagRegistry behind the SAME Tenancy.pulled_schema_row/2 predicate (api/lib/barkpark/content/tag_registry.ex:101); the exclusion is a SCOPING decision and the comment must say so"
else
  ok 'the THE 34 block no longer claims `tag` is written outside the guard'
fi
if grep -q 'It is excluded for SCOPING reasons, not for' "$PROOF"; then
  ok 'the THE 34 block states the real reason `tag` is excluded from the sentinel scope'
else
  bad 'the THE 34 block states why `tag` is excluded' "excluding a now-guarded row is still correct, but the stated reasoning must be the true one"
fi
# pds-bl-step8-cross-invocation-gap: step 8 names the gap it cannot vouch for
if grep -q 'THIS RUNG IS PROCESS-LOCAL and does not claim otherwise' "$PROOF"; then
  ok 'step 8 names the cross-invocation gap it does not vouch for'
else
  bad 'step 8 names the cross-invocation gap' "step 8 has no baseline from any earlier invocation; a PASS that does not say so reads as a whole-transcript guarantee"
fi

# ── the harness is NOT RELOCATABLE, and says so ─────────────────────────────
# (pds-bl-harness-not-relocatable)
#
# The published rehearsal recipe used to be "extract the one file and run it".
# It cannot work: SCRIPT_DIR/REPO_ROOT derive from the invoked path, and
# scripts/lib/bp-curl.sh is SOURCED at load — before argument parsing, before any
# --only gating. This arm RUNS the relocation rather than quoting a remembered
# error, so the header's claim is re-derived on every run instead of ageing.
printf 'pds-pull-proof_test: a bare copy of the harness cannot run, and the header says so\n'
RELOC="$TMP/reloc"; mkdir -p "$RELOC"
cp "$PROOF" "$RELOC/pds-pull-proof.sh"
reloc_out="$(bash "$RELOC/pds-pull-proof.sh" --plan 2>&1)"; reloc_rc=$?
if [ "$reloc_rc" -eq 0 ]; then
  bad 'a relocated copy still fails' "a bare copy at $RELOC/pds-pull-proof.sh exited 0 — if the harness became relocatable the header's recipe is now the wrong one and must be rewritten deliberately, not silently"
else
  case "$reloc_out" in
    *bp-curl.sh*) ok "a relocated copy dies at load (rc=$reloc_rc) — $(printf '%s' "$reloc_out" | head -1)" ;;
    *) bad 'a relocated copy dies at load' "it failed (rc=$reloc_rc) but not at the sourced sibling this header documents. Got: $(printf '%s' "$reloc_out" | head -1)" ;;
  esac
fi
if grep -q 'IT IS NOT RELOCATABLE' "$PROOF"; then
  ok 'the header states the harness is not relocatable'
else
  bad 'the header states the harness is not relocatable' "the file documents a recipe an operator cannot run: nothing in it says the whole scripts/ trio plus a real checkout is required"
fi
if grep -q 'git rev-parse HEAD:scripts/pds-pull-proof.sh' "$PROOF"; then
  ok 'the header verifies the freeze with git rev-parse, by name'
else
  bad 'the header verifies the freeze with git rev-parse' "PDS-D159: the freeze is a recorded BLOB, and only git rev-parse proves the file is it"
fi

printf '\n'

# ── the receipt's own arithmetic is an arm ──────────────────────────────────
# The headline total used to be hand-typed beside a hand-typed breakdown, and a
# wave that added 17 arms typed 58 over a breakdown summing to 57. Nothing local
# caught it: the harness printed a tidy PASS, and the arm-count door in
# api/test/barkpark/pds_pull_proof_test.exs — which counts the REAL `ok` lines —
# was the first reader to notice, in CI, one push later. So the receipt now
# checks itself three ways before it is printed: the breakdown must SUM to the
# declared total, and the declared total must equal the arms this run actually
# printed. A miscount now reds here, in the second it is typed.
ARMS_DECLARED=57
ARMS_BREAKDOWN='13 refuse, 2 accept, 5 manifest_field, 2 identification, 1 discrimination, 4 lifecycle precondition, 10 control-PG verdict, 3 non-relocatable, 7 pin triple, 5 rss attribution, 5 honesty wording'
breakdown_sum="$(printf '%s' "$ARMS_BREAKDOWN" | tr ',' '\n' | awk '{s += $1} END {print s + 0}')"
if [ "$breakdown_sum" -ne "$ARMS_DECLARED" ]; then
  bad 'the receipt adds up' "the declared total is $ARMS_DECLARED but the breakdown sums to $breakdown_sum — one of the two was typed and not counted"
fi
if [ "$arms" -ne "$ARMS_DECLARED" ]; then
  bad 'the receipt counts the arms this run printed' "the receipt declares $ARMS_DECLARED arms; this run printed $arms ok line(s). Update BOTH the total and the breakdown category you changed, in the same commit as the arm."
fi

if [ "$fails" -eq 0 ]; then
  printf 'pds-pull-proof_test: PASS (%s arms: %s)\n' "$ARMS_DECLARED" "$ARMS_BREAKDOWN"
  exit 0
fi
printf 'pds-pull-proof_test: FAIL — %s arm(s)\n' "$fails"
exit 1

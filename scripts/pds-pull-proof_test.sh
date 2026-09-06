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
ok()  { printf '  ok   %s\n' "$1"; }
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
refuse 'non-tar body: HTML 502 proxy page   [ACCEPTED before]' "$FIX/html.tar"      'not a readable tar archive'
refuse 'non-tar body: JSON error payload    [ACCEPTED before]' "$FIX/json.tar"      'not a readable tar archive'
refuse 'gzip that is not a tar              [ACCEPTED before]' "$FIX/gz.tar"        'not a readable tar archive'
refuse 'truncated tar (512 bytes)           [ACCEPTED before]' "$FIX/truncated.tar" 'not a readable tar archive'
refuse 'valid tar, no members               [ACCEPTED before]' "$FIX/no-members.tar" 'no non-empty manifest.json member'
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

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'pds-pull-proof_test: PASS (23 arms: 13 refuse, 2 accept, 5 manifest_field, 2 identification, 1 discrimination)\n'
  exit 0
fi
printf 'pds-pull-proof_test: FAIL — %s arm(s)\n' "$fails"
exit 1

#!/usr/bin/env bash
#
# pds-personal-local-smoke_test.sh — the COLD-READER smoke for
# docs/setup/personal-local.md (pds-bl-personal-local-doc-staleness, c2).
#
#   scripts/pds-personal-local-smoke_test.sh            the --dry-run arm (default)
#   scripts/pds-personal-local-smoke_test.sh --dry-run  resolve every step against
#                                                       the doc and PRINT the plan;
#                                                       boots nothing, calls nothing
#   scripts/pds-personal-local-smoke_test.sh --boot     actually walk it on this host
#
# WHAT IT PROVES, AND WHY IT IS SHAPED THIS WAY
# ---------------------------------------------
# The row this pays says the setup guide omitted five run-proven first-boot
# traps. The repair for a STALE DOC cannot be a script that knows the recipe
# independently — that script would stay green while the doc rotted, which is
# the exact failure it exists to catch. So EVERY step here is DERIVED FROM THE
# DOC AT RUN TIME: each step names a literal anchor, the anchor is located in
# docs/setup/personal-local.md, and the step PRINTS `doc:<line>: <text>` before
# it runs. Delete the sentence from the doc and this harness REDS — in the
# --dry-run arm, with no boot at all.
#
# That is also why the --dry-run arm is the one wired into CI: it is the
# doc-drift ratchet, it is hermetic (one file read, no mix, no Postgres, no
# network, no credential) and it costs milliseconds. The --boot arm is a LOCAL
# proof; a shared runner has no Postgres toolchain and one boot at a time is a
# host-level constraint, not a CI-shaped one.
#
# ISOLATION IS BORROWED, NOT RE-DERIVED. scripts/pds-scratch-target.sh already
# encodes the working recipe (free ports that avoid 5432/5433/4000, the ~85-char
# socket-path assert, the /tmp-symlink canonicalisation, the real-CC pin). This
# file SOURCES it for those helpers rather than writing its own copies. It is
# sourced with `--help` so the dispatch at its foot takes the help arm and boots
# NOTHING; if that ever stops being true the `declare -F` interlock below fails
# CLOSED rather than letting a half-loaded library run a boot.
#
# EXIT: 0 every step passed · 1 a step failed (or a doc anchor is gone) · 2 usage.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
DOC_REL="docs/setup/personal-local.md"
DOC="$REPO_ROOT/$DOC_REL"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*"; }

# ── the doc is the spec: resolve a step's anchor or RED ──────────────────────
#
# grep -n -F -m1 on a LITERAL. Never a regex: a regex that silently stops
# matching after a reflow would turn this ratchet off without saying so.
doc_line() { # $1 = literal anchor
  local n
  n="$(grep -n -F -m1 -- "$1" "$DOC" 2>/dev/null | cut -d: -f1)"
  if [ -z "$n" ]; then
    bad "$DOC_REL no longer contains: $1"
    return 1
  fi
  printf '  %s:%s: %s\n' "$DOC_REL" "$n" "$(sed -n "${n}p" "$DOC")"
  return 0
}

# Every step's anchor, in walk order. `<step>|<anchor>` — one pair per line, so
# the plan the dry-run prints and the steps the boot arm runs cannot drift apart.
ANCHORS='S1 dependency bootstrap|cd api && mix deps.get && cd ..
S2 compiler selection|CC=/usr/bin/clang bin/barkpark up
S2 compiler selection (the failure signature)|gcc and make installed
S3 KEK flag|BARKPARK_KEK
S3 bundle-import flag|BARKPARK_ALLOW_BUNDLE_IMPORT
S4 media directory|BARKPARK_MEDIA_DIR
S5 token creation|bin/barkpark token
S6 first pull (blob push)|PUT /api/workspaces/:workspace_slug/media/blob/*path
S7 teardown|`barkpark stop`
GUARD short $BARKPARK_HOME|under ~85 chars
GUARD never pipe up|Never pipe `up` into `tail`/`head`'

# NOT a pipe into `while`: bash 3.2 has no lastpipe, so a piped loop runs in a
# SUBSHELL and every PASS/FAIL it counts is discarded when the subshell exits.
# The first cut of this file did exactly that and printed `0 passed, 0 failed`
# over a MISSING anchor — a vacuous green produced by the plumbing, not the
# subject. Redirect from a file so the loop runs in THIS shell.
resolve_plan() {
  local label anchor n=0
  printf '%s\n' "$ANCHORS" > "$PLAN_OUT"
  while IFS='|' read -r label anchor; do
    [ -n "$label" ] || continue
    printf '%s\n' "$label"
    if doc_line "$anchor"; then n=$((n+1)); PASS=$((PASS+1)); fi
  done < "$PLAN_OUT"
  printf '  %s of %s doc anchor(s) resolved\n' "$n" "$(grep -c . "$PLAN_OUT")"
  [ "$FAIL" -eq 0 ]
}

cmd_dry_run() {
  printf 'pds-personal-local-smoke: DRY RUN — the plan, derived from %s. Nothing is booted.\n' "$DOC_REL"
  step 'THE PLAN (each step beside the doc line it derives from)'
  resolve_plan

  step 'the subjects this plan will drive exist'
  [ -x "$REPO_ROOT/bin/barkpark" ] && ok 'bin/barkpark is executable' || bad 'bin/barkpark missing or not executable'
  [ -x "$REPO_ROOT/bin/barkpark-pg" ] && ok 'bin/barkpark-pg is executable' || bad 'bin/barkpark-pg missing or not executable'
  [ -f "$SCRIPT_DIR/pds-scratch-target.sh" ] && ok 'scripts/pds-scratch-target.sh (the isolation library) is present' \
    || bad 'scripts/pds-scratch-target.sh is gone — this harness borrows its helpers'

  step 'the --boot arm is reachable from here (library loads, helpers defined)'
  load_library && ok 'pds-scratch-target.sh sourced via --help; free_port/assert_short_home/export_real_cc/canonicalize_path defined' \
    || bad 'the isolation library did not load its helpers — the boot arm would run half-armed'
  return 0
}

# Source the isolation library WITHOUT letting its dispatch boot anything, then
# prove the four helpers this file actually calls are defined. A silent
# half-load is the one failure that would let `--boot` pick a busy port.
load_library() {
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/pds-scratch-target.sh" --help >/dev/null 2>&1 || true
  local f
  for f in free_port assert_short_home export_real_cc canonicalize_path port_in_use; do
    declare -F "$f" >/dev/null 2>&1 || { printf '  (missing helper: %s)\n' "$f" >&2; return 1; }
  done
  set +e   # the library sets -e; this harness counts failures instead of dying on one
  return 0
}

cmd_boot() {
  cmd_dry_run
  [ "$FAIL" -eq 0 ] || { echo "pds-personal-local-smoke: the plan did not resolve — REFUSING to boot" >&2; return 1; }

  step 'BOOT ARM — walking the doc on this host'
  load_library || { bad 'library did not load'; return 1; }

  local home port pg_port media boot_log tok_log ws=default
  home="$(canonicalize_path "${PDS_SMOKE_HOME:-$(mktemp -d /tmp/pds-pl.XXXX)}")"
  mkdir -p "$home"
  assert_short_home "$home"      # doc: keep $BARKPARK_HOME under ~85 chars
  port="$(free_port)"; pg_port="$(free_port "$port")"
  media="$home/media"; mkdir -p "$media"
  boot_log="$home/up.log"; tok_log="$home/token.log"
  printf '  root=%s  PORT=%s  BARKPARK_PG_PORT=%s  BARKPARK_MEDIA_DIR=%s\n' "$home" "$port" "$pg_port" "$media"

  export BARKPARK_HOME="$home" PORT="$port" BARKPARK_PG_PORT="$pg_port" BARKPARK_MEDIA_DIR="$media"

  step 'S1 dependency bootstrap — `cd api && mix deps.get && cd ..`'
  ( cd "$REPO_ROOT/api" && mix deps.get ) >"$home/deps.log" 2>&1
  if [ -d "$REPO_ROOT/api/deps/argon2_elixir" ]; then ok 'api/deps populated (argon2_elixir present)'
  else bad 'mix deps.get did not populate api/deps — see '"$home/deps.log"; fi

  step 'S2 compiler selection — `CC=/usr/bin/clang`'
  export_real_cc
  if [ "${CC:-}" = /usr/bin/clang ]; then ok 'CC pinned to /usr/bin/clang'
  else bad "CC is '${CC:-unset}', not /usr/bin/clang — the argon2 NIF will die on a cc shim"; fi

  step 'S2b boot — `bin/barkpark up`, NEVER piped (doc trap)'
  # Redirected to a FILE on purpose: the doc's trap is about a PIPE's write end,
  # which a detached daemon inherits and never closes.
  "$REPO_ROOT/bin/barkpark" up >"$boot_log" 2>&1
  local up_rc=$?
  if [ "$up_rc" -eq 0 ]; then ok "bin/barkpark up exited 0 (log: $boot_log)"
  else bad "bin/barkpark up exited $up_rc — tail: $(tail -3 "$boot_log" | tr '\n' ' ')"; fi

  step 'S3 KEK / bundle-import flags in $BARKPARK_HOME/.env'
  if grep -q '^BARKPARK_KEK=' "$home/.env" 2>/dev/null; then ok 'BARKPARK_KEK written'
  else bad 'BARKPARK_KEK absent from .env — :prod raises without it'; fi
  if grep -q '^BARKPARK_ALLOW_BUNDLE_IMPORT=1' "$home/.env" 2>/dev/null; then ok 'BARKPARK_ALLOW_BUNDLE_IMPORT=1 written'
  else bad 'BARKPARK_ALLOW_BUNDLE_IMPORT=1 absent from .env'; fi
  # GNU FIRST, BSD second — never the reverse. On GNU coreutils `-f` means
  # FILESYSTEM status, so `stat -f %s` SUCCEEDS on Linux with a block-count
  # report instead of failing, and a BSD-first `||` chain never reaches the
  # GNU form. BSD stat rejects `-c` outright, so GNU-first fails loudly on
  # the wrong platform instead of quietly.
  local mode; mode="$(stat -c '%a' "$home/.env" 2>/dev/null || stat -f '%Lp' "$home/.env" 2>/dev/null)"
  if [ "$mode" = 600 ]; then ok '.env is chmod 0600'; else bad ".env mode is '$mode', doc says 0600"; fi

  step 'S5 token creation — `bin/barkpark token`'
  "$REPO_ROOT/bin/barkpark" token >"$tok_log" 2>&1
  local tok; tok="$(grep -oE 'bp_admin_[A-Za-z0-9_-]+' "$tok_log" | head -1)"
  if [ -n "$tok" ]; then ok "an admin credential was minted (${#tok} chars, bp_admin_…)"
  else bad "no bp_admin_ token in $tok_log — /studio has no key"; fi

  # THE SILENT-SKIP ARM. The doc used to promise only that a re-run "is safe".
  # A cold reader who lost the key re-runs it, sees `minting the admin
  # credential` and exit 0, and gets NOTHING. That is the behaviour the doc now
  # states, so it is the behaviour this harness pins.
  "$REPO_ROOT/bin/barkpark" token >"$home/token2.log" 2>&1
  if grep -q 'bp_admin_' "$home/token2.log"; then
    bad 're-running `token` minted a SECOND key beside a live one — the doc says the seed skips'
  elif grep -q 'minting the admin credential' "$home/token2.log"; then
    ok 're-run announces "minting the admin credential", exits 0, prints no token — the documented silent skip'
  else bad "re-run of \`token\` printed neither a token nor the minting line — $home/token2.log"; fi

  step 'S4 media directory + S6 first pull (blob push)'
  local base="http://localhost:$port" code
  printf 'pds-smoke\n' > "$home/probe.bin"
  # CONTROL: no Content-Type. The doc says this 422s `empty_body` — an arm that
  # only ever pushes successfully cannot tell a working route from a stub.
  code="$(curl -s -o "$home/c1.json" -w '%{http_code}' -X PUT -H "Authorization: Bearer $tok" \
          --data-binary @"$home/probe.bin" "$base/api/workspaces/$ws/media/blob/smoke/probe.bin")"
  if [ "$code" = 422 ] && grep -q 'empty_body' "$home/c1.json"; then ok 'blob PUT without octet-stream 422s empty_body (control)'
  else bad "blob PUT without a Content-Type returned $code, doc says 422 empty_body"; fi
  # CONTROL: no credential at all.
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/octet-stream' \
          --data-binary @"$home/probe.bin" "$base/api/workspaces/$ws/media/blob/smoke/probe.bin")"
  if [ "$code" = 401 ]; then ok 'blob PUT with no token 401s (the route is admin-gated)'
  else bad "blob PUT with no token returned $code, expected 401"; fi
  # THE PUSH.
  code="$(curl -s -o "$home/push.json" -w '%{http_code}' -X PUT -H "Authorization: Bearer $tok" \
          -H 'Content-Type: application/octet-stream' --data-binary @"$home/probe.bin" \
          "$base/api/workspaces/$ws/media/blob/smoke/probe.bin")"
  if [ "$code" = 200 ]; then ok "blob push 200 — $(tr -d '\n' < "$home/push.json")"
  else bad "blob push returned $code — $(head -c 200 "$home/push.json")"; fi
  # AND THE MEDIA DIRECTORY IS THE OVERRIDE'S, NOT THE CHECKOUT'S. The doc's
  # default is `api/uploads` INSIDE the tree, so a run that ignored
  # BARKPARK_MEDIA_DIR would still 200 while writing into the worktree.
  if [ -f "$media/smoke/probe.bin" ]; then ok "the blob landed under \$BARKPARK_MEDIA_DIR ($media/smoke/probe.bin)"
  else bad "the blob is not under \$BARKPARK_MEDIA_DIR — BARKPARK_MEDIA_DIR was ignored"; fi
  if [ -e "$REPO_ROOT/api/uploads/smoke/probe.bin" ]; then bad 'the blob ALSO landed in the checkout api/uploads'
  else ok 'nothing was written into the checkout api/uploads'; fi

  step 'S7 teardown — `bin/barkpark stop`'
  "$REPO_ROOT/bin/barkpark" stop >"$home/stop.log" 2>&1
  if port_in_use "$port"; then bad "port $port still LISTENing after stop"; else ok "HTTP port $port released"; fi
  if port_in_use "$pg_port"; then bad "Postgres port $pg_port still LISTENing after stop"; else ok "Postgres port $pg_port released"; fi
  printf '  scratch root left standing for inspection: %s\n' "$home"
  return 0
}

# PORTABLE mktemp, AND a hard failure. `mktemp -t NAME` with no XXXXXX is a
# BSD-only form: GNU coreutils (every ubuntu CI runner) refuses it. This site
# used to swallow that refusal — $(...) yielded "", every redirect below wrote
# to the empty filename, resolve_plan grepped nothing, and the run reported
# "0 of  doc anchor(s) resolved" while its ARM went green. An mktemp refusal is
# now a named, fatal error; it must never be survivable.
PLAN_OUT="$(mktemp "${TMPDIR:-/tmp}/pds-pl-plan.XXXXXX")" || {
  echo "pds-personal-local-smoke: REFUSING — mktemp failed for the plan file" >&2; exit 2; }
PLAN_ERR="$(mktemp "${TMPDIR:-/tmp}/pds-pl-planerr.XXXXXX")" || {
  echo "pds-personal-local-smoke: REFUSING — mktemp failed for the plan error file" >&2; exit 2; }
[ -n "$PLAN_OUT" ] && [ -n "$PLAN_ERR" ] || {
  echo "pds-personal-local-smoke: REFUSING — mktemp returned an EMPTY path" >&2; exit 2; }
trap 'rm -f "$PLAN_OUT" "$PLAN_ERR"' EXIT

case "${1:---dry-run}" in
  --dry-run|dry-run|"") cmd_dry_run ;;
  --boot|boot)          cmd_boot ;;
  -h|--help|help)       sed -n '3,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "usage: pds-personal-local-smoke_test.sh [--dry-run|--boot]" >&2; exit 2 ;;
esac

# THE TALLY IS THE VERDICT, and it is derived from the counters, never from the
# last command's exit code: a dry run that resolved nothing at all must not be
# able to exit 0 on an empty tally.
printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
if [ "$PASS" -eq 0 ]; then
  echo "pds-personal-local-smoke: REFUSING — zero checks ran; an empty tally is not a pass" >&2
  exit 1
fi
[ "$FAIL" -eq 0 ]

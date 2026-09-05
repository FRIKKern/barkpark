#!/usr/bin/env bash
# doctor.test.sh — behavioral regression for scripts/doctor.sh SECTION 2
# (installed-bp staleness). This is the harness that proves the compare-target
# is origin/main via merge-base, not local HEAD — the false-green that shipped
# twice in one week (regex #5935, then compare-target).
#
# WHY A DEDICATED HARNESS AND NOT upgrade_test.go: the Go
# TestDoctorReleaseCadence fixture has NO fake `bp` on PATH and NO merge-base
# stub, so its fixture takes the `else` (no-bp) branch and NEVER
# exercises section 2. Copying it verbatim reproduces the blind spot one level
# down. So this harness builds REAL git repos (bare origin.git + working clone)
# and puts a REAL fake `bp` on PATH that emits {"commit":"<sha>"} — the only way
# to drive section 2's cat-file / rev-parse / merge-base / diff ladder.
#
# The full 11-cell verdict matrix (the flip-risk surface):
#   1. at-tip                → GREEN  (bp commit == origin/main tip)
#   2. behind-Go             → RED    (Go input changed on origin/main since bp)
#   3. behind-docs-only      → GREEN  (only non-Go paths changed since bp)
#   4. ahead-with-local-Go   → GREEN  (bp ahead; merge-base==origin/main tip)
#   5. diverged              → RED    (off origin/main's history — its OWN
#                                      sentence; remedy is a rebase, not a rebuild)
#   6. unknown-commit        → SKIP   (bp commit absent from the checkout)
#   7. no-stamp              → RED    (bp built without -ldflags: no commit)
#   8. offline / no ref      → SKIP   (origin/main ref unavailable — LOUD, not ok)
#   9. behind vs diverged    → the two RED sentences must DIFFER (W34 S2)
#  10. exit code             → still 0: doctor is advisory, never a gate
#  11. no bp on PATH         → LOUD under --hook (not a silent skip), exit 0
#
# Templated on scripts/install-cli.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$HERE/doctor.sh"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

# ── assertion helpers ────────────────────────────────────────────────────────
# A section-2 outcome line always starts with "installed bp". We must NOT let
# section 1's "checkout is current with origin/main" (same tail!) satisfy a
# section-2 green assertion — so a green check requires a line that carries BOTH
# "installed bp" AND "is current".
# NB: here-strings, not `printf | grep -q`. `grep -q` closes its input on the
# first match; under `set -o pipefail` that SIGPIPEs the upstream printf and the
# pipeline returns 141 (a size-dependent false negative). A here-string has no
# upstream writer to kill, so the match verdict is the ONLY thing that matters.
sec2_green()    { grep -qE 'installed bp .*is current with origin/main' <<<"$1"; }
sec2_red()      { grep -qF 'predates Go changes on origin/main' <<<"$1"; }
# The DIVERGED rung is its own sentence, never the "predates" one: a binary off
# origin/main's history does not predate main, and its remedy is a rebase — a
# rebuild from the same checkout reinstalls the same off-history binary.
sec2_diverged() { grep -qF 'is DIVERGED from origin/main' <<<"$1"; }
has()           { grep -qF "$2" <<<"$1"; }

# assert_green <name> <output>  — section 2 says current, and says nothing stale
assert_green() {
  if sec2_green "$2" && ! sec2_red "$2"; then pass "$1"; else
    fail "$1"; printf '    --- doctor output ---\n%s\n    ---------------------\n' "$2"; fi
}
# assert_red <name> <output>  — section 2 flags stale (BEHIND), does NOT green,
# and does NOT reach for the diverged sentence: a pure-behind binary really does
# predate main, and saying "diverged" there would be the mirror of the bug.
assert_red() {
  if sec2_red "$2" && ! sec2_green "$2" && ! sec2_diverged "$2"; then pass "$1"; else
    fail "$1"; printf '    --- doctor output ---\n%s\n    ---------------------\n' "$2"; fi
}
# assert_diverged <name> <output>  — section 2 flags DIVERGED, does NOT green,
# and does NOT print the (false) "predates" sentence.
assert_diverged() {
  if sec2_diverged "$2" && ! sec2_green "$2" && ! sec2_red "$2"; then pass "$1"; else
    fail "$1"; printf '    --- doctor output ---\n%s\n    ---------------------\n' "$2"; fi
}
# assert_has <name> <output> <substr>  — an exact skip/red string is present …
assert_has() {
  if has "$2" "$3"; then pass "$1"; else
    fail "$1 (missing: $3)"; printf '    --- doctor output ---\n%s\n    ---------------------\n' "$2"; fi
}
# … and section 2 must be neither green nor a stale RED (a clean SKIP).
assert_clean_skip() {
  if ! sec2_green "$2" && ! sec2_red "$2" && ! sec2_diverged "$2"; then pass "$1"; else
    fail "$1 (leaked a green/red verdict)"; printf '    --- doctor output ---\n%s\n    ---------------------\n' "$2"; fi
}

# ── fixtures ────────────────────────────────────────────────────────────────
GIT="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"

# make_bp <bindir> <sha-or-empty> — a fake bp that emits the ldflags-style JSON
# doctor.sh parses. Empty sha ⇒ no "commit" field (the no-stamp cell).
make_bp() {
  local bindir="$1" sha="$2"
  mkdir -p "$bindir"
  if [ -n "$sha" ]; then
    cat > "$bindir/bp" <<EOF
#!/bin/sh
[ "\$1" = version ] && { printf '{"cli_version":"test","commit": "%s"}\n' "$sha"; exit 0; }
exit 0
EOF
  else
    cat > "$bindir/bp" <<'EOF'
#!/bin/sh
[ "$1" = version ] && { echo '{"cli_version":"test"}'; exit 0; }
exit 0
EOF
  fi
  chmod +x "$bindir/bp"
}

# base_repo <root> — a real clone whose origin/main tracking ref exists at a base
# commit "A" carrying a Go file, deploy.sh, and a docs file. Echoes the work dir.
base_repo() {
  local root="$1" origin="$1/origin.git" work="$1/work"
  $GIT init --quiet --bare "$origin"
  $GIT init --quiet "$work"
  $GIT -C "$work" symbolic-ref HEAD refs/heads/main
  $GIT -C "$work" remote add origin "$origin"
  mkdir -p "$work/scripts" "$work/internal/cli/setup/assets"
  cp "$DOCTOR" "$work/scripts/doctor.sh"
  printf 'echo deploy v1\n' > "$work/deploy.sh"
  cp "$work/deploy.sh" "$work/internal/cli/setup/assets/deploy.sh"   # keep §4 quiet
  printf 'package main\n\nfunc main() {}\n' > "$work/main.go"
  printf 'docs v1\n' > "$work/README.md"
  $GIT -C "$work" add -A
  $GIT -C "$work" commit --quiet -m A
  $GIT -C "$work" push --quiet -u origin main 2>/dev/null
  $GIT -C "$work" fetch --quiet origin 2>/dev/null
  echo "$work"
}

# advance_origin <work> <file> <content> <msg> — commit on main and publish it to
# origin/main (a change the installed bp predates).
advance_origin() {
  local work="$1"
  printf '%s\n' "$3" > "$work/$2"
  $GIT -C "$work" add -A
  $GIT -C "$work" commit --quiet -m "$4"
  $GIT -C "$work" push --quiet origin main 2>/dev/null
  $GIT -C "$work" fetch --quiet origin 2>/dev/null
}

run_doctor() { # <work> <bindir> — full doctor output, fake bp shadowing real bp
  env PATH="$2:$PATH" BARKPARK_RELEASES_API_URL="https://example.invalid/releases" \
    /bin/bash "$1/scripts/doctor.sh" 2>&1
}

# ════════════════════════════════════════════════════════════════════════════
echo "== doctor.sh section 2 — 11-cell verdict matrix =="

# ── 1. at-tip → GREEN ────────────────────────────────────────────────────────
R1="$TMP/c1"; mkdir -p "$R1"; W1="$(base_repo "$R1")"
A1="$($GIT -C "$W1" rev-parse HEAD)"
make_bp "$R1/bin" "$A1"
assert_green "1. at-tip: bp == origin/main is GREEN" "$(run_doctor "$W1" "$R1/bin")"

# ── 2. behind-Go → RED ───────────────────────────────────────────────────────
R2="$TMP/c2"; mkdir -p "$R2"; W2="$(base_repo "$R2")"
A2="$($GIT -C "$W2" rev-parse HEAD)"                 # bp built here …
advance_origin "$W2" main.go 'package main // v2' 'B: go change'   # … origin moved on
make_bp "$R2/bin" "$A2"
assert_red "2. behind-Go: origin/main gained a .go change → RED" "$(run_doctor "$W2" "$R2/bin")"

# ── 3. behind-docs-only → GREEN ──────────────────────────────────────────────
R3="$TMP/c3"; mkdir -p "$R3"; W3="$(base_repo "$R3")"
A3="$($GIT -C "$W3" rev-parse HEAD)"
advance_origin "$W3" README.md 'docs v2' 'C: docs only'
make_bp "$R3/bin" "$A3"
assert_green "3. behind-docs-only: no Go input changed → GREEN" "$(run_doctor "$W3" "$R3/bin")"

# ── 4. ahead-with-local-Go → GREEN ───────────────────────────────────────────
# bp built at a LOCAL commit D ahead of origin/main (unpushed Go work). merge-base
# (D, origin/main) == origin/main tip, so the diff is empty. A bare
# `git diff BP_COMMIT origin/main` would FALSE-RED this — the flip that D1 forbids.
R4="$TMP/c4"; mkdir -p "$R4"; W4="$(base_repo "$R4")"
printf 'package main // local ahead\n' > "$W4/main.go"
$GIT -C "$W4" add -A; $GIT -C "$W4" commit --quiet -m 'D: local unpushed go'   # NOT pushed
D4="$($GIT -C "$W4" rev-parse HEAD)"
make_bp "$R4/bin" "$D4"
assert_green "4. ahead-with-local-Go: merge-base==tip → GREEN (not false-red)" "$(run_doctor "$W4" "$R4/bin")"

# ── 5. diverged → RED, in its OWN sentence ───────────────────────────────────
# origin/main advanced with a Go change (B); bp built on a sibling commit E off
# the common ancestor A. Neither commit contains the other, so this binary does
# not PREDATE main — it carries a commit main has never seen, and `make
# cli-install` would rebuild from this same checkout and reinstall it. Before
# W34 S2 this cell printed the identical "predates Go changes" string as cell 2.
R5="$TMP/c5"; mkdir -p "$R5"; W5="$(base_repo "$R5")"
advance_origin "$W5" main.go 'package main // v2 diverge' 'B: go change on main'
$GIT -C "$W5" checkout --quiet -b diverge "$($GIT -C "$W5" rev-list --max-parents=0 HEAD | tail -1)"
printf 'docs on a divergent branch\n' > "$W5/README.md"
$GIT -C "$W5" add -A; $GIT -C "$W5" commit --quiet -m 'E: divergent sibling'
E5="$($GIT -C "$W5" rev-parse HEAD)"
make_bp "$R5/bin" "$E5"
OUT5="$(run_doctor "$W5" "$R5/bin")"
assert_diverged "5. diverged: off origin/main's history → RED, not 'predates'" "$OUT5"
assert_has "5. diverged: the remedy is a rebase, not a rebuild" "$OUT5" "run: git pull --rebase"

# ── 6. unknown-commit → SKIP ─────────────────────────────────────────────────
R6="$TMP/c6"; mkdir -p "$R6"; W6="$(base_repo "$R6")"
make_bp "$R6/bin" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"   # not in the checkout
OUT6="$(run_doctor "$W6" "$R6/bin")"
assert_has        "6. unknown-commit: loud skip line present" "$OUT6" "bp build commit not in this checkout"
assert_clean_skip "6. unknown-commit: no green/red verdict leaked" "$OUT6"

# ── 7. no-stamp → RED ────────────────────────────────────────────────────────
R7="$TMP/c7"; mkdir -p "$R7"; W7="$(base_repo "$R7")"
make_bp "$R7/bin" ""   # bp version emits no "commit" field
assert_has "7. no-stamp: loud RED for unstamped bp" "$(run_doctor "$W7" "$R7/bin")" \
  "installed bp has NO build-commit stamp"

# ── 8. offline / no origin/main ref → SKIP ───────────────────────────────────
# A repo with a commit bp CAN resolve (cat-file passes) but NO origin/main ref.
# The bare merge-base form false-greens here; ours must LOUD-skip.
R8="$TMP/c8"; mkdir -p "$R8"; W8="$R8/work"
$GIT init --quiet "$W8"; $GIT -C "$W8" symbolic-ref HEAD refs/heads/main
mkdir -p "$W8/scripts"; cp "$DOCTOR" "$W8/scripts/doctor.sh"
printf 'echo deploy\n' > "$W8/deploy.sh"; printf 'package main\n' > "$W8/main.go"
$GIT -C "$W8" add -A; $GIT -C "$W8" commit --quiet -m A
A8="$($GIT -C "$W8" rev-parse HEAD)"     # exists → cat-file passes; no origin/main
make_bp "$R8/bin" "$A8"
OUT8="$(run_doctor "$W8" "$R8/bin")"
# Assert on the section-2-UNIQUE tail, not the bare "origin/main ref unavailable"
# — section 1b's release-cadence skip carries that same phrase and would false-pass.
assert_has        "8. offline: LOUD skip when origin/main is unavailable" "$OUT8" "bp staleness check skipped"
assert_clean_skip "8. offline: no green/red verdict leaked" "$OUT8"

# ── 9. behind vs diverged print DIFFERENT sentences ──────────────────────────
# The point of the whole slice, asserted directly rather than inferred from two
# helpers agreeing: run the SAME doctor over cell 2 (behind) and cell 5
# (diverged) and require the section-2 problem lines to differ. A regression
# that re-collapses the two rungs into one string fails HERE even if both cells
# still "RED".
OUT2="$(run_doctor "$W2" "$R2/bin")"
LINE2="$(grep -F 'installed bp (' <<<"$OUT2" | head -1)"
LINE5="$(grep -F 'installed bp (' <<<"$OUT5" | head -1)"
# Strip the commit sha, which differs per fixture for reasons unrelated to the
# rung: what must differ is the SENTENCE.
S2="$(sed 's/(.*)//' <<<"$LINE2")"; S5="$(sed 's/(.*)//' <<<"$LINE5")"
if [ -n "$S2" ] && [ -n "$S5" ] && [ "$S2" != "$S5" ]; then
  pass "9. behind and diverged print DIFFERENT sentences"
else
  fail "9. behind and diverged print the SAME sentence (the W34 S2 defect)"
  printf '    behind:   %s\n    diverged: %s\n' "$LINE2" "$LINE5"
fi
# And the remedies differ in kind: a rebuild for behind, a rebase for diverged.
assert_has "9. behind still prescribes the rebuild" "$LINE2" "run: make cli-install"
if grep -qF 'run: git pull --rebase' <<<"$LINE2"; then
  fail "9. the behind remedy must not become a rebase"
else
  pass "9. behind is not given the rebase remedy"
fi

# ── exit code: doctor is ADVISORY and stays advisory ─────────────────────────
# Every RED above went through `bad`, which counts a problem and never exits
# non-zero. This slice makes the sentence TRUE; it does not make doctor a gate.
run_doctor "$W5" "$R5/bin" >/dev/null 2>&1
RC5=$?
if [ "$RC5" -eq 0 ]; then pass "10. doctor still exits 0 on the diverged RED (advisory)"; else
  fail "10. doctor exited $RC5 on the diverged RED — it must never block a chain"; fi

# ── 11. no bp on PATH → LOUD in --hook mode, still exit 0 ────────────────────
# A second environment (a fresh clone on another machine) has no bp at all, and
# that is precisely the case the SessionStart hook exists to catch. Before this
# case the branch called `skip`, which prints NOTHING under --hook (doctor.sh:20)
# — the hook stayed silent about the most likely failure it could report. This
# case FAILS against that old code, so it is a guard that can lose.
# The PATH is rebuilt from scratch (a bindir holding only a git symlink) so a bp
# installed anywhere on this host cannot satisfy `command -v bp` by accident.
R11="$TMP/c11"; mkdir -p "$R11"; W11="$(base_repo "$R11")"
NOBP="$R11/nobp"; mkdir -p "$NOBP"
for t in git curl; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOBP/$t"
done
if command -v bp >/dev/null 2>&1 && PATH="$NOBP" command -v bp >/dev/null 2>&1; then
  fail "11. fixture PATH still resolves a bp — the no-bp case cannot be tested"
fi
OUT11="$(env -i PATH="$NOBP" HOME="$TMP" \
  BARKPARK_RELEASES_API_URL="https://example.invalid/releases" \
  /bin/bash "$W11/scripts/doctor.sh" --hook 2>&1)"
RC11=$?
assert_has "11. hook mode NAMES the missing bp out loud" "$OUT11" "no bp on PATH"
if [ "$RC11" -eq 0 ]; then pass "11. missing bp stays advisory (exit 0)"; else
  fail "11. doctor exited $RC11 with no bp on PATH — it must never block a session"; fi

# ── 12. migration membership survives large query output ────────────────────
# The real report used printf | grep -q under pipefail. Once grep found an
# early version, printf could receive SIGPIPE and turn a match into "pending".
# Keep this fixture larger than a pipe buffer, with matches at both ends, and
# drive the actual doctor. PostgreSQL is stubbed: no live DB is needed here.
R12="$TMP/c12"; mkdir -p "$R12"; W12="$(base_repo "$R12")"
make_bp "$R12/bin" "$($GIT -C "$W12" rev-parse HEAD)"
mkdir -p "$W12/api/priv/repo/migrations"
printf '# fixture\n' > "$W12/api/priv/repo/migrations/20260101000001_first.exs"
printf '# fixture\n' > "$W12/api/priv/repo/migrations/20261231000000_last.exs"
awk 'BEGIN {
  print "20260101000001"
  for (i = 0; i < 100000; i++) printf "202602%08d\n", i
  print "202601010000020"
  print "20261231000000"
}' > "$R12/applied"
cat > "$R12/bin/psql" <<'EOF'
#!/bin/bash
case "$*" in
  *schema_migrations*) cat "$DOCTOR_TEST_APPLIED" ;;
  *pg_database*) echo 250 ;;
  *pg_stat_activity*) echo 0 ;;
  *max_connections*) echo 100 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$R12/bin/psql"
OUT12="$(DOCTOR_TEST_APPLIED="$R12/applied" run_doctor "$W12" "$R12/bin")"
assert_has "12. large applied list stays current" "$OUT12" "dev DB migration versions are current"
assert_has "12. database count does not claim every row is orphaned" "$OUT12" \
  "250 barkpark_test* databases (orphan status not established;"
if has "$OUT12" "pending migrations:"; then
  fail "12. applied versions were falsely reported pending"
else
  pass "12. no false pending migration at either end of the result"
fi

# A substring of another version is NOT membership. Only the missing file
# should be named; applied versions must not be mixed into its warning.
printf '# fixture\n' > "$W12/api/priv/repo/migrations/20260101000002_missing.exs"
OUT12_MISSING="$(DOCTOR_TEST_APPLIED="$R12/applied" run_doctor "$W12" "$R12/bin")"
assert_has "12. exact missing version is named" "$OUT12_MISSING" \
  "pending migrations: 20260101000002_missing.exs — run:"
if has "$OUT12_MISSING" "dev DB migration versions are current"; then
  fail "12. a missing migration must not also report current"
else
  pass "12. missing version is not falsely current"
fi

OUT12_DOWN="$(DOCTOR_TEST_APPLIED="$R12/absent" run_doctor "$W12" "$R12/bin")"
assert_has "12. failed migration query stays an explicit skip" "$OUT12_DOWN" \
  "dev DB not reachable — migration check skipped"
if has "$OUT12_DOWN" "dev DB migration versions are current" || has "$OUT12_DOWN" "pending migrations:"; then
  fail "12. failed query must not invent a migration verdict"
else
  pass "12. failed query is neither current nor pending"
fi

# ── negative control: prove the harness can SEE a false-green ────────────────
# If section 2 ever regresses to comparing against the ancestor-only diff and
# calls the behind-Go binary current, sec2_green would fire on cell 2. We assert
# the inverse above; this line documents that the matrix is not vacuous — cells
# 2 and 5 RED while 1/3/4 GREEN on the SAME code path is only possible if the
# merge-base compare-target is live.

echo
if [ "$fails" -ne 0 ]; then
  echo "doctor tests: $fails failure(s)" >&2
  exit 1
fi
echo "doctor tests: PASS (11 staleness cells + migration membership matrix)"

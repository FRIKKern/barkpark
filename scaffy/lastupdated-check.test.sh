#!/usr/bin/env bash
# Mutation proof for scaffy/lastupdated-check.sh --diff.
#
# Hermetic: builds a throwaway git repo under mktemp, plants each case as a real
# commit, and runs the guard against it. No network, no bp, no dependence on the
# real corpus — so this harness cannot go vacuous when the corpus changes.
#
# Both directions are proven, which is the point: a guard that only ever reds is
# as useless as one that only ever passes.
#   RED  arm — a recipe edit with a frozen LAST_UPDATED.
#   QUIET arms — the same recipe edit WITH a header bump; a comment-only edit
#                with a frozen header; a header-only bump; an untouched corpus;
#                and a brand-new command file.
#   REFUSAL arm — an unresolvable base ref exits 2, never 0.

set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/lastupdated-check.sh"
PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	echo "  PASS  $1"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "  FAIL  $1"
}

# expect <label> <want-exit> <base> ; runs the guard in $REPO
expect() {
	local label="$1" want="$2" base="$3" out got
	out=$(cd "$REPO" && bash "$GUARD" --diff "$base" 2>&1)
	got=$?
	if [ "$got" -eq "$want" ]; then
		ok "$label (exit $got)"
	else
		bad "$label — want exit $want, got $got"
		echo "$out" | sed 's/^/        /'
	fi
	LAST_OUT="$out"
}

FIXTURE='COMMAND "Fixture" DESCRIPTION "d" LAST_UPDATED "01-01-2026-00-00-00" DOMAIN "barkpark" TAGS "scaffy" CONCEPT "fixture" VARIANT "text" DIRECTION "add" VARIABLES
  VARIABLE 1 "Name" TITLE "t" DESCRIPTION "d" EXAMPLES "X"

# a full-line comment, deliberately present so the comment arm has something to edit
TARGET "a.txt"
  ANCHOR AFTER "marker"
  INJECT ":::
hello {{.Name}}
:::"'

new_repo() {
	REPO=$(mktemp -d)
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@t.t
	git -C "$REPO" config user.name t
	mkdir -p "$REPO/scaffy/commands"
	printf '%s\n' "$FIXTURE" >"$REPO/scaffy/commands/fixture.scaffy"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm base
	BASE=$(git -C "$REPO" rev-parse HEAD)
}

commit_all() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"; }

echo "scaffy/lastupdated-check.test.sh"

# ── 1. RED: recipe edit, header frozen ──────────────────────────────────────
new_repo
sed -i.bak 's/hello {{.Name}}/goodbye {{.Name}}/' "$REPO/scaffy/commands/fixture.scaffy" && rm -f "$REPO"/scaffy/commands/*.bak
commit_all "recipe edit, no bump"
expect "recipe edit with frozen LAST_UPDATED REDS" 1 "$BASE"
case "$LAST_OUT" in
*VIOLATION*) ok "red arm names the file as a VIOLATION" ;;
*) bad "red arm did not print VIOLATION" ;;
esac
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

# ── 2. QUIET: same recipe edit, header bumped ───────────────────────────────
new_repo
sed -i.bak -e 's/hello {{.Name}}/goodbye {{.Name}}/' -e 's/LAST_UPDATED "01-01-2026-00-00-00"/LAST_UPDATED "02-02-2026-00-00-00"/' "$REPO/scaffy/commands/fixture.scaffy" && rm -f "$REPO"/scaffy/commands/*.bak
commit_all "recipe edit, bumped"
expect "recipe edit WITH a LAST_UPDATED bump stays quiet" 0 "$BASE"
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

# ── 3. QUIET: comment-only edit, header frozen ──────────────────────────────
new_repo
sed -i.bak 's/^# a full-line comment.*/# a REWORDED full-line comment/' "$REPO/scaffy/commands/fixture.scaffy" && rm -f "$REPO"/scaffy/commands/*.bak
commit_all "comment-only edit"
expect "comment-only edit with a frozen header stays quiet" 0 "$BASE"
case "$LAST_OUT" in
*"no recipe change"*) ok "comment arm is classified as no-recipe-change, not skipped" ;;
*) bad "comment arm did not report 'no recipe change'" ;;
esac
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

# ── 4. QUIET: header-only bump ──────────────────────────────────────────────
new_repo
sed -i.bak 's/LAST_UPDATED "01-01-2026-00-00-00"/LAST_UPDATED "03-03-2026-00-00-00"/' "$REPO/scaffy/commands/fixture.scaffy" && rm -f "$REPO"/scaffy/commands/*.bak
commit_all "header-only bump"
expect "header-only bump stays quiet" 0 "$BASE"
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

# ── 5. QUIET: nothing touched at all ────────────────────────────────────────
new_repo
echo "unrelated" >"$REPO/other.txt"
commit_all "unrelated change"
expect "a diff touching no command file stays quiet" 0 "$BASE"
case "$LAST_OUT" in
*"no command files changed"*) ok "empty arm says so rather than silently passing" ;;
*) bad "empty arm gave no reason" ;;
esac
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

# ── 6. QUIET: a brand-new command file ──────────────────────────────────────
new_repo
printf '%s\n' "$FIXTURE" | sed 's/"Fixture"/"Second"/' >"$REPO/scaffy/commands/second.scaffy"
commit_all "new command file"
expect "a new command file is not a violation" 0 "$BASE"
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

# ── 7. REFUSAL: base ref cannot be resolved ─────────────────────────────────
new_repo
expect "an unresolvable base ref REFUSES (exit 2), never passes" 2 "no-such-ref-xyz"
trash "$REPO" 2>/dev/null || rm -rf "$REPO"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

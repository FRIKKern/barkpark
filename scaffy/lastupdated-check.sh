#!/usr/bin/env bash
# scaffy LAST_UPDATED freshness guard.
#
# THE RULE THIS ENFORCES (decided by task-8559e07059a59583):
#   LAST_UPDATED means "the date the RECIPE last changed" — NOT "the date a byte
#   in this file last changed". A change to the recipe must move the header in
#   the SAME commit; a comment-only edit must not.
#
# WHY NOT "just derive it from git" (the other candidate meaning). The header is
# not metadata beside the file: `scaffy/seed` seeds the WHOLE file text as the
# catalog document's `source` field (scaffy/seed/main.go, `Source: string(src)`),
# and `source` is one of the eight comparedFields the drift check compares. So a
# LAST_UPDATED byte is a CATALOG-VISIBLE byte: bumping it flips that command's
# row from MATCH to DRIFT in `go run ./scaffy/seed --check` until an owner
# re-seeds the served catalog. MEASURED, not reasoned — bumping add-migration's
# header alone and nothing else took the corpus from 18/22 MATCH to 17/22 MATCH
# with `source` as the divergent field. A generated last-touched date would
# therefore demand an owner-only catalog republish on EVERY commit that grazes a
# command file, including typo fixes. That is why the header is hand-declared and
# why it tracks the recipe.
#
# WHY THIS GUARD IS DIFF-SCOPED, NOT WHOLE-CORPUS. 8 of the 22 command files on
# main today already declare a header older than their last recipe-affecting
# commit (run `--corpus` to see them). A whole-corpus arm would red main from the
# minute it landed and could only be cleared by bumping 8 headers — which, per
# the paragraph above, manufactures 5 NEW catalog DRIFT rows that only an
# owner-only republish can clear. So this follows the precedent the repo already
# ratified for exactly this shape (docs/ops/merge-gates.md, the `format` job):
# enforce on the files THIS diff touches, print inherited drift and stay neutral
# on it. The 8 get repaired by whoever next edits them, in a PR that was already
# going to re-seed the catalog.
#
# THE "RECIPE BYTES" OF A COMMAND FILE = the file with (a) full-line `#` comments
# dropped and (b) the LAST_UPDATED value itself elided. Everything else — every
# header field, every fenced block, every anchor — is recipe.
#
# MODES
#   --diff <base-ref>   enforcing: red if a command file changed in
#                       <base-ref>..HEAD has recipe churn without a header move.
#   --corpus            informational census of header-vs-last-recipe-commit
#                       across the whole corpus. Never reds. Exit 0 always.
#   --self-test         hermetic mutation proof of both directions. No network.

set -uo pipefail

CMD_GLOB_DIR="scaffy/commands"

# recipe_bytes strips the two non-recipe classes from stdin.
recipe_bytes() {
	sed -e 's/LAST_UPDATED "[^"]*"/LAST_UPDATED "<elided>"/g' -e '/^[[:space:]]*#/d'
}

# header_value prints the raw LAST_UPDATED token of a file's text on stdin.
header_value() {
	grep -o 'LAST_UPDATED "[^"]*"' | head -1 | sed 's/LAST_UPDATED "//; s/"$//'
}

# blob_at prints <rev>:<path>, or nothing when the path did not exist there.
blob_at() {
	git show "$1:$2" 2>/dev/null
}

# --------------------------------------------------------------------------
# --diff <base>
# --------------------------------------------------------------------------
run_diff() {
	local base="$1" merge_base
	merge_base=$(git merge-base "$base" HEAD 2>/dev/null)
	if [ -z "$merge_base" ]; then
		echo "scaffy-lastupdated: REFUSING — cannot resolve merge-base of '$base' and HEAD." >&2
		echo "scaffy-lastupdated: a guard that cannot tell must fail, never wave through." >&2
		return 2
	fi

	local changed
	changed=$(git diff --name-only --diff-filter=d "$merge_base" HEAD -- "$CMD_GLOB_DIR" | grep '\.scaffy$' || true)
	if [ -z "$changed" ]; then
		echo "scaffy-lastupdated: no command files changed in ${base}..HEAD — nothing to check."
		return 0
	fi

	local violations=0 f before after rb_before rb_after hv_before hv_after
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		before=$(blob_at "$merge_base" "$f")
		if [ -z "$before" ]; then
			echo "  NEW      $f — new command file, header freshness not applicable"
			continue
		fi
		after=$(cat "$f")
		rb_before=$(printf '%s' "$before" | recipe_bytes | shasum | cut -d' ' -f1)
		rb_after=$(printf '%s' "$after" | recipe_bytes | shasum | cut -d' ' -f1)
		hv_before=$(printf '%s' "$before" | header_value)
		hv_after=$(printf '%s' "$after" | header_value)

		if [ "$rb_before" = "$rb_after" ]; then
			echo "  ok       $f — no recipe change (comment/header-only edit)"
			continue
		fi
		if [ "$hv_before" != "$hv_after" ]; then
			echo "  ok       $f — recipe changed, LAST_UPDATED moved ${hv_before} -> ${hv_after}"
			continue
		fi
		echo "  VIOLATION $f — recipe bytes changed but LAST_UPDATED is still \"${hv_after}\""
		violations=$((violations + 1))
	done <<<"$changed"

	if [ "$violations" -gt 0 ]; then
		echo ""
		echo "scaffy-lastupdated: ${violations} command file(s) changed their recipe without moving LAST_UPDATED."
		echo "  Set the header to today in DD-MM-YYYY-HH-MM-SS form, e.g. LAST_UPDATED \"$(date -u +%d-%m-%Y-%H-%M-%S)\"."
		echo "  Then re-seed the served catalog (scaffy/seed/README.md) — the header rides the seeded \`source\` field."
		return 1
	fi
	echo "scaffy-lastupdated: every command file this diff touches declares a fresh LAST_UPDATED."
	return 0
}

# --------------------------------------------------------------------------
# --corpus (informational only)
# --------------------------------------------------------------------------
run_corpus() {
	local f hv decl last_recipe sha parent cur prev stale=0 total=0
	printf "%-38s %-12s %-12s %s\n" "COMMAND" "DECLARED" "RECIPE" "STATUS"
	for f in "$CMD_GLOB_DIR"/*.scaffy; do
		total=$((total + 1))
		hv=$(cat "$f" | header_value)
		decl=$(printf '%s' "$hv" | awk -F- '{print $3"-"$2"-"$1}')
		last_recipe=""
		for sha in $(git log --format=%H -- "$f"); do
			parent=$(git rev-parse "${sha}^" 2>/dev/null) || parent=""
			cur=$(blob_at "$sha" "$f" | recipe_bytes | shasum | cut -d' ' -f1)
			if [ -n "$parent" ]; then
				prev=$(blob_at "$parent" "$f" | recipe_bytes | shasum | cut -d' ' -f1)
			else
				prev="NONE"
			fi
			if [ "$cur" != "$prev" ]; then
				last_recipe=$(git log -1 --format=%cd --date=short "$sha")
				break
			fi
		done
		if [ -n "$last_recipe" ] && [[ "$decl" < "$last_recipe" ]]; then
			stale=$((stale + 1))
			printf "%-38s %-12s %-12s %s\n" "$(basename "$f")" "$decl" "$last_recipe" "STALE"
		else
			printf "%-38s %-12s %-12s %s\n" "$(basename "$f")" "$decl" "$last_recipe" "ok"
		fi
	done
	echo ""
	echo "scaffy-lastupdated --corpus: ${stale} of ${total} declare a header older than their last recipe-affecting commit."
	echo "INFORMATIONAL — this mode never reds. Enforcement is --diff, on the files a PR touches."
	return 0
}

main() {
	case "${1:---corpus}" in
	--diff)
		[ $# -ge 2 ] || {
			echo "usage: $0 --diff <base-ref>" >&2
			return 2
		}
		run_diff "$2"
		;;
	--corpus) run_corpus ;;
	--self-test) bash "$(dirname "$0")/lastupdated-check.test.sh" ;;
	*)
		echo "usage: $0 [--diff <base-ref> | --corpus | --self-test]" >&2
		return 2
		;;
	esac
}

main "$@"

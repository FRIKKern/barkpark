#!/usr/bin/env bash
#
# scratchpad-reaper.sh — reclaim agent scratchpad space MEASURED BY df, and
# refuse to start work below a stated free-space floor.
#
# WHY THIS EXISTS (task-80d117829feec84e, measured 2026-08-10, cloud-console-
# hardening wave 66). Every Bash call on the wave host died with
# `ENOSPC: no space left on device` while opening its OWN output file. The
# digest phase ran ZERO commands: it could not patch the wave Paper, could not
# stamp the epic heartbeat, ran no premise smoke. Three surveyors lost their
# final scans mid-run. A wave that dispatches builders onto a full host gets
# gate output INDISTINGUISHABLE from a real test failure — an environment fault
# wearing a defect's face.
#
# RETRACTION — THE BRIEFED REMEDY IS A PROVED NO-OP
# -------------------------------------------------
# The remedy briefed during that incident was:
#
#     rm -rf /private/tmp/claude-501/*/tasks/*.output
#
# MEASURED that day: output-files matched 0, `rm` returned rc=1, and free space
# was UNCHANGED at 117Mi before and after. Those `.output` files are the
# ENOSPC's VICTIM, not its cause — at zero bytes free the harness cannot create
# one at all, which is why the glob matched nothing. Do not run it; it targets
# the symptom's own casualty. (Searched 2026-09-13 across `.claude/` and
# `docs/`: the string appears in exactly one place in this repo,
# `.claude/workflows/bp-cloud-console-hardening-charter.md` D810, and it is
# already RECORDED THERE AS REFUTED, not briefed as a remedy. This header is
# the durable retraction for anyone who meets the advice outside the repo.)
#
# THE ACTUAL CONSUMER, measured: /private/tmp held 56 GB, of which
# /private/tmp/claude-501 was 43.5 GB. Recovery to 11Gi free came from deleting
# one FOREIGN project's scratch tree (11,048 MB). The refill engine is the
# per-project scratchpad the agent harness hands each session: a repo clone /
# git-archive extract / worktree PER AGENT PER WAVE — 3,644 entries dated
# 2026-08-07..2026-08-10 totalling 32.8 GB in a SINGLE session directory,
# ~11 GB/day, and nothing ever removed one. This script is the thing that
# removes one.
#
# THE MEASUREMENT TRAP, re-confirmed: `du` and statfs disagree by an order of
# magnitude on APFS. Deleting 36 stale session directories that `du` valued at
# ~33 GB freed UNDER 0.5 GB — APFS clones share blocks, so `du` charges every
# clone the full price while deleting one frees nothing. THIS SCRIPT NEVER
# SIZES A RECLAIM WITH `du`. Every reclaim step is bracketed by `df -P -k` and
# reports the DELTA IN AVAILABLE BLOCKS. `du` appears nowhere below by design.
#
# NEVER STRAND BUILT WORK
# -----------------------
# 17 registered git worktrees were live in that scratch tree; a registered
# worktree can hold a sibling lane's unpushed build. So, before anything is
# removed:
#
#   1. Any candidate that IS, CONTAINS, or SITS UNDER a worktree registered by
#      `git worktree list --porcelain` in any --repo is SKIP-WORKTREE, always,
#      even when it is clean and fully pushed. Removing the directory strands
#      the registration too.
#   2. Any OTHER git checkout found anywhere inside a candidate must PROVE it
#      holds nothing unpushed: a clean `status --porcelain`, an empty stash,
#      at least one remote, and `rev-list --count <branch> --not --remotes`
#      equal to 0 for every local branch. Anything else, including a git
#      command that FAILS, is a skip. An unreadable candidate is never a
#      deletable one.
#   3. A candidate younger than --min-age-days is SKIP-FRESH: a live agent's
#      tree is the one most likely to be mid-write.
#
# WHY `rm -rf` AND NOT `trash`
# ----------------------------
# The repo convention is `trash` over `rm`, and it is the right default for
# source. It cannot be the default HERE: macOS trashes a file from volume V
# into V's own `.Trashes`, so on the volume this script exists to unblock,
# trashing reclaims exactly ZERO bytes — the same failure mode as the retracted
# remedy above. Deletion is therefore `rm -rf`, and it is fenced instead:
# dry-run is the DEFAULT, an actual reclaim needs both --reap and --yes-delete,
# and every skip gate above runs first.
#
# MODES
#   scratchpad-reaper.sh --floor <GiB> [PATH]        refuse below a free-space floor
#   scratchpad-reaper.sh --dry-run --root DIR ...    classify; delete NOTHING (default)
#   scratchpad-reaper.sh --reap --yes-delete --root DIR ...   classify and reclaim
#
# OPTIONS
#   --root DIR           a scratchpad root to sweep; repeatable; required for a sweep
#   --repo DIR           a git repo whose worktree registrations are honoured;
#                        repeatable; defaults to this script's own repo root
#   --min-age-days N     a candidate modified within N days is never touched (default 2)
#   --no-entries-census  skip the before/after `find | wc -l` entry count (two extra
#                        full walks per root); never changes what is reaped
#   --floor <GiB>        check mode (see above); delegates the verdict to
#                        scripts/disk-headroom-guard.sh, which is the repo's
#                        one free-space instrument
#
# EXIT CODES
#   0  OK          — floor met, or sweep completed with every candidate readable
#   1  UNREADABLE  — sweep completed but at least one candidate could not be read
#                    (deliberately NOT byte-identical to a clean zero)
#   2  REFUSED     — measured, and below the floor
#   3  BLIND       — could not measure (missing root, df or guard unreadable)
#   4  USAGE       — bad invocation
#
# COST, measured on this machine 2026-09-13. A dry run over ONE session
# scratchpad holding 7,397,328 entries took 5m34s: two full `find` passes for
# the entry census plus a pruned `.git` walk per candidate. Scope a run to the
# root you mean (a wave's own scratchpad), not to the whole per-user tree — the
# shared root above it held 14,264,338 entries on the same day. The unpushed
# scan is a FULL walk by design: bounding its depth would let a checkout below
# the bound be deleted with work in it, which is the one outcome this script
# exists to make impossible.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

PROG=scratchpad-reaper
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SELF_DIR/.." && pwd)
GUARD="$SELF_DIR/disk-headroom-guard.sh"

MIN_AGE_DAYS=2
ENTRIES_CENSUS=1
MODE=dry-run
YES_DELETE=0
FLOOR_GB=""
ROOTS=""
REPOS=""
FLOOR_PATH=""

n_reap=0
n_skip=0
n_unreadable=0
freed_kb_total=0

die_usage() {
	printf '%s: USAGE — %s\n' "$PROG" "$1" >&2
	printf 'usage: %s --floor <GiB> [PATH]\n' "$PROG" >&2
	printf '       %s [--dry-run] --root DIR [--root DIR ...] [--repo DIR] [--min-age-days N]\n' "$PROG" >&2
	printf '       %s --reap --yes-delete --root DIR [...]\n' "$PROG" >&2
	exit 4
}

cannot_read() {
	printf '%s: CANNOT READ %s — %s\n' "$PROG" "$1" "$2" >&2
	n_unreadable=$((n_unreadable + 1))
}

# avail_kb <path> — POSIX df Avail (column 4) in 1K blocks, on stdout.
# Returns 1 and prints nothing when the reading is not a run of digits: an
# instrument that cannot measure must never be mistaken for a measurement.
avail_kb() {
	local out line field
	out=$(df -P -k -- "$1" 2>/dev/null) || return 1
	line=$(printf '%s\n' "$out" | awk 'NR==2 {print; exit}')
	[ -n "$line" ] || return 1
	field=$(printf '%s\n' "$line" | awk '{print $4}')
	case "$field" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$field"
	return 0
}

kb_human() {
	# Whole MiB, then GiB with one decimal via integer arithmetic. No bc, no awk
	# float formatting differences between BSD and GNU.
	local kb="$1" mib gib_whole gib_tenth
	mib=$((kb / 1024))
	gib_whole=$((mib / 1024))
	gib_tenth=$(((mib % 1024) * 10 / 1024))
	printf '%d MiB (%d.%d GiB)' "$mib" "$gib_whole" "$gib_tenth"
}

# ---------------------------------------------------------------- floor mode

floor_mode() {
	local target="$1" gb="$2" before out rc

	case "$gb" in
	'' | *[!0-9]*) die_usage "--floor takes a whole number of GiB, got: $gb" ;;
	esac

	if [ ! -e "$target" ]; then
		printf '%s: BLIND — floor path does not exist: %s\n' "$PROG" "$target" >&2
		exit 3
	fi

	if ! before=$(avail_kb "$target"); then
		printf '%s: BLIND — df gave no usable Avail figure for %s; refusing to report headroom it did not measure\n' "$PROG" "$target" >&2
		exit 3
	fi

	if [ ! -r "$GUARD" ]; then
		cannot_read "$GUARD" "the free-space guard is missing; the floor verdict has no authority"
		printf '%s: BLIND — cannot delegate the floor verdict\n' "$PROG" >&2
		exit 3
	fi

	# The VERDICT belongs to the repo's one free-space instrument. This script
	# owns the reclaim; it does not grow a second, drifting definition of "full".
	# Read to EOF, never piped: a gate through `head`/`grep -q` reports the
	# pipe's exit code, not the gate's.
	out=$(BP_DISK_MIN_FREE_GB="$gb" "$GUARD" "$target" 2>&1)
	rc=$?
	printf '%s\n' "$out"

	case "$rc" in
	0)
		printf '%s: FLOOR OK — %s has %s free, at or above the %s GiB floor. Dispatch allowed.\n' \
			"$PROG" "$target" "$(kb_human "$before")" "$gb"
		exit 0
		;;
	2)
		printf '%s: FLOOR REFUSED — %s has %s free, BELOW the stated floor of %s GiB. Refusing to dispatch builders: at ENOSPC every gate on this host fails at once and its output is indistinguishable from a real defect.\n' \
			"$PROG" "$target" "$(kb_human "$before")" "$gb" >&2
		exit 2
		;;
	*)
		printf '%s: BLIND — the floor guard exited %d without a verdict for %s (floor %s GiB)\n' \
			"$PROG" "$rc" "$target" "$gb" >&2
		exit 3
		;;
	esac
}

# ------------------------------------------------------------ worktree fence

# worktree_paths — every registered worktree path across every --repo, one per
# line. A repo that cannot be read is LOUD and makes the whole sweep blind:
# sweeping without the fence is exactly how built work gets stranded.
worktree_paths() {
	local repo out
	for repo in $REPOS; do
		if ! out=$(git -C "$repo" worktree list --porcelain 2>/dev/null); then
			cannot_read "$repo" "git worktree list failed; the worktree fence would be incomplete"
			return 1
		fi
		printf '%s\n' "$out" | awk '$1 == "worktree" { $1 = ""; sub(/^ /, ""); print }'
	done
	return 0
}

# path_overlaps <a> <b> — true when a == b, a is under b, or b is under a.
path_overlaps() {
	case "$1" in
	"$2") return 0 ;;
	"$2"/*) return 0 ;;
	esac
	case "$2" in
	"$1"/*) return 0 ;;
	esac
	return 1
}

# ------------------------------------------------------- unpushed-work proof

# checkout_is_pushed <dir> — 0 only when this checkout demonstrably holds
# nothing that exists solely here. Every failure mode returns non-zero and
# prints its reason on stdout, so a git error can never read as "safe".
checkout_is_pushed() {
	local dir="$1" st stash remotes br behind
	if ! st=$(git -C "$dir" status --porcelain 2>/dev/null); then
		printf 'git status failed\n'
		return 1
	fi
	if [ -n "$st" ]; then
		printf 'working tree is dirty or holds untracked files\n'
		return 1
	fi
	stash=$(git -C "$dir" stash list 2>/dev/null)
	if [ -n "$stash" ]; then
		printf 'stash is not empty\n'
		return 1
	fi
	if ! remotes=$(git -C "$dir" remote 2>/dev/null); then
		printf 'git remote failed\n'
		return 1
	fi
	if [ -z "$remotes" ]; then
		printf 'no remote configured, so nothing here can be proved pushed\n'
		return 1
	fi
	while IFS= read -r br; do
		[ -n "$br" ] || continue
		behind=$(git -C "$dir" rev-list --count "$br" --not --remotes 2>/dev/null)
		case "$behind" in
		'' | *[!0-9]*)
			printf 'rev-list could not count unpushed commits on %s\n' "$br"
			return 1
			;;
		esac
		if [ "$behind" -gt 0 ]; then
			printf '%s carries %s commit(s) present on no remote\n' "$br" "$behind"
			return 1
		fi
	done <<EOF
$(git -C "$dir" for-each-ref --format='%(refname)' refs/heads 2>/dev/null)
EOF
	return 0
}

# candidate_holds_unpushed <dir> — scans EVERY git checkout at any depth inside
# the candidate (`.git` is pruned, so the walk does not descend into object
# stores). Prints the first blocking reason; returns 0 when a block exists.
candidate_holds_unpushed() {
	local dir="$1" gitdir co why
	while IFS= read -r gitdir; do
		[ -n "$gitdir" ] || continue
		co=$(dirname "$gitdir")
		if ! why=$(checkout_is_pushed "$co"); then
			printf '%s: %s\n' "$co" "$why"
			return 0
		fi
	done <<EOF
$(find "$dir" -name .git -prune -print 2>/dev/null)
EOF
	return 1
}

# -------------------------------------------------------------------- sweep

sweep() {
	local wt_list root entry age_cutoff before after freed why

	[ -n "$ROOTS" ] || die_usage "a sweep needs at least one --root DIR"

	if ! wt_list=$(worktree_paths); then
		printf '%s: BLIND — the registered-worktree fence could not be built; refusing to sweep\n' "$PROG" >&2
		exit 3
	fi
	printf '%s: fence — %d registered worktree path(s) across repos: %s\n' \
		"$PROG" "$(printf '%s\n' "$wt_list" | awk 'NF' | wc -l | tr -d ' ')" "$(printf '%s' "$REPOS" | tr '\n' ' ')"
	printf '%s: mode=%s min-age-days=%d\n' "$PROG" "$MODE" "$MIN_AGE_DAYS"

	for root in $ROOTS; do
		if [ ! -d "$root" ]; then
			printf '%s: BLIND — root is not a directory: %s\n' "$PROG" "$root" >&2
			exit 3
		fi
		if ! before=$(avail_kb "$root"); then
			printf '%s: BLIND — df gave no usable Avail figure for root %s\n' "$PROG" "$root" >&2
			exit 3
		fi
		printf '%s: ROOT %s\n' "$PROG" "$root"
		printf '%s: DF-BEFORE-ROOT %s avail_kb=%s (%s)\n' "$PROG" "$root" "$before" "$(kb_human "$before")"
		if [ "$ENTRIES_CENSUS" -eq 1 ]; then
			printf '%s: ENTRIES-BEFORE %s %s (find, all depths — the count the incident used)\n' \
				"$PROG" "$root" "$(find "$root" 2>/dev/null | wc -l | tr -d ' ')"
		else
			printf '%s: ENTRIES-BEFORE %s SKIPPED (--no-entries-census)\n' "$PROG" "$root"
		fi

		for entry in "$root"/*; do
			[ -e "$entry" ] || continue
			[ -d "$entry" ] || continue
			classify_and_maybe_reap "$entry" "$wt_list"
		done

		if ! after=$(avail_kb "$root"); then
			cannot_read "$root" "df gave no usable Avail figure AFTER the sweep"
		else
			freed=$((after - before))
			# A ROOT-LEVEL delta is NOT a reclaim figure and is never reported as
			# one. Measured on this box 2026-09-13: a DRY run over a 7,397,328-entry
			# scratchpad deleted nothing and still showed delta_kb=-278876, because
			# ~30 other agent lanes wrote to the same volume during the 5m34s walk
			# (the entry count ROSE by 8,983 over the same window). Only the
			# per-step REAPED delta is attributable, and even that is approximate
			# on a shared host. This line is a context reading, labelled as one.
			printf '%s: DF-AFTER-ROOT %s avail_kb=%s (%s) delta_kb=%d (context only — other lanes write this volume; NOT a reclaim figure%s)\n' \
				"$PROG" "$root" "$after" "$(kb_human "$after")" "$freed" \
				"$([ "$MODE" = dry-run ] && printf ', and this run deleted NOTHING' || printf '')"
			if [ "$ENTRIES_CENSUS" -eq 1 ]; then
				printf '%s: ENTRIES-AFTER %s %s\n' \
					"$PROG" "$root" "$(find "$root" 2>/dev/null | wc -l | tr -d ' ')"
			else
				printf '%s: ENTRIES-AFTER %s SKIPPED (--no-entries-census)\n' "$PROG" "$root"
			fi
		fi
	done

	printf '%s: TOTALS mode=%s reaped=%d skipped=%d unreadable=%d freed_kb=%d\n' \
		"$PROG" "$MODE" "$n_reap" "$n_skip" "$n_unreadable" "$freed_kb_total"

	if [ "$n_unreadable" -gt 0 ]; then
		printf '%s: completed with %d unreadable candidate(s) — this is exit 1, not a clean zero\n' \
			"$PROG" "$n_unreadable" >&2
		exit 1
	fi
	exit 0
}

classify_and_maybe_reap() {
	local entry="$1" wt_list="$2" wt why mtime_epoch now age_days before after freed

	# SELF. Never remove the tree this script is running out of.
	if path_overlaps "$entry" "$REPO_ROOT"; then
		printf '%s: SKIP-SELF      %s — overlaps this script'"'"'s own repo root\n' "$PROG" "$entry"
		n_skip=$((n_skip + 1))
		return
	fi

	# 1. REGISTERED WORKTREE — unconditional, even when clean and pushed.
	while IFS= read -r wt; do
		[ -n "$wt" ] || continue
		if path_overlaps "$entry" "$wt"; then
			printf '%s: SKIP-WORKTREE  %s — overlaps registered worktree %s\n' "$PROG" "$entry" "$wt"
			n_skip=$((n_skip + 1))
			return
		fi
	done <<EOF
$wt_list
EOF

	# 2. FRESHNESS — a live agent's tree is the one most likely to be mid-write.
	mtime_epoch=$(stat -f %m "$entry" 2>/dev/null || stat -c %Y "$entry" 2>/dev/null)
	case "$mtime_epoch" in
	'' | *[!0-9]*)
		cannot_read "$entry" "stat gave no usable mtime; not removing what cannot be dated"
		return
		;;
	esac
	now=$(date +%s)
	age_days=$(((now - mtime_epoch) / 86400))
	if [ "$age_days" -lt "$MIN_AGE_DAYS" ]; then
		printf '%s: SKIP-FRESH     %s — modified %d day(s) ago, under the %d-day floor\n' \
			"$PROG" "$entry" "$age_days" "$MIN_AGE_DAYS"
		n_skip=$((n_skip + 1))
		return
	fi

	# 3. UNPUSHED WORK anywhere inside.
	if why=$(candidate_holds_unpushed "$entry"); then
		printf '%s: SKIP-UNPUSHED  %s — %s\n' "$PROG" "$entry" "$why"
		n_skip=$((n_skip + 1))
		return
	fi

	if [ "$MODE" = dry-run ]; then
		printf '%s: WOULD-REAP     %s — age %d day(s), no registered worktree, no unpushed commit\n' \
			"$PROG" "$entry" "$age_days"
		n_reap=$((n_reap + 1))
		return
	fi

	# df BEFORE and AFTER this one step. Never du: on APFS a clone is charged
	# full price by du and frees nothing when deleted (measured: 36 dirs, du
	# ~33 GB, df delta under 0.5 GB).
	if ! before=$(avail_kb "$entry"); then
		cannot_read "$entry" "df gave no usable Avail figure before the reclaim; not removing what cannot be measured"
		return
	fi
	if ! rm -rf -- "$entry"; then
		cannot_read "$entry" "rm -rf failed"
		return
	fi
	# The entry is gone, so the AFTER reading is taken on its parent, which is
	# the same filesystem and still exists.
	after=$(avail_kb "$(dirname "$entry")") || after=""
	if [ -z "$after" ]; then
		cannot_read "$entry" "df gave no usable Avail figure after the reclaim; the freed figure is unknown"
		n_reap=$((n_reap + 1))
		return
	fi
	freed=$((after - before))
	freed_kb_total=$((freed_kb_total + freed))
	printf '%s: REAPED         %s — df avail_kb %s -> %s, freed_kb=%d (%s). Sized by df, never du.\n' \
		"$PROG" "$entry" "$before" "$after" "$freed" "$(kb_human "$freed")"
	n_reap=$((n_reap + 1))
}

# --------------------------------------------------------------------- main

main() {
	local arg
	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
		--floor)
			[ "$#" -ge 2 ] || die_usage "--floor needs a whole number of GiB"
			FLOOR_GB="$2"
			shift 2
			;;
		--root)
			[ "$#" -ge 2 ] || die_usage "--root needs a directory"
			# ROOTS and REPOS are whitespace-separated lists (bash 3.2: no
			# arrays here), so a path containing a space would silently split
			# into two half-paths and sweep neither. Refuse it by name.
			case "$2" in
			*[[:space:]]*) die_usage "--root path contains whitespace, which this list cannot represent: $2" ;;
			esac
			ROOTS="$ROOTS $2"
			shift 2
			;;
		--repo)
			[ "$#" -ge 2 ] || die_usage "--repo needs a directory"
			case "$2" in
			*[[:space:]]*) die_usage "--repo path contains whitespace, which this list cannot represent: $2" ;;
			esac
			REPOS="$REPOS $2"
			shift 2
			;;
		--min-age-days)
			[ "$#" -ge 2 ] || die_usage "--min-age-days needs a whole number"
			case "$2" in
			'' | *[!0-9]*) die_usage "--min-age-days must be a whole number, got: $2" ;;
			esac
			MIN_AGE_DAYS="$2"
			shift 2
			;;
		--no-entries-census)
			# The entry census is TWO extra full `find` passes per root. It is the
			# figure criterion 1 of task-80d117829feec84e asks for and stays ON by
			# default, but on a very large root it dominates the run (14,264,338
			# entries measured under one per-user tree on 2026-09-13), so it can be
			# turned off. Turning it off never changes which candidates are reaped.
			ENTRIES_CENSUS=0
			shift
			;;
		--dry-run)
			MODE=dry-run
			shift
			;;
		--reap)
			MODE=reap
			shift
			;;
		--yes-delete)
			YES_DELETE=1
			shift
			;;
		-h | --help)
			printf 'usage: %s --floor <GiB> [PATH]\n' "$PROG"
			printf '       %s [--dry-run] --root DIR [--root DIR ...] [--repo DIR] [--min-age-days N]\n' "$PROG"
			printf '       %s --reap --yes-delete --root DIR [...]\n' "$PROG"
			printf 'exit:  0 OK  1 UNREADABLE candidate  2 REFUSED (below floor)  3 BLIND  4 USAGE\n'
			exit 0
			;;
		-*) die_usage "unknown option: $arg" ;;
		*)
			if [ -n "$FLOOR_GB" ] && [ -z "$FLOOR_PATH" ]; then
				FLOOR_PATH="$arg"
				shift
			else
				die_usage "unexpected argument: $arg"
			fi
			;;
		esac
	done

	if [ -n "$FLOOR_GB" ]; then
		[ -z "$ROOTS" ] || die_usage "--floor is a check mode and takes no --root"
		floor_mode "${FLOOR_PATH:-$REPO_ROOT}" "$FLOOR_GB"
	fi

	if [ "$MODE" = reap ] && [ "$YES_DELETE" -ne 1 ]; then
		die_usage "--reap deletes directories and requires --yes-delete alongside it"
	fi

	[ -n "$REPOS" ] || REPOS="$REPO_ROOT"

	sweep
}

main "$@"

#!/usr/bin/env bash
# disk-headroom-guard.sh — REFUSE to start work when the volume is nearly full.
#
# WHY THIS EXISTS
# ---------------
# This machine runs many concurrent agent lanes, each holding git worktrees and
# build trees. When the volume fills, every lane fails at once, with errors that
# name anything BUT the disk (a compiler ENOSPC, a truncated git object, a
# half-written test fixture). The failure is silent about its own cause.
#
# This guard makes that failure LOUD and EARLY: it exits non-zero with a named
# error BEFORE the work starts, instead of letting the work fail obscurely later.
# It is report-and-refuse ONLY. It deletes nothing, ever. There is no delete path
# in this file, by design: reclaiming disk on this box is destructive (worktrees
# hold uncommitted work from many lanes) and belongs behind a separate, explicitly
# opted-in tool that uses `trash`, not `rm`.
#
# THE MEASUREMENT TRAP THIS AVOIDS
# --------------------------------
# On macOS/APFS you must key on ABSOLUTE FREE BYTES, never on df's capacity
# percentage. All volumes in an APFS container share one free pool, and the
# read-only system snapshot mounted at `/` reports its OWN tiny usage as the
# percentage. Measured on this machine:
#
#   /dev/disk3s1s1  228Gi  17Gi used  17Gi avail   51%  /
#   /dev/disk3s5    228Gi 150Gi used  17Gi avail   90%  /System/Volumes/Data
#
# A guard reading "51%" from `/` calls a 90%-full machine healthy. Both rows
# report the same honest 17Gi Avail. So: parse Avail, ignore Capacity.
#
# NON-VACUITY
# -----------
# A guard that cannot measure must not pass. If df fails, prints no data row, or
# yields a field that is not a positive integer, this exits BLIND (3) rather than
# OK (0). "I could not tell" is a refusal here, not a green.
#
# USAGE
#   scripts/disk-headroom-guard.sh [PATH]        # default: this repo's root
#   BP_DISK_MIN_FREE_GB=25 scripts/disk-headroom-guard.sh
#   scripts/disk-headroom-guard.sh --self-test   # prove the guard still bites
#
# EXIT CODES
#   0  OK      — measured, and at or above the threshold
#   2  REFUSED — measured, and below the threshold
#   3  BLIND   — could not measure; deliberately NOT a pass
#   4  USAGE   — bad invocation

set -uo pipefail

PROG=disk-headroom-guard

# Default floor in whole GiB. Chosen for this box's workload: a single Elixir
# _build tree plus a fresh worktree checkout runs several GiB, and multiple lanes
# can start at once, so a few GiB of slack is not enough to be meaningful.
: "${BP_DISK_MIN_FREE_GB:=10}"

die_usage() {
	printf '%s: USAGE — %s\n' "$PROG" "$1" >&2
	printf 'usage: %s [PATH] | %s --self-test\n' "$PROG" "$PROG" >&2
	exit 4
}

# avail_kb_from_df <df-P-k-output>
#
# Extracts the Avail field (column 4) from POSIX `df -P -k` output. Emits the
# number on stdout and returns 0 only when it is a plain positive integer;
# otherwise emits nothing and returns 1. Split out from the df call so the
# self-test can feed it known-bad input and prove the blind path fires.
avail_kb_from_df() {
	local out="$1" line field
	# -P guarantees exactly one data line per filesystem, never wrapped.
	line=$(printf '%s\n' "$out" | awk 'NR==2 {print; exit}')
	[ -n "$line" ] || return 1
	field=$(printf '%s\n' "$line" | awk '{print $4}')
	# Reject empty, non-numeric, signed, and zero. A literal "0" free is itself a
	# refusal case, but it must arrive via the REFUSED path with a real reading,
	# and df never legitimately reports an empty or non-numeric Avail — so
	# anything that is not a run of digits means the instrument, not the disk.
	case "$field" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$field"
	return 0
}

self_test() {
	local fails=0 got

	check_blind() {
		local name="$1" input="$2"
		if got=$(avail_kb_from_df "$input"); then
			printf 'FAIL %s: parser returned %s; expected BLIND\n' "$name" "$got" >&2
			fails=$((fails + 1))
		else
			printf 'ok   %s -> BLIND\n' "$name"
		fi
	}

	check_value() {
		local name="$1" input="$2" want="$3"
		if got=$(avail_kb_from_df "$input") && [ "$got" = "$want" ]; then
			printf 'ok   %s -> %s\n' "$name" "$got"
		else
			printf 'FAIL %s: got %s; want %s\n' "$name" "${got:-<none>}" "$want" >&2
			fails=$((fails + 1))
		fi
	}

	# The instrument going blind must never read as healthy.
	check_blind 'empty df output' ''
	check_blind 'header only, no data row' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
	check_blind 'non-numeric Avail' 'Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s5 239022080 - - - /'

	# A real reading must parse, and must come from Avail (col 4), not Capacity.
	check_value 'real df -P -k row' 'Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s5 239022080 157286400 17825792 90% /System/Volumes/Data' 17825792

	# The APFS trap, made executable: the `/` snapshot row says 51% capacity while
	# reporting the same honest Avail. Reading col 4 keeps both rows agreeing; a
	# guard reading Capacity would call this one healthy.
	check_value 'APFS sealed / row (51% capacity, same Avail)' 'Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1s1 239022080 17825792 17825792 51% /' 17825792

	if [ "$fails" -ne 0 ]; then
		printf '%s: SELF-TEST FAILED (%d)\n' "$PROG" "$fails" >&2
		return 1
	fi
	printf '%s: self-test OK\n' "$PROG"
	return 0
}

main() {
	local target df_out avail_kb min_kb avail_gb

	case "${1-}" in
	--self-test)
		[ "$#" -eq 1 ] || die_usage "--self-test takes no other arguments"
		self_test
		exit $?
		;;
	-h | --help)
		printf 'usage: %s [PATH]        refuse if PATH'"'"'s volume is below the free-space floor\n' "$PROG"
		printf '       %s --self-test   prove the guard still bites\n' "$PROG"
		printf 'env:   BP_DISK_MIN_FREE_GB  whole GiB floor (default 10)\n'
		printf 'exit:  0 OK  2 REFUSED  3 BLIND (could not measure)  4 USAGE\n'
		exit 0
		;;
	-*) die_usage "unknown option: $1" ;;
	esac

	[ "$#" -le 1 ] || die_usage "expected at most one PATH"
	target="${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}"

	if [ ! -e "$target" ]; then
		printf '%s: BLIND — path does not exist: %s\n' "$PROG" "$target" >&2
		exit 3
	fi

	case "$BP_DISK_MIN_FREE_GB" in
	'' | *[!0-9]*) die_usage "BP_DISK_MIN_FREE_GB must be a whole number of GiB, got: $BP_DISK_MIN_FREE_GB" ;;
	esac

	if ! df_out=$(df -P -k -- "$target" 2>/dev/null); then
		printf '%s: BLIND — df failed on %s; refusing to report headroom it did not measure\n' \
			"$PROG" "$target" >&2
		exit 3
	fi

	if ! avail_kb=$(avail_kb_from_df "$df_out"); then
		printf '%s: BLIND — could not parse an Avail figure from df for %s\n' "$PROG" "$target" >&2
		printf '%s\n' "$df_out" >&2
		exit 3
	fi

	min_kb=$((BP_DISK_MIN_FREE_GB * 1024 * 1024))
	avail_gb=$((avail_kb / 1024 / 1024))

	if [ "$avail_kb" -lt "$min_kb" ]; then
		printf '%s: REFUSED — %s has %d GiB free, below the %d GiB floor.\n' \
			"$PROG" "$target" "$avail_gb" "$BP_DISK_MIN_FREE_GB" >&2
		printf '%s: starting work now risks ENOSPC across every lane at once.\n' "$PROG" >&2
		printf '%s: this guard deletes nothing. Reclaim deliberately (use trash, never rm),\n' "$PROG" >&2
		printf '%s: and never touch a worktree holding uncommitted work.\n' "$PROG" >&2
		exit 2
	fi

	printf '%s: OK — %s has %d GiB free (floor %d GiB)\n' \
		"$PROG" "$target" "$avail_gb" "$BP_DISK_MIN_FREE_GB"
	exit 0
}

main "$@"

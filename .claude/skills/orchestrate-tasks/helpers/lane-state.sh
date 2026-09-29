#!/usr/bin/env bash
# lane-state.sh <lane> [owner/repo] — reconstruct a lane's LIVE state for a takeover, from the
# three stores that are never stale: the ledger, GitHub and the worktrees on disk.
#
# WHEN: the FIRST command of a takeover whenever the predecessor's status file is older than the
# last line of its pulse log. The status file is a snapshot; the pulse log proves the lead kept
# working after it. Measured 2026-09-11 (task-57cfe2111cf4d7c0): lead-studio-r10 last wrote
# status.md at 09:40Z and died at 10:38Z; in between it closed five rows, cancelled one and opened
# SIX draft PRs it never recorded. The successor spent ~40 min and 8 tool calls re-deriving:
#
#   ## LEDGER     every in_progress row whose claim.worker starts with lead-<lane> (any round),
#                 with epoch, lease PR and lease expiry.
#   ## PRS        every open PR on <lane>/ or <lane>- branches — delegated to lane-open-prs.sh
#                 (ONE copy of that parse; a second copy here would diverge from it) — then each
#                 PR's Task: trailer checked against the LEDGER rows above.
#   ## WORKTREES  every git worktree of this repo on a <lane>/ or <lane>- branch, or in a
#                 <lane>-* directory, that carries commits not on origin/main, uncommitted
#                 tracked changes or untracked files — EXCLUDING a branch whose PR is MERGED. Squash merges make
#                 ancestry useless (a squash-merged branch stays "ahead" of main forever), so the
#                 merge verdict is asked of GitHub, per branch, over REST.
#
# RULES
#   * READ-ONLY. bp runs with BARKPARK_TOKEN unset; gh does GETs; git does no fetch and no write.
#     It reads origin/main as the repo last fetched it: a stale origin/main only makes a
#     worktree look MORE ahead, never hides one.
#   * A FAILED READ IS NEVER AN EMPTY SECTION. Every failed read prints `CANNOT READ <what>` and
#     the run exits 2. A section that read successfully and found nothing says so in words that
#     name the read ("the read SUCCEEDED …"), which no refusal prints.
#   * A worktree whose PR state could not be read is REPORTED under CANNOT READ, never dropped:
#     an unknown merge state is not a merged one.
#
# USAGE
#   lane-state.sh infra                         # repo FRIKKern/barkpark
#   lane-state.sh studio FRIKKern/barkpark
#   lane-state.sh infra --root /path/to/checkout   # which repo's worktrees (default: this file's)
#
# EXIT: 0 every read succeeded (with or without work) · 2 at least one CANNOT READ · 1 bad usage.
#
# TEST: lane-state.test.sh beside this file (offline; stubbed bp/gh, a scratch git repo).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE=""; REPO="FRIKKern/barkpark"; ROOT=""; nrepo=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0;;
    --*) echo "lane-state.sh: unknown flag '$1'" >&2; exit 1;;
    *) if [ -z "$LANE" ]; then LANE="$1"
       elif [ "$nrepo" = 0 ]; then REPO="$1"; nrepo=1
       else echo "lane-state.sh: too many arguments at '$1'" >&2; exit 1; fi
       shift;;
  esac
done
[ -n "$LANE" ] || { echo "usage: lane-state.sh <lane> [owner/repo] [--root DIR]" >&2; exit 1; }
case "$REPO" in */*) ;; *) echo "lane-state.sh: repo must be owner/name, got '$REPO'" >&2; exit 1;; esac
OWNER="${REPO%%/*}"
for t in jq gh git bp; do
  command -v "$t" >/dev/null 2>&1 || { echo "CANNOT READ: '$t' is not on PATH — nothing was measured"; exit 2; }
done
if [ -z "$ROOT" ]; then ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) || ROOT=""; fi

FAIL=0
TMP=$(mktemp -d) || { echo "CANNOT READ: mktemp failed"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
cant() { echo "CANNOT READ $*"; FAIL=$((FAIL+1)); }

echo "# lane-state $LANE repo=$REPO root=${ROOT:-?} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ------------------------------------------------------------------ LEDGER ----------------------
echo; echo "## LEDGER — in_progress rows claimed by lead-$LANE*"
LEDGER_OK=0
: > "$TMP/ledger.tsv"
if ! env -u BARKPARK_TOKEN bp task ls --status in_progress --all -o json > "$TMP/ls.json" 2> "$TMP/ls.err"; then
  cant "ledger: bp task ls --status in_progress failed: $(tr '\n' ' ' < "$TMP/ls.err" | cut -c1-300)"
elif ! jq -e '(.docs | type == "array") and (.page.has_more != true)' "$TMP/ls.json" >/dev/null 2>&1; then
  cant "ledger: bp answered but not with a complete .docs page ($(cut -c1-200 < "$TMP/ls.json" | tr '\n' ' '))"
else
  LEDGER_OK=1
  # .docs[].claim.worker is THIS verb's claim path (task.get puts it at .doc.claim.worker).
  jq -r --arg p "lead-$LANE" '.docs[]
    | select(((.claim.worker // "") | tostring) | startswith($p))
    | [ .doc_id, (.claim.worker), "epoch=\(.claim.epoch // "?")",
        "lease-pr=\(.claim.lease_extension.pr // "none")",
        "lease-expires=\(.claim.lease_expires_at // "?")",
        ((.title // "") | gsub("[\t\n]"; " ") | .[0:80]) ] | @tsv' "$TMP/ls.json" \
    | LC_ALL=C sort > "$TMP/ledger.tsv"
  cut -f1 "$TMP/ledger.tsv" > "$TMP/ledger.ids"
  scanned=$(jq '.docs | length' "$TMP/ls.json")
  n=$(grep -c . "$TMP/ledger.tsv")
  withheld=$(jq '(.page.dataset_ambiguous // []) | length' "$TMP/ls.json")
  if [ "$n" = 0 ]; then
    echo "NO in_progress rows claimed by lead-$LANE* — the read SUCCEEDED over $scanned in_progress row(s)."
  else
    echo "$n row(s) (of $scanned in_progress scanned):"
    tr '\t' ' ' < "$TMP/ledger.tsv"
  fi
  [ "$withheld" != 0 ] && echo "NOTE: $withheld doc_id(s) withheld as dataset-ambiguous by the listing — not examined."
fi

# ------------------------------------------------------------------ PRS -------------------------
echo; echo "## PRS — open PRs on $LANE/ and $LANE- branches (lane-open-prs.sh)"
if [ ! -f "$HERE/lane-open-prs.sh" ]; then
  cant "PRs: lane-open-prs.sh is not beside this file ($HERE)"
else
  bash "$HERE/lane-open-prs.sh" --repo "$REPO" "$LANE/,$LANE-" > "$TMP/prs.out" 2>&1; prc=$?
  cat "$TMP/prs.out"
  if [ "$prc" != 0 ]; then
    cant "PRs: lane-open-prs.sh exited $prc — the open-PR set above is INCOMPLETE"
  elif [ "$LEDGER_OK" = 1 ]; then
    # Cross-check each PR's Task: trailer against the ledger rows this lane holds.
    grep -E '^#[0-9]+ ' "$TMP/prs.out" | while IFS= read -r l; do
      num=${l%% *}; t=${l#* task=}; t=${t%% *}
      if [ "$t" = NONE ]; then echo "  $num task=NONE — no Task: trailer; the required task gate refuses this PR"
      elif grep -qxF -- "$t" "$TMP/ledger.ids"; then
        echo "  $num task=$t — claimed by this lane"
      else
        echo "  $num task=$t — NOT in_progress under lead-$LANE* (closed, released, or another lane's claim)"
      fi
    done
  else
    echo "  (trailer cross-check skipped: the LEDGER read failed above)"
  fi
fi

# ------------------------------------------------------------------ WORKTREES -------------------
echo; echo "## WORKTREES — $LANE/ or $LANE- branches (or $LANE-* dirs) with commits off origin/main or uncommitted files"
WT_OK=1
if [ -z "$ROOT" ] || ! git -C "$ROOT" worktree list --porcelain > "$TMP/wt.txt" 2> "$TMP/wt.err"; then
  cant "worktrees: git worktree list failed under root=${ROOT:-<none>} $(tr '\n' ' ' < "$TMP/wt.err" 2>/dev/null)"; WT_OK=0
elif ! git -C "$ROOT" rev-parse --verify -q origin/main > /dev/null; then
  cant "worktrees: origin/main does not resolve in $ROOT — ahead counts are unmeasurable"; WT_OK=0
elif ! git -C "$ROOT" ls-remote --heads origin > "$TMP/remote.txt" 2> "$TMP/remote.err"; then
  cant "worktrees: git ls-remote origin failed: $(tr '\n' ' ' < "$TMP/remote.err" | cut -c1-200)"; WT_OK=0
fi
if [ "$WT_OK" = 1 ]; then
  # porcelain blocks -> TSV: path, head, branch|-(detached), prunable(0/1). The first block is the
  # main checkout and is never a lane worktree.
  awk 'BEGIN{OFS="\t"}
       /^worktree /{ if (p!="") print p,h,b,pr; p=substr($0,10); h=""; b="-"; pr=0 }
       /^HEAD /{ h=$2 } /^branch /{ b=$2; sub("^refs/heads/","",b) } /^prunable/{ pr=1 }
       END{ if (p!="") print p,h,b,pr }' "$TMP/wt.txt" | tail -n +2 > "$TMP/wt.tsv"
  found=0; level=0; excluded=""; nexcl=0
  while IFS=$'\t' read -r path head br prunable; do
    base=${path##*/}
    case "$br" in "$LANE"/*|"$LANE"-*) ;; *) case "$base" in "$LANE"-*) ;; *) continue;; esac;; esac
    [ "$prunable" = 1 ] && { echo "$base: prunable (directory gone) — skipped"; continue; }
    if ! ahead=$(git -C "$ROOT" rev-list --count "origin/main..$head" 2>/dev/null); then
      cant "worktree $base: rev-list origin/main..$head failed"; continue
    fi
    if ! st=$(git -C "$path" status --porcelain --untracked-files=normal 2>/dev/null < /dev/null); then
      cant "worktree $base: git status failed"; continue
    fi
    # dirty = tracked changes; new = untracked files (a builder's not-yet-added script is work too).
    new=$(printf '%s\n' "$st" | grep -c '^??')
    dirty=$(( $(printf '%s' "$st" | grep -c .) - new ))
    if [ "$ahead" = 0 ] && [ "$dirty" = 0 ] && [ "$new" = 0 ]; then level=$((level+1)); continue; fi
    if [ "$br" = - ]; then
      echo "$base detached head=${head:0:10} ahead_main=$ahead dirty=$dirty untracked=$new — no branch, so no PR to ask GitHub about"
      found=$((found+1)); continue
    fi
    rsha=$(awk -v r="refs/heads/$br" '$2==r{print $1}' "$TMP/remote.txt")
    if [ -z "$rsha" ]; then pushed="no-remote-branch"
    elif [ "$rsha" = "$head" ]; then pushed="pushed"
    elif git -C "$ROOT" merge-base --is-ancestor "$head" "$rsha" 2>/dev/null; then pushed="pushed(remote-ahead)"
    else pushed="UNPUSHED(remote=${rsha:0:10})"; fi
    if ! gh api "repos/$REPO/pulls?state=all&head=$OWNER:$br&per_page=30" > "$TMP/pr.json" 2>/dev/null < /dev/null \
       || ! jq -e 'type == "array"' "$TMP/pr.json" >/dev/null 2>&1; then
      cant "worktree $base branch=$br ahead_main=$ahead dirty=$dirty untracked=$new: GitHub PR state unreadable — merge state UNKNOWN, not excluded"
      continue
    fi
    open=$(jq -r '[.[] | select(.state == "open") | .number] | map("#\(.)") | join(",")' "$TMP/pr.json")
    merged=$(jq -r '[.[] | select(.merged_at != null)] | sort_by(.merged_at) | last | if . then "\(.number) \(.head.sha)" else "" end' "$TMP/pr.json")
    closed=$(jq -r '[.[] | select(.state == "closed" and .merged_at == null) | .number] | map("#\(.)") | join(",")' "$TMP/pr.json")
    if [ -z "$open" ] && [ -n "$merged" ] && [ "$dirty" = 0 ] && [ "$new" = 0 ]; then
      mnum=${merged%% *}; msha=${merged#* }
      if [ "$msha" = "$head" ] || git -C "$ROOT" merge-base --is-ancestor "$head" "$msha" 2>/dev/null; then
        excluded="$excluded $base(#$mnum)"; nexcl=$((nexcl+1)); continue
      fi
      echo "$base branch=$br head=${head:0:10} ahead_main=$ahead dirty=$dirty untracked=$new $pushed — PR #$mnum MERGED, but this head is NOT in it (commits after the merge)"
      found=$((found+1)); continue
    fi
    prs="no PR"
    [ -n "$open" ] && prs="open PR $open"
    [ -z "$open" ] && [ -n "$closed" ] && prs="PR $closed CLOSED unmerged"
    [ -z "$open" ] && [ -n "$merged" ] && prs="PR #${merged%% *} MERGED, but uncommitted files remain"
    echo "$base branch=$br head=${head:0:10} ahead_main=$ahead dirty=$dirty untracked=$new $pushed — $prs"
    found=$((found+1))
  done < "$TMP/wt.tsv"
  echo "worktrees with work: $found · level with origin/main and clean: $level · excluded, PR merged: $nexcl"
  [ "$nexcl" != 0 ] && echo "excluded (PR merged):$excluded"
fi

echo
if [ "$FAIL" != 0 ]; then
  echo "lane-state: CANNOT READ — $FAIL read(s) failed. The sections above are INCOMPLETE; a missing line is not an absent item."
  exit 2
fi
echo "lane-state: OK — every read succeeded."
exit 0

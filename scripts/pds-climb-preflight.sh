#!/usr/bin/env bash
#
# pds-climb-preflight.sh — the five preconditions of the CROWN CLIMB, PROVEN
# at run time instead of remembered.
#
# Wave 12 fires ONE unsplit `scripts/pds-pull-proof.sh --all`. Three of its
# preconditions have been mis-remembered in prose across several waves, the
# fourth (a quiet deploy window) cannot be remembered at all — it is only ever
# true for the minute you measure it — and the fifth (a warm api/ tree) was
# invisible to every card in the repo until it killed a live arm. This script
# measures all five and prints ONE verdict line per check, then a single
# closing verdict.
#
# IT IS READ-ONLY, BY CONSTRUCTION:
#   · it NEVER fires an export (no /export call is made, at all)
#   · it NEVER takes the PDS-D31 lock ($FULL_DIR/lock is stat-ed, never mkdir-ed)
#   · it NEVER writes to $FULL_DIR — not the attempts counter, not the .meta,
#     not the tar. Running it a hundred times costs zero export budget.
#   · its only remote call is `git rev-parse HEAD` over SSH on the source box.
# Safe to run repeatedly, and MEANT to be: check 4 decays in seconds (PDS-D155's
# measured MINIMUM deploy gap is 9 SECONDS), so re-run it immediately before you
# fire and never reuse an older reading.
#
# THE FIVE CHECKS
#   1 WORKTREE (PDS-D225)   HEAD == origin/main, tree clean, harness blob frozen
#                           — verified with `git rev-parse`, NEVER shasum
#                           (PDS-D154: shasum reads b9eb6e3a… on the same bytes
#                           and a verifier reaching for it concludes the freeze
#                           broke). THE FREEZE VALUE IS DERIVED AT RUN TIME from
#                           `origin/main:scripts/pds-pull-proof.sh`, never a
#                           hand-edited literal: a pinned default goes false on
#                           the next harness commit and then refuses for a
#                           reason that reads as tampering. The wave-9/10 value
#                           e219e97c… survives only as the LAST-RESORT fallback
#                           when origin/main is unresolvable, and the refusal it
#                           produces says so in those words.
#   2 BUDGET (PDS-D224)     the required PDS_FULL_EXPORT_BUDGET is DERIVED from
#                           the attempts file read at run time: spent + 2. Never
#                           a literal — the store is HOST-LOCAL (PDS-D156) and a
#                           climb host reading 0 needs 2, not 3.
#   3 PARKED BUNDLE / THE RETRY-REUSE TRAP (PDS-D223)
#                           served_sha of the parked .meta printed beside the
#                           deployed sha, WARNING when they MATCH.
#   4 FIRE WINDOW           no deploy.yml run in_progress or queued, plus every
#                           open PR touching deploy.yml's push paths.
#   5 PRE-WARM (PDS-D258)   api/deps non-empty and api/_build present. Both are
#                           GITIGNORED, so a worktree cut fresh at origin/main —
#                           exactly the worktree check 1 demands — has NEITHER,
#                           and `arm` with the default pre-warm prints the full
#                           ARMED banner, returns 0, and the detached child dies
#                           on `** (Mix) Can't continue due to errors on
#                           dependencies` for ZERO draws. Nothing else in the
#                           repo can see this.
#
# USAGE
#   scripts/pds-climb-preflight.sh            report, exit 0 (the default)
#   scripts/pds-climb-preflight.sh --strict   exit 0 GO · 2 GO-WITH-WARN · 1 otherwise
#   scripts/pds-climb-preflight.sh --selftest hermetic arms over the freeze
#                                             resolver; no ssh, no gh, no network
#   scripts/pds-climb-preflight.sh --help
#
# The default exits 0 even on NO-GO ON PURPOSE: this script is committed and
# runs in CI-shaped gates from ordinary builder worktrees, where check 1 is
# EXPECTED to be red (a builder worktree is by definition not the climb
# worktree). A gate that reds there teaches people to skip it. Use --strict when
# the exit code is the thing you are acting on.
#
# ENV (all optional; the defaults mirror scripts/pds-pull-proof.sh exactly)
#   PDS_FULL_EXPORT_DIR      default /tmp/pds-full-export   (see the warning below)
#   PDS_FULL_EXPORT_BUDGET   default 1 — the value check 2 judges
#   PDS_SOURCE_SSH           default root@157.180.90.121
#   PDS_SOURCE_SSH_KEY       default ~/.ssh/barkpark_indx
#   PDS_DEPLOYED_SHA         skip the SSH probe and assert this sha instead
#   PDS_CLIMB_FREEZE_BLOB    the PER-CLIMB freeze override. Unset (the normal
#                            case) the freeze is DERIVED from origin/main; set,
#                            it pins the climb to a value you chose, and the
#                            transcript says which of the two it read.
#
# REPOINTING PDS_FULL_EXPORT_DIR FOR A REAL CLIMB IS FORBIDDEN (PDS-D223) — it
# hides a spend rather than paying it. The override exists so the warn path of
# check 3 can be exercised against a throwaway store; whenever it is set away
# from the default this script says REHEARSAL out loud in check 3's verdict.

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

HARNESS_REL="scripts/pds-pull-proof.sh"

# THE FREEZE IS A MEASUREMENT, NOT A MEMORY.
#
# This line was a hand-edited literal default — FREEZE_BLOB set from the
# override with the wave-9/10 blob as its shell-default operand. It went false
# on 2026-07-20, the first time anyone committed to the harness after wave 9/10,
# and it stayed false and SILENT for ~48 days while check 1 refused every
# worktree with "THE HARNESS IS NOT FROZEN" — which reads as tampering rather
# than as "this instrument default expired". Re-pinning the literal buys the
# same bug back on the next harness commit, so the value is now DERIVED from the
# ref the climb is actually cut from.
#
# Precedence, highest first:
#   1  $PDS_CLIMB_FREEZE_BLOB      — the PER-CLIMB override, taken verbatim
#   2  origin/main:$HARNESS_REL    — DERIVED, the normal path
#   3  $FREEZE_BLOB_HISTORICAL     — LAST RESORT, and every refusal built on it
#                                    names itself a historical wave-9/10 value
#                                    and names the override.
FREEZE_BLOB_HISTORICAL="e219e97ccf7f33797c86a2b84d998d599b6bda31"
FREEZE_BLOB=""
FREEZE_SOURCE=""

resolve_freeze_blob() {
  if [ -n "${PDS_CLIMB_FREEZE_BLOB:-}" ]; then
    FREEZE_BLOB="$PDS_CLIMB_FREEZE_BLOB"
    FREEZE_SOURCE="OVERRIDE — PDS_CLIMB_FREEZE_BLOB, set for this climb"
    return 0
  fi
  # --verify, AND a hex-shape test on the result. Measured while building the
  # selftest: bare `git rev-parse origin/main:scripts/pds-pull-proof.sh` on a
  # repo with no such ref exits 128 but ECHOES ITS OWN ARGUMENT ON STDOUT (the
  # "not a rev, so it must be a path" fallback), so `2>/dev/null || true` reads
  # back the literal string `origin/main:scripts/pds-pull-proof.sh`, a non-empty
  # value that is not a blob and that no real blob equals. That silently
  # resurrects the same class of bug this whole change removes — a freeze value
  # nothing measured. --verify suppresses the echo; the regex refuses anything
  # that is not 40 hex characters even if a future git changes its mind.
  FREEZE_BLOB="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/main:$HARNESS_REL" 2>/dev/null || true)"
  case "$FREEZE_BLOB" in
    *[!0-9a-f]* | "") FREEZE_BLOB="" ;;
  esac
  [ "${#FREEZE_BLOB}" -eq 40 ] || FREEZE_BLOB=""
  if [ -n "$FREEZE_BLOB" ]; then
    FREEZE_SOURCE="DERIVED — git rev-parse refs/remotes/origin/main:$HARNESS_REL, read just now"
    return 0
  fi
  FREEZE_BLOB="$FREEZE_BLOB_HISTORICAL"
  FREEZE_SOURCE="FALLBACK — the historical wave-9/10 literal; origin/main is unresolvable here, so NOTHING in this run measured the freeze"
  return 0
}

FULL_DIR_DEFAULT="/tmp/pds-full-export"
FULL_DIR="${PDS_FULL_EXPORT_DIR:-$FULL_DIR_DEFAULT}"
FULL_TAR="$FULL_DIR/full-${PDS_SOURCE_WORKSPACE:-default}.tar"
FULL_META="$FULL_TAR.meta"
FULL_ATTEMPTS_FILE="$FULL_DIR/attempts"
FULL_LOCK="$FULL_DIR/lock"
FULL_BUDGET="${PDS_FULL_EXPORT_BUDGET:-1}"

SOURCE_SSH="${PDS_SOURCE_SSH-root@157.180.90.121}"
SOURCE_SSH_KEY="${PDS_SOURCE_SSH_KEY:-$HOME/.ssh/barkpark_indx}"

# deploy.yml's on.push.paths, verbatim (.github/workflows/deploy.yml:9-24). The
# INSTANCE job — the only one that can move guerrilla's sha, and so the only one
# that can break rung 0b under a running climb — is gated more narrowly, on
# ^(api|internal|deploy|connectors)/ (deploy.yml:72, PDS-D155).
TRIGGER_PATHS='^(cloud|api|internal|deploy|templates|connectors)/|^\.github/workflows/deploy\.yml$'
INSTANCE_PATHS='^(api|internal|deploy|connectors)/'

STRICT=0
SELFTEST=0
# The help window is 2..HEADER_LAST. It is a LITERAL and it drifts the moment
# anyone edits the header, so --selftest arm (f) asserts the last line in the
# window is still the closing line of the header rather than shell code.
HEADER_LAST=82
case "${1:-}" in
  --strict) STRICT=1 ;;
  --selftest) SELFTEST=1 ;;
  -h|--help|help) sed -n "2,${HEADER_LAST}p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) printf 'usage: %s [--strict|--selftest|--help]\n' "$SELF" >&2; exit 3 ;;
esac

# ── output ───────────────────────────────────────────────────────────────────

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }

N_GO=0; N_WARN=0; N_NOGO=0

verdict() { # id label state detail
  case "$3" in
    GO)      N_GO=$((N_GO + 1)) ;;
    WARN)    N_WARN=$((N_WARN + 1)) ;;
    *)       N_NOGO=$((N_NOGO + 1)) ;;
  esac
  printf '\n  %-6s CHECK %s — %s\n' "$3" "$1" "$2"
  printf '         %s\n' "$4"
}

head_check() { # id title
  printf '\n'
  rule
  printf 'CHECK %s — %s\n' "$1" "$2"
  rule
}

# ── check 1 — WORKTREE (PDS-D225) ────────────────────────────────────────────

check_worktree() {
  head_check 1 "WORKTREE — clean origin/main, harness frozen (PDS-D225)"

  local head_sha origin_sha dirty blob state detail
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unresolved)"
  origin_sha="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo unresolved)"
  dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  # PDS-D154: the freeze value is a GIT BLOB hash. `shasum -a 1` on the same
  # bytes answers b9eb6e3a… and is the wrong instrument, always.
  blob="$(git -C "$REPO_ROOT" rev-parse "HEAD:$HARNESS_REL" 2>/dev/null || echo unresolved)"

  info "worktree ................. $REPO_ROOT"
  info "HEAD ..................... $head_sha"
  info "origin/main .............. $origin_sha  (as last fetched — this script never fetches)"
  info "uncommitted paths ........ $dirty"
  info "$HARNESS_REL blob"
  info "  measured (git rev-parse) $blob"
  info "  frozen at (PDS-D154) ... $FREEZE_BLOB"
  # RECORDED IN THE CLIMB TRANSCRIPT: a freeze you cannot trace to its source is
  # indistinguishable from a freeze someone typed in from memory.
  info "  freeze source .......... $FREEZE_SOURCE"

  state=GO; detail="clean origin/main worktree, harness blob matches the freeze"
  if [ "$blob" != "$FREEZE_BLOB" ]; then
    state=NO-GO
    detail="THE HARNESS IS NOT FROZEN at this HEAD — do not climb. PDS-D159: a rehearsal red is a FILED TASK, never a harness edit. Freeze source: $FREEZE_SOURCE."
    case "$FREEZE_SOURCE" in
      FALLBACK*)
        detail="$detail READ THAT SOURCE BEFORE CONCLUDING TAMPERING: the value this refusal compared against is the DEFAULT — a HISTORICAL wave-9/10 value ($FREEZE_BLOB_HISTORICAL) — not a reading of any tree, because origin/main could not be resolved here. Fetch origin and re-run so the freeze is DERIVED, or set PDS_CLIMB_FREEZE_BLOB to the per-climb freeze you actually mean."
        ;;
    esac
  elif [ "$head_sha" = unresolved ] || [ "$origin_sha" = unresolved ]; then
    state=NO-GO
    detail="HEAD or origin/main is unresolvable here — the climb needs a checkout whose provenance rung 0b can assert against."
  elif [ "$head_sha" != "$origin_sha" ]; then
    state=NO-GO
    detail="HEAD is not origin/main ($head_sha != $origin_sha). Climb from a FRESH origin/main worktree — rung 0b asserts the deployed sha is an ancestor of this one (pds-pull-proof.sh:645-657)."
  elif [ "$dirty" != "0" ]; then
    state=NO-GO
    detail="$dirty uncommitted path(s). The transcript must be dated by a sha that actually exists on origin."
  fi
  verdict 1 "WORKTREE" "$state" "$detail"
}

# ── check 2 — BUDGET (PDS-D224) ──────────────────────────────────────────────

check_budget() {
  head_check 2 "BUDGET — required = spent + 2, read at run time (PDS-D224)"

  local spent required state detail
  # Same reader as the harness (pds-pull-proof.sh:1247-1253): an absent, empty
  # or garbage counter reads 0 rather than empty.
  spent=0
  if [ -f "$FULL_ATTEMPTS_FILE" ]; then
    spent="$(tr -dc '0-9' <"$FULL_ATTEMPTS_FILE" | head -c 6)"
    spent="${spent:-0}"
  fi
  # NOT a literal. The store is HOST-LOCAL (PDS-D156): `attempts=1` is a fact
  # about one Mac, and a climb host reading 0 needs 2, not 3. Two, because the
  # climb is allowed exactly one fresh export plus one retry after a red.
  required=$((spent + 2))

  info "attempts file ............ $FULL_ATTEMPTS_FILE"
  info "spent (read just now) .... $spent"
  info "required budget .......... $spent + 2 = $required   ← derived, never a literal"
  info "PDS_FULL_EXPORT_BUDGET ... $FULL_BUDGET (default 1 when unset)"
  info "the gate itself .......... cond_c tests spent < budget (pds-pull-proof.sh:1313)"

  if [ "$spent" -lt "$FULL_BUDGET" ]; then
    state=GO
    detail="$spent < $FULL_BUDGET, so cond_c passes and one fresh export can be taken. For a retry after a red, export PDS_FULL_EXPORT_BUDGET=$required."
  else
    state=NO-GO
    detail="EXHAUSTED: $spent of $FULL_BUDGET. cond_c is false, so the climb cannot fire at all. Export PDS_FULL_EXPORT_BUDGET=$required before firing. Resetting $FULL_ATTEMPTS_FILE is FORBIDDEN (PDS-D212), and PDS_FULL_EXPORT_MIN_MEM_MB is NEVER the knob to move (PDS-D156) — it encodes a live OOM risk to the content API."
  fi
  verdict 2 "BUDGET" "$state" "$detail"
}

# ── deployed sha ─────────────────────────────────────────────────────────────

DEPLOYED_SHA=""
resolve_deployed_sha() {
  if [ -n "${PDS_DEPLOYED_SHA:-}" ]; then DEPLOYED_SHA="$PDS_DEPLOYED_SHA"; return 0; fi
  [ -n "$SOURCE_SSH" ] || return 0
  DEPLOYED_SHA="$(ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" \
    'cd /opt/barkpark && git rev-parse HEAD' 2>/dev/null | tr -d '[:space:]' || true)"
  return 0
}

# ── check 3 — PARKED BUNDLE / THE RETRY-REUSE TRAP (PDS-D223) ────────────────

check_parked_bundle() {
  head_check 3 "PARKED BUNDLE — the retry-reuse trap (PDS-D223)"

  local served bytes state detail lock_held="" rehearsal=""
  # STAT-ed, never mkdir-ed. Taking this lock is what an EXPORT does; a preflight
  # that took it would deadlock the very run it clears (pds-pull-proof.sh:1343).
  [ -d "$FULL_LOCK" ] && lock_held=1
  [ "$FULL_DIR" != "$FULL_DIR_DEFAULT" ] && rehearsal="REHEARSAL STORE ($FULL_DIR is not the default $FULL_DIR_DEFAULT; repointing it for a real climb is FORBIDDEN, PDS-D223). "

  served=""
  if [ -f "$FULL_META" ]; then
    served="$(awk '$1 == "served_sha:" { $1=""; sub(/^[ \t]+/, ""); print; exit }' "$FULL_META")"
  fi
  bytes=0
  [ -f "$FULL_TAR" ] && bytes="$(wc -c <"$FULL_TAR" | tr -d ' ')"

  info "parked tar ............... $FULL_TAR ($bytes bytes)"
  info "parked .meta served_sha .. ${served:-<none>}"
  info "deployed sha (live) ...... ${DEPLOYED_SHA:-<unresolved>}"
  info "the reuse gate ........... served_sha == deployed sha  =>  REUSED for 0 attempts"
  info "                           (pds-pull-proof.sh:1268-1283; the sidecar is written"
  info "                            stamped with the deployed sha at :1452)"

  if [ -n "$lock_held" ]; then
    info "export lock .............. HELD by another run — $FULL_LOCK  (stat-ed, never taken)"
  else
    info "export lock .............. free  ($FULL_LOCK absent; stat-ed, never taken)"
  fi

  if [ -n "$lock_held" ]; then
    state=NO-GO
    detail="${rehearsal}$FULL_LOCK is HELD — another full export is in flight. Two concurrent full exports OOM the box (PDS-D31). Wait for it, then re-run. Do NOT rmdir a lock this process did not create."
  elif [ -z "$DEPLOYED_SHA" ]; then
    state=UNKNOWN
    detail="${rehearsal}the deployed sha is unresolvable (SSH to $SOURCE_SSH failed and PDS_DEPLOYED_SHA is unset), so whether the parked bundle would be reused cannot be decided. A gate that cannot see is UNKNOWN, never OK (PDS-D98)."
  elif [ "$bytes" -lt 1024 ] || [ -z "$served" ]; then
    state=GO
    detail="${rehearsal}no usable parked bundle, so no reuse can fire — the climb's first --all takes a fresh export and spends one attempt."
  elif [ "$served" = "$DEPLOYED_SHA" ]; then
    state=WARN
    detail="${rehearsal}THE RETRY-REUSE TRAP IS ARMED. The parked bundle carries the CURRENTLY DEPLOYED sha, so the next --all REUSES it for 0 attempts and rungs 3/4 scan a bundle taken by ANOTHER invocation — a differential dated by this run's pin off someone else's bytes, with no warning in the transcript. This is exactly how a criterion-11 mosaic passes through the sanctioned path. Before firing: delete $FULL_TAR (+ .meta) — PDS-D223 PERMITS this, because it spends budget honestly rather than hiding the spend. Resetting the attempts file and repointing PDS_FULL_EXPORT_DIR stay FORBIDDEN."
  else
    state=GO
    detail="${rehearsal}parked bundle is STALE ($served != $DEPLOYED_SHA), so the reuse guard refuses it and a fresh export is taken. NOTE: the moment that fresh export lands it writes a .meta stamped with $DEPLOYED_SHA — re-run this preflight before ANY retry --all, when this check will WARN."
  fi
  verdict 3 "PARKED BUNDLE" "$state" "$detail"
}

# ── check 4 — FIRE WINDOW ────────────────────────────────────────────────────

check_fire_window() {
  head_check 4 "FIRE WINDOW — is the deploy pipeline quiet right now?"

  local running queued gh_rc prs hits instance_hits n state detail

  if ! command -v gh >/dev/null 2>&1; then
    info "gh ....................... NOT INSTALLED"
    verdict 4 "FIRE WINDOW" UNKNOWN "gh is not on PATH, so neither running deploys nor open PRs can be read. A gate that cannot see is UNKNOWN, never OK (PDS-D98)."
    return 0
  fi

  # gh's exit status is captured APART from its stdout: the GitHub API answers
  # 503 often enough to matter, and `… | tr … || true` would make an API error
  # and a genuinely quiet pipeline read identically (PDS-D98).
  gh_rc=0
  running="$(gh run list --workflow deploy.yml --branch main --status in_progress \
              --limit 10 --json databaseId -q '.[].databaseId' 2>/dev/null)" || gh_rc=$?
  if [ "$gh_rc" -eq 0 ]; then
    queued="$(gh run list --workflow deploy.yml --branch main --status queued \
                --limit 10 --json databaseId -q '.[].databaseId' 2>/dev/null)" || gh_rc=$?
  fi
  if [ "$gh_rc" -ne 0 ]; then
    verdict 4 "FIRE WINDOW" UNKNOWN "gh exited $gh_rc reading deploy.yml runs — the window is unreadable, not quiet."
    return 0
  fi

  running="$(printf '%s' "$running" | tr '\n' ' ' | tr -s ' ')"
  queued="$(printf '%s' "$queued" | tr '\n' ' ' | tr -s ' ')"
  info "deploy.yml in_progress ... ${running:-none}"
  info "deploy.yml queued ........ ${queued:-none}"

  hits=""; instance_hits=""
  # The PR read fails CLOSED for the same reason the run reads above do, and it
  # is captured SEPARATELY from its stdout for the same reason: `|| prs=""`
  # makes a 503 and a genuinely empty PR list read IDENTICALLY, and an empty
  # list flows all the way down to `state=GO … no open PR touches a deploy
  # path`. That is the precise vacuous green this check exists to prevent —
  # the quietest-looking verdict in the script, produced by not being able to
  # see. Empty-with-rc-0 is a real fact; empty-because-the-API-failed is not
  # (PDS-D98).
  pr_rc=0
  prs="$(gh pr list --state open --limit 100 --json number,files \
           -q '.[] | "\(.number)\t\([.files[].path] | join(" "))"' 2>/dev/null)" || pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    verdict 4 "FIRE WINDOW" UNKNOWN "the deploy.yml pipeline is quiet (in_progress:${running:-none} queued:${queued:-none}), but \`gh pr list\` exited $pr_rc, so open PRs on the deploy paths are UNREADABLE. A merge landing mid-climb moves guerrilla's sha and reds rung 0b (PDS-D78, minimum observed gap 9 SECONDS), and this check cannot currently rule one out. Unreadable is UNKNOWN, never quiet (PDS-D98). Re-run; the GitHub API 503s often enough that a retry usually clears it."
    return 0
  fi
  if [ -n "$prs" ]; then
    while IFS="$(printf '\t')" read -r n files; do
      [ -n "$n" ] || continue
      if printf '%s\n' $files | grep -qE "$TRIGGER_PATHS"; then
        hits="$hits #$n"
        printf '%s\n' $files | grep -qE "$INSTANCE_PATHS" && instance_hits="$instance_hits #$n"
      fi
    done <<EOF
$prs
EOF
  fi
  info "open PRs on deploy paths . ${hits:-none}"
  info "  ...of which move the box ${instance_hits:-none}   (deploy.yml:72 gates the instance job on ^(api|internal|deploy|connectors)/)"
  info "cadence (PDS-D155) ....... 33 guerrilla deploys/24h job-level · median gap 22.6 min ·"
  info "                           MINIMUM GAP 9 SECONDS · only 68.8% of gaps exceed 10 min."
  info "                           The ~58/day, ~28-min-median figure is PDS-D78's SUPERSEDED"
  info "                           run-level count (skipped instance jobs still report success)."
  info "                           There is no quiet-window mechanism: this reading is a"
  info "                           SNAPSHOT, never a reservation."

  if [ -n "$running" ] || [ -n "$queued" ]; then
    state=NO-GO
    detail="a deploy.yml run is in flight (in_progress:${running:-none} queued:${queued:-none}). It will move guerrilla's sha under the climb and red rung 0b mid-run (PDS-D78). Wait for it to land, THEN re-run this preflight."
  elif [ -n "$instance_hits" ]; then
    state=WARN
    detail="pipeline quiet this instant, but open PR(s)$instance_hits touch ^(api|internal|deploy|connectors)/ and would move the box the moment they merge. Do not fire while a merge of theirs is plausible — median gap 22.6 min, MINIMUM 9 SECONDS."
  elif [ -n "$hits" ]; then
    state=GO
    detail="pipeline quiet. Open PR(s)$hits touch deploy.yml push paths but NONE of them hit the instance filter, so merging them cannot move guerrilla's sha (PDS-D155: cloud/** and templates/** are absent from deploy.yml:72)."
  else
    state=GO
    detail="pipeline quiet and no open PR touches a deploy path. Re-read this immediately before firing — the minimum observed gap is 9 SECONDS."
  fi
  verdict 4 "FIRE WINDOW" "$state" "$detail"
}

# ── check 5 — PRE-WARM (PDS-D258) ────────────────────────────────────────────

check_prewarm_ready() {
  head_check 5 "PRE-WARM — can this worktree compile at all? (PDS-D258)"

  local api_dir deps_dir build_dir deps_n deps_state prod_state dev_state state detail
  # Resolved from the SCRIPT's OWN location, the way the launcher resolves its
  # API_DIR — never from cwd. A preflight invoked by absolute path from some
  # other directory must judge the tree it LIVES in, because that is the tree
  # `arm` will compile.
  api_dir="$REPO_ROOT/api"
  deps_dir="$api_dir/deps"
  build_dir="$api_dir/_build"

  # STAT ONLY, like every other read in this script. No mix, no compile, no
  # fetch, nothing written anywhere, and $FULL_DIR is not touched at all. The
  # entry count matters because a half-finished `mix deps.get` leaves an EMPTY
  # deps/ behind, and an empty deps/ is cold, not warm.
  # `find -L`, not bare `find`: deps/ is very often a SYMLINK to a warm tree's
  # deps, and bare find does not descend one — it reports 0 entries and this
  # check would call a genuinely warm worktree cold. Measured while building
  # this check, which is the only reason it reads -L.
  deps_n=0
  [ -d "$deps_dir" ] && deps_n="$(find -L "$deps_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  deps_state="ABSENT"
  [ -d "$deps_dir" ] && deps_state="present, $deps_n entr$([ "$deps_n" = 1 ] && echo y || echo ies)"
  prod_state="ABSENT"; [ -d "$build_dir/prod" ] && prod_state="present"
  dev_state="ABSENT";  [ -d "$build_dir/dev" ]  && dev_state="present"

  info "api tree ................. $api_dir"
  info "api/deps ................. $deps_state"
  info "api/_build/prod .......... $prod_state   ← what the D241 pre-warm compiles"
  info "api/_build/dev ........... $dev_state   ← what pds-scratch-target.sh up compiles"
  info "both are GITIGNORED ...... a worktree cut fresh at origin/main has NEITHER,"
  info "                           and check 1 demands exactly such a worktree."
  info "the launcher's pre-warm .. runs \`CC=/usr/bin/clang MIX_ENV=prod mix compile\`"
  info "                           (pds-crown-launch.sh:258 detached, :443 synchronous)."
  info "                           It NEVER runs \`mix deps.get\` — in either form."
  info "the flag that matters .... arm --prewarm-now compiles in the ARMING shell and"
  info "                           dies loudly at :441-444 on failure. The DEFAULT"
  info "                           pre-warm compiles inside the DETACHED child, where"
  info "                           a failure is invisible until \`collect\`."

  state=GO
  detail="api/deps holds $deps_n entr$([ "$deps_n" = 1 ] && echo y || echo ies) and both _build envs are present — the pre-warm has something to compile against. Arm with --prewarm-now anyway (PDS-D258): it moves any surviving compile failure into the arming shell, where you can see it."
  if [ ! -d "$api_dir" ]; then
    state=NO-GO
    detail="there is no $api_dir — this is not a Barkpark checkout, so nothing here can be pre-warmed or climbed from."
  elif [ ! -d "$deps_dir" ] || [ "$deps_n" -eq 0 ]; then
    state=NO-GO
    detail="COLD WORKTREE (PDS-D258): api/deps is ${deps_state}. \`arm\` will print the full ARMED banner and return 0, and the detached child will then die on \`** (Mix) Can't continue due to errors on dependencies\` -> \`prewarm: FAILED rc=1 — NOT firing\` -> EXIT 1, for ZERO draws — a dead climb you do not discover until \`collect\`. Pay the warm-up in THIS worktree first, then arm with --prewarm-now: cd api && mix deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile"
  elif [ ! -d "$build_dir/prod" ]; then
    state=NO-GO
    detail="COLD WORKTREE (PDS-D258): api/deps is warm but api/_build/prod is ABSENT, so the pre-warm is a full cold prod compile (~155 s) — paid inside the climb's own window under the default form, and its failure is invisible there until \`collect\`. Pay it here first, then arm with --prewarm-now: cd api && mix deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile"
  elif [ ! -d "$build_dir/dev" ]; then
    state=WARN
    detail="api/deps and api/_build/prod are warm, but api/_build/dev is ABSENT. The pre-warm only ever compiles MIX_ENV=prod, so this one is not caught by --prewarm-now: \`pds-scratch-target.sh up --verify\` pays it instead, as a >10-minute cold dev compile. Pay it before you arm: cd api && mix deps.get && MIX_ENV=dev mix compile && CC=/usr/bin/clang MIX_ENV=prod mix compile"
  fi
  verdict 5 "PRE-WARM" "$state" "$detail"
}

# ── --selftest — the freeze resolver, proved hermetically ────────────────────
#
# HERMETIC BY CONSTRUCTION: every arm runs against a throwaway git repo built by
# this function. No ssh, no gh, no network, no read of $FULL_DIR, and it never
# touches the real REPO_ROOT except to grep this file's own source.
#
# EVERY ARM ASSERTS A COUNT, and every count is taken by grepping a FILE. A
# `printf ... | grep -q` arm cannot be trusted here: under `set -o pipefail` a
# short-circuiting grep kills printf and the pipeline reports 141, and an arm
# written as `grep -q ... || fail` silently passes on EMPTY output — the exact
# way a guard becomes decoration.

ST_FAIL=0
ST_RUN=0

st_eq() { # label want got
  ST_RUN=$((ST_RUN + 1))
  if [ "$2" = "$3" ]; then
    printf '  PASS  %s\n' "$1"
  else
    ST_FAIL=$((ST_FAIL + 1))
    printf '  FAIL  %s\n          want: %s\n          got:  %s\n' "$1" "$2" "$3"
  fi
}

st_ne() { # label not-want got
  ST_RUN=$((ST_RUN + 1))
  if [ "$2" != "$3" ]; then
    printf '  PASS  %s\n' "$1"
  else
    ST_FAIL=$((ST_FAIL + 1))
    printf '  FAIL  %s\n          must differ from: %s\n' "$1" "$2"
  fi
}

st_count() { # label file want-count fixed-needle
  local n
  # grep -c on a FILE, never a pipe; `|| true` because grep exits 1 on zero
  # matches and 0 is a legitimate expected count here.
  n="$(grep -c -F -- "$4" "$2" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  st_eq "$1 (count of: $4)" "$3" "$n"
}

st_count_re() { # label file want-count ere-needle
  local n
  n="$(grep -c -E -- "$4" "$2" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  st_eq "$1 (ERE count of: $4)" "$3" "$n"
}

st_mkrepo() { # dir first-content [second-content]
  mkdir -p "$1/scripts"
  git -C "$1" init -q
  printf '%s\n' "$2" >"$1/$HARNESS_REL"
  git -C "$1" add -A
  git -C "$1" -c user.name=selftest -c user.email=selftest@example.invalid \
      commit -qm "fixture 1"
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  if [ "${3:-}" != "" ]; then
    printf '%s\n' "$3" >"$1/$HARNESS_REL"
    git -C "$1" add -A
    git -C "$1" -c user.name=selftest -c user.email=selftest@example.invalid \
        commit -qm "fixture 2"   # origin/main deliberately LEFT BEHIND at 1
  fi
}

run_selftest() {
  local tmp r_ok r_drift r_noorigin out want got
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pds-preflight-selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  say ""
  rule
  say "PDS CROWN-CLIMB PREFLIGHT — SELFTEST (freeze resolution)"
  rule

  r_ok="$tmp/ok"
  r_drift="$tmp/drift"
  r_noorigin="$tmp/noorigin"
  st_mkrepo "$r_ok" "harness fixture ALPHA"
  st_mkrepo "$r_drift" "harness fixture ALPHA" "harness fixture BRAVO"
  st_mkrepo "$r_noorigin" "harness fixture CHARLIE"
  git -C "$r_noorigin" update-ref -d refs/remotes/origin/main

  # ── (a) DERIVED is the normal path, and it is a MEASUREMENT ────────────────
  want="$(git -C "$r_ok" rev-parse "refs/remotes/origin/main:$HARNESS_REL")"
  # FIXTURE TWINS MUST BE DISTINCT FIRST: if the derived value happened to equal
  # the historical literal, arm (a) would pass for a script that still hardcodes.
  st_ne "(a0) fixture blob is DISTINCT from the historical literal" \
        "$FREEZE_BLOB_HISTORICAL" "$want"
  got="$( REPO_ROOT="$r_ok"; unset PDS_CLIMB_FREEZE_BLOB; resolve_freeze_blob; printf '%s' "$FREEZE_BLOB" )"
  st_eq "(a1) freeze is DERIVED from origin/main:$HARNESS_REL" "$want" "$got"
  got="$( REPO_ROOT="$r_ok"; unset PDS_CLIMB_FREEZE_BLOB; resolve_freeze_blob; printf '%s' "${FREEZE_SOURCE%% *}" )"
  st_eq "(a2) the transcript labels that source DERIVED" "DERIVED" "$got"

  # ── (b) the per-climb override still wins ──────────────────────────────────
  got="$( REPO_ROOT="$r_ok"; PDS_CLIMB_FREEZE_BLOB=0000000000000000000000000000000000000000; resolve_freeze_blob; printf '%s' "$FREEZE_BLOB" )"
  st_eq "(b1) PDS_CLIMB_FREEZE_BLOB outranks the derivation" \
        "0000000000000000000000000000000000000000" "$got"
  got="$( REPO_ROOT="$r_ok"; PDS_CLIMB_FREEZE_BLOB=0000000000000000000000000000000000000000; resolve_freeze_blob; printf '%s' "${FREEZE_SOURCE%% *}" )"
  st_eq "(b2) the transcript labels that source OVERRIDE" "OVERRIDE" "$got"

  # ── (c) a DERIVED refusal must NOT blame a historical value ────────────────
  out="$tmp/derived-refusal.txt"
  ( REPO_ROOT="$r_drift"; unset PDS_CLIMB_FREEZE_BLOB; resolve_freeze_blob; check_worktree ) >"$out" 2>&1
  st_count "(c1) a drifted harness still refuses" "$out" 1 "THE HARNESS IS NOT FROZEN"
  st_count "(c2) the refusal names its freeze source" "$out" 1 "Freeze source: DERIVED"
  st_count "(c3) a DERIVED refusal never blames wave-9/10" "$out" 0 "HISTORICAL wave-9/10"

  # ── (d) the FALLBACK refusal explains ITSELF ───────────────────────────────
  # This is the whole point of the row: the shape that refused for ~48 days said
  # only "not frozen". If the derivation is impossible, the refusal must say the
  # value is historical and name the override.
  out="$tmp/fallback-refusal.txt"
  ( REPO_ROOT="$r_noorigin"; unset PDS_CLIMB_FREEZE_BLOB; resolve_freeze_blob; check_worktree ) >"$out" 2>&1
  st_count "(d1) fallback path is labelled FALLBACK" "$out" 1 "Freeze source: FALLBACK"
  st_count "(d2) the refusal says the default is HISTORICAL wave-9/10" "$out" 1 "HISTORICAL wave-9/10"
  st_count "(d3) the refusal names the per-climb override" "$out" 1 "set PDS_CLIMB_FREEZE_BLOB"
  # TWO lines, and the count is pinned at 2 on purpose: the `frozen at` info
  # line AND the refusal detail. A reader who sees only the info line cannot
  # tell a measured freeze from a remembered one, so both must carry it.
  st_count "(d5) the historical value appears on BOTH the info line and the refusal" "$out" 2 "$FREEZE_BLOB_HISTORICAL"

  # ── (g) the GO path records the freeze in the transcript too ───────────────
  # Arms (c)/(d) read the REFUSAL detail, so deleting the transcript info line
  # left them all green — measured, as MUT-3. The record has to be asserted on
  # the path where check 1 PASSES, because that is the transcript a climb ships.
  out="$tmp/go-transcript.txt"
  ( REPO_ROOT="$r_ok"; unset PDS_CLIMB_FREEZE_BLOB; resolve_freeze_blob; check_worktree ) >"$out" 2>&1
  st_count "(g0) this arm really is the GO path" "$out" 0 "THE HARNESS IS NOT FROZEN"
  st_count "(g1) a PASSING check 1 still records the freeze source" "$out" 1 "freeze source .......... DERIVED"
  # 2: `measured` and `frozen at`. On the GO path they are EQUAL by definition,
  # and the count pins that they are both printed rather than one collapsed away.
  st_count "(g2) ...beside both the measured and the frozen value" "$out" 2 "$want"

  # ── (e) the rot-by-construction shape cannot come back ─────────────────────
  # The defect was a NON-EMPTY shell default on the override. `${VAR:-}` (empty)
  # is the legal guard and must not trip this. Needle assembled in two pieces so
  # the arm does not match its own source line.
  local rot
  rot='PDS_CLIMB_FREEZE_BLOB'
  rot="$rot:-[0-9a-f]"
  st_count_re "(e1) no hand-pinned blob default survives in this file" "$0" 0 "$rot"
  st_count "(e2) the historical value survives ONLY as the named fallback" "$0" 1 "FREEZE_BLOB_HISTORICAL=\"$FREEZE_BLOB_HISTORICAL\""

  # ── (f) --help's line window still ends on the header ──────────────────────
  # HEADER_LAST is a literal; this arm is what makes editing the header above
  # safe, because the window silently swallowing shell code is otherwise mute.
  out="$tmp/header-window.txt"
  sed -n "${HEADER_LAST}p" "$0" >"$out"
  st_count_re "(f1) HEADER_LAST is inside the comment header" "$out" 1 '^#'
  sed -n "$((HEADER_LAST + 1))p" "$0" >"$out"
  st_count_re "(f2) HEADER_LAST is the LAST header line" "$out" 0 '^#'

  printf '\n'
  rule
  if [ "$ST_FAIL" -eq 0 ]; then
    say "SELFTEST: PASS — $ST_RUN assertion(s), 0 failed."
    rule
    return 0
  fi
  say "SELFTEST: FAIL — $ST_FAIL of $ST_RUN assertion(s) failed."
  rule
  return 1
}

if [ "$SELFTEST" -eq 1 ]; then
  run_selftest
  exit $?
fi

# ── main ─────────────────────────────────────────────────────────────────────

say ""
rule
say "PDS CROWN-CLIMB PREFLIGHT — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
rule
say "READ-ONLY. This script fires no export, takes no PDS-D31 lock, and writes"
say "nothing under $FULL_DIR. It costs ZERO export budget."
say "The invocation it clears is:  scripts/pds-pull-proof.sh --all"
say "(--step IS NOT A FLAG. The parser at pds-pull-proof.sh:2574-2603 accepts only"
say " --plan|--all|--only <ids>|--help and exits 3 having run NOTHING.)"

resolve_freeze_blob
resolve_deployed_sha
check_worktree
check_budget
check_parked_bundle
check_fire_window
# Last, and cheap: check 5 is four `test -d`s, so it cannot stale check 4's
# window reading. It is also the only check that judges the ARMING shell rather
# than the source plane.
check_prewarm_ready

printf '\n'
rule
if [ "$N_NOGO" -gt 0 ]; then
  say "VERDICT: NO-GO — $N_NOGO check(s) block the climb, $N_WARN warn, $N_GO clear."
  say "Fix the blocking check(s) above and re-run. Do not fire on a stale reading."
  rule
  [ "$STRICT" -eq 1 ] && exit 1
elif [ "$N_WARN" -gt 0 ]; then
  say "VERDICT: GO WITH WARNINGS — $N_WARN warn, $N_GO clear, 0 block."
  say "Every warning above names an action. Take it, then re-run."
  rule
  [ "$STRICT" -eq 1 ] && exit 2
else
  say "VERDICT: GO — all $N_GO checks clear."
  say "Fire NOW: the window reading decays in seconds (PDS-D155 min gap = 9s)."
  rule
fi
exit 0

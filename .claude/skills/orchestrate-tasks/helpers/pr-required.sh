#!/usr/bin/env bash
# pr-required.sh <pr-number> [owner/repo] — the truth about a PR's REQUIRED checks, by head sha.
# `gh pr checks` renders cancelled/queued in the same column as fail; this reads check-runs for the
# PR's current head and prints one line per required context with its real status/conclusion.
#
# CONTRACT: the verdict line ("MERGEABLE: 4/4 …" / "NOT YET: n/4 …" / "CONFLICTING: 4/4 … DIRTY") is ALWAYS THE LAST LINE. MERGEABLE now also means not DIRTY.
# Callers do `| tail -1`. Anything appended after it silently swaps what every wrapper reads
# (measured 2026-09-02: an EARLY RED section appended here made a lane's watcher report a job
# name where the verdict should be, and would have stopped the merge sweep merging anything).
#
# SELFTEST: `pr-required.sh --selftest` drives six arms (healthy PR / unreadable repo /
# unreadable head sha / unfetchable check-runs / repo-arg omitted / genuine 0/4) against a stub `gh` on PATH,
# from a cwd that is NOT a git repo, and asserts for each that `| tail -1` reads the verdict or
# the refusal — never an intermediate line — that no refusal contains the string "0/4", and
# that an HONEST 0/4 (four required contexts present, all failed) still verdicts at exit 0.
# It makes NO network calls. Run it after ANY edit to this file.
set -u
SELF="${BASH_SOURCE[0]}"; case "$SELF" in */*) SELFDIR="${SELF%/*}";; *) SELFDIR=".";; esac
# ------------------------------------------------------------------ SELFTEST (no network) ----
selftest() {
  local d rc out last fails=0 label want wantrc brk
  d=$(mktemp -d) || return 1
  mkdir -p "$d/bin" "$d/norepo"
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. GH_STUB_BREAK names the ONE read that fails; everything else answers healthily,
# so a refusal proves specificity, not a blanket refusal.
case "$1 $2" in
  "repo view"*) [ "${GH_STUB_BREAK:-}" = repo ] && exit 1; echo "acme/widget"; exit 0;;
  "pr view"*)   [ "${GH_STUB_BREAK:-}" = sha ]  && exit 1; echo "aaaaaaaaaa11112222333344445555666677778888"; exit 0;;
esac
if [ "$1" = api ]; then
  for a in "$@"; do
    case "$a" in
      */check-runs*)   [ "${GH_STUB_BREAK:-}" = runs ] && exit 1
                       # GH_STUB_ALLRED: the four required contexts EXIST on this head and every
                       # one concluded failure — a real, measured 0/4, not a failed read.
                       c=success; [ "${GH_STUB_ALLRED:-}" = 1 ] && c=failure
                       printf '%s\n' \
                         "Cloud gate	completed	$c	2026-01-01T00:00:00Z" \
                         "Console gate	completed	$c	2026-01-01T00:00:00Z" \
                         "Elixir gate	completed	$c	2026-01-01T00:00:00Z" \
                         "PR references an active task	completed	$c	2026-01-01T00:00:00Z"
                       exit 0;;
      */actions/runs*) echo 0; exit 0;;
      */pulls/*)       [ "${GH_STUB_BREAK:-}" = sha ] && exit 1
                       case " $* " in *" .mergeable_state"*) echo clean;; *) echo "aaaaaaaaaa11112222333344445555666677778888";; esac
                       exit 0;;
    esac
  done
fi
exit 0
STUB
  chmod +x "$d/bin/gh"
  _arm() { # label  expected-LAST-line-prefix  expected-exit  GH_STUB_BREAK  args...
    label="$1"; want="$2"; wantrc="$3"; brk="$4"; shift 4
    out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_STUB_BREAK="$brk" GH_STUB_ALLRED="${ALLRED:-}" GH_REPO="" bash "$SELF" "$@" 2>/dev/null ); rc=$?
    last=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" = "$wantrc" ] && case "$last" in "$want"*) true;; *) false;; esac; then
      printf 'PASS %-20s exit=%s | tail -1: %s\n' "$label" "$rc" "$last"
    else
      printf 'FAIL %-20s exit=%s (want %s) | tail -1: %s (want prefix %s)\n' "$label" "$rc" "$wantrc" "$last" "$want"; fails=$((fails+1))
    fi
    if [ "$want" = "CANNOT READ" ]; then
      case "$out" in *0/4*) printf 'FAIL %-20s the string 0/4 appears in a refusal\n' "$label"; fails=$((fails+1));; esac
    fi
  }
  _arm "healthy PR"       "MERGEABLE: 4/4"  0 ""     42 acme/widget
  cp "$SELF" "$d/norepo/pr-required.sh"   # arm 2 runs a copy that has NO git remote at its own dir
  out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_STUB_BREAK=repo GH_REPO="" bash "$d/norepo/pr-required.sh" 42 2>/dev/null ); rc=$?
  last=$(printf '%s\n' "$out" | tail -1)
  case "$rc:$last" in
    3:"CANNOT READ"*) printf 'PASS %-20s exit=3 | tail -1: %s\n' "unreadable repo" "$last";;
    *) printf 'FAIL %-20s exit=%s | tail -1: %s\n' "unreadable repo" "$rc" "$last"; fails=$((fails+1));;
  esac
  case "$out" in *0/4*) printf 'FAIL %-20s the string 0/4 appears in a refusal\n' "unreadable repo"; fails=$((fails+1));; esac
  _arm "unreadable sha"   "CANNOT READ"     3 sha    42 acme/widget
  _arm "unfetchable runs" "CANNOT READ"     3 runs   42 acme/widget
  # Arm 5: NO repo argument and `gh repo view` dead — the git-remote fallback must still resolve
  # owner/repo from the directory the SCRIPT lives in, so a lead calling `pr-required.sh <pr>`
  # from any cwd gets a verdict instead of the empty-repo lie. This is the cwd trigger.
  git init -q "$d/r" 2>/dev/null && git -C "$d/r" remote add origin git@github.com:acme/widget.git 2>/dev/null
  cp "$SELF" "$d/r/pr-required.sh"
  out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_STUB_BREAK=repo GH_REPO="" bash "$d/r/pr-required.sh" 42 2>/dev/null ); rc=$?
  last=$(printf '%s\n' "$out" | tail -1)
  case "$rc:$last" in
    0:MERGEABLE:*) printf 'PASS %-20s exit=0 | tail -1: %s\n' "git-remote default" "$last";;
    *) printf 'FAIL %-20s exit=%s | tail -1: %s\n' "git-remote default" "$rc" "$last"; fails=$((fails+1));;
  esac
  # Arm 6 — ANTI-OVER-REACH. A head whose four required contexts all EXIST and all concluded
  # failure is a genuine, measured zero. The refusal must NOT swallow it: the verdict stays
  # "NOT YET: 0/4 …" at exit 0. This arm FAILS if anyone widens the CANNOT READ guard to cover
  # "no required context is green", which would make an honest red indistinguishable from a
  # broken read in the opposite direction.
  ALLRED=1 _arm "genuine 0/4"    "NOT YET: 0/4"    0 ""     42 acme/widget
  unset ALLRED
  rm -rf "$d"
  if [ "$fails" = 0 ]; then echo "SELFTEST: 6/6 arms pass"; return 0; fi
  echo "SELFTEST: $fails assertion(s) FAILED"; return 1
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
PR="${1:?pr number}"
# RESOLVING owner/repo. `gh repo view --json` goes over GraphQL (its own per-user budget, which
# empties long before REST does) AND is resolved from the CALLER'S cwd — which resets between tool
# calls in this harness. Either failure yields an EMPTY $REPO, every URL below becomes "repos//…"
# which 404s, and this script printed "0/4" for a PR that was at 3/4 (measured 2026-09-02).
# The campaign's own LEAD-BRIEF tells leads to call this with NO repo argument, so the cwd trigger
# is live on every such call and needs no GraphQL outage to fire. Resolve cheapest-and-most-
# reliable first, GraphQL LAST:
#   1. arg 2   2. $GH_REPO   3. git remote of the dir this SCRIPT lives in (no network, no GraphQL,
#   cwd-independent)   4. git remote of the cwd   5. gh repo view (GraphQL) — and refuse if none.
_repo_from_git() { # $1 = directory to ask; prints owner/repo, or nothing
  local url
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$url" ] || return 0
  url="${url%.git}"; url="${url%/}"       # git@host:OWNER/REPO.git | https://host/OWNER/REPO.git | ssh://git@host/OWNER/REPO
  case "$url" in *[:/]*/*) printf '%s/%s\n' "$(basename "$(dirname "$url")")" "$(basename "$url")";; esac
}
REPO="${2:-}"
[ -n "$REPO" ] || REPO="${GH_REPO:-}"
[ -n "$REPO" ] || REPO=$(_repo_from_git "$SELFDIR")
[ -n "$REPO" ] || REPO=$(_repo_from_git ".")
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$REPO" ]; then
  echo "CANNOT READ: no owner/repo — pass it as arg 2 (or set GH_REPO). No git remote at this script's own directory or at the cwd, and gh repo view (GraphQL) failed too. This is NOT a verdict, and NOT a count of zero green."
  exit 3
fi
REQ='Elixir gate|PR references an active task|Cloud gate|Console gate'
# READ THE HEAD SHA, AND REFUSE IF IT CANNOT BE READ (lead-silent, 2026-09-02).
# `gh pr view --json` goes over GraphQL, which has its OWN per-user limit that empties long
# before REST does — `gh api rate_limit` can report graphql 5000/5000 remaining while every
# gh pr view returns "API rate limit already exceeded for user ID". When that happened, SHA
# went EMPTY, the check-runs URL became .../commits//check-runs and 404'd, RUNS was empty, and
# this script printed "NOT YET: 0/4 required green on " AND EXITED 0. A failed read was
# byte-identical to "nothing is green" for every one of the eighteen lanes reading `| tail -1`,
# and the merge sweep would have stalled the whole campaign without one error anyone could see.
# So: fall back to REST (which still works when GraphQL is spent), and if BOTH fail, REFUSE on
# the LAST line with a non-zero exit rather than reporting a number we did not measure.
SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || true)
if [ -z "$SHA" ]; then
  SHA=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)
fi
if [ -z "$SHA" ]; then
  echo "CANNOT READ: pr #$PR head sha unreadable over BOTH GraphQL and REST — this is NOT a verdict, and NOT a count of zero green. Check \`gh auth status\` and \`gh api rate_limit\`; GraphQL empties before REST does."
  exit 3
fi
# MERGE STATE: four green checks do NOT mean the PR can merge; a DIRTY branch is refused by GitHub regardless.
# Read mergeable_state over REST (one call) so the LAST LINE never says MERGEABLE for a conflicting branch.
MSTATE=$(gh api "repos/$REPO/pulls/$PR" --jq '.mergeable_state // "-"' 2>/dev/null || echo "-")
if ! RUNS=$(gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")\t\(.started_at // "-")"' 2>/dev/null); then
  echo "CANNOT READ: check-runs for $REPO@${SHA:0:10} could not be fetched — this is NOT a verdict, and NOT a count of zero green."
  exit 3
fi
# A head with ZERO check runs is also not a verdict: CI has not started, or the read was empty
# for a reason we cannot see. Saying "0/4" there is the same lie in a quieter voice.
if [ -z "$RUNS" ]; then
  echo "CANNOT READ: $REPO@${SHA:0:10} has NO check runs at all — CI has not started, or the read came back empty. This is NOT a verdict, and NOT a count of zero green."
  exit 3
fi

# EARLY RED, printed BEFORE the verdict: the aggregate "Elixir gate" context stays QUEUED for
# 20+ min while the `Test (Elixir …)` job it depends on has already FAILED. Advisory jobs are
# excluded by name — Format/Boundary/spec-drift are advisory and most api PRs carry one, so
# naming them here would make the line fire on everything and stop discriminating.
printf '%s\n' "$RUNS" | awk -F'\t' '$3=="failure"{print $1}' \
  | grep -viE 'advisory' | grep -vE "^($REQ)$" | sort -u \
  | sed 's/^/  RED non-required job (blocks the aggregate ONLY if it is in elixir.yml needs; security.yml reds do NOT): /'

# ABSENT vs FAILED: a required context with NO check run on this head (its dispatcher was cancelled, or the run
# was evicted) reads as "3/4" exactly like a failing one, and needs the OPPOSITE remedy (re-fire the dispatcher /
# update-branch, not fix the code). Name the absent ones explicitly, before the verdict.
ABSENT=$(printf '%s\n' "$REQ" | tr '|' '\n' | while read -r ctx; do printf '%s\n' "$RUNS" | grep -qF "$ctx	" || printf '%s; ' "$ctx"; done)
# An aggregator's check run is not created until its run is scheduled, so "no check run yet" on a head whose
# workflow run is still queued/in_progress is PENDING, not absent. Only call it ABSENT when nothing is running.
if [ -n "$ABSENT" ]; then
  LIVE=$(gh api "repos/$REPO/actions/runs?head_sha=$SHA&per_page=50" --jq '[.workflow_runs[]|select(.status!="completed")]|length' 2>/dev/null || echo 0)
  if [ "${LIVE:-0}" -gt 0 ]; then echo "  PENDING required context (no check run yet, but $LIVE workflow run(s) still queued/in_progress on this head — wait, do not re-fire): ${ABSENT%; }"; ABSENT=""
  else echo "  ABSENT required context (no check run on this head and nothing running — re-fire with: gh api -X PUT repos/$REPO/pulls/$PR/update-branch): ${ABSENT%; }"; fi
fi
printf '%s\n' "$RUNS" | grep -E "^($REQ)	" | sort -t$'\t' -k1,1 -k4,4r | awk -F'\t' '!seen[$1]++' \
  | awk -F'\t' -v sha="$SHA" -v ms="$MSTATE" -v absent="$ABSENT" 'BEGIN{ok=0;n=0} {n++; printf "%-32s %-12s %s\n",$1,$2,$3; if($3=="success")ok++} END{ if(ok==4 && ms=="dirty") printf "CONFLICTING: 4/4 required green on %s but the branch is DIRTY — rebase before merge\n",substr(sha,1,10); else if(ok<4 && absent!="") printf "NOT YET: %d/4 required green on %s (%d ABSENT — re-fire, do not debug)\n",ok,substr(sha,1,10),4-n; else printf "%s: %d/4 required green on %s\n",(ok==4?"MERGEABLE":"NOT YET"),ok,substr(sha,1,10)}'

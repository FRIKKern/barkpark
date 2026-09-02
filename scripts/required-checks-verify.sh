#!/usr/bin/env bash
# required-checks-verify.sh — the three-way drift guard: LIVE branch protection,
# the COMMITTED spec, and the check names a real PR head actually renders must
# all agree, and this script fails when it cannot see any one of them.
#
# WHAT IT CATCHES THAT GITHUB WILL NOT TELL YOU (honest-gates D21, D41)
#
#   * A context string GitHub accepted and nothing publishes. `PUT` with
#     `Test (Elixir 1.18.1 / OTP 27.O)` (capital O) returned 200 and read the
#     typo back verbatim. The PR then sits "expected" forever.
#   * `app_id: 99999999` returns 200 and reads back `app_id: null` — "ANY app
#     may satisfy this context". Anything with `checks:write` can then publish a
#     matching name, so a typo'd id silently converts a pinned gate into a
#     spoofable one. `null` where the spec pins an id is a HARD failure here.
#   * State nobody committed. The protection PUT does NOT converge: omitting
#     `required_linear_history` / `required_conversation_resolution` leaves them
#     TRUE while `allow_force_pushes` resets to false. So this diffs the FULL
#     read-back object, not just the keys the spec happens to mention — an
#     unaccounted key is a failure, because that is exactly the shape an
#     "idempotent apply" hides behind.
#   * A spec that says the gate is OFF while the gate is ON (cch-w51-s6). This
#     is the direction the script used to decline to look in: with
#     `enforced=false` it returned 0 before ever reading live protection, so a
#     checkout carrying a stale or post-break-glass spec reported "protection is
#     not applied yet" while required contexts were blocking under
#     enforce_admins. Both directions are read now — see probe_live_protection.
#
# THE DEADLOCK DETECTOR IS A SET DIFFERENCE, NOT A MESSAGE GREP (D38)
#
# At N=2 required checks GitHub's refusal reads `2 of 2 required status checks
# are expected.` — counts and categories, NEVER a name. A detector that greps
# the refusal for a context works at N=1 and silently returns nothing the moment
# a second check is added. So: take the committed spec's contexts, take the
# check-run names actually rendered on a real head, and subtract. Missing names
# are a DEADLOCK — a third state, exit 3, distinct from pass and fail. Extra
# rendered names are tolerated: new advisory checks land constantly.
#
# AND A FOURTH SURFACE: WHAT THE WORKFLOWS TELL THE BUILDER (cch-w32-s4)
#
# A required context is only half a contract; the other half is what a builder
# reading the workflow believes about their red. console-harness.yml said in
# three places that `Console gate` was "ADVISORY today" for two waves after it
# became required — a comment that rots is a gate lying about itself. So the
# committed spec's context names are now also checked against the prose of every
# workflow: see advisory_prose_check below, including its two stated limits.
#
# EXIT CODES   0 = agree · 1 = drift / prose contradicts the spec / cannot read
#              3 = DEADLOCK · 4 = RE-RUN
#
# 4 is returned by --deadlock, the mode a caller points at a SPECIFIC head (the
# merge verb's pre-flight). --full and --ci SAMPLE an arbitrary settled head, so
# there it is printed as a NOTE and never reds: a cancelled run on a foreign
# merged PR is not drift, and no PR author could fix it.
#
# 4 (RE-RUN) is the state D56 found the detector blind to: every required
# context IS rendered on the head, so the set difference is empty, but one of
# them concluded `cancelled` — which nothing will ever re-report on its own.
# Exit 0 there is shape-identical to green on a permanently frozen head.
#
# USAGE
#   scripts/required-checks-verify.sh                 # full three-way check
#   scripts/required-checks-verify.sh --branch <b>    # live-read b, not .branch
#   scripts/required-checks-verify.sh --ci            # the CI guard
#   scripts/required-checks-verify.sh --deadlock      # detector only
#   scripts/required-checks-verify.sh --selftest      # mutation-prove the clauses

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# THE FILE UNDER TEST, resolved absolutely. selftest's probe() re-execs THIS —
# never "$REPO_ROOT/scripts/required-checks-verify.sh", which is the committed
# copy and therefore always armed no matter what the running file says. A
# mutant copy has to grade ITSELF or its --selftest is a vacuous green.
# `${BASH_SOURCE[0]}` and not `$0` so the resolution survives being sourced.
# A copy OUTSIDE the repo now re-execs instead of exiting 127, but carries
# REPO_ROOT into its own parent directory; --selftest refuses that up front by
# name rather than letting the probes red on a missing scan directory. Keep a
# mutant inside scripts/ — that refusal is the honest report, not a bug to
# widen away.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

SPEC="$REPO_ROOT/.github/required-checks.json"
# Read the live protection of a branch OTHER than the one the spec names. The
# only caller is required-checks-apply.sh --branch <throwaway>, whose live
# probe applies to a scratch branch and must then verify THAT branch. Without
# it the probe reads main's protection and the round-trip can never be green —
# an apply/verify pair that structurally cannot agree.
BRANCH_OVERRIDE=""
READBACK_FILE=""
RUNS_FILE=""
HEAD_SHA=""
MODE="full"
QUIET=0
# The directory the advisory-prose clause scans. Overridable ONLY so the
# selftest can point the identical clause at fixture workflows; every real
# invocation reads the committed tree.
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

fail() { echo "FAIL: $*" >&2; exit 1; }
say()  { [ "$QUIET" -eq 1 ] || echo "$*"; }

read_spec() {
  [ -f "$SPEC" ] || fail "no spec at $SPEC — the guard cannot read the committed list (this is a failure, never a skip)"
  jq -e . "$SPEC" >/dev/null 2>&1 || fail "$SPEC is not valid JSON"
  jq -e '.protection.required_status_checks.checks | length > 0' "$SPEC" >/dev/null 2>&1 \
    || fail "$SPEC lists zero required contexts — a spec that requires nothing cannot fail"
}

spec_repo()   { jq -r '.repo'   "$SPEC"; }
spec_branch() { if [ -n "$BRANCH_OVERRIDE" ]; then printf '%s' "$BRANCH_OVERRIDE"; else jq -r '.branch' "$SPEC"; fi; }
spec_enforced() { jq -r '.enforced == true' "$SPEC"; }

# ── the live read-back ───────────────────────────────────────────────────────
# Unreadable is FAILURE. Wave 1's review found three guards that turned an
# unreadable input into a green tick; this is that clause for this guard.
live_protection() {
  if [ -n "$READBACK_FILE" ]; then
    [ -f "$READBACK_FILE" ] || fail "cannot read protection read-back file $READBACK_FILE"
    jq -e . "$READBACK_FILE" >/dev/null 2>&1 || fail "$READBACK_FILE is not valid JSON"
    cat "$READBACK_FILE"
    return
  fi
  local repo branch out
  repo="$(spec_repo)"; branch="$(spec_branch)"
  out="$(gh api "repos/$repo/branches/$branch/protection" 2>&1)" || {
    grep -q "Branch not protected" <<<"$out" \
      && fail "branch $branch of $repo is NOT PROTECTED, while the committed spec says enforced=$(jq -r '.enforced' "$SPEC")"
    fail "cannot read live protection for $repo/$branch: $out"
  }
  printf '%s' "$out"
}

# ── the OTHER polarity: is the branch protected RIGHT NOW? (cch-w51-s6) ──────
#
# `live_protection` above is the enforced=true reader, and its polarity is
# baked in: an absent config is a hard `fail`, because with enforced=true that
# IS the drift. The enforced=false branch of `run_full` needs the opposite —
# absent is the state the spec claims, and PRESENT is the drift — so it cannot
# reuse that reader. For two waves it therefore read nothing at all: the branch
# `return 0`d before `live_protection` was ever called, which made this script
# structurally incapable of seeing one of the two drift directions. It did not
# fail when it could not see; it declined to look.
#
# THREE-VALUED ON PURPOSE. Collapsing to a boolean would fold "I looked and
# found no protection" into "I could not look", and the second one must never
# be rendered as agreement (that is this repo's standing rule for guards, and
# the header three lines up already states it for the other polarity).
#
# stdout, exactly two lines, and it ALWAYS exits 0 — the CALLER decides what
# each state means:
#   1: protected | unprotected | unknown
#   2: protected   -> the live required contexts, comma-joined ("" if none)
#      unprotected -> how that was established
#      unknown     -> why the look failed
probe_live_protection() {
  local repo branch out
  repo="$(spec_repo)"; branch="$(spec_branch)"

  if [ -n "$READBACK_FILE" ]; then
    if [ ! -f "$READBACK_FILE" ]; then
      printf 'unknown\nno protection read-back file at %s\n' "$READBACK_FILE"; return 0
    fi
    if ! jq -e . "$READBACK_FILE" >/dev/null 2>&1; then
      printf 'unknown\n%s is not valid JSON\n' "$READBACK_FILE"; return 0
    fi
    out="$(cat "$READBACK_FILE")"
  elif ! command -v gh >/dev/null 2>&1; then
    printf 'unknown\nthe gh CLI is not on PATH, so live protection could not be read at all\n'; return 0
  elif ! out="$(gh api "repos/$repo/branches/$branch/protection" 2>&1)"; then
    # GitHub's own 404 body is the ONE honest "there is nothing there".
    # Anything else — a token without admin, a rate limit, a network fault —
    # is a failure to look, not a finding.
    if grep -q "Branch not protected" <<<"$out"; then
      printf 'unprotected\n%s/%s returns the API'"'"'s own "Branch not protected" body\n' "$repo" "$branch"; return 0
    fi
    printf 'unknown\ncannot read live protection for %s/%s: %s\n' "$repo" "$branch" "$(head -1 <<<"$out")"
    return 0
  fi

  # A read-back FIXTURE may also carry that 404 body — that is how the suite
  # drives this arm hermetically, with the API's real shape rather than a
  # sentinel invented for the test.
  if jq -e 'type == "object" and ((.message? // "") | test("Branch not protected"; "i"))' <<<"$out" >/dev/null 2>&1; then
    printf 'unprotected\n%s/%s returns the API'"'"'s own "Branch not protected" body\n' "$repo" "$branch"; return 0
  fi
  local ctxs=""
  ctxs="$(jq -r '[(.required_status_checks.checks[]?.context), (.required_status_checks.contexts[]?)]
                 | unique | join(", ")' <<<"$out" 2>/dev/null || true)"
  printf 'protected\n%s\n' "$ctxs"
}

# The clause the enforced=false branch was missing entirely. Green here means
# the spec's claim and reality agree in BOTH directions, not just the one the
# script happened to look in.
unapplied_spec_matches_reality() {
  local probe state detail
  probe="$(probe_live_protection)"
  state="$(sed -n 1p <<<"$probe")"
  detail="$(sed -n 2p <<<"$probe")"
  case "$state" in
    unprotected)
      say "  live probe: $detail — the spec's enforced=false claim matches reality."
      return 0
      ;;
    protected)
      echo "FAIL: the committed spec says enforced=false — protection NOT applied — but $(spec_repo)/$(spec_branch) IS PROTECTED right now." >&2
      echo "      live required contexts: ${detail:-(none named — the branch is protected by other rules)}" >&2
      echo "      Nothing downstream of this spec can be trusted about the gate: a merge pre-flight" >&2
      echo "      loads the SPEC's contexts, so every live context the spec omits is invisible to it." >&2
      echo "      Fix by re-applying (scripts/required-checks-apply.sh) or by committing enforced=true — but do" >&2
      echo "      not leave the file claiming a gate is off while it is on." >&2
      return 1
      ;;
    *)
      echo "FAIL: could not look at live protection, so this run CANNOT stand behind the spec's enforced=false claim." >&2
      echo "      reason: $detail" >&2
      echo "      This is a failure, never a skip: \"I could not look\" is not \"they agree\"." >&2
      return 1
      ;;
  esac
}

# ── the full-object diff ─────────────────────────────────────────────────────
# Informational keys the API returns and the PUT cannot set. Everything else in
# the read-back must be accounted for by the spec.
IGNORED_KEYS='["url","contexts_url","protection_url"]'

compare_protection() {
  local actual="$1" failures=0

  # 1. enforce_admins — a left-open break-glass must red CI.
  local ea
  # NOT `// "MISSING"`: jq's alternative operator treats `false` as empty, so a
  # genuinely-false boolean would report as MISSING and every clause below would
  # read the wrong state. Every read-back probe in this file is null-tested.
  ea="$(printf '%s' "$actual" | jq -r '.enforce_admins.enabled | if . == null then "MISSING" else tostring end')"
  if [ "$ea" != "true" ]; then
    echo "  DRIFT  enforce_admins.enabled = $ea (spec: true) — a false here means an admin can merge straight past the required set, i.e. a gate that cannot block. Merge with scripts/bp-merge.sh; restore with: gh api -X POST repos/$(spec_repo)/branches/$(spec_branch)/protection/enforce_admins" >&2
    failures=$((failures + 1))
  else
    say "  ok     enforce_admins.enabled = true"
  fi

  # 2. strict
  local sw sa
  sw="$(jq -r '.protection.required_status_checks.strict' "$SPEC")"
  sa="$(printf '%s' "$actual" | jq -r '.required_status_checks.strict | if . == null then "MISSING" else tostring end')"
  if [ "$sw" != "$sa" ]; then
    echo "  DRIFT  required_status_checks.strict = $sa (spec: $sw)" >&2
    failures=$((failures + 1))
  else
    say "  ok     required_status_checks.strict = $sa"
  fi

  # 3. checks[] — context AND app_id, both directions, app_id:null is hard.
  local want got
  want="$(jq -c '.protection.required_status_checks.checks | sort_by(.context)' "$SPEC")"
  got="$(printf '%s' "$actual" | jq -c '[.required_status_checks.checks[]? | {context, app_id}] | sort_by(.context)')"
  if [ "$want" != "$got" ]; then
    echo "  DRIFT  required_status_checks.checks disagree" >&2
    echo "         spec: $want" >&2
    echo "         live: $got" >&2
    # Name the specific shapes, because "they differ" is not actionable.
    printf '%s' "$actual" | jq -r --argjson w "$(jq -c '.protection.required_status_checks.checks' "$SPEC")" '
      ([.required_status_checks.checks[]? | {context, app_id}]) as $g
      | ( $w - [$g[] | .] | .[] | "         MISSING from live: \(.context) (app_id \(.app_id))" ),
        ( $g - [$w[] | .] | .[] | "         EXTRA on live: \(.context) (app_id \(.app_id // "null"))" )' >&2 || true
    printf '%s' "$actual" | jq -r --argjson w "$(jq -c '.protection.required_status_checks.checks' "$SPEC")" '
      [.required_status_checks.checks[]? ] as $g
      | $g[] | select(.app_id == null) | select([$w[].context] | index(.context))
      | "         HARD: \(.context) reads app_id:null while the spec pins an id — ANY app with checks:write can satisfy it"' >&2 || true
    failures=$((failures + 1))
  else
    say "  ok     required_status_checks.checks match on context AND app_id ($(printf '%s' "$got" | jq 'length') context(s))"
  fi

  # 4. the optional booleans, INCLUDING the falses (D41: the PUT does not converge).
  local key wantv gotv
  while IFS= read -r key; do
    wantv="$(jq -r --arg k "$key" '.protection[$k]' "$SPEC")"
    gotv="$(printf '%s' "$actual" | jq -r --arg k "$key" '.[$k].enabled | if . == null then "MISSING" else tostring end')"
    if [ "$gotv" != "$wantv" ]; then
      echo "  DRIFT  $key.enabled = $gotv (spec: $wantv) — state nobody committed" >&2
      failures=$((failures + 1))
    else
      say "  ok     $key.enabled = $gotv"
    fi
  done <<EOF
$(jq -r '.protection | to_entries[] | select(.value | type == "boolean") | select(.key != "enforce_admins") | .key' "$SPEC")
EOF

  # 5. spec-null blocks must be absent from the read-back.
  while IFS= read -r key; do
    if printf '%s' "$actual" | jq -e --arg k "$key" 'has($k)' >/dev/null; then
      echo "  DRIFT  $key is set on the branch but the spec says null" >&2
      failures=$((failures + 1))
    else
      say "  ok     $key absent (spec: null)"
    fi
  done <<EOF
$(jq -r '.protection | to_entries[] | select(.value == null) | .key' "$SPEC")
EOF

  # 6. FULL-OBJECT diff: any read-back key the spec does not account for.
  local extra
  extra="$(printf '%s' "$actual" | jq -r --argjson ig "$IGNORED_KEYS" --argjson spec "$(jq -c '.protection' "$SPEC")" '
    keys[] | select((. as $k | $ig | index($k)) | not)
           | select(. != "required_status_checks" and . != "enforce_admins")
           | select((. as $k | $spec | has($k)) | not)')"
  if [ -n "$extra" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      # required_signatures is set through a different endpoint; it still counts
      # as uncommitted state whenever it is ON.
      if [ "$key" = "required_signatures" ] \
         && [ "$(printf '%s' "$actual" | jq -r '.required_signatures.enabled')" = "false" ]; then
        say "  ok     required_signatures disabled (informational)"
        continue
      fi
      echo "  DRIFT  live protection carries '$key', which the committed spec never mentions — enumerate it or turn it off" >&2
      failures=$((failures + 1))
    done <<EOF
$extra
EOF
  fi

  return "$failures"
}

# ── the deadlock detector ────────────────────────────────────────────────────
rendered_names() {
  local sha="$1" json
  if [ -n "$RUNS_FILE" ]; then
    [ -f "$RUNS_FILE" ] || fail "cannot read check-runs file $RUNS_FILE"
    json="$(cat "$RUNS_FILE")"
  else
    json="$(gh api "repos/$(spec_repo)/commits/$sha/check-runs?per_page=100" 2>/dev/null)" \
      || fail "cannot read check runs for $sha — the guard has nothing to render names against (failure, not a skip)"
  fi
  jq -e '.check_runs | length > 0' <<<"$json" >/dev/null 2>&1 \
    || fail "check-runs for $sha is EMPTY — refusing to declare agreement against an empty feed"
  # latest row per name; a re-run leaves both and only the newest is the truth.
  # Four columns: name, conclusion ("null" when unsettled), status, started_at.
  # Downstream consumers key on $1/$2 and are untouched by the extra columns;
  # the PENDING clause below is what reads $3/$4.
  jq -r '.check_runs | sort_by(.started_at // "") | .[] | [.name, (.conclusion // "null"), (.status // ""), (.started_at // "")] | @tsv' <<<"$json" \
    | awk -F'\t' '{ seen[$1] = $2 "\t" $3 "\t" $4 } END { for (n in seen) printf "%s\t%s\n", n, seen[n] }' | sort
}

# A SETTLED head, deliberately: a MERGED PR's checks have all reported, while
# the head of the PR being tested right now is mid-flight — and a required
# context that simply has not reported YET would read as a false DEADLOCK.
recent_pr_head() {
  local sha
  sha="$(gh pr list --repo "$(spec_repo)" --state merged --limit 20 \
          --json headRefOid,statusCheckRollup \
          --jq '[.[] | select((.statusCheckRollup // []) | length > 0)][0].headRefOid' 2>/dev/null || true)"
  [ -n "$sha" ] && [ "$sha" != "null" ] || fail "cannot find a recent PR head with check runs to render names against (failure, not a skip)"
  printf '%s' "$sha"
}

deadlock_check() {
  local sha="$1" names missing
  # `fail` inside rendered_names exits only the command-substitution subshell,
  # so its status MUST be propagated here — otherwise an unreadable feed yields
  # an empty name set and every required context reads as "missing", turning a
  # read failure into a fake DEADLOCK. Wrong state, right-looking red.
  if ! names="$(rendered_names "$sha")"; then
    return 1
  fi
  missing=""
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    # Here-string, not a pipe: under `set -o pipefail` a matching `grep -q`
    # exits at once, the upstream takes SIGPIPE, and the pipeline reports 141 —
    # i.e. a PRESENT context would intermittently read as missing and this guard
    # would cry DEADLOCK at a healthy repo.
    if ! grep -qxF "$ctx" <<<"$(cut -f1 <<<"$names")"; then
      missing="$missing$ctx
"
    fi
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF

  if [ -n "$missing" ]; then
    echo "DEADLOCK: the committed spec requires context(s) that head $sha never rendered." >&2
    printf '%s' "$missing" | sed 's/^/         missing: /' >&2
    echo "         GitHub reports these as \"expected\" forever and NEVER names them at N>1 (D38), so this set difference is the only signal." >&2
    return 3
  fi

  # PRESENT is not the same as ABLE TO SATISFY (D56). rendered_names already
  # emits `name<TAB>conclusion`, and the loop above threw the conclusion away by
  # matching on `cut -f1` — so a required context whose latest run concluded
  # `cancelled` returned EXIT 0, shape-identical to green. Proven live on head
  # 5ea4cb4f, whose required `PR references an active task` was cancelled. That
  # is the worst state to be blind to: nothing re-reports a cancelled run on its
  # own, so the head is frozen while the detector says it is fine. RE-RUN is a
  # FOURTH state, exit 4 — not a deadlock (the workflow does emit this context)
  # and not a pass.
  local cancelled=""
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    local concl
    # Here-string for the same SIGPIPE reason as above; the tuple is already in
    # hand, this only stops discarding it.
    concl="$(awk -F'\t' -v c="$ctx" '$1 == c { print $2 }' <<<"$names")"
    # `skipped` is DELIBERATELY ABSENT from this set, and the omission is the
    # reviewed decision (wave 4 review). GitHub counts a required check whose
    # conclusion is `skipped` as SATISFYING protection — so listing it here
    # would make the merge verb refuse a head GitHub would happily merge, which
    # is a lie in the opposite direction inside an epic about honest gates. The
    # states below share one property `skipped` does not: GitHub blocks on them
    # AND nothing re-reports them on its own. Probe 16/23 pins this both ways.
    case "$concl" in
      cancelled|timed_out|stale|action_required)
        cancelled="$cancelled$ctx (concluded $concl)
"
        ;;
    esac
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF

  if [ -n "$cancelled" ]; then
    echo "RE-RUN: head $sha rendered every required context, but one concluded in a state that will never turn green on its own." >&2
    printf '%s' "$cancelled" | sed 's/^/         re-run: /' >&2
    echo "         This is NOT a deadlock — the workflow does emit the context — and it is NOT green. Re-run the run, then merge." >&2
    echo "         Note (D57): \"Elixir gate\" launders cancellation into failure, so a cancelled upstream can also surface as \"is failing.\"" >&2
    return 4
  fi
  # PENDING is INFORMATIONAL, deliberately NOT a fifth failing state (charter
  # D76: additive-safe — bp-merge.sh calls this detector once pre-flight, so a
  # failing PENDING would refuse every freshly pushed PR in the fleet). But a
  # required context that is rendered and UNSETTLED (conclusion null —
  # in_progress, or queued with no conclusion) used to print the same ok line
  # as green, and an operator running the pre-flight before a PUT could not
  # tell rendered-but-unsettled from satisfied. Name it, with its status and
  # started_at, and still exit 0. An age threshold on started_at (refusing a
  # dispatched-then-never-scheduled check early) is a later enhancement.
  local pending_seen=0
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    local row concl st sat
    row="$(awk -F'\t' -v c="$ctx" '$1 == c { print; exit }' <<<"$names")"
    [ -n "$row" ] || continue
    concl="$(cut -f2 <<<"$row")"
    if [ "$concl" = "null" ]; then
      st="$(cut -f3 <<<"$row")"
      sat="$(cut -f4 <<<"$row")"
      echo "PENDING: $ctx has not settled (status=${st:-unknown}, started_at=${sat:-unknown})"
      pending_seen=1
    fi
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF
  if [ "$pending_seen" -eq 1 ]; then
    say "  ok     every required context RENDERED on $sha — but the PENDING line(s) above have not settled; rendered is not satisfied"
    return 0
  fi

  say "  ok     every required context appears in the $(printf '%s' "$names" | grep -c . || true) name(s) rendered on $sha"
  return 0
}

# ── the advisory-prose clause ────────────────────────────────────────────────
# THE DEFECT THIS EXISTS FOR (cch-w32-s4). console-harness.yml told a builder,
# in three separate comments, that `Console gate` "is ADVISORY today — the live
# required set is `Elixir gate` and `PR references an active task`". Live
# protection had required FOUR contexts since 2026-08-03, `Console gate` among
# them. The comment was not wrong when written; it rotted, because it had
# re-enumerated a set that lives somewhere else. A builder who read it would
# have shipped a red believing the merge was still open to them — a gate layer
# telling a builder something it cannot support, which is this epic's thesis
# pointed at itself.
#
# THE CLAUSE. NEITHER SIDE IS HAND-ENUMERATED. The context names come from the
# committed spec (`.github/required-checks.json`), the prose comes from a scan
# of every `*.yml` under .github/workflows. Adding a context to the spec
# therefore widens the guard on its own, and removing one narrows it — the
# guard tracks the spec, never a frozen string (probes 17 and 18 prove exactly
# that pair).
#
# THE LENS, pinned so a reader knows what it does and does not see. Per workflow
# file, comment markers are stripped and lines are joined into one stream, so a
# claim spread over three wrapped comment lines still matches. For each
# occurrence of a required context name, the NEXT $PROSE_WINDOW characters are
# searched for a disclaimer. Directional on purpose: "`Console gate` … is
# ADVISORY" matches, while "…is ADVISORY … the required set is `Elixir gate`"
# does not blame `Elixir gate` for a sentence that named it as REQUIRED.
#
# TWO HONEST LIMITS, named rather than papered over:
#
#   (i) IT IS A REGEX OVER PARAPHRASABLE PROSE. It catches the phrasings listed
#       in PROSE_DISCLAIMERS below and nothing else; "you can merge over this
#       one" or "cosmetic for now" sail straight past. It is also proximity, not
#       attribution — a required context named within the window of somebody
#       else's disclaimer is flagged, and the fix is to reword, not to widen the
#       window. Treat it as a tripwire on the phrasing that actually rotted
#       here, not as a proof that every comment is true.
#
#  (ii) IT COMPOSES WITH, AND DOES NOT DUPLICATE, THE LIVE-VS-SPEC HALF. This
#       clause proves only that no workflow's prose CONTRADICTS the committed
#       spec. That the spec matches live branch protection is compare_protection
#       above, and that the required names actually render is deadlock_check.
#       Alone, this clause would happily certify prose that agrees with a spec
#       which itself disagrees with GitHub — which is why it runs beside them in
#       the same modes rather than instead of them.
PROSE_WINDOW=200
# Ordered loosest-last; matched case-insensitively against the joined stream.
PROSE_DISCLAIMERS='advisory|non-?blocking|not blocking|does not block|does not by itself block|do(es)? not block|doesn.?t block|will not block|won.?t block|never blocks|blocks nothing|not (a )?required|non-?required|not enforced'

advisory_prose_check() {
  [ -d "$WORKFLOWS_DIR" ] \
    || fail "cannot read $WORKFLOWS_DIR — the advisory-prose clause has nothing to scan (a failure, never a skip)"
  local files
  # BOTH legal spellings. GitHub runs a workflow written `*.yaml` exactly like a
  # `*.yml` one (never-cancel-main-check.sh:96 already scans both, and cgsiw-s2
  # widened required-checks-generate.sh's glob for the same reason). A guard
  # that scans only one spelling is silent on the other — the vacuity class this
  # whole file exists to refuse, so the scan covers both even though zero
  # `*.yaml` workflows exist today.
  files="$(find "$WORKFLOWS_DIR" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) | sort)"
  [ -n "$files" ] \
    || fail "no *.yml or *.yaml under $WORKFLOWS_DIR — scanning zero files is the vacuous pass this guard exists to refuse"

  local tmp ctxfile nctx nfiles out
  tmp="$(mktemp -d)"
  ctxfile="$tmp/contexts.txt"
  jq -r '.protection.required_status_checks.checks[].context' "$SPEC" > "$ctxfile"
  nctx="$(grep -c . "$ctxfile" || true)"
  nfiles="$(printf '%s\n' "$files" | grep -c . || true)"

  out="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk \
    -v CTXFILE="$ctxfile" -v WINDOW="$PROSE_WINDOW" -v DISC="$PROSE_DISCLAIMERS" '
    function flushfile(   i, j, p, abs, start, ctxlc, streamlc, hay, exc, ln) {
      if (fname == "") return
      streamlc = tolower(stream)
      for (i = 1; i <= nctx; i++) {
        ctxlc = tolower(ctx[i])
        start = 1
        while ((p = index(substr(streamlc, start), ctxlc)) > 0) {
          abs = start + p - 1
          hay = substr(streamlc, abs + length(ctxlc), WINDOW)
          if (hay ~ DISC) {
            exc = substr(stream, abs, length(ctxlc) + WINDOW)
            gsub(/\|/, " ", exc)
            ln = 1
            for (j = 1; j <= nmark; j++) if (markoff[j] <= abs) ln = markline[j]
            printf "%s|%d|%s|%s\n", fname, ln, ctx[i], exc
            break
          }
          start = abs + 1
        }
      }
    }
    BEGIN {
      while ((getline c < CTXFILE) > 0) if (length(c) > 0) ctx[++nctx] = c
    }
    FNR == 1 { flushfile(); fname = FILENAME; stream = ""; nmark = 0 }
    {
      line = $0
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      nmark++; markoff[nmark] = length(stream) + 1; markline[nmark] = FNR
      stream = stream line " "
    }
    END { flushfile() }
  ' 2>&1)" || { rm -rf "$tmp"; fail "advisory-prose scan could not run: $out"; }
  rm -rf "$tmp"

  if [ -n "$out" ]; then
    echo "FAIL: a workflow describes a REQUIRED context as advisory / non-blocking." >&2
    echo "      The committed spec ($SPEC) says these contexts BLOCK the merge." >&2
    printf '%s\n' "$out" | while IFS='|' read -r f l c e; do
      echo "      $f:$l  claims \"$c\" is not blocking" >&2
      echo "        … ${e} …" >&2
    done
    echo "      Fix the PROSE, not the spec — unless the context genuinely should stop being required," >&2
    echo "      in which case regenerate the spec and this clause narrows with it." >&2
    return 1
  fi
  say "  ok     no workflow calls any of the $nctx required context(s) advisory ($nfiles workflow file(s) scanned)"
  return 0
}

# ── the merge-truth prose clause, OUTSIDE .github/workflows ──────────────────
# THE BLIND SPOT THIS CLOSES (cch-w34). advisory_prose_check above scans exactly
# `find "$WORKFLOWS_DIR" -maxdepth 1` — .github/workflows, one level, two YAML
# spellings. It cannot see `.claude/workflows/*.md`, `docs/**` or `CLAUDE.md`,
# and those are where the fleet actually reads its merge truth: a charter is
# loaded into an agent's context BY NAME, in full, before that agent has run a
# single `gh api`. The founding defect (cch-w32-s4) was a workflow comment
# calling `Console gate` advisory while it was required; the SAME sentence,
# re-copied into a charter, was invisible to every clause in this file.
#
# MEASURED, and the number is the whole design argument. Pointing the clause
# ABOVE at `.claude/workflows/*.md` unchanged returns 17 rows. Sixteen are
# PROXIMITY, not attribution: `Elixir gate ... Format is advisory-by-design`,
# `Cloud gate, Console gate} ... doc-gates ... is NOT required`, and — purely
# lexical — `per-doc advisory lock`. One is real. A clause that is 94% noise on
# the corpus it was just handed does not get switched on; it gets switched off.
# So the corpus widens and the LENS TIGHTENS with it, and the two arms are
# deliberately not merged: a workflow comment is terse and directive, where
# proximity is the right reading, and narrative prose is not.
#
# MEASURED AGAIN, at the full width. Over all 2359 TRACKED *.md/*.markdown/*.txt
# in the repository the tightened lens returns THREE rows: the charter claim
# pinned below, one wave-ledger row REPORTING that a workflow made the claim,
# and one wave ledger with a probe fixture pasted inside a ``` block. Rules
# 3(a) and 3(c) take the second and third, so the census is the whole tracked
# corpus and the residue is one sentence. That is why the scan below is
# `git ls-files` over the repository and not a list of three directories.
#
# THE LENS: ATTRIBUTION, NOT PROXIMITY. Three rules, each structural.
#
#   1. THE SPAN STOPS AT THE CLAUSE. From the end of the context name, read
#      forward to the FIRST of `;`, `)`, an em/en dash, a table pipe, `. `, or
#      ANY required-context name (a new name is a new subject) — never a flat
#      200 characters. `Cloud gate, Console gate} (branch-protection API) —
#      doc-gates ... is NOT required` therefore blames nobody.
#   2. THE DISCLAIMER MUST BE PREDICATED OF THE CONTEXT. The span has to OPEN
#      with a copula — is / are / was / were / remains / stays / reads / counts
#      as / has been. `Console gate` are ADVISORY today` opens with `are` and
#      fires; ``Elixir gate` with an advisory PASSES the count floor` opens with
#      `with` and does not, because there `advisory` is a noun.
#   3. IT DISTINGUISHES ASSERTING THE FALSEHOOD FROM RECORDING THAT IT WAS
#      FALSE — the thing this repo's corpus is mostly made of, and the reason a
#      naive widening would red on its own audit trail. THREE fences, every one
#      on the matched text or on markdown structure and none on a path (a path
#      fence is a directory exemption wearing a hat, and §18 of the suite
#      already refused that):
#        (a) RECORD — the claim or its immediate left context carries a
#            retraction/dating marker, or a REPORTED-SPEECH verb: RETRACTED,
#            RETIRED, STRUCK, CORRECTED, SUPERSEDED, "no longer", "used to",
#            "at the time", "as measured", "BEFORE (", "still says", "was
#            false", "now false", "dated", "claims/claimed".
#            `required-checks-drift.yml`s own header does exactly this ("Until
#            wave 53 this header labelled the spec-gate job BLOCKING. It is
#            not") and must stay green; so does a ledger row reading "two prose
#            blocks in console-harness.yml CLAIM `Console gate` is ADVISORY",
#            which names the claim's owner and is therefore a report of it.
#        (b) QUOTE — the context name is inside a quotation (a `"` within the
#            four characters to its left). A quoted past reason string is
#            evidence about a claim, not the claim.
#        (c) TRANSCRIPT — the line sits inside a ``` or ~~~ fenced block. The
#            wave ledgers paste planted fixtures and shell sessions verbatim as
#            evidence; a fixture written to make this suite RED is not a
#            sentence telling an agent anything.
#      All three fences are counted and PRINTED on a green run. A fence nobody
#      can see the size of is a fence that quietly becomes an exemption.
#
# WHAT IT STILL CANNOT DO, stated rather than discovered: rule 2 is a copula
# test, so a fresh paraphrase that never predicates ("you can merge over Console
# gate") walks straight through, and rule 3(a) is a marker list, so an UNMARKED
# dated record reds and needs a pin. It is a tripwire on the phrasing that
# actually rotted here twice, not a proof that every charter sentence is true.
PROSE_ROOT_OVERRIDE=""
# Rule 2. Anchored at the head of the attributed span, so it is the CONTEXT the
# disclaimer is predicated of and never the next noun along.
PROSE_COPULA='^[^a-z]*(is|are|was|were|remains|stays|reads|counts as|has been|have been)[^a-z]'
# Rule 3(a). Ordered loosest-last, matched case-insensitively.
PROSE_RECORD_MARKERS='retracted|retired|struck|corrected|superseded|obsolete|no longer|used to|at the time|as measured|before [(]|still say|still said|still read|was false|now false|dated|claim'

# THE PIN LIST — the same contract §18 of required-checks.test.sh runs on, for
# the same reason: a census is a SET EQUALITY, never a count. A pinned line that
# DISAPPEARS is reported STALE, so the commit that fixes a claim has to drop its
# pin in the same breath, and a pin cannot rot into a permanent exemption.
#
# The key is `<repo-relative path>|<context>|<the attributed span, 60 chars>` —
# deliberately the SENTENCE and not a whole-file hash, so editing the claim
# un-pins it and brings it back for a human reading, while an unrelated edit to
# the file does not.
#
# THE LIST IS EMPTY, AND THE HISTORY OF ITS ONE ENTRY IS THE CONTRACT IN ACTION.
# When this clause was first run at full width it found exactly ONE class-A
# claim: `.claude/workflows/bp-cloud-console-hardening-charter.md` (D163, under
# "AND THE FACT A BUILDER MUST NOT MISREAD") told a builder that `Cloud gate`
# and `Console gate` "are ADVISORY today — a red one does not stop the merge
# button", in the same sentence that correctly said the committed spec carries
# FOUR contexts with `enforced: true`. Live protection has required all four
# since 2026-08-03 — the cch-w32-s4 defect, verbatim, in this epic's OWN
# charter. The builder pinned it (fenced out of the charters); the lead then
# corrected the sentence into a dated record (CORRECTED 2026-09-02, "used to
# say") and dropped the pin IN THE SAME COMMIT, which is the only order the
# STALE arm permits. A future entry here must carry its owner and its
# replacement, and must not outlive one wave: a pin that is still here a wave
# later means this clause has become the thing it was written to catch.
PROSE_CLAIM_PINS=''

merge_truth_prose_check() {
  local files
  # The same refusal advisory_prose_check makes, for the same reason: scanning
  # zero files is the vacuous pass this whole file exists to attack.
  if [ -n "$PROSE_ROOT_OVERRIDE" ]; then
    # A fixture tree is not a git checkout, so the override reads the filesystem.
    # RECURSIVE on purpose — no -maxdepth. The depth-1 glob above is precisely
    # the shape this clause exists to stop repeating.
    files="$(find "$PROSE_ROOT_OVERRIDE" -type f \( -name '*.md' -o -name '*.markdown' -o -name '*.txt' \) 2>/dev/null | sort)"
    [ -n "$files" ] \
      || fail "no *.md/*.markdown/*.txt under $PROSE_ROOT_OVERRIDE — scanning zero files is a vacuous pass, not a green"
  else
    # TRACKED, and the WHOLE repository — deliberately not a root list. This
    # started as `.claude/workflows docs CLAUDE.md` and the measurement killed
    # it: a root list is a directory allowlist wearing a hat, and a directory
    # allowlist is the exact shape (`.github/workflows -maxdepth 1`) this clause
    # exists to stop repeating. `git ls-files` is the census §13 and §18 of the
    # suite already run on; it cannot be widened by a stray untracked file, and
    # it cannot be narrowed by forgetting a directory — a new docs tree, a new
    # charter folder, a README added under api/ all arrive already scanned.
    # 2359 files at the time of writing, against 217 under the three roots.
    # `[ -f ]` because a tracked path deleted in the worktree is still listed,
    # and awk would abort on it — a scan that dies is not a verdict.
    files="$(cd "$REPO_ROOT" && git ls-files -- '*.md' '*.markdown' '*.txt' 2>/dev/null \
      | while IFS= read -r f; do [ -f "$f" ] && printf '%s/%s\n' "$REPO_ROOT" "$f"; done | sort)"
    [ -n "$files" ] \
      || fail "git ls-files listed no tracked *.md/*.markdown/*.txt under $REPO_ROOT — scanning zero files is a vacuous pass, not a green (is this a git checkout?)"
  fi

  local tmp ctxfile nctx nfiles raw
  tmp="$(mktemp -d)"
  ctxfile="$tmp/contexts.txt"
  # Spec-derived, exactly like the clause above: adding a required context
  # widens this scan on its own and removing one narrows it. Nothing is typed.
  jq -r '.protection.required_status_checks.checks[].context' "$SPEC" > "$ctxfile"
  nctx="$(grep -c . "$ctxfile" || true)"
  nfiles="$(printf '%s\n' "$files" | grep -c . || true)"

  # THE PRE-FILTER, and it is not an exemption. Every rule below is anchored on
  # an occurrence of a required-context NAME, so a file containing none of them
  # cannot produce a row: `grep -ilFf` selects exactly the set the awk would
  # reach, and does it two orders of magnitude cheaper. That is the difference
  # between 13s and a fraction of a second per run, and the suite drives this
  # script 27 times. The candidate count is PRINTED beside the scanned count on
  # every green run — a pre-filter that quietly matched nothing would otherwise
  # be indistinguishable from a clean corpus, which is the vacuous pass this
  # whole file exists to refuse.
  local candidates ncand
  if [ -n "$PROSE_ROOT_OVERRIDE" ]; then
    candidates="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -ilFf "$ctxfile" 2>/dev/null || true)"
  else
    # `git grep` over `xargs grep` on the committed corpus: same 214 files out of
    # the same 2359, six times faster (0.16s against 0.93s), and it is already
    # the tracked-file census the rest of the suite runs on.
    candidates="$(cd "$REPO_ROOT" && git grep -ilF -f "$ctxfile" -- '*.md' '*.markdown' '*.txt' 2>/dev/null \
      | while IFS= read -r f; do printf '%s/%s\n' "$REPO_ROOT" "$f"; done || true)"
  fi
  ncand="$(printf '%s\n' "$candidates" | grep -c . || true)"

  # LC_ALL=C, and it is not a style preference. The tracked corpus carries bytes
  # that are not valid in the ambient UTF-8 locale (a mojibake'd em dash in one
  # wave ledger), and BWK awk does not skip those — it ABORTS the whole run with
  # "towc: multibyte conversion failure", mid-corpus, taking every file after it
  # with it. That is a scan that stops early and a `fail` that names a locale
  # instead of a claim. Every comparison below is a byte comparison and every
  # tolower() is on ASCII context names, so the C locale changes no verdict.
  # `if`, not a pipeline into xargs: with an empty candidate list `xargs -0 awk`
  # runs awk with NO file operands, which reads STDIN — the run would hang, and
  # a gate that hangs is worse than one that lies.
  if [ "$ncand" -eq 0 ]; then raw=""; else
  raw="$(printf '%s\n' "$candidates" | tr '\n' '\0' | xargs -0 env LC_ALL=C awk \
    -v CTXFILE="$ctxfile" -v WINDOW="$PROSE_WINDOW" -v DISC="$PROSE_DISCLAIMERS" \
    -v COP="$PROSE_COPULA" -v REC="$PROSE_RECORD_MARKERS" -v ROOT="$REPO_ROOT/" '
    function clip(s, n) { gsub(/[[:space:]]+/, " ", s); return (length(s) > n ? substr(s, 1, n) : s) }
    # RULE 1 — the attributed span: end of the context name to the first clause
    # boundary or the next context name, whichever comes first.
    function clausespan(s,   i, j, best, other) {
      best = length(s)
      if ((i = index(s, ";"))   > 0 && i - 1 < best) best = i - 1
      if ((i = index(s, ")"))   > 0 && i - 1 < best) best = i - 1
      if ((i = index(s, " — ")) > 0 && i - 1 < best) best = i - 1
      if ((i = index(s, " – ")) > 0 && i - 1 < best) best = i - 1
      if ((i = index(s, "|"))   > 0 && i - 1 < best) best = i - 1
      if (match(s, /\. /) && RSTART - 1 < best) best = RSTART - 1
      for (j = 1; j <= nctx; j++) {
        other = tolower(ctx[j])
        if ((i = index(s, other)) > 0 && i - 1 < best) best = i - 1
      }
      return substr(s, 1, best)
    }
    function flushfile(   i, j, p, abs, start, ctxlc, streamlc, span, left, exc, ln, rel, verdict) {
      if (fname == "") return
      stream = stream buf; buf = ""
      rel = fname; sub("^" ROOT, "", rel)
      streamlc = tolower(stream)
      for (i = 1; i <= nctx; i++) {
        ctxlc = tolower(ctx[i]); start = 1
        while ((p = index(substr(streamlc, start), ctxlc)) > 0) {
          abs = start + p - 1
          span = clausespan(substr(streamlc, abs + length(ctxlc), WINDOW))
          if (span ~ COP && span ~ DISC) {
            left = substr(streamlc, (abs > 160 ? abs - 160 : 1), (abs > 160 ? 160 : abs - 1))
            exc  = substr(stream, abs, length(ctxlc) + WINDOW); gsub(/\|/, " ", exc)
            ln = 1; for (j = 1; j <= nmark; j++) if (markoff[j] <= abs) ln = markline[j]
            verdict = "CLAIM"
            if ((left span) ~ REC) verdict = "RECORD"
            else if (index(substr(stream, (abs > 4 ? abs - 4 : 1), 4), "\"") > 0) verdict = "QUOTE"
            printf "%s|%s|%d|%s|%s|%s\n", verdict, rel, ln, ctx[i], clip(span, 60), clip(exc, 150)
            break
          }
          start = abs + 1
        }
      }
    }
    BEGIN { while ((getline c < CTXFILE) > 0) if (length(c) > 0) ctx[++nctx] = c }
    FNR == 1 { flushfile(); fname = FILENAME; stream = ""; buf = ""; slen = 0; nmark = 0; infence = 0 }
    {
      line = $0
      # RULE 3(c) — A FENCED CODE BLOCK IS A TRANSCRIPT, NOT PROSE, and it is
      # the third thing this corpus is made of. The wave ledgers paste planted
      # probe fixtures, workflow snippets and shell sessions VERBATIM inside
      # ``` fences as evidence of what was measured; `# PROBE: `Elixir gate` is
      # ADVISORY here` is a fixture somebody wrote to make this very suite red,
      # not a sentence telling an agent anything. Reading a transcript as an
      # assertion is the same error as reading a quotation as one, so it gets
      # the same structural fence — on markdown STRUCTURE, never on a path.
      # The blanked lines still take a marker slot, so line attribution below
      # is unchanged.
      if (line ~ /^[[:space:]]*(```|~~~)/) { infence = !infence; line = ""; nfenced++ }
      else if (infence)                    { line = ""; nfenced++ }
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      nmark++; markoff[nmark] = slen + 1; markline[nmark] = FNR
      # CHUNKED, and this one is measured too. `stream = stream line " "` copies
      # the whole accumulated string once per line, which is quadratic in file
      # length — on a 4600-line charter it is most of the runtime, and a single
      # 217-file pass took 13s. Appending through an 8KB buffer divides that
      # copying by ~8192 and the same pass over 2359 files runs in a fraction of
      # the old time. `slen` carries the true offset so nothing else changes.
      buf = buf line " "; slen += length(line) + 1
      if (length(buf) > 8192) { stream = stream buf; buf = "" }
    }
    END { flushfile(); printf "FENCED|%d\n", nfenced }
  ' 2>&1)" || { rm -rf "$tmp"; fail "merge-truth prose scan could not run: $raw"; }
  fi
  rm -rf "$tmp"

  local nrec nqt nfence unpinned="" pinned_seen="" key
  nrec="$(printf '%s\n' "$raw" | grep -c '^RECORD|' || true)"
  nqt="$(printf '%s\n' "$raw" | grep -c '^QUOTE|'  || true)"
  # Rule 3(c)'s size, so the transcript fence is visible on a green run for the
  # same reason (a) and (b) are: a fence nobody can see the size of is a fence
  # that quietly becomes an exemption.
  nfence="$(printf '%s\n' "$raw" | sed -n 's/^FENCED|//p' | tail -1)"
  nfence="${nfence:-0}"

  # Both directions, always. UNPINNED = a claim nobody has read; STALE = a pin
  # whose sentence is gone, i.e. somebody fixed the text and left the exemption
  # behind to rot into a silencer.
  while IFS='|' read -r verdict rel ln ctx span exc; do
    [ "$verdict" = "CLAIM" ] || continue
    key="$rel|$ctx|$span"
    if printf '%s\n' "$PROSE_CLAIM_PINS" | grep -qxF "$key"; then
      pinned_seen="$pinned_seen$key
"
      say "  UNRESOLVED  $rel:$ln  says \"$ctx\" is not blocking (PINNED — see PROSE_CLAIM_PINS; fixing the sentence must drop the pin)"
    else
      unpinned="$unpinned$rel|$ln|$ctx|$exc
"
    fi
  done <<EOF
$raw
EOF

  # STALE is asserted only against the COMMITTED corpus. Under --prose the scan
  # root is a fixture tree that cannot satisfy a pin keyed on a repo-relative
  # path, so enforcing it there would make every fixture probe red for a reason
  # that has nothing to do with what the probe is about.
  local stale=""
  if [ -z "$PROSE_ROOT_OVERRIDE" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      printf '%s' "$pinned_seen" | grep -qxF "$key" || stale="$stale$key
"
    done <<EOF
$PROSE_CLAIM_PINS
EOF
  fi

  if [ -n "$unpinned" ] || [ -n "$stale" ]; then
    echo "FAIL: tracked prose OUTSIDE .github/workflows describes a REQUIRED context as advisory / non-blocking." >&2
    echo "      The committed spec ($SPEC) says these contexts BLOCK the merge, and a charter is loaded" >&2
    echo "      into an agent's context by name long before that agent reads the protection API." >&2
    printf '%s' "$unpinned" | while IFS='|' read -r f l c e; do
      [ -n "$f" ] || continue
      echo "      UNPINNED  $f:$l  claims \"$c\" is not blocking" >&2
      echo "        … ${e} …" >&2
    done
    printf '%s' "$stale" | while IFS= read -r k; do
      [ -n "$k" ] || continue
      echo "      STALE  the pin \"$k\" matches nothing — if the sentence was fixed, drop its pin in the SAME commit" >&2
    done
    echo "      Fix the PROSE, not the spec. If the context genuinely should stop being required," >&2
    echo "      regenerate .github/required-checks.json and this clause narrows with it." >&2
    return 1
  fi
  say "  ok     no tracked prose predicates a disclaimer of any of the $nctx required context(s) ($nfiles tracked file(s) scanned outside .github/workflows, $ncand naming a required context; $nrec dated record(s), $nqt quotation(s) and $nfence code-fence line(s) fenced)"
  return 0
}

# ── the blocking-authority clause (the INVERSE of the one above) ─────────────
# THE HOLE THIS FILLS (cgsiw-s1). advisory_prose_check catches ONE direction:
# a workflow calling a REQUIRED context advisory. Its own limit (ii) above says
# so plainly — it proves that no prose CONTRADICTS the spec. The other direction
# was enforced by nothing: a workflow that tells a builder its red BLOCKS the
# merge when the committed spec says that context is not required at all. That
# lie is strictly worse than the one already caught, because it manufactures
# authority: a builder chases a red that could never have stopped them, and a
# reviewer treats a green there as a merge gate it is not.
#
# ITS OWN AUTHORITY CEILING, stated rather than left for a reader to assume.
# This clause runs in --full and --ci, whose CI homes are `Required-check spec
# gate` (a committed EXCLUSION row, S7 — excluded by decision) and
# `Required-check spec drift (advisory)` (continue-on-error). main requires
# exactly four contexts: Cloud gate, Console gate, Elixir gate, PR references an
# active task. So a red from THIS clause is visible on every PR and BLOCKS
# NOTHING today. That is not an argument for softening it — it is the reason to
# say it out loud, since a tripwire whose teeth are assumed is the same class of
# defect it exists to catch.
#
# THE SUBJECT SET IS A COMPLEMENT, NEVER AN `.exclusions` JOIN (D1). The denied
# set is every rendered job context that is NOT in the committed
# `.protection.required_status_checks.checks` AND NOT in the transitive
# `needs:`-closure of one of those names. Two reasons it is not a join over the
# spec's `exclusions` ledger:
#
#   * A ledger row is not an excuse for the lie. `Doc budgets + anchors` carries
#     an S4 exclusion row and was still the flagship violation — 21 step names
#     reading `(blocking)` under a context nothing can block on.
#   * A join can only reach names somebody already wrote down. connectors.yml's
#     `shim-confinement` job carries a comment claiming BLOCKING and has NO
#     ledger row at all; the join reds 3 specimens, the complement reds 4.
#
# The closure half is what keeps the complement honest in the other direction:
# an upstream job an aggregator `needs:` genuinely does block the merge through
# it, so it must not be accused. Membership is by file+job id, never by rendered
# name — a matrixed upstream renders a suffix its `name:` template does not
# carry (the same trap generate.sh's subsumed_jobs documents).
#
# EVIDENCE IS STRUCTURAL, NEVER A SUBSTRING SEARCH FOR THE CONTEXT NAME (D2).
# Three classes, each anchored to a YAML structure rather than to prose
# proximity:
#
#   1. NAME TOKEN  — the job's post-matrix `name:` matches `(blocking)`.
#   2. STEP TOKEN  — any `steps[].name` inside that job matches `(blocking)`.
#   3. JOB-ADJACENT PROSE — the contiguous `#` block IMMEDIATELY above the job
#      key (blank lines do not break it, any other line does) asserts BLOCKING.
#
# The mirror of advisory_prose_check's PROSE_WINDOW — anchor on the context
# name, read forward N characters — was tried and REJECTED. It misses every
# known specimen (doc-gates.yml states its claim on line 4 and names the job 300
# lines later) and, on the complement, collides on ordinary English: job keys
# named `changes`, `build` and `control-plane` are words that appear in prose
# about something else entirely.
#
# UNRESOLVED IS REPORTED AND GATES, NEVER SKIPPED — the same refusal
# advisory_prose_check makes about scanning zero files:
#
#   (a) a workflow file from which no job can be read at all;
#   (b) a rendered job name still carrying an unexpanded `${{ }}` that is not a
#       `matrix.` reference — its real context name is unknown, so neither
#       membership nor evidence can be decided;
#   (c) FILE-HEADER blocking prose in a file where NOTHING is required or
#       transitively blocking. This one is counted against a COMMITTED BASELINE
#       instead of reddening on sight, and that is deliberate (D3): of today's
#       hits, several are files whose header prose exists precisely to DENY
#       authority ("but NEVER blocks the merge", "can never be a merge gate").
#       Reddening a correction is the fastest way to get a guard switched off.
#       A NEW one reds; a REMOVED one prints a note asking for the baseline to
#       come down, because a guard that reds on its own repair is a trap.
#
# ONE THING IS DELIBERATELY A NOTE AND NOT A FAILURE: a required context that
# matches no job in the scanned directory. It cannot make this clause vacuous —
# an unresolved required name shrinks the closure, which ENLARGES the denied set
# and makes the clause strictly more able to fail. That names actually render is
# deadlock_check's job, one surface over, and duplicating it here would red
# every fixture-scoped probe for a reason that has nothing to do with prose.
# THE DISARM PROOF, recorded here because a tripwire nobody proved can fail is
# the thing this whole file exists to refuse. Run by hand with the §6(d)
# direct-invocation idiom (a mutant copy INSIDE scripts/, invoked with
# --spec/--readback/--runs/--sha/--workflows), on one fixture workflow declaring
# `Widget gate (blocking)` against a spec requiring only `Elixir gate`:
#
#     ARMED    (committed clause)                    -> rc=1
#     DISARMED (BLOCKING_NAME_TOKEN neutered)        -> rc=0
#     the mutant copy's OWN --selftest               -> rc=1, "SELFTEST FAILED"
#
# The third line USED to read rc=0, "SELFTEST OK", and that was the whole
# defect: probe() re-execed "$REPO_ROOT/scripts/required-checks-verify.sh"
# rather than the file it was launched from, so a fully disarmed copy graded
# the COMMITTED script and passed. probe() now re-execs $SELF, so a mutant
# grades itself and a neutered clause reds its own selftest. The §6(d)
# direct-invocation idiom above stays the recipe of record for proving ONE
# clause on a fixture; what changed is that the whole-file arm can fail at all.
# Turning that arm into a planted suite CLAUSE is still cgsiw-s4's slice — this
# one only makes the arm capable of failing for it to assert.
BLOCKING_NAME_TOKEN='[(]blocking[)]'
BLOCKING_PROSE_CLAIM='(^|[^A-Za-z])BLOCKING([^A-Za-z]|$)|blocks the merge|must block|merge gate'
# The escape hatch, established here because the repo had no annotation idiom
# for this at all. `# spec-authority: advisory-ok — <reason>` on the job key, in
# the comment block above it, or on a step's `- name:` line. The reason text is
# MANDATORY and non-empty: a bare token is a silencer, a reason is a decision
# somebody can review. And the annotation is checked in BOTH directions —
# putting it on a context that IS required reds, because that is the same lie
# advisory_prose_check catches, wearing a machine-readable hat.
BLOCKING_HEADER_UNRESOLVED_BASELINE=3

# A job `name:` template as an anchored ERE — `${{ … }}` holes punched out
# BEFORE metacharacters are escaped, so literal parens stay literal. Same
# transform as required-checks-generate.sh's tmpl_to_regex, kept local so this
# guard has no dependency on the generator it is supposed to be independent of.
wf_tmpl_to_regex() {
  local t="$1"
  t="$(printf '%s' "$t" | sed -E 's/\$\{\{[^}]*\}\}/@@MX@@/g')"
  t="$(printf '%s' "$t" | sed -E 's/[][\.^$*+?(){}|\\]/\\&/g')"
  t="$(printf '%s' "$t" | sed 's/@@MX@@/.+/g')"
  printf '%s' "$t"
}

blocking_authority_check() {
  [ -d "$WORKFLOWS_DIR" ] \
    || fail "cannot read $WORKFLOWS_DIR — the blocking-authority clause has nothing to scan (a failure, never a skip)"
  local files
  # BOTH legal spellings. GitHub runs a workflow written `*.yaml` exactly like a
  # `*.yml` one (never-cancel-main-check.sh:96 already scans both, and cgsiw-s2
  # widened required-checks-generate.sh's glob for the same reason). A guard
  # that scans only one spelling is silent on the other — the vacuity class this
  # whole file exists to refuse, so the scan covers both even though zero
  # `*.yaml` workflows exist today.
  files="$(find "$WORKFLOWS_DIR" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) | sort)"
  [ -n "$files" ] \
    || fail "no *.yml or *.yaml under $WORKFLOWS_DIR — scanning zero files is the vacuous pass this guard exists to refuse"

  local tmp idx out
  tmp="$(mktemp -d)"
  idx="$tmp/index.tsv"

  # One row per job: JOB<TAB>file<TAB>job<TAB>line<TAB>rendered-name<TAB>matrixed
  # <TAB>needs<TAB>name-token<TAB>step-token<TAB>adjacent-prose<TAB>annotation.
  # Plus PARSE<TAB>file for a file yielding no jobs and HDR<TAB>file for
  # file-header blocking prose.
  out="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk \
    -v BLOCK_PROSE="$BLOCKING_PROSE_CLAIM" -v NAME_TOKEN="$BLOCKING_NAME_TOKEN" '
    function emit_job(   n) {
      if (job == "") return
      n = adj
      # cap the adjacent block at the last 25 comment lines
      printf "JOB\t%s\t%s\t%d\t%s\t%d\t%s\t%d\t%d\t%d\t%s\n", file, job, jobline,
             (jname == "" ? job : jname), matrixed, (needs == "" ? "-" : needs),
             namehit, stephit, ((n ~ BLOCK_PROSE) ? 1 : 0), (mark == "" ? "-" : mark)
      job = ""; jname = ""; matrixed = 0; needs = ""; namehit = 0; stephit = 0
      adj = ""; mark = ""; instrategy = 0; inneeds = 0
    }
    function endfile() {
      emit_job()
      if (file != "" && njobs == 0) printf "PARSE\t%s\n", file
      if (file != "" && hdrhit) printf "HDR\t%s\n", file
    }
    function note_mark(l,   m) {
      # The comment block above a job key reaches this function with its `#`
      # markers already stripped, so the marker is matched WITHOUT requiring one.
      # A prose mention of the token therefore lands as a malformed hatch rather
      # than as silence — the conservative direction, and the reason this file
      # never spells the token out in ordinary prose.
      if (l !~ /spec-authority:/) return
      m = l; sub(/^.*spec-authority:[ \t]*/, "", m); sub(/[ \t]+$/, "", m)
      if (m ~ /^advisory-ok[ \t]*(—|--)[ \t]*[^ \t]/) mark = "ok"
      else mark = "bad"
    }
    function push_comment(l,   c, i) {
      c = l; sub(/^[ \t]*#[ \t]?/, "", c)
      cl[++ncbuf] = c
      if (ncbuf > 25) { for (i = 1; i < ncbuf; i++) cl[i] = cl[i + 1]; ncbuf-- }
    }
    function joined_comments(   i, s) { s = ""; for (i = 1; i <= ncbuf; i++) s = s " " cl[i]; return s }
    BEGIN { file = "" }
    FNR == 1 {
      endfile()
      file = FILENAME; sub(/^.*\//, "", file)
      injobs = 0; instrategy = 0; inneeds = 0; njobs = 0
      hdr = ""; hdrhit = 0; inhdr = 1; ncbuf = 0
      job = ""; adj = ""; mark = ""
    }
    {
      line = $0

      if (inhdr) {
        if (line ~ /^[ \t]*#/) { h = line; sub(/^[ \t]*#[ \t]?/, "", h); hdr = hdr " " h }
        else if (line !~ /^[ \t]*$/) { inhdr = 0; if (hdr ~ BLOCK_PROSE) hdrhit = 1 }
      }

      if (line ~ /^jobs:[ \t]*$/) { emit_job(); injobs = 1; ncbuf = 0; next }
      if (injobs && line ~ /^[a-zA-Z]/) { emit_job(); injobs = 0 }

      if (injobs && line ~ /^  [A-Za-z0-9_.-]+:[ \t]*(#.*)?$/) {
        emit_job()
        adj = joined_comments()
        job = line; sub(/^  /, "", job); sub(/:.*$/, "", job); jobline = FNR
        note_mark(adj); note_mark(line)
        njobs++
        ncbuf = 0
        next
      }

      if (injobs && job != "") {
        if (line ~ /^    strategy:/) instrategy = 1
        else if (instrategy && line ~ /^    [a-z]/) instrategy = 0
        if (instrategy && line ~ /^      matrix:/) matrixed = 1

        if (line ~ /^    name:/) {
          v = line; sub(/^    name:[ \t]*/, "", v); sub(/[ \t]*#.*$/, "", v)
          gsub(/^["\047]|["\047]$/, "", v); sub(/[ \t]+$/, "", v); jname = v
          if (v ~ NAME_TOKEN) namehit = 1
        } else if (line ~ /^[ \t]*-?[ \t]*name:[ \t]/) {
          v = line; sub(/^[ \t]*-?[ \t]*name:[ \t]*/, "", v); sub(/[ \t]*#.*$/, "", v)
          gsub(/^["\047]|["\047]$/, "", v)
          if (v ~ NAME_TOKEN) stephit = 1
        }

        # Only on a YAML line, never on a free-standing comment inside the job
        # body: those lines are ALSO the adjacent block of the NEXT job, and
        # marking from them let one annotation silence the preceding job too.
        # The hatch lives on the job key, in the block above it, or trailing the
        # `- name:` line of a step — all three are YAML lines or the block.
        if (line !~ /^[ \t]*#/) note_mark(line)

        if (line ~ /^    needs:[ \t]*\[/) {
          v = line; sub(/^    needs:[ \t]*\[/, "", v); sub(/\].*$/, "", v)
          gsub(/[ \t"\047]/, "", v); needs = v; inneeds = 0
        } else if (line ~ /^    needs:[ \t]*$/) inneeds = 1
        else if (line ~ /^    needs:[ \t]*[^ \t[]/) {
          v = line; sub(/^    needs:[ \t]*/, "", v); sub(/[ \t]*#.*$/, "", v)
          gsub(/[ \t"\047]/, "", v); needs = v
        } else if (inneeds && line ~ /^      - /) {
          v = line; sub(/^      -[ \t]*/, "", v); sub(/[ \t]*#.*$/, "", v)
          gsub(/[ \t"\047]/, "", v)
          needs = (needs == "" ? v : needs "," v)
        } else if (inneeds && line !~ /^      /) inneeds = 0
      }

      if (line ~ /^[ \t]*#/) push_comment(line)
      else if (line !~ /^[ \t]*$/) ncbuf = 0
    }
    END { endfile() }
  ' 2>&1)" || { rm -rf "$tmp"; fail "blocking-authority scan could not run: $out"; }
  printf '%s\n' "$out" > "$idx"

  local njobs nfiles
  njobs="$(grep -c '^JOB	' "$idx" || true)"
  nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
  [ "$njobs" -gt 0 ] \
    || { rm -rf "$tmp"; fail "read zero jobs from $nfiles workflow file(s) — scanning zero jobs is the vacuous pass this guard exists to refuse"; }

  # ── UNRESOLVED (a): a file we could read no job out of at all ──────────────
  local unparsed
  unparsed="$(awk -F'\t' '$1 == "PARSE" { print $2 }' "$idx")"

  # ── the blocking closure: required contexts + everything they need ─────────
  local closure="$tmp/closure" snap="$tmp/snap" unresolved_ctx="" ctx row re
  : > "$closure"
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    row=""
    while IFS=$'\t' read -r tag f j _ln nm mx _nd _n _s _p _m; do
      [ "$tag" = "JOB" ] || continue
      re="$(wf_tmpl_to_regex "$nm")"
      if grep -qE "^${re}$" <<<"$ctx"; then row="$f	$j"; break; fi
      if [ "$mx" = "1" ] && ! grep -q '\${{' <<<"$nm" && grep -qE "^${re} \(.+\)$" <<<"$ctx"; then
        row="$f	$j"; break
      fi
    done < "$idx"
    if [ -n "$row" ]; then
      grep -qxF "$row" "$closure" || printf '%s\n' "$row" >> "$closure"
    else
      unresolved_ctx="$unresolved_ctx$ctx
"
    fi
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF

  local grew=1 key f j needs n k
  while [ "$grew" -eq 1 ]; do
    grew=0
    cp "$closure" "$snap"
    while IFS=$'\t' read -r f j; do
      [ -n "$f" ] || continue
      needs="$(awk -F'\t' -v f="$f" -v j="$j" '$1 == "JOB" && $2 == f && $3 == j { print $7 }' "$idx")"
      [ "$needs" = "-" ] && needs=""
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        k="$(printf '%s\t%s' "$f" "$n")"
        if ! grep -qxF "$k" "$closure"; then
          printf '%s\n' "$k" >> "$closure"
          grew=1
        fi
      done <<EOF
$(printf '%s' "$needs" | tr ',' '\n')
EOF
    done < "$snap"
  done

  # ── the verdict, per denied job ───────────────────────────────────────────
  local violations="" hatched=0 hatch_lies="" hatch_bad="" interp="" denied=0
  local tag ln nm mx _nd nh sh ph mk required why
  while IFS=$'\t' read -r tag f j ln nm mx _nd nh sh ph mk; do
    [ "$tag" = "JOB" ] || continue
    required=0
    if grep -qxF "$(printf '%s\t%s' "$f" "$j")" "$closure"; then required=1; fi

    if [ "$mk" = "bad" ]; then
      hatch_bad="$hatch_bad$f:$ln  job '$j'
"
    fi
    if [ "$mk" = "ok" ] && [ "$required" -eq 1 ]; then
      hatch_lies="$hatch_lies$f:$ln  job '$j' renders \"$nm\", which IS required or transitively blocking
"
    fi

    if [ "$required" -eq 1 ]; then continue; fi
    denied=$((denied + 1))

    # UNRESOLVED (b): a rendered name we cannot resolve to a real context
    if printf '%s' "$nm" | sed -E 's/\$\{\{[[:space:]]*matrix\.[^}]*\}\}//g' | grep -q '\${{'; then
      interp="$interp$f:$ln  job '$j' renders name template \"$nm\"
"
      continue
    fi

    if [ "$mk" = "ok" ]; then hatched=$((hatched + 1)); continue; fi

    why=""
    if [ "$nh" = "1" ]; then why="${why}job name says (blocking); "; fi
    if [ "$sh" = "1" ]; then why="${why}a step name says (blocking); "; fi
    if [ "$ph" = "1" ]; then why="${why}the comment block above the job key asserts blocking authority; "; fi
    if [ -n "$why" ]; then
      violations="$violations$f:$ln|$j|$nm|${why%; }
"
    fi
  done < "$idx"

  # ── UNRESOLVED (c): file-header prose over a fully-denied file ────────────
  local hdr_unresolved="" hdr_n=0 hf hdr_blocking
  while IFS=$'\t' read -r tag hf; do
    [ "$tag" = "HDR" ] || continue
    hdr_blocking=0
    if awk -F'\t' -v f="$hf" '$1 == "JOB" && $2 == f { printf "%s\t%s\n", $2, $3 }' "$idx" \
         | grep -qxFf "$closure" -; then hdr_blocking=1; fi
    if [ "$hdr_blocking" -eq 1 ]; then continue; fi
    hdr_unresolved="$hdr_unresolved  $hf
"
    hdr_n=$((hdr_n + 1))
  done < "$idx"

  rm -rf "$tmp"

  local rc=0
  if [ -n "$unparsed" ]; then
    echo "FAIL: UNRESOLVED — no job could be read out of these workflow file(s), so their blocking claims are undecidable:" >&2
    printf '%s\n' "$unparsed" | sed 's/^/        /' >&2
    rc=1
  fi
  if [ -n "$interp" ]; then
    echo "FAIL: UNRESOLVED — a denied job's rendered name still carries an unexpanded \${{ }} that is not a matrix reference," >&2
    echo "      so its real context name — and therefore whether it may claim authority — cannot be decided:" >&2
    printf '%s' "$interp" | sed 's/^/        /' >&2
    rc=1
  fi
  if [ -n "$hatch_bad" ]; then
    echo "FAIL: a \`# spec-authority: advisory-ok\` annotation carries no reason text." >&2
    echo "      The form is \`# spec-authority: advisory-ok — <reason>\`; a bare token silences the guard without recording a decision." >&2
    printf '%s' "$hatch_bad" | sed 's/^/        /' >&2
    rc=1
  fi
  if [ -n "$hatch_lies" ]; then
    echo "FAIL: a \`# spec-authority: advisory-ok\` annotation sits on a context the committed spec REQUIRES." >&2
    echo "      The annotation is for prose that overclaims; here it under-claims, which is the defect advisory_prose_check catches." >&2
    printf '%s' "$hatch_lies" | sed 's/^/        /' >&2
    rc=1
  fi
  if [ "$hdr_n" -gt "$BLOCKING_HEADER_UNRESOLVED_BASELINE" ]; then
    echo "FAIL: UNRESOLVED file-header blocking prose rose above the committed baseline ($hdr_n > $BLOCKING_HEADER_UNRESOLVED_BASELINE)." >&2
    echo "      These files claim blocking authority in their HEADER while nothing in them is required or transitively blocking:" >&2
    printf '%s' "$hdr_unresolved" >&2
    rc=1
  fi
  if [ -n "$violations" ]; then
    echo "FAIL: a workflow claims BLOCKING authority the committed spec DENIES." >&2
    echo "      None of these contexts is required by $SPEC, nor needed by one that is." >&2
    printf '%s' "$violations" | while IFS='|' read -r loc j nm why; do
      echo "      $loc  job '$j' renders \"$nm\"" >&2
      echo "        … $why" >&2
    done
    echo "      Fix the PROSE, not the spec. If the claim is a deliberate aspiration, annotate it:" >&2
    echo "        # spec-authority: advisory-ok — <why this says blocking while the spec denies it>" >&2
    rc=1
  fi
  [ "$rc" -eq 0 ] || return 1

  if [ -n "$unresolved_ctx" ]; then
    say "  note   $(printf '%s' "$unresolved_ctx" | grep -c . || true) required context(s) matched no job under $WORKFLOWS_DIR — the closure shrank, so the denied set only GREW (deadlock_check owns whether names render)"
  fi
  if [ "$hdr_n" -lt "$BLOCKING_HEADER_UNRESOLVED_BASELINE" ]; then
    say "  note   UNRESOLVED file-header blocking prose is now $hdr_n, below the committed baseline of $BLOCKING_HEADER_UNRESOLVED_BASELINE — lower BLOCKING_HEADER_UNRESOLVED_BASELINE to ratchet"
  fi
  say "  ok     no denied context claims blocking authority ($denied of $njobs job(s) outside the required set + its needs-closure; $hatched annotated advisory-ok; $hdr_n header claim(s) UNRESOLVED at baseline $BLOCKING_HEADER_UNRESOLVED_BASELINE)"
  return 0
}

# ── modes ────────────────────────────────────────────────────────────────────
run_full() {
  read_spec
  say "spec: $SPEC ($(jq -r '.protection.required_status_checks.checks | length' "$SPEC") required context(s), enforced=$(jq -r '.enforced' "$SPEC"))"
  local rc=0 actual
  # enforced=false is a COMMITTED, reviewable state, not an unreadable input —
  # the same distinction --ci draws. Before the flip there is nothing live to
  # compare against, and hard-failing here would make hgw2-s7's own gate
  # (`bash scripts/required-checks-verify.sh`) red for the one reason it is
  # SUPPOSED to be red on: protection not applied yet. The deadlock detector
  # below still runs against a real head, so this mode is never vacuous either.
  if [ "$(spec_enforced)" != "true" ]; then
    say "── enforced=false: the spec CLAIMS nothing has been applied — checking that against the live branch ──"
    say "  There is no full-object diff to run before the flip, but there is still one"
    say "  question worth asking, and this branch used to return 0 without asking it:"
    say "  is the branch protected right now anyway? A yes is drift, in the direction"
    say "  no amount of spec-reading can see."
    unapplied_spec_matches_reality || return 1
    say "  The deadlock detector below still runs against a real PR head. From the"
    say "  commit that flips enforced to true, an unreadable or absent protection"
    say "  config is a hard failure here."
    say "── advisory-prose clause (spec-derived names × workflow prose) ──"
    advisory_prose_check || return 1
    say "── blocking-authority clause (the inverse: prose claiming authority the spec denies) ──"
    blocking_authority_check || return 1
    say "── merge-truth clause (the same names, the prose an agent actually reads) ──"
    merge_truth_prose_check || return 1
    local drc0=0
    deadlock_check "${HEAD_SHA:-$(recent_pr_head)}" || drc0=$?
    [ "$drc0" -eq 3 ] && return 3
    [ "$drc0" -eq 4 ] && say "NOTE: the sampled head carries a cancelled required context (above). See --deadlock for the actionable form."
    [ "$drc0" -eq 0 ] || [ "$drc0" -eq 4 ] || return 1
    say "OK: the branch is genuinely unprotected, and the committed spec and the rendered check names agree; protection is not applied yet."
    return 0
  fi
  actual="$(live_protection)"
  say "── live protection vs committed spec ──"
  compare_protection "$actual" || rc=1
  say "── advisory-prose clause (spec-derived names × workflow prose) ──"
  advisory_prose_check || rc=1
  say "── blocking-authority clause (the inverse: prose claiming authority the spec denies) ──"
  blocking_authority_check || rc=1
  say "── merge-truth clause (the same names, the prose an agent actually reads) ──"
  merge_truth_prose_check || rc=1
  say "── deadlock detector ──"
  local sha="${HEAD_SHA:-$(recent_pr_head)}"
  local drc=0
  deadlock_check "$sha" || drc=$?
  [ "$drc" -eq 3 ] || [ "$drc" -eq 4 ] || [ "$drc" -eq 0 ] || rc=1
  # Precedence, deliberate: config drift outranks DEADLOCK in the exit code,
  # because a spec that disagrees with live config is the actionable finding and
  # a typo'd context reports as BOTH. Both are always printed; only the code is
  # ranked. DEADLOCK (3) is reserved for "live and spec agree, and the names
  # still never render" — the state no refusal message can tell you (D38).
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: the committed spec is contradicted — by live config, by workflow prose, or both (see above)." >&2
    return 1
  fi
  [ "$drc" -eq 3 ] && return 3
  # Note-only in the sampling modes; EXIT 4 belongs to --deadlock, the mode a
  # caller points at a SPECIFIC head. See the run_ci comment for the reasoning.
  [ "$drc" -eq 4 ] && say "NOTE: the sampled head carries a cancelled required context (above). See --deadlock for the actionable form."
  say "OK: live protection, the committed spec and the rendered check names all agree."
  return 0
}

run_ci() {
  read_spec
  local rc=0
  say "── deadlock detector (runs in EVERY mode — this is what keeps the guard non-vacuous before the flip) ──"
  local sha="${HEAD_SHA:-$(recent_pr_head)}"
  local drc=0
  deadlock_check "$sha" || drc=$?
  [ "$drc" -eq 3 ] || [ "$drc" -eq 4 ] || [ "$drc" -eq 0 ] || rc=1

  say "── advisory-prose clause (spec-derived names × workflow prose) ──"
  advisory_prose_check || rc=1
  say "── blocking-authority clause (the inverse: prose claiming authority the spec denies) ──"
  blocking_authority_check || rc=1
  say "── merge-truth clause (the same names, the prose an agent actually reads) ──"
  merge_truth_prose_check || rc=1

  if [ "$(spec_enforced)" = "true" ]; then
    say "── enforced=true: live protection must match ──"
    local actual
    actual="$(live_protection)"
    compare_protection "$actual" || rc=1
  else
    # THE ARM THAT USED TO DECLINE TO LOOK (cchi-w51). Until this commit these
    # five lines were the WHOLE of the enforced=false path in --ci: four
    # sentences arguing that `enforced=false` is a committed, reviewable state,
    # and not one read of the live branch. cch-w51-s6 had already closed the
    # identical hole in `run_full` — deliberately scoping itself there, because
    # --ci is what `required-checks-drift.yml` runs on every PR and flipping its
    # polarity is a merge-path change. That review is this commit.
    #
    # The prose was not wrong; it was answering a question nobody asked. That
    # the state is committed and reviewable says nothing about whether it is
    # TRUE, and the one direction a spec-reader can never see is SPEC SAYS THE
    # GATE IS OFF WHILE THE GATE IS ON. So the argument stays (as one line) and
    # the clause it used to stand in for now runs.
    say "── enforced=false: the spec CLAIMS nothing has been applied — checking that against the live branch ──"
    say "  A committed enforced=false is a reviewable state, not an unreadable input."
    say "  Reviewable is not the same as TRUE: this asks the live branch."
    unapplied_spec_matches_reality || rc=1
  fi
  [ "$rc" -eq 0 ] || { echo "FAIL: required-checks guard is RED." >&2; return 1; }
  [ "$drc" -eq 3 ] && return 3
  # RE-RUN is deliberately NOT a CI failure, and this is a scope judgement, not
  # a softening. --ci samples an ARBITRARY settled head (a recently merged PR)
  # to render names against, and 13 of 120 recent heads carry a cancelled latest
  # run. A cancelled run on someone else's merged PR is not drift between this
  # repo's committed spec and its live protection, which is the only thing this
  # guard certifies — failing on it would red every PR for a state no author of
  # that PR can fix. It is still PRINTED, loudly, by deadlock_check above. The
  # consumer that must act on it is the merge verb, which asks the head it is
  # actually about to merge: scripts/bp-merge.sh calls --deadlock and exits 3.
  if [ "$drc" -eq 4 ]; then
    say "NOTE: the sampled head carries a cancelled required context (see above). Not drift; not a CI failure here."
  fi
  say "OK: required-checks guard green."
  return 0
}

# ── selftest ─────────────────────────────────────────────────────────────────
# Every clause is proven by MUTATION on temp copies: the honest read-back
# passes, and each single-field corruption reds. A clause that cannot fail is
# not a clause.
selftest() {
  local tmp rc=0
  tmp="$(mktemp -d)"

  local good_spec="$tmp/spec.json"
  cat > "$good_spec" <<'JSON'
{
  "enforced": true,
  "repo": "FRIKKern/barkpark",
  "branch": "main",
  "protection": {
    "required_status_checks": { "strict": false, "checks": [
      { "context": "Elixir gate", "app_id": 15368 },
      { "context": "PR references an active task", "app_id": 15368 }
    ] },
    "enforce_admins": true,
    "required_pull_request_reviews": null,
    "restrictions": null,
    "required_linear_history": false,
    "allow_force_pushes": false,
    "allow_deletions": false,
    "block_creations": false,
    "required_conversation_resolution": false,
    "lock_branch": false,
    "allow_fork_syncing": false
  }
}
JSON

  local good_rb="$tmp/readback.json"
  cat > "$good_rb" <<'JSON'
{
  "url": "https://api.github.com/repos/FRIKKern/barkpark/branches/main/protection",
  "required_status_checks": {
    "url": "…", "strict": false, "contexts": ["Elixir gate", "PR references an active task"],
    "contexts_url": "…",
    "checks": [
      { "context": "Elixir gate", "app_id": 15368 },
      { "context": "PR references an active task", "app_id": 15368 }
    ]
  },
  "enforce_admins": { "url": "…", "enabled": true },
  "required_signatures": { "url": "…", "enabled": false },
  "required_linear_history": { "enabled": false },
  "allow_force_pushes": { "enabled": false },
  "allow_deletions": { "enabled": false },
  "block_creations": { "enabled": false },
  "required_conversation_resolution": { "enabled": false },
  "lock_branch": { "enabled": false },
  "allow_fork_syncing": { "enabled": false }
}
JSON

  local good_runs="$tmp/runs.json"
  cat > "$good_runs" <<'JSON'
{ "check_runs": [
  { "name": "Elixir gate", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" },
  { "name": "PR references an active task", "conclusion": "failure", "started_at": "2026-07-28T01:00:00Z" },
  { "name": "PR references an active task", "conclusion": "success", "started_at": "2026-07-28T02:00:00Z" },
  { "name": "Boundary gate (advisory)", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" }
] }
JSON

  # THE NEUTRAL PROSE CORPUS, and it is the same isolation `--workflows` already
  # buys every probe that plants a fixture workflow. Nearly every probe below
  # overrides the SPEC — two contexts, one context, a `Widget gate` that does not
  # exist — and merge_truth_prose_check is SPEC-DERIVED in both directions: the
  # names it hunts AND rule 1's clause boundary, which stops the attributed span
  # at the next required-context name. Narrow the spec and a span in the REAL
  # charter that used to stop at `Cloud gate` runs on into a disclaimer 150
  # characters later, so probe 21 reds on a sentence it has nothing to do with.
  # Measured, not predicted: before this default, `--selftest` failed at 21/29
  # with an UNPINNED row at charter.md:7213 and a STALE pin, both artefacts of
  # the two-context fixture spec. A probe must red on the clause it names.
  local neutral_prose="$tmp/prose-neutral"
  mkdir -p "$neutral_prose"
  printf '%s\n' "Neutral corpus. It names no required context, so the merge-truth clause has something real to scan and nothing to say about it." \
    > "$neutral_prose/neutral.md"

  probe() { # label expect_rc <args…>
    local label="$1" expect="$2"; shift 2
    local out rc=0
    # Only when the caller has not chosen its own corpus — probes 24-27 are ABOUT
    # this clause and pass their own --prose, which must win.
    case " $* " in *" --prose "*) : ;; *) set -- "$@" --prose "$neutral_prose" ;; esac
    out="$(bash "$SELF" "$@" 2>&1)" || rc=$?
    if [ "$rc" -eq "$expect" ]; then
      echo "  ok   $label (exit $rc)"
      return 0
    fi
    echo "  SELFTEST FAIL: $label expected exit $expect, got $rc" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    return 1
  }

  echo "── verify selftest: every clause proven by mutation ──"

  # Now that probe() re-execs $SELF, a copy run from OUTSIDE the repo actually
  # executes instead of exiting 127 — and carries REPO_ROOT into its own parent
  # directory. Every probe that does not pass --workflows would then red on a
  # missing scan directory rather than on the clause it names, which quietly
  # turns the fourteen probes expecting exit 1 into "ok" for the wrong reason.
  # Refuse by name instead: the 127 used to say this loudly and it must not be
  # traded for a green.
  [ -d "$WORKFLOWS_DIR" ] || {
    echo "  SELFTEST FAIL: this copy is $SELF, so REPO_ROOT is $REPO_ROOT and $WORKFLOWS_DIR does not exist — the probes that scan workflows would red on the missing directory instead of on their own clause. Run the copy from inside the repo's scripts/." >&2
    rm -rf "$tmp"
    echo "SELFTEST FAILED" >&2
    return 1
  }

  probe "1/29 honest read-back passes" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe || rc=1

  jq '.protection.required_status_checks.checks[0].context = "Elixir gat"' "$good_spec" > "$tmp/typo.json"
  probe "2/29 a typo'd context reds (GitHub accepts it; we must not)" 1 \
    --spec "$tmp/typo.json" --readback "$good_rb" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.checks[0].app_id = null' "$good_rb" > "$tmp/nullapp.json"
  probe "3/29 app_id:null where the spec pins an id is HARD" 1 \
    --spec "$good_spec" --readback "$tmp/nullapp.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.checks[0].app_id = 8329' "$good_rb" > "$tmp/wrongapp.json"
  probe "4/29 a wrong app_id reds" 1 \
    --spec "$good_spec" --readback "$tmp/wrongapp.json" --runs "$good_runs" --sha probe || rc=1

  jq '.enforce_admins.enabled = false' "$good_rb" > "$tmp/breakglass.json"
  probe "5/29 a left-open break-glass (enforce_admins false) reds" 1 \
    --spec "$good_spec" --readback "$tmp/breakglass.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_linear_history.enabled = true' "$good_rb" > "$tmp/oob.json"
  probe "6/29 out-of-band required_linear_history=true reds (the PUT does not converge it — D41)" 1 \
    --spec "$good_spec" --readback "$tmp/oob.json" --runs "$good_runs" --sha probe || rc=1

  jq '. + {"required_deployments": {"enabled": true}}' "$good_rb" > "$tmp/extra.json"
  probe "7/29 a read-back key the spec never mentions reds (FULL-object diff)" 1 \
    --spec "$good_spec" --readback "$tmp/extra.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.strict = true' "$good_rb" > "$tmp/strict.json"
  probe "8/29 strict:true reds (it would serialise this fleet's parallel merges)" 1 \
    --spec "$good_spec" --readback "$tmp/strict.json" --runs "$good_runs" --sha probe || rc=1

  jq '.protection.required_status_checks.checks += [{"context":"No workflow emits me","app_id":15368}]' "$good_spec" > "$tmp/deadspec.json"
  probe "9/29 a spec context no workflow emits is DEADLOCK — a third state, at N=3 where the refusal message names nothing" 3 \
    --spec "$tmp/deadspec.json" --readback "$good_rb" --runs "$good_runs" --sha probe --deadlock || rc=1

  probe "10/29 an unreadable protection read-back FAILS (never skips)" 1 \
    --spec "$good_spec" --readback "$tmp/does-not-exist.json" --runs "$good_runs" --sha probe || rc=1

  probe "11/29 an unreadable check-run feed FAILS (never skips)" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/no-runs.json" --sha probe || rc=1

  echo '{ "check_runs": [] }' > "$tmp/emptyruns.json"
  probe "12/29 an EMPTY check-run feed FAILS — agreement against nothing is the vacuous pass this epic exists for" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/emptyruns.json" --sha probe || rc=1

  # 13 & 14 are the D56 clause: the detector used to match on `cut -f1` and
  # throw away the conclusion column rendered_names already emits, so a required
  # context concluding `cancelled` returned EXIT 0 — shape-identical to green on
  # a head that is frozen forever. Proven live on head 5ea4cb4f. Mutation-proof:
  # 13 must be 4 and 14 must be 0, and reverting the clause makes 13 return 0.
  jq '(.check_runs[] | select(.name == "PR references an active task" and .started_at == "2026-07-28T02:00:00Z") | .conclusion) = "cancelled"' \
    "$good_runs" > "$tmp/cancelledruns.json"
  probe "13/29 a required context whose LATEST run concluded cancelled is RE-RUN, not green (D56; returned exit 0 before this clause)" 4 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/cancelledruns.json" --sha probe --deadlock || rc=1

  # The mirror clause: cancellation on a NON-required check is none of our
  # business, and a detector that reds on it would red constantly — advisory
  # checks are cancelled by concurrency groups all day.
  jq '(.check_runs[] | select(.name == "Boundary gate (advisory)") | .conclusion) = "cancelled"' \
    "$good_runs" > "$tmp/advcancelled.json"
  probe "14/29 a cancelled ADVISORY check does NOT trip RE-RUN (the clause must be scoped to the required set)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/advcancelled.json" --sha probe --deadlock || rc=1

  # The caller-scope clause above, proven rather than asserted: --ci must NOT
  # turn a cancelled run on an arbitrary sampled head into a red, while
  # --deadlock (13/15) still exits 4 on the identical input.
  probe "15/29 --ci does NOT red on a cancelled required context (it samples a FOREIGN settled head; the merge verb asks --deadlock about its OWN head)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/cancelledruns.json" --sha probe --ci || rc=1

  # 16 pins the scope of the RE-RUN set from the other side. GitHub counts a
  # required check concluding `skipped` as SATISFYING protection, so a detector
  # that called it RE-RUN would refuse a head GitHub would merge — a false stall
  # in a wrapper whose whole promise is that it never lies about the merge. The
  # builder had `skipped` in the set as an unmeasured guess; the review took it
  # out and pinned the removal here, so re-adding it reds this probe.
  jq '(.check_runs[] | select(.name == "PR references an active task" and .started_at == "2026-07-28T02:00:00Z") | .conclusion) = "skipped"' \
    "$good_runs" > "$tmp/skippedruns.json"
  probe "16/29 a required context concluding SKIPPED is NOT RE-RUN (GitHub treats skipped as satisfying; refusing it would be a false stall)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/skippedruns.json" --sha probe --deadlock || rc=1

  # 17 & 18 are the cch-w32-s4 clause, and they are ONE mutation proven from
  # both sides with the SAME fixture workflow. The fixture reproduces the exact
  # defect console-harness.yml carried: a disclaimer about a required context,
  # wrapped across comment lines so a single-line grep would miss it.
  mkdir -p "$tmp/wf"
  cat > "$tmp/wf/fixture.yml" <<'YML'
name: Fixture
on: [pull_request]
jobs:
  probe:
    # HONEST SCOPE: `Elixir gate`, the aggregator this job reaches branch
    # protection through, is ADVISORY today — its red is visible but it does
    # not by itself block a merge.
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YML
  probe "17/29 a workflow calling a SPEC'D context advisory reds (the defect this clause exists for; claim wrapped over 3 comment lines, so a line-wise grep would miss it)" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe --workflows "$tmp/wf" || rc=1

  # The mirror, and the whole point: the guard tracks the SPEC, not a frozen
  # string. Drop `Elixir gate` from the required set (spec and read-back
  # together, so the live-vs-spec half stays honest) and the IDENTICAL sentence
  # in the IDENTICAL file becomes a true statement — and goes green. A guard
  # that stayed red here would be pinning a phrase, not a fact.
  jq 'del(.protection.required_status_checks.checks[] | select(.context == "Elixir gate"))' "$good_spec" > "$tmp/noelixir_spec.json"
  jq '.required_status_checks.contexts = ["PR references an active task"]
      | .required_status_checks.checks = [{"context":"PR references an active task","app_id":15368}]' \
    "$good_rb" > "$tmp/noelixir_rb.json"
  probe "18/29 the SAME claim in the SAME file goes GREEN once that context leaves the spec (the clause tracks the committed set, not a frozen string)" 0 \
    --spec "$tmp/noelixir_spec.json" --readback "$tmp/noelixir_rb.json" --runs "$good_runs" --sha probe --workflows "$tmp/wf" || rc=1

  # 19-22 are the cgsiw-s1 clause, the INVERSE of 17/18: a workflow claiming
  # BLOCKING authority the committed spec DENIES. Same idiom as 17/18 — one
  # heredoc fixture per directory, pointed at by --workflows, and the mirror
  # proving the clause tracks the committed set rather than a frozen string.
  # Each fixture gets its OWN directory because the clause scans every *.yml in
  # the one it is given, so sharing $tmp/wf would leak 17/18's specimen in here.
  mkdir -p "$tmp/wf-block"
  cat > "$tmp/wf-block/widget.yml" <<'YML'
name: Widget
on: [pull_request]
jobs:
  widget:
    name: Widget gate (blocking)
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YML
  probe "19/29 a workflow claiming BLOCKING authority for a context the spec does NOT require reds (the inverse of 17; nothing caught this before cgsiw-s1)" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe --workflows "$tmp/wf-block" || rc=1

  # The mirror, and the whole point: the subject set is the COMPLEMENT of the
  # committed required set, derived every run. Put that same context INTO the
  # spec (and the read-back, and the rendered names, so the other three clauses
  # stay honest) and the IDENTICAL file becomes a true statement, and greens.
  jq '.protection.required_status_checks.checks += [{"context":"Widget gate (blocking)","app_id":15368}]' \
    "$good_spec" > "$tmp/widget_spec.json"
  jq '.required_status_checks.contexts += ["Widget gate (blocking)"]
      | .required_status_checks.checks += [{"context":"Widget gate (blocking)","app_id":15368}]' \
    "$good_rb" > "$tmp/widget_rb.json"
  jq '.check_runs += [{"name":"Widget gate (blocking)","conclusion":"success","started_at":"2026-07-28T01:00:00Z"}]' \
    "$good_runs" > "$tmp/widget_runs.json"
  probe "20/29 the SAME claim in the SAME file goes GREEN once that context IS required (the clause reads the complement of the committed set, not a frozen string)" 0 \
    --spec "$tmp/widget_spec.json" --readback "$tmp/widget_rb.json" --runs "$tmp/widget_runs.json" --sha probe --workflows "$tmp/wf-block" || rc=1

  # 21/23 establishes the escape hatch, and 22/23 is why it is an escape hatch
  # and not a silencer: the reason text is mandatory. A bare token would let any
  # future overclaim be waved through with six characters and no decision.
  mkdir -p "$tmp/wf-hatch"
  cat > "$tmp/wf-hatch/widget.yml" <<'YML'
name: Widget
on: [pull_request]
jobs:
  # spec-authority: advisory-ok — the token names authority inside this
  # workflow, and the ledger row this context carries is keyed on the name.
  widget:
    name: Widget gate (blocking)
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YML
  probe "21/29 the escape hatch WITH a reason greens the identical violation (a spec-authority advisory-ok comment carrying a real why)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe --workflows "$tmp/wf-hatch" || rc=1

  mkdir -p "$tmp/wf-hatch-empty"
  cat > "$tmp/wf-hatch-empty/widget.yml" <<'YML'
name: Widget
on: [pull_request]
jobs:
  # spec-authority: advisory-ok —
  widget:
    name: Widget gate (blocking)
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YML
  probe "22/29 the hatch with an EMPTY reason REDS — a bare token is a silencer, a reason is a decision somebody can review" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe --workflows "$tmp/wf-hatch-empty" || rc=1

  # The hatch checked in the OTHER direction. An annotation saying "the spec
  # denies this and we mean it" placed on a context the spec REQUIRES is the
  # same rot advisory_prose_check catches, wearing a machine-readable hat — so
  # it must red rather than exempt. Same fixture as 21, only the spec moves: the
  # identical annotated file is fine while the context is denied, and a failure
  # the moment it is required.
  probe "23/29 an advisory-ok annotation on a context the spec REQUIRES reds (the hatch lying in the other direction)" 1 \
    --spec "$tmp/widget_spec.json" --readback "$tmp/widget_rb.json" --runs "$tmp/widget_runs.json" --sha probe --workflows "$tmp/wf-hatch" || rc=1

  # ── 24-27: the merge-truth clause, OUTSIDE .github/workflows (cch-w34) ─────
  # The fixture is a CHARTER, nested two directories deep and named `*.md` —
  # the two properties the clause above is structurally blind to. Its four
  # decision rows are the four cases that have to be told apart, and they live
  # in ONE file on purpose: a fixture with one line per probe would prove the
  # regexes and not the discrimination.
  mkdir -p "$tmp/prose/nested/deeper"
  cat > "$tmp/prose/nested/deeper/bp-fixture-charter.md" <<'MD'
# Fixture charter

- **D1 — the ASSERTION.** Land on green. `Elixir gate` is ADVISORY today, so a red
  one does not stop the merge button; treat it as blocking anyway.
- **D2 — a dated RECORD, which must stay green.** At the time this wave was
  written `Elixir gate` was advisory; it is required now.
- **D3 — a QUOTED past reason, which must stay green.** The seal printed
  *"`Elixir gate` is NOT a required status check on main"* under the old spec.
- **D4 — PROXIMITY, not attribution, which must stay green.** The required set
  is `Elixir gate` and `PR references an active task`; doc-gates hosts the
  shell check but is NOT required.
MD
  probe "24/29 a charter TWO directories deep, named .md, calling a required context advisory REDS — the corpus the depth-1 workflow glob cannot reach" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe \
    --workflows "$WORKFLOWS_DIR" --prose "$tmp/prose" || rc=1

  # Delete ONLY D1. Everything left is the audit trail this repo is mostly made
  # of — a dated retraction, a quoted past reason, and a required name sitting
  # near somebody ELSE'S disclaimer. If any of the three red, the widening is
  # 94% noise and gets switched off in a wave; that is the measured failure this
  # probe exists to hold shut.
  sed -e '/D1 — the ASSERTION/,+1d' "$tmp/prose/nested/deeper/bp-fixture-charter.md" > "$tmp/prose/nested/deeper/x" \
    && mv "$tmp/prose/nested/deeper/x" "$tmp/prose/nested/deeper/bp-fixture-charter.md"
  probe "25/29 …and with ONLY the claim removed the dated record, the quoted past reason and the proximity row all stay GREEN (assertion vs. record, told apart)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe \
    --workflows "$WORKFLOWS_DIR" --prose "$tmp/prose" || rc=1

  # SPEC-DERIVED, the same pair probes 17/18 make for the clause above: the
  # identical sentence is a lie about a REQUIRED context and merely true about a
  # denied one. Nothing here is a frozen string.
  mkdir -p "$tmp/prose-denied"
  cat > "$tmp/prose-denied/charter.md" <<'MD'
- **D1.** `Widget gate` is ADVISORY today, so a red one does not stop the merge.
MD
  probe "26/29 the SAME sentence about a context the committed spec does NOT require is green — the clause reads the spec, never a frozen name" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe \
    --workflows "$WORKFLOWS_DIR" --prose "$tmp/prose-denied" || rc=1

  # Scanning nothing is the vacuous pass this whole file exists to refuse, and
  # the clause has to make that refusal for its OWN corpus too.
  mkdir -p "$tmp/prose-empty"
  probe "27/29 a prose root with no readable text file FAILS — scanning zero files is never a green" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe \
    --workflows "$WORKFLOWS_DIR" --prose "$tmp/prose-empty" || rc=1

  # ── 28-29: --ci reads live protection on enforced=false too (cchi-w51) ─────
  # run_full has been checked here since cch-w51-s6; --ci had the same shape and
  # printed prose instead. It is the arm required-checks-drift.yml runs on every
  # PR, so it gets its own pair rather than inheriting run_full's.
  local unapplied="$tmp/spec-unapplied.json"
  jq '.enforced = false' "$good_spec" > "$unapplied"
  local unprotected="$tmp/rb-unprotected.json"
  printf '%s\n' '{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}' > "$unprotected"
  probe "28/29 --ci on an enforced=false spec against a PROTECTED branch REDS — the direction no amount of spec-reading can see" 1 \
    --ci --spec "$unapplied" --readback "$good_rb" --runs "$good_runs" --sha probe \
    --workflows "$WORKFLOWS_DIR" --prose "$tmp/prose" || rc=1
  probe "29/29 …and --ci on the same spec against a genuinely unprotected branch still exits 0 — the fix is not \"always red here\"" 0 \
    --ci --spec "$unapplied" --readback "$unprotected" --runs "$good_runs" --sha probe \
    --workflows "$WORKFLOWS_DIR" --prose "$tmp/prose" || rc=1

  rm -rf "$tmp"
  echo
  if [ "$rc" -eq 0 ]; then
    echo "SELFTEST OK — every clause can both pass and fail."
  else
    echo "SELFTEST FAILED" >&2
  fi
  return "$rc"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) SPEC="$2"; shift 2 ;;
      --branch) BRANCH_OVERRIDE="$2"; shift 2 ;;
      --readback) READBACK_FILE="$2"; shift 2 ;;
      --runs) RUNS_FILE="$2"; shift 2 ;;
      --sha) HEAD_SHA="$2"; shift 2 ;;
      --workflows) WORKFLOWS_DIR="$2"; shift 2 ;;
      # The merge-truth clause's scan root. Same contract as --workflows: an
      # override exists ONLY so the suite can point the identical clause at a
      # fixture tree; every real invocation reads the committed corpus.
      --prose) PROSE_ROOT_OVERRIDE="$2"; shift 2 ;;
      --deadlock) MODE="deadlock"; shift ;;
      --ci) MODE="ci"; shift ;;
      --selftest) MODE="selftest"; shift ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  case "$MODE" in
    selftest) selftest ;;
    deadlock)
      read_spec
      deadlock_check "${HEAD_SHA:-$(recent_pr_head)}"
      ;;
    ci)   run_ci ;;
    *)    run_full ;;
  esac
}

main "$@"

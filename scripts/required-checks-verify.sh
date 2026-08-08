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
  jq -r '.check_runs | sort_by(.started_at // "") | .[] | [.name, (.conclusion // "null"), (.started_at // "")] | @tsv' <<<"$json" \
    | awk -F'\t' '{ seen[$1] = $2 } END { for (n in seen) printf "%s\t%s\n", n, seen[n] }' | sort
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
    # AND nothing re-reports them on its own. Probe 16/18 pins this both ways.
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
  files="$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.yml' | sort)"
  [ -n "$files" ] \
    || fail "no *.yml under $WORKFLOWS_DIR — scanning zero files is the vacuous pass this guard exists to refuse"

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

  if [ "$(spec_enforced)" = "true" ]; then
    say "── enforced=true: live protection must match ──"
    local actual
    actual="$(live_protection)"
    compare_protection "$actual" || rc=1
  else
    say "── enforced=false ──"
    say "  The committed spec says protection has NOT been applied yet. That is a"
    say "  COMMITTED, reviewable state visible in the file's diff — not an"
    say "  unreadable input silently swallowed. The deadlock detector above still"
    say "  ran against a real head. hgw2-s7 flips enforced to true, and from that"
    say "  commit an unreadable protection API is a hard failure here."
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

  probe() { # label expect_rc <args…>
    local label="$1" expect="$2"; shift 2
    local out rc=0
    out="$(bash "$REPO_ROOT/scripts/required-checks-verify.sh" "$@" 2>&1)" || rc=$?
    if [ "$rc" -eq "$expect" ]; then
      echo "  ok   $label (exit $rc)"
      return 0
    fi
    echo "  SELFTEST FAIL: $label expected exit $expect, got $rc" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    return 1
  }

  echo "── verify selftest: every clause proven by mutation ──"

  probe "1/18 honest read-back passes" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe || rc=1

  jq '.protection.required_status_checks.checks[0].context = "Elixir gat"' "$good_spec" > "$tmp/typo.json"
  probe "2/18 a typo'd context reds (GitHub accepts it; we must not)" 1 \
    --spec "$tmp/typo.json" --readback "$good_rb" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.checks[0].app_id = null' "$good_rb" > "$tmp/nullapp.json"
  probe "3/18 app_id:null where the spec pins an id is HARD" 1 \
    --spec "$good_spec" --readback "$tmp/nullapp.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.checks[0].app_id = 8329' "$good_rb" > "$tmp/wrongapp.json"
  probe "4/18 a wrong app_id reds" 1 \
    --spec "$good_spec" --readback "$tmp/wrongapp.json" --runs "$good_runs" --sha probe || rc=1

  jq '.enforce_admins.enabled = false' "$good_rb" > "$tmp/breakglass.json"
  probe "5/18 a left-open break-glass (enforce_admins false) reds" 1 \
    --spec "$good_spec" --readback "$tmp/breakglass.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_linear_history.enabled = true' "$good_rb" > "$tmp/oob.json"
  probe "6/18 out-of-band required_linear_history=true reds (the PUT does not converge it — D41)" 1 \
    --spec "$good_spec" --readback "$tmp/oob.json" --runs "$good_runs" --sha probe || rc=1

  jq '. + {"required_deployments": {"enabled": true}}' "$good_rb" > "$tmp/extra.json"
  probe "7/18 a read-back key the spec never mentions reds (FULL-object diff)" 1 \
    --spec "$good_spec" --readback "$tmp/extra.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.strict = true' "$good_rb" > "$tmp/strict.json"
  probe "8/18 strict:true reds (it would serialise this fleet's parallel merges)" 1 \
    --spec "$good_spec" --readback "$tmp/strict.json" --runs "$good_runs" --sha probe || rc=1

  jq '.protection.required_status_checks.checks += [{"context":"No workflow emits me","app_id":15368}]' "$good_spec" > "$tmp/deadspec.json"
  probe "9/18 a spec context no workflow emits is DEADLOCK — a third state, at N=3 where the refusal message names nothing" 3 \
    --spec "$tmp/deadspec.json" --readback "$good_rb" --runs "$good_runs" --sha probe --deadlock || rc=1

  probe "10/18 an unreadable protection read-back FAILS (never skips)" 1 \
    --spec "$good_spec" --readback "$tmp/does-not-exist.json" --runs "$good_runs" --sha probe || rc=1

  probe "11/18 an unreadable check-run feed FAILS (never skips)" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/no-runs.json" --sha probe || rc=1

  echo '{ "check_runs": [] }' > "$tmp/emptyruns.json"
  probe "12/18 an EMPTY check-run feed FAILS — agreement against nothing is the vacuous pass this epic exists for" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/emptyruns.json" --sha probe || rc=1

  # 13 & 14 are the D56 clause: the detector used to match on `cut -f1` and
  # throw away the conclusion column rendered_names already emits, so a required
  # context concluding `cancelled` returned EXIT 0 — shape-identical to green on
  # a head that is frozen forever. Proven live on head 5ea4cb4f. Mutation-proof:
  # 13 must be 4 and 14 must be 0, and reverting the clause makes 13 return 0.
  jq '(.check_runs[] | select(.name == "PR references an active task" and .started_at == "2026-07-28T02:00:00Z") | .conclusion) = "cancelled"' \
    "$good_runs" > "$tmp/cancelledruns.json"
  probe "13/18 a required context whose LATEST run concluded cancelled is RE-RUN, not green (D56; returned exit 0 before this clause)" 4 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/cancelledruns.json" --sha probe --deadlock || rc=1

  # The mirror clause: cancellation on a NON-required check is none of our
  # business, and a detector that reds on it would red constantly — advisory
  # checks are cancelled by concurrency groups all day.
  jq '(.check_runs[] | select(.name == "Boundary gate (advisory)") | .conclusion) = "cancelled"' \
    "$good_runs" > "$tmp/advcancelled.json"
  probe "14/18 a cancelled ADVISORY check does NOT trip RE-RUN (the clause must be scoped to the required set)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/advcancelled.json" --sha probe --deadlock || rc=1

  # The caller-scope clause above, proven rather than asserted: --ci must NOT
  # turn a cancelled run on an arbitrary sampled head into a red, while
  # --deadlock (13/15) still exits 4 on the identical input.
  probe "15/18 --ci does NOT red on a cancelled required context (it samples a FOREIGN settled head; the merge verb asks --deadlock about its OWN head)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/cancelledruns.json" --sha probe --ci || rc=1

  # 16 pins the scope of the RE-RUN set from the other side. GitHub counts a
  # required check concluding `skipped` as SATISFYING protection, so a detector
  # that called it RE-RUN would refuse a head GitHub would merge — a false stall
  # in a wrapper whose whole promise is that it never lies about the merge. The
  # builder had `skipped` in the set as an unmeasured guess; the review took it
  # out and pinned the removal here, so re-adding it reds this probe.
  jq '(.check_runs[] | select(.name == "PR references an active task" and .started_at == "2026-07-28T02:00:00Z") | .conclusion) = "skipped"' \
    "$good_runs" > "$tmp/skippedruns.json"
  probe "16/18 a required context concluding SKIPPED is NOT RE-RUN (GitHub treats skipped as satisfying; refusing it would be a false stall)" 0 \
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
  probe "17/18 a workflow calling a SPEC'D context advisory reds (the defect this clause exists for; claim wrapped over 3 comment lines, so a line-wise grep would miss it)" 1 \
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
  probe "18/18 the SAME claim in the SAME file goes GREEN once that context leaves the spec (the clause tracks the committed set, not a frozen string)" 0 \
    --spec "$tmp/noelixir_spec.json" --readback "$tmp/noelixir_rb.json" --runs "$good_runs" --sha probe --workflows "$tmp/wf" || rc=1

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

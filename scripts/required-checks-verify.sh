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
# EXIT CODES   0 = agree · 1 = drift / cannot read · 3 = DEADLOCK · 4 = RE-RUN
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
    echo "  DRIFT  enforce_admins.enabled = $ea (spec: true) — every merge in this repo is --admin, so a false here is a gate that cannot block" >&2
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
    case "$concl" in
      cancelled|skipped|timed_out|stale|action_required)
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
    say "── enforced=false: nothing has been applied, so there is no live config to diff ──"
    say "  The deadlock detector below still runs against a real PR head. From the"
    say "  commit that flips enforced to true, an unreadable or absent protection"
    say "  config is a hard failure here."
    local drc0=0
    deadlock_check "${HEAD_SHA:-$(recent_pr_head)}" || drc0=$?
    [ "$drc0" -eq 3 ] && return 3
    [ "$drc0" -eq 4 ] && say "NOTE: the sampled head carries a cancelled required context (above). See --deadlock for the actionable form."
    [ "$drc0" -eq 0 ] || [ "$drc0" -eq 4 ] || return 1
    say "OK: the committed spec and the rendered check names agree; protection is not applied yet."
    return 0
  fi
  actual="$(live_protection)"
  say "── live protection vs committed spec ──"
  compare_protection "$actual" || rc=1
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
    echo "FAIL: live config and the committed spec disagree." >&2
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

  probe "1/15 honest read-back passes" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$good_runs" --sha probe || rc=1

  jq '.protection.required_status_checks.checks[0].context = "Elixir gat"' "$good_spec" > "$tmp/typo.json"
  probe "2/15 a typo'd context reds (GitHub accepts it; we must not)" 1 \
    --spec "$tmp/typo.json" --readback "$good_rb" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.checks[0].app_id = null' "$good_rb" > "$tmp/nullapp.json"
  probe "3/15 app_id:null where the spec pins an id is HARD" 1 \
    --spec "$good_spec" --readback "$tmp/nullapp.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.checks[0].app_id = 8329' "$good_rb" > "$tmp/wrongapp.json"
  probe "4/15 a wrong app_id reds" 1 \
    --spec "$good_spec" --readback "$tmp/wrongapp.json" --runs "$good_runs" --sha probe || rc=1

  jq '.enforce_admins.enabled = false' "$good_rb" > "$tmp/breakglass.json"
  probe "5/15 a left-open break-glass (enforce_admins false) reds" 1 \
    --spec "$good_spec" --readback "$tmp/breakglass.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_linear_history.enabled = true' "$good_rb" > "$tmp/oob.json"
  probe "6/15 out-of-band required_linear_history=true reds (the PUT does not converge it — D41)" 1 \
    --spec "$good_spec" --readback "$tmp/oob.json" --runs "$good_runs" --sha probe || rc=1

  jq '. + {"required_deployments": {"enabled": true}}' "$good_rb" > "$tmp/extra.json"
  probe "7/15 a read-back key the spec never mentions reds (FULL-object diff)" 1 \
    --spec "$good_spec" --readback "$tmp/extra.json" --runs "$good_runs" --sha probe || rc=1

  jq '.required_status_checks.strict = true' "$good_rb" > "$tmp/strict.json"
  probe "8/15 strict:true reds (it would serialise this fleet's parallel merges)" 1 \
    --spec "$good_spec" --readback "$tmp/strict.json" --runs "$good_runs" --sha probe || rc=1

  jq '.protection.required_status_checks.checks += [{"context":"No workflow emits me","app_id":15368}]' "$good_spec" > "$tmp/deadspec.json"
  probe "9/15 a spec context no workflow emits is DEADLOCK — a third state, at N=3 where the refusal message names nothing" 3 \
    --spec "$tmp/deadspec.json" --readback "$good_rb" --runs "$good_runs" --sha probe --deadlock || rc=1

  probe "10/15 an unreadable protection read-back FAILS (never skips)" 1 \
    --spec "$good_spec" --readback "$tmp/does-not-exist.json" --runs "$good_runs" --sha probe || rc=1

  probe "11/15 an unreadable check-run feed FAILS (never skips)" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/no-runs.json" --sha probe || rc=1

  echo '{ "check_runs": [] }' > "$tmp/emptyruns.json"
  probe "12/15 an EMPTY check-run feed FAILS — agreement against nothing is the vacuous pass this epic exists for" 1 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/emptyruns.json" --sha probe || rc=1

  # 13 & 14 are the D56 clause: the detector used to match on `cut -f1` and
  # throw away the conclusion column rendered_names already emits, so a required
  # context concluding `cancelled` returned EXIT 0 — shape-identical to green on
  # a head that is frozen forever. Proven live on head 5ea4cb4f. Mutation-proof:
  # 13 must be 4 and 14 must be 0, and reverting the clause makes 13 return 0.
  jq '(.check_runs[] | select(.name == "PR references an active task" and .started_at == "2026-07-28T02:00:00Z") | .conclusion) = "cancelled"' \
    "$good_runs" > "$tmp/cancelledruns.json"
  probe "13/15 a required context whose LATEST run concluded cancelled is RE-RUN, not green (D56; returned exit 0 before this clause)" 4 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/cancelledruns.json" --sha probe --deadlock || rc=1

  # The mirror clause: cancellation on a NON-required check is none of our
  # business, and a detector that reds on it would red constantly — advisory
  # checks are cancelled by concurrency groups all day.
  jq '(.check_runs[] | select(.name == "Boundary gate (advisory)") | .conclusion) = "cancelled"' \
    "$good_runs" > "$tmp/advcancelled.json"
  probe "14/15 a cancelled ADVISORY check does NOT trip RE-RUN (the clause must be scoped to the required set)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/advcancelled.json" --sha probe --deadlock || rc=1

  # The caller-scope clause above, proven rather than asserted: --ci must NOT
  # turn a cancelled run on an arbitrary sampled head into a red, while
  # --deadlock (13/15) still exits 4 on the identical input.
  probe "15/15 --ci does NOT red on a cancelled required context (it samples a FOREIGN settled head; the merge verb asks --deadlock about its OWN head)" 0 \
    --spec "$good_spec" --readback "$good_rb" --runs "$tmp/cancelledruns.json" --sha probe --ci || rc=1

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

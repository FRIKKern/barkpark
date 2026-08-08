#!/usr/bin/env bash
# check-deployyml-filters.sh — the paths↔regex drift gate for the production
# deploy workflow (stw9, charter D57a).
#
# THE BUG THIS EXISTS FOR
#
# .github/workflows/deploy.yml keeps TWO lists that must agree and nothing made
# them:
#
#   1. `on.push.paths` — which merges RUN the workflow at all;
#   2. the `changes` job's `grep -qE '^(...)/'` regexes — which of the two deploy
#      jobs (control-plane / instance) a run actually TARGETS.
#
# `templates/**` was added to (1) and never to (2). The consequence is the worst
# shape a CI failure can take: a templates-only merge STARTED the deploy
# workflow, both job filters evaluated false, nothing deployed — and the run
# reported GREEN. Sites kept building from a stale template with a green tick
# above them. (Third instance of this class in the repo: internal/cmd was fixed
# in 96879b11c; scripts/connectors is still open.)
#
# THE ASSERTION
#
# Every `on.push.paths` entry must be matched by at least one job filter regex —
# i.e. every merge that can START this workflow must be able to DEPLOY something.
# A path that is deliberately targetless (editing the workflow file itself) must
# say so with a `deploy-filter-exempt:` comment in the block ABOVE it, which
# makes the exception explicit and reviewable instead of invisible.
#
# `--selftest` PROVES the tripwire on temp copies (plants nothing in the tree):
# the real file passes, a copy with `templates` stripped from the instance regex
# FAILS, and an unexplained targetless path FAILS. Modelled on
# scripts/connectors-catalog-drift-check.sh's bundled selftest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT=".github/workflows/deploy.yml"

# ── extraction ───────────────────────────────────────────────────────────────

# The `on.push.paths` entries, one per line, unquoted. Reads only the block
# between `paths:` and the next top-level key, so a `paths:` elsewhere in the
# file (or a job-level one) can never widen the set. An entry whose preceding
# comment block carries `deploy-filter-exempt:` is emitted with a trailing
# "\tEXEMPT" column.
extract_paths() {
  awk '
    /^on:/                    { in_on = 1; next }
    in_on && /^[a-z]/         { in_on = 0 }
    in_on && /^    paths:/    { in_paths = 1; exempt = 0; next }
    in_paths && /^    [a-z]/  { in_paths = 0 }
    in_paths && /^ *#/        { if ($0 ~ /deploy-filter-exempt:/) exempt = 1; next }
    in_paths && /^ *- / {
      line = $0
      sub(/^ *- */, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (line == "") next
      print line "\t" (exempt ? "EXEMPT" : "REQUIRED")
      exempt = 0
    }
  ' "$1"
}

# Every job-filter regex: the `grep -qE '<re>'` patterns the `changes` job uses
# to decide which target changed — and ONLY those.
#
# Scoped to the `changes` job by the same 2-space job-boundary technique
# check-deploy-smoke.sh's extract_cp_smoke uses, because an unscoped grep over
# the whole file let the workflow DISARM ITS OWN GATE: any other job whose shell
# happens to contain a single-quoted `grep -qE '^(...|templates|...)/'` — a
# deploy RECORDER classifying the same paths is the obvious one — was harvested
# as if it were a dispatch filter, so stripping `templates` from the real
# instance filter still read `OK ... 7 path(s) ... target at least one deploy
# job` at rc=0. Worse, a VERBATIM copy defeated `--selftest` too: the drift the
# gate exists for became invisible in the exact run meant to prove the gate can
# lose. A regex outside the `changes` job dispatches nothing, so it may not
# answer for a path.
extract_regexes() {
  awk '
    /^  [a-zA-Z0-9_-]+:/ {
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job)
    }
    job == "changes"
  ' "$1" | { grep -oE "grep -qE '[^']+'" || true; } | sed -E "s/^grep -qE '//; s/'$//"
}

# A path glob reduced to ONE representative file path, which is what the job
# regexes are actually run against (`git diff --name-only` output).
#   "cloud/**"                    -> cloud/x
#   ".github/workflows/deploy.yml"-> .github/workflows/deploy.yml
sample_for() {
  case "$1" in
    */\*\*) printf '%sx\n' "${1%\*\*}" ;;
    *\**)   printf '%s\n' "${1%\**}x" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

# ── the check ────────────────────────────────────────────────────────────────

check_file() {
  local yml="$1" label="$2"
  local failures=0 checked=0 exempted=0

  local regexes
  regexes="$(extract_regexes "$yml")"
  if [ -z "$regexes" ]; then
    echo "FAIL[$label]: no 'grep -qE' job filters found inside the 'changes' job — the extractor is broken, not the workflow" >&2
    echo "Cause: extract_regexes ends the job at the next line indented exactly two spaces and ending in ':'," >&2
    echo "so a 2-space-indented heredoc body (or any such line) inside the job truncates the scan. Re-indent it," >&2
    echo "or teach the awk boundary about it — do NOT widen the scan back to the whole file (a regex outside the" >&2
    echo "'changes' job dispatches nothing and would let a new job green this gate for free)." >&2
    return 1
  fi

  local path state sample matched re
  while IFS=$'\t' read -r path state; do
    [ -n "$path" ] || continue
    if [ "$state" = "EXEMPT" ]; then
      exempted=$((exempted + 1))
      echo "  exempt   $path (deploy-filter-exempt)"
      continue
    fi

    checked=$((checked + 1))
    sample="$(sample_for "$path")"
    matched=""
    while IFS= read -r re; do
      [ -n "$re" ] || continue
      if printf '%s\n' "$sample" | grep -qE "$re"; then
        matched="$re"
        break
      fi
    done <<EOF
$regexes
EOF

    if [ -n "$matched" ]; then
      echo "  ok       $path  ->  $matched"
    else
      echo "  DRIFT    $path  ->  matched by NO job filter (a merge here runs the workflow and deploys nothing)" >&2
      failures=$((failures + 1))
    fi
  done <<EOF
$(extract_paths "$yml")
EOF

  if [ "$checked" -eq 0 ]; then
    echo "FAIL[$label]: no on.push.paths entries found — the extractor is broken" >&2
    return 1
  fi

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures path(s) start the deploy workflow but target no deploy job." >&2
    echo "Fix: add the prefix to the matching job's grep -qE regex in the 'changes' job," >&2
    echo "or, if it is deliberately targetless, add a '# deploy-filter-exempt: <why>' comment above it." >&2
    return 1
  fi

  echo "OK[$label]: $checked path(s) each target at least one deploy job ($exempted exempt)."
  return 0
}

# ── selftest ─────────────────────────────────────────────────────────────────

selftest() {
  # No RETURN trap: bash 3.2 (macOS) does not scope one to this function, so it
  # re-fires in the caller where $tmp is gone and `set -u` kills the run AFTER a
  # green selftest — a false red, the exact dishonesty this file is about.
  local tmp
  tmp="$(mktemp -d)"

  local real="$REPO_ROOT/$DEPLOY_YML_DEFAULT"
  local rc=0

  echo "selftest 1/4: the real workflow passes"
  if ! check_file "$real" "real"; then
    echo "SELFTEST FAIL: the real deploy.yml does not pass" >&2
    rc=1
  fi

  echo
  echo "selftest 2/4: dropping 'templates' from the instance regex must FAIL (the original bug)"
  sed "s/|connectors|templates)\//|connectors)\//" "$real" > "$tmp/mutated.yml"
  if cmp -s "$real" "$tmp/mutated.yml"; then
    echo "SELFTEST FAIL: the mutation changed nothing — the instance regex no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/mutated.yml" "mutated" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a templates-less regex read GREEN — the gate cannot fail" >&2
    rc=1
  else
    echo "  ok: the gate reds when templates/** loses its target"
  fi

  echo
  echo "selftest 3/4: an unexplained targetless path must FAIL"
  awk '{ print } /^      - "connectors\/\*\*"$/ { print "      - \"totally-unrouted/**\"" }' \
    "$real" > "$tmp/orphan.yml"
  if cmp -s "$real" "$tmp/orphan.yml"; then
    echo "SELFTEST FAIL: the orphan-path injection changed nothing" >&2
    rc=1
  elif check_file "$tmp/orphan.yml" "orphan" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: an unrouted path read GREEN" >&2
    rc=1
  else
    echo "  ok: the gate reds on a path no job targets"
  fi

  echo
  echo "selftest 4/4: another job's own regex must NOT rescue a drifted dispatch filter"
  # The disarm shape, verbatim: strip `templates` from the instance filter AND
  # append a recorder job whose shell carries a copy of the same regex. Before
  # extract_regexes was scoped to `changes`, this read OK at rc=0.
  sed "s/|connectors|templates)\//|connectors)\//" "$real" > "$tmp/disarm.yml"
  cat >> "$tmp/disarm.yml" <<'YML'

  selftest-recorder:
    runs-on: ubuntu-latest
    steps:
      - run: |
          if echo "$changed" | grep -qE '^(api|internal|deploy|connectors|templates)/'; then echo instance; fi
YML
  if ! grep -q 'selftest-recorder' "$tmp/disarm.yml"; then
    echo "SELFTEST FAIL: the recorder job was not appended" >&2
    rc=1
  elif check_file "$tmp/disarm.yml" "disarm" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a non-dispatching job's regex greened the gate — it is disarmable again" >&2
    rc=1
  else
    echo "  ok: only the 'changes' job's own filters answer for a path"
  fi

  rm -rf "$tmp"

  echo
  if [ "$rc" -eq 0 ]; then
    echo "SELFTEST OK — the tripwire can both pass and fail."
  fi
  return "$rc"
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --selftest) selftest ;;
    "")         check_file "$REPO_ROOT/$DEPLOY_YML_DEFAULT" "deploy.yml" ;;
    *)          check_file "$1" "$(basename "$1")" ;;
  esac
}

main "$@"

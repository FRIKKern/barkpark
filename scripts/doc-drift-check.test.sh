#!/usr/bin/env bash
# doc-drift-check.test.sh — the regression fixtures for scripts/doc-drift-check.sh.
#
# SIX FIXTURE CLASSES, named by task-b97741617bf6c860's own acceptance criteria.
# Each one is planted in a throwaway repo and the gate's verdict on it is
# asserted BY NAME — a bare exit code is a verdict a blind gate would also
# produce.
#
#   MUST RED   broken-link         a relative target that resolves nowhere
#   MUST RED   placeholder         an exposed FIXME/TBD in an active doc
#   MUST RED   failing-example     an allowlisted snippet that is actually RUN
#                                  and exits non-zero
#   MUST STAY QUIET  extensionless-route  a bare `docs/ops` next to docs/ops/
#   MUST STAY QUIET  intentional-example  an unmarked fence full of illustrative
#                                  junk — it is never run and never judged
#   MUST STAY QUIET  excluded-history     the same defects under a fixtures/,
#                                  _attic/ or cold-tier path
#
# Plus the two scope arms the diff-scoping exists for, and the VACUITY CONTROL:
# an empty corpus must REFUSE (exit 2), never pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/doc-drift-check.sh"
FAILED=0

plant() {
  # A minimal repo: one real doc tree, one real route target, one real file.
  local r="$1"
  mkdir -p "$r/docs/ops" "$r/scripts" "$r/tooling/doc-truth/fixtures" "$r/_attic"
  cat > "$r/docs/ops/live.md" <<'F'
<!-- doc-tier: agent | canonical-for: fixture-live | budget: 100tok -->
# Live doc

A link that resolves: [the other doc](other.md).
F
  cat > "$r/docs/ops/other.md" <<'F'
<!-- doc-tier: agent | canonical-for: fixture-other | budget: 100tok -->
# Other
F
  echo 'echo hi' > "$r/scripts/real.sh"
  ( cd "$r" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
}

run_gate() { # $1=root  $2...=scoped files ("" = report-only)
  local root="$1"; shift
  DOC_DRIFT_ROOT="$root" DOC_DRIFT_FILES="$*" DOC_DRIFT_BASE= bash "$GATE" 2>&1
}

case_() { # name  want_exit  needle ("" = must NOT appear)  scoped_files  mutation
  local name="$1" want="$2" needle="$3" scope="$4" mutate="$5" out rc fix
  fix="$(mktemp -d)"
  plant "$fix"
  FIX="$fix"; eval "$mutate"
  ( cd "$fix" && git add -A >/dev/null 2>&1 )
  set +e
  out=$(run_gate "$fix" $scope); rc=$?
  set -e
  rm -rf "$fix"
  if [ "$rc" != "$want" ]; then
    echo "TEST FAIL: $name — expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/    | /'
    FAILED=1; return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF "$needle"; then
    echo "TEST FAIL: $name — exit $rc as expected but output lacks: $needle"
    printf '%s\n' "$out" | sed 's/^/    | /'
    FAILED=1; return
  fi
  echo "ok:   $name"
}

quiet_() { # name  scoped_files  mutation  forbidden_needle
  local name="$1" scope="$2" mutate="$3" forbid="$4" out rc fix
  fix="$(mktemp -d)"
  plant "$fix"
  FIX="$fix"; eval "$mutate"
  ( cd "$fix" && git add -A >/dev/null 2>&1 )
  set +e
  out=$(run_gate "$fix" $scope); rc=$?
  set -e
  rm -rf "$fix"
  if [ "$rc" != 0 ]; then
    echo "TEST FAIL: $name — expected a QUIET pass (exit 0), got $rc"
    printf '%s\n' "$out" | sed 's/^/    | /'
    FAILED=1; return
  fi
  if printf '%s\n' "$out" | grep -q "$forbid"; then
    echo "TEST FAIL: $name — gate spoke when it should have stayed quiet: $forbid"
    printf '%s\n' "$out" | sed 's/^/    | /'
    FAILED=1; return
  fi
  echo "ok:   $name"
}

echo "== MUST RED =="

case_ "broken link in a touched doc reds" 1 \
  "link/route does not resolve: gone.md" "docs/ops/live.md" '
  printf "\nSee [the removed one](gone.md).\n" >> "$FIX/docs/ops/live.md"'

case_ "exposed placeholder in a touched doc reds" 1 \
  "exposed placeholder" "docs/ops/live.md" '
  printf "\nThe rollback procedure is TBD.\n" >> "$FIX/docs/ops/live.md"'

case_ "allowlisted example that fails reds" 1 \
  "allowlisted example at line" "docs/ops/live.md" '
  {
    printf "\n<!-- doc-exec: allowlisted -->\n"
    printf "\140\140\140bash\n"
    printf "test -f definitely-not-here\n"
    printf "\140\140\140\n"
  } >> "$FIX/docs/ops/live.md"'

case_ "a doc-exec marker with no fence reds" 1 \
  "no fenced block follows" "docs/ops/live.md" '
  printf "\n<!-- doc-exec: allowlisted -->\n\nJust prose.\n" >> "$FIX/docs/ops/live.md"'

case_ "an example reds when its DECLARED DEPENDENCY is what the diff touched" 1 \
  "allowlisted example at line" "scripts/real.sh" '
  {
    printf "\n<!-- doc-exec: allowlisted deps=scripts/real.sh -->\n"
    printf "\140\140\140bash\n"
    printf "exit 7\n"
    printf "\140\140\140\n"
  } >> "$FIX/docs/ops/live.md"'

echo "== MUST STAY QUIET =="

quiet_ "a valid extensionless route is not a broken link" "docs/ops/live.md" '
  printf "\nSee the [ops tree](../ops) and [this repo file](../../scripts/real.sh).\n" >> "$FIX/docs/ops/live.md"' \
  "^FAIL:"

quiet_ "an UNMARKED fence is never run and never judged" "docs/ops/live.md" '
  {
    printf "\n\140\140\140bash\n"
    printf "rm -rf /  # FIXME illustrative only\n"
    printf "curl https://example.invalid/TBD\n"
    printf "\140\140\140\n"
  } >> "$FIX/docs/ops/live.md"' \
  "^FAIL:"

quiet_ "history / fixture / attic trees are excluded" "tooling/doc-truth/fixtures/broken.md _attic/old.md" '
  printf "%s\n" "<!-- doc-tier: agent | canonical-for: fixture-broken | budget: 10tok -->" "TBD [gone](nope.md)" > "$FIX/tooling/doc-truth/fixtures/broken.md"
  printf "%s\n" "<!-- doc-tier: agent | canonical-for: fixture-attic | budget: 10tok -->" "TBD [gone](nope.md)" > "$FIX/_attic/old.md"' \
  "^FAIL:"

quiet_ "a cold-tier doc is retired text, not drift" "docs/ops/cold.md" '
  printf "%s\n" "<!-- doc-tier: cold | canonical-for: fixture-cold | budget: 10tok -->" "TBD [gone](nope.md)" > "$FIX/docs/ops/cold.md"' \
  "^FAIL:"

echo "== DIFF SCOPE =="

quiet_ "drift in a doc the diff did NOT touch is inherited and neutral" "docs/ops/other.md" '
  printf "\nSee [the removed one](gone.md). TBD.\n" >> "$FIX/docs/ops/live.md"' \
  "^FAIL:"

case_ "the same drift IS owned once the diff touches that doc" 1 \
  "link/route does not resolve: gone.md" "docs/ops/live.md docs/ops/other.md" '
  printf "\nSee [the removed one](gone.md).\n" >> "$FIX/docs/ops/live.md"'

echo "== VACUITY CONTROL =="
# A checker that answers "clean" for every input passes vacuously. Empty the
# corpus and the gate must REFUSE, not pass.
VFIX="$(mktemp -d)"; mkdir -p "$VFIX/docs"
printf 'not markdown\n' > "$VFIX/docs/x.txt"
( cd "$VFIX" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
set +e
vout=$(DOC_DRIFT_ROOT="$VFIX" DOC_DRIFT_BASE= bash "$GATE" 2>&1); vrc=$?
set -e
rm -rf "$VFIX"
if [ "$vrc" = 2 ] && printf '%s\n' "$vout" | grep -q 'REFUSED'; then
  echo "ok:   an empty corpus REFUSES (exit 2) rather than passing vacuously"
else
  echo "TEST FAIL: empty corpus — expected exit 2 + REFUSED, got $vrc"
  printf '%s\n' "$vout" | sed 's/^/    | /'
  FAILED=1
fi

echo
if [ "$FAILED" -ne 0 ]; then echo "doc-drift-check.test.sh: FAIL"; exit 1; fi
echo "doc-drift-check.test.sh: all arms pass"

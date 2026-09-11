#!/usr/bin/env bash
# CLI RELEASE CADENCE GATE — is the shipped `bp` source newer than its newest release tag?
#
# Row pds-bl-w49-cli-release-cadence-gate (PDS-D711). The CLI is distributed as a
# tagged binary: `curl -fsSL .../install-cli.sh | sh` resolves GitHub's
# `releases/latest`, which cli-release.yml only ever cuts FROM a `cli-v*` tag
# push. So everything a `curl|sh` user runs is the tree AT THAT TAG. Nothing
# measured whether the shipped source had moved past it, and the first time that
# mattered a fix to the go:embed'ed installer sat on main, unreleased, for weeks
# while every fresh install kept getting the pre-fix bytes.
#
# THE ORACLE IS PURE GIT AND OFFLINE. No network, no `gh`, no release feed, no
# `strings` on a downloaded binary: newest `cli-v*` tag by VERSION sort, then
# `git rev-list --count <tag>..HEAD -- <scope>`. Non-zero means the shipped
# assets moved and no tag carried them to a user. THE REPAIR IS A TAG — the
# cli-v namespace has no immutability wall (unlike npm), so cutting the next
# cli-v<semver> is both the fix and the only fix.
#
# WHY THE SCOPE IS `internal/cli/setup/assets` AND NOT `internal/cli`.
# Measured on origin/main 5d1be5f1f (2026-09-11), newest tag cli-v1.21.0:
#     internal/cli/setup/assets  ->   3 commits   <- this gate's scope
#     internal/cli               -> 118 commits   <- what a wider gate would see
# A gate scoped to `internal/cli` reds on essentially every commit to the CLI,
# and a gate that is red on every PR is not a gate: it is a red that gets muted,
# then weakened, then deleted. `internal/cli/setup/assets` is DISPOSABLE in the
# precise sense the row demands — it is two files (assets.go and the go:embed'ed
# deploy.sh) that change a handful of times per release cycle, so its count
# returns to zero the moment a tag is cut and STAYS zero for most of a cycle.
# That is what makes "red" mean "cut a tag", instead of "yes, the CLI changed".
#
# ADVISORY BY CONSTRUCTION. .github/required-checks.json requires exactly four
# contexts; this gate is not one of them and this script's caller in
# .github/workflows/go-tests.yml says so in its own comment. Nothing here blocks
# a merge. It is a signal a human reads and answers with `git tag cli-vX.Y.Z`.
#
# EXITS: 0 in cadence · 1 DRIFT (a tag is owed) · 2 the instrument is broken
# (no tags visible, scope path gone, not a git repo) — never a silent green.
#
# Self-check: `bash scripts/cli-release-cadence-gate.sh --selftest` drives both
# directions against scratch repos in a tmpdir. It is a SUBCOMMAND, not a
# separate *_test.sh, so it needs no harness registration to stay reachable.

set -euo pipefail

SCOPE="${CLI_CADENCE_SCOPE:-internal/cli/setup/assets}"
REPO="${CLI_CADENCE_REPO:-.}"
REF="${CLI_CADENCE_REF:-HEAD}"
TAG_GLOB="${CLI_CADENCE_TAG_GLOB:-cli-v*}"

die_instrument() {
  echo "::error title=cli release cadence gate: instrument fault::$1"
  echo "cli-release-cadence-gate: INSTRUMENT FAULT — $1" >&2
  exit 2
}

# run_gate [repo] — the repo argument exists for --selftest, which must be able
# to point the SAME code path at a scratch repo. Overriding CLI_CADENCE_REPO as
# a command prefix cannot work: $REPO is bound once, at script start.
run_gate() {
  local REPO="${1:-$REPO}"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || die_instrument "$REPO is not a git repository, so this gate measured nothing."

  # ANTI-VACUITY 1 — the tag set. A shallow checkout (actions/checkout's default
  # fetch-depth: 1) fetches NO tags, and "newest tag" would then be the empty
  # string: `git rev-list --count ..HEAD` over an empty left side counts every
  # commit ever, or the command errors. Either way a caller that swallowed it
  # would read as informative. Refuse instead, and name the fix.
  local tags newest count
  tags="$(git -C "$REPO" tag -l "$TAG_GLOB" --sort=v:refname || true)"
  if [ -z "$tags" ]; then
    die_instrument "no tag matches '$TAG_GLOB' in $REPO. Either the release namespace was renamed, or this is a shallow/tagless checkout — in CI that means the checkout step needs 'fetch-depth: 0'. A cadence gate with no tag to compare against cannot be green."
  fi
  newest="$(printf '%s\n' "$tags" | tail -1)"

  # ANTI-VACUITY 2 — the corpus. If the scope path is renamed or deleted,
  # `rev-list -- <gone path>` counts 0 and the gate goes permanently, silently
  # green over nothing. Same failure shape deploy-harnesses.yml's MIN_FILES floor
  # exists to refuse. Re-point the scope DELIBERATELY; do not let a green be how
  # you find out the CLI's shipped assets moved house.
  if ! git -C "$REPO" cat-file -e "$REF:$SCOPE" 2>/dev/null; then
    die_instrument "the scope path '$SCOPE' does not exist at $REF. A count of 0 over a path that is gone is not 'in cadence', it is a gate that stopped looking. Re-point CLI_CADENCE_SCOPE in this script."
  fi

  count="$(git -C "$REPO" rev-list --count "$newest..$REF" -- "$SCOPE")"

  echo "cli-release-cadence-gate"
  echo "  newest tag ($TAG_GLOB)   : $newest ($(git -C "$REPO" rev-list -n1 "$newest" | cut -c1-9), $(git -C "$REPO" log -1 --format=%cs "$newest^{commit}"))"
  echo "  scope                  : $SCOPE"
  echo "  commits since that tag : $count   ($newest..$REF -- $SCOPE)"

  if [ "$count" -eq 0 ]; then
    echo "  VERDICT: IN CADENCE — everything under $SCOPE that exists on $REF also shipped in $newest."
    return 0
  fi

  echo "  commits a curl|sh user does NOT have:"
  git -C "$REPO" log --oneline "$newest..$REF" -- "$SCOPE" | sed 's/^/    /'
  echo "::error title=bp CLI release cadence::$count commit(s) under $SCOPE landed after $newest. Every 'curl -fsSL .../install-cli.sh | sh' installs the $newest bytes, so those commits reach nobody. THE FIX IS A TAG: cut the next cli-v<semver> (cli-release.yml builds and publishes it on the tag push). This check is ADVISORY — it is not in .github/required-checks.json and blocks no merge."
  echo "  VERDICT: DRIFT — a cli-v tag is owed."
  return 1
}

# ---------------------------------------------------------------------------
# --selftest: both directions, against scratch repos. Offline, no network, and
# it never touches the repo it guards.
# ---------------------------------------------------------------------------
selftest() {
  local rc fails=0 out
  # NOT `local`: the EXIT trap below runs after this function's frame is gone,
  # and a local $tmp there is an unbound-variable crash under `set -u`.
  SELFTEST_TMP="$(mktemp -d)"
  local tmp="$SELFTEST_TMP"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT

  mk_repo() { # $1 = dir
    local d="$1"
    mkdir -p "$d/internal/cli/setup/assets"
    git -C "$d" init -q
    git -C "$d" config user.email selftest@example.invalid
    git -C "$d" config user.name selftest
    git -C "$d" config commit.gpgsign false
    printf 'a\n' > "$d/internal/cli/setup/assets/deploy.sh"
    printf 'other\n' > "$d/internal/cli/other.go"
    git -C "$d" add -A
    git -C "$d" commit -qm "base"
  }

  judge() { # $1 = label, $2 = expected rc, $3 = actual rc, $4 = output
    if [ "$2" = "$3" ]; then
      echo "  ok   $1 (exit $3)"
    else
      echo "  FAIL $1 — expected exit $2, got $3"
      printf '%s\n' "$4" | sed 's/^/       /'
      fails=$((fails + 1))
    fi
  }

  echo "cli-release-cadence-gate --selftest"

  # A — tagged tip, nothing after it: GREEN.
  mk_repo "$tmp/a"
  git -C "$tmp/a" tag cli-v1.0.0
  out="$(run_gate "$tmp/a" 2>&1)" && rc=0 || rc=$?
  judge "in-cadence repo is green" 0 "$rc" "$out"

  # B — one commit IN SCOPE after the tag: RED. This is the mutation that must
  # flip A's green; if it does not, A proved nothing.
  cp -R "$tmp/a" "$tmp/b"
  printf 'b\n' >> "$tmp/b/internal/cli/setup/assets/deploy.sh"
  git -C "$tmp/b" commit -qam "asset change after the tag"
  out="$(run_gate "$tmp/b" 2>&1)" && rc=0 || rc=$?
  judge "one post-tag commit IN SCOPE reds" 1 "$rc" "$out"
  if ! printf '%s\n' "$out" | grep -q "THE FIX IS A TAG"; then
    echo "  FAIL the red names no remedy — a cadence red that does not say 'cut a tag' gets muted"
    fails=$((fails + 1))
  else
    echo "  ok   the red prescribes the tag"
  fi

  # C — DISCRIMINATION. A commit OUTSIDE the scope must NOT red, or the gate is
  # just "the CLI changed" and is the always-red c1 forbids.
  cp -R "$tmp/a" "$tmp/c"
  printf 'c\n' >> "$tmp/c/internal/cli/other.go"
  git -C "$tmp/c" commit -qam "non-asset CLI change after the tag"
  out="$(run_gate "$tmp/c" 2>&1)" && rc=0 || rc=$?
  judge "a post-tag commit OUTSIDE the scope stays green" 0 "$rc" "$out"

  # D — VERSION SORT, not lexical. `sort`/refname order puts cli-v1.9.0 AFTER
  # cli-v1.21.0 and the gate would compare against a tag five releases old,
  # reporting drift that is not there (or hiding drift that is).
  cp -R "$tmp/a" "$tmp/d"
  git -C "$tmp/d" tag cli-v1.9.0
  git -C "$tmp/d" tag cli-v1.21.0
  out="$(run_gate "$tmp/d" 2>&1)" && rc=0 || rc=$?
  if printf '%s\n' "$out" | grep -Fq "newest tag (cli-v*)   : cli-v1.21.0"; then
    echo "  ok   version sort picks cli-v1.21.0 over cli-v1.9.0"
  else
    echo "  FAIL version sort picked the wrong tag (lexical order would say cli-v1.9.0)"
    printf '%s\n' "$out" | sed 's/^/       /'
    fails=$((fails + 1))
  fi

  # E — NO TAGS AT ALL (the shallow-checkout shape): exit 2, never 0.
  mk_repo "$tmp/e"
  out="$(run_gate "$tmp/e" 2>&1)" && rc=0 || rc=$?
  judge "a tagless (shallow) checkout is an INSTRUMENT FAULT, not a green" 2 "$rc" "$out"

  # F — THE CORPUS EVAPORATES: scope path gone => exit 2, never a vacuous 0.
  cp -R "$tmp/a" "$tmp/f"
  git -C "$tmp/f" rm -rq internal/cli/setup/assets
  git -C "$tmp/f" commit -qm "assets moved house"
  out="$(run_gate "$tmp/f" 2>&1)" && rc=0 || rc=$?
  judge "a vanished scope path is an INSTRUMENT FAULT, not a green" 2 "$rc" "$out"

  if [ "$fails" -ne 0 ]; then
    echo "cli-release-cadence-gate --selftest: $fails check(s) FAILED"
    return 1
  fi
  echo "cli-release-cadence-gate --selftest: 7/7 checks passed (green arm, red arm, discrimination, version sort, 2 instrument-fault arms)"
  return 0
}

case "${1-}" in
  --selftest) selftest ;;
  "") run_gate ;;
  -h | --help)
    sed -n '2,40p' "$0"
    ;;
  *)
    echo "usage: $0 [--selftest]" >&2
    exit 64
    ;;
esac

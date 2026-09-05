#!/usr/bin/env bash
# vips-hedge-tripwire.sh [--selftest] — the hedge that became a check.
#
# WHAT IT REPLACED. `mix-prod-compile` in .github/workflows/elixir.yml used to
# run `apt-get update && apt-get install -y libvips-dev`, 39 s of a 112 s job,
# justified in its comment as INSURANCE: keep a system libvips where the prod
# artifact is compiled, so that a future switch to
# `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` — or a vix bump that falls
# back to a source build — is exercised in CI rather than discovered in prod.
#
# The premise was true and the price was wrong. `VIX_COMPILATION_MODE` is UNSET
# in this repo, so vix (0.38) runs in its default PRECOMPILED_NIF_AND_LIBVIPS
# mode: the NIF arrives prebuilt with libvips bundled and that job never once
# linked or executed the system libvips it spent 39 s installing. Insurance
# against a hypothetical does not get a third of a required gate's runtime; it
# gets a TRIPWIRE. So the install is gone and this script is what the hedge
# became — it costs milliseconds and reds the moment the hypothetical stops
# being hypothetical.
#
# THE RULE, one sentence: if `PLATFORM_PROVIDED_LIBVIPS` is selected anywhere in
# the build configuration while no app-building CI lane installs a system
# libvips, this script exits 1. Either state alone is fine. Both at once is the
# exact failure the deleted step was insuring against, and it is now caught at
# lint speed instead of paid for on every run.
#
# WHERE IT LOOKS.
#   SETTING sources   api/config/**, api/mix.exs, and every .github/workflows/*.yml
#                     — the three places a mode can actually be selected.
#   INSTALLER sources every .github/workflows/*.yml EXCEPT the exclusions below.
#
# THE ONE EXCLUSION, and why an exclusion rather than an include list. Scanning
# every workflow for an installer is the FAIL-CLOSED direction: a new app-build
# lane is covered the day it lands, where an include list would silently not
# cover it. But `create-quickstart-smoke.yml` installs `libvips-dev` for the
# beam of a SCAFFOLDED quickstart project it generates, not for the release
# artifact — and counting it would make this tripwire permanently vacuous, since
# it installs vips unconditionally on every run. It is excluded by name, with
# that reason, and the list is ONE entry long ON PURPOSE: a second entry is the
# signal that this guard has started waving things through rather than
# discriminating between them. Do not grow it; re-derive the rule instead.
#
# A `name:` IS NOT A COMMENT, and this bit on the first real run: the wiring
# step was originally called "PLATFORM_PROVIDED_LIBVIPS is not selected without a
# system libvips" and the tripwire reddened on its own step name. That is correct
# behaviour — a YAML `name:` is live document text, not stripped prose — so the
# step reads around the token instead. Do not put the mode token in a step name.
#
# COMMENTS ARE NOT CONFIGURATION. Both scans strip `#` comments before matching.
# Without that this script would red on its own header, on elixir.yml's and
# security.yml's prose about vix modes, and on any future note explaining the
# decision — i.e. it would fire on people DISCUSSING the setting rather than
# SETTING it. Selftest case 4 is that stripping, asserted, so nobody removes it
# and gets a guard that cries on documentation.
#
# NON-VACUITY. It refuses to report a pass (exit 4) when a scan root turns up no
# files at all — a guard that inspected nothing must never print OK. Selftest
# case 7 proves the refusal fires.
#
# USAGE
#   bash scripts/vips-hedge-tripwire.sh              # scan this repo
#   bash scripts/vips-hedge-tripwire.sh --selftest   # hermetic: fixtures in a tmpdir
#
# EXITS  0 clean · 1 hedge required but absent · 4 vacuous scan · 2 usage
#
# WIRED IN as a step of the `path-escape` job in .github/workflows/elixir.yml —
# an unfiltered, no-`if:`, no-continue-on-error job that is in `elixir-gate`'s
# `needs` with gate value NEVER, so a red here reds a REQUIRED context. A STEP
# and not a job, for the reason written above that job's sibling ratchets: a new
# job reds elixir/cloud/console-path-escape-check.test.sh via
# `blocking_not_in_needs`, and a step adds no rendered check name.

set -uo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# The value name IS the selection. `VIX_COMPILATION_MODE` alone is not enough to
# match on: setting it to PRECOMPILED_NIF_AND_LIBVIPS is the status quo and must
# not red.
SELFTEST_TMP=""
trap '[ -n "$SELFTEST_TMP" ] && rm -rf "$SELFTEST_TMP"' EXIT

SETTING_TOKEN='PLATFORM_PROVIDED_LIBVIPS'

# AN INSTALLER IS A PACKAGE-MANAGER INVOCATION, not any line saying "install"
# and "libvips". The first draft matched `install.*libvips`, and this script's own
# wiring step — then named "... is not selected without a system libvips
# installed" — matched it, which would have made the tripwire VACUOUSLY PASS
# forever: a setting hit plus a phantom installer reads as "the hedge is live".
# The guard caught it on its first real run. A package-manager word is now
# required on the same non-comment line. Selftest case 10 freezes that.
INSTALLER_RE='(apt-get|apt|apk|brew|dnf|yum|pacman|dpkg|nix-env)([[:space:]]|-)[^#]*install[^#]*libvips'

# Workflows whose libvips install does NOT stand in for the app build. See the
# header. ONE entry. Keep it that way.
EXCLUDED_INSTALLER_WORKFLOWS='create-quickstart-smoke.yml'

# Strip `#` comments so the scans read configuration, not prose. A `#` counts as
# a comment opener at start-of-line or after whitespace, which is true for YAML
# and for Elixir; a `#` inside a token (`#{...}` interpolation, a URL fragment)
# is left alone.
strip_comments() {
  sed -E 's/(^|[[:space:]])#.*$/\1/' "$1"
}

scan_paths() {
  # setting sources
  local f
  [ -f "$ROOT/api/mix.exs" ] && printf '%s\n' "$ROOT/api/mix.exs"
  if [ -d "$ROOT/api/config" ]; then
    find "$ROOT/api/config" -type f 2>/dev/null | sort
  fi
  workflow_paths
}

workflow_paths() {
  if [ -d "$ROOT/.github/workflows" ]; then
    find "$ROOT/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
  fi
}

main() {
  local setting_hits=() installer_hits=() f rel line
  local setting_files=0 installer_files=0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    setting_files=$((setting_files + 1))
    # Never let the tripwire trip on itself.
    case "$f" in */scripts/vips-hedge-tripwire.sh) continue ;; esac
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rel="${f#"$ROOT"/}"
      setting_hits+=("$rel: $line")
    done < <(strip_comments "$f" | grep -nE "$SETTING_TOKEN" || true)
  done < <(scan_paths)

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$ROOT"/}"
    case " $EXCLUDED_INSTALLER_WORKFLOWS " in
      *" $(basename "$f") "*) continue ;;
    esac
    installer_files=$((installer_files + 1))
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      installer_hits+=("$rel: $line")
    done < <(strip_comments "$f" | grep -nE "$INSTALLER_RE" || true)
  done < <(workflow_paths)

  if [ "$setting_files" -eq 0 ] || [ "$installer_files" -eq 0 ]; then
    echo "VACUOUS: scanned ${setting_files} setting source(s) and ${installer_files} installer source(s) under ${ROOT}."
    echo "A guard that inspected nothing must not report OK. Check ROOT."
    return 4
  fi

  echo "vips-hedge-tripwire: ${setting_files} setting source(s), ${installer_files} installer source(s) scanned under ${ROOT}"
  echo "  ${SETTING_TOKEN} selected in non-comment config: ${#setting_hits[@]} place(s)"
  echo "  system libvips installed by a CI lane:           ${#installer_hits[@]} place(s)"

  if [ "${#setting_hits[@]}" -eq 0 ]; then
    echo "OK — ${SETTING_TOKEN} is not selected anywhere; vix uses its bundled precompiled libvips."
    echo "     No CI lane needs a system libvips, and none is required to install one."
    return 0
  fi

  printf '  setting hit: %s\n' "${setting_hits[@]}"

  if [ "${#installer_hits[@]}" -gt 0 ]; then
    printf '  installer:   %s\n' "${installer_hits[@]}"
    echo "OK — ${SETTING_TOKEN} is selected AND a CI lane installs a system libvips. The hedge is live."
    return 0
  fi

  cat >&2 <<MSG
::error::${SETTING_TOKEN} is selected in the build configuration, but NO CI lane installs a system libvips.
vix will look for a platform-provided libvips that CI does not have. This is the exact
failure the deleted \`Install libvips for media renditions\` step in mix-prod-compile
was insuring against — the insurance was replaced by this tripwire when the setting was
unset and the step cost 39 s of a 112 s required job.

FIX, pick one:
  * restore a \`sudo apt-get update && sudo apt-get install -y libvips-dev\` step to the
    lane that compiles the app (mix-prod-compile in .github/workflows/elixir.yml), or
  * unset ${SETTING_TOKEN} and stay on vix's default PRECOMPILED_NIF_AND_LIBVIPS.
MSG
  return 1
}

# ── selftest ────────────────────────────────────────────────────────────────
# Hermetic: fixture trees in a tmpdir, no network, no repo reads. It asserts the
# guard reds AND that it passes, because a guard never observed failing is not a
# guard and a guard that only ever fails is not one either.
fixture() {
  # fixture <dir> <setting-placement> <installer:yes|no|commented>
  local d="$1" setting="$2" installer="$3"
  mkdir -p "$d/api/config" "$d/.github/workflows"
  printf 'defmodule Api.MixProject do\n  use Mix.Project\nend\n' > "$d/api/mix.exs"
  printf 'import Config\n' > "$d/api/config/runtime.exs"
  printf 'name: wf\njobs:\n  build:\n    steps:\n      - run: mix compile\n' > "$d/.github/workflows/elixir.yml"

  case "$setting" in
    none) : ;;
    config) printf 'System.put_env("VIX_COMPILATION_MODE", "PLATFORM_PROVIDED_LIBVIPS")\n' >> "$d/api/config/runtime.exs" ;;
    mix)    printf '# tail\nSystem.put_env("VIX_COMPILATION_MODE", "PLATFORM_PROVIDED_LIBVIPS")\n' >> "$d/api/mix.exs" ;;
    wf)     printf '    env:\n      VIX_COMPILATION_MODE: PLATFORM_PROVIDED_LIBVIPS\n' >> "$d/.github/workflows/elixir.yml" ;;
    comment) printf '      # someday: VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS\n' >> "$d/.github/workflows/elixir.yml" ;;
  esac

  case "$installer" in
    no) : ;;
    yes) printf '      - run: sudo apt-get install -y libvips-dev\n' >> "$d/.github/workflows/elixir.yml" ;;
    commented) printf '      # - run: sudo apt-get install -y libvips-dev\n' >> "$d/.github/workflows/elixir.yml" ;;
    prose) printf '      - name: check libvips is installed somewhere\n        run: true\n' >> "$d/.github/workflows/elixir.yml" ;;
    excluded)
      printf 'name: qs\njobs:\n  s:\n    steps:\n      - run: sudo apt-get install -y libvips-dev\n' \
        > "$d/.github/workflows/create-quickstart-smoke.yml" ;;
  esac
}

selftest() {
  local rc fails=0 n=0
  tmp="$(mktemp -d)"
  SELFTEST_TMP="$tmp"

  check() { # check <case-name> <expected-exit> <setting> <installer>
    local name="$1" want="$2" setting="$3" installer="$4" d
    n=$((n + 1))
    d="$tmp/case$n"
    fixture "$d" "$setting" "$installer"
    ROOT="$d" main >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$want" ]; then
      printf 'ok   %d  %s (exit %d)\n' "$n" "$name" "$rc"
    else
      printf 'FAIL %d  %s — wanted exit %d, got %d\n' "$n" "$name" "$want" "$rc"
      fails=$((fails + 1))
    fi
  }

  #                                                              want  setting   installer
  check "no setting, no installer — the status quo passes"          0  none      no
  check "setting in api/config, no installer — REDS"                1  config    no
  check "setting in api/mix.exs, no installer — REDS"               1  mix       no
  check "setting in a workflow env, no installer — REDS"            1  wf        no
  check "setting present AND an installer — passes, hedge live"     0  wf        yes
  check "setting in a COMMENT only — passes, prose is not config"   0  comment   no
  check "setting live, installer only in a COMMENT — REDS"          1  wf        commented
  check "installer only in the EXCLUDED workflow — still REDS"      1  wf        excluded
  check "a step NAME saying install+libvips is not an installer"    1  wf        prose

  # case 9: the non-vacuity refusal.
  n=$((n + 1))
  ROOT="$tmp/does-not-exist" main >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 4 ]; then
    printf 'ok   %d  empty scan root refuses to report OK (exit 4)\n' "$n"
  else
    printf 'FAIL %d  empty scan root — wanted exit 4, got %d\n' "$n" "$rc"
    fails=$((fails + 1))
  fi

  echo
  if [ "$fails" -eq 0 ]; then
    echo "vips-hedge-tripwire --selftest: ${n} tests, 0 failures"
    return 0
  fi
  echo "vips-hedge-tripwire --selftest: ${n} tests, ${fails} FAILURES"
  return 1
}

case "${1-}" in
  --selftest) selftest ;;
  "")         main ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
#
# prod-build-cache-guard.sh — the tripwire that makes caching `_build/prod`
# dependency artifacts safe inside the Prod compile gate.
#
# WHY THIS EXISTS
# ---------------
# elixir.yml's `mix-prod-compile` used to spend 83s (median of 10 completed main
# runs, 2026-09-02) on `mix deps.compile --force`, rebuilding every dependency's
# BEAM output from sources that were ALREADY on disk — `api/deps` has been cached
# for a long time; `_build/prod` never was. Caching the dependency half of
# `_build/prod` removes that 83s, but it walks straight at CLAUDE.md Golden Rule
# #1 ("never partially clean _build") and Past Mistake #1 ("cleaned
# _build/prod/lib/barkpark only; HEEx templates in Layouts stayed stale; old HTML
# served for hours").
#
# The distinction that makes it safe — and the reason this script exists rather
# than a comment promising good behaviour — is twofold:
#
#   * Those rules describe the production SERVER, where a stale module was SERVED
#     to users for hours. This is a CI runner whose only output is an exit code;
#     nothing it builds is ever served to anyone.
#   * The thing that went stale in Past Mistake #1 was OUR OWN module. This
#     design never restores our own code. The application still compiles from
#     nothing on every run. Only `_build/prod/lib/<dep>` for deps named in
#     mix.lock is restored, and a dependency's compiled output is a pure function
#     of (runner OS, OTP, Elixir, mix.lock) — which is exactly the cache key.
#
# That second bullet is a claim about a directory tree, so it is CHECKED here,
# not asserted in prose. Past Mistake #2 (a missing `deps.compile --force` once
# left `Plug.Exception` undefined at runtime) is closed by the completeness arm:
# a cache that does not carry every prod dependency is not used at all, and the
# job falls back to the old `rm -rf _build/prod` + `--force` path and says so.
#
# THREE VERDICTS
# --------------
#   exit 0  CACHE-COMPLETE     — restored tree is dep-only and total; the job may
#                                run plain `mix deps.compile`.
#   exit 3  CACHE-INCOMPLETE   — cache miss, a missing dependency, or an input
#                                list too small to be trusted. NOT an error: the
#                                caller must `rm -rf _build/prod` and run
#                                `mix deps.compile --force`.
#   exit 1  CACHE-CONTAMINATED — the restored tree holds something that is not a
#                                dependency artifact. HARD FAIL. Never "clean it
#                                up and continue": a tree that can hold one of
#                                our modules can hold a stale one, and that is
#                                the exact shape of Past Mistake #1.
#
# Contamination is checked BEFORE completeness, so a tree that is both partial
# and dirty reds rather than quietly falling back.
#
# USAGE
#   prod-build-cache-guard.sh <build_lib_dir> <allowlist_file> <required_file>
#   prod-build-cache-guard.sh --selftest
#
#   allowlist_file  every dependency name that MAY appear as a directory —
#                   derived from api/mix.lock, a superset (mix.lock also names
#                   dev/test-only deps that prod never builds).
#   required_file   every dependency name that MUST be present with a non-empty
#                   ebin — derived from `MIX_ENV=prod mix deps`, the exact prod
#                   set.
#
# Both lists are re-derived by the caller on every run. A list that arrives
# nearly empty (a parse that silently stopped matching, a `mix deps` that errored
# into an empty pipe) would make this guard VACUOUS — a completeness check over
# zero required names passes trivially — so each list carries a floor, and
# tripping a floor is fail-closed, never a pass.

set -uo pipefail

MIN_ALLOWLIST=10
MIN_REQUIRED=10

say() { printf '%s\n' "$*"; }

guard() {
  local dir="$1" allow="$2" req="$3"
  local -a allow_names req_names
  local line
  local contaminated=0

  # Plain read loops, not `mapfile`: this script has to be runnable on the
  # bash 3.2 that ships with macOS as well as on the runner's bash 5.
  allow_names=()
  while IFS= read -r line; do allow_names+=("$line"); done \
    < <(grep -E '^[a-z0-9_]+$' "$allow" 2>/dev/null | sort -u)
  req_names=()
  while IFS= read -r line; do req_names+=("$line"); done \
    < <(grep -E '^[a-z0-9_]+$' "$req" 2>/dev/null | sort -u)

  # ---- Input floors. Fail-closed: a broken allowlist would call every real
  # dependency "not allowed" (noisy but safe); a broken required list would make
  # the completeness arm pass over nothing (silent and NOT safe). Both stop here.
  if [ "${#allow_names[@]}" -lt "$MIN_ALLOWLIST" ]; then
    say "CACHE-CONTAMINATED: allowlist has ${#allow_names[@]} names (< $MIN_ALLOWLIST) — mix.lock parse looks broken; refusing to judge the tree"
    return 1
  fi
  if [ "${#req_names[@]}" -lt "$MIN_REQUIRED" ]; then
    say "CACHE-INCOMPLETE: required list has ${#req_names[@]} names (< $MIN_REQUIRED) — 'mix deps' output looks broken; a completeness check over it would be vacuous"
    return 3
  fi

  if [ ! -d "$dir" ]; then
    say "CACHE-INCOMPLETE: $dir does not exist (cache miss)"
    return 3
  fi

  # ---- Arm 1: nothing but dependency directories. Our application's build dir
  # (`barkpark`) is not in mix.lock, so this arm catches it by name alone.
  local entry name
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    if [ ! -d "$entry" ]; then
      say "CONTAMINANT: $name is not a directory"
      contaminated=1
      continue
    fi
    if ! printf '%s\n' "${allow_names[@]}" | grep -qxF "$name"; then
      say "CONTAMINANT: directory '$name' is not a dependency named in mix.lock"
      contaminated=1
    fi
  done

  # ---- Arm 2: not one byte of barkpark-owned compiled code, wherever it hides.
  # Arm 1 already rejects a `barkpark` directory; this arm catches the same code
  # smuggled inside a directory that IS allowlisted.
  local -a strays
  strays=()
  while IFS= read -r line; do
    [ -n "$line" ] && strays+=("$line")
  done < <(find "$dir" -type f -name 'Elixir.Barkpark*.beam' 2>/dev/null | head -50)
  if [ "${#strays[@]}" -gt 0 ]; then
    for entry in "${strays[@]}"; do
      say "CONTAMINANT: barkpark-owned artifact $entry"
    done
    contaminated=1
  fi

  if [ "$contaminated" -eq 1 ]; then
    say "CACHE-CONTAMINATED: the restored _build/prod tree is not dependency-only"
    return 1
  fi

  # ---- Arm 3: completeness. This is what keeps Past Mistake #2 closed — a
  # half-populated cache must never be allowed to skip `--force`.
  local missing=0
  for name in "${req_names[@]}"; do
    if ! ls "$dir/$name"/ebin/*.beam >/dev/null 2>&1; then
      say "MISSING: prod dependency '$name' has no compiled ebin in the restored tree"
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    say "CACHE-INCOMPLETE: $missing of ${#req_names[@]} prod dependencies missing from the restored tree"
    return 3
  fi

  say "CACHE-COMPLETE: ${#req_names[@]} prod dependencies present, no barkpark-owned artifacts, no directory outside mix.lock"
  return 0
}

# ---------------------------------------------------------------------------
# --selftest — MUTATION PROOF. A tripwire never observed failing is not a
# tripwire, so this plants each contaminant in turn and asserts the verdict.
# ---------------------------------------------------------------------------
SELFTEST_ROOT=""
cleanup_selftest_root() { [ -n "$SELFTEST_ROOT" ] && rm -rf "$SELFTEST_ROOT"; }

selftest() {
  local root failures=0
  # The trap has to name a GLOBAL: `root` is function-local and is already out
  # of scope by the time an EXIT trap fires, which under `set -u` turns a clean
  # pass into an "unbound variable" error printed after the summary line.
  SELFTEST_ROOT="$(mktemp -d)"
  root="$SELFTEST_ROOT"
  trap cleanup_selftest_root EXIT

  local allow="$root/allow" req="$root/req"
  local -a deps=(jason plug plug_cowboy ecto ecto_sql postgrex phoenix phoenix_html telemetry finch nimble_pool castore)
  printf '%s\n' "${deps[@]}" > "$allow"
  # mix.lock is a superset: two dev/test-only names live in the allowlist and in
  # no prod tree, which is exactly the case a naive "allowlist == required"
  # implementation would get wrong.
  printf '%s\n' sobelow mix_audit >> "$allow"
  printf '%s\n' "${deps[@]}" > "$req"

  mk_tree() {
    local d="$1"; rm -rf "$d"; local n
    for n in "${deps[@]}"; do
      mkdir -p "$d/$n/ebin"
      : > "$d/$n/ebin/Elixir.${n}.beam"
    done
  }

  check() {
    local label="$1" want="$2" dir="$3" a="${4:-$allow}" r="${5:-$req}"
    local out got
    out="$(guard "$dir" "$a" "$r")"; got=$?
    if [ "$got" -eq "$want" ]; then
      say "  PASS  $label (exit $got)"
    else
      say "  FAIL  $label — wanted exit $want, got $got"
      printf '%s\n' "$out" | sed 's/^/        /'
      failures=$((failures + 1))
    fi
  }

  say "prod-build-cache-guard --selftest"

  local t="$root/lib"

  mk_tree "$t"
  check "clean dep-only tree is COMPLETE" 0 "$t"

  # THE MUTATION THE BRIEF ASKS FOR: a barkpark-owned .beam hidden inside an
  # allowlisted dependency's ebin. Arm 1 cannot see it; arm 2 must.
  mk_tree "$t"; : > "$t/jason/ebin/Elixir.Barkpark.Stale.beam"
  check "planted Elixir.Barkpark.Stale.beam REDS" 1 "$t"

  mk_tree "$t"; mkdir -p "$t/barkpark/ebin"; : > "$t/barkpark/ebin/Elixir.Barkpark.Repo.beam"
  check "our own application's build dir REDS" 1 "$t"

  mk_tree "$t"; mkdir -p "$t/some_vendored_thing/ebin"
  check "directory absent from mix.lock REDS" 1 "$t"

  mk_tree "$t"; : > "$t/loose_file"
  check "a loose file in the tree REDS" 1 "$t"

  # THE FALLBACK PROOF: remove one dependency's directory; the verdict must be
  # INCOMPLETE (3), so the caller rebuilds with --force rather than compiling
  # against a half-built prod tree.
  mk_tree "$t"; rm -rf "$t/postgrex"
  check "one missing dependency directory FALLS BACK" 3 "$t"

  mk_tree "$t"; rm -f "$t"/ecto/ebin/*.beam
  check "a dependency with an empty ebin FALLS BACK" 3 "$t"

  rm -rf "$t"
  check "cache miss (no tree at all) FALLS BACK" 3 "$t"

  # Vacuity floors.
  mk_tree "$t"; printf 'jason\nplug\n' > "$root/tiny_req"
  check "a suspiciously small required list FALLS BACK, never passes" 3 "$t" "$allow" "$root/tiny_req"

  mk_tree "$t"; printf 'jason\n' > "$root/tiny_allow"
  check "a suspiciously small allowlist REDS" 1 "$t" "$root/tiny_allow" "$req"

  mk_tree "$t"; : > "$root/empty"
  check "an empty allowlist REDS (never waves the tree through)" 1 "$t" "$root/empty" "$req"

  if [ "$failures" -eq 0 ]; then
    say "selftest OK — 11 cases"
    return 0
  fi
  say "selftest FAILED — $failures case(s)"
  return 1
}

main() {
  if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
  fi
  if [ "$#" -ne 3 ]; then
    say "usage: $0 <build_lib_dir> <allowlist_file> <required_file>"
    say "       $0 --selftest"
    exit 2
  fi
  guard "$1" "$2" "$3"
  exit $?
}

main "$@"

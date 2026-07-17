#!/usr/bin/env bash
# warm-worktree.sh <cell-slug> [--with-elixir]
#
# Pre-warm a cell worktree at the registered pin (D64) so a duel cell measures
# WORK, not cold-build noise. Idempotent: a second call reuses the worktree and
# skips a warm that already happened.
#
# Steps (the canonical recipe — README documents it verbatim):
#   1. `git worktree add --detach <wt> 591fdcd53` (isolated tmp, never the primary checkout).
#   2. Copy api/deps from the primary checkout — AFTER asserting mix.lock byte-matches
#      the pin (md5 fail-loud): mismatched deps = a silently different build.
#   3. With --with-elixir: run ONE scoped `mix test` (errors_test + error_code_coverage_test)
#      to compile the app into _build/test (~170s cold, ~4s warm after).
#      NEVER `mix ecto.create`/`ecto.migrate` — they force a second full MIX_ENV=dev
#      compile and need a DB the scoped, DB-free tests do not.
#
# Serial only. Emits the worktree path on stdout (last line) for the caller.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CELL="${1:?usage: warm-worktree.sh <cell-slug> [--with-elixir]}"
WITH_ELIXIR=0
[[ "${2:-}" == "--with-elixir" ]] && WITH_ELIXIR=1

WT="$(_scaffy_duels_wt "$CELL")"
PRIMARY="$(_scaffy_duels_primary)"
[[ -d "$PRIMARY/api/deps" ]] || die "primary checkout has no api/deps at $PRIMARY — cannot seed the worktree"

# 1. Worktree at the pin (idempotent).
# NB: string-match a captured listing — piping into `grep -q` under `pipefail`
# races (grep closes the pipe, git dies on SIGPIPE, the pipeline reports failure).
_wt_list="$(git worktree list --porcelain)"
if [[ $'\n'"$_wt_list"$'\n' == *$'\n'"worktree $WT"$'\n'* ]]; then
  note "worktree exists, reusing: $WT"
else
  note "adding worktree at pin $SCAFFY_DUELS_PIN -> $WT"
  git worktree add --detach "$WT" "$SCAFFY_DUELS_PIN" >&2
fi

got="$(git -C "$WT" rev-parse --short=9 HEAD)"
[[ "$got" == "$SCAFFY_DUELS_PIN" ]] || die "worktree HEAD $got != pin $SCAFFY_DUELS_PIN"

# 2. Deps — md5-gate then copy.
lock_primary="$(md5_file "$PRIMARY/api/mix.lock")"
lock_wt="$(md5_file "$WT/api/mix.lock")"
[[ "$lock_primary" == "$lock_wt" ]] || \
  die "mix.lock md5 mismatch (primary=$lock_primary pin=$lock_wt) — deps do not match the pin; refusing to copy"
if [[ -d "$WT/api/deps" ]]; then
  note "deps present, reusing"
else
  note "copying api/deps ($(du -sh "$PRIMARY/api/deps" 2>/dev/null | awk '{print $1}')) from primary"
  cp -R "$PRIMARY/api/deps" "$WT/api/deps"
fi

# 3. Elixir warm (optional — needed for chores whose gates run Elixir).
if [[ "$WITH_ELIXIR" == 1 ]]; then
  if [[ -d "$WT/api/_build/test/lib/barkpark/ebin" ]]; then
    note "_build/test already warm, skipping mix compile"
  else
    note "warming _build/test via scoped mix test (never ecto.create/migrate)…"
    ( cd "$WT/api" && CC=/usr/bin/clang mix test \
        test/barkpark/content/errors_test.exs \
        test/barkpark_web/contract/error_code_coverage_test.exs >&2 ) \
      || die "warm mix test failed — _build not usable"
  fi
else
  note "elixir warm skipped (--with-elixir not passed); Elixir-gated chores will not score green here"
fi

# Last stdout line = the worktree path (contract with run-cell.sh).
printf '%s\n' "$WT"

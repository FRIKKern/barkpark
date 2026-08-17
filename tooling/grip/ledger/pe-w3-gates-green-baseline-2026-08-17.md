# pe-w3 gates-green baseline — re-derivation recipe (2026-08-17)

Wave-3 verifier proof that the five pinned Elixir suites + pdrender Go tests
are GREEN on origin/main @ 17b3aabf45 (all 7 wave-2 PRs #11757-11762,#11720 present),
BEFORE any wave-3 slice flies. Distrust vacuous green: these were RUN, not read.

## Baseline ref
    git -C /Volumes/SATECHI/github/barkpark rev-parse origin/main   # 17b3aabf4538aadf90d9fcd27b44e4dce99e8a09
    git -C /Volumes/SATECHI/github/barkpark log --oneline origin/main | grep -iE '1175[789]|1176[012]|11720'  # all 7 present

## Setup (isolated worktree — shared checkout was behind 18, ff blocked by untracked ledger collisions)
    WT=<scratchpad>/wt-gates-green
    git -C /Volumes/SATECHI/github/barkpark worktree add --detach "$WT" 17b3aabf45
    cd "$WT/api"
    export CC=/usr/bin/clang            # REQUIRED: `cc` alias shadows compiler; argon2 NIF fails with "unknown option '-g'"
    MIX_ENV=test mix deps.get
    MIX_ENV=test mix deps.compile argon2_elixir --force   # after CC set
    MIX_ENV=test mix compile
    MIX_ENV=test mix ecto.create ; MIX_ENV=test mix ecto.migrate   # DB already present/up locally

## The five Elixir suites (run together)
    cd "$WT/api" && CC=/usr/bin/clang MIX_ENV=test mix test \
      test/barkpark/portable_doc/render/section_layout_test.exs \
      test/barkpark/portable_doc/render/view_edit_parity_test.exs \
      test/barkpark/portable_doc/bpml_test.exs \
      test/barkpark/portable_doc/render/reader_dark_token_parity_test.exs \
      test/barkpark/content/papers/body_html_stamp_honesty_test.exs
    # => "74 tests, 0 failures"  (Finished in 4.8s)

## pdrender Go tests
    cd "$WT" && CC=/usr/bin/clang go test ./internal/pdrender/...
    # => ok github.com/FRIKKern/barkpark/internal/pdrender 2.169s ; htmlcheck ok ; demo/dump/widthcheck no test files

## Hairline-grid parity-invisibility grep
    grep -nE '\.bp-stat([^s]|$)' "$WT/api/test/barkpark/portable_doc/render/view_edit_parity_test.exs"
    # => exit 1, NO match: singular per-cell `.bp-stat` selector is NOT parity-tracked.
    grep -n 'bp-stat' "$WT/api/test/barkpark/portable_doc/render/view_edit_parity_test.exs"
    # => the CONTAINER `.bp-stats` IS tracked (in @parity_elements L74 and @mirror_elements L428).
    # Nuance for Decide: the hairline-grid CELL paint (`.bp-stat`) is parity-invisible as surveyed,
    # BUT container `.bp-stats` props ARE compared View↔Edit — a container-level paint reds the gate
    # unless both surfaces match (comment L71-72 already handles a prior `.bp-stats padding:4px` twin).

## Cleanup
    git -C /Volumes/SATECHI/github/barkpark worktree remove --force "$WT"

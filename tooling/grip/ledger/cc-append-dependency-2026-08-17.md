<!-- doc-tier: cold | canonical-for: cc-append-dependency-2026-08-17 | budget: 900tok -->
# CC-append dependency — re-derivation recipe (scaffy wave verify, 2026-08-17)

Question: which house ASSERT CMDs depend on the engine's unconditional
`CC=/usr/bin/clang` append (apply.go:790, D38), and does anything break without it?

## Re-derive the enumeration (origin/main authority)

    # 17 .scaffy files have ASSERT CMD but no inline CC=/usr/bin/clang:
    for f in $(git show origin/main:scaffy/commands | tail -n +3); do case "$f" in *.scaffy)
      c=$(git show origin/main:scaffy/commands/$f);
      echo "$c" | grep -q 'ASSERT CMD' && ! echo "$c" | grep -q 'CC=/usr/bin/clang' && echo "$f";; esac; done

    # Of those, EVERY C-compiling assert (cd api && mix compile / mix test / mix ecto)
    # carries TIER ci — DEFERRED, never executed locally (D38: "TIER ci -> never execute").
    # The non-ci (locally-run) asserts invoke only: grep, node --test, python3 json,
    # pnpm/vitest/tsc, sed/grep, bash scripts — none invoke a C compiler.

## Re-derive the harm mechanism (cold NIF path DOES honor CC)

    # api has native NIF deps via elixir_make: argon2_elixir, vix, expty, lazy_html.
    cd api
    CC=/usr/bin/does-not-exist-clang mix deps.compile argon2_elixir --force; echo $?  # -> 1 (No such file)
    CC=/usr/bin/clang               mix deps.compile argon2_elixir --force; echo $?  # -> 0
    # Incremental (NIF already built) ignores CC entirely:
    CC=/usr/bin/does-not-exist-clang mix compile; echo $?                            # -> 0

## Verdict input for D38

No locally-executed house assert compiles C: all `mix compile/test/ecto` asserts are
TIER ci (deferred, run only by Barkpark CI where clang exists); all non-ci asserts are
compiler-free. The CC append is therefore INERT on the engine's local exec path.
Cold NIF builds honor CC and fail on a bogus/missing path — but no local assert triggers one.
Safe ruling: drop-entirely regresses nothing the engine runs; CC-only-when-unset is the
minimal-risk variant (preserves D38's clang default for any future cold compile while
never clobbering a stranger's cc/gcc toolchain). host-probe is unjustified.

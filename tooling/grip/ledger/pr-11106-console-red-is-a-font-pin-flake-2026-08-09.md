# PR #11106's Console gate red was a FONT PIN flake, not a defect — re-derivation recipe

Wave 59 verifier, 2026-08-09. Assignment `v12-11106-extra-reds`.

## Claim under test

The survey read #11106 as owning TWO reds main does not own (Console gate + Overflow guard),
and flagged that as the thing that would break the wave-58 unjam batch on its last merge.

## Verdict: REFUTED. The refusal was transient. One re-run cleared both.

## Re-derivation

    # 1. The failing job's own words (run 31293638441, job 93195205876, head 7f80f4b1d)
    gh run view --job 93195205876 --log | grep -F "FONT PIN REFUSED"
    #  -> Inter=false IBM Plex Mono=false. Inter [declared 0/1 face(s): none] ·
    #     IBM Plex Mono [declared 0/3 face(s): none]. document.fonts.status=loaded size=4.
    #     ... ENVIRONMENT refusal (exit 2), NOT a measured screen defect (exit 1).

    # 2. The assets are NOT missing — 4 woff2 on disk, 4 @font-face declared, zero headroom
    git ls-tree -r --name-only origin/main -- cloud/priv/static/fonts
    git show origin/main:cloud/priv/static/app.css | grep -c '@font-face'   # 4

    # 3. Re-run the single job
    gh run rerun --job 93195205876
    gh pr checks 11106 | grep -iE 'console gate|overflow'
    #  -> Overflow guard (rendered)  pass  52s   job 93199006869
    #  -> Console gate               pass   3s   job 93199087461

    # 4. The pass is not vacuous — GR115 (the leg that refused) measured
    gh run view --job 93199006869 --log | grep -F "OVERFLOW GUARD PASS"
    #  -> ... GR115-bpconsole-dead-rule ... 25 legs measured fixed in a real browser

## Why it happened, and why it will happen again

Charter D380(3) already ruled the class: "all four ship on `origin/main` with exactly four
`@font-face` blocks and ZERO headroom, so a `FONT PIN REFUSED` today is a SERVING fault,
never a missing asset, and never a layout to chase."

Mechanism: `nav()` (`cloud/priv/static/__preview__/overflow-guard.mjs:766-779`) polls
`readyExpr` and calls `pinFonts(url)` the instant it is truthy. `document.fonts` reported
`size=4` yet `declared 0/1` and `0/3` for both families — i.e. four FontFace entries existed
whose `family` matched neither expected name at that instant. That is a navigation-commit
race, not repo state: the same pin passed on the two preceding legs (GR108, GR109) in the
same process and on the same bytes.

Exposure is universal, not Console-scoped: `scripts/console-path-escape-check.sh` declares
`cloud/lib/**` inside `CONSOLE_PATHS` (wave 30 S1, deliberate over-inclusion), so every
wave-58 PR — all of which touch `cloud/lib/barkpark_cloud/**` — runs the full Overflow guard
and is exposed to this race. Observed rate: 1 refusal in 8 recent `console-harness.yml` runs.

## What #11106 actually owns after the re-run

    gh pr checks 11106 | grep fail
    #  -> Cloud control-plane (test) (27.0, 1.18.1)   fail
    #  -> Cloud gate                                  fail

Exactly the two contexts `origin/main`'s own head (`0e9246447`) is red on, and the three
failing tests are byte-for-byte main's three:
`payload_key_set_census_test.exs:1431`, `reader_less_instrument_census_test.exs:687/703`,
`reader_less_instrument_census_test.exs:656/657`.

(main is red on a THIRD context, Sobelow, that #11106 skips — so the PRs are a strict subset
of main's reds, never a superset.)

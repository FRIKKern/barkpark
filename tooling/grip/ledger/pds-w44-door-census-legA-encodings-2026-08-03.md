# PDS w44 — door-census leg-A encodings: re-derivation recipes

Verifier lane `door-census-legA-encodings`. Every row below is a command that
re-derives its claim from scratch. `origin/main` MOVED mid-run: #9332, #9333,
#9334 merged at `3f18ab048`; figures taken before that are labelled PRE-MERGE.

## R1 — denominator (19, derived not transcribed)

    git ls-tree -r --name-only origin/main -- scripts | grep -cE '^scripts/pds-.*\.(sh|exs)$'   # 19 (17 .sh + 2 .exs)

`43` counts every `scripts/pds-*` including `.md`/`.txt`; `17` counts `.sh` only.

## R2 — the two legs, per row

    D=$(mktemp -d); git archive origin/main | tar -x -C $D; cd $D
    bash scripts/elixir-path-escape-check.sh --list-escapes        # leg A source (derived census)
    bash scripts/elixir-path-escape-check.sh --print-set test      # leg B source (declared set)
    printf '%s\n' scripts/pds-ledger-census.sh | bash scripts/elixir-path-escape-check.sh --match test

THROUGH on `3f18ab048` = 3 of 19: `pds-status-only-residue.exs`,
`pds-record-parity.test.sh`, `pds-elixir-receipt-census.exs`. PRE-MERGE it was 1.

## R3 — the legs are NOT independent (mutation, both directions)

    # MUT-1  leg A present, leg B removed  -> ALREADY RED on main today
    perl -0pi -e 's{^scripts/pds-record-parity\.test\.sh\n}{}m' scripts/elixir-path-escape-check.sh
    bash scripts/elixir-path-escape-check.sh --check; echo rc=$?
    # rc=1 ::error:: UNCOVERED repo-root read: scripts/pds-record-parity.test.sh

    # MUT-2  leg B present, leg A absent  -> GREEN, invisible to every gate
    perl -0pi -e 's{^scripts/pds-status-only-residue\.exs\n}{scripts/pds-ledger-census.sh\nscripts/pds-status-only-residue.exs\n}m' scripts/elixir-path-escape-check.sh
    bash scripts/elixir-path-escape-check.sh --check; echo rc=$?   # rc=0 OK

`--check` runs at `.github/workflows/elixir.yml:244`, so leg A ⟹ leg B is
ratchet-enforced. The AGREEMENT check is not "vacuously green today" — it is
structurally unable to red in the direction the wave cares about. Its only
non-redundant class is MUT-2, the DEAD DECLARATION.

## R4 — a COMMENT manufactures a false THROUGH

    perl -0pi -e 's{# The "\.\./\.\./\.\./scripts/[^"]*" STRING LITERAL}{# The "../../../scripts/pds-ledger-census.sh" STRING LITERAL}' api/test/barkpark/pds_residue_lens_test.exs
    perl -0pi -e 's{^scripts/pds-status-only-residue\.exs\n}{scripts/pds-ledger-census.sh\nscripts/pds-status-only-residue.exs\n}m' scripts/elixir-path-escape-check.sh
    bash scripts/elixir-path-escape-check.sh --check   # OK — and now BOTH legs hold for a script no test runs

The extractor (`grep -Eoh '"\.\./[^"]*"'`, ~l.215) is comment-blind; the
existence filter only saved the shipped case because the real comment names a
unicode-ellipsis path that is not on disk.

## R5 — the honest leg A (kills R4, keeps all three real doors)

    grep -rn --include='*.exs' -E '^[[:space:]]*@[a-z_]+ +"\.\./[^"]*<basename>"' api/test/

Depth-agnostic (`"\.\./`, never a fixed `../../../`), comment-stripped
(first non-space char must not be `#`), attribute-bound. Pair it with a
`System.cmd(` reachability check in the same file. All three landed doors use
the identical shape: `@x_rel` at l.44 / l.55 / l.64.

## R6 — execution encodings actually present in api/test

    git grep -nE 'System\.cmd\(|Code\.require_file' origin/main -- 'api/test/**'

E1 `System.cmd(elixir, [script])` — residue lens, census. E2
`System.cmd(ctx.bash, [harness])` — record-parity, `pds_record_parity_test.exs:79`
(so "no api/test file shells a repo .sh" is REFUTED on landed main). E3
`Code.require_file` — `async_env_seam_scan.exs`, in-BEAM, not D633-priceable,
but NOT a `pds-*` row so it is outside this denominator. E4 interpreter-with-
inline-program: `benchmark_test.exs:626` passes the script as argv[2] of
`python3 -c` — argv[0] is not the instrument.

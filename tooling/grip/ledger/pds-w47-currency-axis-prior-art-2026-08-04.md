# pds-w47 — the currency axis already exists, at a better key, and it is printing DRIFT today

Verifier lane `drifted-head-second-look`, wave 47. Ground: clean `git archive origin/main`
export at **49345a98c1dbd9c768f3312185be0f5483878241**.

## The prior art the direction did not cite

    bp search query "judged rows keyed path mfa head_hash expr_fp three verdicts"
    #  -> pds-w34-hand-bucket-register (open, 19/21)

`scripts/pds-elixir-receipt-census.exs` (7,634 lines, on main) already ships the
"does this row still descend from the code" oracle:

    git -C "$R" show origin/main:scripts/pds-elixir-receipt-census.exs | sed -n '565,600p'

- The register is keyed on `{path, module.name/arity, head_hash, expr_fp}` — 91 rows.
- Its own measurement, in the file: `{path, mfa} = 75 distinct · +head_hash = 76 ·
  +expr_fp = 91 · expr_fp ALONE = 67`, and `expr_fp IS THE LOAD-BEARING FIELD`.
  A **path/line** key — what wave 47's proposed currency axis would use — is a
  strict subset of `{path, mfa}`, which collapses 91 rows to 75: it loses 18% of
  the discrimination before it resolves a single token.
- `UNJUDGED` already means "the current head_hash+expr_fp equal the recorded pair",
  and it `:reds`. Drift detection is not a missing capability.
- `ROSTER-VERDICT-FRESH` re-derives `anchor_mfa` AND `def_fp` every run, never
  transcribed, and **states its own blind shape in the output**: a repair confined
  to a CALLEE moves no byte inside the roster row's own def, so the arm prints PASS
  through it. That is the D633 shape the direction wanted, already built.

Building a path/line rival is a dedup defect against a shipped, better-keyed
instrument, and the repo's own doc contract forbids it.

## Run it — it exits OK and it prints five stale literals

    cd $(mktemp -d) && git -C "$R" archive origin/main | tar -x
    elixir scripts/pds-elixir-receipt-census.exs        # no mix project, no compile
    # ... INTEGRITY: 13 arms, all PASS ... "CENSUS OK", user cpu ~10,641 ms

    DRIFT vs PDS-D448 (advisory — printed, never enforced)
      textual        recorded  103  derived  104  DRIFT
      ast-literal    recorded   95  derived   95  ==
      phantom        recorded    8  derived    9  DRIFT
      consumer       recorded    4  derived    4  ==
      emitted        recorded   91  derived   91  ==
      write-routed   recorded   64  derived   54  DRIFT
      read-routed    recorded   17  derived   14  DRIFT
      unrouted       recorded   10  derived   23  DRIFT

**Five of eight committed PDS-D448 population literals no longer descend from the
tree**, and the instrument that knows it is advisory by construction (`printed,
never enforced`, file line 120). `write-routed` is off by 10 (64 -> 54) and
`unrouted` by 13 (10 -> 23) — a 130% error on the number the epic's own routing
argument rests on.

This is the wish's sentence, already measured, one flag from refusing. It is
strictly cheaper and strictly more load-bearing than a new path-resolver.

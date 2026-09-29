# merge-check: INHERITED vs OWN — 2026-09-15 (gates-r19-w9)

`merge-check.sh`'s `full rollup` arm failed on ANY concluded non-success, so a red
the PR caused and a red it inherited from main rendered identically. In r19 the
same arm produced one correct refusal (#18400 first head `fa3fbb28a`, its own prose
violation) and three false ones (#18400 later, #18448, #18431 `d21637ca2` — all
already failing on main). #18431 strictly improved its gate, 17 novel to 10, and
was refused anyway.

The ratio is the finding, not the nuisance. False refusals train the operator to
override the arm, and the day the red IS the PR's own, the override is a habit.

## What the fix reads

The same context's CHECK-RUNS on the 5 most recent `origin/main` heads.

- **Read check-runs, not runs.** Job-level `continue-on-error` launders the RUN
  conclusion and `needs.<job>.result` but NOT the check run. Run `34955892970`
  reads `success`; its job `Required-check spec drift (advisory)` and its
  check-run on `214d6cd98` both read `failure`. A `gh run list --branch main`
  failure census is structurally blind to precisely these reds.
- **`--paginate -q` evaluates once per page**, emitting one value per page and
  never a total, so a row on page 2 reads as NOT RENDERED rather than as an
  error. A STREAM is safe under per-page evaluation; an AGGREGATE is not. The
  census uses `--paginate` with no per-page filter, piped to `jq -s`.
- **An empty census is not a clean main.** An exhausted shared rate limit renders
  as an empty result set with stderr suppressed. Below a 10-row floor the arm
  refuses to answer instead of classifying every red as OWN.

## Sample size is a judgement, not a constant

Measured over the 5 newest main heads: `Doc budgets + anchors` 5/5 (stable),
`Required-check spec drift (advisory)` 1/5 (flapping, ~1-in-6). A single sample
of main is a coin flip whose losing side is a false OWN. N=5, overridable.

A stable red, a flapping red and a thin sample are three different objects and
print as three different words. `1/1` is inherited but it is not evidence of a
stable main red, and calling it STABLE would overstate one sample's confidence
in exactly the direction that gets a guard ignored.

## Fail-closed directions

`UNPROVEN` (rendered on no sampled main head) refuses: an absence is never
evidence of health. Any own-class red refuses the whole set even when inherited
reds sit beside it — proven on `fa3fbb28a`, which carries both.

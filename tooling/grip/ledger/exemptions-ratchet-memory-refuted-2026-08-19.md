# design/check.mjs Part E has NO cross-commit memory — re-derivation recipe

Claim under test: the design/exemptions.json ratchet is defeatable by a two-PR split
because Part E compares current-tree literal counts against current-tree baselines only.

VERDICT: cross-commit memory REFUTED (Part E reads the working tree, never git).
The ratchet itself is sound; the defeat is a doc-gates paths-filter gap
(design/exemptions.json matches ZERO globs in either `on:` block of
.github/workflows/doc-gates.yml — the sole workflow that runs `node design/check.mjs`).

## Re-derive (hermetic, temp copy only — never mutate the shared checkout)

    cd /Volumes/SATECHI/github/barkpark
    T=$(mktemp -d) && git archive origin/main | tar -x -C "$T"
    (cd "$T" && node design/check.mjs >/dev/null 2>&1; echo "baseline rc=$?")   # => 0

    # Mutation 1: raise ONE baseline, touch no literals -> must RED (SHRANK)
    (cd "$T" && python3 - <<'PY'
import json
p='design/exemptions.json'; d=json.load(open(p))
for e in d['entries']:
    if e['path']=='cloud/priv/static/app.css': e['count']=34   # was 31
json.dump(d,open(p,'w'),indent=1)
PY
     node design/check.mjs >/dev/null 2>&1; echo "mutation1 rc=$?")            # => 1

    # Mutation 2: add 3 literals up to the raised ceiling -> passes again
    (cd "$T" && printf '\n.a{color:#abc123}\n.b{color:#def456}\n.c{color:#123abc}\n' \
        >> cloud/priv/static/app.css
     node design/check.mjs >/dev/null 2>&1; echo "mutation2 rc=$?")            # => 0

## The wiring gap (what actually makes the ratchet defeatable)

    git show origin/main:.github/workflows/doc-gates.yml | grep -c exemptions   # => 0
    git grep -n "design/check.mjs" origin/main -- .github                       # only doc-gates.yml:442

PR shape: PR-1 edits design/exemptions.json ALONE (count 31 -> 34). No glob matches,
doc-gates never runs, merge is green — even though mutation 1 proves the guard WOULD
have red. PR-2 adds three hand-stamped hex to cloud/priv/static/app.css (glob-matched),
doc-gates runs, Part E compares 34 vs 34 and passes. Ratchet defeated by two ordinary PRs.

Severity re-pricing: doc-gates is NOT a required context (.github/required-checks.json
files "Doc budgets + anchors" under S4 PATHS-FILTERED), so this is a post-merge
DETECTION gap, not a merge hole.

Secondary: `api/priv/static/assets/bp-graph.js` is a ledger entry that also matches no
doc-gates glob. Planting one hex there reds Part E when the gate runs
(`Part E FAIL: api/priv/static/assets/bp-graph.js GREW 114 -> 115`), but a PR touching
only that file never triggers doc-gates. It does trigger bp-graph-drift.yml, whose job
is named "(advisory)".

Fix direction: add `design/exemptions.json` (and `api/priv/static/assets/bp-graph.js`)
to BOTH `on.push.paths` and `on.pull_request.paths` in doc-gates.yml.

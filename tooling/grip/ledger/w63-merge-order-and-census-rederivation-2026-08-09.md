# w63 / v10-merge-order — re-derivation recipes

All commands run from the repo root unless a `cd` is shown. Sandbox = a scratchpad
copy of `origin/main:cloud/priv/static` with PR #11337's `scenarios.mjs` swapped in,
so nothing here touches the working tree.

## Build the sandbox

    SP=/tmp/w63 && rm -rf $SP && mkdir -p $SP
    git archive origin/main cloud/priv/static | tar -x -C $SP
    gh api "repos/:owner/:repo/contents/cloud/priv/static/__preview__/scenarios.mjs?ref=c2dbadfd7837175c5b24262a0457e08238de6f7f" \
      --jq .content | base64 -d > $SP/cloud/priv/static/__preview__/scenarios.mjs
    cd $SP/cloud/priv/static/__preview__

Note the `?ref=` MUST be quoted — unquoted, zsh globs it away, `gh` errors, and the
sha you compare becomes `da39a3ee…` (the empty-string sha), which reads DIFFER for
every file. That false answer was produced once in this phase.

## Counter race — which open PRs touch the pin files

    for n in $(gh pr list --state open --limit 100 --json number -q '.[].number'); do
      gh pr view $n --json files -q ".files[].path" | sed "s|^|$n |"
    done | grep -E 'scenarios\.mjs|breakpoint-sweep|member-authority-sweep'

Truncation guard (gh caps `files` at 100 — verify no PR is at the cap):

    ... | awk '{c[$1]++} END{for(k in c) print c[k], k}' | sort -rn | head -3

## Pin-file identity between main and the PR head

    for f in breakpoint-sweep.test.mjs member-authority-sweep.mjs breakpoint-sweep.mjs scenarios.mjs; do
      a=$(git show origin/main:cloud/priv/static/__preview__/$f | shasum | cut -d' ' -f1)
      b=$(gh api "repos/:owner/:repo/contents/cloud/priv/static/__preview__/$f?ref=<PRHEAD>" --jq .content | base64 -d | shasum | cut -d' ' -f1)
      echo "$f $([ "$a" = "$b" ] && echo SAME || echo DIFFER)"
    done

## Census — baseline, red, and the two candidate fixes

    node --test breakpoint-sweep.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)|^not ok|census reconciles'

- main scenarios, main pins → `54/54`.
- PR scenarios, main pins → `50/54`, four named reds:
  `not ok 17` coverageReport, `not ok 21` THE IMPORT PROOF, `not ok 44` census,
  `not ok 50` "A 101st SCENARIO IS REFUSED BY NAME".
- CELL path: append one `CELLS` row after `instance-detail`, then bump exactly
  `:596 → 111`, `:597 → 27`, `:598 → 26` → `54/54`.
- RESIDUE path: add one `SCENARIO_RESIDUE` key, bump `:596 → 111`, `:599 → 86`,
  `:602 → 86` → `52/54`; `not ok 47` (family header `// hash:#instance — 22`) and
  `not ok 48` (`These N` in `RESIDUE_FAMILY_REASONS`) still red.

## The member-authority pins — prove the instruction is wrong by mutation

    node member-authority-sweep.mjs; echo "exit=$?"

- pins untouched (10/110) against 111 scenarios → prints `ok actor-set … (pinned 10/110)`
  plus a `note`, and **exits 0**. The pin cannot lose.
- following the sweep's own printed instruction ("update both pins", 11/111) →
  `FAIL actor-set … 1 guard failure(s) — exit 1`.
- correct state (10/111) → `ok … (pinned 10/111)`, exit 0, note gone.

## Branch protection — the required set, measured not remembered

    gh api repos/:owner/:repo/branches/main/protection \
      --jq '{strict: .required_status_checks.strict, contexts: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}'

## Is main itself red before blaming a PR

    gh api "repos/:owner/:repo/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
      --jq '.check_runs[] | select(.name|test("Console|tier floor|Overflow")) | "\(.conclusion)\t\(.name)"'

## Anchor shift — why order matters even with zero conflicts

    gh pr diff <N> --patch | awk '/^diff --git/{f=$3} /^@@/{print f" "$0}' | grep app.js
    git show origin/main:cloud/priv/static/app.js | grep -n 'function updateBadge\|function lastCheckedText\|function fleetUpdateChip'
    git merge-tree --write-tree origin/main refs/tmp/pr<N> >/dev/null; echo rc=$?

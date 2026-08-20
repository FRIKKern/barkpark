<!-- doc-tier: cold | canonical-for: acrc-baseline-green-recipe | budget: 400tok -->

# acrc content/render wave — baseline-green re-derivation recipe

Verifier assignment [baseline-green], 2026-08-18. origin/main tip `328f8288c9`;
primary checkout `4eb5cae30e` is byte-identical to origin/main for the three
test files and `walk.ex` (empty `git diff --stat 4eb5cae30e origin/main --` over
those paths), and had a test build — so the run below is a true origin/main baseline.

## Claim: the three render test files pass CLEAN on origin/main.

Re-derive (from api/, primary checkout or a worktree at origin/main):

    cd api && CC=/usr/bin/clang mix test \
      test/barkpark/portable_doc/render/render_tolerance_test.exs \
      test/barkpark/portable_doc/render/walk_test.exs \
      test/barkpark/portable_doc/render/render_test.exs 2>&1 | tail -15

Result: `86 tests, 0 failures`. Per file:
render_tolerance_test 12, walk_test 67, render_test 7 (each 0 failures).

## Supporting: the mutation's children:null case is genuinely uncovered.

    git show origin/main:api/test/barkpark/portable_doc/render/render_tolerance_test.exs \
      | grep -n '"children"'

The fuzzer sets `"children" => [gen_scalar()]` (line 109) — always a LIST value.
No case puts a null/scalar VALUE at the children key, so a new red is real, not vacuous.

## Supporting: 16 children->Enum.map sites; 5 bypass the shared helpers.

    git show origin/main:api/lib/barkpark/portable_doc/render/walk.ex \
      | grep -nE 'Map.get\(.*"children".*\[\]\)|not is_list'

16 sites. render_children/paragraph_inner sites: 188,198,212,1434,1447,1527,1536,
1543,1548,1563,1569. Inline direct-Enum.map sites that bypass both helpers:
283,350,424,544,649. Guarding only the two shared helpers leaves these 5 raising —
confirms the digest contradiction; children_of/1 routed through all 16 is the complete fix.

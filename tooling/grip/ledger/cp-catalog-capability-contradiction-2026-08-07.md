# Re-derivation recipe — the control plane serves `catalog:false` for the two kinds it implements a catalog for

Wave 45 verifier, `catalog-contradiction` assignment. Baseline `origin/main` = `b00d793c0`.
NOTE: the primary checkout was 571 commits BEHIND origin/main at derivation time
(`git rev-list --count HEAD..origin/main` → 571). Every fact below is re-derived from
`origin/main`, in a detached scratchpad worktree — never from the working tree.

## 0. Isolate (the primary checkout is stale and must not be edited)

    git worktree add --detach /tmp/w45-main b00d793c0e2065e98a03fed6c4356245d897ee3a

The parity-test surfaces happen to be identical between local HEAD and origin/main —
verify before trusting an in-tree run:

    for f in internal/cli/cloud/providers_capabilities.json internal/cli/cloud/registry_test.go \
             internal/cli/cloud/registry.go internal/cli/cloud/provider.go \
             cloud/priv/static/__fixtures__/providers_capabilities.json \
             cloud/test/barkpark_cloud/providers_capabilities_contract_test.exs; do
      git diff --quiet origin/main HEAD -- "$f" && echo "SAME  $f" || echo "DIFF  $f"; done

`router.ex` and `failure_copy.ex` are DIFF — read those only via `git show origin/main:`.

## 1. The contradiction

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'defp build_provider_catalog('
    git show origin/main:internal/cli/cloud/providers_capabilities.json
    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '727,729p'

Two clause heads (`"hetzner"`, `"azure"`), both `catalog:false` in the served fixture,
and the gap sentence the console paints for them.

## 2. The two existing parity gates are green in the same breath

    cd /tmp/w45-main/cloud && CC=clang mix test test/barkpark_cloud/providers_capabilities_contract_test.exs
    cd /tmp/w45-main   && CC=clang go test ./internal/cli/cloud/ -run TestRegistry

(The Elixir one has no deps in a fresh worktree — run it in a tree that does, the file
is byte-identical.)

## 3. The proposed derived CP arm, and the existing gate, side by side

Script: `cp_catalog_arm.exs` (standalone; regenerate from this recipe). Domain = the kinds
with a `defp build_provider_catalog("<kind>"` clause head, read from the router source;
cross-check side = `@neutral_kinds ~w(hetzner azure)` at router.ex:9312, so deleting a
clause head cannot buy silence.

    elixir cp_catalog_arm.exs \
      /tmp/w45-main/cloud/lib/barkpark_cloud/web/router.ex \
      /tmp/w45-main/internal/cli/cloud/providers_capabilities.json \
      /tmp/w45-main/cloud/priv/static/__fixtures__/providers_capabilities.json

On unmodified main: `EXISTING GATE … PASS` and `PROPOSED ARM: FAIL … ["azure","hetzner"]`, rc=1.

## 4. The escape hatch is closed (mutation)

    # flip catalog:false -> true in BOTH copies (the only edit the Elixir drift gate allows)
    perl -pi -e 's/"catalog": false/"catalog": true /g' internal/cli/cloud/providers_capabilities.json
    cp internal/cli/cloud/providers_capabilities.json cloud/priv/static/__fixtures__/providers_capabilities.json
    CC=clang go test ./internal/cli/cloud/ ./internal/cli/ \
      -run 'TestCapabilityFixtureParity|TestFixtureAzureRowHonest|TestAzureFixtureParityInCLI'
    git checkout -- internal/cli/cloud/providers_capabilities.json cloud/priv/static/__fixtures__/providers_capabilities.json

Three Go tests red — hetzner via DERIVED `DetectCapabilities`, azure via a hand pin
(`TestFixtureAzureRowHonest`) AND via derived parity in the cli package where the azure
package is linked (`TestAzureFixtureParityInCLI`). No Go provider implements `Cataloger`:

    grep -rn 'Cataloger\|func (.*) Catalog(' internal/cli/cloud/*.go internal/cli/cloud/azure/*.go

## 5. Teardown

    git worktree remove /tmp/w45-main

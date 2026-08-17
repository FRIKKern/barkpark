<!-- doc-tier: cold | canonical-for: pe-w6-onramp-parity-ci-wiring-rederivation | budget: 900tok -->

# pe-w6 onramp parity CI wiring — re-derivation recipe

Verdict: on origin/main, `scripts/check-doc-budgets.sh` FIRES on an md-only PR;
the Go test `TestOnrampAgentsMdWrapperParity` does NOT. The CODEX-headroom slice's
safety argument ("the parity test still guards the uncounted bytes") is UNWIRED for
md-only edits — the exact vacuous-green shape. The slice must add an md trigger
(at minimum `docs/setup/CODEX.md`, `docs/setup/AGENTS-MD.md`) to go-tests.yml, or
move the guard into a workflow that fires on md.

## Re-derive

    # (a) check-doc-budgets runner + trigger
    git show origin/main:.github/workflows/doc-gates.yml | sed -n '8,22p'      # push paths incl **/*.md
    git show origin/main:.github/workflows/doc-gates.yml | sed -n '330,336p'   # step: bash scripts/check-doc-budgets.sh
    # doc-gates fires on **/*.md AND runs check-doc-budgets.sh  => (a) GUARDED on md-only

    # (b) which workflow runs the parity test
    git grep -n 'func TestOnrampAgentsMdWrapperParity' origin/main
    #   internal/cli/onramp_cmd_test.go:433  (reads ../../docs/setup/CODEX.md, asserts embeds agentsMDCanonicalBody)
    git show origin/main:.github/workflows/go-tests.yml | sed -n '88,89p'      # run: go test -race ./...
    git show origin/main:.github/workflows/go-tests.yml | sed -n '18,52p'      # push+PR paths: NO **/*.md
    git show origin/main:.github/workflows/doc-gates.yml | grep -nE 'go test|TestOnramp'   # empty — doc-gates runs no go test
    # only cli-release.yml runs `go test ./...` but on cli-v* tags / dispatch, not md PRs
    #   => (b) UNGUARDED on md-only edits to CODEX.md / AGENTS-MD.md

## Trigger stanzas (quoted)

doc-gates.yml push+pull_request paths both begin `- "**/*.md"` and include
`- "scripts/check-doc-budgets.sh"`.

go-tests.yml push+pull_request paths: `**/*.go`, `go.mod`, `go.sum`,
`.github/workflows/go-tests.yml`, `templates/**`, `internal/pdrender/testdata/**`,
`internal/taskboard/testdata/**`, `docs/cli/fixtures/**`,
`cloud/priv/static/__fixtures__/**` — no `.md`, no `docs/setup/**`.

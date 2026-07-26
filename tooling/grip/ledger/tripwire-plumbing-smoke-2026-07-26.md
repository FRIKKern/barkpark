# Re-derivation recipes — tripwire-plumbing-smoke (mobile blocks wave, 2026-07-26)

Each row re-derives one load-bearing fact from scratch. Run from the repo root
unless a `cd` is shown.

## 1. mobile.yml ALREADY watches internal/pdrender/testdata/** (option (a) needs zero mobile.yml edits)

    sed -n '19,32p' .github/workflows/mobile.yml

Expect `paths:` blocks (push + pull_request) each listing `apps/mobile/**`,
`internal/pdrender/testdata/**`, `pnpm-workspace.yaml`,
`.github/workflows/mobile.yml`. No `js/**`.

## 2. js-tests.yml watches js/** but NOT internal/pdrender/testdata/**

    grep -n 'js/\*\*\|web/lib\|internal/pdrender' .github/workflows/js-tests.yml

Expect `js/**` twice, `web/lib/...` twice, zero `internal/pdrender` hits.

## 3. mobile jest + tsc BOTH accept a deep import of react source AND of a js-package JSON

    mkdir -p /tmp/bpprobe && cd /tmp/bpprobe && cat > p.probe.test.tsx <<'EOF'
    import { REGISTERED_TYPES } from '/Volumes/SATECHI/github/barkpark/js/packages/react/src/blocks/registry'
    it('66', () => { expect(REGISTERED_TYPES.length).toBe(66) })
    EOF
    cd /Volumes/SATECHI/github/barkpark/apps/mobile && npx jest --roots /tmp/bpprobe --testMatch '**/*.probe.test.tsx'

Expect `Tests: 1 passed`. For the tsc half, write `/tmp/bpprobe/tsconfig.probe.json`
extending `apps/mobile/tsconfig.json` with
`"compilerOptions": {"types": [], "typeRoots": ["<abs>/apps/mobile/node_modules/@types"]}`
(the `types:["jest"]` inherit cannot resolve from outside the package) and run
`npx tsc --noEmit -p /tmp/bpprobe/tsconfig.probe.json` from `apps/mobile` — expect exit 0.

## 4. REGISTERED_TYPES is NOT publicly exported from @barkpark/react

    grep -n 'REGISTERED_TYPES' js/packages/react/src/index.ts

Expect NO output — the live-import tripwire must reach `src/blocks/registry` by
relative path, not through the package entry.

## 5. mobile baseline (jest + typecheck) is green

    cd apps/mobile && npx jest 2>&1 | tail -5
    cd apps/mobile && npx tsc --noEmit -p tsconfig.json; echo "exit=$?"

Expect `Test Suites: 30 passed`, `Tests: 456 passed`, and `exit=0`.

## 6. scaffy has zero mobile awareness, and its anchors ARE CI-gated

    grep -rin 'mobile' scaffy/            # expect NO output
    grep -n 'scaffy/commands' .github/workflows/doc-gates.yml
    CC=/usr/bin/clang go run ./cmd/barkpark scaffy validate --repo . scaffy/commands/

Expect the validate envelope `{"anchors_ok":47,...,"files":22,"findings":[],"ok":true}`.
Any mobile payload anchor must exist verbatim in a real mobile file at merge time.

## 7. Path churn — the cost of widening mobile.yml

    for p in js/ js/packages/react/src/blocks/ apps/mobile/ internal/pdrender/testdata/; do \
      echo -n "$p -> "; git log --format=%H HEAD~400..HEAD -- "$p" | wc -l; done

Expect roughly `js/ -> 5`, `js/packages/react/src/blocks/ -> 3`,
`apps/mobile/ -> 23`, `internal/pdrender/testdata/ -> 1` (403-commit window).

## 8. The changeset gate the (b) placement would trip

    sed -n '164,170p' .github/workflows/js-tests.yml
    cat js/.changeset/config.json

Expect `pnpm changeset status --since=origin/${{ github.base_ref }}` and the
changesets config at `js/.changeset/` (baseBranch main).

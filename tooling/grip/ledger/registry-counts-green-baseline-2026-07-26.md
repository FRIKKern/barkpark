# Re-derivation recipes — registry counts + mobile green baseline (wave: barkpark-tasks-mobile-blocks, 2026-07-26)

Verified at `origin/main` = `d58bef19abe1370a0e7d0ef7a840749c5dfa6ccf` (worktree identical; `git diff origin/main` empty on all files below).

## R1 — react registry is 66 (settles the 66-vs-65 dispute)

    cd /Volumes/SATECHI/github/barkpark/js && pnpm --filter @barkpark/react test 2>&1 | tail -8
    # => Test Files 15 passed (15) / Tests 322 passed (322)

    cd /Volumes/SATECHI/github/barkpark/js/packages/react && \
      npx vitest run tests/PortableDoc.test.tsx --reporter=verbose 2>&1 | grep "registered types"
    # => ✓ ... covers EXACTLY the registered types (registry ≡ authored cases) 1ms
    #    (that test body asserts authored === Object.keys(DISPATCH) AND toHaveLength(66))

## R2 — runtime key list, independent of the assertion (no hand counting)

    cd /Volumes/SATECHI/github/barkpark/js && \
      node_modules/.pnpm/esbuild@0.25.12/node_modules/esbuild/bin/esbuild \
      packages/react/src/blocks/registry.ts --bundle --format=cjs --platform=node \
      --outfile=/tmp/reg.cjs --log-level=error && \
      node -e "const k=[...require('/tmp/reg.cjs').REGISTERED_TYPES];console.log(k.length);console.log(k.sort().join(' '))"
    # => 66

## R3 — mobile registry is 43 and a STRICT subset; gap = 23

    cd /Volumes/SATECHI/github/barkpark/apps/mobile && pnpm test 2>&1 | tail -6
    # => Test Suites: 30 passed, 30 total / Tests: 456 passed, 456 total  (~10s)

    cd /Volumes/SATECHI/github/barkpark/apps/mobile && \
      npx jest __tests__/chatRenderers.test.tsx --verbose 2>&1 | grep -E "registry tripwire|registered types|Tests:"
    # => registry tripwire (charter D31) / ✓ covers EXACTLY the registered types / Tests: 55 passed

Gap derivation (react runtime keys minus mobile literal keys + the 6 spread chat rows) =
23: api-endpoint asciicast bar-chart card chart code-tabs criteria-progress diff equation
filetree form gauge-list heatmap pipeline questionnaire roadmap sheet stage status-legend
tabs task-board task-detail video. mobile-only keys = 0.

## R4 — pd-parity fixtures ARE importable from mobile jest (crown-floor mechanics)

Precedent already green on main: `apps/mobile/__tests__/chatRenderers.test.tsx:32` imports
`../../../internal/pdrender/testdata/chat_golden_toolrows.json`, and
`__tests__/paperRenderer.test.tsx:38` requires `../../../tooling/webview-spike/assets/capstone.json`.
Direct probe (run from a scratchpad roots override so no repo file is added):

    npx jest --config '{"preset":"jest-expo","rootDir":"/Volumes/SATECHI/github/barkpark","roots":["<scratchpad>/probe"],"testMatch":["**/*.probe.test.tsx"]}'
    # probe required all 60 api/test/support/fixtures/pd-parity/*.json => PASS, 60 files

Fixture shape is per-type single-block: keys `_comment,expectedHtml,input,shape,type`
(NOT `{blocks:[…]}`) — a mobile harness iterates `input` as the one block under test.

## Baseline the round-0 split must preserve

react: 15 test files / 322 tests. mobile: 30 suites / 456 tests (suite list =
`npx jest --listTests`). `apps/mobile/src/papers/portabledoc/blocks.tsx` = 969 lines,
`chat.tsx` = 470, `inlines.tsx` = 249, `MermaidIsland.tsx` = 190, `model.ts` = 130.

#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Selftest for check-named-test-steps.mjs: proves the rule can still lose.
// Each row feeds judge() a workflow and a package config in memory and
// requires the exit it must give (0 pass, 1 fail by name, 2 cannot read) and
// the words that name the cause. The last rows hold excludeUnlessNamed: a file
// is named plain, as ./…, or absolute; nothing else counts.
//
// Usage: node scripts/check-named-test-steps.selftest.mjs

import { excludeUnlessNamed } from '../test-utils/named-step-files.mjs'
import { judge } from './check-named-test-steps.mjs'
function selftest() {
  const wf = (mirror, conf, extra = '') => `name: t
on:
  pull_request:
    paths:
      - "js/**"
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Mirror
        run: |
${mirror}
      - name: Conformance
${conf}
${extra}      - name: Test
        run: pnpm exec turbo run test \${{ steps.scope.outputs.filter }}
`
  // The mirror step's captured block, as js-tests.yml writes it.
  const MIRROR_LINES = [
    'set +e',
    'out="$(pnpm --filter @fix/react exec vitest run tests/b.test.ts 2>&1)"',
    'status=$?',
    'set -e',
    'echo "$out"',
    'case "$out" in',
    '  *"No projects matched the filters"*)',
    '    echo "mirror gate FAILED: pnpm --filter matched ZERO packages" >&2',
    '    exit 1',
    '    ;;',
    'esac',
    'exit "$status"',
  ]
  const block = (lines) => lines.map((l) => `          ${l}`).join('\n')
  const MIRROR = block(MIRROR_LINES)
  const CONF = '        run: pnpm --filter @fix/react exec vitest run tests/a.test.tsx'
  const cfg = (items) =>
    `import { configDefaults, defineConfig } from 'vitest/config'\nimport { excludeUnlessNamed } from '../../test-utils/named-step-files.mjs'\n\nconst NAMED_STEP_FILES = [${items}]\n\nexport default defineConfig({\n  test: {\n    exclude: [\n      ...configDefaults.exclude,\n      ...excludeUnlessNamed(NAMED_STEP_FILES, process.argv, import.meta.dirname),\n    ],\n  },\n})\n`
  const GOOD = cfg("'tests/a.test.tsx', 'tests/b.test.ts'")
  const ONE_LINE = GOOD.replace(
    /exclude: \[[^\]]*\]/,
    'exclude: [...configDefaults.exclude, ...excludeUnlessNamed(NAMED_STEP_FILES, process.argv, import.meta.dirname)]',
  )
  const pkg = ({
    text = GOOD,
    script = 'vitest run',
    files = ['tests/a.test.tsx', 'tests/b.test.ts', 'tests/c.test.ts'],
    extraConfig,
  } = {}) => [
    {
      name: '@fix/react',
      dir: 'packages/react',
      testScript: script,
      configs: [
        { file: 'vitest.config.ts', isDefault: true, text },
        ...(extraConfig ? [extraConfig] : []),
      ],
      has: (f) => files.includes(f),
    },
  ]
  const cases = [
    ['the good shape passes', wf(MIRROR, CONF), pkg(), 0, []],
    [
      'the known line in a block that ends 0 is refused',
      wf(
        MIRROR,
        '        run: |\n          set +e\n          pnpm --filter @fix/react exec vitest run tests/a.test.tsx\n          exit 0',
      ),
      pkg(),
      2,
      ['step "Conformance"', 'not one of the known whole forms'],
    ],
    [
      'the captured block without its last line is refused',
      wf(block(MIRROR_LINES.slice(0, -1)), CONF),
      pkg(),
      2,
      ['step "Mirror"', 'not one of the known whole forms'],
    ],
    [
      'the captured block with a line after its last is refused',
      wf(block([...MIRROR_LINES, 'exit 0']), CONF),
      pkg(),
      2,
      ['step "Mirror"', 'not one of the known whole forms'],
    ],
    [
      'the known line under a shell: key is refused',
      wf(MIRROR, `        shell: bash {0}\n${CONF}`),
      pkg(),
      2,
      ['step "Conformance"', 'shell: bash {0}'],
    ],
    ['the one-line exclude passes too', wf(MIRROR, CONF), pkg({ text: ONE_LINE }), 0, []],
    [
      'old setup: both named files still run by the Test step',
      wf(MIRROR, CONF),
      pkg({ text: 'export default {}\n' }),
      1,
      [
        '@fix/react tests/a.test.tsx: run by name',
        '@fix/react tests/b.test.ts: run by name',
        'runs it again',
      ],
    ],
    [
      'a listed file no step runs is red by name',
      wf(MIRROR, CONF),
      pkg({ text: cfg("'tests/a.test.tsx', 'tests/b.test.ts', 'tests/c.test.ts'") }),
      1,
      ['@fix/react tests/c.test.ts: listed in NAMED_STEP_FILES', 'nothing runs it'],
    ],
    [
      'a file named by two steps',
      wf(
        MIRROR,
        CONF,
        '      - name: Again\n        run: pnpm --filter @fix/react exec vitest run tests/a.test.tsx\n',
      ),
      pkg(),
      1,
      ['tests/a.test.tsx: run by name by 2 steps'],
    ],
    [
      'a named file that does not exist',
      wf(MIRROR, CONF),
      pkg({ files: ['tests/b.test.ts'] }),
      1,
      ['tests/a.test.tsx: run by name', 'does not exist'],
    ],
    [
      'a named step with if:',
      wf(MIRROR, `        if: github.event_name == 'push'\n${CONF}`),
      pkg(),
      1,
      ["has `if: github.event_name == 'push'`"],
    ],
    [
      'a named step with continue-on-error',
      wf(MIRROR, `        continue-on-error: true\n${CONF}`),
      pkg(),
      1,
      ['continue-on-error: true'],
    ],
    [
      'a named step in a job with if:',
      wf(MIRROR, '        run: echo moved').replace(
        'jobs:\n',
        `jobs:\n  other:\n    if: github.event_name == 'push'\n    steps:\n      - name: Elsewhere\n${CONF}\n`,
      ),
      pkg(),
      1,
      ['its job "other" has `if:'],
    ],
    [
      'a package no workspace has',
      wf(MIRROR, CONF.replace('@fix/react', '@fix/gone')),
      pkg(),
      1,
      ['names @fix/gone, which is no workspace package'],
    ],
    [
      'npx is cannot-read',
      wf(MIRROR, '        run: npx vitest run tests/a.test.tsx'),
      pkg(),
      2,
      ['shape this script cannot read'],
    ],
    [
      'a cd is cannot-read',
      wf(MIRROR, '        run: cd packages/react && pnpm exec vitest run tests/a.test.tsx'),
      pkg(),
      2,
      ['cannot read'],
    ],
    [
      'a backslash continuation is cannot-read',
      wf(
        MIRROR,
        '        run: |\n          pnpm --filter @fix/react exec vitest run \\\n            tests/a.test.tsx',
      ),
      pkg(),
      2,
      ['cannot read'],
    ],
    [
      'a partial filter is cannot-read',
      wf(MIRROR, '        run: pnpm --filter @fix/react exec vitest run conformance'),
      pkg(),
      2,
      ['cannot read'],
    ],
    [
      './ in the step is cannot-read',
      wf(MIRROR, '        run: pnpm --filter @fix/react exec vitest run ./tests/a.test.tsx'),
      pkg(),
      2,
      ['cannot read'],
    ],
    [
      'jest on a test file is cannot-read',
      wf(MIRROR, '        run: pnpm --filter @fix/react exec jest tests/a.test.tsx'),
      pkg(),
      2,
      ['cannot read'],
    ],
    [
      'a matrix value is cannot-read',
      wf(MIRROR, CONF).replace(
        '    runs-on: ubuntu-latest\n',
        '    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        file: [tests/d.test.ts]\n',
      ),
      pkg(),
      2,
      ['outside a run line'],
    ],
    [
      '--exclude in the test script is cannot-read',
      wf(MIRROR, CONF),
      pkg({ script: 'vitest run --exclude tests/a.test.tsx' }),
      2,
      ['uses --exclude'],
    ],
    [
      'a named file excluded another way is cannot-read',
      wf(MIRROR, CONF),
      pkg({
        text: "export default { test: { exclude: ['tests/a.test.tsx', 'tests/b.test.ts'] } }\n",
      }),
      2,
      ['some other way'],
    ],
    [
      'a list built by code is cannot-read',
      wf(MIRROR, CONF),
      pkg({ text: GOOD.replace("'tests/a.test.tsx', 'tests/b.test.ts'", '...OTHER') }),
      2,
      ['not a plain quoted test file path'],
    ],
    [
      'dropping configDefaults is cannot-read',
      wf(MIRROR, CONF),
      pkg({ text: GOOD.replace(/\s*\.\.\.configDefaults\.exclude,/, '') }),
      2,
      ['is not written as'],
    ],
    [
      'a list in a config the test script does not load',
      wf(MIRROR, CONF),
      pkg({
        text: 'export default {}\n',
        extraConfig: { file: 'vitest.browser.config.ts', isDefault: false, text: GOOD },
      }),
      2,
      ['does not load'],
    ],
    [
      'no single Test step is cannot-read',
      wf(MIRROR, CONF).replace('turbo run test', 'turbo run lint'),
      pkg(),
      2,
      ['exactly one all-packages Test step'],
    ],
    [
      'nothing to read is cannot-read',
      wf(block(['echo none']), '        run: echo none'),
      pkg({ text: 'export default {}\n' }),
      2,
      ['nothing to read'],
    ],
  ]
  let failed = 0
  const say = (ok, label, detail = '') => {
    if (!ok) failed++
    console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${ok ? '' : `\n       ${detail}`}`)
  }
  for (const [label, text, pkgs, want, needles] of cases) {
    const r = judge(text, pkgs)
    const got = r.cannot.length ? 2 : r.problems.length ? 1 : 0
    const out = [...r.cannot, ...r.problems].join('\n')
    const missing = needles.filter((s) => !out.includes(s))
    say(
      got === want && missing.length === 0,
      `${label} (exit ${want})`,
      `got exit ${got}; missing ${JSON.stringify(missing)}\n${out}`,
    )
  }
  // excludeUnlessNamed: a file is named plain, as ./…, or absolute; nothing else counts.
  const dir = '/w/js/packages/react'
  const FILES = ['tests/a.test.tsx', 'tests/b.test.ts']
  const argvCases = [
    ['no argument names a file: both left out', [], dir, FILES],
    ['plain tests/a.test.tsx names it', ['tests/a.test.tsx'], dir, ['tests/b.test.ts']],
    ['./tests/a.test.tsx names it', ['./tests/a.test.tsx'], dir, ['tests/b.test.ts']],
    ['an absolute path names it', [`${dir}/tests/a.test.tsx`], '/elsewhere', ['tests/b.test.ts']],
    [
      'a path relative to the cwd names it',
      ['packages/react/tests/a.test.tsx'],
      '/w/js',
      ['tests/b.test.ts'],
    ],
    ['a partial filter does not', ['a', 'tests/a', 'tests/a.test', 'a.test.tsx'], dir, FILES],
    [
      'another directory does not',
      ['/other/tests/a.test.tsx', 'tests/a.test.tsx'],
      '/other',
      FILES,
    ],
    ['an option value does not', ['--exclude=tests/a.test.tsx', '--dir'], dir, FILES],
  ]
  for (const [label, args, cwd, want] of argvCases) {
    const got = excludeUnlessNamed(FILES, ['node', 'vitest', 'run', ...args], dir, cwd)
    say(
      JSON.stringify(got) === JSON.stringify(want),
      `excludeUnlessNamed: ${label}`,
      `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
    )
  }
  const total = cases.length + argvCases.length
  if (failed) {
    console.error(`check-named-test-steps --selftest: ${failed} of ${total} rows FAILED`)
    return 1
  }
  console.log(`check-named-test-steps --selftest: all ${total} rows passed`)
  return 0
}

process.exitCode = selftest()

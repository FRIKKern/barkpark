// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Fixtures for check-named-test-steps.selftest.mjs: a workflow and a package
// config in memory, shaped like js-tests.yml and @barkpark/react's config.

import { jqLine } from './named-test-steps-workflow.mjs'

export const FLAGS = ' --reporter=default --reporter=json --outputFile.json="$report"'
export const named = (files) => `pnpm --filter @fix/react exec vitest run ${files}${FLAGS}`
// The two known whole forms, as js-tests.yml writes them.
export const MIRROR_LINES = [
  'report="$RUNNER_TEMP/m.json"',
  'rm -f "$report"',
  'set +e',
  `out="$(${named('tests/b.test.ts')} 2>&1)"`,
  'status=$?',
  'set -e',
  'echo "$out"',
  'case "$out" in',
  '  *"No projects matched the filters"*)',
  '    echo "mirror gate FAILED" >&2',
  '    exit 1',
  '    ;;',
  'esac',
  jqLine(['tests/b.test.ts']),
  'exit "$status"',
]
export const CONF_LINES = [
  'set -e',
  'report="$RUNNER_TEMP/c.json"',
  'rm -f "$report"',
  named('tests/a.test.tsx'),
  jqLine(['tests/a.test.tsx']),
]
export const block = (lines) => lines.map((l) => `          ${l}`).join('\n')
export const MIRROR = block(MIRROR_LINES)
export const CONF = `        run: |\n${block(CONF_LINES)}`
export const without = (lines, i) => lines.filter((_, k) => k !== i)
export const wf = (mirror, conf, extra = '') => `name: t
on:
  pull_request:
concurrency:
  group: t
jobs:
  test:
    name: Build
    runs-on: ubuntu-latest
    timeout-minutes: 40
    defaults:
      run:
        working-directory: js
    steps:
      - name: Mirror
        run: |
${mirror}
      - name: Conformance
${conf}
${extra}      - name: Test
        run: pnpm exec turbo run test \${{ steps.scope.outputs.filter }}
`
export const GOOD_WF = wf(MIRROR, CONF)
export const otherJob = (jobKeys) =>
  wf(MIRROR, '        run: echo moved').replace(
    'jobs:\n',
    `jobs:\n  other:\n${jobKeys}    steps:\n      - name: Elsewhere\n${CONF}\n`,
  )
export const cfg = (items) =>
  `import { configDefaults, defineConfig } from 'vitest/config'\nimport { excludeUnlessNamed } from '../../test-utils/named-step-files.mjs'\n\nconst NAMED_STEP_FILES = [${items}]\n\nexport default defineConfig({\n  test: {\n    exclude: [\n      ...configDefaults.exclude,\n      ...excludeUnlessNamed(NAMED_STEP_FILES, process.argv, import.meta.dirname),\n    ],\n  },\n})\n`
export const GOOD = cfg("'tests/a.test.tsx', 'tests/b.test.ts'")
export const ONE_LINE = GOOD.replace(
  /exclude: \[[^\]]*\]/,
  'exclude: [...configDefaults.exclude, ...excludeUnlessNamed(NAMED_STEP_FILES, process.argv, import.meta.dirname)]',
)
export const pkg = ({
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
export const PROOF = 'not one of the known whole forms with the run-time proof'
export const LINE = 'is not a `name:` or `run:` line'

export const ARGV_DIR = '/w/js/packages/react'
export const ARGV_FILES = ['tests/a.test.tsx', 'tests/b.test.ts']
// excludeUnlessNamed: a file is named plain, as ./…, or absolute; nothing else counts.
export const ARGV_CASES = [
  ['no argument names a file: both left out', [], ARGV_DIR, ARGV_FILES],
  ['plain tests/a.test.tsx names it', ['tests/a.test.tsx'], ARGV_DIR, ['tests/b.test.ts']],
  ['./tests/a.test.tsx names it', ['./tests/a.test.tsx'], ARGV_DIR, ['tests/b.test.ts']],
  [
    'an absolute path names it',
    [`${ARGV_DIR}/tests/a.test.tsx`],
    '/elsewhere',
    ['tests/b.test.ts'],
  ],
  [
    'a path relative to the cwd names it',
    ['packages/react/tests/a.test.tsx'],
    '/w/js',
    ['tests/b.test.ts'],
  ],
  [
    'a partial filter does not',
    ['a', 'tests/a', 'tests/a.test', 'a.test.tsx'],
    ARGV_DIR,
    ARGV_FILES,
  ],
  [
    'another directory does not',
    ['/other/tests/a.test.tsx', 'tests/a.test.tsx'],
    '/other',
    ARGV_FILES,
  ],
  ['an option value does not', ['--exclude=tests/a.test.tsx', '--dir'], ARGV_DIR, ARGV_FILES],
]

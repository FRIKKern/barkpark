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
import { jqLine } from './named-test-steps-workflow.mjs'

function selftest() {
  const FLAGS = ' --reporter=default --reporter=json --outputFile.json="$report"'
  const named = (files) => `pnpm --filter @fix/react exec vitest run ${files}${FLAGS}`
  // The two known whole forms, as js-tests.yml writes them.
  const MIRROR_LINES = [
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
  const CONF_LINES = [
    'set -e',
    'report="$RUNNER_TEMP/c.json"',
    'rm -f "$report"',
    named('tests/a.test.tsx'),
    jqLine(['tests/a.test.tsx']),
  ]
  const block = (lines) => lines.map((l) => `          ${l}`).join('\n')
  const MIRROR = block(MIRROR_LINES)
  const CONF = `        run: |\n${block(CONF_LINES)}`
  const without = (lines, i) => lines.filter((_, k) => k !== i)
  const wf = (mirror, conf, extra = '') => `name: t
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
  const GOOD_WF = wf(MIRROR, CONF)
  const otherJob = (jobKeys) =>
    wf(MIRROR, '        run: echo moved').replace(
      'jobs:\n',
      `jobs:\n  other:\n${jobKeys}    steps:\n      - name: Elsewhere\n${CONF}\n`,
    )
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
  const PROOF = 'not one of the known whole forms with the run-time proof'
  const LINE = 'is not a `name:` or `run:` line'
  const cases = [
    ['the good shape passes', GOOD_WF, pkg(), 0, []],
    ['the one-line exclude passes too', GOOD_WF, pkg({ text: ONE_LINE }), 0, []],
    [
      'old setup: both named files still run by the Test step',
      GOOD_WF,
      pkg({ text: 'export default {}\n' }),
      1,
      ['@fix/react tests/a.test.tsx: run by name', '@fix/react tests/b.test.ts: run by name'],
    ],
    [
      'a listed file no step runs is red by name',
      GOOD_WF,
      pkg({ text: cfg("'tests/a.test.tsx', 'tests/b.test.ts', 'tests/c.test.ts'") }),
      1,
      ['@fix/react tests/c.test.ts: listed in NAMED_STEP_FILES', 'nothing runs it'],
    ],
    [
      'a file named by two steps',
      wf(MIRROR, CONF, `      - name: Again\n${CONF}\n`),
      pkg(),
      1,
      ['tests/a.test.tsx: run by name by 2 steps'],
    ],
    [
      'a named file that does not exist',
      GOOD_WF,
      pkg({ files: ['tests/b.test.ts'] }),
      1,
      ['tests/a.test.tsx: run by name', 'does not exist'],
    ],
    [
      'a package no workspace has',
      wf(MIRROR, CONF.replace('@fix/react', '@fix/gone')),
      pkg(),
      1,
      ['names @fix/gone, which is no workspace package'],
    ],
    // The run block: one of the two known whole forms, each with its proof.
    [
      'the line form without its proof',
      wf(MIRROR, `        run: |\n${block(without(CONF_LINES, 4))}`),
      pkg(),
      2,
      ['step "Conformance"', PROOF],
    ],
    [
      'the captured form without its proof',
      wf(block(without(MIRROR_LINES, 13)), CONF),
      pkg(),
      2,
      ['step "Mirror"', PROOF],
    ],
    [
      'the proof read for another file',
      wf(MIRROR, CONF.replace(jqLine(['tests/a.test.tsx']), jqLine(['tests/b.test.ts']))),
      pkg(),
      2,
      [PROOF],
    ],
    [
      'the known line in a block that ends 0',
      wf(MIRROR, `        run: |\n${block(['set +e', named('tests/a.test.tsx'), 'exit 0'])}`),
      pkg(),
      2,
      [PROOF],
    ],
    [
      'the captured form without its last line',
      wf(block(MIRROR_LINES.slice(0, -1)), CONF),
      pkg(),
      2,
      [PROOF],
    ],
    [
      'the captured form with a line after its last',
      wf(block([...MIRROR_LINES, 'exit 0']), CONF),
      pkg(),
      2,
      [PROOF],
    ],
    [
      'the known line without the report flags',
      wf(MIRROR, `        run: pnpm --filter @fix/react exec vitest run tests/a.test.tsx`),
      pkg(),
      2,
      ['shape this script cannot read'],
    ],
    // Every line of a named step is `- name:`, `name:`, `run:` or a run-block line.
    [
      'a line after an inline run value',
      wf(MIRROR, `        run: ${named('tests/a.test.tsx')}\n          || true`),
      pkg(),
      2,
      ['step "Conformance"', LINE],
    ],
    [
      'a quoted key in a named step',
      wf(MIRROR, `        "working-directory": /tmp\n${CONF}`),
      pkg(),
      2,
      ['step "Conformance"', LINE],
    ],
    [
      'a spaced or ? key in a named step',
      wf(MIRROR, `        working-directory : /tmp\n        ? shell\n        : sh\n${CONF}`),
      pkg(),
      2,
      ['step "Conformance"', LINE],
    ],
    [
      'a quoted job key',
      GOOD_WF.replace(
        '    defaults:\n      run:\n        working-directory: js\n',
        '    "defaults":\n      run:\n        working-directory: /tmp\n',
      ),
      pkg(),
      2,
      ['a line this script cannot place: "defaults":'],
    ],
    // The frame: workflow keys, job keys, job defaults, named step keys.
    [
      'a job env',
      GOOD_WF.replace(
        '    timeout-minutes: 40\n',
        '    timeout-minutes: 40\n    env:\n      NPM_CONFIG_WORKSPACE_DIR: /tmp\n',
      ),
      pkg(),
      2,
      ['step "Conformance"', 'its job "test" has keys'],
    ],
    [
      'a workflow env',
      GOOD_WF.replace('jobs:\n', 'env:\n  NPM_CONFIG_WORKSPACE_DIR: /tmp\njobs:\n'),
      pkg(),
      2,
      ['top-level keys are'],
    ],
    [
      'the workflow adds a defaults block',
      GOOD_WF.replace('jobs:\n', 'defaults:\n  run:\n    shell: bash {0}\njobs:\n'),
      pkg(),
      2,
      ['top-level keys are'],
    ],
    [
      'the job defaults set another working directory',
      GOOD_WF.replace('working-directory: js', 'working-directory: js/packages'),
      pkg(),
      2,
      ['step "Mirror"', 'step "Conformance"', 'defaults block other than'],
    ],
    [
      'the job defaults add a shell',
      GOOD_WF.replace('working-directory: js', 'working-directory: js\n        shell: bash {0}'),
      pkg(),
      2,
      ['defaults block other than'],
    ],
    [
      'a named step with a shell key',
      wf(MIRROR, `        shell: bash {0}\n${CONF}`),
      pkg(),
      2,
      ['step "Conformance"', 'it has name, shell, run'],
    ],
    [
      'a named step with a working-directory key',
      wf(MIRROR, `        working-directory: js/packages/react\n${CONF}`),
      pkg(),
      2,
      ['it has name, working-directory, run'],
    ],
    [
      'a named step with if:',
      wf(MIRROR, `        if: github.event_name == 'push'\n${CONF}`),
      pkg(),
      2,
      ['it has name, if, run'],
    ],
    [
      'a named step with continue-on-error',
      wf(MIRROR, `        continue-on-error: true\n${CONF}`),
      pkg(),
      2,
      ['it has name, continue-on-error, run'],
    ],
    [
      'a named step in another job',
      otherJob('    runs-on: ubuntu-latest\n'),
      pkg(),
      2,
      ['step "Elsewhere"', "not in the Test step's job"],
    ],
    [
      'a named step in a job with if:',
      otherJob("    if: github.event_name == 'push'\n"),
      pkg(),
      2,
      ['step "Elsewhere"', "not in the Test step's job"],
    ],
    [
      'a step writes GITHUB_ENV or GITHUB_PATH',
      wf(
        MIRROR,
        CONF,
        '      - name: Env\n        run: echo "X=/tmp" >> "$GITHUB_ENV"\n      - name: Path\n        run: echo /tmp/bin >> "$GITHUB_PATH"\n',
      ),
      pkg(),
      2,
      ['step "Env"', 'step "Path"', 'names GITHUB_ENV or GITHUB_PATH'],
    ],
    // Any other run line that starts a test runner on a named file.
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
      wf(MIRROR, `        run: ${named('conformance')}`),
      pkg(),
      2,
      ['cannot read'],
    ],
    [
      './ in the step is cannot-read',
      wf(MIRROR, `        run: ${named('./tests/a.test.tsx')}`),
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
      GOOD_WF.replace(
        '    runs-on: ubuntu-latest\n',
        '    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        file: [tests/d.test.ts]\n',
      ),
      pkg(),
      2,
      ['outside a run line'],
    ],
    // The package side.
    [
      '--exclude in the test script is cannot-read',
      GOOD_WF,
      pkg({ script: 'vitest run --exclude tests/a.test.tsx' }),
      2,
      ['uses --exclude'],
    ],
    [
      'a named file excluded another way is cannot-read',
      GOOD_WF,
      pkg({
        text: "export default { test: { exclude: ['tests/a.test.tsx', 'tests/b.test.ts'] } }\n",
      }),
      2,
      ['some other way'],
    ],
    [
      'a list built by code is cannot-read',
      GOOD_WF,
      pkg({ text: GOOD.replace("'tests/a.test.tsx', 'tests/b.test.ts'", '...OTHER') }),
      2,
      ['not a plain quoted test file path'],
    ],
    [
      'dropping configDefaults is cannot-read',
      GOOD_WF,
      pkg({ text: GOOD.replace(/\s*\.\.\.configDefaults\.exclude,/, '') }),
      2,
      ['is not written as'],
    ],
    [
      'a list in a config the test script does not load',
      GOOD_WF,
      pkg({
        text: 'export default {}\n',
        extraConfig: { file: 'vitest.browser.config.ts', isDefault: false, text: GOOD },
      }),
      2,
      ['does not load'],
    ],
    [
      'no single Test step is cannot-read',
      GOOD_WF.replace('turbo run test', 'turbo run lint'),
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

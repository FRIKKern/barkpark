#!/usr/bin/env node
// Coverage gate for turbo's `size` and `test` tasks.
//
// WHY THIS EXISTS (task-3cd40ebba5ab106a, task-d4c973367c0d1a76).
// `turbo run <task>` scores a package with NO SCRIPT for that task as a
// SUCCESS. It is not a bug in turbo — there is nothing to run — but it means
// the "N successful, N total" line is a count of OPTED-IN packages, never a
// statement about the workspace. Two measured consequences on
// 6744725c58d6657b0e90e4767ee17e938b87cf9e:
//
//   size: a 4000-key exported object appended to packages/nextjs-query/src/
//         index.ts took dist/index.mjs from 291 B to 238114 B.
//         `pnpm exec turbo run size --filter='!@barkpark/react' --force`
//         -> "Tasks: 14 successful, 14 total", EXIT=0.
//   test: packages/w3probe with a deliberately failing test file, no `test`
//         script and no vitest.config.ts.
//         `pnpm exec turbo run test --force` -> "20 successful, 20 total",
//         EXIT=0, and `node scripts/check-vitest-projects.mjs` -> OK.
//
// So this gate is derived from the PACKAGE SET (scripts/workspace-packages.mjs)
// and never from which packages declare a script — that set is the defect. The
// rules below are predicates over each manifest. There is no allowlist of
// package names anywhere in this file, on purpose: an enumeration is a
// snapshot, a predicate is a rule, and the hole above is exactly what a
// snapshot misses.
//
// RULES
//   SIZE  every PUBLISHED package that ships a dist payload and is not a
//         bin-only CLI must have BOTH a `size` script and a size-limit config.
//   TEST  every package that ships *.test.* / *.spec.* files must have BOTH a
//         `test` script and a vitest config (the config is what makes it
//         declarable to js/vitest.config.mts, which is what the execution
//         floor in check-vitest-projects.mjs guards).
//
// EXIT CODES
//   0  every rule satisfied
//   1  one or more packages violate a rule (each is NAMED)
//   2  HARNESS failure — the package set could not be derived, or is empty.
//      A pass over an empty set is the failure mode this gate exists to catch,
//      so it is never reported as a pass.
//
// SELFTEST. `--selftest` plants synthetic package trees on disk in a throwaway
// directory and asserts each rule both FIRES and stays QUIET where it should,
// plus the empty-set positive control. It never touches the real workspace.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  DerivationError,
  needsSizeBudget,
  needsTestExecution,
  workspacePackages,
} from './workspace-packages.mjs'

/** Pure over the derived records: returns one violation per broken rule. */
export function violations(packages) {
  const out = []
  for (const p of packages) {
    if (needsSizeBudget(p)) {
      if (!p.hasSizeScript) {
        out.push({
          rule: 'SIZE',
          code: 'NO_SIZE_SCRIPT',
          package: p.name,
          detail:
            `is published (private is not true) and ships a dist payload, but declares no ` +
            `\`size\` script — so \`turbo run size\` scores it as a success having measured ` +
            `NOTHING. Add "size": "size-limit" and a .size-limit.json with a MEASURED ceiling.`,
        })
      } else if (!p.hasSizeLimitConfig) {
        out.push({
          rule: 'SIZE',
          code: 'NO_SIZE_CEILING',
          package: p.name,
          detail:
            `declares a \`size\` script but carries no size-limit config, so the script has ` +
            `no ceiling to enforce. Add .size-limit.json.`,
        })
      }
    }
    if (needsTestExecution(p)) {
      if (!p.hasTestScript) {
        out.push({
          rule: 'TEST',
          code: 'NO_TEST_SCRIPT',
          package: p.name,
          detail:
            `ships ${p.testFiles.length} test file(s) (e.g. ${p.testFiles[0]}) but declares no ` +
            `\`test\` script, so \`turbo run test\` counts it as a success having executed ZERO ` +
            `of them. Add "test": "vitest run".`,
        })
      }
      if (!p.hasVitestConfig) {
        out.push({
          rule: 'TEST',
          code: 'NO_VITEST_CONFIG',
          package: p.name,
          detail:
            `ships ${p.testFiles.length} test file(s) but has no vitest config, so it is not ` +
            `declarable to js/vitest.config.mts and the execution floor in ` +
            `check-vitest-projects.mjs cannot see it. Add vitest.config.ts.`,
        })
      }
    }
  }
  return out
}

function report(packages) {
  const sized = packages.filter(needsSizeBudget)
  const tested = packages.filter(needsTestExecution)
  console.log(
    `check-turbo-task-coverage: ${packages.length} workspace package(s) derived from ` +
      `pnpm-workspace.yaml`,
  )
  console.log(
    `  SIZE rule applies to ${sized.length}: ${sized.map((p) => p.name).join(', ') || '(none)'}`,
  )
  console.log(
    `  TEST rule applies to ${tested.length}: ${tested.map((p) => p.name).join(', ') || '(none)'}`,
  )
  const v = violations(packages)
  if (v.length === 0) {
    console.log('check-turbo-task-coverage: OK — every applicable package opts into its task.')
    return 0
  }
  console.error('')
  for (const x of v) {
    console.error(`check-turbo-task-coverage: ${x.rule} ${x.code} — ${x.package} ${x.detail}`)
  }
  console.error('')
  console.error(
    `check-turbo-task-coverage: FAILED — ${v.length} coverage violation(s). turbo would have ` +
      `reported "N successful, N total" for every one of them.`,
  )
  return 1
}

// ---------------------------------------------------------------------------
// SELFTEST

function plant(root, name, { manifest, files = [] }) {
  const dir = join(root, 'packages', name)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'package.json'), JSON.stringify(manifest, null, 2))
  for (const f of files) {
    const full = join(dir, f)
    mkdirSync(join(full, '..'), { recursive: true })
    writeFileSync(full, '// selftest specimen\n')
  }
  return dir
}

function makeWorkspace() {
  const root = mkdtempSync(join(tmpdir(), 'turbo-cov-selftest-'))
  mkdirSync(join(root, 'packages'), { recursive: true })
  writeFileSync(join(root, 'pnpm-workspace.yaml'), "packages:\n  - 'packages/*'\n")
  return root
}

const CONFORMING_LIB = {
  manifest: {
    name: 'ok-lib',
    main: './dist/index.cjs',
    files: ['dist'],
    scripts: { size: 'size-limit', test: 'vitest run' },
  },
  files: ['.size-limit.json', 'vitest.config.ts', 'tests/a.test.ts'],
}

function selftest() {
  const cases = [
    {
      arm: 'EMPTY SET (positive control) — a gate over no packages must refuse, not pass',
      plant: () => [],
      expect: { harness: true },
    },
    {
      arm: 'SIZE fires: published + dist payload + no `size` script',
      plant: () => [
        CONFORMING_LIB,
        {
          manifest: { name: 'unbudgeted', private: false, files: ['dist'] },
          files: [],
        },
      ],
      expect: { codes: ['NO_SIZE_SCRIPT'], package: 'unbudgeted' },
    },
    {
      arm: 'SIZE fires: `size` script present but no ceiling file',
      plant: () => [
        CONFORMING_LIB,
        {
          manifest: { name: 'ceilingless', files: ['dist'], scripts: { size: 'size-limit' } },
          files: [],
        },
      ],
      expect: { codes: ['NO_SIZE_CEILING'], package: 'ceilingless' },
    },
    {
      arm: 'SIZE quiet: a PRIVATE package ships no bytes to a consumer',
      plant: () => [
        CONFORMING_LIB,
        { manifest: { name: 'priv', private: true, files: ['dist'] }, files: [] },
      ],
      expect: { codes: [] },
    },
    {
      arm: 'SIZE quiet: a bin-only CLI has no importable entry (carve-out must stay narrow)',
      plant: () => [
        CONFORMING_LIB,
        {
          manifest: { name: 'cli', files: ['dist'], bin: { cli: './dist/index.js' } },
          files: [],
        },
      ],
      expect: { codes: [] },
    },
    {
      arm: 'SIZE fires: a CLI that ALSO exports a library entry is not carved out',
      plant: () => [
        CONFORMING_LIB,
        {
          manifest: {
            name: 'cli-plus-lib',
            files: ['dist'],
            bin: { cli: './dist/cli.js' },
            main: './dist/index.cjs',
          },
          files: [],
        },
      ],
      expect: { codes: ['NO_SIZE_SCRIPT'], package: 'cli-plus-lib' },
    },
    {
      arm: 'TEST fires: ships a test file, declares no `test` script (the w3probe shape)',
      plant: () => [
        CONFORMING_LIB,
        {
          manifest: { name: 'w3probe-shape', private: true, scripts: { build: 'tsup' } },
          files: ['tests/broken.test.ts'],
        },
      ],
      expect: { codes: ['NO_TEST_SCRIPT', 'NO_VITEST_CONFIG'], package: 'w3probe-shape' },
    },
    {
      arm: 'TEST fires: `test` script present but no vitest config (undeclarable to the floor)',
      plant: () => [
        CONFORMING_LIB,
        {
          manifest: { name: 'unconfigured', private: true, scripts: { test: 'vitest run' } },
          files: ['tests/a.test.ts'],
        },
      ],
      expect: { codes: ['NO_VITEST_CONFIG'], package: 'unconfigured' },
    },
    {
      arm: 'TEST quiet: a package that ships no test files is not asked for a suite',
      plant: () => [
        CONFORMING_LIB,
        { manifest: { name: 'no-tests', private: true }, files: ['src/index.ts'] },
      ],
      expect: { codes: [] },
    },
    {
      arm: 'GREEN IS REACHABLE: a fully conforming package violates nothing',
      plant: () => [CONFORMING_LIB],
      expect: { codes: [] },
    },
  ]

  let failed = 0
  for (const c of cases) {
    const root = makeWorkspace()
    try {
      let n = 0
      for (const spec of c.plant()) plant(root, spec.manifest.name ?? `p${n++}`, spec)
      let got
      let harness = false
      try {
        got = violations(workspacePackages(root))
      } catch (err) {
        if (!(err instanceof DerivationError)) throw err
        harness = true
      }
      if (c.expect.harness) {
        if (harness) console.log(`  PASS  ${c.arm}`)
        else {
          failed += 1
          console.error(`  FAIL  ${c.arm}\n        expected a HARNESS refusal, got a verdict`)
        }
        continue
      }
      if (harness) {
        failed += 1
        console.error(`  FAIL  ${c.arm}\n        unexpected HARNESS refusal`)
        continue
      }
      const relevant = c.expect.package ? got.filter((v) => v.package === c.expect.package) : got
      const codes = relevant.map((v) => v.code).sort()
      const want = [...c.expect.codes].sort()
      if (JSON.stringify(codes) === JSON.stringify(want)) {
        console.log(`  PASS  ${c.arm}`)
      } else {
        failed += 1
        console.error(
          `  FAIL  ${c.arm}\n        expected [${want.join(', ')}], got [${codes.join(', ')}]`,
        )
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }
  console.log('')
  if (failed > 0) {
    console.error(`check-turbo-task-coverage --selftest: ${failed} of ${cases.length} arm(s) FAILED`)
    return 1
  }
  console.log(`check-turbo-task-coverage --selftest: all ${cases.length} arm(s) passed`)
  return 0
}

// ---------------------------------------------------------------------------

const isSelftest = process.argv.slice(2).includes('--selftest')
try {
  process.exit(isSelftest ? selftest() : report(workspacePackages(process.cwd())))
} catch (err) {
  if (err instanceof DerivationError) {
    console.error(`check-turbo-task-coverage: HARNESS FAILURE — ${err.message}`)
    process.exit(2)
  }
  throw err
}

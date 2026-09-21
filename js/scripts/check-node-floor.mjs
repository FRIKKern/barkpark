#!/usr/bin/env node
// The Node major the js-tests job pins must satisfy the engines floor js/package.json
// declares, and the floor must be one the root vitest config can actually load under.
//
// WHY THIS EXISTS (task-a9c4b827881d71bd). #19113 made js/vitest.config.mts a Node 22
// config (fs.globSync, and a native dynamic import() of each package's .ts config,
// which Node strips types for only from 22.6). js-tests.yml kept pinning Node 20 and
// engines.node kept saying >=20, so every js-tests run from 2026-09-17 on died at
// config load with HARNESS FAILURE before its first test — and that early death
// buried the @barkpark/react size-budget red the job already carried. Nothing
// connected the two numbers; this connects them.
//
// Checks, all derived from the files (no version literal lives here):
//   1. every `node-version:` under a setup-node step in .github/workflows/js-tests.yml
//      satisfies js/package.json engines.node;
//   2. there is at least one such pin (an empty read is a red, never a pass);
//   3. the floor itself is >= the lowest major the root config needs, declared ONCE
//      in js/package.json as `barkpark.vitestConfigNodeFloor` — the config's own
//      requirement, kept beside the engines field it constrains.
//
// Selftest (`--selftest`) proves each check can lose against a fixture copy.
import { readFileSync, mkdtempSync, writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const jsRoot = resolve(here, '..')
const repoRoot = resolve(jsRoot, '..')

function readPins(workflowText) {
  // Every `node-version:` that follows a `uses: actions/setup-node` within its step.
  const lines = workflowText.split('\n')
  const pins = []
  let inSetupNode = false
  for (const line of lines) {
    if (/^\s*-\s+(name|uses):/.test(line) || /^\s*-\s+/.test(line)) inSetupNode = /actions\/setup-node/.test(line)
    else if (/^\s*uses:\s*actions\/setup-node/.test(line)) inSetupNode = true
    const m = line.match(/^\s*node-version:\s*["']?([0-9]+)(?:\.[0-9x.]+)?["']?\s*$/)
    if (m && inSetupNode) pins.push(Number(m[1]))
  }
  return pins
}

function floorOf(range) {
  // engines.node in this repo is a single ">=N" (or ">=N.x") floor. Anything else is
  // refused rather than guessed at.
  const m = String(range).trim().match(/^>=\s*([0-9]+)(?:\.[0-9]+)*$/)
  if (!m) throw new Error(`engines.node "${range}" is not a plain >=MAJOR floor; this check refuses to guess`)
  return Number(m[1])
}

function check({ workflowText, pkg }) {
  const problems = []
  const pins = readPins(workflowText)
  if (pins.length === 0) problems.push('js-tests.yml: found ZERO setup-node node-version pins — an empty read is not a pass')
  let floor
  try {
    floor = floorOf(pkg?.engines?.node)
  } catch (e) {
    problems.push(`js/package.json: ${e.message}`)
  }
  const configFloor = Number(pkg?.barkpark?.vitestConfigNodeFloor)
  if (!Number.isInteger(configFloor)) problems.push('js/package.json: barkpark.vitestConfigNodeFloor is missing — the root vitest config must declare the Node major it needs')
  if (floor !== undefined) {
    for (const pin of pins) if (pin < floor) problems.push(`js-tests.yml pins Node ${pin}, below engines.node floor >=${floor}`)
    if (Number.isInteger(configFloor) && floor < configFloor) problems.push(`js/package.json engines.node >=${floor} admits a Node major the root vitest config cannot load under (it needs >=${configFloor})`)
  }
  return { pins, floor, configFloor, problems }
}

function live() {
  const workflowText = readFileSync(join(repoRoot, '.github/workflows/js-tests.yml'), 'utf8')
  const pkg = JSON.parse(readFileSync(join(jsRoot, 'package.json'), 'utf8'))
  return check({ workflowText, pkg })
}

function selftest() {
  const base = live()
  if (base.problems.length) {
    console.error('check-node-floor: SELFTEST cannot start — the live tree is already red:\n  ' + base.problems.join('\n  '))
    return 2
  }
  const workflowText = readFileSync(join(repoRoot, '.github/workflows/js-tests.yml'), 'utf8')
  const pkg = JSON.parse(readFileSync(join(jsRoot, 'package.json'), 'utf8'))
  const arms = [
    {
      name: 'workflow pins a major below the floor',
      run: () => check({ workflowText: workflowText.replace(/node-version:\s*"?\d+"?/, 'node-version: "18"'), pkg }),
      expect: /below engines\.node floor/,
    },
    {
      name: 'engines floor moves above the workflow pin',
      run: () => check({ workflowText, pkg: { ...pkg, engines: { ...pkg.engines, node: `>=${Math.max(...base.pins) + 2}` } } }),
      expect: /below engines\.node floor/,
    },
    {
      name: 'engines floor drops below what the config needs',
      run: () => check({ workflowText, pkg: { ...pkg, engines: { ...pkg.engines, node: `>=${base.configFloor - 2}` } } }),
      expect: /cannot load under/,
    },
    {
      name: 'workflow with no setup-node pins',
      run: () => check({ workflowText: workflowText.replace(/node-version:.*\n/g, ''), pkg }),
      expect: /ZERO setup-node/,
    },
    {
      name: 'config floor declaration missing',
      run: () => check({ workflowText, pkg: { ...pkg, barkpark: {} } }),
      expect: /vitestConfigNodeFloor is missing/,
    },
    {
      name: 'live tree (positive control: green, with pins read)',
      run: () => base,
      expect: null,
    },
  ]
  let failed = 0
  for (const arm of arms) {
    const r = arm.run()
    const ok = arm.expect ? r.problems.some((p) => arm.expect.test(p)) : r.problems.length === 0 && r.pins.length > 0
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${arm.name}${ok ? '' : ' -> ' + JSON.stringify(r.problems)}`)
    if (!ok) failed++
  }
  console.log(`check-node-floor: selftest ${failed ? 'FAILED' : 'PASS'} (${arms.length - failed}/${arms.length})`)
  return failed ? 1 : 0
}

if (process.argv.includes('--selftest')) process.exit(selftest())
const r = live()
if (r.problems.length) {
  console.error('check-node-floor: RED\n  ' + r.problems.join('\n  '))
  process.exit(1)
}
console.log(`check-node-floor: OK — js-tests.yml pins Node ${[...new Set(r.pins)].join(',')}; engines.node >=${r.floor}; root vitest config needs >=${r.configFloor}`)

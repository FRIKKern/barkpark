#!/usr/bin/env node
// Coverage gate for js/scripts/: every script here must be REACHABLE FROM A CI
// WORKFLOW STEP, or carry an explicit waiver with a reason.
//
// WHY THIS EXISTS. js/scripts/check-no-node-imports.selftest.sh sat in this
// directory with no caller anywhere in the repo and rotted until 10 of its 13
// cases failed, while reading — to anyone grepping — like a second layer of
// proof for the edge-import guard. Nothing noticed, because the two repo
// censuses that hunt this class (shell-harnesses.yml,
// posix-vacuous-green-census.yml) are scoped to the ROOT scripts/ directory and
// cannot see js/scripts/ at all.
//
// THE ENUMERATION IS A PREDICATE, NOT A LIST, AND NOT A KEYWORD.
//
//   * NOT A LIST — nothing here names the files it guards. The population is
//     "every script-extension file under js/scripts/", derived from the tree on
//     every run, so a new harness is covered the day it lands and no snapshot
//     can fall behind. A hand-written enumeration is exactly what rotted the
//     orphan: its CORPUS=(...) of six directories went three dirs stale against
//     the guard's derived corpus and every specimen arm died at exit 3.
//
//   * NOT A KEYWORD — this does not grep for the word "selftest". A repo sweep
//     for that word misses a tripwire whose step is named "Prove the glass can
//     be shown open", and would also miss a harness named `verify-*.mjs`. The
//     question asked of every file is behavioural — does anything RUN it? — and
//     a file's name has no bearing on the answer.
//
// WHAT COUNTS AS AN INVOKER, and what deliberately does not:
//
//   WIRED            a `run:` block in a repo-root .github/workflows/*.yml
//                    names the file's path.
//   WIRED (package)  a package.json `scripts` entry names the file AND that
//                    script's name is itself run from a workflow (`pnpm <name>`,
//                    `turbo run <name>`, ...). A DECLARATION IS NOT AN INVOCATION:
//                    js/package.json has declared `selftest:changesets` for
//                    months and no workflow ever ran it. That shape is an ORPHAN
//                    here, reported with the declaration quoted, precisely so it
//                    cannot hide behind looking wired.
//   LIBRARY          the file exports and is imported by another enumerated
//                    file that is itself reachable. Transitive, computed to a
//                    fixed point — workspace-packages.mjs is never executed and
//                    must not be demanded to be.
//   WAIVED           an explicit row below, with a reason and a task. Printed
//                    LOUDLY on every run, never silently skipped, and a waiver
//                    that has gone stale (names a file that is now wired, or no
//                    longer exists) is itself reported — a waiver list is an
//                    enumeration too, and this one is not allowed to rot either.
//
//   NOT AN INVOKER: `js/.github/workflows/`. GitHub Actions reads workflows only
//   from `.github/workflows/` at the REPOSITORY ROOT; that nested tree is inert
//   and says so in its own header. A file whose ONLY reference lives there is
//   reported as PHANTOM — strictly worse than having no caller, because it reads
//   like it has one.
//
//   TEETH: a file that declares a `--selftest` mode must be invoked WITH that
//   flag by some workflow step. A harness wired only in its plain mode has its
//   proof-of-teeth un-run, which is the same defect one level down.
//
// THE POSITIVE CONTROL IS NOT OPTIONAL. A coverage guard whose scan finds
// nothing passes every assertion below it and prints a clean bill of health for
// a directory it never opened. `--selftest` therefore points THIS SAME audit
// function at a fixture tree holding a known orphan of every shape and requires
// it to NAME each one, to clear the two reachable files without a false
// positive, and — the direction that makes the rest load-bearing — to STOP
// naming an orphan once the fixture gains a step that runs it.
//
// Usage: node js/scripts/check-harness-wiring.mjs             # the audit
//        node js/scripts/check-harness-wiring.mjs --selftest  # prove it can see
//
// Exit codes, kept distinct so a failed READ is never a clean read:
//   0  every script under js/scripts/ is reachable or waived.
//   1  at least one orphan, phantom, un-run selftest mode, or stale waiver.
//   3  HARNESS FAILURE: the scan could not read its population.
//  64  bad usage.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const JS_ROOT = path.resolve(HERE, '..')
const REPO_ROOT = path.resolve(JS_ROOT, '..')

const EXIT_PROBLEM = 1
const EXIT_HARNESS = 3
const EXIT_USAGE = 64

// A file is a script by EXTENSION, a property of the tree, not of its name.
const SCRIPT_EXTS = new Set(['.sh', '.bash', '.mjs', '.cjs', '.js', '.ts'])

// The floor is the one expectation that does NOT come from the tree it
// measures. A derived population agrees with an emptied directory by
// construction: delete every script and the scan happily audits nothing and
// calls it clean. This literal is what makes that a refusal instead.
const POPULATION_FLOOR = 5

// ── WAIVERS ──────────────────────────────────────────────────────────────────
// Each row needs a reason a reader can check and a task to argue with. Printed
// on every run. A row that no longer applies REDS (see stale-waiver handling).
const WAIVERS = [
  // EMPTY, and that is a RESULT, not a default. The one row here waived
  // vercel-preview-smoke.sh — a stub that echoed "stub (Phase 5)" and exited 0
  // for every input, whose ONLY reference was js/.github/workflows/vercel-preview.yml,
  // a file in the INERT nested workflow tree GitHub never reads. Both are
  // DELETED (task-7a49b8c2e3104aa2): a gate that cannot fail, wired to a
  // workflow that cannot run, is not debt to be waived — it is a false entry in
  // the repo's inventory of what is checked, and the honest close was to remove
  // it rather than keep explaining it.
  //
  // The nested-workflow CLASS is now closed one level up by
  // scripts/workflow-root-only-check.sh, run from .github/workflows/pr-meta.yml:
  // a second js/.github/workflows/ cannot be added silently, so no future script
  // can acquire a phantom caller of that shape and land back in this list.
  //
  // An empty waiver list is the goal state, not an invitation. A new row still
  // needs a reason a reader can check and a task to argue with, and it still
  // prints LOUDLY on every run.
]

// ── reading the world ────────────────────────────────────────────────────────

function listScripts(dir) {
  const out = []
  const walk = (abs, rel) => {
    let entries
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true })
    } catch (e) {
      throw new HarnessError(`cannot read script directory ${abs}: ${e.message}`)
    }
    for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const childRel = rel ? `${rel}/${e.name}` : e.name
      if (e.isDirectory()) {
        if (e.name === 'node_modules' || e.name.startsWith('.')) continue
        walk(path.join(abs, e.name), childRel)
      } else if (e.isFile() && SCRIPT_EXTS.has(path.extname(e.name))) {
        out.push(childRel)
      }
    }
  }
  walk(dir, '')
  return out
}

class HarnessError extends Error {}

// Collect every `run:` body from a workflow file, with the step name that owns
// it. Deliberately a text scan and not a YAML parse: the thing being looked for
// IS a literal command string, and adding a YAML dependency to a guard that
// must run before install would be a new way for it to fail.
function runBlocks(text, file) {
  const lines = text.split('\n')
  const blocks = []
  let stepName = '(unnamed step)'
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const nameM = line.match(/^\s*-?\s*name:\s*(.+?)\s*$/)
    if (nameM) stepName = nameM[1].replace(/^['"]|['"]$/g, '')
    const inlineM = line.match(/^(\s*)-?\s*run:\s*(\S.*)$/)
    if (inlineM && !/^\s*[|>]/.test(inlineM[2])) {
      blocks.push({ file, step: stepName, text: inlineM[2] })
      continue
    }
    const blockM = line.match(/^(\s*)-?\s*run:\s*[|>][-+]?\s*$/)
    if (blockM) {
      const indent = blockM[1].length
      const body = []
      for (let j = i + 1; j < lines.length; j++) {
        const l = lines[j]
        if (l.trim() === '') { body.push(''); continue }
        const lead = l.length - l.trimStart().length
        if (lead <= indent) break
        body.push(l)
      }
      blocks.push({ file, step: stepName, text: body.join('\n') })
    }
  }
  return blocks
}

function readWorkflowDir(dir) {
  let names
  try {
    names = fs.readdirSync(dir).filter((n) => /\.ya?ml$/.test(n)).sort()
  } catch {
    return []
  }
  const blocks = []
  for (const n of names) {
    const text = fs.readFileSync(path.join(dir, n), 'utf8')
    blocks.push(...runBlocks(text, path.relative(REPO_ROOT, path.join(dir, n)) || n))
  }
  return blocks
}

function readManifests(roots) {
  const out = []
  for (const abs of roots) {
    let raw
    try {
      raw = fs.readFileSync(abs, 'utf8')
    } catch {
      continue
    }
    let json
    try {
      json = JSON.parse(raw)
    } catch (e) {
      throw new HarnessError(`cannot parse ${abs}: ${e.message}`)
    }
    out.push({
      file: path.relative(REPO_ROOT, abs) || abs,
      scripts: json.scripts && typeof json.scripts === 'object' ? json.scripts : {},
    })
  }
  return out
}

function manifestRoots(jsRoot) {
  const roots = [path.join(jsRoot, 'package.json')]
  // packages/* and the private parity harnesses in test-harnesses/* are both
  // workspace member roots (js/pnpm-workspace.yaml).
  for (const memberRoot of ['packages', 'test-harnesses']) {
    const pkgDir = path.join(jsRoot, memberRoot)
    let entries = []
    try {
      entries = fs.readdirSync(pkgDir, { withFileTypes: true })
    } catch {
      entries = []
    }
    for (const e of entries) {
      if (e.isDirectory()) roots.push(path.join(pkgDir, e.name, 'package.json'))
    }
  }
  return roots
}

// Every task name a workflow actually RUNS. This is what separates a declared
// package script from an invoked one.
function ciTaskNames(blocks) {
  const names = new Set()
  for (const b of blocks) {
    for (const m of b.text.matchAll(
      /\b(?:pnpm|npm|yarn)\b(?:\s+(?:exec|-r|--recursive|--filter[=\s]\S+))*\s+(?:run\s+)?(?:turbo\s+run\s+)?([A-Za-z0-9:_-]+)/g,
    )) {
      names.add(m[1])
    }
    for (const m of b.text.matchAll(/\bturbo\s+run\s+([A-Za-z0-9:_-]+)/g)) names.add(m[1])
  }
  return names
}

// ── the audit ────────────────────────────────────────────────────────────────
//
// `world` is everything the audit reads, passed in rather than looked up, so
// --selftest drives THIS function over a fixture tree instead of a second
// implementation that could agree with the first while both are wrong.

function audit(world) {
  const { scriptsDir, pathPrefixes, workflowBlocks, phantomBlocks, manifests, waivers, floor } =
    world

  const files = listScripts(scriptsDir)
  if (files.length < floor) {
    throw new HarnessError(
      `the derived population is ${files.length} script(s), floor is ${floor} — ` +
        `${scriptsDir} was renamed, emptied, or this is the wrong working directory. ` +
        `Refusing to audit an empty population and report it clean.`,
    )
  }

  const needles = (rel) => pathPrefixes.map((p) => `${p}${rel}`)
  const sources = new Map()
  for (const rel of files) sources.set(rel, fs.readFileSync(path.join(scriptsDir, rel), 'utf8'))

  // Shape test, not a name test: does the file's own argv dispatch declare a
  // --selftest mode?
  const declaresSelftest = (src) =>
    /--selftest\)/.test(src) || /argv[^\n]*--selftest/.test(src) || /'--selftest'|"--selftest"/.test(src)

  const hit = (text, rel) => needles(rel).some((n) => text.includes(n))

  const rows = []
  for (const rel of files) {
    const src = sources.get(rel)
    const wf = workflowBlocks.filter((b) => hit(b.text, rel))
    const phantom = phantomBlocks.filter((b) => hit(b.text, rel))
    const decls = []
    for (const m of manifests) {
      for (const [name, body] of Object.entries(m.scripts)) {
        if (hit(body, rel)) decls.push({ manifest: m.file, name, body })
      }
    }
    rows.push({
      file: rel,
      src,
      wf,
      phantom,
      decls,
      selftestMode: declaresSelftest(src),
      importers: [],
      status: null,
      via: null,
    })
  }

  // Library edges: an enumerated file importing a sibling by relative path.
  const byBase = new Map(rows.map((r) => [path.basename(r.file), r]))
  for (const r of rows) {
    for (const m of r.src.matchAll(/(?:from|import|require)\s*\(?\s*['"](\.\.?\/[^'"]+)['"]/g)) {
      const target = byBase.get(path.basename(m[1]))
      if (target && target !== r) target.importers.push(r.file)
    }
  }

  const tasks = ciTaskNames(workflowBlocks)

  // First pass: direct reachability.
  for (const r of rows) {
    if (r.wf.length) {
      r.status = 'WIRED'
      r.via = r.wf.map((b) => `${b.file} :: ${b.step}`).join(', ')
      continue
    }
    const invoked = r.decls.filter((d) => tasks.has(d.name))
    if (invoked.length) {
      r.status = 'WIRED (package script)'
      r.via = invoked.map((d) => `${d.manifest} scripts["${d.name}"]`).join(', ')
    }
  }

  // Fixed point: a library is reachable when an importer of it is reachable.
  for (let changed = true; changed; ) {
    changed = false
    for (const r of rows) {
      if (r.status) continue
      const live = r.importers.filter((f) => rows.find((x) => x.file === f)?.status)
      if (live.length) {
        r.status = 'LIBRARY'
        r.via = `imported by ${live.join(', ')}`
        changed = true
      }
    }
  }

  // Waivers last, so a waiver can never mask a file that is genuinely wired.
  const waiverFor = new Map(waivers.map((w) => [w.file, w]))
  const problems = []

  for (const r of rows) {
    const w = waiverFor.get(r.file)
    if (r.status && w) {
      problems.push({
        file: r.file,
        kind: 'STALE WAIVER',
        detail: `waived as un-runnable, but it IS reachable (${r.status}: ${r.via}). Delete the waiver row.`,
      })
      continue
    }
    if (r.status) {
      // TEETH: wired, but is its selftest mode ever actually run?
      if (r.selftestMode) {
        const armed = r.wf.some((b) => b.text.includes('--selftest') && hit(b.text, r.file))
        const armedByScript = r.decls.some(
          (d) => tasks.has(d.name) && d.body.includes('--selftest'),
        )
        if (!armed && !armedByScript) {
          problems.push({
            file: r.file,
            kind: 'SELFTEST MODE NEVER INVOKED',
            detail:
              `it declares a --selftest mode and is wired (${r.via}), but no invoker passes ` +
              `the flag — its proof-of-teeth has never run.`,
          })
        }
      }
      continue
    }
    if (w) continue // waived and genuinely un-run: reported under WAIVERS, not a problem
    if (r.phantom.length) {
      problems.push({
        file: r.file,
        kind: 'PHANTOM CALLER',
        detail:
          `its only reference is ${r.phantom.map((b) => `${b.file} :: ${b.step}`).join(', ')}, ` +
          `which is NOT in a repo-root .github/workflows/ and is therefore never run by ` +
          `GitHub Actions. It reads as wired and is not.`,
      })
      continue
    }
    if (r.decls.length) {
      problems.push({
        file: r.file,
        kind: 'DECLARED BUT NEVER RUN',
        detail:
          `declared as ${r.decls
            .map((d) => `${d.manifest} scripts["${d.name}"] = ${JSON.stringify(d.body)}`)
            .join(', ')}, but no workflow runs that script name. A declaration is not an ` +
          `invocation.`,
      })
      continue
    }
    problems.push({
      file: r.file,
      kind: 'ORPHAN',
      detail: 'no workflow step, package script or turbo task invokes it, anywhere.',
    })
  }

  for (const w of waivers) {
    if (!rows.find((r) => r.file === w.file)) {
      problems.push({
        file: w.file,
        kind: 'STALE WAIVER',
        detail: 'waived, but no such file exists under the scanned directory. Delete the row.',
      })
    }
  }

  return { rows, problems, scanned: files.length }
}

// ── the real world ───────────────────────────────────────────────────────────

function realWorld() {
  return {
    scriptsDir: path.join(JS_ROOT, 'scripts'),
    // The prefixes a workflow or package script could plausibly use. `js/scripts/`
    // and `scripts/` (js-tests.yml sets working-directory: js), plus the
    // `../../scripts/` form the per-package build scripts use.
    pathPrefixes: ['js/scripts/', 'scripts/', '../../scripts/', './'],
    workflowBlocks: readWorkflowDir(path.join(REPO_ROOT, '.github', 'workflows')),
    phantomBlocks: readWorkflowDir(path.join(JS_ROOT, '.github', 'workflows')),
    manifests: readManifests(manifestRoots(JS_ROOT)),
    waivers: WAIVERS,
    floor: POPULATION_FLOOR,
  }
}

function report(result, label) {
  console.log(`${label}: ${result.scanned} script(s) under the scanned directory`)
  const width = Math.max(...result.rows.map((r) => r.file.length))
  const waived = new Set(WAIVERS.map((w) => w.file))
  for (const r of result.rows) {
    const status = r.status || (waived.has(r.file) ? 'WAIVED' : 'UNREACHABLE')
    console.log(`  ${r.file.padEnd(width)}  ${status}${r.via ? `  <- ${r.via}` : ''}`)
  }
  if (WAIVERS.length) {
    console.log('')
    console.log(`  WAIVERS (${WAIVERS.length}) — stated, never silent:`)
    for (const w of WAIVERS) console.log(`    ${w.file} (${w.task}): ${w.reason}`)
  }
  if (result.problems.length) {
    console.log('')
    for (const p of result.problems) console.log(`  FAIL: ${p.kind} — ${p.file}: ${p.detail}`)
    console.log('')
    console.log(`${label}: ${result.problems.length} problem(s)`)
    return EXIT_PROBLEM
  }
  console.log('')
  console.log(`${label}: clean — every script is reachable from a CI workflow step or waived`)
  return 0
}

// ── POSITIVE CONTROL ─────────────────────────────────────────────────────────
//
// Points the SAME audit() at a fixture tree with a planted orphan of every
// shape. A scan whose loop body never runs names none of them and fails here.

function selftest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-wiring-'))
  const sdir = path.join(tmp, 'scripts')
  fs.mkdirSync(sdir, { recursive: true })

  const W = (n, s) => fs.writeFileSync(path.join(sdir, n), s)
  W('wired-gate.mjs', "import { thing } from './shared-lib.mjs'\nconsole.log(thing)\n")
  W('shared-lib.mjs', 'export const thing = 1\n')
  W('lonely-harness.sh', '#!/usr/bin/env bash\necho nothing runs me\n')
  W('declared-only.mjs', 'console.log("declared, never invoked")\n')
  W('teeth.sh', '#!/usr/bin/env bash\ncase "${1:-}" in\n  --selftest) echo teeth ;;\nesac\n')
  W('phantom-only.sh', '#!/usr/bin/env bash\necho only an inert workflow names me\n')

  const wfBlocks = [
    { file: 'fixture.yml', step: 'Run the wired gate', text: 'node scripts/wired-gate.mjs' },
    { file: 'fixture.yml', step: 'Run teeth plainly', text: 'bash scripts/teeth.sh' },
    { file: 'fixture.yml', step: 'Install', text: 'pnpm install --frozen-lockfile' },
  ]
  const phantomBlocks = [
    { file: 'js/.github/workflows/inert.yml', step: 'Smoke', text: 'bash js/scripts/phantom-only.sh' },
  ]
  const manifests = [
    {
      file: 'fixture/package.json',
      scripts: { 'selftest:demo': 'node scripts/declared-only.mjs' },
    },
  ]

  const base = {
    scriptsDir: sdir,
    pathPrefixes: ['js/scripts/', 'scripts/', './'],
    workflowBlocks: wfBlocks,
    phantomBlocks,
    manifests,
    waivers: [],
    floor: 5,
  }

  let bad = 0
  let ran = 0
  const say = (ok, msg) => {
    ran++
    if (ok) console.log(`  ok    ${msg}`)
    else {
      console.log(`  FAIL  ${msg}`)
      bad++
    }
  }
  const named = (r, file, kind) => r.problems.some((p) => p.file === file && p.kind === kind)

  console.log(`check-harness-wiring --selftest (fixture tree under ${tmp})`)

  // C1. THE SCAN SAW THE POPULATION. Everything below is vacuous without this:
  //     a guard that enumerates nothing reports no orphans and exits clean.
  const r = audit(base)
  say(r.scanned === 6, `the scan ENUMERATED the fixture population: 6 file(s) (got ${r.scanned})`)

  // C2. It NAMES a file nothing references at all.
  say(named(r, 'lonely-harness.sh', 'ORPHAN'), 'it NAMES lonely-harness.sh as an ORPHAN')

  // C3. It NAMES the declared-but-never-run shape — changelog-batched's exact
  //     shape — and does not let a package.json declaration pass as wiring.
  say(
    named(r, 'declared-only.mjs', 'DECLARED BUT NEVER RUN'),
    'it NAMES declared-only.mjs: a package.json declaration is not an invocation',
  )

  // C4. It NAMES a file whose only caller is in the inert nested workflow tree.
  say(
    named(r, 'phantom-only.sh', 'PHANTOM CALLER'),
    'it NAMES phantom-only.sh: a caller under js/.github/workflows is not a caller',
  )

  // C5. TEETH — wired, but its --selftest mode is never invoked.
  say(
    named(r, 'teeth.sh', 'SELFTEST MODE NEVER INVOKED'),
    'it NAMES teeth.sh: wired in plain mode, its --selftest arm never run',
  )

  // C6. NO FALSE POSITIVES — the genuinely reachable files are cleared, and the
  //     library is cleared through its importer rather than demanded to be run.
  say(
    !r.problems.some((p) => p.file === 'wired-gate.mjs'),
    'wired-gate.mjs is CLEARED (a real workflow step runs it)',
  )
  const lib = r.rows.find((x) => x.file === 'shared-lib.mjs')
  say(
    lib?.status === 'LIBRARY' && !r.problems.some((p) => p.file === 'shared-lib.mjs'),
    `shared-lib.mjs is CLEARED as a LIBRARY via its importer (got ${lib?.status})`,
  )

  // C7. THE VERDICT TRACKS THE INPUT. Give the orphan a workflow step and it
  //     must STOP being named. Without this arm every assertion above could be
  //     satisfied by a function that names every file unconditionally.
  const fixed = audit({
    ...base,
    workflowBlocks: [
      ...wfBlocks,
      { file: 'fixture.yml', step: 'Now it runs', text: 'bash scripts/lonely-harness.sh' },
    ],
  })
  say(
    !named(fixed, 'lonely-harness.sh', 'ORPHAN'),
    'once a step RUNS lonely-harness.sh it is no longer named (the verdict tracks the input)',
  )

  // C8. A WAIVER ON A WIRED FILE IS ITSELF REPORTED — the waiver list cannot rot
  //     into cover for something that has since been properly wired.
  const stale = audit({
    ...base,
    waivers: [{ file: 'wired-gate.mjs', task: 'fixture', reason: 'fixture' }],
  })
  say(
    named(stale, 'wired-gate.mjs', 'STALE WAIVER'),
    'a waiver naming an ALREADY-WIRED file is reported as a STALE WAIVER',
  )

  // C9. THE FLOOR — an emptied population is a refusal, never a clean read.
  const empty = path.join(tmp, 'empty')
  fs.mkdirSync(empty, { recursive: true })
  let refused = false
  try {
    audit({ ...base, scriptsDir: empty })
  } catch (e) {
    refused = e instanceof HarnessError
  }
  say(refused, 'an EMPTY population is REFUSED (exit 3), never audited clean')

  fs.rmSync(tmp, { recursive: true, force: true })

  const total = 10
  console.log('')
  if (bad === 0 && ran === total) {
    console.log(`check-harness-wiring --selftest: PASS (${ran}/${total})`)
    return 0
  }
  if (ran !== total) {
    console.log(`check-harness-wiring --selftest: SHORT RUN — ${ran} of ${total} planned case(s) ran`)
  }
  console.log(`check-harness-wiring --selftest: FAILED (${bad} case(s), ${ran}/${total} ran)`)
  return EXIT_PROBLEM
}

// ── entry ────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2)
try {
  if (argv.includes('--selftest')) {
    process.exit(selftest())
  } else if (argv.length === 0) {
    process.exit(report(audit(realWorld()), 'check-harness-wiring'))
  } else {
    console.error('usage: node js/scripts/check-harness-wiring.mjs [--selftest]')
    process.exit(EXIT_USAGE)
  }
} catch (e) {
  if (e instanceof HarnessError) {
    console.error(`CANNOT READ: ${e.message}`)
    process.exit(EXIT_HARNESS)
  }
  throw e
}

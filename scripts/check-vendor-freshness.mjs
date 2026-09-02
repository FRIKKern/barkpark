#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Vendored-SDK FRESHNESS gate.
//
// The starter templates do not install @barkpark/core or @barkpark/react from
// npm — they vendor packed tarballs (templates/*/vendor/barkpark-*.tgz) that
// are FROZEN COPIES of js/packages/{core,react}. Every commit to those packages
// after the pack date ships to nobody: a scaffolded user gets the old bytes and
// no signal that they are old.
//
// A sibling gate, scripts/check-vendor-blocks.mjs, already covers ONE axis of
// that decay: whether the vendored RENDERER paints every block type the repo
// teaches. That gate is blind to @barkpark/core entirely (measured: `git grep
// barkpark-core -- scripts .github/workflows` returned nothing), and blind to
// any react change that does not add a block type. A core-side regression fix
// — a retry bug, an SSE starvation fix, a new export — ships stale, invisibly,
// and no block renders as unknown.
//
// This gate closes that axis: it asks whether the vendored tarballs correspond
// to the CURRENT source of the packages they were cut from.
//
// ---------------------------------------------------------------------------
// WHY NOT COMPARE THE TARBALLS THEMSELVES
// ---------------------------------------------------------------------------
//
// The obvious gate — re-run `pnpm pack` and compare `shasum` against the
// committed .tgz — is PERMANENTLY RED and therefore worthless. A .tgz embeds
// per-entry mtimes and gzip metadata, so two packs of byte-identical content
// produce different archive bytes. The selftest below PROVES this rather than
// asserting it: it packs one fixture twice with different mtimes, shows the
// archive sha256 differs, and shows this gate's content digest does not.
//
// So the gate compares two CONTENT digests, both mtime-free, both computed the
// same way — sha256 over `<relative path>\0<sha256 of bytes>\n` for every file,
// paths sorted:
//
//   SOURCE digest  — the pack INPUTS of js/packages/<pkg>: src/**, package.json,
//                    tsup.config.ts, tsconfig.json. Not tests, not README,
//                    not CHANGELOG: a test-only commit cannot change dist, and
//                    a gate that reds on it gets muted within a week.
//
//   TARBALL digest — every file inside the committed .tgz (the `package/…`
//                    tree), extracted and hashed. Mtimes never enter.
//
// Both are recorded in templates/VENDOR-STAMP.json at pack time. The gate
// re-measures both and adjudicates:
//
//   STALE-SOURCE        the package's pack inputs changed since the tarball was
//                       cut — the vendored SDK is behind main. RE-CUT.
//   TARBALL-DRIFT       the committed tarball's content is not what the stamp
//                       records — a tarball was swapped without re-stamping, or
//                       the stamp was edited without re-packing. Either way the
//                       stamp is no longer evidence of anything.
//   TARBALL-DIVERGENCE  the two templates vendor DIFFERENT bytes for the same
//                       package — one was re-cut and the other forgotten.
//   STAMP-MISSING       a vendored package with no stamp entry, or a stamp with
//                       no packages at all. Fails; an unstamped tarball is not
//                       a fresh tarball.
//
// FAIL-CLOSED throughout: a missing file, an unreadable stamp and an empty
// package set are all failures, never skips.
//
// Usage:
//   node scripts/check-vendor-freshness.mjs            # gate
//   node scripts/check-vendor-freshness.mjs --selftest # prove the gate can fail
//   node scripts/check-vendor-freshness.mjs --write    # re-stamp after a re-cut
//
// To fix a STALE-SOURCE red, run scripts/recut-vendor-tarballs.sh — it builds,
// packs with pnpm (NEVER npm: npm emits `workspace:^` specifiers that are
// uninstallable outside this monorepo), copies into both templates, repins each
// lockfile's integrity and re-stamps.

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const STAMP_REL = 'templates/VENDOR-STAMP.json'
const TEMPLATES = ['templates/search-starter', 'templates/astro-search-starter']

/** The vendored packages: stamp key -> where it comes from and what it lands as. */
const VENDORED = {
  '@barkpark/core': { source: 'js/packages/core', tarball: 'barkpark-core.tgz' },
  '@barkpark/react': { source: 'js/packages/react', tarball: 'barkpark-react.tgz' },
}

// The pack INPUTS — everything that can change what `pnpm pack` emits. `src` is
// a directory (walked); the rest are single files, optional because not every
// package carries every config.
const SOURCE_INPUTS = {
  dirs: ['src'],
  files: ['package.json', 'tsup.config.ts', 'tsconfig.json'],
}

// ---------------------------------------------------------------------------
// Content digests — mtime-free, order-free, path-relative.
// ---------------------------------------------------------------------------

/** Every file under `dir`, as paths relative to `base`, sorted. */
export function walkFiles(dir, base = dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const abs = join(dir, entry.name)
    if (entry.isDirectory()) walkFiles(abs, base, out)
    else if (entry.isFile()) out.push(relative(base, abs).split(sep).join('/'))
  }
  return out
}

/**
 * sha256 over `<relpath>\0<sha256 of bytes>\n` for every entry, paths sorted.
 *
 * Deliberately NOT a hash of the concatenated bytes: this shape makes a rename
 * a difference (the path is hashed) while making archive metadata — mtimes,
 * ownership, gzip headers, entry order — invisible.
 *
 * `entries` is [{ path, bytes }].
 */
export function digestEntries(entries) {
  if (entries.length === 0) throw new Error('digestEntries: refusing to hash an empty file set')
  const h = createHash('sha256')
  for (const e of [...entries].sort((a, b) => (a.path < b.path ? -1 : 1))) {
    h.update(e.path)
    h.update('\0')
    h.update(createHash('sha256').update(e.bytes).digest('hex'))
    h.update('\n')
  }
  return `sha256:${h.digest('hex')}`
}

/** The pack-input digest of a package directory. */
export function sourceDigest(pkgDir, inputs = SOURCE_INPUTS) {
  if (!existsSync(pkgDir)) throw new Error(`source package not found: ${pkgDir}`)
  const entries = []
  for (const d of inputs.dirs) {
    const abs = join(pkgDir, d)
    if (!existsSync(abs)) continue
    for (const rel of walkFiles(abs, pkgDir)) entries.push({ path: rel, bytes: readFileSync(join(pkgDir, rel)) })
  }
  for (const f of inputs.files) {
    const abs = join(pkgDir, f)
    if (existsSync(abs)) entries.push({ path: f, bytes: readFileSync(abs) })
  }
  return digestEntries(entries)
}

/**
 * The content digest of a packed tarball — extracted, then hashed by path.
 *
 * Uses the system `tar` rather than a bundled reader on purpose: this gate must
 * run with zero npm dependencies so it can execute on a bare checkout, before
 * any install, in the same job that would otherwise not be worth adding.
 */
export function tarballDigest(tgzPath) {
  if (!existsSync(tgzPath)) throw new Error(`vendored tarball not found: ${tgzPath}`)
  const dir = mkdtempSync(join(tmpdir(), 'bp-vendor-fresh-'))
  try {
    execFileSync('tar', ['-xzf', tgzPath, '-C', dir], { stdio: ['ignore', 'ignore', 'pipe'] })
    const rels = walkFiles(dir)
    return digestEntries(rels.map((r) => ({ path: r, bytes: readFileSync(join(dir, r)) })))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// ---------------------------------------------------------------------------
// Adjudication — pure, so the selftest can drive every verdict without a repo.
// ---------------------------------------------------------------------------

/**
 * Compare a stamp against measurements and return named failures.
 *
 * `measured` is { [pkgKey]: { sourceDigest, version, tarballs: { [templateRel]: digest } } }.
 * Returns [{ reason, pkg, detail }] — empty means fresh.
 */
export function adjudicate(stamp, measured) {
  const failures = []
  const stamped = (stamp && stamp.packages) || {}

  if (Object.keys(stamped).length === 0) {
    failures.push({
      reason: 'STAMP-MISSING',
      pkg: '(all)',
      detail: `${STAMP_REL} records no packages — an unstamped tarball is not a fresh tarball`,
    })
  }

  for (const [pkg, m] of Object.entries(measured)) {
    const s = stamped[pkg]
    if (!s) {
      failures.push({ reason: 'STAMP-MISSING', pkg, detail: `no entry in ${STAMP_REL}` })
      continue
    }

    const digests = Object.entries(m.tarballs)
    const distinct = new Set(digests.map(([, d]) => d))
    if (distinct.size > 1) {
      failures.push({
        reason: 'TARBALL-DIVERGENCE',
        pkg,
        detail:
          `the templates vendor DIFFERENT bytes for ${pkg} — one was re-cut and the other forgotten:\n` +
          digests.map(([t, d]) => `       ${t} ${d}`).join('\n'),
      })
    }

    for (const [tpl, d] of digests) {
      if (d !== s.tarball_digest) {
        failures.push({
          reason: 'TARBALL-DRIFT',
          pkg,
          detail:
            `${tpl}/vendor/${VENDORED[pkg] ? VENDORED[pkg].tarball : 'tarball'} content is ${d}\n` +
            `       but ${STAMP_REL} records ${s.tarball_digest}\n` +
            `       a tarball was swapped without re-stamping, or the stamp was edited without re-packing`,
        })
      }
    }

    if (m.sourceDigest !== s.source_digest) {
      failures.push({
        reason: 'STALE-SOURCE',
        pkg,
        detail:
          `${s.source} changed since the tarball was cut${s.cut_at ? ` on ${s.cut_at}` : ''}\n` +
          `       stamped source digest ${s.source_digest}\n` +
          `       current source digest ${m.sourceDigest}\n` +
          (m.version && s.version && m.version !== s.version
            ? `       version also moved ${s.version} -> ${m.version}\n`
            : '') +
          `       the vendored SDK is BEHIND main; every scaffolded user gets the old bytes.\n` +
          `       re-cut: bash scripts/recut-vendor-tarballs.sh`,
      })
    }
  }

  return failures
}

// ---------------------------------------------------------------------------
// Measurement against the real repo.
// ---------------------------------------------------------------------------

function measure(repoRoot = REPO_ROOT, templates = TEMPLATES) {
  const out = {}
  for (const [pkg, spec] of Object.entries(VENDORED)) {
    const pkgDir = join(repoRoot, spec.source)
    const tarballs = {}
    for (const tpl of templates) {
      tarballs[tpl] = tarballDigest(join(repoRoot, tpl, 'vendor', spec.tarball))
    }
    let version = null
    try {
      version = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8')).version
    } catch {
      /* a package with no readable package.json is caught by sourceDigest */
    }
    out[pkg] = { sourceDigest: sourceDigest(pkgDir), version, tarballs }
  }
  return out
}

function readStamp(repoRoot = REPO_ROOT) {
  const p = join(repoRoot, STAMP_REL)
  if (!existsSync(p)) return null
  return JSON.parse(readFileSync(p, 'utf8'))
}

function headCommit(repoRoot) {
  try {
    return execFileSync('git', ['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  } catch {
    return null
  }
}

function writeStamp(repoRoot = REPO_ROOT) {
  const measured = measure(repoRoot)
  const packages = {}
  for (const [pkg, m] of Object.entries(measured)) {
    const digests = new Set(Object.values(m.tarballs))
    if (digests.size > 1) {
      console.log(
        `FAIL --write refuses: the templates vendor different bytes for ${pkg}.\n` +
          `     re-cut both templates first (scripts/recut-vendor-tarballs.sh), then re-stamp.`
      )
      return false
    }
    packages[pkg] = {
      source: VENDORED[pkg].source,
      tarball: VENDORED[pkg].tarball,
      version: m.version,
      source_digest: m.sourceDigest,
      tarball_digest: [...digests][0],
      cut_at: new Date().toISOString().slice(0, 10),
      cut_from_commit: headCommit(repoRoot),
    }
  }
  const stamp = {
    _readme:
      'Freshness stamp for the vendored starter SDKs. source_digest and tarball_digest are ' +
      'mtime-free content hashes (see scripts/check-vendor-freshness.mjs); a .tgz is NOT ' +
      'byte-reproducible so its archive checksum is deliberately not recorded. Regenerate ' +
      'with: node scripts/check-vendor-freshness.mjs --write, and only after a real re-cut.',
    templates: TEMPLATES,
    packages,
  }
  writeFileSync(join(repoRoot, STAMP_REL), `${JSON.stringify(stamp, null, 2)}\n`)
  console.log(`wrote ${STAMP_REL}`)
  for (const [pkg, p] of Object.entries(packages)) {
    console.log(`  ${pkg} ${p.version} source=${p.source_digest} tarball=${p.tarball_digest}`)
  }
  return true
}

function gate(repoRoot = REPO_ROOT) {
  const stamp = readStamp(repoRoot)
  if (!stamp) {
    console.log(`FAIL STAMP-MISSING: ${STAMP_REL} does not exist — nothing to adjudicate against.`)
    return false
  }
  const measured = measure(repoRoot)
  const failures = adjudicate(stamp, measured)

  for (const [pkg, m] of Object.entries(measured)) {
    const s = (stamp.packages || {})[pkg] || {}
    const bad = failures.some((f) => f.pkg === pkg)
    console.log(
      `${bad ? 'FAIL' : 'ok  '} ${pkg} ${m.version || '?'} — source ${m.sourceDigest.slice(0, 23)}… vs stamped ${
        (s.source_digest || '(none)').slice(0, 23)
      }…`
    )
  }

  if (failures.length === 0) {
    console.log(
      `ok   vendored SDKs are fresh: ${Object.keys(measured).length} packages x ${TEMPLATES.length} templates, ` +
        `content-compared against ${STAMP_REL}`
    )
    return true
  }
  for (const f of failures) console.log(`FAIL ${f.reason} ${f.pkg}: ${f.detail}`)
  console.log(`${failures.length} freshness failure(s)`)
  return false
}

// ---------------------------------------------------------------------------
// Selftest — the gate must be able to fail, proven, not asserted.
// ---------------------------------------------------------------------------

function selftest() {
  const checks = []
  const check = (name, fn) => checks.push({ name, fn })
  const eq = (a, b, what) => {
    const A = JSON.stringify(a)
    const B = JSON.stringify(b)
    if (A !== B) throw new Error(`${what}: got ${A}, want ${B}`)
  }
  const reasons = (fs) => fs.map((f) => f.reason).sort()

  const dir = mkdtempSync(join(tmpdir(), 'bp-vendor-fresh-selftest-'))
  try {
    // --- a fixture package -------------------------------------------------
    const pkgDir = join(dir, 'pkg')
    mkdirSync(join(pkgDir, 'src', 'util'), { recursive: true })
    mkdirSync(join(pkgDir, 'tests'), { recursive: true })
    writeFileSync(join(pkgDir, 'src', 'index.ts'), 'export const a = 1\n')
    writeFileSync(join(pkgDir, 'src', 'util', 'x.ts'), 'export const x = 2\n')
    writeFileSync(join(pkgDir, 'package.json'), '{"name":"@fix/pkg","version":"1.0.0"}\n')
    writeFileSync(join(pkgDir, 'tsup.config.ts'), 'export default {}\n')
    writeFileSync(join(pkgDir, 'tests', 'a.test.ts'), 'it("x", () => {})\n')
    writeFileSync(join(pkgDir, 'README.md'), '# fixture\n')

    check('sourceDigest is stable across repeated measurement', () => {
      eq(sourceDigest(pkgDir), sourceDigest(pkgDir), 'repeat digest')
    })

    check('sourceDigest ignores mtime — the whole reason this gate is not a shasum', () => {
      const before = sourceDigest(pkgDir)
      const t = new Date(Date.now() - 86400_000)
      utimesSync(join(pkgDir, 'src', 'index.ts'), t, t)
      if (sourceDigest(pkgDir) !== before) throw new Error('an mtime change moved the source digest')
    })

    check('sourceDigest MOVES when a src file changes', () => {
      const before = sourceDigest(pkgDir)
      writeFileSync(join(pkgDir, 'src', 'index.ts'), 'export const a = 2\n')
      if (sourceDigest(pkgDir) === before) throw new Error('a src edit did not move the digest — the gate is blind')
      writeFileSync(join(pkgDir, 'src', 'index.ts'), 'export const a = 1\n')
      eq(sourceDigest(pkgDir), before, 'digest after restore')
    })

    check('sourceDigest ignores tests and README — a test-only commit must not red the gate', () => {
      const before = sourceDigest(pkgDir)
      writeFileSync(join(pkgDir, 'tests', 'a.test.ts'), 'it("y", () => {})\n')
      writeFileSync(join(pkgDir, 'README.md'), '# fixture, edited\n')
      eq(sourceDigest(pkgDir), before, 'digest after test/README edit')
    })

    check('sourceDigest MOVES when package.json or the build config changes', () => {
      const before = sourceDigest(pkgDir)
      writeFileSync(join(pkgDir, 'tsup.config.ts'), 'export default { minify: true }\n')
      if (sourceDigest(pkgDir) === before) throw new Error('a tsup.config edit did not move the digest')
      writeFileSync(join(pkgDir, 'tsup.config.ts'), 'export default {}\n')
    })

    check('digestEntries REFUSES an empty file set instead of hashing nothing', () => {
      let raised = false
      try {
        digestEntries([])
      } catch {
        raised = true
      }
      if (!raised) throw new Error('an empty file set produced a digest — every package would compare equal')
    })

    check('digestEntries hashes the PATH, so a rename is a difference', () => {
      const a = digestEntries([{ path: 'a.ts', bytes: Buffer.from('x') }])
      const b = digestEntries([{ path: 'b.ts', bytes: Buffer.from('x') }])
      if (a === b) throw new Error('renaming a file left the digest unchanged')
    })

    // --- THE LOAD-BEARING PROOF: .tgz bytes are not reproducible, content is --
    const packDir = join(dir, 'packs')
    mkdirSync(packDir)
    const contentDir = join(dir, 'content', 'package')
    mkdirSync(contentDir, { recursive: true })
    writeFileSync(join(contentDir, 'index.mjs'), 'export const v = 1\n')
    writeFileSync(join(contentDir, 'package.json'), '{"name":"@fix/pkg"}\n')

    const packA = join(packDir, 'a.tgz')
    const packB = join(packDir, 'b.tgz')
    const tarUp = (out) => execFileSync('tar', ['-czf', out, '-C', join(dir, 'content'), 'package'])
    tarUp(packA)
    const future = new Date(Date.now() + 3600_000)
    utimesSync(join(contentDir, 'index.mjs'), future, future)
    tarUp(packB)

    check('a .tgz is NOT byte-reproducible — a shasum gate would be permanently red', () => {
      const sha = (p) => createHash('sha256').update(readFileSync(p)).digest('hex')
      if (sha(packA) === sha(packB)) {
        throw new Error('the two packs were byte-identical — this selftest can no longer prove the premise')
      }
    })

    check('tarballDigest is IDENTICAL across those two non-identical archives', () => {
      eq(tarballDigest(packA), tarballDigest(packB), 'content digest across packs')
    })

    check('tarballDigest MOVES when the packed content actually changes', () => {
      const before = tarballDigest(packA)
      writeFileSync(join(contentDir, 'index.mjs'), 'export const v = 2\n')
      const packC = join(packDir, 'c.tgz')
      tarUp(packC)
      if (tarballDigest(packC) === before) throw new Error('a content change did not move the tarball digest')
    })

    check('tarballDigest FAILS on a missing tarball rather than returning a green', () => {
      let raised = false
      try {
        tarballDigest(join(packDir, 'nope.tgz'))
      } catch {
        raised = true
      }
      if (!raised) throw new Error('a missing tarball digested quietly')
    })

    // --- adjudication: every verdict, both arms ---------------------------
    const FRESH_STAMP = {
      packages: {
        '@barkpark/core': {
          source: 'js/packages/core',
          version: '1.0.0',
          source_digest: 'sha256:aaa',
          tarball_digest: 'sha256:ttt',
          cut_at: '2026-09-02',
        },
      },
    }
    const FRESH_MEASURED = {
      '@barkpark/core': {
        sourceDigest: 'sha256:aaa',
        version: '1.0.0',
        tarballs: { 'templates/search-starter': 'sha256:ttt', 'templates/astro-search-starter': 'sha256:ttt' },
      },
    }

    check('adjudicate is GREEN when stamp and measurement agree', () => {
      eq(adjudicate(FRESH_STAMP, FRESH_MEASURED), [], 'fresh verdict')
    })

    check('adjudicate returns STALE-SOURCE when the package source moved', () => {
      const m = JSON.parse(JSON.stringify(FRESH_MEASURED))
      m['@barkpark/core'].sourceDigest = 'sha256:bbb'
      const f = adjudicate(FRESH_STAMP, m)
      eq(reasons(f), ['STALE-SOURCE'], 'stale reasons')
      if (!f[0].detail.includes('js/packages/core')) throw new Error('the failure does not name the source package')
      if (!f[0].detail.includes('recut-vendor-tarballs.sh')) throw new Error('the failure does not name the remedy')
    })

    check('a STALE-SOURCE detail names the version move when the version also changed', () => {
      const m = JSON.parse(JSON.stringify(FRESH_MEASURED))
      m['@barkpark/core'].sourceDigest = 'sha256:bbb'
      m['@barkpark/core'].version = '1.1.0'
      const f = adjudicate(FRESH_STAMP, m)
      if (!f[0].detail.includes('1.0.0 -> 1.1.0')) throw new Error(`version move not reported: ${f[0].detail}`)
    })

    check('adjudicate returns TARBALL-DRIFT when a committed tarball is not what the stamp records', () => {
      const m = JSON.parse(JSON.stringify(FRESH_MEASURED))
      m['@barkpark/core'].tarballs['templates/search-starter'] = 'sha256:zzz'
      m['@barkpark/core'].tarballs['templates/astro-search-starter'] = 'sha256:zzz'
      eq(reasons(adjudicate(FRESH_STAMP, m)), ['TARBALL-DRIFT', 'TARBALL-DRIFT'], 'drift reasons')
    })

    check('adjudicate returns TARBALL-DIVERGENCE when one template was re-cut and the other forgotten', () => {
      const m = JSON.parse(JSON.stringify(FRESH_MEASURED))
      m['@barkpark/core'].tarballs['templates/astro-search-starter'] = 'sha256:other'
      const f = adjudicate(FRESH_STAMP, m)
      if (!reasons(f).includes('TARBALL-DIVERGENCE')) throw new Error(`no divergence verdict: ${reasons(f)}`)
    })

    check('adjudicate returns STAMP-MISSING for a vendored package with no stamp entry', () => {
      const m = JSON.parse(JSON.stringify(FRESH_MEASURED))
      m['@barkpark/react'] = { sourceDigest: 'sha256:r', version: '1', tarballs: { 'templates/search-starter': 'sha256:x' } }
      eq(reasons(adjudicate(FRESH_STAMP, m)), ['STAMP-MISSING'], 'missing-entry reasons')
    })

    check('adjudicate FAILS an empty stamp instead of passing vacuously', () => {
      const f = adjudicate({ packages: {} }, {})
      if (f.length === 0) throw new Error('an empty stamp with no measurements returned green')
      eq(reasons(f), ['STAMP-MISSING'], 'empty-stamp reasons')
    })

    check('adjudicate FAILS a null stamp instead of throwing past the caller', () => {
      const f = adjudicate(null, {})
      eq(reasons(f), ['STAMP-MISSING'], 'null-stamp reasons')
    })

    // --- the real repo, end to end ----------------------------------------
    check('the real stamp covers every vendored package this gate knows about', () => {
      const stamp = readStamp()
      if (!stamp) throw new Error(`${STAMP_REL} does not exist`)
      for (const pkg of Object.keys(VENDORED)) {
        if (!stamp.packages || !stamp.packages[pkg]) throw new Error(`${STAMP_REL} has no entry for ${pkg}`)
      }
    })

    let passed = 0
    for (const c of checks) {
      c.fn()
      passed += 1
      console.log(`ok   ${c.name}`)
    }
    console.log(`selftest ${passed}/${checks.length} passed`)
    return true
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// ---------------------------------------------------------------------------

// process.exitCode, never process.exit(): node does not flush a pending stdout
// write before process.exit(), so a piped consumer can lose the very verdict
// line the gate exists to print while the exit code arrives intact.
function main() {
  const argv = process.argv.slice(2)
  if (argv.includes('--selftest')) return selftest() ? 0 : 1
  if (argv.includes('--write')) return writeStamp() ? 0 : 1
  return gate() ? 0 : 1
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main()
  } catch (err) {
    console.error(`check-vendor-freshness: ${err && err.stack ? err.stack : err}`)
    process.exitCode = 1
  }
}

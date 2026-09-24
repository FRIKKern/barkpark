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
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const STAMP_REL = 'templates/VENDOR-STAMP.json'
const TEMPLATES = ['templates/search-starter', 'templates/astro-search-starter']

/**
 * The vendored packages: stamp key -> where it comes from and what it lands as.
 *
 * `external` — build inputs that live OUTSIDE the package directory. Both
 * packages run `tsup && node ../../scripts/post-build-dts.mjs`, so that script
 * is a pack input: change what it copies and `dist` changes, with nothing
 * inside js/packages/<pkg> moving a byte. The react build additionally copies
 * api/assets/paper-surface/paper-surface.css into dist (tsup.config.ts
 * `onSuccess`), and that config says so in as many words: "Because the source
 * lives outside `js/`'s turbo+pnpm workspace, turbo's cache hash can't see
 * edits to it." Neither could this gate's source digest until they were listed
 * here — a real build input whose edit did not invalidate freshness.
 *
 * `copied` — source paths that land VERBATIM in the packed artifact, as
 * `<repo-relative source>: <path inside the .tgz>`. These are the load-bearing
 * half of the correspondence check below: they are the one place where a
 * source byte and an ARTIFACT byte must be equal, which is what lets this gate
 * refuse to bless a tarball whose build inputs have moved on.
 */
const VENDORED = {
  '@barkpark/core': {
    source: 'js/packages/core',
    tarball: 'barkpark-core.tgz',
    external: ['js/scripts/post-build-dts.mjs'],
    copied: {},
  },
  '@barkpark/react': {
    source: 'js/packages/react',
    tarball: 'barkpark-react.tgz',
    external: ['js/scripts/post-build-dts.mjs', 'api/assets/paper-surface/paper-surface.css'],
    copied: { 'api/assets/paper-surface/paper-surface.css': 'package/dist/paper-surface.css' },
  },
}

// The pack INPUTS inside the package directory — everything there that can
// change what `pnpm pack` emits. `src` is a directory (walked); the rest are
// single files, optional because not every package carries every config.
// Inputs OUTSIDE the package dir are per-package: VENDORED[pkg].external.
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

/**
 * The pack-input digest of a package directory.
 *
 * `external` is a list of repo-root-relative paths to build inputs that live
 * outside `pkgDir`. They are hashed under their repo-relative path (never a
 * `../..` path, which would differ by where the package sits), so moving one
 * is a difference exactly like renaming an in-package file. Unlike the
 * in-package optional config files, an external input that does NOT EXIST is a
 * THROW, not a skip: this list is hand-written, and a typo that silently
 * hashed nothing would reinstate the very blindness it was added to close.
 */
export function sourceDigest(pkgDir, inputs = SOURCE_INPUTS, external = [], repoRoot = REPO_ROOT) {
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
  for (const rel of external) {
    const abs = join(repoRoot, rel)
    if (!existsSync(abs)) throw new Error(`external build input not found: ${rel} (listed in VENDORED[...].external)`)
    entries.push({ path: `@repo/${rel}`, bytes: readFileSync(abs) })
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
export function tarballEntries(tgzPath) {
  if (!existsSync(tgzPath)) throw new Error(`vendored tarball not found: ${tgzPath}`)
  const dir = mkdtempSync(join(tmpdir(), 'bp-vendor-fresh-'))
  try {
    execFileSync('tar', ['-xzf', tgzPath, '-C', dir], { stdio: ['ignore', 'ignore', 'pipe'] })
    return walkFiles(dir).map((r) => ({ path: r, bytes: readFileSync(join(dir, r)) }))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

export function tarballDigest(tgzPath) {
  return digestEntries(tarballEntries(tgzPath))
}

// ---------------------------------------------------------------------------
// SOURCE -> ARTIFACT CORRESPONDENCE
// ---------------------------------------------------------------------------
//
// The digest pair above answers "did the source move since the stamp was
// written". It cannot answer "does this tarball actually contain a build of
// that source", because the two digests are recorded INDEPENDENTLY: `--write`
// reads the source, reads the tarball, and records both, agreeing with itself
// no matter how far apart they are. Edit a package, run `--write` WITHOUT
// re-cutting, and the gate goes green over a stale tarball — the stamp says
// only "these were the bytes on the day someone ran --write".
//
// Re-deriving the whole build inside the gate is not available (it needs a
// pnpm install, a tsup run and several minutes). What IS available are the
// places where a SOURCE byte and an ARTIFACT byte must be equal, or where the
// build's own contract is visible in the packed output. Those are checked
// here, against the real tarball, and — the load-bearing part — they are
// checked by `--write` TOO, which refuses to stamp when they fail. That is
// what makes a stale tarball unblessable: the CSS a user imports is the CSS
// the repo teaches, or nothing gets stamped.
//
//   COPIED-ASSET  a file copied verbatim into dist (today:
//                 api/assets/paper-surface/paper-surface.css ->
//                 package/dist/paper-surface.css) differs from its source.
//                 Edit the stylesheet without re-cutting and this fires.
//   MANIFEST      the packed package/package.json is not the source
//                 package.json. Dependency specifiers are compared modulo
//                 pnpm's `workspace:` rewrite — and a `workspace:` specifier
//                 SURVIVING into the artifact is itself a failure, because
//                 that is the npm-packed tarball scripts/recut-vendor-
//                 tarballs.sh exists to prevent (uninstallable outside this
//                 monorepo).
//   DTS-PAIRING   js/scripts/post-build-dts.mjs copies every dist/<e>.d.ts to
//                 <e>.d.mts; package.json `exports` resolves import.types
//                 THERE. A packed dist missing a pair, or carrying a stale
//                 one, means the post-build step did not run over these bytes.
//                 Zero pairs is a failure, not a pass: a `dts: true` build
//                 that emitted no declarations never happened.

const WORKSPACE_DEP_FIELDS = ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']

/**
 * Compare a package's SOURCE against the contents of its packed artifact.
 *
 * Pure: `sources` is a Map of repo-relative path -> bytes and `entries` a Map
 * of in-tarball path -> bytes, so the selftest drives every arm without a repo.
 * Returns an array of detail strings; empty means the artifact corresponds.
 */
export function correspondenceFailures(spec, sources, entries) {
  const out = []

  // --- COPIED-ASSET ------------------------------------------------------
  for (const [src, art] of Object.entries(spec.copied || {})) {
    const want = sources.get(src)
    if (!want) {
      out.push(`COPIED-ASSET ${src} is not readable in the working tree — cannot verify ${art}`)
      continue
    }
    const got = entries.get(art)
    if (!got) {
      out.push(`COPIED-ASSET the tarball has no ${art}, but ${src} is supposed to be copied there`)
      continue
    }
    if (!Buffer.from(want).equals(Buffer.from(got))) {
      const sha = (b) => createHash('sha256').update(b).digest('hex').slice(0, 16)
      out.push(
        `COPIED-ASSET ${art} is NOT the current ${src}\n` +
          `       source   sha256:${sha(want)}… (${want.length} bytes)\n` +
          `       artifact sha256:${sha(got)}… (${got.length} bytes)\n` +
          `       the vendored SDK ships a stale copy of a file the repo has since changed`
      )
    }
  }

  // --- MANIFEST ----------------------------------------------------------
  const srcManifestPath = `${spec.source}/package.json`
  const srcManifestBytes = sources.get(srcManifestPath)
  const artManifestBytes = entries.get('package/package.json')
  if (!srcManifestBytes) out.push(`MANIFEST ${srcManifestPath} is not readable`)
  else if (!artManifestBytes) out.push('MANIFEST the tarball has no package/package.json')
  else {
    let a = null
    let b = null
    try {
      a = JSON.parse(Buffer.from(srcManifestBytes).toString('utf8'))
      b = JSON.parse(Buffer.from(artManifestBytes).toString('utf8'))
    } catch (err) {
      out.push(`MANIFEST unparseable package.json: ${err.message}`)
    }
    if (a && b) {
      for (const field of WORKSPACE_DEP_FIELDS) {
        for (const [dep, range] of Object.entries((b[field] || {}))) {
          if (typeof range === 'string' && range.startsWith('workspace:')) {
            out.push(
              `MANIFEST the packed manifest still carries ${field}.${dep} = "${range}"\n` +
                `       a \`workspace:\` specifier is uninstallable outside this monorepo — this tarball was\n` +
                `       packed with npm, not pnpm. Re-cut: bash scripts/recut-vendor-tarballs.sh`
            )
          }
        }
        // pnpm REWRITES workspace: ranges at pack time, so compare those keys by
        // presence, not value; every other field compares exactly.
        for (const [dep, range] of Object.entries((a[field] || {}))) {
          if (typeof range === 'string' && range.startsWith('workspace:')) {
            if (!(b[field] || {})[dep]) out.push(`MANIFEST the packed manifest dropped ${field}.${dep}`)
            delete a[field][dep]
            if (b[field]) delete b[field][dep]
          }
        }
      }
      // Compare FIELD BY FIELD, each serialised on its own. NOT
      // `JSON.stringify(o, Object.keys(o).sort())` — the array form of the
      // second argument is a property WHITELIST applied at every depth, not a
      // key order, so it flattens `exports` to `{}` and makes every nested
      // difference invisible. (Measured: two manifests differing only in
      // `exports["."].import` compared EQUAL under that shape.) Key order
      // inside a field is not normalised on purpose — a reordered manifest is
      // still a manifest that was not the one packed.
      const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])]
      const moved = keys.filter((k) => JSON.stringify(a[k]) !== JSON.stringify(b[k])).sort()
      if (moved.length > 0) {
        out.push(
          `MANIFEST ${srcManifestPath} does not match the packed package/package.json\n` +
            `       fields that differ: ${moved.join(', ')}\n` +
            `       the tarball was packed from a different manifest than the one in the tree`
        )
      }
    }
  }

  // --- DTS-PAIRING -------------------------------------------------------
  let pairs = 0
  for (const [path, bytes] of entries) {
    if (!path.endsWith('.d.ts') || path.endsWith('.d.cts')) continue
    const mts = `${path.slice(0, -'.d.ts'.length)}.d.mts`
    const got = entries.get(mts)
    if (!got) {
      out.push(
        `DTS-PAIRING the tarball has ${path} but no ${mts}\n` +
          `       js/scripts/post-build-dts.mjs did not run over these bytes; package.json exports\n` +
          `       resolves import.types to the missing file`
      )
      continue
    }
    if (!Buffer.from(bytes).equals(Buffer.from(got))) {
      out.push(`DTS-PAIRING ${mts} is not a copy of ${path} — the post-build step ran over DIFFERENT bytes`)
      continue
    }
    pairs += 1
  }
  if (pairs === 0) {
    out.push(
      'DTS-PAIRING the tarball carries no .d.ts/.d.mts pair at all — both packages build with ' +
        '`dts: true`, so a pack with zero declarations is a build that never happened'
    )
  }

  return out
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

    for (const [tpl, details] of Object.entries(m.correspondence || {})) {
      for (const detail of details) {
        failures.push({
          reason: 'SOURCE-ARTIFACT-MISMATCH',
          pkg,
          detail: `${tpl}/vendor/${VENDORED[pkg] ? VENDORED[pkg].tarball : 'tarball'} does not correspond to its source\n       ${detail}`,
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

export function measure(repoRoot = REPO_ROOT, templates = TEMPLATES) {
  const out = {}
  for (const [pkg, spec] of Object.entries(VENDORED)) {
    const pkgDir = join(repoRoot, spec.source)

    // The source bytes the correspondence rules compare against: the manifest
    // plus every file the build copies verbatim into dist.
    const sources = new Map()
    for (const rel of [`${spec.source}/package.json`, ...Object.keys(spec.copied || {})]) {
      const abs = join(repoRoot, rel)
      if (existsSync(abs)) sources.set(rel, readFileSync(abs))
    }

    const tarballs = {}
    const correspondence = {}
    for (const tpl of templates) {
      const entries = tarballEntries(join(repoRoot, tpl, 'vendor', spec.tarball))
      tarballs[tpl] = digestEntries(entries)
      correspondence[tpl] = correspondenceFailures(spec, sources, new Map(entries.map((e) => [e.path, e.bytes])))
    }
    let version = null
    try {
      version = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8')).version
    } catch {
      /* a package with no readable package.json is caught by sourceDigest */
    }
    out[pkg] = {
      sourceDigest: sourceDigest(pkgDir, SOURCE_INPUTS, spec.external || [], repoRoot),
      version,
      tarballs,
      correspondence,
    }
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

/**
 * The correspondence mismatches that make a package UNSTAMPABLE.
 *
 * Exported so the selftest can drive `--write`'s refusal in both directions
 * against REAL measurements, without a test that writes the real stamp file.
 * `writeStamp` calls exactly this — there is no second copy of the rule.
 */
export function blessingRefusals(pkg, measuredPkg) {
  return Object.entries(measuredPkg.correspondence || {}).flatMap(([tpl, ds]) => ds.map((d) => [tpl, d]))
}

function writeStamp(repoRoot = REPO_ROOT) {
  const measured = measure(repoRoot)
  const packages = {}
  for (const [pkg, m] of Object.entries(measured)) {
    // THE BLESSING WALL. --write records the source digest and the tarball
    // digest independently, so on its own it will happily stamp a tarball that
    // predates the source it is being stamped against. Every correspondence
    // rule that the gate enforces is enforced HERE FIRST: if the packed
    // artifact does not match the source it claims to be built from, there is
    // nothing legitimate to stamp, and the operator is sent to the re-cut.
    const mismatches = blessingRefusals(pkg, m)
    if (mismatches.length > 0) {
      console.log(
        `FAIL --write refuses to stamp ${pkg}: the packed artifact does not correspond to its source.\n` +
          mismatches.map(([tpl, d]) => `     ${tpl}: ${d}`).join('\n') +
          `\n     re-cut first: bash scripts/recut-vendor-tarballs.sh`
      )
      return false
    }
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

    // --- EXTERNAL BUILD INPUTS: the axis this gate used to be blind to -----
    //
    // Both packages build with `tsup && node ../../scripts/post-build-dts.mjs`,
    // and the react build copies api/assets/paper-surface/paper-surface.css
    // into dist. Neither file lives under js/packages/<pkg>, so until they were
    // listed in VENDORED[pkg].external, editing a REAL BUILD INPUT left the
    // source digest unmoved and the gate green over a tarball that no longer
    // matched. These arms mutate the real files, prove the digest MOVES, and
    // restore them byte-identically.
    //
    // The restore is in a `finally` and is verified: a selftest that leaves the
    // working tree dirty would be a worse defect than the one it guards.

    const realSourceDigest = (pkg) =>
      sourceDigest(join(REPO_ROOT, VENDORED[pkg].source), SOURCE_INPUTS, VENDORED[pkg].external, REPO_ROOT)

    /** Mutate a repo file; assert the digest moves for `moves` and NOT for `stays`; restore. */
    const externalInputMutation = (relPath, moves, stays) => {
      const abs = join(REPO_ROOT, relPath)
      if (!existsSync(abs)) throw new Error(`${relPath} does not exist — cannot prove it is a build input`)
      const original = readFileSync(abs)
      const before = {}
      for (const pkg of [...moves, ...stays]) before[pkg] = realSourceDigest(pkg)
      try {
        writeFileSync(abs, Buffer.concat([original, Buffer.from('\n/* vendor-freshness selftest mutant */\n')]))
        // ASSERT THE MUTATION LANDED before measuring anything: a write that
        // silently did nothing would make every arm below pass vacuously.
        const mutated = readFileSync(abs)
        if (mutated.equals(original)) throw new Error(`the mutation of ${relPath} did not land`)
        if (!mutated.includes('vendor-freshness selftest mutant')) {
          throw new Error(`the mutant text is not present in ${relPath} on disk`)
        }
        for (const pkg of moves) {
          if (realSourceDigest(pkg) === before[pkg]) {
            throw new Error(
              `editing ${relPath} did not move ${pkg}'s source digest — the gate is blind to a real build input`
            )
          }
        }
        for (const pkg of stays) {
          eq(realSourceDigest(pkg), before[pkg], `${pkg} digest while ${relPath} is mutated (it is not ${pkg}'s input)`)
        }
      } finally {
        writeFileSync(abs, original)
      }
      if (!readFileSync(abs).equals(original)) throw new Error(`failed to restore ${relPath}`)
      for (const pkg of [...moves, ...stays]) eq(realSourceDigest(pkg), before[pkg], `${pkg} digest after restoring ${relPath}`)
    }

    check('mutating js/scripts/post-build-dts.mjs invalidates freshness for BOTH packages; restoring passes', () => {
      externalInputMutation('js/scripts/post-build-dts.mjs', ['@barkpark/core', '@barkpark/react'], [])
    })

    check('mutating api/assets/paper-surface/paper-surface.css invalidates freshness for @barkpark/react, and NOT for @barkpark/core; restoring passes', () => {
      externalInputMutation('api/assets/paper-surface/paper-surface.css', ['@barkpark/react'], ['@barkpark/core'])
    })

    check('an external build input that does not exist THROWS instead of hashing nothing', () => {
      let raised = false
      try {
        sourceDigest(join(REPO_ROOT, 'js/packages/core'), SOURCE_INPUTS, ['js/scripts/no-such-input.mjs'], REPO_ROOT)
      } catch {
        raised = true
      }
      if (!raised) throw new Error('a missing external input was skipped — a typo would reinstate the blindness')
    })

    check('every vendored package lists the post-build declaration script as a build input', () => {
      for (const [pkg, spec] of Object.entries(VENDORED)) {
        const manifest = JSON.parse(readFileSync(join(REPO_ROOT, spec.source, 'package.json'), 'utf8'))
        const buildScript = (manifest.scripts || {}).build || ''
        for (const m of buildScript.matchAll(/node\s+\.\.\/\.\.\/scripts\/([A-Za-z0-9._-]+)/g)) {
          const rel = `js/scripts/${m[1]}`
          if (!(spec.external || []).includes(rel)) {
            throw new Error(`${pkg}'s build runs ${rel} but VENDORED['${pkg}'].external does not list it`)
          }
        }
      }
    })

    // --- SOURCE -> ARTIFACT CORRESPONDENCE, pure arms ----------------------

    const CORR_SPEC = {
      source: 'js/packages/fix',
      copied: { 'api/assets/x.css': 'package/dist/x.css' },
    }
    const buildCorr = (mut = (s, e) => {}) => {
      const sources = new Map([
        ['js/packages/fix/package.json', Buffer.from('{"name":"@fix/pkg","version":"1.0.0"}\n')],
        ['api/assets/x.css', Buffer.from('.a{color:red}\n')],
      ])
      const entries = new Map([
        ['package/package.json', Buffer.from('{"name":"@fix/pkg","version":"1.0.0"}\n')],
        ['package/dist/x.css', Buffer.from('.a{color:red}\n')],
        ['package/dist/index.d.ts', Buffer.from('export declare const a: number\n')],
        ['package/dist/index.d.mts', Buffer.from('export declare const a: number\n')],
        ['package/dist/index.d.cts', Buffer.from('export declare const a: number\n')],
      ])
      mut(sources, entries)
      return correspondenceFailures(CORR_SPEC, sources, entries)
    }

    check('correspondenceFailures is GREEN when the artifact corresponds to the source', () => {
      eq(buildCorr(), [], 'corresponding verdict')
    })

    check('correspondenceFailures reds COPIED-ASSET when the source stylesheet moved but the artifact did not', () => {
      const f = buildCorr((sources) => sources.set('api/assets/x.css', Buffer.from('.a{color:blue}\n')))
      if (f.length !== 1 || !f[0].startsWith('COPIED-ASSET')) throw new Error(`wrong verdict: ${JSON.stringify(f)}`)
      if (!f[0].includes('package/dist/x.css')) throw new Error('the failure does not name the artifact path')
    })

    check('correspondenceFailures reds COPIED-ASSET when the artifact is missing the copied file entirely', () => {
      const f = buildCorr((_s, entries) => entries.delete('package/dist/x.css'))
      if (!f.some((d) => d.startsWith('COPIED-ASSET'))) throw new Error(`no copied-asset verdict: ${JSON.stringify(f)}`)
    })

    check('correspondenceFailures reds MANIFEST when the packed manifest is not the source manifest', () => {
      const f = buildCorr((_s, entries) =>
        entries.set('package/package.json', Buffer.from('{"name":"@fix/pkg","version":"9.9.9"}\n'))
      )
      if (!f.some((d) => d.startsWith('MANIFEST') && d.includes('version'))) {
        throw new Error(`no manifest verdict naming version: ${JSON.stringify(f)}`)
      }
    })

    check('correspondenceFailures reds a MANIFEST difference NESTED inside exports, not just a top-level field', () => {
      // The regression control for a bug this file shipped for one commit:
      // `JSON.stringify(o, Object.keys(o).sort())` treats its array argument as
      // a property whitelist at EVERY depth, so it serialised `exports` as `{}`
      // and two manifests differing only inside it compared equal.
      const nested = (importPath) =>
        Buffer.from(`{"name":"@fix/pkg","version":"1.0.0","exports":{".":{"import":"${importPath}"}}}\n`)
      const f = buildCorr((sources, entries) => {
        sources.set('js/packages/fix/package.json', nested('./dist/index.mjs'))
        entries.set('package/package.json', nested('./dist/DIFFERENT.mjs'))
      })
      if (!f.some((d) => d.startsWith('MANIFEST') && d.includes('exports'))) {
        throw new Error(`a nested exports difference was not seen: ${JSON.stringify(f)}`)
      }
      // ...and the same shape with no difference must still be GREEN.
      eq(
        buildCorr((sources, entries) => {
          sources.set('js/packages/fix/package.json', nested('./dist/index.mjs'))
          entries.set('package/package.json', nested('./dist/index.mjs'))
        }),
        [],
        'identical nested manifests'
      )
    })

    check('correspondenceFailures ACCEPTS pnpm rewriting a workspace: specifier but REJECTS one that survived', () => {
      const withDep = (srcRange, artRange) =>
        buildCorr((sources, entries) => {
          sources.set(
            'js/packages/fix/package.json',
            Buffer.from(`{"name":"@fix/pkg","version":"1.0.0","dependencies":{"@fix/core":"${srcRange}"}}\n`)
          )
          entries.set(
            'package/package.json',
            Buffer.from(`{"name":"@fix/pkg","version":"1.0.0","dependencies":{"@fix/core":"${artRange}"}}\n`)
          )
        })
      eq(withDep('workspace:^', '^1.0.0'), [], 'pnpm-rewritten specifier')
      const leaked = withDep('workspace:^', 'workspace:^')
      if (!leaked.some((d) => d.includes('workspace:'))) {
        throw new Error(`a leaked workspace: specifier was accepted: ${JSON.stringify(leaked)}`)
      }
    })

    check('correspondenceFailures reds DTS-PAIRING when the .d.mts sibling is missing or stale', () => {
      const missing = buildCorr((_s, entries) => entries.delete('package/dist/index.d.mts'))
      if (!missing.some((d) => d.startsWith('DTS-PAIRING'))) throw new Error(`no pairing verdict: ${JSON.stringify(missing)}`)
      const stale = buildCorr((_s, entries) =>
        entries.set('package/dist/index.d.mts', Buffer.from('export declare const a: string\n'))
      )
      if (!stale.some((d) => d.startsWith('DTS-PAIRING'))) throw new Error(`a stale .d.mts was accepted: ${JSON.stringify(stale)}`)
    })

    check('correspondenceFailures reds a pack with NO declarations rather than passing vacuously', () => {
      const f = buildCorr((_s, entries) => {
        entries.delete('package/dist/index.d.ts')
        entries.delete('package/dist/index.d.mts')
      })
      if (!f.some((d) => d.includes('no .d.ts/.d.mts pair at all'))) throw new Error(`empty dist passed: ${JSON.stringify(f)}`)
    })

    check('adjudicate surfaces a correspondence mismatch as SOURCE-ARTIFACT-MISMATCH', () => {
      const m = JSON.parse(JSON.stringify(FRESH_MEASURED))
      m['@barkpark/core'].correspondence = { 'templates/search-starter': ['COPIED-ASSET fixture mismatch'] }
      const f = adjudicate(FRESH_STAMP, m)
      eq(reasons(f), ['SOURCE-ARTIFACT-MISMATCH'], 'mismatch reasons')
      if (!f[0].detail.includes('COPIED-ASSET fixture mismatch')) throw new Error('the detail was dropped')
    })

    // --- THE BLESSING WALL: --write cannot stamp a stale tarball ----------
    //
    // This is the defect the gate could not previously see. --write records the
    // source digest and the tarball digest INDEPENDENTLY, so before this wall
    // existed, editing a build input and running --write produced a green stamp
    // over an unchanged, now-stale tarball. The arm below mutates a real build
    // input on disk, re-measures the REAL repo, and proves --write's own
    // refusal predicate fires — then restores and proves it stops firing.

    check('RED/GREEN: --write REFUSES to bless the committed tarball after the paper-surface CSS changes, and stops refusing when it is restored', () => {
      const rel = 'api/assets/paper-surface/paper-surface.css'
      const abs = join(REPO_ROOT, rel)
      const original = readFileSync(abs)

      // GREEN before: the committed tarballs do correspond to the tree as it stands.
      const greenBefore = measure()
      for (const [pkg, m] of Object.entries(greenBefore)) {
        eq(blessingRefusals(pkg, m), [], `${pkg} refusals before the mutation`)
      }

      let red = null
      try {
        writeFileSync(abs, Buffer.concat([original, Buffer.from('\n/* vendor-freshness selftest mutant */\n')]))
        const onDisk = readFileSync(abs)
        if (onDisk.equals(original)) throw new Error('the CSS mutation did not land')
        if (!onDisk.includes('vendor-freshness selftest mutant')) throw new Error('the mutant text is not on disk')
        red = measure()
      } finally {
        writeFileSync(abs, original)
      }
      if (!readFileSync(abs).equals(original)) throw new Error(`failed to restore ${rel}`)

      // RED: react is unstampable, and the failure names the artifact.
      const reactRefusals = blessingRefusals('@barkpark/react', red['@barkpark/react'])
      if (reactRefusals.length === 0) {
        throw new Error('--write would still have blessed the tarball after a build input changed')
      }
      if (!reactRefusals.every(([, d]) => d.includes('package/dist/paper-surface.css'))) {
        throw new Error(`refusal does not name the stale artifact: ${JSON.stringify(reactRefusals)}`)
      }
      // The gate reds on the same measurement, with the named reason.
      const gateFailures = adjudicate(readStamp(), red)
      if (!gateFailures.some((f) => f.reason === 'SOURCE-ARTIFACT-MISMATCH' && f.pkg === '@barkpark/react')) {
        throw new Error(`the gate did not red SOURCE-ARTIFACT-MISMATCH: ${JSON.stringify(gateFailures.map((f) => f.reason))}`)
      }
      // CONTROL: core vendors no copied asset, so it must stay stampable —
      // a wall that refuses everything proves nothing.
      eq(blessingRefusals('@barkpark/core', red['@barkpark/core']), [], '@barkpark/core refusals during the mutation')

      // GREEN after: restoring the input makes the tarball stampable again.
      const greenAfter = measure()
      for (const [pkg, m] of Object.entries(greenAfter)) {
        eq(blessingRefusals(pkg, m), [], `${pkg} refusals after restoring ${rel}`)
      }
    })

    check('the committed tarballs correspond to the current source on every template', () => {
      const m = measure()
      for (const [pkg, meas] of Object.entries(m)) {
        const seen = Object.keys(meas.correspondence || {})
        eq(seen.sort(), [...TEMPLATES].sort(), `${pkg} correspondence templates measured`)
        for (const [tpl, ds] of Object.entries(meas.correspondence)) {
          if (ds.length > 0) throw new Error(`${pkg} @ ${tpl}: ${ds.join('; ')}`)
        }
      }
    })

    // --- THE VERDICT WIRING, graded on the whole program ------------------
    //
    // task-92a213f01ca30817. Every check above grades adjudicate / measure /
    // blessingRefusals IN PROCESS; none executes main()'s `return gate() ? 0 : 1`,
    // the one line that turns the verdict into the PROCESS exit, so disarming it
    // kept this selftest green while CI certified a stale vendor. Same idiom as
    // PR #13405 / #20180: RE-EXEC THE WHOLE PROGRAM on a fixture root and assert
    // the PROCESS exit. REPO_ROOT derives from the script's own location, so a
    // copy at <root>/scripts/ reads only the fixture — no override — and the
    // fixture is a COPY of every input the gate reads (stamp, both templates'
    // tarballs, both package sources, the external build inputs), so the plant
    // lands in the copy and the real tree is never written.

    check('E2E: the whole program exits 1 on a stale build input, 0 once restored, 1 on an empty root', () => {
      const root = join(dir, 'e2e-root')
      const copy = (rel) => cpSync(join(REPO_ROOT, rel), join(root, rel), { recursive: true })
      mkdirSync(join(root, 'scripts'), { recursive: true })
      copy('scripts/check-vendor-freshness.mjs')
      copy(STAMP_REL)
      for (const tpl of TEMPLATES) {
        for (const spec of Object.values(VENDORED)) copy(`${tpl}/vendor/${spec.tarball}`)
      }
      for (const spec of Object.values(VENDORED)) {
        for (const d of SOURCE_INPUTS.dirs) copy(`${spec.source}/${d}`)
        for (const f of SOURCE_INPUTS.files) if (existsSync(join(REPO_ROOT, spec.source, f))) copy(`${spec.source}/${f}`)
        for (const e of spec.external || []) if (!existsSync(join(root, e))) copy(e)
      }
      const exec = (r) =>
        spawnSync(process.execPath, [join(r, 'scripts/check-vendor-freshness.mjs')], { encoding: 'utf8' })

      const css = join(root, 'api/assets/paper-surface/paper-surface.css')
      const original = readFileSync(css)
      writeFileSync(css, Buffer.concat([original, Buffer.from('\n/* vendor-freshness e2e plant */\n')]))
      const planted = exec(root)
      if (planted.status !== 1) throw new Error(`planted stale input must exit 1, got ${planted.status}\n${planted.stdout}${planted.stderr}`)
      if (!/FAIL STALE-SOURCE @barkpark\/react/.test(planted.stdout)) throw new Error(`exit 1 but not for the plant:\n${planted.stdout}`)

      writeFileSync(css, original)
      const removed = exec(root)
      if (removed.status !== 0) throw new Error(`restored input must exit 0, got ${removed.status}\n${removed.stdout}${removed.stderr}`)

      const empty = join(dir, 'e2e-empty')
      mkdirSync(join(empty, 'scripts'), { recursive: true })
      cpSync(join(REPO_ROOT, 'scripts/check-vendor-freshness.mjs'), join(empty, 'scripts/check-vendor-freshness.mjs'))
      const none = exec(empty)
      if (none.status === 0) throw new Error('an EMPTY root exited 0 — a green over nothing')
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

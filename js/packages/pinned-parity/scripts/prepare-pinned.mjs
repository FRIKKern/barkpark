#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// PREPARE THE PINNED ARTIFACT — the hard prerequisite of this package's suite.
// It is invoked from `vitest.globalSetup.ts`, wired as `globalSetup` on this
// package's own vitest config, so it runs on EVERY invocation path (the package
// script, the monorepo root `npx vitest run`, `--project=`, an IDE runner) and
// not just from a package.json script chain. A cold checkout therefore cannot
// produce a vacuous pass: if this script cannot materialise a real tarball it
// exits non-zero and vitest never runs, and if it somehow produced nothing the
// suite's own preflight throws rather than skipping.
//
// WHAT IS PINNED. Every other parity package in this monorepo consumes
// `@barkpark/react` as `workspace:^` — always-current SOURCE, re-transpiled by
// the test runner. That can never catch the drift class an EXTERNAL consumer
// actually hits, because a consumer installs an ARTIFACT: a fixed tarball whose
// `files` list, `exports` map and prebuilt `dist/**` are frozen at publish time.
// This script materialises exactly that artifact and the suite renders the
// CURRENT Elixir goldens through it.
//
// INPUT (`BARKPARK_PINNED_REACT`), three accepted forms:
//   unset / "workspace-pack"  → `npm pack` the workspace @barkpark/react into a
//                               tarball (the default; offline, deterministic,
//                               and the only form CI can run without network).
//   <path ending in .tgz>     → a VENDORED tarball, used verbatim.
//   <npm spec>                → e.g. `@barkpark/react@1.0.0-preview.1`; fetched
//                               with `npm pack <spec>` (requires network).
//
// The tarball is extracted to `.pinned/package` (gitignored) and NEVER
// installed into the workspace: the pinned artifact's own bare imports
// (`react`, `@barkpark/core`) resolve upward into this package's node_modules,
// exactly as they would inside a consumer's install tree.
//
// NEGATIVE-CONTROL VARIANTS. Alongside the pristine extraction the script emits
// deliberately-WRONG copies of the same artifact under `.pinned/negative/<id>`.
// Each corruption is applied by literal string replacement whose occurrence
// count is ASSERTED to be non-zero — a corruption that silently matched nothing
// would make the negative control vacuous, so it hard-fails instead. The suite
// runs the same parity loop against those copies and requires them to RED.

import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = join(HERE, '..')
const REACT_PKG = resolve(PKG_ROOT, '..', 'react')
const PINNED_DIR = join(PKG_ROOT, '.pinned')
const TARBALL_DIR = join(PINNED_DIR, 'tarball')
const EXTRACT_DIR = join(PINNED_DIR, 'package')
const NEGATIVE_DIR = join(PINNED_DIR, 'negative')

/**
 * The negative controls. `find` MUST occur in the pristine artifact — the count
 * is asserted below, so a rename upstream breaks this loudly instead of
 * quietly disarming the proof.
 *
 * - `surface-class`: renames the `.bp-paper-surface` root the comparator
 *   unwraps past, so EVERY golden must red. Proves the lane can fail at all.
 * - `callout-class`: renames only the callout family's class, so the callout
 *   goldens must red while `paragraph` must stay GREEN. Present-in-file is not
 *   fires-when-it-should: the paired quiet arm is what proves the lane is
 *   discriminating rather than merely broken.
 */
const NEGATIVE_CONTROLS = [
  { id: 'surface-class', find: 'bp-paper-surface', replace: 'bp-paper-surface-DRIFT' },
  { id: 'callout-class', find: 'bp-callout', replace: 'bp-callout-DRIFT' },
]

function run(cmd, args, cwd) {
  return execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] })
}

function log(msg) {
  process.stdout.write(`prepare-pinned: ${msg}\n`)
}

/** Build the workspace @barkpark/react if its dist is absent (hard prerequisite). */
function ensureWorkspaceBuild() {
  const entry = join(REACT_PKG, 'dist', 'index.mjs')
  if (existsSync(entry)) return
  log('workspace @barkpark/react dist is ABSENT — building it (hard prerequisite)')
  run('pnpm', ['--filter', '@barkpark/core', '--filter', '@barkpark/react', 'build'], resolve(PKG_ROOT, '..', '..'))
  if (!existsSync(entry)) {
    throw new Error(`build completed but ${entry} is still missing — refusing to run a vacuous parity suite`)
  }
}

/** Produce the pinned tarball; returns its absolute path. */
function materialiseTarball(spec) {
  mkdirSync(TARBALL_DIR, { recursive: true })
  if (spec.endsWith('.tgz')) {
    const vendored = resolve(process.cwd(), spec)
    if (!existsSync(vendored)) throw new Error(`vendored tarball not found: ${vendored}`)
    const dest = join(TARBALL_DIR, 'pinned.tgz')
    cpSync(vendored, dest)
    log(`vendored tarball: ${vendored}`)
    return dest
  }
  if (spec === 'workspace-pack') {
    ensureWorkspaceBuild()
    const out = run('npm', ['pack', '--pack-destination', TARBALL_DIR], REACT_PKG).trim().split('\n').pop().trim()
    log(`packed the workspace artifact: ${out}`)
    return join(TARBALL_DIR, out)
  }
  const out = run('npm', ['pack', spec, '--pack-destination', TARBALL_DIR], PKG_ROOT).trim().split('\n').pop().trim()
  log(`fetched published artifact ${spec}: ${out}`)
  return join(TARBALL_DIR, out)
}

function extract(tarball) {
  mkdirSync(PINNED_DIR, { recursive: true })
  run('tar', ['-xzf', tarball, '-C', PINNED_DIR], PKG_ROOT)
  if (!existsSync(join(EXTRACT_DIR, 'package.json'))) {
    throw new Error(`extraction produced no ${EXTRACT_DIR}/package.json`)
  }
}

/** Every file in the extracted artifact, relative — this IS the shipped file list. */
function fileList(dir, prefix = '') {
  const out = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) out.push(...fileList(join(dir, e.name), `${prefix}${e.name}/`))
    else out.push(`${prefix}${e.name}`)
  }
  return out.sort()
}

function corrupt(id, find, replace) {
  const dest = join(NEGATIVE_DIR, id)
  rmSync(dest, { recursive: true, force: true })
  mkdirSync(dest, { recursive: true })
  cpSync(EXTRACT_DIR, join(dest, 'package'), { recursive: true })
  let hits = 0
  for (const rel of fileList(join(dest, 'package'))) {
    if (!/\.(mjs|cjs|js)$/.test(rel)) continue
    const file = join(dest, 'package', rel)
    const body = readFileSync(file, 'utf8')
    const n = body.split(find).length - 1
    if (n === 0) continue
    hits += n
    writeFileSync(file, body.split(find).join(replace))
  }
  if (hits === 0) {
    throw new Error(
      `negative control "${id}" matched ZERO occurrences of "${find}" in the pinned artifact — ` +
        `the control would be vacuous. Fix the literal, never delete the control.`,
    )
  }
  log(`negative control "${id}": ${hits} occurrence(s) of "${find}" corrupted`)
  return { id, find, replace, hits }
}

function main() {
  const spec = process.env.BARKPARK_PINNED_REACT?.trim() || 'workspace-pack'
  log(`spec = ${spec}`)
  rmSync(PINNED_DIR, { recursive: true, force: true })
  const tarball = materialiseTarball(spec)
  const bytes = readFileSync(tarball)
  extract(tarball)
  const files = fileList(EXTRACT_DIR)
  const manifest = {
    spec,
    tarball: tarball.slice(PKG_ROOT.length + 1),
    sha256: createHash('sha256').update(bytes).digest('hex'),
    byteLength: bytes.length,
    // Derived from the extraction, never a literal: this is the artifact's own census.
    fileCount: files.length,
    files,
    negativeControls: NEGATIVE_CONTROLS.map((c) => corrupt(c.id, c.find, c.replace)),
    preparedAt: new Date().toISOString(),
  }
  writeFileSync(join(PINNED_DIR, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`)
  log(`ready — ${files.length} shipped file(s), sha256 ${manifest.sha256.slice(0, 12)}…`)
}

main()

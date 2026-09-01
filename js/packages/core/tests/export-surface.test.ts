// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * EXPORT-SURFACE GATE — every `export` under `src/**` must be either reachable
 * from `src/index.ts` or declared private out loud.
 *
 * WHY THIS EXISTS
 * ---------------
 * A function that is correct in `@barkpark/core` but not re-exported from
 * `src/index.ts` does not stay unused. It gets hand-reimplemented in a
 * consuming package. Five such forks were measured in one night, all against
 * this package:
 *
 *   - `detectEdgeRuntime` (`src/util/edge-detect.ts`) forked into
 *     `@barkpark/nextjs`'s `live.tsx` — and forked BROKEN. The copy classified
 *     every plain browser as an edge runtime, so `<BarkparkLive/>` threw during
 *     render for any consumer whose bundler injects no `process` shim. The
 *     remedy was to export the original and delete the copy.
 *   - `assertSegment` (`src/util/guards.ts`) forked into
 *     `@barkpark/nextjs`'s `server/core.ts` as `assertPathSegment` — correctly.
 *     Same remedy: export the original, delete the copy.
 *   - `normalizeFieldList`, `pickRequestId`, `buildBaseHeaders` and
 *     `BARKPARK_VENDOR_ACCEPT` — four more mirrors, all in that same
 *     `server/core.ts`, all correct today.
 *
 * One of the first two came out broken. All the current forks being correct is
 * the sample, not the guarantee.
 *
 * THE CAUSE IS WRITTEN IN THE SOURCE. `@barkpark/nextjs`'s own
 * `normalizeFieldList` mirror carries this in its doc comment, verbatim:
 *
 *   "the @barkpark/core bundle sits bytes under its size cap, so widening its
 *    index for this helper was not worth the risk."
 *
 * That is the size budget deciding this package's export surface, in silence.
 * A downstream author discovered a door was shut and quietly retyped what was
 * behind it; nothing in this package ever said the door was shut, or why.
 *
 * This gate does not open the door. It makes the decision loud: a core author
 * must state that a symbol stays private and give a reason, instead of a
 * downstream author finding out by hitting the wall. Exporting the symbols
 * that should be exported is deferred separately (it costs gzipped bytes on a
 * budget with very little headroom) and tracked as task-296d7e0028c7e7e0.
 *
 * WHAT THIS GATE DOES NOT CATCH — stated plainly, because an overclaiming
 * comment is worse than no comment:
 *
 *  1. IT CATCHES UNREACHABILITY, NOT FORKING. Nothing here can see "a consumer
 *     copied a private function into their own package." Only a cross-package
 *     duplication scanner detects that. This gate attacks the CONDITION that
 *     produces forks (a useful symbol with no reachable door), not the forks
 *     themselves. Every one of the five forks above sat behind a symbol this
 *     gate would have flagged — but the gate learns nothing from the fork.
 *
 *  2. "EXPORTED BUT NOT RE-EXPORTED" IS A STRICT SUBSET OF "UNREACHABLE."
 *     A symbol that is not exported from its own module never enters this
 *     inventory at all, because `getExportsOfModule` cannot see it. That class
 *     is real and already has a specimen: `decodeErrorAndThrow` in
 *     `src/transport.ts` is a module-private `async function`, and
 *     `@barkpark/nextjs`'s `server/core.ts` mirrors it as `decodeAndThrow`.
 *     This gate is blind to it and always will be — catching that shape needs
 *     a duplication scanner, which is limit 1 again. Do not read a green here
 *     as "no core logic is duplicated downstream."
 *
 *  3. IT COVERS `@barkpark/core` ONLY. The reverse direction runs too —
 *     `@barkpark/react` has its own unreachable exports, two of which are
 *     reimplemented in `web/`. Extending this gate to that package is separate
 *     work and is not claimed here.
 *
 *  4. "HAS A REASON" IS ENFORCED AS A LENGTH FLOOR, which is a crude proxy. It
 *     stops a bare `@internal` and it stops `@internal internal helper`; it
 *     cannot stop thirty characters of determined filler. The floor buys the
 *     author a beat of thought, not a guarantee of insight. Review still owns
 *     whether a reason is honest.
 *
 * METHOD: the TypeScript compiler API. Module exports come from
 * `getExportsOfModule`, and reachability is decided by RESOLVED SYMBOL
 * IDENTITY, not by matching name strings — so a rename-on-re-export
 * (`export { a as b }`) correctly counts as exported, and two unrelated
 * modules that happen to export the same name are never confused.
 *
 * This file ships zero bundle bytes: it is a test, it is not in `src/`, and
 * nothing in `src/` imports it.
 */

import { describe, expect, it } from 'vitest'
import { readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import ts from 'typescript'

const SRC_DIR = fileURLToPath(new URL('../src', import.meta.url))
const INDEX_FILE = path.join(SRC_DIR, 'index.ts')

/**
 * Minimum characters of prose after `@internal` before we accept it as a
 * reason. See limit 4 in the moduledoc: this is a floor on effort, not a
 * measure of quality.
 */
const MIN_REASON_CHARS = 30

/**
 * Positive controls. If the compiler program fails to load — a bad path, a
 * resolution change, a TypeScript upgrade that renames an API — every lookup
 * below returns empty, the violation list is empty, and the gate goes GREEN
 * while inspecting nothing. That is the exact vacuous-pass shape this repo
 * keeps hitting, so the counts are asserted, not merely computed.
 *
 * These floors are deliberately far below the real numbers (237 module exports
 * / 207 index exports at the time of writing). They are tripwires for "the
 * instrument saw nothing," not a pinned inventory that reds on every new
 * export.
 */
const MIN_PLAUSIBLE_MODULE_EXPORTS = 150
const MIN_PLAUSIBLE_INDEX_EXPORTS = 150

interface Unreachable {
  name: string
  file: string
  isType: boolean
  reason: string | null
}

function walkTsFiles(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir)) {
    const p = path.join(dir, entry)
    if (statSync(p).isDirectory()) out.push(...walkTsFiles(p))
    else if (p.endsWith('.ts') && !p.endsWith('.d.ts')) out.push(p)
  }
  return out
}

const files = walkTsFiles(SRC_DIR).sort()

const program = ts.createProgram(files, {
  target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.Bundler,
  strict: true,
  noEmit: true,
  skipLibCheck: true,
})
const checker = program.getTypeChecker()

/** Follow `export { x } from` / `import`-alias chains to the declaring symbol. */
function resolveAlias(sym: ts.Symbol): ts.Symbol {
  let s = sym
  const seen = new Set<ts.Symbol>()
  while (s.flags & ts.SymbolFlags.Alias && !seen.has(s)) {
    seen.add(s)
    try {
      s = checker.getAliasedSymbol(s)
    } catch {
      break
    }
  }
  return s
}

function moduleExports(file: string): ts.Symbol[] {
  const sf = program.getSourceFile(file)
  if (!sf) return []
  const sym = checker.getSymbolAtLocation(sf)
  if (!sym) return []
  return checker.getExportsOfModule(sym)
}

/**
 * Read the `@internal` reason off a symbol.
 *
 * JSDoc does not always hang off the node the symbol points at: for
 * `export const X = ...` the comment sits on the enclosing VariableStatement,
 * two parents up from the VariableDeclaration. We therefore check the
 * declaration and its two ancestors, and accept a marker on ANY declaration of
 * the symbol (overload sets have several).
 *
 * Returns the trimmed reason text, `''` for a bare `@internal` with no prose,
 * or `null` when there is no `@internal` tag at all.
 */
function internalReason(sym: ts.Symbol): string | null {
  let sawTag = false
  for (const decl of sym.getDeclarations() ?? []) {
    const nodes: ts.Node[] = [decl]
    if (decl.parent) nodes.push(decl.parent)
    if (decl.parent?.parent) nodes.push(decl.parent.parent)
    for (const node of nodes) {
      for (const tag of ts.getJSDocTags(node)) {
        if (tag.tagName.escapedText !== 'internal') continue
        sawTag = true
        const raw = tag.comment
        const text = typeof raw === 'string' ? raw : (raw ?? []).map((p) => p.text ?? '').join('')
        const trimmed = text.trim()
        if (trimmed.length > 0) return trimmed
      }
    }
  }
  return sawTag ? '' : null
}

const indexExportSymbols = moduleExports(INDEX_FILE)
const indexReachable = new Set(indexExportSymbols.map(resolveAlias))

let totalModuleExports = 0
let reExported = 0
const unreachable: Unreachable[] = []

for (const file of files) {
  if (file === INDEX_FILE) continue
  for (const sym of moduleExports(file)) {
    totalModuleExports++
    const resolved = resolveAlias(sym)
    if (indexReachable.has(resolved)) {
      reExported++
      continue
    }
    unreachable.push({
      name: sym.getName(),
      file: path.relative(SRC_DIR, file),
      isType: (resolved.flags & ts.SymbolFlags.Value) === 0,
      reason: internalReason(sym),
    })
  }
}

unreachable.sort((a, b) => a.file.localeCompare(b.file) || a.name.localeCompare(b.name))

function remedy(u: Unreachable): string {
  return [
    `  ${u.isType ? 'type ' : 'value'}  ${u.name}  (src/${u.file})`,
    `         Either: re-export it from src/index.ts — it becomes part of the`,
    `                 public contract, and downstream stops retyping it.`,
    `         Or:     mark the declaration \`@internal <reason>\` (at least`,
    `                 ${MIN_REASON_CHARS} chars) saying why a consumer should not need`,
    `                 it, or what they should reach for instead.`,
  ].join('\n')
}

describe('export surface', () => {
  it('reads a plausible inventory (positive control — a silent no-op reads as green)', () => {
    expect(
      files.length,
      'no .ts files found under src/ — the walker or the path is wrong, and every ' +
        'assertion below is vacuous',
    ).toBeGreaterThan(10)

    expect(
      totalModuleExports,
      `only ${totalModuleExports} module exports found under src/** (expected >${MIN_PLAUSIBLE_MODULE_EXPORTS}). ` +
        'The TypeScript program almost certainly failed to load — getExportsOfModule ' +
        'returns [] for a file the program never parsed, which makes this whole gate ' +
        'pass while inspecting nothing.',
    ).toBeGreaterThan(MIN_PLAUSIBLE_MODULE_EXPORTS)

    expect(
      indexExportSymbols.length,
      `only ${indexExportSymbols.length} exports read from src/index.ts (expected >${MIN_PLAUSIBLE_INDEX_EXPORTS}). ` +
        'If index.ts reads as empty, EVERY module export looks unreachable — or, if ' +
        'the walk also failed, nothing looks like anything.',
    ).toBeGreaterThan(MIN_PLAUSIBLE_INDEX_EXPORTS)

    expect(
      reExported,
      'zero exports resolved back to index.ts — alias resolution is broken, so ' +
        'reachability is being decided by nothing at all',
    ).toBeGreaterThan(0)

    // Printed so a pass carries a real number rather than a bare tick.
    console.log(
      `[export-surface] ${totalModuleExports} module exports under src/** — ` +
        `${reExported} reachable from index.ts, ${unreachable.length} not ` +
        `(${unreachable.filter((u) => !u.isType).length} values, ` +
        `${unreachable.filter((u) => u.isType).length} types), ` +
        `${unreachable.filter((u) => u.reason).length} declared @internal with a reason`,
    )
  })

  it('exercises the @internal path (positive control — an unused branch proves nothing)', () => {
    // If nothing in the package is unreachable, the marker-reading code above
    // never runs, and a bug in internalReason() would be invisible until the
    // day someone adds an unreachable export. Today this package has plenty.
    // Should that ever legitimately drop to zero, delete this control — do not
    // weaken the real assertion to keep it happy.
    expect(
      unreachable.length,
      'no unreachable exports at all: internalReason() was never called, so the ' +
        'marker half of this gate is untested by this run',
    ).toBeGreaterThan(0)

    const withReason = unreachable.filter((u) => u.reason !== null && u.reason.length > 0)
    expect(
      withReason.length,
      'not one @internal reason was parsed out of the tree. Either every marker was ' +
        'stripped, or internalReason() stopped finding JSDoc tags — in which case the ' +
        'real assertion below is failing everything for the wrong cause.',
    ).toBeGreaterThan(0)
  })

  it('exports every symbol from index.ts, or declares it @internal with a reason', () => {
    const unmarked = unreachable.filter((u) => u.reason === null)
    const bare = unreachable.filter((u) => u.reason !== null && u.reason.length === 0)
    const thin = unreachable.filter(
      (u) => u.reason !== null && u.reason.length > 0 && u.reason.length < MIN_REASON_CHARS,
    )

    const problems: string[] = []

    if (unmarked.length > 0) {
      problems.push(
        `${unmarked.length} export(s) under src/** are NOT re-exported from src/index.ts ` +
          `and carry no @internal marker.\n\n` +
          `A symbol that is useful but unreachable does not stay unused — it gets ` +
          `retyped downstream. That has happened five times against this package, and ` +
          `one of the copies shipped broken. Pick a remedy for each:\n\n` +
          unmarked.map(remedy).join('\n\n'),
      )
    }

    if (bare.length > 0) {
      problems.push(
        `${bare.length} export(s) carry a bare @internal with no reason.\n\n` +
          `The marker without prose only restates itself. Say why a consumer should ` +
          `not need this symbol, or what they should use instead:\n\n` +
          bare.map(remedy).join('\n\n'),
      )
    }

    if (thin.length > 0) {
      problems.push(
        `${thin.length} export(s) carry an @internal reason under ${MIN_REASON_CHARS} characters.\n\n` +
          `"internal helper" restates the marker and teaches the next reader nothing. ` +
          `A good reason says why a consumer should not need this, or names the ` +
          `supported alternative:\n\n` +
          thin
            .map((u) => `${remedy(u)}\n         current reason: ${JSON.stringify(u.reason)}`)
            .join('\n\n'),
      )
    }

    expect(problems.join('\n\n' + '-'.repeat(74) + '\n\n')).toBe('')
  })
})

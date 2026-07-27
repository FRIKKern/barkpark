#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// build-harness.mjs — WebView spike harness builder (charter D11).
//
// SPIKE ARTIFACT, NOT PRODUCT CODE. Renders the capstone paper
// (barkpark-tasks-mobile-capstone: 104 blocks, 16 headings, 3 mermaid, 0 images)
// through the BUILT @barkpark/react `renderPortableDocument` (ROOT export — the
// './server' subpath does not exist, see mob-bl-react-server-export), wraps it in
// the `.bp-paper-surface` container the string form omits, skins it with the real
// dist/paper-surface.css (93,449 B, zero url() — fully self-contained), and writes
// BOTH WebView load variants into ./assets/:
//
//   assets/capstone-inline.html   — CSS inlined in <style>; app passes source={{html}}
//   assets/capstone-file.html     — <link href="paper-surface.css">; app copies both
//   assets/paper-surface.css        files to its documentDirectory and loads
//                                   file://…/capstone-file.html (baseUrl variant)
//
// Both variants carry the FMP instrumentation script (double-rAF after
// DOMContentLoaded → postMessage to React Native; a pure static-content FMP proxy —
// the doc has 0 images and the 3 mermaid mounts stay INERT, mermaid is deliberately
// NOT bundled).
//
// SELF-ASSERTS (exit non-zero on any failure):
//   1. capstone has exactly 104 blocks
//   2. every one of the 104 blocks renders non-empty HTML
//   3. 16 <h1-3> headings, ZERO empty (the D12 heading content[] fix, verified live)
//   4. 3 inert mermaid mounts (<pre class="mermaid">)
//   5. paper-surface.css present, >80 KB, zero url() (self-contained)
//   6. both variants written; total payload in the expected ~178 KB band
//
// Prereqs (run from the repo root):
//   pnpm install --filter @barkpark/core --filter @barkpark/react
//   (cd js/packages/core  && pnpm build)
//   (cd js/packages/react && pnpm build)
//
// Usage:
//   node build-harness.mjs             # fetch capstone via `bp` (guerrilla server)
//   node build-harness.mjs --cached    # reuse assets/capstone.json from a prior run
//
// The capstone fetch is READ-ONLY, via the `bp` CLI with the configured guerrilla
// token (falls back to a direct GET using ~/.config/barkpark/config.json
// known_servers if `bp` is not on PATH).

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync, rmSync, lstatSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..')
const REACT_PKG = join(REPO_ROOT, 'js', 'packages', 'react')
const ASSETS = join(HERE, 'assets')
const SERVER = process.env.BP_SPIKE_SERVER || 'https://guerrilla.barkpark.cloud'
const PAPER_ID = 'barkpark-tasks-mobile-capstone'

// ---------------------------------------------------------------- utilities
let failures = 0
function assert(cond, label, detail = '') {
  const mark = cond ? 'PASS' : 'FAIL'
  if (!cond) failures++
  console.log(`  [${mark}] ${label}${detail ? ` — ${detail}` : ''}`)
}

// ------------------------------------------------- 1. resolve @barkpark/react
// The spike is standalone (NOT in any pnpm workspace glob), so give Node a
// node_modules symlink to the BUILT workspace package. Root-export resolution
// (package.json "exports" map) still applies — this is exactly how pnpm links.
function ensureRendererLink() {
  const distIndex = join(REACT_PKG, 'dist', 'index.mjs')
  if (!existsSync(distIndex)) {
    console.error(
      `FATAL: ${distIndex} missing — build the renderer first:\n` +
        `  (cd ${join(REPO_ROOT, 'js/packages/core')} && pnpm build)\n` +
        `  (cd ${join(REPO_ROOT, 'js/packages/react')} && pnpm build)`,
    )
    process.exit(1)
  }
  const scope = join(HERE, 'node_modules', '@barkpark')
  const link = join(scope, 'react')
  mkdirSync(scope, { recursive: true })
  try {
    if (lstatSync(link, { throwIfNoEntry: false })) rmSync(link, { recursive: true })
  } catch {
    /* ignore */
  }
  symlinkSync(REACT_PKG, link, 'dir')
}

// ---------------------------------------------------- 2. fetch the capstone
function bpFetch() {
  if (process.env.BP_SPIKE_NO_BP) throw new Error('BP_SPIKE_NO_BP set — skipping bp CLI')
  const bp = join(homedir(), '.local', 'bin', 'bp')
  const bin = existsSync(bp) ? bp : 'bp'
  const out = execFileSync(bin, ['-s', SERVER, 'doc', 'get', 'paper', PAPER_ID, '--json'], {
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
  return JSON.parse(out)
}

async function directFetch() {
  // Fallback: read the guerrilla token from bp's own config. known_servers is a
  // LIST of {name, server, token, dataset, …} entries (verified live).
  const cfgPath = join(homedir(), '.config', 'barkpark', 'config.json')
  const cfg = JSON.parse(readFileSync(cfgPath, 'utf8'))
  const ks = cfg.known_servers || []
  const servers = Array.isArray(ks) ? ks : Object.values(ks)
  const host = new URL(SERVER).host
  const entry = servers.find((s) => {
    try {
      return new URL(s.server || s.url || '').host === host
    } catch {
      return false
    }
  })
  if (!entry || !entry.token) throw new Error(`no known_servers token for ${host} in ${cfgPath}`)
  const dataset = entry.dataset || 'production'
  // GET /v1/data/doc/<dataset>/paper/<id> — verified 200, body {"result": {...}}
  const r = await fetch(`${SERVER}/v1/data/doc/${dataset}/paper/${PAPER_ID}`, {
    headers: { Authorization: `Bearer ${entry.token}` },
  })
  if (!r.ok) throw new Error(`GET paper → ${r.status}`)
  const body = await r.json()
  return body.result || body
}

async function loadCapstone(useCached) {
  const cache = join(ASSETS, 'capstone.json')
  if (useCached && existsSync(cache)) {
    console.log(`capstone: cached (${cache})`)
    return JSON.parse(readFileSync(cache, 'utf8'))
  }
  let doc
  try {
    doc = bpFetch()
    console.log('capstone: fetched via bp CLI')
  } catch (e) {
    console.log(`capstone: bp CLI failed (${e.message.split('\n')[0]}); trying direct fetch`)
    doc = await directFetch()
    console.log('capstone: fetched directly with known_servers token')
  }
  mkdirSync(ASSETS, { recursive: true })
  writeFileSync(cache, JSON.stringify(doc))
  return doc
}

// -------------------------------------------------------- 3. HTML composition
// FMP proxy: double requestAnimationFrame after DOMContentLoaded — the content is
// fully static (0 images, inert mermaid), so the second painted frame after DOM
// parse IS first meaningful paint for this document.
const INSTRUMENT = `<script>
(function () {
  function post(m) {
    if (window.ReactNativeWebView) window.ReactNativeWebView.postMessage(JSON.stringify(m));
  }
  window.addEventListener('DOMContentLoaded', function () {
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        post({ kind: 'fmp', domMs: Math.round(performance.now()) });
      });
    });
  });
})();
</script>`

function page({ title, headExtra, body }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
${headExtra}
${INSTRUMENT}
</head>
<body>
${body}
</body>
</html>
`
}

// ------------------------------------------------------------------- main
const useCached = process.argv.includes('--cached')
ensureRendererLink()
const { renderPortableDocument } = await import('@barkpark/react')

const doc = await loadCapstone(useCached)
const blocks = doc.blocks || []

// Render — the string form omits the .bp-paper-surface wrapper (charter D11): add it.
const inner = renderPortableDocument(blocks)
const surface = `<div class="bp-paper-surface">\n${inner}\n</div>`

const css = readFileSync(join(REACT_PKG, 'dist', 'paper-surface.css'), 'utf8')

const inlineHtml = page({
  title: 'capstone — inline variant',
  headExtra: `<style>\n${css}\n</style>`,
  body: surface,
})
const fileHtml = page({
  title: 'capstone — file/baseUrl variant',
  headExtra: `<link rel="stylesheet" href="paper-surface.css">`,
  body: surface,
})

mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, 'capstone-inline.html'), inlineHtml)
writeFileSync(join(ASSETS, 'capstone-file.html'), fileHtml)
writeFileSync(join(ASSETS, 'paper-surface.css'), css)

// JS-string module for the Expo app: the inline variant feeds source={{html}}
// directly; the file variant's html+css strings are written to the app's
// documentDirectory at boot and loaded via file:// (the baseUrl variant). No
// metro assetExts tweaks, no expo-asset — the strings ride the JS bundle.
writeFileSync(
  join(ASSETS, 'generated.js'),
  `// GENERATED by build-harness.mjs — do not edit; re-run \`node build-harness.mjs\`.\n` +
    `export const inlineHtml = ${JSON.stringify(inlineHtml)}\n` +
    `export const fileHtml = ${JSON.stringify(fileHtml)}\n` +
    `export const paperSurfaceCss = ${JSON.stringify(css)}\n`,
)

// ------------------------------------------------------------ self-asserts
console.log('\nself-assertions:')

assert(blocks.length === 104, '104 blocks in the capstone paper', `got ${blocks.length}`)

const perBlock = blocks.map((b) => renderPortableDocument([b]))
const emptyBlocks = perBlock
  .map((html, i) => ({ html, i }))
  .filter(({ html }) => html.trim() === '')
assert(
  emptyBlocks.length === 0,
  'all 104 blocks render non-empty HTML',
  emptyBlocks.length
    ? `empty: ${emptyBlocks.map(({ i }) => `${blocks[i].type}#${blocks[i].id}`).join(', ')}`
    : `${perBlock.length}/104 non-empty`,
)

const headings = [...inner.matchAll(/<h([1-3])(?:\s[^>]*)?>([\s\S]*?)<\/h\1>/g)]
const emptyHeadings = headings.filter((m) => m[2].replace(/<[^>]*>/g, '').trim() === '')
assert(headings.length === 16, '16 <h1-3> heading tags rendered', `got ${headings.length}`)
assert(
  emptyHeadings.length === 0,
  '0 empty heading tags (D12 content[] fix live)',
  `${emptyHeadings.length} empty of ${headings.length}`,
)

const mermaidMounts = (inner.match(/<pre class="mermaid">/g) || []).length
assert(mermaidMounts === 3, '3 inert mermaid mounts (mermaid NOT bundled)', `got ${mermaidMounts}`)

const cssBytes = Buffer.byteLength(css)
assert(
  cssBytes > 80_000 && !css.includes('url('),
  'paper-surface.css self-contained (>80 KB, zero url())',
  `${cssBytes} B, url() count ${(css.match(/url\(/g) || []).length}`,
)

const inlineB = Buffer.byteLength(inlineHtml)
const fileB = Buffer.byteLength(fileHtml) + cssBytes
assert(
  inlineB > 0 && fileB > 0 && existsSync(join(ASSETS, 'generated.js')),
  'both variants produced (+ generated.js bundle module)',
  `inline ${inlineB} B; file ${fileB} B (html+css)`,
)
assert(
  inlineB >= 150_000 && inlineB <= 220_000,
  'inline payload in the expected ~178 KB band',
  `${(inlineB / 1024).toFixed(1)} KB`,
)

console.log(
  `\nwrote assets/capstone-inline.html (${inlineB} B), assets/capstone-file.html (${Buffer.byteLength(fileHtml)} B), assets/paper-surface.css (${cssBytes} B)`,
)

if (failures) {
  console.error(`\n${failures} self-assertion(s) FAILED`)
  process.exit(1)
}
console.log('\nall self-assertions passed')

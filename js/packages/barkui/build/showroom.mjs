// node build/showroom.mjs: writes dist/showroom/, one static page that opens
// from disk with no server and no network. Every part comes from discovery;
// nothing here names a part.
import { mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync, copyFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import * as esbuild from 'esbuild'
import { lintPartCss, inPartsLayer } from './css-lint.mjs'
import { discoverParts, hashFiles, partsDir } from './parts.mjs'
import { renderPage } from './page.mjs'

export const root = join(import.meta.dirname, '..')
export const outDir = join(root, 'dist', 'showroom')
export const proofPath = join(root, 'dist', 'proof.json')
// The one source of the skins. Copied into dist at build time, never committed twice.
export const tokensPath = join(root, '..', '..', '..', 'api', 'priv', 'barkui', 'tokens.css')

const require = createRequire(import.meta.url)
const uiSdkDir = dirname(require.resolve('@ui-sdk/web/package.json'))
export const uiSdkVersion = JSON.parse(readFileSync(join(uiSdkDir, 'package.json'), 'utf8')).version

/** Skin names, read from the sheet itself. */
export function skinNames(tokensCss) {
  return [...new Set([...tokensCss.matchAll(/\[data-skin="([\w-]+)"\]/g)].map((m) => m[1]))]
}

/** What every part's look and proof also rest on; a proof is stale when this moves. */
export function foundationHash() {
  const check = readdirSync(join(root, 'check')).filter((f) => f.endsWith('.mjs') && f !== 'shots.mjs')
  return hashFiles([
    ['tokens.css', readFileSync(tokensPath)],
    ['base.css', readFileSync(join(root, 'css', 'base.css'))],
    ['ui-sdk', uiSdkVersion],
    ['sheet-waits.mjs', readFileSync(join(root, 'build', 'sheet-waits.mjs'))],
    ...check.map((f) => [`check/${f}`, readFileSync(join(root, 'check', f))]),
  ])
}

/** Showroom only: `data-pin="hover"` (or active, focus-visible, checked) holds that state for viewing. Selectors ignore
    case, so this does too; the check reads every part's pinned rules back from the browser and refuses a state
    the pin did not reach (check/cssom.mjs). */
export function pinStates(css) {
  return css.replace(/(?<!\(\s*(?:any-)?hover\s*):(hover|active|focus-visible|checked)(?![-\w])/gi, (_, s) => `:is(:${s.toLowerCase()}, [data-pin~="${s.toLowerCase()}"])`)
}

// `bare` leaves every demo out of the script: the check's baseline for what the
// build itself puts on the page. `plantCss` is for the selftest alone: a sheet
// added after the lint, so it can plant breaks in paint that part.css may not.
export async function buildShowroom({ dir = partsDir, out = outDir, proof: proofFile = proofPath, quiet = false, bare = false, plantCss = '' } = {}) {
  const parts = discoverParts(dir)
  const lint = parts.flatMap((p) => lintPartCss(p.css).map((f) => `parts/${p.name}/part.css ${f}`))
  if (lint.length) throw new Error(`part.css may only read --ui-* and --bark-* colours:\n  ${lint.join('\n  ')}`)

  mkdirSync(out, { recursive: true })
  const tokens = readFileSync(tokensPath, 'utf8')
  copyFileSync(tokensPath, join(out, 'tokens.css'))

  const layered = [
    '@layer ui-sdk, bark-base, bark-parts, bark-focus;',
    readFileSync(join(uiSdkDir, 'browser', 'web.css'), 'utf8'),
    readFileSync(join(root, 'css', 'base.css'), 'utf8'),
    ...parts.map((p) => `/* parts/${p.name}/part.css */\n${inPartsLayer(p.css)}`),
  ].join('\n')
  writeFileSync(join(out, 'barkui.css'), pinStates(layered) + (plantCss ? `\n/* selftest plant */\n${plantCss}\n` : ''))
  writeFileSync(join(out, 'showroom.css'), readFileSync(join(root, 'build', 'showroom.css')))

  // Classic script so the page runs from file://. Part imports first, so every
  // element is defined before the controls and demos run.
  const imports = [...new Set(parts.flatMap((p) => p.json.imports))]
  const demos = bare ? [] : parts.filter((p) => p.demo)
  const entry = [
    ...imports.map((i) => `import ${JSON.stringify(i)}`),
    ...demos.map((p, i) => `import demo${i} from ${JSON.stringify(p.demo)}`),
    ...demos.map((p, i) => `demo${i}(document.querySelector(${JSON.stringify(`[data-part="${p.name}"]`)}))`),
    `import ${JSON.stringify(join(root, 'build', 'controls.mjs'))}`,
  ].join('\n')
  await esbuild.build({
    stdin: { contents: entry, resolveDir: root, sourcefile: 'showroom-entry.js' },
    bundle: true,
    format: 'iife',
    minify: true,
    target: 'es2022',
    legalComments: 'none',
    outfile: join(out, 'showroom.js'),
    logLevel: 'warning',
  })

  const proof = existsSync(proofFile) ? JSON.parse(readFileSync(proofFile, 'utf8')) : null
  const html = renderPage({ parts, proof, skins: skinNames(tokens), foundation: foundationHash(), uiSdkVersion })
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
  const twice = ids.filter((id, i) => ids.indexOf(id) !== i)
  if (twice.length) throw new Error(`the showroom page prints id "${twice[0]}" more than once`)
  writeFileSync(join(out, 'index.html'), html)
  if (!quiet) console.log(`showroom: ${parts.length} part(s) -> ${join(out, 'index.html')}${proof ? `, proof from ${proof.ranAt}` : ', no check run yet'}`)
  return { parts, file: join(out, 'index.html') }
}

if (process.argv[1] === import.meta.filename) {
  buildShowroom().catch((e) => {
    console.error(`showroom: ${e.message}`)
    process.exit(1)
  })
}

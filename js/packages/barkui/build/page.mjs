// The showroom page as one string. Parts arrive from discovery; proof lights
// arrive from dist/proof.json, written by the check. A light is on only when
// the last run proved it for this exact part folder and foundation.
/** The sheet's surfaces; the switch sets data-surface on every part's stage. */
export const SURFACES = ['base', 'raised', 'sunken', 'primary', 'inverse']

export const LIGHTS = [
  ['pressed', 'Pressed by real keys'],
  ['skins', 'Every skin'],
  ['schemes', 'Light and dark'],
  ['phone', 'Phone width'],
  ['noscript', 'Printed with no script'],
]

import { SHEET_WAITS } from './sheet-waits.mjs'

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

export function lightState(part, proof, foundation, key) {
  const run = proof?.parts?.[part.name]
  if (!run?.lights?.[key]) return { on: false, why: 'not run yet' }
  if (run.hash !== part.hash) return { on: false, why: 'stale: the part folder changed after the run' }
  if (proof.foundation !== foundation) return { on: false, why: 'stale: tokens, base styles, UI SDK or the check changed after the run' }
  if (run.failed || proof.errors?.length) return { on: false, why: 'the last run failed' }
  const l = run.lights[key]
  return { on: l.pass === true, why: l.detail || (l.pass ? 'proved' : 'failed') }
}

function lights(part, ctx) {
  const items = LIGHTS.map(([key, label]) => {
    const { on, why } = lightState(part, ctx.proof, ctx.foundation, key)
    const text = key === 'skins' ? `${ctx.skins.length} skins` : label
    return `<li class="sr-light" data-light="${key}" data-on="${on}"><span class="sr-dot" aria-hidden="true"></span><span>${esc(text)}</span><span class="sr-state">${on ? 'on' : 'off'}</span><span class="sr-why">${on ? '' : esc(why)}</span></li>`
  })
  return `<ul class="sr-lights" aria-label="Proof from the last check run">${items.join('')}</ul>`
}

/** Plain lines for what the sheet does not deliver yet, from the numbers the check measured. */
function waits(part, proof) {
  const measures = proof?.parts?.[part.name]?.measures ?? {}
  const lines = Object.entries(SHEET_WAITS)
    .filter(([key, w]) => measures[key] && measures[key].min < w.needs)
    .map(([key, w]) => `<p class="sr-wait">waiting on the sheet: ${esc(w.label)} ${measures[key].min.toFixed(2)}:1, needs ${w.needs}:1</p>`)
  const free = proof?.parts?.[part.name]?.paintFree ?? []
  if (free.length) lines.push(`<p class="sr-wait">${free.length} element${free.length === 1 ? '' : 's'} carry no paint: ${free.map((f) => esc(f.selector)).join(', ')}</p>`)
  return lines.join('')
}

function radios(name, label, values, checked) {
  const items = values.map(
    (v) => `<label class="sr-radio"><input type="radio" name="${name}" value="${esc(v)}"${v === checked ? ' checked' : ''}><span>${esc(v)}</span></label>`,
  )
  return `<fieldset class="sr-group"><legend>${label}</legend>${items.join('')}</fieldset>`
}

function partSection(part, ctx) {
  const { name, json } = part
  return `<section class="sr-part" id="part-${name}" aria-labelledby="part-${name}-title">
  <header class="sr-part-head">
    <h2 id="part-${name}-title" tabindex="-1">${esc(name)}</h2>
    <p class="sr-meta">${esc(json.family)} · <code>&lt;${esc(json.element)}&gt;</code></p>
    <p class="sr-summary">${esc(json.summary)}</p>
    ${lights(part, ctx)}
    ${waits(part, ctx.proof)}
  </header>
  <div class="sr-stage" data-part="${name}" data-surface="base">
${part.example}
  </div>
  <details class="sr-source"><summary>Markup: parts/${name}/example.html</summary><pre><code>${esc(part.example)}</code></pre></details>
</section>`
}

export function renderPage({ parts, proof, skins, foundation, uiSdkVersion }) {
  const ctx = { proof, skins, foundation }
  const failed = proof && [...Object.entries(proof.parts ?? {}).filter(([, r]) => r.failed).map(([n, r]) => `${n}: ${r.failed}`), ...(proof.errors ?? [])]
  const run = failed?.length
    ? `The last check run failed at <time datetime="${esc(proof.ranAt)}">${esc(proof.ranAt.replace('T', ' ').slice(0, 16))} UTC</time>, so no light is on: ${esc(failed[0])}.`
    : proof
    ? `Proof lights from the check run at <time datetime="${esc(proof.ranAt)}">${esc(proof.ranAt.replace('T', ' ').slice(0, 16))} UTC</time> in ${esc(proof.browser)}.`
    : 'No check run yet, so every proof light is off. Run <code>pnpm run check</code>.'
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BarkUI showroom</title>
<link rel="stylesheet" href="barkui.css">
<link rel="stylesheet" href="tokens.css">
<link rel="stylesheet" href="showroom.css">
<script src="showroom.js" defer></script>
</head>
<body>
<header class="sr-top">
  <div class="sr-title">
    <h1>BarkUI</h1>
    <p>${parts.length} part${parts.length === 1 ? '' : 's'} on UI SDK ${esc(uiSdkVersion)}. ${run}</p>
  </div>
  <form class="sr-controls" data-controls hidden aria-label="View">
    ${radios('skin', 'Skin', skins, skins[0])}
    ${radios('scheme', 'Scheme', ['light', 'dark', 'system'], 'system')}
    ${radios('surface', 'Surface', SURFACES, 'base')}
    ${radios('width', 'Width', ['desktop', 'phone'], 'desktop')}
  </form>
</header>
<div class="sr-body">
  <nav class="sr-index" aria-label="Parts"><ul>${parts.map((p) => `<li><a href="#part-${p.name}">${esc(p.name)}</a></li>`).join('')}</ul></nav>
  <main class="sr-main">
${parts.map((p) => partSection(p, ctx)).join('\n')}
  </main>
</div>
</body>
</html>
`
}

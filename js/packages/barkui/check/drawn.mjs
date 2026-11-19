// Everything in a stage is judged by what is drawn, and drawn in full.
// installDrawn runs inside the check's isolated world after installHelpers and
// installBoundary (it is serialised, so it may not reach anything outside its
// own body) and adds its readers to the same helper object.
//
// The check captures the stage three times: as drawn, with every glyph
// unpainted, and with every graphic (svg, img, a pseudo-element with a box)
// unpainted; each toggle is an !important sheet in the earliest cascade layer,
// put there from the isolated world. A thing's ink is the pixels that differ
// when it is toggled off, weighed by how far each moved (so a colour or a fade
// does not change the amount). That amount must be at least 90% of the same
// thing drawn alone by the check, unclipped and uncovered (the same string in
// the same font for text, a copy of the node for a graphic): anything less is
// cut. Contrast is read from the core of the ink (the strongest tenth), the
// colour as drawn against what is drawn there without it: 4.5:1 for text, 3:1
// for a graphic. Covers, filters, blend modes, opacity anywhere above, masks,
// clips, transforms and font sizes all show up in the pixels.
export function installDrawn() {
  const h = window.__barkCheck
  const box = (r, pad = 0) => ({ x: r.left + scrollX - pad, y: r.top + scrollY - pad, w: r.width + 2 * pad, h: r.height + 2 * pad })
  const textRects = (node, pad = 0) => {
    const range = document.createRange()
    range.selectNodeContents(node)
    return [...range.getClientRects()].filter((r) => r.width >= 1 && r.height >= 1).map((r) => box(r, pad))
  }
  const textNodes = (el) => {
    const out = []
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    for (let n; (n = walk.nextNode()); ) if (n.textContent.trim()) out.push(n)
    return out
  }
  const quiet = (el) => !!el.closest('[data-disabled], :disabled')
  /** Text kept for screen readers only: inside a box of at most 1px that clips what overflows it. */
  const forReadersOnly = (el, root) => {
    for (let n = el; n && n !== root; n = n.parentElement) {
      const r = n.getBoundingClientRect()
      const s = getComputedStyle(n)
      if (r.width <= 1 && r.height <= 1 && (s.overflowX !== 'visible' || s.clip !== 'auto' || s.clipPath !== 'none')) return true
    }
    return false
  }
  const FONT = ['font-family', 'font-size', 'font-weight', 'font-style', 'font-stretch', 'font-variant', 'font-feature-settings', 'font-variation-settings', 'font-kerning', 'font-optical-sizing', 'text-transform', '-webkit-font-smoothing']
  const fontOf = (s) => FONT.map((p) => `${p}: ${s.getPropertyValue(p)}`).join('; ')
  /** The text a pseudo-element's content says, or null when it comes from a counter or an attribute. */
  const said = (content) => {
    if (/counter|attr\(/.test(content)) return null
    return [...content.matchAll(/"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/g)].map((m) => m[1] ?? m[2]).join('').replace(/\s+/g, ' ').trim()
  }
  const BOX = ['width', 'height', 'border-top-width', 'border-right-width', 'border-bottom-width', 'border-left-width', 'border-top-style', 'border-right-style', 'border-bottom-style', 'border-left-style', 'border-top-left-radius', 'border-top-right-radius', 'border-bottom-left-radius', 'border-bottom-right-radius', 'background-image', 'background-size', 'background-position', 'background-repeat', 'mask-image', 'mask-size', 'mask-position', 'mask-repeat', '-webkit-mask-image', '-webkit-mask-size', '-webkit-mask-position', '-webkit-mask-repeat']
  const SIDES = ['top', 'right', 'bottom', 'left']
  /** A pseudo-element that draws a box of its own: its look, in black, for drawing it alone. */
  const boxOf = (ps) => {
    if (!(parseFloat(ps.width) > 0 && parseFloat(ps.height) > 0)) return null
    const edges = SIDES.filter((d) => parseFloat(ps.getPropertyValue(`border-${d}-width`)) > 0 && ps.getPropertyValue(`border-${d}-style`) !== 'none' && h.rgba(ps.getPropertyValue(`border-${d}-color`))[3] > 0)
    const fill = h.rgba(ps.backgroundColor)[3] > 0
    if (!fill && !edges.length && ps.backgroundImage === 'none') return null
    const look = BOX.map((p) => `${p}: ${ps.getPropertyValue(p)}`)
    look.push(`background-color: ${fill ? '#000' : 'transparent'}`, ...SIDES.map((d) => `border-${d}-color: ${edges.includes(d) ? '#000' : 'transparent'}`))
    return look.join('; ')
  }

  // The things of the current view, kept here so their elements never cross to the page or to Node.
  let items = []
  const keyed = new Map()
  /** Every visible thing in the stage: text runs and graphics, with the boxes their ink sits in. */
  const things = (root) => {
    items = []
    const graphicEls = [...root.querySelectorAll('svg, img')].filter((g) => !(g.parentElement?.closest('svg')) && g.checkVisibility())
    const painting = new Map()
    for (const el of h.shown(root)) {
      if (!el.checkVisibility()) continue
      for (const [p, ps, text] of h.pseudos(el)) {
        const look = p === '::before' || p === '::after' ? boxOf(ps) : null
        if (look) painting.set(el, [...(painting.get(el) ?? []), look])
        if (text) {
          const str = p === '::placeholder' ? el.getAttribute('placeholder') : p === '::marker' ? null : said(ps.content)
          const holes = textNodes(el).flatMap((n) => textRects(n))
          items.push({ kind: 'text', el, at: `${h.describe(el)}${p}`, quiet: quiet(el), rects: [box(el.getBoundingClientRect())], holes, key: str ? `text|${fontOf(ps)}|${str}` : null, draw: str ? { font: fontOf(ps), str } : null })
        }
      }
    }
    for (const n of textNodes(root)) {
      const el = n.parentElement
      if (el instanceof SVGElement || !el.checkVisibility() || forReadersOnly(el, root)) continue
      const str = n.textContent.replace(/\s+/g, ' ').trim()
      const font = fontOf(getComputedStyle(el))
      items.push({ kind: 'text', el, at: h.describe(el), quiet: quiet(el), rects: textRects(n, 1), key: `text|${font}|${str}`, draw: { font, str } })
    }
    const owner = (g) => g.closest(h.CONTROLS) ?? g.parentElement
    for (const g of graphicEls) {
      const r = g.getBoundingClientRect()
      if (r.width < 1 || r.height < 1) continue
      items.push({ kind: 'graphic', el: g, at: `${h.describe(owner(g))} ${g.tagName.toLowerCase()}`, quiet: quiet(g), rects: [box(r, 1)], key: `node|${items.length}|${r.width}x${r.height}|${g.outerHTML.length}`, draw: { node: g, w: r.width, h: r.height } })
    }
    for (const [el, looks] of painting) {
      const inner = [...painting.keys()].filter((x) => x !== el && el.contains(x)).concat(graphicEls.filter((g) => el.contains(g)))
      items.push({ kind: 'graphic', el, at: `${h.describe(el)}::before/::after`, quiet: quiet(el), rects: [box(el.getBoundingClientRect())], holes: inner.map((x) => box(x.getBoundingClientRect(), 1)), key: `box|${looks.join('|')}`, draw: { looks } })
    }
    return { count: items.length, missing: [...new Set(items.filter((t) => t.key && !keyed.has(t.key)).map((t) => t.key))] }
  }

  const PAINT = ['fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin', 'stroke-dasharray', 'stroke-dashoffset', 'fill-rule', 'clip-rule', 'display', 'object-fit', 'object-position']
  /** A copy of a node, drawn alone: its own shapes in black at its drawn size, with nothing above it to fade or clip it. */
  const copyOf = ({ node, w, h: ht }) => {
    const copy = node.cloneNode(true)
    const pairs = [[node, copy], ...[...node.querySelectorAll('*')].map((x, i) => [x, copy.querySelectorAll('*')[i]])]
    for (const [from, to] of pairs) {
      if (!to?.style) continue
      const s = getComputedStyle(from)
      for (const p of PAINT) to.style.setProperty(p, s.getPropertyValue(p))
      if (s.fill !== 'none') to.style.setProperty('fill', '#000')
      if (s.stroke !== 'none') to.style.setProperty('stroke', '#000')
      to.style.setProperty('opacity', '1')
      to.style.setProperty('visibility', 'visible')
      to.style.setProperty('filter', 'none')
    }
    copy.style.setProperty('display', 'block')
    copy.style.setProperty('width', `${w}px`)
    copy.style.setProperty('height', `${ht}px`)
    copy.style.setProperty('color', '#000')
    return copy
  }
  let sheet = null
  /** Lay out every thing not yet measured, alone, black on white, at the top of the document; returns its box. */
  const alone = (keys) => {
    sheet?.remove()
    sheet = document.createElement('div')
    sheet.setAttribute('style', 'all: initial; position: absolute; left: 0; top: 0; z-index: 2147483647; display: flex; flex-direction: column; align-items: flex-start; gap: 8px; padding: 8px; background: #fff; color: #000;')
    for (const key of keys) {
      const t = items.find((x) => x.key === key)
      const cell = document.createElement('div')
      cell.dataset.key = key
      cell.setAttribute('style', 'all: initial; display: block; padding: 4px; background: #fff; color: #000; line-height: normal; white-space: pre;')
      if (t.draw.str) {
        cell.setAttribute('style', `${cell.getAttribute('style')} ${t.draw.font};`)
        cell.textContent = t.draw.str
      } else if (t.draw.node) cell.append(copyOf(t.draw))
      else for (const look of t.draw.looks) cell.append(Object.assign(document.createElement('div'), { style: `all: initial; display: block; ${look}` }))
      sheet.append(cell)
    }
    document.documentElement.append(sheet)
    return box(sheet.getBoundingClientRect())
  }

  const pixels = async (b64) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
    const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }))
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height)
    const g = canvas.getContext('2d', { willReadFrequently: true })
    g.drawImage(bitmap, 0, 0)
    return { w: bitmap.width, h: bitmap.height, data: g.getImageData(0, 0, bitmap.width, bitmap.height).data }
  }
  const inside = (x, y, rs) => rs.some((r) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
  /** The ink between two captures inside some boxes: its amount (each pixel weighed by how far it moved,
      against the most any moved), how many pixels clearly moved, and the contrast of its core. */
  const ink = (a, b, clip, scale, rects, holes) => {
    const moved = []
    const strong = []
    for (const r of rects) {
      const x0 = Math.max(0, Math.floor((r.x - clip.x) * scale))
      const y0 = Math.max(0, Math.floor((r.y - clip.y) * scale))
      const x1 = Math.min(a.w, Math.ceil((r.x + r.w - clip.x) * scale))
      const y1 = Math.min(a.h, Math.ceil((r.y + r.h - clip.y) * scale))
      for (let y = y0; y < y1; y++)
        for (let x = x0; x < x1; x++) {
          if (holes?.length && inside(clip.x + x / scale, clip.y + y / scale, holes)) continue
          const i = (y * a.w + x) * 4
          const d = Math.max(Math.abs(a.data[i] - b.data[i]), Math.abs(a.data[i + 1] - b.data[i + 1]), Math.abs(a.data[i + 2] - b.data[i + 2]))
          if (d <= 8) continue
          moved.push(d)
          if (d > 16) strong.push(h.contrast([a.data[i], a.data[i + 1], a.data[i + 2]], [b.data[i], b.data[i + 1], b.data[i + 2]]))
        }
    }
    const top = moved.reduce((m, d) => Math.max(m, d), 0)
    const amount = moved.reduce((s, d) => s + Math.min(1, d / top), 0)
    strong.sort((p, q) => q - p)
    const core = strong.slice(0, Math.max(1, Math.ceil(strong.length / 10)))
    return { amount, count: strong.length, ratio: strong.length ? core[Math.floor(core.length / 2)] : 1 }
  }
  /** Measure the things drawn alone (white is what is under them). */
  const measureAlone = async (png, clip, scale) => {
    const a = await pixels(png)
    const white = { w: a.w, h: a.h, data: new Uint8ClampedArray(a.data.length).fill(255) }
    for (const cell of sheet.children) keyed.set(cell.dataset.key, ink(a, white, clip, scale, [box(cell.getBoundingClientRect())]).amount)
    sheet.remove()
    sheet = null
  }

  const TOGGLES = {
    glyphs: `*, *::before, *::after, *::marker, *::placeholder, *::first-letter, *::first-line { -webkit-text-fill-color: transparent !important;
      -webkit-text-stroke-color: transparent !important; text-shadow: none !important; text-decoration-color: transparent !important;
      text-emphasis-color: transparent !important; transition: none !important; }`,
    graphics: 'svg, img, *::before, *::after { opacity: 0 !important; transition: none !important; }',
  }
  let toggle = null
  /** Unpaint the glyphs or the graphics, or paint everything again (null). The sheet goes first in the document,
      so its layer is the earliest and its !important declarations win over any the page's own sheets make. */
  const unpaint = (what) => {
    toggle?.remove()
    toggle = null
    if (!what) return
    toggle = document.createElement('style')
    toggle.textContent = `@layer barkui-check { ${TOGGLES[what]} }`
    document.head.prepend(toggle)
  }

  /** Read every thing of the view from the three captures: does it draw, in full, and how strongly. Also every
      control that shows nothing, and every text-only control with no drawn label (see boundaries). */
  const judge = async (drawnPng, noGlyphsPng, noGraphicsPng, clip, scale, root) => {
    const [a, b, c] = await Promise.all([pixels(drawnPng), pixels(noGlyphsPng), pixels(noGraphicsPng)])
    const read = items.map((t) => ({ t, ...ink(a, t.kind === 'text' ? b : c, clip, scale, t.rects, t.holes) }))
    const shows = (el, kind) => read.some((r) => r.count >= 4 && el.contains(r.t.el) && (!kind || r.t.kind === kind))
    const empty = h.controls(root).filter((el) => !el.matches(h.FIELDS) && !shows(el)).map((el) => h.describe(el))
    const unlabelled = (h.state.bare ?? []).filter((el) => !shows(el, 'text')).map((el) => h.describe(el))
    return {
      things: read.map(({ t, amount, count, ratio }) => ({ kind: t.kind, at: t.at, quiet: t.quiet, draws: count >= 4, share: t.key && keyed.get(t.key) ? amount / keyed.get(t.key) : null, alone: t.key ? keyed.get(t.key) : null, ratio })),
      empty,
      unlabelled,
    }
  }

  Object.assign(h, { things, alone, measureAlone, unpaint, judge })
}

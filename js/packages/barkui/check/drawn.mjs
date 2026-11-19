// Text judged by what is drawn, and a control's boundary whatever token draws it.
// installDrawn runs inside the check's isolated world after installHelpers (it is
// serialised, so it may not reach anything outside its own body) and adds its
// readers to the same helper object.
//
// Drawn text: the check captures the stage twice, as drawn and with every glyph
// unpainted (an !important text fill of transparent in the earliest cascade
// layer, put there from the isolated world), and compares the two. The pixels
// that differ inside a run's boxes are its glyphs. The run's contrast is read
// from their core (the strongest tenth, not the anti-aliased rim): the glyph
// colour as drawn against what is drawn there without it. Covers, filters,
// blend modes, opacity anywhere above, masks, clips and a zero font size all
// show up in the pixels; none of them can answer for the reading.
export function installDrawn() {
  const h = window.__barkCheck
  const box = (r) => ({ x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height })
  const rectsOf = (node) => {
    const range = document.createRange()
    range.selectNodeContents(node)
    return [...range.getClientRects()].filter((r) => r.width >= 1 && r.height >= 1).map(box)
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

  /** Every run of text in the stage that a person is meant to see, with the boxes its glyphs sit in. */
  const runs = (root) => {
    const out = []
    const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    for (let n; (n = walk.nextNode()); ) {
      const el = n.parentElement
      if (!n.textContent.trim() || el instanceof SVGElement || !el.checkVisibility() || forReadersOnly(el, root)) continue
      out.push({ at: h.describe(el), quiet: quiet(el), rects: rectsOf(n) })
    }
    // Text drawn by a pseudo-element: its element's box, less the element's own text.
    for (const el of h.shown(root))
      for (const [p, , text] of h.pseudos(el)) {
        if (!text || !el.checkVisibility()) continue
        const own = [...el.childNodes].filter((c) => c.nodeType === 3 && c.textContent.trim()).flatMap(rectsOf)
        out.push({ at: `${h.describe(el)}${p}`, quiet: quiet(el), rects: [box(el.getBoundingClientRect())], holes: own })
      }
    return out
  }

  const GLYPHS = `@layer barkui-glyphs { *, *::before, *::after, *::marker, *::placeholder, *::first-letter, *::first-line {
    -webkit-text-fill-color: transparent !important; -webkit-text-stroke-color: transparent !important; text-shadow: none !important;
    text-decoration-color: transparent !important; text-emphasis-color: transparent !important; transition: none !important; } }`
  let unpainted = null
  /** Paint or unpaint every glyph. The sheet goes first in the document, so its layer is the earliest
      and its !important declarations win over any the page's own sheets make. */
  const glyphs = (paint) => {
    if (paint) {
      unpainted?.remove()
      unpainted = null
    } else if (!unpainted) {
      unpainted = document.createElement('style')
      unpainted.textContent = GLYPHS
      document.head.prepend(unpainted)
    }
  }

  const pixels = async (b64) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
    const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }))
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height)
    const g = canvas.getContext('2d', { willReadFrequently: true })
    g.drawImage(bitmap, 0, 0)
    return { w: bitmap.width, h: bitmap.height, data: g.getImageData(0, 0, bitmap.width, bitmap.height).data }
  }

  /** Each run's glyphs, from the stage as drawn (a) and without glyphs (b): does it draw, and how strongly. */
  const compare = async (a64, b64, clip, scale, list) => {
    const [a, b] = await Promise.all([pixels(a64), pixels(b64)])
    const inside = (x, y, rs) => rs.some((r) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
    return list.map((run) => {
      const seen = []
      for (const r of run.rects) {
        const x0 = Math.max(0, Math.floor((r.x - clip.x) * scale))
        const y0 = Math.max(0, Math.floor((r.y - clip.y) * scale))
        const x1 = Math.min(a.w, Math.ceil((r.x + r.w - clip.x) * scale))
        const y1 = Math.min(a.h, Math.ceil((r.y + r.h - clip.y) * scale))
        for (let y = y0; y < y1; y++)
          for (let x = x0; x < x1; x++) {
            if (run.holes && inside(clip.x + x / scale, clip.y + y / scale, run.holes)) continue
            const i = (y * a.w + x) * 4
            const pa = [a.data[i], a.data[i + 1], a.data[i + 2]]
            const pb = [b.data[i], b.data[i + 1], b.data[i + 2]]
            if (Math.max(Math.abs(pa[0] - pb[0]), Math.abs(pa[1] - pb[1]), Math.abs(pa[2] - pb[2])) > 16) seen.push(h.contrast(pa, pb))
          }
      }
      if (seen.length < 4) return { at: run.at, quiet: run.quiet, draws: false }
      seen.sort((p, q) => q - p)
      const core = seen.slice(0, Math.max(1, Math.ceil(seen.length / 10)))
      return { at: run.at, quiet: run.quiet, draws: true, ratio: core[Math.floor(core.length / 2)] }
    })
  }

  // Everything a person can operate: native controls, links, anything with a control's role or a tabindex.
  const ROLES = ['button', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'slider', 'spinbutton', 'combobox', 'textbox', 'searchbox', 'link', 'treeitem']
  const CONTROLS = `button, input:not([type="hidden"]), select, textarea, summary, a[href], [tabindex], ${ROLES.map((r) => `[role="${r}"]`).join(', ')}`
  /** How faded an element is drawn over its ground: its opacity and every ancestor's up to the one that paints the ground. */
  const fadeOver = (el) => {
    let f = parseFloat(getComputedStyle(el).opacity)
    for (let n = el.parentElement; n && n.nodeType === 1; n = n.parentElement) {
      const s = getComputedStyle(n)
      if (h.rgba(s.backgroundColor)[3] >= 1) break
      if (s.display !== 'contents') f *= parseFloat(s.opacity)
    }
    return f
  }
  const insetShadows = (value) => {
    const out = []
    let depth = 0
    let cur = ''
    for (const ch of `${value},`) {
      if (ch === '(') depth++
      if (ch === ')') depth--
      if (ch === ',' && !depth) {
        if (/\binset\b/.test(cur)) out.push(...(cur.match(/(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)/g) ?? []))
        cur = ''
      } else cur += ch
    }
    return out
  }

  /** What marks where each control is: the best of its fill and its drawn edge (border, outline, inset ring),
      against the ground next to it. Controls part.json calls text-only are named and left out; disabled ones too. */
  const boundaries = (root, textOnly = []) => {
    const controls = [...root.querySelectorAll(CONTROLS)].filter((el) => el.getClientRects().length && !el.closest('[data-disabled], :disabled, [aria-disabled="true"]'))
    const bare = controls.filter((el) => textOnly.some((sel) => el.matches(sel)))
    const read = controls.filter((el) => !bare.includes(el)).map((el) => {
      const s = getComputedStyle(el)
      const ground = h.effectiveBg(el.parentElement)
      const fade = fadeOver(el)
      const against = (css) => h.against(css, ground, fade)
      const seen = [['fill', against(s.backgroundColor)]]
      const sides = ['top', 'right', 'bottom', 'left'].filter((d) => parseFloat(s.getPropertyValue(`border-${d}-width`)) > 0 && s.getPropertyValue(`border-${d}-style`) !== 'none')
      if (sides.length) seen.push(['edge', Math.min(...sides.map((d) => against(s.getPropertyValue(`border-${d}-color`))))])
      if (s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0 && !el.matches(':focus-visible')) seen.push(['outline', against(s.outlineColor)])
      for (const c of insetShadows(s.boxShadow)) seen.push(['inset ring', against(c)])
      const [by, ratio] = seen.reduce((best, x) => (x[1] > best[1] ? x : best))
      return { at: h.describe(el), by, ratio }
    })
    return { read, bare: textOnly.map((selector) => ({ selector, controls: bare.filter((el) => el.matches(selector)).map((el) => h.describe(el)) })), count: controls.length }
  }

  Object.assign(h, { runs, glyphs, compare, boundaries })
}

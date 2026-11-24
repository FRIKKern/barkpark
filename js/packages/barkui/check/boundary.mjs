// A control's boundary, whatever token draws it. installBoundary runs inside the
// check's isolated world after installHelpers (it is serialised, so it may not
// reach anything outside its own body) and adds its readers to the helper object.
export function installBoundary() {
  const h = window.__barkCheck
  // Everything a person can operate: native controls, links, anything with a control's role or a tabindex.
  const ROLES = ['button', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'slider', 'spinbutton', 'combobox', 'textbox', 'searchbox', 'link', 'treeitem']
  const CONTROLS = `button, input:not([type="hidden"]), select, textarea, summary, a[href], [tabindex], ${ROLES.map((r) => `[role="${r}"]`).join(', ')}`
  const FIELDS = 'input, select, textarea'
  const off = (el) => !!el.closest('[data-disabled], :disabled, [aria-disabled="true"]')

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

  /** Everything that can mark where a control is, each against the ground next to it: [what, ratio]. */
  const marks = (el) => {
    const s = getComputedStyle(el)
    const ground = h.effectiveBg(el.parentElement)
    const fade = fadeOver(el)
    const against = (css) => h.against(css, ground, fade)
    const seen = [['fill', against(s.backgroundColor)]]
    const sides = ['top', 'right', 'bottom', 'left'].filter((d) => parseFloat(s.getPropertyValue(`border-${d}-width`)) > 0 && s.getPropertyValue(`border-${d}-style`) !== 'none')
    if (sides.length) seen.push(['edge', Math.min(...sides.map((d) => against(s.getPropertyValue(`border-${d}-color`))))])
    if (s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0 && !el.matches(':focus-visible')) seen.push(['outline', against(s.outlineColor)])
    for (const c of insetShadows(s.boxShadow)) seen.push(['inset ring', against(c)])
    return seen
  }
  const best = (seen) => seen.reduce((b, x) => (x[1] > b[1] ? x : b))

  /** A control at rest: its showroom pin (hover, active, focus-visible) let go while it is read, and set again after.
      Both go through restyle (probes.mjs), so the reading is the rest state, not the first frame of a change
      towards it, and the pin is back in full before the next read. */
  const atRest = (el, read) => {
    const pin = el.getAttribute('data-pin')
    if (pin === null) return read(el)
    h.restyle('a pin let go for a reading at rest', () => el.removeAttribute('data-pin'))
    try {
      return read(el)
    } finally {
      h.restyle('a pin let go for a reading at rest', () => el.setAttribute('data-pin', pin))
    }
  }

  /** The controls in a stage that a person can operate now, each as the control a person sees (probes.mjs shownAs). */
  const controls = (root) => [...new Set([...root.querySelectorAll(CONTROLS)].map(h.shownAs))].filter((el) => el.getClientRects().length && !off(el) && !h.behind?.(el))

  /** What marks where each control is: the best of its fill and its drawn edge (border, outline, inset ring),
      against the ground next to it. A control part.json calls text-only is left out only when, at rest, it
      draws no fill and no edge of its own; one that does is held to 3:1 like any other and named. */
  const boundaries = (root, textOnly = []) => {
    const all = controls(root)
    const bare = []
    const misnamed = []
    const read = []
    for (const el of all) {
      const called = textOnly.some((sel) => el.matches(sel))
      const drawn = called ? atRest(el, (x) => marks(x).filter(([, r]) => r > 1.05)) : null
      if (called && !drawn.length) {
        bare.push(el)
        continue
      }
      const [by, ratio] = best(marks(el))
      read.push({ at: h.describe(el), by, ratio })
      if (called) misnamed.push({ at: h.describe(el), by: best(drawn)[0], ratio: best(drawn)[1] })
    }
    h.state.bare = bare
    return {
      read,
      misnamed,
      bare: textOnly.map((selector) => ({ selector, controls: bare.filter((el) => el.matches(selector)).map((el) => h.describe(el)) })),
      count: all.length,
    }
  }

  Object.assign(h, { CONTROLS, FIELDS, controls, boundaries })
}

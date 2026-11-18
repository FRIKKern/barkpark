// In-page helpers for the check. installHelpers runs inside the page (it is
// serialised), so it may not reach anything outside its own body.
export function installHelpers() {
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = 1
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  const rgba = (css) => {
    ctx.clearRect(0, 0, 1, 1)
    ctx.fillStyle = 'rgba(0,0,0,0)'
    ctx.fillStyle = css
    ctx.fillRect(0, 0, 1, 1)
    const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data
    return [r, g, b, a / 255]
  }
  const over = (top, under) => top.slice(0, 3).map((c, i) => c * top[3] + under[i] * (1 - top[3])).concat(1)
  const effectiveBg = (el) => {
    const layers = []
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const c = rgba(getComputedStyle(n).backgroundColor)
      if (c[3] > 0) layers.push(c)
      if (c[3] >= 1) break
    }
    return layers.reduceRight((under, top) => over(top, under), [255, 255, 255, 1])
  }
  const lum = ([r, g, b]) => {
    const f = (v) => ((v /= 255) <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
  }
  const contrast = (a, b) => {
    const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p)
    return (x + 0.05) / (y + 0.05)
  }
  /** A colour seen over a ground, against that ground. */
  const against = (css, ground) => contrast(over(rgba(css), ground), ground)
  const resolve = (name, within = document.body) => {
    const probe = document.createElement('span')
    probe.style.color = `var(${name})`
    within.append(probe)
    const value = getComputedStyle(probe).color
    probe.remove()
    return value
  }
  const describe = (el) => (el ? `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''} "${(el.textContent || '').trim().slice(0, 30)}"` : 'nothing')
  const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
  const carries = (el) => [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim()) || !!el.querySelector(':scope > svg')
  const painted = (root) => [...root.querySelectorAll('[data-slot]')].filter((el) => el.getClientRects().length && !el.closest('[data-paint-free]'))

  /** Names that hold a colour (an invalid colour falls back to the parent's, whatever it is). */
  const colourVars = (names) => {
    const host = document.createElement('div')
    document.body.append(host)
    const keep = names.filter((n) => {
      const seen = ['rgb(1, 2, 3)', 'rgb(4, 5, 6)'].map((c) => {
        host.style.color = c
        return resolve(n, host)
      })
      return seen[0] !== 'rgb(1, 2, 3)' || seen[1] !== 'rgb(4, 5, 6)'
    })
    host.remove()
    return keep
  }

  /** This view's value of every colour variable, and every painted element's colours. */
  const trace = (root, names) => {
    const vars = Object.fromEntries(names.map((n) => [n, resolve(n, root)]))
    const els = painted(root).map((el) => {
      const s = getComputedStyle(el)
      const props = { 'background-color': s.backgroundColor }
      if (carries(el)) props.color = s.color
      if (parseFloat(s.borderTopWidth) > 0) props['border-top-color'] = s.borderTopColor
      const seen = Object.fromEntries(Object.entries(props).map(([k, v]) => [k, { v, clear: rgba(v)[3] === 0 }]))
      return { at: describe(el), props: seen }
    })
    return { vars, els }
  }

  /** Colours named in part.json, and the weakest readable text. */
  const paint = (root, spec = []) => {
    const wrong = []
    for (const { selector, ...props } of spec) {
      const el = root.querySelector(selector)
      if (!el) {
        wrong.push(`${selector}: not found`)
        continue
      }
      const s = getComputedStyle(el)
      for (const [prop, name] of Object.entries(props)) {
        const want = resolve(name, el.parentElement)
        if (s.getPropertyValue(prop) !== want) wrong.push(`${selector} ${prop} ${s.getPropertyValue(prop)}, want ${name} ${want}`)
      }
    }
    let weakest = { ratio: Infinity, at: '' }
    const signature = []
    for (const el of painted(root)) {
      const s = getComputedStyle(el)
      signature.push(`${s.color}|${s.backgroundColor}|${s.borderTopColor}`)
      if (!carries(el) || el.matches('[data-disabled], :disabled')) continue
      const ratio = against(s.color, effectiveBg(el))
      if (ratio < weakest.ratio) weakest = { ratio, at: describe(el) }
    }
    return { wrong, weakest, signature: signature.join(';') }
  }

  /** The control edge (a border in --ui-input) against the ground, for every element that has one. */
  const controlEdges = (root) => {
    const input = resolve('--ui-input', root)
    return painted(root)
      .filter((el) => !el.matches('[data-disabled], :disabled, :focus-visible, [data-pin]'))
      .filter((el) => parseFloat(getComputedStyle(el).borderTopWidth) > 0 && getComputedStyle(el).borderTopColor === input)
      .map((el) => against(input, effectiveBg(el.parentElement)))
  }

  /** The focus ring on the focused element: gap in the ground, edge, halo; drawn once. */
  const ring = (el) => {
    const s = getComputedStyle(el)
    if (s.outlineStyle !== 'none' && rgba(s.outlineColor)[3] > 0) return { fail: `a second ring is drawn as outline ${s.outlineColor}` }
    const layers = []
    let depth = 0
    let cur = ''
    for (const ch of s.boxShadow) {
      if (ch === '(') depth++
      if (ch === ')') depth--
      if (ch === ',' && !depth) {
        layers.push(cur.trim())
        cur = ''
      } else cur += ch
    }
    layers.push(cur.trim())
    const parsed = layers.map((l) => {
      const m = l.match(/^(.*\))\s+(-?[\d.]+)px\s+(-?[\d.]+)px\s+(-?[\d.]+)px\s+(-?[\d.]+)px$/)
      return m && { color: m[1], x: +m[2], y: +m[3], blur: +m[4], spread: +m[5] }
    })
    if (s.boxShadow === 'none' || parsed.length < 3 || parsed.some((p) => !p || p.x || p.y || p.blur))
      return { fail: `no gap-edge-halo ring (box-shadow: ${s.boxShadow.slice(0, 80)})` }
    const [gap, edge, halo] = parsed
    const ground = effectiveBg(el.parentElement)
    const want = (n) => resolve(n, el.parentElement)
    if (gap.spread < 2 || rgba(gap.color)[3] < 1) return { fail: `gap ${gap.spread}px ${gap.color} is not a solid 2px gap` }
    if (gap.color !== want('--ui-background')) return { fail: `gap ${gap.color} is not --ui-background` }
    if (edge.spread - gap.spread < 2) return { fail: `edge is ${edge.spread - gap.spread}px, needs 2px` }
    if (edge.color !== want('--ui-ring-border')) return { fail: `edge ${edge.color} is not --ui-ring-border` }
    if (halo.spread <= edge.spread || halo.color !== want('--ui-ring')) return { fail: `halo ${halo.color} ${halo.spread}px is not --ui-ring outside the edge` }
    const ratio = against(edge.color, ground)
    if (ratio < 3) return { fail: `edge ${ratio.toFixed(2)}:1 against the ground, needs 3:1`, ratio }
    return { ratio }
  }

  /** Text or icon that a person can actually see: a box, visible, opaque enough, not clipped away. */
  const seen = (el) => {
    const r = el.getBoundingClientRect()
    if (!r.width || !r.height) return 'has no size'
    if (!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return 'is hidden (display, visibility or opacity)'
    let opacity = 1
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const s = getComputedStyle(n)
      opacity *= parseFloat(s.opacity)
      if (s.clipPath !== 'none' || (s.clip !== 'auto' && s.position === 'absolute')) return `is clipped by ${describe(n)}`
      if (n !== el && /hidden|clip|scroll|auto/.test(s.overflowX + s.overflowY)) {
        const b = n.getBoundingClientRect()
        if (r.left < b.left - 1 || r.right > b.right + 1 || r.top < b.top - 1 || r.bottom > b.bottom + 1) return `is cut off by ${describe(n)}`
      }
    }
    return opacity < 0.1 ? `is ${opacity} opaque` : true
  }

  /** Waits until every part's computed colours read the same on two frames 50ms apart (at most 2s).
      Polled on animation frames: in a headless page, transitions advance only when a frame runs. */
  const settle = async () => {
    const read = () => [...document.querySelectorAll('[data-slot]')].map((el) => {
      const s = getComputedStyle(el)
      return `${s.color}|${s.backgroundColor}|${s.borderTopColor}|${s.boxShadow}`
    }).join(';')
    await frame()
    const running = document.getAnimations().filter((a) => a instanceof CSSTransition)
    await Promise.race([Promise.all(running.map((a) => a.finished.catch(() => {}))), new Promise((r) => setTimeout(r, 2000))])
    await frame()
    let last = read()
    for (let i = 0; i < 40; i++) {
      await new Promise((r) => setTimeout(r, 50))
      await frame()
      const now = read()
      if (now === last) return
      last = now
    }
  }

  window.__barkCheck = { settle, rgba, contrast, against, effectiveBg, resolve, describe, frame, carries, painted, colourVars, trace, paint, controlEdges, ring, seen, state: {} }
}

/** Turns a function written in press.mjs into source the page can run. */
export function source(fn) {
  const s = fn.toString()
  return /^(async\s+)?(function\b|\(|[\w$]+\s*=>)/.test(s) ? s : `function ${s}`
}

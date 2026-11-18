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
  /** A colour seen over a ground, against that ground; `fade` is the opacity it is drawn at. */
  const against = (css, ground, fade = 1) => {
    const c = rgba(css)
    c[3] *= fade
    return contrast(over(c, ground), ground)
  }
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
  const hasText = (el) => [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())
  const carries = (el) => hasText(el) || !!el.querySelector(':scope > svg')
  /** Every element in the stage with a box: the part's elements, all that is inside them, the demo frame. */
  const shown = (root) => [...root.querySelectorAll('*')].filter((el) => el.getClientRects().length)
  /** The pseudo-elements of an element that draw something, as [name, style, shows text]. */
  const pseudos = (el) =>
    ['::before', '::after', '::marker', '::placeholder'].flatMap((p) => {
      if (p === '::marker' && getComputedStyle(el).display !== 'list-item') return []
      if (p === '::placeholder' && !(el.hasAttribute('placeholder') && !el.value)) return []
      const s = getComputedStyle(el, p)
      if ((p === '::before' || p === '::after') && /^(none|normal)$/.test(s.content)) return []
      if (s.display === 'none') return []
      return [[p, s, p === '::marker' || p === '::placeholder' || /["'][^"']*\S|counter|attr\(/.test(s.content)]]
    })
  /** How faded an element is drawn: its opacity times its ancestors', up to the ground behind it. */
  const fadeOf = (el) => {
    let f = 1
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const s = getComputedStyle(n)
      // A box-less element (display: contents) draws no opacity of its own.
      if (s.display !== 'contents') f *= parseFloat(s.opacity)
      if (rgba(s.backgroundColor)[3] >= 1) break
    }
    return f
  }
  /** Every part element with a box. data-paint-free never hides one from any light. */
  const painted = (root) => [...root.querySelectorAll('[data-slot]')].filter((el) => el.getClientRects().length)
  const selectorOf = (el, root) => {
    if (el.id) return `#${el.id}`
    const path = []
    for (let n = el; n && n !== root; n = n.parentElement) path.unshift(`${n.localName}:nth-of-type(${[...n.parentElement.children].filter((c) => c.localName === n.localName).indexOf(n) + 1})`)
    return path.join(' > ')
  }

  /** An element marked data-paint-free must carry no paint of its own; it is only excused from the skin comparison. */
  const paintFree = (root) =>
    [...root.querySelectorAll('[data-paint-free]')].map((el) => {
      const s = getComputedStyle(el)
      const selector = selectorOf(el, root)
      const fail = (why) => ({ selector, fail: `paint-free ${describe(el)} ${why}` })
      if (rgba(s.backgroundColor)[3] > 0) return fail(`carries its own background ${s.backgroundColor}`)
      if (s.backgroundImage !== 'none') return fail(`carries a background image`)
      for (const side of ['Top', 'Right', 'Bottom', 'Left'])
        if (parseFloat(s[`border${side}Width`]) > 0 && s[`border${side}Style`] !== 'none') return fail(`has a ${side.toLowerCase()} border`)
      if (s.boxShadow !== 'none') return fail(`casts a shadow ${s.boxShadow.slice(0, 60)}`)
      if (s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0 && rgba(s.outlineColor)[3] > 0) return fail('draws an outline')
      const from = getComputedStyle(el.parentElement).color
      if (s.color !== from) return fail(`sets its own text colour ${s.color} (its parent has ${from})`)
      return { selector, why: 'no background, border, shadow, outline or image; text colour inherited' }
    })

  const COLOUR_IN = /(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)/g
  const drawn = (s, side) => parseFloat(s.getPropertyValue(`${side}-width`)) > 0 && s.getPropertyValue(`${side}-style`) !== 'none'

  /** Every colour an element (or a pseudo-element) shows, by the property that shows it. A value that is
      transparent, or the element's own text colour (for anything but text), takes no paint of its own. */
  const colours = (el, s, text) => {
    const props = {}
    const put = (key, v, isText) => (props[key] = { v, clear: rgba(v)[3] === 0 || (!isText && v === s.color) })
    const svg = el instanceof SVGElement
    if (text) put('color', s.color, true)
    if (text) put('-webkit-text-fill-color', s.webkitTextFillColor)
    put('background-color', s.backgroundColor)
    for (const side of ['top', 'right', 'bottom', 'left']) if (drawn(s, `border-${side}`)) put(`border-${side}-color`, s.getPropertyValue(`border-${side}-color`))
    if (drawn(s, 'outline')) put('outline-color', s.outlineColor)
    if (drawn(s, 'column-rule')) put('column-rule-color', s.columnRuleColor)
    if (text && s.textDecorationLine !== 'none') put('text-decoration-color', s.textDecorationColor)
    if (text && s.textEmphasisStyle !== 'none') put('text-emphasis-color', s.textEmphasisColor)
    if (text && parseFloat(s.webkitTextStrokeWidth) > 0) put('-webkit-text-stroke-color', s.webkitTextStrokeColor)
    put('caret-color', s.caretColor)
    put('accent-color', s.accentColor)
    if (svg) for (const prop of ['fill', 'stroke']) put(prop, s.getPropertyValue(prop))
    if (el.localName === 'stop') put('stop-color', s.stopColor)
    if (/^fe(flood|dropshadow)$/i.test(el.localName)) put('flood-color', s.floodColor)
    if (/^fe(diffuse|specular)lighting$/i.test(el.localName)) put('lighting-color', s.lightingColor)
    for (const [prop, value] of [['box-shadow', s.boxShadow], ['text-shadow', text ? s.textShadow : 'none'], ['filter', s.filter], ['background-image', s.backgroundImage], ['scrollbar-color', s.scrollbarColor]])
      (value.match(COLOUR_IN) ?? []).forEach((v, i) => put(`${prop} #${i + 1}`, v))
    for (const [, url] of s.backgroundImage.matchAll(/url\("?([^")]*)"?\)/g)) {
      const image = decodeURIComponent(url)
      if (!/^data:image\/svg\+xml/.test(image) || !/currentColor/i.test(image)) props['background-image url'] = { v: 'image', image: true }
    }
    return props
  }

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

  /** This view's value of every colour variable, and every colour each element in the stage and each of
      its pseudo-elements shows. A paint-free element is left out; its pseudo-elements are not. */
  const trace = (root, names) => {
    const vars = Object.fromEntries(names.map((n) => [n, resolve(n, root)]))
    const els = []
    for (const el of shown(root)) {
      if (!el.hasAttribute('data-paint-free')) els.push({ at: describe(el), props: colours(el, getComputedStyle(el), carries(el)) })
      for (const [p, ps, text] of pseudos(el)) els.push({ at: `${describe(el)}${p}`, props: colours(el, ps, text) })
    }
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
    }
    // Every run of text in the stage, in the colour it is filled with, at the opacity it is drawn at,
    // against the ground actually behind it. Disabled controls and text no one can see are left out.
    const weigh = (fill, ground, fade, at) => {
      const ratio = against(fill, ground, fade)
      if (ratio < weakest.ratio) weakest = { ratio, at }
    }
    for (const el of shown(root)) {
      if (el.closest('[data-disabled], :disabled') || !el.checkVisibility({ visibilityProperty: true })) continue
      const s = getComputedStyle(el)
      const ground = effectiveBg(el)
      const fade = fadeOf(el)
      if (hasText(el)) weigh(s.webkitTextFillColor, ground, fade, describe(el))
      for (const [p, ps, text] of pseudos(el)) {
        if (!text || ps.visibility === 'hidden') continue
        const own = rgba(ps.backgroundColor)
        weigh(ps.webkitTextFillColor, own[3] > 0 ? over(own, ground) : ground, fade * parseFloat(ps.opacity), `${describe(el)}${p}`)
      }
    }
    return { wrong, weakest, signature: signature.join(';') }
  }

  /** Does a disabled control look live? Its fill against the ground, and against the primary fill. Numbers only. */
  const disabledFill = (root) =>
    painted(root)
      .filter((el) => el.matches('[data-disabled], :disabled'))
      .map((el) => {
        const ground = effectiveBg(el.parentElement)
        const fill = over(rgba(getComputedStyle(el).backgroundColor), ground)
        return { ground: contrast(fill, ground), primary: contrast(fill, over(rgba(resolve('--ui-primary', el.parentElement)), ground)) }
      })

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

  window.__barkCheck = { settle, paintFree, selectorOf, shown, pseudos, hasText, rgba, contrast, against, effectiveBg, resolve, describe, frame, carries, painted, colourVars, trace, paint, disabledFill, ring, seen, state: {} }
}

/** Turns a function written in press.mjs into source the page can run. */
export function source(fn) {
  const s = fn.toString()
  return /^(async\s+)?(function\b|\(|[\w$]+\s*=>)/.test(s) ? s : `function ${s}`
}

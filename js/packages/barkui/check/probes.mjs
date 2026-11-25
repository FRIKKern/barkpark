// In-page helpers for the check. installHelpers runs inside the page (it is
// serialised), so it may not reach anything outside its own body: the lists it reads come in as its argument
// (LISTS, motion.mjs).
export function installHelpers(lists) {
  if (!lists?.places?.length || !lists?.changes?.length || !Object.keys(lists?.motion ?? {}).length) throw new Error('installHelpers needs the lists of check/motion.mjs')
  const PLACES = lists.places
  const MOTION = lists.motion
  const CHANGES = new Set(lists.changes)
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
  /** A box the browser draws in the top layer (an open popover, a modal dialog): it is drawn over the page,
      not inside its DOM parent, so nothing of its ancestors is behind it, fades it or paints its ground. */
  const TOP = ':popover-open, :modal'
  const effectiveBg = (el) => {
    const layers = []
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const c = rgba(getComputedStyle(n).backgroundColor)
      if (c[3] > 0) layers.push(c)
      if (c[3] >= 1) break
      if (n.matches(TOP)) {
        // Behind a top-layer box: its ::backdrop, then what the page really draws there, read from a capture
        // taken with the open boxes hidden (check/layers.mjs). With no such capture the ground is not known,
        // so it reads as no colour at all, and nothing drawn on it can pass as itself.
        const b = rgba(getComputedStyle(n, '::backdrop').backgroundColor)
        if (b[3] > 0) layers.push(b)
        if (b[3] >= 1) break
        const under = state.under?.(el)
        if (!under) return [NaN, NaN, NaN, 1]
        return layers.reduceRight((below, top) => over(top, below), under)
      }
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
  /** A token as it resolves at an element, as an rgb() string. The token is read from the element's own computed
      style, and only turned into a colour by a probe at body level: no reader puts a child into the element it
      measures, since an element that draws no children (an input, a textarea, a select, an img) does not give one
      its own values. A token the element does not define reads as its colour, as `color: var(--missing)` would. */
  const resolve = (name, within = document.body) => {
    const raw = getComputedStyle(within).getPropertyValue(name).trim()
    if (!raw) return getComputedStyle(within).color
    const probe = document.createElement('span')
    probe.style.setProperty('transition', 'none', 'important')
    // The sheet's colours are light-dark() pairs: the probe takes the element's own scheme, so a surface that
    // flips it resolves as it does at the element.
    probe.style.colorScheme = getComputedStyle(within).colorScheme
    probe.style.color = raw
    document.body.append(probe)
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
      // Text only when a quoted string holds something to read (content: "" draws a box, not text), or a counter or attribute.
      const words = [...s.content.matchAll(/"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/g)].some((m) => /\S/.test(m[1] ?? m[2]))
      return [[p, s, p === '::marker' || p === '::placeholder' || words || /counter|attr\(/.test(s.content)]]
    })
  /** How faded an element is drawn: its opacity times its ancestors', up to the ground behind it. */
  const fadeOf = (el) => {
    let f = 1
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const s = getComputedStyle(n)
      // A box-less element (display: contents) draws no opacity of its own.
      if (s.display !== 'contents') f *= parseFloat(s.opacity)
      if (rgba(s.backgroundColor)[3] >= 1 || n.matches(TOP)) break
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
    // The check's own probe: its colour changes below start no transition of its own.
    host.style.setProperty('transition', 'none', 'important')
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

  /** The control a person sees for an element that takes focus. UI SDK's slider takes focus on a range input it
      hides inside each ui-slider-thumb (rangeInputStyle in components/slider/slider.js): that input, while no one
      sees it, is read on its thumb, for boundary, nothing to show and the ring. Every other element is its own. */
  const THUMB_INPUT = 'ui-slider ui-slider-thumb > ui-slider-thumb-input > input[type="range"]'
  const shownAs = (el) => (el?.matches?.(THUMB_INPUT) && seen(el) !== true ? el.closest('ui-slider-thumb') : el)

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

  /** What moves on the page now: the one meaning of "at rest" in the check, used by settle and by the gate. A
      transition or animation that is running moves, in its delay too; a paused one (the motion light holds them at
      one moment on purpose) shows what the page truly shows, and is at rest. `ends`: only those that have an end. */
  const moving = (ends = false) =>
    document.getAnimations().filter((a) => a.playState === 'running' && (!ends || a.effect?.getComputedTiming().endTime !== Infinity))
  const named = (list) =>
    [...new Set(list.map((a) => `${describe(a.effect?.target ?? null)}${a.effect?.pseudoElement ?? ''} ${a instanceof CSSTransition ? `transition of ${a.transitionProperty}` : a instanceof CSSAnimation ? `animation ${a.animationName}` : 'animation'}`))].slice(0, 3).join('; ')
  /** The check's own red, not a part's: a look is read only on a page at rest. */
  const AT_REST = 'the check could not read (not a fault of the part): read on a page not at rest'
  /** Motion where the check cannot see it, by name: a mover anywhere but the places of PLACES. */
  const UNSEEN = 'the check could not read (not a fault of the part): motion where the check cannot see it'
  const FOCUS_UNSEEN = 'the check could not read (not a fault of the part; task-937d3e772d576b90): focus outside the view after a key'
  /** Scrolls under way: what scrolled since a frame was last seen to pass with no scroll. A scroll that goes on
      scrolls again on every frame; one that has ended does not. */
  const scroll = { count: 0, seen: 0, by: new Set() }
  addEventListener('scroll', (e) => {
    scroll.count++
    scroll.by.add(e.target)
  }, { capture: true })
  const scrolling = () => (scroll.count === scroll.seen ? [] : [...scroll.by])
  const atRest = (who) => {
    const now = moving()
    const off = now.filter((a) => !PLACES.includes(a.effect?.pseudoElement ?? ''))
    if (off.length) throw new Error(`${UNSEEN}: ${who}: ${named(off)}`)
    if (now.length) throw new Error(`${AT_REST}: ${who}: ${named(now)}`)
    const going = scrolling()
    if (going.length) throw new Error(`${AT_REST}: ${who}: a scroll under way at ${going.slice(0, 3).map((x) => (x === document ? 'the page' : describe(x))).join('; ')}`)
  }
  /** The sheets' motion anywhere but PLACES, by selector: every sheet the page loads and every adopted one, every
      rule in every block, nested rules read from their parent. `texts` ({ href: text }) are the sheets a page
      loaded from a file, which the browser keeps from script: read from the same text. Any other sheet the check
      cannot read is named. With no `texts`, the answer also names each file sheet to read (`files`). */
  const motionOffList = (texts = null) => {
    const off = []
    const top = (sel) => {
      const out = []
      let depth = 0
      let from = 0
      for (let i = 0; i < sel.length; i++) {
        if ('([{'.includes(sel[i])) depth++
        else if (')]}'.includes(sel[i])) depth--
        else if (sel[i] === ',' && !depth) {
          out.push(sel.slice(from, i).trim())
          from = i + 1
        }
      }
      return [...out, sel.slice(from).trim()]
    }
    // The pseudo-element a selector's subject is, '' for the element itself.
    const placeOf = (sel, parent) => {
      const flat = sel.replace(/\([^()]*\)|\[[^\]]*\]/g, '')
      const last = flat.split(/[\s>+~]+/).filter(Boolean).pop() ?? ''
      const m = last.match(/::([\w-]+)|:(before|after|first-letter|first-line)\b/)
      if (m) return `::${m[1] ?? m[2]}`
      return last.includes('&') ? parent : ''
    }
    const moves = (style) => [...style].some((p) => p in MOTION)
    // A kind whose rule names a still value is declared at any other value only where motion is allowed, so it
    // holds in every state a rule can match.
    const fixed = Object.entries(MOTION).filter(([, r]) => r.still !== 'nothing running')
    const unstill = (style, sels, free) => {
      if (free) return
      for (const [p, r] of fixed) {
        const v = style.getPropertyValue(p).trim()
        if (v && v !== r.still) for (const s of sels) off.push(`${s.sel} declares ${p}: ${v} outside @media (prefers-reduced-motion: no-preference)`)
      }
    }
    const walk = (rules, parents, free) => {
      for (const r of rules) {
        let here = parents
        if (r instanceof CSSStyleRule) {
          here = top(r.selectorText).flatMap((s) => (parents.length ? parents.map((p) => ({ sel: s, place: placeOf(s, p.place) })) : [{ sel: s, place: placeOf(s, '') }]))
          if (moves(r.style)) for (const s of here) if (!PLACES.includes(s.place)) off.push(s.sel)
          unstill(r.style, here, free)
        } else if (typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations) {
          if (moves(r.style)) for (const s of parents) if (!PLACES.includes(s.place)) off.push(s.sel)
          unstill(r.style, parents, free)
        }
        const allowed = free || (r instanceof CSSMediaRule && /\(\s*prefers-reduced-motion\s*:\s*no-preference\s*\)/.test(r.conditionText))
        if (r.cssRules && !(r instanceof CSSKeyframesRule)) walk(r.cssRules, here, allowed)
      }
    }
    const files = []
    for (const s of [...document.styleSheets, ...document.adoptedStyleSheets]) {
      let rules
      try {
        rules = s.cssRules
      } catch {
        if (s.href?.startsWith('file:') && texts && s.href in texts) {
          const copy = new CSSStyleSheet()
          copy.replaceSync(texts[s.href])
          rules = copy.cssRules
        } else if (s.href?.startsWith('file:') && !texts) {
          files.push(s.href)
          continue
        } else {
          off.push(`a sheet the check cannot read: ${s.href}`)
          continue
        }
      }
      walk(rules, [], false)
    }
    return { off: [...new Set(off)], files }
  }
  /** The element with focus, through open shadow roots; null when nothing has it (the body or the root). */
  const focused = () => {
    let a = document.activeElement
    while (a?.shadowRoot?.activeElement) a = a.shadowRoot.activeElement
    return a && a !== document.body && a !== document.documentElement ? a : null
  }
  /** Where a scroll into view of `el` would still move something: the scroller, or null when on each axis of every
      scroller around it the element is inside the scroller's view, covers that view, or the scroller is at its limit
      the way the element lies. No scroller around a box with position: fixed moves it. */
  const intoView = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    const holds = (a0, a1, v0, v1, at, most) => (a0 >= v0 - 1 && a1 <= v1 + 1) || (a0 <= v0 + 1 && a1 >= v1 - 1) || (a0 < v0 ? at <= 1 : at >= most - 1)
    const scrolls = (o) => o === 'auto' || o === 'scroll' || o === 'hidden'
    for (let n = el; n; ) {
      if (getComputedStyle(n).position === 'fixed') return null
      n = n.assignedSlot ?? n.parentElement ?? (n.getRootNode() instanceof ShadowRoot ? n.getRootNode().host : null)
      if (!n || n === document.body) continue
      const root = n === document.documentElement
      const s = getComputedStyle(n)
      const b = root ? { top: 0, left: 0 } : n.getBoundingClientRect()
      const top = b.top + (root ? 0 : n.clientTop)
      const left = b.left + (root ? 0 : n.clientLeft)
      const y = (root || scrolls(s.overflowY)) && n.scrollHeight > n.clientHeight && !holds(r.top, r.bottom, top, top + n.clientHeight, n.scrollTop, n.scrollHeight - n.clientHeight)
      const x = (root || scrolls(s.overflowX)) && n.scrollWidth > n.clientWidth && !holds(r.left, r.right, left, left + n.clientWidth, n.scrollLeft, n.scrollWidth - n.clientWidth)
      if (y || x) return root ? 'the page' : describe(n)
    }
    return null
  }
  /** Waits for what moves and has an end, inside the bound of 2s, a frame at a time (in a headless page an
      animation advances only when a frame runs), and for `also` (a condition read, empty when it holds). What has
      no end never comes to rest; waiting for it changes nothing. */
  const toRest = async (also = () => null) => {
    const until = performance.now() + 2000
    while ((moving(true).length || scrolling().length || also()) && performance.now() < until) {
      const was = scroll.count
      // A frame's scroll events come before its animation frame callbacks, so one frame tells a scroll that goes on.
      if (moving(true).length) await frame()
      else await new Promise((r) => requestAnimationFrame(r))
      if (scroll.count === was) {
        scroll.seen = was
        scroll.by.clear()
      }
    }
  }
  /** The rest step after the checker's input on a page (check/acts.mjs), `who` naming the act and where the checker
      made it: a frame is drawn, so what the input started shows, then the page comes to rest inside the bound, or
      the act is red there by name and nothing reads on. At rest is: nothing with an end moves, no scroll is under
      way, and after a key (`kind` 'key'), which the browser follows by scrolling the element with focus into view, a
      scroll into view of that element would move nothing (or nothing has focus). After the pointer, whose focus the
      browser never scrolls, only the first two. Motion with no end is left to the read, whose gate names it. */
  const afterAct = async ([who, kind]) => {
    const moved = kind === 'key' ? focused() : null
    const unscrolled = () => intoView(moved)
    await frame()
    await toRest(unscrolled)
    const left = moving(true)
    if (left.length) throw new Error(`${AT_REST}: ${who}: ${named(left)}`)
    const going = scrolling()
    if (going.length) throw new Error(`${AT_REST}: ${who}: a scroll under way at ${going.slice(0, 3).map((x) => (x === document ? 'the page' : describe(x))).join('; ')}`)
    const at = unscrolled()
    if (at) throw new Error(`${FOCUS_UNSEEN}: after ${who}, ${describe(moved)} has focus outside the view of ${at}, and no scroll has brought it in`)
  }
  /** The door before a read: the page comes to rest inside the bound, or the read is red by name. */
  const still = async (who) => {
    await toRest()
    atRest(who)
  }
  /** Waits until the page is at rest (inside the bound), then until every part's computed colours read the same on
      two frames 50ms apart (at most 2s). */
  const settle = async () => {
    const read = () => [...document.querySelectorAll('[data-slot]')].map((el) => {
      const s = raw.getComputedStyle(el)
      return `${s.color}|${s.backgroundColor}|${s.borderTopColor}|${s.boxShadow}`
    }).join(';')
    await frame()
    await toRest()
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

  /** Every way the check learns a look in this world: each reads only a page at rest, or is red by name. The
      world is isolated, so the page cannot reach these or undo them. `raw` keeps the ungated ones for the gate's own
      waiting (settle compares colours while the page comes to rest). */
  const raw = {}
  const LOOKS = [
    [window, 'getComputedStyle'], [window, 'matchMedia'],
    [Element.prototype, 'getBoundingClientRect'], [Element.prototype, 'getClientRects'], [Element.prototype, 'checkVisibility'], [Element.prototype, 'computedStyleMap'],
    [Range.prototype, 'getBoundingClientRect'], [Range.prototype, 'getClientRects'],
    [Document.prototype, 'elementFromPoint'], [Document.prototype, 'elementsFromPoint'], [Document.prototype, 'caretPositionFromPoint'], [Document.prototype, 'caretRangeFromPoint'],
    ...['offsetWidth', 'offsetHeight', 'offsetTop', 'offsetLeft', 'offsetParent'].map((k) => [HTMLElement.prototype, k, 'get']),
    ...['clientWidth', 'clientHeight', 'clientTop', 'clientLeft', 'scrollWidth', 'scrollHeight', 'scrollTop', 'scrollLeft'].map((k) => [Element.prototype, k, 'get']),
  ]
  const gated = []
  for (const [on, key, get] of LOOKS) {
    const name = `${on === window ? 'window' : on.constructor.name}.${key}`
    const d = Object.getOwnPropertyDescriptor(on, key)
    const fn = get ? d?.get : d?.value
    if (typeof fn !== 'function') continue
    if (on === window) raw[key] = fn.bind(window)
    const wrapped = { [key](...a) { atRest(name); return fn.apply(this, a) } }[key]
    Object.defineProperty(on, key, get ? { ...d, get: wrapped } : { ...d, value: wrapped })
    gated.push(name)
  }
  const looks = { ways: LOOKS.length, gated }

  const state = {}
  /** The one way the checker changes the page's look (a sheet of its own on or off, a pin set or taken off): `change`
      runs with transitions held off by a first-layer sheet of the checker's own, and style is brought up to date
      before that sheet goes, so the change starts no transition. The checker adds no animation to the page. The
      sheet holds off exactly the places of PLACES, the only places a sheet may declare motion.
      `place` names the caller; state.restyled counts the calls by place. */
  let stillSheet = null
  const restyle = (place, change) => {
    if (!CHANGES.has(place)) throw new Error(`restyle was asked for a change that is not in check/motion.mjs's CHANGES: "${place}"`)
    // The hold sheet would end a transition of the page's own: one still running now (each call first waits for
    // rest inside the bound) is the page not at rest, red by name, never read silently at its end.
    const cut = moving().filter((a) => a instanceof CSSTransition)
    if (cut.length) throw new Error(`${AT_REST}: the checker's change "${place}": ${named(cut)}`)
    stillSheet ??= Object.assign(document.createElement('style'), { textContent: `@layer barkui-check { ${PLACES.map((p) => `*${p}`).join(', ')} { transition: none !important; } }` })
    document.head.prepend(stillSheet)
    try {
      change()
    } finally {
      // getAnimations brings the whole document's style up to date with transitions off: the new style is then the
      // starting point of any later change, and taking the sheet off starts nothing.
      document.getAnimations()
      stillSheet.remove()
      ;(state.restyled ??= {})[place] = (state.restyled[place] ?? 0) + 1
    }
  }
  window.__barkCheck = { TOP, settle, restyle, moving, atRest, toRest, still, afterAct, motionOffList, looks, AT_REST, UNSEEN, paintFree, selectorOf, shown, pseudos, hasText, rgba, contrast, against, effectiveBg, resolve, describe, frame, carries, painted, colourVars, trace, paint, disabledFill, ring, seen, shownAs, state }
}

/** Turns a function written in press.mjs into source the page can run. */
export function source(fn) {
  const s = fn.toString()
  return /^(async\s+)?(function\b|\(|[\w$]+\s*=>)/.test(s) ? s : `function ${s}`
}

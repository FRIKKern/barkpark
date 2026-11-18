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
  const resolve = (name, within = document.body) => {
    const probe = document.createElement('span')
    probe.style.color = `var(${name})`
    within.append(probe)
    const value = getComputedStyle(probe).color
    probe.remove()
    return value
  }
  const describe = (el) => (el ? `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''} "${(el.textContent || '').trim().slice(0, 30)}"` : 'nothing')

  /** Colours of every part element, the named paint, and the weakest text contrast. */
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
    for (const el of root.querySelectorAll('[data-slot]')) {
      const s = getComputedStyle(el)
      signature.push(`${s.color}|${s.backgroundColor}|${s.borderTopColor}`)
      const text = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())
      if (!text || el.matches('[data-disabled], :disabled') || !el.getClientRects().length) continue
      const ratio = contrast(over(rgba(s.color), effectiveBg(el)), effectiveBg(el))
      if (ratio < weakest.ratio) weakest = { ratio, at: describe(el) }
    }
    return { wrong, weakest, signature: signature.join(';') }
  }

  /** Waits until every part's computed colours read the same on two frames 50ms apart (at most 2s).
      Polled on animation frames: in a headless page, transitions advance only when a frame runs. */
  const settle = async () => {
    const read = () => [...document.querySelectorAll('[data-slot]')].map((el) => {
      const s = getComputedStyle(el)
      return `${s.color}|${s.backgroundColor}|${s.borderTopColor}|${s.outlineColor}`
    }).join(';')
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    await frame()
    // Transitions still waiting out a delay or running: let them finish first.
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

  window.__barkCheck = { rgba, contrast, effectiveBg, resolve, describe, paint, settle, state: {} }
}

/** Turns a function written in press.mjs into source the page can run. */
export function source(fn) {
  const s = fn.toString()
  return /^(async\s+)?(function\b|\(|[\w$]+\s*=>)/.test(s) ? s : `function ${s}`
}

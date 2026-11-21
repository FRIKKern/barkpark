// The top layer. An open popover or a modal dialog is drawn over the page, not inside its DOM parent: its box can
// stand outside the stage's box, and what is behind it is whatever the page draws there, not its parent's
// background. A part names each top-layer box of its own in part.json "layers", with the real input that opens it
// and the input that closes it (docs/PARTS.md "The top layer"). The check opens each one in every view the stage
// is read in, reads the stage with it open (reading.mjs), and closes it again. While a named box is open:
// - the capture covers the stage and the box;
// - the ground behind the box is read from a capture of the page with the open boxes hidden, at the place each
//   thing stands (probes.mjs effectiveBg asks state.under), never from the box's DOM parent;
// - a thing outside the box that the box covers, and everything a modal box blocks, is not read in that reading:
//   each is read in the reading with the box closed.
// What no layer names fails by name, in two ways:
// - Every element that can enter the top layer (a dialog, or an element that carries popover) and that the page
//   holds at any moment, in the document at load or added or given popover later, must be named by a layer, whether
//   or not it ever opens. A world of the check's own watches the page from its first frame (census, below), and
//   each reading and each look after real input names what it has seen that no layer names, once per page.
// - A box open in the top layer that no layer names fails at every moment the check judges or drives the part: each
//   reading, each Tab stop of the focus walk, each press step, each driven state, and each layer's open and close.
// A layer's box opens at once on its input: one not open once its input settles fails by name, so a box that opens
// late (a tooltip with a delay) cannot pass as named. The one limit: a box the page never holds while the check has
// it open, up to the check's last look (one made only after an input the check never gives), or one only inside a
// closed shadow root, is not seen.
import { limit } from './limit.mjs'
import { source } from './probes.mjs'

const STEP_MS = 5000

/** Runs in the check's world, after installHelpers, installBoundary and installDrawn (it is serialised). */
export function installLayers() {
  const h = window.__barkCheck
  const page = (r) => ({ x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height })
  const meets = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
  /** Every box open in the top layer, and which of them the part names: the boxes its `layers` select. */
  const layers = (root, boxes) => {
    const named = new Set(boxes.map((s) => root.querySelector(s)).filter(Boolean))
    const open = [...document.querySelectorAll(h.TOP)]
    h.state.open = open.filter((b) => named.has(b))
    return { boxes: h.state.open.map((b) => page(b.getBoundingClientRect())), unnamed: open.filter((b) => !named.has(b)).map((b) => h.describe(b)) }
  }
  /** The boxes open in the top layer now that no layer names, without touching what a reading keeps. */
  const unnamed = (root, boxes) => {
    const named = new Set(boxes.map((s) => root.querySelector(s)).filter(Boolean))
    return [...document.querySelectorAll(h.TOP)].filter((b) => !named.has(b)).map((b) => h.describe(b))
  }
  /** Whether an element is not read while a named box is open: a modal box blocks all outside it, and any open box
      covers what is outside it under its own box. */
  const behind = (el) => {
    const open = h.state.open ?? []
    if (!open.length || open.some((b) => b.contains(el))) return false
    if (open.some((b) => b.matches(':modal'))) return true
    const r = page(el.getBoundingClientRect())
    return open.some((b) => meets(r, page(b.getBoundingClientRect())))
  }
  // The open boxes and their backdrops, hidden (true) or drawn again (false), by a first-layer sheet of the check's
  // own: the capture taken so is what the page draws behind them.
  let hide = null
  const hideLayers = (on) => {
    hide?.remove()
    hide = null
    if (!on) return
    hide = document.createElement('style')
    hide.textContent = `@layer barkui-check { :is(${h.TOP}) { opacity: 0 !important; } :is(${h.TOP})::backdrop { background: transparent !important; } }`
    document.head.prepend(hide)
  }
  /** Keeps the page as drawn behind the open boxes; state.under(el) is then its colour where el stands (the middle
      of the samples across its box), and null outside the capture. `null` forgets it. */
  const under = async (png, clip, scale) => {
    if (!png) return void (h.state.under = null)
    const bytes = Uint8Array.from(atob(png), (c) => c.charCodeAt(0))
    const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }))
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height)
    const g = canvas.getContext('2d', { willReadFrequently: true })
    g.drawImage(bitmap, 0, 0)
    const { data } = g.getImageData(0, 0, bitmap.width, bitmap.height)
    h.state.under = (el) => {
      const r = page(el.getBoundingClientRect())
      const seen = []
      for (let i = 1; i < 6; i++)
        for (let j = 1; j < 6; j++) {
          const x = Math.floor((r.x + (r.w * i) / 6 - clip.x) * scale)
          const y = Math.floor((r.y + (r.h * j) / 6 - clip.y) * scale)
          if (x < 0 || y < 0 || x >= bitmap.width || y >= bitmap.height) return null
          const k = (y * bitmap.width + x) * 4
          seen.push([data[k], data[k + 1], data[k + 2]])
        }
      const mid = (n) => seen.map((p) => p[n]).sort((a, b) => a - b)[seen.length >> 1]
      return [mid(0), mid(1), mid(2), 1]
    }
  }
  Object.assign(h, { layers, unnamed, behind, hideLayers, under })
}

/** Real input on the page: focus, the pointer moved away (`leave`), a click or the pointer at a control's centre
    (only once it is what is on top there), then keys. */
async function drive(page, part, step, what) {
  if (step.focus) await page.barkCheck(([n, s]) => document.querySelector(`[data-part="${n}"] ${s}`)?.focus(), [part.name, step.focus])
  if (step.leave) await page.mouse.move(0, 0)
  for (const [how, sel] of [['click', step.click], ['hover', step.hover]]) {
    if (!sel) continue
    const at = await page.barkCheck(([n, s]) => {
      const el = document.querySelector(`[data-part="${n}"] ${s}`)
      if (!el) return { miss: 'is not in the stage' }
      el.scrollIntoView({ block: 'center', inline: 'center' })
      const r = el.getBoundingClientRect()
      const [x, y] = [r.left + r.width / 2, r.top + r.height / 2]
      const top = document.elementFromPoint(x, y)
      return el === top || el.contains(top) ? { x, y } : { miss: `is not what a click at its centre reaches: ${window.__barkCheck.describe(top)} is on top` }
    }, [part.name, sel])
    if (at.miss) throw new Error(`${what}: ${sel} ${at.miss}`)
    if (how === 'click') await page.mouse.click(at.x, at.y)
    else await page.mouse.move(at.x, at.y)
  }
  for (const key of step.keys ?? []) await page.keyboard.press(key)
  await page.barkCheck(() => window.__barkCheck.settle())
}

/** The fail for a box open in the top layer that no layer names, the same at every judged moment. */
export const UNNAMED = (at) => `${at} is open in the top layer during the reading, and no layer in part.json names it`
/** The fail for an element that can enter the top layer and that no layer names, open or not. */
export const UNNAMED_CAN = (at) => `${at} can open in the top layer (a dialog, or it carries popover), and no layer in part.json names it`

/** Runs in the census world from the page's first frame (it is serialised): it notes every element that can enter
    the top layer, with the part whose stage held it when it was seen (null outside every stage), in the document and
    in each open shadow root, as it arrives or gains popover. __barkCensus(part, boxes) names, once per page, each
    one seen for that part or outside every stage that none of the part's layers selects. */
function census() {
  const CAN = 'dialog, [popover]'
  const seen = new Map()
  const told = new Set()
  const roots = new WeakSet()
  const up = (e) => e.parentElement ?? (e.getRootNode() instanceof ShadowRoot ? e.getRootNode().host : null)
  const owner = (n) => {
    for (let e = n; e; e = up(e)) if (e.dataset?.part) return e.dataset.part
    return null
  }
  const note = (el, from) => seen.has(el) || seen.set(el, owner(el.isConnected ? el : from))
  const mo = new MutationObserver((list) => {
    for (const m of list) if (m.type === 'attributes') take(m.target)
    else for (const n of m.addedNodes) take(n, m.target)
  })
  const watch = (r) => mo.observe(r, { childList: true, subtree: true, attributes: true, attributeFilter: ['popover'] })
  function take(n, from = n) {
    if (n.nodeType !== 1) return
    for (const e of [n, ...n.querySelectorAll('*')]) {
      if (e.matches(CAN)) note(e, from)
      if (e.shadowRoot && !roots.has(e.shadowRoot)) {
        roots.add(e.shadowRoot)
        watch(e.shadowRoot)
        for (const c of e.shadowRoot.children) take(c)
      }
    }
  }
  watch(document)
  if (document.documentElement) take(document.documentElement)
  const describe = (el) => `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''} "${(el.textContent || '').trim().slice(0, 30)}"`
  globalThis.__barkCensus = (part, boxes) => {
    if (document.documentElement) take(document.documentElement)
    const stage = document.querySelector(`[data-part="${CSS.escape(part)}"]`)
    const named = new Set(boxes.map((s) => stage?.querySelector(s)).filter(Boolean))
    const out = []
    for (const [el, of] of seen) {
      if (told.has(el) || (of !== null && of !== part) || named.has(el)) continue
      if (!el.isConnected && of === part && boxes.some((s) => el.matches(s))) continue
      told.add(el)
      out.push(describe(el))
    }
    return out
  }
}

/** The census world on `page`, set before the page opens its URL, so it watches from the first frame. Returns
    look(part) → what census() names for the part. A page that runs no script of its own gets the census when first
    asked: nothing on it can add a box later. */
export async function installCensus(page) {
  const cdp = await page.context().newCDPSession(page)
  const { frameTree } = await cdp.send('Page.getFrameTree')
  const frameId = frameTree.frame.id
  let id = null
  cdp.on('Runtime.executionContextCreated', ({ context: c }) => {
    if (c.name === 'barkui-census' && c.auxData?.frameId === frameId) id = c.id
  })
  await cdp.send('Runtime.enable')
  const code = `(${source(census)})()`
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: code, worldName: 'barkui-census' })
  const run = async (expression) => {
    const { result, exceptionDetails } = await cdp.send('Runtime.evaluate', { expression, contextId: id, returnByValue: true })
    if (exceptionDetails) throw new Error(`the census: ${String(exceptionDetails.exception?.description ?? exceptionDetails.text).split('\n')[0]}`)
    return result.value
  }
  let ready = false
  return async (part) => {
    if (!ready && (id === null || !(await run('typeof __barkCensus === "function"').catch(() => false)))) {
      id = (await cdp.send('Page.createIsolatedWorld', { frameId, worldName: 'barkui-census-late' })).executionContextId
      await run(code)
    }
    ready = true
    return run(`__barkCensus(${JSON.stringify(part.name)}, ${JSON.stringify((part.json.layers ?? []).map((l) => l.box))})`)
  }
}

/** After real input (a Tab stop, a driven state, a press step, a layer's input), the fails for what no layer
    names: each box open in the top layer now, and each element that can open there that the census has seen. */
export async function unnamedNow(page, part) {
  const t0 = Date.now()
  try {
    const open = await page.barkCheck(([n, b]) => window.__barkCheck.unnamed(document.querySelector(`[data-part="${n}"]`), b), [part.name, (part.json.layers ?? []).map((l) => l.box)])
    const can = page.barkCensus ? await page.barkCensus(part) : []
    return [...open.map(UNNAMED), ...can.map(UNNAMED_CAN)]
  } finally {
    looks.n++
    looks.ms += Date.now() - t0
  }
}
/** How many of those looks this process made, and how long they took: the selftest prints what they cost. */
export const looks = { n: 0, ms: 0 }

/** The fail for a layer whose box is not open once its "open" input settles. */
export const LATE = (name) => `${name} is not open in the top layer once its "open" input settles: it opened later than the check waits, or not at all; a layer opens at once on its input`

const isOpen = (page, part, box) => page.barkCheck(([n, s, top]) => !!document.querySelector(`[data-part="${n}"] ${s}`)?.matches(top), [part.name, box, ':popover-open, :modal'])

/** Each of the part's layers opened by its own input, read by `read` while open, then closed by its input. The
    fails of each, with what opening or closing did not do; `read(layer)` returns the fails of that reading. */
export async function eachLayer(page, part, read) {
  const fails = []
  for (const layer of part.json.layers ?? []) {
    const name = `the layer ${layer.box}`
    try {
      await limit(drive(page, part, layer.open, `opening ${name}`), STEP_MS, `opening ${name}`)
      for (const f of await unnamedNow(page, part)) fails.push(`after opening ${name}: ${f}`)
      if (!(await isOpen(page, part, layer.box))) {
        fails.push(LATE(name))
        continue
      }
      fails.push(...(await read(layer)))
    } catch (e) {
      fails.push(String(e.message).split('\n')[0])
    } finally {
      try {
        await limit(drive(page, part, layer.close, `closing ${name}`), STEP_MS, `closing ${name}`)
        if (await isOpen(page, part, layer.box)) fails.push(`${name} is still open after its "close" input`)
        for (const f of await unnamedNow(page, part)) fails.push(`after closing ${name}: ${f}`)
      } catch (e) {
        fails.push(String(e.message).split('\n')[0])
      }
    }
  }
  return fails
}

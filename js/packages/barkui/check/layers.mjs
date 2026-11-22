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
//   each reading and each look after real input names what it has seen that no layer names, once per page. Every
//   element it sees arrive is read with its open shadow root, so a host that arrives carrying one (parsed by
//   setHTMLUnsafe or parseHTMLUnsafe, cloned, adopted) is read on arrival. A root comes to exist on a host already
//   in the page in these ways only, each seen at once or refused by name:
//   - a script calls attachShadow: a hook set in the page before any of its script tells the census at once,
//     wherever the host stands (tellRoots, below; the page cannot take it away);
//   - the parser meets a declared root while it parses example.html: refused as the part is read (build/parts.mjs);
//   - markup is written into the parsed document (document.write, writeln or open): refused by name (tellRoots);
//   - another window attaches one with its own attachShadow: every frame in the page, window.open, and any other
//     window the page opens (a link or a form with a target) is refused by name.
//   Markup parsed into a host already in the page (setHTMLUnsafe, innerHTML) cannot give that host a root: a
//   declared root at the top of the markup stays a plain template, and one deeper is on a new host, read on arrival.
// - A box open in the top layer that no layer names fails at every moment the check judges or drives the part: each
//   reading, each Tab stop of the focus walk, each press step, each driven state, and each layer's open and close.
// A layer's box opens at once on its input: one not open once its input settles fails by name, so a box that opens
// late (a tooltip with a delay) cannot pass as named. The one limit: a box the page never holds while the check has
// it open, up to the check's last look (one made only after an input the check never gives), or one only inside a
// closed shadow root, is not seen.
import { limit } from './limit.mjs'
import { HOLDER_UNREAD, HOLDERS_UNLISTED, placementSource, SHADOW_ABOVE } from './placement.mjs'
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
/** The fail for a frame anywhere in the page: another window, whose attachShadow and boxes the census does not watch. */
export const FRAME = (at) => `${at} is a frame, another window in the page, which the check does not watch; a part makes none`
/** The fail for a call the page's world refuses (tellRoots): the call, and why. */
export const REFUSED = {
  'window.open': 'the page called window.open, which the check refuses: another window, which the check does not watch',
  'document.write': 'the page called document.write after it was parsed, which the check refuses: it starts the document again, and the check\'s watch with it',
  'document.writeln': 'the page called document.writeln after it was parsed, which the check refuses: it starts the document again, and the check\'s watch with it',
  'document.open': 'the page called document.open, which the check refuses: it starts the document again, and the check\'s watch with it',
  window: 'the page opened another window (by a link or a form with a target), which the check refuses: another window, which the check does not watch',
}
/** How a selftest case's check run touched the top layer, by what it did, not by its name: its part names a layer,
    or the run says one of the top layer's fails (a box no layer names, open or not; a frame; a refused call).
    Empty when it did neither. */
export function topLayerTouch(layers, proof) {
  if (layers?.length) return 'its part names a layer'
  const text = JSON.stringify(proof ?? {})
  const hit = [UNNAMED(''), UNNAMED_CAN(''), FRAME(''), ...Object.values(REFUSED)].find((s) => text.includes(JSON.stringify(s.trim()).slice(1, -1)))
  return hit ? `its run says "${hit.trim()}"` : ''
}
/** What the census tells, as the fail it is. */
const said = ({ kind, at }) => (kind === 'frame' ? FRAME(at) : kind === 'call' ? REFUSED[at] : UNNAMED_CAN(at))

/** Runs in the census world from the page's first frame (it is serialised): it notes every element that can enter
    the top layer, with the part whose stage held it when it was seen (null outside every stage), in the document and
    in each open shadow root, as it arrives or gains popover, and watches each open root from the moment
    attachShadow makes it (told by tellRoots). It also notes every frame (another window), and each call tellRoots
    refuses. __barkCensus(part, boxes) tells, once per page, each one seen for that part or outside every stage that
    none of the part's layers selects. `placement` (placement.mjs placementSource) watches each document and open
    root the census watches; __barkPlacement(part) is its fails for the part. docs/PARTS.md "Placement" says what
    is read and when. `script` is false on a page with no script. */
function census(placement, script) {
  const CAN = 'dialog, [popover]'
  const FRAMES = 'iframe, frame, object, embed, fencedframe'
  const seen = new Map()
  const told = new Set()
  const roots = new WeakSet()
  const up = (e) => e.parentElement ?? (e.getRootNode() instanceof ShadowRoot ? e.getRootNode().host : null)
  const owner = (n) => {
    for (let e = n; e; e = up(e)) if (e.dataset?.part) return e.dataset.part
    return null
  }
  const note = (el, from, kind) => seen.has(el) || seen.set(el, { of: owner(el.isConnected ? el : from), kind })
  const records = (list) => {
    for (const m of list) if (m.type === 'attributes') take(m.target)
    else for (const n of m.addedNodes) take(n, m.target)
  }
  const mo = new MutationObserver(records)
  const describe = (el) => `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''} "${(el.textContent || '').trim().slice(0, 30)}"`
  const placed = placement(script, owner, (part) => [...seen].filter(([el, v]) => v.kind === 'can' && (part === undefined || v.of === part)).map(([el]) => el), describe)
  const watch = (r) => {
    mo.observe(r, { childList: true, subtree: true, attributes: true, attributeFilter: ['popover'] })
    placed.watch(r)
  }
  function take(n, from = n) {
    if (n.nodeType !== 1) return
    for (const e of [n, ...n.querySelectorAll('*')]) {
      if (e.matches(CAN)) note(e, from, 'can')
      if (e.matches(FRAMES)) note(e, from, 'frame')
      if (e.shadowRoot && !roots.has(e.shadowRoot)) {
        roots.add(e.shadowRoot)
        watch(e.shadowRoot)
        for (const c of e.shadowRoot.children) take(c)
      }
    }
  }
  watch(document)
  if (document.documentElement) take(document.documentElement)
  // The host, at once inside attachShadow, before the page can put anything in its new root.
  addEventListener('barkui-census-root', (e) => take(e.composedPath()[0]), true)
  for (const at of ['window.open', 'document.write', 'document.writeln', 'document.open'])
    addEventListener(`barkui-census-${at}`, () => seen.has(at) || seen.set(at, { of: null, kind: 'call' }), true)
  globalThis.__barkPlacement = (part) => {
    // Every box seen so far, even one given popover and gone again since the last delivery.
    records(mo.takeRecords())
    if (document.documentElement) take(document.documentElement)
    return placed.look(part)
  }
  globalThis.__barkHolders = (part) => placed.holders(part)
  globalThis.__barkCensus = (part, boxes) => {
    if (document.documentElement) take(document.documentElement)
    const stage = document.querySelector(`[data-part="${CSS.escape(part)}"]`)
    const named = new Set(boxes.map((s) => stage?.querySelector(s)).filter(Boolean))
    const out = []
    for (const [el, { of, kind }] of seen) {
      if (told.has(el) || (of !== null && of !== part) || named.has(el)) continue
      if (kind === 'can' && !el.isConnected && of === part && boxes.some((s) => el.matches(s))) continue
      told.add(el)
      out.push({ kind, at: kind === 'call' ? el : describe(el) })
    }
    return out
  }
}

/** Runs in the page's own world before any of its script, in this window and in every frame (it is serialised).
    attachShadow tells the census each host the moment its root exists, by an event the census hears first. What
    would put a window or a document out of the census's sight is refused and told by name instead: window.open, and
    document.open, write and writeln once the document is parsed (while it is parsing, written markup is parsed like
    the rest). removeAttribute and removeAttributeNS bring a style attribute up to date before they run: Chromium
    writes a style set through el.style or attributeStyleMap into the attribute only when it is next read, and
    removeAttribute does not read it first, so the record the placement log gets would hold the value before that
    write, not the one the element held (placement.mjs). The page cannot remove or replace any of these, and they
    call nothing it can change afterwards. */
function tellRoots() {
  const [apply, define, send, Ev, doc] = [Reflect.apply, Object.defineProperty, EventTarget.prototype.dispatchEvent, Event, document]
  const [getAttr, removeAttr, removeAttrNS] = [Element.prototype.getAttribute, Element.prototype.removeAttribute, Element.prototype.removeAttributeNS]
  const [attach, write, writeln, ready] = [Element.prototype.attachShadow, Document.prototype.write, Document.prototype.writeln, Object.getOwnPropertyDescriptor(Document.prototype, 'readyState').get]
  const tell = (target, type) => apply(send, target, [new Ev(type, { bubbles: true, composed: true })])
  const fix = (o, k, value) => define(o, k, { value, writable: false, enumerable: true, configurable: false })
  fix(Element.prototype, 'attachShadow', function attachShadow(init) {
    const root = apply(attach, this, [init])
    tell(this, 'barkui-census-root')
    return root
  })
  fix(Element.prototype, 'removeAttribute', function removeAttribute(...a) {
    apply(getAttr, this, ['style'])
    return apply(removeAttr, this, a)
  })
  fix(Element.prototype, 'removeAttributeNS', function removeAttributeNS(...a) {
    apply(getAttr, this, ['style'])
    return apply(removeAttrNS, this, a)
  })
  fix(window, 'open', function open() {
    tell(window, 'barkui-census-window.open')
    return null
  })
  fix(Document.prototype, 'open', function open() {
    tell(window, 'barkui-census-document.open')
    return this
  })
  for (const [k, f] of [['write', write], ['writeln', writeln]])
    fix(Document.prototype, k, function (...a) {
      if (this !== doc || apply(ready, doc, []) === 'loading') return apply(f, this, a)
      tell(window, `barkui-census-document.${k}`)
    })
}

/** The census world on `page`, set before the page opens its URL, so it watches from the first frame. Returns
    look(part) → what census() names for the part, and look.placement(name) → the placement fails for the part
    (placement.mjs). A page that runs no script of its own (`script` false) gets the census when first asked:
    nothing on it can add a box or write a style attribute later. */
export async function installCensus(page, { script = true } = {}) {
  const cdp = await page.context().newCDPSession(page)
  const { frameTree } = await cdp.send('Page.getFrameTree')
  const frameId = frameTree.frame.id
  let id = null
  cdp.on('Runtime.executionContextCreated', ({ context: c }) => {
    if (c.name === 'barkui-census' && c.auxData?.frameId === frameId) id = c.id
  })
  await cdp.send('Runtime.enable')
  // A script to evaluate on a new document runs only for a session with the Page domain on.
  await cdp.send('Page.enable')
  const code = (on) => `(${source(census)})(${placementSource(source)}, ${on})`
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: code(script), worldName: 'barkui-census' })
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: `(${source(tellRoots)})()` })
  const run = async (expression) => {
    const { result, exceptionDetails } = await cdp.send('Runtime.evaluate', { expression, contextId: id, returnByValue: true })
    if (exceptionDetails) throw new Error(`the census: ${String(exceptionDetails.exception?.description ?? exceptionDetails.text).split('\n')[0]}`)
    return result.value
  }
  // Another window the page opens by any way but window.open (a link or a form with a target, opener or not): its
  // own attachShadow is not hooked, so it is closed at once and refused by name, once each.
  let windows = 0
  page.on('popup', (w) => {
    windows++
    w.close().catch(() => {})
  })
  let ready = false
  const ensure = async () => {
    if (!ready && (id === null || !(await run('typeof __barkCensus === "function"').catch(() => false)))) {
      id = (await cdp.send('Page.createIsolatedWorld', { frameId, worldName: 'barkui-census-late' })).executionContextId
      await run(code(script))
    }
    ready = true
  }
  const look = async (part) => {
    await ensure()
    const opened = Array.from({ length: windows }, () => REFUSED.window)
    windows = 0
    return [...opened, ...(await run(`__barkCensus(${JSON.stringify(part.name)}, ${JSON.stringify((part.json.layers ?? []).map((l) => l.box))})`)).map(said)]
  }
  look.placement = async (name) => {
    await ensure()
    return [...(await run(`__barkPlacement(${JSON.stringify(name)})`)), ...(await shadowAbove(name))]
  }
  /** Each element that holds a stage of the part and hosts a shadow root, of any mode and however it was made: asked
      of the browser's own tree, at the look, element by element. A holder the browser gives no answer for fails. */
  const shadowAbove = async (name) => {
    const objectGroup = 'barkui-holders'
    const t0 = Date.now()
    const ask = (method, params) => within(cdp.send(method, params), `${method} gave no answer in ${ASK_MS / 1000} s`)
    const fails = []
    try {
      const { result, exceptionDetails } = await ask('Runtime.evaluate', { expression: `__barkHolders(${JSON.stringify(name)})`, contextId: id, objectGroup })
      if (exceptionDetails || !result?.objectId) throw new Error('the census did not list them')
      const { result: items } = await ask('Runtime.getProperties', { objectId: result.objectId, ownProperties: true })
      const at = new Map(items.filter((p) => /^\d+$/.test(p.name)).map((p) => [Number(p.name), p.value]))
      for (let i = 0; at.has(i); i += 2) {
        const who = String(at.get(i + 1)?.value ?? `holder ${i / 2 + 1}`)
        holderReads.holders++
        try {
          const objectId = at.get(i)?.objectId
          if (!objectId) throw new Error('no element')
          const { node } = await ask('DOM.describeNode', { objectId, depth: 0 })
          if (!node) throw new Error('no node')
          if (node.shadowRoots?.length) fails.push(SHADOW_ABOVE(who))
        } catch (e) {
          fails.push(HOLDER_UNREAD(who, e.message))
        }
      }
    } catch (e) {
      fails.push(HOLDERS_UNLISTED(name, e.message))
    } finally {
      await cdp.send('Runtime.releaseObjectGroup', { objectGroup }).catch(() => {})
      holderReads.looks++
      holderReads.ms += Date.now() - t0
    }
    return fails
  }
  return look
}

/** After real input (a Tab stop, a driven state, a press step, a layer's input), the fails for what no layer
    names: each box open in the top layer now, and each element that can open there that the census has seen. */
export async function unnamedNow(page, part) {
  const t0 = Date.now()
  try {
    const open = await page.barkCheck(([n, b]) => window.__barkCheck.unnamed(document.querySelector(`[data-part="${n}"]`), b), [part.name, (part.json.layers ?? []).map((l) => l.box)])
    const can = page.barkCensus ? await page.barkCensus(part) : []
    return [...open.map(UNNAMED), ...can]
  } finally {
    looks.n++
    looks.ms += Date.now() - t0
  }
}
/** How many of those looks this process made, and how long they took: the selftest prints what they cost. */
export const looks = { n: 0, ms: 0 }
/** What asking the browser about the holders of stages cost, over a process: looks, holders read, and ms. */
export const holderReads = { looks: 0, holders: 0, ms: 0 }
export const holderSentence = () => `placement: ${holderReads.looks} looks asked the browser about ${holderReads.holders} holders of a stage, in ${(holderReads.ms / 1000).toFixed(1)} s`
// One answer from the browser, or a fail by name after ASK_MS.
const ASK_MS = 5000
const within = (p, why) => {
  let timer
  return Promise.race([p, new Promise((_, no) => (timer = setTimeout(() => no(new Error(why)), ASK_MS)))]).finally(() => clearTimeout(timer))
}

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

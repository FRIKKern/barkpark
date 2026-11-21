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
// A top-layer box open during any reading that no layer of the part names is a fail by name, so leaving a box out
// of part.json never leaves it unread.
import { limit } from './limit.mjs'

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
  Object.assign(h, { layers, behind, hideLayers, under })
}

/** Real input on the page: a click at a control's centre (only once it is what is on top there), then keys. */
async function drive(page, part, step, what) {
  if (step.focus) await page.barkCheck(([n, s]) => document.querySelector(`[data-part="${n}"] ${s}`)?.focus(), [part.name, step.focus])
  if (step.click) {
    const at = await page.barkCheck(([n, s]) => {
      const el = document.querySelector(`[data-part="${n}"] ${s}`)
      if (!el) return { miss: 'is not in the stage' }
      el.scrollIntoView({ block: 'center', inline: 'center' })
      const r = el.getBoundingClientRect()
      const [x, y] = [r.left + r.width / 2, r.top + r.height / 2]
      const top = document.elementFromPoint(x, y)
      return el === top || el.contains(top) ? { x, y } : { miss: `is not what a click at its centre reaches: ${window.__barkCheck.describe(top)} is on top` }
    }, [part.name, step.click])
    if (at.miss) throw new Error(`${what}: ${step.click} ${at.miss}`)
    await page.mouse.click(at.x, at.y)
  }
  for (const key of step.keys ?? []) await page.keyboard.press(key)
  await page.barkCheck(() => window.__barkCheck.settle())
}

const isOpen = (page, part, box) => page.barkCheck(([n, s, top]) => !!document.querySelector(`[data-part="${n}"] ${s}`)?.matches(top), [part.name, box, ':popover-open, :modal'])

/** Each of the part's layers opened by its own input, read by `read` while open, then closed by its input. The
    fails of each, with what opening or closing did not do; `read(layer)` returns the fails of that reading. */
export async function eachLayer(page, part, read) {
  const fails = []
  for (const layer of part.json.layers ?? []) {
    const name = `the layer ${layer.box}`
    try {
      await limit(drive(page, part, layer.open, `opening ${name}`), STEP_MS, `opening ${name}`)
      if (!(await isOpen(page, part, layer.box))) {
        fails.push(`${name} is not open in the top layer after its "open" input`)
        continue
      }
      fails.push(...(await read(layer)))
    } catch (e) {
      fails.push(String(e.message).split('\n')[0])
    } finally {
      try {
        await limit(drive(page, part, layer.close, `closing ${name}`), STEP_MS, `closing ${name}`)
        if (await isOpen(page, part, layer.box)) fails.push(`${name} is still open after its "close" input`)
      } catch (e) {
        fails.push(String(e.message).split('\n')[0])
      }
    }
  }
  return fails
}

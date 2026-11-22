// Placement in a style attribute. UI SDK places a popup by writing where it sits into the box's own style
// attribute, and names the control it hangs from there too. That is the one thing a style attribute in a stage may
// hold: where a top-layer box sits, never how anything looks. The look belongs in part.css.
//
// The closed list is here, once, with the UI SDK control that writes each entry, and apart from it one more entry
// with its own reason, transition, the one entry whose value is read. A box is an element the census
// (layers.mjs) has seen can open in the top layer for the part: a dialog, or an element that carries popover. Every
// box property is allowed only on such a box; anchor-name only on an element whose anchor name a box's
// position-anchor names; anything else, anywhere in a stage, fails by name. docs/PARTS.md "Placement" prints the
// same list, and a unit row is red when the two differ.
//
// What is read: the declarations the browser applies, by property name (values are not read, except transition's), as it parses the attribute's text (a
// shorthand is judged by its longhands, so `inset` is top, right, bottom and left, and `all` is its own name).
// Text the browser drops is not a declaration. When it is read: every value the attribute holds, from the page's
// first frame (placementWorld, below, in the census's world), so a property written while a box is open and taken
// away at close fails by name. On a stage with no script, any style attribute fails: nothing there can write one.

export const REASON = 'placement is where a box sits, never how it looks'

const SELECT_MENU = 'UI SDK select and menu, on the box (foundation/platform/anchoring.js and position.js)'
/** The closed list: each property, where it may stand (`box`, or `anchor`: the element a box anchors to), and which
    UI SDK control writes it. `value`, where given, is the one value the whole shorthand may hold. */
export const PLACEMENT = [
  { property: 'anchor-name', on: 'anchor', writer: 'UI SDK select and menu, on the trigger (foundation/platform/anchoring.js)' },
  { property: 'position-anchor', on: 'box', writer: SELECT_MENU },
  { property: 'position', on: 'box', writer: SELECT_MENU },
  { property: 'top', on: 'box', writer: SELECT_MENU },
  { property: 'right', on: 'box', writer: SELECT_MENU },
  { property: 'bottom', on: 'box', writer: SELECT_MENU },
  { property: 'left', on: 'box', writer: SELECT_MENU },
  { property: 'margin-top', on: 'box', writer: SELECT_MENU },
  { property: 'margin-right', on: 'box', writer: SELECT_MENU },
  { property: 'margin-bottom', on: 'box', writer: SELECT_MENU },
  { property: 'margin-left', on: 'box', writer: SELECT_MENU },
  { property: 'position-try-fallbacks', on: 'box', writer: SELECT_MENU },
  { property: 'position-visibility', on: 'box', writer: SELECT_MENU },
  { property: '--available-height', on: 'box', writer: SELECT_MENU },
  { property: '--available-width', on: 'box', writer: SELECT_MENU },
  { property: '--anchor-width', on: 'box', writer: SELECT_MENU },
  { property: '--anchor-height', on: 'box', writer: SELECT_MENU },
  { property: '--transform-origin', on: 'box', writer: SELECT_MENU },
  { property: '--arrow-offset', on: 'box', writer: SELECT_MENU },
  { property: '--dialog-stack', on: 'box', writer: 'UI SDK dialog, on the box (components/dialog/dialog-parts.js)' },
  { property: '--keyboard-inset', on: 'box', writer: 'UI SDK dialog, on the box (foundation/platform/keyboard.js)' },
  { property: '--visual-viewport-height', on: 'box', writer: 'UI SDK dialog, on the box (foundation/platform/keyboard.js)' },
]

/** Apart from the list, with its own reason: UI SDK writes "transition: none" on a select or menu box when it first
    places it and puts the old value back in the same task (foundation/platform/position.js), so only a reader from
    the first frame sees it. Allowed only on a box, and only as "none" in all five longhands; any other value, or
    none on an element that is not a box, fails by name. */
export const TRANSITION = {
  property: 'transition',
  longhands: ['transition-behavior', 'transition-duration', 'transition-timing-function', 'transition-delay', 'transition-property'],
  value: 'none',
  on: 'box',
  reason: 'UI SDK switches motion off on a box while it measures where to put it; none takes motion away and adds no look',
  writer: 'UI SDK select and menu, on the box (foundation/platform/position.js)',
}
/** Every entry the judge allows: the list, then transition. */
export const ALLOWED = [...PLACEMENT, TRANSITION]

/** The fail for a property that is not placement, on any element in a stage. */
export const NOT_PLACEMENT = (at, prop) => `${at} was given ${prop} in a style attribute, which is not placement: the look belongs in part.css`
/** The fail for a box property on an element that cannot open in the top layer. */
export const NOT_A_BOX = (at, prop) => `${at} was given ${prop} in a style attribute, and only a box that can open in the top layer may carry it there`
/** The fail for an anchor name no box's position-anchor names. */
export const NOT_ANCHORED = (at, name) => `${at} was given anchor-name ${name} in a style attribute, and no box in the top layer anchors to it`
/** The fail for an entry with one value, given another. */
export const NOT_VALUE = (at, prop, value, entry) => `${at} was given ${prop}: ${value} in a style attribute, and ${entry.property} is allowed there only as "${entry.property}: ${entry.value}"`
/** The fail for any style attribute on a stage with no script. */
export const NO_SCRIPT = (at) => `${at} carries a style attribute on the stage with no script, where nothing may write one`

/** Runs in the census's world (it is serialised): the log of every value each style attribute in a stage holds,
    from the first frame, and the judge of it. `list` is ALLOWED; `script` is false on a page with no script; `say`
    holds the fails' wording; `owner(el)` names the part whose stage holds el (null outside every stage);
    `boxes(part)` the elements the census has seen can open in the top layer for that part; `describe(el)` names an
    element. Returns { watch(root): observe a document or an open shadow root from now on, look(part): the fails
    for that part, in the order first seen }. */
export function placementWorld(list, script, say, owner, boxes, describe) {
  const entries = new Map()
  for (const e of list) for (const name of [e.property, ...(e.longhands ?? [])]) entries.set(name, e)
  const pad = document.createElement('div')
  const parse = (text) => {
    pad.setAttribute('style', text)
    const decls = []
    for (let i = 0; i < pad.style.length; i++) decls.push({ prop: pad.style.item(i), value: pad.style.getPropertyValue(pad.style.item(i)) })
    return { decls, of: (name) => pad.style.getPropertyValue(name) }
  }
  // Every value held, by element: text, and the part whose stage held the element then.
  const held = new Map()
  const hold = (el, text, part) => {
    if (text === null || part === null) return
    if (!held.has(el)) held.set(el, new Map())
    if (!held.get(el).has(text)) held.get(el).set(text, part)
  }
  const up = (n) => (n.parentNode instanceof ShadowRoot ? n.parentNode.host : n.parentNode)
  // Where a node stood when record i was made: one taken out later in the same delivery stood where it was taken
  // from. `gone` maps each node taken out in the delivery to [its record's index, the parent it left].
  const where = (node, i, gone) => {
    let top = node
    for (let n = node; n; n = up(n)) top = n
    if (top === document) return owner(node)
    const g = gone.get(top)
    return g && g[0] > i ? where(g[1], g[0], gone) : null
  }
  // An element as it arrives, with all under it and inside each open shadow root it carries.
  const arrive = (n, part) => {
    if (n.nodeType !== 1) return
    for (const e of [n, ...n.querySelectorAll('*')]) {
      if (e.hasAttribute('style')) hold(e, e.getAttribute('style'), part)
      if (e.shadowRoot) for (const c of e.shadowRoot.children) arrive(c, part)
    }
  }
  const take = (records) => {
    const gone = new Map()
    records.forEach((m, i) => {
      if (m.type === 'childList') for (const n of m.removedNodes) gone.set(n, [i, m.target])
    })
    records.forEach((m, i) => {
      if (m.type === 'childList') {
        for (const n of m.addedNodes) arrive(n, where(m.target, i, gone))
        return
      }
      // Each record holds the value before it; the value after the last one is the attribute now.
      const part = where(m.target, i, gone)
      hold(m.target, m.oldValue, part)
      if (!records.some((r, k) => k > i && r.type === 'attributes' && r.target === m.target)) hold(m.target, m.target.getAttribute('style'), part)
    })
  }
  const so = new MutationObserver(take)
  const watch = (root) => so.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'], attributeOldValue: true })
  const look = (part) => {
    take(so.takeRecords())
    for (const e of document.querySelectorAll('[style]')) hold(e, e.getAttribute('style'), owner(e))
    const mine = new Set(boxes(part))
    // The anchor names the part's boxes hang from: every position-anchor a box held, or holds from part.css.
    const anchors = new Set()
    for (const b of mine) {
      for (const text of held.get(b)?.keys() ?? []) anchors.add(parse(text).of('position-anchor').trim())
      if (b.isConnected) anchors.add(getComputedStyle(b).getPropertyValue('position-anchor').trim())
    }
    const fails = []
    const fail = (s) => fails.includes(s) || fails.push(s)
    for (const [el, texts] of held)
      for (const [text, of] of texts) {
        if (of !== part) continue
        const at = describe(el)
        if (!script) {
          fail(say.NO_SCRIPT(at))
          continue
        }
        const p = parse(text)
        for (const { prop, value } of p.decls) {
          const e = entries.get(prop)
          if (!e) fail(say.NOT_PLACEMENT(at, prop))
          else if (e.on === 'box' && !mine.has(el)) fail(say.NOT_A_BOX(at, prop))
          else if (e.value !== undefined && p.of(e.property) !== e.value) fail(say.NOT_VALUE(at, prop, value, e))
          else if (e.on === 'anchor') for (const name of value.split(',').map((s) => s.trim())) if (!anchors.has(name)) fail(say.NOT_ANCHORED(at, name))
        }
      }
    return fails
  }
  return { watch, look }
}

/** placementWorld as code for the census's world, the list and the fails' wording in it: a function of
    (script, owner, boxes, describe). `source` is probes.mjs's. */
export function placementSource(source) {
  const say = { NOT_PLACEMENT, NOT_A_BOX, NOT_ANCHORED, NOT_VALUE, NO_SCRIPT }
  const said = `{ ${Object.entries(say).map(([k, f]) => `${k}: ${source(f)}`).join(', ')} }`
  return `((script, owner, boxes, describe) => (${source(placementWorld)})(${JSON.stringify(ALLOWED)}, script, ${said}, owner, boxes, describe))`
}

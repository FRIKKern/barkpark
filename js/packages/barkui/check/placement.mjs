// Placement in a style attribute. UI SDK places a popup by writing where it sits into the box's own style
// attribute, and names the control it hangs from there too. That is the one thing a style attribute in a stage may
// hold: where a top-layer box sits, never how anything looks. The look belongs in part.css.
//
// The closed list is here, once, with the UI SDK control that writes each entry, and apart from it one more entry
// with its own reason, TRANSITION. A box is an element the census
// (layers.mjs) has seen can open in the top layer for the part: a dialog, or an element that carries popover. Every
// box property is allowed only on such a box; anchor-name only on an element whose anchor name a box's
// position-anchor names; anything else, anywhere in a stage, fails by name. docs/PARTS.md "Placement" prints the
// same list, and a unit row is red when the two differ.
//
// SLOTS is the third list, with its own reason: the pieces of a control UI SDK lays out at run time (a slider's
// control, track, indicator, thumbs and the range input it hides in each thumb), each with only the properties UI SDK
// writes on it, by line, and the values it writes there. A later control's pieces go in as more entries.
//
// SCROLL_LOCK is the second list, with its own reason and its values, for an element that holds a stage: the root
// element or body only, and only while a dialog box is open. OUT_OF_DOCUMENT names a stage that does not stand in
// the document; SHADOW_ABOVE names an element that holds a stage and hosts a shadow root, asked of the browser's
// own tree by layers.mjs.
//
// docs/PARTS.md "Placement" says what is read and when. placementWorld, below, keeps the log in the census's
// world and judges it. On a stage with no script, any style attribute fails: nothing there can write one.

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

/** The second list, for the root element and body, which hold every stage, with its own reason: UI SDK stops the page
    scrolling behind an open dialog by writing these on the root element (its scroller), each with the one value, or
    the one kind of value, it writes; scrollbar-gutter and --scrollbar-width only when the page has a scrollbar that
    takes room. It is what UI SDK writes in the browser the check runs: where scrollbar-gutter is missing it writes
    padding-right instead, which is not here. UI SDK writes the lock a frame after the box enters the top layer and
    takes it away before the box leaves, so it is allowed only while a dialog box is open. Any other element that
    holds a stage may carry nothing: a stage inherits from it. */
export const ROOT_REASON = 'UI SDK stops the page scrolling behind an open dialog; that is behaviour, not look'
const LOCK = 'UI SDK dialog, on the root element (foundation/popups/modal.js)'
export const SCROLL_LOCK = [
  { property: 'overflow-x', on: 'root', value: 'hidden', writer: LOCK },
  { property: 'overflow-y', on: 'root', value: 'hidden', writer: LOCK },
  { property: 'scroll-behavior', on: 'root', value: 'auto', writer: LOCK },
  { property: 'scrollbar-gutter', on: 'root', value: 'stable', writer: LOCK },
  { property: '--scrollbar-width', on: 'root', length: 'px', writer: LOCK },
]

/** The third list, with its own reason, for the pieces of a UI SDK control that lays them out at run time: each slot
    by the element it is (`at`, a selector), and each property UI SDK writes there, by its lines in the writer's file.
    `values` are the values UI SDK writes there (any one of them, as the browser gives it back), where `{p}` is a place
    on the track, a number from 0 to 100: UI SDK writes every place as a percentage it clamps to that range (percentOf
    in components/slider/slider-values.js). Every entry has its values. A slot carries only its own properties; any other property there, any of them on another
    element, and a value UI SDK does not write fail by name, as any style attribute does. A later control's slots go in as more entries. */
export const SLOT_REASON = 'UI SDK lays out the pieces of a slider on its track at run time; where a piece sits is not how it looks'
const SLIDER = 'UI SDK slider, on its pieces (components/slider/slider.js)'
const PLACE = { values: ['{p}%'] }
export const SLOTS = [
  { slot: 'ui-slider-control', at: 'ui-slider ui-slider-control', writer: SLIDER, writes: [{ property: 'touch-action', values: ['none'], lines: [179] }] },
  { slot: 'ui-slider-track', at: 'ui-slider ui-slider-track', writer: SLIDER, writes: [{ property: 'position', values: ['relative'], lines: [187] }] },
  {
    slot: 'ui-slider-indicator',
    at: 'ui-slider ui-slider-indicator',
    writer: SLIDER,
    writes: [
      { property: 'position', values: ['absolute'], lines: [79] },
      { property: 'inset-inline-start', ...PLACE, lines: [80] },
      { property: 'width', ...PLACE, lines: [81] },
      { property: 'height', ...PLACE, lines: [81] },
      { property: 'top', values: ['0'], lines: [82] },
      { property: 'bottom', values: ['0', '{p}%'], lines: [80, 82] },
      { property: 'left', values: ['0'], lines: [82] },
      { property: 'right', values: ['0'], lines: [82] },
      { property: '--slider-indicator-start', ...PLACE, lines: [83] },
      { property: '--slider-indicator-size', ...PLACE, lines: [84] },
    ],
  },
  {
    slot: 'ui-slider-thumb',
    at: 'ui-slider ui-slider-thumb',
    writer: SLIDER,
    writes: [
      { property: 'position', values: ['absolute'], lines: [59] },
      { property: 'bottom', ...PLACE, lines: [60] },
      { property: 'left', values: ['50%'], lines: [60] },
      { property: 'translate', values: ['-50% 50%', '0 -50%'], lines: [60, 65] },
      { property: 'inset-inline', values: ['calc({p}% - 50%) calc(50% - {p}%)'], lines: [61] },
      { property: 'margin-inline', values: ['auto'], lines: [62] },
      { property: 'justify-self', values: ['center'], lines: [63] },
      { property: 'top', values: ['50%'], lines: [64] },
      { property: 'z-index', values: ['1', '2'], lines: [67] },
      { property: '--slider-thumb-position', ...PLACE, lines: [68] },
    ],
  },
  {
    slot: 'the range input in ui-slider-thumb-input',
    at: 'ui-slider ui-slider-thumb > ui-slider-thumb-input > input[type="range"]',
    writer: SLIDER,
    writes: [
      { property: 'position', values: ['absolute'], lines: [88] },
      { property: 'inset', values: ['0'], lines: [89] },
      { property: 'width', values: ['100%'], lines: [90] },
      { property: 'height', values: ['100%'], lines: [91] },
      { property: 'margin', values: ['0'], lines: [92] },
      { property: 'padding', values: ['0'], lines: [93] },
      { property: 'border', values: ['0'], lines: [94] },
      { property: 'opacity', values: ['0'], lines: [95] },
      { property: 'overflow', values: ['hidden'], lines: [96] },
      { property: 'clip-path', values: ['inset(50%)'], lines: [97] },
      { property: 'white-space', values: ['nowrap'], lines: [98] },
      { property: 'pointer-events', values: ['none'], lines: [99] },
    ],
  },
]

/** The fail for a property that is not placement, on any element in a stage. */
export const NOT_PLACEMENT = (at, prop) => `${at} was given ${prop} in a style attribute, which is not placement: the look belongs in part.css`
/** The fail for a box property on an element that cannot open in the top layer. */
export const NOT_A_BOX = (at, prop) => `${at} was given ${prop} in a style attribute, and only a box that can open in the top layer may carry it there`
/** The fail for an anchor name no box's position-anchor names. */
export const NOT_ANCHORED = (at, name) => `${at} was given anchor-name ${name} in a style attribute, and no box in the top layer anchors to it`
/** The fail for an entry with one value, given another. */
export const NOT_VALUE = (at, prop, value, entry) => `${at} was given ${prop}: ${value} in a style attribute, and ${entry.property} is allowed there only as "${entry.property}: ${entry.value}"`
/** The fail for a property off the scroll lock on the root element or body. */
export const NOT_LOCK = (at, prop) => `${at} was given ${prop} in a style attribute, and it holds every stage: only the scroll lock may stand there, while a dialog is open`
/** The fail for a scroll lock property with a value the lock does not write. */
export const LOCK_VALUE = (at, prop, value, entry) => `${at} was given ${prop}: ${value} in a style attribute, and the scroll lock writes ${prop} there only as ${entry.length ? `a ${entry.length} length` : `"${entry.value}"`}`
/** The fail for a slot's property with a value UI SDK does not write there. */
export const SLOT_VALUE = (at, prop, value, slot, w) =>
  `${at} was given ${prop}: ${value} in a style attribute, and UI SDK writes ${w.property} on ${slot} only as ${w.values.map((v) => `"${v}"`).join(' or ')}${w.values.some((v) => v.includes('{p}')) ? ', {p} a number from 0 to 100' : ''}`
/** The fail for the scroll lock on the root element or body with no dialog open. */
export const NO_DIALOG = (at, prop) => `${at} was given ${prop} in a style attribute while no dialog was open: the scroll lock stands there only while a dialog is open`
/** The fail for any property on another element that holds a stage. */
export const ON_ANCESTOR = (at, prop) => `${at} was given ${prop} in a style attribute, and it holds a stage, which inherits from it: nothing may stand there`
/** The fail for a stage whose root node is not the document: one moved into a shadow root, or taken out. */
export const OUT_OF_DOCUMENT = (at) => `${at} is a stage outside the document itself: a stage stands in the document, never in a shadow root`
/** The fail for an element that holds a stage and hosts a shadow root, of any mode. */
export const SHADOW_ABOVE = (at) => `${at} hosts a shadow root above a stage: nothing that holds a stage may host one`
/** The fail for an element that holds a stage when the browser gives no answer on whether it hosts a shadow root. */
export const HOLDER_UNREAD = (at, why) => `${at} holds a stage, and the browser gave no answer on whether it hosts a shadow root (${why}): one the check cannot read fails`
/** The fail for a part whose stage's holders the check could not list for the browser. */
export const HOLDERS_UNLISTED = (part, why) => `the check could not list what holds the stage of ${part} for the browser (${why}): a holder it cannot read fails`
/** The fail for any style attribute on a stage with no script. */
export const NO_SCRIPT = (at) => `${at} carries a style attribute on the stage with no script, where nothing may write one`

/** Runs in the census's world (it is serialised): the placement log and its judge; docs/PARTS.md "Placement"
    says what is read and when. `lists` is { allowed: ALLOWED, root:
    SCROLL_LOCK, slots: SLOTS }; `script` is false on a page with no script; `say` holds the fails' wording; `owner(el)` names the
    part whose stage holds el (null outside every stage); `boxes(part)` the elements the census has seen can open in
    the top layer for that part, and boxes() all of them; `describe(el)` names an element. Returns { watch(root): observe a document or an open
    shadow root from now on, look(part): the fails for that part, in the order first seen, holders(part): each
    element that holds a stage of the part, for the check to ask the browser whether it hosts a shadow root }. */
export function placementWorld(lists, script, say, owner, boxes, describe) {
  const entries = new Map()
  for (const e of lists.allowed) for (const name of [e.property, ...(e.longhands ?? [])]) entries.set(name, e)
  const lock = new Map(lists.root.map((e) => [e.property, e]))
  // A scroll lock value: the one value its entry gives, or a plain length in its unit.
  const fits = (e, value) => (e.length ? new RegExp(`^\\d+(\\.\\d+)?${e.length}$`).test(value.trim()) : value.trim() === e.value)
  const pad = document.createElement('div')
  const parse = (text) => {
    pad.setAttribute('style', text)
    const decls = []
    for (let i = 0; i < pad.style.length; i++) decls.push({ prop: pad.style.item(i), value: pad.style.getPropertyValue(pad.style.item(i)) })
    return { decls, of: (name) => pad.style.getPropertyValue(name) }
  }
  // Each slot's writes by the longhands the browser applies.
  const slots = lists.slots.map((s) => {
    const by = new Map()
    for (const w of s.writes) for (const { prop } of parse(`${w.property}: inherit`).decls) by.set(prop, w)
    return { ...s, by }
  })
  // A value of a write as the browser gives it back for the longhand `prop`, on a pad of its own (parse's stays put).
  const norm = document.createElement('div')
  const given = (w, prop, v) => {
    norm.setAttribute('style', `${w.property}: ${v}`)
    return norm.style.getPropertyValue(prop).trim()
  }
  // A value fits when it is one UI SDK writes there, with {p} a place from 0 to 100. The places tried are each number in
  // the value, and the place it stands for in a form the browser folds (calc(40% - 50%) comes back as calc(-10%)).
  const slotFits = (w, prop, value) => {
    const v = value.trim()
    return w.values.some((form) => {
      if (!form.includes('{p}')) return given(w, prop, form) === v
      const ps = [...v.matchAll(/-?\d+(\.\d+)?/g)].flatMap((m) => [+m[0], +m[0] + 50, 50 - +m[0], -m[0], +m[0] - 50])
      return ps.some((p) => p >= 0 && p <= 100 && given(w, prop, form.replaceAll('{p}', String(p))) === v)
    })
  }
  // Whether a dialog box is open: one the census has seen can open in the top layer, open now, that is a dialog or holds
  // one. The browser tells beforetoggle at once, before a box opens or closes, so the writes waiting until then are
  // taken there, while the box is as it was.
  const DIALOG = 'dialog, [role="dialog"], [role="alertdialog"]'
  const dialogOpen = () => boxes().some((b) => b.isConnected && b.matches(':modal, :popover-open, dialog[open]') && (b.matches(DIALOG) || !!b.querySelector(DIALOG)))
  const toggles = () => take(so.takeRecords())
  // Where an element stands: in a part's stage ({ part }), or holding stages ({ parts, root: the root element or
  // body, dialog: a dialog box open }); null when neither.
  const place = (el) => {
    const part = owner(el)
    if (part !== null) return { part }
    if (el.nodeType !== 1 || !el.querySelector('[data-part]')) return null
    return { parts: [...el.querySelectorAll('[data-part]')].map((e) => e.dataset.part), root: el === document.documentElement || el === document.body, dialog: dialogOpen() }
  }
  // Every value held, by element: each text with where the element stood then.
  const held = new Map()
  const hold = (el, text, at) => {
    if (text === null || at === null) return
    if (!held.has(el)) held.set(el, new Map())
    const key = `${at.dialog ? 1 : 0}${text}`
    if (!held.get(el).has(key)) held.get(el).set(key, { text, at })
  }
  const up = (n) => (n.parentNode instanceof ShadowRoot ? n.parentNode.host : n.parentNode)
  // Where a node stood when record i was made: one taken out later in the same delivery stood where it was taken
  // from. `gone` maps each node taken out in the delivery to [its record's index, the parent it left].
  const where = (node, i, gone) => {
    let top = node
    for (let n = node; n; n = up(n)) top = n
    if (top === document) return place(node)
    const g = gone.get(top)
    if (!g || g[0] <= i) return null
    const from = where(g[1], g[0], gone)
    if (from?.part !== undefined) return from
    const p = place(node)
    return p?.parts ? p : null
  }
  // Every stage seen, by part: each element that carried data-part as it arrived, or at a look.
  const stages = new Map()
  const stage = (e) => e.dataset?.part !== undefined && (stages.get(e.dataset.part) ?? stages.set(e.dataset.part, new Set()).get(e.dataset.part)).add(e)
  const named = (el) => `${el.localName}${el.id ? '#' + el.id : ''}${el.dataset?.part !== undefined ? `[data-part="${el.dataset.part}"]` : ''}`
  // An element as it arrives, with all under it and inside each open shadow root it carries.
  const arrive = (n, i, gone) => {
    if (n.nodeType !== 1) return
    for (const e of [n, ...n.querySelectorAll('*')]) {
      stage(e)
      if (e.hasAttribute('style')) hold(e, e.getAttribute('style'), where(e, i, gone))
      if (e.shadowRoot) for (const c of e.shadowRoot.children) arrive(c, i, gone)
    }
  }
  const take = (records) => {
    const gone = new Map()
    records.forEach((m, i) => {
      if (m.type === 'childList') for (const n of m.removedNodes) gone.set(n, [i, m.target])
    })
    records.forEach((m, i) => {
      if (m.type === 'childList') {
        for (const n of m.addedNodes) arrive(n, i, gone)
        return
      }
      // Each record holds the value before it; the value after the last one is the attribute now.
      const at = where(m.target, i, gone)
      hold(m.target, m.oldValue, at)
      if (!records.some((r, k) => k > i && r.type === 'attributes' && r.target === m.target)) hold(m.target, m.target.getAttribute('style'), at)
    })
  }
  const so = new MutationObserver(take)
  const watch = (root) => {
    so.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'], attributeOldValue: true })
    root.addEventListener('beforetoggle', toggles, true)
  }
  const look = (part) => {
    take(so.takeRecords())
    for (const e of document.querySelectorAll('[style]')) hold(e, e.getAttribute('style'), place(e))
    for (const e of document.querySelectorAll('[data-part]')) stage(e)
    const mine = new Set(boxes(part))
    // The anchor names the part's boxes hang from: every position-anchor a box held, or holds from part.css.
    const anchors = new Set()
    for (const b of mine) {
      for (const { text } of held.get(b)?.values() ?? []) anchors.add(parse(text).of('position-anchor').trim())
      if (b.isConnected) anchors.add(getComputedStyle(b).getPropertyValue('position-anchor').trim())
    }
    const fails = []
    const fail = (s) => fails.includes(s) || fails.push(s)
    // A stage of the part whose root node is not the document fails: OUT_OF_DOCUMENT. (Whether anything that holds it hosts a shadow root, the check asks the browser: holders.)
    for (const s of stages.get(part) ?? []) if (s.getRootNode() !== document) fail(say.OUT_OF_DOCUMENT(named(s)))
    for (const [el, texts] of held)
      for (const { text, at } of texts.values()) {
        if (at.part !== undefined ? at.part !== part : !at.parts.includes(part)) continue
        // An element that holds a stage is named by its tag and id: its text is every stage's.
        const who = at.part !== undefined ? describe(el) : `${el.localName}${el.id ? '#' + el.id : ''}`
        if (!script) {
          fail(say.NO_SCRIPT(who))
          continue
        }
        const p = parse(text)
        for (const { prop, value } of p.decls) {
          if (at.part === undefined) {
            if (!at.root) fail(say.ON_ANCESTOR(who, prop))
            else if (!lock.has(prop)) fail(say.NOT_LOCK(who, prop))
            else if (!fits(lock.get(prop), value)) fail(say.LOCK_VALUE(who, prop, value, lock.get(prop)))
            else if (!at.dialog) fail(say.NO_DIALOG(who, prop))
            continue
          }
          // A slot of a control UI SDK lays out at run time carries what UI SDK writes on it, as it writes it.
          const s = slots.find((x) => el.matches(x.at))
          const own = s?.by.get(prop)
          if (own) {
            if (!slotFits(own, prop, value)) fail(say.SLOT_VALUE(who, prop, value, s.slot, own))
            continue
          }
          const e = entries.get(prop)
          if (!e) fail(say.NOT_PLACEMENT(who, prop))
          else if (e.on === 'box' && !mine.has(el)) fail(say.NOT_A_BOX(who, prop))
          else if (e.value !== undefined && p.of(e.property) !== e.value) fail(say.NOT_VALUE(who, prop, value, e))
          else if (e.on === 'anchor') for (const name of value.split(',').map((s) => s.trim())) if (!anchors.has(name)) fail(say.NOT_ANCHORED(who, name))
        }
      }
    return fails
  }
  // Each element that holds a stage of the part, then its name: [el, name, el, name, …].
  const holders = (part) => {
    const out = new Set()
    for (const e of document.querySelectorAll('[data-part]')) stage(e)
    for (const s of stages.get(part) ?? []) if (s.getRootNode() === document) for (let e = s.parentElement; e; e = e.parentElement) out.add(e)
    return [...out].flatMap((e) => [e, named(e)])
  }
  return { watch, look, holders }
}

/** placementWorld as code for the census's world, the list and the fails' wording in it: a function of
    (script, owner, boxes, describe). `source` is probes.mjs's. */
export function placementSource(source) {
  const say = { NOT_PLACEMENT, NOT_A_BOX, NOT_ANCHORED, NOT_VALUE, SLOT_VALUE, NO_SCRIPT, NOT_LOCK, LOCK_VALUE, NO_DIALOG, ON_ANCESTOR, OUT_OF_DOCUMENT, SHADOW_ABOVE }
  const said = `{ ${Object.entries(say).map(([k, f]) => `${k}: ${source(f)}`).join(', ')} }`
  return `((script, owner, boxes, describe) => (${source(placementWorld)})(${JSON.stringify({ allowed: ALLOWED, root: SCROLL_LOCK, slots: SLOTS })}, script, ${said}, owner, boxes, describe))`
}

// Real-key steps for the tabs. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the selected tab of the list across.

export function setup() {}

export const steps = [
  {
    name: "Tab enters the list at the selected tab, focus-visible, and every list's indicator, the pinned rows' too, sits on its selected tab",
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-overview')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (!t.matches(':focus-visible')) return 'not :focus-visible'
      const lists = [...root.querySelectorAll('[data-slot="tabs-list"]')]
      if (lists.length !== 5) return `${lists.length} tab lists, not 5`
      for (const list of lists) {
        const on = list.querySelector('[data-slot="tabs-tab"][data-selected]')
        const ind = list.querySelector(':scope > [data-slot="tabs-indicator"]')
        if (!ind) return `the list ${list.getAttribute('aria-label')} has no indicator`
        const [a, b] = [ind.getBoundingClientRect(), on.getBoundingClientRect()]
        const off = Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(a[k] - b[k])))
        if (off > 1) return `the indicator of ${list.getAttribute('aria-label')} sits ${off.toFixed(1)}px off ${h.describe(on)}`
      }
      return true
    },
    ax: { '#tabs-plant-wrong-overview': { role: 'tab', name: 'Overview', selected: true }, '#tabs-plant-wrong-reports': { role: 'tab', name: 'Reports', disabled: true } },
  },
  {
    name: 'ArrowRight selects the next tab, its panel shows, and the indicator slides to it',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-analytics')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-selected') !== 'true') return 'Analytics is not selected'
      const shown = [...root.querySelectorAll('#tabs-plant-wrong-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      if (shown.length !== 1) return `${shown.length} panels show`
      if (shown[0].getAttribute('aria-labelledby') !== t.id) return `the panel shown is ${h.describe(shown[0])}, not Analytics's`
      const ind = root.querySelector('#tabs-plant-wrong-main [data-slot="tabs-indicator"]')
      if (!ind) return 'the list across has no indicator'
      const [a, b] = [ind.getBoundingClientRect(), t.getBoundingClientRect()]
      const off = Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(a[k] - b[k])))
      return off <= 1 || `the indicator sits ${off.toFixed(1)}px off Analytics`
    },
  },
  {
    name: 'ArrowRight reaches the disabled tab: it takes focus, Enter and Space select nothing, and the Analytics panel stays',
    keys: ['ArrowRight', 'Enter', 'Space'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-reports')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-selected') === 'true') return 'the disabled Reports tab is selected'
      const shown = [...root.querySelectorAll('#tabs-plant-wrong-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      if (shown.length !== 1) return `${shown.length} panels show`
      return shown[0].getAttribute('aria-labelledby') === 'tabs-plant-wrong-analytics' || `the panel shown is ${h.describe(shown[0])}, not Analytics's`
    },
  },
  {
    name: 'ArrowRight from the last tab wraps to the first',
    keys: ['ArrowRight', 'ArrowRight'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-overview')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.getAttribute('aria-selected') === 'true' || 'Overview is not selected'
    },
  },
  {
    name: 'End reaches the last tab, and its panel shows',
    keys: ['End'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-settings')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const shown = [...root.querySelectorAll('#tabs-plant-wrong-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      return (shown.length === 1 && shown[0].getAttribute('aria-labelledby') === t.id) || 'the Settings panel does not show alone'
    },
  },
  {
    name: 'Home reaches the first tab, and its panel shows',
    keys: ['Home'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-overview')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const shown = [...root.querySelectorAll('#tabs-plant-wrong-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      return (shown.length === 1 && shown[0].getAttribute('aria-labelledby') === t.id) || 'the Overview panel does not show alone'
    },
  },
  {
    name: 'Tab moves from the list into the shown panel',
    keys: ['Tab'],
    expect: (root, h) => {
      const p = document.activeElement
      if (p?.getAttribute('role') !== 'tabpanel' || !p.closest('#tabs-plant-wrong-main')) return `focus is on ${h.describe(p)}`
      return p.getAttribute('aria-labelledby') === 'tabs-plant-wrong-overview' || `focus is on ${h.describe(p)}, not the Overview panel`
    },
  },
  {
    name: 'Down the side: Tab reaches the selected tab, ArrowDown selects the next, and the indicator slides down to it',
    keys: ['Tab', 'ArrowDown'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-password')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-selected') !== 'true') return 'Password is not selected'
      const ind = root.querySelector('#tabs-plant-wrong-side [data-slot="tabs-indicator"]')
      if (!ind) return 'the list down the side has no indicator'
      const [a, b] = [ind.getBoundingClientRect(), t.getBoundingClientRect()]
      const off = Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(a[k] - b[k])))
      return off <= 1 || `the indicator sits ${off.toFixed(1)}px off Password`
    },
  },
  {
    name: 'Down the side: ArrowRight does nothing',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-plant-wrong-password')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.getAttribute('aria-selected') === 'true' || 'Password is not selected'
    },
  },
]

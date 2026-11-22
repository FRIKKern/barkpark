// Real-key steps for the tabs. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the selected tab of the list across.

export function setup() {}

export const steps = [
  {
    name: 'Tab enters the list at the selected tab, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-overview')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#tabs-overview': { role: 'tab', name: 'Overview', selected: true }, '#tabs-reports': { role: 'tab', name: 'Reports', disabled: true } },
  },
  {
    name: 'ArrowRight selects the next tab, and its panel shows',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-analytics')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-selected') !== 'true') return 'Analytics is not selected'
      const shown = [...root.querySelectorAll('#tabs-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      if (shown.length !== 1) return `${shown.length} panels show`
      return shown[0].getAttribute('aria-labelledby') === t.id || `the panel shown is ${h.describe(shown[0])}, not Analytics's`
    },
  },
  {
    name: 'ArrowRight reaches the disabled tab: it takes focus, Enter and Space select nothing, and the Analytics panel stays',
    keys: ['ArrowRight', 'Enter', 'Space'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-reports')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-selected') === 'true') return 'the disabled Reports tab is selected'
      const shown = [...root.querySelectorAll('#tabs-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      if (shown.length !== 1) return `${shown.length} panels show`
      return shown[0].getAttribute('aria-labelledby') === 'tabs-analytics' || `the panel shown is ${h.describe(shown[0])}, not Analytics's`
    },
  },
  {
    name: 'ArrowRight from the last tab wraps to the first',
    keys: ['ArrowRight', 'ArrowRight'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-overview')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.getAttribute('aria-selected') === 'true' || 'Overview is not selected'
    },
  },
  {
    name: 'End reaches the last tab, and its panel shows',
    keys: ['End'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-settings')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const shown = [...root.querySelectorAll('#tabs-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      return (shown.length === 1 && shown[0].getAttribute('aria-labelledby') === t.id) || 'the Settings panel does not show alone'
    },
  },
  {
    name: 'Home reaches the first tab, and its panel shows',
    keys: ['Home'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-overview')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const shown = [...root.querySelectorAll('#tabs-main [role="tabpanel"]')].filter((p) => p.checkVisibility())
      return (shown.length === 1 && shown[0].getAttribute('aria-labelledby') === t.id) || 'the Overview panel does not show alone'
    },
  },
  {
    name: 'Tab moves from the list into the shown panel',
    keys: ['Tab'],
    expect: (root, h) => {
      const p = document.activeElement
      if (p?.getAttribute('role') !== 'tabpanel' || !p.closest('#tabs-main')) return `focus is on ${h.describe(p)}`
      return p.getAttribute('aria-labelledby') === 'tabs-overview' || `focus is on ${h.describe(p)}, not the Overview panel`
    },
  },
  {
    name: 'Down the side: Tab reaches the selected tab, ArrowDown selects the next',
    keys: ['Tab', 'ArrowDown'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-password')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.getAttribute('aria-selected') === 'true' || 'Password is not selected'
    },
  },
  {
    name: 'Down the side: ArrowRight does nothing',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const t = root.querySelector('#tabs-password')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.getAttribute('aria-selected') === 'true' || 'Password is not selected'
    },
  },
]

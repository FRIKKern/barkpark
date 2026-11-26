// Real-key steps for the segmented control. `setup` and each `expect` run in an isolated world of the page (its DOM,
// none of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the
// first Tab lands on the checked item of the Range control, Day.

export function setup() {}

export const steps = [
  {
    name: "Tab reaches the Range control at the checked Day, focus-visible, and every control's indicator, the pinned rows' too, sits on its checked item",
    keys: ['Tab'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-plant-missing-day')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `aria-checked is ${r.getAttribute('aria-checked')}`
      if (!r.matches(':focus-visible')) return 'not :focus-visible'
      const groups = [...root.querySelectorAll('[data-slot="segmented-control"]')]
      if (groups.length !== 6) return `${groups.length} segmented controls, not 6`
      for (const g of groups) {
        const on = g.querySelector('[data-slot="segmented-control-item"][data-checked]')
        const ind = g.querySelector(':scope > [data-slot="segmented-control-indicator"]')
        if (!ind) return `${h.describe(g)} has no indicator`
        const [a, b] = [ind.getBoundingClientRect(), on.getBoundingClientRect()]
        const off = Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(a[k] - b[k])))
        if (off > 1) return `the indicator of ${g.id} sits ${off.toFixed(1)}px off ${h.describe(on)}`
      }
      return true
    },
    ax: {
      '#segmented-control-plant-missing-day': { role: 'radio', name: 'Day', checked: 'true' },
      '#segmented-control-plant-missing-week': { role: 'radio', name: 'Week', checked: 'false' },
      '#segmented-control-plant-missing-month': { role: 'radio', name: 'Month', disabled: true },
    },
  },
  {
    name: 'ArrowRight moves the choice from Day to Week, and the indicator slides to Week',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-plant-missing-week')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `Week: aria-checked is ${r.getAttribute('aria-checked')}`
      const was = root.querySelector('#segmented-control-plant-missing-day').getAttribute('aria-checked')
      if (was !== 'false') return `Day: aria-checked is ${was}`
      const ind = root.querySelector('#segmented-control-plant-missing-range > [data-slot="segmented-control-indicator"]')
      if (!ind) return 'the Range control has no indicator'
      const [a, b] = [ind.getBoundingClientRect(), r.getBoundingClientRect()]
      const off = Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(a[k] - b[k])))
      return off <= 1 || `the indicator sits ${off.toFixed(1)}px off Week`
    },
    ax: { '#segmented-control-plant-missing-week': { role: 'radio', name: 'Week', checked: 'true' }, '#segmented-control-plant-missing-day': { role: 'radio', checked: 'false' } },
  },
  {
    name: 'ArrowRight passes the disabled Month and checks Year, and the indicator slides past Month to Year',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-plant-missing-year')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `Year: aria-checked is ${r.getAttribute('aria-checked')}`
      const checked = [...root.querySelectorAll('#segmented-control-plant-missing-range [data-slot="segmented-control-item"]')].filter((o) => o.getAttribute('aria-checked') === 'true')
      if (checked.length !== 1) return `${checked.length} items are checked`
      const ind = root.querySelector('#segmented-control-plant-missing-range > [data-slot="segmented-control-indicator"]')
      if (!ind) return 'the Range control has no indicator'
      const [a, b] = [ind.getBoundingClientRect(), r.getBoundingClientRect()]
      const off = Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(a[k] - b[k])))
      return off <= 1 || `the indicator sits ${off.toFixed(1)}px off Year`
    },
  },
  {
    name: 'ArrowLeft passes Month again, back to Week',
    keys: ['ArrowLeft'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-plant-missing-week')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      const checked = [...root.querySelectorAll('#segmented-control-plant-missing-range [data-slot="segmented-control-item"]')].filter((o) => o.getAttribute('aria-checked') === 'true')
      return (checked.length === 1 && checked[0] === r) || `checked: ${checked.map((o) => o.id).join(', ') || 'none'}`
    },
  },
  {
    name: 'Tab leaves the Range control after one stop, skips the disabled Theme, for the read-only plan at Pro',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#segmented-control-plant-missing-pro') || `focus is on ${h.describe(document.activeElement)}`,
    ax: { '#segmented-control-plant-missing-pro': { role: 'radio', name: 'Pro', checked: 'true' } },
  },
  {
    name: 'In the read-only plan, ArrowLeft moves focus to Free and Space checks nothing',
    keys: ['ArrowLeft', 'Space'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-plant-missing-free')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'false') return `Free: aria-checked is ${r.getAttribute('aria-checked')}`
      const pro = root.querySelector('#segmented-control-plant-missing-pro').getAttribute('aria-checked')
      return pro === 'true' || `Pro: aria-checked is ${pro}`
    },
  },
  {
    name: 'ArrowRight returns to Pro, still checked',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-plant-missing-pro')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      return r.getAttribute('aria-checked') === 'true' || `Pro: aria-checked is ${r.getAttribute('aria-checked')}`
    },
  },
]

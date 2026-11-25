// Real-key steps for the segmented control. `setup` and each `expect` run in an isolated world of the page (its DOM,
// none of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the
// first Tab lands on the checked item of the range, Day.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the range at the checked Day, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-day')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `aria-checked is ${r.getAttribute('aria-checked')}`
      return r.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: {
      '#segmented-control-day': { role: 'radio', name: 'Day', checked: 'true' },
      '#segmented-control-week': { role: 'radio', name: 'Week', checked: 'false' },
      '#segmented-control-month': { role: 'radio', name: 'Month', disabled: true },
    },
  },
  {
    name: 'ArrowRight moves the choice from Day to Week',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-week')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `Week: aria-checked is ${r.getAttribute('aria-checked')}`
      const was = root.querySelector('#segmented-control-day').getAttribute('aria-checked')
      return was === 'false' || `Day: aria-checked is ${was}`
    },
    ax: { '#segmented-control-week': { role: 'radio', name: 'Week', checked: 'true' }, '#segmented-control-day': { role: 'radio', checked: 'false' } },
  },
  {
    name: 'ArrowRight passes the disabled Month and checks Year',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-year')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `Year: aria-checked is ${r.getAttribute('aria-checked')}`
      const checked = [...root.querySelectorAll('#segmented-control-range [data-slot="segmented-control-item"]')].filter((o) => o.getAttribute('aria-checked') === 'true')
      return checked.length === 1 || `${checked.length} items are checked`
    },
  },
  {
    name: 'ArrowLeft passes Month again, back to Week',
    keys: ['ArrowLeft'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-week')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      const checked = [...root.querySelectorAll('#segmented-control-range [data-slot="segmented-control-item"]')].filter((o) => o.getAttribute('aria-checked') === 'true')
      return (checked.length === 1 && checked[0] === r) || `checked: ${checked.map((o) => o.id).join(', ') || 'none'}`
    },
  },
  {
    name: 'Tab leaves the range after one stop, skips the disabled Theme, for the read-only plan at Pro',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#segmented-control-pro') || `focus is on ${h.describe(document.activeElement)}`,
    ax: { '#segmented-control-pro': { role: 'radio', name: 'Pro', checked: 'true' } },
  },
  {
    name: 'In the read-only plan, ArrowLeft moves focus to Free and Space checks nothing',
    keys: ['ArrowLeft', 'Space'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-free')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'false') return `Free: aria-checked is ${r.getAttribute('aria-checked')}`
      const pro = root.querySelector('#segmented-control-pro').getAttribute('aria-checked')
      return pro === 'true' || `Pro: aria-checked is ${pro}`
    },
  },
  {
    name: 'ArrowRight returns to Pro, still checked',
    keys: ['ArrowRight'],
    expect: (root, h) => {
      const r = root.querySelector('#segmented-control-pro')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      return r.getAttribute('aria-checked') === 'true' || `Pro: aria-checked is ${r.getAttribute('aria-checked')}`
    },
  },
]

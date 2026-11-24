// Real-key steps for the radio group. `setup` and each `expect` run in an isolated world of the page (its DOM, none
// of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the checked option of the shipping speeds, Standard.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the shipping speeds at the checked Standard, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const r = root.querySelector('#radio-standard')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `aria-checked is ${r.getAttribute('aria-checked')}`
      return r.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: {
      '#radio-standard': { role: 'radio', name: 'Standard', checked: 'true' },
      '#radio-express': { role: 'radio', name: 'Express', checked: 'false' },
      '#radio-same-day': { role: 'radio', name: 'Same day', disabled: true },
    },
  },
  {
    name: 'ArrowDown moves the choice from Standard to Express',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      const r = root.querySelector('#radio-express')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `Express: aria-checked is ${r.getAttribute('aria-checked')}`
      const was = root.querySelector('#radio-standard').getAttribute('aria-checked')
      return was === 'false' || `Standard: aria-checked is ${was}`
    },
    ax: { '#radio-express': { role: 'radio', name: 'Express', checked: 'true' }, '#radio-standard': { role: 'radio', checked: 'false' } },
  },
  {
    name: 'ArrowDown passes the disabled Same day and checks Overnight',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      const r = root.querySelector('#radio-overnight')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `Overnight: aria-checked is ${r.getAttribute('aria-checked')}`
      const checked = [...root.querySelectorAll('#radio-speed [data-slot="radio"]')].filter((o) => o.getAttribute('aria-checked') === 'true')
      return checked.length === 1 || `${checked.length} options are checked`
    },
  },
  {
    name: 'ArrowUp passes Same day again, back to Express',
    keys: ['ArrowUp'],
    expect: (root, h) => {
      const r = root.querySelector('#radio-express')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      const checked = [...root.querySelectorAll('#radio-speed [data-slot="radio"]')].filter((o) => o.getAttribute('aria-checked') === 'true')
      return (checked.length === 1 && checked[0] === r) || `checked: ${checked.map((o) => o.id).join(', ') || 'none'}`
    },
  },
  {
    name: 'Tab leaves the group after one stop, for the read-only plan at Pro',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#radio-pro') || `focus is on ${h.describe(document.activeElement)}`,
  },
  {
    name: 'In the read-only plan, ArrowDown moves focus to Free and Space checks nothing',
    keys: ['ArrowDown', 'Space'],
    expect: (root, h) => {
      const r = root.querySelector('#radio-free')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'false') return `Free: aria-checked is ${r.getAttribute('aria-checked')}`
      const pro = root.querySelector('#radio-pro').getAttribute('aria-checked')
      return pro === 'true' || `Pro: aria-checked is ${pro}`
    },
  },
  {
    name: 'ArrowUp returns to Pro, and Tab skips the disabled Theme for the invalid Order updates at Email only',
    keys: ['ArrowUp', 'Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#radio-email') || `focus is on ${h.describe(document.activeElement)}`,
    ax: { '#radio-email': { role: 'radio', name: 'Email only', checked: 'false' } },
  },
  {
    name: 'ArrowDown checks SMS only, and the group stays invalid',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      const r = root.querySelector('#radio-sms')
      if (document.activeElement !== r) return `focus is on ${h.describe(document.activeElement)}`
      if (r.getAttribute('aria-checked') !== 'true') return `SMS only: aria-checked is ${r.getAttribute('aria-checked')}`
      const g = root.querySelector('#radio-updates')
      return (g.hasAttribute('data-invalid') && g.getAttribute('aria-invalid') === 'true') || 'the group is no longer marked invalid'
    },
  },
]

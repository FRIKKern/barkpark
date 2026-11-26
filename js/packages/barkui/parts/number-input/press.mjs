// Real-key steps for the number input. `setup` and each `expect` run in an isolated world of the page (its DOM, none
// of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent alone,
// so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the browser's
// own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the first Tab
// lands on the Guests input, at its lowest value, 1 (its step buttons stay out of the Tab order).

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Guests input at 1, focus-visible, past its step buttons',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#number-input-guests-control')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.value !== '1') return `value is ${JSON.stringify(t.value)}`
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#number-input-guests-control': { name: 'Guests' }, '#number-input-nights-control': { name: 'Nights', invalid: true } },
  },
  {
    name: 'ArrowUp steps Guests up to 2, and the decrement button comes on',
    keys: ['ArrowUp'],
    expect: (root, h) => {
      const t = root.querySelector('#number-input-guests-control')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.value !== '2') return `value is ${JSON.stringify(t.value)}`
      const less = root.querySelector('#number-input-guests-less')
      return !less.disabled || 'the decrement button is still disabled'
    },
  },
  {
    name: 'ArrowDown steps Guests back down to 1',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      const t = root.querySelector('#number-input-guests-control')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.value === '1' || `value is ${JSON.stringify(t.value)}`
    },
  },
  {
    name: 'ArrowDown at 1 stops there, its lowest, and the decrement button is disabled',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      const t = root.querySelector('#number-input-guests-control')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.value !== '1') return `value is ${JSON.stringify(t.value)}`
      const less = root.querySelector('#number-input-guests-less')
      return (less.disabled && less.hasAttribute('data-at-bound')) || 'the decrement button is not disabled at its bound'
    },
  },
  {
    name: 'ArrowUp six times from 1 reaches 6, its highest, and stops there, the increment button disabled',
    keys: ['ArrowUp', 'ArrowUp', 'ArrowUp', 'ArrowUp', 'ArrowUp', 'ArrowUp'],
    expect: (root, h) => {
      const t = root.querySelector('#number-input-guests-control')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.value !== '6') return `value is ${JSON.stringify(t.value)}`
      const more = root.querySelector('#number-input-guests-more')
      return (more.disabled && more.hasAttribute('data-at-bound')) || 'the increment button is not disabled at its bound'
    },
  },
]

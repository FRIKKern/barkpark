// Real-key steps for the password input. `setup` and each `expect` run in an isolated world of the page (its DOM,
// none of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the
// first Tab lands on the first field, Password, which is empty and hidden.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Password field, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#password-input-new')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#password-input-new': { name: 'Password' }, '#password-input-confirm': { name: 'Confirm password', invalid: true } },
  },
  {
    name: 'Typing into Password writes it, and it stays hidden',
    keys: ['f', 'a', 'k', 'e', '-', '1', '2', '3'],
    expect: (root, h) => {
      const t = root.querySelector('#password-input-new')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.value !== 'fake-123') return `value is ${JSON.stringify(t.value)}`
      return t.type === 'password' || `the field is type ${t.type}`
    },
  },
  {
    name: 'Tab moves on to its Show password button',
    keys: ['Tab'],
    expect: (root, h) => {
      const b = root.querySelector('#password-input-new-field [data-slot="password-input-toggle"]')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      return b.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#password-input-new-field [data-slot="password-input-toggle"]': { name: 'Show password' } },
  },
  {
    name: 'Space shows the typed text: the field turns to text, the button is pressed and keeps focus',
    keys: ['Space'],
    expect: (root, h) => {
      const t = root.querySelector('#password-input-new')
      const b = root.querySelector('#password-input-new-field [data-slot="password-input-toggle"]')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      if (t.type !== 'text') return `the field is type ${t.type}`
      if (t.value !== 'fake-123') return `value is ${JSON.stringify(t.value)}`
      return b.getAttribute('aria-pressed') === 'true' || `aria-pressed is ${b.getAttribute('aria-pressed')}`
    },
  },
  {
    name: 'Space again hides it: the field is a password field again, the button not pressed',
    keys: ['Space'],
    expect: (root, h) => {
      const t = root.querySelector('#password-input-new')
      const b = root.querySelector('#password-input-new-field [data-slot="password-input-toggle"]')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      if (t.type !== 'password') return `the field is type ${t.type}`
      if (t.value !== 'fake-123') return `value is ${JSON.stringify(t.value)}`
      return b.getAttribute('aria-pressed') === 'false' || `aria-pressed is ${b.getAttribute('aria-pressed')}`
    },
  },
]

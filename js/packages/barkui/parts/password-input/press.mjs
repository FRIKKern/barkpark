// Real-key steps for the password input. `setup` and each `expect` run in an isolated world of the page (its DOM,
// none of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the
// first Tab lands on the first field, Password, which is empty and hidden.
//
// The eye: setup notes how the Password field's show button draws its eye while the password is hidden, as the
// check draws a ::before alone (check/drawn.mjs, BOX): its size, edges, corners and background images, each colour
// read as ink or clear. Showing the password must change that picture, and hiding it again must bring the same one
// back, so a shown eye drawn like the hidden one is red by name.

export function setup(root, h) {
  const b = root.querySelector('#password-input-new-field [data-slot="password-input-toggle"]')
  const s = getComputedStyle(b, '::before')
  const look = ['width', 'height', 'border-width', 'border-style', 'border-radius', 'background-image', 'background-size', 'background-position', 'background-repeat']
  h.state.hiddenEye = look.map((p) => `${p}: ${s.getPropertyValue(p).replace(/rgba?\([^)]*\)/g, (c) => (/,\s*0\)$/.test(c) ? 'clear' : 'ink'))}`).join('; ')
}

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
    name: 'Space shows the typed text: the field turns to text, the button is pressed and keeps focus, and its eye is drawn unlike the hidden eye',
    keys: ['Space'],
    expect: (root, h) => {
      const t = root.querySelector('#password-input-new')
      const b = root.querySelector('#password-input-new-field [data-slot="password-input-toggle"]')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      if (t.type !== 'text') return `the field is type ${t.type}`
      if (t.value !== 'fake-123') return `value is ${JSON.stringify(t.value)}`
      if (b.getAttribute('aria-pressed') !== 'true') return `aria-pressed is ${b.getAttribute('aria-pressed')}`
      const s = getComputedStyle(b, '::before')
      const look = ['width', 'height', 'border-width', 'border-style', 'border-radius', 'background-image', 'background-size', 'background-position', 'background-repeat']
      const eye = look.map((p) => `${p}: ${s.getPropertyValue(p).replace(/rgba?\([^)]*\)/g, (c) => (/,\s*0\)$/.test(c) ? 'clear' : 'ink'))}`).join('; ')
      if (!h.state.hiddenEye) return 'setup noted no hidden eye'
      return eye !== h.state.hiddenEye || `the shown eye is drawn like the hidden eye: ${eye}`
    },
  },
  {
    name: 'Space again hides it: the field is a password field again, the button not pressed, and its eye is the hidden eye again',
    keys: ['Space'],
    expect: (root, h) => {
      const t = root.querySelector('#password-input-new')
      const b = root.querySelector('#password-input-new-field [data-slot="password-input-toggle"]')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      if (t.type !== 'password') return `the field is type ${t.type}`
      if (t.value !== 'fake-123') return `value is ${JSON.stringify(t.value)}`
      if (b.getAttribute('aria-pressed') !== 'false') return `aria-pressed is ${b.getAttribute('aria-pressed')}`
      const s = getComputedStyle(b, '::before')
      const look = ['width', 'height', 'border-width', 'border-style', 'border-radius', 'background-image', 'background-size', 'background-position', 'background-repeat']
      const eye = look.map((p) => `${p}: ${s.getPropertyValue(p).replace(/rgba?\([^)]*\)/g, (c) => (/,\s*0\)$/.test(c) ? 'clear' : 'ink'))}`).join('; ')
      return eye === h.state.hiddenEye || `the eye is not the hidden eye again: ${eye}`
    },
  },
]

// Real-key steps for the checkbox. `setup` and each `expect` run in an isolated world of the page (its DOM, none
// of its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the first checkbox.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the first checkbox, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const c = root.querySelector('#checkbox-updates')
      if (document.activeElement !== c) return `focus is on ${h.describe(document.activeElement)}`
      return c.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: {
      '#checkbox-updates': { role: 'checkbox', name: 'Product updates', checked: 'false' },
      '#checkbox-topics': { role: 'checkbox', name: 'All topics', checked: 'mixed' },
      '#checkbox-beta': { role: 'checkbox', name: 'Beta features', disabled: true },
      '#checkbox-consent': { role: 'checkbox', name: 'Share my reading list', invalid: 'true' },
    },
  },
  {
    name: 'Space checks it, and its tick shows',
    keys: ['Space'],
    expect: (root, h) => {
      const c = root.querySelector('#checkbox-updates')
      if (document.activeElement !== c) return `focus is on ${h.describe(document.activeElement)}`
      if (c.getAttribute('aria-checked') !== 'true') return `aria-checked is ${c.getAttribute('aria-checked')}`
      return (c.hasAttribute('data-checked') && getComputedStyle(c, '::after').rotate === '45deg') || 'the tick does not show'
    },
    ax: { '#checkbox-updates': { role: 'checkbox', checked: 'true' } },
  },
  {
    name: 'Space again unchecks it, and its tick goes',
    keys: ['Space'],
    expect: (root, h) => {
      const c = root.querySelector('#checkbox-updates')
      if (document.activeElement !== c) return `focus is on ${h.describe(document.activeElement)}`
      if (c.getAttribute('aria-checked') !== 'false') return `aria-checked is ${c.getAttribute('aria-checked')}`
      return getComputedStyle(c, '::after').content === 'none' || 'the mark still shows'
    },
    ax: { '#checkbox-updates': { role: 'checkbox', checked: 'false' } },
  },
  {
    name: 'Tab past the checked terms reaches the mixed box, and Space checks it',
    keys: ['Tab', 'Tab', 'Space'],
    expect: (root, h) => {
      const c = root.querySelector('#checkbox-topics')
      if (document.activeElement !== c) return `focus is on ${h.describe(document.activeElement)}`
      if (c.getAttribute('aria-checked') !== 'true') return `aria-checked is ${c.getAttribute('aria-checked')}`
      return (c.hasAttribute('data-checked') && getComputedStyle(c, '::after').rotate === '45deg') || 'the tick does not show in place of the dash'
    },
  },
  {
    name: 'Tab reaches the read-only box, and Space leaves it checked',
    keys: ['Tab', 'Space'],
    expect: (root, h) => {
      const c = root.querySelector('#checkbox-twofactor')
      if (document.activeElement !== c) return `focus is on ${h.describe(document.activeElement)}`
      return c.getAttribute('aria-checked') === 'true' || `aria-checked is ${c.getAttribute('aria-checked')}`
    },
  },
  {
    name: 'Tab skips the disabled boxes and reaches the invalid one in its field',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#checkbox-consent') || `focus is on ${h.describe(document.activeElement)}`,
  },
]

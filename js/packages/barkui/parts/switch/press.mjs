// Real-key steps for the switch. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the first switch, Product updates, which is off.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Product updates switch, off, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const s = root.querySelector('#switch-updates')
      if (document.activeElement !== s) return `focus is on ${h.describe(document.activeElement)}`
      if (s.getAttribute('aria-checked') !== 'false') return `aria-checked is ${s.getAttribute('aria-checked')}`
      return s.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#switch-updates': { role: 'switch', name: 'Product updates' }, '#switch-alerts': { role: 'switch', name: 'Security alerts', checked: true } },
  },
  {
    name: 'Space turns Product updates on',
    keys: ['Space'],
    expect: (root, h) => {
      const s = root.querySelector('#switch-updates')
      if (document.activeElement !== s) return `focus is on ${h.describe(document.activeElement)}`
      if (s.getAttribute('aria-checked') !== 'true') return `aria-checked is ${s.getAttribute('aria-checked')}`
      return (s.hasAttribute('data-checked') && s.querySelector('[data-slot="switch-thumb"]').hasAttribute('data-checked')) || 'the switch or its thumb is not drawn on'
    },
    ax: { '#switch-updates': { role: 'switch', name: 'Product updates', checked: true } },
  },
  {
    name: 'Space turns Product updates off again',
    keys: ['Space'],
    expect: (root, h) => {
      const s = root.querySelector('#switch-updates')
      if (document.activeElement !== s) return `focus is on ${h.describe(document.activeElement)}`
      if (s.getAttribute('aria-checked') !== 'false') return `aria-checked is ${s.getAttribute('aria-checked')}`
      return (s.hasAttribute('data-unchecked') && s.querySelector('[data-slot="switch-thumb"]').hasAttribute('data-unchecked')) || 'the switch or its thumb is not drawn off'
    },
  },
  {
    name: 'Tab walks to the read-only Encrypt backups, and Space leaves it on',
    keys: ['Tab', 'Tab', 'Space'],
    expect: (root, h) => {
      const s = root.querySelector('#switch-backups')
      if (document.activeElement !== s) return `focus is on ${h.describe(document.activeElement)}`
      return s.getAttribute('aria-checked') === 'true' || `aria-checked is ${s.getAttribute('aria-checked')}`
    },
    ax: { '#switch-backups': { role: 'switch', name: 'Encrypt backups', checked: true, readonly: true } },
  },
  {
    name: 'Tab skips the two disabled switches and reaches the invalid Two-factor sign-in',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#switch-two-factor') || `focus is on ${h.describe(document.activeElement)}`,
    ax: { '#switch-two-factor': { role: 'switch', name: 'Two-factor sign-in', invalid: true } },
  },
]

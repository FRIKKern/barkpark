// Real-key steps for the button. `setup` and each `expect` run inside the page
// with the part's example element and the check's helpers (`h`), so they may
// not reach anything else in this file. An expect returns true or a reason.
// Keys go through the browser's own input pipeline, so focus-visible, Space and
// Enter behave as they do for a person. The check focuses the part's heading
// first; the first Tab lands on the first control of the example.

/** Log every action by its button id. UI SDK's action event does not bubble. */
export function setup(root, h) {
  h.state.actions = []
  for (const el of root.querySelectorAll('ui-button')) el.addEventListener('action', () => h.state.actions.push(el.querySelector('button')?.id ?? '?'))
}

export const steps = [
  {
    name: 'Tab reaches the primary button and draws one visible ring',
    keys: ['Tab'],
    expect: (root, h) => {
      const b = root.querySelector('#button-primary')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      if (!b.matches(':focus-visible')) return 'not :focus-visible'
      const s = getComputedStyle(b)
      if (s.outlineStyle !== 'solid' || parseFloat(s.outlineWidth) < 3) return `outline is ${s.outlineStyle} ${s.outlineWidth}`
      if (s.outlineColor !== h.resolve('--ui-ring')) return `outline ${s.outlineColor}, want --ui-ring ${h.resolve('--ui-ring')}`
      if (s.borderTopColor !== h.resolve('--ui-ring-border')) return `edge ${s.borderTopColor}, want --ui-ring-border`
      if (s.boxShadow !== 'none') return `a second ring is drawn as box-shadow: ${s.boxShadow}`
      return true
    },
  },
  { name: 'Space activates it', keys: ['Space'], expect: (root, h) => h.state.actions.join() === 'button-primary' || `actions: ${h.state.actions}` },
  { name: 'Enter activates it', keys: ['Enter'], expect: (root, h) => h.state.actions.join() === 'button-primary,button-primary' || `actions: ${h.state.actions}` },
  {
    name: 'Tab walks secondary, quiet, destructive',
    keys: ['Tab', 'Tab', 'Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#button-destructive') || `focus is on ${h.describe(document.activeElement)}`,
  },
  {
    name: 'Tab skips the disabled button',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#button-after') || `focus is on ${h.describe(document.activeElement)}`,
  },
  {
    name: 'Tab, Enter: the save button goes pending',
    keys: ['Tab', 'Enter'],
    wait: 100,
    expect: (root, h) => {
      const b = root.querySelector('#button-save')
      if (document.activeElement !== b) return 'focus left the save button'
      if (!b.hasAttribute('data-pending') || b.getAttribute('aria-busy') !== 'true') return 'not pending'
      const spin = b.querySelector('[data-slot="spinner"]')
      if (getComputedStyle(spin).display === 'none') return 'spinner hidden while pending'
      return h.state.actions.at(-1) === 'button-save' || `actions: ${h.state.actions}`
    },
  },
  {
    name: 'Enter while pending is refused',
    keys: ['Enter', 'Space'],
    expect: (root, h) => h.state.actions.filter((a) => a === 'button-save').length === 1 || `actions: ${h.state.actions}`,
  },
  {
    name: 'Pending ends and the spinner hides',
    wait: 1700,
    expect: (root) => {
      const b = root.querySelector('#button-save')
      if (b.hasAttribute('data-pending')) return 'still pending'
      return getComputedStyle(b.querySelector('[data-slot="spinner"]')).display === 'none' || 'spinner still shown'
    },
  },
  {
    name: 'A real click on the disabled button fires nothing',
    click: '#button-disabled',
    expect: (root, h) => !h.state.actions.includes('button-disabled') || `actions: ${h.state.actions}`,
  },
]

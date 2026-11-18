// Real-key steps for the button. Each `expect` runs in the page with the part's
// example element and the check's helpers (`h`); it returns true or a reason.
// Keys go through the browser's own input pipeline, so focus-visible, Space and
// Enter behave as they do for a person.

/** Runs once in the page before the steps: log every action by its button id. */
export function setup(root) {
  window.__buttonActions = []
  root.addEventListener('action', (e) => window.__buttonActions.push(e.target.querySelector('button')?.id ?? '?'))
}

const actions = () => window.__buttonActions.join(',')

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
  { name: 'Space activates it', keys: ['Space'], expect: () => actions() === 'button-primary' || `actions: ${actions()}` },
  { name: 'Enter activates it', keys: ['Enter'], expect: () => actions() === 'button-primary,button-primary' || `actions: ${actions()}` },
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
    expect: (root) => {
      const b = root.querySelector('#button-save')
      if (document.activeElement !== b) return 'focus left the save button'
      if (!b.hasAttribute('data-pending') || b.getAttribute('aria-busy') !== 'true') return 'not pending'
      const spin = b.querySelector('[data-slot="spinner"]')
      if (getComputedStyle(spin).display === 'none') return 'spinner hidden while pending'
      return actions().endsWith('button-save') || `actions: ${actions()}`
    },
  },
  {
    name: 'Enter while pending is refused',
    keys: ['Enter', 'Space'],
    expect: () => actions().split(',').filter((a) => a === 'button-save').length === 1 || `actions: ${actions()}`,
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
    expect: () => !actions().includes('button-disabled') || `actions: ${actions()}`,
  },
]

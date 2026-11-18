// Real-key steps for the button. `setup` and each `expect` run inside the page
// with the part's example element and the check's helpers (`h`), so they may
// not reach anything else in this file. An expect returns true or a reason.
// `ax` names what the browser hands a screen reader for an element (role,
// name, states), read after the expect passes. Keys go through the browser's
// own input pipeline. The check focuses the part's heading first; the first
// Tab lands on the first control. The focus ring itself is measured for every
// part by the check, on every Tab stop, skin and scheme.

/** Log every action by its button id (UI SDK's action event does not bubble) and every live announcement. */
export function setup(root, h) {
  h.state.actions = []
  h.state.announced = []
  for (const el of root.querySelectorAll('ui-button')) el.addEventListener('action', () => h.state.actions.push(el.querySelector('button')?.id ?? '?'))
  new MutationObserver(() => {
    for (const region of document.querySelectorAll('[aria-live]')) {
      const text = region.textContent.trim()
      if (text && h.state.announced.at(-1) !== text) h.state.announced.push(text)
    }
  }).observe(document.body, { childList: true, subtree: true, characterData: true })
}

export const steps = [
  {
    name: 'Tab reaches the primary button, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const b = root.querySelector('#button-primary')
      if (document.activeElement !== b) return `focus is on ${h.describe(document.activeElement)}`
      return b.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#button-primary': { role: 'button', name: 'Publish' }, '#button-more': { role: 'button', name: 'More actions' } },
  },
  { name: 'Space activates it', keys: ['Space'], expect: (root, h) => h.state.actions.join() === 'button-primary' || `actions: ${h.state.actions}` },
  { name: 'Enter activates it', keys: ['Enter'], expect: (root, h) => h.state.actions.join() === 'button-primary,button-primary' || `actions: ${h.state.actions}` },
  {
    name: 'Tab walks secondary, quiet, destructive',
    keys: ['Tab', 'Tab', 'Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#button-destructive') || `focus is on ${h.describe(document.activeElement)}`,
  },
  {
    name: 'Tab skips the disabled button, which says it is disabled',
    keys: ['Tab'],
    expect: (root, h) => {
      if (document.activeElement !== root.querySelector('#button-after')) return `focus is on ${h.describe(document.activeElement)}`
      const d = root.querySelector('#button-disabled')
      return d.disabled || d.getAttribute('aria-disabled') === 'true' || 'the disabled button is neither disabled nor aria-disabled'
    },
    ax: { '#button-disabled': { role: 'button', name: 'Unavailable', disabled: true } },
  },
  {
    name: 'Tab, Enter: the save button goes pending and busy',
    keys: ['Tab', 'Enter'],
    wait: 100,
    expect: (root, h) => {
      const b = root.querySelector('#button-save')
      if (document.activeElement !== b) return 'focus left the save button'
      if (!b.hasAttribute('data-pending')) return 'not pending'
      if (b.getAttribute('aria-busy') !== 'true' || b.getAttribute('aria-disabled') !== 'true') return `aria-busy=${b.getAttribute('aria-busy')} aria-disabled=${b.getAttribute('aria-disabled')}`
      if (getComputedStyle(b.querySelector('[data-slot="spinner"]')).display === 'none') return 'spinner hidden while pending'
      return h.state.actions.at(-1) === 'button-save' || `actions: ${h.state.actions}`
    },
    ax: { '#button-save': { role: 'button', name: 'Save changes', busy: true, disabled: true } },
  },
  {
    name: 'Enter while pending is refused',
    keys: ['Enter', 'Space'],
    expect: (root, h) => h.state.actions.filter((a) => a === 'button-save').length === 1 || `actions: ${h.state.actions}`,
  },
  {
    name: 'A slow save is announced as "Saving"',
    wait: 1100,
    expect: (root, h) => h.state.announced.includes('Saving') || `announced: ${JSON.stringify(h.state.announced)}`,
  },
  {
    name: 'Pending ends and the spinner hides',
    wait: 1500,
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

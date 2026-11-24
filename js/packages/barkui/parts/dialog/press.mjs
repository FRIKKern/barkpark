// Real-key steps for the dialog. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the Rename page trigger. Inside the open dialog the Tab order is Cancel, Rename, Close.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Rename page trigger, focus-visible, the dialog closed',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#dialog-rename-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (root.querySelector('#dialog-rename-content').matches(':popover-open')) return 'the dialog is open'
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#dialog-rename-trigger': { role: 'button', name: 'Rename page' } },
  },
  {
    name: 'Enter opens the dialog over the page, focus on its first button',
    keys: ['Enter'],
    wait: 300,
    expect: (root, h) => {
      const box = root.querySelector('#dialog-rename-content')
      if (!box.matches(':popover-open')) return 'the dialog is not open'
      if (box.getAttribute('aria-modal') !== 'true') return 'the dialog does not say it is modal'
      const first = root.querySelector('#dialog-rename-cancel')
      return document.activeElement === first || `focus is on ${h.describe(document.activeElement)}`
    },
    ax: { '#dialog-rename-content': { role: 'dialog', name: 'Rename page' } },
  },
  {
    name: 'Tab moves through the open dialog and from its last button back to its first, never leaving it',
    keys: ['Tab', 'Tab', 'Tab'],
    expect: (root, h) => {
      if (!root.querySelector('#dialog-rename-content').matches(':popover-open')) return 'the dialog is not open'
      const first = root.querySelector('#dialog-rename-cancel')
      return document.activeElement === first || `focus is on ${h.describe(document.activeElement)}`
    },
  },
  {
    name: 'Escape closes it, focus back on the trigger',
    keys: ['Escape'],
    wait: 300,
    expect: (root, h) => {
      if (root.querySelector('#dialog-rename-content').matches(':popover-open')) return 'the dialog is still open'
      const t = root.querySelector('#dialog-rename-trigger')
      return document.activeElement === t || `focus is on ${h.describe(document.activeElement)}`
    },
  },
  {
    name: 'Space opens it again, focus on its first button',
    keys: ['Space'],
    wait: 300,
    expect: (root, h) => {
      if (!root.querySelector('#dialog-rename-content').matches(':popover-open')) return 'the dialog is not open'
      const first = root.querySelector('#dialog-rename-cancel')
      return document.activeElement === first || `focus is on ${h.describe(document.activeElement)}`
    },
  },
  {
    name: 'Shift+Tab from its first button goes round to the close button, never leaving the dialog',
    keys: ['Shift+Tab'],
    expect: (root, h) => {
      if (!root.querySelector('#dialog-rename-content').matches(':popover-open')) return 'the dialog is not open'
      const close = root.querySelector('#dialog-rename-close')
      return document.activeElement === close || `focus is on ${h.describe(document.activeElement)}`
    },
    ax: { '#dialog-rename-close': { role: 'button', name: 'Close' } },
  },
  {
    name: 'Enter on the close button closes it, focus back on the trigger',
    keys: ['Enter'],
    wait: 300,
    expect: (root, h) => {
      if (root.querySelector('#dialog-rename-content').matches(':popover-open')) return 'the dialog is still open'
      const t = root.querySelector('#dialog-rename-trigger')
      return document.activeElement === t || `focus is on ${h.describe(document.activeElement)}`
    },
  },
]

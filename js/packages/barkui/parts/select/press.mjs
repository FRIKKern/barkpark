// Real-key steps for the select. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the Status trigger. Only the Role list is opened: it is the one layer in part.json.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Status trigger, which shows its placeholder; the disabled Team trigger is passed over',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#select-status-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const v = root.querySelector('#select-status-value')
      if (!v.hasAttribute('data-placeholder')) return 'the Status value is not marked as a placeholder'
      return v.textContent.trim() === 'Pick a status' || `the Status trigger shows "${v.textContent.trim()}"`
    },
    ax: { '#select-status-trigger': { role: 'combobox', name: 'Status' }, '#select-team-trigger': { role: 'combobox', name: 'Team', disabled: true } },
  },
  {
    name: 'Tab moves on to the Role trigger, focus-visible, closed',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#select-role-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-expanded') !== 'false') return 'the trigger says it is open'
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#select-role-trigger': { role: 'combobox', name: 'Role' } },
  },
  {
    name: 'Enter opens the list over the page, the chosen option highlighted',
    keys: ['Enter'],
    expect: (root, h) => {
      const list = root.querySelector('#select-role-content')
      if (!list.matches(':popover-open')) return 'the list is not open'
      if (root.querySelector('#select-role-trigger').getAttribute('aria-expanded') !== 'true') return 'the trigger does not say it is open'
      const lit = root.querySelectorAll('#select-role-content [data-highlighted]')
      if (lit.length !== 1 || lit[0].id !== 'select-role-editor') return `highlighted: ${[...lit].map((e) => h.describe(e)).join(', ') || 'nothing'}`
      return true
    },
  },
  {
    name: 'ArrowDown passes over the disabled option to the next',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      const lit = root.querySelectorAll('#select-role-content [data-highlighted]')
      return (lit.length === 1 && lit[0].id === 'select-role-admin') || `highlighted: ${[...lit].map((e) => h.describe(e)).join(', ') || 'nothing'}`
    },
  },
  {
    name: 'Enter chooses it: the list closes, the trigger shows it and has focus',
    keys: ['Enter'],
    wait: 500,
    expect: (root, h) => {
      if (root.querySelector('#select-role-content').matches(':popover-open')) return 'the list is still open'
      const t = root.querySelector('#select-role-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (root.querySelector('#select-role-owner').getAttribute('aria-selected') === 'true') return 'the disabled Owner is selected'
      if (root.querySelector('#select-role-admin').getAttribute('aria-selected') !== 'true') return 'Admin is not selected'
      const shown = root.querySelector('#select-role-value').textContent.trim()
      return shown === 'Admin' || `the trigger shows "${shown}"`
    },
  },
  {
    name: 'ArrowDown on the trigger opens the list',
    keys: ['ArrowDown'],
    wait: 300,
    expect: (root) => root.querySelector('#select-role-content').matches(':popover-open') || 'the list is not open',
  },
  {
    name: 'Escape closes it, the choice kept',
    keys: ['Escape'],
    wait: 300,
    expect: (root, h) => {
      if (root.querySelector('#select-role-content').matches(':popover-open')) return 'the list is still open'
      const t = root.querySelector('#select-role-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const shown = root.querySelector('#select-role-value').textContent.trim()
      return shown === 'Admin' || `the trigger shows "${shown}"`
    },
  },
]

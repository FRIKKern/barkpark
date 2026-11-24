// Real-key steps for the menu. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent
// alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the
// browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first;
// the first Tab lands on the Page actions trigger (the pinned rows are inert). The items, in order: Rename,
// Duplicate, Move (disabled), Archive. UI SDK's arrows stop on a disabled item, as the menu pattern asks, and
// Enter there chooses nothing.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Page actions trigger, focus-visible, the menu closed',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#menu-page-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is open'
      if (t.getAttribute('aria-expanded') !== 'false') return 'the trigger says it is open'
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#menu-page-trigger': { role: 'button', name: 'Page actions' } },
  },
  {
    name: 'Enter opens the menu over the page, focus on its first item',
    keys: ['Enter'],
    wait: 300,
    expect: (root, h) => {
      if (!root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is not open'
      if (root.querySelector('#menu-page-trigger').getAttribute('aria-expanded') !== 'true') return 'the trigger does not say it is open'
      const first = root.querySelector('#menu-page-rename')
      if (document.activeElement !== first) return `focus is on ${h.describe(document.activeElement)}`
      const lit = root.querySelectorAll('#menu-page-content [data-highlighted]')
      return (lit.length === 1 && lit[0] === first) || `highlighted: ${[...lit].map((e) => h.describe(e)).join(', ') || 'nothing'}`
    },
    ax: { '#menu-page-content': { role: 'menu', name: 'Page actions' }, '#menu-page-rename': { role: 'menuitem', name: 'Rename' } },
  },
  {
    name: 'ArrowDown moves through the items onto the disabled Move',
    keys: ['ArrowDown', 'ArrowDown'],
    expect: (root, h) => {
      if (!root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is not open'
      const move = root.querySelector('#menu-page-move')
      if (document.activeElement !== move) return `focus is on ${h.describe(document.activeElement)}`
      const lit = root.querySelectorAll('#menu-page-content [data-highlighted]')
      return (lit.length === 1 && lit[0] === move) || `highlighted: ${[...lit].map((e) => h.describe(e)).join(', ') || 'nothing'}`
    },
    ax: { '#menu-page-move': { role: 'menuitem', name: 'Move', disabled: true } },
  },
  {
    name: 'Enter on the disabled Move chooses nothing, the menu stays open',
    keys: ['Enter'],
    wait: 300,
    expect: (root, h) => {
      if (!root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu closed'
      const shown = root.querySelector('#menu-page-chosen').textContent.trim()
      if (shown !== 'Nothing chosen yet') return `the page shows "${shown}"`
      const move = root.querySelector('#menu-page-move')
      return document.activeElement === move || `focus is on ${h.describe(document.activeElement)}`
    },
  },
  {
    name: 'ArrowDown moves on past the disabled Move to Archive',
    keys: ['ArrowDown'],
    expect: (root, h) => {
      if (!root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is not open'
      const archive = root.querySelector('#menu-page-archive')
      if (document.activeElement !== archive) return `focus is on ${h.describe(document.activeElement)}`
      const lit = root.querySelectorAll('#menu-page-content [data-highlighted]')
      return (lit.length === 1 && lit[0] === archive) || `highlighted: ${[...lit].map((e) => h.describe(e)).join(', ') || 'nothing'}`
    },
  },
  {
    name: 'Enter chooses Archive: the menu closes, focus back on the trigger, the choice shown',
    keys: ['Enter'],
    wait: 500,
    expect: (root, h) => {
      if (root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is still open'
      const t = root.querySelector('#menu-page-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      if (t.getAttribute('aria-expanded') !== 'false') return 'the trigger says it is open'
      const shown = root.querySelector('#menu-page-chosen').textContent.trim()
      return shown === 'Chose archive' || `the page shows "${shown}"`
    },
  },
  {
    name: 'Space opens it again, focus on its first item',
    keys: ['Space'],
    wait: 300,
    expect: (root, h) => {
      if (!root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is not open'
      const first = root.querySelector('#menu-page-rename')
      return document.activeElement === first || `focus is on ${h.describe(document.activeElement)}`
    },
  },
  {
    name: 'Escape closes it, focus back on the trigger, nothing more chosen',
    keys: ['Escape'],
    wait: 300,
    expect: (root, h) => {
      if (root.querySelector('#menu-page-content').matches(':popover-open')) return 'the menu is still open'
      const t = root.querySelector('#menu-page-trigger')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      const shown = root.querySelector('#menu-page-chosen').textContent.trim()
      return shown === 'Chose archive' || `the page shows "${shown}"`
    },
  },
]

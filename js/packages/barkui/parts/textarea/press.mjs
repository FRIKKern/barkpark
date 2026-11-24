// Real-key steps for the textarea. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent alone,
// so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the browser's
// own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the first Tab
// lands on the first textarea, Notes, which is empty.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Notes textarea, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#textarea-notes')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#textarea-notes': { role: 'textbox', name: 'Notes' }, '#textarea-review': { role: 'textbox', name: 'Review', invalid: true } },
  },
  {
    name: 'Typing two lines into Notes, Enter between them, writes both',
    keys: ['L', 'e', 'f', 't', 'Enter', 'g', 'a', 't', 'e'],
    expect: (root, h) => {
      const t = root.querySelector('#textarea-notes')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.value === 'Left\ngate' || `value is ${JSON.stringify(t.value)}`
    },
  },
  {
    name: 'Tab leaves Notes for Message, and Notes keeps both lines',
    keys: ['Tab'],
    expect: (root, h) => {
      if (document.activeElement !== root.querySelector('#textarea-message')) return `focus is on ${h.describe(document.activeElement)}`
      const v = root.querySelector('#textarea-notes').value
      return v === 'Left\ngate' || `Notes holds ${JSON.stringify(v)}`
    },
  },
  {
    name: 'Tab reaches the read-only Terms, which takes no typing',
    keys: ['Tab', 'x', 'Enter'],
    expect: (root, h) => {
      const t = root.querySelector('#textarea-terms')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.value === 'Paid within 30 days.\nNo refunds after delivery.' || `value is ${JSON.stringify(t.value)}`
    },
  },
  {
    name: 'Tab skips the disabled Reply and reaches the invalid Review',
    keys: ['Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#textarea-review') || `focus is on ${h.describe(document.activeElement)}`,
  },
]

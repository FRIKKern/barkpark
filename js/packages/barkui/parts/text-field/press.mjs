// Real-key steps for the text field. `setup` and each `expect` run in an isolated world of the page (its DOM,
// none of its script) with the part's example element and a copy of the check's helpers (`h`). Each function
// is sent alone, so it may not reach anything else in this file. An expect returns true or a reason. Keys go
// through the browser's own input pipeline, one key per entry, on a US layout. The check focuses the part's
// heading first; the first Tab lands on the first field.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the title field, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const t = root.querySelector('#text-field-title')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#text-field-title': { role: 'textbox', name: 'Title' }, '#text-field-email': { role: 'textbox', name: 'Email', invalid: true } },
  },
  {
    name: 'Typing writes the value',
    keys: ['S', 'p', 'r', 'i', 'n', 'g'],
    expect: (root) => {
      const v = root.querySelector('#text-field-title').value
      return v === 'Spring' || `value is ${JSON.stringify(v)}`
    },
  },
  {
    name: 'Backspace clears it, and the placeholder shows again',
    keys: ['Backspace', 'Backspace', 'Backspace', 'Backspace', 'Backspace', 'Backspace'],
    expect: (root) => {
      const t = root.querySelector('#text-field-title')
      if (t.value !== '') return `value is ${JSON.stringify(t.value)}`
      return t.matches(':placeholder-shown') || 'the placeholder is not shown'
    },
  },
  {
    name: 'Tab walks slug, summary and the read-only id, and skips the disabled owner',
    keys: ['Tab', 'Tab', 'Tab', 'Tab'],
    expect: (root, h) => document.activeElement === root.querySelector('#text-field-email') || `focus is on ${h.describe(document.activeElement)}`,
  },
  {
    name: 'The read-only id takes focus but no typing',
    keys: ['Shift+Tab', 'x'],
    expect: (root, h) => {
      const t = root.querySelector('#text-field-id')
      if (document.activeElement !== t) return `focus is on ${h.describe(document.activeElement)}`
      return t.value === 'post-1042' || `value is ${JSON.stringify(t.value)}`
    },
  },
]

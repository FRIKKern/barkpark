// Real-key steps for the text field. `setup` and each `expect` run in an isolated world of the page (its DOM,
// none of its script) with the part's example element and a copy of the check's helpers (`h`). An expect
// returns true or a reason. Keys go through the browser's own input pipeline, one key per entry, on a US
// layout. The check focuses the part's heading first; the first Tab lands on the first field.

const at = (root, id) => root.querySelector(`#text-field-${id}`)
const focusOn = (root, h, id) => document.activeElement === at(root, id) || `focus is on ${h.describe(document.activeElement)}`

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the title field, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const f = focusOn(root, h, 'title')
      if (f !== true) return f
      return at(root, 'title').matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#text-field-title': { role: 'textbox', name: 'Title' }, '#text-field-email': { role: 'textbox', name: 'Email', invalid: true } },
  },
  {
    name: 'Typing writes the value',
    keys: ['S', 'p', 'r', 'i', 'n', 'g'],
    expect: (root) => at(root, 'title').value === 'Spring' || `value is ${JSON.stringify(at(root, 'title').value)}`,
  },
  {
    name: 'Backspace clears it, and the placeholder shows again',
    keys: ['Backspace', 'Backspace', 'Backspace', 'Backspace', 'Backspace', 'Backspace'],
    expect: (root) => {
      const t = at(root, 'title')
      if (t.value !== '') return `value is ${JSON.stringify(t.value)}`
      return t.matches(':placeholder-shown') || 'the placeholder is not shown'
    },
  },
  {
    name: 'Tab walks slug, summary and the read-only id, and skips the disabled owner',
    keys: ['Tab', 'Tab', 'Tab', 'Tab'],
    expect: (root, h) => focusOn(root, h, 'email'),
  },
  {
    name: 'The read-only id takes focus but no typing',
    keys: ['Shift+Tab', 'x'],
    expect: (root, h) => {
      const f = focusOn(root, h, 'id')
      if (f !== true) return f
      return at(root, 'id').value === 'post-1042' || `value is ${JSON.stringify(at(root, 'id').value)}`
    },
  },
]

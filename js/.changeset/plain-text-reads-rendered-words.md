---
"@barkpark/react": patch
---

`toPlainText` now reads each inline leaf the way the renderers and the Go and Elixir readers do: the first non-empty of its `value`, its legacy `text`, then its `children`, in that order; a number in `value` or `text` reads as its digits, a string `children` as its text, and a nested array as its items; and inline nesting of any depth reads to the end instead of throwing.

Examples:

- `{ type: 'text', value: 'a', children: [{ type: 'text', value: 'b' }] }` gave `ab`, now `a`.
- `{ type: 'text', value: 42, text: 'forty-two' }` gave `forty-two`, now `42`.
- A bare array `[[{ type: 'text', value: 'x' }]]` in a paragraph's content gave nothing, now `x`.

Ordinary text leaves and mark wrappers read as before. If you store excerpts made by `toPlainText`, regenerating them can change their text.

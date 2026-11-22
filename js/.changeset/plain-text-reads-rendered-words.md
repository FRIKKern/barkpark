---
"@barkpark/react": patch
---

`toPlainText` now reads inline content with the `inlineText` in `src/inline.tsx`, in place of its own copy. A leaf (an object in an inline array) reads as its `value` if that is a non-empty string or a finite number, else as its legacy `text` by the same test, else as its `children`. In an inline array and in a leaf's `children`, a string reads as its text, a number as `String(number)` writes it, an array as its items in order, and an object inside an array as a leaf; anything else (`true`, `false`, `null`, or an object standing alone as `children`) reads as nothing. Inline nesting of any depth reads to the end instead of throwing.

Examples:

- `{ type: 'text', value: 'a', children: [{ type: 'text', value: 'b' }] }` gave `ab`, now `a`.
- `{ type: 'text', value: 42, text: 'forty-two' }` gave `forty-two`, now `42`.
- A bare array `[[{ type: 'text', value: 'x' }]]` in a paragraph's content gave nothing, now `x`.

If you store excerpts made by `toPlainText`, regenerating them can change their text.

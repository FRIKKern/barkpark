---
"@barkpark/react": patch
---

`toPlainText` now returns the same words the renderers draw for inline content. It reads each inline leaf the way `PortableDoc`, the Elixir reader and the Go reader do: the first non-empty of `value`, legacy `text`, then the leaf's own `children`. A caller sees different text in four cases:

- A leaf with both a `value` and `children` gives only its `value`. Before, the children's text was appended (`{ value: 'a', children: [{ value: 'b' }] }` gave `ab`, now `a`).
- A leaf whose `value` is an empty string reads its legacy `text`. Before, it gave nothing.
- A leaf whose `value` is a number gives its digits (`42` gives `42`). Before, it gave nothing.
- A bare array where an inline node was expected (`[[{ type: 'text', value: 'x' }]]`) gives its text. Before, it was skipped.

Text built only from ordinary `{ type: 'text', value }` leaves and mark wrappers is unchanged. If you store excerpts made by `toPlainText`, they change only for content holding one of the shapes above, and only when you regenerate them.

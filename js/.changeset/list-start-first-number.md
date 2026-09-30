---
'@barkpark/react': patch
---

PortableDoc: an ordered `list` with an integer `start` other than 1 renders `<ol start="N">`, byte-equal to the Elixir `:article` reader. Absent `start`, `start: 1`, a string `start` and bullet lists keep the bare `<ol>`/`<ul>` bytes. Nested ordered lists honour their own `start`.

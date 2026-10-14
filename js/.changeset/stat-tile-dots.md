---
'@barkpark/react': minor
---

PortableDoc: stat items render `dots: {on, of}` as an accessible dot row. A stat or stats item with `dots: { on: 2, of: 10 }` draws ten dots, the first two filled, inside `div.bp-stat__dots` (`role="img"`, `aria-label="2 of 10"` through the chrome string `%{on} of %{total}`; the dots themselves are `aria-hidden`). `of` must be a whole number 1..50 and `on` is clamped into 0..of; anything else draws nothing, so a stat without the field renders byte-identically. `paper-surface.css` styles the row. Mirrors the Elixir renderer; email and the Go TUI degrade it to `●●○○○○○○○○ 2/10`.

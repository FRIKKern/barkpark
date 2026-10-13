---
'@barkpark/react': patch
---

PortableDoc task list: the "in progress" spinner glyph is now a named image, `<span class="bp-g bp-g--progress" role="img" aria-label="in progress">`. An `aria-label` on a span with no role is prohibited (axe aria-prohibited-attr) and was never announced. The shipped `paper-surface.css` follows the status manifest's darker light "ok" tone, `#0d9488` → `#0f766e`, so "done" clears WCAG AA on the light paper: 3.56:1 → 5.20:1 on `#f6faf9`. Dark mode is unchanged.

---
'@barkpark/react': patch
---

The shipped `paper-surface.css` darkens faint paper text so it clears WCAG AA on both paper grounds. Light `--paper-ink-faint` moves from `#82918b` to `#62706b`: 3.13 → 4.93 on `bg` and 2.87 → 4.52 on `bg-deep`. Dark moves from `#6c7a74` to `#788680`: 4.09 → 4.83 and 3.84 → 4.53. Decorative dots, borders and the chart axis move to a new `--paper-ink-faint-line` at the old value, so they do not darken. The form option ring stays on `--paper-ink-faint` and clears 3:1.

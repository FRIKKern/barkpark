---
'create-barkpark-app': patch
---

Accessibility: both starters now include a "Skip to content" link (WCAG 2.4.1 Bypass Blocks) — visually hidden until focused, it lets keyboard users jump past the nav to `<main id="main">`. The blog-starter's pagination now marks the current page with `aria-current="page"` so screen readers announce which page you're on.

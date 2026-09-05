---
'@barkpark/react': minor
---

**One `<figcaption>`, one class.** Every article figure — `figure`, `diagram`, `asciicast` — now emits `<figcaption class="bp-figcaption">` instead of ~200 bytes of inline `color`/`font-style`/`font-size`/`font-family`/`max-width`, matching the Elixir producer (`Render.Figures` / `Render.Compose`).

Two functions collapse into one. The renderer used to carry `articleFigcaption` AND `asciicastFigcaption` for a single reason: the Elixir asciicast emitter had drifted to a bare `#55635e` where the figure/diagram captions read `var(--paper-ink-soft, …)`, and this package had to reproduce the drift byte for byte or the DOM-shape comparator diverged. That hex is **2.97:1 on the dark ground** — a WCAG failure the token-reading copies did not have. Both the drift and the second function are gone.

The caption's type changed with the mechanism: the reading **serif**, roman rather than italic, `0.9rem`/`1.45`, `--paper-ink-soft`, returned to `--bp-evidence-caption` inside a figure that may be 1240px wide.

**If you render PortableDoc without `paper-surface.css`**, captions were self-styled before and are now unstyled — load the stylesheet (or declare a `.bp-figcaption` rule of your own). `:email`/default output is unchanged and still inline-styled, because an email client has no stylesheet to carry a class.

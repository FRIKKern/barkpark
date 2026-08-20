---
'@barkpark/react': patch
---

PortableDoc figures open with a real beat, and a wide diagram no longer drags the whole page sideways.

The four article `<figure>` emitters (`diagram`, `asciicast`, `video`, and the generic captioned `figure`) previously hard-coded `margin:1.6rem 0` and set no overflow. Two consequences, both measured on a real render: a figure opened at 25.6px where the reader's spacing scale calls for 40px, and a hydrated Mermaid SVG wider than the reading column **spilled out of the figure and widened the document** — a 1400px diagram at a 1440px viewport took the page to a 1850px scroll width, so the reader got a horizontal scrollbar on the whole article rather than on the diagram.

The margin now reads `var(--bp-air-figure, 1.6rem)` / `var(--bp-air-asciicast, 1.6rem)` — the paper surface's air scale, which is emitted from `design/tokens.json` as a ratio of the paragraph beat, so evidence spacing is one source across the reader, the Studio canvas and this renderer instead of three sets of literals. The literal stays as the `var()` fallback, so a host that ships no paper stylesheet renders exactly as before. `overflow-x:auto` on the same elements contains the overflow: the figure self-scrolls and the document does not.

The markup change is one attribute value per figure kind and is pinned by the shared `pd-golden` fixtures, which are generated from the Elixir renderer — so this side and the server side cannot drift apart without the parity test failing.

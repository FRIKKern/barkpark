---
'@barkpark/react': patch
---

PortableDoc: the `asciicast` player now follows the reader's colour mode, and the cast mount's border is tokenised. `hydrateAsciicast` mounted every recording with a hardcoded `theme: 'asciinema'` — a `#121314` terminal — so a light-mode paper carried one embed that ignored the mode while its sibling mermaid diagram tracked it.

A new exported `activeAsciicastTheme(doc)` **delegates** to the existing `activeMermaidTheme` rather than re-deriving the mode: `'dark'` maps to asciinema's own dark theme, anything else to `'solarized-light'`. One derivation seam means the two lazy embeds on a page cannot disagree about which mode is active, and it resolves once per hydrate pass rather than per node. The light name is not arbitrary: of the nine themes `asciinema-player` 3.17.0 ships, `solarized-light` (`--term-color-background: #fdf6e3`) is the only one with a light background — the other eight sit between `#002b36` and `#2e3440`.

Separately, the `asciicast` mount emitted `border:1px solid #dde7e2`, the last bare hex among the block emitters; every sibling (evidence figure, paper-link card, section divider) already reads `var(--paper-rule, #dde7e2)`. On a dark surface that drew a light rule around a black terminal. The Elixir emitter carries the identical string and moved in the same change, so the pd-parity goldens were regenerated rather than hand-edited.

---
'@barkpark/react': patch
---

PortableDoc: the `asciicast` block gained an optional `poster` — the frame the terminal player rests on before play. Both hydrating clients previously hardcoded asciinema's `poster: 'npt:0:1'`, so a recording that opens on a one-line banner and then pauses for reading rested as a title line, a play triangle, and a tall slab of empty terminal black. A block may now name a later, FULL frame (`{ type: 'asciicast', src, poster: 'npt:0:12' }`, or `'end'`), and the resting state shows real, legible terminal content instead.

`poster` rides a new `data-cast-poster` attribute on the `div.bp-asciicast` mount point, emitted ONLY when set — an unset poster leaves the markup byte-identical to before and both clients (`@barkpark/react/client`'s `hydratePortableDoc` and the Phoenix `runAsciicast` hook) keep the `npt:0:1` fallback, so nothing changes for existing content. The value is attribute-escaped and handed to asciinema-player verbatim. Proven in a real browser: the same fixture frame that stays gated out at the default poster (revealed only by a play click) is on screen at rest under `poster: 'npt:0:2'`, with the player still paused.

Inert by design on the two player-less surfaces: the Go TUI renderer and the React Native card both degrade an asciicast to a labeled box, so there is no resting frame to choose (the same ruling `video`'s `poster` already carries in the TUI).

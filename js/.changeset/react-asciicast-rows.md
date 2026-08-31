---
'@barkpark/react': patch
---

PortableDoc asciicasts now preserve compact terminal heights across server and React readers.

The React emitter validates a block's `rows` value against the same 6–40 range as the Elixir renderer and emits it as `data-cast-rows`. The shared browser hydration path can therefore pass the authored height to asciinema-player instead of silently falling back to its default.

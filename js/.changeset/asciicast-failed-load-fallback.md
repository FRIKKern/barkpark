---
'@barkpark/react': patch
---

PortableDoc: a `asciicast` recording that cannot be loaded now renders an honest fallback instead of asciinema's bare 💥 box, and `hydratePortableDoc` stops counting it as a hydrated recording.

`hydrateAsciicast` called `player.create(...)`, stamped `data-asciicast-done` and incremented its counter unconditionally. Mounting is not loading: `create()` returns before the `fetch()` of `data-cast-src` resolves, so a 404 / CSP-blocked / CORS-refused / air-gapped recording produced `div.ap-overlay-error` — a bordered box whose entire content is one 💥 glyph, exactly the empty box the komposisjon law forbids — while the return still said `{asciicast: 1}`. Two lies in one call: one to the reader, one to the caller.

Detection is a post-mount probe of the player's own DOM, because asciinema-player 3.x exposes no error event (`create()`'s handle carries play/pause/ended/input/marker only): `.ap-overlay-error` means faulted, `.ap-terminal`/`.ap-overlay-start` means painted, and each mount resolves as soon as its own DOM answers. A probe that reaches its ceiling without either marker counts as loaded and swaps nothing — replacing a slow-but-working player with a "could not be loaded" card would be its own lie. A `create()` that throws lands on the fallback immediately.

The fallback is built with DOM APIs (no `innerHTML`): "Opptaket kunne ikke lastes." plus a link to the raw recording, under an own scheme allow-list so a hostile `data-cast-src` degrades to message-only rather than a `javascript:` link. The `<figcaption>` survives by construction — it is the `<figure>`'s sibling of the mount point, not the player's child — and the mount is stamped `data-asciicast-failed="true"` so a faulted cast is selectable without parsing the copy.

`HydrateResult` gains two fields: `asciicast` is now the **loaded** count, with `asciicastMounted` (players attempted) and `asciicastFailed` beside it, so `asciicast + asciicastFailed === asciicastMounted`. A caller reading only `asciicast` keeps a number that is true — and truer than before.

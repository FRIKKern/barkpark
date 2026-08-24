---
'@barkpark/core': patch
---

`listen()` no longer invents a `welcome` event out of a corrupt frame. A frame whose `data:` fails to parse has been skipped-and-reported through `onDroppedFrame` since that channel landed. A frame whose data *parses* but is not a JSON object — `data: null`, `data: 42`, `data: "hi"`, `data: [1,2]` — took a different path: it collapsed to an empty payload, and an empty payload is not dropped, it is **built**. `buildListenEvent` maps an unrecognised SSE event name to `welcome` and a missing id to `''`, so the async iterator yielded a synthetic `{ eventId: '', type: 'welcome' }` that the server never sent, on no channel at all.

That is the sharper half of the same defect. The parse failure lost an event; this one fabricated one — and `welcome` is the stream's "I am (re)connected, reset your cursor" signal, so a consumer keying on it acted on a message that never existed. An array was the quietest case of all: `typeof [] === 'object'`, so it sailed through the old check untouched.

Both are now the same skip with the same report: a non-object payload raises through the existing `onDroppedFrame` path, carrying the raw text and a `TypeError`. `data: {}` still yields — the real welcome frame carries no fields, and the guard has to reject non-objects without rejecting the empty object the old collapse produced by accident.

`onDroppedFrame`'s documented contract widens to match: it now fires for any unusable payload, not only an unparseable one. Callers already handling it need no change; callers who were silently receiving phantom welcomes will start seeing the reports instead.

Paid for within the gzipped budget rather than by raising it: the `reconnectBaseMs` guard carried a dead `Number.isFinite` conjunct next to a `Number.isInteger` that already rejects every non-finite number, so it was dropped — with tests now covering the `Infinity` case the old suite never did. Net ESM 16278 → 16298 B, CJS 16971 → 16989 B, both under their limits.

---
'@barkpark/react': patch
---

PortableDoc: the `chat-approval` / `chat-question` / `chat-plan` card header now wraps the way the Elixir engine wraps. The shared header row emitted `font-weight: 600` on the title span and `margin-left: auto; white-space: nowrap` on the status span — the state `components.ex` `chat_card_header/2` left behind. The engine had already retired the inline `nowrap` (being INLINE it beat every `paper-surface.css` rule, so a long status word forced one unbreakable line and gave the whole reader page horizontal scroll at a 390px viewport) and replaced it with `min-width: 0; overflow-wrap: anywhere` on BOTH spans — `anywhere` is the only value that reduces the intrinsic width a shrink-to-fit flex box is sized from, and `min-width: 0` is what lets the flex item shrink below its content size at all.

The JS mirror now emits the same three declarations, so an SDK-rendered chat card is the document the reader renders. Six frozen render-parity tests were red on `main` on this exact drift — the three per-block DOM-shape comparisons and the three composed-document cascades that replay each golden inside a multi-block document — and are green here. No golden fixture moved: the goldens already carried the engine's bytes, and the JS renderer moved to them.

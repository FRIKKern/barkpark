---
'@barkpark/react': patch
---

PortableDoc: the `heading` emitter now composes a non-empty `content` inline array through the shared inline dispatcher, falling back to the bare `text` string — the same dual-shape body `paragraph` uses and the byte-for-byte twin of the `compose.ex` heading clause. Headings persisted with the `content[]` shape (16/16 of the mobile capstone's headings) were rendering an empty `<h2></h2>` because the emitter read `text` alone. Render-side only; hostile author strings stay escaped.

---
'@barkpark/react': patch
---

PortableDoc: a draft-only task row now wears a DRAFT chip. The `task-board` card, the `tasks` / `task-list` row and the `roadmap` lane paint `<span class="bp-draft">DRAFT</span>` inside their title span when the snapshot row carries `draft: true` — the marker the Phoenix task resolver sets on a row whose stored id is still `drafts.`-prefixed. A published row carries no `draft` key and its markup is byte-identical to before. The Phoenix View emitter paints the same bytes, and `paper-surface.css` styles the chip.

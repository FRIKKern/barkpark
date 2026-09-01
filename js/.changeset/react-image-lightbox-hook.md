---
'@barkpark/react': patch
---

PortableDoc article images now carry the reader's lightbox hook, so an SDK-rendered Paper enlarges the same images the hosted reader does.

The React emitter mirrors `walk.ex`'s `:article` image leg and emits `data-bp-lightboxable="true"` on every content `<img>`. The reader shell enhances only images carrying that hook, so a Paper's chrome images are no longer turned into lightbox triggers. Elixir's email and default render legs stay bare.

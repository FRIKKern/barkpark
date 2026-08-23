---
'@barkpark/react': patch
---

`toPlainText` no longer drops a `note`/`notes` body persisted as
`{content:[…]}`. The renderer's `noteItemHtml` was swept for that shape (its
own comment records the sweep); the extractor twin still read `text` alone, so
a content-shape note rendered its prose on the page but contributed only its
label to excerpts, SEO descriptions, reading-time and search indexing. Flat
`text` stays the fallback and every existing golden is byte-identical.

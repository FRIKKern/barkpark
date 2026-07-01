---
'@barkpark/react': minor
---

Add `toPlainText(value)` — extracts the plain text from a Portable Text value for excerpts, SEO meta descriptions, reading-time estimates, and search indexing. Blocks are joined with a blank line; non-`block` custom nodes are skipped; malformed input is skipped rather than throwing. Pure and dependency-free, so it works in a Server Component (`generateMetadata`) as well as on the client — exported from both the client and RSC entries.

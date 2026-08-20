---
'create-barkpark-app': patch
---

Clean up a half-written scaffold when the copy step fails, so the immediate retry is no longer blocked by `Target directory "…" is not empty.`. The removal only touches bytes this run wrote: a directory the user created (or a symlink to one) keeps existing and only its entries go.

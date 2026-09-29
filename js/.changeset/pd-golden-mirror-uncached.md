---
---

No release. A comment-only edit to `@barkpark/react`'s pd-golden mirror-freshness
test header: the "KNOWN LIMIT" caveat said the guard could not fire on an
Elixir-only mirror change, which stopped being true when
`.github/workflows/js-tests.yml` gained an uncached step that runs it
(task-0fb4f5e1ef4a1237). No source, no types, no runtime behaviour changed.

---
---

Empty changeset: turbo task-input configuration only. The pd-golden fixtures the parity harnesses read live in `@barkpark/react`'s `tests/` dir, so they were in no turbo task's `inputs` and a fixture change did not invalidate the cache — `@barkpark/astro-parity`, `@barkpark/next-parity` and `@barkpark/media-parity` served a cached green over mutated goldens. All three are `private: true` test-only proof packages and no published package changes, so there is no version bump.

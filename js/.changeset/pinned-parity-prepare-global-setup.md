---
---

Empty changeset: pinned-parity is a private:true test/proof package (no version bump). The pinned-artifact prepare step moved from the package.json `test` script chain into a vitest `globalSetup` on the package's own config, so `cd js && npx vitest run` no longer reds on a missing `.pinned/` artifact. No shipped package changes.

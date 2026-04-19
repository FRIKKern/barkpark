---
'@barkpark/nextjs': patch
---

Fix TS2339 in `server/core.ts`: align `barkparkFetchInner` with the new flat envelope shape from `@barkpark/core@1.0.0-preview.1`. The deprecated `ReadEnvelope<T>` is now aliased to `T`, so the previous `envelope.result` access returned `undefined` at runtime and produced a TypeScript error in downstream builds. The fetch helper now returns the parsed body directly, matching the ADR-0001 contract.

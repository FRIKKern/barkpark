---
'create-barkpark-app': patch
---

Regenerate the blog-starter showcase seed to the full 46-type PortableDocument grammar (was 42), picking up the three interactive studio-chat cards (`chat-approval`, `chat-question`, `chat-plan`) and the `gauge-list` meter now that the canonical `@barkpark/react` renderer covers every in-scope type. The seed is auto-generated from the pd-golden parity fixtures (`scripts/gen-showcase-content.mjs`), so this keeps `showcase-content.test.ts` in sync with the react package's fixture set and unbreaks the create-barkpark-app gate when the renderer's 46-golden set lands. Cloud template mirror re-synced.

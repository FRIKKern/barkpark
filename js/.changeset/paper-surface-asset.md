---
'@barkpark/react': patch
---

react: ship `paper-surface.css` as a consumable asset. `@barkpark/react` now emits `dist/paper-surface.css` — a byte-for-byte copy of `api/assets/paper-surface/paper-surface.css`, the source of Phoenix's `Render.Stylesheet.css/0` — and exposes it via a new `"./paper-surface.css"` export subpath. Consumers `import "@barkpark/react/paper-surface.css"` to skin the (incoming) type-keyed `PortableDoc` renderer with the exact `bp-*` vocabulary Phoenix emits, so one stylesheet skins Next, Astro, and Phoenix identically.

The stylesheet is COPIED at build time by tsup's `onSuccess` hook, never `import`ed as a JS string — it gzips to ~15.9KB and inlining it would blow the bundle budgets. Because the api source lives outside `js/`'s turbo/pnpm workspace (turbo's cache hash can't observe edits to it), `tests/paper-surface-asset.test.ts` is the real drift guard: it fails CI if `dist/paper-surface.css` is not byte-identical to the api source.

size-limit budgets were re-based off ACTUAL measured usage, replacing the loose 8KB/15KB limits (which were caps, not usage). Today: `PortableText` 1.2KB, full bundle 3.1KB gzipped. New budgets: `PortableText` 2KB (tight regression guard), a named `PortableDoc renderer bundle` entry at 12KB, and total published JS at 12KB — the headroom sized for the incoming ~42-type `PortableDoc` renderer (the private web fork it ports from is ~1400 lines / ~15KB raw source, well under 12KB minified+gzipped). The per-symbol `import "{ PortableDoc }"` isolation entry lands with the renderer slice that creates the export.

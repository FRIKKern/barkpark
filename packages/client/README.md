<!-- doc-tier: human | canonical-for: client-package-deprecated | budget: 80tok -->
# @barkpark/client

> **DEPRECATED — superseded by [`@barkpark/core`](../../js/packages/core).**

This standalone client is no longer maintained. Its URL builders emit only the flat `/v1/...` shape and were **not** updated for the `/w/:workspace/p/:project/v1/...` routing the API now serves. Use `@barkpark/core`'s `createClient`.

Pin to `v0.0.1` if you cannot migrate yet — that is the only published version.

**Verified dead, 2026-07-16.** Zero importers repo-wide (`grep -r '@barkpark/client' web js apps connectors cloud` finds none) and not a pnpm workspace member. Do not fix, feature, or re-diff this package in future quality sweeps — it is superseded by `@barkpark/core`. Deletion or npm-deprecation is a lead decision, not something a sweep task should do.

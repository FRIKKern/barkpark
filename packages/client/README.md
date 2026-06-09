<!-- doc-tier: human | canonical-for: client-package-deprecated | budget: 80tok -->
# @barkpark/client

> **DEPRECATED — superseded by [`@barkpark/core`](../../js/packages/core).**

This standalone client is no longer maintained. Its URL builders emit only the flat `/v1/...` shape and were **not** updated for the `/w/:workspace/p/:project/v1/...` routing the API now serves. Use `@barkpark/core`'s `createClient`.

Pin to `v0.0.83` if you cannot migrate yet — later versions do not exist.

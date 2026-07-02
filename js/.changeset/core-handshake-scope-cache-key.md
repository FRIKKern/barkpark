---
'@barkpark/core': patch
---

core: fix `createHandshakeCache` keying `/v1/meta` on `projectUrl + dataset` only. The actual request is prefixed with `scopePrefix(config)` (`/w/<workspace>/p/<project>` when scoped), so two configs sharing `projectUrl + dataset` but differing in workspace/project hit different endpoints with different schema hashes yet collided on one cache entry — the second caller silently got the first scope's meta, corrupting schema-drift detection when the cache is shared across scoped configs. The cache key now includes `workspace` and `project`, matching the scope the request URL is built from.

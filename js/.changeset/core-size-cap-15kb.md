---
'@barkpark/core': patch
---

**Build:** raise the `@barkpark/core` size-limit cap from 14 KB to 15 KB. The gzipped CJS bundle reached 14.07 KB (over the 14 KB cap, breaking the Bundle-budget CI gate on main) after this session's legitimate API-surface growth — asset update/checkout/relations/search/suggestions, schema CRUD, and webhook management (#582–#622). The growth is real features, not bloat (ESM is 13.43 KB); 15 KB restores ~1 KB of headroom for continued growth while keeping the client lean. Same justified-growth call as the prior 14 KB bump.

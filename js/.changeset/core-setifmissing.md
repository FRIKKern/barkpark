---
'@barkpark/core': patch
---

Docs: document `patch().setIfMissing()` (a working op the README's patch enumeration omitted) and fix the stale `patch.ts` comment that claimed "Phase 1A implements only patch.set" — set/unset/inc/dec/setIfMissing all work now; only array ops + diffMatchPatch throw.

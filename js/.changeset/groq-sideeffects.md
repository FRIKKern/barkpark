---
'@barkpark/groq': patch
---

Set `"sideEffects": true` in `@barkpark/groq`'s package.json so the deferred stub's eager import-time `throw` cannot be tree-shaken away. The module's whole purpose is to throw on import (so projects can't ship against an empty 1.0 surface); the old `"sideEffects": false` told bundlers (webpack/Rollup/esbuild/Next.js) the module was pure and could be dropped when its bindings looked unused, which would silently elide the throw. The throw IS the intended side effect.

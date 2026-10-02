---
'@barkpark/nextjs': patch
---

`createDraftModeRoutes`: the GET redirect now always stays on the request's own origin.

A valid signature proves who signed `path`. It does not prove that `path` stays on this site. If a trusted signer signed an attacker-shaped slug such as `//evil.example`, `/\evil.example` or `/\t/evil.example`, the route sent the editor off-site after turning draft mode on. Browsers strip tab, CR and LF before resolving a URL, which is how the last form becomes `//evil.example`.

The redirect target is checked after `resolvePath` runs:

- a target containing a control character or a backslash, or one that resolves to another origin, redirects to `/`;
- a same-origin absolute URL returned by `resolvePath` is kept, reduced to its path, query and hash.

Relative paths work exactly as before.

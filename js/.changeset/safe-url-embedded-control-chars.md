---
'@barkpark/react': patch
---

`safeUrl` now removes ASCII tab, LF and CR from the WHOLE href before it tests for the protocol-relative `//host` / `/\host` form, instead of stripping control characters only at the head.

The WHATWG URL parser deletes exactly those three bytes — anywhere in the string — before it parses. So a CMS-authored link written as `/<TAB>/evil.example/phish` passed the allow-list as a root-relative path and then resolved in the browser to `https://evil.example/phish`, an off-site navigation from the reader's `<a href>`. The returned href is now the cleaned string, so the value that was checked is the value that resolves.

Legitimate URLs are unaffected: an href with no tab/LF/CR is byte-identical to before.

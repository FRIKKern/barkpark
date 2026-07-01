---
'@barkpark/react': patch
---

README: document the `components.hardBreak` option and add a security note that a mark's `value.href` is untrusted CMS content — the link-mark example must sanitize the URL (reject `javascript:`/`data:`/`vbscript:` schemes) before rendering it in an `href`. The renderer forwards mark values verbatim, so scheme filtering is the consumer's responsibility.

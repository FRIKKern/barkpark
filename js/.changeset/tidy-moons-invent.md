---
"@barkpark/nextjs-query": patch
"@barkpark/groq": patch
---

Adds a size budget. Both packages are published and ship a dist bundle, but
neither declared a `size` script — and turbo scores a package with no script
for a task as a success, so `turbo run size` reported them green having
measured nothing. Each now declares `size: size-limit` against a
`.size-limit.json` ceiling set from a measured build. No code change.

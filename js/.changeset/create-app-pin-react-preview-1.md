---
"create-barkpark-app": patch
---

Pin `@barkpark/react` to `^1.0.0-preview.1` in the blog-starter and website-starter templates. The templates carried `^1.0.0-preview.2`, but `@barkpark/react` has only ever published through `preview.1` — a caret range on a prerelease line does not float up to a later prerelease, so `npm install` in a freshly scaffolded project failed at resolution before a new user wrote a single line of code.

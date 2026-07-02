---
'@barkpark/codegen': patch
---

The generated `BarkparkImage` prelude interface is now flat (`_ref?`/`_id?`/`url?`) instead of the Sanity-style nested `asset?: { _ref }`. This matches the shape `@barkpark/core`'s `imageUrl()` and `<BarkparkImage>` actually resolve (`ImageRef`), so a codegen-typed image field passes straight into those helpers without a cast — previously the nested shape resolved to `null`. `BarkparkReference` is unchanged.

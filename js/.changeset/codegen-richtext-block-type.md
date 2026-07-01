---
'@barkpark/codegen': patch
---

Generated types now emit `Array<BarkparkPortableTextBlock>` for `richText` fields instead of `unknown`, so `post.body` carries a concrete shape and consumers can render `<PortableText value={post.body} />` without a cast. A new standalone `BarkparkPortableTextBlock` interface is added to the prelude next to `BarkparkSlug`/`BarkparkImage` (no `@barkpark/react` import — the module stays self-contained). Widening `unknown` to this block array is non-breaking: existing narrowing/casts still compile.

---
'@barkpark/react': minor
---

`<PortableText>`'s `value` prop now accepts `null` / `undefined`, matching what the renderer already tolerated at runtime (nullish input renders nothing). Previously the prop was typed `PortableTextNode[] | PortableTextNode`, so a consumer with an optional/unset body field (`post.body: PortableTextNode[] | undefined` — the shape codegen and real data produce) hit a spurious TS error or had to add guards. Widening the input type is non-breaking; all existing callers still type-check.

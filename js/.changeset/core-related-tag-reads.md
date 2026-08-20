---
'@barkpark/core': minor
---

**Added:** three weighted-tag reads mirroring the ae-w10 server routes —
`client.getRelated(id, opts?)` (`GET /v1/data/related/:dataset/:id`, server PR #5615),
`client.listTags(opts?)` (`GET /v1/data/tags/:dataset`, server PR #5632), and
`client.getTagDocs(tag, opts?)` (`GET /v1/data/tags/:dataset/:tag`, server PR #5632).
`getRelated` returns the fused tag-overlap / backlink candidates (`{ related, count }`,
each entry carrying `score` / `sources` / `shared_tags`); `listTags` returns the per-tag
registry (`{ tags, count }`, each `{ tag, counts, total }`); `getTagDocs` returns the
strength-ranked carriers (`{ tag, documents, count }`). New public types
`RelatedEntry` / `RelatedResult` / `RelatedOptions`, `SharedTag`, `TagRegistryEntry` /
`ListTagsResult` / `ListTagsOptions`, `TagDoc` / `TagDocsResult` / `TagDocsOptions`,
and a `WeightedTag` interface with a `normalizeTags(tags)` helper that collapses a
document's dual-shape `tags` field (weighted objects OR flat strings) into
`{ names, entries }`. These mixed-type reads stay unnarrowed on `typedClient` by
design, like `getBacklinks`/`getGraph`.

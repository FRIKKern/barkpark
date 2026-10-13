<!-- doc-tier: agent | canonical-for: search-media-overview | budget: 350tok -->
# Search + Media

OWNER doc: **docs/search/INTELLIGENCE.md** — search architecture, the analytics ops contract (crystallizer at 03:30/04:00 UTC, 90-day retention, `X-BP-Search-Parent` lineage header), and the design-principle constraints. Read it before touching anything under `api/lib/barkpark/search/`.

Shape of the system:
- `QueryPipeline.search/4` ranks results from surface, scope and context. Retrievers are pluggable (`documents_retriever.ex`); Indx rides that seam via `engine=indx` and stays outside the plugin registry. Media search uses `api/lib/barkpark/media/delivery/retriever.ex` (`Barkpark.Media.Delivery.Retriever`), which does not implement `Barkpark.Search.Retriever`.
- `Intelligence.record/6` + `record_interaction/4` capture query/interaction events; the crystallizer batch-distills them.
- Phase tracker + deliberate-skip table (P9/P10 triggers) → docs/search/ROADMAP.md.

Media HTTP responses — asset `absoluteUrl` and the `/v1/media/*` list envelope (`total`/`hasMore`/`nextOffset`/`nextCursor`, and the two meanings of `count`): [../contracts/media-http-envelope.md](../contracts/media-http-envelope.md).

Image upload and on-demand transforms (`/media/files/<path>?w=&h=&fit=&crop=&rect=&fp-x=&fp-y=&fm=&auto=&q=`, cached on first request): [../media/IMAGE-TRANSFORMS.md](../media/IMAGE-TRANSFORMS.md).

Sanity image and file URLs, `@sanity/image-url` config, `sourceId`: [../media/SANITY-IMAGE-URLS.md](../media/SANITY-IMAGE-URLS.md).

Media discovery: **Find-vs-Pick** (search-first Find pane, browse Pick modal) and the OpenSearch/Meilisearch choice: docs/media/DISCOVERY.md. Plugin: `api/lib/barkpark/plugins/media.ex`; assets: `priv/plugins/media/`.

Pending local cleanup captures the exact migration-versioned raw row, including `source_id`; unknown schemas refuse.

## Code anchors
- api/lib/barkpark/search/query_pipeline.ex — def search
- api/lib/barkpark/search/intelligence.ex — def record, def record_interaction
- api/lib/barkpark/media/delivery/retriever.ex — defmodule Barkpark.Media.Delivery.Retriever
- api/lib/barkpark/plugins/media.ex — defmodule (media plugin)
- api/lib/barkpark/media/storage/delete_operation.ex — def commit
- api/lib/barkpark/media/transform.ex — defmodule Barkpark.Media.Transform

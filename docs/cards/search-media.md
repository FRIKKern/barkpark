<!-- doc-tier: agent | canonical-for: search-media-overview | budget: 350tok -->
# Search + Media

OWNER doc: **docs/search/INTELLIGENCE.md** — search architecture, the analytics ops contract (crystallizer at 03:30/04:00 UTC, 90-day retention, `X-BP-Search-Parent` lineage header), and the design-principle constraints. Read it before touching anything under `api/lib/barkpark/search/`.

Shape of the system:
- `QueryPipeline.search/4` is the single entry — surface + scope + context in, ranked results out. Retrievers are pluggable behind the retriever seam (`documents_retriever.ex`, `media_retriever.ex`; the Indx engine rides the same seam via `engine=indx` and is deliberately absent from the plugin registry).
- `Intelligence.record/6` + `record_interaction/4` capture query/interaction events; the crystallizer batch-distills them.
- Phase tracker + deliberate-skip table (P9/P10 triggers) → docs/search/ROADMAP.md.

Media discovery: the **Find-vs-Pick** philosophy (search-first Find pane vs browse Pick modal) and the OpenSearch-vs-Meilisearch decision point live in docs/media/DISCOVERY.md. Media plugin itself: `api/lib/barkpark/plugins/media.ex`; assets in `priv/plugins/media/`.

## Code anchors
- api/lib/barkpark/search/query_pipeline.ex — def search
- api/lib/barkpark/search/intelligence.ex — def record, def record_interaction
- api/lib/barkpark/search/media_retriever.ex — defmodule Barkpark.Search.MediaRetriever
- api/lib/barkpark/plugins/media.ex — defmodule (media plugin)

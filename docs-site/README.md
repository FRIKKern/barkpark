<!-- doc-tier: human | canonical-for: docs-site-overview | budget: 80tok -->
# docs-site/

Placeholder directory intended for Track A's Fumadocs app (`js/docs/`) to read at build time. The build-time wiring is not yet implemented — `js/docs/source.config.ts` currently reads from `content/docs/` only.

| Path | Owner | Notes |
| --- | --- | --- |
| `reference/<package>/` | CI (`typedoc.yml`) | Regenerated when `js/packages/**` or `tooling/typedoc/**` change on `main`, not committed (uploaded as the `typedoc-reference` CI artifact) |

Nothing here is a runnable site on its own. The Fumadocs app (`js/docs/`) is the consumer.

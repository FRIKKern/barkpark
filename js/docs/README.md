<!-- doc-tier: human | canonical-for: js-docs-site | budget: 100tok -->
# @barkpark/docs

Barkpark documentation site — Next.js 15 + Fumadocs v14.

## Quickstart

This package belongs to the `js/` workspace, not the repository-root one, so
`--filter @barkpark/docs` matches nothing when run from the root. Run both
commands from anywhere in the repository:

```bash
pnpm -C js install
pnpm -C js --filter @barkpark/docs dev
```

Open <http://localhost:3000>.

## Information architecture (P0)

`getting-started`, `concepts`, `reference/errors` are the highest-priority pages. Content lives in `content/docs/`.

CI-generated API reference lands at `docs-site/reference/<pkg>/` (Track A consumer).

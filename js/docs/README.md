# @barkpark/docs

Barkpark documentation site — Next.js 15 + Fumadocs v14.

## Quickstart

```bash
pnpm install
pnpm --filter @barkpark/docs dev
```

Open <http://localhost:3000>.

## Production build

```bash
pnpm --filter @barkpark/docs build
```

## Content

Content lives in `content/docs/`. The information architecture (Getting Started,
Concepts, Studio, Content Modeling, APIs and SDKs, Framework Guides, Task Guides,
Reference, Templates) spans the doc set.

The P0 pages (`getting-started`, `concepts`, `reference/errors`) are authored
multi-section MDX.

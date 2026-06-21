<!-- doc-tier: agent | canonical-for: nextjs-version-warning | budget: 250tok -->
<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

`web/` is the read-only Next.js demo consuming the Phoenix API. SDK consumption patterns (raw fetch vs `@barkpark/nextjs`, live examples): `docs/cards/js-sdk.md`. Demo specifics (env vars, routes, SDK status, rollback): `web/README.md`.

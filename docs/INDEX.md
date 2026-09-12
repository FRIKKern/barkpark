<!-- doc-tier: agent | canonical-for: doc-catalog | budget: 300tok -->
# Docs

Two reader paths, in order. Agents route from the routing table at the
repository root.

**A small collection** (notes, links, a reading list)
1. [setup/QUICKSTART.md](setup/QUICKSTART.md) — install `bp`
2. [learn/README.md](learn/README.md) — the model and local loop
3. [cheatsheets/bp.md](cheatsheets/bp.md) — the `bp` reference

**A CMS** (a site with authors)
1. [setup/QUICKSTART.md](setup/QUICKSTART.md) local · [setup/CLOUD-QUICKSTART.md](setup/CLOUD-QUICKSTART.md) hosted
2. [learn/README.md](learn/README.md) — model your types
3. [studio/user-guide.md](studio/user-guide.md) — editors' manual
4. Read from your app — HTTP: [api-v1.md](api-v1.md) · JS/TS: [cards/js-sdk.md](cards/js-sdk.md)

JS docs site: `pnpm -C js install && pnpm -C js --filter @barkpark/docs dev`

**Also supported** — [learn/plugins-catalog.md](learn/plugins-catalog.md):
papers, tasks, sheets, ONIX. Self-host: [setup/GO-LIVE.md](setup/GO-LIVE.md),
[PHILOSOPHY.md](PHILOSOPHY.md).

Deeper reference: [contracts/schema-v2.md](contracts/schema-v2.md), plus
[ops/](ops/), [cheatsheets/](cheatsheets/), [setup/](setup/).

<!-- doc-tier: human | canonical-for: paper-authoring-cheatsheet | budget: 600tok -->
# Papers — cheatsheet

A paper is Barkpark's block document (Bulldocs plugin). Read it anywhere; author it through the ingest API or Studio.

| Surface | Where |
|---|---|
| Browser reader | `GET /papers/:slug` (public) |
| Terminal | `bp paper view <slug>` (`--theme dark\|light\|auto` · `--perspective published\|drafts\|raw` · `--width N` · `-o json`) |
| TUI | paper pane (read-only render) |
| Studio | block editing at `/studio` |

Ingest is tier `ingest` — token read from `BARKPARK_INGEST_TOKEN` (bearer fallback):

| Action | bp | HTTP |
|---|---|---|
| Publish / upsert | `bp bulldocs publish <slug> --file paper.json` | `POST /v1/plugins/bulldocs/papers` |
| Patch blocks (atomic ops) | `bp bulldocs patch <slug> --file ops.json --if-rev N` | `POST /v1/plugins/bulldocs/papers/:slug/ops` |
| Pending intents | `BARKPARK_INGEST_TOKEN=… bp bulldocs intents` | `GET /v1/plugins/bulldocs/intents` (ingest tier, not your admin token) |
| Drain one intent | `bp bulldocs intent-processed <id>` | `POST /v1/plugins/bulldocs/intents/:id/processed` |

Publish: `{"slug":…,"blocks":[…]}` (preferred) or `{"slug":…,"body_html":…}`. Patch: `{"ops":[…]}`; `--if-rev` rejects unless the paper is still at that rev.

**`body_html` onto a paper that ALREADY has blocks: 422.** Blocks win; those bytes become a cache the next read rewrites. Send `blocks`, or `"clear_blocks":true` to make the row HTML-only.

**Read-back:** no single-paper GET: `/v1/plugins/bulldocs/papers/:slug` 404s. Read via `bp doc get paper <slug>` or `bp paper view <slug>`.

**Authoring standard (agents: read before publishing).** ~50 block types in three tiers (element/widget/section — heading, paragraph, table, cards, pipeline, roadmap, …) — owned by `api/lib/barkpark/portable_doc/tiers.ex` (`Tiers.by_tier/0`). Doctrine papers: `bp paper view portabledoc-doctrine` (six rules) and `composition-doctrine-plan` (nine principles). Publish wall (papers + tasks): non-trivial `description` + 2–4 weighted tags, each registered as a published `type:tag` doc.

The paper schema uses v2 field types, so the TUI renders papers read-only — edit in Studio. Clean installs ship one paper at `/papers/welcome`.

Canon: [`api/CLAUDE.md`](../../api/CLAUDE.md) (Bulldocs section) · [`../cards/tui.md`](../cards/tui.md).

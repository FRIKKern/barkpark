<!-- doc-tier: human | canonical-for: paper-authoring-cheatsheet | budget: 600tok -->
# Papers — cheatsheet

A paper is Barkpark's block document (Bulldocs plugin). Read it anywhere; author it through the ingest API or Studio.

| Surface | Where |
|---|---|
| Browser reader | `GET /papers/:slug` (public) |
| Terminal | `bp paper view <slug>` (`--theme dark\|light` · `--perspective drafts\|raw` · `--width N` · `-o json`) |
| TUI | paper pane (read-only render) |
| Studio | block editing at `/studio` |

Ingest is tier `ingest` — token read from `BARKPARK_INGEST_TOKEN` (bearer fallback):

| Action | bp | HTTP |
|---|---|---|
| Publish / upsert | `bp bulldocs publish <slug> --file paper.json` | `POST /v1/plugins/bulldocs/papers` |
| Patch blocks (atomic ops) | `bp bulldocs patch <slug> --file ops.json --if-rev N` | `POST /v1/plugins/bulldocs/papers/:slug/ops` |
| Pending intents | `BARKPARK_INGEST_TOKEN=… bp bulldocs intents` | `GET /v1/plugins/bulldocs/intents` (ingest tier, not your admin token) |
| Drain one intent | `bp bulldocs intent-processed <id>` | `POST /v1/plugins/bulldocs/intents/:id/processed` |

Publish payload: `{"slug":…,"blocks":[…]}` or `{"body_html":…}`. Patch payload: `{"ops":[…]}`; `--if-rev` rejects unless the paper is still at that rev.

The paper schema uses v2 field types, so the TUI renders papers read-only — edit in Studio. Clean installs ship one paper at `/papers/welcome`.

Canon: [`api/CLAUDE.md`](../../api/CLAUDE.md) (Bulldocs section) · [`../cards/tui.md`](../cards/tui.md).

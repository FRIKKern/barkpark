<!-- doc-tier: human -->
# scaffy plugin

Registers the `command` document type — the wire form of a `.scaffy` command.

Scaffy is **commands as content** (epic charter `.claude/workflows/bp-scaffy-charter.md`).
The engine (`internal/scaffy` + `bp scaffy validate/fmt/run/remove`) is shipped and
live. This plugin makes a command a first-class Barkpark document so a connected
repo can pull its scaffolding over one connect, exactly like Papers and Tasks.

## What this plugin contributes

- `register_schemas/1` → the `command` document type, read from
  `schemas/command.json`. Auto-registers on every boot via
  `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
  `(name, dataset)`. `capabilities: ["schemas"]` only — **zero routes**: the
  generic query endpoint (`GET /v1/data/query/:dataset/command`) serves every
  registered public schema, and the Studio editor renders it through the shared
  `studio_editor_shell`. No bespoke API, no new LiveView.

## The `command` schema (charter D45/D46)

The `.scaffy` source is stored **verbatim** in one content string field —
`source`, field type `"source"` — never a lossy block decomposition: the
`.scaffy` file IS the truth. Studio renders `source` read-only in a monospace
`<pre>` (see `BarkparkWeb.Components.FieldInputs` — the `"source"` clause) and
emits no form input, so a Studio save can never diverge the server copy from the
repo copy.

Label-spine metadata is queryable:

| field | type | source (parsed from the `.scaffy` header) |
|---|---|---|
| `title` | string | `COMMAND` |
| `description` | text | `DESCRIPTION` |
| `concept` | string | `CONCEPT` |
| `variant` | string | `VARIANT` |
| `domain` | string | `DOMAIN` |
| `direction` | string | `DIRECTION` (`add`\|`remove`) |
| `tags` | arrayOf composite `{tag,strength,rationale}` | `TAGS`, re-weighted with distinct descending strengths |

`visibility: "public"` — tokenless reads. One connect = zero tokens for
`bp scaffy pull` / `ls --remote`.

Stable doc id: `<domain>--<concept>--<variant>` (concept alone is non-unique —
`docs-card` has both an `add` and a `remove` command). Seeding of the 7-command
corpus is the `scaffy-w4-seed-corpus` slice.

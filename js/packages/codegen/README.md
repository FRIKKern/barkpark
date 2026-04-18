# @barkpark/codegen

Type-safe codegen for Barkpark CMS. Generates TypeScript interfaces, Zod schemas, and a typed client from your dataset schema.

## Status

v0.1 — Phase 4 initial release. Unstable API until v1.0.

## Install

Install per-app as a dev dependency (not globally — the CLI binds to the generated output in each project):

```bash
pnpm add -D @barkpark/codegen
# or
npm install --save-dev @barkpark/codegen
# or
yarn add -D @barkpark/codegen
```

## Quick start

1. Scaffold config:

   ```bash
   pnpm barkpark init
   ```

   Writes `barkpark.config.ts` and an empty `.barkpark/` directory.

2. Pull the live schema envelope:

   ```bash
   BARKPARK_TOKEN=... pnpm barkpark schema extract
   ```

   Fetches `/v1/schemas/:dataset` and caches it at `.barkpark/schema.json`.

3. Emit types:

   ```bash
   pnpm barkpark codegen
   ```

   Writes `barkpark.types.ts`.

4. Use the generated client in your app:

   ```ts
   import { createClient } from '@barkpark/core'
   import { typedClient, collectionMap } from './barkpark.types'

   const client = typedClient(
     createClient({ apiUrl: 'http://localhost:4000', token: process.env.BARKPARK_TOKEN }),
   )

   const posts = await client.query('post').fetch()
   ```

## CLI reference

### `barkpark init [--cwd <path>]`

Scaffolds a new project:

- `barkpark.config.ts` — default config with `apiUrl`, `dataset: "production"`, and codegen output paths.
- `.barkpark/.gitkeep` — placeholder for the cached schema envelope.

Skips files that already exist. Use `--cwd` to target a different directory than the current working directory.

### `barkpark schema extract [--api-url <url>] [--token <token>] [--dataset <name>] [--out <path>]`

Fetches the dataset schema envelope and writes it to disk.

| Flag | Default | Env fallback |
|---|---|---|
| `--api-url` | from config | — |
| `--token` | — | `BARKPARK_TOKEN` |
| `--dataset` | `production` | — |
| `--out` | `.barkpark/schema.json` | — |

Exits `2` on auth failure (401/403), `3` on network failure.

### `barkpark codegen [--in <path>] [--out <path>] [--watch] [--loose] [--check] [--no-prettier] [--source <text>]`

Emits `barkpark.types.ts` from the cached schema.

| Flag | Default | Purpose |
|---|---|---|
| `--in` | `.barkpark/schema.json` | Source envelope path. |
| `--out` | `barkpark.types.ts` | Output file. |
| `--watch` | off | Re-emit on `--in` change (chokidar, 200ms trailing debounce). |
| `--loose` | off | Map unknown field types to `string` / Zod `.passthrough()`. |
| `--check` | off | Exit non-zero if the output would differ from the existing file. For CI drift detection. |
| `--no-prettier` | prettier on | Skip formatting. Also auto-skipped if prettier is not installed (prints a warning). |
| `--source` | `/v1/schemas/production` | Label embedded in the generated header for traceability. |

### `barkpark check [--api-url <url>] [--dataset <name>] [--cache <path>]`

Compares the hash of the cached schema against the live `/v1/meta` response.

- Exit `0` — cache matches server.
- Exit `1` — drift detected (prints both hashes).
- Exit `3` — network failure (CI inconclusive — not `0`).

Intended for a CI gate that blocks merges when the server schema has moved ahead of the committed cache.

## Config file

```ts
// barkpark.config.ts
import { defineConfig } from '@barkpark/codegen'

export default defineConfig({
  apiUrl: 'http://localhost:4000',
  dataset: 'production',
  // token can also come from BARKPARK_TOKEN env var
  schema: {
    cachePath: '.barkpark/schema.json',
  },
  codegen: {
    out: 'barkpark.types.ts',
    loose: false,
    prettier: true,
    source: '/v1/schemas/production',
  },
  watch: {
    debounceMs: 200,
  },
})
```

CLI flags always override config values.

## Generated output

`barkpark.types.ts` contains, in this order:

- **Header** — `AUTO-GENERATED` banner with `schemaHash` (SHA-256 over canonical envelope), codegen version, mode (`strict` / `loose`), and source label.
- **Per-schema `export interface X`** — one interface per document type with all fields typed.
- **Per-schema `export type XField` / `export type XFilter`** — string unions of filterable field names.
- **`DocumentMap` / `DocumentType`** — union of every schema in the envelope.
- **`CollectionMap` / `CollectionSlug`** — union of schemas marked `"public"`.
- **Per-schema `export const XInputSchema = z.object({...}).strict()`** — Zod input validators (`.passthrough()` in `--loose`).
- **`collectionMap`** — runtime const mapping slug → input schema.
- **`typedClient()`** — helper that wraps `@barkpark/core`'s `createClient` with the generated types.
- **`__run_barkpark_codegen_first__`** — compile-time sentinel that deliberately breaks the build if codegen never ran. The fix is always "run `barkpark codegen` once".

## Strict vs loose

**Strict (default):**

- Unknown field types → TypeScript `unknown`.
- Zod input schemas are `.strict()` (extra keys rejected).
- Best for mature schemas where you want the compiler to flag every gap.

**Loose (`--loose`):**

- Unknown field types → `string`.
- Zod input schemas are `.passthrough()` (extra keys retained).
- Best during early development or when the schema is still churning and ergonomics matter more than safety.

Prefer strict for shipped apps; loose only while iterating.

## CI integration

Add a drift gate to your pipeline so stale committed types fail fast:

```yaml
- name: Verify codegen is up to date
  env:
    BARKPARK_TOKEN: ${{ secrets.BARKPARK_TOKEN }}
  run: |
    pnpm barkpark schema extract --api-url https://cms.example.com
    pnpm barkpark codegen --check --source https://cms.example.com/v1/schemas/production
```

`--check` exits `1` if the regenerated output would differ from the committed `barkpark.types.ts`. `--source` pins the label embedded in the generated header so hashes stay reproducible across environments.

## Watch mode

`barkpark codegen --watch` observes the schema file (default `.barkpark/schema.json`) with chokidar and re-emits on change, debounced 200ms. Useful during local dev when paired with a file-sync tool that writes the envelope on schema edits.

A dedicated Phoenix → file bridge is deferred to 1.1 — for now, either re-run `barkpark schema extract` on demand or point a sync tool at `.barkpark/schema.json`.

## Troubleshooting

- **`Cannot read schema at .barkpark/schema.json`** — run `barkpark schema extract` first. Requires `BARKPARK_TOKEN` env var or `--token`.
- **`drift: generated output differs from ...`** — the committed file is stale. Run `barkpark codegen` (no `--check`) to regenerate, then commit.
- **`prettier not available — emitting unformatted output`** — either `pnpm add -D prettier` or pass `--no-prettier` to silence the warning.
- **`__run_barkpark_codegen_first__` compile error** — run `pnpm barkpark codegen` once. The generated file is not checked in for new projects.
- **Exit code `2` (auth)** — `BARKPARK_TOKEN` is missing or not admin-scoped. `/v1/schemas/:dataset` requires admin.
- **Exit code `3` (network)** — `--api-url` is unreachable. Check the URL and that the Phoenix service is running.

## Deferred to 1.1

- Worker-thread AST walk for schemas > 500 (currently single-threaded with a runtime warning).
- Dedicated Phoenix-native file bridge for watch mode (current implementation watches a local `schema.json`).
- `@barkpark/core` runtime extraction of `typedClient` (currently inlined in generated output).

## License

Apache-2.0

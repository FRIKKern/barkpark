<!-- doc-tier: agent | canonical-for: media-plugin-overview | budget: 150tok -->
# media plugin

Native media library — one document per asset with rich metadata.

**Domain:** compiled module in `lib/barkpark/plugins/media.ex`; manifest, schemas, and this README under `priv/plugins/media/`. The entry module lives in the compiled tree so it actually registers — the plugin ecosystem requires the module on the BEAM path, not just the `priv/` manifest.

## Capabilities

- `schemas` — registers the `media_file` document type
- `codelists` — registers media-related codelists

## Verifying

```bash
cd api
mix compile
mix test test/barkpark/plugins/media_test.exs
```

## Further reading

- `docs/contracts/schema-v2.md` — composite, arrayOf, codelist, localizedText
- `lib/barkpark/plugin.ex` @moduledoc — CANONICAL plugin contract
- `lib/barkpark/plugins/registry.ex` — discovery & registration entrypoint

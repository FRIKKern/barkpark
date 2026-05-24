# media

Native media library — one document per asset with rich metadata.

## Capabilities

- `schemas`
- `codelists`

## Layout

The entry module lives in the compiled tree so it actually registers; the
manifest, schemas, and this README live under `priv/plugins/media/`.

```
lib/barkpark/plugins/media.ex     # plugin module (use Barkpark.Plugin)
test/barkpark/plugins/media_test.exs  # on the mix test path
priv/plugins/media/
├── plugin.json                   # manifest (validated at compile time)
├── README.md                     # this file
└── schemas/                      # plugin schema definitions
```

## Adding code

- Schemas: drop JSON or Elixir schema files into
  `priv/plugins/media/schemas/`.
- Logic: extend the module in `lib/barkpark/plugins/media.ex`.
- Tests: add cases to `test/barkpark/plugins/media_test.exs`
  and run `mix test`.

## Verifying

```bash
cd api
mix compile
mix test test/barkpark/plugins/media_test.exs
```

## Further reading

- `docs/plugins/SCHEMA_V2.md` — composite, arrayOf, codelist, localizedText
- `Barkpark.Plugin` behaviour — `lib/barkpark/plugin.ex`
- `Barkpark.Plugins.Registry` — discovery & registration entrypoint

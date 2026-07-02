---
'@barkpark/codegen': patch
---

Make the `barkpark` CLI's flag/config resolution consistent across commands.

- `barkpark generate --from <file>` now reads `output` and `dataset` from `--config`
  (like the fetch path already does), so a project driving codegen from
  `barkpark.config` can add `--from schema.json` for the network-free CI drift gate
  without re-passing those flags. CLI flags stay overrides; the schema file itself is
  still one-shot (config-file `--watch` remains fetch-path-only).
- `barkpark schema-path` now rejects a lone `--workspace` or `--project` (exit 1 with
  the both-or-neither message) instead of silently printing the flat
  `/v1/schemas/<dataset>` path — the same guard `generate` already applies.

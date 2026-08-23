---
"@barkpark/codegen": minor
---

The schema-fetch deadline is now settable without editing code: `--timeout <ms>` on the CLI, `timeoutMs` in `barkpark.config`, or the `BARKPARK_SCHEMA_TIMEOUT_MS` environment variable (precedence in that order, mirroring `apiUrl`). `0` disables the deadline (core's convention); the default stays 30s. A mistyped value fails loud instead of silently becoming the default.

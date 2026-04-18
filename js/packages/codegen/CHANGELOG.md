# Changelog

All notable changes to @barkpark/codegen will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-04-18

### Added
- Initial `barkpark` CLI: `init`, `schema extract`, `codegen`, `check`
- TypeScript interface generation from Phoenix schema envelope
- Zod input schema emission (strict / loose modes)
- Typed client wrapper with field and filter string unions
- SHA-256 canonical schema hash in generated header (ADR-011)
- `codegen --check` for CI drift detection against committed output
- `codegen --watch` for local development (chokidar, 200ms debounce)
- Offline `.barkpark/schema.json` fallback (no Phoenix required at build)
- Empty-DocumentMap compile-time sentinel `__run_barkpark_codegen_first__`

### Known limitations
- Worker-thread AST walk for schemas > 500 deferred to 1.1 (single-threaded emit with warning)
- TypedClient runtime inlined in generated file (extraction to `@barkpark/core` deferred)

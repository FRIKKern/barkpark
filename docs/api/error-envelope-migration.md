<!-- doc-tier: agent | canonical-for: error-envelope-migration | budget: 500tok -->
# Error Envelope Migration — v1 → v2

## Sunset policy

v1 is **not scheduled for removal.** Minimum runway after v2 GA is one minor release; actual sunset will be announced explicitly in this document. TUI and curl-based workflows depend on the v1 shape and need a coordinated migration. Until the announcement lands, treat v1 as permanent.

Rollout when scheduled:
1. v2 becomes default; v1 works via `Accept-Version: 1`.
2. v1 emits `Deprecation` response header (RFC 8594 / RFC 9745) with a sunset date.
3. v1 removed; requests without `Accept-Version` get v2.

Each step is gated on the public Studio + TUI clients confirming they have moved.

## Why v2

Phase 3 introduced a structured error envelope so SDK clients, pipeline tools, and Studio can render per-field validation diagnostics without parsing free-form strings.

## Wire shapes

Select with `Accept-Version: 2` header. Non-validation errors (`not_found`, `unauthorized`, `precondition_failed`, etc.) are **unchanged** in v2 — negotiation only reshapes `validation_failed`.

| Concern | v1 (default) | v2 (opt-in) |
|---|---|---|
| Header | absent or `Accept-Version: 1` | `Accept-Version: 2` |
| Validation key | `error.details` — `%{field => [str]}` | `error.errors` — `%{path => [violation]}` |
| Path format | flat field name | JSON Pointer (`/contributors/0/role`) |
| Per-violation | bare string | `{severity, code, message, rule}` |
| Buckets | `errors` only | `errors`, `warnings`, `infos` |

## Implementation pointers

- Module: `BarkparkWeb.ErrorEnvelope` (`serialize_v1/1`, `serialize_v2/1`)
- Plug: `BarkparkWeb.Plugs.ErrorEnvelopeNegotiation` — wired into 14 pipelines — `:api`, `:cycle_api`, `:scoped_api`, `:shared_docs_api`, `:shared_media_api`, `:scoped_mutate`, `:scoped_media_mutate`, `:api_unlimited`, `:api_preview`, `:session_token_root`, `:user_auth`, `:media_mutate`, `:flat_admin_api`, `:media_processing_callback`. Re-derive rather than transcribe: `awk '/^  pipeline /{n=$2} /plug\(BarkparkWeb.Plugs.ErrorEnvelopeNegotiation\)/{print n}' api/lib/barkpark_web/router.ex`
- Today only `MutateController` reshapes for `validation_failed` v2; other controllers pick up the assign automatically when they need it
- Code registry: `Barkpark.Content.ErrorCodes` — compile-time map atom → `%{message_template, default_severity, since_version}`; new codes are additive
- Hints: `Barkpark.Content.Errors.to_envelope/2` adds an additive top-level `hint` string keyed off the stable `code` (`@hints` map); v1 and v2 both include it; it reshapes no existing key

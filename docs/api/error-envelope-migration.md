# Error Envelope Migration — v1 → v2

> Status: **v2 opt-in available.** v1 remains the default. Sunset of v1 is
> deferred — see [Sunset Timeline](#sunset-timeline) below.

Phase 3 introduced a structured error envelope (v2) so SDK clients,
pipeline tools, and the Web Studio can render per-field validation
diagnostics without parsing free-form strings. v1 continues to work
unchanged for every existing consumer; opt in only when you need the
extra structure.

## TL;DR

| Concern              | v1 (default)                            | v2 (opt-in)                              |
| -------------------- | --------------------------------------- | ---------------------------------------- |
| Selection            | absent or `Accept-Version: 1`           | `Accept-Version: 2`                      |
| Validation error key | `error.details` — `%{field => [str]}`   | `error.errors` — `%{path => [violation]}` |
| Severity buckets     | only `errors`                           | `errors`, `warnings`, `infos`            |
| Path format          | flat field name                         | JSON Pointer (e.g. `/contributors/0/role`) |
| Per-violation shape  | bare string                             | `{severity, code, message, rule}`        |

Non-validation errors (`not_found`, `unauthorized`, `precondition_failed`
with structured `details`, etc.) are **unchanged** in v2 — their shape
already encodes structured fields, and the negotiation only reshapes
validation error envelopes.

## Selecting a version

Send the `Accept-Version` request header. The
`BarkparkWeb.Plugs.ErrorEnvelopeNegotiation` plug runs in every API
pipeline and assigns `:error_envelope_version` on the conn:

```http
POST /v1/data/mutate/production HTTP/1.1
Authorization: Bearer barkpark-dev-token
Content-Type: application/json
Accept-Version: 2
```

Whitespace around the value is tolerated. Any value that is not exactly
`2` (after trimming) falls back to `:v1`.

## Response shapes

### v1 (default — preserves existing TUI / curl workflows)

```json
{
  "error": {
    "code": "validation_failed",
    "message": "document failed validation",
    "details": {
      "type": ["can't be blank"],
      "title": ["can't be blank"]
    }
  }
}
```

### v2

```json
{
  "error": {
    "code": "validation_failed",
    "message": "document failed validation",
    "errors": {
      "/type": [
        {
          "severity": "error",
          "code": "required",
          "message": "Required",
          "rule": null
        }
      ],
      "/contributors/0/role": [
        {
          "severity": "error",
          "code": "type_mismatch",
          "message": "Expected string",
          "rule": null
        }
      ]
    },
    "warnings": {},
    "infos": {}
  }
}
```

## Violation shape

Each violation is `{severity, code, message, rule}`:

* `severity` — `"error" | "warning" | "info"`. Determines which top-level
  bucket the violation lands in.
* `code` — a registered code from `Barkpark.Content.ErrorCodes` (e.g.
  `"required"`, `"max_items"`, `"codelist_unknown"`). New codes carry a
  `since_version` so older clients can degrade gracefully.
* `message` — human-readable, ready to render. Localisation is a future
  concern; today it is always English.
* `rule` — the rule name that fired, or `null` for built-in field-level
  diagnostics.

Path keys use [JSON Pointer](https://datatracker.ietf.org/doc/html/rfc6901):
`/title`, `/contributors/0/role`, `/blurb/en`. The root of the document
is `/`.

## Registered codes (initial set)

| Code                        | Default severity | Notes                           |
| --------------------------- | ---------------- | ------------------------------- |
| `required`                  | error            | field is required               |
| `nilable_violation`         | error            | explicit nil rejected           |
| `one_of`                    | error            | none / multiple branches matched |
| `in_violation`              | error            | value not in allowed set        |
| `nonempty_violation`        | error            | empty list/string rejected      |
| `max_items`                 | error            | array length cap exceeded       |
| `checker_failed`            | error            | named checker rejected the value |
| `type_mismatch`             | error            | type predicate failed           |
| `codelist_unknown`          | error            | unknown codelist value          |
| `codelist_version_mismatch` | error            | wrong issue pinned              |
| `unknown_field`             | warning          | extra field not in schema       |

The full registry lives in `Barkpark.Content.ErrorCodes`. New codes are
additive — clients should treat unknown codes as a fallback to
`message`.

## Sunset timeline

v1 is **not** scheduled for removal. The minimum runway after v2 GA is
**one minor release**, but the actual sunset will be announced
explicitly — there are TUI and curl-based workflows that depend on the
v1 shape, and they need a coordinated migration. Until that
announcement lands in this document, treat v1 as permanent.

When sunset is scheduled, the rollout will be:

1. v2 becomes the default; v1 continues to work via `Accept-Version: 1`.
2. v1 starts emitting a `Deprecation` response header with a sunset
   date (RFC 8594 / RFC 9745 style).
3. v1 is removed; requests without `Accept-Version` get v2.

Each step is gated on the public Studio + TUI clients confirming they
have moved.

## Implementation pointers

* Module: `BarkparkWeb.ErrorEnvelope` (`serialize_v1/1`, `serialize_v2/1`).
  Accepts the WI1 `validation_result` map, the legacy
  `%{field => [string]}` map from `Barkpark.Content.Validation`, or a
  flat list of strings.
* Plug: `BarkparkWeb.Plugs.ErrorEnvelopeNegotiation` — wired into
  `:api`, `:api_unlimited`, and `:api_preview` pipelines.
* Controllers: today only `MutateController` reshapes its response
  body for v2 (and only for `validation_failed`). Other controllers
  pick up the negotiation assign automatically when they need it.
* Code registry: `Barkpark.Content.ErrorCodes` — compile-time map of
  atom code → `%{message_template, default_severity, since_version}`.

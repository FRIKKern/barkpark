# Barkpark CLI — Error-code ↔ Exit-code Table (M0 frozen)

> **Status:** DECIDED at M0. This is the single canonical mapping. The CLI maps the
> error envelope's `code` string — **never** re-derives an exit code from the HTTP
> status. (Contract spine rule #3: *one error↔exit table*.)

## How the mapping works

Every coded error from the Barkpark API arrives in the v1 envelope shape:

```json
{ "error": { "code": "<string>", "message": "<string>", "details": { … }, "request_id": "…" } }
```

The CLI reads `error.code` and looks it up in the table below to pick its process
exit code. The HTTP status is carried only on the response status line and is
recorded here for reference — **it is NOT the lookup key.** Two reasons this is
load-bearing:

1. The same HTTP status maps to multiple distinct `code`s (409 covers both
   `rev_mismatch` and `conflict`; 422 covers `validation_failed`,
   `invalid_paper`, `invalid_op`, and the dynamic patch-engine codes). The exit
   code distinguishes them; the status cannot.
2. A `code` is a stable contract string; a status can drift (e.g. a 412 added
   later for `precondition_failed`). Keying on `code` keeps the CLI stable.

When `error.code` is absent or unknown (see "Codes with no `error.code`" below),
the CLI falls back to **exit 1** (generic/unexpected).

## The stable exit-code scheme

> **Codes 0–5 are byte-identical in meaning to the published CLI handbook; 6–8 are
> purely ADDITIVE (the handbook did not enumerate conflict / rate-limit / server).
> No handbook code meaning is redefined.**

| Exit | Bucket | Meaning |
|---|---|---|
| `0` | success | Command completed. |
| `1` | generic / unexpected | Other / network / timeout; also the fallback for an unknown `code` or a no-`code` error shape. |
| `2` | usage / unknown command | Bad arguments, malformed request body, unknown command/sub-command. |
| `3` | auth / forbidden | Missing/invalid credential or insufficient permission. |
| `4` | not-found | Resource or schema does not exist. |
| `5` | validation | Document/payload failed schema or op validation (the message names the field). |
| `6` | conflict | Optimistic-concurrency / write-conflict / precondition failure (ADDITIVE). |
| `7` | rate-limited | Throttled; honor `Retry-After` (ADDITIVE). |
| `8` | server (5xx) | Server-side `internal_error` / 5xx fallthrough (ADDITIVE). |

The handbook (§29) enumerated only `0` success · `1` other/network/timeout · `2` usage/unknown
command · `3` auth · `4` not-found · `5` validation. This table keeps those six
EXACTLY and adds `6` (conflict), `7` (rate-limited), `8` (server) as a strict
superset — categories the handbook left folded into the generic bucket are now
broken out without redefining any handbook code.

## The canonical table

The `code` column is sourced **verbatim** from the API's real enumerated error
codes (`Barkpark.Content.Errors.build/1` plus the direct emitters). HTTP status
is the status the API actually returns for that code.

| `code` | HTTP status | Exit | Meaning | CLI message guidance |
|---|---|---|---|---|
| *(no error; success)* | 2xx | `0` | Command succeeded. | Print the result (or the minimal receipt on writes). |
| `not_found` | 404 | `4` | Resource (doc/media/task/etc.) does not exist. | `not found: <noun> <id>` — suggest `barkpark <noun> ls`. |
| `schema_unknown` | 404 | `4` | Named schema/type is not registered. | `unknown schema: <name>` — suggest `barkpark schema ls`. |
| `unauthorized` | 401 | `3` | Missing or invalid credential. | `authentication required` — suggest `barkpark login`. |
| `unauthorized` (+`reason:"replay"`) | 401 | `3` | Idempotency-key replay rejected. | `request replayed; retry with a fresh idempotency key`. |
| `forbidden` | 403 | `3` | Authenticated but lacks permission. | `forbidden: token lacks <tier> for this command`. |
| `cors_forbidden` | 403 | `3` | Origin not allowed (browser-origin path). | `origin not permitted` — rare from the CLI; treat as auth. |
| `csrf_required` | 403 | `3` | CSRF token missing (session-cookie path). | `csrf required` — rare from the CLI; treat as auth. |
| `malformed` | 400 | `2` | Request body/args were invalid. | `bad request: <message>` — name the offending arg. |
| `validation_failed` | 422 | `5` | Document failed schema validation. | `validation failed` — print `details`/`errors` field paths. |
| `invalid_paper` | 422 | `5` | Bulldocs paper payload invalid. | `invalid paper: <message>`. |
| `malformed_op` | 422 | `5` | Bulldocs block-op malformed. | `malformed op: <message>`. |
| `invalid_op` | 422 | `5` | Bulldocs/PortableDoc op rejected. | `invalid op: <message>`. |
| `block_not_found` | 422 | `5` | Patch target block id absent (dynamic). | `block not found: <block_id>`. |
| `type_mismatch` | 422 | `5` | Patch op type mismatch (dynamic). | `type mismatch in op`. |
| `duplicate_id` | 422 | `5` | Patch would create a duplicate block id (dynamic). | `duplicate id: <id>`. |
| `rev_mismatch` | 409 | `6` | Optimistic-concurrency revision mismatch. | `conflict: document changed; re-fetch and retry`. |
| `precondition_failed` | 412 | `6` | `ifRev` precondition failed (carries `expected`/`actual`). | `precondition failed: expected rev <e>, got <a>`. |
| `conflict` | 409 | `6` | Generic write conflict. | `conflict: <message>` — retry or re-fetch. |
| `share_expired` | 410 | `4` | Media collection share link expired/gone. | `share expired` — treat as gone (not-found bucket). |
| `rate_limited` | 429 | `7` | Throttled. | `rate limited; retry after <Retry-After>s`. |
| `rate_limited` (+`details.retry_after`) | 429 | `7` | Throttled with explicit retry hint. | Same; use `details.retry_after` for the backoff. |
| `internal_error` | 500 | `8` | Server-side failure. | `server error (<request_id>)` — surface `request_id` for support. |

## Codes that don't cleanly fit — proposed buckets

The reader enumeration found a handful of real wire shapes that are **not** the
canonical `{code, message}` object. The CLI must still produce a deterministic
exit code for them. Proposed mappings:

| Real shape | HTTP | Where | Proposed exit | Rationale |
|---|---|---|---|---|
| `{"error":"halted","reason":…}` | 409 | mutate / legacy / history lifecycle-veto | `6` (conflict) | `error` is a bare string, not a coded object — there is no `error.code`. A lifecycle veto is semantically a conflict (the write was refused), so bucket it as **6** (the additive conflict code). The CLI special-cases the literal string `"halted"` since the key is `error`, not `error.code`. |
| `{"ok":false,"reason":"invalid_edge",…}` | (tasks) | `tasks_controller` add-edge | `2` (validation) | Different schema entirely (`ok`/`reason`). It is a client-side validation failure on the edge payload → **2**. |
| `{"ok":false,"error":"not_found","id":…}` | (intents) | `bulldocs_intents_controller` | `4` (not-found) | `error` is a string `"not_found"`, not `error.code`. Map the string value to the same bucket as the canonical `not_found` → **4**. |
| plugin-settings bare strings: `"not_found"` | — | `plugin_settings_controller` | `4` | String-valued `error`; map `"not_found"` → **4**. |
| plugin-settings bare strings: `"invalid"`, `"settings_object_required"` | — | `plugin_settings_controller` | `2` | String-valued `error`; both are client-side validation → **2**. |
| `{"error":{"message":…}}` with **no `code`** | — | `search_controller`, `v1/media_controller` ("from and to are required", "synonym not found", "validation failed") | `2` (or `4` if the message is a not-found) | No `error.code` to key on. Default these to **2** (usage/validation); the CLI MAY downgrade to **4** when the message text is a recognizable not-found. Flagged as a server inconsistency to be normalized into the coded envelope later. |

> **Internal-only codes — NOT exit-mapped.** `"legacy"` and `"unknown"` appear as
> the `code` field *inside* a v2 validation *violation* object (the
> `errors`/`warnings`/`infos` tree), never as the top-level `error.code`. They are
> per-violation labels for display, not process-exit signals. The CLI uses the
> top-level `validation_failed` → exit `5` and renders these violation codes in the
> message body.

## Envelope-version note (does not change the table)

The v2 envelope (opt-in via `Accept-Version: 2`) only reshapes the
`validation_failed` **422** body — it swaps the flat `details` map for an
`errors`/`warnings`/`infos` JSON-pointer tree. The top-level `error.code` is
identical across versions, so the exit-code mapping above is version-invariant.
Every other code/status is byte-identical between v1 and v2.

## Schema field references

This document keys off the v1 error **envelope** (`error.code`, `error.message`,
`error.details`, `error.request_id`), which is the API wire contract — distinct
from the capabilities **manifest**. Where it touches the manifest, it uses the
frozen field names from `manifest.schema.json`: each command's required
`auth_tier` is what the CLI sends a credential for, and `dry_run: false` is why
`--dry-run` degrades to client-side request-printing (see `m0-decisions.md`).
The manifest's per-command `default_output: "minimal"` governs the receipt the
CLI prints on a successful (exit `0`) write.

<!-- doc-tier: agent | canonical-for: cli-error-exit-mapping | budget: 2500tok -->
# Barkpark CLI — Error-code ↔ Exit-code Table (M0 frozen)

> **Status:** DECIDED at M0. This is the single canonical mapping. For any CODED
> error the CLI maps the envelope's `code` string — **never** re-derives an exit
> code from the HTTP status. The ONE exception is a body with no decodable coded
> error at all (a non-JSON gateway/proxy page), where status is the only signal —
> see the fallback note below. (Contract spine rule #3: *one error↔exit table*.)

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
the CLI falls back to **exit 1** (generic/unexpected). The SOLE exception: a body
that decodes to no known error shape at all — a non-JSON gateway/proxy page (nginx
502·503·504 HTML, a plain-text load-balancer banner) — carries no `code`, so as a
last resort the CLI keys the bucket off the HTTP status (5xx→`8`, 429→`7`,
401/403→`3`, 404/410→`4`, other 4xx→`2`, else→`1`) and caps the raw body to ~200
chars so an HTML page never spews to stderr. A JSON envelope whose `code` is merely
unknown still falls to exit 1.

**Compound reason tokens.** The tasks API mints reasons that carry their detail
inline — `not_holder:<worker>`, `not_in_progress:<status>`, `criteria_unmet:<i,j>`,
`acknowledgement_unposted:<issue>`,
`invalid_lifecycle:<s>`, `sentinel_worker_id:<w>`. The CLI looks up the literal
token first, then the family name before the first `:` (`reasonKey` /
`lookupExit` in `internal/cli/errors.go`). This is a lookup on the reason STRING
only — it still never reads the HTTP status. `lookupExit` is the ONE consult, shared
by the coded envelope, the `{"ok":false,"reason":…}` shape and the bare-string
`{"error":"<token>"}` shape, so a token cannot mean two exit codes depending on
which envelope carried it.

**Retryability is what 5 vs 6 encodes** for the stamp/close family: `6` means the
world moved (re-read/re-claim, then retry); `5` means the request itself is wrong
and retrying it verbatim can never work. A wrapper that branches on the exit code
alone gets the right behaviour without parsing the message.

## The stable exit-code scheme

> **Codes 0–5 are byte-identical in meaning to the published CLI handbook; 6–8 are
> purely ADDITIVE (the handbook did not enumerate conflict / rate-limit / server).
> No handbook code meaning is redefined.**

| Exit | Bucket | Meaning |
|---|---|---|
| `0` | success | Command completed. |
| `1` | generic / unexpected | Other / network / timeout; the fallback for an unknown envelope `code`. (A non-JSON, no-`code` gateway body instead keys off HTTP status — see the fallback note.) |
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
| `forbidden_field` | 422 | `3` | Filter/order over a field the caller may not read. | `forbidden field: <field>` — use a token that can read it (keys on code, not the 422). |
| `malformed` | 400 | `2` | Request body/args were invalid. | `bad request: <message>` — name the offending arg. |
| `invalid_filter` | 400 | `2` | Unknown filter operator, or a `filter[<key>]` the route cannot honour (`GET /v1/tasks`). | `invalid filter operator: <op>` — print the valid set from the message. |
| `validation_failed` | 422 | `5` | Document failed schema validation. | `validation failed` — print `details`/`errors` field paths. |
| `invalid_paper` | 422 | `5` | Bulldocs paper payload invalid. | `invalid paper: <message>`. |
| `malformed_op` | 422 | `5` | Bulldocs block-op malformed. | `malformed op: <message>`. |
| `invalid_op` | 422 | `5` | Bulldocs/PortableDoc op rejected. | `invalid op: <message>`. |
| `block_not_found` | 422 | `5` | Patch target block id absent (dynamic). | `block not found: <block_id>`. |
| `type_mismatch` | 422 | `5` | Patch op type mismatch (dynamic). | `type mismatch in op`. |
| `duplicate_id` | 422 | `5` | Patch would create a duplicate block id (dynamic). | `duplicate id: <id>`. |
| `invalid_path` | 422 | `5` | Blob push rejected: the relative path failed the server-blob allowlist (traversal / absolute / malformed segment), refused before any disk write. | `invalid blob path: <path>` — the sidecar path must be the server-generated `YYYY/MM/<slug>-<hex8>.<ext>` shape. |
| `empty_body` | 422 | `5` | Blob push rejected: zero-byte body (commonly a mislabeled content-type that `Plug.Parsers` consumed). | `empty blob body` — send the raw bytes as `application/octet-stream`. |
| `rev_mismatch` | 409 | `6` | Optimistic-concurrency revision mismatch. | `conflict: document changed; re-fetch and retry`. |
| `precondition_failed` | 412 | `6` | `ifRev` precondition failed (carries `expected`/`actual`). | `precondition failed: expected rev <e>, got <a>`. |
| `conflict` | 409 | `6` | Generic write conflict. | `conflict: <message>` — retry or re-fetch. |
| `halted` | 409 | `6` | Plugin lifecycle veto (canonical envelope). | `halted: <message>` — the plugin's reason. The bare-string `{"error":"halted"}` shape is also handled (see below); both bucket to `6`. |
| `fenced_off` · `stale_claim` · `not_ready` · `blocked_by_unsatisfied_deps` · `resource_conflict` · `already_claimed`† | 409 | `6` | Task claim/close contention (`/v1/tasks/*` `ok:false` reasons). †`already_claimed` is a defensive CLI mapping (`internal/cli/errors.go`) for forward compatibility — the API does not currently emit it; the five confirmed server-side reasons are the other codes in this row. | Re-claim / re-fetch; `resource_conflict` carries `conflicts[]` naming the holders. |
| `not_holder` · `not_in_progress` | 409 | `6` | Stamp/close refused: the lease moved (another worker holds the claim) or the task left `in_progress`. The server mints these COMPOUND — `not_holder:<worker>`, `not_in_progress:<status>` (`tasks_controller/params.ex` `reason_to_string/1`); the CLI keys on the part before the first `:`. | `re-read with bp task get, re-claim under your worker id, then retry` — RETRYABLE. |
| `doc_changed_since_claim` · `claimed_has_worker` | 409 | `6` | The task's brief changed under your claim, or the claim is held by a named worker. | Re-read / reconcile, then retry (the CLI hint names the recovery). |
| `acknowledgement_unposted` | 409 | `5` | The task was born from an OUTSIDER's GitHub issue (`gh-<num>`) and its `ack_gate` acceptance criterion is unmet, so a `done`/`cancelled` close would end the row with the reporter never told. Mints compound as `acknowledgement_unposted:<issue>`. | Post the outcome on the issue and stamp the criterion with the comment URL — or `--set ack_override="<why the reporter is not being told>"`. NOT retryable as sent: nothing moved, and `criteria_override` does not discharge it. |
| `criteria_mismatch` · `criteria_index_out_of_range` · `criterion_text_required` · `note_required` | 409/422 | `5` | Stamp payload guards: the `--criterion-text` does not match the row at `--criterion N`, the index is off the end, a `--met` arrived without its text, or a `--miss` without a note. | `fix the flag and re-send` — NOT retryable as sent. |
| `illegal_transition` | 422 | `5` | A lifecycle stage the task cannot make from its current state (`tasks_controller.ex` `put_status(:unprocessable_entity)`). Also arrives as a BARE-STRING `{"error":"illegal_transition"}` from the cloud router; both shapes bucket to `5`. | `the transition is impossible from this state` — the one member of this family that a retry can NEVER satisfy. |
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

## The table above is a WORKED SUBSET — `codeExit` is the authority

The per-code table is hand-maintained and enumerates the codes worth explaining.
It is **not** the full vocabulary, and treating it as one is what broke this
contract once already: `internal/cli/errors.go` `codeExit` mirrored the table
rather than the API, so every code the API grew after the table was written
exited `1` (generic). Measured at the repair: **61 of the API's 81 public codes
had no bucket** — `mfa_required` (a 401) was indistinguishable from a network
timeout, and a script branching `if rc -eq 3; then bp login; fi` never fired.

Two rules keep it closed:

1. **`codeExit` must be a superset of `Barkpark.Content.Errors.known_codes/0`.**
   `TestCodeExitCoversKnownAPICodes` (`internal/cli/errors_api_parity_test.go`)
   parses the API source and fails when a code has neither a bucket nor a named
   exclusion. Adding a public code to the API without touching the CLI now reds.
2. **Bucket by the status the emitter actually returns**, never by the code's
   name: `400` → `2`, `401`/`403` → `3`, `404` → `4`, `409`/`412` → `6`,
   `402`/`413`/`422` → `5`, `429` → `7`, `5xx` → `8`. Two live codes read against
   this rule — `source_not_found` answers **422** (not 404) and
   `payload_too_large` answers **413** — and both follow the status, because
   bucketing on the name is the guesswork the table exists to end.

The "code, never status" rule at the top of `errors.go` is unchanged: the CLI
still reads only `error.code` at runtime. The status is what the *maintainer*
consults when choosing a bucket, once.

### Deliberate non-members

Two members of `known_codes/0` are excluded on purpose, listed with reasons in
`codeExitNotWireBucketable`. `hollow_paper` and `structure` are never a
top-level `error.code` at all — they are violation entries nested inside another
response's body.

The other exclusion kind is now **empty**, and that is the point. `export_failed`,
`invalid_mode` and `session_unavailable` were each emitted at **two different
statuses** with opposite retryability, so no exit code could be honest about
both arms — `8` would spin a retry wrapper forever on the permanent arm, `5`
would abandon a recoverable one. The API has since split each into one code per
arm, so all six carry a real bucket:

| Retired token | Retryable arm | Permanent arm |
|---|---|---|
| `export_failed` | `export_transport_failed` — 503, exit 8 | `export_build_failed` — 422, exit 5 |
| `session_unavailable` | `session_restarting` — 503 + `retry-after`, exit 8 | `session_start_failed` — 422, exit 5 |
| `invalid_mode` | *(neither arm is retryable)* `invalid_import_mode` — 422, exit 5 | `invalid_deploy_mode` — 400, exit 5 |

If this exclusion kind ever reappears, the fix belongs in the API — split the
token — not in a new entry here.

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

<!-- doc-tier: agent | canonical-for: bokbasen-wire-api-spec | budget: 9800tok -->
<!--
  Bokbasen wire-level API contract (Phase 7 WI1)
  Author: Worker_W2.1 (Task #1, Phase 7 WI1)
  Created: 2026-04-30
  Source-of-truth branch: doey/team-2-0430-1145 (off main 81adb84)
  Status: pinned contract — drives WI2 (credentials), WI3 (HTTP client), WI4 (Oban worker)
-->

# Bokbasen ingestion — wire-level API contract

> **Phase 7 WI1 deliverable.** This pins the HTTP-level contract Phase 7
> WI2–WI7 will implement against. All claims trace to a public Bokbasen
> source (URL + retrieval date) or are explicitly tagged as a
> Boss-escalation question in §9. No Elixir code is shipped in WI1.

All Confluence URLs accessed via the Confluence REST API
(`/wiki/rest/api/content/<id>?expand=body.storage`) on **2026-04-30**.
Page IDs are the canonical identifiers; human-readable URLs may rewrite.

---

## 1. Overview & scope

### 1.1 What this contract covers

The wire-level contract for **publishing one or more ONIX 3.0/3.1
products to Bokbasen's metadata import service**, including:

- OAuth2 client-credentials authentication (token acquisition + caching).
- The single-phase async ingestion POST (Onix Import V2).
- Status polling (per-item + list) until terminal state (`COMPLETED` /
  `FAILED`).
- Object Import for cover images and audio samples (separate endpoint,
  binary upload, synchronous 201).
- Error-envelope shape and HTTP status mapping.
- Rate-limit / retry / Retry-After semantics (best-known; one open
  question remains).

### 1.2 What this contract defers

| Deferred to | What |
|-------------|------|
| **Phase 7 WI2** | Credential plumbing: encrypted storage in the `plugin_settings` table + env-var fallback; this doc only specifies the *header format* the credential lands in. |
| **Phase 7 WI3** | The actual `Req`-based HTTP client module (function names, struct shapes, telemetry). This doc specifies the URLs, methods, headers, bodies, and error mapping; WI3 turns those into Elixir code. |
| **Phase 7 WI4** | Oban worker that orchestrates stage → poll → terminal-state and writes back to the publish-job row. This doc specifies the state machine; WI4 implements the worker. |
| **Phase 7 WI5–WI7** | Studio UI hooks, queue back-pressure, ops dashboard. |
| **Phase 8 / Task #12** | Bokbasen → barkpark *acknowledgement loop* (Bokbasen pushing back catalogue-entry confirmations). The Phase 7 flow stops at "Bokbasen says `COMPLETED`"; downstream "did the record actually land in DDS / surface to retailers" is a future task. |
| **Object Import** | Listed here for completeness because the contract is needed for the cover-image flow, but the WI4 worker is metadata-only — Object Import becomes its own WI in a later phase (it is not in Task #1's WI2–WI7 acceptance criteria). |

### 1.3 ⚠️ Important contract finding — re-framing "two-phase claim"

The Phase 7 task brief refers to a **two-phase claim** lifecycle. This
language does **not** match Bokbasen's actual public API. Bokbasen
exposes a **single-phase asynchronous ingestion** model:

> *"The Onix Import API allows clients to post a single Onix `Product`
> or multiple `Products` within an `ONIXMessage` for registration in
> the Bokbasen system. […] If posted data validates as Onix the client
> receives a "202 Accepted" response with a Location header pointing
> to a service where the client can retrieve the current status of the
> import request."* — Bokbasen Confluence, *Import Service*, page id
> 48955439, retrieved 2026-04-30.[^import]

There is **no separate `claim` / `confirm` step**, and no `abort`
endpoint. Once the synchronous POST returns `202 Accepted`, the record
is committed to the asynchronous queue; the only way to "abort" is to
let the record fail and either resubmit or `NotificationType=05`-delete
it. See §4 for how this maps onto the WI4 worker state machine.

The remaining "two-phase" semantics in the task brief should be read as:

- **Phase A (synchronous):** stage POST returns 202 + status URL.
- **Phase B (asynchronous):** poll the status URL until terminal state.

This is captured as **[blocking] Q-A** in §9 — Boss confirms whether
that re-framing is the intended Phase 7 acceptance criterion before
WI4 codes the state machine.

---

## 2. Auth

### 2.1 Decision

| Item | Pinned value | Source |
|---|---|---|
| Method | OAuth2 **`client_credentials`** flow | [Authentication Service][^auth] |
| Token endpoint (PROD) | `POST https://auth.bokbasen.io/oauth/token` | [^auth] |
| Token endpoint (TEST/sandbox) | `POST https://auth.stage.bokbasen.io/oauth/token` | [^auth] |
| Audience (metadata import) | `https://api.bokbasen.io/metadata/` | [^auth] [^import] |
| Request body content-type (preferred) | `application/x-www-form-urlencoded` (also accepts `application/json`, also accepts Basic-auth-encoded credentials) | [^auth] |
| Required body params | `client_id`, `client_secret`, `audience`, `grant_type=client_credentials` | [^auth] |
| Response | JSON: `{access_token, expires_in, token_type:"Bearer"}` | [^auth] |
| Authorization header on subsequent calls | `Authorization: Bearer <access_token>` | [^auth] [^import] |

> *"Each environment has it's own set of credentials. PROD
> https://auth.bokbasen.io/oauth/token TEST
> https://auth.stage.bokbasen.io/oauth/token"* — [^auth]

### 2.2 Caching

Bokbasen actively documents caching:

> *"We are optimizing when new tokens are generated and therefore you
> will see that `expires_in` will change dynamically through out the
> day. We are then serving you cached access_token while it is valid
> (we will not give you a token with less than 5 minutes left). […] If
> you want to reduce number of needed calls, we encourage you to cache
> it, just look at the `expires_in` (seconds) or look at `exp` in the
> payload-part of the JWT-token (right before you do the API-call)."* — [^auth]

**WI3 client must cache the bearer token** keyed by `(audience,
client_id)` and refresh at `exp - 60s`. Token lifetime is variable but
typically `expires_in: 86400` (24 h) per the published JWT
example.[^auth]

### 2.3 Credential plumbing (forward-reference WI2)

WI2 owns credential storage; this doc only fixes the **shape of the
secret** and the **env-var override names**. Implemented in the
`config :barkpark, :bokbasen` block of `api/config/runtime.exs` and in
`Barkpark.Plugins.OnixEdit.Bokbasen.Settings`.

**THERE IS NO DOTTED KEY.** `plugin_settings` is ONE row per plugin
(`@primary_key {:plugin_name, :string}`) whose `settings` field is a map, and
the whole map is Cloak-encrypted through `Barkpark.EncryptedMap`. So the row is
`plugin_name = "bokbasen"` and the map keys are the bare names below — there is
no `bokbasen.client_id` anywhere, and no per-key split between plain and
encrypted storage.

| Setting | key in the `"bokbasen"` settings map | Env override | Notes |
|---|---|---|---|
| Client ID | `client_id` | `BOKBASEN_CLIENT_ID` | Encrypted at rest with the rest of the map |
| Client secret | `client_secret` | `BOKBASEN_CLIENT_SECRET` | Encrypted at rest with the rest of the map |
| API base URL | `api_base` | `BOKBASEN_API_BASE` | Full base URL, e.g. `https://api.bokbasen.io` |
| OAuth token URL | `oauth_token_url` | `BOKBASEN_OAUTH_TOKEN_URL` | Full token endpoint URL |
| Client role | `client_role` | `BOKBASEN_CLIENT_ROLE` | `publisher` (default) or `distributor`; affects which Onix Blocks Bokbasen accepts |

> **Note re task-brief env-var names.** The brief lists
> `BOKBASEN_API_KEY` / `BOKBASEN_USERNAME` / `BOKBASEN_PASSWORD`. Those
> match the **legacy** Bokbasen TGT auth flow used by the
> `Bokbasen/php-sdk-auth` repo (`POST https://login.boknett.no/v1/tickets`
> with form-encoded `username` + `password`, response header
> `Boknett-TGT: …`).[^php-auth] The current public docs explicitly
> deprecate that:
>
> > *"Change to how Authorization-header is constructed. No longer
> > use `Authorization: Boknett TGT-...` Instead use:
> > `Authorization: Bearer <access_token_here>`"* — [^auth]
>
> WI1 pins **OAuth2 client_credentials**, not username/password.
> Env-var names follow the OAuth2 vocabulary
> (`BOKBASEN_CLIENT_ID` / `BOKBASEN_CLIENT_SECRET`), not API-key /
> username/password. This is a **deviation from the task-brief env-var
> hint** and is tagged as **[non-blocking] Q-B** in §9.

---

## 3. Endpoints

All endpoints accessed at base host `https://api.bokbasen.io` (PROD).
Sandbox base host is **OPEN — see §9 Q-C**.

| Name | Method | Path | Content-Type (req.) | Required headers | Body shape | Response shape | Notes |
|---|---|---|---|---|---|---|---|
| **Token (auth)** | POST | `https://auth.bokbasen.io/oauth/token` | `application/x-www-form-urlencoded` *or* `application/json` | (none) | Form: `client_id`, `client_secret`, `audience`, `grant_type=client_credentials` | JSON `{access_token,expires_in,token_type}` | Returns `200 OK` / `401` / `403`. [^auth] |
| **Stage (V2 — preferred)** | POST | `/metadata/import/onix/v2` | `application/xml` | `Authorization: Bearer …` | Raw ONIX XML — accepts a `<Product>` element *or* a full `<ONIXMessage>` with one or more `<Product>` children. ONIX 3.0.x or 3.1.x. **No multipart, no gzip in public docs.** | `202 Accepted` (no body) + `Location: https://api.bokbasen.io/metadata/import/onix/v2/status/<uuid>`. On `400` returns error XML (see §5). | Audience must be `https://api.bokbasen.io/metadata/`. [^import] |
| **Stage (V1 — legacy)** | POST | `/metadata/import/onix/v1` | `application/xml` | `Authorization: Bearer …` | Raw ONIX XML — **single peeled `<Product>` element only**, no `<ONIXMessage>` wrapper, no `<Header>`. ONIX 3.0.x. | `202 Accepted` (no body) + `Location: https://api.bokbasen.io/metadata/import/onix/v1/status/<uuid>`. | The barkpark Phase 6 export currently emits a full `<ONIXMessage>`, so V2 is the natural fit. [^import] |
| **Status (poll one)** | GET | `/metadata/import/onix/v1/status/{uuid}` *(see §3.1 on V2 path)* | — | `Authorization: Bearer …` | (none) | XML `<importItem>` with `<id>`, `<registered>`, `<state>`, optional `<errors>`, `<warnings>`, `<actionsCompleted>`. State ∈ `{UNPROCESSED, COMPLETED, FAILED}`. | `200 OK` / `400` / `401` / `403` / `500`. [^import] |
| **Status (list all)** | GET | `/metadata/import/onix/v1/status/all` | — | `Authorization: Bearer …` | (none) | XML list of `<importItem>` summaries (`<id>`, `<url>`, `<registered>`, `<state>`). | `200 OK` / `400` / `401` / `403` / `500`. [^import] |
| **Object import (cover/audio)** | POST | `/metadata/import/object/v1/{ean}/{type}` | `image/jpeg` \| `image/png` \| `audio/mpeg` (per `{type}`) | `Authorization: Bearer …` | Binary file content. **≤ 10 MB.** | `201 Created` (no body) on success; XML on validation error. | `{type}` ∈ `productimage` (jpeg/png) or `audiosample` (mp3). [^import] |

### 3.1 Status path notes

The V2 stage endpoint *returns* a Location header pointing at
`/metadata/import/onix/v2/status/<uuid>`[^import]:

```
HTTP/1.1 202 Accepted
Location: https://api.bokbasen.io/metadata/import/onix/v2/status/b64555a0-1d4b-472c-91e5-461a034a8fde
```

…but the public docs only spec the **status response shape** under the
V1 path (`/metadata/import/onix/v1/status/{uuid}`). The V2-mounted
status URL is presumed to return the same XML schema. This is **[non-blocking]
Q-D** in §9. Action for WI3: **always read the URL from the `Location`
header verbatim**, never construct a status URL by string-templating
the version segment.

### 3.2 Idempotency

Bokbasen's public docs do **not** spec an `Idempotency-Key` header.
Record-level idempotency is provided implicitly by ONIX
`<RecordReference>` plus `<NotificationType>`:

- A duplicate POST with the same `<RecordReference>` and updated
  content overwrites the prior record (semantics defined per Onix Block
  in [^import] §"Deletion of data").
- `<NotificationType>05` ("delete this record") is the explicit delete
  path — there is no separate DELETE endpoint.

WI4 worker idempotency strategy: deduplicate at the **publish-job**
layer (one Oban job per `(book_id, attempt)`); rely on Bokbasen to
overwrite a republished record by `<RecordReference>` if the worker
retries after a network blip. This avoids needing a Bokbasen-side
idempotency key. Tagged **[non-blocking] Q-E** in §9 for confirmation.

---

## 4. Lifecycle (re-framed two-phase)

### 4.1 State machine

```
                   ┌────────────────────────────────────────┐
                   │                                        │
                   │  WI4 Oban worker — per publish-job     │
                   │                                        │
                   └────────────────────────────────────────┘

   PENDING ──[render ONIX XML]──▶ READY_TO_STAGE
                                         │
                                         │ POST /metadata/import/onix/v2
                                         ▼
                          ┌──────────────────────────────┐
                          │ HTTP 202 Accepted            │
                          │ Location: …/status/<uuid>    │
                          └──────────────────────────────┘
                                         │
                                         │  persist <uuid> + status URL
                                         │  on the publish-job row
                                         ▼
                                    STAGED
                                         │
                                         │ schedule poll (initial delay 5s,
                                         │ exp. backoff capped at 60s; see §6)
                                         ▼
                                  ┌─────────────┐
                          GET ───▶│ POLL_STATE  │◀── reschedule if still
                                  └─────────────┘    UNPROCESSED
                                    │  │   │
        ┌───────────────────────────┘  │   └─────────────────────────┐
        │                              │                             │
        │ state=COMPLETED              │ state=FAILED                │ no terminal
        │                              │                             │ within budget
        ▼                              ▼                             ▼
  ┌───────────┐                  ┌──────────┐                ┌────────────────┐
  │ COMPLETED │                  │  FAILED  │                │ TIMEOUT        │
  │ + actions │                  │ + errors │                │ (operator      │
  │ Imported  │                  │ + warns  │                │  intervention) │
  └───────────┘                  └──────────┘                └────────────────┘
        │                              │                             │
        ▼                              ▼                             ▼
  publish-job:                   publish-job:                   publish-job:
  status=published               status=rejected                status=stuck
  bokbasen_id=<uuid>             bokbasen_errors=[…]            requires manual
                                                                 status check
```

### 4.2 Transitions in detail

| Transition | Trigger | Side effects |
|---|---|---|
| `PENDING → READY_TO_STAGE` | Worker pulled job; renders ONIX XML via `Barkpark.Plugins.OnixEdit.Export.to_iodata/1` (which gates on XSD validation before returning `{:ok, iodata}`). | Validate locally against vendored XSD before any network call. If local validation fails, transition straight to `FAILED` with `error_source: "local_xsd"` — never POST a known-invalid file. |
| `READY_TO_STAGE → STAGED` | `POST /metadata/import/onix/v2` returns `202`. | Persist `(bokbasen_status_url, bokbasen_uuid, staged_at)` on the publish-job row. |
| `READY_TO_STAGE → FAILED` (sync) | Stage POST returns `400` (XML errors envelope) or `401`. | Persist parsed `<error>` entries. `401` triggers token refresh + one retry. |
| `STAGED → POLL_STATE` | Oban schedule fires. | None. |
| `POLL_STATE → STAGED` (re-armed) | GET status returns `<state>UNPROCESSED</state>`. | Reschedule next poll per backoff schedule. |
| `POLL_STATE → COMPLETED` | GET status returns `<state>COMPLETED</state>`. | Record `actionsCompleted` (which Onix Blocks were imported); broadcast a Phoenix PubSub event so Studio's publish dashboard can react in real time. |
| `POLL_STATE → FAILED` (async) | GET status returns `<state>FAILED</state>`. | Record `<errors>` and `<warnings>`. Do *not* auto-retry — Bokbasen explicitly says: *"A Product that is FAILED will not be acted upon by Bokbasen. It is the Senders responsibility to act upon FAILED Products and resubmit the Product with valid data."*[^import] |
| `* → TIMEOUT` | Total elapsed exceeds polling budget (proposed: 30 min). | Job ends in `stuck`; operator runs the status-list endpoint to recover. |

### 4.3 No abort, no claim

There is **no abort/cancel endpoint** on the import service. To "undo"
a published record, the publisher submits a fresh ONIX message with
`<NotificationType>05</NotificationType>`:

> *"05 = 'delete this record' (record MUST be deleted on receipt)"*

There is also **no separate claim/confirm step**. The 202 response *is*
the commit; the async work is purely catalogue ingestion.

### 4.4 Expiry / staleness

Bokbasen's public docs do **not** publish an expiry on the
`status/{uuid}` URL. The status-list endpoint (`/status/all`)[^import]
strongly implies status records are retained at least long enough for
operators to see all currently-`UNPROCESSED` items, but the retention
window is undocumented. Treated as **[non-blocking] Q-F** in §9; WI4
will use a 30-minute polling budget by default and surface stuck jobs
to ops.

---

## 5. Error semantics

### 5.1 Status-code → error-class mapping

| HTTP | Class | Source endpoint(s) | WI4 handling |
|------|-------|-------------------|---------------|
| `200 OK` | success | status endpoints | Parse `<importItem>`. |
| `201 Created` | success | object import | No body. |
| `202 Accepted` | success (async) | stage V1, V2 | Read `Location` header; persist UUID; schedule poll. |
| `400 Bad Request` | **validation error (terminal)** | stage V1, V2; object import | Parse error-XML envelope (§5.2); transition publish-job to `rejected`. **Do not retry.** |
| `401 Unauthorized` | auth | all | Refresh OAuth2 token (§2.2); retry **once**. If still `401`, mark job `auth_error` and alert ops. |
| `403 Forbidden` | auth/scope | status endpoints | Wrong audience, no permission for the resource. Mark job `auth_error`; do not retry. |
| `413 Payload Too Large` | size | (export only — listed for completeness)[^export] | Not expected on import; log + alert if seen. |
| `500 Internal Server Error` | transient | stage V1, V2; status endpoints | Retry with exponential backoff (§6). |
| `502 / 503 / 504` | transient | (inferred from typical Bokbasen Apache-Coyote frontend in `Via:` headers — see [^import] sample bodies) | Retry with backoff. |
| `429 Too Many Requests` | rate-limited | **OPEN** — see §6.2 + §9 Q-G | If `Retry-After` present, honour it; else exponential backoff. |

### 5.2 Sample error envelope (V1, real, quoted)

The Confluence "Import Service" page documents the V1 400 body
schema verbatim[^import]:

```xml
<errors>
  <error ref="..." code="..." message="..."/>
  <error ref="..." code="..." message="..."/>
</errors>
```

Element / attribute meaning (verbatim):

> *"`errors` Top element, can contain multiple `error` elements. […]
> `ref` Internal error reference. Include this if you are contacting
> Bokbasen about this error. […] `code` Error code used to categorize
> errors. […] `message` Error message in clear text"* — [^import]

The V2 documentation is currently marked *"documentation in
progress.."* on the Confluence page; the V2 envelope shape is **assumed
identical to V1** (Bokbasen has not stated otherwise) but this is
flagged as **[non-blocking] Q-H** in §9. WI3 will parse V1 and V2
errors with the same code path.

### 5.3 Sample status-detail body (real, quoted)

V1 status detail, `COMPLETED` with a warning, verbatim Confluence
example[^import]:

```xml
<importItem>
  <id>a47ad10b-58cc-4372-a567-0e2342c3d479</id>
  <registered>20140907233000</registered>
  <state>COMPLETED</state>
  <warnings>
    <warning ref="xxx" message="Some warning text"/>
  </warnings>
  <actionsCompleted>
    <action type="onixBlockImported" value="1"/>
    <action type="onixBlockImported" value="4"/>
  </actionsCompleted>
</importItem>
```

> *"`action.type` Type of action that is completed. Currently the only
> possible value is `onixBlockImported`. […] `action.value` Value
> related to the specific action type. For action.type
> `onixBlockImported` the possible values are 1-6."* — [^import]

The barkpark Phase 6 export currently emits Blocks 1, 2, 4, and 6
(DescriptiveDetail, CollateralDetail, PublishingDetail, ProductSupply); a
successful `COMPLETED` should therefore enumerate `value="1"`/`"2"`/`"4"`/`"6"`,
modulo the per-sender-role filtering rule documented in [^import]
§"Onix Blocks". WI4 should *log* the imported blocks and surface them
in the publish-job audit trail; missing blocks are not an error.

### 5.4 Sample status-list body (real, quoted, illustrative)

V1 status list[^import]:

```xml
<importItems>
  <importItem>
    <id>2b6eea56-f448-4210-a1d3-2dd49479567d</id>
    <url>https://api.bokbasen.io/metadata/import/onix/v1/status/2b6eea56-f448-4210-a1d3-2dd49479567d</url>
    <registered>20141002101349</registered>
    <state>UNPROCESSED</state>
  </importItem>
  <importItem>
    <id>b64555a0-1d4b-472c-91e5-461a034a8fde</id>
    <url>https://api.bokbasen.io/metadata/import/onix/v1/status/b64555a0-1d4b-472c-91e5-461a034a8fde</url>
    <registered>20141002142426</registered>
    <state>UNPROCESSED</state>
  </importItem>
</importItems>
```

`<registered>` is in `yyyyMMddHHmmss` (no timezone — assumed
Europe/Oslo per Bokbasen's locale; flagged **[non-blocking] Q-I** in
§9).

---

## 6. Rate limits & retry policy

### 6.1 What the public docs say

Bokbasen's public Confluence pages **do not document a rate-limit
policy** for the metadata import endpoints. The most explicit
operational guidance is on the *export* side, where `413 Try with a
smaller pagesize` is documented[^export] — that is a *payload-size*
hint, not a request-rate limit, and only applies to export.

There is no documented:

- `X-RateLimit-Remaining` / `X-RateLimit-Reset` header
- `Retry-After` header (neither documented nor forbidden)
- requests-per-minute ceiling
- concurrent-uploads ceiling

This is captured as **[blocking] Q-G** in §9 — the WI4 Oban worker
needs *some* rate to throttle to, even if Bokbasen's silent on the
matter, so Boss must either (a) get a number from a Bokbasen partner
contact, or (b) sign off on the proposed conservative defaults below.

### 6.2 Proposed conservative retry policy

Until §9 Q-G resolves, WI3 should pin Req's retry mode to `:transient`
with the following parameters. All claims here are *engineering
defaults*, not Bokbasen-quoted numbers — they are explicitly safe
under-shoots.

```elixir
# Pseudocode for WI3 — illustrative, not for paste
Req.new(
  retry: :transient,                # retry on network errors + 408/429/5xx
  max_retries: 5,                   # 5 attempts ≈ ~62s ceiling at 2^n
  retry_delay: fn attempt ->
    base_ms = min(60_000, :math.pow(2, attempt) * 1_000 |> trunc())
    jitter_ms = :rand.uniform(div(base_ms, 4))   # up to 25% jitter
    base_ms + jitter_ms
  end,
  retry_log_level: :warning
)
```

Backoff math (per attempt index, before jitter):

| attempt | delay (s) |
|---:|---:|
| 1 | 2 |
| 2 | 4 |
| 3 | 8 |
| 4 | 16 |
| 5 | 32 |
| ≥6 | 60 (cap) |

Honour `Retry-After` if present (Req does this automatically in
`:transient` mode for 429 responses; this is built into Req
0.5.x[^req-retry]). Cap total retry budget at **5 minutes** per HTTP
call — anything longer must surface to ops.

Status-poll cadence (orthogonal to HTTP retry — this is *intra-job*
polling, not retry of a failed call):

| poll # | delay since previous |
|---:|---:|
| 1 | 5 s after 202 |
| 2 | 5 s |
| 3 | 10 s |
| 4 | 20 s |
| 5+ | 60 s (cap) |

Total polling budget: 30 minutes (matches `* → TIMEOUT` rule in §4.1).

### 6.3 Concurrency

WI4 Oban worker queue **`:bokbasen`** with concurrency = **4** — the
`bokbasen: 4` entry in the `config :barkpark, Oban` queues list in
`api/config/config.exs`, and `queue: :bokbasen` on
`Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker`. This is the
implemented default; adjusting it requires either a quoted Bokbasen
ceiling or Boss sign-off.

---

## 7. HTTP client decision: Req

### 7.1 Decision

**Pinned: `Req`.** The dep has since been bumped past the `~> 0.5` this
contract was drafted against — `api/mix.exs` now carries:

```elixir
{:req, "~> 0.6.1"},
```

resolving to 0.6.3 in `api/mix.lock`. Note `~> 0.5` would NOT have resolved a
0.6.x release, so the "a newer 0.5.x patch is picked up at `mix deps.update`"
reasoning below no longer describes how this dep moves. WI1 does **not** add a
Mix dep — the dep is already present and was introduced in Phase 6. Read the
0.5.x figures in the rest of §7 and in the footnotes as historical.

> *"Req is a batteries-included HTTP client for Elixir. It provides
> automatic response body decompression & decoding, following
> redirects, retrying on errors, and much more."* — [Req README, accessed 2026-04-30][^req-hex]

### 7.2 Why Req

| Need | Req | Comment |
|---|---|---|
| Retry on transient errors | `retry: :transient` built-in[^req-retry] | Honors `Retry-After` automatically; backoff via `retry_delay` lambda |
| `application/xml` body | Pass `body: iodata`, set `Content-Type` header | Matches Bokbasen V1/V2 stage payload exactly |
| OAuth2 bearer header | `auth: {:bearer, token}` shorthand[^req-readme] | Plumbs token without manual header juggling |
| Streaming (object import 10 MB) | `Req.post!(url, body: file_stream)` accepts iodata or `Stream` | Works for ≤10 MB cover uploads |
| Already in tree | yes | Phase 6 already shipped Req as a transitive dep; WI1 keeps the choice consistent |

### 7.3 Alternatives considered

| Library | Why not |
|---|---|
| **Finch (raw)** | Lower-level — would force WI3 to hand-roll retry, redirect, decoding, content-type defaults. Req sits on top of Finch already, so we get Finch's pool benefits without re-implementing the ergonomics. |
| **HTTPoison** | Maintenance mode; no first-class `Retry-After` support; older hackney transport. No reason to introduce it alongside Req. |
| **Tesla** | Middleware-stack model is heavier than needed for two endpoints; adds a 2nd HTTP abstraction to a project that already has Req. |
| **Mint (raw)** | Same argument as Finch: too low-level for an integration that needs retry + auth refresh out of the box. |

### 7.4 Pinned version & dep line

```elixir
# api/mix.exs (WI1 makes no mix.exs edit — but the dep HAS moved since):
# {:req, "~> 0.6.1"},        # was "~> 0.5" when this contract was drafted
#
# The "latest stable 0.5.17, verified 2026-04-30" figure below it is historical.
# Re-read api/mix.exs and api/mix.lock rather than trusting a pin quoted here.
```

---

## 8. Test mocking decision: Bypass

### 8.1 Decision

**Pinned: `Bypass` ~> 2.1 (latest stable: 2.1.0).**[^bypass-hex]

`Bypass` is now a test dep in `api/mix.exs` (added since this contract
was drafted — it landed with WI3):

```elixir
# api/mix.exs:
{:bypass, "~> 2.1", only: :test},
```

WI1 did not add this dep — that was WI3's job.

### 8.2 Why Bypass

- **In-process Plug-based mock server.** Tests can `start_supervised`
  a Bypass instance, register `expect`-style handlers per route, and
  drive the real `Req` client at it. No external service.
- **Compatible with Phoenix's existing test stack** — bandit + plug
  are already in the tree.
- **Zero Mox required for the integration tests.** The HTTP boundary
  is mocked at the *socket*, so the WI3 client module under test runs
  unmocked — gives us higher fidelity than function-level mocks.
- **Recorded golden-path fixtures** can live alongside Bypass tests
  without any extra runtime: tests load XML fixtures from
  `api/test/fixtures/bokbasen/` and the Bypass handler simply
  echoes them. ExVCR (cassette-based playback) is **not** needed
  because Bokbasen's responses are deterministic per
  `<RecordReference>` + `<NotificationType>` and Phase 6 already has
  golden ONIX fixtures.

### 8.3 Fixture layout

> **Note:** WI3 shipped a flat layout instead of the subdirectory tree
> originally proposed here. The actual directory matches what the
> "How to test" section documents below.

```
api/test/fixtures/bokbasen/
├── oauth_token_response.json     # 200 OK token JSON (synthetic credentials)
├── stage_202_location.txt        # 202 Location header value
├── poll_pending.xml              # state=UNPROCESSED
├── poll_accepted.xml             # state=COMPLETED
├── poll_rejected.xml             # state=FAILED
├── error_401.json                # 401 Unauthorized
├── error_429.json                # 429 Too Many Requests
└── error_500.json                # 500 Internal Server Error
```

### 8.4 Alternatives considered

| Library | Why not |
|---|---|
| **Mox** | Function-level mocking — would require defining a behaviour for the WI3 client and substituting a stub in tests. That moves the mock seam *above* the HTTP layer, missing the very integration risks (header serialization, status-code parsing, error-XML decode) that WI1 needs to harden. Useful if/when WI3 grows internal collaborators worth mocking, but not for the primary HTTP contract test. |
| **ExVCR** | Cassette-based replay. Strong choice for *recording* real Bokbasen interactions, but: (1) no sandbox credentials available yet (§9 Q-C), (2) cassettes go stale silently, (3) we don't get error-injection control (Bypass lets each test return any HTTP status). Re-evaluate once sandbox creds land — at that point ExVCR could *complement* Bypass for one or two recorded golden-path tests. |
| **Hand-rolled `Plug.Test` server** | Re-implements Bypass. No reason to. |
| **Tesla mock adapter** | We're not using Tesla. |

---

## 9. Open questions for Boss

Each entry tagged `[blocking]` (must resolve before WI4 codes) or
`[non-blocking]` (WI4 ships with a documented assumption; resolution
becomes a follow-up). All cross-link the relevant contract section.

### 9.1 Blocking

- **[blocking] Q-A — "two-phase claim" re-framing.** The task brief
  uses the phrase "two-phase claim". Bokbasen's actual API is a
  single-phase async-poll model (§1.3). Confirm the WI4 worker should
  implement *Phase A = stage POST, Phase B = poll-until-terminal* and
  that there is no expectation of a separate Bokbasen-side "claim"
  step. Without this confirmation, WI4 cannot pin its Oban state
  machine.
- **[blocking] Q-C — Sandbox credential availability.** §2.1 confirms
  a sandbox auth endpoint (`https://auth.stage.bokbasen.io/oauth/token`)
  exists. The corresponding **metadata import sandbox base URL** is
  *not* in public docs — `https://api.stage.bokbasen.io/metadata/`
  is the obvious mirror but is not stated. We also need real
  `client_id` / `client_secret` for the sandbox. This blocks WI3
  integration tests from running against a live mock host (Bypass
  covers unit tests; sandbox covers smoke tests).
- **~~[blocking]~~ Q-G — Rate limits. ANSWERED IN CODE; no longer blocking.**
  Bokbasen publishes no documented rate limit for metadata imports (§6.1), and
  the shipped `Bokbasen.Client` says so in its own `## Rate limit (Q-G)`
  moduledoc: it relies on Bokbasen's `429 + Retry-After` plus an optional
  per-request floor (`BOKBASEN_RATE_LIMIT_MS` env var / `:bokbasen_rate_limit_ms`
  app env, default 0). Note the parenthetical below was wrong on its own terms:
  the queue concurrency is **4** (§6.3), never 1.
- **~~[blocking]~~ Q-J — Onix Block matrix for barkpark's sender role.
  ANSWERED IN CODE; no longer blocking.** Bokbasen scopes import permissions
  per sender role.[^import] `Settings.default_client_role/0` records the
  decision verbatim — *"Default `client_role` per Phase 7 plan (Q-J):
  Barkpark = Publisher"* — and the client sends the publisher block set by
  default, overridable per request via `:onix_block_access`.

### 9.2 Non-blocking

- **[non-blocking] Q-B — Env-var naming deviation.** Task brief
  hints `BOKBASEN_API_KEY` / `BOKBASEN_USERNAME` / `BOKBASEN_PASSWORD`;
  this contract pins the OAuth2 vocabulary
  `BOKBASEN_CLIENT_ID` / `BOKBASEN_CLIENT_SECRET`. Boss confirms the
  rename is acceptable (it is the wire protocol's vocabulary).
  Default WI2 ships with the OAuth2 names.
- **[non-blocking] Q-D — V2 status path schema.** The V2 stage
  endpoint returns a Location header at `…/onix/v2/status/<uuid>`,
  but only the V1 path's status-response schema is documented. WI3
  will assume V1 == V2 schema and read the URL verbatim from the
  Location header (§3.1).
- **[non-blocking] Q-E — Idempotency-key support.** No documented
  `Idempotency-Key` header (§3.2). WI4 dedupes at the publish-job
  layer and relies on `<RecordReference>`-based overwrite. Confirm
  this is acceptable end-state behaviour (no risk of double-publish
  events flowing to retailers).
- **[non-blocking] Q-F — Status URL retention.** Bokbasen does not
  publish how long `…/status/<uuid>` URLs remain queryable (§4.4).
  WI4 uses a 30-min polling budget; long-lived monitoring assumes
  list-endpoint scrape.
- **[non-blocking] Q-H — V2 error envelope shape.** Confluence labels
  V2 docs *"in progress.."*; V1 envelope is documented. WI3 assumes
  V1 == V2 and parses both with one code path; revisit if a real V2
  body diverges.
- **[non-blocking] Q-I — Status `<registered>` timezone.** Format is
  `yyyyMMddHHmmss` (no offset); assumed Europe/Oslo per Bokbasen
  locale. WI4 normalises to UTC on persist; flag if drift observed.
- **[non-blocking] Q-K — Object Import ownership.** Object Import
  (cover image / audio sample) is in the contract for completeness
  but not in WI4's metadata-only scope. Confirm cover uploads land
  in a later WI/phase, not bolted onto WI4.
- **[non-blocking] Q-L — V1 vs V2 endpoint preference.** Both V1
  and V2 are live; V2 accepts the existing `<ONIXMessage>` wrapper
  barkpark already emits, V1 requires a peeled `<Product>` element.
  WI3 should default to V2; confirm Boss has no Bokbasen-side
  preference.

---

## How to test

The Phase 7 deliverables ship with a tagged end-to-end integration test
that drives the full publishing pipeline against a [Bypass][^bypass-hex]
HTTP mock. The test is the executable, version-controlled counterpart
to this contract — it confirms WI2/WI3/WI4 production code parses the
exact response shapes documented above.

### File layout

- **Test:** `api/test/barkpark/plugins/onixedit/bokbasen/e2e_test.exs`
- **Redacted fixtures:** `api/test/fixtures/bokbasen/`
  - `oauth_token_response.json` — OAuth2 client_credentials token reply
    (synthetic `test_access_token_xyz`, see §2.2).
  - `stage_202_location.txt` — 202 `Location` header value the worker
    parses to recover `submission_id` + `poll_url` (see §3.1).
  - `poll_pending.xml` / `poll_accepted.xml` / `poll_rejected.xml` —
    XML poll-status fixtures with `<state>UNPROCESSED</state>` /
    `<state>COMPLETED</state>` / `<state>FAILED</state>` (see §5.3; §3.2 is
    *Idempotency*).
  - `error_401.json` / `error_429.json` / `error_500.json` — error
    envelopes the WI3 `Errors` module surfaces as `AuthError`,
    `RateLimitError`, `HTTPError`.

All fixture credentials are synthetic — `test_*` prefixes,
`api.example.com` URLs, no real bearer tokens, no real submission IDs.
The fixture filenames + shapes are CI-stable; treat them as the
contract's executable annex.

### Default `mix test` excludes the suite

The suite is tagged `@moduletag :bokbasen_integration` and excluded by
default via `api/test/test_helper.exs` so CI's standard `mix test`
invocation stays free of any external-shape fixtures and cannot leak
real credentials. The `format` and `mix-prod-compile` gates run
unaffected.

### Run the integration suite locally

```bash
cd api
mix test --include bokbasen_integration
```

To run only the Bokbasen E2E test:

```bash
cd api
mix test --include bokbasen_integration \
  test/barkpark/plugins/onixedit/bokbasen/e2e_test.exs
```

### Run against the real Bokbasen sandbox

Set the five env vars (see §2.1 *Decision* for the published URLs — §2.2 is
*Caching*, not *Authentication*) and clear the test-only stub:

```bash
export BOKBASEN_API_BASE="<api base from §2.2>"
export BOKBASEN_OAUTH_TOKEN_URL="<token endpoint from §2.2>"
export BOKBASEN_CLIENT_ID="<sandbox client id>"
export BOKBASEN_CLIENT_SECRET="<sandbox client secret>"
export BOKBASEN_CLIENT_ROLE="publisher"

cd api && mix run priv/scripts/publish_demo.exs   # if/when added
```

The integration test itself **never** reaches a real Bokbasen endpoint;
it only exercises the local Bypass mock against the redacted fixtures.

---

## Footnotes / sources

[^import]: Bokbasen Confluence — *Import Service*, page id 48955439.
  Retrieved via `https://bokbasen.jira.com/wiki/rest/api/content/48955439?expand=body.storage`
  on **2026-04-30**. Human URL:
  https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service

[^auth]: Bokbasen Confluence — *Authentication Service*, page id 2994962433.
  Retrieved via REST API on **2026-04-30**. Human URL:
  https://bokbasen.jira.com/wiki/spaces/api/pages/2994962433/Authentication+Service

[^export]: Bokbasen Confluence — *ONIX*, page id 67993632. Documents
  the export endpoint with the `413 Try with a smaller pagesize`
  language. Retrieved 2026-04-30. Human URL:
  https://bokbasen.jira.com/wiki/spaces/api/pages/67993632/ONIX

[^php-auth]: Bokbasen GitHub — *php-sdk-auth*, file `src/Auth/Login.php`.
  Source verifies the legacy TGT auth flow (`POST
  https://login.boknett.no/v1/tickets`, header
  `Boknett-TGT`) that the modern OAuth2 endpoint replaces. Retrieved
  2026-04-30 via
  https://raw.githubusercontent.com/Bokbasen/php-sdk-auth/master/src/Auth/Login.php

[^req-hex]: Hex.pm package metadata for `req` — `latest_stable_version: 0.5.17`,
  total downloads ~12 M. Verified 2026-04-30 via
  https://hex.pm/api/packages/req

[^req-readme]: Req README on hexdocs — https://hexdocs.pm/req/readme.html
  retrieved 2026-04-30. Documents `auth: {:bearer, token}` shorthand
  and `:transient` retry mode.

[^req-retry]: Req docs — `Req` `:retry` option `:transient` mode
  retries on `408/429/500/502/503/504` and honors `Retry-After`.
  https://hexdocs.pm/req/Req.Steps.html#retry/1 retrieved 2026-04-30.

[^bypass-hex]: Hex.pm package metadata for `bypass` — `latest_stable_version: 2.1.0`.
  Verified 2026-04-30 via https://hex.pm/api/packages/bypass

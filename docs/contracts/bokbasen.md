<!-- doc-tier: agent | canonical-for: bokbasen-integration | budget: 1500tok -->

# Bokbasen integration contract (OnixEdit plugin)

HTTP wire detail is PATH-FROZEN at `docs/spec/bokbasen-api-contract.md` — code
cites its §-anchors. This doc owns the rest. Ops: `docs/ops/bokbasen-go-live.md`. Fields:
`docs/contracts/onix-field-map.md`.

## Transport facts (ASSUMED until exercised)

Source: public Confluence (read 2026-04-30) + frozen contract; not
production-validated (Task #12).

- OAuth2 client-credentials at `https://auth.bokbasen.io/oauth/token`, audience `https://api.bokbasen.io/metadata/`; auth sandbox host `auth.stage.bokbasen.io`. Metadata-import *sandbox host* unconfirmed (§9 Q-C, blocking).
- Sender identity derives from the OAuth2 token (T5) — `<Header>/<Sender>` informational only; placeholder `<SenderName>barkpark.cloud</SenderName>` acceptable, no GLN (Q1, resolved WI1).
- T3: V1 endpoint accepts a single `<Product>` and REJECTS the `<ONIXMessage>` wrapper (`<Header>` rejected); V2 accepts either. Barkpark emits `<ONIXMessage>` → **V2 is the pinned endpoint** (§3).
- T6: Block access scoped by sender role; disallowed blocks silently ignored. Distributor → Blocks 1,2,4,6; publisher matrix unconfirmed (Q5). Barkpark = Publisher (Q-J), emits Blocks 1+2+3+4.
- T7: 3-stage validation — (1) sender access, (2) EDItEUR XSD, (3) Bokbasen/Norwegian required-field checks. Barkpark covers only (2) via `Validator.validate_xsd/2`.
- T8: Object Import — covers/audio POST to `…/import/object/v1/{ean}/{type}`, ≤10 MB, `image/jpeg|png` for `productimage`, `audio/mpeg` for `audiosample`. NOT implemented; barkpark emits `<SupportingResource>` URI links.
- F9/F10 export gaps: `<SalesRestriction>` List 71 incl. Bokbasen extensions 06/09/13/20/99; `<SalesOutlet>` List 139 retailer codes (FAB/EBK/NXT/BOO/STT, 2026-v3). Phase 7+.
- Required-vs-optional field matrix: partner-only PDFs (1.0–1.18); Confluence + change-log are the only open sources.
- Rate limits partner-only; defaults (Q-G): 1 req/sec, 10 concurrent, backoff + jitter on 429, honor `Retry-After` (integer-seconds AND RFC 7231 IMF-fixdate).

## Lifecycle + status (verified in code)

Single-phase **async-poll, not two-phase claim** (WI1 amendment):
`Client.stage/2 → poll/2 → cancel/2`, no `claim`. 9-state composite
`bp_export_status`: `:pending → :staging → :staged → :polling → :accepted | :rejected | :failed | :cannot_cancel → :cancelled`.

- `Status.write/2` **re-fetches the doc from DB before merging** (concurrent-write safe), broadcasts the composite on PubSub `bokbasen:document:#{doc_id}`, auto-derives `signed_off=true` when `accepted_at` is set unless caller passes `false`.
- Rejection sentinel `http_status: 200` = body-level rejection (HTTP ok, content rejected) — distinct from transport-level 422. `raw_xml` truncated to 4096 bytes.
- `:cancelled` is **state-only by design** — Bokbasen returns 204 on cancel; no `cancelled_at`. `:cannot_cancel` preserves prior timestamps via merge.
- PublishWorker: `queue: :bokbasen, max_attempts: 5, unique: [keys: [:document_id]]` (60 s window); existing `submission_id` skips stage, resumes polling — never a duplicate stage POST. Verified: `config.exs` sets queue concurrency **4**, not 1; per-document serialization comes from `unique`, not queue width.

## Bound decisions

- **D12** — Go TUI read-only for plugin schemas in v1; `book` renders as JSON dump; Studio is the editing surface.
- **D21** — BYO codelist snapshot: plugin ships no EDItEUR codelist XML; publisher supplies via `BARKPARK_ONIX_CODELIST_PATH` (license resolution).

## Credentials

**Env first, then DB** (`Settings.get_credentials/0`). Five keys:
`BOKBASEN_CLIENT_ID`, `BOKBASEN_CLIENT_SECRET`, `BOKBASEN_API_BASE`,
`BOKBASEN_OAUTH_TOKEN_URL`, `BOKBASEN_CLIENT_ROLE` (default `publisher`). Env read
by `config/runtime.exs` at boot; DB = encrypted `plugin_settings` row `bokbasen`
(`Barkpark.EncryptedMap` / `BARKPARK_CLOAK_KEY`), editable in Studio; env shadows
until cleared.

- Local: `cp deploy/bokbasen.env.example deploy/bokbasen.env && chmod 600 …`, then `set -a; source …; set +a`. `deploy/` sits **outside** `api/` (outside Phoenix's static pipeline); `deploy/*.env` git-ignored.
- **No secret-leak scanner** — pre-commit checks formatting only. `.gitignore` is the single safeguard; never paste real values into `bokbasen.env.example`.

## Credential redaction

Fixtures under `api/test/fixtures/bokbasen/` use synthetic markers: `test_*`
prefixes, `api.example.com`, short opaque strings. E2E rewrites fixture
`Location` URLs onto the local Bypass port. Enforced with
`refute blob =~ ~r/bokbasen\.no/i`. All new fixtures follow this.

## Deploy gate (Task #12)

Phase 8 NOT production-validated until **≥1 real (redacted) Bokbasen ack lives in
`fixtures/bokbasen/real/` AND the parser classifies it correctly**. Code-complete
≠ production-validated.

## Known gotchas

- **Thema hoisting** — `themaSubjectCategory` is its own field; ONIX submits Thema as `<Subject>` with `<SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>`. Exporter hoists; wrong-field Thema codes need re-import.
- **localizedText fallback** — `contributor.biographicalNote` / `textContent.text` use chain `["nob", "eng", "first-non-empty"]`; exporter emits ONE language per `<Text>`.
- **Bokbasen-internal codelists** (e.g. sales channels) are not in EDItEUR issue 73 — affected fields render as an empty `<select>`. Seed via `plugin_settings` or confirm with Bokbasen.

## Code anchors

- `api/lib/barkpark/plugins/onixedit/bokbasen/` — `client.ex` (`stage`, `poll`, `cancel`) · `publish_worker.ex` (Oban `unique`, `max_attempts`) · `status.ex` (`read`, `write`) · `settings.ex` (`get_credentials`) · `auth.ex` (`token`, `credentials`)
- `api/lib/barkpark/plugins/onixedit/export/validator.ex` — `validate_xsd`
- `api/config/config.exs` — Oban `queues` (bokbasen: 4); `api/config/runtime.exs` — `bokbasen_env_keys`

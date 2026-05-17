# Bokbasen go-live runbook

How to wire Bokbasen credentials into a Barkpark instance and verify the publish pipeline end-to-end. Use when sandbox or production credentials arrive.

## Prerequisites

- Bokbasen has issued you a `client_id` + `client_secret` (sandbox or prod)
- `client_role` is known (typically `publisher`)
- An admin-token Studio session (for Option A — recommended). SSH access is only needed for Option B (fallback).
- A draft `book` document with at least one valid `ProductIdentifier` (ISBN-13 minimum) — Bokbasen rejects books without identifiers

## Step 1 — set credentials

Two equivalent paths. Pick one.

### Option A: admin Studio form (recommended)

No SSH, no `mix run`. Browse to:

```
http://89.167.28.206/studio/production/_plugins/onixedit/settings
```

Fill in the five Bokbasen fields:

| Field | Value |
|---|---|
| Bokbasen API base URL | `https://api.bokbasen.io` (sandbox: `https://api-sandbox.bokbasen.io`) |
| OAuth token URL       | `https://login.bokbasen.io/oauth2/token` |
| Client ID             | issued by Bokbasen |
| Client secret         | issued by Bokbasen (stored encrypted at rest via `BARKPARK_CLOAK_KEY`) |
| Client role           | `publisher` (default) or `distributor` |

Click **Save**. Then click **Test connection** — a green flash confirms
Bokbasen accepted the credentials. The secret never appears in the DOM
again unless you explicitly click "Reveal" (which records a `"reveal"`
audit row in `plugin_settings_audits`). "Clear" wipes a single field.

No restart needed — `Bokbasen.Settings.get_credentials/0` reads the
encrypted row on every token fetch, so the next publish picks up the
new values immediately.

### Option B: SSH + `.env` (fallback)

If you can't reach Studio (e.g. first-boot before any admin token
exists), set the five `BOKBASEN_*` env vars:

```bash
ssh root@89.167.28.206
cd /opt/barkpark
# Append the 5 BOKBASEN_* vars to the existing .env
cat >> .env <<'EOF'
BOKBASEN_API_BASE=https://api.bokbasen.io
BOKBASEN_OAUTH_TOKEN_URL=https://login.bokbasen.io/oauth2/token
BOKBASEN_CLIENT_ID=<your client_id>
BOKBASEN_CLIENT_SECRET=<your client_secret>
BOKBASEN_CLIENT_ROLE=publisher
EOF

# Sandbox? Use the test endpoints (Bokbasen will confirm exact URLs):
# BOKBASEN_API_BASE=https://api-sandbox.bokbasen.io
# BOKBASEN_OAUTH_TOKEN_URL=https://login-sandbox.bokbasen.io/oauth2/token

systemctl restart barkpark
```

`runtime.exs` reads `BOKBASEN_*` at boot. Env wins over the
plugin_settings row, so this is also useful for one-off overrides
(e.g. swapping prod ↔ sandbox without touching the DB).

## Step 2 — verify the client can fetch a token

```bash
cd /opt/barkpark/api
mix run -e '
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Client
  case Client.fetch_token() do
    {:ok, token} -> IO.puts "TOKEN OK: #{String.slice(token, 0, 20)}..."
    {:error, e}  -> IO.puts "TOKEN FAILED: #{inspect(e)}"
  end
'
```

Expected: `TOKEN OK: eyJhbGciOiJIUzI1NiIs…`.

If you get `401 invalid_client` or `403`, the credentials are wrong or the role doesn't match. Bokbasen's support team can verify.

## Step 3 — dry-run a single book

Pick a book with valid identifiers. From the Studio UI:

```
http://89.167.28.206/studio/production/book/<your-book-id>
```

In the editor header → "Publish to Bokbasen" button (or the ••• overflow if narrower viewport).

The modal opens with two stages:
1. **Dry-run** — generates the ONIX XML in-memory, runs Bokbasen's validation endpoint, returns a structured result (valid / errors). Nothing is submitted.
2. **Confirm** — enqueues an `Oban` job (`Plugins.OnixEdit.Bokbasen.PublishWorker`) that POSTs the real ONIX XML to Bokbasen, polls for status, writes the final state back to `bp_export_status`.

You can drive the same flow from a shell for repeatable testing:

```bash
mix run -e '
  alias Barkpark.Plugins.OnixEdit.Actions
  IO.inspect Actions.publish_to_bokbasen("<doc-id>", "production", :dryrun)
'
```

## Step 4 — watch the live ONIX preview while the book is being edited

`http://89.167.28.206/studio/production/book/<id>` has the right pane "ONIX 3.0 preview" — re-renders every autosave. If you see "export failed", the document is missing required ONIX elements (e.g. no ProductIdentifier). The cross-validation banner above the form names which validation rule fired.

## Step 5 — submit for real and watch the status pill

After the dry-run is clean, click "Confirm" in the modal. The status pill at the top of the editor flows:

```
draft → queued → staging → staged → polling → accepted   (or rejected / failed)
```

Each transition publishes on `Phoenix.PubSub` topic `external_sync:bokbasen:<doc_id>`. The `ExternalSyncPill` component subscribes; the editor live-updates without a refresh.

If the state stays `polling` for more than ~5 minutes, check the Oban dashboard or:

```bash
psql "$PG_URL" -c "SELECT id, state, attempt, last_error FROM oban_jobs WHERE worker='Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker' ORDER BY id DESC LIMIT 5;"
```

## Step 6 — admin staleness dashboard

`http://89.167.28.206/studio/production/onixedit/staleness` shows every book's Bokbasen status with last-success timestamps. Useful for spotting books that synced once and then quietly stopped (e.g. retries exhausted, schema changes invalidated the ONIX).

## Rolling back a stuck book

```bash
mix run -e '
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status
  Status.write(%{doc_id: "<doc-id>", dataset: "production"}, %{state: "draft", last_error: nil})
'
```

Then re-edit and re-publish.

## Production checklist before going live with real ISBNs

- [ ] `mix onix.export_proof` produces byte-stable output (no drift)
- [ ] `mix test` is green
- [ ] `mix compile --warnings-as-errors` is green
- [ ] DB has been backed up (`/root/backups/barkpark-pre-bokbasen-<ts>.sql`)
- [ ] At least one dry-run has returned `valid: true` for a representative book
- [ ] Bokbasen support has confirmed the client_role matches their account expectations
- [ ] Oban job concurrency is set to 1 for the PublishWorker (default; verify in `config/runtime.exs` or `config/prod.exs`) — submitting multiple books in parallel can trip Bokbasen's rate limit
- [ ] `BOKBASEN_RATE_LIMIT_MS` env var is set if you want to rate-limit per-doc submission spacing (default per Bokbasen.Client)

## Known gotchas

- **Thema codes vs Subject codes**: book.json declares `themaSubjectCategory` as a separate field, but ONIX submits Thema codes as `<Subject>` with `<SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>`. The exporter handles this hoisting. If you imported books that have Thema codes in the wrong field, re-import or run a one-off migration.
- **Multi-language `localizedText`**: `contributor.biographicalNote` and `textContent.text` are localizedText with fallback chain `["nob", "eng", "first-non-empty"]`. The exporter emits ONE language per `<Text>` element (Bokbasen's preferred). Make sure the right language is populated.
- **Date format**: ONIX `<Date>` is compact `YYYYMMDD`; book.json stores ISO `YYYY-MM-DD`. Exporter strips dashes. Importer rehydrates. If a date roundtrips wrong, it's a renderer-side bug, not a Bokbasen issue.
- **Bokbasen-internal codelist values**: Bokbasen-specific extension codelists (e.g. their internal sales channels) are not in EDItEUR's issue 73. If a field expects one of these, the field will render as `<select>` with no options. Either seed the values via `plugin_settings` or coordinate with Bokbasen to confirm the accepted vocabulary.

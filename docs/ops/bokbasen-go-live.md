<!-- doc-tier: agent | canonical-for: bokbasen-go-live-runbook | budget: 1200tok -->

# Bokbasen go-live runbook

Wire Bokbasen credentials into a Barkpark instance and verify the publish pipeline end-to-end. Use when sandbox or production credentials arrive. Contract facts (endpoints, lifecycle, redaction rule, gotchas): `docs/contracts/bokbasen.md`.

## Prerequisites

- Bokbasen-issued `client_id` + `client_secret` (sandbox or prod); `client_role` known (typically `publisher`)
- Admin-token Studio session (Option A — recommended); SSH only for Option B
- A draft `book` document with at least one valid `ProductIdentifier` (ISBN-13 minimum) — Bokbasen rejects books without identifiers

## Step 1 — set credentials

Resolution order, key names, encryption, and `deploy/` handling: see **`docs/contracts/bokbasen.md` § Credentials**. In short:

- **Option A (recommended):** Studio form at `https://api.barkpark.cloud/studio/production/_plugins/onixedit/settings` — fill the five Bokbasen fields, **Save**, then **Test connection** (green flash = accepted). "Reveal" writes an audit row to `plugin_settings_audit`. No restart needed — credentials are read on every token fetch.
- **Option B (fallback, e.g. first-boot):** append the five `BOKBASEN_*` vars to `/opt/barkpark/.env` over SSH, then `systemctl restart barkpark`. Env wins over the DB row — useful for one-off prod ↔ sandbox swaps.

## Step 2 — verify token fetch

```bash
cd /opt/barkpark/api
mix run -e '
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth
  case Auth.token() do
    {:ok, token} -> IO.puts "TOKEN OK: #{String.slice(token, 0, 20)}..."
    {:error, e}  -> IO.puts "TOKEN FAILED: #{inspect(e)}"
  end
'
```

Expected: `TOKEN OK: eyJ…`. A `401 invalid_client` / `403` means wrong credentials or role mismatch — Bokbasen support can verify.

## Step 3 — dry-run a single book

Open `https://api.barkpark.cloud/studio/production/book/<your-book-id>` → "Publish to Bokbasen" (or ••• overflow). The modal has two stages:

1. **Dry-run** — generates the ONIX XML in-memory, runs validation, returns structured valid/errors. Nothing submitted.
2. **Confirm** — enqueues the Oban `PublishWorker` job: POSTs the ONIX, polls status, writes `bp_export_status`.

Shell equivalent for repeatable testing:

```bash
mix run -e '
  alias Barkpark.Plugins.OnixEdit.Actions
  IO.inspect Actions.publish_to_bokbasen("<doc-id>", "production", :dryrun)
'
```

## Step 4 — live ONIX preview

The book editor's right pane "ONIX 3.0 preview" re-renders on every autosave. "Export failed" = missing required ONIX elements (e.g. no ProductIdentifier); the cross-validation banner names the rule that fired.

## Step 5 — submit for real, watch the pill

After a clean dry-run, click "Confirm". Status pill flow:

```
draft → queued → staging → staged → polling → accepted   (or rejected / failed)
```

Each transition publishes on PubSub; the editor live-updates. Stuck in `polling` > ~5 min:

```bash
psql "$PG_URL" -c "SELECT id, state, attempt, last_error FROM oban_jobs WHERE worker='Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker' ORDER BY id DESC LIMIT 5;"
```

## Step 6 — admin staleness dashboard

`http://89.167.28.206/admin/onixedit/staleness` — every book's Bokbasen status with last-success timestamps. Spots books that synced once and quietly stopped (retries exhausted, schema changes invalidated the ONIX).

## Rolling back a stuck book

```bash
mix run -e '
  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status
  doc = Content.get_document("<doc-id>", "book", "production")
  Status.write(doc, %{state: "draft", last_error: nil})
'
```

Then re-edit and re-publish.

## Production checklist before going live with real ISBNs

- [ ] `mix onix.export_proof` produces byte-stable output (no drift)
- [ ] `mix test` green
- [ ] `mix compile --warnings-as-errors` green
- [ ] DB backed up (`/root/backups/barkpark-pre-bokbasen-<ts>.sql`)
- [ ] At least one dry-run returned `valid: true` for a representative book
- [ ] Bokbasen support has confirmed the client_role matches their account expectations
- [ ] Duplicate-submission protection understood: the Oban `bokbasen` queue is concurrency **4** in `config.exs`; per-document serialization comes from PublishWorker's `unique: [keys: [:document_id]]` clause (see `docs/contracts/bokbasen.md` § Lifecycle). Don't mass-enqueue — Bokbasen rate limit is 1 req/sec.
- [ ] `BOKBASEN_RATE_LIMIT_MS` set if you want per-doc submission spacing (default per Bokbasen.Client)

## Known gotchas

Moved to **`docs/contracts/bokbasen.md` § Known gotchas** (Thema hoisting, localizedText fallback chain, Bokbasen-internal codelist gap). One renderer-side note stays here: ONIX `<Date>` is compact `YYYYMMDD`, book.json stores ISO `YYYY-MM-DD`; the exporter strips dashes and the importer rehydrates — a wrong roundtrip is a renderer bug, not a Bokbasen issue.

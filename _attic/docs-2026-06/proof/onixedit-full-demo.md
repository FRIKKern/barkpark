ARCHIVED — do not load; facts moved to docs/contracts/bokbasen.md
# OnixEdit — Phase 4-8 full pipeline demo

This artifact walks the demo path that the plugin executes when a
publisher hits **Publish to Bokbasen** in the BookEditor. It is the
counterpart to `proof/onix-sample.xml` (Phase 6 WI8): that file is the
*input* (rendered ONIX); this file narrates the *flow* around it.

The corresponding executable proof is
`api/test/barkpark/plugins/onixedit/phase8_e2e_test.exs`
(`@moduletag :phase8_demo`, opt-in via `mix test --include phase8_demo`).

---

## 1. Phase 4 — Plugin foundation, schema v2

`book` documents are validated against the v2 schema (composite,
arrayOf, codelist, localizedText). The Go TUI renders them as JSON
dumps; editing happens in the LiveView Studio at `/studio`. See
`docs/plugins/SCHEMA_V2.md`.

## 2. Phase 5 — BookEditor LiveView shell + 8-tab framework

The editor lives at:

    /studio/:dataset/onixedit/book/:doc_id

Eight tabs (Identity, Title, Contributors, Subjects, Publishing,
Supply, Marketing, Related), Thema picker on Subjects (WI2), v2 field
adapter dispatches composite/arrayOf/codelist/localizedText to the
right primitive (Phase 4 WI4).

## 3. Phase 6 — ONIX 3.0 export

`Barkpark.Plugins.OnixEdit.Export.to_iodata/1` renders an ONIX 3.0
message and validates it against the bundled EDItEUR XSD. Header
excerpt from the canonical fixture (`proof/onix-sample.xml`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ONIXMessage release="3.0" xmlns="http://ns.editeur.org/onix/3.0/reference">
  <Header>
    <Sender>
      <SenderName>barkpark.cloud</SenderName>
    </Sender>
    <SentDateTime>20260430T112142</SentDateTime>
    <MessageNote>Barkpark dataset:production</MessageNote>
  </Header>
  <Product>
    <RecordReference>barkpark.cloud:p9</RecordReference>
    <NotificationType>03</NotificationType>
    <ProductIdentifier>
      <ProductIDType>15</ProductIDType>
      <IDValue>9788234567890</IDValue>
    </ProductIdentifier>
```

XSD failures short-circuit before the worker enqueues — `BookEditor`
catches `{:error, {:xsd_invalid, reasons}}` and surfaces them in the
publish modal's preview pane.

## 4. Phase 7 — Bokbasen submit + async-poll worker

`Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker` (Oban) drives the
state machine:

    :pending → :staging → :staged → :polling → :accepted
                                            ↘ :rejected
                                            ↘ :failed
                                            ↘ :cancelled
                                            ↘ :cannot_cancel

HTTP shape (Bypass-mocked in tests):

  * `POST /metadata/import/onix/v2` → `202 Accepted` + `Location: …/<submission_id>`
  * `GET  /metadata/import/onix/v2/<submission_id>` → repeated polls
    until terminal.

Synthesised `poll_accepted.xml` fixture (verbatim — zero real IDs,
zero real credentials):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<importItem>
  <submissionId>test-submission-id-xyz</submissionId>
  <state>COMPLETED</state>
</importItem>
```

Counterpart `poll_pending.xml` (returned on the first poll so the
worker snoozes once):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<importItem>
  <submissionId>test-submission-id-xyz</submissionId>
  <state>UNPROCESSED</state>
</importItem>
```

## 5. Phase 8 WI1 — `bp_export_status` composite promotion

The Phase 7 worker stored status as a JSON-encoded string. WI1
promoted the field to a native composite map; the only sanctioned
read/write surface is `Barkpark.Plugins.OnixEdit.Bokbasen.Status`.
Reads tolerate every shape ever persisted (legacy plain string,
Phase 7 JSON-encoded string, Phase 8 native map). Writes always stamp
`updated_at` and derive `signed_off: true` whenever `accepted_at` is
present.

## 6. Phase 8 WI2 — ack-loop full state capture

WI2 extended the worker so every persistent transition stamps a
discrete timestamp into the composite — `staging_started_at`,
`staged_at`, `polling_started_at`, `accepted_at` (or terminal-error
equivalents). The composite is the canonical audit trail; admin LV
and BookEditor read from it directly.

## 7. Phase 8 WI3 — BookEditor sign-off badge (parallel team)

When `signed_off: true` lands in the composite, the BookEditor
toolbar renders a sign-off badge alongside the existing status pill.

> **TBD pending WI3 merge.** Planned snippet (subject to WI3's final
> selector):
>
> ```html
> <span class="bp-signoff-badge"
>       data-test-id="bokbasen-signoff-badge"
>       data-bp-signoff="true"
>       title="Accepted by Bokbasen 2026-04-30 11:21 UTC">
>   ✓ Signed off
> </span>
> ```
>
> The phase 8 demo test (`phase8_e2e_test.exs` `:requires_wi3`
> describe) tolerates either `[data-test-id="bokbasen-signoff-badge"]`
> or `[data-bp-signoff="true"]` so the contract negotiation between
> WI3 and WI5 stays loose until WI6 close-out.

## 8. Phase 8 WI4 — codelist staleness check (parallel team)

After a doc is `:accepted`, an operator can re-validate it against
a newer EDItEUR issue (e.g. issue 74 vs. the issue 73 the doc was
authored against). WI4 surfaces removed / renamed Thema (and other)
codes so the publisher knows to refresh subject pickers before the
next export.

> **TBD pending WI4 merge.** Planned report shape:
>
> ```elixir
> %{
>   stale_codes: %{
>     "Thema" => [
>       %{code: "FXX", reason: :removed_in_issue_74},
>       %{code: "JBSL1", reason: :renamed, replacement: "JBSL"}
>     ]
>   },
>   issue_authored_against: 73,
>   issue_compared_to: 74
> }
> ```
>
> The `:requires_wi4` describe block in `phase8_e2e_test.exs` calls
> `Codelists.staleness_report/2` with `%{issue: 74}` and expects a
> map with at least one of `:stale_codes` / `:removed_codes`. The
> exact module path and report shape lock at WI4 merge.

## 9. Phase 8 WI5 — this PR

  * Centralised the 5-bucket pill palette in
    `Barkpark.Plugins.OnixEdit.Export.StatusPill` (Phase 7 WI5/WI6
    each carried an inline copy — drift risk eliminated).
  * Added the `:ops` LiveView role and routed `/admin/bokbasen`
    through it. Existing `:admin` tokens still pass (backwards
    compat). See `docs/auth.md`.
  * This proof artifact + the Phase 8 demo test.

---

## Credential redaction

All HTTP fixtures under `api/test/fixtures/bokbasen/` use synthetic
markers (`test_*` prefixes, `api.example.com`, opaque-but-short test
strings). The `phase8_e2e_test.exs` setup rewrites the fixture's
`Location` URL onto the local Bypass port so no real Bokbasen host
ever appears in test traffic. The Phase 7 WI7 e2e test enforces this
with a `refute blob =~ ~r/bokbasen\.no/i` guard; this artifact
follows the same redaction rule.
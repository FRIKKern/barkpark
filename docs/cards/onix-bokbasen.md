<!-- doc-tier: agent | canonical-for: onix-export-overview | budget: 450tok -->
# ONIX / Bokbasen (OnixEdit plugin)

The OnixEdit plugin exports `book` documents as ONIX 3.0 XML and ships them to Bokbasen. Export is split by ONIX block, one submodule each under `api/lib/barkpark/plugins/onixedit/export/`:

| Submodule | ONIX block |
|---|---|
| header.ex / message.ex | Header + ONIXMessage envelope (attrs MUST stay a keyword list — map ordering is non-deterministic) |
| descriptive_detail.ex | DescriptiveDetail (contributors, Thema, form) |
| collateral_detail.ex | CollateralDetail (texts, covers) |
| publishing_detail.ex | PublishingDetail (publisher, dates) |
| product_supply.ex | ProductSupply (price, availability) |
| validator.ex / codelists.ex | XSD validation (xmllint) + codelist resolution |

Constraints:
- **D12:** the `book` schema (v2 field types) is TUI **read-only** — JSON dump in the TUI, editing in Studio. → docs/contracts/schema-v2.md.
- Field → submodule+function index, ERRATA (codelistId 162→86; list 93 ≠ Thema), RecordReference global-uniqueness → docs/contracts/onix-field-map.md (canonical).
- **RecordReference host** = `ONIX_DATASET_HOST` (default `barkpark.cloud`), resolved at export time by `Export.dataset_host/0`; the per-export `:dataset_host` opt still wins, and a malformed value raises at boot. It is an identifier NAMESPACE, so a self-hoster must set it BEFORE the first submission — changing it later re-identifies every record a partner already holds.
- Bokbasen wire contract: no-ONIXMessage-wrapper rejection, OAuth sender identity, size limits, creds setup, credential-redaction rule, known gotchas → docs/contracts/bokbasen.md (canonical).
- Go-live checklist (Oban concurrency=4) → docs/ops/bokbasen-go-live.md.
- EDItEUR/Thema license posture → api/priv/codelists/README.md (canonical).

## Code anchors
- api/lib/barkpark/plugins/onixedit.ex — defmodule Barkpark.Plugins.OnixEdit
- api/lib/barkpark/plugins/onixedit/export/descriptive_detail.ex — def build
- api/lib/barkpark/plugins/onixedit/export/message.ex — def wrap
- api/lib/barkpark/plugins/onixedit/export/validator.ex — def validate_xsd

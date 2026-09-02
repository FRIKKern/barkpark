<!-- doc-tier: agent | canonical-for: onix-export-field-map | budget: 1400tok -->

# ONIX 3.0 export — field → module map

Replaces the prior line-by-line mapping spec (removed; recover from git history). Authoritative worked example: `api/test/fixtures/onix/onix-sample.xml` — XSD-validated output of `Export.to_string/2` from `api/test/fixtures/onix/full-book.json`, drift-guarded by `export_proof_test.exs`; regenerate with `cd api && mix onix.export_proof`.

## Module index (verified against source, 2026-06-10)

| ONIX area | Module (`Barkpark.Plugins.OnixEdit.Export…`) | Entry functions |
|---|---|---|
| Public API + Product envelope (RecordReference, NotificationType, ProductIdentifier) | `Export` | `export/2`, `to_iodata/2`, `to_string/2`, `to_file/3` |
| `<ONIXMessage>` wrapper (`release="3.0"`, reference-tag namespace) | `.Message` | `wrap/2` |
| `<Header>` (Sender, SentDateTime `YYYYMMDDTHHMMSS`, MessageNote) | `.Header` | `build/1` |
| `<DescriptiveDetail>` (form, titles, contributors, languages, subjects/Thema, audience) | `.DescriptiveDetail` | `build/2` |
| `<CollateralDetail>` (TextContent, SupportingResource, Prize) | `.CollateralDetail` | `build/2` |
| `<PublishingDetail>` (Imprint, Publisher, dates, SalesRights) | `.PublishingDetail` | `build/2` |
| `<ProductSupply>` (Market, Supplier, Price, UnpricedItemType) | `.ProductSupply` | `build/2` |
| Codelist validation/label helpers | `.Codelists` | `contributor_role/1`, `product_form/1`, `thema/1`, `currency_code/1`, … |
| XSD gate (xmllint vs vendored Issue 73 XSD) | `.Validator` | `validate_xsd/2`, `default_xsd_path/0` |
| Status pill (5 buckets over 9 lifecycle states) | `.StatusPill` | `color_class/1`, `label/1` |

Export opts: `:dataset` (default `"production"` — written into `<MessageNote>`), `:sent_at` (DateTime, default `DateTime.utc_now/0` — overridable for tests), `:dataset_host` (`ONIX_DATASET_HOST`, else `"barkpark.cloud"`). XML lib: **XmlBuilder `~> 2.2`** (already vendored; Saxy rejected — parser-first lib, streaming unneeded at 10–30 KB/message). Coverage totals at spec close: MAPPED 138 · PARTIAL 47 · UNMAPPED 9 (`bp_*` internals, doc envelope) · DEFERRED 4 (Promotion, Production, Measure, SupplyContact).

## Norwegian defaults — rationale

- **`nob`** — ISO 639-2/B (List 74) for Norwegian Bokmål. ONIX requires alpha-3, not BCP-47: `bcp47_to_iso6392b/1` maps `nb-NO`/`nb` → `nob`, `nn` → `nno`, unknown → `eng`. localizedText fallback chain is `["nob", "eng", "first-non-empty"]`; an English fallback logs a warning and tags `language="eng"`.
- **`NO`** — ISO 3166-1 alpha-2 (List 91). Multi-country form is space-separated inside ONE `<CountriesIncluded>` element (`NO SE DK`), not repeated elements.
- **`NOK`** — ISO 4217 (List 96) default currency. With no price, emit `<UnpricedItemType>01</UnpricedItemType>` instead of `<Price>`. Norwegian book VAT is 0% — `<Tax>` may be omitted.
- Codelists pinned to **EDItEUR Issue 73**; Thema emitted as `<SubjectSchemeVersion>1.6</SubjectSchemeVersion>` (the seeded `onixedit:thema` registry).

## RecordReference — global-uniqueness rule

`<RecordReference>` = `<dataset_host>:<_publishedId>`, domain-prefixed for cross-publisher uniqueness. The `drafts.` prefix is **stripped**, so a draft and its published doc share one RecordReference (Bokbasen tracks records by it across updates).

## ERRATA (schema-annotation bugs — corrections are deliberate)

1. **`bibleVersion` codelistId 162 → 86.** `book.json` annotates List 162, but ONIX List 162 is "Resource version feature type"; the Bible-version list is **86**. Emit `<BibleVersion>` against List 86.
2. **`themaSubjectCategory` codelistId 93.** ONIX List 93 is *Supplier role*. Here `93` is the **SubjectSchemeIdentifier VALUE** ("this code is Thema"), not a pointer into the ONIX list registry. Fix shipped: allowlist in the alias resolver + bundled Thema JSON. Do not "correct" it back.
3. Related plugin-name bug: `Adapter.resolve_plugin/2` once defaulted nested codelists to `"core"` (13 broken `<select>`s) — see `docs/cards/plugins.md` anti-patterns.

## Decision log digest (Q1–Q5)

| Q | Decision |
|---|---|
| Q1 | RecordReference is domain-prefixed `barkpark.cloud:<id>` — not raw `_publishedId`. |
| Q2 | Missing `notificationType` defaults to `03` "Confirmed on publication" (XSD requires the element). |
| Q3 | First Thema code is the main subject, encoded as an empty flag INSIDE the subject: `<Subject><MainSubject/><SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>…</Subject>`. `<MainSubjectSchemeIdentifier>` does not exist in the XSD. |
| Q4 | Sender ID: none required — Bokbasen derives sender from the OAuth2 token; placeholder `<SenderName>barkpark.cloud</SenderName>` stands (see `docs/contracts/bokbasen.md`). |
| Q5 | = ERRATA 1 (`bibleVersion` 162 → 86). |

## Code anchors

- `api/lib/barkpark/plugins/onixedit/export.ex` — `export`, `to_string`
- `api/lib/barkpark/plugins/onixedit/export/message.ex` — `wrap`
- `api/lib/barkpark/plugins/onixedit/export/header.ex` — `build`
- `api/lib/barkpark/plugins/onixedit/export/descriptive_detail.ex` — `build`
- `api/lib/barkpark/plugins/onixedit/export/collateral_detail.ex` — `build`
- `api/lib/barkpark/plugins/onixedit/export/product_supply.ex` — `build`
- `api/lib/barkpark/plugins/onixedit/export/codelists.ex` — `thema`, `contributor_role`
- `api/lib/barkpark/plugins/onixedit/export/validator.ex` — `validate_xsd`
- `api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd` — vendored Issue 73 / Revision 8

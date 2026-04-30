<!--
  Bokbasen ONIX 3.0 pre-flight audit
  Author: Worker_W3.1 (Task #43, Phase 6 WI7)
  Created: 2026-04-30
  Source-of-truth branch: doey/team-3-0430-1032 (off main b9602eb)
  Status: research recon — NOT a formal Bokbasen integration spec
-->

# Bokbasen ONIX 3.0 pre-flight audit

> **Scope:** capture what is *publicly documented* about Bokbasen's ONIX
> ingestion and verify the existing barkpark ONIX 3.0 export against those
> findings. Apply only low-risk in-scope fixes that public Bokbasen
> documentation explicitly justifies. Everything else goes to Phase 7.

> **Result of audit (TL;DR):** Phase 6 (WI1–WI5.5) ships a Norwegian-locale
> ONIX 3.0 export that XSD-validates against the vendored EDItEUR schema.
> Bokbasen's *transport surface* (auth, endpoint, async status polling,
> proprietary extensions like SalesRestriction subscription codes) is
> outside the WI1–WI5.5 scope and is captured here as Phase 7 follow-ups.
> No code changes were applied in WI7 — the only pre-approved candidate
> (sender ID → GLN) turned out to be **not** a Bokbasen requirement
> (sender info is derived from the OAuth2 token, the Header is
> informational at best and rejected entirely on V1).

---

## 1. Bokbasen overview

[Bokbasen AS](https://www.bokbasen.no/) is the central Norwegian metadata
and digital book distribution hub for the publishing industry. It operates
the canonical Norwegian-language book metadata catalogue, the Distribution
of Digital Sales (DDS) platform, and a set of HTTP APIs that publishers,
distributors and retailers integrate with. Bokbasen provides both an
**ONIX import** path (publisher → Bokbasen) for registering / updating
book metadata, and an **ONIX export** path (Bokbasen → retailer) for
downstream catalogue consumption.

For Phase 6 of the OnixEdit plugin, Bokbasen is the *target* ingestion
partner — barkpark publishers will eventually POST ONIX 3.0 product
records to Bokbasen's import API. This WI captures what is publicly
findable about that path; partner-only validation rules and credentials
remain out of band until a real partner contact is established.

---

## 2. Sources consulted

All URLs accessed 2026-04-30. Bokbasen runs a public-read Confluence space
(`bokbasen.jira.com/wiki/spaces/api`); pages are anonymously readable but
some downloads (PDF specifications) require partner login.

| URL | Status |
|-----|--------|
| https://bokbasen.jira.com/wiki/spaces/api/pages/51347471/Introduction | verified |
| https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service | verified |
| https://bokbasen.jira.com/wiki/spaces/api/pages/51347475/ONIX+for+Bokbasen+import | verified (index page; full field-level PDFs are downloads) |
| https://bokbasen.jira.com/wiki/spaces/api/pages/57868299/Change+log+-+import+ONIX | verified |
| https://bokbasen.jira.com/wiki/spaces/api/pages/57868301/Change+log+-+export+ONIX | partial access (linked, not fetched in full) |
| https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3 | verified |
| https://bokbasen.jira.com/wiki/spaces/api/pages/71335938/ONIX+codelists | verified |
| https://bokbasen.jira.com/wiki/spaces/api/pages/67993632/ONIX | verified |
| https://bokbasen.jira.com/wiki/spaces/api/pages/54100062/ONIX+from+Bokbasen | verified |
| https://bokbasen.jira.com/wiki/pages/viewpage.action?pageId=91062280 (International e-books) | verified |
| https://github.com/Bokbasen | verified (12 public repos; no public ONIX spec / fixture repo) |
| Versioned PDF spec downloads `1.0` … `1.18` (linked from "ONIX for Bokbasen import") | paywalled / partner-only — link list only |

Authoritative ONIX 3.0 references (consulted as background, not Bokbasen-specific):

- https://www.editeur.org/8/ONIX/ — EDItEUR (ONIX standard maintainer)
- https://ns.editeur.org/onix/nb — ONIX online code list browser
- vendored XSD set in `api/priv/onix/onix-3.0/` (already in repo)

---

## 3. Required ONIX 3.0 fields per Bokbasen public docs

> **Caveat:** Bokbasen's *field-level required-vs-optional* matrix lives
> inside the versioned PDF specifications (`1.0` … `1.18`) on their
> import page. Those PDFs are linked but the underlying assets require
> partner login to download. The table below captures what is recoverable
> from the **public Confluence pages** plus Bokbasen's own ONIX export
> example (which mirrors their input expectations for the same fields).

### 3.1 Transport / auth (Bokbasen-specific, not ONIX)

| # | Bokbasen requirement | Source | barkpark coverage | Code |
|---|----------------------|--------|-------------------|------|
| T1 | OAuth2 client-credentials token from `https://auth.bokbasen.io/oauth/token`, audience `https://api.bokbasen.io/metadata/`, sent as `Authorization: Bearer <token>` | [Import Service](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ❌ missing (no transport layer in Phase 6) | n/a — Phase 7 candidate |
| T2 | POST to `https://api.bokbasen.io/metadata/import/onix/v2` (V2) or `…/v1` (V1), `Content-Type: application/xml` | [Import Service](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ❌ missing | n/a |
| T3 | V1 accepts a single `<Product>` (NOT a full `<ONIXMessage>` — `<Header>` is rejected); V2 accepts a single `<Product>` *or* a full `<ONIXMessage>` with one or more `<Product>` children | [Import Service §3.2.1](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ⚠️ partial — `Message.wrap/2` always emits a full `<ONIXMessage>` so V1 path would need a peeled-out `<Product>` extractor; V2 path is fine | `api/lib/barkpark/plugins/onixedit/export/message.ex:16` |
| T4 | Async response model: 202 Accepted + `Location: …/status/{uuid}`; client must poll `Import Item Status` until `COMPLETED` or `FAILED` | [Import Service §2.1.1, §3.2.2](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ❌ missing (no async client) | n/a |
| T5 | Sender identity is derived **from the OAuth2 token**, NOT from `<Header>/<Sender>` content. *"Information about sender that is normally extracted from the Onix Header is managed by the Authentication process and consequently not part of the exchanged data."* | [Import Service §3.2.1](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ✅ shipped — current `<SenderName>barkpark.cloud</SenderName>` is informational and XSD-valid; no GLN format required | `api/lib/barkpark/plugins/onixedit/export/header.ex:9` |
| T6 | Onix Block access is scoped per sender role. Distributor sender → may write Blocks 1, 2, 4, 6. Disallowed Blocks are silently ignored. Block 3 (Collateral) is publisher-only in the distributor scenario. | [Import Service §3.2.3](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ❓ unknown — barkpark exports Blocks 1+2+3+4 (no Block 5/6); behaviour depends on whose token is used | covers `descriptive_detail.ex`, `collateral_detail.ex`, `publishing_detail.ex`, `product_supply.ex` |
| T7 | Validation pipeline: (1) sender access, (2) EDItEUR XSD, (3) Bokbasen's "additional XML data validations to assure that fields that are required by bokbasen and the Norwegian publishing industry is in place" | [Import Service §3.3](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ⚠️ partial — barkpark covers (2) via `Validator.validate_xsd/2`; (1) and (3) are partner-side | `api/lib/barkpark/plugins/onixedit/export/validator.ex` |
| T8 | Object Import for cover images / audio samples: separate endpoint `…/import/object/v1/{ean}/{type}`, ≤10 MB, `image/jpeg` or `image/png` for `productimage`, `audio/mpeg` for `audiosample` | [Import Service §2.2](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) | ❌ missing (covers are emitted as `<SupportingResource>` URI links, not posted as binaries) | `api/lib/barkpark/plugins/onixedit/export/collateral_detail.ex` (SupportingResource builder) |

### 3.2 ONIX 3.0 content (Bokbasen public docs)

The "ONIX for Bokbasen import" landing page lists 19 versioned PDFs
(1.0 → 1.18) as the field-level source of truth. Those PDFs are not
captured in this audit because the binary assets require partner login
to download. What *is* recoverable from the public Confluence
[change log](https://bokbasen.jira.com/wiki/spaces/api/pages/57868299/Change+log+-+import+ONIX)
and from [Bokbasen's own ONIX export example](https://bokbasen.jira.com/wiki/spaces/api/pages/54100062/ONIX+from+Bokbasen):

| # | Bokbasen-recognised element | Source | barkpark coverage | Code |
|---|---|---|---|---|
| F1 | `<RecordReference>` per Product (free-form unique key) | EDItEUR + change log examples | ✅ shipped — emitted as `<host>:<published_id>` | `api/lib/barkpark/plugins/onixedit/export.ex:141` |
| F2 | `<NotificationType>` from List 1; `05` = "delete this record" (record MUST be deleted on receipt) | [ONIX from Bokbasen](https://bokbasen.jira.com/wiki/spaces/api/pages/54100062/ONIX+from+Bokbasen) | ✅ shipped — defaults to `03` (Notification confirmed on publication); pass-through accepts any List 1 code | `api/lib/barkpark/plugins/onixedit/export.ex:137,142` |
| F3 | `<ProductIdentifier>` with `<ProductIDType>15` (ISBN-13) and `<ProductIDType>03` (GTIN-13) — Norwegian books are dual-keyed by both in the Bokbasen export sample | Bokbasen export example (§ON FROM Bokbasen) | ✅ shipped — pass-through; both codes are accepted by `Codelists.product_id_type/1` | `api/lib/barkpark/plugins/onixedit/export.ex:83-90,155` |
| F4 | `<DescriptiveDetail>` with `<ProductForm>` (List 150), `<TitleDetail>`/`<TitleType>01`, `<Contributor>` with role from List 17, `<Subject>` with `<SubjectSchemeIdentifier>93` (Thema) | Change log v1.16 (Thema/Contributor codes) + v1.17 (`MainSubject` for Thema) | ✅ shipped — incl. `<MainSubject/>` flag on first Thema (post-WI5.5) | `api/lib/barkpark/plugins/onixedit/export/descriptive_detail.ex` |
| F5 | `<CollateralDetail>` `<TextContent>` with `<Text language="…">`; multi-language TextContent is a 2026 v3 feature | Change log v1.17, [Coming Changes §5.4](https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3) | ✅ shipped — single language per `<Text>` (v1 chain `["nob", "eng", "first-non-empty"]`); multi-language is Phase 7 v3 candidate | `api/lib/barkpark/plugins/onixedit/export/collateral_detail.ex:110` |
| F6 | `<PublishingDetail>` with `<Publisher>`/`<PublishingRole>` + `<PublishingDate>` | Change log v1.17 (PublishingDate breaking change) | ✅ shipped (WI4) | `api/lib/barkpark/plugins/onixedit/export/publishing_detail.ex` |
| F7 | `<ProductSupply>` `<Market>/<Territory>/<CountriesIncluded>` with codes from List 91 (ISO 3166-1 alpha-2). Multi-country form: space-separated (e.g. `NO SE DK FI`) | [Coming Changes §5.1 examples](https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3) | ✅ shipped — emitted via `Enum.join(countries, " ")` | `api/lib/barkpark/plugins/onixedit/export/product_supply.ex:156` |
| F8 | `<Price>` `<CurrencyCode>` from List 96 (ISO 4217); Norwegian retail price defaults to `NOK` | barkpark default + Bokbasen `<spd>` doc on DDS order ("Price in Norwegian øre"). NOK is implicit in Norwegian-market context. | ✅ shipped (default `NOK`) | `api/lib/barkpark/plugins/onixedit/export/product_supply.ex:52` |
| F9 | `<SalesRestriction>` (List 71) — Bokbasen-specific extensions: `13` "To subscription services only", `20` "Except to some subscription services", `06` "To libraries only", `09` "Except to libraries", `99` "No restrictions on sales" | Change log v1.13, [Coming Changes §5.1](https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3) | ❌ missing — no `<SalesRestriction>` builder | n/a — Phase 7 candidate |
| F10 | `<SalesOutlet>` (post-2026 v3) with `<SalesOutletIDType>03` + IDValue from List 139 (e.g. `FAB` Fabel, `EBK` Ebok.no, `NXT` Nextory, `BOO` BookBeat, `STT` Storytel) | [Coming Changes §5.1](https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3) | ❌ missing | n/a — Phase 7 candidate (v3 alignment) |
| F11 | `<ProductFormFeature>` for FSC, PEFC, EUDR, carbon emission disclosure (post-2026 v3) | [Coming Changes §5.13](https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3) | ❌ missing | n/a — Phase 7 candidate |
| F12 | `<ProductFormFeature>` `<ProductFormFeatureType>07` value `Unibok` (Norwegian digital learning resources extension) | Change log v1.12 | ❌ missing | n/a — Phase 7 candidate (digital-learning vertical) |
| F13 | `<ContributorRole>` codes: A15 Preface, A19 Afterword, A23 Foreword, A36 Cover design, A42 Continued, A43 Interviewer, A44 Interviewee + B36 Modernized by (v1.18) | Change log v1.16 + v1.18 | ✅ shipped — pass-through; `Codelists.contributor_role/1` validates against EDItEUR list 17 | `api/lib/barkpark/plugins/onixedit/export/codelists.ex` |
| F14 | `<EpubUsageConstraint>`/`<EpubUsageLimit>` for digital learning resources | Change log v1.12, v1.18, [Coming Changes §5.14](https://bokbasen.jira.com/wiki/spaces/api/pages/3812229200/Coming+Changes+ONIX+2026+-+v3) | ❌ missing (not in Phase 6 scope) | n/a |
| F15 | Codelist version: Bokbasen tracks EDItEUR codelists *issue 73* (April 2026). Importer accepts older issues; exporter emits aligned with whichever issue Bokbasen lifted to. | [ONIX codelists](https://bokbasen.jira.com/wiki/spaces/api/pages/71335938/ONIX+codelists) | ✅ shipped — barkpark vendored set sources from EDItEUR issue 73 (verified by ONIX_BookProduct_3.0_reference.xsd version comment block) | `api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd` |
| F16 | ONIX release: Bokbasen's *export* feed is on the way to ONIX 3.1 (the v3 endpoint advertises `Response body: XML (Onix 3.1)`). *Import* still accepts ONIX 3.0.x. | [ONIX](https://bokbasen.jira.com/wiki/spaces/api/pages/67993632/ONIX) — endpoint description; [Import Service §V2](https://bokbasen.jira.com/wiki/spaces/api/pages/48955439/Import+Service) — "XML (Onix 3.0.x or 3.1.x)" | ✅ shipped at 3.0; 3.1 alignment is Phase 7 | `api/lib/barkpark/plugins/onixedit/export/message.ex:7` |

---

## 4. Norwegian-locale requirements verified

Verification was performed by rendering the two named fixtures
(`api/test/fixtures/onix/full-book.json` and
`api/test/fixtures/onix/synthesized-supplier-book.json`) through
`Barkpark.Plugins.OnixEdit.Export.export/2` and grepping the emitted
ONIX XML. xmllint sweep against the vendored EDItEUR XSD was re-run on
all three valid fixtures (`minimal-book`, `full-book`,
`synthesized-supplier-book`) — all green
(`api/test/barkpark/plugins/onixedit/export/validator_test.exs` 7/7 passing).

| Locale requirement | Expected | full-book.json output | synthesized-supplier-book.json output | Verdict |
|---|---|---|---|---|
| Description language tag — `nob` per ISO 639-2/B (List 74) on `<Text>` `language` attribute | `<Text language="nob">…</Text>` when book carries Norwegian Bokmål text | `<Text language="nob">En medrivende roman om kjærlighet og lengsel.</Text>` | (no CollateralDetail → no `<Text>`) | ✅ pass — `bcp47_to_iso6392b/1` maps `nb-NO`/`nb`/`nob` → `nob` (`api/lib/barkpark/plugins/onixedit/export/collateral_detail.ex:229`) |
| NOK currency — default `<CurrencyCode>NOK</CurrencyCode>` when omitted in book.json | At least one `<CurrencyCode>NOK</CurrencyCode>` | `<CurrencyCode>NOK</CurrencyCode>` plus `<CurrencyCode>EUR</CurrencyCode>` and `<CurrencyCode>SEK</CurrencyCode>` (multi-market fixture) | (no `<Price>` — synthesised supplier emits `<UnpricedItemType>01</UnpricedItemType>` instead) | ✅ pass — default `@default_currency "NOK"` (`api/lib/barkpark/plugins/onixedit/export/product_supply.ex:52`) |
| Country code `NO` — `<CountriesIncluded>NO</CountriesIncluded>` in `<Market>/<Territory>` when omitted | At least one `<CountriesIncluded>NO…</CountriesIncluded>` block | `<CountriesIncluded>NO</CountriesIncluded>` plus `<CountriesIncluded>SE DK</CountriesIncluded>` (multi-market fixture, Bokbasen-canonical space-separated form) | `<CountriesIncluded>NO</CountriesIncluded>` (synthesised default) | ✅ pass — default `@default_country "NO"` (`api/lib/barkpark/plugins/onixedit/export/product_supply.ex:51`) |
| ISO 639-2/B `nob` language tag — task brief mentions a `<Language>` block in `descriptive_detail.ex` (post-WI5.5) | `<Language>` composite with `<LanguageCode>nob</LanguageCode>` | **not emitted** | **not emitted** | ⚠️ **discrepancy with task brief** — `descriptive_detail.ex` has no `<Language>` builder; the only ISO 639-2/B emission in WI1–WI5.5 is the `language="nob"` attribute on `<Text>` in `CollateralDetail` (verified via `grep -rn 'Language\|nob' api/lib/barkpark/plugins/onixedit/`). DescriptiveDetail/Language is a Bokbasen-required *content* field that is **❌ not yet shipped** — see open question Q4 below. |
| MOMS / VAT inclusion (Norwegian VAT 0% on physical books, 0% on e-books, 0% on audiobooks since 2023) | Optional `<Tax>` composite under `<Price>` if VAT is itemised; else `<PriceType>02` "RRP including tax" by default | `<PriceType>02</PriceType>` defaulted, no `<Tax>` composite | n/a (no `<Price>`) | ✅ pass for default — `@default_price_type "02"` (`api/lib/barkpark/plugins/onixedit/export/product_supply.ex:55`). Itemised `<Tax>` block is ❌ missing (Phase 7 candidate). |
| `MainSubject` flag on first Thema subject (Bokbasen v1.17 import requirement) | First `<Subject>` with `<SubjectSchemeIdentifier>93` carries `<MainSubject/>` as its first child | `<Subject><MainSubject/><SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>…</Subject>` | (no Thema codes in fixture → no `<Subject>`) | ✅ pass — emitted by `descriptive_detail.ex:278` (post-WI5.5) |
| ONIX release attribute on `<ONIXMessage>` | `release="3.0"` + EDItEUR reference-tag namespace | `<ONIXMessage xmlns="http://ns.editeur.org/onix/3.0/reference" release="3.0">` | same | ✅ pass — `api/lib/barkpark/plugins/onixedit/export/message.ex:7-8` |
| Sender block — Bokbasen's example uses `<SenderIdentifier>` composite (proprietary IDType=01) + `<SenderName>` + `<EmailAddress>`; barkpark emits free-form `<SenderName>barkpark.cloud</SenderName>` only | `<Sender>` block valid per XSD | `<SenderName>barkpark.cloud</SenderName>` | same | ⚠️ partial — XSD-valid but does not match Bokbasen's *export* shape. Not a blocker because Bokbasen's *import* derives sender from auth (T5). Phase 7 candidate to align shape if barkpark ever emits to non-Bokbasen partners. |

xmllint sweep result (re-run on `2026-04-30`):

```
$ xmllint --noout --schema api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd /tmp/wi7-full-book.xml
/tmp/wi7-full-book.xml validates
$ xmllint --noout --schema api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd /tmp/wi7-synthesized-supplier-book.xml
/tmp/wi7-synthesized-supplier-book.xml validates
$ MIX_ENV=test mix test test/barkpark/plugins/onixedit/export/validator_test.exs
7 tests, 0 failures
```

Full baseline: 698 tests, 0 failures (unchanged from b9602eb).

---

## 5. Open questions for real Bokbasen partner contact

These items cannot be resolved from public documentation and need a real
Bokbasen partner conversation before a Phase 7 ticket can have an
acceptance criterion. Each maps to a Phase 7 candidate task in §6.

- **Q1 — Sender ID format & assignment.** Bokbasen's import API derives
  sender from the OAuth2 token (T5). What value, if any, do they expect
  in `<Header>/<Sender>/<SenderIdentifier>` for *informational*
  reconciliation? Bokbasen's own export uses
  `<SenderIDType>01</SenderIDType><IDTypeName>Bokbasen</IDTypeName><IDValue>902000</IDValue>`
  — does Bokbasen issue a similar proprietary publisher ID? Or is GLN
  preferred? **Pre-flight assumption:** the current placeholder
  `<SenderName>barkpark.cloud</SenderName>` is acceptable; no GLN
  required. Confirm before Phase 7 ships transport code.
- **Q2 — Test/sandbox endpoint.** Public docs name only the production
  hosts (`api.bokbasen.io`). The `https://api.stage.bokbasen.io/dds/`
  audience appears once in DDS docs. Does the metadata import service
  have a mirror at `api.stage.bokbasen.io`? Is there a synthetic fixture
  set publishers can POST against without affecting catalogue state?
- **Q3 — OAuth2 client credentials.** `client_id` / `client_secret`
  issuance process is partner-only. What scopes does barkpark need
  (`metadata:import:onix`, `metadata:import:object`)? Audience is
  `https://api.bokbasen.io/metadata/`.
- **Q4 — Required `<Language>` block.** Bokbasen's import expects a
  `<DescriptiveDetail>/<Language>/<LanguageCode>` composite to identify
  the language of the *work* (vs. the language of `<Text>` content,
  which barkpark already emits in CollateralDetail). The exact
  required-vs-optional status, plus the LanguageRole (`01` "Language of
  text") expectation, lives in the partner-only PDF spec. Is `<Language>`
  *required* for Norwegian-language imports? What LanguageRole codes are
  accepted?
- **Q5 — Onix Block access matrix per sender role.** Public docs give one
  example (Distributor → Blocks 1, 2, 4, 6). What Blocks does a
  *Publisher* sender role get? An *Aggregator* / *Service-bureau*
  sender? barkpark currently emits Blocks 1+2+3+4 — would a
  publisher token successfully write all four?
- **Q6 — Object Import (covers/audio).** Bokbasen treats cover images as
  binaries posted to a separate endpoint keyed by EAN, not as
  `<SupportingResource>` URI references. Does Bokbasen also accept the
  ONIX 3.0 standard `<SupportingResource>` URI form for cover assets, or
  must covers always travel via `…/import/object/v1/{ean}/productimage`?
- **Q7 — Field-level required matrix.** Where is the
  required-vs-recommended-vs-optional matrix authoritative? The
  versioned PDFs (`1.0` … `1.18`) on the import-spec landing page are
  binary downloads behind partner login. Need a publicly-quotable copy
  *or* partner sign-off that the Confluence page text + change log is a
  sufficient substitute.
- **Q8 — V1 vs V2 endpoint preference.** V1 wants a peeled-out
  `<Product>` element; V2 wants a full `<ONIXMessage>`. barkpark
  currently emits `<ONIXMessage>` only. Does Bokbasen recommend V1 or V2
  for new integrations? V2 is described as "documentation in progress…"
  in their public space.
- **Q9 — Norwegian VAT itemisation.** Norwegian books have been zero-VAT
  since 2023 across print, e-book, and audio formats. Bokbasen's import
  spec does not require an itemised `<Tax>` composite under `<Price>` —
  but a `<Tax>` block carrying `<TaxType>04</TaxType>` (zero-rated VAT)
  may be expected for cross-border supply. Confirm.
- **Q10 — `RecordSourceIdentifier`.** Bokbasen's *export* example
  carries a `<RecordSourceIdentifier>` composite identifying who
  originally produced the record (e.g. publisher 0995). Does the
  *import* expect this on incoming records, or is it computed on
  Bokbasen's side from the auth token?
- **Q11 — `EmailAddress` under `<Sender>`.** Bokbasen's export emits
  `<EmailAddress>post@bokbasen.no</EmailAddress>`. Should barkpark
  imports include a contact email for the publisher? If so, which one
  (publisher's, technical contact's, support@barkpark)?

---

## 6. Recommended Phase 7 follow-up tasks

Each bullet is one candidate task title; severity is *informational* —
none of these blocks WI1–WI5.5 since the existing export already
XSD-validates and is Norwegian-locale-correct for the standard ONIX 3.0
surface. Phase 7 prioritisation should be driven by the partner
conversation that resolves §5.

### 6.1 Transport / integration

- **Phase 7 candidate (T1+T2+T4):** "Implement Bokbasen ONIX import client (OAuth2 + POST + async status polling)" — ties Q3.
- **Phase 7 candidate (T3):** "Emit a single peeled `<Product>` element for Bokbasen V1 import path (no `<ONIXMessage>` wrapper)" — ties Q8.
- **Phase 7 candidate (T8):** "Implement Bokbasen Object Import for cover images and audio samples (`POST …/import/object/v1/{ean}/{type}`)" — ties Q6.
- **Phase 7 candidate (Q2):** "Wire Bokbasen sandbox / staging audience for non-production exports".
- **Phase 7 candidate (Q3):** "Provision Bokbasen OAuth2 client credentials and store via `Application.get_env(:barkpark, :bokbasen_oauth_*)`".

### 6.2 Sender-block alignment

- **Phase 7 candidate (T5+Q1):** "Configure Bokbasen-format sender ID in ONIX `<Header>` (proprietary `<SenderIdentifier>` + optional `<EmailAddress>`)" — make the value config-driven via `Application.get_env(:barkpark, :onix_sender_id, "barkpark.cloud")` so per-publisher tokens can override. **Not applied in WI7** because Bokbasen's import does not require it (sender is derived from the OAuth2 token); applying it now is speculative without partner sign-off.

### 6.3 ONIX content gaps

- **Phase 7 candidate (F9):** "Add `<SalesRestriction>` builder with Bokbasen List 71 codes (06/09/13/20/99) for subscription-service market rules" — ties Q5.
- **Phase 7 candidate (F10):** "Add `<SalesOutlet>` builder with List 139 retailer/streaming codes (FAB/EBK/NXT/BOO/STT) — ONIX 2026 v3 alignment".
- **Phase 7 candidate (F11):** "Add `<ProductFormFeature>` for FSC/PEFC/EUDR/carbon emission compliance — ONIX 2026 v3".
- **Phase 7 candidate (F12):** "Add `<ProductFormFeature>` Type=07 with `Unibok` value for Norwegian digital learning resources".
- **Phase 7 candidate (Q4):** "Emit `<DescriptiveDetail>/<Language>` composite (LanguageCode + LanguageRole) for Norwegian-locale book records" — ties Q4.
- **Phase 7 candidate (Q9):** "Add `<Tax>` composite under `<Price>` for itemised Norwegian zero-VAT disclosure".
- **Phase 7 candidate (Q10):** "Add optional `<RecordSourceIdentifier>` composite to Product builder".
- **Phase 7 candidate (F14):** "Add `<EpubUsageConstraint>` / `<EpubUsageLimit>` builders for Norwegian digital learning resources".

### 6.4 Standards alignment

- **Phase 7 candidate (F16):** "Migrate ONIX export from release 3.0 → 3.1 once Bokbasen import accepts 3.1 (already accepted on Import Service V2 today; XSD changeover needed)".
- **Phase 7 candidate (F15):** "Track EDItEUR codelist issue cadence (current 73 → next ~Q3 2026); wire a CI check that flags codelists drift".
- **Phase 7 candidate (Q11):** "Add optional `<EmailAddress>` to `<Sender>` block via `Application.get_env(:barkpark, :onix_sender_email)`".
- **Phase 7 candidate (Q7):** "Acquire Bokbasen partner-spec PDFs (1.18 + future) and cross-walk to barkpark export coverage matrix".

### 6.5 Documentation / process

- **Phase 7 candidate:** "Establish Bokbasen partner-contact runbook — escalation list, support email, expected SLA on rejected records".
- **Phase 7 candidate:** "Set up a Bokbasen-fixture corpus (anonymised real records) for regression testing once sandbox access exists".

---

## Appendix A — config keys mentioned (none added in WI7)

No new `Application.get_env/3` keys were introduced in this WI. Phase 7
work that lifts the placeholder sender ID from a module attribute to
runtime config (Q1, candidate 6.2) should use:

```elixir
# config/config.exs
config :barkpark, :onix_sender_id, "barkpark.cloud"        # placeholder until partner contact (Q1)
config :barkpark, :onix_sender_email, nil                  # optional, ties Q11
config :barkpark, :bokbasen_oauth_client_id, nil           # ties Q3
config :barkpark, :bokbasen_oauth_client_secret, nil       # ties Q3 — must come from env
config :barkpark, :bokbasen_audience, "https://api.bokbasen.io/metadata/"
```

— end of audit —

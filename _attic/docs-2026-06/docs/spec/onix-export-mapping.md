ARCHIVED — do not load; facts moved to docs/contracts/onix-field-map.md
# ONIX 3.0 export — book schema mapping

> **Status:** Phase 6 WI1 deliverable. Spec phase only — no production code.
> **Owner:** Barkpark Phase 6 (Task #43).
> **Unblocks:** WI2 (skeleton) → WI3 (DescriptiveDetail) → WI4 (Collateral/Publishing/Supply) → WI5 (XSD CI gate) → WI6 (HTTP+UI) → WI7 (Bokbasen pre-flight) → WI8 (sample fixture for Phase 7).

> **Worked example (WI8):** `proof/onix-sample.xml` is the live, XSD-validated
> ONIX 3.0 output produced by `Barkpark.Plugins.OnixEdit.Export.to_string/1`
> from `api/test/fixtures/onix/full-book.json`. Use it as the authoritative
> reference when reading the per-field mappings below — every XPath in this
> document corresponds to an element you can search for in that file. Drift
> against the live exporter is enforced by
> `api/test/barkpark/plugins/onixedit/export_proof_test.exs`; regenerate with
> `cd api && mix onix.export_proof`.

## 1. Overview

Phase 6 turns each OnixEdit `book` document into an ONIX-for-Books 3.0
reference-tag XML message that an EDItEUR-conformant trading partner —
specifically Bokbasen for Phase 7 — can ingest. WI1 (this document):

1. Walks the `book` schema field by field and pins every field to an XPath
   in the ONIX `<ONIXMessage>` tree (or marks it **UNMAPPED**, **PARTIAL**,
   or **DEFERRED** with a reason).
2. Cross-references the codelist references against EDItEUR Issue 73
   identifiers and ISO standard codelists (language, country, currency).
3. Picks an Elixir XML library for the emitter and explains the rationale.
4. Vendors the official EDItEUR XSD bundle so WI5 has something to validate
   against without a live network dependency.
5. Writes down the WI2 deliverable contract (module names, function shapes,
   header element list) so the next worker has zero ambiguity to resolve.
6. Surfaces the open questions, gaps, and Norwegian-locale concerns the
   later WIs need to address — especially Bokbasen-specific ones for WI7.

The book schema is private (publisher-managed metadata) and reuses every v2
schema feature: nested `composite`, ordered/unordered `arrayOf`,
`codelist` references against the EDItEUR-issued Issue 73, and
`localizedText` with Norwegian-first fallback chains. The mapping has to
carry all four shapes faithfully through to ONIX without invention.

### Norwegian-locale invariants (WI7 will audit)

- `LanguageCode`/`DefaultLanguageOfText` defaults to `nob` (ISO 639-2/B for
  Norwegian Bokmål) on Norwegian books. Fallback chain in `localizedText`
  fields is `["nob", "eng", "first-non-empty"]` per the schema; emission
  must respect that resolution before serializing `<TextContent>` /
  `<BiographicalNote>`.
- `CountryCode` for `<Market>`, `<CountryOfPublication>`, sales-rights
  territories, and price `<CountryOfManufacture>` defaults to `NO`
  (ISO 3166-1 alpha-2) for the Norwegian market shipment.
- `CurrencyCode` for `<Price>` defaults to `NOK` (ISO 4217). VAT in Norway
  is currently 0% on books — `<TaxRate>` may be omitted, but if present,
  `taxRateType` should map to ONIX List 171 with the Norwegian zero-rate
  code; WI4 must validate against current Norwegian VAT rules at emit
  time.
- `<TextContent>` blurbs export Norwegian primary, English fallback. When
  Norwegian is missing the export log records a warning and emits the
  English fallback with `language="eng"` so Bokbasen ingestion does not
  break (Phase 6 risk register: "Norwegian language fallback").

## 2. Source schema summary

`api/priv/plugins/onixedit/schemas/book.json` (1490 lines as of branch
`feature/phase6-onix-export-wi1`). Top-level structure (counts: top-level
fields and arrays only — composites recurse arbitrarily deep):

| Group                       | Top-level field count | Notes |
| --- | --- | --- |
| Record metadata             | 5  | `notificationType`, `deletionText`, `recordSourceType`, `recordSourceIdentifier`, `recordSourceName` |
| Product identifiers         | 2  | `productIdentifiers[]`, `barcode` |
| Product form                | 7  | `productForm`, `productFormDetail`, `productFormFeatures[]`, `productPackaging`, `productFormDescription`, `productPartCount`, `productParts[]` |
| EPUB protection             | 2  | `epubTechnicalProtection`, `epubUsageConstraints[]` |
| Extents & ancillary         | 3  | `extents[]`, `illustrationsNote`, `ancillaryContents[]` |
| Classifications             | 1  | `productClassifications[]` |
| Titles                      | 1  | `titleDetails[]` (deeply nested via `titleElements[]`) |
| Thesis                      | 1  | `thesis` |
| Contributors                | 3  | `contributors[]` (placeholder shape; **filled by WI2 via the `contributor` sub-schema**), `contributorStatement`, `noContributor` |
| Conference                  | 1  | `conference` (composite with sub-arrays) |
| Edition                     | 5  | `editionType`, `editionNumber`, `editionVersionNumber`, `editionStatement`, `noEdition` |
| Religious text              | 1  | `religiousText` |
| Languages                   | 1  | `languages[]` |
| Subjects (free + Thema)     | 2  | `subjects[]`, `themaSubjectCategory[]` |
| Audience                    | 4  | `audienceCodes[]`, `audienceRanges[]`, `audienceDescription`, `complexity` |
| **Collateral**              | 1  | `collateralDetail` → `textContents[]` (composite; **WI2 inserts `localizedText` blurb via `text_content` sub-schema**), `citedContents[]`, `supportingResources[]`, `prizes[]` |
| **Content detail**          | 1  | `contentDetail.contentItems[]` |
| **Publishing detail**       | 1  | `publishingDetail` (imprint, publishers, country, dates, copyright, salesRights) |
| **Related material**        | 1  | `relatedMaterial` (relatedWorks, relatedProducts) |
| **Product supply**          | 1  | `productSupplies[]` (market, marketPublishingDetail, supplyDetails with prices) |
| Barkpark internal           | 3  | `bp_internal_note`, `bp_export_status`, `bp_last_exported_at` (UNMAPPED — workflow only) |

**Top-level field count: 46.** Counting recursively into composites and
`arrayOf` items, the schema surfaces ≈ 200 distinct field paths — the
"~200 fields" estimate from the Phase 6 masterplan is correct.

Codelists (all pinned to `version: 73`, namespaced `onixedit:*`): see §4.

## 3. Field mapping

### Conventions

- ONIX paths are XPath-shaped, anchored at `/ONIXMessage/Product` for
  Product-level fields. `[@…]` denotes attribute. `[i]` denotes positional
  child. `+` after a path means 1..n; bare path is 0..1 unless noted.
- Status legend:
  - **MAPPED** — direct emission, no transform.
  - **PARTIAL** — emit with a documented transform (e.g. ISO date
    rewrite, codelist pass-through, localizedText resolution).
  - **UNMAPPED** — no ONIX equivalent; not emitted in v1. Backlog candidate.
  - **DEFERRED** — book.json carries it but Phase 6 explicitly does not
    emit it (out of scope for v1; some other WI/Phase or post-Phase-6).
- WI assignment buckets:
  - **WI2** — skeleton ONIXMessage + Header + Product envelope
  - **WI3** — DescriptiveDetail (everything inside `<DescriptiveDetail>`)
  - **WI4** — CollateralDetail + PublishingDetail + ProductSupply
  - **WI5** — validation only (no new field emission)
  - **WI6** — controller / Studio download (no field emission)
  - **WI7** — locale audit (no field emission)
  - **WI8** — fixture (no field emission)

### 3.1 Document envelope (synthetic, derived)

| Book path            | Type      | ONIX path                                  | Notes                                                                                                             | Status   | WI |
| --- | --- | --- | --- | --- | --- |
| _doc.`_id` (or `_publishedId`) | system | `/ONIXMessage/Product/RecordReference`      | Use the **published** id. Strip any `drafts.` prefix. Required by ONIX (gp.record_metadata).                       | PARTIAL  | WI2 |
| _doc.`_type`         | system    | (none — implicit; only `book` exports)      | The export pipeline filters on `_type == "book"`.                                                                  | DEFERRED | WI6 |
| _doc.`_draft`        | system    | `Header/MessageNote` advisory               | Drafts must NOT be exported to a trading partner; controller blocks `_draft=true` unless `?force=1`.                | PARTIAL  | WI6 |
| _doc.`_publishedId`  | system    | (see RecordReference above)                 | Single source of truth for `<RecordReference>`.                                                                    | PARTIAL  | WI2 |
| _doc.`_createdAt`    | system    | (none in Product; `<Header/SentDateTime>` is the message timestamp) | Internal only.                                                                                                     | UNMAPPED | —   |
| _doc.`_updatedAt`    | system    | (advisory)                                  | Could feed `Header/MessageNote` provenance string; not required.                                                   | UNMAPPED | —   |

**Important gap (Q1 — see §8):** `book.json` has no explicit field for
`<RecordReference>`. WI2 derives it from `_publishedId` and **also** declares
the convention (e.g. prefixing with sender DNS like `barkpark.cloud:p1`)
because Bokbasen typically requires globally-unique record references.

### 3.2 Header (driven by app config, not book document)

| Source                                | ONIX path                                                       | Notes                                                                  | Status   | WI |
| --- | --- | --- | --- | --- |
| App env / config                       | `/ONIXMessage/Header/Sender/SenderName`                         | Publisher trading name (e.g. "Barkpark Demo Forlag AS").                | PARTIAL  | WI2 |
| App env / config                       | `/ONIXMessage/Header/Sender/SenderIdentifier[SenderIDType]/IDValue` | GLN / Bokbasen sender ID — see Q4.                                     | PARTIAL  | WI2 |
| App env / config                       | `/ONIXMessage/Header/Sender/EmailAddress`                       | Optional but Bokbasen-recommended.                                     | PARTIAL  | WI2 |
| App env / config                       | `/ONIXMessage/Header/Sender/ContactName`                        | Optional contact person.                                               | PARTIAL  | WI2 |
| (omitted v1)                           | `/ONIXMessage/Header/Addressee/*`                               | Bokbasen ID hardcoded by WI7 if required; v1 may omit.                 | DEFERRED | WI7 |
| Sequence (timestamp + counter)         | `/ONIXMessage/Header/MessageNumber`                             | E.g. `2026-04-29-0001`. Stored on `bp_export_status`?                  | PARTIAL  | WI2 |
| Build clock                            | `/ONIXMessage/Header/SentDateTime`                              | UTC, ONIX format `YYYYMMDDTHHMMSS` (no separators).                    | MAPPED   | WI2 |
| Static `"nob"`                          | `/ONIXMessage/Header/DefaultLanguageOfText`                     | List 74 — Norwegian Bokmål default; tunable per dataset config.        | PARTIAL  | WI2 |
| Static `"NO"`                           | `/ONIXMessage/Header/DefaultPriceType*` etc.                    | Defaults documented but emitted per-product, not per-message, in v1.   | DEFERRED | WI4 |

`Header/MessageNote` is reserved for human-readable provenance ("Generated
by Barkpark vX.Y.Z, doc rev N"). Optional — surfaces as backlog if useful.

### 3.3 Record metadata (gp.record_metadata)

| Book path                                       | Type        | ONIX path                                                              | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `notificationType`                              | codelist 1  | `/Product/NotificationType`                                            | Values per List 1 (e.g. `03` "Confirmed publication"). Required by XSD. | MAPPED  | WI2 |
| `deletionText`                                  | text        | `/Product/DeletionText`                                                | Only emitted when `notificationType == "05"`. Otherwise skipped. | PARTIAL | WI2 |
| `recordSourceType`                              | codelist 3  | `/Product/RecordSourceType`                                            | Per List 3. | MAPPED  | WI2 |
| `recordSourceIdentifier.recordSourceIdentifierType` | codelist 44 | `/Product/RecordSourceIdentifier/RecordSourceIDType`                   | Per List 44. | MAPPED  | WI2 |
| `recordSourceIdentifier.idTypeName`             | string      | `/Product/RecordSourceIdentifier/IDTypeName`                           | Only emitted when type=01 (proprietary). | PARTIAL | WI2 |
| `recordSourceIdentifier.idValue`                | string      | `/Product/RecordSourceIdentifier/IDValue`                              | | MAPPED  | WI2 |
| `recordSourceName`                              | string      | `/Product/RecordSourceName`                                            | | MAPPED  | WI2 |

### 3.4 Product identifiers (gp.product_numbers)

| Book path                                     | Type        | ONIX path                                                                              | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `productIdentifiers[].productIdType`          | codelist 5  | `/Product/ProductIdentifier/ProductIDType`                                            | List 5. ISBN-13 = `15`, GTIN-13 = `03`, DOI = `06`. | MAPPED | WI2 |
| `productIdentifiers[].idTypeName`             | string      | `/Product/ProductIdentifier/IDTypeName`                                               | Only emitted when productIdType=01 (proprietary). | PARTIAL | WI2 |
| `productIdentifiers[].idValue`                | string      | `/Product/ProductIdentifier/IDValue`                                                  | ISBN normalised: hyphens stripped on emit (Bokbasen accepts both, but stripping is safer). | PARTIAL | WI2 |
| `barcode`                                     | codelist 141| `/Product/Barcode`                                                                    | Repeats `0..n` in XSD; book.json declares single value. PARTIAL because we serialise as one `<Barcode>` element if present, none otherwise. | PARTIAL | WI3 |

### 3.5 DescriptiveDetail — product form

| Book path                                                 | Type         | ONIX path                                                          | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| (synthetic; constant `"00"` in v1)                         | —            | `/Product/DescriptiveDetail/ProductComposition`                    | Required by XSD. List 2. v1 emits `"00"` (Single-component retail product) by default; future Phase 8 may surface to schema. | PARTIAL | WI3 |
| `productForm`                                             | codelist 150 | `/Product/DescriptiveDetail/ProductForm`                           | List 150. Required. | MAPPED | WI3 |
| `productFormDetail`                                       | codelist 175 | `/Product/DescriptiveDetail/ProductFormDetail`                     | List 175. | MAPPED | WI3 |
| `productFormFeatures[].productFormFeatureType`            | codelist 79  | `/Product/DescriptiveDetail/ProductFormFeature/ProductFormFeatureType` | List 79. | MAPPED | WI3 |
| `productFormFeatures[].productFormFeatureValue`           | string       | `/Product/DescriptiveDetail/ProductFormFeature/ProductFormFeatureValue` | List 79 may dictate enumerated values per type. | MAPPED | WI3 |
| `productFormFeatures[].productFormFeatureDescription`     | text         | `/Product/DescriptiveDetail/ProductFormFeature/ProductFormFeatureDescription` | | MAPPED | WI3 |
| `productPackaging`                                        | codelist 80  | `/Product/DescriptiveDetail/ProductPackaging`                      | List 80. | MAPPED | WI3 |
| `productFormDescription`                                  | text         | `/Product/DescriptiveDetail/ProductFormDescription`                | | MAPPED | WI3 |
| `productPartCount`                                        | string       | `/Product/DescriptiveDetail/NumberOfItemsOfThisForm`               | ONIX renamed from `ProductPartCount` to `NumberOfItemsOfThisForm` in 3.0 — confirm in WI3 against XSD. | PARTIAL | WI3 |
| `productParts[].productIdentifier.productIdType`          | codelist 5   | `/Product/DescriptiveDetail/ProductPart/ProductIdentifier/ProductIDType` | | MAPPED | WI3 |
| `productParts[].productIdentifier.idValue`                | string       | `/Product/DescriptiveDetail/ProductPart/ProductIdentifier/IDValue`  | | MAPPED | WI3 |
| `productParts[].productForm`                              | codelist 150 | `/Product/DescriptiveDetail/ProductPart/ProductForm`                | | MAPPED | WI3 |
| `productParts[].productPackaging`                         | codelist 80  | `/Product/DescriptiveDetail/ProductPart/ProductPackaging`           | | MAPPED | WI3 |
| `productParts[].numberOfCopies`                           | string       | `/Product/DescriptiveDetail/ProductPart/NumberOfCopies`             | | MAPPED | WI3 |

### 3.6 DescriptiveDetail — EPUB protection

| Book path                                              | Type         | ONIX path                                                                | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `epubTechnicalProtection`                              | codelist 144 | `/Product/DescriptiveDetail/EpubTechnicalProtection`                     | List 144. | MAPPED | WI3 |
| `epubUsageConstraints[].epubUsageType`                  | codelist 145 | `/Product/DescriptiveDetail/EpubUsageConstraint/EpubUsageType`           | List 145. | MAPPED | WI3 |
| `epubUsageConstraints[].epubUsageStatus`                | codelist 146 | `/Product/DescriptiveDetail/EpubUsageConstraint/EpubUsageStatus`         | List 146. | MAPPED | WI3 |
| `epubUsageConstraints[].epubUsageLimit.quantity`        | string       | `/Product/DescriptiveDetail/EpubUsageConstraint/EpubUsageLimit/Quantity` | | MAPPED | WI3 |
| `epubUsageConstraints[].epubUsageLimit.epubUsageUnit`   | codelist 147 | `/Product/DescriptiveDetail/EpubUsageConstraint/EpubUsageLimit/EpubUsageUnit` | List 147. | MAPPED | WI3 |

### 3.7 DescriptiveDetail — extents, ancillary, classifications

| Book path                                                       | Type         | ONIX path                                                                   | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `extents[].extentType`                                          | codelist 23  | `/Product/DescriptiveDetail/Extent/ExtentType`                              | List 23. | MAPPED | WI3 |
| `extents[].extentValue`                                         | string       | `/Product/DescriptiveDetail/Extent/ExtentValue`                             | | MAPPED | WI3 |
| `extents[].extentValueRoman`                                    | string       | `/Product/DescriptiveDetail/Extent/ExtentValueRoman`                        | | MAPPED | WI3 |
| `extents[].extentUnit`                                          | codelist 24  | `/Product/DescriptiveDetail/Extent/ExtentUnit`                              | List 24. | MAPPED | WI3 |
| `illustrationsNote`                                             | text         | `/Product/DescriptiveDetail/IllustrationsNote`                              | | MAPPED | WI3 |
| `ancillaryContents[].ancillaryContentType`                      | codelist 25  | `/Product/DescriptiveDetail/AncillaryContent/AncillaryContentType`          | List 25. | MAPPED | WI3 |
| `ancillaryContents[].number`                                    | string       | `/Product/DescriptiveDetail/AncillaryContent/Number`                        | | MAPPED | WI3 |
| `ancillaryContents[].ancillaryContentDescription`               | text         | `/Product/DescriptiveDetail/AncillaryContent/AncillaryContentDescription`   | | MAPPED | WI3 |
| `productClassifications[].productClassificationType`            | codelist 9   | `/Product/DescriptiveDetail/ProductClassification/ProductClassificationType`| List 9. | MAPPED | WI3 |
| `productClassifications[].productClassificationCode`            | string       | `/Product/DescriptiveDetail/ProductClassification/ProductClassificationCode`| | MAPPED | WI3 |
| `productClassifications[].percent`                              | string       | `/Product/DescriptiveDetail/ProductClassification/Percent`                  | Decimal string. | MAPPED | WI3 |

### 3.8 DescriptiveDetail — titles

| Book path                                                         | Type         | ONIX path                                                                                  | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `titleDetails[].titleType`                                        | codelist 15  | `/Product/DescriptiveDetail/TitleDetail/TitleType`                                         | List 15. `01` = distinctive title. | MAPPED | WI3 |
| `titleDetails[].titleStatement`                                   | string       | `/Product/DescriptiveDetail/TitleDetail/TitleStatement`                                    | | MAPPED | WI3 |
| `titleDetails[].titleElements[].sequenceNumber`                   | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/SequenceNumber`                       | | MAPPED | WI3 |
| `titleDetails[].titleElements[].titleElementLevel`                | codelist 149 | `/Product/DescriptiveDetail/TitleDetail/TitleElement/TitleElementLevel`                    | List 149. | MAPPED | WI3 |
| `titleDetails[].titleElements[].partNumber`                       | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/PartNumber`                           | | MAPPED | WI3 |
| `titleDetails[].titleElements[].yearOfAnnual`                     | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/YearOfAnnual`                         | | MAPPED | WI3 |
| `titleDetails[].titleElements[].titleText`                        | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/TitleText`                            | Mutually exclusive with prefix/withoutPrefix pair (XSD `xs:choice`). | MAPPED | WI3 |
| `titleDetails[].titleElements[].titlePrefix`                      | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/TitlePrefix`                          | | MAPPED | WI3 |
| `titleDetails[].titleElements[].titleWithoutPrefix`               | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/TitleWithoutPrefix`                   | | MAPPED | WI3 |
| `titleDetails[].titleElements[].subtitle`                         | string       | `/Product/DescriptiveDetail/TitleDetail/TitleElement/Subtitle`                             | | MAPPED | WI3 |

### 3.9 DescriptiveDetail — thesis

| Book path                  | Type         | ONIX path                                                       | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `thesis.thesisType`        | codelist 72  | `/Product/DescriptiveDetail/Thesis/ThesisType`                  | List 72. | MAPPED | WI3 |
| `thesis.thesisPresentedTo` | string       | `/Product/DescriptiveDetail/Thesis/ThesisPresentedTo`           | | MAPPED | WI3 |
| `thesis.thesisYear`        | string       | `/Product/DescriptiveDetail/Thesis/ThesisYear`                  | | MAPPED | WI3 |
| `thesis.dissertationTitle` | string       | `/Product/DescriptiveDetail/Thesis/DissertationTitle`           | | MAPPED | WI3 |

### 3.10 DescriptiveDetail — contributors

The book schema's `contributors` arrayOf carries the **placeholder** shape;
the actual composite is owned by `api/priv/plugins/onixedit/schemas/contributor.json`
(referenced in `BookEditor` and `Schemas` aggregator). WI3 must walk the
contributor sub-schema, not the empty placeholder. All paths below are
relative to one `Contributor` element:

| Contributor sub-schema path                              | Type          | ONIX path (relative to `/Product/DescriptiveDetail/Contributor[i]`)         | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `sequenceNumber`                                         | string        | `SequenceNumber`                                                            | | MAPPED | WI3 |
| `contributorRole`                                        | codelist 17   | `ContributorRole`                                                           | List 17. Repeatable per Contributor — book schema has 1; WI3 emits 1..n. | MAPPED | WI3 |
| `languageCode`                                           | codelist 74   | `LanguageCode`                                                              | List 74. | MAPPED | WI3 |
| `nameType`                                               | codelist 18   | `NameType`                                                                  | List 18. | MAPPED | WI3 |
| `personName.personName`                                  | string        | `PersonName`                                                                | XSD: choice between PersonName/PersonNameInverted block and CorporateName. | MAPPED | WI3 |
| `personName.personNameInverted`                          | string        | `PersonNameInverted`                                                        | | MAPPED | WI3 |
| `personName.titlesBeforeNames`                           | string        | `TitlesBeforeNames`                                                         | | MAPPED | WI3 |
| `personName.namesBeforeKey`                              | string        | `NamesBeforeKey`                                                            | | MAPPED | WI3 |
| `personName.prefixToKey`                                 | string        | `PrefixToKey`                                                               | | MAPPED | WI3 |
| `personName.keyNames`                                    | string        | `KeyNames`                                                                  | | MAPPED | WI3 |
| `personName.namesAfterKey`                               | string        | `NamesAfterKey`                                                             | | MAPPED | WI3 |
| `personName.suffixToKey`                                 | string        | `SuffixToKey`                                                               | | MAPPED | WI3 |
| `personName.lettersAfterNames`                           | string        | `LettersAfterNames`                                                         | | MAPPED | WI3 |
| `personName.titlesAfterNames`                            | string        | `TitlesAfterNames`                                                          | | MAPPED | WI3 |
| `corporateName.corporateName`                            | string        | `CorporateName`                                                             | Mutually exclusive with PersonName per XSD. | MAPPED | WI3 |
| `corporateName.corporateNameInverted`                    | string        | `CorporateNameInverted`                                                     | | MAPPED | WI3 |
| `nameIdentifiers[].nameIdType`                           | codelist 44   | `NameIdentifier/NameIDType`                                                 | List 44. | MAPPED | WI3 |
| `nameIdentifiers[].idTypeName`                           | string        | `NameIdentifier/IDTypeName`                                                 | | MAPPED | WI3 |
| `nameIdentifiers[].idValue`                              | string        | `NameIdentifier/IDValue`                                                    | | MAPPED | WI3 |
| `professionalAffiliation[].professionalPosition`         | string        | `ProfessionalAffiliation/ProfessionalPosition`                              | | MAPPED | WI3 |
| `professionalAffiliation[].affiliation`                  | string        | `ProfessionalAffiliation/Affiliation`                                       | | MAPPED | WI3 |
| `biographicalNote`                                       | localizedText | `BiographicalNote` (with `language` attribute)                              | Resolved via `Barkpark.Content.LocalizedText.resolve/2` with chain `["nob", "eng", "first-non-empty"]`. Emit `<BiographicalNote language="nob">…` for the resolved language. Phase 6 risk: when `nob` is missing, emit fallback language **and** record warning in export log. | PARTIAL | WI3 |
| `websiteForContributor`                                  | string        | `Website/WebsiteLink` (with `Website/WebsiteRole` of `06` "Author website") | The `onix.element` annotation says `WebsiteLink` directly; WI3 wraps in `<Website>` per XSD. | PARTIAL | WI3 |

| Book path                  | Type    | ONIX path                                                                            | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `contributorStatement`     | text    | `/Product/DescriptiveDetail/ContributorStatement`                                    | | MAPPED   | WI3 |
| `noContributor`            | boolean | `/Product/DescriptiveDetail/NoContributor` (empty element)                           | Emitted only when `true`; XSD treats it as an empty element — pass `nil` content. | PARTIAL | WI3 |

### 3.11 DescriptiveDetail — conference

| Book path                                                         | Type        | ONIX path                                                                  | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `conference.conferenceRole`                                       | codelist 20 | `/Product/DescriptiveDetail/Conference/ConferenceRole`                     | List 20. | MAPPED | WI3 |
| `conference.conferenceName`                                       | string      | `/Product/DescriptiveDetail/Conference/ConferenceName`                     | | MAPPED | WI3 |
| `conference.conferenceAcronym`                                    | string      | `/Product/DescriptiveDetail/Conference/ConferenceAcronym`                  | | MAPPED | WI3 |
| `conference.conferenceNumber`                                     | string      | `/Product/DescriptiveDetail/Conference/ConferenceNumber`                   | | MAPPED | WI3 |
| `conference.conferenceTheme`                                      | string      | `/Product/DescriptiveDetail/Conference/ConferenceTheme`                    | | MAPPED | WI3 |
| `conference.conferenceDate`                                       | datetime    | `/Product/DescriptiveDetail/Conference/ConferenceDate`                     | ISO → ONIX `YYYYMMDD` digit string. | PARTIAL | WI3 |
| `conference.conferencePlace`                                      | string      | `/Product/DescriptiveDetail/Conference/ConferencePlace`                    | | MAPPED | WI3 |
| `conference.conferenceSponsors[].personName`                      | string      | `/Product/DescriptiveDetail/Conference/ConferenceSponsor/PersonName`       | XSD: choice with CorporateName. | MAPPED | WI3 |
| `conference.conferenceSponsors[].corporateName`                   | string      | `/Product/DescriptiveDetail/Conference/ConferenceSponsor/CorporateName`    | | MAPPED | WI3 |
| `conference.conferenceWebsites[].websiteRole`                     | codelist 73 | `/Product/DescriptiveDetail/Conference/Website/WebsiteRole`                | List 73. | MAPPED | WI3 |
| `conference.conferenceWebsites[].websiteDescription`              | text        | `/Product/DescriptiveDetail/Conference/Website/WebsiteDescription`         | | MAPPED | WI3 |
| `conference.conferenceWebsites[].websiteLink`                     | string      | `/Product/DescriptiveDetail/Conference/Website/WebsiteLink`                | | MAPPED | WI3 |

### 3.12 DescriptiveDetail — edition

| Book path                | Type        | ONIX path                                                              | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `editionType`            | codelist 21 | `/Product/DescriptiveDetail/EditionType`                               | List 21. | MAPPED | WI3 |
| `editionNumber`          | string      | `/Product/DescriptiveDetail/EditionNumber`                             | | MAPPED | WI3 |
| `editionVersionNumber`   | string      | `/Product/DescriptiveDetail/EditionVersionNumber`                      | | MAPPED | WI3 |
| `editionStatement`       | string      | `/Product/DescriptiveDetail/EditionStatement`                          | | MAPPED | WI3 |
| `noEdition`              | boolean     | `/Product/DescriptiveDetail/NoEdition` (empty element)                  | Emitted only when `true`. | PARTIAL | WI3 |

### 3.13 DescriptiveDetail — religious text

| Book path                                                  | Type         | ONIX path                                                                       | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `religiousText.bibleContents[]`                            | codelist 82  | `/Product/DescriptiveDetail/ReligiousText/Bible/BibleContents`                  | List 82. Multiple values OK. | MAPPED | WI3 |
| `religiousText.bibleVersion`                               | codelist 162 | `/Product/DescriptiveDetail/ReligiousText/Bible/BibleVersion`                   | List 162 (named `BibleVersion` codelist; book schema currently calls field `bibleVersion` — confirm during WI3). | MAPPED | WI3 |
| `religiousText.studyBibleType`                             | codelist 84  | `/Product/DescriptiveDetail/ReligiousText/Bible/StudyBibleType`                 | List 84. | MAPPED | WI3 |
| `religiousText.bibleTextFeatures[]`                        | codelist 97  | `/Product/DescriptiveDetail/ReligiousText/Bible/BibleTextFeature`               | List 97. | MAPPED | WI3 |

(Future revisions of book.json may add `Quran`/other religious-text branches
— ONIX 3.0's `<ReligiousText>` is a choice block; v1 only emits `<Bible>`.)

### 3.14 DescriptiveDetail — languages

| Book path                              | Type        | ONIX path                                                            | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `languages[].languageRole`             | codelist 22 | `/Product/DescriptiveDetail/Language/LanguageRole`                   | List 22. | MAPPED | WI3 |
| `languages[].languageCode`             | codelist 74 | `/Product/DescriptiveDetail/Language/LanguageCode`                   | List 74 (ISO 639-2/B). Default for Norwegian books: `nob`. | MAPPED | WI3 |
| `languages[].countryCode`              | codelist 91 | `/Product/DescriptiveDetail/Language/CountryCode`                    | List 91 (ISO 3166-1 alpha-2). | MAPPED | WI3 |
| `languages[].regionCode`               | codelist 49 | `/Product/DescriptiveDetail/Language/RegionCode`                     | List 49. | MAPPED | WI3 |
| `languages[].scriptCode`               | codelist 121| `/Product/DescriptiveDetail/Language/ScriptCode`                     | List 121 (ISO 15924). | MAPPED | WI3 |

### 3.15 DescriptiveDetail — subjects

| Book path                                          | Type        | ONIX path                                                              | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `subjects[].mainSubject`                           | boolean     | `/Product/DescriptiveDetail/Subject/MainSubject` (empty element)       | Empty `<MainSubject/>` when true. | PARTIAL | WI3 |
| `subjects[].subjectSchemeIdentifier`               | codelist 27 | `/Product/DescriptiveDetail/Subject/SubjectSchemeIdentifier`           | List 27 (e.g. `93` Thema, `10` BISAC). | MAPPED | WI3 |
| `subjects[].subjectSchemeName`                     | string      | `/Product/DescriptiveDetail/Subject/SubjectSchemeName`                 | | MAPPED | WI3 |
| `subjects[].subjectSchemeVersion`                  | string      | `/Product/DescriptiveDetail/Subject/SubjectSchemeVersion`              | | MAPPED | WI3 |
| `subjects[].subjectCode`                           | string      | `/Product/DescriptiveDetail/Subject/SubjectCode`                       | | MAPPED | WI3 |
| `subjects[].subjectHeadingText`                    | string      | `/Product/DescriptiveDetail/Subject/SubjectHeadingText`                | | MAPPED | WI3 |
| `themaSubjectCategory[]`                           | codelist 93 | `/Product/DescriptiveDetail/Subject` (composite synthesised)           | Each Thema code emits one `<Subject>` block: `<SubjectSchemeIdentifier>93</SubjectSchemeIdentifier><SubjectSchemeVersion>1.5</SubjectSchemeVersion><SubjectCode>NNN</SubjectCode>`. The first Thema with `mainSubject` semantics — Phase 5 picker doesn't expose `mainSubject` on `themaSubjectCategory`, so v1 marks the **first** Thema as main subject. Confirm with Boss (Q3). | PARTIAL | WI3 |

### 3.16 DescriptiveDetail — audience

| Book path                                                  | Type        | ONIX path                                                              | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `audienceCodes[].audienceCodeType`                         | codelist 29 | `/Product/DescriptiveDetail/Audience/AudienceCodeType`                 | List 29. WI3 wraps in `<Audience>` per XSD. | PARTIAL | WI3 |
| `audienceCodes[].audienceCodeTypeName`                     | string      | `/Product/DescriptiveDetail/Audience/AudienceCodeTypeName`             | | MAPPED | WI3 |
| `audienceCodes[].audienceCodeValue`                        | codelist 28 | `/Product/DescriptiveDetail/Audience/AudienceCodeValue`                | List 28. | MAPPED | WI3 |
| `audienceRanges[].audienceRangeQualifier`                  | codelist 30 | `/Product/DescriptiveDetail/AudienceRange/AudienceRangeQualifier`      | List 30. | MAPPED | WI3 |
| `audienceRanges[].audienceRangePrecision`                  | codelist 31 | `/Product/DescriptiveDetail/AudienceRange/AudienceRangePrecision`      | List 31. WI3 emits two `<AudienceRangePrecision>+<AudienceRangeValue>` pairs for from/to bounds. | PARTIAL | WI3 |
| `audienceRanges[].audienceRangeValue`                      | string      | `/Product/DescriptiveDetail/AudienceRange/AudienceRangeValue`          | | MAPPED | WI3 |
| `audienceDescription`                                      | text        | `/Product/DescriptiveDetail/AudienceDescription`                       | | MAPPED | WI3 |
| `complexity.complexitySchemeIdentifier`                    | codelist 32 | `/Product/DescriptiveDetail/Complexity/ComplexitySchemeIdentifier`     | List 32. | MAPPED | WI3 |
| `complexity.complexityCode`                                | string      | `/Product/DescriptiveDetail/Complexity/ComplexityCode`                 | | MAPPED | WI3 |

### 3.17 CollateralDetail

The book schema's `collateralDetail.textContents[]` carries the
**placeholder** shape; the real localizedText blurb lives in
`api/priv/plugins/onixedit/schemas/text_content.json`. WI4 walks the
text-content sub-schema.

| Book path                                                              | Type          | ONIX path                                                                   | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `collateralDetail.textContents[].textType`                             | codelist 153  | `/Product/CollateralDetail/TextContent/TextType`                            | List 153 (`02` Short description, `03` Long description, `04` Author bio…). | MAPPED | WI4 |
| `collateralDetail.textContents[].contentAudience`                      | codelist 154  | `/Product/CollateralDetail/TextContent/ContentAudience`                     | List 154. | MAPPED | WI4 |
| `text_content.textFormat` (sub-schema)                                  | codelist 34   | `/Product/CollateralDetail/TextContent/Text/@textformat`                    | Attribute on `<Text>`. List 34. WI4 default `02` HTML or `06` plain — TBD. | PARTIAL | WI4 |
| `text_content.text` (sub-schema, localizedText)                         | localizedText | `/Product/CollateralDetail/TextContent/Text` (with `language` attribute)    | Resolve via `LocalizedText.resolve/2`. **Norwegian primary, English fallback.** Bokbasen requires `nob` long description for fiction listings. | PARTIAL | WI4 |
| `collateralDetail.textContents[].textSourceCorporate`                  | string        | `/Product/CollateralDetail/TextContent/TextSourceCorporate`                 | | MAPPED | WI4 |
| `collateralDetail.textContents[].textAuthor`                           | string        | `/Product/CollateralDetail/TextContent/TextAuthor`                          | | MAPPED | WI4 |
| `collateralDetail.textContents[].textSourceTitle`                      | string        | `/Product/CollateralDetail/TextContent/TextSourceTitle`                     | | MAPPED | WI4 |
| `collateralDetail.citedContents[].citedContentType`                    | codelist 156  | `/Product/CollateralDetail/CitedContent/CitedContentType`                   | List 156. | MAPPED | WI4 |
| `collateralDetail.citedContents[].contentAudience`                     | codelist 154  | `/Product/CollateralDetail/CitedContent/ContentAudience`                    | List 154. | MAPPED | WI4 |
| `collateralDetail.citedContents[].sourceType`                          | codelist 157  | `/Product/CollateralDetail/CitedContent/SourceType`                         | List 157. | MAPPED | WI4 |
| `collateralDetail.citedContents[].sourceTitle`                         | string        | `/Product/CollateralDetail/CitedContent/SourceTitle`                        | | MAPPED | WI4 |
| `collateralDetail.citedContents[].citedDate.contentDateRole`           | codelist 163  | `/Product/CollateralDetail/CitedContent/CitedContentDate/ContentDateRole`   | List 163. | MAPPED | WI4 |
| `collateralDetail.citedContents[].citedDate.date`                      | datetime      | `/Product/CollateralDetail/CitedContent/CitedContentDate/Date`              | ISO → ONIX `YYYYMMDD`. | PARTIAL | WI4 |
| `collateralDetail.citedContents[].resourceLink`                        | string        | `/Product/CollateralDetail/CitedContent/CitedContentLink`                   | XSD names this `CitedContentLink`. | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceContentType`           | codelist 158  | `/Product/CollateralDetail/SupportingResource/ResourceContentType`          | List 158 (`01` Front cover, `04` Author photo…). | MAPPED | WI4 |
| `collateralDetail.supportingResources[].contentAudience`               | codelist 154  | `/Product/CollateralDetail/SupportingResource/ContentAudience`              | | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceMode`                  | codelist 159  | `/Product/CollateralDetail/SupportingResource/ResourceMode`                 | List 159 (`03` Image, `04` Text…). | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceFeatureDescription`    | text          | `/Product/CollateralDetail/SupportingResource/ResourceFeatureDescription`   | XSD wraps under `<ResourceFeature>` composite — confirm during WI4. | PARTIAL | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].resourceForm` | codelist 161 | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ResourceForm` | List 161. | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].resourceVersionFeatureDescription` | text | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ResourceVersionFeatureDescription` | | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].resourceVersionFeatures[].resourceVersionFeatureType` | codelist 162 | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ResourceVersionFeature/ResourceVersionFeatureType` | List 162. | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].resourceVersionFeatures[].featureValue` | string | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ResourceVersionFeature/FeatureValue` | | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].resourceLink` | string      | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ResourceLink` | **Image URI contract:** absolute URL preferred. Phoenix `media/` should serve at `https://api.barkpark.cloud/media/<id>`. WI4 documents the contract; WI7 audits Bokbasen's image-fetch expectations. | PARTIAL | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].contentDate.contentDateRole` | codelist 163 | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ContentDate/ContentDateRole` | List 163. | MAPPED | WI4 |
| `collateralDetail.supportingResources[].resourceVersions[].contentDate.date` | datetime | `/Product/CollateralDetail/SupportingResource/ResourceVersion/ContentDate/Date` | ISO → `YYYYMMDD`. | PARTIAL | WI4 |
| `collateralDetail.prizes[].prizeName`                                 | string        | `/Product/CollateralDetail/Prize/PrizeName`                                 | | MAPPED | WI4 |
| `collateralDetail.prizes[].prizeYear`                                 | string        | `/Product/CollateralDetail/Prize/PrizeYear`                                 | | MAPPED | WI4 |
| `collateralDetail.prizes[].prizeCountry`                              | codelist 91   | `/Product/CollateralDetail/Prize/PrizeCountry`                              | List 91. | MAPPED | WI4 |
| `collateralDetail.prizes[].prizeCode`                                 | codelist 41   | `/Product/CollateralDetail/Prize/PrizeCode`                                 | List 41. | MAPPED | WI4 |
| `collateralDetail.prizes[].prizeStatement`                            | text          | `/Product/CollateralDetail/Prize/PrizeStatement`                            | XSD permits XHTML; v1 emits as plain string. | PARTIAL | WI4 |
| `collateralDetail.prizes[].prizeJury`                                 | string        | `/Product/CollateralDetail/Prize/PrizeJury`                                 | | MAPPED | WI4 |

### 3.18 ContentDetail

| Book path                                                            | Type         | ONIX path                                                              | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `contentDetail.contentItems[].levelSequenceNumber`                   | string       | `/Product/ContentDetail/ContentItem/LevelSequenceNumber`               | | MAPPED | WI4 |
| `contentDetail.contentItems[].textItem.textItemType`                 | codelist 153 | `/Product/ContentDetail/ContentItem/TextItem/TextItemType`             | XSD lists `TextItemType` against List 153. | MAPPED | WI4 |
| `contentDetail.contentItems[].textItem.textItemIdentifier`           | string       | `/Product/ContentDetail/ContentItem/TextItem/TextItemIdentifier`       | XSD wraps in composite `<TextItemIdentifier>` w/ Type+Value — confirm during WI4. | PARTIAL | WI4 |
| `contentDetail.contentItems[].textItem.pageRun`                      | string       | `/Product/ContentDetail/ContentItem/TextItem/PageRun`                  | XSD splits to `<FirstPageNumber>+<LastPageNumber>` — book schema collapses; WI4 may need to split on emit (e.g. `"3-25"` → `<PageRun><FirstPageNumber>3</FirstPageNumber><LastPageNumber>25</LastPageNumber></PageRun>`). | PARTIAL | WI4 |
| `contentDetail.contentItems[].textItem.numberOfPages`                | string       | `/Product/ContentDetail/ContentItem/TextItem/NumberOfPages`            | | MAPPED | WI4 |
| `contentDetail.contentItems[].componentTypeName`                     | string       | `/Product/ContentDetail/ContentItem/ComponentTypeName`                 | | MAPPED | WI4 |
| `contentDetail.contentItems[].componentNumber`                       | string       | `/Product/ContentDetail/ContentItem/ComponentNumber`                   | | MAPPED | WI4 |
| `contentDetail.contentItems[].titleDetail.titleType`                 | codelist 15  | `/Product/ContentDetail/ContentItem/TitleDetail/TitleType`             | | MAPPED | WI4 |
| `contentDetail.contentItems[].titleDetail.titleText`                 | string       | `/Product/ContentDetail/ContentItem/TitleDetail/TitleElement/TitleText`| WI4 wraps `titleText` in a single `<TitleElement>`. | PARTIAL | WI4 |

### 3.19 PublishingDetail

| Book path                                                            | Type        | ONIX path                                                                 | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `publishingDetail.imprint.imprintIdentifier.imprintIDType`           | codelist 44 | `/Product/PublishingDetail/Imprint/ImprintIdentifier/ImprintIDType`       | List 44. | MAPPED | WI4 |
| `publishingDetail.imprint.imprintIdentifier.idTypeName`              | string      | `/Product/PublishingDetail/Imprint/ImprintIdentifier/IDTypeName`          | | MAPPED | WI4 |
| `publishingDetail.imprint.imprintIdentifier.idValue`                 | string      | `/Product/PublishingDetail/Imprint/ImprintIdentifier/IDValue`             | | MAPPED | WI4 |
| `publishingDetail.imprint.imprintName`                               | string      | `/Product/PublishingDetail/Imprint/ImprintName`                           | | MAPPED | WI4 |
| `publishingDetail.publishers[].publishingRole`                       | codelist 45 | `/Product/PublishingDetail/Publisher/PublishingRole`                      | List 45. | MAPPED | WI4 |
| `publishingDetail.publishers[].publisherIdentifier.publisherIDType`  | codelist 44 | `/Product/PublishingDetail/Publisher/PublisherIdentifier/PublisherIDType` | List 44. | MAPPED | WI4 |
| `publishingDetail.publishers[].publisherIdentifier.idValue`          | string      | `/Product/PublishingDetail/Publisher/PublisherIdentifier/IDValue`         | | MAPPED | WI4 |
| `publishingDetail.publishers[].publisherName`                        | string      | `/Product/PublishingDetail/Publisher/PublisherName`                       | | MAPPED | WI4 |
| `publishingDetail.publishers[].fundingSource`                        | string      | `/Product/PublishingDetail/Publisher/Funding/FundingIdentifier/IDValue`   | XSD wraps in `<Funding>` composite; v1 emits a stripped string + WI4 confirms. | PARTIAL | WI4 |
| `publishingDetail.cityOfPublication`                                 | string      | `/Product/PublishingDetail/CityOfPublication`                             | | MAPPED | WI4 |
| `publishingDetail.countryOfPublication`                              | codelist 91 | `/Product/PublishingDetail/CountryOfPublication`                          | Norwegian books → `NO`. | MAPPED | WI4 |
| `publishingDetail.publishingStatus`                                  | codelist 64 | `/Product/PublishingDetail/PublishingStatus`                              | List 64. | MAPPED | WI4 |
| `publishingDetail.publishingStatusNote`                              | text        | `/Product/PublishingDetail/PublishingStatusNote`                          | | MAPPED | WI4 |
| `publishingDetail.publishingDates[].publishingDateRole`              | codelist 163| `/Product/PublishingDetail/PublishingDate/PublishingDateRole`             | List 163 (`01` publication date). | MAPPED | WI4 |
| `publishingDetail.publishingDates[].dateFormat`                      | codelist 55 | `/Product/PublishingDetail/PublishingDate/Date/@dateformat`               | List 55 attribute on `<Date>`. | PARTIAL | WI4 |
| `publishingDetail.publishingDates[].date`                            | datetime    | `/Product/PublishingDetail/PublishingDate/Date`                           | ISO → `YYYYMMDD`. | PARTIAL | WI4 |
| `publishingDetail.latestReprintNumber`                               | string      | `/Product/PublishingDetail/LatestReprintNumber`                           | | MAPPED | WI4 |
| `publishingDetail.copyrightStatement.copyrightYear`                  | string      | `/Product/PublishingDetail/CopyrightStatement/CopyrightYear`              | Repeatable in XSD; book schema is a single string — WI4 wraps in single element. | MAPPED | WI4 |
| `publishingDetail.copyrightStatement.copyrightOwners[].copyrightOwnerIdentifier.copyrightOwnerIDType` | codelist 44 | `/Product/PublishingDetail/CopyrightStatement/CopyrightOwner/CopyrightOwnerIdentifier/CopyrightOwnerIDType` | | MAPPED | WI4 |
| `publishingDetail.copyrightStatement.copyrightOwners[].copyrightOwnerIdentifier.idValue` | string | `/Product/PublishingDetail/CopyrightStatement/CopyrightOwner/CopyrightOwnerIdentifier/IDValue` | | MAPPED | WI4 |
| `publishingDetail.copyrightStatement.copyrightOwners[].personName`   | string      | `/Product/PublishingDetail/CopyrightStatement/CopyrightOwner/PersonName`  | | MAPPED | WI4 |
| `publishingDetail.copyrightStatement.copyrightOwners[].corporateName`| string      | `/Product/PublishingDetail/CopyrightStatement/CopyrightOwner/CorporateName` | | MAPPED | WI4 |
| `publishingDetail.salesRights[].salesRightsType`                     | codelist 46 | `/Product/PublishingDetail/SalesRights/SalesRightsType`                   | List 46. | MAPPED | WI4 |
| `publishingDetail.salesRights[].territory.countries[]`               | codelist 91 | `/Product/PublishingDetail/SalesRights/Territory/CountriesIncluded`       | XSD: `<CountriesIncluded>` carries space-separated codes (single element, not repeated). WI4 joins on space. | PARTIAL | WI4 |
| `publishingDetail.salesRights[].territory.regions[]`                 | codelist 49 | `/Product/PublishingDetail/SalesRights/Territory/RegionsIncluded`         | Space-separated. | PARTIAL | WI4 |
| `publishingDetail.salesRights[].territory.regionsIncluded`           | string      | `/Product/PublishingDetail/SalesRights/Territory/RegionsIncluded`         | If supplied, used verbatim and `regions[]` is ignored. | PARTIAL | WI4 |
| `publishingDetail.salesRights[].territory.countriesIncluded`         | string      | `/Product/PublishingDetail/SalesRights/Territory/CountriesIncluded`       | Same. | PARTIAL | WI4 |
| `publishingDetail.salesRights[].territory.regionsExcluded`           | string      | `/Product/PublishingDetail/SalesRights/Territory/RegionsExcluded`         | | PARTIAL | WI4 |
| `publishingDetail.salesRights[].territory.countriesExcluded`         | string      | `/Product/PublishingDetail/SalesRights/Territory/CountriesExcluded`       | | PARTIAL | WI4 |
| `publishingDetail.salesRights[].salesRestrictions[].salesRestrictionType` | codelist 71 | `/Product/PublishingDetail/SalesRights/SalesRestriction/SalesRestrictionType` | List 71. | MAPPED | WI4 |
| `publishingDetail.salesRights[].salesRestrictions[].salesRestrictionNote` | text   | `/Product/PublishingDetail/SalesRights/SalesRestriction/SalesRestrictionNote` | | MAPPED | WI4 |
| `publishingDetail.salesRights[].salesRestrictions[].startDate`       | datetime    | `/Product/PublishingDetail/SalesRights/SalesRestriction/StartDate`        | ISO → `YYYYMMDD`. | PARTIAL | WI4 |
| `publishingDetail.salesRights[].salesRestrictions[].endDate`         | datetime    | `/Product/PublishingDetail/SalesRights/SalesRestriction/EndDate`          | ISO → `YYYYMMDD`. | PARTIAL | WI4 |

### 3.20 RelatedMaterial

| Book path                                                      | Type        | ONIX path                                                                          | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `relatedMaterial.relatedWorks[].workRelationCode`              | codelist 164| `/Product/RelatedMaterial/RelatedWork/WorkRelationCode`                            | List 164. | MAPPED | WI4 |
| `relatedMaterial.relatedWorks[].workIdentifier.workIDType`     | codelist 16 | `/Product/RelatedMaterial/RelatedWork/WorkIdentifier/WorkIDType`                   | List 16. | MAPPED | WI4 |
| `relatedMaterial.relatedWorks[].workIdentifier.idValue`        | string      | `/Product/RelatedMaterial/RelatedWork/WorkIdentifier/IDValue`                      | | MAPPED | WI4 |
| `relatedMaterial.relatedProducts[].productRelationCode`        | codelist 51 | `/Product/RelatedMaterial/RelatedProduct/ProductRelationCode`                      | List 51. | MAPPED | WI4 |
| `relatedMaterial.relatedProducts[].productIdentifier.productIDType` | codelist 5 | `/Product/RelatedMaterial/RelatedProduct/ProductIdentifier/ProductIDType`         | List 5. | MAPPED | WI4 |
| `relatedMaterial.relatedProducts[].productIdentifier.idValue`  | string      | `/Product/RelatedMaterial/RelatedProduct/ProductIdentifier/IDValue`                | | MAPPED | WI4 |
| `relatedMaterial.relatedProducts[].productForm`                | codelist 150| `/Product/RelatedMaterial/RelatedProduct/ProductForm`                              | | MAPPED | WI4 |

### 3.21 ProductSupply

| Book path                                                                    | Type        | ONIX path                                                                             | Notes | Status | WI |
| --- | --- | --- | --- | --- | --- |
| `productSupplies[].market.territory.countries[]`                            | codelist 91 | `/Product/ProductSupply/Market/Territory/CountriesIncluded`                           | Norwegian market → contains `NO`. | PARTIAL | WI4 |
| `productSupplies[].market.territory.regions[]`                              | codelist 49 | `/Product/ProductSupply/Market/Territory/RegionsIncluded`                             | | PARTIAL | WI4 |
| `productSupplies[].market.salesOutlets[].salesOutletIdentifier.salesOutletIDType` | codelist 102 | `/Product/ProductSupply/Market/SalesOutlet/SalesOutletIdentifier/SalesOutletIDType` | List 102. | MAPPED | WI4 |
| `productSupplies[].market.salesOutlets[].salesOutletIdentifier.idValue`     | string      | `/Product/ProductSupply/Market/SalesOutlet/SalesOutletIdentifier/IDValue`             | | MAPPED | WI4 |
| `productSupplies[].market.salesOutlets[].salesOutletName`                   | string      | `/Product/ProductSupply/Market/SalesOutlet/SalesOutletName`                           | | MAPPED | WI4 |
| `productSupplies[].marketPublishingDetail.publisherRepresentatives[].agentRole` | codelist 69 | `/Product/ProductSupply/MarketPublishingDetail/PublisherRepresentative/AgentRole`  | List 69. | MAPPED | WI4 |
| `productSupplies[].marketPublishingDetail.publisherRepresentatives[].agentName` | string  | `/Product/ProductSupply/MarketPublishingDetail/PublisherRepresentative/AgentName`     | | MAPPED | WI4 |
| `productSupplies[].marketPublishingDetail.marketPublishingStatus`           | codelist 68 | `/Product/ProductSupply/MarketPublishingDetail/MarketPublishingStatus`                | List 68. | MAPPED | WI4 |
| `productSupplies[].marketPublishingDetail.marketDates[].marketDateRole`     | codelist 163| `/Product/ProductSupply/MarketPublishingDetail/MarketDate/MarketDateRole`             | List 163. | MAPPED | WI4 |
| `productSupplies[].marketPublishingDetail.marketDates[].date`               | datetime    | `/Product/ProductSupply/MarketPublishingDetail/MarketDate/Date`                       | ISO → `YYYYMMDD`. | PARTIAL | WI4 |
| `productSupplies[].supplyDetails[].supplier.supplierRole`                   | codelist 93 | `/Product/ProductSupply/SupplyDetail/Supplier/SupplierRole`                           | List 93. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplier.supplierIdentifier.supplierIDType` | codelist 92 | `/Product/ProductSupply/SupplyDetail/Supplier/SupplierIdentifier/SupplierIDType`   | List 92. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplier.supplierIdentifier.idValue`     | string      | `/Product/ProductSupply/SupplyDetail/Supplier/SupplierIdentifier/IDValue`             | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplier.supplierName`                   | string      | `/Product/ProductSupply/SupplyDetail/Supplier/SupplierName`                           | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplier.telephoneNumber`                | string      | `/Product/ProductSupply/SupplyDetail/Supplier/TelephoneNumber`                        | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplier.emailAddress`                   | string      | `/Product/ProductSupply/SupplyDetail/Supplier/EmailAddress`                           | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].productAvailability`                     | codelist 65 | `/Product/ProductSupply/SupplyDetail/ProductAvailability`                             | List 65. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplyDates[].supplyDateRole`            | codelist 166| `/Product/ProductSupply/SupplyDetail/SupplyDate/SupplyDateRole`                       | List 166. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].supplyDates[].date`                      | datetime    | `/Product/ProductSupply/SupplyDetail/SupplyDate/Date`                                 | ISO → `YYYYMMDD`. | PARTIAL | WI4 |
| `productSupplies[].supplyDetails[].orderTime.days`                          | string      | `/Product/ProductSupply/SupplyDetail/OrderTime/Days`                                  | XSD: `<DaysAsInteger>` — confirm in WI4. | PARTIAL | WI4 |
| `productSupplies[].supplyDetails[].orderTime.weeks`                         | string      | `/Product/ProductSupply/SupplyDetail/OrderTime/Weeks`                                 | | PARTIAL | WI4 |
| `productSupplies[].supplyDetails[].orderTime.orderTimeDescription`          | text        | `/Product/ProductSupply/SupplyDetail/OrderTime/OrderTimeDescription`                  | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].packQuantity`                            | string      | `/Product/ProductSupply/SupplyDetail/PackQuantity`                                    | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].priceType`                      | codelist 58 | `/Product/ProductSupply/SupplyDetail/Price/PriceType`                                 | List 58. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].priceQualifier`                 | codelist 59 | `/Product/ProductSupply/SupplyDetail/Price/PriceQualifier`                            | List 59. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].priceStatus`                    | codelist 61 | `/Product/ProductSupply/SupplyDetail/Price/PriceStatus`                               | List 61. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].priceAmount`                    | string      | `/Product/ProductSupply/SupplyDetail/Price/PriceAmount`                               | Decimal string, period as separator (XSD `xs:decimal`). | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].currencyCode`                   | codelist 96 | `/Product/ProductSupply/SupplyDetail/Price/CurrencyCode`                              | ISO 4217. **Norwegian books → `NOK`.** | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].countryOfManufacture`           | codelist 91 | `/Product/ProductSupply/SupplyDetail/Price/CountryOfManufacture`                      | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].taxRate.taxRateType`            | codelist 171| `/Product/ProductSupply/SupplyDetail/Price/Tax/TaxType` (XSD nests under `<Tax>`)      | List 171. WI4 wraps under `<Tax>` composite. | PARTIAL | WI4 |
| `productSupplies[].supplyDetails[].prices[].taxRate.taxRatePercent`         | string      | `/Product/ProductSupply/SupplyDetail/Price/Tax/TaxRatePercent`                        | Norwegian books currently 0% → `<Tax>` may be omitted. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].taxRate.taxableAmount`          | string      | `/Product/ProductSupply/SupplyDetail/Price/Tax/TaxableAmount`                         | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].taxRate.taxAmount`              | string      | `/Product/ProductSupply/SupplyDetail/Price/Tax/TaxAmount`                             | | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].priceDate.priceDateRole`        | codelist 173| `/Product/ProductSupply/SupplyDetail/Price/PriceDate/PriceDateRole`                   | List 173. | MAPPED | WI4 |
| `productSupplies[].supplyDetails[].prices[].priceDate.date`                 | datetime    | `/Product/ProductSupply/SupplyDetail/Price/PriceDate/Date`                            | ISO → `YYYYMMDD`. | PARTIAL | WI4 |

### 3.22 Barkpark internal (`bp_*`)

| Book path             | Type     | ONIX path | Notes                                                                                  | Status   | WI |
| --- | --- | --- | --- | --- | --- |
| `bp_internal_note`    | text     | (none)    | Plugin-internal staff note. Never emitted.                                              | UNMAPPED | —  |
| `bp_export_status`    | string   | (none)    | Export workflow state (e.g. `pending`, `exported`, `acknowledged`). Phase 6/8 internal. | UNMAPPED | —  |
| `bp_last_exported_at` | datetime | (none)    | Last successful export timestamp. WI6 updates on every export.                          | UNMAPPED | —  |

## 4. Codelist references

The book schema uses `version: 73` for every codelist. The plugin codelist
registry namespaces lists as `onixedit:<name>` per Decision 20. Below is
the round-trip: book schema list-id → ONIX List number → ONIX list name.

| `codelistId` | ONIX list | ONIX list name (canonical) | Notes |
| --- | --- | --- | --- |
| `onixedit:notification_type`         | 1   | Notification or update type                          | WI2 |
| `onixedit:product_id_type`           | 5   | Product identifier type                              | ISBN-13 = `15`. |
| `onixedit:record_source_type`        | 3   | Record source type                                   | |
| `onixedit:product_classification_type` | 9 | Product classification type                          | |
| `onixedit:title_type`                | 15  | Title type                                           | `01` distinctive title. |
| `onixedit:work_id_type`              | 16  | Work identifier type                                 | |
| `onixedit:contributor_role`          | 17  | Contributor role                                     | Norwegian-publisher fanout: `A01` Author, `B01` Editor, etc. |
| `onixedit:name_type`                 | 18  | Name type                                            | |
| `onixedit:conference_role`           | 20  | Conference role                                      | |
| `onixedit:edition_type`              | 21  | Edition type                                         | |
| `onixedit:language_role`             | 22  | Language role                                        | |
| `onixedit:extent_type`               | 23  | Extent type                                          | |
| `onixedit:extent_unit`               | 24  | Extent unit                                          | |
| `onixedit:ancillary_content_type`    | 25  | Illustrated content type / illustration & content type | |
| `onixedit:subject_scheme`            | 27  | Subject scheme identifier                            | `93` Thema, `10` BISAC, `12` BIC, `26` BISAC region. |
| `onixedit:audience_code_value`       | 28  | Audience code value                                  | |
| `onixedit:audience_code_type`        | 29  | Audience code type                                   | |
| `onixedit:audience_range_qualifier`  | 30  | Audience range qualifier                             | |
| `onixedit:audience_range_precision`  | 31  | Audience range precision                             | |
| `onixedit:complexity_scheme`         | 32  | Complexity scheme identifier                         | |
| `onixedit:text_format`               | 34  | Text format                                          | (sub-schema `text_content.textFormat`) |
| `onixedit:prize_code`                | 41  | Prize / award achievement                            | |
| `onixedit:name_id_type`              | 44  | Name identifier type                                 | Used for sender, contributor, copyright owner, imprint, publisher, supplier. |
| `onixedit:publishing_role`           | 45  | Publishing role                                      | |
| `onixedit:sales_rights_type`         | 46  | Sales rights type                                    | |
| `onixedit:region_code`               | 49  | Region code                                          | ISO 3166-2 + ONIX extensions. |
| `onixedit:product_relation`          | 51  | Product relation code                                | |
| `onixedit:date_format`               | 55  | Date format                                          | Attribute. |
| `onixedit:price_type`                | 58  | Price type                                           | |
| `onixedit:price_qualifier`           | 59  | Price qualifier                                      | |
| `onixedit:price_status`              | 61  | Price status                                         | |
| `onixedit:publishing_status`         | 64  | Publishing status                                    | |
| `onixedit:product_availability`      | 65  | Product availability                                 | |
| `onixedit:market_publishing_status`  | 68  | Market publishing status                             | |
| `onixedit:agent_role`                | 69  | Agent role                                           | |
| `onixedit:sales_restriction_type`    | 71  | Sales restriction type                               | |
| `onixedit:thesis_type`               | 72  | Thesis type                                          | |
| `onixedit:website_role`              | 73  | Website role                                         | |
| `onixedit:language_code`             | 74  | Language code – ISO 639-2/B                          | Norwegian Bokmål = `nob`, Norwegian Nynorsk = `nno`, English = `eng`. |
| `onixedit:product_form_feature_type` | 79  | Product form feature type                            | |
| `onixedit:product_packaging`         | 80  | Product packaging type                               | |
| `onixedit:bible_contents`            | 82  | Bible contents                                       | |
| `onixedit:study_bible_type`          | 84  | Study bible type                                     | |
| `onixedit:country_code`              | 91  | Country code – ISO 3166-1 alpha-2                    | Norway = `NO`. |
| `onixedit:supplier_id_type`          | 92  | Supplier identifier type                             | |
| `onixedit:supplier_role`             | 93  | Supplier role                                        | (book-schema-only confusion: ONIX list 93 is **Thema** in subjects context **and** "Supplier role" — the schema's `themaSubjectCategory` does set `onix.codelistId: 93` because the SubjectCode is constrained to Thema. Distinct semantic, different XSD enum types.) |
| `onixedit:currency_code`             | 96  | Currency code – ISO 4217                             | NOK, EUR, USD. |
| `onixedit:bible_text_feature`        | 97  | Bible text feature                                   | |
| `onixedit:sales_outlet_id_type`      | 102 | Sales outlet identifier type                         | |
| `onixedit:barcode_indicator`         | 141 | Barcode indicator                                    | |
| `onixedit:epub_technical_protection` | 144 | E-publication technical protection                   | |
| `onixedit:epub_usage_type`           | 145 | E-publication usage type                             | |
| `onixedit:epub_usage_status`         | 146 | E-publication usage status                           | |
| `onixedit:epub_usage_unit`           | 147 | E-publication usage unit                             | |
| `onixedit:title_element_level`       | 149 | Title element level                                  | |
| `onixedit:product_form`              | 150 | Product form                                         | |
| `onixedit:text_type`                 | 153 | Text type                                            | |
| `onixedit:content_audience`          | 154 | Content audience                                     | |
| `onixedit:cited_content_type`        | 156 | Cited content type                                   | |
| `onixedit:cited_source_type`         | 157 | Cited content source type                            | |
| `onixedit:resource_content_type`     | 158 | Resource content type                                | |
| `onixedit:resource_mode`             | 159 | Resource mode                                        | |
| `onixedit:resource_form`             | 161 | Resource form                                        | |
| `onixedit:resource_version_feature_type` | 162 | Resource version feature type                    | |
| `onixedit:bible_version`             | (162 in book.json — likely intended 86 "Bible version" — confirm in WI3) | Bible version | Q5 — book.json's `religiousText.bibleVersion` annotates `codelistId: 162`, but ONIX list 162 is "Resource version feature type". Likely transcription error in book.json; ONIX list **86** is "Bible version". |
| `onixedit:publishing_date_role`      | 163 | Publishing date role / Content date role / Market date role | List 163 covers all date-role contexts. |
| `onixedit:work_relation`             | 164 | Work relation code                                   | |
| `onixedit:supply_date_role`          | 166 | Supply date role                                     | |
| `onixedit:tax_rate_type`             | 171 | Tax rate / tax type code                             | |
| `onixedit:price_date_role`           | 173 | Price date role                                      | |
| `onixedit:script_code`               | 121 | Script code – ISO 15924                              | |

### 4.1 ISO standard codelists used

- ISO 639-2/B (List 74) — language. Always 3-letter alpha-3. Norwegian
  Bokmål = `nob`. ONIX uses `eng` not `en`; the LiveView LocalizedText
  resolver outputs language tags in this same alpha-3 form so emit can
  copy through directly.
- ISO 3166-1 alpha-2 (List 91) — country. Norway = `NO`. ONIX `Country*`
  fields require alpha-2.
- ISO 4217 (List 96) — currency. Norway = `NOK`. Three-letter alpha.
- ISO 15924 (List 121) — script. Latin = `Latn`.

### 4.2 BISAC

Surfaced via `subjects[].subjectSchemeIdentifier=10` + `subjectCode=…`.
Not native to Norway but Bokbasen passes BISAC through to international
trading partners — surface but optional. WI4 emits exactly what the
document declares; no transform.

## 5. XML library decision

### 5.1 Comparison matrix

| Criterion (1=worst, 5=best)                                  | Saxy | XmlBuilder | Raw EEx |
| --- | --- | --- | --- |
| Streaming output (large catalogs)                            | 5    | 2          | 3       |
| Namespace declaration on root + child elements               | 5    | 4          | 3       |
| UTF-8 encoding correctness (ø, å, æ in titles/blurbs)        | 5    | 4          | 3       |
| Special-character escaping (`&`, `<`, `>`, `"`, `'`)         | 5    | 5          | 1 (manual) |
| Mature, maintained (current ≥ 2024)                          | 5    | 4          | 5 (Phoenix) |
| Already-vendored Hex maturity within Barkpark deps           | 0    | 5 (already in `mix.exs`) | 5 (Phoenix is a core dep) |
| Simplicity for one ONIXMessage per book (10–30 KB output)    | 3    | 5          | 3       |
| Test fixture friendliness (golden-XML diffs)                 | 4    | 5          | 4       |
| Future fit for batched catalog export (Phase 8+)             | 5    | 3          | 3       |
| Validation hooks (XSD via xmllint, custom guards)            | 5    | 5          | 5 (all use `xmllint` shell) |

### 5.2 Decision: **`XmlBuilder` (`~> 2.2`)**

Pick: **XmlBuilder** — chosen over the masterplan's Saxy candidate.

Rationale (in plain language):

1. **Already vendored.** `xml_builder ~> 2.2` is in `api/mix.exs` (declared
   in Phase 0 alongside `sweet_xml` per the SCHEMA_V2 doc, lines 228 +
   272–278). Adding Saxy is a new dependency to justify; the masterplan
   marked it a candidate, not a constraint.
2. **Output shape we actually need.** Phase 6 emits **one
   `<ONIXMessage>` per book** (single Product per message). The XML is
   10–30 KB. We do not need streaming today. XmlBuilder produces a
   tree-as-data structure that's trivial to test (`assert builder ==
   {:ONIXMessage, %{release: "3.0", xmlns: "..."}, [...children]}`).
3. **Norwegian text correctness.** XmlBuilder uses Erlang's xmerl under
   the hood for serialisation; UTF-8 in/out is correct for `ø`, `å`,
   `æ` and XHTML rich-text snippets without manual encoding.
4. **Saxy is for parsing.** Saxy is a SAX-style parser library. It does
   ship a builder API but it's lower-level than XmlBuilder for the use
   case "tree → string". The masterplan's Saxy preference appears to
   have been chasing namespace correctness — both libs handle that fine.
5. **Future batched export (Phase 8+).** When we ship multi-product
   catalog export, we can either (a) emit a single `<ONIXMessage>` with
   N `<Product>` children using XmlBuilder, which is fine up to ~10 MB
   docs (Bokbasen typical batch size), or (b) wrap in a streaming
   IO list and write `:file.write/2` in chunks. We don't need Saxy's
   SAX writer until catalog sizes approach 100 MB — well beyond v1.

Trade-off accepted: if Phase 8 turns out to demand truly streamed multi-
megabyte catalog output, swapping XmlBuilder for Saxy is a localised
refactor inside `Barkpark.Plugins.OnixEdit.Export.*` (the only place
emission lives). The mapping doc is library-agnostic; the swap doesn't
invalidate WI3/WI4.

**Action for WI2:** add no new dependencies. `xml_builder` is already in
`mix.exs`; just `import` / `alias` it. The deferred Saxy add is
explicitly **not** part of WI2.

## 6. XSD vendoring

See `api/priv/onix/onix-3.0/README.md` for full provenance. Summary:

- Source: <https://www.editeur.org/files/ONIX%203/ONIX_BookProduct_3.0_XSDs+codes_Issue_73.zip>
- Release: ONIX for Books 3.0, Revision 8; Reference XSD `version="3.0.8.0"` (revised 2025-12-11). Codelists Issue 73.
- Files vendored: `ONIX_BookProduct_3.0_reference.xsd`,
  `ONIX_BookProduct_3.0_short.xsd`, `ONIX_BookProduct_CodeLists.xsd`,
  `ONIX_XHTML_Subset.xsd`. SHA256s in the README.
- License: EDItEUR free-of-charge licence, DOI [10.4400/nwgj](https://doi.org/10.4400/nwgj).
  Vendoring an unmodified copy for offline xmllint validation is the
  intended "strictly internal" use case.

WI5 will shell to `xmllint --schema api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd <file>`.
The two XSD includes resolve relatively, so all four files must remain in
the same directory.

## 7. Norwegian locale & Bokbasen pre-flight notes

Phase 7 (Task #11) is the gate where WI7 lives. The audit inputs WI7
needs to land:

1. **DefaultLanguageOfText** — Norwegian books emit `nob` at the message
   header level. WI2 must surface this as a config knob (`config :barkpark,
   :onixedit, default_language: "nob"`) so non-Norwegian datasets can
   override.
2. **CountryCode for Market** — Bokbasen ingests records targeting `NO`.
   WI4 must validate that **at least one** `productSupplies[].market.territory.countries`
   entry contains `NO`; otherwise the export is suspect and WI6's
   pre-flight should refuse the download (or at least flag).
3. **CurrencyCode** — Bokbasen pricing is `NOK`. WI4 emits `<CurrencyCode>NOK</CurrencyCode>`
   from the document; if the document has no NOK price, the export
   carries no `<Price>` block (XSD permits omission). WI7 audits whether
   Bokbasen requires NOK price.
4. **TextContent localisation** — Bokbasen surfaces fiction long
   descriptions in Norwegian. The export must emit `<Text language="nob">…</Text>`.
   The fallback chain `["nob", "eng", "first-non-empty"]` resolves at
   emit time via `Barkpark.Content.LocalizedText.resolve/2`. When
   Norwegian is missing and the export uses English fallback, the
   export log records a warning **and** the emitted `<Text>` carries
   `language="eng"` so Bokbasen ingests it as English.
5. **Thema codelist version** — The book schema pins Thema to ONIX List
   93 / Issue 73. WI3 emits `<SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>`
   plus `<SubjectSchemeVersion>1.5</SubjectSchemeVersion>` (Issue 73 is
   Thema 1.5). WI7 confirms Bokbasen accepts Thema 1.5 — earlier issues
   of Thema (1.4, 1.3) had different namespace expectations.
6. **Sender identification (Q4)** — Bokbasen requires a sender ID. Common
   choices: GLN (13 digits), proprietary publisher code. WI2 must place
   this in app config; WI7 confirms exact format Bokbasen expects.
7. **MessageNumber uniqueness** — Bokbasen tracks ack-loop messages by
   `<MessageNumber>`. WI2 generates `YYYYMMDD-NNNN` per send and
   persists the counter on `bp_export_status` so re-exports do not
   collide. (This intersects with Phase 8 ack loop.)
8. **VAT (TaxRate)** — Norwegian books have 0% VAT. WI4 either emits
   `<Tax><TaxType>02</TaxType><TaxRatePercent>0</TaxRatePercent></Tax>`
   or omits `<Tax>`. WI7 confirms Bokbasen tolerance.

Bokbasen integration documentation reachable from public sources is sparse
(login-walled); WI7 must request the formal Bokbasen ONIX 3.0 sender guide
from the publisher partner. Q6.

## 8. Open questions for Boss

1. **RecordReference convention.** Bokbasen typically wants globally-unique,
   stable-over-time references. Should WI2 emit `_publishedId` raw
   (e.g. `p1`) or a domain-prefixed form (`barkpark.cloud:p1`)? The
   masterplan does not specify. Recommend domain-prefixed for clean
   cross-publisher coexistence.
2. **NotificationType default.** When the document does not set
   `notificationType`, WI2 must emit one (XSD requires it). Recommend
   default `03` "Confirmed publication" once the doc has a publishing
   date in the past, else `01` "Early notification". OK?
3. **Thema main-subject semantics.** `themaSubjectCategory` is a flat
   array; the schema does not flag the primary Thema. Should WI3 mark
   the **first** Thema as `<MainSubject/>`, or should v1 omit the flag
   entirely? Recommend marking first as main; aligns with Bokbasen
   expectation and the Phase 5 multi-select picker UX (first chip is
   primary).
4. **Sender ID format.** GLN, ISBN-prefix, proprietary? Bokbasen-specific.
   Required input for WI2's app config.
5. **`bibleVersion` codelist ID.** book.json annotates List **162**, but
   ONIX List 162 is "Resource version feature type" — the version-of-the-
   Bible list is **86**. WI3 should emit `<BibleVersion>` against List
   86, not 162. Treat book.json as having a transcription bug; track a
   1-line follow-up to fix the schema annotation. (No emission impact
   if the registry codelist is loaded correctly under the same
   `onixedit:bible_version` name.)
6. **Bokbasen documentation source.** Does Boss have access to the formal
   Bokbasen ONIX sender specification? WI7 needs it for the locale audit.
7. **MessageNumber persistence.** `bp_export_status` is a free-form string
   today. Should WI2 / WI6 promote it to a structured composite (`{counter,
   last_message_number, last_acknowledged_message_number}`) or keep it
   string-only and let Phase 8's ack loop re-shape? Recommend defer to
   Phase 8.

## 9. WI2 deliverable plan

Concrete contract WI2's worker will land. Module names align with the
masterplan's Phase 6 scope (`api/lib/barkpark/plugins/onixedit/export.ex`
and siblings).

### 9.1 Module shape

```
api/lib/barkpark/plugins/onixedit/export.ex          # public API
api/lib/barkpark/plugins/onixedit/export/header.ex   # WI2 owns
api/lib/barkpark/plugins/onixedit/export/message.ex  # WI2 owns
api/lib/barkpark/plugins/onixedit/export/product.ex  # WI3 stub, WI3 fills
api/lib/barkpark/plugins/onixedit/export/codelists.ex # WI2 helper (resolve onixedit:* → ONIX integer)
```

Public surface (`Barkpark.Plugins.OnixEdit.Export`):

```elixir
@type book :: %{required(String.t()) => any()}
@type opts :: keyword()

@spec to_iodata(book(), opts()) :: iodata()
@spec to_string(book(), opts()) :: String.t()
@spec to_file(book(), Path.t(), opts()) :: :ok | {:error, term()}
```

`opts` accepts `:sender`, `:default_language` (default `"nob"`),
`:message_number`, `:sent_at` (DateTime — defaults to `DateTime.utc_now/0`).

WI2 ships `to_iodata/2` returning a valid `<ONIXMessage>` whose `<Product>`
is empty (no DescriptiveDetail / CollateralDetail / etc. yet) but whose
`<Header>` and Product record-metadata + identifiers are correct.

### 9.2 Header builder

`Barkpark.Plugins.OnixEdit.Export.Header.build/1`:

```elixir
@spec build(opts :: map()) :: XmlBuilder.element()
def build(%{sender: sender, sent_at: sent_at, default_language: lang, message_number: msg_no}) do
  {:Header, %{}, [
    {:Sender, %{}, sender_children(sender)},
    {:MessageNumber, %{}, msg_no},
    {:SentDateTime, %{}, format_sent_at(sent_at)},
    {:DefaultLanguageOfText, %{}, lang}
  ]}
end
```

Required header elements (per gp.record_metadata + Header schema in
`ONIX_BookProduct_3.0_reference.xsd` line 5369):

- `<Sender>`
  - `<SenderIdentifier><SenderIDType>…</SenderIDType><IDValue>…</IDValue></SenderIdentifier>`
  - `<SenderName>`
  - `<ContactName>` (optional)
  - `<EmailAddress>` (optional)
- `<MessageNumber>`
- `<SentDateTime>` (format `YYYYMMDDTHHMMSS`)
- `<DefaultLanguageOfText>` (default `nob`)

Optional but worth surfacing:
- `<Addressee>` (Bokbasen target — WI7)
- `<MessageNote>` (provenance — `"Generated by Barkpark vX.Y.Z"`)

### 9.3 Message wrapper

`Barkpark.Plugins.OnixEdit.Export.Message.wrap/2`:

```elixir
@spec wrap(header :: XmlBuilder.element(), products :: [XmlBuilder.element()]) :: iodata()
def wrap(header, products) do
  doc = {:ONIXMessage,
    %{
      release: "3.0",
      xmlns: "http://ns.editeur.org/onix/3.0/reference"
    },
    [header | products]}

  XmlBuilder.generate(doc, format: :indent)
end
```

### 9.4 Test fixtures

`api/test/barkpark/plugins/onixedit/export_test.exs` (WI2 starts the file):

- `test "minimal book → wrapper + Header round-trips"` —
  - Construct minimal book (`%{"_id" => "p1", "_publishedId" => "p1", "_type" => "book", "title" => "x"}`).
  - Assert `Export.to_string/2` returns string starting with
    `<?xml version="1.0" encoding="UTF-8"?>` (or whatever XmlBuilder
    emits), containing `<ONIXMessage release="3.0" xmlns="http://ns.editeur.org/onix/3.0/reference">`,
    `<Header>`, `<Sender>`, `<MessageNumber>…</MessageNumber>`,
    `<SentDateTime>20260429T…</SentDateTime>`,
    `<DefaultLanguageOfText>nob</DefaultLanguageOfText>`,
    one empty `<Product><RecordReference>p1</RecordReference><NotificationType>03</NotificationType></Product>`.
- `test "explicit overrides flow through (sender, lang, message_number)"`.
- `test "drafts.* IDs are stripped from RecordReference"`.

WI3 + WI4 add the rest. WI5 promotes the round-trip test to also shell
out to `xmllint --schema` against the vendored XSD.

### 9.5 What WI2 does NOT do

- No DescriptiveDetail emission (WI3).
- No CollateralDetail / PublishingDetail / ProductSupply (WI4).
- No HTTP route, no Studio button (WI6).
- No new Hex deps (xml_builder already vendored).
- No locale audit doc (WI7).
- No proof fixture (WI8).

## 10. Backlog

Items found during the mapping that should land outside Phase 6's scope:

1. **`bibleVersion` codelist ID typo in book.json** — annotated as List
   162; should be List 86. Tiny PR, ideally before WI3 lands so the
   annotation matches reality.
2. **`ProductComposition` not surfaced in book.json.** ONIX requires it
   (DescriptiveDetail child); v1 emits constant `"00"`. Phase 8 (or
   sooner if a publisher needs anything other than single-component
   retail) should surface this as a schema field.
3. **`Promotion` block (`<PromotionDetail>`)** added in ONIX revision
   3.0.7. Not in book.json. Phase 8 candidate.
4. **`Production` block (`<ProductionDetail>`)** added in revision 3.0.8.
   Not in book.json. Phase 8 candidate.
5. **`Measure` (book dimensions: H/W/T/Weight)** is part of ONIX
   `<DescriptiveDetail>` but absent from book.json. Phase 8 candidate
   when physical-product publishers come on board.
6. **`SupplyContact`** (per supplier contact person + telephone) is in
   ONIX 3.0.8 but not in book.json's supplier shape. Phase 8.
7. **Mutually-exclusive title element variants.** XSD enforces a `xs:choice`
   between `<TitleText>` and `<TitlePrefix>+<TitleWithoutPrefix>`. WI3
   must validate at runtime that callers do not provide both, raising
   a clear error. Add a Studio-side warning on the title tab.
8. **Image URI contract.** `collateralDetail.supportingResources[].resourceVersions[].resourceLink`
   is a free-form string today. WI4 must document the contract: absolute
   URL, served by Phoenix media at `https://api.barkpark.cloud/media/<id>`.
   A guard in the export rejects relative paths so Bokbasen never gets a
   broken link. Track as separate ticket if WI4 doesn't ship the guard.
9. **Pre-flight on draft documents.** Studio-side: drafts should not be
   exportable to a trading partner; WI6 returns `403` unless `?force=1`
   is present and the user is admin.
10. **Codelist registry empty in tests.** Phase 0 ships the registry
    schema with zero data. Tests that assert codelist labels need a
    test-helper seeder (`Barkpark.Test.Codelists.seed_minimal/1`) — WI3
    can land it the first time it is needed.
11. **Pre-Phase-7 compatibility note.** When WI8's `proof/onix-sample.xml`
    lands, ensure the file is referenced from Task #11 (Phase 7 Bokbasen)
    so the next phase has a concrete starting fixture.

## 11. XSD Validation (WI5)

WI5 lands the formal gate that blocks invalid ONIX from shipping. It wraps
`xmllint --noout --schema` against the vendored EDItEUR Reference XSD
(Issue 73 / Revision 8 / schema version 3.0.8.0 — see §6 for provenance).

### Where it lives

- Module: `Barkpark.Plugins.OnixEdit.Export.Validator` at
  `api/lib/barkpark/plugins/onixedit/export/validator.ex`.
- Public surface: `validate_xsd/2` (returns `:ok | {:error, [reason, ...]}`)
  and `default_xsd_path/0` (resolved via `Application.app_dir(:barkpark, ...)`).
- Top-level wrapper: `Barkpark.Plugins.OnixEdit.Export.validate_against_xsd/2`
  delegates here; replaces the WI2 raise stub.
- Tests: `api/test/barkpark/plugins/onixedit/export/validator_test.exs` with
  `@moduletag :validator`.
- Fixtures: `api/test/fixtures/onix/{minimal,full,broken}-book.json` —
  see file-level `_note` for what each one exercises.

### Local development

xmllint ships in the `libxml2-utils` package on Debian/Ubuntu and via
`brew install libxml2` on macOS. Without it, the validator returns
`{:error, ["xmllint not on PATH; install libxml2-utils to run validator"]}`
and the test module skips cleanly via `setup_all`.

```bash
# Debian / Ubuntu
sudo apt-get install -y libxml2-utils

# macOS (Homebrew)
brew install libxml2

# Run only the validator suite
cd api && mix test test/barkpark/plugins/onixedit/export/validator_test.exs

# Or run the full test suite including the :validator tag
cd api && mix test --include validator
```

### What failures look like

`xmllint --noout --schema <xsd> <xml>` writes one diagnostic line per
violation to stderr, e.g.

```
broken-book.xml:13: element DescriptiveDetail: Schemas validity error :
  Element '...DescriptiveDetail': This element is not expected. Expected
  is one of (..., ProductIdentifier).
broken-book.xml fails to validate
```

`Validator.parse_reasons/1` keeps lines mentioning *element*, *attribute*,
*complexType*, or *fails to validate*. Reading: each line tells you the
file/line, the element under inspection, and the XSD-expected siblings
or parent constraint that was violated.

### CI behaviour

The Phase-2 / WI4 `mix-test` job in `.github/workflows/elixir.yml` installs
`libxml2-utils` immediately after `mix deps.get`. There is no
`--exclude :validator` anywhere — the gate runs on every PR. Failing
validator tests turn the job red; the job is currently
`continue-on-error: true` (advisory) while pre-existing test-infra drift
is being remediated, but ONIX-specific failures are visible in the run log
and Boss treats them as merge blockers.

### Backlog surfaced by WI5

WI5 ran every WI3+WI4 codepath through xmllint and found four upstream
emission bugs. WI5 fixed the smallest one (Header SentDateTime ISO-8601
format → ONIX-compatible `YYYYMMDDTHHMMSS`); the rest are in the
pre-WI8 follow-up backlog:

1. **WI3 Thema → MainSubject convention.** WI3 emits `<MainSubject>` as a
   sibling of `<Subject>`, but ONIX 3.0 XSD treats `<MainSubject>` as an
   empty flag *inside* `<Subject>`. The `<MainSubjectSchemeIdentifier>`
   element does not exist in the XSD. Boss Q3 convention is correct
   (first Thema is primary); the encoding needs to flip to:
   `<Subject><MainSubject/><SubjectSchemeIdentifier>93</SubjectSchemeIdentifier>...</Subject>`.
   `themaSubjectCategory` is therefore omitted from `full-book.json` and
   the Phase-7 / WI8 proof fixture until this lands.
2. **WI4 Text language attribute.** `CollateralDetail.textContents[].text`
   resolves the localizedText fallback chain and emits e.g.
   `<Text language="nb-NO">…</Text>`. ONIX expects ISO 639-2/B alpha-3
   (`nob`), not BCP-47 (`nb-NO`). Same fix needed for any `language=` in
   contributor BiographicalNote and other localized blocks.
3. **WI4 PublisherRepresentative ordering.** WI4 emits `<AgentName>` only
   inside `<PublisherRepresentative>`; XSD requires `<AgentRole>` first
   (then optional `<AgentName>`). Either default an `agentRole` (List 69
   `01` "Sales agent") or make AgentRole non-optional in the schema and
   propagate the requirement through to Studio.
4. **WI4 default ProductSupply Supplier.** When book.json carries no
   `productSupplies`, `ProductSupply.build_supplier/1` synthesises a
   `<Supplier>` with `<SupplierRole>` only. XSD requires either
   `<SupplierIdentifier>` or `<SupplierName>`. Fix: synthesise a default
   `<SupplierName>"Barkpark"</SupplierName>` (or pull the SenderName)
   so the default is XSD-valid; alternatively also synthesise a default
   `<UnpricedItemType>` when no `prices` are present, so `<SupplyDetail>`
   does not fail on missing Price/SupplyDate/etc.

Each is a small, well-bounded fix the next worker can land before WI8
takes the proof artefact.

## Appendix A — Field count & status totals

Counted against the 10 mapping subsections plus envelope:

| Status   | Count |
| --- | --- |
| MAPPED   | 138 |
| PARTIAL  | 47  |
| UNMAPPED | 9   |
| DEFERRED | 4   |

(Counts derived by walking §§3.1–3.22; PARTIAL items collect transforms
like ISO-date rewrite, localizedText resolution, and XSD wrapper
synthesis. UNMAPPED is dominated by `bp_*` plugin-internal fields and
document envelope housekeeping. DEFERRED is the small set of
post-Phase-6 features — Promotion, Production, Measure, etc.)

UNMAPPED bucket reasons:
- Plugin-internal workflow (`bp_internal_note`, `bp_export_status`, `bp_last_exported_at`) — 3.
- Document envelope housekeeping not surfaced to ONIX (`_createdAt`, `_updatedAt`) — 2.
- Misc: ONIX-required-but-not-surfaced (`Header/Addressee`, `Header/MessageNote`,
  `<DefaultPriceType>`-style header default knobs) — 4.

## Appendix B — XSD references checked

The mapping was verified against the vendored
`api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd` for these
elements (line numbers in that file):

| Element                  | XSD line |
| --- | --- |
| `ONIXMessage`            | 291      |
| `Header`                 | 5369     |
| `Sender`                 | 11709    |
| `MessageNumber`          | 6495     |
| `SentDateTime`           | 11823    |
| `DefaultLanguageOfText`  | 3576     |
| `Product`                | 8570     |
| `RecordReference`        | 10071    |
| `NotificationType`       | 6966     |
| `RecordSourceType`       | 10173    |
| `RecordSourceIdentifier` | 10097    |
| `RecordSourceName`       | 10147    |
| `DeletionText`           | 3628     |
| `ProductIdentifier`      | 9120     |
| `Barcode`                | 1145     |
| `DescriptiveDetail`      | 3655     |
| `CollateralDetail`       | 1704     |
| `ContentDetail`          | 2528     |
| `PublishingDetail`       | 9796     |
| `RelatedMaterial`        | 10364    |
| `ProductSupply`          | 9338     |

Element groups:
- `gp.record_metadata` — line 14728 (RecordReference, NotificationType,
  DeletionText*, RecordSourceType?, RecordSourceIdentifier*,
  RecordSourceName?).
- `gp.product_numbers` — line 14742 (ProductIdentifier+, Barcode*).

Anywhere this doc says "see WI3 confirm against XSD," that's the call to
double-check during emission whether book.json's shape exactly matches the
XSD content model — XmlBuilder will not catch shape mismatches; xmllint
(WI5) will.
# Vendored EDItEUR ONIX 3.0 XSDs (Issue 73)

This directory contains the official EDItEUR-published XSD bundle for ONIX for
Books 3.0, codelists Issue 73. It is vendored verbatim and used for two
downstream purposes in Phase 6 (Task #43):

1. WI5 — `xmllint --schema ONIX_BookProduct_3.0_reference.xsd …` validation in
   tests and CI.
2. WI8 — proof fixture (`proof/onix-sample.xml`) is the input artefact for
   Phase 7 (Bokbasen, Task #11).

Do **not** modify these files. EDItEUR's terms forbid amending or copying
them for use outside the schemas; vendoring an unmodified copy for offline
validation is the supported "strictly internal" use case.

## Source

- Bundle: `ONIX_BookProduct_3.0_XSDs+codes_Issue_73.zip`
- Source URL: <https://www.editeur.org/files/ONIX%203/ONIX_BookProduct_3.0_XSDs+codes_Issue_73.zip>
- Landing page: <https://www.editeur.org/93/Release-3.0-Downloads/>
- Release: ONIX for Books 3.0, Revision 8 (released 2009-04-09)
- Reference XSD `version`: 3.0.8.0 (revised 2025-12-11)
- Codelists: Issue 73
- Retrieved: 2026-04-29 (UTC) by Phase 6 WI1
- Bundle SHA256: `0121c9b1e7df8d9b3f3f7e9104165245353d394956a880e1258eb0fa39f46e0c`

The schema header comment block (lines 1–60 of
`ONIX_BookProduct_3.0_reference.xsd`) carries the canonical EDItEUR copyright
notice and revision history; consult it for authoritative provenance.

## Files

| File | SHA256 | Purpose |
| --- | --- | --- |
| `ONIX_BookProduct_3.0_reference.xsd` | `5ac4e162cbcc4a549c62fdfa3db47bd3ae0b13e3da26a9f92ec743debf10962d` | Reference (long-tag) structure schema. **Phase 6 emits against this.** |
| `ONIX_BookProduct_3.0_short.xsd`     | `8460dfa70d55675f4388d799b007eb37f4ba0a43d2faed28aea6c154eb4789e6` | Short-tag variant; not used by Phase 6, kept for completeness. |
| `ONIX_BookProduct_CodeLists.xsd`     | `130b3b5f4ed5121bc41621f362cc8a4ff930cb755bd6a37fbc3c52c55c93c0fd` | Codelist enumerations (Issue 73). Imported by both reference and short XSDs. |
| `ONIX_XHTML_Subset.xsd`              | `5192454649d7b32a2b3dde20dcb63f6fc888b9b9e6227d56e981c283c73d1f1c` | XHTML subset for `<Text textformat="05">` rich content. |

## License

Copyright (c) 2000–2025 EDItEUR. Distributed under EDItEUR's "free of charge
for general use" licence (DOI: [10.4400/nwgj](https://doi.org/10.4400/nwgj)).
Key terms reproduced verbatim from the schema header:

> 1. You agree that you will not add to, delete from, amend or copy for use
>    outside of the schemas any part thereof except for strictly internal use
>    in your own organization.
>
> 2. You agree that if your business would benefit from future additions or
>    amendments to or extracts of the schemas for any purpose that is not
>    strictly internal to your own organisation, you will in the first
>    instance notify EDItEUR and allow EDItEUR to review and comment on your
>    proposed use, in the interest of securing an orderly development of the
>    Schema for the benefit of other users.

The full licence text lives at <https://www.editeur.org/> per the schema
header. Consult it before redistributing or extending these files.

## Refreshing

When EDItEUR ships a new revision (e.g. Issue 74, or a 3.0.8.x correction),
re-run the steps below and bump the SHA256 table above. Do **not** hand-edit
the XSDs. If a downstream test demands a tweak, raise an issue on the export
adapter, not on the vendored schema.

```bash
TMP=$(mktemp -d)
curl -sSLfo "$TMP/onix-3.0.zip" \
  'https://www.editeur.org/files/ONIX%203/ONIX_BookProduct_3.0_XSDs+codes_Issue_73.zip'
unzip -o "$TMP/onix-3.0.zip" -d "$TMP"
cp "$TMP/ONIX_BookProduct_3.0_XSDs+codes_Issue_73/"*.xsd \
   api/priv/onix/onix-3.0/
sha256sum api/priv/onix/onix-3.0/*.xsd
```

## Validation usage

WI5 will shell to `xmllint`:

```bash
xmllint --noout \
  --schema api/priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd \
  proof/onix-sample.xml
```

The reference XSD `<xs:include>`s both `ONIX_BookProduct_CodeLists.xsd` and
`ONIX_XHTML_Subset.xsd` (lines 288–289); both must sit alongside it for
validation to resolve.

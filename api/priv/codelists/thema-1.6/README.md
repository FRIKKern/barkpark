# Bundled EDItEUR Thema codelist

This directory holds an unmodified snapshot of the EDItEUR **Thema** subject
classification scheme, vendored so the codelist registry seeds on first
boot without asking the publisher to fetch a private snapshot first. Same
posture as the sibling `../onix-issue-73.xml` bundle.

## Files

| Path | Bytes | Source |
|---|---|---|
| `thema-v1.6-en.json` | ~3.5 MB | https://www.editeur.org/files/Thema/1.6/v1.6_en/20250410_Thema_v1.6_en.json |

- **Version**: Thema v1.6 (issue date 2024-10-31, file revised 2025-04-10)
- **Format**: EDItEUR's reference JSON shape — `{CodeList: {ThemaCodes: {Code: [...]}}}`
- **Entries**: 9,187 codes (26 roots, 9,161 with `CodeParent` hierarchy)
- **Languages**: English only in this bundle. EDItEUR publishes per-language
  snapshots in sibling directories (`v1.6_nb`, `v1.6_de`, `v1.6_fr`, …)
  — drop additional files here and extend `seed_thema/1` to merge them
  as `translations` per code if you need a multi-language Studio.

## License

The Thema codelist is © 2003–2026 EDItEUR. From the EDItEUR site:

> Thema is made available free of charge for general use under the licence
> at DOI 10.4400/nwgj. Use of Thema is governed by these terms; if you
> reproduce Thema data you should not add, delete, amend, or rearrange any
> part of it except for strictly internal use in your own organisation.

Barkpark vendors this file unmodified for internal use inside Barkpark
installations — the same posture as the ONIX codelist XML at
`../onix-issue-73.xml`. Downstream redistribution as a derivative work
would require notifying EDItEUR per their license.

## Refreshing

EDItEUR posts revised Thema snapshots in the same directory with a new
date-prefixed filename (`YYYYMMDD_Thema_v1.6_en.json`). To pick up the
latest revision of the current version:

    LATEST=$(curl -sL https://www.editeur.org/files/Thema/1.6/v1.6_en/ \
      | grep -oE '[0-9]{8}_Thema_v1.6_en.json' | sort -u | tail -1)
    curl -fsSL "https://www.editeur.org/files/Thema/1.6/v1.6_en/$LATEST" \
      -o api/priv/codelists/thema-1.6/thema-v1.6-en.json

For a new minor version (1.7, 2.0, …) create a sibling directory
`thema-1.7/` next to this one, drop the new JSON inside, and update
`Barkpark.Codelists.EDItEUR` (`@thema_bundled_path` + `@thema_issue`) to
point at the new file. The next boot re-registers the codelist rows under
the new `(plugin_name, list_id, issue)` triple alongside the previous
issue (history preserved).

## Why JSON, not XML?

Both formats are published on the EDItEUR site. The JSON file is the same
data with less ceremony — no SweetXml stream, no per-element xpath calls
— and at 3.5 MB it's well within the order of magnitude of the existing
ONIX bundle. The ONIX codelist directory stayed with XML because its
parser predates this work; new EDItEUR data we bundle uses JSON.

## Why not "onix-list-93"?

ONIX list 93 is **Supplier role** (16 entries), unrelated to Thema. The
value 93 *does* appear next to Thema in book schemas — it's the
`SubjectSchemeIdentifier` code for Thema inside ONIX list 27 ("Subject
scheme identifier"), not an ONIX codelist ID. Thema is registered under
the friendly key `onixedit:thema`; the alias resolver in
`Barkpark.Content.Codelists` carries a small allowlist of these external
scheme names so they bypass the `friendly → list_<N>` rewrite that would
otherwise mis-route a Thema lookup to Supplier role. See
`api/lib/barkpark/content/codelists.ex` (`@external_scheme_friendlies`).

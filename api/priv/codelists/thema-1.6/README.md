<!-- doc-tier: agent | canonical-for: thema-codelist-vendor | budget: 250tok -->
# Bundled EDItEUR Thema codelist

Unmodified snapshot of the EDItEUR **Thema** subject classification scheme. Same posture as the sibling `../onix-issue-73.xml` bundle.

**License:** © 2003–2026 EDItEUR, DOI `10.4400/nwgj`. Vendored unmodified for internal use. Downstream redistribution as a derivative work requires notifying EDItEUR. See `api/priv/codelists/README.md` for the CANONICAL license posture.

## Files

| Path | Bytes | Source |
|---|---|---|
| `thema-v1.6-en.json` | ~3.5 MB | https://www.editeur.org/files/Thema/1.6/v1.6_en/20250410_Thema_v1.6_en.json |

- **Version**: Thema v1.6 (issue date 2024-10-31, file revised 2025-04-10)
- **Format**: EDItEUR JSON — `{CodeList: {ThemaCodes: {Code: [...]}}}`
- **Entries**: 9,187 codes (26 roots, 9,161 with `CodeParent` hierarchy)
- **Languages**: English only; EDItEUR publishes per-language snapshots in sibling dirs (`v1.6_nb`, `v1.6_de`, …)

## Why JSON (not XML)?

The ONIX codelist stayed with XML because its parser predates this work. For Thema, JSON was preferred — less ceremony, same data, well within the size order of magnitude of the ONIX bundle.

## Refreshing

```bash
LATEST=$(curl -sL https://www.editeur.org/files/Thema/1.6/v1.6_en/ \
  | grep -oE '[0-9]{8}_Thema_v1.6_en.json' | sort -u | tail -1)
curl -fsSL "https://www.editeur.org/files/Thema/1.6/v1.6_en/$LATEST" \
  -o api/priv/codelists/thema-1.6/thema-v1.6-en.json
```

For a new minor version, create a sibling directory (`thema-1.7/`) and update `@thema_bundled_path` + `@thema_issue` in `Barkpark.Codelists.EDItEUR`.

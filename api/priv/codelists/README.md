# Bundled EDItEUR ONIX codelists

This directory holds an unmodified snapshot of the EDItEUR ONIX codelist
data file, vendored so the codelist registry seeds on first boot without
asking the publisher to fetch a private snapshot first.

## Files

| Path | Bytes | Source |
|---|---|---|
| `onix-issue-73.xml` | ~1.4 MB | https://www.editeur.org/files/ONIX%20for%20books%20-%20code%20lists/ONIX_BookProduct_Codelists_Issue_73.xml |

- **Issue**: 73 (released 2026-04-08)
- **Format**: EDItEUR's reference XML codelist format (the same shape
  `Barkpark.Codelists.EDItEUR.parse_xml/1` already parses)
- **Lists included**: 166 distinct `<CodeList>` elements covering every
  ONIX 3.0 / 3.1 codelist (notification types, contributor roles, languages,
  countries, currencies, Thema, etc.)

## License

The ONIX codelists are © 2003–2026 EDItEUR, distributed under the license
at https://doi.org/10.4400/nwgj. The relevant terms (reproduced from the
file header):

> All ONIX standards and documentation – including this document – are
> copyright materials, made available free of charge for general use. A
> full license agreement (DOI: 10.4400/nwgj) that governs their use is
> available on the EDItEUR website. In particular, if you use any of the
> ONIX for Books Product Information Format schemas (RNG, XSD or DTD)
> ('the schemas'), you will be deemed to have accepted these terms and
> conditions:
>
> 1. You agree that you will not add to, delete from, amend or copy for
> use outside of the schemas any part thereof except for strictly
> internal use in your own organization.

Barkpark vendors this file unmodified for internal use inside Barkpark
installations — the same posture as the XSDs already vendored at
`api/priv/onix/onix-3.0/`. Downstream redistribution as a derivative
work would require notifying EDItEUR per their license.

## Refreshing

When EDItEUR publishes a new issue:

    curl -fsSL "https://www.editeur.org/files/ONIX%20for%20books%20-%20code%20lists/ONIX_BookProduct_Codelists_Issue_NN.xml" \
      -o api/priv/codelists/onix-issue-NN.xml

Update `Barkpark.Codelists.EDItEUR` (`@bundled_issue` + `@bundled_filename`)
to point at the new file, commit, and the next boot re-registers the
codelist rows under the new `(plugin_name, list_id, issue)` triple
alongside the previous issue (history preserved).

## Why XML, not JSON?

The research note for this task referenced JSON, but EDItEUR only
distributes the codelist data file in XML on `www.editeur.org`. The
`ns.editeur.org` codelist browser is HTML-only; there is no public JSON
endpoint. The existing `Barkpark.Codelists.EDItEUR.parse_xml/1` already
streams the XML format with bounded memory usage, so the bundled file
matches the format the parser already understands.

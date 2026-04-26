# Bring-Your-Own EDItEUR Codelists

Barkpark's OnixEdit plugin (Phase 4) consumes the EDItEUR ONIX codelist
catalogue at runtime — Contributor Role (list 17), Product Form (list 7),
Notification Type (list 1), Thema subject codes (list 93), and a few
hundred others depending on which book fields a publisher wires up.

**Barkpark ships the parser. Publishers ship the data.** This page
explains why and how.

## Why BYO

The EDItEUR codelist XML is licensed by EDItEUR Limited; the redistribution
terms vary by jurisdiction and by which subset of the lists you use. The
masterplan's risk review (D21, `masterplan-20260425-085425.md`) closed the
license blocker by deciding that Barkpark itself never bundles a real
EDItEUR snapshot. A publisher who has accepted EDItEUR's terms downloads
their own copy and points Barkpark at it.

The repository ships exactly one XML file —
`api/test/fixtures/codelists/synthetic.xml` — covering a tiny synthetic
slice of lists 1, 7, 17, and 64. It is not a real EDItEUR snapshot; do
not derive production codes from it.

## Getting an EDItEUR snapshot

1. Visit https://www.editeur.org/ and follow their instructions for
   downloading the ONIX codelist issue you need (the most common public
   release format is a ZIP containing one large `ONIXCodeTable.xml`).
2. Accept the EDItEUR licence terms at the point of download.
3. Place the XML somewhere the API process can read — e.g.
   `/var/lib/barkpark/codelists/onix-issue-73.xml`.
4. Confirm the *issue number* you downloaded (currently issue 73 is
   widely used). Barkpark records this verbatim — multiple issues can
   coexist in the registry.

## Telling Barkpark where the XML lives

The seeder resolves the path in this fixed precedence:

1. **`--source PATH` argument** to `mix barkpark.codelists.seed`
2. **`BARKPARK_ONIX_CODELIST_PATH` environment variable**
3. **Plugin settings**, key `"codelist_path"` for plugin `"onixedit"`
   (configured via Studio at `/studio/plugins/onixedit/settings`)

If none are configured, the Mix task prints a guided message pointing
publishers at the Studio first-boot wizard and exits 1 — there is no
silent fallback.

## Seeding

```bash
cd api
mix barkpark.codelists.seed \
    --plugin onixedit \
    --issue  73 \
    --source /var/lib/barkpark/codelists/onix-issue-73.xml
```

What you should see:

    ==> seeding codelists for onixedit from … (issue 73)
    ==> seeded N codelist(s):
        - onixedit:list_1
        - onixedit:list_7
        - onixedit:list_17
        - onixedit:list_93
        …

Re-running with the same `--issue` is **idempotent**: existing values and
translations are replaced and the codelist row is upserted. Re-running
with a different `--issue` (e.g. 74) leaves the prior issue intact and
inserts the new one alongside — `Codelists.lookup/3` resolves to the
latest issue by default.

## Expected XML shape

Barkpark expects the canonical EDItEUR codelist XML structure. The
parser reads only the elements listed below; everything else is ignored,
which keeps the parser tolerant to format drift between issues.

```xml
<ONIXCodeTable IssueNumber="73">
  <CodeList>
    <CodeListNumber>17</CodeListNumber>
    <CodeListDescription>Contributor role code</CodeListDescription>
    <Code>
      <CodeValue>A01</CodeValue>
      <Description language="eng">By (author)</Description>
      <Description language="nob">Forfatter</Description>
    </Code>
    <Code>
      <CodeValue>B01</CodeValue>
      <CodeDescription>Edited by</CodeDescription>
    </Code>
  </CodeList>
  <!-- … further <CodeList> entries … -->
</ONIXCodeTable>
```

Element-by-element:

| Element                | Notes                                                                 |
|------------------------|-----------------------------------------------------------------------|
| `ONIXCodeTable@IssueNumber` | Issue / version. Falls back to `--issue` when missing.            |
| `CodeList`             | One ONIX list. Wrappers without `CodeListNumber` are silently skipped.|
| `CodeListNumber`       | Numeric ID. Becomes `list_id = "onixedit:list_<N>"` in the registry.  |
| `CodeListDescription`  | Human-readable list name.                                             |
| `Code`                 | One entry within a list.                                              |
| `CodeValue`            | The code itself (e.g. `A01`, `BC`, `nob`).                            |
| `CodeDescription`      | Default-language label. Treated as `eng` if no `Description` siblings.|
| `Description@language` | Per-language label (BCP-47 tag). Multiple allowed per `Code`.         |
| `CodeNotes`            | Optional long-form description. Stored as the `eng` `description`.    |
| `ParentCode`           | Code of the parent entry (Thema, list 93). Builds `parent_id` links.  |

## Hierarchy (Thema, list 93)

ONIX issue 73 has only a handful of codelists with intrinsic hierarchy.
The seeder pays attention to a `<ParentCode>` element on each `<Code>`:

```xml
<Code>
  <CodeValue>ABA</CodeValue>
  <CodeDescription>Theory of art</CodeDescription>
  <ParentCode>AB</ParentCode>
</Code>
```

The parser collects all codes for a list, then walks them once more to
build a tree before handing the result to the Phase 0 registry, which
performs the `parent_id` self-reference inserts. Codes whose parent is
not present in the same `<CodeList>` are kept as roots — forward
references inside the list resolve correctly.

If your snapshot encodes Thema hierarchy by code-prefix instead of an
explicit `<ParentCode>`, run a one-time conversion before seeding (or
file an issue — the parser can grow a `--derive-thema-hierarchy` flag
later if there is demand).

## Stale-codelist remediation

Once you upgrade to a new issue, some codes may have been retired.
Barkpark plans to ship `mix barkpark.codelists.scan` to walk every
document and report references to retired codes; severity is *warning*
in Studio, not blocking. (Tracked under the Phase 4 task description —
see `doey task get --id 8`.)

## Tests

The synthetic fixture is exercised by `Barkpark.Codelists.EDItEURTest`:

    cd api
    mix test test/barkpark/codelists/editeur_test.exs

This is the only XML the repository carries. CI runs the parser end-to-end
against the synthetic fixture and asserts post-import row counts; it does
**not** run against a real EDItEUR snapshot.

# EDItEUR Codelists — bundled default + Bring-Your-Own

Barkpark's OnixEdit plugin (Phase 4) consumes the EDItEUR ONIX codelist
catalogue at runtime — Contributor Role (list 17), Product Form (list 7),
Notification Type (list 1), Thema subject codes (list 93), and a few
hundred others depending on which book fields a publisher wires up.

**Barkpark ships a bundled default codelist snapshot and the parser.**
The repo vendors a real EDItEUR **Issue 73** snapshot at
`api/priv/codelists/onix-issue-73.xml` (~1.4 MB, unmodified — see
`api/priv/codelists/README.md`), which `Barkpark.Codelists.EDItEUR.seed_bundled/0`
loads on every boot (wired via OnixEdit's `codelist_seeders/0` in
`api/lib/barkpark/plugins/onixedit.ex`). Out of the box, a fresh install
has Issue 73 codes available with no publisher action. This page explains
the bundled default and how to bring your own for a different issue or
publisher.

## Why bring your own

The EDItEUR codelist XML is © EDItEUR Limited, distributed under the
license at https://doi.org/10.4400/nwgj. Barkpark vendors the Issue 73
snapshot **for internal use** inside Barkpark installations — the same
posture as the ONIX XSDs already vendored at `api/priv/onix/onix-3.0/`
(see the README's License section). Downstream redistribution as a
derivative work would require notifying EDItEUR per their terms.

Bring-your-own is the path when you need a **different issue** (e.g. a
newer Issue 74) or codelists from **another publisher** that Barkpark
does not bundle. A publisher who has accepted EDItEUR's terms downloads
their own copy and points Barkpark at it via the precedence below; the
seeded issue coexists alongside the bundled Issue 73 in the registry.

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
   (configured via Studio at `/studio/production/_plugins/onixedit/settings`
   — the admin plugin-settings route is `/studio/:dataset/_plugins/:plugin/settings`)

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

The synthetic fixture at `api/test/fixtures/codelists/synthetic.xml`
(a tiny synthetic slice of lists 1, 7, 17, and 64 — not a real EDItEUR
snapshot, do not derive production codes from it) is exercised by
`Barkpark.Codelists.EDItEURTest`:

    cd api
    mix test test/barkpark/codelists/editeur_test.exs

CI runs the parser end-to-end against the synthetic fixture and asserts
post-import row counts. The vendored Issue 73 snapshot
(`api/priv/codelists/onix-issue-73.xml`) is the real-data snapshot the
repository carries and is what `seed_bundled/0` loads at boot.

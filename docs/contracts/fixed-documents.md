<!-- doc-tier: agent | canonical-for: schema-fixed-documents | budget: 300tok -->
# Fixed documents

`fixed_documents` (`fixedDocuments` on the wire) lists a type's document ids, e.g. `["side-om-oss"]`. On that type (`Content.FixedDocuments`):

- A create of an id not listed, with no row of that id and type, is refused: `create`, `createIfNotExists`, `createOrReplace`, a duplicate. `[]` allows no new document.
- A listed id may be created while it does not exist (first import, restore).
- Deleting a listed document is refused. An unlisted one may be deleted.
- Edits, publish, unpublish, discard and a mutate `delete` of `drafts.<id>` (the draft only) are unchanged. `Content.delete_document/4` of `drafts.<id>` removes both rows, so a listed id is refused there.

Refusal: 409 `fixed_document`, `details.{action,type,id}`; one refused op fails the batch. Emptying a dataset or workspace and sync are unchanged. Ids are strings without `drafts.`/`versions.`; else 422. `null` removes the list; no key = no limit. A list on a shared schema holds in every workspace that has no schema of its own for the type.

---
'@barkpark/nextjs': minor
---

`defineActions` now includes `deleteDoc(id, type)` — the Server Action for deleting a document (a delete button in a form), completing the mutation set alongside `createDoc`/`patchDoc`/`publish`/`unpublish`. Like the others, it fans out `doc:<id>` + `type:<type>` revalidate tags so cached fetches refresh.

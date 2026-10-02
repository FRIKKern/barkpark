---
'@barkpark/core': minor
---

Reads can now ask the server to resolve query-shaped task blocks: `client.doc(type, id, { resolve: 'tasks' })` and `client.docs(type, { resolve: 'tasks' })` send `?resolve=tasks`.

The API has honoured that parameter since the p-resolve-seam work (`query_controller.ex`, `maybe_resolve_tasks/3`): it runs the same resolver Studio runs, swapping every PortableDoc task block that carries a `query` for a live `snapshot` of the matching rows, perspective-threaded like the documents around it. Nothing in the JS SDK could send it, so every query-shaped task block reached a consumer with no rows — and a renderer that reads `snapshot` (`@barkpark/react`'s task-board among them) had nothing to draw. Measured on the production dataset: of 39 task blocks across 21 papers, 19 arrived query-only and empty on a bare read; all 39 arrive snapshot-filled under `?resolve=tasks`.

Strictly opt-in and additive. Omit it and the request is byte-identical to before — no `resolve` param is sent — so no existing consumer changes shape. Author-pinned blocks (a literal `snapshot`/`task` and no `query`) are left untouched by the server either way. The new `ResolveSpec` type is exported from the package root, and `resolve` rides beside `expand` / `fields` / `perspective` on the same query builder rather than replacing any of them.

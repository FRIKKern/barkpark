<!-- doc-tier: agent | canonical-for: paper-masters | budget: 1000tok -->
# 0010 — Paper masters: storage, detached and linked insertion (2026-09-24)

Ratified by main, 2026-09-23 (`cd-5b-template-generalization`). Code:
`api/lib/barkpark/plugins/bulldocs/masters.ex`, `masters/linked.ex`.

## 1. Storage

One `paper_master` document per master (Bulldocs, private). `content`: `node`
(verbatim), `tier`, `block_type`, `source_paper`, `source_block_id`. `rev` is
the master revision. Not masterable: an unclassified type, `locked: true`, a
slot role, a `fieldName` binding.

## 2. Tenancy

A master is born in the saving paper's workspace, project and dataset, and is
looked up only INSIDE the target paper's. A foreign master answers exactly
like a missing one: no existence oracle.

## 3. Detached insertion

ONE `insert-after`/`append-block` op through
`Content.apply_paper_block_ops_once/6` (every guard runs; a retry replays).
Fresh ids `mst-` + sha256(request id, master id, old id); internal `anchor`
and `#id` hrefs follow them. Root provenance
`master: {id, rev, mode: "detached"}`. Later master edits never reach it.

## 4. Editor (task-3b6e562e916c8ce4)

Socket events, no route: `paper-save-master`, `paper-insert-master`
(through `paper_ops/5`, request id, replay). The picker lists
`list_for_paper/1` only; the public reader offers neither action. Host code
reaches the plugin only via `PaperMastersSeam` (registry + enablement).

## 5. Linked instances (task-59f078a2fd248698, main 2026-09-24T02:14Z)

- Block `master-ref`: `{master, version}`; `version: nil` follows latest, a
  `_rev` pins. Inserted by `paper-insert-master` with `mode: "linked"`.
- Resolved at READ time: compose → `PdMasterRef`, the walker injects
  `:masters[key]` HTML. Non-resolving callers (body_html cache, delta frames,
  email, Go TUI) show a neutral "Linked master"; JS degrades it like `embed`.
- `Linked.render_map/3` batches per nesting level, at most 3 levels; a
  master already on the chain renders "Master unavailable", as do missing
  and foreign masters (identical bytes). The public reader resolves
  published master rows only.
- A master edit never writes an instance paper.
- Detach (`paper-detach-master`): `replace-block` with a detached copy
  (§5b). Pin (`paper-pin-master`): `patch-block` `version` = a rev (§5b);
  Unpin sets nil. Both ride the request-identified op path.
- Deleting a master with live instances (same-scope papers, any depth) is
  refused (`before_delete`): 409 `halted`, listing their ids.
- `save_master` PUBLISHES the master (task-59be65118320fa0e); later edits
  are drafts, and the reader shows the published row. Rejected: the reader
  resolving a draft-only master (it would re-expose a withdrawn one); an
  insert warning only. Nested master-refs preview in Studio.

## 5b. Pin and Detach take PUBLISHED content (task-881d4b6e857b1b65, task-01c812041613a8d3)

Both need only paper write access and publish with the paper, so neither
may reach a master draft.
- Pin takes the published row's rev (a draft rev is never published, so it
  read "Master unavailable" forever); Studio previews what readers see.
- Detach copies what the public reader shows: the pinned published revision,
  else the latest published row.
- Nothing published (draft-only, withdrawn, a pre-§5b draft-rev pin):
  refused, `master_unpublished`; foreign stays `master_not_found`.

Rejected: refusing while a draft exists (a pin guards a paper from that
edit); pins resolving in any state; detaching the draft when the actor may
publish the master (the socket checks paper grants only; publish first).
Unpublishing still hides every pin.

## 6. Deferred (deliberate)

- A blockref `target` is not retargeted across papers.
- No live push: an open editor sees a master edit on its next read. It
  needs a jsonpath scan over the tenant's papers per master save.
- The 409 lists every same-tenant instance id, not grant-narrowed:
  `:before_delete` carries no caller grants.

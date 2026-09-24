<!-- doc-tier: agent | canonical-for: paper-masters | budget: 1000tok -->
# 0010 — Paper masters: storage, detached and linked insertion (2026-09-24)

Ratified by main, 2026-09-23 (`cd-5b-template-generalization`). Code:
`api/lib/barkpark/plugins/bulldocs/masters.ex`, `masters/linked.ex`.

## 1. Storage

One document per master, type `paper_master` (Bulldocs, private). `content`:
`node` (the saved block, verbatim), `tier`, `block_type`, `source_paper`,
`source_block_id`. The row's `rev` is the master revision. Not masterable: an
unclassified type, `locked: true`, a slot role, a `fieldName` binding.

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
  `:masters[key]` HTML. Callers that do not resolve (body_html cache, delta
  frames, email, Go TUI) show a neutral "Linked master". The JS renderer is
  unchanged (generic unknown-block degrade; out of pd-parity scope, like
  `embed`).
- `Linked.render_map/3` batches per nesting level (current rows + pinned
  revisions), at most 3 levels; a master already on the chain renders
  "Master unavailable", as do missing and foreign masters (identical bytes).
  The public reader resolves published master rows only.
- A master edit never writes an instance paper.
- Detach (`paper-detach-master`): `replace-block` with a detached copy of
  what it shows. Pin (`paper-pin-master`): `patch-block` `version` = a rev
  (§5b); Unpin sets nil. Both ride the request-identified op path.
- Deleting a master with live instances (same-scope papers holding a
  `master-ref` to it, any depth) is refused (`before_delete`): 409
  `halted`, listing their ids (never another tenant's).
- `save_master` PUBLISHES the master (task-59be65118320fa0e): the save is the
  author's choice to reuse it. Later edits are drafts; the reader shows the
  published row. Rejected: the reader resolving a draft-only master (an
  UNPUBLISHED master is draft-only too: it would re-expose what the author
  withdrew); an insert warning only. A nested master-ref previews in
  Studio; the slash menu offers "(linked)".

## 5b. Pin freezes the latest PUBLISHED rev (task-881d4b6e857b1b65)

Publish mints a new rev, so a pin to a draft rev read "Master unavailable"
publicly forever. Pin takes the published row's rev; Studio previews what
readers see. No published row: refused, `master_unpublished`. Rejected:
refusing while a draft exists (a pin guards a paper from that pending edit);
the reader resolving pins in any state (a paper editor would publish a
master draft). Unpublishing still hides every pin.

## 6. Deferred (deliberate)

- A blockref `target` is not retargeted across papers.
- No live push: an open editor sees a master edit on its next read. It
  needs a jsonpath scan over the tenant's papers per master save.
- The 409 lists every same-tenant instance id, not grant-narrowed:
  `:before_delete` carries no caller grants.

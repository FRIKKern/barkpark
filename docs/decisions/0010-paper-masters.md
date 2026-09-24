<!-- doc-tier: agent | canonical-for: paper-masters | budget: 1000tok -->
# 0010 — Paper masters: storage, detached insertion, seam (2026-09-24)

Ratified by main, 2026-09-23, for `cd-5b-template-generalization` (parent
`composition-doctrine`). Code: `api/lib/barkpark/plugins/bulldocs/masters.ex`.

## 1. Storage: one document per master

A master is its own document, type `paper_master` (Bulldocs schema
`priv/plugins/bulldocs/schemas/paper_master.json`, visibility `private`).
Fields, all in `content`:

| field | meaning |
|---|---|
| `node` | the saved block, verbatim, its authored ids included |
| `tier` | `element`, `widget` or `section` (`PortableDoc.Tiers.tier_of/1`) |
| `block_type` | the node's `type` |
| `source_paper`, `source_block_id` | where it was saved from |

The row's `title` names it; the row's own `rev` column is the master revision.
Not masterable: an unclassified type, a node carrying `locked: true` or a
paper slot role (`title`/`featured`/`ingress`), or a `fieldName` binding (a
copy would bind a second block to one schema field).

## 2. Tenancy

A master is born in the saving paper's workspace, project and dataset.
Insertion looks the master up INSIDE the target paper's workspace, project
and dataset, so a master from another tenant answers `:master_not_found` —
the same answer as a missing one, so no existence oracle.

## 3. Detached insertion and the seam

Insert builds ONE op — `insert-after` (or `append-block` at the top level)
carrying the copy — and applies it through
`Content.apply_paper_block_ops_once/6`. There is no side door: every Patch
constraint, ratchet, normalization, encryption and projection step runs, and
a retried request replays its receipt.

The copy:

- every map in the node that carries an `id` gets a fresh one,
  `mst-` + 12 hex of sha256(request id, master id, old id). Derived, not
  random, so a retry rebuilds the byte-identical op the idempotency
  fingerprint needs;
- its root carries `"master" => {"id", "rev", "mode": "detached"}`
  (published master id, master row `rev` at insert time). Rendering ignores
  the key;
- nothing links it back. Later master edits never reach it.

## 4. Editor half (task-3b6e562e916c8ce4)

Two LiveView events on the Studio paper socket, no HTTP route:
`paper-save-master` (canvas block menu, boundary toolbar) and
`paper-insert-master` (the canvas slash menu's Masters group, read from the
`[data-paper-masters]` carrier). The insert goes through `paper_ops/5` with
a request id, so a retry replays. The picker lists `Masters.list_for_paper/1`
only. The public reader does not offer either action.

References inside the copy that name one of the node's own ids follow the
fresh ids: `anchor` (blockref, TOC entry) and `href: "#<id>"`.

## 5. Deferred

- LINKED (live-updating) instances: a separate row. The `master.mode` key
  leaves room for a `linked` value without reshaping detached copies.
- A blockref's `target` (a paper title) is not retargeted when the copy
  lands in another paper.

---
'@barkpark/react': patch
---

PortableDoc: a `roadmap` no longer invents a timeline for rows that carry no geometry. A live-query roadmap row (title/status/priority, no `left`/`width`) used to be clamped to the same `left:0%;width:100%` bar as every other such row. Now, when no row has author geometry, the block renders "No schedule to place these items on." and lists the items through the task-list emitter; when some rows are placed, a geometry-less lane gets `bp-rm__lane--unplaced` and a "not scheduled" marker instead of a bar. The markup and both strings match the Phoenix View emitter byte for byte; a fully authored roadmap is unchanged.

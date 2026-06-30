---
'@barkpark/core': minor
---

Added the content-graph API to the SDK: `client.getGraph(id, opts)` traverses the reference graph from a root document (depth/direction/kinds/sources/perspective), `client.getOrphans()` lists documents with no edges, and `client.getDangling()` lists broken references. The server + CLI (`graph.show`/`orphans`/`dangling`) had these all along; the SDK was the missing layer. New types: `GraphResult`, `GraphNode`, `GraphEdge`, `GraphOptions`.

# bp-graph dev harness

`index.html` mounts `api/priv/static/assets/bp-graph.js` against fixture datasets
(full ~60 nodes, drafts, sparse, void, fetch-continuity, parse-error) so the graph
renderer can be smoke-tested in isolation from Phoenix. It makes zero network
calls — every dataset is local synthetic data.

Open it directly (`open api/assets/graph-harness/index.html`) or serve the repo
root statically. It loads the renderer by relative path; there is no build step.

## Why it is not under `api/priv/static/assets/`

It used to live there as `_graph_harness.html`. Everything under
`api/priv/static/assets/` is publicly served — `BarkparkWeb.static_paths/0`
allowlists the whole `assets` directory, so the file answered 200 in production
even though nothing in the tree referenced it. Dev scaffolding does not belong on
the public edge, so it moved here. Do not move it back.

<!-- doc-tier: cold | canonical-for: legendary-paper-verify-25-evidence | budget: 1800tok -->
# Verify 25 — stored HTML ownership and freshness

Verdict: `refuted`, with one narrower carried freshness gap. `body_html` and `body.html` are distinct raw-byte projections, but their ownership is defined: `content.blocks` is canonical, `body_html` is a derived renderer cache, and `body.html` belongs to the derived `content.body` projection.

| Paper | Blocks | `body_html` SHA | `body.html` SHA | Semantic result |
| --- | ---: | --- | --- | --- |
| Cloud Console wave 29 | 252 | `6fb682b6…8383` | `ec92d61e…0cc4` | equal; current stamp |
| PDS wave 45 | 227 | `d01ae15e…29c0` | `01fd7940…2239` | equal; current stamp |
| Cloud Console wave 28 | 237 | `caa2ae2c…08d7` | `081fe3d1…20ce` | equal; current stamp |
| PDS wave 44 | 99 | `0cb6a0b7…e816` | `efc2958d…f5dc` | equal; stale `body_html` stamp |

For every Paper, `blocks == body.blocks`; normalized semantic hashes for `body_html`, `body.html`, and public article output agree; public block order matches canonical blocks. Email differs by exactly one prepended title insertion. Newest history snapshots match current blocks and both stored projections; publish-history timestamps follow document updates by less than one second.

Ownership is explicit in code. `Content.Papers` calls blocks the source of truth and `body_html` a derived cache. `PortableDoc.Projection.project/3` derives `content.body`, including `body.html`, from blocks. Render code defines the renderer-source digest; writer, block operations, and sheets regenerate projections on canonical writes. Active public, email, Studio, web, and Go readers prefer canonical blocks rather than treating `body.html` as authority.

`body_html` has a renderer digest, byte comparison, stale/divergent classification, guarded read-refresh, provenance tests, and a rehydration task. Three Papers carry the current digest `c77575…521b`; PDS wave 44 carries old `55c67e…02d1`, independently demonstrating renderer-version staleness while preserving canonical blocks.

The narrower residual is real: `body.html` has no independent renderer-version stamp, byte-coherence check, or rehydration sweep. It refreshes atomically on projecting writes, but renderer-only changes can leave its presentation bytes stale until another write. This is weaker observable freshness, not undefined ownership. No deletion-safety conclusion follows.

All 18 renderer-digest inputs, projection/write/read paths, relevant provenance tests, four live Paper documents/history records, and public/email captures were checked. No active reader using `body.html` as canonical authority was found. No repository or Barkpark state was mutated; the worktree was clean at `f4817bccc9394c51dd19666970992c29e6b71593`.

---
'@barkpark/react': minor
---

New subpath exports split the two rendering surfaces so an app that uses one never pays for the other: `@barkpark/react/portable-text` serves the legacy Sanity-shaped shim alone (~1.33 KB gz, down from ~14 KB riding the shared renderer chunk), and `@barkpark/react/portable-doc` serves the canonical PortableDoc renderer without the shim (~19.91 KB gz). The entry split also isolates the shim into its own chunk, so even the root-barrel `import { PortableText }` now tree-shakes free of the renderer (measured 1.2 KB, was 20.75 KB). Compatibility policy (README "Subpath exports"): the root barrel keeps exporting both surfaces unchanged indefinitely — the subpaths are additive opt-in. `portable-doc` is hook-free and RSC-safe; `portable-text` carries the client boundary. Guarded by a production bundle-analysis test walking each entry's chunk graph, plus new size-limit budgets.

---
'@barkpark/react': patch
---

Raise the three drifted PortableDoc size-limit baselines so `pnpm size` is honest on `main` again. A clean `--force` build measured the PortableDoc client (`dist/index.mjs`), RSC server (`dist/server.mjs`), and PortableDoc subpath (`dist/portable-doc.mjs`) at 24950 / 23940 / 21017 B gzipped — 200 / 210 / 207 B over the limits set at #17667. The overage is diffuse PortableDoc drift across #17684, #17729, #17759, and #17966, each of which added a few dozen bytes without bumping the baseline; no single commit dominates. This dedicated baseline-move raises the three limits to 25.25 / 24.2 / 21.3 KB (300 / 260 / 283 B headroom) and touches no passing subpath. No runtime behaviour changes.

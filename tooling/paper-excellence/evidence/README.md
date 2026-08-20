<!-- doc-tier: human | canonical-for: paper-excellence-evidence-archive | budget: 4000tok -->

# Paper-excellence benchmark evidence (2026-08-12)

The measurement record behind the Heggemsnes-Act wave, committed so the wave's
claims can be re-checked after every scratchpad is gone.

```sh
shasum -a 256 -c tooling/paper-excellence/evidence/MANIFEST.sha256   # 27 OK, run from the repo root
```

| file | what it is |
|---|---|
| `erasure.html` | the standalone benchmark artifact — self-contained, no external asset can rot (`grep -oiE '(src\|href)="' erasure.html` → zero hits) |
| `full.jpeg` | full-page capture of the artifact, 2400 x 21430, `deviceScaleFactor: 2` |
| `light.jpeg`, `decl.jpeg`, `decl2.jpeg`, `cast.jpeg` | supporting captures |
| `shots/*.png` | the 5-paper panel as first shot: **above the fold only**, `deviceScaleFactor: 1`, 1440x1200, taken over the network against guerrilla |
| `shot.mjs` | the script that produced `shots/` — archived **as it ran**, absolute machine paths and all |

Two things to know before reusing any of this:

* **The twin sides are unlike captures.** `shots/` is fold-only at 1x; the
  artifact side is full-page at 2x. A regression panel built on both compares
  different things below the fold. The hermetic replacement lives next door in
  `../rig/` and captures full page at 2x; `../rig/baselines/` is the panel to
  compare against from now on.
* **`shot.mjs` is archived, not runnable.** Its Playwright import and output
  directory are absolute paths on one machine, and the output directory was an
  ephemeral scratchpad. It is kept verbatim because it is the provenance of
  `shots/`; the portable successor is `../rig/shoot.mjs`.

`MANIFEST.sha256` lists paths **relative to the repo root** so the one command
above works from anywhere in the tree; the digests are unchanged from the
archive as captured. It can genuinely fail — appending a line to `shot.mjs`
yields `tooling/paper-excellence/evidence/shot.mjs: FAILED` and a nonzero exit,
and restoring the file returns all 27 to OK.

// sheet family (charter D49) — EMPTY this round, spread into BLOCK_RENDERERS
// at split time so the round-2 slice (mob-zb-s6-grid-natives: sheet, D46b —
// h-scroll grid with FIXED per-column widths; do NOT copy the table
// renderer's per-cell minWidth/maxWidth) fills this map WITHOUT touching
// registry.tsx.
import type { Render } from '../register'

export const sheetRenderers: Record<string, Render> = {}

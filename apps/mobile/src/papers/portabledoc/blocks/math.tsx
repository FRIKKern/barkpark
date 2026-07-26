// math family (charter D49) — EMPTY this round, spread into BLOCK_RENDERERS
// at split time so the round-2 slice (mob-zb-s7-tail-media: equation, D45 —
// transliterated from react math.ts's PARSER, never equation.go's regex)
// fills this map WITHOUT touching registry.tsx.
import type { Render } from '../register'

export const mathRenderers: Record<string, Render> = {}

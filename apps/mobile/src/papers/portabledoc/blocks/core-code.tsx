// core-code family (charter D49) — EMPTY this round, spread into
// BLOCK_RENDERERS at split time so the round-2 slice (mob-zb-s4-navcode-
// natives: tabs, code-tabs, api-endpoint, filetree, diff) fills this map
// WITHOUT touching registry.tsx. The plain `code` fence renderer lives in
// core-media per the D49 band split.
import type { Render } from '../register'

export const coreCodeRenderers: Record<string, Render> = {}

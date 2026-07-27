// The shape of one authored registry-tripwire case (charter D31/D49): a
// registered block type plus a block instance that must render WITHOUT the
// unknown-block fallback. One case file per renderer family, mirroring
// src/papers/portabledoc/blocks/ — a round-2 slice adds its renderers AND its
// cases without touching any shared file; chatRenderers.test.tsx concatenates
// them and pins the set against Object.keys(BLOCK_RENDERERS).
export interface BlockCase {
  type: string
  block: Record<string, unknown>
}

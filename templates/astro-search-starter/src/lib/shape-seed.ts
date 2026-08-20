// Seed shaping for the finder island — the Astro-glue seam between the build's
// baked `search-seed.json` and the shapes the vendored finder consumes.
//
// This is NOT part of the vendored finder (it has no Next equivalent), so it
// lives outside `src/finder/**` and is deliberately React-free: it is a pure
// pair of type + function, unit-tested by `shape-seed.test.ts` via `node --test`
// so the exact contract that once broke ("everything disappears" on keystroke)
// can never silently regress again.
import { shapeFindResponse } from '../finder/lib/find-shape.ts'
import { buildPrefixSeed } from '../finder/lib/prefix-seed.ts'
import type { UpstreamSearchJson } from '../finder/lib/find-shape.ts'
import type { FindResponse } from '../finder/lib/find.ts'
import type { PrefixSeed, SeedDoc } from '../finder/lib/prefix-seed.ts'

/** What the finder island holds after shaping — the exact props the finder reads. */
export interface SeedState {
  initialData: FindResponse | null
  initialSeed: PrefixSeed | null
}

// The build bakes `initialData` as the RAW browse upstream JSON (`documents`,
// `count`, …) — the exact payload `handleFind` receives over HTTP — NOT an
// already-shaped FindResponse. The finder reads `initialData.hits`, so the
// island MUST run the same `shapeFindResponse` mapping the live route uses
// (browse, engine=postgres — the engine the seed is baked with, see
// `bp.ts` → `browseSeed`; the payload's own server-reported `engineUsed` wins
// over the fallback here). Without this the first-paint browse landing renders
// EMPTY (raw JSON has no `.hits`) and the finder skips its refetch on the
// matching seed key.
//
// The build (`src/lib/bp.ts` → `browseSeed`) bakes `initialSeed` as the RANKED
// CORPUS — a flat `SeedDoc[]` — NOT an already-built `PrefixSeed`. The island is
// what "turns [that] ranked corpus into an in-browser prefix index" (per the
// baker's own contract), so `shapeSeed` MUST run `buildPrefixSeed` here. Passing
// the raw array straight through made `lookupPrefix` read `seed.index[key]` on
// an Array (no `.index`) → `Cannot read properties of undefined` on the first
// 1–2 char keystroke, which unmounted the whole island ("everything disappears").
export interface RawSeed {
  initialData: UpstreamSearchJson | null
  initialSeed: SeedDoc[] | null
}

/** Shape the baked `search-seed.json` into the finder's `SeedState`. Pure —
 * safe to call on the server (no window) and unit-testable without a DOM. */
export function shapeSeed(raw: RawSeed | null): SeedState {
  if (!raw) return { initialData: null, initialSeed: null }
  const initialData = raw.initialData
    ? shapeFindResponse(raw.initialData, {
        engine: 'postgres',
        engineUsed: 'postgres',
        browse: true,
        cache: false,
        upstreamMs: null,
      })
    : null
  return {
    initialData,
    // Build the in-browser prefix index from the ranked corpus the build baked.
    initialSeed:
      raw.initialSeed && raw.initialSeed.length > 0
        ? buildPrefixSeed(raw.initialSeed)
        : null,
  }
}

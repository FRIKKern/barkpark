import { describe, it, expect } from 'vitest'
import { PortableText, BarkparkImage, imageUrl } from '../src/server'
import type {
  PortableTextProps,
  PortableTextComponents,
  PortableTextNode,
  PortableTextBlock,
  PortableTextSpan,
  PortableTextMarkDef,
  CustomBlock,
  BarkparkImageProps,
  ImageAsset,
  ImageAssetRef,
  ImageAssetExpanded,
  ImageAssetMetadata,
  BarkparkReferenceProps,
  RefInput,
  ResolvedDoc,
  BarkparkReferenceClient,
  RenditionPreset,
  ImageRef,
  ImageUrlOptions,
} from '../src/server'

// The RSC-safe entry (src/server.ts, the package's `react-server` export
// condition) must expose the SAME pure surface as the client entry (src/index.ts,
// guarded by exports.test.ts) — every context-free renderer, the pure `imageUrl`
// builder, and all data-shape types — MINUS the `BarkparkReference` COMPONENT,
// which calls createContext and would crash the RSC import graph. Its TYPES are
// still exported (a server component can accept the props type without rendering
// the client component). Before this guard, server.ts silently omitted the
// Portable Text / image data-shape types and imageUrl, so a Server Component
// could not type its content or build rendition URLs from `@barkpark/react`.
describe('RSC (server) entry exports', () => {
  it('exports the two context-free components + imageUrl at runtime', () => {
    expect(typeof PortableText).toBe('function')
    expect(typeof BarkparkImage).toBe('function')
    expect(typeof imageUrl).toBe('function')
  })

  it('does NOT export the client-only BarkparkReference component at runtime', async () => {
    const mod = (await import('../src/server')) as Record<string, unknown>
    expect('BarkparkReference' in mod).toBe(false)
  })

  it('re-exports every data-shape type the client entry does (compile-time guard)', () => {
    // Type-position only — this file fails to typecheck if any export is missing
    // from src/server.ts, which is the regression this locks. Mirrors the union
    // in exports.test.ts so the two entries cannot drift apart.
    const _types: Array<
      | PortableTextProps
      | PortableTextComponents
      | PortableTextNode
      | PortableTextBlock
      | PortableTextSpan
      | PortableTextMarkDef
      | CustomBlock
      | BarkparkImageProps
      | ImageAsset
      | ImageAssetRef
      | ImageAssetExpanded
      | ImageAssetMetadata
      | BarkparkReferenceProps
      | RefInput
      | ResolvedDoc
      | BarkparkReferenceClient
      | RenditionPreset
      | ImageRef
      | ImageUrlOptions
    > = []
    expect(_types).toEqual([])
  })
})

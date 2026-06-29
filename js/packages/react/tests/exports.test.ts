import { describe, it, expect } from 'vitest'
import { PortableText, BarkparkImage, BarkparkReference, imageUrl } from '../src'
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
} from '../src'

describe('public exports', () => {
  it('exports the three components at runtime', () => {
    expect(typeof PortableText).toBe('function')
    expect(typeof BarkparkImage).toBe('function')
    expect(typeof BarkparkReference).toBe('function')
    expect(typeof imageUrl).toBe('function')
  })

  it('re-exports the data-shape types the props accept (compile-time guard)', () => {
    // Used only in type position — this file fails to typecheck if any export is
    // missing, which is the regression this test locks. No runtime value needed.
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

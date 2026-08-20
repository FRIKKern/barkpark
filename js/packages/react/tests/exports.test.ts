import { describe, it, expect } from 'vitest'
import {
  PortableText,
  PortableDoc,
  renderPortableDocument,
  BarkparkImage,
  BarkparkReference,
  imageUrl,
  toPlainText,
} from '../src'
import type {
  PortableTextProps,
  PortableTextComponents,
  PortableTextNode,
  PortableTextBlock,
  PortableTextSpan,
  PortableTextMarkDef,
  CustomBlock,
  PortableDocProps,
  Block,
  Inline,
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
  it('exports the components + renderers at runtime', () => {
    expect(typeof PortableText).toBe('function')
    // The canonical type-keyed PortableDocument renderer (charter D2).
    expect(typeof PortableDoc).toBe('function')
    expect(typeof renderPortableDocument).toBe('function')
    expect(typeof BarkparkImage).toBe('function')
    expect(typeof BarkparkReference).toBe('function')
    expect(typeof imageUrl).toBe('function')
    expect(typeof toPlainText).toBe('function')
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
      | PortableDocProps
      | Block
      | Inline
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

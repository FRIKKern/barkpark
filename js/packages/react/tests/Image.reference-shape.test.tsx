// @vitest-environment happy-dom
import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderToString } from 'react-dom/server'
import { createElement } from 'react'
import type { ReactElement } from 'react'
import { BarkparkImage } from '../src/Image'
import type { BarkparkImageProps, ImageAsset } from '../src/Image'

// Behind BARKPARK_CANONICAL_SHAPE_WRITES the server writes an image as
// {asset: {_ref: "image-<sha1>-<w>x<h>-<ext>"}, hotspot, crop}
// (docs/contracts/schema-v2.md). BarkparkImage read only a top-level url or
// _ref/_id/assetId, so this value rendered nothing. Its URL is the dataset's
// Sanity image route, as the server builds it (BarkparkWeb.Studio.ImageRefUrl).
const SHA1 = '7f9a2c4e1b3d5f60718293a4b5c6d7e8f9012345'
const cover: ImageAsset = {
  _type: 'image',
  asset: { _ref: `image-${SHA1}-1440x813-jpg`, _type: 'reference' },
  hotspot: { x: 0.5, y: 0.5, height: 1, width: 1 },
}
const base = 'https://cms.example.com'
const scope = '/w/acme/p/blog'
const file = `${base}${scope}/images/barkpark/production/${SHA1}-1440x813.jpg`

function html(props: Partial<BarkparkImageProps>): string {
  return renderToString(
    createElement(BarkparkImage, { asset: cover, alt: 'cover', ...props }) as ReactElement,
  )
}

afterEach(() => vi.restoreAllMocks())

describe('BarkparkImage on the reference image shape', () => {
  it("renders the dataset's image route from asset._ref", () => {
    expect(html({ baseUrl: base, pathPrefix: scope, dataset: 'production' })).toContain(
      `src="${file}"`,
    )
  })

  it('a preset sends its bounds, without the no-id warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(
      html({ baseUrl: base, pathPrefix: scope, dataset: 'production', preset: 'thumb' }),
    ).toContain(`src="${file}?w=320&amp;h=320&amp;fit=max"`)
    expect(warn).not.toHaveBeenCalled()
  })

  it('renders nothing without a dataset, and never reports a missing baseUrl', () => {
    const onMissingBaseUrl = vi.fn()
    expect(html({ baseUrl: base, pathPrefix: scope, onMissingBaseUrl })).toBe('')
    expect(onMissingBaseUrl).not.toHaveBeenCalled()
  })

  it('renders nothing for a ref that names another dataset', () => {
    const cross: ImageAsset = { asset: { _ref: `image-${SHA1}-1440x813-jpg`, _dataset: 'staging' } }
    expect(html({ asset: cross, baseUrl: base, pathPrefix: scope, dataset: 'production' })).toBe('')
  })

  it('an expanded asset.url renders without a dataset', () => {
    const expanded: ImageAsset = {
      asset: { _ref: `image-${SHA1}-1440x813-jpg`, url: '/media/files/x.jpg' },
    }
    expect(html({ asset: expanded, baseUrl: base })).toContain(`src="${base}/media/files/x.jpg"`)
  })

  it('the legacy {url, assetId} value renders as before', () => {
    const legacy: ImageAsset = { url: '/media/files/legacy.jpg', assetId: 'a1' }
    expect(html({ asset: legacy, baseUrl: base, dataset: 'production' })).toContain(
      `src="${base}/media/files/legacy.jpg"`,
    )
    expect(
      html({
        asset: legacy,
        baseUrl: base,
        pathPrefix: scope,
        dataset: 'production',
        preset: 'hero',
      }),
    ).toContain(`src="${base}${scope}/media/renditions/a1/hero"`)
  })
})

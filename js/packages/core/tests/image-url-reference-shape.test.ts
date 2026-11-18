import { describe, it, expect } from 'vitest'
import { imageUrl } from '../src/image-url'
import { createClient } from '../src/client'

// Behind BARKPARK_CANONICAL_SHAPE_WRITES the server writes an image as
// {asset: {_ref: "image-<sha1>-<w>x<h>-<ext>"}, hotspot, crop}
// (docs/contracts/schema-v2.md). Its URL is the dataset's Sanity image route,
// <scope>/images/barkpark/<dataset>/<sha1>-<w>x<h>.<ext> — the server's rule
// (FieldInputs.sanity_image_url/4, BarkparkWeb.Studio.ImageRefUrl). Before this
// the SDK read only the legacy {url, assetId} and gave this value no URL.
const SHA1 = '7f9a2c4e1b3d5f60718293a4b5c6d7e8f9012345'
const REF = `image-${SHA1}-1440x813-jpg`
const cover = {
  _type: 'image',
  asset: { _ref: REF, _type: 'reference' },
  hotspot: { x: 0.5, y: 0.5, height: 1, width: 1 },
}
const base = 'https://cms.example.com'
const scope = '/w/acme/p/blog'

describe('imageUrl on the reference image shape', () => {
  it("builds the dataset's Sanity image route from asset._ref", () => {
    expect(imageUrl(cover, { baseUrl: base, pathPrefix: scope, dataset: 'production' })).toBe(
      `${base}${scope}/images/barkpark/production/${SHA1}-1440x813.jpg`,
    )
  })

  it('lower-cases the sha1 and the extension, as the server does', () => {
    const upper = { asset: { _ref: `image-${SHA1.toUpperCase()}-10x20-PNG` } }
    expect(imageUrl(upper, { pathPrefix: scope, dataset: 'production' })).toBe(
      `${scope}/images/barkpark/production/${SHA1}-10x20.png`,
    )
  })

  it("a known preset sends the preset's bounds as transform params", () => {
    const opts = { baseUrl: base, pathPrefix: scope, dataset: 'production' }
    const file = `${base}${scope}/images/barkpark/production/${SHA1}-1440x813.jpg`
    expect(imageUrl(cover, { ...opts, preset: 'thumb' })).toBe(`${file}?w=320&h=320&fit=max`)
    expect(imageUrl(cover, { ...opts, preset: 'hero' })).toBe(`${file}?w=1920&h=1080&fit=max`)
    expect(imageUrl(cover, { ...opts, preset: 'og' })).toBe(`${file}?w=1200&h=630&fit=crop`)
    // An unknown preset, or an inherited object key, is the original.
    expect(imageUrl(cover, { ...opts, preset: 'banner' })).toBe(file)
    expect(imageUrl(cover, { ...opts, preset: 'constructor' })).toBe(file)
  })

  it('has no URL without a dataset — it never guesses one', () => {
    expect(imageUrl(cover, { baseUrl: base, pathPrefix: scope })).toBeNull()
  })

  it('has no URL for a ref that names another dataset', () => {
    const cross = { asset: { _ref: REF, _dataset: 'staging' } }
    expect(imageUrl(cross, { pathPrefix: scope, dataset: 'production' })).toBeNull()
    expect(imageUrl(cross, { pathPrefix: scope, dataset: 'staging' })).toBe(
      `${scope}/images/barkpark/staging/${SHA1}-1440x813.jpg`,
    )
  })

  it('has no URL for a _ref that is not an image id', () => {
    for (const ref of [
      'file-' + SHA1 + '-pdf',
      `image-${SHA1}-0x10-jpg`,
      `image-abc-10x10-jpg`,
      `image-${SHA1}-10x10-jpg/../x`,
      '',
    ]) {
      expect(imageUrl({ asset: { _ref: ref } }, { dataset: 'production' })).toBeNull()
    }
    expect(imageUrl({ asset: null }, { dataset: 'production' })).toBeNull()
  })

  it('an expanded asset.url is the URL, through the same scheme guard', () => {
    expect(imageUrl({ asset: { _ref: REF, url: '/media/files/x.jpg' } }, { baseUrl: base })).toBe(
      `${base}/media/files/x.jpg`,
    )
    expect(
      imageUrl({ asset: { _id: REF, url: 'https://cdn.example.com/x.jpg' } }, { preset: 'thumb' }),
    ).toBe('https://cdn.example.com/x.jpg')
    expect(imageUrl({ asset: { url: 'javascript:alert(1)' } }, { baseUrl: base })).toBeNull()
  })

  it('leaves the legacy shapes as they were: a top-level url or id wins', () => {
    const both = { url: '/media/files/legacy.jpg', assetId: 'a1', asset: { _ref: REF } }
    const opts = { baseUrl: base, pathPrefix: scope, dataset: 'production' }
    expect(imageUrl(both, opts)).toBe(`${base}/media/files/legacy.jpg`)
    expect(imageUrl(both, { ...opts, preset: 'thumb' })).toBe(
      `${base}${scope}/media/renditions/a1/thumb`,
    )
  })
})

describe("the client's imageUrl on the reference image shape", () => {
  const config = {
    projectUrl: base,
    dataset: 'production',
    apiVersion: '2026-04-01',
  } as const

  it("a scoped client builds its own scope and dataset's route", () => {
    const bp = createClient({ ...config, workspace: 'acme', project: 'blog' })
    expect(bp.imageUrl(cover)).toBe(
      `${base}${scope}/images/barkpark/production/${SHA1}-1440x813.jpg`,
    )
    expect(bp.imageUrl(cover, { preset: 'preview' })).toBe(
      `${base}${scope}/images/barkpark/production/${SHA1}-1440x813.jpg?w=1600&h=1600&fit=max`,
    )
  })

  it("never builds a URL for a dataset other than the client's", () => {
    const bp = createClient({ ...config, workspace: 'acme', project: 'blog' })
    expect(bp.imageUrl(cover, { dataset: 'staging' })).toBe(
      `${base}${scope}/images/barkpark/production/${SHA1}-1440x813.jpg`,
    )
    expect(bp.imageUrl({ asset: { _ref: REF, _dataset: 'staging' } })).toBeNull()
  })

  it('a flat client gives it no URL: the route exists only under /w/:ws/p/:proj', () => {
    const bp = createClient(config)
    expect(bp.imageUrl(cover)).toBeNull()
    expect(bp.imageUrl(cover, { dataset: 'production' })).toBeNull()
  })

  it('the legacy {url, assetId} value is unchanged on a scoped client', () => {
    const bp = createClient({ ...config, workspace: 'acme', project: 'blog' })
    const legacy = { url: '/media/files/x.jpg', assetId: 'a1' }
    expect(bp.imageUrl(legacy)).toBe(`${base}/media/files/x.jpg`)
    expect(bp.imageUrl(legacy, { preset: 'thumb' })).toBe(
      `${base}${scope}/media/renditions/a1/thumb`,
    )
  })
})

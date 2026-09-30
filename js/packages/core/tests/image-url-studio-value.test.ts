import { describe, it, expect } from 'vitest'
import { imageUrl } from '../src/image-url'
import { createClient } from '../src/client'

// The Studio media picker stores an image field as {url, assetId, alt, width,
// height, lqip} (bp-media-picker.js; `assetId` is the canonical spelling). This
// is that value as a local instance stored it (stranger walk, 2026-09-30). A
// preset used to fall through to the full-size original because only `_ref` /
// `_id` were read as the asset id.
const studioCover = {
  alt: 'r2d-test.png',
  url: '/w/default/p/default/media/files/d/11c90353-30fd-4d20-aee8-98e1cbbbf1ba/2026/09/r2d-test-68208560.png',
  width: 1440,
  height: 813,
  lqip: 'data:image/jpeg;base64,/9j/4QC8',
  assetId: '05c49ba9-a911-4c7b-8199-7b0b2cf8ec48',
}

describe('imageUrl on the Studio-stored image value', () => {
  it('a preset resolves the rendition from assetId', () => {
    expect(
      imageUrl(studioCover, {
        preset: 'thumb',
        baseUrl: 'http://127.0.0.1:4610',
        pathPrefix: '/w/default/p/default',
      }),
    ).toBe(
      'http://127.0.0.1:4610/w/default/p/default/media/renditions/05c49ba9-a911-4c7b-8199-7b0b2cf8ec48/thumb',
    )
  })

  it('without a preset it is still the stored original url', () => {
    expect(imageUrl(studioCover, { baseUrl: 'http://127.0.0.1:4610' })).toBe(
      `http://127.0.0.1:4610${studioCover.url}`,
    )
  })

  it("the scoped client's imageUrl emits the scoped rendition route", () => {
    const bp = createClient({
      projectUrl: 'http://127.0.0.1:4610',
      dataset: 'production',
      apiVersion: '2026-04-01',
      workspace: 'default',
      project: 'default',
    })
    expect(bp.imageUrl(studioCover, { preset: 'hero' })).toBe(
      'http://127.0.0.1:4610/w/default/p/default/media/renditions/05c49ba9-a911-4c7b-8199-7b0b2cf8ec48/hero',
    )
  })

  it('_ref and _id still win over assetId', () => {
    expect(imageUrl({ _ref: 'r1', assetId: 'a1' }, { preset: 'thumb' })).toBe(
      '/media/renditions/r1/thumb',
    )
    expect(imageUrl({ _id: 'i1', assetId: 'a1' }, { preset: 'thumb' })).toBe(
      '/media/renditions/i1/thumb',
    )
  })

  it('an empty assetId is no id', () => {
    expect(imageUrl({ url: '/media/files/x.png', assetId: '' }, { preset: 'thumb' })).toBe(
      '/media/files/x.png',
    )
  })
})

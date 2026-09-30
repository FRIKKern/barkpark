// @vitest-environment happy-dom
import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderToString } from 'react-dom/server'
import { createElement } from 'react'
import type { ReactElement } from 'react'
import { BarkparkImage } from '../src/Image'
import type { ImageAsset } from '../src/Image'

// The Studio media picker stores {url, assetId, alt, width, height, lqip}, with
// the metadata FLAT (bp-media-picker.js). BarkparkImage read only _ref/_id and
// metadata.*, so a preset served the original (with a "no resolvable id"
// warning) and the stored size and blur placeholder were dropped (stranger
// walk, 2026-09-30). The value below is what a local instance stored.
const studioCover: ImageAsset = {
  alt: 'r2d-test.png',
  url: '/w/default/p/default/media/files/d/11c90353/2026/09/r2d-test-68208560.png',
  width: 1440,
  height: 813,
  lqip: 'data:image/jpeg;base64,/9j/4QC8',
  assetId: '05c49ba9-a911-4c7b-8199-7b0b2cf8ec48',
}

afterEach(() => vi.restoreAllMocks())

describe('BarkparkImage on the Studio-stored image value', () => {
  it('a preset renders the rendition from assetId, without the no-id warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const html = renderToString(
      createElement(BarkparkImage, {
        asset: studioCover,
        alt: 'cover',
        preset: 'thumb',
        baseUrl: 'http://127.0.0.1:4610',
        pathPrefix: '/w/default/p/default',
      }) as ReactElement,
    )
    expect(html).toContain(
      'src="http://127.0.0.1:4610/w/default/p/default/media/renditions/05c49ba9-a911-4c7b-8199-7b0b2cf8ec48/thumb"',
    )
    expect(warn).not.toHaveBeenCalled()
  })

  it('forwards the flat width/height', () => {
    const html = renderToString(
      createElement(BarkparkImage, { asset: studioCover, alt: 'cover' }) as ReactElement,
    )
    expect(html).toContain('width="1440"')
    expect(html).toContain('height="813"')
  })

  it('forwards the flat lqip as blurDataURL to a custom component', () => {
    const seen: Record<string, unknown>[] = []
    const Probe = (p: Record<string, unknown>) => {
      seen.push(p)
      return null
    }
    renderToString(
      createElement(BarkparkImage, { asset: studioCover, alt: 'cover', as: Probe }) as ReactElement,
    )
    expect(seen[0]?.blurDataURL).toBe('data:image/jpeg;base64,/9j/4QC8')
    expect(seen[0]?.width).toBe(1440)
  })

  it('explicit width/height props still win', () => {
    const html = renderToString(
      createElement(BarkparkImage, {
        asset: studioCover,
        alt: 'c',
        width: 10,
        height: 20,
      }) as ReactElement,
    )
    expect(html).toContain('width="10"')
    expect(html).toContain('height="20"')
  })
})

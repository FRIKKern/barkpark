import { describe, it, expect, vi } from 'vitest'
import { renderToString } from 'react-dom/server'
import { createElement } from 'react'
import type { ReactElement } from 'react'
import { BarkparkImage } from '../src/Image'
import type { ImageAsset } from '../src/Image'

describe('BarkparkImage', () => {
  it('renders <img> from expanded asset with .url', () => {
    const asset: ImageAsset = {
      _id: 'image-abc-100x50-jpg',
      _type: 'image',
      url: 'https://cdn.example.com/direct.jpg',
    }
    const html = renderToString(
      createElement(BarkparkImage, { asset, alt: 'hello' }) as ReactElement,
    )
    expect(html).toContain('<img')
    expect(html).toContain('src="https://cdn.example.com/direct.jpg"')
    expect(html).toContain('alt="hello"')
  })

  it('builds URL from _ref + baseUrl', () => {
    const asset: ImageAsset = { _ref: 'image-abc-100x50-jpg', _type: 'reference' }
    const html = renderToString(
      createElement(BarkparkImage, {
        asset,
        alt: 'cat',
        baseUrl: 'https://cdn.example.com',
      }) as ReactElement,
    )
    expect(html).toContain('src="https://cdn.example.com/images/image-abc-100x50-jpg"')
    expect(html).toContain('alt="cat"')
  })

  it('trims trailing slash on baseUrl', () => {
    const asset: ImageAsset = { _ref: 'image-x-1x1-png', _type: 'reference' }
    const html = renderToString(
      createElement(BarkparkImage, {
        asset,
        alt: 'x',
        baseUrl: 'https://cdn.example.com/',
      }) as ReactElement,
    )
    expect(html).toContain('src="https://cdn.example.com/images/image-x-1x1-png"')
  })

  it('passes src/alt/width/height to custom `as` component', () => {
    const received: Record<string, unknown> = {}
    const Custom = (props: Record<string, unknown>) => {
      Object.assign(received, props)
      return createElement('span', null, 'x')
    }
    const asset: ImageAsset = {
      _id: 'image-y-1x1-png',
      _type: 'image',
      url: 'https://cdn.example.com/y.png',
    }
    renderToString(
      createElement(BarkparkImage, {
        asset,
        alt: 'ALT',
        width: 100,
        height: 50,
        as: Custom,
      }) as ReactElement,
    )
    expect(received.src).toBe('https://cdn.example.com/y.png')
    expect(received.alt).toBe('ALT')
    expect(received.width).toBe(100)
    expect(received.height).toBe(50)
  })

  it('returns null when no url and no baseUrl; fires onMissingBaseUrl', () => {
    const asset: ImageAsset = { _ref: 'image-z-1x1-png', _type: 'reference' }
    const spy = vi.fn()
    const html = renderToString(
      createElement(BarkparkImage, {
        asset,
        alt: 'z',
        onMissingBaseUrl: spy,
      }) as ReactElement,
    )
    expect(html).toBe('')
    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(asset)
  })

  it('derives width/height from metadata when props absent', () => {
    const asset: ImageAsset = {
      _id: 'image-m-200x100-jpg',
      _type: 'image',
      url: 'https://cdn.example.com/m.jpg',
      metadata: { dimensions: { width: 200, height: 100 } },
    }
    const html = renderToString(
      createElement(BarkparkImage, { asset, alt: 'm' }) as ReactElement,
    )
    expect(html).toContain('width="200"')
    expect(html).toContain('height="100"')
  })

  it('user-supplied width overrides metadata', () => {
    const asset: ImageAsset = {
      _id: 'image-o-200x100-jpg',
      _type: 'image',
      url: 'https://cdn.example.com/o.jpg',
      metadata: { dimensions: { width: 200, height: 100 } },
    }
    const html = renderToString(
      createElement(BarkparkImage, { asset, alt: 'o', width: 50 }) as ReactElement,
    )
    expect(html).toContain('width="50"')
    expect(html).toContain('height="100"')
  })

  it('spreads extra props (className, arbitrary) to custom `as`', () => {
    const received: Record<string, unknown> = {}
    const Custom = (props: Record<string, unknown>) => {
      Object.assign(received, props)
      return createElement('span', null, 'x')
    }
    const asset: ImageAsset = {
      _id: 'image-s-1x1-png',
      _type: 'image',
      url: 'https://cdn.example.com/s.png',
    }
    const props: Record<string, unknown> = {
      asset,
      alt: 'a',
      as: Custom,
      className: 'my-img',
      'data-test': 'foo',
    }
    renderToString(
      createElement(BarkparkImage as unknown as (p: Record<string, unknown>) => ReactElement, props) as ReactElement,
    )
    expect(received.className).toBe('my-img')
    expect(received['data-test']).toBe('foo')
  })

  it('passes blurDataURL from metadata.lqip to custom component', () => {
    const received: Record<string, unknown> = {}
    const Custom = (props: Record<string, unknown>) => {
      Object.assign(received, props)
      return createElement('span', null, 'x')
    }
    const asset: ImageAsset = {
      _id: 'image-l-1x1-png',
      _type: 'image',
      url: 'https://cdn.example.com/l.png',
      metadata: { lqip: 'data:image/png;base64,AAAA' },
    }
    renderToString(
      createElement(BarkparkImage, {
        asset,
        alt: 'l',
        as: Custom,
      }) as ReactElement,
    )
    expect(received.blurDataURL).toBe('data:image/png;base64,AAAA')
  })
})

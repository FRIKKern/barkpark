// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// W4 (render-path-unification charter, D20/D21) — MEDIA hydration third:
// preset -> rendition RESOLUTION proof for the canonical @barkpark/react image
// path. This is the honest, reconciled image scope — NOT width-parametric srcset.
//
// Why no srcset (the GAP this test documents):
//   Barkpark serves a fixed set of NAMED renditions at
//   `/media/renditions/<id>/<preset>` (thumb/preview/hero/og). Those presets are
//   aspect-VARYING crops, not width variants of one crop — core `imageUrl`
//   explicitly disclaims `srcSet`/`w=` (packages/core/src/image-url.ts:7-9). A
//   width ladder would swap between differently-cropped images at each breakpoint,
//   which is wrong. So the resolver emits ONE rendition URL and NO srcset. This
//   test pins that decision: a `srcset` attribute must appear nowhere in the
//   rendered markup.
//
// The resolution is pure (no browser, no effects), so this runs in the default
// `node` environment with `renderToStaticMarkup` — the SSR path a consuming app
// (Next/Astro/Phoenix host) hits on first paint.

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createElement } from 'react'
import type { ReactElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { imageUrl } from '@barkpark/core'
import { BarkparkImage } from '../src/Image'
import type { ImageAsset } from '../src/Image'

const HERE = dirname(fileURLToPath(import.meta.url))

interface ImageAssetFixture {
  baseUrl: string
  presetAsset: { _id: string; _type: string; url?: string }
  preset: string
  expectedRenditionSuffix: string
  bareUrlAsset: string
}

// Sibling of pd-golden — a NEW asset-shaped fixture carrying {_id, preset}. The
// frozen pd-golden array is off-limits; its image.golden.json is a bare URL with
// no id/preset, so preset resolution has nowhere to live there.
const fixture = JSON.parse(
  readFileSync(join(HERE, 'fixtures', 'media', 'image-asset.fixture.json'), 'utf8'),
) as ImageAssetFixture

describe('W4 media — image preset → rendition resolution (@barkpark/react)', () => {
  it('resolves {_id}+named-preset to the /media/renditions/<id>/<preset> route', () => {
    // Mirror of ONE core assertion (core image-url.test.ts is already 13/13 green)
    // proving the react surface consumes the same resolver.
    const url = imageUrl(fixture.presetAsset as ImageAsset, {
      preset: fixture.preset,
      baseUrl: fixture.baseUrl,
    })
    expect(url).toBe(`${fixture.baseUrl}${fixture.expectedRenditionSuffix}`)
    expect(url).toMatch(
      new RegExp(`/media/renditions/${fixture.presetAsset._id}/${fixture.preset}$`),
    )
  })

  it('passes a bare-URL asset through UNCHANGED even when a preset is supplied', () => {
    // A bare URL string has no id, so a rendition path cannot be built — the string
    // is returned verbatim (no rendition route spliced in, no crash).
    const url = imageUrl(fixture.bareUrlAsset as ImageAsset, {
      preset: fixture.preset,
      baseUrl: fixture.baseUrl,
    })
    expect(url).toBe(fixture.bareUrlAsset)
    expect(url).not.toContain('/media/renditions/')
  })

  it('the resolved rendition URL lands in the rendered <img src> (SSR)', () => {
    // BarkparkImage is the ONLY surface that resolves presets (the PortableDoc
    // image BLOCK emits a bare <img> from b.src); prove the resolved URL reaches
    // the DOM the consuming app ships on first paint.
    const html = renderToStaticMarkup(
      createElement(BarkparkImage, {
        asset: fixture.presetAsset as ImageAsset,
        alt: 'W4 hero',
        baseUrl: fixture.baseUrl,
        preset: fixture.preset,
      }) as ReactElement,
    )
    expect(html).toContain('<img')
    expect(html).toContain(
      `src="${fixture.baseUrl}${fixture.expectedRenditionSuffix}"`,
    )
    // The rendition wins over the asset's inline `.url` (the original) — the preset
    // is a distinct crop, not the source file.
    expect(html).not.toContain(fixture.presetAsset.url as string)
  })

  it('emits NO srcset attribute anywhere — srcset is a reconciled GAP, not an API', () => {
    // Presets are aspect-varying crops, not a width ladder (image-url.ts disclaims
    // srcSet/w=). A width-parametric srcset would swap differently-cropped images
    // per breakpoint. Pin the decision: no srcset in EITHER render path.
    const presetHtml = renderToStaticMarkup(
      createElement(BarkparkImage, {
        asset: fixture.presetAsset as ImageAsset,
        alt: 'W4 hero',
        baseUrl: fixture.baseUrl,
        preset: fixture.preset,
      }) as ReactElement,
    )
    const bareHtml = renderToStaticMarkup(
      createElement(BarkparkImage, {
        asset: fixture.bareUrlAsset as ImageAsset,
        alt: 'W4 cover',
        baseUrl: fixture.baseUrl,
        preset: fixture.preset,
      }) as ReactElement,
    )
    for (const html of [presetHtml, bareHtml]) {
      // Case-insensitive: catch both the DOM attr (`srcset`) and the React prop
      // spelling (`srcSet`) should either ever appear.
      expect(html).not.toMatch(/srcset/i)
    }
  })
})

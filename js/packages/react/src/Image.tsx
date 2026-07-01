'use client'

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createElement } from 'react'
import type { ComponentType, ReactElement } from 'react'
import { imageUrl } from '@barkpark/core'
import type { RenditionPreset } from '@barkpark/core'

/** Unresolved reference to an image asset (the default shape in stored documents). */
export interface ImageAssetRef {
  _ref: string
  _type: 'reference' | 'image'
}

/** Metadata produced by the media pipeline — dimensions, LQIP, palette. */
export interface ImageAssetMetadata {
  dimensions?: { width: number; height: number; aspectRatio?: number }
  lqip?: string
  palette?: unknown
}

/** Expanded asset document (resolved during fetch via projection). */
export interface ImageAssetExpanded {
  _id: string
  _type: string
  url?: string
  metadata?: ImageAssetMetadata
  mimeType?: string
}

/** Either unresolved (`_ref`) or expanded (`_id` + optional `url`/`metadata`). */
/**
 * Either an unresolved reference (`_ref`), an expanded asset document, or a bare
 * URL string — the shape Barkpark stores for image fields, e.g.
 * `"/media/files/2026/04/cover.jpg"`.
 */
export type ImageAsset = ImageAssetRef | ImageAssetExpanded | string

/** Props for {@link BarkparkImage}. Extra props (`...rest`) are forwarded to the underlying element. */
export interface BarkparkImageProps {
  /** The image asset — a reference, an expanded asset document, or a URL string.
   *  `null`/`undefined` (an unset optional image field) renders nothing. */
  asset: ImageAsset | null | undefined
  /** Required alt text. */
  alt: string
  /** Origin used to build `/images/<id>` URLs when the asset lacks an inline `url`. */
  baseUrl?: string
  /**
   * Request a named server rendition (`thumb`/`preview`/`hero`/`og`) instead of the
   * full-size original — `/media/renditions/<id>/<preset>`. Needs `baseUrl` (like the
   * `/images/<id>` fallback); without one the component falls back to the original.
   */
  preset?: RenditionPreset
  /** Override the rendered component/tag. Defaults to `'img'`. Use `next/image` for framework-aware rendering. */
  as?: ComponentType<any> | string
  /** Explicit width; falls back to `asset.metadata.dimensions.width`. */
  width?: number
  /** Explicit height; falls back to `asset.metadata.dimensions.height`. */
  height?: number
  className?: string
  /** Invoked once when neither `asset.url` nor `baseUrl` is available. */
  onMissingBaseUrl?: (asset: ImageAsset) => void
  /** Extra props forwarded unchanged to the underlying component. */
  [key: string]: unknown
}

let warnedMissingBaseUrl = false

function getAssetId(asset: ImageAsset): string | undefined {
  if (typeof asset === 'string') return undefined
  if ('_ref' in asset && asset._ref) return asset._ref
  if ('_id' in asset && asset._id) return asset._id
  return undefined
}

function getAssetUrl(asset: ImageAsset): string | undefined {
  if (typeof asset === 'string') return asset
  if ('url' in asset && typeof asset.url === 'string' && asset.url) return asset.url
  return undefined
}

function getMetadata(asset: ImageAsset): ImageAssetMetadata | undefined {
  if (typeof asset === 'string') return undefined
  if ('metadata' in asset) return asset.metadata
  return undefined
}

/**
 * Renders a Barkpark image asset as an `<img>` (or a custom component
 * passed via `as`). Prefers `asset.url` when present; otherwise builds
 * `${baseUrl}/images/${assetId}` from `asset._ref` or `asset._id`.
 *
 * Forwards metadata `dimensions` to `width`/`height` when those props
 * are omitted. When rendering through a custom component (e.g.
 * `next/image`), also forwards `metadata.lqip` as `blurDataURL`.
 *
 * @param props — {@link BarkparkImageProps}
 * @returns An `<img>` element (or `as` component), or `null` when the asset is unusable.
 *
 * @example
 * import { BarkparkImage } from '@barkpark/react'
 * import NextImage from 'next/image'
 *
 * <BarkparkImage
 *   asset={post.coverImage}
 *   alt={post.title}
 *   baseUrl="https://cdn.barkpark.dev"
 *   as={NextImage}
 *   placeholder="blur"
 * />
 */
export function BarkparkImage(props: BarkparkImageProps): ReactElement | null {
  const {
    asset,
    alt,
    baseUrl,
    as,
    width: widthProp,
    height: heightProp,
    className,
    onMissingBaseUrl,
    preset,
    ...rest
  } = props

  // An unset optional image field (`null`/`undefined`) renders nothing — guard
  // before the getAsset* helpers, which use `in` and would throw on a nullish asset.
  if (asset == null) return null

  let src: string | undefined
  // A `preset` requests a server rendition — prefer it over the inline url, using
  // the same core helper as the SDK. It needs a baseUrl for an absolute URL (like
  // the `/images/<id>` path below); without one we fall through to the original.
  if (preset && baseUrl) {
    src = imageUrl(asset, { preset, baseUrl }) ?? undefined
  }
  if (!src) {
    if (typeof asset === 'string') {
      // A bare URL string is how Barkpark stores image fields (e.g.
      // "/media/files/…"). Prepend baseUrl when it's a relative path.
      src = baseUrl && asset.startsWith('/') ? `${baseUrl.replace(/\/+$/, '')}${asset}` : asset
    } else {
      src = getAssetUrl(asset)
    }
  }
  if (!src) {
    const id = getAssetId(asset)
    if (id) {
      if (baseUrl) {
        const trimmed = baseUrl.replace(/\/+$/, '')
        // Encode the id — spaces, '#', '?', '/' and non-ASCII are all legal in
        // Barkpark ids and would otherwise yield a broken/ambiguous <img src>.
        // Matches core imageUrl + Reference.buildDocPath.
        src = `${trimmed}/images/${encodeURIComponent(id)}`
      } else {
        if (onMissingBaseUrl) {
          onMissingBaseUrl(asset)
        } else if (!warnedMissingBaseUrl) {
          warnedMissingBaseUrl = true
          // eslint-disable-next-line no-console
          console.warn(
            '[BarkparkImage] asset has no .url and no baseUrl was provided; skipping render.',
          )
        }
        return null
      }
    } else {
      return null
    }
  }

  const metadata = getMetadata(asset)
  const dims = metadata?.dimensions
  const width = widthProp ?? dims?.width
  const height = heightProp ?? dims?.height

  const Component: ComponentType<any> | string = as ?? 'img'
  const isStringTag = typeof Component === 'string'

  const elementProps: Record<string, unknown> = {
    ...rest,
    src,
    alt,
  }
  if (width !== undefined) elementProps.width = width
  if (height !== undefined) elementProps.height = height
  if (className !== undefined) elementProps.className = className

  if (!isStringTag && metadata?.lqip) {
    elementProps.blurDataURL = metadata.lqip
  }

  return createElement(Component, elementProps)
}

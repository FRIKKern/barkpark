// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createElement } from 'react'
import type { ComponentType, ReactElement } from 'react'

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
export type ImageAsset = ImageAssetRef | ImageAssetExpanded

/** Props for {@link BarkparkImage}. Extra props (`...rest`) are forwarded to the underlying element. */
export interface BarkparkImageProps {
  /** The image asset — either a reference or an expanded asset document. */
  asset: ImageAsset
  /** Required alt text. */
  alt: string
  /** Origin used to build `/images/<id>` URLs when the asset lacks an inline `url`. */
  baseUrl?: string
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
  if ('_ref' in asset && asset._ref) return asset._ref
  if ('_id' in asset && asset._id) return asset._id
  return undefined
}

function getAssetUrl(asset: ImageAsset): string | undefined {
  if ('url' in asset && typeof asset.url === 'string' && asset.url) return asset.url
  return undefined
}

function getMetadata(asset: ImageAsset): ImageAssetMetadata | undefined {
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
    ...rest
  } = props

  let src = getAssetUrl(asset)
  if (!src) {
    const id = getAssetId(asset)
    if (id) {
      if (baseUrl) {
        const trimmed = baseUrl.replace(/\/+$/, '')
        src = `${trimmed}/images/${id}`
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

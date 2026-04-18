// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createElement } from 'react'
import type { ComponentType, ReactElement } from 'react'

export interface ImageAssetRef {
  _ref: string
  _type: 'reference' | 'image'
}

export interface ImageAssetMetadata {
  dimensions?: { width: number; height: number; aspectRatio?: number }
  lqip?: string
  palette?: unknown
}

export interface ImageAssetExpanded {
  _id: string
  _type: string
  url?: string
  metadata?: ImageAssetMetadata
  mimeType?: string
}

export type ImageAsset = ImageAssetRef | ImageAssetExpanded

export interface BarkparkImageProps {
  asset: ImageAsset
  alt: string
  baseUrl?: string
  as?: ComponentType<any> | string
  width?: number
  height?: number
  className?: string
  onMissingBaseUrl?: (asset: ImageAsset) => void
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

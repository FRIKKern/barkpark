'use client'

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createElement, useEffect } from 'react'
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
   * full-size original — `/media/renditions/<id>/<preset>`. With `baseUrl` you get an
   * absolute URL; without one a relative rendition path is returned (valid same-origin),
   * matching core `imageUrl`.
   *
   * Requires an asset with a resolvable id (`_ref`/`_id`). A bare URL string or an
   * id-less expanded asset can't be turned into a rendition path, so it silently
   * falls back to the full-size original (and dev logs a one-time warning).
   */
  preset?: RenditionPreset
  /**
   * Workspace/project scope prefix (e.g. `/w/<ws>/p/<proj>`) prepended to the built
   * rendition path — see core `imageUrl`'s `pathPrefix`. Needed when the asset lives in
   * a non-Default workspace, whose renditions are only reachable via the scoped route.
   */
  pathPrefix?: string
  /** Override the rendered component/tag. Defaults to `'img'`. Use `next/image` for framework-aware rendering. */
  as?: ComponentType<any> | string
  /** Explicit width; falls back to `asset.metadata.dimensions.width`. */
  width?: number
  /** Explicit height; falls back to `asset.metadata.dimensions.height`. */
  height?: number
  className?: string
  /** Invoked on each render where neither `asset.url` nor `baseUrl` resolves. */
  onMissingBaseUrl?: (asset: ImageAsset) => void
  /** Extra props forwarded unchanged to the underlying component. */
  [key: string]: unknown
}

const warnedMissingBaseUrlIds = new Set<string>()
let warnedPresetWithoutId = false

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
 * Pure src resolution — no user-visible side effects, so it's safe to call on
 * every render (including concurrent/aborted renders that never commit).
 *
 * Returns the built `src`, or `missAsset` set for the one case that used to warn
 * and invoke the user callback during render: an asset with a resolvable id but
 * no inline `.url` and no `baseUrl`. The caller reports that miss from an effect
 * (once per COMMIT) instead — see {@link BarkparkImage}.
 *
 * (The `preset`-without-id dev warning stays here: it's a one-shot module flag,
 * not a per-render user callback, so it can't double-fire a caller's analytics.)
 */
function computeImageSrc(
  asset: ImageAsset | null | undefined,
  baseUrl: string | undefined,
  preset: RenditionPreset | undefined,
  pathPrefix: string | undefined,
): { src?: string; missAsset?: ImageAsset } {
  // An unset optional image field (`null`/`undefined`) renders nothing — guard
  // before the getAsset* helpers, which use `in` and would throw on a nullish asset.
  if (asset == null) return {}

  let src: string | undefined
  // A `preset` requests a server rendition — prefer it over the inline url, using
  // the same core helper as the SDK.
  if (preset) {
    // A preset only applies to an asset with a resolvable id — core's imageUrl
    // returns a bare URL string / id-less asset unchanged, silently serving the
    // full-size original. Warn once so that invisible fallback isn't a mystery.
    if (getAssetId(asset) === undefined && !warnedPresetWithoutId) {
      warnedPresetWithoutId = true
      // eslint-disable-next-line no-console
      console.warn(
        `[BarkparkImage] preset '${preset}' requested but the asset has no resolvable id (bare URL string or missing _ref/_id); serving the full-size original instead of the rendition.`,
      )
    }
    // Include baseUrl/pathPrefix only when set — an unset prop never widens the path.
    const imgOpts: { preset: RenditionPreset; baseUrl?: string; pathPrefix?: string } = { preset }
    if (baseUrl) imgOpts.baseUrl = baseUrl
    if (pathPrefix) imgOpts.pathPrefix = pathPrefix
    src = imageUrl(asset, imgOpts) ?? undefined
  }
  if (!src) {
    if (typeof asset === 'string') {
      // A bare URL string is how Barkpark stores image fields. Prepend baseUrl
      // when it's a relative path.
      src = baseUrl && asset.startsWith('/') ? `${baseUrl.replace(/\/+$/, '')}${asset}` : asset
    } else {
      // An expanded asset's inline `.url` is likewise stored relative. Prepend
      // baseUrl when it's a relative path.
      const inline = getAssetUrl(asset)
      src = baseUrl && inline && inline.startsWith('/') ? `${baseUrl.replace(/\/+$/, '')}${inline}` : inline
    }
  }
  if (!src) {
    const id = getAssetId(asset)
    if (id) {
      if (baseUrl) {
        const trimmed = baseUrl.replace(/\/+$/, '')
        // Encode the id — spaces, '#', '?', '/' and non-ASCII are all legal in
        // Barkpark ids. Matches core imageUrl + Reference.buildDocPath.
        src = `${trimmed}/images/${encodeURIComponent(id)}`
      } else {
        // Resolvable id but no `.url` and no baseUrl → nothing to render. Report
        // this miss from an effect (see BarkparkImage) so a caller wiring analytics
        // into onMissingBaseUrl gets exactly one event per commit — not one per
        // render, and not for a concurrent render that never commits.
        return { missAsset: asset }
      }
    } else {
      return {}
    }
  }
  return { src }
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
 * The native `<img>` fallback defaults to `loading="lazy"` and
 * `decoding="async"` (the modern default, as in `next/image`). Both are
 * overridable — pass `loading="eager"` for an above-the-fold / LCP hero. Custom
 * `as` components are left untouched (they manage their own loading).
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
    pathPrefix,
    ...rest
  } = props

  // Resolve the src PURELY (no side effects), then report a missing-baseUrl miss
  // from the effect below. Doing the callback/logging in an effect means it fires
  // once per COMMITTED render — never twice within a StrictMode/concurrent commit,
  // and never for a render that React starts then throws away.
  const { src, missAsset } = computeImageSrc(asset, baseUrl, preset, pathPrefix)

  useEffect(() => {
    if (missAsset === undefined) return
    if (onMissingBaseUrl) {
      onMissingBaseUrl(missAsset)
      return
    }
    const id = getAssetId(missAsset)
    // De-dupe per asset id so the FIRST broken image doesn't silence diagnostics
    // for every other distinct broken asset — and name the id so "why is my image
    // blank" is debuggable.
    if (id !== undefined && !warnedMissingBaseUrlIds.has(id)) {
      warnedMissingBaseUrlIds.add(id)
      // eslint-disable-next-line no-console
      console.warn(
        `[BarkparkImage] asset '${id}' has no .url and no baseUrl was provided; skipping render.`,
      )
    }
  }, [missAsset, onMissingBaseUrl])

  // Rendered output stays synchronous: no src (unset/null asset, an id-less asset,
  // or a reported miss) renders nothing. `src` implies a non-null asset — the
  // `asset == null` check also narrows the type for the getAsset* helpers below.
  if (src === undefined || asset == null) return null

  const metadata = getMetadata(asset)
  const dims = metadata?.dimensions
  const width = widthProp ?? dims?.width
  const height = heightProp ?? dims?.height

  const Component: ComponentType<any> | string = as ?? 'img'
  const isStringTag = typeof Component === 'string'

  // For the native <img> fallback, default to the modern performance posture —
  // native lazy-loading + async decoding — matching what next/image and other
  // current image components do out of the box. Seeded BEFORE `...rest` so the
  // caller overrides freely: pass `loading="eager"` for an above-the-fold / LCP
  // hero. Custom `as` components (e.g. next/image) manage their own loading, so
  // we never inject these there.
  const elementProps: Record<string, unknown> = isStringTag
    ? { loading: 'lazy', decoding: 'async', ...rest, src, alt }
    : { ...rest, src, alt }
  if (width !== undefined) elementProps.width = width
  if (height !== undefined) elementProps.height = height
  if (className !== undefined) elementProps.className = className

  if (!isStringTag && metadata?.lqip) {
    elementProps.blurDataURL = metadata.lqip
  }

  return createElement(Component, elementProps)
}

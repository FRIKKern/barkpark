// Image URL builder — the preset-based equivalent of Sanity's `urlFor`.
//
// Barkpark serves a curated set of named renditions (mirroring the server's
// `Barkpark.Media.Renditions` presets) at `/media/renditions/<id>/<preset>`,
// rather than arbitrary on-the-fly transforms. `imageUrl` turns a stored image
// field — a `{_ref}` reference, an expanded `{_id, url}` asset, the reference
// shape `{asset: {_ref: "image-<sha1>-<w>x<h>-<ext>"}}`, or a bare URL string —
// into the URL for an `<img src>`. Renditions are fixed-size named presets, not
// width-parametric transforms, so there is no `srcSet` / `w=` (responsive-width)
// support.

import { isHttpUrl } from './util/guards'

/**
 * Server rendition presets (see `Barkpark.Media.Renditions.@presets`).
 *
 * Open union: editors still suggest the known preset names, but arbitrary
 * strings compile too, so a newly-added server preset isn't a false SDK
 * compile error (the SDK only interpolates the name into the URL path).
 */
export type RenditionPreset = 'thumb' | 'preview' | 'hero' | 'og' | (string & {})

/**
 * A stored image field: an unresolved reference (`{_ref}`), an expanded asset
 * (`{_id, url}`), the Studio media picker's value (`{url, assetId, …}`), the
 * reference shape (`{asset: {_ref}}`, docs/contracts/schema-v2.md; `asset` may
 * also be expanded to carry its `url`), or a bare URL string. Loose by design
 * so it accepts the core `MediaAsset`, the react `ImageAsset` and the Studio's
 * stored shapes without coupling.
 */
export type ImageRef =
  | string
  | {
      _ref?: string
      _id?: string
      assetId?: string
      url?: string
      asset?: { _ref?: string; _id?: string; _dataset?: string; url?: string } | null
    }

export interface ImageUrlOptions {
  /** A named server rendition (`thumb`/`preview`/`hero`/`og`). Omit for the original. */
  preset?: RenditionPreset
  /** Origin prepended to relative paths (e.g. the project URL). */
  baseUrl?: string
  /**
   * Workspace/project scope prefix, e.g. `/w/<ws>/p/<proj>`, prepended to the
   * built `/media/...` and `/images/...` paths; ignored when the asset carries
   * an inline url.
   */
  pathPrefix?: string
  /**
   * The dataset an image in the reference shape (`{asset: {_ref}}`) is served
   * from: `<pathPrefix>/images/barkpark/<dataset>/<sha1>-<w>x<h>.<ext>`. Without
   * it such an image has no URL. The client's `imageUrl` always sets its own.
   */
  dataset?: string
}

// A preset on a reference-shape image: the rendition route reads Barkpark file
// ids only, so the preset's bounds go to the Sanity route as transform params.
const PRESET_BOUNDS: Record<string, string> = {
  thumb: 'w=320&h=320&fit=max',
  preview: 'w=1600&h=1600&fit=max',
  hero: 'w=1920&h=1080&fit=max',
  og: 'w=1200&h=630&fit=crop',
}

function assetId(asset: ImageRef): string | undefined {
  if (typeof asset === 'string') return undefined
  if (asset._ref) return asset._ref
  if (asset._id) return asset._id
  // The Studio media picker stores `{url, assetId, alt, width, height, lqip}`
  // (bp-media-picker.js, `assetId` the canonical spelling). Without this a
  // `preset` on every Studio-authored image fell through to the full-size
  // original (stranger walk, 2026-09-30).
  if (typeof asset.assetId === 'string' && asset.assetId) return asset.assetId
  return undefined
}

function assetUrl(asset: ImageRef): string | undefined {
  if (typeof asset === 'string') return asset
  if (typeof asset.url === 'string' && asset.url) return asset.url
  return undefined
}

/**
 * Build a URL for a stored image field.
 *
 * - With `preset` (and a resolvable id) → the rendition route
 *   `<baseUrl>/media/renditions/<id>/<preset>`.
 * - Otherwise → the original: an inline `url` if the asset carries one, else
 *   `<baseUrl>/images/<id>`.
 * - The reference shape `{asset: {_ref}}` (no top-level id or url) → its
 *   expanded `asset.url`, else `<baseUrl><pathPrefix>/images/barkpark/<dataset>/
 *   <sha1>-<w>x<h>.<ext>` for `opts.dataset`, with a known `preset`'s bounds as
 *   `w`/`h`/`fit`. No `dataset`, a `_ref` that is not an image id, or a
 *   `_dataset` other than `opts.dataset` → `null`.
 *
 * Returns `null` when the asset is nullish, when no id/url can be resolved, or
 * when the stored url is not an absolute http(s) URL. That last case is a real
 * guard, not a claim: an image field is attacker-writable content, and the
 * inline branch used to return it verbatim — so `javascript:`, `data:`,
 * `vbscript:` and protocol-relative `//host` strings came straight back out of a
 * function whose whole job is to produce a URL for markup. It is a null here
 * rather than a throw because this is a synchronous render helper with a
 * documented `null` return; a bad field should blank the image, not crash the
 * page. Relative paths (a single leading `/`) are still ours and pass through.
 *
 * @example
 * imageUrl(post.cover, { preset: 'hero', baseUrl: 'https://cdn.example.com' })
 * // → 'https://cdn.example.com/media/renditions/abc/hero'
 */
export function imageUrl(
  asset: ImageRef | null | undefined,
  opts?: ImageUrlOptions,
): string | null {
  if (asset == null) return null
  const base = opts?.baseUrl ? opts.baseUrl.replace(/\/+$/, '') : ''
  const prefix = opts?.pathPrefix ?? ''
  const id = assetId(asset)

  if (opts?.preset && id) {
    return `${base}${prefix}/media/renditions/${encodeURIComponent(id)}/${encodeURIComponent(opts.preset)}`
  }

  const inline = assetUrl(asset)
  if (inline) {
    // A single leading '/' is a path on our own origin; '//host' is scheme-relative
    // and escapes it, so it goes through the scheme allowlist like any absolute URL.
    if (inline.startsWith('/') && inline[1] !== '/') return `${base}${inline}`
    return isHttpUrl(inline) ? inline : null
  }
  if (id) return `${base}${prefix}/images/${encodeURIComponent(id)}`
  return typeof asset === 'object' ? refUrl(asset.asset, base, prefix, opts) : null
}

// The reference shape: an expanded `asset.url` as any inline url, else the
// Sanity image route of `opts.dataset`, whose file is `<sha1>-<w>x<h>.<ext>` of
// the id `image-<sha1>-<w>x<h>-<ext>` (the server's rule:
// FieldInputs.sanity_image_url/4). A ref that names another dataset
// (`_dataset`) has no URL here.
function refUrl(
  a: { _ref?: string; _id?: string; _dataset?: string; url?: string } | null | undefined,
  base: string,
  prefix: string,
  opts?: ImageUrlOptions,
): string | null {
  if (!a || typeof a !== 'object') return null
  if (typeof a.url === 'string' && a.url) return imageUrl(a.url, opts)
  const m = /^image-([0-9a-f]{40}-[1-9]\d*x[1-9]\d*)-([a-z0-9]+)$/.exec(
    String(a._ref || a._id || '').toLowerCase(),
  )
  const ds = opts?.dataset
  // `typeof` keeps an inherited key (`constructor`, `__proto__`) out of the query.
  const q = PRESET_BOUNDS[opts?.preset as string]
  return m && ds && (!a._dataset || a._dataset === ds)
    ? `${base}${prefix}/images/barkpark/${encodeURIComponent(ds)}/${m[1]}.${m[2]}${typeof q === 'string' ? `?${q}` : ''}`
    : null
}

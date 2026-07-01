// Image URL builder — the preset-based equivalent of Sanity's `urlFor`.
//
// Barkpark serves a curated set of named renditions (mirroring the server's
// `Barkpark.Media.Renditions` presets) at `/media/renditions/<id>/<preset>`,
// rather than arbitrary on-the-fly transforms. `imageUrl` turns a stored image
// field — a `{_ref}` reference, an expanded `{_id, url}` asset, or a bare URL
// string — into the right URL for an `<img src>` / `srcSet`.

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
 * (`{_id, url}`), or a bare URL string. Loose by design so it accepts both the
 * core `MediaAsset` and the react `ImageAsset` shapes without coupling.
 */
export type ImageRef = string | { _ref?: string; _id?: string; url?: string }

export interface ImageUrlOptions {
  /** A named server rendition (`thumb`/`preview`/`hero`/`og`). Omit for the original. */
  preset?: RenditionPreset
  /** Origin prepended to relative paths (e.g. the project URL). */
  baseUrl?: string
}

function assetId(asset: ImageRef): string | undefined {
  if (typeof asset === 'string') return undefined
  if (asset._ref) return asset._ref
  if (asset._id) return asset._id
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
 *
 * Returns `null` when the asset is nullish or no id/url can be resolved. A bare
 * URL string has no id, so a `preset` can't apply — the string is returned as-is.
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
  const id = assetId(asset)

  if (opts?.preset && id) {
    return `${base}/media/renditions/${encodeURIComponent(id)}/${opts.preset}`
  }

  const inline = assetUrl(asset)
  if (inline) return base && inline.startsWith('/') ? `${base}${inline}` : inline
  if (id) return `${base}/images/${encodeURIComponent(id)}`
  return null
}

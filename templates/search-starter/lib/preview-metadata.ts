import type { Metadata } from "next";

/**
 * The ONE preview manifest → Next `Metadata` mapping (preview-contract W3a).
 *
 * Every Barkpark document carries a write-time `content["preview"]` manifest
 * (og-shaped, computed beside `content["body"]` so it can never drift). The v1
 * envelope HOISTS content keys to the top level, so it arrives on the query
 * response as `doc.preview` — NOT `doc.content.preview`. This module turns that
 * manifest into the finder page's OpenGraph/Twitter metadata, exactly the way
 * the papers reader's `BarkparkWeb.ShareMeta` turns it into head tags. No
 * per-type description/`article` switch: the manifest is the single source.
 *
 * Kept pure and Next-free (only a type-only `Metadata` import, erased at
 * runtime) so `node --test` — and pc-w4's cross-surface parity gate — can drive
 * it without a Next server. The API origin is injected (from the `bp-env`
 * `resolveApiUrl` seam), never read from `process.env` here.
 */

/** Branded 1200×630 fallback card served by the API — every doc unfurls, never blank (D5). */
export const DEFAULT_OG_IMAGE_PATH = "/images/og-default.jpg";
export const OG_IMAGE_WIDTH = 1200;
export const OG_IMAGE_HEIGHT = 630;
export const DEFAULT_IMAGE_TYPE = "image/jpeg";
export const SITE_NAME = "Barkpark";

/** The manifest's image object (D7): 5 fields, `url` stored RELATIVE (D3). */
export interface PreviewImage {
  url?: string;
  width?: number;
  height?: number;
  alt?: string;
  type?: string;
}

/** The write-time preview manifest, as hoisted onto the query response. */
export interface PreviewManifest {
  title?: string;
  type?: string;
  description?: string;
  url?: string;
  image?: PreviewImage | null;
  extensions?: Record<string, unknown>;
}

export interface PreviewMetadataInput {
  /** `doc.preview` off the query response — may be absent (legacy unstamped doc). */
  preview: unknown;
  /** API origin (from `resolveApiUrl`), used to absolutize the relative image src + default card. */
  apiOrigin: string;
  /** The finder page's own canonical path, for `og:url` (Next resolves it against `metadataBase`). */
  pageUrl: string;
  /** Title of last resort when the manifest is absent or title-less (slug / row title). */
  fallbackTitle: string;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

/** Trim to a non-empty string, else undefined. */
function cleanStr(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return t === "" ? undefined : t;
}

/** A positive integer dimension, else undefined (falls back to the constant 1200/630 geometry). */
function positiveInt(v: unknown): number | undefined {
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) return undefined;
  return Math.trunc(v);
}

// D8 — `type` stays raw in the manifest; the emitter maps it. paper/post →
// article, everything else → website. Mirrors ShareMeta.og_type/1 exactly.
function ogTypeFor(type: string | undefined): "article" | "website" {
  return type === "paper" || type === "post" || type === "article"
    ? "article"
    : "website";
}

// D3 — the manifest stores RELATIVE urls; absolutize the image src against the
// API origin at emission (the reader host serves `/media/renditions/…` and
// `/images/og-default.jpg`). Already-absolute + protocol-relative srcs pass
// through; a blank src becomes the branded default card.
function absolutizeImage(src: string | undefined, apiOrigin: string): string {
  const origin = apiOrigin.replace(/\/+$/, "");
  if (!src) return `${origin}${DEFAULT_OG_IMAGE_PATH}`;
  if (/^https?:\/\//i.test(src) || src.startsWith("//")) return src;
  if (src.startsWith("/")) return `${origin}${src}`;
  return `${origin}/${src}`;
}

/**
 * Map a preview manifest to the finder page's `Metadata`.
 *
 * Graceful degradation is total: an absent/garbage manifest yields title-only +
 * the branded default image + `website` type — never a broken/empty tag, never
 * a throw. twitter.card is always `summary_large_image` because an image (real
 * or default) always exists.
 */
export function metadataFromPreview({
  preview,
  apiOrigin,
  pageUrl,
  fallbackTitle,
}: PreviewMetadataInput): Metadata {
  const m: PreviewManifest = isRecord(preview) ? preview : {};

  const title = cleanStr(m.title) ?? cleanStr(fallbackTitle) ?? SITE_NAME;
  const description = cleanStr(m.description);
  const ogType = ogTypeFor(cleanStr(m.type));

  const img = isRecord(m.image) ? (m.image as PreviewImage) : null;
  const image = {
    url: absolutizeImage(cleanStr(img?.url), apiOrigin),
    width: positiveInt(img?.width) ?? OG_IMAGE_WIDTH,
    height: positiveInt(img?.height) ?? OG_IMAGE_HEIGHT,
    alt: cleanStr(img?.alt) ?? title,
    type: cleanStr(img?.type) ?? DEFAULT_IMAGE_TYPE,
  };

  return {
    title: `${title} · ${SITE_NAME}`,
    ...(description ? { description } : {}),
    openGraph: {
      title,
      ...(description ? { description } : {}),
      type: ogType,
      url: pageUrl,
      images: [image],
    },
    twitter: {
      card: "summary_large_image",
      title,
      ...(description ? { description } : {}),
      images: [image],
    },
  };
}

/**
 * The finder's manifest → Metadata mapping (preview-contract W3a). The write-
 * time `content["preview"]` card is the SINGLE source of every og/twitter tag —
 * no per-type description or `article` switch. These cases pin the three shapes
 * the epic must survive: a rich manifest, an image-less manifest (branded
 * default card), and an absent manifest (legacy unstamped doc → graceful,
 * never-broken degrade).
 *
 * Runs under Node's built-in test runner (`node --test`), which strips
 * TypeScript types at load time in Node v22+.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/preview-metadata.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  metadataFromPreview,
  DEFAULT_OG_IMAGE_PATH,
  OG_IMAGE_WIDTH,
  OG_IMAGE_HEIGHT,
} from "../lib/preview-metadata.ts";

const API = "https://api.example";

/**
 * Next's `Metadata.openGraph`/`twitter` are broad discriminated unions; the
 * fields this helper always sets (`type`, `card`, `images`) aren't narrowed on
 * the base union, so read them through a loose view for assertion purposes.
 */
type OgView = { type?: string; title?: unknown; url?: unknown; description?: unknown; images?: unknown };
type TwView = { card?: string; title?: unknown; description?: unknown; images?: unknown };

function og(md: ReturnType<typeof metadataFromPreview>): OgView {
  return (md.openGraph ?? {}) as OgView;
}
function tw(md: ReturnType<typeof metadataFromPreview>): TwView {
  return (md.twitter ?? {}) as TwView;
}

/** The single OG image descriptor the emitter always produces (real or default). */
function ogImage(md: ReturnType<typeof metadataFromPreview>) {
  const images = og(md).images;
  assert.ok(Array.isArray(images) && images.length === 1, "exactly one og:image");
  return images[0] as {
    url: string;
    width: number;
    height: number;
    alt: string;
    type: string;
  };
}

test("rich manifest: title/description/type/image all flow from the manifest", () => {
  const md = metadataFromPreview({
    preview: {
      title: "Theme System",
      type: "paper",
      description: "How Barkpark's design tokens fan out to every surface.",
      url: "/papers/theme-system",
      image: {
        url: "/media/renditions/abc123/og",
        width: 1200,
        height: 630,
        alt: "Theme System cover",
        type: "image/jpeg",
      },
    },
    apiOrigin: API,
    pageUrl: "/d/paper/theme-system",
    fallbackTitle: "theme-system",
  });

  assert.equal(md.title, "Theme System · Barkpark");
  assert.equal(
    md.description,
    "How Barkpark's design tokens fan out to every surface.",
  );
  // D8 — paper → article.
  assert.equal(og(md).type, "article");
  assert.equal(og(md).title, "Theme System");
  assert.equal(og(md).url, "/d/paper/theme-system");
  assert.equal(
    og(md).description,
    "How Barkpark's design tokens fan out to every surface.",
  );

  const img = ogImage(md);
  // D3 — relative rendition src absolutized against the API origin.
  assert.equal(img.url, "https://api.example/media/renditions/abc123/og");
  assert.equal(img.width, 1200);
  assert.equal(img.height, 630);
  assert.equal(img.alt, "Theme System cover");
  assert.equal(img.type, "image/jpeg");

  // twitter.card is always the large-image card, mirroring the image.
  assert.equal(tw(md).card, "summary_large_image");
  assert.equal(tw(md).title, "Theme System");
  const timages = tw(md).images;
  assert.ok(Array.isArray(timages) && timages.length === 1);
});

test("non-article type maps to website and carries no article og:type", () => {
  const md = metadataFromPreview({
    preview: { title: "Q3 Plan", type: "sheet", url: "/sheets/q3-plan" },
    apiOrigin: API,
    pageUrl: "/d/sheet/q3-plan",
    fallbackTitle: "q3-plan",
  });
  assert.equal(og(md).type, "website");
});

test("post type maps to article (mirrors reader D8)", () => {
  const md = metadataFromPreview({
    preview: { title: "Hello", type: "post" },
    apiOrigin: API,
    pageUrl: "/d/post/hello",
    fallbackTitle: "hello",
  });
  assert.equal(og(md).type, "article");
});

test("image-less manifest: falls back to the API's branded default card", () => {
  const md = metadataFromPreview({
    preview: {
      title: "No Cover",
      type: "paper",
      description: "A paper with no featured image.",
      url: "/papers/no-cover",
      image: null,
    },
    apiOrigin: API,
    pageUrl: "/d/paper/no-cover",
    fallbackTitle: "no-cover",
  });

  const img = ogImage(md);
  assert.equal(img.url, `${API}${DEFAULT_OG_IMAGE_PATH}`);
  assert.equal(img.width, OG_IMAGE_WIDTH);
  assert.equal(img.height, OG_IMAGE_HEIGHT);
  // A nil image alt falls back to the title (never empty).
  assert.equal(img.alt, "No Cover");
  assert.equal(img.type, "image/jpeg");
  // Still the large-image card — an image always exists.
  assert.equal(tw(md).card, "summary_large_image");
});

test("absent manifest (legacy unstamped doc): title-only + default image, no broken tags", () => {
  const md = metadataFromPreview({
    preview: undefined,
    apiOrigin: API,
    pageUrl: "/d/page/about",
    fallbackTitle: "About Barkpark",
  });

  assert.equal(md.title, "About Barkpark · Barkpark");
  // No description key at all — never an empty/broken tag.
  assert.equal(md.description, undefined);
  assert.equal(og(md).description, undefined);
  assert.equal(tw(md).description, undefined);
  // Degrades to website + branded default card.
  assert.equal(og(md).type, "website");
  const img = ogImage(md);
  assert.equal(img.url, `${API}${DEFAULT_OG_IMAGE_PATH}`);
  assert.equal(img.alt, "About Barkpark");
  assert.equal(tw(md).card, "summary_large_image");
});

test("garbage manifest (non-object) degrades exactly like an absent one", () => {
  const md = metadataFromPreview({
    preview: "not-an-object",
    apiOrigin: API,
    pageUrl: "/d/page/weird",
    fallbackTitle: "Weird",
  });
  assert.equal(md.title, "Weird · Barkpark");
  assert.equal(og(md).type, "website");
  assert.equal(ogImage(md).url, `${API}${DEFAULT_OG_IMAGE_PATH}`);
});

test("absolutize is trailing-slash safe and passes through absolute image srcs", () => {
  const md = metadataFromPreview({
    preview: {
      title: "Ext",
      type: "paper",
      image: { url: "https://cdn.example/pic.png", alt: "ext" },
    },
    apiOrigin: "https://api.example/", // trailing slash must not double up
    pageUrl: "/d/paper/ext",
    fallbackTitle: "ext",
  });
  // Already-absolute src passes through untouched.
  assert.equal(ogImage(md).url, "https://cdn.example/pic.png");

  const md2 = metadataFromPreview({
    preview: { title: "Rel", type: "paper", image: { url: "/media/x/og" } },
    apiOrigin: "https://api.example/",
    pageUrl: "/d/paper/rel",
    fallbackTitle: "rel",
  });
  assert.equal(ogImage(md2).url, "https://api.example/media/x/og");
});

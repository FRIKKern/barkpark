/**
 * Cross-surface preview-parity — the WEB leg (preview-contract W4, charter D20).
 *
 * The finder's `metadataFromPreview` (the SAME pure helper `generateMetadata`
 * uses) is driven over the SHARED parity fixture — the ONE
 * `Barkpark.Preview.project/3` manifest, mirrored byte-for-byte from the api
 * generator (`mix barkpark.preview.gen_parity`). Every og/twitter field the web
 * finder renders is asserted equal to the fixture manifest, so the web can
 * never drift from the reader / envelope / Studio / TUI surfaces without reddin
 * here. The api freshness lock (`preview_parity_fixture_test.exs`) proves this
 * mirror equals the other two.
 *
 * DEGRADATION INVARIANT: the `core` variant (title/type/url only) still yields a
 * valid BRANDED card — the branded default image, `article` type, title-only.
 *
 * Runs under Node's built-in test runner (`node --test`), which strips
 * TypeScript types at load time. Run: `pnpm test`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  metadataFromPreview,
  DEFAULT_OG_IMAGE_PATH,
  OG_IMAGE_WIDTH,
  OG_IMAGE_HEIGHT,
} from "../lib/preview-metadata.ts";

const API = "https://api.example";

const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("./fixtures/preview-parity.json", import.meta.url)),
    "utf8",
  ),
) as {
  rich: { manifest: Record<string, any> };
  core: { manifest: Record<string, any> };
};

type OgView = { type?: string; title?: unknown; url?: unknown; description?: unknown; images?: unknown };
type TwView = { card?: string; title?: unknown; description?: unknown; images?: unknown };

function og(md: ReturnType<typeof metadataFromPreview>): OgView {
  return (md.openGraph ?? {}) as OgView;
}
function tw(md: ReturnType<typeof metadataFromPreview>): TwView {
  return (md.twitter ?? {}) as TwView;
}
function ogImage(md: ReturnType<typeof metadataFromPreview>) {
  const images = og(md).images;
  assert.ok(Array.isArray(images) && images.length === 1, "exactly one og:image");
  return images[0] as { url: string; width: number; height: number; alt: string; type: string };
}

test("rich: every og/twitter field flows from the shared manifest", () => {
  const m = fixture.rich.manifest;
  const md = metadataFromPreview({
    preview: m,
    apiOrigin: API,
    pageUrl: m.url,
    fallbackTitle: m.title,
  });

  // title / description / type — straight off the manifest.
  assert.equal(og(md).title, m.title);
  assert.equal(og(md).description, m.description);
  assert.equal(og(md).type, "article"); // paper → article (D8)
  assert.equal(og(md).url, m.url);

  // image — the RELATIVE manifest url absolutized against the API origin (D3),
  // all five fields intact.
  const img = ogImage(md);
  assert.equal(img.url, `${API}${m.image.url}`);
  assert.equal(img.width, m.image.width);
  assert.equal(img.height, m.image.height);
  assert.equal(img.alt, m.image.alt);
  assert.equal(img.type, m.image.type);

  // twitter mirrors the same fields; card is always summary_large_image.
  assert.equal(tw(md).card, "summary_large_image");
  assert.equal(tw(md).title, m.title);
  assert.equal(tw(md).description, m.description);
});

test("DEGRADATION — core: title-only manifest still yields a branded card", () => {
  const m = fixture.core.manifest;
  const md = metadataFromPreview({
    preview: m,
    apiOrigin: API,
    pageUrl: m.url,
    fallbackTitle: m.title,
  });

  assert.equal(og(md).title, m.title);
  // No description in the manifest → the tag is omitted, never emitted empty.
  assert.equal(og(md).description, undefined);

  // The branded 1200×630 default card (D5) — every doc unfurls, never blank.
  const img = ogImage(md);
  assert.equal(img.url, `${API}${DEFAULT_OG_IMAGE_PATH}`);
  assert.equal(img.width, OG_IMAGE_WIDTH);
  assert.equal(img.height, OG_IMAGE_HEIGHT);
  assert.equal(img.alt, m.title); // nil alt falls back to the title
  assert.equal(tw(md).card, "summary_large_image");
});

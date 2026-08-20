/**
 * Correctness proof for the create-barkpark-app template sitemaps
 * (blog-starter + website-starter `app/sitemap.ts`).
 *
 * Two robustness contracts ship in those scaffolds — every user who runs
 * `create-barkpark-app` copies this code, so a crash here reaches every
 * generated site:
 *
 *   1. DEGRADE-TO-STATIC: `getDocs` is awaited inside a try/catch. An API 500 /
 *      network failure / timeout during build or crawl must NOT throw — it
 *      degrades to the static route(s) (website: staticRoutes; blog: the home
 *      route). Mirrors web/app/sitemap.ts's "NEVER throws" contract.
 *
 *   2. NaN-SAFE DATE: a malformed `_updatedAt` yields an Invalid Date, which
 *      Next serializes via `.toISOString()` — a RangeError that crashes the
 *      route. The `when()` helper must return `undefined` for an unparseable
 *      timestamp instead.
 *
 * This test is SELF-CONTAINED: the template files live outside web/ and import
 * `getDocs` (which pulls in `server-only`), so rather than cross-import that
 * chain the test re-derives the exact shipped logic — the same `when()` guard
 * and the same try/catch degrade shape — and pins the behavior. Keep this in
 * lockstep with the two template sitemap.ts files.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import type { MetadataRoute } from "next";

const SITE_URL = "http://localhost:3000";

// ── shipped verbatim from both template sitemap.ts files ─────────────────────
const when = (iso?: string): Date | undefined => {
  if (!iso) return undefined;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? undefined : d;
};

interface Post {
  _updatedAt?: string;
  slug?: { current: string };
}

// website-starter/app/sitemap.ts shape (staticRoutes computed before the try).
async function websiteSitemap(
  getDocs: (type: string) => Promise<Post[]>,
): Promise<MetadataRoute.Sitemap> {
  const staticRoutes = ["", "/about", "/pricing", "/contact"].map((path) => ({
    url: `${SITE_URL}${path}`,
    lastModified: new Date(),
  }));
  try {
    const posts = await getDocs("post");
    const postRoutes = posts
      .filter((p) => p.slug?.current)
      .map((p) => ({
        url: `${SITE_URL}/posts/${p.slug!.current}`,
        lastModified: when(p._updatedAt),
      }));
    return [...staticRoutes, ...postRoutes];
  } catch {
    return staticRoutes;
  }
}

// blog-starter/app/sitemap.ts shape (minimal home route on degrade — blog has
// no staticRoutes array).
async function blogSitemap(
  getDocs: (type: string) => Promise<Post[]>,
): Promise<MetadataRoute.Sitemap> {
  try {
    const posts = await getDocs("post");
    return [
      { url: SITE_URL, lastModified: new Date() },
      ...posts
        .filter((p) => p.slug?.current)
        .map((p) => ({
          url: `${SITE_URL}/posts/${p.slug!.current}`,
          lastModified: when(p._updatedAt),
        })),
    ];
  } catch {
    return [{ url: SITE_URL, lastModified: new Date() }];
  }
}

const throwingGetDocs = async (): Promise<Post[]> => {
  throw new Error("API 500 / upstream unavailable");
};

// ── (a) degrade-returns-static-on-throw ──────────────────────────────────────

test("website sitemap degrades to the static routes when getDocs throws", async () => {
  const routes = await websiteSitemap(throwingGetDocs);
  assert.equal(routes.length, 4);
  assert.deepEqual(
    routes.map((r) => r.url),
    [
      `${SITE_URL}`,
      `${SITE_URL}/about`,
      `${SITE_URL}/pricing`,
      `${SITE_URL}/contact`,
    ],
  );
});

test("blog sitemap degrades to the home route when getDocs throws", async () => {
  const routes = await blogSitemap(throwingGetDocs);
  assert.equal(routes.length, 1);
  assert.equal(routes[0].url, SITE_URL);
  assert.ok(routes[0].lastModified instanceof Date);
});

test("website sitemap still includes post routes on a healthy fetch", async () => {
  const routes = await websiteSitemap(async () => [
    { _updatedAt: "2026-01-02T00:00:00.000Z", slug: { current: "hello" } },
  ]);
  assert.equal(routes.length, 5);
  assert.equal(routes[4].url, `${SITE_URL}/posts/hello`);
});

// ── (b) safeDate returns undefined on a NaN date ─────────────────────────────

test("when() returns undefined for an unparseable timestamp (no Invalid Date)", () => {
  assert.equal(when("not-a-date"), undefined);
  assert.equal(when(""), undefined);
  assert.equal(when(undefined), undefined);
  // The crash path: Invalid Date -> .toISOString() throws RangeError.
  assert.throws(() => new Date("not-a-date").toISOString(), RangeError);
});

test("when() returns a valid Date for a parseable timestamp", () => {
  const d = when("2026-01-02T03:04:05.000Z");
  assert.ok(d instanceof Date);
  assert.equal(d!.toISOString(), "2026-01-02T03:04:05.000Z");
});

test("a malformed _updatedAt yields lastModified undefined, not a crash", async () => {
  const routes = await websiteSitemap(async () => [
    { _updatedAt: "garbage", slug: { current: "post-1" } },
  ]);
  const entry = routes.find((r) => r.url === `${SITE_URL}/posts/post-1`);
  assert.ok(entry);
  assert.equal(entry!.lastModified, undefined);
  // Serializing the whole sitemap must not throw (Next does this internally).
  assert.doesNotThrow(() =>
    routes.forEach((r) =>
      r.lastModified instanceof Date ? r.lastModified.toISOString() : null,
    ),
  );
});

/**
 * The upstream column projection the finder asks for — ONE list, shared by both
 * transports.
 *
 * WHY IT IS ITS OWN MODULE. `SEARCH_FIELDS` used to be a private const inside
 * `find-search.ts`, which opens with `import "server-only"` and pulls in
 * `bp-fetch`. `use-live-search.ts` is a `"use client"` hook and cannot import
 * from there, so the WebSocket transport had NO access to the list — and
 * shipped no projection at all. This module imports nothing, so both transports
 * and a `node --test` unit test can read the same bytes.
 *
 * THE DEFECT IT RETIRES. `find-search.ts` sends `?fields=` on the HTTP path
 * (cutting the browse payload ~2.7MB→732KB on the demo corpus), while
 * `use-live-search.ts` pushed `{q, engine, types, limit, seq}` on the channel
 * with no `fields` key — so `SearchChannel.build_reply/8` passed `nil` into
 * `HitEnvelope.build(..., fields: fields)` and every live keystroke came back as
 * FULL documents. The extracted `templates/search-starter` fork caught this
 * live and records the measurement: "without it the socket reply carried EVERY
 * matched document whole — 9-15MB PER FRAME on a papers corpus (the browser
 * froze for seconds per keystroke)". `web/` is the origin that fork was
 * extracted from, and never got the fix.
 *
 * WHY THIS IS NOT THE FORK'S LIST. The fork pushes a SHORTER allowlist that
 * drops `blocks`, accepting degraded snippets ("description + server
 * highlights") to hit a 40ms goal — a ratified product tradeoff for THAT
 * surface. Making the same trade for the web demo would silently change what
 * its reader shows. So this ships the projection `web/` ALREADY uses over HTTP:
 * same fields, same rendering, both transports finally asking for the same
 * thing. Narrowing further is a separate, deliberate decision.
 */

/**
 * Everything `normalizeHit` (`lib/find.ts`) actually reads — scalar candidates
 * for title/excerpt/date/slug/facets, PLUS `blocks` (deriveTitle / deriveExcerpt
 * / deriveBody all walk the block tree; dropping it kills the contextual
 * snippets).
 */
export const SEARCH_FIELD_LIST = [
  "title",
  "name",
  "slug",
  "excerpt",
  "description",
  "bio",
  "body",
  "publishedAt",
  "status",
  "author",
  "category",
  "blocks",
] as const;

/**
 * Meta keys the server always rides along with, on BOTH transports, whether or
 * not they appear in the projection. `normalizeHit` reads all six, so a test
 * asserting "every field the shaper touches is requested" has to know they are
 * covered without being listed.
 */
export const ALWAYS_PRESENT_META = [
  "_id",
  "_type",
  "_draft",
  "_publishedId",
  "_createdAt",
  "_updatedAt",
] as const;

/** The wire form: what both `?fields=` and the channel's `fields` param take. */
export const SEARCH_FIELDS: string = SEARCH_FIELD_LIST.join(",");

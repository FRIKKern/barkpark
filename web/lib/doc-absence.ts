/**
 * The ABSENT-vs-UNAVAILABLE ruling for `lib/get-document.ts`, extracted so it
 * is testable: `get-document.ts` imports `next/cache`, which does not resolve
 * under bare `node --test` (the same constraint behind `lib/paginate.ts` and
 * `lib/graph-truncation.ts`). This module imports only `@barkpark/core`, which
 * does resolve, so the ruling ships and is tested as ONE artifact.
 *
 * THE DEFECT IT RETIRES. `js/packages/core/src/docs.ts` documents a DELIBERATE
 * asymmetry (site-spawner-backlog-core-list-404-swallow, wave-7 D72):
 *
 *   - a PUBLIC type with zero matching documents is a 200 with an empty page —
 *     `.findOne()` resolves `null`, because absence of DATA is a normal state;
 *   - a MISSING OR PRIVATE TYPE is a 404 — `.findOne()` REJECTS with
 *     `BarkparkNotFoundError`, because a schema-name typo or a type that is
 *     private for this token is a misconfiguration the caller must see;
 *   - `getDoc` (the by-id leg) maps its own 404 to `null`, since the absence of
 *     ONE document of a valid type IS a normal data state.
 *
 * `get-document.ts` wrapped BOTH legs in one try/catch that turned every throw
 * into `{ doc: null, error: err.message }`, and its consumers read that as
 * "upstream unavailable", never as "absent":
 *
 *   app/(finder)/d/[type]/[slug]/page.tsx  `if (!doc && !error) notFound()`
 *                                          — an error means NO 404
 *   …/page.tsx                             returns "Document unavailable"
 *                                          instead of the 404 metadata
 *   components/document-detail.tsx         renders the red "Failed to load
 *                                          document." panel
 *
 * So a request for a type in that route's hard-coded `KNOWN_TYPES` set that the
 * target dataset does not define — or that is private for the demo's read
 * token — answered HTTP 200 with a red error panel where the honest answer is
 * 404. A soft-404 on a route that should 404, reachable by a hand-typed URL and
 * by any crawler.
 *
 * THE LAW. The two absent-doc shapes are DISTINCT because they render
 * differently, and the distinction is the whole point:
 *
 *   { doc: null, error: null }   → not found          → the page 404s honestly
 *   { doc: null, error: "…" }    → upstream unavailable → inline error panel
 *
 * An upstream 404 belongs to the FIRST bucket. Everything else — a 401, a 500,
 * a timeout, a parse failure, a non-Error throw — belongs to the SECOND and
 * keeps its message: degrading a real outage to a 404 would hide it, which is
 * the opposite mistake and just as dishonest.
 *
 * Membership is tested with `@barkpark/core`'s own `isBarkparkError`, which
 * keys on the error's `code` string rather than `instanceof`. That matters in
 * this monorepo: `@barkpark/core` is linked by `file:`, so a second copy of the
 * class in another realm would defeat an `instanceof` check while the code
 * comparison holds.
 */

import { isBarkparkError } from "@barkpark/core";

/** The absent-doc half of `DocResult` — `doc` is always null here. */
export interface DocAbsence {
  doc: null;
  /** null = not found (404 honestly); a string = upstream unavailable. */
  error: string | null;
}

/**
 * Rule on a throw from either fetch leg. A `BarkparkNotFoundError` means the
 * type does not exist or is not readable by this token — from the reader's
 * point of view the document is ABSENT, so it 404s. Anything else is a real
 * failure and keeps its message.
 */
export function docResultFromError(err: unknown): DocAbsence {
  if (isBarkparkError(err, "BarkparkNotFoundError")) {
    return { doc: null, error: null };
  }
  return { doc: null, error: err instanceof Error ? err.message : String(err) };
}

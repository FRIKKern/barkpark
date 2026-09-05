/**
 * The ABSENT-vs-MISCONFIGURED ruling for `lib/get-document.ts`, extracted so it
 * is testable HERE, in the tree that ships it.
 *
 * WHY EXTRACTED (the decision, not a copy of web's layout). `get-document.ts`
 * imports `server-only`, `react`'s `cache` and `next/cache`'s `unstable_cache`.
 * The CI job that runs this suite — `search-starter-smoke.yml` `finder-unit` —
 * is DELIBERATELY dependency-free (node 22's native type-stripping, no
 * `npm ci`), so `get-document.ts` cannot be imported there at all. The template
 * already made this call twice for the same reason: `lib/listings-data.ts`
 * exists because `lib/listings.ts` pulls `server-only` + `next/cache`, and
 * `lib/retry-after.ts` exists because `lib/bp-fetch.ts` does. This is the third
 * instance of the fork's OWN pattern; that it also matches `web/lib/`'s layout
 * is a consequence, not the reason.
 *
 * The one dependency kept is `@barkpark/core`'s `isBarkparkError`, which the
 * test resolves through `lib/__test-stub-hooks.mjs` (the same mechanism that
 * makes `bp-fetch.ts` importable dep-free). Classification stays keyed on the
 * error's `code` STRING, never `instanceof`: `@barkpark/core` is linked by
 * `file:` here, so a second copy of the class in another realm would defeat an
 * `instanceof` check while the code comparison holds.
 *
 * ── THE RULING ──────────────────────────────────────────────────────────────
 *
 * `js/packages/core/src/docs.ts` encodes a DELIBERATE asymmetry
 * (site-spawner-backlog-core-list-404-swallow, wave-7 D72), and the whole point
 * of this module is to keep the two halves apart:
 *
 *   - a PUBLIC type with zero matching documents is a 200 with an empty page —
 *     `.findOne()` RESOLVES `null`, because absence of DATA is a normal state;
 *   - a MISSING OR PRIVATE TYPE is a 404 — `.findOne()` REJECTS with
 *     `BarkparkNotFoundError`, because a schema-name typo or a type that is
 *     private to this token is a MISCONFIGURATION THE OPERATOR MUST SEE;
 *   - `getDoc` (the by-id leg, `client.doc(type, slug)`) maps its OWN 404 to
 *     `null` inside core, since the absence of ONE document of a valid type IS
 *     a normal data state.
 *
 * That third bullet is what makes the split decidable with no extra plumbing:
 * the by-id leg never throws `BarkparkNotFoundError`, so any that reaches this
 * module came from the slug-query leg, and from the slug-query leg it means the
 * TYPE, not the document.
 *
 * ── WHAT THIS RETIRES ───────────────────────────────────────────────────────
 *
 * `get-document.ts` used to catch every `BarkparkNotFoundError` into
 * `{ doc: null, error: null }` — "absent, and that is fine" — and its comment
 * defended the collapse: *"the slug-query leg THROWS BarkparkNotFoundError
 * (e.g. when the type itself is unknown to the API), so it is caught here — a
 * doc that does not exist must never wear a red failure panel."* The first
 * clause is true and the conclusion does not follow from it: "the type is
 * unknown to the API" is not "the doc does not exist".
 *
 * The consequence was worst exactly where this code ships. `DOC_TYPES` comes
 * from the operator's own config, and `/d/[type]/[slug]/page.tsx` builds
 * `KNOWN_TYPES` from it — so a mistyped schema name is admitted by the route's
 * own guard, reaches this ruling, and renders a clean, confident 404 page.
 * Nothing logged, nothing red; the operator's only signal is that their content
 * "isn't showing up". For a TEMPLATE, whose audience is someone wiring up a new
 * instance for the first time, that is the worst available failure mode.
 *
 * ── THE LAW ─────────────────────────────────────────────────────────────────
 *
 * Two `DocResult` shapes, kept DISTINCT because they render differently:
 *
 *   { doc: null, error: null }   → absent, honestly  → the page 404s
 *   { doc: null, error: "…" }    → the reader must see it → inline error panel
 *
 * An upstream 404 on the TYPE belongs to the SECOND bucket, with a message that
 * names the type and the two things that produce it. Everything else — a 401, a
 * 500, a timeout, a parse failure, a non-Error throw — also belongs to the
 * second and keeps its own message: degrading a real outage to a 404 hides it,
 * which is the same mistake pointed the other way.
 *
 * The FIRST bucket is not reached by catching anything. It is the success path:
 * `.findOne()` resolved `null` and the by-id fallback resolved `null` too.
 */

import { isBarkparkError } from "@barkpark/core";

/** `{ doc, error }` — `doc` is null exactly when there is nothing to render. */
export interface DocOutcome<T> {
  doc: T | null;
  /** null = absent (404 honestly); a string = the reader must be told. */
  error: string | null;
}

/**
 * The message for the misconfiguration bucket. Exported so the test asserts the
 * text an operator actually reads, and so it is written once.
 */
export function unknownTypeMessage(type: string): string {
  return (
    `Unknown document type "${type}". The API answered 404 for the TYPE ` +
    `itself, not for this document — either the schema name is misspelled in ` +
    `this site's config, or the type is not readable by the configured token.`
  );
}

/**
 * Run a document fetch and rule on the outcome.
 *
 * Resolving `null` is the ABSENT bucket. A `BarkparkNotFoundError` is the
 * unknown-or-private TYPE bucket and is surfaced. Any other throw is surfaced
 * with its own message.
 *
 * The fetch is injected rather than imported so this ruling is exercised
 * end-to-end — both branches, one code path — without dragging `next/cache`
 * into the dep-free test job.
 */
export async function resolveDocOutcome<T>(
  type: string,
  fetchDoc: () => Promise<T | null>,
): Promise<DocOutcome<T>> {
  try {
    return { doc: await fetchDoc(), error: null };
  } catch (err) {
    if (isBarkparkError(err, "BarkparkNotFoundError")) {
      return { doc: null, error: unknownTypeMessage(type) };
    }
    return {
      doc: null,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

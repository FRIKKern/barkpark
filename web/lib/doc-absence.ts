/**
 * The ABSENT-vs-MISCONFIGURED ruling for `lib/get-document.ts`, extracted so it
 * is testable: `get-document.ts` imports `next/cache`, which does not resolve
 * under bare `node --test` (the same constraint behind `lib/paginate.ts` and
 * `lib/graph-truncation.ts`). This module imports only `@barkpark/core`, which
 * does resolve, so the ruling ships and is tested as ONE artifact.
 *
 * ── THE ASYMMETRY IT ENCODES ────────────────────────────────────────────────
 *
 * `js/packages/core/src/docs.ts` documents a DELIBERATE asymmetry
 * (site-spawner-backlog-core-list-404-swallow, wave-7 D72):
 *
 *   - a PUBLIC type with zero matching documents is a 200 with an empty page —
 *     `.findOne()` RESOLVES `null`, because absence of DATA is a normal state;
 *   - a MISSING OR PRIVATE TYPE is a 404 — `.findOne()` REJECTS with
 *     `BarkparkNotFoundError`, because a schema-name typo or a type that is
 *     private for this token is a MISCONFIGURATION THE OPERATOR MUST SEE;
 *   - `getDoc` (the by-id leg, `client.doc(type, slug)`) maps its OWN 404 to
 *     `null` inside core (`js/packages/core/src/doc.ts`, in `getDoc`), since the
 *     absence of ONE document of a valid type IS a normal data state.
 *
 * That third bullet is what makes the split decidable with no extra plumbing:
 * the by-id leg never throws `BarkparkNotFoundError`, so any that reaches this
 * module came from the slug-query leg, and from the slug-query leg it means the
 * TYPE, not the document.
 *
 * ── WHAT THIS RETIRES (twice, in opposite directions) ───────────────────────
 *
 * FIRST, `get-document.ts` wrapped both legs in one try/catch that turned every
 * throw into `{ doc: null, error: err.message }`, so a document that simply did
 * not exist wore the red "Failed to load document." panel behind an HTTP 200
 * where the honest answer is 404. #13431 fixed that by routing the throw here.
 *
 * SECOND — and this is the correction — that fix over-shot: it pushed the TYPE
 * 404 into the ABSENT bucket too, ruling verbatim that "from the reader's point
 * of view the document is ABSENT, so it 404s". The reader is not the only
 * audience. `app/(finder)/d/[type]/[slug]/page.tsx` gates the route on its own
 * hard-coded `KNOWN_TYPES` set, so an unknown type CANNOT arrive from a
 * hand-typed URL — it is rejected by `notFound()` before any fetch. A
 * `BarkparkNotFoundError` therefore reaches this module only for a type THIS
 * SITE claims to render: the schema name is misspelled in the site's own
 * config, or the type is not readable by the configured token. Ruling that
 * absent renders a clean, confident 404 with nothing logged — the operator's
 * only signal is that their content "isn't showing up".
 *
 * `templates/search-starter/lib/doc-absence.ts` reached the same conclusion for
 * the template (PR #15762); this module is the web half of that pair, and
 * `scripts/check-web-fork-drift.sh` INV-7 now watches that the two agree.
 *
 * ── THE LAW ─────────────────────────────────────────────────────────────────
 *
 * Two `DocResult` shapes, kept DISTINCT because they render differently:
 *
 *   { doc: null, error: null }   → absent, honestly     → the page 404s
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
 *
 * Membership is tested with `@barkpark/core`'s own `isBarkparkError`, which
 * keys on the error's `code` STRING rather than `instanceof`. That matters in
 * this monorepo: `@barkpark/core` is linked by `file:`, so a second copy of the
 * class in another realm would defeat an `instanceof` check while the code
 * comparison holds.
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
 * into the bare `node --test` job.
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

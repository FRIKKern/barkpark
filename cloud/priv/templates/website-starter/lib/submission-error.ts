/**
 * Turns a caught mutation error into the sentence an ANONYMOUS visitor is
 * allowed to read.
 *
 * WHY THIS EXISTS
 *
 * The contact form used to render `Submission failed: ${err.message}` straight
 * into the page. `err.message` on this path is the raw upstream answer from
 * `POST /v1/data/mutate/:dataset` — it can carry the API host, the dataset and
 * workspace/project slugs, schema field names, a bearer-token rejection reason,
 * or a database constraint string. None of that is the visitor's to see, and a
 * contact form is reachable by anyone with the URL. What the visitor needs is
 * whether to retry and how else to reach you; the detail belongs in the SERVER
 * log, where the operator can read it.
 *
 * Kept dependency-free (no 'server-only', no next/*, no @barkpark/* imports) so
 * it is unit-testable directly — see create-barkpark-app's
 * tests/template-contact-action.test.ts, which imports THIS file.
 */

/** The one sentence any failed submission shows. Never derived from the error. */
export const SUBMISSION_FAILED_MESSAGE =
  'Sorry — we could not send your message just now. Please try again in a moment.'

/**
 * The public message for a failed submission: a fixed string, chosen WITHOUT
 * reading the error. The parameter exists so the signature documents that the
 * error was considered and deliberately not surfaced, and so a future variant
 * (e.g. a distinct "we are rate-limiting you" line) has an obvious home — any
 * such branch must be driven by a value THIS code produced, never by upstream text.
 */
export function publicSubmissionMessage(_err: unknown): string {
  return SUBMISSION_FAILED_MESSAGE
}

/**
 * The operator-facing detail, for `console.error` on the server only.
 * Never returned to the browser.
 */
export function serverLogDetail(err: unknown): string {
  if (err instanceof Error) return err.stack ?? `${err.name}: ${err.message}`
  return String(err)
}

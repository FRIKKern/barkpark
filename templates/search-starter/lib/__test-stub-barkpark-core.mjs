// A dep-free stand-in for the sliver of `@barkpark/core` that `doc-absence.ts`
// imports. The `finder-unit` CI job runs with NO `npm ci`, and the real package
// arrives as a `file:` vendor tarball, so the bare specifier cannot resolve
// there — the same situation `undici` is in for `bp-fetch.ts`.
//
// `isBarkparkError` below is a VERBATIM port of
// `js/packages/core/src/errors.ts:345-350` (the runtime body; the file's other
// eleven lines are TypeScript overload signatures, which erase). If that body
// ever changes, this copy is wrong and `doc-absence.test.ts` is testing a
// fiction — the check is four lines long precisely so the comparison is cheap.
//
// The point it must preserve: matching is on the `code` STRING, not
// `instanceof`. Everything downstream of it is the fork's own code, unstubbed.

/**
 * @param {unknown} e
 * @param {string} [code]
 * @returns {boolean}
 */
export function isBarkparkError(e, code) {
  if (typeof e !== "object" || e === null) return false;
  const c = /** @type {{ code?: unknown }} */ (e).code;
  if (typeof c !== "string") return false;
  return code === undefined || c === code;
}

/**
 * The shape core throws on a 404: `BarkparkNotFoundError extends
 * BarkparkAPIError extends BarkparkError`, whose `code` is the class name and
 * whose `status` is carried from the response.
 */
export class BarkparkNotFoundError extends Error {
  /** @param {string} message @param {{status?: number, serverCode?: string}} [opts] */
  constructor(message, opts) {
    super(message);
    this.name = "BarkparkNotFoundError";
    this.code = "BarkparkNotFoundError";
    this.status = opts?.status ?? 404;
    if (opts?.serverCode !== undefined) this.serverCode = opts.serverCode;
  }
}

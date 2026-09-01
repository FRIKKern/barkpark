// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// The two shared runtime guards for caller-supplied strings that end up in a
// URL: one for a single PATH SEGMENT, one for a whole URL's scheme. Both are
// runtime checks on purpose — this package ships CJS/ESM to plain JS callers
// with no types at all, so a type signature closes nothing.

import { BarkparkValidationError } from '../errors'

/**
 * Assert `value` is usable as ONE URL path segment.
 *
 * `encodeURIComponent` escapes `/` and `\` but NOT `.`, so an id of `'..'`
 * reaches `fetch` intact and the WHATWG URL parser resolves it BEFORE the
 * request leaves — retargeting the call at an endpoint other than the one the
 * function name promises (worst case: a collection share-revoke emitted
 * `DELETE /v1/media/:dataset/:id`, i.e. an asset deletion). Escaping harder
 * cannot fix that; the honest rule is that a path segment may not be a
 * relative-path operator.
 *
 * Percent-encoded forms (`%2e%2e`) are deliberately NOT rejected: every call
 * site wraps the value in `encodeURIComponent`, which escapes the `%` itself
 * (`%252e%252e`), so they can never decode back to `..` at the URL parser.
 * A guard against them would cost bytes and close nothing.
 *
 * Empty and whitespace-only values are rejected too — they collapse the path
 * the same way (`//share`).
 *
 * `/` and `\` are rejected as well, as defence in depth for identifiers: no id
 * in this API legitimately contains one, and the ban holds even if a future
 * path builder forgets `encodeURIComponent`. Pass `allowSep` at the one call
 * site where separators ARE legitimate content — a hierarchical tag name like
 * `a/b`, which `encodeURIComponent` turns into a single `a%2Fb` segment.
 */
export function assertSegment(
  value: unknown,
  field: string,
  message?: string,
  allowSep = false,
): void {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value === '.' ||
    value === '..' ||
    (!allowSep && /[/\\]/.test(value))
  ) {
    throw new BarkparkValidationError(
      message ?? `${field} must be one non-empty path segment (not '.', '..', '/' or '\\')`,
      { field },
    )
  }
}

/**
 * True when `url` parses as an absolute http(s) URL. The package's single
 * scheme allowlist — used for webhook delivery urls and for the url `imageUrl`
 * hands back to a caller for markup.
 *
 * @internal Held back over a NAME COLLISION, not a doubt about the function.
 * `web/lib/sheets.ts` already exports its own `isHttpUrl`, and it is a
 * different rule: it is the TypeScript twin of the server's sheet-url regexp,
 * not a URL-parser scheme check, and the two disagree on real inputs.
 * Publishing this one under the same name would put two differently-contracted
 * `isHttpUrl`s in reach of one import statement — the shape that produces a
 * WRONG fix rather than a duplicated one. If a consumer needs it, export it
 * under an unambiguous name (`isHttpOrHttpsUrl`) rather than this one.
 */
export function isHttpUrl(url: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }
  return parsed.protocol === 'http:' || parsed.protocol === 'https:'
}

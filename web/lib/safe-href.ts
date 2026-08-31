/**
 * `safeHref` — scheme allow-list for CMS-authored links spliced into the
 * PortableDoc reader. React does NOT sanitize href schemes, so a paper
 * authored as `[x](javascript:…)` or a `data:text/html` URL would otherwise
 * render a clickable script/navigation payload. This is defense-in-depth the
 * renderer owns: coerce, then permit only http/https/mailto/tel absolute URLs
 * and a small set of scheme-less relative forms; everything else (including
 * protocol-relative `//host` and its backslash form `/\host`, which browsers
 * normalize to `//host`) is dropped.
 *
 * ASCII tab / LF / CR are removed from the WHOLE string first, not just its
 * head: the WHATWG URL parser deletes exactly those three bytes — anywhere —
 * before it parses, so `/<TAB>/host` is the protocol-relative `//host` by the
 * time a browser sees it. A leading-only strip followed by a position-1 test
 * looks right and lets that straight through. The cleaned string is what is
 * returned, so the value that was CHECKED is the value that RESOLVES.
 *
 * `tel:` is permitted for parity with the Elixir
 * (`api/lib/barkpark/portable_doc/render/util.ex` `safe_url`) and Go
 * (`internal/pdrender/inline.go` `sanitizeURL`) sibling renderers.
 *
 * Pure and unit-tested via the node --test lib harness.
 */

const SCHEME = /^[a-z][a-z0-9+.-]*:/i;
const SAFE_SCHEMES = new Set(["http:", "https:", "mailto:", "tel:"]);

/** The three bytes the WHATWG URL parser deletes from a URL, anywhere in it,
 * before parsing — measured across 0x00-0x20, only these collapse. Twin of
 * `URL_STRIPPED` in `js/packages/react/src/inline.tsx`. */
const URL_STRIPPED = /[\t\n\r]/g;

export function safeHref(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.replace(URL_STRIPPED, "").trim();
  if (!trimmed) return undefined;

  const match = trimmed.match(SCHEME);
  if (match) {
    // Absolute URL with a leading scheme — allow only the vetted set.
    return SAFE_SCHEMES.has(match[0].toLowerCase()) ? trimmed : undefined;
  }

  // Scheme-less. Protocol-relative `//host` (and the browser-normalized
  // backslash form `/\host`) is unsafe (inherits page scheme, navigates off-site).
  if (/^\/[/\\]/.test(trimmed)) return undefined;

  // Permit in-document / relative / query forms.
  if (/^(#|\/|\.\/|\.\.\/|\?)/.test(trimmed)) return trimmed;

  return undefined;
}

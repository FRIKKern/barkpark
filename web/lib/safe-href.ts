/**
 * `safeHref` — scheme allow-list for CMS-authored links spliced into the
 * PortableDoc reader. React does NOT sanitize href schemes, so a paper
 * authored as `[x](javascript:…)` or a `data:text/html` URL would otherwise
 * render a clickable script/navigation payload. This is defense-in-depth the
 * renderer owns: coerce, then permit only http/https/mailto absolute URLs and
 * a small set of scheme-less relative forms; everything else (including
 * protocol-relative `//host`) is dropped.
 *
 * Pure and unit-tested via the node --test lib harness.
 */

const SCHEME = /^[a-z][a-z0-9+.-]*:/i;
const SAFE_SCHEMES = new Set(["http:", "https:", "mailto:"]);

export function safeHref(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  if (!trimmed) return undefined;

  const match = trimmed.match(SCHEME);
  if (match) {
    // Absolute URL with a leading scheme — allow only the vetted set.
    return SAFE_SCHEMES.has(match[0].toLowerCase()) ? trimmed : undefined;
  }

  // Scheme-less. Protocol-relative `//host` is unsafe (inherits page scheme).
  if (trimmed.startsWith("//")) return undefined;

  // Permit in-document / relative / query forms.
  if (/^(#|\/|\.\/|\.\.\/|\?)/.test(trimmed)) return trimmed;

  return undefined;
}

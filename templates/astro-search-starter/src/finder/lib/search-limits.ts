/**
 * THE search working-set cap — one declaration per tree, every transport
 * imports it.
 *
 * THE DEFECT THIS RETIRES. `MAX_HITS = 100` was declared SIX times across
 * three trees (web/lib/find-search.ts, web/lib/use-live-search.ts, this
 * template's find-search.ts + use-live-search.ts, the Astro island and the
 * Astro vendored hook) with no shared export and no guard. Two transports
 * carry the number to the server — the HTTP leg sends `limit: String(MAX_HITS)`
 * and the WebSocket leg pushes `limit: MAX_HITS` — and web/lib/result-window.ts
 * reasons in prose ABOUT it ("the engine caps what it hands back at a WORKING
 * SET (`MAX_HITS`, 100 rows)"). The moment one copy drifts, the honesty fix
 * that docstring describes starts silently lying on whichever transport moved,
 * which is the exact defect it was written to retire.
 *
 * WHY THIS FILE EXISTS THREE TIMES AND THAT IS STILL ONE DECLARATION. The
 * copies are gate-locked, not trusted: templates/astro-search-starter's copy is
 * byte-identity-enforced against this one by scripts/check-astro-finder-drift.sh,
 * and the web/ fork is pinned to it by web/__tests__/max-hits-lock.test.ts,
 * which DERIVES the declaration set by scanning web/, templates/ and js/ rather
 * than trusting a list, and refuses to return a verdict when its scan comes
 * back empty. A seventh declaration anywhere in those trees reds that test by
 * name.
 */

/** Cap the working set; the client facets + sorts + paginates over it. */
export const MAX_HITS = 100;

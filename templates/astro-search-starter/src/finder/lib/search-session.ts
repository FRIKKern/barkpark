/**
 * Stable per-browser search session id.
 *
 * Persisted in `localStorage["bp-search-client"]` and forwarded (via the Next
 * proxy) as the `X-BP-SEARCH-CLIENT` header so the API can count DISTINCT
 * sessions accepting a correction — the anti-gaming key that gates
 * correction → synonym auto-promotion.
 *
 * Client-only: guarded for SSR (no `window`/`localStorage`) so it can be the
 * lazy initialiser of a `useState`. Returns "" on the server; the real id lands
 * once the component hydrates and the value is read again on the client.
 */

const KEY = "bp-search-client";

export function getSearchSessionId(): string {
  if (typeof window === "undefined") return "";
  try {
    const existing = window.localStorage.getItem(KEY);
    if (existing) return existing;
    const id =
      typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
        ? crypto.randomUUID()
        : `bp-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    window.localStorage.setItem(KEY, id);
    return id;
  } catch {
    // Private mode / storage disabled — degrade to an ephemeral id so the
    // session still threads through this page load (just not persisted).
    return typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `bp-${Date.now().toString(36)}`;
  }
}

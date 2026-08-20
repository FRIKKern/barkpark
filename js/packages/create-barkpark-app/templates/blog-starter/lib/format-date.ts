/**
 * Format an ISO date string for display, guarding against `Invalid Date`.
 *
 * A truthiness-only guard (`publishedAt ? new Date(publishedAt)... : null`) still
 * lets a malformed-but-truthy value (e.g. `"not-a-date"`, `"2026-13-99"`) reach
 * `new Date(...).toLocaleDateString()`, which renders the literal string
 * `"Invalid Date"` in the UI. This helper returns `null` for both the absent and
 * the unparseable case so callers can render a fallback (or nothing) instead.
 */
export function formatDate(iso?: string): string | null {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  return d.toLocaleDateString()
}

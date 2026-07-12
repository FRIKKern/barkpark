/**
 * One shared normaliser for a paper's `tags` array — the single reader every
 * public surface (the /tags/[tag] listing, the sitemap) leans on.
 *
 * WHY THIS EXISTS. The authoring-excellence wall (charter D8–D10) upgraded tags
 * from flat strings to WEIGHTED objects `{ tag, strength, rationale }`. Every
 * doc published since that landed carries the weighted shape, but the legacy
 * corpus still carries flat strings — and a mid-migration array can hold BOTH.
 * The old per-surface helpers filtered `typeof t === "string"`, so weighted
 * papers silently vanished from `/tags/<tag>` and the sitemap (charter D18,
 * consumer sites 5–6). This normaliser tolerates every shape so no published
 * paper falls off a public surface again.
 */

/**
 * A single entry as it may appear on `content.tags`:
 *   - a flat legacy string (`"search"`), or
 *   - a weighted object (`{ tag: "search", strength: 90, rationale: "…" }`).
 * The `tag` name is the only member the read surfaces care about; `strength`
 * and `rationale` ride along for the authoring/search layers.
 */
export type PaperTag =
  | string
  | { tag?: string; strength?: number; rationale?: string };

/**
 * Normalise a `tags` array (flat strings, weighted objects, or a mix) into a
 * clean list of unique, non-empty tag NAMES, preserving first-seen order.
 *
 *   - flat string        → the string itself
 *   - weighted object    → its `tag` name
 *   - anything else       → dropped (null, numbers, `{}` with no `tag`, blanks)
 *
 * Whitespace is trimmed; empty/duplicate names are dropped. Returns `[]` for
 * `undefined`, `null`, or any non-array input, so callers never guard the shape.
 */
export function paperTags(
  tags: readonly PaperTag[] | undefined | null,
): string[] {
  if (!Array.isArray(tags)) return [];

  const seen = new Set<string>();
  const names: string[] = [];

  for (const entry of tags) {
    let name: unknown;
    if (typeof entry === "string") {
      name = entry;
    } else if (entry && typeof entry === "object") {
      name = (entry as { tag?: unknown }).tag;
    }
    if (typeof name !== "string") continue;

    const trimmed = name.trim();
    if (trimmed.length === 0 || seen.has(trimmed)) continue;

    seen.add(trimmed);
    names.push(trimmed);
  }

  return names;
}

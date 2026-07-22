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

/**
 * A tag with its authoring-weight metadata, as the strength-aware read surfaces
 * (the ranked `/tags/[tag]` listing) consume it:
 *   - `tag`       — the clean, trimmed name (always present).
 *   - `strength`  — the authored 1–100 weight, or `undefined` for a legacy flat
 *                   string (which carries no strength).
 *   - `rationale` — the authored calibration note, or `undefined` when absent.
 */
export interface PaperTagEntry {
  tag: string;
  strength?: number;
  rationale?: string;
}

/**
 * Normalise a `tags` array (flat strings, weighted objects, or a mix) into a
 * clean list of {@link PaperTagEntry} — the dual-shape sibling of {@link paperTags}
 * that PRESERVES each entry's `strength` + `rationale` instead of flattening to
 * names. Same tolerance guarantees: trims names, drops blanks / duplicates
 * (first-seen wins) / non-string names, and returns `[]` for any non-array input.
 *
 *   - flat string     → `{ tag }`                  (no strength, no rationale)
 *   - weighted object → `{ tag, strength?, rationale? }`
 *
 * A weighted object's `strength` survives only when it's a finite number; its
 * `rationale` only when it's a non-empty string. Everything else is dropped so a
 * malformed row degrades to a bare name rather than surfacing junk metadata.
 */
export function paperTagEntries(
  tags: readonly PaperTag[] | undefined | null,
): PaperTagEntry[] {
  if (!Array.isArray(tags)) return [];

  const seen = new Set<string>();
  const entries: PaperTagEntry[] = [];

  for (const raw of tags) {
    let name: unknown;
    let strength: unknown;
    let rationale: unknown;
    if (typeof raw === "string") {
      name = raw;
    } else if (raw && typeof raw === "object") {
      const obj = raw as {
        tag?: unknown;
        strength?: unknown;
        rationale?: unknown;
      };
      name = obj.tag;
      strength = obj.strength;
      rationale = obj.rationale;
    }
    if (typeof name !== "string") continue;

    const trimmed = name.trim();
    if (trimmed.length === 0 || seen.has(trimmed)) continue;
    seen.add(trimmed);

    const entry: PaperTagEntry = { tag: trimmed };
    if (typeof strength === "number" && Number.isFinite(strength)) {
      entry.strength = strength;
    }
    if (typeof rationale === "string" && rationale.trim().length > 0) {
      entry.rationale = rationale.trim();
    }
    entries.push(entry);
  }

  return entries;
}

/**
 * The authored strength of tag `name` on a `tags` array, or `undefined` when the
 * tag isn't present OR is present only as a legacy flat string (no weight). Names
 * are compared trimmed, matching {@link paperTagEntries}. `undefined` is the
 * signal the ranked listing sorts LAST — an unweighted match still ranks, just
 * below every weighted one.
 */
export function tagStrength(
  tags: readonly PaperTag[] | undefined | null,
  name: string,
): number | undefined {
  const target = name.trim();
  if (target.length === 0) return undefined;
  for (const entry of paperTagEntries(tags)) {
    if (entry.tag === target) return entry.strength;
  }
  return undefined;
}

/**
 * Stable-sort papers by their matched-tag strength DESCENDING, with
 * unknown-strength papers (legacy flat matches, or the tag absent) LAST. Pure and
 * non-mutating: returns a new array, leaves the input untouched.
 *
 * The incoming order is the caller's tiebreak — the listing passes papers already
 * ordered `_updatedAt:desc`, so equal-strength papers stay newest-first. A weighted
 * paper (any strength) always outranks an unweighted match; among weighted papers,
 * higher strength wins. This is the reader payoff for the authored weights: the
 * strongest topical match leads the page.
 */
export function sortPapersByTagStrength<
  T extends { tags?: readonly PaperTag[] | null },
>(papers: readonly T[], tag: string): T[] {
  // rank: weighted → its strength; unweighted/absent → -Infinity (sorts last).
  const rank = (paper: T): number => {
    const s = tagStrength(paper.tags, tag);
    return s === undefined ? Number.NEGATIVE_INFINITY : s;
  };
  // Array.prototype.sort is stable (Node ≥ 12 / V8), so equal ranks preserve the
  // caller's incoming order — no explicit index tiebreak needed.
  return [...papers].sort((a, b) => rank(b) - rank(a));
}

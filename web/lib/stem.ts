/**
 * Conservative, token-level morphological normalizer for MATCH COMPARISON.
 *
 * Folds the obvious inflections — possessives and simple plurals — so that
 * "operators", "operator's", and "operator" compare equal, WITHOUT the
 * over-stemming that makes "operations" collapse into the same bucket
 * (Postgres' Snowball stems all three to `oper`; we deliberately don't, so the
 * displayed match-strength never over-claims relative to the engine's ranking).
 *
 * It is intentionally LESS aggressive than a Porter/Snowball stemmer:
 *   - it only strips possessive `'s` and conservative plural endings,
 *   - it keeps `-ss` / vowel+`s` words (class, bus, gas, analysis) intact,
 *   - it leaves a short blocklist of common non-plural `-s` words alone (news…).
 *
 * Used by every client matcher + the highlighter so they all agree.
 */

// Common words ending in -s that are NOT plurals (the guards below miss a few).
const NON_PLURAL = new Set([
  "news",
  "lens",
  "series",
  "species",
  "ours",
  "yours",
  "its",
  "this",
  "perhaps",
  "always",
  "across",
]);

/** Normalize one token to its conservative stem. Pure, idempotent-ish. */
export function stemToken(raw: string): string {
  // Lowercase + fold curly apostrophes to straight.
  let t = raw.toLowerCase().replace(/[‘’]/g, "'");
  // Possessive: operator's -> operator, devs' -> devs.
  t = t.replace(/'s?$/, "");
  if (t.length < 4 || NON_PLURAL.has(t)) return t;
  // companies -> company, libraries -> library (consonant + ies).
  if (/[bcdfghjklmnpqrstvwxyz]ies$/.test(t)) return t.slice(0, -3) + "y";
  // boxes -> box, classes -> class, watches -> watch, dishes -> dish (sibilant + es).
  if (/(s|x|z|ch|sh)es$/.test(t)) return t.slice(0, -2);
  // Keep -ss (class, process) and vowel+s (bus, gas, virus, analysis, basis) — those
  // are usually singular or already a stem; folding them is the foot-gun.
  if (/ss$/.test(t) || /[aeiou]s$/.test(t)) return t;
  // Simple plural: operators -> operator, docs -> doc, cats -> cat.
  if (/s$/.test(t)) return t.slice(0, -1);
  return t;
}

/** Stems of the query terms (deduped, non-empty). */
export function queryStems(terms: string[]): Set<string> {
  const out = new Set<string>();
  for (const term of terms) {
    const s = stemToken(term);
    if (s) out.add(s);
  }
  return out;
}

const WORD_RE = /[A-Za-z0-9_'’]+/g;

/** Stems of every word in a block of text (for membership tests). */
export function textStems(text: string): Set<string> {
  const out = new Set<string>();
  const words = text.match(WORD_RE);
  if (words) for (const w of words) out.add(stemToken(w));
  return out;
}

/**
 * Does a query `term` match `text`? True when it appears as a substring
 * (preserves exact/prefix/partial behavior) OR its stem matches one of the
 * text's word-stems (the morphological case: operators ↔ operator's). Pass the
 * precomputed lowercased text + its stem set to avoid recomputing per term.
 */
export function termMatches(
  term: string,
  lowerText: string,
  stems: Set<string>,
): boolean {
  const t = term.toLowerCase();
  if (t.length < 2) return false;
  if (lowerText.includes(t)) return true;
  return stems.has(stemToken(t));
}

/** Is a single `word` one we should highlight, given the query terms/stems? */
export function wordMatchesQuery(
  word: string,
  lowerTerms: string[],
  stems: Set<string>,
): boolean {
  if (stems.has(stemToken(word))) return true;
  const w = word.toLowerCase();
  return lowerTerms.some((t) => t.length >= 2 && w.includes(t));
}

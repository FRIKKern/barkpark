import type { FindHit, ParsedQuery, PopularQuery } from "@/lib/find";

/**
 * Client-side "Did you mean …?" — a spelling suggestion derived from signals the
 * finder already has, so it works identically for BOTH engines (Indx's native
 * fuzzy match and Postgres's typo_widen recovery both return docs that contain
 * the *correct* term).
 *
 * The trick: if the typed term does NOT appear verbatim in the results but a
 * near-identical word DOES (in a result title/excerpt) or is a popular
 * successful query, the typed term is almost certainly a misspelling of it.
 * Levenshtein ≤2 over a small candidate set is plenty for one-token typos.
 *
 * Deliberately conservative: single-token queries only, length ≥ 4, and never
 * suggest when the term already appears in the results (a real, found term).
 */

const MIN_LEN = 4;

/** Levenshtein edit distance (iterative two-row DP). */
function editDistance(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  if (m === 0) return n;
  if (n === 0) return m;
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  let curr = new Array<number>(n + 1);
  for (let i = 1; i <= m; i++) {
    curr[0] = i;
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    [prev, curr] = [curr, prev];
  }
  return prev[n];
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Split free text into lowercased word tokens (letters/digits/hyphen). */
function words(text: string): string[] {
  return text.toLowerCase().split(/[^a-z0-9-]+/).filter(Boolean);
}

export interface SuggestArgs {
  query: string;
  parsed: ParsedQuery | null;
  hits: FindHit[];
  popular: PopularQuery[];
  /** Extra vocabulary (e.g. words from the browse seed's titles/excerpts) so a
   * correction can be found even when the typed term returned no/odd results. */
  corpus?: string[];
}

/**
 * Returns the suggested corrected query, or null when there's nothing
 * confident to suggest.
 */
export function suggestCorrection({
  query,
  parsed,
  hits,
  popular,
  corpus = [],
}: SuggestArgs): string | null {
  const raw = query.trim();
  if (raw.length < MIN_LEN) return null;

  // One meaningful token only — multi-word queries get noisy fast, and the
  // common typo case ("hadless", "phoenex") is a single word.
  const terms = (parsed?.terms ?? []).filter((t) => t.length >= MIN_LEN);
  const term = (terms.length === 1 ? terms[0] : raw).toLowerCase();
  if (terms.length > 1 || term.length < MIN_LEN || /\s/.test(term)) return null;

  // The typed term IS in the results → it's a real word, not a typo. Bail.
  const resultText = hits
    .map((h) => `${h.title} ${h.excerpt ?? ""}`)
    .join(" ")
    .toLowerCase();
  if (new RegExp(`\\b${escapeRegExp(term)}\\b`).test(resultText)) return null;

  // Candidate corrections, weighted: popular successful queries rank above
  // incidental words pulled from the result titles/excerpts.
  const candidates = new Map<string, number>();
  const consider = (w: string, weight: number) => {
    const k = w.toLowerCase();
    if (k.length >= MIN_LEN && /^[a-z][a-z0-9-]*$/.test(k)) {
      candidates.set(k, Math.max(candidates.get(k) ?? 0, weight));
    }
  };
  for (const p of popular) {
    if (p.query && !/\s/.test(p.query)) {
      consider(p.query, 1000 + (p.resultCount ?? p.count ?? 0));
    }
  }
  for (const h of hits) {
    for (const w of words(`${h.title} ${h.excerpt ?? ""}`)) consider(w, 1);
  }
  for (const w of corpus) consider(w, 1);

  // Tighter distance budget for short words (fewer false flips).
  const maxDist = term.length <= 5 ? 1 : 2;
  let best: string | null = null;
  let bestDist = Infinity;
  let bestScore = -1;
  for (const [cand, score] of candidates) {
    if (cand === term) continue;
    const d = editDistance(term, cand);
    if (d >= 1 && d <= maxDist) {
      if (d < bestDist || (d === bestDist && score > bestScore)) {
        best = cand;
        bestDist = d;
        bestScore = score;
      }
    }
  }
  if (!best) return null;

  // Rebuild the query with the corrected token (preserves surrounding text for
  // the rare multi-token case that slips through, though we gate to one token).
  return raw.toLowerCase() === term
    ? best
    : raw.replace(new RegExp(escapeRegExp(term), "i"), best);
}

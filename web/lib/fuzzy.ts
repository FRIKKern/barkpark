/**
 * Search-highlight match analysis — turns a snippet of text + the query terms
 * into ready-to-render segments, each tinted by how well (and how honestly) the
 * word answers the query.
 *
 * The governing idea: the colour is an HONEST readout of how the engine
 * understood you. A word you typed VERBATIM (exact, a real prefix, a substring,
 * or a grammatical inflection) was understood as-is → GREEN. A word we only
 * understood after CORRECTING your typing (a misspelling) → YELLOW→RED, graded
 * by how much correction it took. Three non-colliding channels carry it:
 *
 *   • background hue   — quality, green→red (the primary, colourful signal),
 *   • underline style  — solid / dashed / dotted (a NON-colour echo, so the
 *                        whole red→green scale survives red-green colour-blindness),
 *   • faded letters    — within a corrected word, the inferred/changed letters
 *                        are ghosted, so you can see exactly what we translated.
 *
 * The scorer leans on well-known techniques expressed as continuous factors:
 * subsequence + (keyboard- and phonetic-aware) Damerau-Levenshtein for the
 * lexical score, an LCS alignment for the letter-level diff, and a phrase /
 * stop-word pass for whole-query coherence. Pure + dependency-free; shares
 * {@link stemToken} with the other client matchers.
 */
import { stemToken } from "./stem";

/** Below this a word is left un-highlighted, and the bottom of the colour ramp. */
export const MIN_SCORE = 0.4;
const MIN_FUZZY_LEN = 3; // gappy / edit paths need this much term to be safe
const MAX_EDITS = 2; // a real typo is a few edits, not a coincidence

// Two honest axes. CORRECTNESS (kind → underline style): a word typed verbatim
// vs a misspelling we corrected. CONFIDENCE (score → colour): how sure we are
// it's the word you meant — driven by coverage for verbatim matches and by edit
// severity for corrections. Corrections are graded into [CORRECT_MIN, CORRECT_MAX]
// and never reach green; a verbatim match's colour rides on coverage, so even a
// spelled-right short prefix ("sec"→"section") stays amber until it covers more.
const CORRECT_MIN = 0.45;
const CORRECT_MAX = 0.72;
const RAW_LO = 0.5; // plausible range of a raw correction quality, used to
const RAW_HI = 0.95; // spread corrections across the whole yellow→red band

/** Search stop words — almost never worth lighting up on their own. */
const STOP_WORDS = new Set([
  "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with",
  "is", "are", "was", "were", "be", "by", "at", "as", "it", "this", "that",
  "from", "but", "not", "no", "we", "you", "your",
]);

const fold = (s: string) => s.toLowerCase().replace(/[‘’]/g, "'");
const clamp01 = (n: number) => (n < 0 ? 0 : n > 1 ? 1 : n);
const clamp = (n: number, lo: number, hi: number) => (n < lo ? lo : n > hi ? hi : n);
const lengthSim = (a: number, b: number) => 1 - Math.abs(a - b) / Math.max(a, b);

const VOWELS = new Set(["a", "e", "i", "o", "u"]);
/** Undo a doubled final consonant ("runn" → "run") left by suffix stripping. */
function deDouble(s: string): string {
  const n = s.length;
  return n > 2 && s[n - 1] === s[n - 2] && !VOWELS.has(s[n - 1]) ? s.slice(0, -1) : s;
}
/**
 * Light INFLECTIONAL stem on top of the shared plural/possessive {@link stemToken}:
 * also folds the verb endings -ing / -ed, so "publish", "publishing", and
 * "published" all compare equal — which is what the engine's Snowball stemmer
 * does, and why those docs matched. Deliberately does NOT strip derivational
 * suffixes (-or, -ion, -er): "operator" and "operation" must stay distinct, so
 * the highlight never over-claims a relationship the words don't have.
 */
function morphStem(raw: string): string {
  const w = fold(raw);
  if (w.length > 5 && w.endsWith("ing")) return deDouble(w.slice(0, -3));
  if (w.length > 4 && w.endsWith("ed")) return deDouble(w.slice(0, -2));
  return stemToken(w);
}

/** Plain unit-cost Levenshtein — used to measure how far apart two surface forms
 * of the same root are ("publishing" ↔ "publish" = 3), which grades inflection
 * confidence. (Distinct from the keyboard-weighted typo distance below.) */
function levenshtein(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  if (!m) return n;
  if (!n) return m;
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

/* ── human typo model: keyboard adjacency + a mini-phonetic key ───────────── */

/** QWERTY neighbour map — a substitution between adjacent keys is a far likelier
 * slip than a random one, so it costs less below. Built once from the rows. */
const KEY_NEIGHBORS: Map<string, Set<string>> = (() => {
  const rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"];
  const at = (r: number, c: number) => (rows[r] ? rows[r][c] : undefined);
  const m = new Map<string, Set<string>>();
  for (let r = 0; r < rows.length; r++) {
    for (let c = 0; c < rows[r].length; c++) {
      const k = rows[r][c];
      const set = m.get(k) ?? new Set<string>();
      for (const [rr, cc] of [
        [r, c - 1], [r, c + 1],
        [r - 1, c - 1], [r - 1, c],
        [r + 1, c], [r + 1, c + 1],
      ]) {
        const n = at(rr, cc);
        if (n) set.add(n);
      }
      m.set(k, set);
    }
  }
  return m;
})();

const keyAdjacent = (a: string, b: string) => KEY_NEIGHBORS.get(a)?.has(b) ?? false;
/** Substitution cost: discounted for an adjacent-key slip, full for a random
 * swap. The discount floor (0.67) is deliberate: 3 × 0.67 = 2.01 > MAX_EDITS, so
 * three cheap edits can never sneak past the 2-edit admission gate, while any
 * genuine 2-edit path (≤ 2.0) still passes. */
const CHEAP_EDIT = 0.67;
const subCost = (a: string, b: string) => (a === b ? 0 : keyAdjacent(a, b) ? CHEAP_EDIT : 1);

/** A light, Metaphone-flavoured sound key: folds the common digraphs (ph→f,
 * gh→∅, ck→k, qu→kw), collapses vowel runs, de-doubles, and drops a trailing
 * vowel — enough to catch "fone"≈"phone", "nite"≈"night", "thru"≈"through". */
function phoneticKey(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z]/g, "")
    .replace(/ph/g, "f")
    .replace(/gh/g, "")
    .replace(/ck/g, "k")
    .replace(/qu/g, "kw")
    .replace(/[aeiou]+/g, "a")
    .replace(/(.)\1+/g, "$1")
    .replace(/a$/, "");
}

/* ── lexical similarity ───────────────────────────────────────────────────── */

/**
 * Bounded, keyboard-aware Damerau-Levenshtein similarity in [0,1]. Adjacent
 * transpositions and adjacent-key substitutions are cheap; strict admission
 * (≤ {@link MAX_EDITS} effective edits, ≥0.55 similarity) keeps unrelated words
 * that merely share letters out of the corrected band.
 */
function damerauSimilarity(a: string, b: string): number {
  const al = a.length;
  const bl = b.length;
  if (!al || !bl) return 0;
  const maxLen = Math.max(al, bl);
  if (maxLen < MIN_FUZZY_LEN) return a === b ? 1 : 0;
  if (Math.abs(al - bl) > MAX_EDITS) return 0;

  let prevPrev = new Array<number>(bl + 1).fill(0);
  let prev = new Array<number>(bl + 1);
  let curr = new Array<number>(bl + 1);
  for (let j = 0; j <= bl; j++) prev[j] = j;
  for (let i = 1; i <= al; i++) {
    curr[0] = i;
    for (let j = 1; j <= bl; j++) {
      let v = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + subCost(a[i - 1], b[j - 1]));
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        // A transposition ("teh"→"the") is the commonest human typo — cost it
        // below a full substitution, but ≥ CHEAP_EDIT so the gate still holds.
        v = Math.min(v, prevPrev[j - 2] + CHEAP_EDIT);
      }
      curr[j] = v;
    }
    [prevPrev, prev, curr] = [prev, curr, prevPrev];
  }
  const dist = prev[bl];
  if (dist > MAX_EDITS) return 0;
  const sim = 1 - dist / maxLen;
  return sim >= 0.55 ? sim : 0;
}

/**
 * Verbatim substring/prefix score — the letters were typed exactly, so this is
 * always a SOLID-underline (no-correction) match. The COLOUR, though, is driven
 * by COVERAGE on a deliberately STEEP curve, so every letter you add visibly
 * shifts the hue toward green: "stud"→"studio" reads yellow, "studi" yellow-
 * green, "studio" green. A short fragment ("sec"→"section") sits in amber — it's
 * spelled right but ambiguous (sec/section/sector/secure), so low confidence.
 * Confidence and correctness are separate axes; this is the confidence one.
 */
function verbatimScore(term: string, word: string): number {
  const coverage = term.length / word.length;
  const start = word.indexOf(term);
  const head = start === 0 ? 0.03 : 0;
  const posPenalty = (start / word.length) * 0.04;
  // coverage^1.6 spreads partial prefixes across the whole amber→green ramp
  // instead of bunching them all up near green.
  return clamp(0.4 + 0.57 * Math.pow(coverage, 1.6) + head - posPenalty, MIN_SCORE, 0.97);
}

/** Raw correction quality from a gappy (non-contiguous) subsequence. 0 if not a
 * subsequence; uncapped — the caller grades it into the yellow→red band. */
function gappySubsequenceQuality(term: string, word: string): number {
  if (term.length < MIN_FUZZY_LEN || word.length < term.length) return 0;
  let w = 0;
  let first = -1;
  let last = -1;
  let adjacent = 0;
  for (let t = 0; t < term.length; t++) {
    let found = -1;
    for (; w < word.length; w++) {
      if (word[w] === term[t]) { found = w; w++; break; }
    }
    if (found === -1) return 0;
    if (first === -1) first = found;
    if (last !== -1 && found === last + 1) adjacent++;
    last = found;
  }
  const contiguity = term.length > 1 ? adjacent / (term.length - 1) : 1;
  const coverage = term.length / word.length;
  const span = last - first + 1;
  const compactness = span > 0 ? term.length / span : 1;
  return clamp01(0.45 + 0.26 * contiguity + 0.16 * coverage + 0.13 * compactness);
}

/** Map a raw correction quality into the yellow→red band (never green). */
function gradeCorrection(raw: number): number {
  if (raw <= 0) return 0;
  const n = clamp01((raw - RAW_LO) / (RAW_HI - RAW_LO));
  return CORRECT_MIN + (CORRECT_MAX - CORRECT_MIN) * n;
}

export type MatchKind = "exact" | "inflection" | "verbatim" | "corrected";

/** Score one query `term` against one `word`: a continuous quality plus the
 * KIND of match (so the renderer knows whether to ghost any letters). */
function matchTerm(term: string, word: string): { score: number; kind: MatchKind } {
  const t = fold(term);
  const w = fold(word);
  if (t.length < 2 || w.length < 2) return { score: 0, kind: "corrected" };
  if (t === w) return { score: 1, kind: "exact" };
  if (morphStem(t) === morphStem(w)) {
    // Same root, different surface form. Grade confidence by how far apart the
    // two forms are: "operators"→"operator" is 1 step (strong), "publishing"→
    // "publish" is 3 (weaker). Both spelled right, so it stays a SOLID-underline
    // match — the colour, not the underline, carries the morphological distance.
    const d = levenshtein(t, w);
    return { score: clamp(0.9 - 0.1 * (d - 1), 0.5, 0.9), kind: "inflection" };
  }
  // Verbatim substring/prefix → green. But a STOP WORD must match as a whole
  // word only — never as a coincidental fragment buried mid-word ("the" inside
  // "o[the]r"), which would falsely read as a verbatim/green understanding.
  if (w.includes(t) && !(STOP_WORDS.has(t) && t.length < w.length)) {
    return { score: verbatimScore(t, w), kind: "verbatim" };
  }
  if (t.length < MIN_FUZZY_LEN) return { score: 0, kind: "corrected" };

  // Correction: best of dropped-letter (subsequence), mistyped-letter (edit
  // distance), and sounds-alike (phonetic).
  let raw = Math.max(gappySubsequenceQuality(t, w), damerauSimilarity(t, w));
  let phonetic = false;
  if (raw === 0 && lengthSim(t.length, w.length) >= 0.5) {
    const pk = phoneticKey(t);
    if (pk.length >= 2 && pk === phoneticKey(w)) { raw = 0.66; phonetic = true; } // sounds the same
  }
  // First-letter agreement is a fat-finger signal — but a phonetic hit's first
  // letters legitimately differ (ph/f, qu/kw), so don't penalise it for that.
  if (raw > 0 && !phonetic) raw = clamp01(raw + (t[0] === w[0] ? 0.04 : -0.06));
  return { score: gradeCorrection(raw), kind: "corrected" };
}

/** Indices in `word` that were INFERRED to make a correction fit — the gaps /
 * substitutions, via an LCS alignment. Empty for verbatim/exact matches, and
 * skipped when the alignment is too thin to be meaningful. */
function inferredIndices(term: string, word: string): number[] {
  const t = fold(term);
  const w = fold(word);
  const n = t.length;
  const m = w.length;
  // LCS DP over (term, word), then backtrace the matched WORD indices.
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = 1; i <= n; i++) {
    for (let j = 1; j <= m; j++) {
      dp[i][j] = t[i - 1] === w[j - 1] ? dp[i - 1][j - 1] + 1 : Math.max(dp[i - 1][j], dp[i][j - 1]);
    }
  }
  const matched = new Set<number>();
  let i = n;
  let j = m;
  while (i > 0 && j > 0) {
    if (t[i - 1] === w[j - 1]) { matched.add(j - 1); i--; j--; }
    else if (dp[i - 1][j] >= dp[i][j - 1]) i--;
    else j--;
  }
  if (matched.size < Math.ceil(n / 2)) return []; // too little aligned to trust
  // Every word letter we did NOT align to a typed letter was inferred — gaps in
  // the middle AND leading/trailing insertions (the "ph" we added to make "fone"
  // → "phone"). The size guard above keeps thin alignments from over-ghosting.
  const inferred: number[] = [];
  for (let k = 0; k < m; k++) if (!matched.has(k)) inferred.push(k);
  return inferred;
}

/* ── colour + label, derived continuously from the score ─────────────────── */

const normalize = (score: number) => clamp01((score - MIN_SCORE) / (1 - MIN_SCORE));

/** Highlight background (light/dark) for a score. To maximise the number of
 * PERCEPTIBLE steps, three channels move together across the visible band: hue
 * sweeps red→emerald, saturation climbs muted→vivid, and lightness deepens a
 * touch — so a weak match reads as a greyish red and a strong one as a vivid
 * deep green, with every gradation clearly its own colour. Returns null below
 * the floor. Lightness stays in a contrast-safe window for the inherited text. */
export function highlightColors(score: number): { light: string; dark: string } | null {
  if (score < MIN_SCORE) return null;
  const t = normalize(score); // 0 (worst real match) → 1 (exact)
  // All four perceptual levers swing hard and together so the most steps are
  // distinguishable: hue red→emerald, saturation washed→vivid, lightness
  // pale→deep. A weak match is a faint pink, a strong one a saturated deep
  // green, with many clearly-separate stages between. Lightness stays in a
  // dark-text-safe window in light mode (≥ 71%) and a light-text-safe one in
  // dark mode.
  const hue = Math.round(t * 162); // 0 red → 162 emerald
  const sat = Math.round(45 + t * 50); // 45% washed → 95% vivid
  const lightL = Math.round(89 - t * 18); // 89% pale → 71% deep
  const darkL = Math.round(38 + t * 16); // 38% → 54%
  return {
    light: `hsl(${hue} ${sat}% ${lightL}% / 0.92)`,
    dark: `hsl(${hue} ${Math.round(sat * 0.8)}% ${darkL}% / 0.46)`,
  };
}

/** Underline STYLE = the non-colour CORRECTNESS axis: anything typed verbatim
 * (exact / inflection / prefix / substring — even a partial one) is SOLID; a
 * misspelling we had to correct is dashed (close) or dotted (loose). Independent
 * of the colour, which carries confidence. */
function underlineStyle(kind: MatchKind, score: number): "solid" | "dashed" | "dotted" {
  if (kind !== "corrected") return "solid";
  return score >= 0.58 ? "dashed" : "dotted";
}

/** Granular, non-colour quality word for the tooltip / screen reader — names
 * BOTH axes: whether we corrected the spelling (kind) and how confident we are
 * (score). A spelled-right-but-short prefix is a "Partial match", not a
 * "Corrected" one. */
export function qualityLabel(kind: MatchKind, score: number): string {
  if (kind === "exact") return "Exact match";
  if (kind === "inflection") {
    if (score >= 0.85) return "Strong match"; // 1 step (plural/possessive)
    if (score >= 0.72) return "Solid match";
    return "Related form"; // a few steps away (publishing → publish)
  }
  if (kind === "verbatim") {
    if (score >= 0.86) return "Strong match";
    if (score >= 0.75) return "Solid match";
    return "Partial match"; // spelled right, but only part of the word
  }
  if (score >= 0.64) return "Corrected — close";
  if (score >= 0.54) return "Corrected — fuzzy";
  return "Corrected — loose";
}

/* ── public API: text → render segments ──────────────────────────────────── */

/** One run inside a highlighted word — `inferred` letters are ghosted. */
export interface HlRun {
  text: string;
  inferred: boolean;
}

/** A render segment: either plain text or a highlighted word with its styling. */
export interface HlSegment {
  text: string;
  match: boolean;
  runs?: HlRun[];
  light?: string;
  dark?: string;
  underline?: "solid" | "dashed" | "dotted";
  label?: string;
  score?: number;
}

interface WordHit {
  score: number;
  kind: MatchKind;
  termPos: number; // position of the winning term in the query (for adjacency)
  term: string;
}

const WORD_SPLIT = /([A-Za-z0-9_'’]+)/;
const isWord = (s: string) => /[A-Za-z0-9_'’]/.test(s);

/** Best matching query term for a word, with the query position of that term. */
function analyzeWord(word: string, lowerTerms: string[]): WordHit | null {
  let best: WordHit | null = null;
  for (let p = 0; p < lowerTerms.length; p++) {
    const { score, kind } = matchTerm(lowerTerms[p], word);
    if (!best || score > best.score) best = { score, kind, termPos: p, term: lowerTerms[p] };
  }
  return best && best.score > 0 ? best : null;
}

/**
 * Analyze `text` against the query `terms` and return render-ready segments.
 * Applies whole-query coherence on top of the per-word scores: stop words are
 * dropped unless they're part of a contiguous in-order phrase, and adjacent
 * in-order matches get a small boost (kept inside their spelling band, so a
 * corrected word still never turns green). Terms arrive pre-lowercased.
 */
export function highlightSegments(text: string, terms: string[]): HlSegment[] {
  const lowerTerms = terms.filter(Boolean).map((t) => t.toLowerCase());
  if (!lowerTerms.length) return [{ text, match: false }];

  const tokens = text.split(WORD_SPLIT);
  // First pass: score each word token; remember token index for the phrase pass.
  const hits: (WordHit | null)[] = tokens.map((tok) => (isWord(tok) ? analyzeWord(tok, lowerTerms) : null));

  // Phrase + stop-word pass over the WORD tokens in reading order.
  const wordTokenIdx = tokens.map((t, i) => (isWord(t) ? i : -1)).filter((i) => i >= 0);
  for (let k = 0; k < wordTokenIdx.length; k++) {
    const here = hits[wordTokenIdx[k]];
    if (!here) continue;
    const prev = k > 0 ? hits[wordTokenIdx[k - 1]] : null;
    const next = k < wordTokenIdx.length - 1 ? hits[wordTokenIdx[k + 1]] : null;
    const adjPrev = prev && prev.termPos === here.termPos - 1;
    const adjNext = next && next.termPos === here.termPos + 1;
    const inPhrase = Boolean(adjPrev || adjNext);

    // Stop words: a non-exact stop-word match (substring / correction) is never
    // trustworthy — drop it regardless of any phrase, so phrase-adjacency can't
    // protect a coincidental fragment. An exact stop word survives only when it
    // anchors a contiguous in-order phrase.
    if (STOP_WORDS.has(here.term) && here.kind !== "exact") {
      hits[wordTokenIdx[k]] = null;
      continue;
    }
    if (STOP_WORDS.has(here.term) && !inPhrase) {
      hits[wordTokenIdx[k]] = null;
      continue;
    }
  }

  // Adjacency boost — reward in-order contiguous phrase matches, in a second
  // pass so a dropped hit can never be boosted. Never lifts a correction into
  // the green (verbatim) band.
  for (let k = 0; k < wordTokenIdx.length; k++) {
    const here = hits[wordTokenIdx[k]];
    if (!here) continue;
    const prev = k > 0 ? hits[wordTokenIdx[k - 1]] : null;
    const next = k < wordTokenIdx.length - 1 ? hits[wordTokenIdx[k + 1]] : null;
    const inPhrase =
      (prev && prev.termPos === here.termPos - 1) ||
      (next && next.termPos === here.termPos + 1);
    if (inPhrase) {
      // A correction can rise within its band but never into green; a verbatim
      // match can climb toward a confident green.
      const ceil = here.kind === "corrected" ? CORRECT_MAX : 0.97;
      here.score = clamp(here.score + 0.06, 0, ceil);
    }
  }

  // Build segments.
  return tokens.map((tok, i): HlSegment => {
    const hit = hits[i];
    if (!hit || hit.score < MIN_SCORE) return { text: tok, match: false };
    const colors = highlightColors(hit.score)!;
    const inferred = hit.kind === "corrected" ? inferredIndices(hit.term, tok) : [];
    const runs: HlRun[] = inferred.length ? toRuns(tok, inferred) : [{ text: tok, inferred: false }];
    return {
      text: tok,
      match: true,
      runs,
      light: colors.light,
      dark: colors.dark,
      underline: underlineStyle(hit.kind, hit.score),
      label: qualityLabel(hit.kind, hit.score),
      score: hit.score,
    };
  });
}

/** Split a word into contiguous solid / inferred runs for letter-level render. */
function toRuns(word: string, inferred: number[]): HlRun[] {
  const flag = new Array(word.length).fill(false);
  for (const idx of inferred) if (idx >= 0 && idx < word.length) flag[idx] = true;
  const runs: HlRun[] = [];
  let cur = "";
  let curFlag = flag[0];
  for (let i = 0; i < word.length; i++) {
    if (flag[i] === curFlag) cur += word[i];
    else {
      runs.push({ text: cur, inferred: curFlag });
      cur = word[i];
      curFlag = flag[i];
    }
  }
  if (cur) runs.push({ text: cur, inferred: curFlag });
  return runs;
}

/* ── shared "is this a hit?" — keeps the strength meter + ranking in step with
 *    the highlighter on what counts as a match ───────────────────────────── */

/** Split text into words, using the same token rule as the highlighter. */
export function words(text: string): string[] {
  return text.match(/[A-Za-z0-9_'’]+/g) ?? [];
}

/**
 * Does a query `term` HIT any of these words the way the highlighter counts a
 * real match — exact, an inflectional relative ("publishing" ≈ "publish"), or a
 * verbatim substring/prefix? Excludes faint typo-corrections, so the strength
 * meter and the exact-promotion ranking agree with what actually lights up.
 */
export function termHitsWords(term: string, ws: string[]): boolean {
  const t = term.toLowerCase();
  for (const w of ws) {
    if (matchTerm(t, w).kind !== "corrected") return true; // exact / inflection / verbatim
  }
  return false;
}

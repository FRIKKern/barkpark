/**
 * Reading `/api/find?suggest=1` — the one place the finder turns that route's
 * answer into the popular-query chips, WITH the reason an empty list is empty.
 *
 * WHY THIS FILE EXISTS: it imports nothing but a type, so the reading ships and
 * is tested as ONE artifact under bare `node --test`, exactly like
 * `lib/paginate.ts`, `lib/result-window.ts`, and `lib/doc-absence.ts`.
 * `components/finder.tsx` pulls in `next/navigation` and `phoenix`, which is
 * why the rule it applies lives out here.
 *
 * ## The defect it retires
 *
 * `app/api/find/route.ts` goes to deliberate trouble to make an empty
 * suggestion list READABLE. Its own words:
 *
 *   "`error` is the field the two empty lists descend from: `null` when the
 *    upstream actually answered (the corpus really has no popular or no-hit
 *    queries yet), and the upstream's own reason when it did not. Without it,
 *    'nobody has searched yet' and 'the suggestions endpoint is down' are the
 *    same bytes."
 *
 * It has a dedicated regression test (`__tests__/find-suggestions-receipt.test.ts`)
 * holding that receipt in place. And the route has exactly ONE consumer, which
 * did this:
 *
 *   fetch("/api/find?suggest=1")
 *     .then((r) => r.json())
 *     .then((d: { popular?: PopularQuery[] }) => setPopular(…))
 *     .catch(() => {});
 *
 * The type it read the body through does not even DECLARE `error`. So the
 * receipt was computed, tested, transmitted — and then discarded one layer up,
 * making the two cases the same bytes again, which is exactly what the route
 * was written to prevent.
 *
 * The `.catch(() => {})` is worse than the drop: a network failure, a 500, or
 * an unparseable body vanished with no console line and no state change at all.
 * That is the plainest form of the class this codebase legislates against
 * everywhere else — `bp-fetch`'s structured throw, `find-event`'s `recorded`,
 * `listings`' `substituted`, `graph`'s `truncated`.
 *
 * ## What is deliberately NOT changed
 *
 * The route answers 200 on the degraded path on purpose, "so a caller reading
 * `res.ok` never sees this optional panel as a page failure". Popular chips are
 * a decoration; a missing chip row is not a user-facing outage and must not be
 * dressed as one. So this module makes the failure ATTRIBUTABLE (an operator
 * sees the cause; the caller can tell the two empties apart) without inventing
 * a user-facing error state the route's contract rules out.
 */

import type { PopularQuery } from "./find.ts";

/** How many chips the idle status row has room for. */
export const POPULAR_CHIP_LIMIT = 6;

/**
 * Most words a popular query may have to earn a chip.
 *
 * Same value as the search-starter fork's `POPULAR_CHIP_MAX_WORDS`
 * (`templates/search-starter/lib/find.ts`) — deliberately NOT a new threshold.
 * This pair already carries unpaid divergences; the chip rule is not where a
 * seventh gets added for free.
 */
export const POPULAR_CHIP_MAX_WORDS = 2;

/**
 * Longest a popular query may be (characters) to earn a chip.
 *
 * Same value as the fork's `POPULAR_CHIP_MAX_CHARS`. Two words can still be
 * long ("internationalisation checklist"), so the character bound is not
 * implied by the word bound and both are needed.
 */
export const POPULAR_CHIP_MAX_CHARS = 24;

/**
 * The finder's reading of one suggestions answer.
 *
 * `error` carries the SAME distinction the route draws: `null` means the
 * upstream answered and the corpus genuinely has no popular queries; a string
 * is the reason no answer was obtained. An empty `popular` with a null `error`
 * is a fact; an empty `popular` with a string is an absence of information.
 */
export interface SuggestionsReading {
  popular: PopularQuery[];
  error: string | null;
}

/** The shape the route answers with, as far as this reader depends on it. */
interface SuggestionsBody {
  popular?: unknown;
  error?: unknown;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** A usable chip: an object carrying a non-empty `query` string. */
function toPopular(v: unknown): PopularQuery | null {
  if (!isRecord(v)) return null;
  const query = typeof v.query === "string" ? v.query.trim() : "";
  if (query === "") return null;
  const count = typeof v.count === "number" && Number.isFinite(v.count) ? v.count : 0;
  return { query, count };
}

/**
 * Curate the raw popular-query pool down to the chips worth offering.
 *
 * THE DEFECT THIS RETIRES: this module CAPPED the pool at
 * {@link POPULAR_CHIP_LIMIT} and stopped there. `/api/find?suggest` returns the
 * query LOG verbatim, and a Barkpark instance's log is mostly machine exhaust —
 * agents probing with whole sentences ("research coverage ledger"), operator
 * syntax, one-off spelunking. A chip row is a promise ("these are the searches
 * worth trying"), so an uncapped-but-uncurated row shipped that promise over
 * telemetry: a single whole-sentence agent probe could occupy one of the six
 * visible slots, and "Deploy" and "deploy" could occupy two.
 *
 * The rule is the search-starter fork's `curatePopularQueries`, thresholds and
 * all: at most {@link POPULAR_CHIP_MAX_WORDS} words AND at most
 * {@link POPULAR_CHIP_MAX_CHARS} characters, deduped case-insensitively (the
 * log records "Deploy" and "deploy" separately), capped at
 * {@link POPULAR_CHIP_LIMIT}. Input rank order is preserved — the pool arrives
 * sorted by popularity and the chip row's order IS that ranking.
 *
 * DEGRADES TO NOTHING BY DESIGN, AND THAT IS NOT AN ERROR: a fresh dataset has
 * an empty log, and a dev-heavy one can have a log with nothing short in it.
 * Both yield `[]` — the caller renders no row rather than a row of leftovers,
 * and {@link readSuggestions} still reports `error: null`, because "everything
 * we saw was too long" is a FACT ABOUT THE CORPUS, not a failure to reach
 * upstream. Curation must never be able to turn an answered empty into an
 * unanswered one; that distinction is the reason this module exists.
 */
export function curatePopularQueries(pool: PopularQuery[]): PopularQuery[] {
  const seen = new Set<string>();
  const chips: PopularQuery[] = [];
  for (const entry of pool) {
    const query = entry.query.trim();
    if (!query || query.length > POPULAR_CHIP_MAX_CHARS) continue;
    if (query.split(/\s+/).length > POPULAR_CHIP_MAX_WORDS) continue;
    const key = query.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    chips.push({ ...entry, query });
    if (chips.length >= POPULAR_CHIP_LIMIT) break;
  }
  return chips;
}

/**
 * Read the route's answer.
 *
 * Tolerant of shape drift in the same spirit as `readQueryPage`: a body that is
 * not an object, or whose `popular` is not an array, yields no chips. But it
 * does NOT invent a reason — a body we could not read is reported as exactly
 * that, never as a null error, because "we learned nothing" and "the upstream
 * said there is nothing" are the two states this whole module exists to keep
 * apart.
 */
export function readSuggestions(json: unknown): SuggestionsReading {
  if (!isRecord(json)) {
    return {
      popular: [],
      error: "suggestions response was not an object",
    };
  }

  const body = json as SuggestionsBody;
  // NOTE THE SHAPE: `answered` is computed from `Array.isArray(body.popular)`,
  // NOT from `popular.length`. Curation can legitimately empty the list, and an
  // emptied list must keep reading as "the upstream answered" — see the receipt
  // reasoning below. Deriving the receipt from the list's length instead is the
  // one edit that would silently re-fuse the two empties.
  const answered = Array.isArray(body.popular);
  const popular = answered
    ? curatePopularQueries(
        (body.popular as unknown[])
          .map(toPopular)
          .filter((p): p is PopularQuery => p !== null),
      )
    : [];

  // The route always sends `error` (null or a string). A body without it is an
  // OLDER route or something else answering this path — either way we did not
  // get the receipt, and saying `null` would assert an upstream answer we never
  // read. Absent `popular` too? Then there is nothing to report but the silence.
  if (typeof body.error === "string" && body.error.trim() !== "") {
    return { popular, error: body.error };
  }
  if (body.error === null) return { popular, error: null };
  if (!("error" in body)) {
    return {
      popular,
      error: answered
        ? null // a readable list without a receipt: the list itself is the answer
        : "suggestions response carried neither a list nor a reason",
    };
  }
  return { popular, error: "suggestions response carried an unreadable reason" };
}

/**
 * The reading for a suggestions fetch that never produced a body — a network
 * failure, an abort, an unparseable payload. Exported so the failure path and
 * the answered path build the SAME shape, and neither can quietly become the
 * other.
 */
export function suggestionsUnreachable(err: unknown): SuggestionsReading {
  const message = err instanceof Error ? err.message : String(err);
  return { popular: [], error: `suggestions unreachable: ${message}` };
}

/**
 * The operator-facing line for a failed suggestions read, or null when there is
 * nothing to say.
 *
 * Deliberately NOT a user-facing banner: the route answers 200 on this path so
 * an optional panel never reads as a page failure, and a missing chip row is a
 * missing decoration. What must not happen is the failure leaving no trace at
 * all — which is what `.catch(() => {})` did.
 */
export function suggestionsNotice(reading: SuggestionsReading): string | null {
  if (reading.error === null) return null;
  return (
    `[finder] popular-query suggestions unavailable — ${reading.error}. ` +
    `The idle shortcut row is empty because nothing answered, NOT because the ` +
    `corpus has no popular queries; "did you mean" also loses this candidate pool.`
  );
}

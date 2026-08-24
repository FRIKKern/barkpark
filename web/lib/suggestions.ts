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
  const popular = Array.isArray(body.popular)
    ? body.popular
        .map(toPopular)
        .filter((p): p is PopularQuery => p !== null)
        .slice(0, POPULAR_CHIP_LIMIT)
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
      error: Array.isArray(body.popular)
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

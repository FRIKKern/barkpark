/**
 * The corpus-graph TRUNCATION contract for `lib/graph.ts` and the landing that
 * renders it, extracted so the shaping is testable (task-b1d01077c255c335).
 *
 * WHY THIS FILE EXISTS: `lib/graph.ts` pulls in `server-only`, `next/cache` and
 * `@/` path aliases, so `node --test` cannot load it — the same constraint that
 * produced `lib/paginate.ts`. This module deliberately imports NOTHING, so the
 * truncation law ships and is tested as ONE artifact under bare `node --test`.
 *
 * THE DEFECT IT RETIRES: `GET /v1/graph` has emitted `truncated` +
 * `truncation_reason` since the server-honesty fix
 * (`TasksController.derive_graph_corpus/2`, whose own comment calls a graph
 * that quietly ignores its ceilings "the exact dishonesty class this endpoint's
 * truncation fix kills"). `web/lib/graph.ts` declared an `UpstreamGraph` of
 * `{ nodes?, edges? }` and threw BOTH fields on the floor, so the Next.js
 * finder landing drew a capped subset of the corpus with no indication anything
 * had been dropped. Against the live `production` dataset the endpoint answers
 * `truncated: true, truncation_reason: "per_type_cap"` TODAY — this was not
 * hypothetical.
 *
 * The Phoenix `/finder` (`api/lib/barkpark_web/live/finder_live.ex`) and the
 * extracted `templates/search-starter` fork both already carry the pair; the
 * web demo they were extracted FROM is the instance nobody paid.
 *
 * THE LAW:
 *   - `truncated` is TRUE only for a literal upstream `true` — an absent field,
 *     a string, or a number never manufactures a partial-graph claim (the
 *     landing must not cry wolf on a complete corpus);
 *   - `truncationReason` is meaningful ONLY when `truncated` is true. A reason
 *     emitted WITHOUT the flag is discarded, never promoted into a claim;
 *   - every reason the server can emit gets its OWN sentence, because the
 *     ceilings differ in kind: `node_budget` cuts the tail off one flat list
 *     ("the first N" is fair), while `per_type_cap` cuts EACH TYPE at its own
 *     ceiling — copy that says "showing the first N" there names the wrong
 *     ceiling and misdescribes what the reader is looking at;
 *   - a truncation the server declares WITHOUT a reason still gets a notice
 *     that says the corpus was cut and admits the ceiling went unnamed —
 *     silence is the one thing this module exists to prevent.
 */

/** The reasons `TasksController.graph_truncation_reason/2` can emit. */
export const TRUNCATION_REASONS = [
  "per_type_cap",
  "node_budget",
  "per_type_cap+node_budget",
] as const;

export type TruncationReason = (typeof TRUNCATION_REASONS)[number];

/** The pair as the app carries it — `reason` is null unless `truncated`. */
export interface Truncation {
  truncated: boolean;
  truncationReason: string | null;
}

/** The raw upstream fields, before any of this module's law is applied. */
export interface RawTruncation {
  truncated?: unknown;
  truncation_reason?: unknown;
}

/**
 * Read the upstream pair under the law above: a literal `true` is the only
 * thing that sets the flag, and the reason only survives alongside it.
 */
export function readTruncation(raw: RawTruncation | null | undefined): Truncation {
  if (!raw || typeof raw !== "object") return { truncated: false, truncationReason: null };
  const truncated = raw.truncated === true;
  if (!truncated) return { truncated: false, truncationReason: null };
  const reason =
    typeof raw.truncation_reason === "string" && raw.truncation_reason.trim() !== ""
      ? raw.truncation_reason.trim()
      : null;
  return { truncated: true, truncationReason: reason };
}

/**
 * The VISIBLE sentence the landing shows when the corpus was cut, or null when
 * it was not. Deliberately visible text and not a `title=` attribute: a tooltip
 * is invisible to touch, to screen readers reading the caption, and to anyone
 * who never hovers — the reader has to be able to SEE that the graph is partial.
 */
export function truncationNotice(
  truncated: boolean,
  truncationReason: string | null,
): string | null {
  if (!truncated) return null;
  switch (truncationReason) {
    case "node_budget":
      return "Partial graph — the corpus is larger than the server's whole-graph node ceiling, so the documents past it are not drawn.";
    case "per_type_cap":
      return "Partial graph — at least one document type hit the server's per-type ceiling, so this is a sample of that type rather than all of it.";
    case "per_type_cap+node_budget":
      return "Partial graph — both the per-type ceiling and the whole-graph node ceiling fired, so documents are missing on both counts.";
    default:
      return "Partial graph — the server reported it cut the corpus but did not name the ceiling.";
  }
}

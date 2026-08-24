/**
 * What the page is actually serving, in words — the human counterpart of the
 * `<meta name="bp-*">` HEALTH markers (`lib/markers.ts`), which only a machine
 * ever reads.
 *
 * THE INVARIANT, and it is the whole module: every value printed here must
 * equal something the page ACTUALLY READ. There are exactly three sources —
 * the deploy markers (`lib/markers.buildIdentity`, from the slot boot env), the
 * corpus graph payload (`lib/graph.CorpusGraph`), and whether an API base was
 * configured at all (`lib/bp-env.isApiUrlConfigured`). Nothing is derived,
 * assumed, or typed in as a constant: a hardcoded provenance line keeps
 * claiming freshness long after it stops being true, which is worse than no
 * line at all.
 *
 * Four rules this file exists to enforce:
 *
 *  1. NO BUILD TIME. `BARKPARK_BUILD_ID` is an opaque caller-supplied string
 *     (`deploy/site-deploy-node.sh`) with no format contract — it is not a
 *     timestamp, and no build-time variable exists in the deploy runtime
 *     allowlist. "Built at …" cannot be derived from anything the page holds,
 *     so it is never printed.
 *  2. A MISSING MARKER IS A STATE, NOT A VALUE. `siteMarkers()` falls back to
 *     the literals "dev"/"unknown" because the HEALTH gate needs non-empty
 *     `content=` attributes. A human line that says `build dev` reads as a
 *     build NAMED dev. `buildIdentity()` reports an unset marker as `null` and
 *     this module renders that as "not a deployed build".
 *  3. A CAPPED COUNT AND A COMPLETE COUNT NEVER RENDER ALIKE. A count the
 *     server cut is printed as "At least N", with the ceiling that actually
 *     fired named in VISIBLE text (a `title=` tooltip reaches no touch,
 *     keyboard or screen-reader user), and a complete count says so explicitly.
 *  4. UNREACHABLE IS NOT EMPTY. A refused connection and a genuinely empty
 *     corpus both leave `nodes: []`; they get different opening words here
 *     ("Not connected —" vs "Connected —") so the page cannot pass one off as
 *     the other.
 *
 * Pure, dependency-free and free of `server-only`/`next/cache` on purpose, for
 * the same reason `lib/markers.ts` is: this is the text a human reads off a
 * deployed page, so it must be pinnable by `node --test` (`provenance.test.ts`)
 * rather than by a fixture that hard-codes the very strings it checks.
 *
 * MIRRORED, deliberately: `templates/astro-search-starter/src/lib/provenance.ts`
 * is the same module for the static edition (that template is a separate
 * package and cannot import across the boundary). Keep the two in lockstep —
 * both have their own `provenance.test.ts` pinning identical text.
 */

/* ── build identity ─────────────────────────────────────────────────────── */

/**
 * Which build this page is, with UNSET distinguishable from set. `null` means
 * the boot env carried no value — NOT that the value is the string "dev".
 */
export interface BuildIdentity {
  /** `BARKPARK_BUILD_ID` / `BUILD_ID`, or null when neither was set. */
  buildId: string | null;
  /** `BARKPARK_CONTENT_REV` / `CONTENT_REV`, or null when neither was set. */
  contentRev: string | null;
}

/**
 * The build line. With both markers unset it names the STATE ("not a deployed
 * build") instead of presenting the sentinels as if they were values.
 */
export function buildIdentityLine(build: BuildIdentity): string {
  const { buildId, contentRev } = build;
  if (buildId === null && contentRev === null) {
    return "Not a deployed build — no build id or content revision was stamped.";
  }
  const left = buildId === null ? "Build id not stamped" : `Build ${buildId}`;
  const right =
    contentRev === null ? "content revision not stamped" : `content ${contentRev}`;
  return `${left} · ${right}.`;
}

/* ── corpus provenance ──────────────────────────────────────────────────── */

/** How the corpus line resolved — also emitted as a `data-` attribute so a
 * curl/DOM probe can assert the STATE without string-matching the copy. */
export type CorpusState =
  | "unconfigured"
  | "unreachable"
  | "empty"
  | "complete"
  | "capped";

/**
 * The corpus read, reduced to only what the line needs. Structural on purpose
 * (the same reason `markers.CorpusStatusInput` is): importing `CorpusGraph`
 * from `lib/graph.ts` would drag `server-only` in here and make this module
 * untestable.
 */
export interface CorpusProvenance {
  /** Nodes the page HOLDS after normalization — phantoms included. */
  nodeCount: number;
  /** Non-phantom nodes: documents with a page of their own. */
  docCount: number;
  /** The server cut the corpus at a ceiling (upstream `truncated`). */
  truncated: boolean;
  /** Upstream `truncation_reason`, null when it named none. */
  truncationReason: string | null;
  /** The upstream status when the corpus could NOT be read; null when the read
   * SUCCEEDED — including a read that succeeded and returned nothing. */
  upstreamStatus: number | null;
  /** The failure in the shared `graph <status>: <message>` shape, or null. */
  upstreamReason: string | null;
  /** Whether an API base URL was configured at all (`lib/bp-env`). False means
   * the read went to the local-dev default nobody asked for, which is a
   * different fault from "the configured host refused". */
  apiConfigured: boolean;
}

/** One rendered corpus line plus its machine-readable state. */
export interface CorpusLine {
  state: CorpusState;
  text: string;
}

/**
 * Thousands separators without `toLocaleString()`: this line is rendered on the
 * server AND hydrated in the browser, and the two runtimes do not agree on a
 * default locale (Node ICU "1,765" vs a browser "1 765"), which is a hydration
 * mismatch on a component whose entire job is to be trustworthy.
 */
export function groupDigits(value: number): string {
  const n = Math.trunc(value);
  const sign = n < 0 ? "-" : "";
  return sign + String(Math.abs(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** The reconciliation sentence: the document count and the node count are
 * DIFFERENT numbers (phantoms are referenced-but-absent, not corpus size), and
 * a page that prints one must account for the other. Empty when they agree. */
function nodesClause(nodeCount: number, docCount: number): string {
  const phantom = nodeCount - docCount;
  if (phantom <= 0) return "";
  return `${groupDigits(nodeCount)} nodes drawn, ${groupDigits(phantom)} referenced but absent.`;
}

/**
 * Which ceiling actually fired, in words. The upstream reason is an opaque
 * token ("node_budget", "per_type_cap", "per_type_cap+node_budget"); it is
 * matched by CONTAINMENT so a compound reason names both ceilings, and an
 * unrecognised token still yields an honest "a ceiling it did not name" rather
 * than a confident wrong claim.
 */
function ceilingClause(reason: string | null): string {
  const r = reason ?? "";
  const perType = r.includes("per_type_cap");
  const budget = r.includes("node_budget");
  if (perType && budget) {
    return "the server stopped at BOTH its per-type document cap and its whole-graph node budget";
  }
  if (perType) {
    return "the server stopped at its per-type document cap, so some types are incomplete";
  }
  if (budget) {
    return "the server stopped at its whole-graph node budget, so the corpus continues past what is drawn";
  }
  return "the server cut the corpus at a ceiling it did not name";
}

/** Join non-empty sentence fragments with single spaces. */
function sentences(...parts: string[]): string {
  return parts.filter((p) => p !== "").join(" ");
}

/**
 * The corpus line — five states, and no two of them read alike.
 *
 * The ORDER of the checks is the contract: a failed read is reported as a
 * failed read even though it also carries zero nodes, so "could not reach the
 * API" can never be served as "the corpus is empty".
 */
export function corpusProvenanceLine(corpus: CorpusProvenance): CorpusLine {
  const {
    nodeCount,
    docCount,
    truncated,
    truncationReason,
    upstreamStatus,
    upstreamReason,
    apiConfigured,
  } = corpus;

  // 1-2. The read FAILED. Which of the two failures it was matters: an unset
  // API base silently falls back to a local-dev default (lib/bp-env), so the
  // refusal a visitor sees has nothing to do with any host anyone configured.
  if (upstreamStatus !== null) {
    const why = upstreamReason ?? `graph ${upstreamStatus}: no detail recorded`;
    return apiConfigured
      ? {
          state: "unreachable",
          text: `Not connected — the corpus could not be read (${why}).`,
        }
      : {
          state: "unconfigured",
          text: `Not connected — no corpus link is configured, so nothing was read (${why}).`,
        };
  }

  // 3. The read SUCCEEDED and there was nothing in it. "Connected —" is the
  // whole point: it is the word the two failures above do not get.
  if (nodeCount === 0) {
    return {
      state: "empty",
      text: "Connected — the corpus read succeeded and holds 0 documents.",
    };
  }

  // 4. The read succeeded and the server cut it. "At least" is load-bearing:
  // the number is a ceiling, not a size. The reason token is VISIBLE, not a
  // tooltip.
  if (truncated) {
    return {
      state: "capped",
      text: sentences(
        `At least ${groupDigits(docCount)} documents — ${ceilingClause(truncationReason)}.`,
        truncationReason === null ? "" : `Cut reported as ${truncationReason}.`,
        nodesClause(nodeCount, docCount),
      ),
    };
  }

  // 5. Complete. It says so out loud, so a complete count and a capped one are
  // never the same sentence with a different number in it.
  return {
    state: "complete",
    text: sentences(
      `${groupDigits(docCount)} documents, complete — nothing was cut.`,
      nodesClause(nodeCount, docCount),
    ),
  };
}

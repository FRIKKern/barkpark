// What the page is actually serving, in words — the human counterpart of the
// `<meta name="bp-*">` HEALTH markers (src/layouts/Base.astro), which only a
// machine ever reads.
//
// THE INVARIANT, and it is the whole module: every value printed here must
// equal something the page ACTUALLY READ. For the static edition there are two
// sources, both baked into `graph.json` at build (src/pages/graph.json.ts) and
// fetched by the island: the build identity (src/lib/bp.buildIdentity) and the
// corpus payload itself. Nothing is derived, assumed, or typed in as a
// constant: a hardcoded provenance line keeps claiming freshness long after it
// stops being true, which is worse than no line at all.
//
// Four rules this file exists to enforce:
//
//  1. NO BUILD TIME. `BARKPARK_BUILD_ID` is an opaque caller-supplied string
//     (deploy/site-deploy-node.sh) with no format contract — it is not a
//     timestamp, and no build-time variable exists in the deploy runtime
//     allowlist. "Built at …" cannot be derived from anything the page holds,
//     so it is never printed.
//  2. A MISSING MARKER IS A STATE, NOT A VALUE. `env.buildId` falls back to the
//     literals "dev"/"unknown" because the HEALTH gate needs non-empty
//     `content=` attributes. A human line that says `build dev` reads as a
//     build NAMED dev. `buildIdentity` reports an unset marker as `null` and
//     this module renders that as "not a deployed build".
//  3. A CAPPED COUNT AND A COMPLETE COUNT NEVER RENDER ALIKE. A count the
//     server cut is printed as "At least N", with the ceiling that actually
//     fired named in VISIBLE text (a `title=` tooltip reaches no touch,
//     keyboard or screen-reader user), and a complete count says so explicitly.
//  4. UNREACHABLE IS NOT EMPTY. A corpus that could not be loaded and a corpus
//     that is genuinely empty both leave `nodes: []`; they get different
//     opening words here ("Not connected —" vs "Connected —") so the pane
//     cannot pass one off as the other.
//
// MIRRORED, deliberately: `templates/search-starter/lib/provenance.ts` is the
// same module for the Next edition (that template is a separate package and
// cannot import across the boundary). Keep the two in lockstep — both have
// their own `provenance.test.ts` pinning identical text. React-free and
// dep-free, so `node --test` can run it.

/* ── build identity ─────────────────────────────────────────────────────── */

/** Which build baked this page, with UNSET distinguishable from set. `null`
 * means the build env carried no value — NOT that the value is "dev". */
export interface BuildIdentity {
  /** `BARKPARK_BUILD_ID`, or null when it was not set. */
  buildId: string | null
  /** `BARKPARK_CONTENT_REV`, or null when it was not set. */
  contentRev: string | null
}

/** The build line. With both markers unset it names the STATE ("not a deployed
 * build") instead of presenting the sentinels as if they were values. */
export function buildIdentityLine(build: BuildIdentity): string {
  const { buildId, contentRev } = build
  if (buildId === null && contentRev === null) {
    return 'Not a deployed build — no build id or content revision was stamped.'
  }
  const left = buildId === null ? 'Build id not stamped' : `Build ${buildId}`
  const right = contentRev === null ? 'content revision not stamped' : `content ${contentRev}`
  return `${left} · ${right}.`
}

/* ── corpus provenance ──────────────────────────────────────────────────── */

/** How the corpus line resolved — also emitted as a `data-` attribute so a
 * curl/DOM probe can assert the STATE without string-matching the copy. */
export type CorpusState = 'unconfigured' | 'unreachable' | 'empty' | 'complete' | 'capped'

/** The corpus read, reduced to only what the line needs. */
export interface CorpusProvenance {
  /** Nodes the pane HOLDS after normalization — phantoms included. */
  nodeCount: number
  /** Non-phantom nodes: documents with a page of their own. */
  docCount: number
  /** The server cut the corpus at a ceiling (upstream `truncated`). */
  truncated: boolean
  /** Upstream `truncation_reason`, null when it named none. */
  truncationReason: string | null
  /** The status when the corpus could NOT be read; null when the read
   * SUCCEEDED — including a read that succeeded and returned nothing. */
  upstreamStatus: number | null
  /** The failure in the shared `graph <status>: <message>` shape, or null. */
  upstreamReason: string | null
  /** Whether a corpus link was configured at all. Always true on the static
   * edition — `src/lib/bp.required('BARKPARK_API_URL')` THROWS at build, so an
   * unconfigured astro site never produces bytes to serve. The field exists so
   * the two editions share one module and one set of strings. */
  apiConfigured: boolean
}

/** One rendered corpus line plus its machine-readable state. */
export interface CorpusLine {
  state: CorpusState
  text: string
}

/** Thousands separators without `toLocaleString()`: the runtime locale of the
 * visitor's browser is not the build machine's, and a number that renders
 * differently per visitor is not a number anyone can quote back. */
export function groupDigits(value: number): string {
  const n = Math.trunc(value)
  const sign = n < 0 ? '-' : ''
  return sign + String(Math.abs(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

/** The reconciliation sentence: the document count and the node count are
 * DIFFERENT numbers (phantoms are referenced-but-absent, not corpus size), and
 * a pane that prints one must account for the other. Empty when they agree. */
function nodesClause(nodeCount: number, docCount: number): string {
  const phantom = nodeCount - docCount
  if (phantom <= 0) return ''
  return `${groupDigits(nodeCount)} nodes drawn, ${groupDigits(phantom)} referenced but absent.`
}

/** Which ceiling actually fired, in words. The reason is an opaque token
 * ("node_budget", "per_type_cap", "per_type_cap+node_budget"); it is matched by
 * CONTAINMENT so a compound reason names both ceilings, and an unrecognised
 * token still yields an honest "a ceiling it did not name". */
function ceilingClause(reason: string | null): string {
  const r = reason ?? ''
  const perType = r.includes('per_type_cap')
  const budget = r.includes('node_budget')
  if (perType && budget) {
    return 'the server stopped at BOTH its per-type document cap and its whole-graph node budget'
  }
  if (perType) {
    return 'the server stopped at its per-type document cap, so some types are incomplete'
  }
  if (budget) {
    return 'the server stopped at its whole-graph node budget, so the corpus continues past what is drawn'
  }
  return 'the server cut the corpus at a ceiling it did not name'
}

/** Join non-empty sentence fragments with single spaces. */
function sentences(...parts: string[]): string {
  return parts.filter((p) => p !== '').join(' ')
}

/**
 * The corpus line — five states, and no two of them read alike.
 *
 * The ORDER of the checks is the contract: a failed read is reported as a
 * failed read even though it also carries zero nodes, so "could not load the
 * corpus" can never be served as "the corpus is empty".
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
  } = corpus

  // 1-2. The read FAILED.
  if (upstreamStatus !== null) {
    const why = upstreamReason ?? `graph ${upstreamStatus}: no detail recorded`
    return apiConfigured
      ? { state: 'unreachable', text: `Not connected — the corpus could not be read (${why}).` }
      : {
          state: 'unconfigured',
          text: `Not connected — no corpus link is configured, so nothing was read (${why}).`,
        }
  }

  // 3. The read SUCCEEDED and there was nothing in it. "Connected —" is the
  // whole point: it is the word the two failures above do not get.
  if (nodeCount === 0) {
    return { state: 'empty', text: 'Connected — the corpus read succeeded and holds 0 documents.' }
  }

  // 4. The read succeeded and the server cut it. "At least" is load-bearing:
  // the number is a ceiling, not a size. The reason token is VISIBLE, not a
  // tooltip.
  if (truncated) {
    return {
      state: 'capped',
      text: sentences(
        `At least ${groupDigits(docCount)} documents — ${ceilingClause(truncationReason)}.`,
        truncationReason === null ? '' : `Cut reported as ${truncationReason}.`,
        nodesClause(nodeCount, docCount),
      ),
    }
  }

  // 5. Complete. It says so out loud, so a complete count and a capped one are
  // never the same sentence with a different number in it.
  return {
    state: 'complete',
    text: sentences(
      `${groupDigits(docCount)} documents, complete — nothing was cut.`,
      nodesClause(nodeCount, docCount),
    ),
  }
}

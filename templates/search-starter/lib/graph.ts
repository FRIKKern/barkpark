import "server-only";
import { unstable_cache } from "next/cache";
import { DATASET } from "@/lib/config";
import { bpAll } from "@/lib/bp-tags";
import { PUBLIC_API_URL } from "@/lib/bp-env";
import { bpFetchJson, BpUpstreamError, humanUpstreamMessage } from "@/lib/bp-fetch";

/**
 * The corpus graph for the landing — the one place that talks to Barkpark's
 * content-graph endpoint (`GET /v1/graph`). Shapes the upstream payload into the
 * exact `{ nodes, edges }` shape the vanilla Canvas2D renderer
 * (`public/bp-graph.js`, `window.BarkparkGraphRenderer`) ingests, plus a
 * computed `rootId` (highest-degree node, "barkpark" preferred) so the renderer
 * has an accent/anchor on first paint.
 *
 * Caching mirrors `lib/find-search.ts`: a hand-rolled `unstable_cache` (the
 * Phoenix origin marks responses `private, max-age=0`, so per-fetch revalidate
 * is a silent no-op). 5-min revalidate, tagged "graph" + the dataset `_all` tag
 * so a publish anywhere refreshes the graph via the existing webhook.
 *
 * Scope/auth mirror find-search: Indx-style token-scoped route
 * (`/w/default/p/default`) when a read token is present, else the flat public
 * route. The token + base URL come from the `server-only` `bp-fetch` module.
 */

/** Cache tag for the graph Data Cache — `revalidateTag(GRAPH_TAG)` busts it. */
export const GRAPH_TAG = "graph";

const API_URL = PUBLIC_API_URL;
/** Prefer this node id as the root when it exists, regardless of degree. */
const PREFERRED_ROOT = "barkpark";

/** Re-export so other modules share the resolved dataset name. */
export { DATASET };

/* ── public shapes (mirror the renderer's node/edge contract) ───────────── */

/** A graph node, exactly as `window.BarkparkGraphRenderer` expects it. */
export interface GraphNode {
  id: string;
  /** Document id the node links to (used to build the reader href). */
  doc_id: string;
  /** Document type (post | paper | sheet | …) — drives Full-color + the href. */
  type: string;
  title: string;
  /** A referenced-but-absent node (no document of its own) — never navigable. */
  phantom?: boolean;
}

/** A graph edge, exactly as `window.BarkparkGraphRenderer` expects it. */
export interface GraphEdge {
  from_id: string;
  to_id: string;
  /** Relationship kind (reference | link | …) — opaque to the renderer. */
  kind?: string;
  /** Edge weight (≥1) — opaque to the renderer; reserved for thickness. */
  weight?: number;
}

/** The landing's full payload: nodes, edges, and the chosen accent root. */
export interface CorpusGraph {
  nodes: GraphNode[];
  edges: GraphEdge[];
  /** Highest-degree node id (PREFERRED_ROOT wins when present), or null. */
  rootId: string | null;
  /** The server cut the corpus at a ceiling — the graph shown is a subset,
   * and any caption must say so. Covers BOTH server ceilings (fixed by
   * stw9-backlog-graph-server-honesty): the whole-graph node budget (2000)
   * AND the 1000-docs-per-type cap, so `false` here really means "complete". */
  truncated: boolean;
  /** Upstream truncation cause ("node_budget", "per_type_cap", or
   * "per_type_cap+node_budget"), null when not truncated. */
  truncationReason: string | null;
  /** The upstream HTTP status when the corpus could NOT be read (0 for a
   * network/timeout/parse failure), null when the read SUCCEEDED — including a
   * read that succeeded and returned an empty corpus. This is the status the
   * landing used to destroy: an unreadable corpus and an empty one both left an
   * empty `bp-doc-id` and the deploy row could not tell them apart. */
  upstreamStatus: number | null;
  /** The failure in the shared shape `graph <status>: <message>` — byte-identical
   * in wording to the astro edition's throw (`templates/astro-search-starter/
   * src/lib/bp.ts`), so ONE classifier covers both templates. null on success. */
  upstreamReason: string | null;
}

/** A corpus read that failed, carrying the upstream status out of the fetch
 * layer so the degraded landing can still RECORD which condition stopped it. */
export class CorpusUnavailableError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(`graph ${status}: ${message}`);
    this.name = "CorpusUnavailableError";
    this.status = status;
  }
}

/* ── upstream parsing ───────────────────────────────────────────────────── */

interface UpstreamGraph {
  nodes?: unknown[];
  edges?: unknown[];
  truncated?: unknown;
  truncation_reason?: unknown;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/** Normalise one raw upstream node. Tolerant of field aliases so the landing
 * survives a minor API shape drift (id/node_id, doc_id/document_id, type/_type). */
function normalizeNode(raw: unknown): GraphNode | null {
  if (!raw || typeof raw !== "object") return null;
  const n = raw as Record<string, unknown>;
  const id = str(n.id) ?? str(n.node_id);
  if (!id) return null;
  const docId = str(n.doc_id) ?? str(n.document_id) ?? str(n._id) ?? id;
  const type = str(n.type) ?? str(n._type) ?? "_unknown";
  const title = str(n.title) ?? str(n.name) ?? id;
  const phantom =
    n.phantom === true || n.phantom === "true" || n.is_phantom === true;
  return phantom
    ? { id, doc_id: docId, type, title, phantom: true }
    : { id, doc_id: docId, type, title };
}

/** Normalise one raw upstream edge. Tolerant of from/from_id/source aliases. */
function normalizeEdge(raw: unknown): GraphEdge | null {
  if (!raw || typeof raw !== "object") return null;
  const e = raw as Record<string, unknown>;
  const from = str(e.from_id) ?? str(e.from) ?? str(e.source);
  const to = str(e.to_id) ?? str(e.to) ?? str(e.target);
  if (!from || !to) return null;
  const kind = str(e.kind) ?? str(e.type);
  const weight = num(e.weight);
  const out: GraphEdge = { from_id: from, to_id: to };
  if (kind) out.kind = kind;
  if (weight !== undefined) out.weight = weight;
  return out;
}

/**
 * Root selection: the node with the highest total degree (in + out), with
 * PREFERRED_ROOT ("barkpark") winning outright when it appears in the node set.
 * Degree is computed from edges so it never depends on an upstream-supplied
 * ordering. Returns null for an empty graph.
 */
function computeRootId(nodes: GraphNode[], edges: GraphEdge[]): string | null {
  if (nodes.length === 0) return null;
  const present = new Set(nodes.map((n) => n.id));
  if (present.has(PREFERRED_ROOT)) return PREFERRED_ROOT;

  const degree = new Map<string, number>();
  for (const n of nodes) degree.set(n.id, 0);
  for (const e of edges) {
    if (present.has(e.from_id)) degree.set(e.from_id, (degree.get(e.from_id) ?? 0) + 1);
    if (present.has(e.to_id)) degree.set(e.to_id, (degree.get(e.to_id) ?? 0) + 1);
  }

  let best = nodes[0].id;
  let bestDeg = degree.get(best) ?? 0;
  for (const n of nodes) {
    const d = degree.get(n.id) ?? 0;
    if (d > bestDeg) {
      best = n.id;
      bestDeg = d;
    }
  }
  return best;
}

/* ── upstream fetch ─────────────────────────────────────────────────────── */

/** Raw, uncached upstream call. Caching is layered above by `cachedGraph`. */
async function rawCorpusGraph(): Promise<CorpusGraph> {
  // The corpus endpoint is mounted FLAT (`/v1/graph`, [:api, :require_token]) —
  // tenancy comes from the bearer's default scope, not a `/w/p/` path prefix
  // (the scoped path 404s). The managed deploy path injects a SCOPED
  // BARKPARK_API_URL (`<origin>/w/:ws/p/:proj` — correct for every content
  // read), so derive the BARE ORIGIN here for this one flat call — live-caught:
  // the scoped+flat concatenation 404'd, the corpus came back empty, and the
  // HEALTH gate honestly refused the deploy (empty bp-doc-id).
  const origin = new URL(API_URL).origin;
  const url = `${origin}/v1/graph?dataset=${encodeURIComponent(DATASET)}`;

  let json: UpstreamGraph;
  try {
    json = (await bpFetchJson(url)) as UpstreamGraph;
  } catch (e) {
    if (e instanceof BpUpstreamError) {
      throw new CorpusUnavailableError(e.status, humanUpstreamMessage(e));
    }
    // Network/timeout/parse: status 0, but the message still names the cause —
    // a row that says "graph 0: fetch failed" is legible, an empty one is not.
    throw new CorpusUnavailableError(
      0,
      e instanceof Error ? e.message : String(e),
    );
  }

  const nodes = (json.nodes ?? [])
    .map(normalizeNode)
    .filter((n): n is GraphNode => n !== null);
  // Only keep edges whose endpoints both exist as nodes (an orphan edge would
  // make the renderer draw a phantom it never told us about).
  const ids = new Set(nodes.map((n) => n.id));
  const edges = (json.edges ?? [])
    .map(normalizeEdge)
    .filter((e): e is GraphEdge => e !== null && ids.has(e.from_id) && ids.has(e.to_id));

  // Truncation truth, passed through verbatim-but-typed. Strictly `=== true`
  // so a drifted/absent field degrades to the safe "no claim" state.
  const truncated = json.truncated === true;
  const truncationReason = truncated ? (str(json.truncation_reason) ?? null) : null;

  return {
    nodes,
    edges,
    rootId: computeRootId(nodes, edges),
    truncated,
    truncationReason,
    upstreamStatus: null,
    upstreamReason: null,
  };
}

/** Cached variant — 5-min revalidate, tagged GRAPH_TAG + the dataset `_all`
 * tag so a published change anywhere refreshes the landing via the webhook. */
const cachedGraph = unstable_cache(rawCorpusGraph, ["corpus-graph", DATASET], {
  revalidate: 300,
  tags: [GRAPH_TAG, bpAll()],
});

/** Classify anything thrown out of the fetch path into (status, reason). */
function corpusFailure(e: unknown): { status: number; reason: string } {
  if (e instanceof CorpusUnavailableError) {
    // `message` is already the shared `graph <status>: <message>` shape.
    return { status: e.status, reason: e.message };
  }
  const msg = e instanceof Error ? e.message : String(e);
  return { status: 0, reason: `graph 0: ${msg}` };
}

/**
 * Fetch the corpus graph for the landing. Never throws — a hard upstream
 * failure degrades to an empty graph (the landing shows the renderer's own
 * empty state rather than crashing the Server Component), because the landing
 * is a non-critical SURFACE.
 *
 * It is NOT a non-critical FACT, though: the failure detail used to be
 * destroyed here, so a build that could not read its corpus emitted an empty
 * `bp-doc-id` and the deploy engine could only record the symptom ("marker is
 * empty") for at least seven distinct causes — a 403 from a public-read token,
 * a 401 with no token, a wrong host, a transient 5xx, a genuinely empty corpus,
 * … all one illegible row. So the status is now CARRIED out of the catch on
 * `upstreamStatus`/`upstreamReason`; the landing still degrades, the deploy row
 * finally names the cause (see `corpusStatusMarker`).
 */
export async function fetchCorpusGraph(): Promise<CorpusGraph> {
  try {
    const cached = await cachedGraph();
    if (cached.nodes.length > 0) return cached;
    // The cache held an empty/transiently-failed graph (e.g. a render that
    // happened during an upstream restart). Retry LIVE so one hiccup can't pin
    // the landing empty for the whole revalidate window; the next cache
    // revalidation re-populates from the live API once it's healthy.
    return await rawCorpusGraph();
  } catch (e) {
    const { status, reason } = corpusFailure(e);
    return {
      nodes: [],
      edges: [],
      rootId: null,
      truncated: false,
      truncationReason: null,
      upstreamStatus: status,
      upstreamReason: reason,
    };
  }
}

/** Marker values are read back out of served HTML by a shell `sed` on
 * `content="…"` (`deploy/lib/site-deploy-common.sh` meta_value), so keep the
 * value single-line and quote/angle-free, and bounded so one upstream error
 * body cannot bloat the SSR head. */
const MARKER_MAX = 200;
function sanitizeMarker(text: string): string {
  const flat = text.replace(/[\r\n\t]+/g, " ").replace(/["'<>]/g, "").trim();
  const collapsed = flat.replace(/\s{2,}/g, " ");
  return collapsed.length > MARKER_MAX
    ? `${collapsed.slice(0, MARKER_MAX - 1)}…`
    : collapsed;
}

/**
 * The value of the `bp-corpus-status` HEALTH marker — the upstream condition to
 * RECORD when the SSR could not anchor a content document, and "" when it could
 * (a healthy render has nothing to record).
 *
 * This deliberately does NOT fabricate a doc id to make HEALTH pass: the deploy
 * gate failing closed on an empty `bp-doc-id` is the one part of this story that
 * always behaved correctly (site-spawner D72), and it must keep refusing. All
 * this adds is WHY it refused — `deploy/site-deploy-node.sh` reads this marker
 * into HEALTH_DETAIL, so the recorded failure_reason distinguishes a 403 from a
 * 401, from a wrong host, from a genuinely empty corpus.
 */
export function corpusStatusMarker(graph: CorpusGraph, docId: string): string {
  if (docId !== "") return "";
  if (graph.upstreamReason) return sanitizeMarker(graph.upstreamReason);
  // The read SUCCEEDED — this is the honest "there was nothing to anchor" case
  // (empty corpus, or a corpus of nothing but phantom nodes).
  return sanitizeMarker(
    `graph 200: corpus read OK but carried ${graph.nodes.length} node(s), none usable as a content anchor`,
  );
}

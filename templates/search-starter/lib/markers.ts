/**
 * Deploy HEALTH markers — the three `<meta>` tags the site-deploy engine asserts
 * on before it flips Caddy to a freshly-booted slot
 * (`deploy/site-deploy-node.sh` health_gate_node, marker reader
 * `deploy/lib/site-deploy-common.sh` meta_value):
 *
 *   <meta name="bp-build-id"    content="…">  which build this slot serves
 *   <meta name="bp-content-rev" content="…">  the content revision it was cut against
 *   <meta name="bp-doc-id"      content="…">  a real content document id (content-truth)
 *
 * …plus ONE conditional marker, emitted only when the third is EMPTY:
 *
 *   <meta name="bp-corpus-status" content="…"> which upstream condition stopped
 *                                              the SSR from anchoring a document
 *                                              (cause-truth)
 *
 * It does not rescue the deploy — an empty bp-doc-id still fails the gate closed,
 * which is the one part of that story that always behaved correctly. It makes the
 * refusal LEGIBLE: the recorded failure_reason names a 403, a 401, a wrong host or
 * a genuinely empty corpus instead of collapsing all of them into "marker is
 * empty". Its VALUE SHAPING lives here, beside the other markers and free of
 * `server-only` / `next/cache`, so it can be pinned by a unit test — the marker
 * text is an interface the deploy engine reads back with `sed`, and the shell
 * self-test's fixture hard-codes it, so nothing else would catch the two drifting
 * apart.
 *
 * The gate boots the idle slot and probes ONE path (the site base under
 * `BARKPARK_SITE_HEALTH_PATH`), asserting bp-build-id EQUALS the build it ships,
 * bp-content-rev is non-empty (and matches CONTENT_REV when set), and bp-doc-id
 * is non-empty — so a build that lost its content link fails closed and the live
 * slot is never touched.
 *
 * Values are read at REQUEST time (the finder landing is `force-dynamic`) from
 * the slot BOOT env the engine writes (`BARKPARK_BUILD_ID`, `BARKPARK_CONTENT_REV`,
 * `BARKPARK_SITE_BASE` — see write_slot_env), with dev sentinels so a local
 * `next dev` still renders. The `BUILD_ID` / `CONTENT_REV` bare names are honored
 * as a fallback for parity with other adapters.
 *
 * These are read on the SERVER only (root layout + landing/detail pages, all
 * server components), so no `NEXT_PUBLIC_` prefix is needed.
 */

export interface SiteMarkers {
  /** Immutable id of the build this slot serves (asserted == the shipped build). */
  buildId: string;
  /** The content revision the build was cut against (asserted non-empty). */
  contentRev: string;
  /** The `/sites/<slug>/` base this site is served under (informational marker). */
  siteBase: string;
}

/** Resolve the deploy markers from the (boot) env, with dev sentinels. */
export function siteMarkers(env: NodeJS.ProcessEnv = process.env): SiteMarkers {
  return {
    buildId: env.BARKPARK_BUILD_ID?.trim() || env.BUILD_ID?.trim() || "dev",
    contentRev:
      env.BARKPARK_CONTENT_REV?.trim() || env.CONTENT_REV?.trim() || "unknown",
    siteBase: env.BARKPARK_SITE_BASE?.trim() || "/",
  };
}

/* ── build identity: the same env, read for a HUMAN ───────────────────────── */

/**
 * Which build this is, with UNSET reported as `null` instead of collapsed onto
 * the "dev"/"unknown" sentinels `siteMarkers()` uses.
 *
 * Two readers, two contracts, and they genuinely differ. The deploy gate greps
 * `content="…"` out of the served HTML and asserts it is NON-EMPTY, so the
 * markers must always carry a string — hence the sentinels above, which stay
 * exactly as they are. A HUMAN reading the page needs the opposite: a line that
 * says `build dev` reads as a build NAMED dev, so the provenance surface has to
 * tell "no build id was stamped" from "the build id is the string dev". This
 * function is that distinction; `lib/provenance.buildIdentityLine` turns it
 * into the sentence.
 *
 * Deliberately NOT a refactor of `siteMarkers()`: the marker values are an
 * interface the deploy engine reads back with `sed`, and the shell self-test's
 * fixture hard-codes them. Changing them to satisfy a copy requirement would
 * break a gate in order to fix a sentence.
 */
export interface BuildIdentity {
  /** `BARKPARK_BUILD_ID` / `BUILD_ID`, or null when neither was set. */
  buildId: string | null;
  /** `BARKPARK_CONTENT_REV` / `CONTENT_REV`, or null when neither was set. */
  contentRev: string | null;
}

export function buildIdentity(
  env: NodeJS.ProcessEnv = process.env,
): BuildIdentity {
  return {
    buildId: env.BARKPARK_BUILD_ID?.trim() || env.BUILD_ID?.trim() || null,
    contentRev:
      env.BARKPARK_CONTENT_REV?.trim() || env.CONTENT_REV?.trim() || null,
  };
}

/* ── bp-corpus-status: the cause-truth marker ─────────────────────────────── */

/**
 * The marker value is read back out of served HTML by a shell `sed` on
 * `content="…"` (`deploy/lib/site-deploy-common.sh` meta_value), so it must stay
 * single-line and quote/angle-free, and bounded so one upstream error body
 * cannot bloat the SSR head.
 */
export const CORPUS_STATUS_MARKER_MAX = 200;

export function sanitizeMarkerValue(text: string): string {
  const flat = text.replace(/[\r\n\t]+/g, " ").replace(/["'<>]/g, "").trim();
  const collapsed = flat.replace(/\s{2,}/g, " ");
  return collapsed.length > CORPUS_STATUS_MARKER_MAX
    ? `${collapsed.slice(0, CORPUS_STATUS_MARKER_MAX - 1)}…`
    : collapsed;
}

/**
 * The corpus read, reduced to only what the marker needs. Structural on purpose:
 * importing `CorpusGraph` from `lib/graph.ts` would drag `server-only` and
 * `next/cache` in here and make this module untestable again.
 */
export interface CorpusStatusInput {
  /** `graph <status>: <message>` when the read FAILED, null when it succeeded. */
  upstreamReason: string | null;
  /** How many nodes the read returned (0 on failure, and on an empty corpus). */
  nodeCount: number;
}

/**
 * The value of the `bp-corpus-status` marker: the upstream condition to RECORD
 * when the SSR could not anchor a content document, and `""` when it could — a
 * healthy render has nothing to record and emits no marker at all.
 *
 * It never fabricates a doc id to make HEALTH pass, and it never invents a
 * cause: a read that SUCCEEDED and simply had nothing to anchor says exactly
 * that.
 */
export function corpusStatusMarkerValue(
  input: CorpusStatusInput,
  docId: string,
): string {
  if (docId !== "") return "";
  if (input.upstreamReason) return sanitizeMarkerValue(input.upstreamReason);
  return sanitizeMarkerValue(
    `graph 200: corpus read OK but carried ${input.nodeCount} node(s), none usable as a content anchor`,
  );
}

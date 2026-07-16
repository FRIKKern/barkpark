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

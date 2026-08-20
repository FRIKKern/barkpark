import "server-only";
import {
  createClient as createCoreClient,
  type BarkparkClient,
  type BarkparkClientConfig,
} from "@barkpark/core";
import { DATASET } from "./config";
import { PUBLIC_API_URL, READ_TOKEN } from "./bp-env";

const projectUrl = PUBLIC_API_URL;

/**
 * Server-side read token. Sent by `@barkpark/core` as `Authorization: Bearer`,
 * so SSR fetches authenticate instead of going anonymous — required for the
 * scoped `/w/:ws/p/:project/...` routes (anonymous → 403 "token lacks required
 * permission") and the switcher's tenancy fetches (anonymous → 401).
 *
 * Intentionally NOT `NEXT_PUBLIC_*`: this module is `import "server-only"`, the
 * token must never be bundled into client JS. Single-server-token model — every
 * SSR request shares this read token. (Per-user / per-request tokens would be a
 * separate auth design, not in scope here.) Falls back to `undefined` when
 * unset, which core treats as anonymous (back-compat with public reads).
 *
 * Name: canonical `BARKPARK_TOKEN`, with fallback to the legacy
 * `BARKPARK_READ_TOKEN` (resolved in `./bp-env`).
 */
const readToken = READ_TOKEN;

/** Defaults shared by every client this app builds. */
const BASE_CONFIG = {
  projectUrl,
  dataset: DATASET,
  apiVersion: "2026-04-01",
  perspective: "published",
  ...(readToken ? { token: readToken } : {}),
} satisfies Pick<
  BarkparkClientConfig,
  "projectUrl" | "dataset" | "apiVersion" | "perspective" | "token"
>;

/** Scope passed in from a `/w/:workspace/p/:project` route segment. */
export interface ClientScope {
  workspace?: string;
  project?: string;
  dataset?: string;
}

/**
 * Per-request client factory.
 *
 * When both `workspace` and `project` are supplied, the underlying
 * `@barkpark/core` client scopes every request to `/w/<workspace>/p/<project>`
 * (via core's `scopePrefix`). Omit them — or use the `client` export below — to
 * get the flat `/v1/...` back-compat path.
 *
 * Build a fresh client per request (do NOT memoise across requests): the
 * workspace/project come from route params and differ between requests.
 */
export function createClient(scope: ClientScope = {}): BarkparkClient {
  return createCoreClient({
    ...BASE_CONFIG,
    ...(scope.workspace ? { workspace: scope.workspace } : {}),
    ...(scope.project ? { project: scope.project } : {}),
    ...(scope.dataset ? { dataset: scope.dataset } : {}),
  });
}

/**
 * Default flat-scope client for the existing top-level routes (back-compat).
 * No workspace/project → core emits the flat `/v1/...` paths.
 */
export const client: BarkparkClient = createClient();

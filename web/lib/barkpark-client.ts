import "server-only";
import {
  createClient as createCoreClient,
  type BarkparkClient,
  type BarkparkClientConfig,
} from "@barkpark/core";

const projectUrl = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";

/** Defaults shared by every client this app builds. */
const BASE_CONFIG = {
  projectUrl,
  dataset: "production",
  apiVersion: "2026-04-01",
  perspective: "published",
} satisfies Pick<
  BarkparkClientConfig,
  "projectUrl" | "dataset" | "apiVersion" | "perspective"
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

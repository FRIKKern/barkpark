// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/** Config for createDraftModeRoutes. */
export interface DraftModeConfig {
  /** HMAC key used to verify the signed preview URL's `sign` query param. Server-only. */
  previewSecret: string
  /**
   * Optional rewrite applied to the verified path before redirect. Receives the verified path
   * from the signed URL and returns the final redirect target (e.g. mapping `/posts/x` to
   * `/preview/posts/x`). If omitted the verified path is used as-is.
   */
  resolvePath?: (path: string) => string
  /**
   * Optional hook invoked once after an initial verify failure. Expected to return an
   * alternate HMAC secret (e.g. the previous value during a rotation window). The route
   * retries verification with that secret exactly once; a second failure returns 401.
   * Mirrors the dual-secret rotation pattern used by createWebhookHandler.
   */
  reissuePreviewToken?: () => Promise<string>
}

/** Handlers returned by createDraftModeRoutes. Shaped for Next.js App Router route files. */
export interface DraftModeHandlers {
  GET: (req: Request) => Promise<Response>
  DELETE: (req: Request) => Promise<Response>
}

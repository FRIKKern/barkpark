// src/util/edge-detect.ts
// Zero side effects on import. Pure functions only.
// Detection layers, cheapest → most expensive:
//   1. globalThis.EdgeRuntime truthy (Vercel Edge runtime marker)
//   2. globalThis.process?.env?.NEXT_RUNTIME === 'edge' (Next.js edge runtime)
//   3. Web-Streams heuristic: typeof ReadableStream !== 'undefined' AND
//      typeof globalThis.Response !== 'undefined' AND
//      no `node:*` require AND
//      navigator.userAgent includes 'Cloudflare-Workers' OR globalThis.WebSocketPair exists (workerd signal)

export type EdgeSignal =
  | 'vercel-edge-runtime'
  | 'next-runtime-edge'
  | 'cloudflare-workers'
  | 'workerd'
  | null

/**
 * Returns a string signal when running on an edge runtime that cannot stream SSE
 * reliably, or null when streaming is expected to work.
 *
 * Used by listen() to decide whether to throw BarkparkEdgeRuntimeError immediately.
 *
 * Safe to call in any runtime: never throws, never imports node:*, never reads dynamic modules.
 */
export function detectEdgeRuntime(): EdgeSignal {
  // Layer 1: Vercel Edge marker
  const g = globalThis as any
  if (g?.EdgeRuntime) return 'vercel-edge-runtime'

  // Layer 2: NEXT_RUNTIME env (works in both Next edge bundle and test envs)
  const nextRuntime = g?.process?.env?.NEXT_RUNTIME
  if (nextRuntime === 'edge') return 'next-runtime-edge'

  // Layer 3: Cloudflare Workers / workerd heuristic
  // - WebSocketPair is a workerd/Cloudflare-only global
  // - navigator.userAgent 'Cloudflare-Workers' is set by workerd
  const ua = g?.navigator?.userAgent
  if (typeof ua === 'string' && ua.includes('Cloudflare-Workers')) return 'cloudflare-workers'
  if (typeof g?.WebSocketPair !== 'undefined') return 'workerd'

  return null
}

/**
 * True when listen() should refuse to run.
 * Kept separate so transport.ts can use detectEdgeRuntime() for telemetry
 * without deciding policy.
 */
export function isEdgeRuntime(): boolean {
  return detectEdgeRuntime() !== null
}

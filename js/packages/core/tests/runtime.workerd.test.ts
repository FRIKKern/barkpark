import { describe, it, expect } from 'vitest'
import { createClient, BarkparkEdgeRuntimeError } from '../src'
import { detectEdgeRuntime } from '../src/util/edge-detect'

// THIS FILE USED TO CERTIFY NOTHING (task-526abd1fdc75033f). Titled "core runs
// under workerd", its entire body was `expect(typeof globalThis.fetch).toBe
// ('function')` — it never imported @barkpark/core, and that assertion is true
// in every modern runtime including plain Node. Copied alone into an empty
// directory containing zero lines of core, no workerd and a plain
// `environment: 'node'` config, it went GREEN.
//
// So the two things it must now do, and the order matters:
//   1. PROVE THE RUNTIME FIRST. If the workers pool ever silently degrades to
//      Node, everything below would still pass on a lie. The runtime assertions
//      are workerd-only globals, so this file cannot go green off-workerd.
//   2. ACTUALLY EXERCISE CORE, so the title means something.
//
// The strongest single assertion is the last one: core's documented edge
// contract is that listen() throws SYNCHRONOUSLY under workerd. That can only
// hold if BOTH halves are real — core is loaded AND the runtime is workerd — so
// it is impossible to satisfy by accident in Node.

describe('the runtime really is workerd (asserted BEFORE anything else)', () => {
  it('exposes workerd-only globals', () => {
    // WebSocketPair is workerd/Cloudflare-only; Node has never had it.
    expect(typeof (globalThis as { WebSocketPair?: unknown }).WebSocketPair).not.toBe('undefined')
  })

  it("core's own detector agrees it is on an edge runtime", () => {
    expect(detectEdgeRuntime()).not.toBeNull()
  })

  it('has the Web platform surface core depends on', () => {
    expect(typeof globalThis.fetch).toBe('function')
    expect(typeof globalThis.ReadableStream).toBe('function')
    expect(typeof globalThis.TextEncoder).toBe('function')
    expect(typeof globalThis.crypto?.subtle).toBe('object')
  })
})

describe('@barkpark/core loads and works under workerd', () => {
  const config = {
    projectUrl: 'https://example.com',
    dataset: 'production',
    apiVersion: '2026-04-01',
  } as const

  it('createClient returns the full method surface', () => {
    const client = createClient(config)
    for (const method of [
      'doc',
      'docs',
      'patch',
      'transaction',
      'publish',
      'unpublish',
      'listen',
      'fetchRaw',
      'withConfig',
    ] as const) {
      expect(typeof client[method]).toBe('function')
    }
  })

  it('withConfig composes without touching a node: builtin', () => {
    const client = createClient(config).withConfig({ dataset: 'staging' })
    expect(typeof client.doc).toBe('function')
  })

  it('listen() throws BarkparkEdgeRuntimeError SYNCHRONOUSLY — the edge contract', () => {
    // The load-bearing assertion. It requires core to be imported AND the
    // runtime to be workerd; in Node listen() would build a handle instead of
    // throwing, so this line cannot pass off-workerd. @barkpark/core advertises
    // edge/worker support, and this is the proof of the one behaviour that
    // support actually promises.
    expect(() => createClient(config).listen('post')).toThrow(BarkparkEdgeRuntimeError)
  })
})

import { describe, it, expect } from 'vitest'
import * as root from '../src/index'
import * as actions from '../src/actions/index'
import * as webhook from '../src/webhook/index'
import * as draftMode from '../src/draft-mode/index'
import * as server from '../src/server/index'

describe('@barkpark/nextjs scaffold', () => {
  it('root exports revalidateBarkpark', () => {
    expect(typeof root.revalidateBarkpark).toBe('function')
  })
  it('actions exports defineActions (identity) and useOptimisticDocument', () => {
    const c = { ok: true }
    expect(actions.defineActions(c)).toBe(c)
    expect(typeof actions.useOptimisticDocument).toBe('function')
  })
  it('webhook exports createWebhookHandler', () => {
    expect(typeof webhook.createWebhookHandler).toBe('function')
  })
  it('draft-mode exports createDraftModeRoutes', () => {
    expect(typeof draftMode.createDraftModeRoutes).toBe('function')
  })
  it('server exports createBarkparkServer + defineLive (server-only mocked via setup.server.ts)', () => {
    expect(typeof server.createBarkparkServer).toBe('function')
    expect(typeof server.defineLive).toBe('function')
  })
})

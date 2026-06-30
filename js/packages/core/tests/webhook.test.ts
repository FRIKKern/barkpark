import { describe, it, expect } from 'vitest'
import { createHmac } from 'node:crypto'
import { verifyWebhookSignature } from '../src/webhook'

// Independent reference signer (node:crypto) — the SDK verifies with Web Crypto,
// so a passing test proves the two agree on the `${t}.${body}` HMAC-SHA256 over
// the dispatcher's `t=<unix>,v1=<hex>` header form.
function sign(secret: string, t: number, body: string): string {
  const v1 = createHmac('sha256', secret).update(`${t}.${body}`).digest('hex')
  return `t=${t},v1=${v1}`
}

const SECRET = 'whsec_test'
const BODY = '{"event":"document.published","id":"p1"}'
const NOW = 1_700_000_000

describe('verifyWebhookSignature', () => {
  it('accepts a valid signature within the freshness window', async () => {
    const sig = sign(SECRET, NOW, BODY)
    expect(
      await verifyWebhookSignature({ body: BODY, signature: sig, secret: SECRET, nowSeconds: NOW }),
    ).toBe(true)
  })

  it('rejects a wrong secret', async () => {
    const sig = sign(SECRET, NOW, BODY)
    expect(
      await verifyWebhookSignature({
        body: BODY,
        signature: sig,
        secret: 'whsec_other',
        nowSeconds: NOW,
      }),
    ).toBe(false)
  })

  it('rejects a tampered body', async () => {
    const sig = sign(SECRET, NOW, BODY)
    expect(
      await verifyWebhookSignature({
        body: BODY + ' ',
        signature: sig,
        secret: SECRET,
        nowSeconds: NOW,
      }),
    ).toBe(false)
  })

  it('rejects a stale timestamp (replay defense)', async () => {
    const sig = sign(SECRET, NOW - 1000, BODY)
    expect(
      await verifyWebhookSignature({
        body: BODY,
        signature: sig,
        secret: SECRET,
        nowSeconds: NOW,
        toleranceSeconds: 300,
      }),
    ).toBe(false)
  })

  it('accepts the previousSecret during rotation', async () => {
    const sig = sign('whsec_old', NOW, BODY)
    expect(
      await verifyWebhookSignature({
        body: BODY,
        signature: sig,
        secret: 'whsec_new',
        previousSecret: 'whsec_old',
        nowSeconds: NOW,
      }),
    ).toBe(true)
  })

  it('rejects malformed / missing signatures without throwing', async () => {
    for (const bad of [null, undefined, '', 'garbage', 'v1=abc', `t=${NOW}`, `t=nope,v1=abc`]) {
      expect(
        await verifyWebhookSignature({
          body: BODY,
          signature: bad,
          secret: SECRET,
          nowSeconds: NOW,
        }),
      ).toBe(false)
    }
  })
})

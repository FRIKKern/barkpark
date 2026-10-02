import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  CONTACT_LIMITS,
  CONTACT_RATE_LIMIT,
  CONTACT_RATE_WINDOW_MS,
  HONEYPOT_FIELD,
  clientKey,
  contactFieldError,
  createContactRateLimiter,
  isHoneypotFilled,
} from '../templates/website-starter/lib/contact-guard'

/**
 * r4a: the website-starter contact form is an ANONYMOUS write under the site's
 * server token, and it had no field cap, no honeypot and no rate limit — a loop
 * of POSTs filled the dataset with as many (and as large) documents as the
 * caller liked. The guards are imported from the TEMPLATE itself.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SITE = path.resolve(HERE, '..', 'templates', 'website-starter')

const ok = { name: 'Ada', email: 'ada@example.com', message: 'Hello there' }

describe('contactFieldError', () => {
  it('accepts an ordinary submission', () => {
    expect(contactFieldError(ok)).toBeNull()
  })

  it('refuses an empty field', () => {
    expect(contactFieldError({ ...ok, message: '' })).toMatch(/required/)
  })

  it.each(['name', 'email', 'message'] as const)('refuses an over-long %s, accepts one at the cap', (key) => {
    const cap = CONTACT_LIMITS[key]
    expect(contactFieldError({ ...ok, [key]: 'x'.repeat(cap) })).toBeNull()
    expect(contactFieldError({ ...ok, [key]: 'x'.repeat(cap + 1) })).toMatch(new RegExp(`${key}.*${cap}`))
  })

  it('a multi-megabyte message is refused', () => {
    expect(contactFieldError({ ...ok, message: 'x'.repeat(3 * 1024 * 1024) })).not.toBeNull()
  })
})

describe('honeypot', () => {
  it('empty / absent is a person, any text is a bot', () => {
    expect(isHoneypotFilled(null)).toBe(false)
    expect(isHoneypotFilled('')).toBe(false)
    expect(isHoneypotFilled('  ')).toBe(false)
    expect(isHoneypotFilled('http://spam.example')).toBe(true)
  })
})

describe('createContactRateLimiter (per-instance, in memory)', () => {
  it(`allows ${CONTACT_RATE_LIMIT} per window per client, then refuses, then resets`, () => {
    const lim = createContactRateLimiter()
    const t0 = 1_700_000_000_000
    for (let i = 0; i < CONTACT_RATE_LIMIT; i++) expect(lim.allow('1.2.3.4', t0 + i)).toBe(true)
    expect(lim.allow('1.2.3.4', t0 + 100)).toBe(false)
    // Another client has its own budget.
    expect(lim.allow('5.6.7.8', t0 + 100)).toBe(true)
    // After the window the first client is allowed again.
    expect(lim.allow('1.2.3.4', t0 + CONTACT_RATE_WINDOW_MS + 1)).toBe(true)
  })

  it('clientKey takes the first x-forwarded-for hop, then x-real-ip', () => {
    const h = (m: Record<string, string>) => ({ get: (n: string) => m[n] ?? null })
    expect(clientKey(h({ 'x-forwarded-for': '9.9.9.9, 10.0.0.1' }))).toBe('9.9.9.9')
    expect(clientKey(h({ 'x-real-ip': '8.8.8.8' }))).toBe('8.8.8.8')
    expect(clientKey(h({}))).toBe('unknown')
  })
})

describe('the shipped action and page use the guards', () => {
  it('actions.ts checks caps, honeypot and the limiter BEFORE createDoc', async () => {
    const src = await fs.readFile(path.join(SITE, 'app', 'contact', 'actions.ts'), 'utf8')
    const write = src.indexOf('createDoc({')
    for (const needle of ['contactFieldError(', 'isHoneypotFilled(', 'limiter.allow(']) {
      const at = src.indexOf(needle)
      expect(at, `${needle} present`).toBeGreaterThan(-1)
      expect(at, `${needle} before the write`).toBeLessThan(write)
    }
  })

  it('page.tsx renders the hidden honeypot input', async () => {
    const src = await fs.readFile(path.join(SITE, 'app', 'contact', 'page.tsx'), 'utf8')
    expect(src).toContain(`name="${HONEYPOT_FIELD}"`)
    expect(src).toContain('aria-hidden="true"')
    expect(src).toContain('tabIndex={-1}')
  })
})

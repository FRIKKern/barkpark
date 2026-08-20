// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The schema fetch is bounded by a deadline that survives the BODY read.
// Before this, `fetchSchema` passed no signal and awaited `res.json()` /
// `res.text()` unguarded: a server that stalls after headers stalled
// `barkpark generate` for minutes with no diagnostic, and an injected
// `fetchImpl` that never settled left the promise PENDING with no bound at all.
// Every arm below asserts the rejection MESSAGE and a wall-clock bound — a
// probe that only checks "something was thrown" passes whether or not the fix
// regressed.

import { describe, expect, it } from 'vitest'
import { fetchSchema } from '../src/fetch-schema'

const BOUND_MS = 300

/** A minimal healthy envelope the zod schema accepts. */
const HEALTHY_ENVELOPE = {
  _schemaVersion: 2,
  datasetSchemaHash: 'deadbeefdeadbeef',
  schemas: [{ name: 'post', fields: [] }],
}

function elapsed(from: number): number {
  return Date.now() - from
}

describe('fetchSchema — deadline', () => {
  it('rejects a never-settling fetchImpl with the timeout message inside the bound', async () => {
    const neverSettles: typeof fetch = () => new Promise<Response>(() => {})
    const startedAt = Date.now()

    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: 'https://api.example.test',
        token: 't',
        fetchImpl: neverSettles,
        timeoutMs: BOUND_MS,
      }),
    ).rejects.toThrow(
      `Schema fetch timed out after ${BOUND_MS}ms for https://api.example.test/v1/schemas/production`,
    )

    expect(elapsed(startedAt)).toBeLessThan(BOUND_MS * 6)
  })

  it('rejects when headers arrive but the JSON body read never settles', async () => {
    const stalledBody: typeof fetch = () =>
      Promise.resolve({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: () => new Promise<unknown>(() => {}),
        text: () => new Promise<string>(() => {}),
      } as unknown as Response)
    const startedAt = Date.now()

    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: 'https://api.example.test',
        token: 't',
        fetchImpl: stalledBody,
        timeoutMs: BOUND_MS,
      }),
    ).rejects.toThrow(
      `Schema fetch timed out after ${BOUND_MS}ms for https://api.example.test/v1/schemas/production`,
    )

    expect(elapsed(startedAt)).toBeLessThan(BOUND_MS * 6)
  })

  it('rejects when a non-2xx error-body read never settles', async () => {
    const stalledErrorBody: typeof fetch = () =>
      Promise.resolve({
        ok: false,
        status: 500,
        statusText: 'Internal Server Error',
        json: () => new Promise<unknown>(() => {}),
        text: () => new Promise<string>(() => {}),
      } as unknown as Response)
    const startedAt = Date.now()

    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: 'https://api.example.test',
        token: 't',
        fetchImpl: stalledErrorBody,
        timeoutMs: BOUND_MS,
      }),
    ).rejects.toThrow(
      `Schema fetch timed out after ${BOUND_MS}ms for https://api.example.test/v1/schemas/production`,
    )

    expect(elapsed(startedAt)).toBeLessThan(BOUND_MS * 6)
  })

  it('still resolves a healthy envelope well inside the deadline', async () => {
    const healthy: typeof fetch = () =>
      Promise.resolve({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: () => Promise.resolve(HEALTHY_ENVELOPE),
        text: () => Promise.resolve(JSON.stringify(HEALTHY_ENVELOPE)),
      } as unknown as Response)
    const startedAt = Date.now()

    const envelope = await fetchSchema({
      dataset: 'production',
      apiUrl: 'https://api.example.test',
      token: 't',
      fetchImpl: healthy,
      timeoutMs: BOUND_MS,
    })

    expect(envelope.datasetSchemaHash).toBe('deadbeefdeadbeef')
    expect(elapsed(startedAt)).toBeLessThan(BOUND_MS)
  })

  it('keeps the non-2xx error message when the error body reads normally', async () => {
    const failing: typeof fetch = () =>
      Promise.resolve({
        ok: false,
        status: 404,
        statusText: 'Not Found',
        json: () => Promise.resolve({}),
        text: () => Promise.resolve('no such dataset'),
      } as unknown as Response)

    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: 'https://api.example.test',
        token: 't',
        fetchImpl: failing,
        timeoutMs: BOUND_MS,
      }),
    ).rejects.toThrow(
      'Schema fetch 404 Not Found for https://api.example.test/v1/schemas/production: no such dataset',
    )
  })

  it('timeoutMs: 0 disables the deadline — a stalled body stays pending past the bound', async () => {
    const stalledBody: typeof fetch = () =>
      Promise.resolve({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: () => new Promise<unknown>(() => {}),
        text: () => new Promise<string>(() => {}),
      } as unknown as Response)

    const settled = fetchSchema({
      dataset: 'production',
      apiUrl: 'https://api.example.test',
      token: 't',
      fetchImpl: stalledBody,
      timeoutMs: 0,
    }).then(
      () => 'resolved',
      () => 'rejected',
    )

    const outcome = await Promise.race([
      settled,
      new Promise<string>((resolve) => setTimeout(() => resolve('pending'), BOUND_MS * 3)),
    ])

    expect(outcome).toBe('pending')
  })

  it('defaults to a 30s deadline when timeoutMs is omitted', async () => {
    // The default is asserted structurally: with no timeoutMs, a stalled body is
    // still pending well past the short bound (it is bounded at 30_000ms, the
    // `@barkpark/core` read default — not at BOUND_MS, and not never).
    const stalledBody: typeof fetch = () =>
      Promise.resolve({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: () => new Promise<unknown>(() => {}),
        text: () => new Promise<string>(() => {}),
      } as unknown as Response)

    const settled = fetchSchema({
      dataset: 'production',
      apiUrl: 'https://api.example.test',
      token: 't',
      fetchImpl: stalledBody,
    }).then(
      () => 'resolved',
      (err: Error) => err.message,
    )

    const outcome = await Promise.race([
      settled,
      new Promise<string>((resolve) => setTimeout(() => resolve('pending'), BOUND_MS)),
    ])

    expect(outcome).toBe('pending')
  })
})

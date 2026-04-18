// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createHash } from 'node:crypto'

/**
 * Serialize a value to canonical JSON: keys sorted recursively, no
 * whitespace, `JSON.stringify` rules for scalars. Produces identical output
 * for values that differ only in key order — suitable for stable hashing.
 *
 * `undefined` object properties are elided to match `JSON.stringify`.
 */
export function canonicalJson(value: unknown): string {
  if (value === undefined) return 'null'
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value)
  }
  if (Array.isArray(value)) {
    return '[' + value.map((v) => canonicalJson(v)).join(',') + ']'
  }
  const obj = value as Record<string, unknown>
  const keys = Object.keys(obj)
    .filter((k) => obj[k] !== undefined)
    .sort()
  const parts = keys.map((k) => JSON.stringify(k) + ':' + canonicalJson(obj[k]))
  return '{' + parts.join(',') + '}'
}

/**
 * SHA-256 hex digest over the canonical JSON serialization of `value`.
 * Same input (modulo key order) → same digest, regardless of the enclosing
 * host's `JSON.stringify` iteration order.
 */
export function sha256Canonical(value: unknown): string {
  return createHash('sha256').update(canonicalJson(value)).digest('hex')
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type {
  DocsBuilder,
  FilterOp,
  FilterValue,
  OrderSpec,
  BarkparkDocument,
} from './types'
import { BarkparkValidationError } from './errors'

export interface FilterExpression {
  field: string
  op: FilterOp
  value: FilterValue
}

export interface BuilderState {
  filters: FilterExpression[]
  order?: OrderSpec
  limit?: number
  offset?: number
}

const VALID_OPS: readonly FilterOp[] = ['eq', 'in', 'contains', 'gt', 'gte', 'lt', 'lte']

export function makeFilterExpression(
  field: string,
  op: FilterOp,
  value: FilterValue,
): FilterExpression {
  if (typeof field !== 'string' || field.length === 0) {
    throw new BarkparkValidationError('filter field must be a non-empty string', { field: 'field' })
  }
  if (!VALID_OPS.includes(op)) {
    throw new BarkparkValidationError(`unknown filter op: ${op}`, {
      field: 'op',
      issues: [{ op, allowed: VALID_OPS }],
    })
  }
  if (op === 'in' && !Array.isArray(value)) {
    throw new BarkparkValidationError(`op 'in' requires array value`, { field: 'value' })
  }
  if (op !== 'in' && Array.isArray(value)) {
    throw new BarkparkValidationError(`op '${op}' does not accept array`, { field: 'value' })
  }
  return { field, op, value }
}

/**
 * PURE factory — does NOT hit the network. Returns a builder over BuilderState.
 * The builder mutates its own internal state; `.where(...).order(...)` chains
 * return the same instance (cheap, matches single-chain usage in the client).
 */
export function createDocsBuilder<T = BarkparkDocument>(
  executor: (state: BuilderState) => Promise<T[]>,
): DocsBuilder<T> {
  const state: BuilderState = { filters: [] }

  const b: DocsBuilder<T> = {
    where(field, op, value) {
      state.filters.push(makeFilterExpression(field, op, value))
      return b
    },
    order(spec) {
      if (!/^(_updatedAt|_createdAt):(asc|desc)$/.test(spec)) {
        throw new BarkparkValidationError(`invalid order spec: ${spec}`, { field: 'order' })
      }
      state.order = spec
      return b
    },
    limit(n) {
      if (!Number.isInteger(n) || n < 1 || n > 1000) {
        throw new BarkparkValidationError(`limit must be an integer 1..1000`, { field: 'limit' })
      }
      state.limit = n
      return b
    },
    offset(n) {
      if (!Number.isInteger(n) || n < 0) {
        throw new BarkparkValidationError(`offset must be a non-negative integer`, {
          field: 'offset',
        })
      }
      state.offset = n
      return b
    },
    async find() {
      return executor(state)
    },
    async findOne() {
      const old = state.limit
      state.limit = 1
      try {
        const [doc] = await executor(state)
        return doc ?? null
      } finally {
        if (old === undefined) delete state.limit
        else state.limit = old
      }
    },
  }
  return b
}

/**
 * Encode BuilderState as a Phoenix-compatible query string.
 *
 * Phoenix parser (api/lib/barkpark_web/controllers/query_controller.ex:178-191
 * + api/lib/barkpark/content.ex:113-158) expects nested-map encoding:
 *
 *   filter[<field>][<op>]=<value>      // specific op
 *   filter[<field>]=<value>            // shorthand: op defaults to 'eq'
 *
 * For `in`, the value is a comma-joined string; Phoenix splits it
 * (normalize_filter_op/1 in query_controller.ex:187-189).
 *
 * NOTE: multiple filters on the same (field, op) collapse to the last-written
 * value because Phoenix decodes nested params into a map. Callers wanting
 * range-on-same-field must combine ops (e.g. gt + lt, which keep distinct keys).
 */
export function buildQueryString(state: BuilderState): string {
  const params = new URLSearchParams()

  for (const f of state.filters) {
    const key = `filter[${f.field}][${f.op}]`
    let encoded: string
    if (Array.isArray(f.value)) {
      encoded = f.value.map((v) => String(v)).join(',')
    } else if (f.value === null) {
      encoded = ''
    } else {
      encoded = String(f.value)
    }
    params.append(key, encoded)
  }

  if (state.order) params.set('order', state.order)
  if (state.limit !== undefined) params.set('limit', String(state.limit))
  if (state.offset !== undefined) params.set('offset', String(state.offset))

  return params.toString()
}

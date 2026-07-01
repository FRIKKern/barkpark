// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type {
  DocsBuilder,
  FilterOp,
  FilterValue,
  OrderSpec,
  BarkparkDocument,
  QueryPage,
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
  expand?: string
  select?: string
}

const VALID_OPS: readonly FilterOp[] = [
  'eq',
  'neq',
  'in',
  'nin',
  'has',
  'contains',
  'startsWith',
  'endsWith',
  'gt',
  'gte',
  'lt',
  'lte',
]
// Ops whose value is a list of candidates rather than a scalar.
const ARRAY_OPS: readonly FilterOp[] = ['in', 'nin']

export function makeFilterExpression(
  field: string,
  op: FilterOp,
  value: FilterValue,
): FilterExpression {
  if (typeof field !== 'string' || field.length === 0) {
    throw new BarkparkValidationError('filter field must be a non-empty string', { field: 'field' })
  }
  if (!VALID_OPS.includes(op)) {
    throw new BarkparkValidationError(
      `unknown filter op: ${op} — expected one of ${VALID_OPS.join(', ')}`,
      { field: 'op', issues: [{ op, allowed: VALID_OPS }] },
    )
  }
  if (ARRAY_OPS.includes(op) && !Array.isArray(value)) {
    throw new BarkparkValidationError(`op '${op}' requires an array value`, { field: 'value' })
  }
  if (!ARRAY_OPS.includes(op) && Array.isArray(value)) {
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
  countExecutor?: (state: BuilderState) => Promise<number>,
  pageExecutor?: (state: BuilderState) => Promise<QueryPage<T>>,
): DocsBuilder<T> {
  const state: BuilderState = { filters: [] }

  const b: DocsBuilder<T> = {
    where(field, op, value) {
      state.filters.push(makeFilterExpression(field, op, value))
      return b
    },
    // Semantic sugar over where() — each reuses makeFilterExpression's validation.
    eq(field, value) {
      return b.where(field, 'eq', value)
    },
    neq(field, value) {
      return b.where(field, 'neq', value)
    },
    in(field, values) {
      return b.where(field, 'in', values)
    },
    nin(field, values) {
      return b.where(field, 'nin', values)
    },
    has(field, value) {
      return b.where(field, 'has', value)
    },
    contains(field, value) {
      return b.where(field, 'contains', value)
    },
    startsWith(field, value) {
      return b.where(field, 'startsWith', value)
    },
    endsWith(field, value) {
      return b.where(field, 'endsWith', value)
    },
    gt(field, value) {
      return b.where(field, 'gt', value)
    },
    gte(field, value) {
      return b.where(field, 'gte', value)
    },
    lt(field, value) {
      return b.where(field, 'lt', value)
    },
    lte(field, value) {
      return b.where(field, 'lte', value)
    },
    order(spec) {
      // Field is a top-level name or a dot-path (`price.amount`) — the server
      // orders nested paths the same as top-level, numeric-aware.
      if (
        !/^(_updatedAt|_createdAt|[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)*):(asc|desc)$/.test(spec)
      ) {
        throw new BarkparkValidationError(
          `invalid order spec: ${spec} — expected <field>:asc|desc (e.g. title:asc, price.amount:desc)`,
          { field: 'order' },
        )
      }
      // Each .order() call appends a sort key (comma-joined), so chaining sorts
      // by the first field, then the second as a tiebreak, etc. (multi-field sort).
      state.order = state.order ? `${state.order},${spec}` : spec
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
    expand(fields) {
      const list = Array.isArray(fields) ? fields : [fields]
      const cleaned = list.map((f) => String(f).trim()).filter((f) => f.length > 0)
      if (cleaned.length === 0) {
        throw new BarkparkValidationError(`expand requires at least one field name`, {
          field: 'expand',
        })
      }
      state.expand = cleaned.join(',')
      return b
    },
    select(fields) {
      const list = Array.isArray(fields) ? fields : [fields]
      const cleaned = list.map((f) => String(f).trim()).filter((f) => f.length > 0)
      if (cleaned.length === 0) {
        throw new BarkparkValidationError(`select requires at least one field name`, {
          field: 'select',
        })
      }
      state.select = cleaned.join(',')
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
    async count() {
      if (!countExecutor) {
        throw new BarkparkValidationError('count() requires a client-backed builder', {
          field: 'count',
        })
      }
      return countExecutor(state)
    },
    async findPage() {
      if (!pageExecutor) {
        throw new BarkparkValidationError('findPage() requires a client-backed builder', {
          field: 'findPage',
        })
      }
      return pageExecutor(state)
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
    // `eq(field, null)` / `neq(field, null)` are null/absence checks, not a match
    // against the empty string — map them to the server's `is` op (IS NULL /
    // IS NOT NULL) so they actually find documents missing the field.
    if (f.value === null && (f.op === 'eq' || f.op === 'neq')) {
      params.append(`filter[${f.field}][is]`, f.op === 'eq' ? 'null' : 'notnull')
      continue
    }
    const key = `filter[${f.field}][${f.op}]`
    let encoded: string
    if (Array.isArray(f.value)) {
      encoded = f.value.map((v) => (v instanceof Date ? v.toISOString() : String(v))).join(',')
    } else if (f.value === null) {
      encoded = ''
    } else {
      encoded = f.value instanceof Date ? f.value.toISOString() : String(f.value)
    }
    params.append(key, encoded)
  }

  if (state.order) params.set('order', state.order)
  if (state.limit !== undefined) params.set('limit', String(state.limit))
  if (state.offset !== undefined) params.set('offset', String(state.offset))
  if (state.expand) params.set('expand', state.expand)
  if (state.select) params.set('fields', state.select)

  return params.toString()
}

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
  'hasStrong',
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

/**
 * Eagerly validate `limit`/`offset` for the ad-hoc read paths (search + media
 * list/search builders) that set them raw on a query string. Mirrors the
 * DocsBuilder `.limit()`/`.offset()` guards but WITHOUT the 1..1000 upper cap —
 * search/media accept larger server-side page sizes, so capping here would break
 * currently-working calls. Throws a self-explaining `BarkparkValidationError`
 * instead of shipping a garbage query string (`offset:-5`, `limit:NaN`) that the
 * server answers with an opaque 400/500.
 */
export function assertPaging(limit?: number, offset?: number): void {
  if (limit !== undefined && (!Number.isInteger(limit) || limit < 1)) {
    throw new BarkparkValidationError('limit must be a positive integer', { field: 'limit' })
  }
  if (offset !== undefined && (!Number.isInteger(offset) || offset < 0)) {
    throw new BarkparkValidationError('offset must be a non-negative integer', { field: 'offset' })
  }
}

export function makeFilterExpression(
  field: string,
  op: FilterOp,
  value: FilterValue,
): FilterExpression {
  if (typeof field !== 'string' || field.length === 0) {
    throw new BarkparkValidationError('filter field must be a non-empty string', { field: 'field' })
  }
  // `op` is a parameter and never reassigned, so this membership test is
  // loop-invariant and was evaluated five times below with the same answer.
  // Hoisted verbatim — every guard keeps its exact condition, and the saving
  // pays for the truncation fields findPage now carries (js/CLAUDE.md
  // "Bundle budget").
  const arrayOp = ARRAY_OPS.includes(op)
  if (!VALID_OPS.includes(op)) {
    throw new BarkparkValidationError(
      `unknown filter op: ${op} — expected one of ${VALID_OPS.join(', ')}`,
      { field: 'op', issues: [{ op, allowed: VALID_OPS }] },
    )
  }
  if (arrayOp && !Array.isArray(value)) {
    throw new BarkparkValidationError(`op '${op}' requires an array value`, { field: 'value' })
  }
  if (arrayOp && Array.isArray(value) && value.length === 0) {
    // `filter[field][in]=` (empty candidate list) is an ambiguous match-nothing
    // query — almost always an upstream bug (an empty variable slipped through).
    // Fail closed like every peer guard rather than ship a silent no-match.
    throw new BarkparkValidationError(
      `op '${op}' requires a non-empty array (an empty value list matches nothing — pass at least one candidate or drop the filter)`,
      { field: 'value' },
    )
  }
  if (arrayOp && Array.isArray(value)) {
    // buildQueryString joins candidates with ',' (the wire format the server
    // splits on), so a comma inside a value would silently split into extra
    // candidates — `.in('sku', ['A,B'])` would query A OR B, not the literal
    // 'A,B'. Fail closed like normalizeFieldList's sibling comma guard.
    // Dates are exempt: they serialize to ISO strings, which never contain ','.
    const bad = value.find((v) => !(v instanceof Date) && String(v).includes(','))
    if (bad !== undefined) {
      throw new BarkparkValidationError(
        `op '${op}' candidate values cannot contain a comma (the wire format is comma-separated, so '${String(bad)}' would silently split into multiple candidates)`,
        { field: 'value' },
      )
    }
  }
  if (!arrayOp && Array.isArray(value)) {
    throw new BarkparkValidationError(`op '${op}' does not accept array`, { field: 'value' })
  }
  if (
    !arrayOp &&
    value !== null &&
    typeof value === 'object' &&
    !(value instanceof Date)
  ) {
    // A non-Date object value has no meaningful filter wire form: buildQueryString
    // would `String(value)` it to the opaque '[object Object]' (so
    // `eq('author', {_ref:'x'})` becomes `filter[author][eq]=[object Object]`),
    // which the server answers with a bewildering 400. Fail closed like the peer
    // guards. Dates are exempt (they serialize to ISO); null is a valid absence
    // check handled downstream.
    throw new BarkparkValidationError(
      `op '${op}' requires a scalar value, not an object — pass a primitive (e.g. the reference's id string)`,
      { field: 'value' },
    )
  }
  return { field, op, value }
}

/**
 * Normalize a projection/expand field list (a single name or an array) into the
 * comma-joined query-param value the server expects. Coerces to an array, trims
 * each name, and drops empties — so `['title', '', 'slug']` becomes `title,slug`
 * instead of the phantom-field `title,,slug`. Throws a self-explaining
 * `BarkparkValidationError` when the list is empty after cleaning, or when any
 * name itself contains a `,` (which would silently split into extra projected
 * fields — a corrupted / over-broad projection). `label` names the caller field
 * ('expand'/'fields') for the error. Shared by the builder's expand()/select()
 * and getDoc's expand/fields so both fail closed the same way.
 */
export function normalizeFieldList(input: string | string[], label: string): string {
  const list = Array.isArray(input) ? input : [input]
  const cleaned = list.map((f) => String(f).trim()).filter((f) => f.length > 0)
  if (cleaned.length === 0) {
    throw new BarkparkValidationError(`${label} requires at least one field name`, { field: label })
  }
  const bad = cleaned.find((f) => f.includes(','))
  if (bad !== undefined) {
    throw new BarkparkValidationError(
      `${label} field name cannot contain a comma: ${JSON.stringify(bad)} (pass separate fields as an array)`,
      { field: label },
    )
  }
  return cleaned.join(',')
}

/**
 * Reject any array entry containing a `,` before it's `.join(',')`-ed into a
 * CSV query param (search `types`, graph `kinds`/`sources`, media `tags`/`facets`).
 * A comma inside a value would silently split into extra values on the wire — an
 * over-broad query, the exact corruption `normalizeFieldList`/the `in`/`nin` guard
 * already fail closed on. `field` names the caller param for the error. Array
 * entries only: a caller passing a pre-joined `'a,b'` string may intend CSV.
 */
export function assertNoCommaEntries(values: readonly string[], field: string): void {
  const bad = values.find((v) => v.includes(','))
  if (bad !== undefined) {
    throw new BarkparkValidationError(
      `${field} value cannot contain a comma: ${JSON.stringify(bad)} (the wire format is comma-separated, so it would silently split into multiple values)`,
      { field },
    )
  }
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
    hasStrong(field, value) {
      return b.where(field, 'hasStrong', value)
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
      // Shared normalizer: trims, drops empties, and rejects an empty list or a
      // comma-in-name (which would corrupt the comma-joined `expand` param).
      state.expand = normalizeFieldList(fields, 'expand')
      return b
    },
    select(fields) {
      // See expand(): same normalizer builds the `fields` projection param.
      state.select = normalizeFieldList(fields, 'select')
      return b
    },
    async find() {
      return executor(state)
    },
    async findOne() {
      // Derive a limit:1 state instead of mutating shared `state` — the find
      // executor reads `state` synchronously, so a mutate/restore here would
      // leak limit=1 into a concurrent .find() (Promise.all). Mirrors the
      // count/page executors, which already pass a derived `{...state}`.
      const [doc] = await executor({ ...state, limit: 1 })
      return doc ?? null
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
 * Phoenix parser (normalize_filter_map/1 in query_controller.ex
 * + Barkpark.Content list-query filters) expects nested-map encoding:
 *
 *   filter[<field>][<op>]=<value>      // specific op
 *   filter[<field>]=<value>            // shorthand: op defaults to 'eq'
 *
 * For `in`, the value is a comma-joined string; Phoenix splits it
 * (normalize_filter_op/1 in query_controller.ex).
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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * Codegen schema version stamped into the generated file header.
 * Bump when the emission shape changes in a way consumers must re-generate.
 */
export const CODEGEN_VERSION = '0.1.0'

/**
 * Sentinel document type emitted when no schemas are present so the
 * "did you run `barkpark codegen`?" hint surfaces in compiler errors.
 */
export const EMPTY_MAP_SENTINEL = '"__run_barkpark_codegen_first__"'

/**
 * The filter-op matrix block (ADR-006 / P1-b). Verbatim port of Spike B
 * `codegen.ts` L96–116. Consumers of the generated file rely on
 * `FieldKind`, `OpsForKind`, `FilterField`, and `AcceptedValue` to type
 * the `.where()` call-site.
 */
export const PRELUDE = `// ---- Filter-op matrix (from ADR-006 / P1-b) --------------------------------
export type FieldKind = 'string' | 'number' | 'date' | 'boolean' | 'slug' | 'reference';
export type OpsForKind = {
  string: 'eq' | 'in' | 'ne';
  number: 'eq' | 'ne' | 'gt' | 'lt' | 'gte' | 'lte' | 'in';
  date: 'gt' | 'lt' | 'gte' | 'lte';
  boolean: 'eq';
  slug: 'eq' | 'in';
  reference: 'eq';
};

// Shape of per-document filter descriptor: each field → { kind, value }
type FilterField<K extends FieldKind, V> = { kind: K; value: V };

// Narrow: given a filter descriptor and an op, what is the accepted value?
type AcceptedValue<F, O extends string> =
  F extends FilterField<infer _K, infer V>
    ? O extends 'in' ? readonly V[] : V
    : never;
`

/**
 * The typed-client runtime block. Verbatim port of Spike B `codegen.ts`
 * L184–249. Inlined into the generated file so consumers don't need
 * @barkpark/core at runtime — the generated file is fully self-contained
 * for the client-builder surface.
 */
export const TYPED_CLIENT_RUNTIME = `// ---- Typed client -----------------------------------------------------------

export interface BaseClient {
  fetch(type: string, params: { filters: Array<[string, string, unknown]>; orders: Array<[string, 'asc' | 'desc']>; limit?: number; offset?: number }): Promise<unknown>;
}

export interface TypedBuilder<T extends DocumentType> {
  where<
    F extends keyof FilterMap[T],
    K extends FilterMap[T][F] extends FilterField<infer K0, infer _V> ? K0 : never,
    O extends OpsForKind[K & FieldKind],
  >(
    field: F,
    op: O,
    value: AcceptedValue<FilterMap[T][F], O & string>,
  ): TypedBuilder<T>;

  order<F extends keyof FilterMap[T]>(field: F, direction?: 'asc' | 'desc'): TypedBuilder<T>;
  limit(n: number): TypedBuilder<T>;
  offset(n: number): TypedBuilder<T>;
  find(): Promise<DocumentMap[T][]>;
  findOne(): Promise<DocumentMap[T] | null>;
}

export interface TypedClient {
  docs<T extends DocumentType>(type: T): TypedBuilder<T>;
  doc<T extends DocumentType>(type: T, id: string): Promise<DocumentMap[T] | null>;
}

export function typedClient(client: BaseClient): TypedClient {
  function makeBuilder<T extends DocumentType>(type: T): TypedBuilder<T> {
    const filters: Array<[string, string, unknown]> = [];
    const orders: Array<[string, 'asc' | 'desc']> = [];
    let _limit: number | undefined;
    let _offset: number | undefined;
    const builder: TypedBuilder<T> = {
      where(field, op, value) {
        filters.push([field as string, op as string, value as unknown]);
        return builder;
      },
      order(field, direction = 'asc') {
        orders.push([field as string, direction]);
        return builder;
      },
      limit(n) { _limit = n; return builder; },
      offset(n) { _offset = n; return builder; },
      async find() {
        const res = await client.fetch(type as string, { filters, orders, limit: _limit, offset: _offset });
        return res as DocumentMap[T][];
      },
      async findOne() {
        const res = await client.fetch(type as string, { filters, orders, limit: 1, offset: _offset });
        const arr = res as DocumentMap[T][];
        return arr[0] ?? null;
      },
    };
    return builder;
  }
  return {
    docs(type) { return makeBuilder(type); },
    async doc(type, _id) {
      return null;
    },
  };
}
`

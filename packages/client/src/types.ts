/**
 * Reserved envelope keys emitted by Barkpark /v1. Any document returned by the
 * API is guaranteed to have these plus arbitrary user fields (typed via
 * generics on the Client).
 */
export interface DocumentEnvelope {
  _id: string
  _type: string
  _rev: string
  _draft: boolean
  _publishedId: string
  _createdAt: string
  _updatedAt: string
  [key: string]: unknown
}

export type Perspective = 'published' | 'drafts' | 'raw'

export type Order =
  | '_updatedAt:desc'
  | '_updatedAt:asc'
  | '_createdAt:desc'
  | '_createdAt:asc'

export interface QueryOptions {
  perspective?: Perspective
  limit?: number
  offset?: number
  order?: Order
  filter?: Record<string, string | number | boolean>
}

export interface QueryResponse<T extends DocumentEnvelope = DocumentEnvelope> {
  perspective: Perspective
  documents: T[]
  count: number
  limit: number
  offset: number
}

export type CreateInput = Record<string, unknown> & {
  _id?: string
  _type: string
  title?: string
}

export interface PatchOptions {
  set: Record<string, unknown>
  ifRevisionID?: string
}

export type Mutation =
  | { create: CreateInput }
  | { createOrReplace: CreateInput }
  | { createIfNotExists: CreateInput }
  | { patch: { id: string; type: string; set: Record<string, unknown>; ifRevisionID?: string } }
  | { publish: { id: string; type: string } }
  | { unpublish: { id: string; type: string } }
  | { discardDraft: { id: string; type: string } }
  | { delete: { id: string; type: string } }

export interface MutationResult<T extends DocumentEnvelope = DocumentEnvelope> {
  id: string
  operation:
    | 'create'
    | 'createOrReplace'
    | 'update'
    | 'publish'
    | 'unpublish'
    | 'discardDraft'
    | 'delete'
    | 'noop'
  document: T
}

export interface MutateResponse<T extends DocumentEnvelope = DocumentEnvelope> {
  transactionId: string
  results: MutationResult<T>[]
}

export interface ErrorEnvelope {
  code:
    | 'not_found'
    | 'unauthorized'
    | 'forbidden'
    | 'schema_unknown'
    | 'rev_mismatch'
    | 'conflict'
    | 'malformed'
    | 'validation_failed'
    | 'internal_error'
  message: string
  details?: Record<string, string[]>
}

export interface SchemaDefinition {
  name: string
  title: string
  icon?: string | null
  visibility: 'public' | 'private'
  fields: Array<Record<string, unknown>>
}

export interface SchemasResponse {
  _schemaVersion: 1
  schemas: SchemaDefinition[]
}

export interface SchemaShowResponse {
  _schemaVersion: 1
  schema: SchemaDefinition
}

export interface ClientConfig {
  /** Base URL of the Barkpark instance, e.g. http://89.167.28.206 */
  projectUrl: string
  /** Dataset name, e.g. "production" */
  dataset: string
  /** Bearer token for authenticated endpoints; optional for public reads */
  token?: string
  /** Default perspective for reads (default: "published") */
  perspective?: Perspective
  /** Custom fetch implementation (for testing / SSR) */
  fetch?: typeof fetch
}

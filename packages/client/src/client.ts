import { BarkparkError } from './errors.js'
import type {
  ClientConfig,
  CreateInput,
  DocumentEnvelope,
  MutateResponse,
  Mutation,
  PatchOptions,
  Perspective,
  QueryOptions,
  QueryResponse,
  SchemaShowResponse,
  SchemasResponse,
} from './types.js'

/**
 * Framework-agnostic client for the Barkpark v1 HTTP API.
 *
 * See docs/api-v1.md for the full HTTP contract. This client is a thin,
 * strongly-typed wrapper — no caching, no batching, no runtime magic beyond
 * per-instance config.
 *
 * Clients are immutable: `withPerspective` / `withDataset` / `withToken`
 * return a fresh instance sharing the same fetch function.
 */
export class Client {
  private readonly projectUrl: string
  private readonly dataset: string
  private readonly token: string | undefined
  private readonly perspective: Perspective
  private readonly fetchImpl: typeof fetch

  constructor(config: ClientConfig) {
    if (!config.projectUrl) throw new Error('@barkpark/client: projectUrl is required')
    if (!config.dataset) throw new Error('@barkpark/client: dataset is required')

    this.projectUrl = config.projectUrl.replace(/\/+$/, '')
    this.dataset = config.dataset
    this.token = config.token
    this.perspective = config.perspective ?? 'published'
    this.fetchImpl = config.fetch ?? globalThis.fetch
    if (!this.fetchImpl) {
      throw new Error(
        '@barkpark/client: no global fetch available. Pass a fetch implementation in config.fetch',
      )
    }
  }

  // ── derivation ────────────────────────────────────────────────────────

  withPerspective(perspective: Perspective): Client {
    return new Client({ ...this.config(), perspective })
  }

  withDataset(dataset: string): Client {
    return new Client({ ...this.config(), dataset })
  }

  withToken(token: string | undefined): Client {
    return new Client({ ...this.config(), token })
  }

  private config(): ClientConfig {
    return {
      projectUrl: this.projectUrl,
      dataset: this.dataset,
      token: this.token,
      perspective: this.perspective,
      fetch: this.fetchImpl,
    }
  }

  // ── reads ─────────────────────────────────────────────────────────────

  async query<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    options: QueryOptions = {},
  ): Promise<QueryResponse<T>> {
    const params = new URLSearchParams()
    params.set('perspective', options.perspective ?? this.perspective)
    if (options.limit !== undefined) params.set('limit', String(options.limit))
    if (options.offset !== undefined) params.set('offset', String(options.offset))
    if (options.order) params.set('order', options.order)
    if (options.filter) {
      for (const [key, value] of Object.entries(options.filter)) {
        params.set(`filter[${key}]`, String(value))
      }
    }

    const url = `${this.projectUrl}/v1/data/query/${encodeURIComponent(
      this.dataset,
    )}/${encodeURIComponent(type)}?${params.toString()}`

    return this.request<QueryResponse<T>>(url, { method: 'GET' })
  }

  async getDocument<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    id: string,
  ): Promise<T> {
    const url = `${this.projectUrl}/v1/data/doc/${encodeURIComponent(
      this.dataset,
    )}/${encodeURIComponent(type)}/${encodeURIComponent(id)}`
    return this.request<T>(url, { method: 'GET' })
  }

  async schemas(): Promise<SchemasResponse> {
    const url = `${this.projectUrl}/v1/schemas/${encodeURIComponent(this.dataset)}`
    return this.request<SchemasResponse>(url, { method: 'GET', requireAuth: true })
  }

  async schema(name: string): Promise<SchemaShowResponse> {
    const url = `${this.projectUrl}/v1/schemas/${encodeURIComponent(
      this.dataset,
    )}/${encodeURIComponent(name)}`
    return this.request<SchemaShowResponse>(url, { method: 'GET', requireAuth: true })
  }

  // ── writes (single-shot convenience wrappers) ─────────────────────────

  async create<T extends DocumentEnvelope = DocumentEnvelope>(
    input: CreateInput,
  ): Promise<T> {
    const res = await this.mutate<T>([{ create: input }])
    return res.results[0]!.document
  }

  async createOrReplace<T extends DocumentEnvelope = DocumentEnvelope>(
    input: CreateInput,
  ): Promise<T> {
    const res = await this.mutate<T>([{ createOrReplace: input }])
    return res.results[0]!.document
  }

  async createIfNotExists<T extends DocumentEnvelope = DocumentEnvelope>(
    input: CreateInput,
  ): Promise<T> {
    const res = await this.mutate<T>([{ createIfNotExists: input }])
    return res.results[0]!.document
  }

  async patch<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    id: string,
    options: PatchOptions,
  ): Promise<T> {
    const res = await this.mutate<T>([
      {
        patch: {
          id,
          type,
          set: options.set,
          ...(options.ifRevisionID ? { ifRevisionID: options.ifRevisionID } : {}),
        },
      },
    ])
    return res.results[0]!.document
  }

  async publish<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    id: string,
  ): Promise<T> {
    const res = await this.mutate<T>([{ publish: { id, type } }])
    return res.results[0]!.document
  }

  async unpublish<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    id: string,
  ): Promise<T> {
    const res = await this.mutate<T>([{ unpublish: { id, type } }])
    return res.results[0]!.document
  }

  async discardDraft<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    id: string,
  ): Promise<T> {
    const res = await this.mutate<T>([{ discardDraft: { id, type } }])
    return res.results[0]!.document
  }

  async delete<T extends DocumentEnvelope = DocumentEnvelope>(
    type: string,
    id: string,
  ): Promise<T> {
    const res = await this.mutate<T>([{ delete: { id, type } }])
    return res.results[0]!.document
  }

  /**
   * Submit a batch of mutations atomically. Either all succeed or none do —
   * on failure the whole batch rolls back and a BarkparkError is thrown.
   */
  async mutate<T extends DocumentEnvelope = DocumentEnvelope>(
    mutations: Mutation[],
  ): Promise<MutateResponse<T>> {
    const url = `${this.projectUrl}/v1/data/mutate/${encodeURIComponent(this.dataset)}`
    return this.request<MutateResponse<T>>(url, {
      method: 'POST',
      body: JSON.stringify({ mutations }),
      requireAuth: true,
    })
  }

  // ── internal ──────────────────────────────────────────────────────────

  private async request<T>(
    url: string,
    options: { method: string; body?: string; requireAuth?: boolean },
  ): Promise<T> {
    const headers: Record<string, string> = {}
    if (options.body !== undefined) headers['content-type'] = 'application/json'
    if (this.token) headers['authorization'] = `Bearer ${this.token}`

    const response = await this.fetchImpl(url, {
      method: options.method,
      headers,
      body: options.body,
    })

    if (!response.ok) {
      throw await BarkparkError.fromResponse(response)
    }

    return (await response.json()) as T
  }
}

/** Create a Barkpark v1 client. */
export function createClient(config: ClientConfig): Client {
  return new Client(config)
}

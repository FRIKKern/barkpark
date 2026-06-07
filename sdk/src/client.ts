/**
 * BulldocsClient — the thin HTTP layer over the Bulldocs ingest endpoints.
 *
 *   publish(paper)            -> POST {baseURL}/v1/plugins/bulldocs/papers
 *   submitOps(slug, ops, …)   -> POST {baseURL}/v1/plugins/bulldocs/papers/{slug}/ops
 *
 * Both routes sit behind the RequireIngestToken plug; the token rides as a
 * Bearer header. submitOps sends the BATCH shape `{ops:[...], ifRev?}` in ONE
 * request (BulldocsIngestController.apply_op/2 detects the array-native "ops"
 * key and applies the batch atomically).
 *
 * A non-2xx response carries `{error:{code, message?}}`; we surface that as a
 * thrown `BulldocsError` carrying the code, status, and parsed body.
 */

import type { Paper, PublishBody } from "./paper.js";
import type { Op } from "./ops.js";

export interface BulldocsClientOptions {
  baseURL: string;
  ingestToken: string;
  /** Injectable for tests / mock servers. Defaults to global fetch (node 22). */
  fetch?: typeof fetch;
}

export interface PublishReceipt {
  ok: boolean;
  slug: string;
  rev: string;
  liveview_path: string;
}

export interface SubmitOpsReceipt {
  ok: boolean;
  slug: string;
  op_count: number;
  rev: number;
  block_ids: string[];
}

/** Thrown when the ingest returns a non-2xx `{error:{code}}` response. */
export class BulldocsError extends Error {
  readonly code: string;
  readonly status: number;
  readonly body: unknown;

  constructor(code: string, status: number, message: string, body: unknown) {
    super(message);
    this.name = "BulldocsError";
    this.code = code;
    this.status = status;
    this.body = body;
  }
}

const PAPERS_PATH = "/v1/plugins/bulldocs/papers";

export class BulldocsClient {
  private readonly baseURL: string;
  private readonly ingestToken: string;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: BulldocsClientOptions) {
    // Trim a single trailing slash so baseURL + path never doubles up.
    this.baseURL = opts.baseURL.replace(/\/$/, "");
    this.ingestToken = opts.ingestToken;
    this.fetchImpl = opts.fetch ?? globalThis.fetch;
    if (typeof this.fetchImpl !== "function") {
      throw new TypeError("BulldocsClient: no fetch available; pass opts.fetch");
    }
  }

  /** Publish a paper in ONE POST to /papers. */
  async publish(paper: Paper): Promise<PublishReceipt> {
    const body: PublishBody = paper.toJSON();
    return this.post<PublishReceipt>(`${this.baseURL}${PAPERS_PATH}`, body);
  }

  /**
   * Submit N block-ops to /papers/:slug/ops in ONE batch request. The wire body
   * is `{ops:[...], ifRev?}` — the server applies all ops atomically and returns
   * a minimal receipt. `ifRev` (when given) is an optimistic-concurrency guard;
   * a mismatch rejects the whole batch with a `precondition_failed` error.
   */
  async submitOps(
    slug: string,
    ops: Op[],
    opts: { ifRev?: number | string } = {},
  ): Promise<SubmitOpsReceipt> {
    const url = `${this.baseURL}${PAPERS_PATH}/${encodeURIComponent(slug)}/ops`;
    const body: { ops: Op[]; ifRev?: number | string } = { ops };
    if (opts.ifRev !== undefined) body.ifRev = opts.ifRev;
    return this.post<SubmitOpsReceipt>(url, body);
  }

  private async post<T>(url: string, body: unknown): Promise<T> {
    const res = await this.fetchImpl(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.ingestToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    const text = await res.text();
    let parsed: unknown = undefined;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = text;
      }
    }

    if (!res.ok) {
      const err = (parsed as { error?: { code?: string; message?: string } } | undefined)?.error;
      const code = err?.code ?? "http_error";
      const message = err?.message ?? `request failed with status ${res.status}`;
      throw new BulldocsError(code, res.status, message, parsed);
    }

    return parsed as T;
  }
}

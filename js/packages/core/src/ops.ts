// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Block-op writes: one PortableDoc op on any document type, and the Bulldocs
// paper routes (publish, fenced op batch, proposals).
//
// A stale revision fence answers 412 `precondition_failed`. The transport maps
// that to `BarkparkConflictError` with `status: 412` and
// `serverCode: 'precondition_failed'`, the same error a stale `ifMatch` on
// `/v1/data/mutate` raises. Nothing is written when it is thrown.
//
// The Bulldocs routes have no `/w/:ws/p/:proj` mount. A scoped client names its
// workspace and project in the X-Barkpark-Workspace / X-Barkpark-Project
// headers, which the ingest controller reads when the body does not name them.

import type {
  BarkparkClientConfig,
  CommitOptions,
  DocOpResult,
  PaperOp,
  PaperOpsOptions,
  PaperOpsReceipt,
  PaperProposal,
  PaperProposalReceipt,
  PaperPublishInput,
  PaperPublishReceipt,
} from './types'
import { request } from './transport'
import { scopePrefix, dataPath } from './scope'
import { commitOptions } from './publish'
import { assertSegment } from './util/guards'

type WriteOptions = CommitOptions & { signal?: AbortSignal }

// Input checks stop at the path: every segment is guarded so `..` cannot
// retarget the request. Body shape (op verbs, ifRev, blocks, provenance) is
// validated by the server, which refuses a bad body with 4xx and writes
// nothing. Repeating those checks here would cost bundle bytes for no safety.
//
// `paper` marks a Bulldocs route: those read the dataset from the body and the
// scope from headers.
async function post<T>(
  config: BarkparkClientConfig,
  path: string,
  body: Record<string, unknown>,
  opts: WriteOptions | undefined,
  paper?: boolean,
): Promise<T> {
  const c = commitOptions(opts)
  if (paper) {
    body = { ...body, dataset: config.dataset }
    if (scopePrefix(config)) {
      c.headers['X-Barkpark-Workspace'] = config.workspace as string
      c.headers['X-Barkpark-Project'] = config.project as string
    }
  }
  const { data } = await request<T & { result?: T }>(config, path, {
    method: 'POST',
    kind: 'write',
    body,
    ...c,
    ...(opts?.signal !== undefined ? { signal: opts.signal } : {}),
  })
  return data.result ?? data
}

function paperPath(slug: string, suffix: string): string {
  assertSegment(slug, 'slug')
  return `/v1/plugins/bulldocs/papers/${encodeURIComponent(slug)}/${suffix}`
}

/**
 * Apply one PortableDoc block op to a document
 * (`POST /v1/data/doc/:dataset/:type/:id/ops`). `ifRev` is the document's
 * current `_rev` and is required. When `drafts.<id>` exists the op edits the
 * draft. Papers and sessions are refused with 422; use {@link applyPaperOps}.
 *
 * @throws BarkparkConflictError (status 412) when `ifRev` is stale.
 *   `err.serverDoc.rev` carries the current rev.
 */
export async function applyDocOp(
  config: BarkparkClientConfig,
  type: string,
  id: string,
  op: PaperOp,
  ifRev: string,
  opts?: WriteOptions,
): Promise<DocOpResult> {
  assertSegment(type, 'type')
  assertSegment(id, 'id')
  return post(
    config,
    `${dataPath(config, 'doc')}/${encodeURIComponent(type)}/${encodeURIComponent(id)}/ops`,
    { op, ifRev },
    opts,
  )
}

/**
 * Publish (create or replace) a paper from portable-doc blocks
 * (`POST /v1/plugins/bulldocs/papers`). This route has no revision fence; edit
 * an existing paper with {@link applyPaperOps} to guard against lost updates.
 * A body carrying `ifRev` is refused with 400.
 */
export async function publishPaper(
  config: BarkparkClientConfig,
  paper: PaperPublishInput,
  opts?: WriteOptions,
): Promise<PaperPublishReceipt> {
  assertSegment(paper?.slug, 'slug')
  return post(config, '/v1/plugins/bulldocs/papers', paper, opts, true)
}

/**
 * Apply an atomic batch of block ops to a paper
 * (`POST /v1/plugins/bulldocs/papers/:slug/ops`). Pass the paper's integer
 * `rev` as `opts.ifRev` to fence the batch.
 *
 * @throws BarkparkConflictError (status 412) when `ifRev` is stale. No op is applied.
 */
export async function applyPaperOps(
  config: BarkparkClientConfig,
  slug: string,
  ops: PaperOp[],
  opts?: PaperOpsOptions,
): Promise<PaperOpsReceipt> {
  const ifRev = opts?.ifRev
  return post(config, paperPath(slug, 'ops'), ifRev === undefined ? { ops } : { ops, ifRev }, opts, true)
}

/**
 * Propose insert-only edits to a paper's draft
 * (`POST /v1/plugins/bulldocs/papers/:slug/proposals`). The published revision
 * is not changed; approve by publishing the draft (`client.publish(slug, 'paper')`).
 */
export async function proposePaperEdits(
  config: BarkparkClientConfig,
  slug: string,
  proposal: PaperProposal,
  opts?: WriteOptions,
): Promise<PaperProposalReceipt> {
  return post(config, paperPath(slug, 'proposals'), { ...proposal }, opts, true)
}

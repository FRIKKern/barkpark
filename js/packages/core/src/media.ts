// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Media upload: POST /v1/media/:dataset/upload as multipart/form-data with a
// `file` field. Returns the created asset (server wraps it in `{ result }`).
// FormData is web-standard (Node 18+, browsers, edge, workers) — keeps the
// zero-dependency, runtime-agnostic contract.

import { scopePrefix } from './scope'
import { request } from './transport'
import type { BarkparkClientConfig, MediaAsset, UploadOptions } from './types'

export async function uploadAsset(
  config: BarkparkClientConfig,
  file: Blob,
  opts?: UploadOptions,
): Promise<MediaAsset> {
  if (typeof FormData === 'undefined') {
    throw new Error('uploadAsset requires a runtime with global FormData (Node 18+, browsers, edge)')
  }
  const form = new FormData()
  const filename = opts?.filename ?? (file as { name?: string }).name ?? 'upload'
  form.append('file', file, filename)

  const path = `${scopePrefix(config)}/v1/media/${encodeURIComponent(config.dataset)}/upload`
  const reqOpts: { method: 'POST'; kind: 'write'; body: FormData; signal?: AbortSignal } = {
    method: 'POST',
    kind: 'write',
    body: form,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal

  const { data } = await request<MediaAsset & { result?: MediaAsset }>(config, path, reqOpts)
  return (data.result ?? data) as MediaAsset
}

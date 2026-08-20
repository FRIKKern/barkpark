// Instance API access — @barkpark/core against the CONNECTED Barkpark (the
// content server the cascade landed on), distinct from src/cloud/* which
// talks to the control plane.
//
// LOAD-BEARING (charter D14): the SDK's listen() hard-requires a STREAMING
// response.body, and React Native's built-in fetch cannot stream — so the
// Expo streaming fetch is injected through config.fetch. expo/fetch is a
// WinterCG-shaped fetch whose TS type differs nominally from lib.dom's; the
// cast below is the one sanctioned seam.
import { fetch as expoFetch } from 'expo/fetch'
import { createClient, type BarkparkClient } from '@barkpark/core'

import type { StoredConfig } from '../cascade/knownServers'

export const API_VERSION = '2026-04-01'

export interface InstanceConnection {
  projectUrl: string
  token: string
  dataset: string
  workspace?: string
  project?: string
}

export function connectionFromConfig(config: StoredConfig): InstanceConnection | undefined {
  const projectUrl = (config.server ?? '').trim()
  const token = (config.token ?? '').trim()
  if (projectUrl === '' || token === '') return undefined
  const connection: InstanceConnection = {
    projectUrl,
    token,
    dataset: (config.dataset ?? '').trim() || 'production',
  }
  const workspace = (config.workspace ?? '').trim()
  const project = (config.project ?? '').trim()
  if (workspace !== '' && project !== '') {
    connection.workspace = workspace
    connection.project = project
  }
  return connection
}

export function makeInstanceClient(connection: InstanceConnection): BarkparkClient {
  return createClient({
    projectUrl: connection.projectUrl,
    dataset: connection.dataset,
    apiVersion: API_VERSION,
    token: connection.token,
    ...(connection.workspace !== undefined && connection.project !== undefined
      ? { workspace: connection.workspace, project: connection.project }
      : {}),
    fetch: expoFetch as unknown as typeof globalThis.fetch,
  })
}

// ─── Tasks prime (brief view) ────────────────────────────────────────────────
//
// GET /v1/tasks/prime?view=brief — the one-call agent-rehydration read the
// Tasks tab renders. The brief card is the server's diet v2 shape
// (tasks_controller/params.ex render_doc(:brief)): nils pruned, steady-state
// keys omitted (absent lifecycle_status MEANS "open", absent status MEANS
// "published"), title/now-text …-capped.

export interface BriefClaim {
  worker?: string
  epoch?: number
  now?: { text?: string; ts?: string; criterion?: number }
}

export interface BriefTaskCard {
  doc_id: string
  title: string
  priority?: number
  assignee?: string
  parent_id?: string
  updated_at?: string
  status?: string
  lifecycle_status?: string
  criteria_met?: number
  criteria_total?: number
  claim?: BriefClaim
  child_count?: number
}

export interface PrimeBrief {
  inProgress: BriefTaskCard[]
  ready: BriefTaskCard[]
  counts: Record<string, number>
  /** Top-level truncation-honesty help lines, when any card lost bytes. */
  help: string[]
}

export async function fetchPrimeBrief(client: BarkparkClient): Promise<PrimeBrief> {
  const response = await client.fetchRaw<Response>('/v1/tasks/prime?view=brief')
  if (!response.ok) {
    throw new Error(`tasks prime failed: HTTP ${response.status}`)
  }
  const body = (await response.json()) as {
    in_progress?: BriefTaskCard[]
    ready?: BriefTaskCard[]
    counts?: Record<string, number>
    help?: string[]
  }
  return {
    inProgress: body.in_progress ?? [],
    ready: body.ready ?? [],
    counts: body.counts ?? {},
    help: body.help ?? [],
  }
}

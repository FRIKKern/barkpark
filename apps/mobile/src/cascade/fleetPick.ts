// Fleet-pick cascade — the UI-free decision engine transliterated from the
// CLI's cloudFleetPick / cloudResolveTarget (internal/cli/setup_cloud_login.go).
// Every branch is a COMPLETE typed outcome (never a dead end):
//
//   n == 0  → 'empty'         (logged-in only — launch guidance)
//   n == 1  → AUTO-SELECT     (no picker; resolve immediately)  [charter D14]
//   n >= 2  → 'choose'        (the UI renders the picker, then resolves one)
//
// Resolution order for a picked Barkpark:
//   member-role → try the app-token mint FIRST (the member-reachable exchange,
//   charter D4/D8); 'unsupported' → manual token paste (cloudNoAdminToken
//   idiom — the DAY-1 credential path).
//   owner/admin → the credentials reveal, with no_admin_token → paste and
//   still-provisioning → 'provisioning' (stay logged in).
import type { CloudBarkpark, CloudClient } from '../cloud/api'
import { CloudApiError } from '../cloud/api'

/** A ready-to-store connection (feeds rememberServer). */
export interface ConnectTarget {
  server: string
  token: string
  name: string
  instanceId: string
  team: string
}

/**
 * A paste-shaped outcome: the box is reachable but no credential could be
 * resolved automatically. The UI prompts for a manual token; `connect(token)`
 * builds the target the cloudNoAdminToken way — Server/Token/Name only, with
 * instanceId/team left EMPTY so the first capabilities + fleet reconcile
 * backfills them (charter D14).
 */
export interface PasteRequest {
  barkpark: CloudBarkpark
  server: string
}

export type ResolveOutcome =
  | { kind: 'connected'; target: ConnectTarget }
  | { kind: 'paste'; request: PasteRequest }
  | { kind: 'provisioning'; name: string }

export type FleetDecision =
  | { kind: 'empty' }
  | { kind: 'auto'; picked: CloudBarkpark }
  | { kind: 'choose'; list: CloudBarkpark[] }

/**
 * Resolve a Barkpark's connectable address: full URL preferred, host as the
 * fallback, a scheme-less host promoted to https:// so upsert-equality always
 * compares canonical scheme+host (fleetTarget port). '' when neither is set.
 */
export function fleetTarget(url: string, host: string): string {
  let raw = url.trim()
  if (raw === '') raw = host.trim()
  if (raw === '') return ''
  if (!raw.includes('://')) raw = `https://${raw}`
  return raw
}

/** The n==0 / n==1 / n>=2 decision — pure, synchronous, trivially testable. */
export function decideFleet(list: CloudBarkpark[]): FleetDecision {
  if (list.length === 0) return { kind: 'empty' }
  const first = list[0]
  if (list.length === 1 && first !== undefined) return { kind: 'auto', picked: first }
  return { kind: 'choose', list }
}

function isMemberRole(b: CloudBarkpark): boolean {
  return (b.team?.role ?? '').trim().toLowerCase() === 'member'
}

/** Build the manual-paste target: Server/Token/Name only (backfill later). */
export function connectFromPaste(request: PasteRequest, token: string): ConnectTarget {
  return {
    server: request.server,
    token: token.trim(),
    name: request.barkpark.name,
    instanceId: '',
    team: '',
  }
}

/**
 * Resolve a picked Barkpark to a credentialled target (cloudResolveTarget
 * port, mobile-shaped): members go through the app-token exchange, owners
 * and admins through the credentials reveal. Both credential paths degrade
 * to manual paste rather than dead-ending.
 */
export async function resolveTarget(
  client: CloudClient,
  picked: CloudBarkpark,
): Promise<ResolveOutcome> {
  const server = fleetTarget(picked.url, picked.host)

  if (isMemberRole(picked)) {
    // A member cannot reveal the admin token (the CLI stops here); the app's
    // whole point is the member-reachable mint (charter D4). Unsupported →
    // paste, so the skeleton never blocks on the exchange slice.
    if (server === '') return { kind: 'provisioning', name: picked.name }
    const minted = await client.mintAppToken(picked.id, picked.team?.id ?? '')
    if (minted.kind === 'minted' && minted.token !== '') {
      return {
        kind: 'connected',
        target: {
          server: fleetTarget(minted.url, minted.host) || server,
          token: minted.token,
          name: picked.name,
          instanceId: picked.id.trim(),
          team: picked.team?.name?.trim() ?? '',
        },
      }
    }
    return { kind: 'paste', request: { barkpark: picked, server } }
  }

  let creds
  try {
    creds = await client.getCredentialsForTeam(picked.id, picked.team?.id ?? '')
  } catch (err) {
    if (err instanceof CloudApiError && err.code === 'no_admin_token') {
      // cloudNoAdminToken idiom: no address → still provisioning; otherwise
      // offer the manual paste that feeds the same connect.
      if (server === '') return { kind: 'provisioning', name: picked.name }
      return { kind: 'paste', request: { barkpark: picked, server } }
    }
    throw err
  }

  const target = fleetTarget(creds.url, creds.host)
  if (target === '') return { kind: 'provisioning', name: picked.name }
  return {
    kind: 'connected',
    target: {
      server: target,
      token: creds.adminToken,
      name: picked.name,
      instanceId: picked.id.trim(),
      team: picked.team?.name?.trim() ?? '',
    },
  }
}

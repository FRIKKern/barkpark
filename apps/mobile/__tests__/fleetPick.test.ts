// Cascade decision engine — cloudFleetPick semantics: n==0 logged-in-only,
// n==1 AUTO-SELECT with no picker, n>=2 picker; member mint-first with the
// D8 closed-code paste fallback; owner credentials with no_admin_token →
// paste and still-provisioning → provisioning.
import { CloudApiError, type CloudBarkpark, type CloudClient } from '../src/cloud/api'
import {
  connectFromPaste,
  decideFleet,
  fleetTarget,
  resolveTarget,
} from '../src/cascade/fleetPick'

const park = (over: Partial<CloudBarkpark>): CloudBarkpark => ({
  id: 'inst-1',
  name: 'guerrilla',
  url: 'https://guerrilla.barkpark.cloud',
  host: '',
  team: { id: 'team-1', name: 'Guerrilla', role: 'owner' },
  ...over,
})

const stubClient = (over: Partial<CloudClient>): CloudClient => ({
  deviceStart: jest.fn(),
  devicePoll: jest.fn(),
  listAllBarkparks: jest.fn(),
  getCredentialsForTeam: jest.fn(),
  mintAppToken: jest.fn(),
  ...over,
})

describe('fleetTarget', () => {
  it('prefers the URL, falls back to host, promotes a scheme-less host to https', () => {
    expect(fleetTarget('https://a.example', 'b.example')).toBe('https://a.example')
    expect(fleetTarget('', 'b.example')).toBe('https://b.example')
    expect(fleetTarget('', '')).toBe('')
  })
})

describe('decideFleet', () => {
  it('n==0 → empty (logged-in only, never a dead end)', () => {
    expect(decideFleet([])).toEqual({ kind: 'empty' })
  })

  it('n==1 → AUTO-SELECT with no picker', () => {
    const only = park({})
    expect(decideFleet([only])).toEqual({ kind: 'auto', picked: only })
  })

  it('n>=2 → picker', () => {
    const list = [park({ id: 'a' }), park({ id: 'b' })]
    expect(decideFleet(list)).toEqual({ kind: 'choose', list })
  })
})

describe('resolveTarget — member role (the app-token exchange path)', () => {
  it('mints and connects when the exchange is live', async () => {
    const client = stubClient({
      mintAppToken: jest.fn().mockResolvedValue({
        kind: 'minted',
        token: 'app-tok',
        url: 'https://guerrilla.barkpark.cloud',
        host: '',
      }),
    })
    const outcome = await resolveTarget(client, park({ team: { id: 'team-1', name: 'Guerrilla', role: 'member' } }))
    expect(outcome).toEqual({
      kind: 'connected',
      target: {
        server: 'https://guerrilla.barkpark.cloud',
        token: 'app-tok',
        name: 'guerrilla',
        instanceId: 'inst-1',
        team: 'Guerrilla',
      },
    })
    expect(client.getCredentialsForTeam).not.toHaveBeenCalled()
  })

  it('409 app_token_unsupported → manual paste fallback (charter D8), never a dead end', async () => {
    const client = stubClient({
      mintAppToken: jest.fn().mockResolvedValue({ kind: 'unsupported' }),
    })
    const outcome = await resolveTarget(client, park({ team: { id: 'team-1', name: 'Guerrilla', role: 'member' } }))
    expect(outcome.kind).toBe('paste')
    if (outcome.kind === 'paste') {
      expect(outcome.request.server).toBe('https://guerrilla.barkpark.cloud')
    }
  })
})

describe('resolveTarget — owner/admin (credentials reveal)', () => {
  it('connects with the revealed credentials', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest.fn().mockResolvedValue({
        adminToken: 'admin-tok',
        url: 'https://guerrilla.barkpark.cloud',
        host: '',
      }),
    })
    const outcome = await resolveTarget(client, park({}))
    expect(outcome).toMatchObject({
      kind: 'connected',
      target: { server: 'https://guerrilla.barkpark.cloud', token: 'admin-tok', instanceId: 'inst-1' },
    })
    expect(client.mintAppToken).not.toHaveBeenCalled()
  })

  it('no_admin_token → paste (cloudNoAdminToken idiom)', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest
        .fn()
        .mockRejectedValue(new CloudApiError('get credentials: no_admin_token', 404, 'no_admin_token')),
    })
    const outcome = await resolveTarget(client, park({}))
    expect(outcome.kind).toBe('paste')
  })

  it('no address at all → provisioning (stay logged in)', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest.fn().mockResolvedValue({ adminToken: 't', url: '', host: '' }),
    })
    const outcome = await resolveTarget(client, park({}))
    expect(outcome).toEqual({ kind: 'provisioning', name: 'guerrilla' })
  })

  it('unexpected errors surface (retry affordance), not swallowed', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest.fn().mockRejectedValue(new CloudApiError('boom', 500, '')),
    })
    await expect(resolveTarget(client, park({}))).rejects.toThrow('boom')
  })
})

// https-only (task-4edcfaf85d569b2d): Cloud only ever returns https, so a
// cleartext (or any non-https) instance address from Cloud is a bug or an
// attack. The cascade refuses it with a typed outcome — and when the fleet row
// itself is cleartext, refuses BEFORE asking Cloud for a token at all.
describe('resolveTarget — https only for Cloud-sourced addresses', () => {
  const member = { id: 'team-1', name: 'Guerrilla', role: 'member' }

  it('a cleartext fleet row is refused before any token is minted or revealed', async () => {
    for (const team of [member, { id: 'team-1', name: 'Guerrilla', role: 'owner' }]) {
      const client = stubClient({})
      const outcome = await resolveTarget(client, park({ url: 'http://guerrilla.barkpark.cloud', team }))
      expect(outcome).toEqual({
        kind: 'insecure',
        name: 'guerrilla',
        address: 'http://guerrilla.barkpark.cloud',
      })
      expect(client.mintAppToken).not.toHaveBeenCalled()
      expect(client.getCredentialsForTeam).not.toHaveBeenCalled()
    }
  })

  it('a non-https scheme of any kind is refused, case-insensitively', async () => {
    for (const url of ['HTTP://g.example', 'ws://g.example', 'ftp://g.example']) {
      const outcome = await resolveTarget(stubClient({}), park({ url }))
      expect(outcome.kind).toBe('insecure')
    }
  })

  it('a cleartext address in the app-token mint response is refused (the token is never handed back)', async () => {
    const client = stubClient({
      mintAppToken: jest.fn().mockResolvedValue({
        kind: 'minted',
        token: 'app-tok',
        url: 'http://evil.example',
        host: '',
      }),
    })
    const outcome = await resolveTarget(client, park({ team: member }))
    expect(outcome).toEqual({ kind: 'insecure', name: 'guerrilla', address: 'http://evil.example' })
    expect(JSON.stringify(outcome)).not.toContain('app-tok')
  })

  it('a cleartext address in the credentials reveal is refused (the admin token is never handed back)', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest.fn().mockResolvedValue({
        adminToken: 'admin-tok',
        url: 'http://guerrilla.barkpark.cloud',
        host: '',
      }),
    })
    const outcome = await resolveTarget(client, park({}))
    expect(outcome.kind).toBe('insecure')
    expect(JSON.stringify(outcome)).not.toContain('admin-tok')
  })

  it('a cleartext fleet row never offers the paste fallback (that would send a pasted token over http)', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest
        .fn()
        .mockRejectedValue(new CloudApiError('get credentials: no_admin_token', 404, 'no_admin_token')),
      mintAppToken: jest.fn().mockResolvedValue({ kind: 'unsupported' }),
    })
    for (const team of [member, { id: 'team-1', name: 'Guerrilla', role: 'owner' }]) {
      const outcome = await resolveTarget(client, park({ url: '', host: 'http://g.example', team }))
      expect(outcome.kind).toBe('insecure')
    }
  })

  it('scheme-less hosts still promote to https and connect as before', async () => {
    const client = stubClient({
      getCredentialsForTeam: jest.fn().mockResolvedValue({ adminToken: 't', url: '', host: 'g.example' }),
    })
    const outcome = await resolveTarget(client, park({ url: '', host: 'g.example' }))
    expect(outcome).toMatchObject({ kind: 'connected', target: { server: 'https://g.example' } })
  })
})

describe('connectFromPaste', () => {
  it('stores Server/Token/Name ONLY — instanceId/team backfill on reconcile (charter D14)', () => {
    const target = connectFromPaste(
      { barkpark: park({}), server: 'https://guerrilla.barkpark.cloud' },
      '  pasted-token  ',
    )
    expect(target).toEqual({
      server: 'https://guerrilla.barkpark.cloud',
      token: 'pasted-token',
      name: 'guerrilla',
      instanceId: '',
      team: '',
    })
  })
})

// Device-flow poll loop — the runDeviceLoginFlow semantics: pending keeps
// polling, slow_down widens the interval by 5s, approved resolves with the
// {token, team_id} envelope, terminal refusals classify (expired vs denied),
// and cancel resolves 'cancelled' without another poll.
import { CloudApiError, type CloudClient, type DevicePollResult } from '../src/cloud/api'
import { startDeviceFlow } from '../src/cloud/deviceFlow'

const session = {
  deviceCode: 'dev-code',
  userCode: 'ABCD-1234',
  verificationUri: 'https://barkpark.cloud/activate',
  verificationUriComplete: 'https://barkpark.cloud/activate?code=ABCD-1234',
  interval: 5,
  expiresIn: 600,
}

function clientWithPolls(polls: (DevicePollResult | CloudApiError)[]): {
  client: CloudClient
  pollMock: jest.Mock
} {
  const pollMock = jest.fn()
  for (const p of polls) {
    if (p instanceof CloudApiError) pollMock.mockRejectedValueOnce(p)
    else pollMock.mockResolvedValueOnce(p)
  }
  const client: CloudClient = {
    deviceStart: jest.fn().mockResolvedValue(session),
    devicePoll: pollMock,
    listAllBarkparks: jest.fn(),
    getCredentialsForTeam: jest.fn(),
    mintAppToken: jest.fn(),
  }
  return { client, pollMock }
}

const instantSleep = () => Promise.resolve()

describe('startDeviceFlow', () => {
  it('resolves approved with the token envelope after pending polls', async () => {
    const { client, pollMock } = clientWithPolls([
      { status: 'pending' },
      { status: 'pending' },
      { status: 'approved', token: 'cloud-tok', teamId: 'team-1' },
    ])
    const handle = await startDeviceFlow(client, 'test', instantSleep)
    expect(handle.session.userCode).toBe('ABCD-1234')
    await expect(handle.outcome).resolves.toEqual({ kind: 'approved', token: 'cloud-tok', teamId: 'team-1' })
    expect(pollMock).toHaveBeenCalledTimes(3)
  })

  it('slow_down widens the poll interval by 5s (RFC 8628 §3.5)', async () => {
    const sleeps: number[] = []
    const { client } = clientWithPolls([
      { status: 'slow_down' },
      { status: 'approved', token: 't', teamId: '' },
    ])
    const handle = await startDeviceFlow(client, 'test', (ms) => {
      sleeps.push(ms)
      return Promise.resolve()
    })
    await handle.outcome
    expect(sleeps).toEqual([5000, 10000])
  })

  it('classifies expired_or_invalid as expired', async () => {
    const { client } = clientWithPolls([
      new CloudApiError('device poll: expired_or_invalid', 404, 'expired_or_invalid'),
    ])
    const handle = await startDeviceFlow(client, 'test', instantSleep)
    await expect(handle.outcome).resolves.toEqual({ kind: 'expired' })
  })

  it('classifies access_denied as denied with the code', async () => {
    const { client } = clientWithPolls([
      new CloudApiError('device poll: access_denied', 403, 'access_denied'),
    ])
    const handle = await startDeviceFlow(client, 'test', instantSleep)
    await expect(handle.outcome).resolves.toEqual({ kind: 'denied', code: 'access_denied' })
  })

  it('self-expires when the code TTL runs out even if the server keeps saying pending', async () => {
    const { client } = clientWithPolls([{ status: 'pending' }, { status: 'pending' }])
    let clock = 0
    const handle = await startDeviceFlow(
      client,
      'test',
      () => {
        clock += 400_000 // two sleeps step past the 600s TTL
        return Promise.resolve()
      },
      () => clock,
    )
    await expect(handle.outcome).resolves.toEqual({ kind: 'expired' })
  })

  it('cancel resolves cancelled without polling again', async () => {
    const { client, pollMock } = clientWithPolls([])
    const handle = await startDeviceFlow(client, 'test', () => new Promise(() => {}))
    handle.cancel()
    // The loop re-checks `cancelled` at every seam; the pending sleep never
    // resolves, but the pre-sleep check already returned.
    await expect(handle.outcome).resolves.toEqual({ kind: 'cancelled' })
    expect(pollMock).not.toHaveBeenCalled()
  })

  it('transport failures reject (retry affordance), never masquerade as denial', async () => {
    const { client } = clientWithPolls([])
    ;(client.devicePoll as jest.Mock).mockRejectedValueOnce(new TypeError('Network request failed'))
    const handle = await startDeviceFlow(client, 'test', instantSleep)
    await expect(handle.outcome).rejects.toThrow('Network request failed')
  })
})

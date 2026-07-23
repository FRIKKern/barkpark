// Cloud client outcome mapping — the closed code maps: device poll's 200
// pending-vs-approved discrimination, RFC-8628 alias spellings, and the
// app-token mint's unsupported/minted split (charter D8).
import { createCloudClient, CloudApiError } from '../src/cloud/api'

function fetchReturning(status: number, body: unknown): typeof fetch {
  return jest.fn().mockResolvedValue({
    status,
    json: () => Promise.resolve(body),
  }) as unknown as typeof fetch
}

describe('devicePoll', () => {
  it('200 {status:"pending"} → pending (a pending body can never masquerade as approval)', async () => {
    const client = createCloudClient({ fetch: fetchReturning(200, { status: 'pending' }) })
    await expect(client.devicePoll('code')).resolves.toEqual({ status: 'pending' })
  })

  it('200 with a token → approved with the team id', async () => {
    const client = createCloudClient({ fetch: fetchReturning(200, { token: 'tok', team_id: 'team-9' }) })
    await expect(client.devicePoll('code')).resolves.toEqual({
      status: 'approved',
      token: 'tok',
      teamId: 'team-9',
    })
  })

  it('200 with neither pending nor token → error, not a silent empty approval', async () => {
    const client = createCloudClient({ fetch: fetchReturning(200, {}) })
    await expect(client.devicePoll('code')).rejects.toThrow('neither a pending status nor a token')
  })

  it('tolerates the RFC-8628 spellings: authorization_pending and slow_down', async () => {
    const pending = createCloudClient({ fetch: fetchReturning(400, { error: 'authorization_pending' }) })
    await expect(pending.devicePoll('code')).resolves.toEqual({ status: 'pending' })

    const slow = createCloudClient({ fetch: fetchReturning(429, { error: 'slow_down' }) })
    await expect(slow.devicePoll('code')).resolves.toEqual({ status: 'slow_down' })
  })

  it('terminal refusals surface as CloudApiError with the code', async () => {
    const client = createCloudClient({ fetch: fetchReturning(404, { error: 'expired_or_invalid' }) })
    await expect(client.devicePoll('code')).rejects.toMatchObject({
      name: 'CloudApiError',
      code: 'expired_or_invalid',
      status: 404,
    })
  })
})

describe('mintAppToken (charter D8 closed code map)', () => {
  it('409 app_token_unsupported → unsupported (paste fallback)', async () => {
    const client = createCloudClient({ fetch: fetchReturning(409, { error: 'app_token_unsupported' }) })
    await expect(client.mintAppToken('id', 'team')).resolves.toEqual({ kind: 'unsupported' })
  })

  it('a code-less 404 (route not there yet — day-1 Cloud) → unsupported', async () => {
    const client = createCloudClient({ fetch: fetchReturning(404, { errors: { detail: 'Not Found' } }) })
    await expect(client.mintAppToken('id', 'team')).resolves.toEqual({ kind: 'unsupported' })
  })

  it('2xx → minted with token and address', async () => {
    const client = createCloudClient({
      fetch: fetchReturning(200, { token: 'app-tok', url: 'https://x.example', host: '' }),
    })
    await expect(client.mintAppToken('id', 'team')).resolves.toEqual({
      kind: 'minted',
      token: 'app-tok',
      url: 'https://x.example',
      host: '',
    })
  })

  it('any other refusal is an error, never silently unsupported', async () => {
    const client = createCloudClient({ fetch: fetchReturning(403, { error: 'forbidden' }) })
    await expect(client.mintAppToken('id', 'team')).rejects.toBeInstanceOf(CloudApiError)
  })
})

describe('listAllBarkparks', () => {
  it('requests scope=all with the Bearer and maps the team slice', async () => {
    const fetchMock = fetchReturning(200, {
      barkparks: [
        { id: 'a', name: 'One', url: 'https://one.example', host: '', team: { id: 't', name: 'T', role: 'member' } },
      ],
    })
    const client = createCloudClient({ token: 'cloud-tok', fetch: fetchMock })
    const list = await client.listAllBarkparks()
    expect(list).toEqual([
      { id: 'a', name: 'One', url: 'https://one.example', host: '', team: { id: 't', name: 'T', role: 'member' } },
    ])
    const [url, init] = (fetchMock as unknown as jest.Mock).mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://api.barkpark.cloud/v1/barkparks?scope=all')
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer cloud-tok')
  })
})

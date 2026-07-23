// MRU semantics — the acceptance contract transliterated from
// internal/cli/config.go's RememberServer tests: InstanceID-first upsert
// identity, alias folding, cap 20, name inheritance, and the flat
// active-context promotion that is the app's last-location memory.
import {
  MAX_KNOWN_SERVERS,
  deriveName,
  deriveUniqueName,
  mergeAliases,
  normalizeServerUrl,
  rememberServer,
  sameEntryIdentity,
  type ServerEntry,
  type StoredConfig,
} from '../src/cascade/knownServers'

const entry = (over: Partial<ServerEntry> & { server: string }): ServerEntry => ({ ...over })

describe('normalizeServerUrl', () => {
  it('trims trailing slashes and lowercases scheme+host, preserving path case', () => {
    expect(normalizeServerUrl('HTTPS://Guerrilla.Barkpark.Cloud/')).toBe('https://guerrilla.barkpark.cloud')
    expect(normalizeServerUrl('http://Host.example/Path/Case')).toBe('http://host.example/Path/Case')
  })
})

describe('sameEntryIdentity', () => {
  it('is decided by InstanceID alone when both sides carry one', () => {
    const a = entry({ server: 'https://one.example', instanceId: 'ABC' })
    const b = entry({ server: 'https://totally-different.example', instanceId: 'abc' })
    expect(sameEntryIdentity(a, b)).toBe(true)
  })

  it('falls back to normalized URL / alias equality when an ID is missing', () => {
    const a = entry({ server: 'https://one.example', aliases: ['https://alias.example'] })
    expect(sameEntryIdentity(a, entry({ server: 'https://ALIAS.example/' }))).toBe(true)
    expect(sameEntryIdentity(a, entry({ server: 'https://other.example' }))).toBe(false)
  })
})

describe('rememberServer', () => {
  it('upserts by InstanceID: a new hostname collapses into ONE entry and folds the old primary into aliases', () => {
    let config: StoredConfig = {}
    config = rememberServer(config, entry({ server: 'https://old-host.example', instanceId: 'inst-1', token: 't1' }))
    config = rememberServer(config, entry({ server: 'https://new-host.example', instanceId: 'inst-1', token: 't2' }))

    expect(config.knownServers).toHaveLength(1)
    const head = config.knownServers![0]!
    expect(head.server).toBe('https://new-host.example')
    expect(head.aliases).toEqual(['https://old-host.example'])
    expect(config.server).toBe('https://new-host.example')
    expect(config.token).toBe('t2')
  })

  it('inherits name and instanceId from the matched entry on a plain re-connect', () => {
    let config: StoredConfig = {}
    config = rememberServer(config, entry({ server: 'https://x.example', instanceId: 'inst-9', name: 'prod' }))
    config = rememberServer(config, entry({ server: 'https://x.example', token: 'fresh' }))

    const head = config.knownServers![0]!
    expect(head.name).toBe('prod')
    expect(head.instanceId).toBe('inst-9')
  })

  it('keeps the list most-recent-first and caps it at 20', () => {
    let config: StoredConfig = {}
    for (let i = 0; i < MAX_KNOWN_SERVERS + 5; i++) {
      config = rememberServer(config, entry({ server: `https://s${i}.example`, instanceId: `inst-${i}` }))
    }
    expect(config.knownServers).toHaveLength(MAX_KNOWN_SERVERS)
    expect(config.knownServers![0]!.server).toBe('https://s24.example')
    // The oldest entries fell off the tail.
    expect(config.knownServers!.some((e) => e.server === 'https://s0.example')).toBe(false)
  })

  it('promotes workspace/project/dataset to the flat active context but never blanks them', () => {
    let config: StoredConfig = { workspace: 'acme', project: 'main', dataset: 'production' }
    config = rememberServer(config, entry({ server: 'https://y.example', token: 't' }))
    // Entry carried no scope — the last location survives.
    expect(config.workspace).toBe('acme')
    expect(config.project).toBe('main')
    expect(config.dataset).toBe('production')

    config = rememberServer(config, entry({ server: 'https://y.example', token: 't', dataset: 'staging' }))
    expect(config.dataset).toBe('staging')
  })

  it('does not mutate its input config', () => {
    const original: StoredConfig = { knownServers: [entry({ server: 'https://a.example' })] }
    const frozen = JSON.parse(JSON.stringify(original))
    rememberServer(original, entry({ server: 'https://b.example' }))
    expect(original).toEqual(frozen)
  })
})

describe('mergeAliases', () => {
  it('is order-stable and dedupes by normalized form, excluding the new primary', () => {
    const matched = entry({
      server: 'https://old.example',
      aliases: ['https://older.example', 'https://OLD.example/'],
    })
    expect(mergeAliases('https://new.example', matched, ['https://incoming.example'])).toEqual([
      'https://old.example',
      'https://older.example',
      'https://incoming.example',
    ])
  })

  it('re-connecting to the SAME url yields exactly the prior aliases', () => {
    const matched = entry({ server: 'https://same.example', aliases: ['https://alias.example'] })
    expect(mergeAliases('https://same.example', matched, undefined)).toEqual(['https://alias.example'])
  })
})

describe('name derivation', () => {
  it('derives handles the CLI way', () => {
    expect(deriveName('http://localhost:4000')).toBe('local')
    expect(deriveName('https://api.barkpark.cloud')).toBe('barkpark')
    expect(deriveName('https://staging.foo.com')).toBe('staging')
    expect(deriveName('http://89.167.28.206')).toBe('89.167.28.206')
    expect(deriveName('')).toBe('server')
  })

  it('suffixes -2/-3 on collision, case-insensitively', () => {
    const others = [entry({ server: 'https://api.barkpark.cloud' })]
    expect(deriveUniqueName('https://www.barkpark.cloud', others)).toBe('barkpark-2')
  })
})

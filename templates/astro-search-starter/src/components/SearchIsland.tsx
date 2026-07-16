// Live search, static-site edition: the browser talks STRAIGHT to Barkpark —
// per-keystroke over the Phoenix WebSocket channel when configured, HTTP
// search otherwise. No server between visitor and engine; the deployed site
// is pure static files. Config arrives as build-baked props (public-safe).
import { useEffect, useMemo, useRef, useState } from 'react'
import { Socket, type Channel } from 'phoenix'

interface Hit {
  id: string
  type: string
  title?: string
  excerpt?: string
  slug?: string
}

interface Props {
  base: string
  apiUrl: string
  dataset: string
  workspace: string
  project: string
  /** Public-safe token for the browser-direct search read ('' = anonymous). */
  wsToken: string
  wsUrl: string
}

export default function SearchIsland(p: Props) {
  const [q, setQ] = useState('')
  const [hits, setHits] = useState<Hit[]>([])
  const [status, setStatus] = useState<'idle' | 'live' | 'http' | 'error'>('idle')
  const chanRef = useRef<Channel | null>(null)
  const seq = useRef(0)

  // One persistent socket per island life; live search flips a single frame
  // per keystroke (the finder's signature feel, sans server).
  useEffect(() => {
    if (!p.wsUrl || !p.wsToken) return
    const sock = new Socket(p.wsUrl, { params: { token: p.wsToken } })
    sock.connect()
    const topic = `search:${p.workspace}/${p.project}:${p.dataset}`
    const chan = sock.channel(topic, {})
    chan
      .join()
      .receive('ok', () => {
        chanRef.current = chan
        setStatus('live')
      })
      .receive('error', () => setStatus('http'))
    return () => {
      chan.leave()
      sock.disconnect()
      chanRef.current = null
    }
  }, [p.wsUrl, p.wsToken, p.workspace, p.project, p.dataset])

  useEffect(() => {
    const term = q.trim()
    if (!term) {
      setHits([])
      return
    }
    const mine = ++seq.current
    const chan = chanRef.current
    if (chan) {
      chan
        .push('search', { q: term, limit: 12 })
        .receive('ok', (r: { hits?: Hit[] }) => {
          if (seq.current === mine) setHits(r.hits || [])
        })
      return
    }
    const scope = `/w/${encodeURIComponent(p.workspace)}/p/${encodeURIComponent(p.project)}`
    const url =
      `${p.apiUrl}${scope}/v1/data/search/${encodeURIComponent(p.dataset)}` +
      `?q=${encodeURIComponent(term)}&limit=12`
    fetch(url, { headers: p.wsToken ? { authorization: `Bearer ${p.wsToken}` } : {} })
      .then((r) => r.json())
      .then((r: { result?: { hits?: Hit[] }; hits?: Hit[] }) => {
        if (seq.current !== mine) return
        setHits((r.result && r.result.hits) || r.hits || [])
        setStatus((s) => (s === 'live' ? s : 'http'))
      })
      .catch(() => setStatus('error'))
  }, [q, p.apiUrl, p.dataset, p.workspace, p.project, p.wsToken])

  const badge = useMemo(() => {
    if (status === 'live') return 'live'
    if (status === 'http') return 'search'
    return ''
  }, [status])

  return (
    <div className="bp-search">
      <div className="bp-search-row">
        <input
          className="bp-search-input"
          type="search"
          placeholder="Search everything…"
          value={q}
          autoFocus
          onChange={(e) => setQ(e.target.value)}
          aria-label="Search"
        />
        {badge && <span className={`bp-search-badge bp-search-badge--${status}`}>{badge}</span>}
      </div>
      {hits.length > 0 && (
        <ol className="bp-search-hits">
          {hits.map((h) => (
            <li key={h.id}>
              <a href={`${p.base}d/${encodeURIComponent(h.type)}/${encodeURIComponent(h.slug || h.id)}/`}>
                <strong>{h.title || h.id}</strong>
                {h.excerpt ? <span className="bp-search-x"> — {h.excerpt}</span> : null}
              </a>
            </li>
          ))}
        </ol>
      )}
      {status === 'error' && <p className="bp-search-err">Search is unavailable right now.</p>}
    </div>
  )
}

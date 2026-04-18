import { http, HttpResponse } from 'msw'

export const handlers = [
  http.get('http://localhost/v1/meta', () =>
    HttpResponse.json({ apiVersion: 'v2026-04', serverTime: new Date().toISOString() }),
  ),
  http.get('http://localhost/v1/schemas/:dataset', () => HttpResponse.json({ types: [] })),
  http.get('http://localhost/v1/data/query/:dataset/:type', () =>
    HttpResponse.json({ result: [], ms: 0 }),
  ),
  http.get('http://localhost/v1/data/doc/:dataset/:type/:id', () =>
    HttpResponse.json({ documents: [] }),
  ),
  http.post('http://localhost/v1/data/mutate/:dataset', () => HttpResponse.json({ results: [] })),
]

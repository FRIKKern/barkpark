// The App shape, used the way an app uses it: start the engine, upload a picture,
// publish and edit a paper with a revision check, restart, and check that the data
// and the media URL survive. Runs only when BARKPARK_ENGINE_RELEASE names an engine
// folder (built by scripts/engine/build-release.mjs with --add-postgres).
//
// It exists because an app found the public/listen port split by accident: media
// URLs came back as http://127.0.0.1/media/... with no port and could not be loaded.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { startBarkpark, type Barkpark } from '../src/index'

const release = process.env.BARKPARK_ENGINE_RELEASE
const dataset = 'production'
// A 1x1 transparent PNG.
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')

describe.skipIf(!release)('the App shape: an app boots the engine and uses it', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'barkpark-app-shape-'))
  const running: Barkpark[] = []
  afterAll(async () => { for (const bp of running) await bp.stop().catch(() => {}) })

  const call = async (bp: Barkpark, method: string, route: string, body?: unknown) => {
    const response = await fetch(`${bp.url}${route}`, {
      method,
      headers: { authorization: `Bearer ${bp.token}`, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    const text = await response.text()
    let json: any = null
    try { json = JSON.parse(text) } catch { /* a non-JSON answer is reported below */ }
    return { status: response.status, json, text }
  }
  const unwrap = (json: any) => json?.result ?? json

  it('uploads media, publishes and edits a paper, and keeps both across a restart', async () => {
    const plugins = ['bulldocs', 'media']
    const first = await startBarkpark({ dataDir, plugins, release: release! })
    running.push(first)
    const origin = `http://127.0.0.1:${first.port}`

    // Media: the URL the server hands back must carry the port, and must load.
    const form = new FormData()
    form.append('file', new Blob([png], { type: 'image/png' }), 'app-shape.png')
    const uploadResponse = await fetch(`${first.url}/v1/media/${dataset}/upload`, {
      method: 'POST', headers: { authorization: `Bearer ${first.token}` }, body: form,
    })
    const uploadText = await uploadResponse.text()
    expect(uploadResponse.status, uploadText).toBeLessThan(300)
    const asset = unwrap(JSON.parse(uploadText))
    const mediaUrl: string = asset.absoluteUrl ?? asset.url
    expect(mediaUrl.startsWith(`${origin}/`), `media URL ${mediaUrl} must start with ${origin}/`).toBe(true)
    const mediaBefore = await fetch(mediaUrl)
    expect(mediaBefore.status).toBe(200)
    expect(Buffer.from(await mediaBefore.arrayBuffer()).equals(png)).toBe(true)

    // A paper: publish, edit under its revision, and a stale revision is refused.
    // Only a slug, a title and blocks: the engine runs with the authoring wall off
    // (BARKPARK_AUTHORING_WALL=off), so a fresh app registers no tag and writes no
    // description first (task-8edd8e147c648a36).
    const slug = 'app-shape-paper'
    const published = await call(first, 'POST', '/v1/plugins/bulldocs/papers', {
      slug,
      title: 'App shape paper',
      blocks: [
        { id: 'h', type: 'heading', level: 1, text: 'App shape paper' },
        { id: 'p1', type: 'paragraph', content: [{ type: 'text', value: 'Written before the restart.' }] },
      ],
    })
    expect(published.status, published.text).toBeLessThan(300)
    const rev = Number(unwrap(published.json).rev)
    expect(Number.isSafeInteger(rev)).toBe(true)

    const append = { op: 'append-block', block: { id: 'p2', type: 'paragraph', content: [{ type: 'text', value: 'Appended under ifRev.' }] } }
    const edited = await call(first, 'POST', `/v1/plugins/bulldocs/papers/${slug}/ops`, { ops: [append], ifRev: rev })
    expect(edited.status, edited.text).toBeLessThan(300)
    const stale = await call(first, 'POST', `/v1/plugins/bulldocs/papers/${slug}/ops`, {
      ops: [{ op: 'append-block', block: { id: 'p3', type: 'paragraph', content: [{ type: 'text', value: 'Never written.' }] } }],
      ifRev: rev,
    })
    expect(stale.status, stale.text).toBe(412)

    await first.stop()

    // After a restart on the same data folder, the paper, the edit and the media remain.
    const second = await startBarkpark({ dataDir, plugins, release: release! })
    running.push(second)
    expect(second.port).toBe(first.port)

    const paper = await call(second, 'GET', `/v1/data/doc/${dataset}/paper/${slug}?perspective=raw`)
    expect(paper.status, paper.text).toBe(200)
    expect(paper.text).toContain('Written before the restart.')
    expect(paper.text).toContain('Appended under ifRev.')
    expect(paper.text).not.toContain('Never written.')

    const mediaAfter = await fetch(mediaUrl)
    expect(mediaAfter.status).toBe(200)
    expect(Buffer.from(await mediaAfter.arrayBuffer()).equals(png)).toBe(true)

    await second.stop()
    // Kept on failure for diagnosis; removed once every check passed.
    fs.rmSync(dataDir, { recursive: true, force: true })
  }, 20 * 60_000)
})

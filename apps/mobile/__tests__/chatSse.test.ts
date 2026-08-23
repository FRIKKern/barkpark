// The SSE splitter proofs — the chat events stream's parsing seam, exercised
// without a socket. The server frames (chat_controller.ex events/fleet_events)
// are `event:` + `data:` (+ optional `id:`) blocks separated by blank lines,
// with `: keepalive` comments every 30s.
import {
  MAX_SSE_BUFFER_CHARS,
  parseSseFrame,
  SseFrameTooLargeError,
  SseSplitter,
} from '../src/api/chat'

test('splits frames across arbitrary chunk boundaries', () => {
  const s = new SseSplitter()
  const wire = 'event: chat\ndata: {"type":"result"}\n\nevent: exit\ndata: {"status":0}\n\n'
  const frames = []
  // Feed byte-ish at a time — chunking must not matter.
  for (const ch of wire) frames.push(...s.push(ch))
  expect(frames).toEqual([
    { event: 'chat', data: '{"type":"result"}' },
    { event: 'exit', data: '{"status":0}' },
  ])
})

test('replay frames carry their id (the Last-Event-ID cursor)', () => {
  const s = new SseSplitter()
  const frames = s.push('event: message\nid: 7\ndata: {"seq":7,"role":"user"}\n\n')
  expect(frames).toEqual([{ event: 'message', id: '7', data: '{"seq":7,"role":"user"}' }])
})

test('keepalive comments and empty frames are silent', () => {
  const s = new SseSplitter()
  expect(s.push(': keepalive\n\n')).toEqual([])
  expect(s.push('\n\n')).toEqual([])
})

test('CRLF framing and multi-line data are tolerated', () => {
  const s = new SseSplitter()
  const frames = s.push('event: chat\r\ndata: line1\r\ndata: line2\r\n\r\n')
  expect(frames).toEqual([{ event: 'chat', data: 'line1\nline2' }])
})

test('a dataless frame parses to nothing; default event is message', () => {
  expect(parseSseFrame('event: heartbeat')).toBeUndefined()
  expect(parseSseFrame('data: {"x":1}')).toEqual({ event: 'message', data: '{"x":1}' })
})

test('partial frames stay buffered until their boundary arrives', () => {
  const s = new SseSplitter()
  expect(s.push('event: chat\ndata: {"a"')).toEqual([])
  expect(s.push(':1}\n\n')).toEqual([{ event: 'chat', data: '{"a":1}' }])
})

/* ── the buffer bound ──────────────────────────────────────────────────────
 * `push` used to only ever append and truncate at a discovered boundary, so a
 * stream that never emitted a blank line grew the buffer to the size of
 * everything received. pumpSse resets its backoff ladder on EVERY chunk
 * ("bytes prove a live stream"), so nothing upstream would ever have called
 * that connection unhealthy — on a phone it ends in an OOM, the one failure
 * this app cannot report. */

test('an unterminated stream is refused at the cap instead of buffering forever', () => {
  const s = new SseSplitter()
  const chunk = 'x'.repeat(64 * 1024)
  let pushed = 0
  expect(() => {
    // Well past the cap even if the first few pushes are accepted.
    for (let i = 0; i < 40; i++) {
      s.push(chunk)
      pushed += chunk.length
    }
  }).toThrow(SseFrameTooLargeError)
  // It refused NEAR the cap, not after swallowing an unbounded amount.
  expect(pushed).toBeLessThanOrEqual(MAX_SSE_BUFFER_CHARS + chunk.length)
})

test('the refusal says how much was buffered and what the cap was', () => {
  const s = new SseSplitter()
  let caught: unknown
  try {
    for (let i = 0; i < 40; i++) s.push('x'.repeat(64 * 1024))
  } catch (err) {
    caught = err
  }
  expect(caught).toBeInstanceOf(SseFrameTooLargeError)
  const e = caught as SseFrameTooLargeError
  expect(e.bufferedChars).toBeGreaterThan(MAX_SSE_BUFFER_CHARS)
  expect(e.message).toContain(String(MAX_SSE_BUFFER_CHARS))
  // classifyStreamFailure has no branch for it, which is the POINT: it falls to
  // `transient`, so pumpSse degrades, backs off and reconnects with
  // Last-Event-ID rather than treating a malformed stream as a wall.
  expect(e).toBeInstanceOf(Error)
})

test('a LARGE frame arriving in CHUNKS still assembles — the cap is not a size limit on real traffic', () => {
  const s = new SseSplitter()
  // 512 KiB of payload: far bigger than anything the server emits (the recorded
  // production capture's whole turn is under 3 KB) and still under the cap.
  //
  // FED IN CHUNKS ON PURPOSE. The first draft of this test pushed the whole
  // frame in ONE call, so the boundary was present on the very first push and
  // the cap branch was never reached — lowering MAX_SSE_BUFFER_CHARS to 1024
  // left this test GREEN, which means it guarded nothing about the cap's VALUE.
  // A real 512 KiB frame arrives across many reader.read() chunks, and those
  // intermediate pushes are exactly the ones holding an unterminated buffer.
  const payload = 'y'.repeat(512 * 1024)
  const wire = `event: chat\ndata: ${payload}\n\n`
  const frames = []
  for (let i = 0; i < wire.length; i += 16 * 1024) {
    frames.push(...s.push(wire.slice(i, i + 16 * 1024)))
  }
  expect(frames).toEqual([{ event: 'chat', data: payload }])
})

test('the splitter is REUSABLE after a refusal — the buffer is not left poisoned', () => {
  const s = new SseSplitter()
  expect(() => {
    for (let i = 0; i < 40; i++) s.push('x'.repeat(64 * 1024))
  }).toThrow(SseFrameTooLargeError)
  // pumpSse builds a fresh splitter per connection, so this is belt-and-braces —
  // but a splitter that stayed full would turn one bad stream into a permanent
  // one for any caller that did reuse it.
  expect(s.push('event: chat\ndata: {"ok":1}\n\n')).toEqual([
    { event: 'chat', data: '{"ok":1}' },
  ])
})

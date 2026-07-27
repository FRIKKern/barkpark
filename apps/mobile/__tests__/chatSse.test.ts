// The SSE splitter proofs — the chat events stream's parsing seam, exercised
// without a socket. The server frames (chat_controller.ex events/fleet_events)
// are `event:` + `data:` (+ optional `id:`) blocks separated by blank lines,
// with `: keepalive` comments every 30s.
import { parseSseFrame, SseSplitter } from '../src/api/chat'

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

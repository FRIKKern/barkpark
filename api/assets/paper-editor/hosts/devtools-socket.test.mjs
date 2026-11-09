// devtools-socket.mjs against a local server that speaks the WebSocket wire format by
// hand: no Chrome, no package, any Node. Run: node --test hosts/devtools-socket.test.mjs
//
// Each wire rule the client must keep has its own test, named for the rule, so a break
// names itself: the length forms at their edges (125/126, 65535/65536), masking both
// ways, a header that arrives a byte at a time, pieces of one message (split inside a
// character too), binary frames, ping, close, and a wrong or refused handshake.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { createServer } from "node:http";
import test from "node:test";
import { DevtoolsSocket } from "./devtools-socket.mjs";

const SIZES = [0, 5, 125, 126, 300, 65535, 65536, 70000];
const lengthCode = (n) => (n < 126 ? n : n < 65536 ? 126 : 127);
const tick = (ms = 2) => new Promise((resolve) => setTimeout(resolve, ms));

// A server frame. `mask` is for the one test that sends what no server may send.
const frame = (opcode, payload, { fin = true, mask = null } = {}) => {
  const n = payload.length;
  const head = Buffer.alloc(n < 126 ? 2 : n < 65536 ? 4 : 10);
  head[0] = (fin ? 0x80 : 0) | opcode;
  head[1] = (mask ? 0x80 : 0) | lengthCode(n);
  if (n >= 126 && n < 65536) head.writeUInt16BE(n, 2);
  if (n >= 65536) head.writeBigUInt64BE(BigInt(n), 2);
  if (!mask) return Buffer.concat([head, payload]);
  return Buffer.concat([head, mask, Buffer.from(payload).map((byte, i) => byte ^ mask[i & 3])]);
};

// The client's frames, read off the server's side of the socket. next(length) checks
// the frame's length field the moment its header is in: a wrong field fails the test
// at once, instead of leaving the server waiting for bytes that never come.
function clientFrames(socket) {
  let buffer = Buffer.alloc(0);
  const done = [];
  const asks = [];
  const settle = () => {
    while (buffer.length >= 2) {
      const code = buffer[1] & 0x7f;
      const at = code === 126 ? 4 : code === 127 ? 10 : 2;
      if (buffer.length < at) return;
      const n = code === 126 ? buffer.readUInt16BE(2) : code === 127 ? Number(buffer.readBigUInt64BE(2)) : code;
      const ask = asks[0];
      if (ask && ask.length !== undefined && n !== ask.length) {
        asks.shift();
        buffer = Buffer.alloc(0);
        socket.destroy();
        return ask.reject(new assert.AssertionError({ message: `the frame's length field says ${n}, but the client sent ${ask.length} bytes`, actual: n, expected: ask.length, operator: "strictEqual" }));
      }
      if (buffer.length < at + 4 + n) return;
      const masked = Boolean(buffer[1] & 0x80);
      const mask = buffer.subarray(at, at + 4);
      const payload = Buffer.from(Buffer.from(buffer.subarray(at + 4, at + 4 + n)).map((byte, i) => byte ^ mask[i & 3]));
      const read = { opcode: buffer[0] & 0x0f, fin: Boolean(buffer[0] & 0x80), masked, code, payload };
      buffer = buffer.subarray(at + 4 + n);
      if (asks.length) asks.shift().resolve(read);
      else done.push(read);
    }
  };
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    settle();
  });
  return {
    next: (length) =>
      done.length
        ? Promise.resolve(done.shift())
        : new Promise((resolve, reject) => {
            asks.push({ length, resolve, reject });
            settle();
          }),
  };
}

// A local server, stopped when the test `t` ends, pass or fail. Each test also has a 5 s
// bound, so a client that never opens, errors or closes fails fast instead of hanging.
async function serve(t, onUpgrade, accept = (key) => createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64")) {
  const server = createServer((req, res) => res.writeHead(404).end());
  const sockets = new Set();
  server.on("connection", (socket) => sockets.add(socket));
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    server.close();
  });
  // No onUpgrade: the server answers the upgrade request with a plain 404.
  if (onUpgrade) {
    server.on("upgrade", (req, socket) => {
      socket.setNoDelay(true);
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept(req.headers["sec-websocket-key"])}\r\n\r\n`);
      onUpgrade(socket);
    });
  }
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return `ws://127.0.0.1:${server.address().port}/devtools/page/x`;
}

// An open client and the server's side of it. `messages` collects every message.
async function connect(t) {
  let server;
  const url = await serve(t, (socket) => (server = socket));
  const ws = new DevtoolsSocket(url);
  const messages = [];
  ws.addEventListener("message", ({ data }) => messages.push(data));
  await once(ws, "open");
  return { ws, server, frames: clientFrames(server), messages };
}

// Waits for check() to hold. It gives up after 4 s with an error naming what it waited
// for, and stops when the test ends, so a broken client fails the test by name and
// never leaves a loop running that keeps node alive.
const until = async (t, what, check) => {
  const end = Date.now() + 4_000;
  while (!check()) {
    if (t.signal.aborted) return;
    if (Date.now() > end) throw new Error(`waited 4 s for ${what}`);
    await tick();
  }
};

test("client frames are masked and use the shortest length form, at every edge (125/126, 65535/65536)", { timeout: 5_000 }, async (t) => {
  const { ws, frames } = await connect(t);
  for (const n of SIZES) {
    const text = "x".repeat(n);
    ws.send(text);
    const read = await frames.next(n);
    assert.equal(read.code, lengthCode(n), `a ${n}-byte message uses length code ${lengthCode(n)}`);
    assert.ok(read.masked, `a ${n}-byte client frame is masked`);
    assert.equal(read.payload.toString(), text, `a ${n}-byte message arrives intact`);
  }
});

test("server frames of every length form arrive whole, at every edge", { timeout: 5_000 }, async (t) => {
  const { server, messages } = await connect(t);
  for (const n of SIZES) server.write(frame(0x1, Buffer.from("y".repeat(n))));
  await until(t, `${SIZES.length} messages, got ${messages.length}`, () => messages.length === SIZES.length);
  assert.deepEqual(messages.map((m) => m.length), SIZES);
});

test("a header that arrives a byte at a time is read once it is whole (16-bit and 64-bit forms)", { timeout: 5_000 }, async (t) => {
  const { server, messages } = await connect(t);
  for (const n of [300, 70000]) {
    const bytes = frame(0x1, Buffer.from("z".repeat(n)));
    const headLength = n < 65536 ? 4 : 10;
    for (const byte of bytes.subarray(0, headLength)) {
      server.write(Buffer.from([byte]));
      await tick();
    }
    server.write(bytes.subarray(headLength));
  }
  await until(t, "the 300- and 70000-byte messages", () => messages.length === 2);
  assert.deepEqual(messages.map((m) => m.length), [300, 70000]);
});

test("a message in pieces, with a ping between them, arrives as one message and the ping is answered", { timeout: 5_000 }, async (t) => {
  const { server, frames, messages } = await connect(t);
  server.write(Buffer.concat([frame(0x1, Buffer.from("spl"), { fin: false }), frame(0x9, Buffer.from("p")), frame(0x0, Buffer.from("it"))]));
  const pong = await frames.next(1);
  assert.deepEqual([pong.opcode, pong.payload.toString()], [0xa, "p"]);
  await until(t, "the split message", () => messages.length === 1);
  assert.deepEqual(messages, ["split"]);
});

test("a character split across pieces is decoded whole, not piece by piece", { timeout: 5_000 }, async (t) => {
  const { server, messages } = await connect(t);
  const bytes = Buffer.from("a€b😀c"); // € is 3 bytes, 😀 is 4
  const [one, two, three] = [bytes.subarray(0, 2), bytes.subarray(2, 6), bytes.subarray(6)];
  server.write(Buffer.concat([frame(0x1, one, { fin: false }), frame(0x0, two, { fin: false }), frame(0x0, three)]));
  await until(t, "the message split inside characters", () => messages.length === 1);
  assert.equal(messages[0], "a€b😀c", "the pieces are joined before they are decoded");
});

test("a binary frame is a message, like a text frame", { timeout: 5_000 }, async (t) => {
  const { server, messages } = await connect(t);
  server.write(Buffer.concat([frame(0x2, Buffer.from("binary")), frame(0x1, Buffer.from("text after"))]));
  await until(t, "the text frame after the binary one", () => messages.includes("text after"));
  assert.deepEqual(messages, ["binary", "text after"], "the binary frame was not delivered");
});

test("a masked server frame is an error, never a message", { timeout: 5_000 }, async (t) => {
  const { ws, server, messages } = await connect(t);
  const outcome = Promise.race([once(ws, "error").then(() => "error"), once(ws, "message").then(() => "message")]);
  server.write(frame(0x1, Buffer.from("masked by the server"), { mask: Buffer.from([1, 2, 3, 4]) }));
  assert.equal(await outcome, "error", `the client read a masked server frame as ${JSON.stringify(messages)}`);
  assert.deepEqual(messages, []);
});

test("a close from the server is answered with a close, and the client fires close", { timeout: 5_000 }, async (t) => {
  const { ws, server, frames } = await connect(t);
  const closed = once(ws, "close");
  server.write(frame(0x8, Buffer.alloc(0)));
  const answer = await frames.next(0);
  assert.equal(answer.opcode, 0x8);
  server.end();
  await closed;
});

test("a server whose handshake answer is wrong is an error, never open", { timeout: 5_000 }, async (t) => {
  const url = await serve(t, () => {}, () => "wrong");
  const ws = new DevtoolsSocket(url);
  let opened = false;
  ws.addEventListener("open", () => (opened = true));
  await once(ws, "error");
  assert.equal(opened, false);
});

test("a server that refuses the upgrade is an error", { timeout: 5_000 }, async (t) => {
  const ws = new DevtoolsSocket(await serve(t, null));
  await once(ws, "error");
});

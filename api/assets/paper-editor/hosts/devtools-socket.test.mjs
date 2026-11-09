// devtools-socket.mjs against a local server that speaks the WebSocket wire format by
// hand: no Chrome, no package, any Node. Run: node --test hosts/devtools-socket.test.mjs
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { once } from "node:events";
import test from "node:test";
import { DevtoolsSocket } from "./devtools-socket.mjs";

const frame = (opcode, payload, fin = true) => {
  const n = payload.length;
  const head = Buffer.alloc(n < 126 ? 2 : n < 65536 ? 4 : 10);
  head[0] = (fin ? 0x80 : 0) | opcode;
  if (n < 126) head[1] = n;
  else if (n < 65536) (head[1] = 126), head.writeUInt16BE(n, 2);
  else (head[1] = 127), head.writeBigUInt64BE(BigInt(n), 2);
  return Buffer.concat([head, payload]);
};

// Reads whole client frames off `socket` and hands each to `onFrame`, unmasked.
function readFrames(socket, onFrame) {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      assert.ok(buffer[1] & 0x80, "every client frame is masked");
      let n = buffer[1] & 0x7f;
      let at = 2;
      if (n === 126) (n = buffer.readUInt16BE(2)), (at = 4);
      else if (n === 127) (n = Number(buffer.readBigUInt64BE(2))), (at = 10);
      if (buffer.length < at + 4 + n) return;
      const mask = buffer.subarray(at, at + 4);
      const payload = Buffer.from(buffer.subarray(at + 4, at + 4 + n)).map((byte, i) => byte ^ mask[i & 3]);
      onFrame(buffer[0] & 0x0f, Buffer.from(payload));
      buffer = buffer.subarray(at + 4 + n);
    }
  });
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
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept(req.headers["sec-websocket-key"])}\r\n\r\n`);
      onUpgrade(socket);
    });
  }
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return `ws://127.0.0.1:${server.address().port}/devtools/page/x`;
}

test("text both ways at every length form, a split message, ping and close", { timeout: 5_000 }, async (t) => {
  const sizes = [5, 300, 70_000];
  const got = [];
  const url = await serve(t, (socket) =>
    readFrames(socket, (opcode, payload) => {
      got.push([opcode, payload.toString()]);
      if (opcode === 0x1) socket.write(frame(0x1, payload));
      if (got.length === sizes.length) {
        socket.write(Buffer.concat([frame(0x1, Buffer.from("spl"), false), frame(0x9, Buffer.from("p")), frame(0x0, Buffer.from("it"))]));
      }
      if (opcode === 0xa) socket.write(frame(0x8, Buffer.alloc(0)));
      if (opcode === 0x8) socket.end();
    }),
  );
  const ws = new DevtoolsSocket(url);
  const messages = [];
  ws.addEventListener("message", ({ data }) => messages.push(data));
  await once(ws, "open");
  for (const n of sizes) ws.send("x".repeat(n));
  await once(ws, "close");
  assert.deepEqual(messages, [...sizes.map((n) => "x".repeat(n)), "split"]);
  assert.deepEqual(got.map(([opcode, text]) => [opcode, text.length]), [[1, 5], [1, 300], [1, 70_000], [0xa, 1], [0x8, 0]]);
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

// A small WebSocket client for Chrome's DevTools socket, built on node:http alone.
//
// Node 20, the version CI runs, has no global WebSocket unless node starts with
// --experimental-websocket, so the rigs that drive Chrome died there. This client needs
// no flag and no package, and the rigs use it on every Node, so they run the same code
// everywhere. It speaks only what Cdp in browser.mjs uses: text frames out, masked as a
// client must; text or binary frames in, whole or in pieces; ping, and close. Like the
// WHATWG WebSocket, it fires "open", "message" (event.data is the text), "error" and
// "close".
import { createHash, randomBytes } from "node:crypto";
import { request } from "node:http";

const ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export class DevtoolsSocket extends EventTarget {
  #socket = null;
  #buffer = Buffer.alloc(0);
  #pieces = [];
  #failed = false;

  constructor(url) {
    super();
    const key = randomBytes(16).toString("base64");
    const req = request(url.replace(/^ws:/, "http:"), {
      headers: { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Key": key, "Sec-WebSocket-Version": "13" },
    });
    req.on("upgrade", (res, socket, head) => {
      this.#socket = socket;
      socket.on("error", () => this.#fail());
      socket.on("close", () => this.dispatchEvent(new Event("close")));
      if (res.headers["sec-websocket-accept"] !== createHash("sha1").update(key + ACCEPT_GUID).digest("base64")) return this.#fail();
      socket.on("data", (chunk) => this.#read(chunk));
      this.dispatchEvent(new Event("open"));
      if (head.length) this.#read(head);
    });
    req.on("response", (res) => {
      res.resume();
      this.#fail();
    });
    req.on("error", () => this.#fail());
    req.end();
  }

  send(text) {
    this.#write(0x1, Buffer.from(String(text), "utf8"));
  }

  close() {
    if (!this.#socket || this.#socket.writableEnded) return;
    this.#write(0x8, Buffer.alloc(0));
    this.#socket.end();
  }

  #fail() {
    if (this.#failed) return;
    this.#failed = true;
    this.#socket?.destroy();
    this.dispatchEvent(new Event("error"));
  }

  #write(opcode, payload) {
    if (!this.#socket || this.#socket.writableEnded) return;
    const mask = randomBytes(4);
    const n = payload.length;
    const head = Buffer.alloc(n < 126 ? 2 : n < 65536 ? 4 : 10);
    head[0] = 0x80 | opcode;
    if (n < 126) head[1] = 0x80 | n;
    else if (n < 65536) (head[1] = 0x80 | 126), head.writeUInt16BE(n, 2);
    else (head[1] = 0x80 | 127), head.writeBigUInt64BE(BigInt(n), 2);
    const body = Buffer.from(payload);
    for (let i = 0; i < n; i++) body[i] ^= mask[i & 3];
    this.#socket.write(Buffer.concat([head, mask, body]));
  }

  #read(chunk) {
    this.#buffer = this.#buffer.length ? Buffer.concat([this.#buffer, chunk]) : chunk;
    while (this.#buffer.length >= 2) {
      const b = this.#buffer;
      // A server never masks its frames; one that does is not speaking WebSocket.
      if (b[1] & 0x80) return this.#fail();
      let n = b[1] & 0x7f;
      let at = 2;
      if (n === 126) {
        if (b.length < 4) return;
        (n = b.readUInt16BE(2)), (at = 4);
      } else if (n === 127) {
        if (b.length < 10) return;
        (n = Number(b.readBigUInt64BE(2))), (at = 10);
      }
      if (b.length < at + n) return;
      const payload = b.subarray(at, at + n);
      this.#buffer = b.subarray(at + n);
      const [fin, opcode] = [b[0] & 0x80, b[0] & 0x0f];
      if (opcode === 0x8) return this.close();
      if (opcode === 0x9) this.#write(0xa, payload);
      if (opcode > 0x2) continue;
      this.#pieces.push(payload);
      if (!fin) continue;
      const message = new Event("message");
      message.data = Buffer.concat(this.#pieces).toString("utf8");
      this.#pieces = [];
      this.dispatchEvent(message);
    }
  }
}

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { start } from "./server.mjs";

const SERVER = fileURLToPath(new URL("./server.mjs", import.meta.url));
const standIn = async () => "export const render = () => 'stand-in';";

async function get(url, init) {
  const res = await fetch(url, init);
  return { status: res.status, type: res.headers.get("content-type"), body: await res.text() };
}

const plain = await start({ standIn });
try {
  const page = await get(plain.url);
  assert.equal(page.status, 200);
  assert.equal(page.type, "text/html");
  assert.match(page.body, /<title>Editor testing ground<\/title>/);
  assert.deepEqual(JSON.parse((await get(`${plain.url}build.json`)).body).fold, undefined, "no fold switch: the page folds in the browser");
  assert.match(JSON.parse((await get(`${plain.url}build.json`)).body).sha, /^[0-9a-f]{7,}$/);
  const module = await get(`${plain.url}src/testing-ground/traps.mjs`);
  assert.equal(module.type, "text/javascript");
  assert.match(module.body, /export function lights/);
  assert.equal((await get(`${plain.url}build/bp-paper-editor.css`)).type, "text/css");
  assert.equal(JSON.parse((await get(`${plain.url}pack/samples.json`)).body).length, 80);
  assert.equal((await get(`${plain.url}reader-standin.js`)).body, "export const render = () => 'stand-in';");
  const outside = ["package", "json"].join(".");
  for (const path of [`src/../${outside}`, `src/testing-ground/../../${outside}`, `src/%2e%2e/${outside}`, "src/no-such.mjs", "src/testing-ground", "nope"])
    assert.equal((await get(`${plain.url}${path}`)).status, 404, `${path} is not served`);
  assert.equal((await get(plain.url, { method: "POST" })).status, 404, "only GET reads files");
  assert.equal((await get(`${plain.url}fold`, { method: "POST", body: "{}" })).status, 404, "no fold switch, no /fold");
} finally {
  await plain.close();
}

const broken = await start({ standIn: async () => { throw new Error("no react here\nmore"); } });
try {
  assert.equal((await get(`${broken.url}reader-standin.js`)).body, 'export const render = () => { throw new Error("The stand-in reader did not build: no react here"); };');
} finally {
  await broken.close();
}

const fold = { name: "stub fold", apply: async (blocks, ops) => { if (ops[0].op === "bad") throw new Error("refused: bad"); return [...blocks, ops[0].block]; } };
const switched = await start({ standIn, fold });
try {
  assert.equal(JSON.parse((await get(`${switched.url}build.json`)).body).fold, "stub fold");
  const ok = await get(`${switched.url}fold`, { method: "POST", body: JSON.stringify({ blocks: [{ id: "a" }], ops: [{ op: "append-block", block: { id: "b" } }] }) });
  assert.deepEqual([ok.status, ok.type, JSON.parse(ok.body)], [200, "application/json", { blocks: [{ id: "a" }, { id: "b" }] }]);
  const no = await get(`${switched.url}fold`, { method: "POST", body: JSON.stringify({ blocks: [], ops: [{ op: "bad" }] }) });
  assert.deepEqual([no.status, JSON.parse(no.body)], [422, { error: "refused: bad" }]);
} finally {
  await switched.close();
}

function cli(args, env = {}) {
  const child = spawn(process.execPath, [SERVER, ...args], { env: { ...process.env, BARKPARK_TG_TOKEN: "", ...env } });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  return {
    exited: new Promise((resolve) => child.on("exit", (code) => resolve({ code, out }))),
    printed: async (re) => {
      const until = Date.now() + 20000;
      while (!re.test(out) && Date.now() < until && child.exitCode === null) await new Promise((r) => setTimeout(r, 50));
      return out;
    },
    stop: () => child.kill(),
  };
}

for (const [args, why, env] of [
  [["25044"], /only main for now; PR heads and contract trees come next, got 25044/],
  [["main", "1.19"], /one build at a time, got main 1.19/],
  [["--port"], /unknown or malformed flag --port$/m],
  [["--port=abc"], /unknown or malformed flag --port=abc/],
  [["--open"], /unknown or malformed flag --open/],
  [["--barkpark="], /unknown or malformed flag --barkpark=/],
  [["--barkpark=http://127.0.0.1:4817"], /--barkpark needs BARKPARK_TG_TOKEN/],
  [["--barkpark=https://guerrilla.barkpark.cloud"], /guerrilla.barkpark.cloud is not this machine/, { BARKPARK_TG_TOKEN: "t" }],
]) {
  const { code, out } = await cli(args, env).exited;
  assert.equal(code, 2, `${args.join(" ")} is a usage error`);
  assert.match(out, why);
  assert.match(out, /usage: npm run try \[main\]/);
}

const quiet = cli(["main", "--no-open", "--port=0"]);
try {
  const line = await quiet.printed(/\n/);
  assert.match(line, /^testing ground on main: http:\/\/127\.0\.0\.1:\d+\/\n$/, "no fold switch named");
} finally {
  quiet.stop();
}

const fixed = cli(["--no-open"]);
try {
  assert.match(await fixed.printed(/4417/), /testing ground on main: http:\/\/127\.0\.0\.1:4417\/|EADDRINUSE.*4417/, "npm run try listens on 4417 unless told otherwise");
} finally {
  fixed.stop();
}

const local = cli(["--barkpark=http://127.0.0.1:4999", "--no-open", "--port=0"], { BARKPARK_TG_TOKEN: "t" });
try {
  assert.match(await local.printed(/fold:/), /testing ground on main: http:\/\/127\.0\.0\.1:\d+\/ · fold: Local Barkpark at http:\/\/127\.0\.0\.1:4999/);
} finally {
  local.stop();
}

const bin = mkdtempSync(join(tmpdir(), "tg-open-"));
try {
  writeFileSync(join(bin, "open"), `#!/bin/sh\necho "$1" > "${join(bin, "opened")}"\n`);
  chmodSync(join(bin, "open"), 0o755);
  const opens = cli(["--port=0"], { PATH: `${bin}:${process.env.PATH}` });
  try {
    const url = (await opens.printed(/main: (\S+)/)).match(/main: (\S+)/)[1];
    const until = Date.now() + 10000;
    while (!existsSync(join(bin, "opened")) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    assert.equal(readFileSync(join(bin, "opened"), "utf8").trim(), url, "npm run try opens the page");
  } finally {
    opens.stop();
  }
} finally {
  rmSync(bin, { recursive: true, force: true });
}

console.log("PASS  testing-ground server: routes, the fold switch, the stand-in fallback and every CLI flag");

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { get as rawGet } from "node:http";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { reportArgs } from "./repro.mjs";
import { start } from "./server.mjs";

const SERVER = fileURLToPath(new URL("./server.mjs", import.meta.url));
const standIn = async () => "export const render = () => 'stand-in';";

function getAsIs(url, path) {
  return new Promise((resolve, reject) => rawGet(url, { path: `/${path}` }, (res) => { res.resume(); resolve(res.statusCode); }).on("error", reject));
}

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
    assert.equal(await getAsIs(plain.url, path), 404, `${path} is not served`);
  assert.equal((await get(plain.url, { method: "POST" })).status, 404, "only GET reads files");
  assert.equal((await get(`${plain.url}fold`, { method: "POST", body: "{}" })).status, 404, "no fold switch, no /fold");
  assert.equal(await getAsIs(plain.url, "%E0%A4%A"), 400, "a malformed url is answered");
  assert.equal((await get(plain.url)).status, 200, "and the server keeps serving");
} finally {
  await plain.close();
}

const MAIN_ASSETS = join(fileURLToPath(new URL("../../../../priv/static/assets", import.meta.url)));
const one = await start({ standIn, builds: [{ label: "main", sha: "aaaaaaaaaa", dir: MAIN_ASSETS }] });
try {
  assert.match((await get(one.url)).body, /<title>Editor testing ground<\/title>[\s\S]*class="tg-stamp"/, "one build: / is the editor, with its stamp");
  assert.match((await get(`${one.url}b/0/`)).body, /class="tg-edit"/);
  for (const path of ["split.html", "b/1/", "b/1/build.json", "b/0", "b/x/"]) assert.equal((await get(`${one.url}${path}`)).status, 404, `${path} with one build`);
} finally {
  await one.close();
}

const two = await start({ standIn, builds: [{ label: "main", sha: "aaaaaaaaaa", dir: MAIN_ASSETS }, { label: "PR #7", sha: "bbbbbbbbbb", dir: MAIN_ASSETS }] });
try {
  const shell = await get(two.url);
  assert.match(shell.body, /class="tg-split"[\s\S]*<iframe class="tg-frame"><\/iframe>\s*<iframe class="tg-frame"><\/iframe>/, "two builds: / is the split screen");
  assert.equal((await get(`${two.url}?doc=drill:D01`)).body, shell.body, "the query rides along to the frames");
  assert.deepEqual(JSON.parse((await get(`${two.url}b/1/build.json`)).body), { label: "PR #7", sha: "bbbbbbbbbb" });
  assert.deepEqual(JSON.parse((await get(`${two.url}b/0/build.json`)).body), { label: "main", sha: "aaaaaaaaaa" });
  assert.match((await get(`${two.url}b/1/`)).body, /class="tg-edit"/, "each frame is the editor page");
  assert.equal((await get(`${two.url}b/1/build/bp-paper-editor.css`)).type, "text/css");
  assert.equal((await get(`${two.url}b/1/src/testing-ground/page/mirror.mjs`)).type, "text/javascript");
  assert.equal((await get(`${two.url}b/2/`)).status, 404);
  assert.equal((await get(`${two.url}b/2/src/testing-ground/page/mirror.mjs`)).status, 404, "a frame number past the builds serves nothing");
} finally {
  await two.close();
}

const bpDir = mkdtempSync(join(tmpdir(), "tg-bp-"));
process.on("exit", () => rmSync(bpDir, { recursive: true, force: true }));
const fakeBp = (name, body) => {
  const path = join(bpDir, name);
  writeFileSync(path, `#!${process.execPath}\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
};
const said = join(bpDir, "argv.json");
const bpOk = fakeBp("bp-ok", `require("fs").writeFileSync(${JSON.stringify(said)}, JSON.stringify(process.argv.slice(2))); console.error("draft note"); console.log("published"); console.log(JSON.stringify({ id: "task-fake1", status: "published" }));`);
const bpDown = fakeBp("bp-down", `console.error("bp: 401 unauthorized\\nrun bp login"); process.exit(3);`);
const bpOdd = fakeBp("bp-odd", `console.log("created, somehow");`);
const report = { what: "Six Enters left one line", repro: { v: 1, build: { label: "main", sha: "aaaaaaaaaa" }, fold: "stub", doc: "drill:D01", width: "desk", theme: "light", start: [], events: [], batches: [], red: [] } };
const postJson = (url, body) => get(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const filing = await start({ standIn, bp: bpOk });
try {
  const preview = await postJson(`${filing.url}report/preview`, report);
  assert.deepEqual([preview.status, JSON.parse(preview.body).args], [200, reportArgs(report)], "the preview is the exact bp argv");
  assert.equal(existsSync(said), false, "a preview runs nothing");
  const filed = await postJson(`${filing.url}report`, report);
  assert.deepEqual([filed.status, JSON.parse(filed.body)], [200, { id: "task-fake1" }]);
  assert.deepEqual(JSON.parse(readFileSync(said, "utf8")), reportArgs(report), "bp got exactly what the preview showed");
  assert.deepEqual([(await postJson(`${filing.url}b/0/report/preview`, report)).status], [200], "a frame posts under its own path");
  const empty = await postJson(`${filing.url}report`, { ...report, what: " " });
  assert.deepEqual([empty.status, JSON.parse(empty.body)], [400, { error: "Say what went wrong first." }]);
  const garbled = await get(`${filing.url}report`, { method: "POST", headers: { "content-type": "application/json" }, body: "{" });
  assert.equal(garbled.status, 400, "a body that is not JSON is answered");
  assert.equal((await get(`${filing.url}report`, { method: "POST", body: JSON.stringify(report) })).status, 415, "another origin cannot post a plain form that files a task");
  assert.equal((await get(`${filing.url}report`)).status, 404, "GET files nothing");
  assert.equal((await get(`${filing.url}fold`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status, 404, "no fold switch, still no /fold");
} finally {
  await filing.close();
}
for (const [bp, error] of [[bpDown, "bp failed: bp: 401 unauthorized run bp login"], [bpOdd, "bp answered without a task id: created, somehow"], [join(bpDir, "no-such-bp"), /^bp failed: .*ENOENT/]]) {
  const failing = await start({ standIn, bp });
  try {
    const answer = await postJson(`${failing.url}report`, report);
    assert.equal(answer.status, 502);
    if (typeof error === "string") assert.equal(JSON.parse(answer.body).error, error);
    else assert.match(JSON.parse(answer.body).error, error);
  } finally {
    await failing.close();
  }
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
  const json = { "content-type": "application/json" };
  assert.equal((await get(`${switched.url}fold`, { method: "POST", body: "{}" })).status, 415, "a page on another origin cannot post a plain form to the fold");
  const ok = await get(`${switched.url}fold`, { method: "POST", headers: json, body: JSON.stringify({ blocks: [{ id: "a" }], ops: [{ op: "append-block", block: { id: "b" } }] }) });
  assert.deepEqual([ok.status, ok.type, JSON.parse(ok.body)], [200, "application/json", { blocks: [{ id: "a" }, { id: "b" }] }]);
  const no = await get(`${switched.url}fold`, { method: "POST", headers: json, body: JSON.stringify({ blocks: [], ops: [{ op: "bad" }] }) });
  assert.deepEqual([no.status, JSON.parse(no.body)], [422, { error: "refused: bad" }]);
  assert.equal((await get(`${switched.url}fold`, { method: "POST", headers: json, body: "{" })).status, 422, "a garbled batch is answered, and the server lives on");
  assert.equal((await get(switched.url)).status, 200);
} finally {
  await switched.close();
}

const bin = mkdtempSync(join(tmpdir(), "tg-open-"));
writeFileSync(join(bin, "open"), `#!/bin/sh\necho "$1" >> "${join(bin, "opened")}"\n`);
chmodSync(join(bin, "open"), 0o755);
writeFileSync(join(bin, "npm"), "#!/bin/sh\necho \"fake npm: no build\"\nexit 1\n");
chmodSync(join(bin, "npm"), 0o755);
process.on("exit", () => rmSync(bin, { recursive: true, force: true }));
const children = new Set();
for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => { for (const child of children) child.kill(); process.exit(130); });

function cli(args, env = {}) {
  const child = spawn(process.execPath, [SERVER, ...args], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, BARKPARK_TG_TOKEN: "", ...env } });
  children.add(child);
  child.on("exit", () => children.delete(child));
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  const deadline = setTimeout(() => child.kill(), 20000);
  return {
    exited: new Promise((resolve) => child.on("exit", (code) => { clearTimeout(deadline); resolve({ code, out }); })),
    printed: async (re) => {
      const until = Date.now() + 20000;
      while (!re.test(out) && Date.now() < until && child.exitCode === null) await new Promise((r) => setTimeout(r, 50));
      return out;
    },
    stop: () => child.kill(),
  };
}

for (const [args, why, env] of [
  [["main", "1.19", "25044"], /two builds at most, got main 1\.19 25044/],
  [["1.99"], /no recorded tree for contract 1\.99; recorded: 1\.14, /],
  [["main", "0"], /a build is main, a PR number or a contract like 1\.19, got 0/],
  [["x--y", "--no-open"], /a build is main, a PR number or a contract like 1\.19, got x--y/],
  [["--port"], /unknown or malformed flag --port$/m],
  [["--port=abc"], /unknown or malformed flag --port=abc/],
  [["--port=99999"], /--port=99999 is not a port/],
  [["--port=4611", "--port=4612"], /--port given twice/],
  [["--no-open", "--no-open"], /--no-open given twice/],
  [["--open"], /unknown or malformed flag --open/],
  [["--barkpark="], /unknown or malformed flag --barkpark=/],
  [["--barkpark=http://127.0.0.1:4817"], /--barkpark needs BARKPARK_TG_TOKEN/],
  [["--barkpark=https://guerrilla.barkpark.cloud"], /guerrilla.barkpark.cloud is not this machine/, { BARKPARK_TG_TOKEN: "t" }],
]) {
  const { code, out } = await cli(args, env).exited;
  assert.equal(code, 2, `${args.join(" ")} is a usage error`);
  assert.match(out, why);
  assert.match(out, /usage: npm run try \[main \| <PR number> \| <contract like 1\.19>\] \[<second build>\]/);
}

const failed = await cli(["1.19", "--no-open", "--port=0"]).exited;
assert.equal(failed.code, 1, "a build that fails stops npm run try");
assert.match(failed.out, /^building contract 1\.19 at 648bfeeb44\n/);
assert.match(failed.out, /npm run try: (git archive 648bfeeb44|npm run build for contract 1\.19 at 648bfeeb44 failed:\nfake npm: no build)/);

const quiet = cli(["main", "--no-open", "--port=0"]);
try {
  const line = await quiet.printed(/\n/);
  assert.match(line, /^testing ground on main at [0-9a-f]{10}: http:\/\/127\.0\.0\.1:\d+\/\n$/, "no fold switch named");
} finally {
  quiet.stop();
}

const fixed = cli(["--no-open"]);
try {
  assert.match(await fixed.printed(/4417/), /testing ground on main at [0-9a-f]{10}: http:\/\/127\.0\.0\.1:4417\/|EADDRINUSE.*4417/, "npm run try listens on 4417 unless told otherwise");
} finally {
  fixed.stop();
}

const local = cli(["--barkpark=http://127.0.0.1:4999/--port=1", "--no-open", "--port=0"], { BARKPARK_TG_TOKEN: "t" });
try {
  assert.match(await local.printed(/fold:/), /testing ground on main at [0-9a-f]{10}: http:\/\/127\.0\.0\.1:\d+\/ · fold: Local Barkpark at http:\/\/127\.0\.0\.1:4999/);
} finally {
  local.stop();
}

const opens = cli(["--port=0"]);
try {
  const url = (await opens.printed(/[0-9a-f]{10}: (\S+)/)).match(/[0-9a-f]{10}: (\S+)/)[1];
  const until = Date.now() + 10000;
  while (!existsSync(join(bin, "opened")) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
  assert.equal(readFileSync(join(bin, "opened"), "utf8").trim(), url, "npm run try opens the page, and every --no-open run before it opened nothing");
} finally {
  opens.stop();
}

console.log("PASS  testing-ground server: routes, the fold switch, the stand-in fallback and every CLI flag");

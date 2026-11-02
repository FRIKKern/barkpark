import { createServer } from "node:http";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { barkparkFold } from "./barkpark-fold.mjs";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = join(SRC, "../../../..");
const PACK = join(REPO, "api/priv/portable_doc/goldens");
const MAIN_ASSETS = join(REPO, "api/priv/static/assets");
const BUNDLE_FILES = ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css"];
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };

const git = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8" }).trim();

function primaryJs() {
  return join(dirname(git(REPO, "rev-parse", "--path-format=absolute", "--git-common-dir")), "js");
}

export async function readerStandIn() {
  const react = join(REPO, "js/packages/react");
  const primary = primaryJs();
  const contents = `import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { PortableDoc } from "./src/index";
import { fieldBlocks } from "./src/field-blocks";
import { embedBlocks } from "./src/embed";
const blocks = { ...fieldBlocks, ...embedBlocks() };
export const render = (value) => renderToStaticMarkup(createElement(PortableDoc, { value, blocks }));`;
  const result = await build({
    stdin: { contents, resolveDir: react, loader: "js" },
    bundle: true,
    format: "esm",
    platform: "browser",
    write: false,
    minify: true,
    jsx: "automatic",
    logLevel: "silent",
    nodePaths: [join(primary, "packages/react/node_modules"), join(primary, "node_modules")],
    define: { "process.env.NODE_ENV": '"production"' },
  });
  return result.outputFiles[0].text;
}

export function packSamples() {
  return readdirSync(join(PACK, "blocks")).sort().map((name) => {
    const { type, input, expectedHtml } = JSON.parse(readFileSync(join(PACK, "blocks", name), "utf8"));
    return { type, input, expectedHtml };
  });
}

export function mainBuild() {
  return { label: "main", sha: git(REPO, "log", "-1", "--format=%h", "--", "api/priv/static/assets/bp-paper-editor.bundle.js"), dir: MAIN_ASSETS };
}

function inside(root, rel) {
  const path = normalize(join(root, rel));
  return path.startsWith(root + sep) && extname(path) in TYPES && existsSync(path) ? path : null;
}

async function foldThrough(fold, req, res) {
  let body = "";
  for await (const chunk of req) body += chunk;
  const { blocks, ops } = JSON.parse(body);
  try {
    res.end(JSON.stringify({ blocks: await fold.apply(blocks, ops) }));
  } catch (error) {
    res.statusCode = 422;
    res.end(JSON.stringify({ error: error.message }));
  }
}

async function standInModule(make) {
  try {
    return await make();
  } catch (error) {
    return `export const render = () => { throw new Error(${JSON.stringify(`The stand-in reader did not build: ${error.message.split("\n")[0]}`)}); };`;
  }
}

export async function start({ build: picked = mainBuild(), port = 0, fold = null, standIn = readerStandIn } = {}) {
  const reader = await standInModule(standIn);
  const files = {
    "/index.html": () => readFileSync(join(SRC, "testing-ground/page/index.html")),
    "/build.json": () => JSON.stringify({ label: picked.label, sha: picked.sha, fold: fold?.name }),
    "/pack/samples.json": () => JSON.stringify(packSamples()),
    "/pack/fragments.json": () => readFileSync(join(PACK, "fragments.json")),
    "/pack/paper-surface.css": () => readFileSync(join(PACK, "css/paper-surface.css")),
    "/pack/code-tokens.css": () => readFileSync(join(PACK, "css/code-tokens.css")),
    "/reader-standin.js": () => reader,
  };
  for (const name of BUNDLE_FILES) files[`/build/${name}`] = () => readFileSync(join(picked.dir, name));

  const server = createServer((req, res) => {
    const asked = decodeURIComponent(req.url.split("?")[0]);
    const path = asked === "/" ? "/index.html" : asked;
    if (fold && req.method === "POST" && path === "/fold") {
      res.setHeader("content-type", TYPES[".json"]);
      return foldThrough(fold, req, res);
    }
    const route = files[path];
    const file = path.startsWith("/src/") && inside(SRC, path.slice(5));
    if (req.method !== "GET" || (!route && !file)) {
      res.statusCode = 404;
      return res.end("not found");
    }
    res.setHeader("content-type", TYPES[extname(path)]);
    res.setHeader("cache-control", "no-store");
    res.end(route ? route() : readFileSync(file));
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => new Promise((resolve) => server.close(resolve)) };
}

function usage(why) {
  console.error(`npm run try: ${why}\nusage: npm run try [main] [-- --port=<n>] [--no-open] [--barkpark=<http://localhost:port>]  (--barkpark needs BARKPARK_TG_TOKEN)`);
  process.exit(2);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const known = /^--(port=\d+|no-open|barkpark=.+)$/;
  const [which = "main", ...extra] = args.filter((a) => !a.startsWith("--"));
  const bad = args.find((a) => a.startsWith("--") && !known.test(a));
  if (bad) usage(`unknown or malformed flag ${bad}`);
  if (extra.length) usage(`one build at a time, got ${[which, ...extra].join(" ")}`);
  if (which !== "main") usage(`only main for now; PR heads and contract trees come next, got ${which}`);
  const flag = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
  const token = process.env.BARKPARK_TG_TOKEN;
  if (flag("barkpark") && !token) usage("--barkpark needs BARKPARK_TG_TOKEN, a write token for that local Barkpark");
  let fold;
  try {
    fold = flag("barkpark") && barkparkFold(flag("barkpark"), token);
  } catch (error) {
    usage(error.message);
  }
  const port = flag("port");
  const { url } = await start({ port: port === undefined ? 4417 : Number(port), fold });
  console.log(`testing ground on main: ${url}${fold ? ` · fold: ${fold.name}` : ""}`);
  if (!args.includes("--no-open")) spawn("open", [url], { stdio: "ignore", detached: true }).unref();
}

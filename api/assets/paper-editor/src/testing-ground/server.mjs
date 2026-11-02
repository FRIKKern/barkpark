import { createServer } from "node:http";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { barkparkFold } from "./barkpark-fold.mjs";
import { besideMain, makeBuild, pickBuild } from "./builds.mjs";

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
  return { label: "main", sha: git(REPO, "log", "-1", "--format=%H", "--", "api/priv/static/assets/bp-paper-editor.bundle.js").slice(0, 10), dir: MAIN_ASSETS };
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

export async function start({ builds = [mainBuild()], port = 0, fold = null, standIn = readerStandIn } = {}) {
  const reader = await standInModule(standIn);
  const page = (name) => () => readFileSync(join(SRC, "testing-ground/page", name));
  const files = {
    "/index.html": page("index.html"),
    "/pack/samples.json": () => JSON.stringify(packSamples()),
    "/pack/fragments.json": () => readFileSync(join(PACK, "fragments.json")),
    "/pack/paper-surface.css": () => readFileSync(join(PACK, "css/paper-surface.css")),
    "/pack/code-tokens.css": () => readFileSync(join(PACK, "css/code-tokens.css")),
    "/reader-standin.js": () => reader,
  };
  if (builds.length > 1) files["/split.html"] = page("split.html");
  const perBuild = (build) => ({
    "/build.json": () => JSON.stringify({ label: build.label, sha: build.sha, fold: fold?.name }),
    ...Object.fromEntries(BUNDLE_FILES.map((name) => [`/build/${name}`, () => readFileSync(join(build.dir, name))])),
  });

  const server = createServer((req, res) => {
    let asked;
    try {
      asked = decodeURIComponent(req.url.split("?")[0]);
    } catch {
      res.statusCode = 400;
      return res.end("malformed url");
    }
    const [, index, rest] = asked.match(/^\/b\/(\d+)(\/.*)$/) || [null, "0", asked];
    const build = builds[Number(index)];
    const split = rest === asked && builds.length > 1;
    const path = rest === "/" ? (split ? "/split.html" : "/index.html") : rest;
    if (fold && req.method === "POST" && path === "/fold") {
      if (req.headers["content-type"] !== TYPES[".json"]) {
        res.statusCode = 415;
        return res.end("the fold takes application/json only");
      }
      res.setHeader("content-type", TYPES[".json"]);
      return foldThrough(fold, req, res);
    }
    const route = build && { ...files, ...perBuild(build) }[path];
    const file = path.startsWith("/src/") && inside(SRC, path.slice(5));
    if (req.method !== "GET" || !build || (!route && !file)) {
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
  console.error(`npm run try: ${why}\nusage: npm run try [main | <PR number> | <contract like 1.19>] [<second build>] [-- --port=<n>] [--no-open] [--barkpark=<http://localhost:port>]\n  one build that is not main opens beside main; two open side by side; --barkpark needs BARKPARK_TG_TOKEN`);
  process.exit(2);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => process.exit(130));
  const args = process.argv.slice(2);
  const known = /^--(port=\d+|no-open|barkpark=.+)$/;
  const names = args.filter((a) => !a.startsWith("--"));
  const bad = args.find((a) => a.startsWith("--") && !known.test(a));
  if (bad) usage(`unknown or malformed flag ${bad}`);
  const twice = args.find((a, i) => a.startsWith("--") && args.findIndex((b) => b.split("=")[0] === a.split("=")[0]) !== i);
  if (twice) usage(`${twice.split("=")[0]} given twice`);
  if (names.length > 2) usage(`two builds at most, got ${names.join(" ")}`);
  let picks;
  try {
    picks = besideMain(names).map((name) => (name === "main" ? null : pickBuild(name, { repo: REPO })));
  } catch (error) {
    usage(error.message);
  }
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
  if (Number(port) > 65535) usage(`--port=${port} is not a port`);
  let builds;
  try {
    builds = picks.map((pick) => {
      if (!pick) return mainBuild();
      console.log(`building ${pick.label} at ${pick.sha.slice(0, 10)}`);
      return makeBuild(pick, { repo: REPO });
    });
  } catch (error) {
    console.error(`npm run try: ${error.message}`);
    process.exit(1);
  }
  const { url } = await start({ builds, port: port === undefined ? 4417 : Number(port), fold });
  console.log(`testing ground on ${builds.map((b) => `${b.label} at ${b.sha}`).join(" beside ")}: ${url}${fold ? ` · fold: ${fold.name}` : ""}`);
  if (!args.includes("--no-open")) spawn("open", [url], { stdio: "ignore", detached: true }).unref();
}

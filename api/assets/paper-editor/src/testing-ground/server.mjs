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
  return path.startsWith(root + sep) && existsSync(path) ? path : null;
}

async function foldThrough(fold, req, res) {
  let body = "";
  for await (const chunk of req) body += chunk;
  const { blocks, ops } = JSON.parse(body);
  res.setHeader("content-type", "application/json");
  try {
    res.end(JSON.stringify({ blocks: await fold.apply(blocks, ops) }));
  } catch (error) {
    res.statusCode = 422;
    res.end(JSON.stringify({ error: error.message }));
  }
}

export async function start({ build: picked = mainBuild(), port = 0, fold = null } = {}) {
  let standIn;
  try {
    standIn = await readerStandIn();
  } catch (error) {
    standIn = `export const render = () => { throw new Error(${JSON.stringify(`stand-in reader did not build: ${error.message.split("\n")[0]}`)}); };`;
  }
  const routes = {
    "/": () => readFileSync(join(SRC, "testing-ground/page/index.html")),
    "/build.json": () => JSON.stringify({ label: picked.label, sha: picked.sha, fold: fold?.name || null }),
    "/pack/samples.json": () => JSON.stringify(packSamples()),
    "/pack/fragments.json": () => readFileSync(join(PACK, "fragments.json")),
    "/pack/paper-surface.css": () => readFileSync(join(PACK, "css/paper-surface.css")),
    "/pack/code-tokens.css": () => readFileSync(join(PACK, "css/code-tokens.css")),
    "/reader-standin.js": () => standIn,
  };
  for (const name of BUNDLE_FILES) routes[`/build/${name}`] = () => readFileSync(join(picked.dir, name));

  const server = createServer((req, res) => {
    const path = decodeURIComponent(req.url.split("?")[0]);
    if (fold && req.method === "POST" && path === "/fold") return foldThrough(fold, req, res);
    const route = routes[path];
    const file = !route && path.startsWith("/src/") ? inside(SRC, path.slice(5)) : null;
    if (req.method !== "GET" || (!route && !file)) {
      res.statusCode = 404;
      return res.end("not found");
    }
    res.setHeader("content-type", TYPES[extname(path)] || (path === "/" ? "text/html" : "application/octet-stream"));
    res.setHeader("cache-control", "no-store");
    res.end(route ? route() : readFileSync(file));
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => new Promise((resolve) => server.close(resolve)) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const which = args.find((a) => !a.startsWith("--")) || "main";
  if (which !== "main") {
    console.error(`npm run try ${which}: only main for now; PR heads and contract trees come next.`);
    process.exit(2);
  }
  const flag = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
  const fold = flag("barkpark") ? barkparkFold(flag("barkpark"), process.env.BARKPARK_TG_TOKEN || "barkpark-dev-token") : null;
  const { url } = await start({ port: Number(flag("port") || 4417), fold });
  console.log(`testing ground on main: ${url}${fold ? ` · fold: ${fold.name}` : ""}`);
  if (!args.includes("--no-open")) spawn(process.platform === "darwin" ? "open" : "xdg-open", [url], { stdio: "ignore", detached: true }).unref();
}

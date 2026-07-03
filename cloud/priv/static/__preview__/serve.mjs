// serve.mjs — the preview harness's zero-dependency static server (charter D63).
//
// ─────────────────────────────────────────────────────────────────────────────
//  Cloud SPA preview harness — "LOOK AT IT" in one command
// ─────────────────────────────────────────────────────────────────────────────
//  Render any committed screen state of the Cloud dashboard with no backend.
//
//    make cloud-preview            # serve on http://localhost:4180
//    node cloud/priv/static/__preview__/serve.mjs [--port 4180]
//
//  Then open a scenario (see scenarios.mjs → SCENARIO_NAMES):
//    http://localhost:4180/?scen=empty
//    http://localhost:4180/?scen=mixed-fleet
//    http://localhost:4180/?scen=provisioning&theme=dark
//    http://localhost:4180/?scen=failed
//    http://localhost:4180/?scen=loggedout
//
//  This server serves cloud/priv/static/ verbatim EXCEPT that, when it serves
//  the SPA shell (index.html), it injects <script src="/__preview__/mock.js">
//  immediately before the app.js tag. index.html on disk is never edited (A4
//  owns it); the injection is purely in-flight. mock.js stubs fetch/EventSource
//  from the scenario chosen by ?scen=; app.js then renders unchanged.
//
//  Headless screenshots of every scenario: make cloud-shots  (see shoot.sh).
// ─────────────────────────────────────────────────────────────────────────────

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, ".."); // cloud/priv/static

const argv = process.argv.slice(2);
const portFlag = argv.indexOf("--port");
const PORT = Number(
  (portFlag !== -1 && argv[portFlag + 1]) || process.env.PREVIEW_PORT || 4180,
);

const APP_TAG = '<script src="/app.js"></script>';
const INJECTED =
  '<script src="/__preview__/mock.js"></script>\n    ' + APP_TAG;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
};

// Resolve a request path to a file inside ROOT, refusing traversal.
function resolveInRoot(urlPath) {
  let clean;
  // A malformed escape ("/%zz") throws URIError — refuse the request instead
  // of letting the exception kill the server mid-session / mid-shoot.
  try { clean = decodeURIComponent(urlPath.split("?")[0]); }
  catch (e) { return null; }
  const abs = path.normalize(path.join(ROOT, clean));
  if (abs !== ROOT && !abs.startsWith(ROOT + path.sep)) return null; // escape attempt
  return abs;
}

function serveIndex(res) {
  let html;
  try {
    html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
  } catch (e) {
    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end("index.html not found under " + ROOT);
    return;
  }
  // Inject the mock exactly once, immediately before the app.js tag.
  const injected = html.includes(APP_TAG)
    ? html.replace(APP_TAG, INJECTED)
    : html;
  res.writeHead(200, { "Content-Type": MIME[".html"], "Cache-Control": "no-store" });
  res.end(injected);
}

const server = http.createServer((req, res) => {
  const urlPath = (req.url || "/").split("?")[0];

  // Root and the SPA entry paths get the injected shell.
  if (urlPath === "/" || urlPath === "/index.html" || urlPath === "/new") {
    return serveIndex(res);
  }

  const abs = resolveInRoot(urlPath);
  if (!abs) {
    res.writeHead(403, { "Content-Type": "text/plain" });
    return res.end("forbidden");
  }

  fs.stat(abs, (err, stat) => {
    if (err || !stat.isFile()) {
      // Unknown path with no extension → SPA client route → the injected shell.
      if (!path.extname(urlPath)) return serveIndex(res);
      res.writeHead(404, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
      return res.end("not found");
    }
    const mime = MIME[path.extname(abs).toLowerCase()] || "application/octet-stream";
    res.writeHead(200, { "Content-Type": mime, "Cache-Control": "no-store" });
    fs.createReadStream(abs).pipe(res);
  });
});

server.listen(PORT, () => {
  process.stdout.write(
    "Cloud preview on http://localhost:" + PORT + "/?scen=mixed-fleet\n" +
      "Scenarios: empty · mixed-fleet · provisioning · failed · loggedout" +
      "  (add &theme=dark)\n",
  );
});

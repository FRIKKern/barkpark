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
// The repo root. FOUR levels: this file lives one deeper than app.test.mjs
// (cloud/priv/static/__preview__), which is exactly the off-by-one a live fetch
// of /__fixtures__/… caught and every string-level test missed — see the
// resolution arm in __app.test.mjs, which recomputes this literal.
const REPO_ROOT = path.resolve(HERE, "../../../..");

// ── /__fixtures__/ — the committed Go goldens, served from their ONE source ──
// coherence.html USED to carry a byte-copy of each of these files inside a
// <script type="text/plain"> block, with a byte-identity assertion in
// __app.test.mjs. Two sources of truth: any cycle that legitimately regenerated
// a TUI golden reddened the console harness on the NEXT, unrelated cloud PR,
// and the only repair was a hand re-embed of bytes nobody had reviewed. The
// page now FETCHES the goldens through this table, which is the only place
// their paths are written. A regenerated golden changes what the page renders
// with no HTML edit and nothing to drift from.
//
// Both targets are declared in scripts/console-path-escape-check.sh's
// CONSOLE_PATHS (they were already, for __app.test.mjs's reads), so this
// repo-root read is dispatched on rather than being a silent escape.
const FIXTURE_ROUTES = {
  "/__fixtures__/styleguide_lifecycle.txt": path.join(
    REPO_ROOT, "internal/taskboard/testdata/styleguide_lifecycle.txt"),
  "/__fixtures__/styleguide_tokens.txt": path.join(
    REPO_ROOT, "internal/pdrender/testdata/styleguide_tokens.txt"),
};

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

  // TREE IDENTITY (cchi-w22-bl-guard-port-contention-silently-measures-a-
  // foreign-tree). Port 4199 is shared across concurrent worktrees, and a
  // byte-compare cannot tell two IDENTICAL trees apart — a guard that only
  // compares bytes can silently measure a FOREIGN worktree's server and quote
  // it as its own baseline. This endpoint answers the only question bytes
  // cannot: WHICH tree is this server rooted in.
  if (urlPath === "/__tree") {
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(JSON.stringify({ root: ROOT, pid: process.pid }));
  }

  // The committed Go goldens, read from their canonical path (see
  // FIXTURE_ROUTES). A missing file answers 404 with the path it looked for —
  // never a stale copy, because there is no copy.
  if (Object.prototype.hasOwnProperty.call(FIXTURE_ROUTES, urlPath)) {
    const src = FIXTURE_ROUTES[urlPath];
    let body;
    try {
      body = fs.readFileSync(src);
    } catch (e) {
      res.writeHead(404, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
      return res.end("fixture not found on disk: " + src);
    }
    res.writeHead(200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    });
    return res.end(body);
  }

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
    // ONE REQUEST USED TO BE ABLE TO KILL THE WHOLE SERVER, SILENTLY
    // (gr-blk-accent-scenario-sweep, criterion 4 — the "serve.mjs died mid-sweep
    // with nothing logged" observation). `fs.createReadStream(abs).pipe(res)`
    // registered NO `error` listener on the stream, so any post-stat open
    // failure emitted an unhandled 'error' event, which in Node is an UNCAUGHT
    // EXCEPTION and takes the process down. Every consumer spawns this file
    // with its stdout ignored, so the stack lands wherever stderr is (or is
    // not) read: the observed shape is a server that "simply vanished".
    //
    // DRIVEN, not reasoned (on this file's own bytes, port 4294): a 1-byte file
    // chmod 000 under the root passes fs.stat (it IS a file) and then fails at
    // open. curl got `http=000`, the process was DEAD one second later, and its
    // stderr held `Unhandled 'error' event … EACCES: permission denied, open`.
    // TOCTOU is the general case — stat says file, open says otherwise (EACCES,
    // ENOENT after a concurrent delete, EMFILE under fd pressure) — and every
    // instance of it killed the server for every OTHER in-flight request too.
    // Re-run the control by hand:
    //   printf x > cloud/priv/static/__preview__/fixtures/.probe && chmod 000 …
    //   node cloud/priv/static/__preview__/serve.mjs --port 4294 &
    //   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4294/__preview__/fixtures/.probe
    //
    // WHAT THIS DOES NOT CLAIM. It does not reproduce the filed "~50-60
    // sequential Playwright loads" trigger: 1380 sequential cells in one
    // overflow-guard accent sweep plus 200 deliberately mid-body-aborted loads
    // left this server alive with a flat ~100-118MB RSS. It removes the one
    // unhandled-error path a read of this file can prove, and turns a
    // whole-process death into a 500 on the one request that caused it.
    // The 200 is written on `open`, NEVER before it: a writeHead that has
    // already gone out leaves the error path with no status left to send, so
    // the "500" below would be an unreachable branch dressed up as a remedy.
    const body = fs.createReadStream(abs);
    body.on("error", (e) => {
      process.stderr.write("!! serve.mjs: read failed for " + urlPath + " (" + ((e && e.code) || e) + ") — 500 on this request; the server stays up.\n");
      if (!res.headersSent) res.writeHead(500, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
      res.end("read failed");
    });
    body.once("open", () => {
      res.writeHead(200, { "Content-Type": mime, "Cache-Control": "no-store" });
      body.pipe(res);
    });
    res.on("close", () => body.destroy());
  });
});

// ── the stale-server guard (gr-blk-serve-stale-guard) ────────────────────────
// REAL, HIT LIVE: a preview server left running by a FOREIGN worktree squatted
// the port and served the primary checkout's app.css (187302 B) while the
// measuring tree held 189086 B — a patched --after run printed output
// byte-identical to --before, and would have reported "the fix does nothing"
// about a fix that measurably works. serve.mjs used to have NO port-collision
// story at all: `listen` raised EADDRINUSE, the unhandled error killed the
// process with a bare stack, and every consumer that polls the port for
// readiness then happily measured the SQUATTER's bytes.
//
// Two arms, so every consumer inherits the truth from serve.mjs itself:
//   • EADDRINUSE → DIAGNOSE the squatter before dying: fetch its /app.css and
//     /app.js and compare against THIS tree's disk bytes, then exit 2 naming
//     the counts. "Port in use" alone sends the reader to lsof; "served
//     187302 B but disk has 189086 B" tells them a foreign tree owns the port.
//   • listen succeeded → SELF-PROBE through the same localhost URL a consumer
//     uses, byte-compare against disk, exit 2 on mismatch. This is the arm a
//     dual-stack split would trip (we bound one interface, a squatter owns the
//     one `localhost` resolves to) — without it that shape serves foreign
//     bytes forever with OUR pid alive, which no consumer can catch.
//
// REPRODUCE THE MUTATION PROOF (no /tmp probe — anyone can re-run it):
//   cp -R cloud/priv/static /some/foreign-root && echo x >> /some/foreign-root/app.css
//   node /some/foreign-root/__preview__/serve.mjs --port 4399 &   # the squatter
//   node cloud/priv/static/__preview__/serve.mjs --port 4399; echo $?
//     → "!! STALE SERVER on :4399 …" and exit 2
//   kill the squatter, re-run → the ready banner, exit 0 on SIGTERM.
const CANARIES = ["app.css", "app.js"];

function canaryReport(served, rel, disk) {
  return served.equals(disk)
    ? "   /" + rel + ": served " + served.length + " B == disk " + disk.length + " B (SAME bytes — a concurrent server of this tree?)"
    : "   /" + rel + ": served " + served.length + " B but disk has " + disk.length + " B (a FOREIGN tree)";
}

async function fetchCanary(rel) {
  const r = await fetch("http://localhost:" + PORT + "/" + rel, { cache: "no-store" });
  return Buffer.from(await r.arrayBuffer());
}

server.on("error", async (err) => {
  if (err && err.code === "EADDRINUSE") {
    const lines = [];
    for (const rel of CANARIES) {
      try {
        lines.push(canaryReport(await fetchCanary(rel), rel, fs.readFileSync(path.join(ROOT, rel))));
      } catch (e) {
        lines.push("   /" + rel + ": the squatter did not answer (" + ((e && e.code) || e) + ")");
      }
    }
    process.stderr.write(
      "!! STALE SERVER on :" + PORT + " — another process already owns this port.\n" +
      lines.join("\n") + "\n" +
      "   Serving would be a lie and measuring the squatter certifies the wrong bytes — refusing.\n" +
      "   Find it: lsof -nP -iTCP:" + PORT + " -sTCP:LISTEN\n",
    );
    process.exit(2);
  }
  process.stderr.write("!! serve.mjs: " + ((err && err.stack) || err) + "\n");
  process.exit(2);
});

server.listen(PORT, async () => {
  // The self-probe arm: what THIS URL answers must be THIS tree's bytes.
  for (const rel of CANARIES) {
    let served;
    try {
      served = await fetchCanary(rel);
    } catch (e) {
      process.stderr.write("!! serve.mjs: self-probe of /" + rel + " failed (" + ((e && e.code) || e) + ") — refusing to claim readiness.\n");
      process.exit(2);
    }
    const disk = fs.readFileSync(path.join(ROOT, rel));
    if (!served.equals(disk)) {
      process.stderr.write(
        "!! STALE SERVER on :" + PORT + " — the port answers, but not with this tree's bytes.\n" +
        canaryReport(served, rel, disk) + "\n" +
        "   Another server owns the interface `localhost` resolves to — refusing.\n",
      );
      process.exit(2);
    }
  }
  process.stdout.write(
    "Cloud preview on http://localhost:" + PORT + "/?scen=mixed-fleet\n" +
      "Scenarios: empty · mixed-fleet · provisioning · failed · loggedout" +
      "  (add &theme=dark)\n",
  );
});

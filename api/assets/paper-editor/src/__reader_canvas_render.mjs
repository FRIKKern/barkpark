// __reader_canvas_render.mjs — rendered reader <-> continuous-canvas parity rig.
//
// This is deliberately an opt-in browser harness, not a source-string test. It:
//   1. asks the real Elixir Barkpark.PortableDoc.Render.render_block/2 emitter for
//      the reader HTML;
//   2. bundles the current canvas entry to a temporary IIFE and mounts the real
//      <bp-paper-canvas> custom element;
//   3. loads the same paper-surface CSS and editor-shell CSS used by Studio; and
//   4. measures rendered text/root geometry in Chromium at desktop/mobile and
//      light/dark, while saving a screenshot of every surface.
//
// Run from anywhere:
//   node api/assets/paper-editor/src/__reader_canvas_render.mjs
//
// Useful environment variables:
//   BP_CHROME=/path/to/chrome-headless-shell
//   BP_PARITY_ARTIFACTS=/path/to/output-directory
//   BP_PARITY_REPORT_ONLY=1   report differences without exiting non-zero
//   BP_PARITY_TOLERANCE=0.75  maximum pixel delta for each geometry field
//   BP_PARITY_RENDER_API=/path/to/api  use a separately compiled reader tree
//   MIX_DEPS_PATH=...         forwarded to the fixture-rendering `mix run`
//   MIX_BUILD_PATH=...        forwarded to the fixture-rendering `mix run`

// The screenshots are evidence, not golden images: platform font rasterization
// makes pixel snapshots unsuitable as a portable gate. The numeric geometry is
// the regression assertion; screenshots make each failure diagnosable.

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir, tmpdir } from "node:os";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../..");
const API = join(REPO, "api");
const PACKAGE = join(REPO, "api/assets/paper-editor");
const RENDER_API = process.env.BP_PARITY_RENDER_API || API;
const TMP = mkdtempSync(join(tmpdir(), "bp-reader-canvas-"));
const ARTIFACTS = process.env.BP_PARITY_ARTIFACTS || join(TMP, "artifacts");
const TOLERANCE = Number(process.env.BP_PARITY_TOLERANCE || "0.75");
const REPORT_ONLY = process.env.BP_PARITY_REPORT_ONLY === "1";
const round = (value) => Math.round(value * 100) / 100;

mkdirSync(ARTIFACTS, { recursive: true });

const text = (value) => [{ type: "text", value }];
const FIXTURES = [
  {
    id: "heading",
    block: {
      id: "heading",
      type: "heading",
      level: 1,
      text: "Editing should wrap exactly like the published Paper reader",
    },
  },
  {
    id: "paragraph",
    block: {
      id: "paragraph",
      type: "paragraph",
      content: text("The editing canvas must preserve the reader's measure, rhythm, and line breaks across every viewport."),
    },
  },
  {
    id: "subheading",
    block: {
      id: "subheading",
      type: "heading",
      level: 2,
      text: "A second-level heading must keep its intended air",
    },
  },
  {
    id: "list",
    block: {
      id: "list",
      type: "list",
      ordered: false,
      items: [
        text("A first list item long enough to wrap on a narrow reading column"),
        text("A second item proving marker indentation and line height"),
      ],
    },
  },
  {
    id: "callout",
    block: {
      id: "callout",
      type: "callout",
      tone: "warning",
      title: "Check the rendered result",
      content: text("This editable callout should occupy the same text box as its reader counterpart."),
    },
  },
  { id: "eyebrow", block: { id: "eyebrow", type: "eyebrow", text: "Field notes · parity" } },
  { id: "byline", block: { id: "byline", type: "byline", items: ["Pelle Jarl", "September 2026"] } },
  {
    id: "ingress",
    block: {
      id: "ingress",
      type: "ingress",
      content: text("A lead paragraph carries more visual weight while retaining the exact same wrapping in edit mode."),
    },
  },
  {
    id: "pullquote",
    block: {
      id: "pullquote",
      type: "pullquote",
      content: text("The editor is credible only when the document does not jump after publishing."),
    },
  },
  {
    id: "table",
    block: {
      id: "table",
      type: "table",
      head: [text("Surface"), text("Measured result")],
      rows: [
        [text("Reader"), text("Published geometry")],
        [text("Canvas"), text("Editable geometry")],
      ],
    },
  },
  {
    id: "section",
    block: {
      id: "section",
      type: "section",
      title: "A section inside the same document flow",
      blocks: [
        { id: "section-p", type: "paragraph", content: text("Nested section prose should retain the reader's rules, title placement, and body rhythm.") },
      ],
    },
  },
  {
    id: "card",
    block: {
      id: "card",
      type: "card",
      tone: "info",
      slots: {
        title: [{ type: "heading", text: "A parity card" }],
        body: [{ type: "paragraph", content: text("Card body copy should keep the reader's dimensions in its editable shell.") }],
      },
    },
  },
  {
    id: "code",
    block: {
      id: "code",
      type: "code",
      lang: "text",
      value: "reader_width = canvas_width\nline_two = true",
    },
  },
  {
    id: "figure",
    block: {
      id: "figure",
      type: "figure",
      caption: "A rendered child with an editable caption.",
      child: { type: "paragraph", content: text("Figure child geometry comes from the server renderer.") },
    },
  },
  {
    id: "task-list",
    block: {
      id: "task-list",
      type: "task-list",
      title: "Parity tasks",
      snapshot: [
        { title: "Measure the reader", status: "ready", priority: 1 },
        { title: "Match the canvas", status: "done" },
      ],
    },
  },
];

const SCENARIOS = [
  { name: "desktop-light", width: 1440, height: 2100, theme: "light", bucket: "wide" },
  { name: "desktop-dark", width: 1440, height: 2100, theme: "dark", bucket: "wide" },
  { name: "mobile-light", width: 390, height: 2500, theme: "light", bucket: "phone" },
  { name: "mobile-dark", width: 390, height: 2500, theme: "dark", bucket: "phone" },
];

function findChrome() {
  if (process.env.BP_CHROME && existsSync(process.env.BP_CHROME)) return process.env.BP_CHROME;
  const roots = [
    join(homedir(), "Library/Caches/ms-playwright"),
    join(homedir(), ".cache/ms-playwright"),
    join(homedir(), ".cache/puppeteer"),
  ];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    const stack = [root];
    while (stack.length) {
      const dir = stack.pop();
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) stack.push(path);
        else if (
          entry.name === "chrome-headless-shell" ||
          (entry.name === "Chromium" && path.includes("Chromium.app"))
        ) return path;
      }
    }
  }
  for (const path of [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
  ]) if (existsSync(path)) return path;
  return null;
}

const CHROME = findChrome();
if (!CHROME) {
  console.log("SKIP  reader/canvas rendered parity — no Chromium executable found");
  process.exit(0);
}

function renderReaderPage() {
  const script = join(TMP, "render_reader_layout.exs");
  const out = join(TMP, "reader-layout.html");
  const fragmentsOut = join(TMP, "reader-fragments.json");
  writeFileSync(script, `
blocks = System.fetch_env!("BP_PARITY_FIXTURES") |> Jason.decode!()
{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Barkpark.PubSub)
{:ok, _} = BarkparkWeb.Endpoint.start_link()
rendered = blocks |> Enum.with_index() |> Enum.map(fn {block, index} ->
  id = case Map.get(block, "id") do
    id when is_binary(id) and id != "" -> id
    _ -> "block-#{index}"
  end
  html = Barkpark.PortableDoc.Render.render_block(block, %{style: :article})
  {id, block, html}
end)
body = rendered |> Enum.map(fn {id, block, html} ->
  ~s(<div id="#{id}" data-block-id="#{Map.get(block, "id")}">) <> html <> "</div>"
end) |> Enum.join()
fragments = rendered |> Map.new(fn {id, block, html} ->
  paint = case block do
    %{"type" => "figure", "child" => child} -> Barkpark.PortableDoc.Render.render_block(child, %{style: :article})
    _ -> html
  end
  {id, paint}
end)
inner = ~s(<main class="bp-paper-shell bp-paper-surface bp-paper-article"><article id="paper-body">) <> body <> "</article></main>"
assigns = %{inner_content: Phoenix.HTML.raw(inner), page_title: "Reader/canvas parity", preview: nil, csp_nonce: "parity-nonce", bp_theme: "evergreen"}
html = assigns |> BarkparkWeb.Layouts.bulldocs() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
File.write!(System.fetch_env!("BP_PARITY_LAYOUT_OUT"), html)
File.write!(System.fetch_env!("BP_PARITY_FRAGMENTS_OUT"), Jason.encode!(fragments))
`);
  execFileSync("mix", ["run", "--no-compile", "--no-start", script], {
    cwd: RENDER_API,
    stdio: ["ignore", "ignore", "inherit"],
    maxBuffer: 16 * 1024 * 1024,
    env: {
      ...process.env,
      BP_PARITY_FIXTURES: JSON.stringify(FIXTURES.map(({ block }) => block)),
      BP_PARITY_LAYOUT_OUT: out,
      BP_PARITY_FRAGMENTS_OUT: fragmentsOut,
    },
  });
  return { page: readFileSync(out, "utf8"), fragments: JSON.parse(readFileSync(fragmentsOut, "utf8")) };
}

function buildCanvas() {
  const outfile = join(TMP, "canvas.js");
  const esbuild = join(PACKAGE, "node_modules/.bin/esbuild");
  if (!existsSync(esbuild)) throw new Error(`paper-editor esbuild is missing: ${esbuild}`);
  execFileSync(esbuild, ["src/canvas/index.js", "--bundle", "--format=iife", `--outfile=${outfile}`], {
    cwd: PACKAGE,
    stdio: ["ignore", "ignore", "inherit"],
  });
  return outfile;
}

const { page: readerPage, fragments: readerFragments } = renderReaderPage();
const canvasBundle = buildCanvas();
const shellCss = readFileSync(join(REPO, "api/priv/static/assets/bp-paper-editor-shell.css"), "utf8");

function pageFor(surface, scenario) {
  let page = readerPage
    .replace("<html", `<html data-theme="${scenario.theme}" data-bp-theme="evergreen" data-width-bucket="${scenario.bucket}"`)
    // The shipping page fetches this exact source at /assets. A file:// rig cannot,
    // so inline the source bytes; do not load the standalone editor stylesheet.
    .replace("</head>", `<style>${shellCss}\n#parity-status{display:none}</style></head>`);
  if (surface === "canvas") {
    page = page.replace(
      /<article id="paper-body"[^>]*>[\s\S]*?<\/article>/,
      `<article id="paper-body"><div class="bp-paper-editor"><div id="bp-expected-fields" hidden></div><div id="bp-paper-context-menu-host" hidden></div><div class="bp-paper-edit-canvas"><div id="document"></div></div></div></article>`,
    );
  }
  const setup = surface === "reader"
    ? `setTimeout(measure, 0);`
    : `
const host = document.createElement("bp-paper-canvas");
host.setAttribute("editable", "true");
host.blocks = ${JSON.stringify(FIXTURES.map((fixture) => fixture.block))};
document.getElementById("document").appendChild(host);
customElements.whenDefined("bp-paper-canvas").then(() => {
  const ready = () => {
    if (!host.querySelector(".ProseMirror")) return setTimeout(ready, 20);
    const paint = ${JSON.stringify(readerFragments)};
    for (const hole of host.querySelectorAll("[data-bp-fleet-id] [data-bp-fleet-body]")) {
      const id = hole.closest("[data-bp-fleet-id]").getAttribute("data-bp-fleet-id");
      if (paint[id] != null) hole.innerHTML = paint[id];
    }
    setTimeout(measure, 0);
  };
  ready();
});`;

  const scripts = `<pre id="parity-status">pending</pre>
${surface === "canvas" ? `<script>window.BP_PAPER_EDITOR_NO_INJECT=true;</script><script src="file://${canvasBundle}"></script>` : ""}
<script>
window.addEventListener("error", (event) => {
  document.getElementById("parity-status").textContent = "BP_PARITY_ERROR=" + (event.error && event.error.stack || event.message);
});
window.addEventListener("unhandledrejection", (event) => {
  document.getElementById("parity-status").textContent = "BP_PARITY_ERROR=" + (event.reason && event.reason.stack || event.reason);
});
const fixtureMeta = ${JSON.stringify(FIXTURES.map(({ id, block }) => ({ id, type: block.type })))};
function round(value) { return Math.round(value * 100) / 100; }
function rect(value) { return { x: round(value.x), y: round(value.y), width: round(value.width), height: round(value.height), right: round(value.right), bottom: round(value.bottom) }; }
function rootFor(meta) {
  if (${JSON.stringify(surface)} === "reader") return document.querySelector('[data-block-id="' + meta.id + '"] > :first-child');
  const canvas = document.querySelector("bp-paper-canvas");
  return canvas.querySelector('[data-bp-id="' + meta.id + '"]') || canvas.querySelector('[data-bp-type="' + meta.type + '"]');
}
function contentFor(meta, root) {
  if (meta.type === "table") return root.matches("table") ? root : root.querySelector("table.bp-table") || root;
  return root;
}
function styleFor(meta, root) {
  if (meta.type === "task-list") return root.matches(".bp-tasks") ? root : root.querySelector(".bp-tasks") || root;
  return root;
}
function textGeometry(root) {
  const rects = [];
  const lineRuns = [];
  const append = (top, value) => {
    let line = lineRuns.find((entry) => Math.abs(entry.top - top) < 1);
    if (!line) { line = { top, text: "" }; lineRuns.push(line); }
    line.text += value;
  };
  const isVisible = (element) => {
    for (let el = element; el && root.contains(el); el = el.parentElement) {
      const style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
      if (el === root) break;
    }
    return true;
  };
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (!node.textContent.trim()) continue;
    if (!isVisible(node.parentElement)) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    rects.push(...Array.from(range.getClientRects()).filter((r) => r.width > 0 && r.height > 0));
    for (let i = 0; i < node.textContent.length; i++) {
      range.setStart(node, i);
      range.setEnd(node, i + 1);
      const charRect = range.getClientRects()[0];
      if (charRect) append(charRect.top, node.textContent[i]);
    }
  }
  for (const control of root.querySelectorAll("input, textarea")) {
    const style = getComputedStyle(control);
    if (!isVisible(control) || !control.value) continue;
    const cr = control.getBoundingClientRect();
    const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) || 16;
    control.value.split("\\n").forEach((value, index) => append(cr.top + index * lineHeight, value));
  }
  const lineText = lineRuns
    .sort((a, b) => a.top - b.top)
    .map((entry) => entry.text.trim().replace(/\\s+/g, " "))
    .filter(Boolean);
  if (!rects.length) return { box: rect(root.getBoundingClientRect()), lines: lineText.length, lineText };
  const left = Math.min(...rects.map((r) => r.left));
  const top = Math.min(...rects.map((r) => r.top));
  const right = Math.max(...rects.map((r) => r.right));
  const bottom = Math.max(...rects.map((r) => r.bottom));
  return { box: rect({ x: left, y: top, width: right - left, height: bottom - top, right, bottom }), lines: lineText.length, lineText };
}
function measure() {
  const surface = document.querySelector("main.bp-paper-surface");
  const sr = surface.getBoundingClientRect();
  const style = getComputedStyle(surface);
  const contentLeft = sr.left + parseFloat(style.paddingLeft);
  const cases = {};
  let previous = null;
  for (const meta of fixtureMeta) {
    const root = rootFor(meta);
    if (!root) { cases[meta.id] = { missing: true }; continue; }
    const content = contentFor(meta, root);
    const rr = content.getBoundingClientRect();
    const cs = getComputedStyle(styleFor(meta, content));
    cases[meta.id] = {
      root: rect(rr),
      x: round(rr.left - contentLeft),
      gap: previous ? round(rr.top - previous.bottom) : round(rr.top - (sr.top + parseFloat(style.paddingTop))),
      text: textGeometry(content),
      computed: {
        fontSize: cs.fontSize, lineHeight: cs.lineHeight, fontWeight: cs.fontWeight,
        letterSpacing: cs.letterSpacing, fontStyle: cs.fontStyle,
        fontFamily: cs.fontFamily, fontFeatureSettings: cs.fontFeatureSettings,
        fontVariantLigatures: cs.fontVariantLigatures, fontVariantNumeric: cs.fontVariantNumeric,
        whiteSpace: cs.whiteSpace, wordSpacing: cs.wordSpacing,
        marginTop: cs.marginTop, marginBottom: cs.marginBottom,
        paddingTop: cs.paddingTop, paddingRight: cs.paddingRight,
        paddingBottom: cs.paddingBottom, paddingLeft: cs.paddingLeft,
      },
    };
    previous = rr;
  }
  document.getElementById("parity-status").textContent = "BP_PARITY_RESULT=" + JSON.stringify({
    surface: ${JSON.stringify(surface)}, viewport: { width: innerWidth, height: innerHeight },
    paper: rect(sr), scrollWidth: document.documentElement.scrollWidth, cases,
  });
}
${setup}
</script>`;
  return page.replace("</body>", `${scripts}</body>`);
}

function runPage(surface, scenario) {
  const file = join(TMP, `${scenario.name}-${surface}.html`);
  const screenshot = join(ARTIFACTS, `${scenario.name}-${surface}.png`);
  writeFileSync(file, pageFor(surface, scenario));
  const dom = execFileSync(CHROME, [
    "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
    `--window-size=${scenario.width},${scenario.height}`,
    "--virtual-time-budget=3500", `--screenshot=${screenshot}`, "--dump-dom", `file://${file}`,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 * 1024 * 1024 });
  const marker = dom.match(/BP_PARITY_RESULT=(\{.*?\})<\/pre>/s);
  if (!marker) {
    const error = dom.match(/<pre id="parity-status">BP_PARITY_ERROR=(.*?)<\/pre>/s);
    throw new Error(`${scenario.name}/${surface} produced no measurement marker${error ? `: ${error[1]}` : ""}`);
  }
  return JSON.parse(marker[1].replaceAll("&quot;", '"').replaceAll("&amp;", "&").replaceAll("&lt;", "<").replaceAll("&gt;", ">"));
}

const numericPaths = [
  ["x"], ["gap"], ["root", "width"], ["root", "height"],
  ["text", "lines"],
];
const stylePaths = [
  "fontSize", "lineHeight", "fontWeight", "letterSpacing", "fontStyle", "fontFamily",
  "fontFeatureSettings", "fontVariantLigatures", "wordSpacing",
  "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
];
const get = (object, path) => path.reduce((value, key) => value && value[key], object);
const report = {
  generatedAt: new Date().toISOString(), tolerance: TOLERANCE, chromium: CHROME, artifacts: ARTIFACTS,
  fixtureCount: FIXTURES.length, fixtures: FIXTURES.map(({ id, block }) => ({ id, type: block.type })), scenarios: {},
};
let failures = 0;

for (const scenario of SCENARIOS) {
  const reader = runPage("reader", scenario);
  const canvas = runPage("canvas", scenario);
  const differences = [];
  for (const { id } of FIXTURES) {
    const r = reader.cases[id];
    const c = canvas.cases[id];
    if (!r || r.missing || !c || c.missing) {
      differences.push({ id, field: "mounted", reader: !r?.missing, canvas: !c?.missing });
      failures++;
      continue;
    }
    for (const path of numericPaths) {
      const rv = get(r, path);
      const cv = get(c, path);
      const delta = round(cv - rv);
      if (Math.abs(delta) > TOLERANCE) differences.push({ id, field: path.join("."), reader: rv, canvas: cv, delta });
    }
    for (const field of stylePaths) {
      const rv = r.computed[field];
      const cv = c.computed[field];
      if (rv !== cv) differences.push({ id, field: `computed.${field}`, reader: rv, canvas: cv });
    }
    if (JSON.stringify(r.text.lineText) !== JSON.stringify(c.text.lineText)) {
      differences.push({ id, field: "text.lineText", reader: r.text.lineText, canvas: c.text.lineText });
    }
  }
  failures += differences.length;
  report.scenarios[scenario.name] = {
    readerScreenshot: join(ARTIFACTS, `${scenario.name}-reader.png`),
    canvasScreenshot: join(ARTIFACTS, `${scenario.name}-canvas.png`),
    reader,
    canvas,
    differences,
  };
  console.log(`${differences.length ? "FAIL" : "PASS"}  ${scenario.name}: ${differences.length} reader/canvas differences`);
  for (const diff of differences) {
    const delta = diff.delta == null ? "" : ` (canvas-reader ${diff.delta > 0 ? "+" : ""}${diff.delta}px)`;
    console.log(`      ${diff.id} ${diff.field}: reader=${diff.reader}, canvas=${diff.canvas}${delta}`);
  }
}

const reportFile = join(ARTIFACTS, "report.json");
writeFileSync(reportFile, JSON.stringify(report, null, 2) + "\n");
console.log(`\nEvidence: ${reportFile}`);
console.log(`Screenshots: ${ARTIFACTS}`);
if (failures && !REPORT_ONLY) process.exitCode = 1;

// __view_edit_parity_matrix.mjs — View/Edit COMPUTED-STYLE parity matrix.
//
// The measuring successor of the retired LLM-vote workflow
// .claude/workflows/view-edit-parity.workflow.js. Where the #16092 harness
// (__reader_canvas_render.mjs) compares GEOMETRY and reads computed style only
// at each block's root, this instrument reads the computed style of the element
// that PAINTS every run of text — including a form control's value — and
// compares it with the reader's, axis by axis (view-edit-parity-compare.js).
//
// Three pages per scenario, all on the real Bulldocs layout and the shipping
// editor-shell stylesheet:
//   reader   — Barkpark.PortableDoc.Render.render_block/2, style :article (View);
//   canvas   — every fixture mounted in ONE <bp-paper-canvas>, reader HTML painted
//              into the fleet holes (the #16092 mount);
//   liveview — the public /papers editor itself: PaperEditor.paper_block_editor/1
//              rendered by the server exactly as BulldocsLive's edit mode calls
//              it (canvas_eligible), each canvas run seeded the way the
//              BarkparkPaperCanvas hook seeds it. This is the surface that owns
//              the figure-caption paint button, the caption textarea and the
//              section-title textarea — controls neither older instrument mounts.
//
// Pass/fail: a divergence listed in src/view-edit-parity.known.json (with a
// reason) is reported but tolerated; any OTHER divergence fails, and so does a
// ledger entry that no longer fires (stale — delete it). Every run prints
//   TOTAL view/edit style divergences: <n> (known <k>, unexpected <u>, stale <s>)
//
// Run (needs Chromium and a compiled MIX_ENV=test api tree):
//   npm run test:view-edit-parity            (from api/assets/paper-editor)
//
// Environment:
//   BP_CHROME=/path/to/chrome-headless-shell
//   BP_PARITY_ARTIFACTS=/dir         screenshots + report.json (default: a tmp dir)
//   BP_PARITY_SHELL_CSS=/file.css    measure another editor-shell stylesheet, e.g.
//                                    `git show origin/main:api/priv/static/assets/bp-paper-editor-shell.css`
//   BP_PARITY_PLANT='sel{decl}'      append a rule to the Edit pages only — the
//                                    planted-change proof that the matrix can red
//   BP_PARITY_REPORT_ONLY=1          print everything, never exit non-zero
//   BP_PARITY_REQUIRE_CHROME=1       no Chromium is a failure, not a SKIP (CI)
//   BP_PARITY_RENDER_API=/path/api   render with a separately compiled api tree

import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir, tmpdir } from "node:os";
import { AXES, diffSurface, classify, staleEntries } from "./view-edit-parity-compare.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../..");
const API = join(REPO, "api");
const PACKAGE = join(REPO, "api/assets/paper-editor");
const RENDER_API = process.env.BP_PARITY_RENDER_API || API;
const TMP = mkdtempSync(join(tmpdir(), "bp-view-edit-parity-"));
const ARTIFACTS = process.env.BP_PARITY_ARTIFACTS || join(TMP, "artifacts");
const REPORT_ONLY = process.env.BP_PARITY_REPORT_ONLY === "1";
const SHELL_CSS = process.env.BP_PARITY_SHELL_CSS || join(REPO, "api/priv/static/assets/bp-paper-editor-shell.css");
const PLANT = process.env.BP_PARITY_PLANT || "";
const KNOWN = JSON.parse(readFileSync(join(HERE, "view-edit-parity.known.json"), "utf8")).entries;

mkdirSync(ARTIFACTS, { recursive: true });

const text = (value) => [{ type: "text", value }];
const para = (id, value) => ({ id, type: "paragraph", content: text(value) });

// The #16092 fixtures, the prose/tone/island fixtures the PR #20087 matrix
// added, and the block types no instrument measured before: stats, chart,
// columns, stage, notes, field-* and form.
const FIXTURES = [
  { id: "heading", type: "heading", level: 1, text: "Editing should wrap exactly like the published Paper reader" },
  para("paragraph", "The editing canvas must preserve the reader's measure, rhythm, and line breaks across every viewport."),
  { id: "subheading", type: "heading", level: 2, text: "A second-level heading must keep its intended air" },
  { id: "list", type: "list", ordered: false, items: [text("A first list item long enough to wrap on a narrow reading column"), text("A second item proving marker indentation and line height")] },
  { id: "callout", type: "callout", tone: "warning", title: "Check the rendered result", content: text("This editable callout should occupy the same text box as its reader counterpart.") },
  { id: "eyebrow", type: "eyebrow", text: "Field notes · parity" },
  { id: "byline", type: "byline", items: ["Pelle Jarl", "September 2026"] },
  { id: "ingress", type: "ingress", content: text("A lead paragraph carries more visual weight while retaining the exact same wrapping in edit mode.") },
  { id: "pullquote", type: "pullquote", content: text("The editor is credible only when the document does not jump after publishing.") },
  { id: "table", type: "table", head: [text("Surface"), text("Measured result")], rows: [[text("Reader"), text("Published geometry")], [text("Canvas"), text("Editable geometry")]] },
  { id: "section", type: "section", title: "A section inside the same document flow", blocks: [para("section-p", "Nested section prose should retain the reader's rules, title placement, and body rhythm.")] },
  { id: "card", type: "card", tone: "info", slots: { title: [{ type: "heading", text: "A parity card" }], body: [{ type: "paragraph", content: text("Card body copy should keep the reader's dimensions in its editable shell.") }] } },
  { id: "code", type: "code", lang: "text", value: "reader_width = canvas_width\nline_two = true" },
  { id: "figure", type: "figure", caption: "A rendered child with an editable caption.", child: para("figure-child", "Figure child geometry comes from the server renderer.") },
  { id: "task-list", type: "task-list", title: "Parity tasks", snapshot: [{ title: "Measure the reader", status: "ready", priority: 1 }, { title: "Match the canvas", status: "done" }] },
  { id: "heading-3", type: "heading", level: 3, text: "A third-level heading carries a quieter voice" },
  { id: "list-ordered", type: "list", ordered: true, items: [text("An ordered first item that is long enough to wrap on phones"), text("An ordered second item")] },
  { id: "callout-info", type: "callout", tone: "info", title: "Info tone", content: text("Info callout body copy for the parity matrix.") },
  { id: "callout-success", type: "callout", tone: "success", title: "Success tone", content: text("Success callout body copy for the parity matrix.") },
  { id: "callout-danger", type: "callout", tone: "danger", title: "Danger tone", content: text("Danger callout body copy for the parity matrix.") },
  { id: "callout-neutral", type: "callout", tone: "neutral", title: "Neutral tone", content: text("Neutral callout body copy for the parity matrix.") },
  { id: "terminal", type: "terminal", title: "Build pipeline output", footer: "Press ctrl-c to stop the run", children: [{ type: "paragraph", content: text("Compiling the reader and the canvas together") }] },
  { id: "diagram", type: "diagram", caption: "Diagram caption text for parity", source: "graph LR\n  A-->B" },
  { id: "action", type: "action", href: "https://example.test", label: "Open the parity report", priority: "primary" },
  { id: "paragraph-marks", type: "paragraph", content: [{ type: "text", value: "Plain, " }, { type: "text", value: "bold", marks: ["strong"] }, { type: "text", value: ", " }, { type: "text", value: "italic", marks: ["em"] }, { type: "text", value: " and " }, { type: "text", value: "code", marks: ["code"] }, { type: "text", value: " marks." }] },
  // ── round 2: the block types no instrument measured ──
  { id: "stats", type: "stats", items: [{ label: "In-scope types", value: "42" }, { label: "Renderers", value: "3" }] },
  { id: "chart", type: "chart", kind: "line", caption: "Coverage over time", axes: { xLabels: ["W1", "W2", "W3", "W4"] }, series: [{ label: "Covered", points: [10, 20, 35, 42] }] },
  { id: "columns", type: "columns", columns: [[para("columns-left", "Left column body copy for parity.")], [para("columns-right", "Right column body copy for parity.")]] },
  { id: "stage", type: "stage", kind: "gate", title: "Review", detail: "checks the criteria" },
  { id: "notes", type: "notes", items: [{ label: "Upgrade", lead: "Instant", text: "The board updates live." }, { label: "Why", lead: "Trust", text: "You always feel progress." }] },
  { id: "field-string", type: "field-string", label: "Headline", value: "A string field value" },
  { id: "field-text", type: "field-text", label: "Summary", value: "A long text field value for parity." },
  { id: "field-number", type: "field-number", label: "Pages", value: 312 },
  { id: "field-boolean", type: "field-boolean", label: "Published", value: true },
  { id: "field-select", type: "field-select", label: "Format", value: "option-2", options: [{ value: "option-1", label: "Paperback" }, { value: "option-2", label: "Hardcover" }] },
  { id: "form", type: "form", kind: "grill", questions: [{ id: "q1", prompt: "Ship it?", type: "yesno" }, { id: "q2", prompt: "Pick a surface", type: "single", options: ["Next", "Astro", "Phoenix"] }, { id: "q5", prompt: "Anything else?", type: "text" }] },
];

const SCENARIOS = [
  { name: "desktop-light", width: 1440, height: 4200, theme: "light", bucket: "wide" },
  { name: "desktop-dark", width: 1440, height: 4200, theme: "dark", bucket: "wide" },
  { name: "mobile-light", width: 390, height: 6000, theme: "light", bucket: "phone" },
  { name: "mobile-dark", width: 390, height: 6000, theme: "dark", bucket: "phone" },
];
const EDIT_SURFACES = ["canvas", "liveview"];

function probeFor(block) {
  const t = block.title || block.text || block.caption || block.label || (block.content && block.content[0] && block.content[0].value) || "";
  return String(t).slice(0, 14);
}

function findChrome() {
  if (process.env.BP_CHROME && existsSync(process.env.BP_CHROME)) return process.env.BP_CHROME;
  for (const root of [join(homedir(), "Library/Caches/ms-playwright"), join(homedir(), ".cache/ms-playwright"), join(homedir(), ".cache/puppeteer")]) {
    if (!existsSync(root)) continue;
    const stack = [root];
    while (stack.length) {
      const dir = stack.pop();
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) stack.push(path);
        else if (entry.name === "chrome-headless-shell" || (entry.name === "Chromium" && path.includes("Chromium.app"))) return path;
      }
    }
  }
  for (const path of ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"]) if (existsSync(path)) return path;
  return null;
}

const CHROME = findChrome();
if (!CHROME) {
  console.log("SKIP  view/edit parity matrix — no Chromium executable found");
  process.exit(process.env.BP_PARITY_REQUIRE_CHROME === "1" ? 1 : 0);
}

// One `mix run` renders the reader layout, the per-fixture reader fragments
// (the canvas fleet paint), and the public editor's server HTML.
function renderPages() {
  const script = join(TMP, "render_parity_pages.exs");
  const out = { layout: join(TMP, "reader-layout.html"), fragments: join(TMP, "reader-fragments.json"), editor: join(TMP, "editor.html") };
  writeFileSync(script, `
alias Barkpark.PortableDoc.Render
alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
blocks = System.fetch_env!("BP_PARITY_FIXTURES") |> Jason.decode!()
{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Barkpark.PubSub)
{:ok, _} = BarkparkWeb.Endpoint.start_link()
rendered = Enum.map(blocks, fn block -> {block["id"], block, Render.render_block(block, %{style: :article})} end)
body = rendered |> Enum.map(fn {id, _block, html} -> ~s(<div id="#{id}" data-block-id="#{id}">) <> html <> "</div>" end) |> Enum.join()
fragments = Map.new(rendered, fn {id, block, html} ->
  paint = case block do
    %{"type" => "figure", "child" => child} -> Render.render_block(child, %{style: :article})
    _ -> html
  end
  {id, paint}
end)
inner = ~s(<main class="bp-paper-shell bp-paper-surface bp-paper-article"><article id="paper-body">) <> body <> "</article></main>"
assigns = %{inner_content: Phoenix.HTML.raw(inner), page_title: "View/Edit parity", preview: nil, csp_nonce: "parity-nonce", bp_theme: "evergreen"}
html = assigns |> BarkparkWeb.Layouts.bulldocs() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
# The public /papers edit mode (BulldocsLive): the same call, the same flags.
editor =
  %{__changed__: nil, slug: "view-edit-parity", doc_type: "paper", blocks: blocks, paper_rev: 1,
    dataset: "production", api_token_raw: "", scope_prefix: "", picker_browse: false,
    canvas_eligible: true, task_previews: %{}, paper_links: %{}, save_status: "", paper_halt: nil}
  |> PaperEditor.paper_block_editor()
  |> Phoenix.HTML.Safe.to_iodata()
  |> IO.iodata_to_binary()
File.write!(System.fetch_env!("BP_PARITY_LAYOUT_OUT"), html)
File.write!(System.fetch_env!("BP_PARITY_FRAGMENTS_OUT"), Jason.encode!(fragments))
File.write!(System.fetch_env!("BP_PARITY_EDITOR_OUT"), editor)
`);
  execFileSync("mix", ["run", "--no-compile", "--no-start", script], {
    cwd: RENDER_API,
    stdio: ["ignore", "ignore", "inherit"],
    env: {
      ...process.env,
      MIX_ENV: process.env.MIX_ENV || "test",
      BP_PARITY_FIXTURES: JSON.stringify(FIXTURES),
      BP_PARITY_LAYOUT_OUT: out.layout,
      BP_PARITY_FRAGMENTS_OUT: out.fragments,
      BP_PARITY_EDITOR_OUT: out.editor,
    },
  });
  return {
    layout: readFileSync(out.layout, "utf8"),
    fragments: JSON.parse(readFileSync(out.fragments, "utf8")),
    editor: readFileSync(out.editor, "utf8"),
  };
}

// Bundled from source (never the committed bundle), so a source edit is measured
// before `npm run build`. canvas: the canvas entry the #16092 harness mounts.
// liveview: src/index.js, the entry of bp-paper-editor.bundle.js that the
// Bulldocs layout loads on /papers — it also defines <bp-paper-editor>, which
// the table's contextual editor mounts.
function buildBundle(entry, name) {
  const outfile = join(TMP, name);
  const esbuild = join(PACKAGE, "node_modules/.bin/esbuild");
  if (!existsSync(esbuild)) throw new Error(`paper-editor esbuild is missing: ${esbuild} (run npm ci)`);
  execFileSync(esbuild, [entry, "--bundle", "--format=iife", `--outfile=${outfile}`, "--log-level=error"], {
    cwd: PACKAGE,
    stdio: ["ignore", "ignore", "inherit"],
  });
  return outfile;
}

const pages = renderPages();
const bundles = { canvas: buildBundle("src/canvas/index.js", "canvas.js"), liveview: buildBundle("src/index.js", "editor.js") };
const shellCss = readFileSync(SHELL_CSS, "utf8");

// Runs in the page. Collects { [fixtureId]: { owners } } for one surface.
const MEASURE = `
const AXES = ${JSON.stringify(AXES)};
function norm(t) { return t.trim().replace(/\\s+/g, " "); }
function rootFor(meta) {
  if (SURFACE === "reader") return document.querySelector('[data-block-id="' + meta.id + '"] > :first-child');
  const byId = document.querySelector('[data-bp-id="' + meta.id + '"]') || document.querySelector('[data-edit-block-id="' + meta.id + '"]');
  if (byId) return byId;
  // Canvas node views do not all stamp data-bp-id: find the node of this type
  // whose text carries the fixture's probe string.
  const sel = meta.type.startsWith("field-")
    ? '[data-bp-type="field"][data-field-type="' + meta.type + '"]'
    : '[data-bp-type="' + meta.type + '"]';
  const all = Array.from(document.querySelectorAll("bp-paper-canvas " + sel));
  const hay = (el) => el.textContent + " " + Array.from(el.querySelectorAll("input,textarea")).map((c) => c.value).join(" ");
  return all.find((el) => meta.probe && hay(el).includes(meta.probe)) || all[0] || null;
}
function hidden(el) {
  const cs = getComputedStyle(el);
  return cs.display === "none" || cs.visibility === "hidden";
}
function effBg(el) {
  for (let e = el; e; e = e.parentElement) {
    const b = getComputedStyle(e).backgroundColor;
    if (b !== "rgba(0, 0, 0, 0)" && b !== "transparent") return b;
  }
  return "transparent";
}
function pick(el, role) {
  const cs = getComputedStyle(el);
  const o = {};
  for (const a of AXES) o[a] = cs[a];
  o.backgroundColor = effBg(el);
  o.tag = el.tagName.toLowerCase() + (el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\\s+/)[0] : "");
  o.role = role;
  return o;
}
function ownersFor(root) {
  const out = {};
  const add = (t, style) => {
    if (SURFACE === "reader") { if (!(t in out)) out[t] = style; }
    else (out[t] ||= []).push(style);
  };
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const t = norm(node.textContent);
    if (!t) continue;
    const el = node.parentElement;
    if (hidden(el) || el.closest("script,style,template,textarea,select,option")) continue;
    add(t, pick(el, "text"));
  }
  // A form control paints its value, not a text node. Measured at rest: the
  // focused state changes only the outline, never the type.
  for (const c of root.querySelectorAll("input:not([type=hidden]):not([type=checkbox]):not([type=radio]), textarea")) {
    const t = norm(c.value || "");
    if (t && !hidden(c)) add(t, pick(c, "control"));
  }
  for (const li of root.querySelectorAll("li")) {
    const t = norm(li.textContent);
    if (t && !hidden(li)) add("li::" + t, { listStyleType: getComputedStyle(li).listStyleType, color: getComputedStyle(li).color, tag: "li", role: "marker" });
  }
  return out;
}
function measure() {
  const cases = {};
  for (const meta of FIXTURE_META) {
    const root = rootFor(meta);
    cases[meta.id] = root ? { owners: ownersFor(root) } : { missing: true };
  }
  document.getElementById("parity-status").textContent = "BP_PARITY_RESULT=" + JSON.stringify(cases);
}
`;

function pageFor(surface, scenario) {
  let page = pages.layout
    .replace("<html", `<html data-theme="${scenario.theme}" data-bp-theme="evergreen" data-width-bucket="${scenario.bucket}"`)
    // The shipping page fetches this exact source at /assets; a file:// rig
    // inlines it. The standalone editor stylesheet is NOT loaded (as on /papers).
    .replace("</head>", `<style>${shellCss}\n#parity-status{display:none}</style>${surface === "reader" || !PLANT ? "" : `<style>${PLANT}</style>`}</head>`);
  if (surface === "canvas") {
    page = page.replace(
      /<article id="paper-body"[^>]*>[\s\S]*?<\/article>/,
      `<article id="paper-body"><div class="bp-paper-editor"><div id="bp-expected-fields" hidden></div><div id="bp-paper-context-menu-host" hidden></div><div class="bp-paper-edit-canvas"><div id="document"></div></div></div></article>`,
    );
  }
  if (surface === "liveview") {
    // BulldocsLive's edit mode renders the editor IN PLACE OF the article.
    page = page.replace(/<article id="paper-body"[^>]*>[\s\S]*?<\/article>/, () => pages.editor);
  }
  const setup = {
    reader: `setTimeout(measure, 0);`,
    canvas: `
const host = document.createElement("bp-paper-canvas");
host.setAttribute("editable", "true");
host.blocks = ${JSON.stringify(FIXTURES)};
document.getElementById("document").appendChild(host);
customElements.whenDefined("bp-paper-canvas").then(() => {
  const ready = () => {
    if (!host.querySelector(".ProseMirror")) return setTimeout(ready, 20);
    paintFleet();
    setTimeout(measure, 0);
  };
  ready();
});`,
    // What the BarkparkPaperCanvas hook's mounted() does to each run.
    liveview: `
const runs = Array.from(document.querySelectorAll('[data-test-id="paper-canvas-run"]'));
for (const run of runs) {
  const wc = run.querySelector("bp-paper-canvas");
  wc.setAttribute("editable", "true");
  wc.blocks = JSON.parse(run.dataset.canvasBlocks || "[]");
}
customElements.whenDefined("bp-paper-canvas").then(() => {
  let tries = 0;
  const ready = () => {
    const pending = runs.filter((run) => !run.querySelector(".ProseMirror"));
    if (pending.length && tries++ < 150) return setTimeout(ready, 20);
    paintFleet();
    setTimeout(measure, 0);
  };
  ready();
});`,
  }[surface];

  const scripts = `<pre id="parity-status">pending</pre>
${surface === "reader" ? "" : `<script>window.BP_PAPER_EDITOR_NO_INJECT=true;</script><script src="file://${bundles[surface]}"></script>`}
<script>
window.addEventListener("error", (event) => {
  document.getElementById("parity-status").textContent = "BP_PARITY_ERROR=" + (event.error && event.error.stack || event.message);
});
window.addEventListener("unhandledrejection", (event) => {
  document.getElementById("parity-status").textContent = "BP_PARITY_ERROR=" + (event.reason && event.reason.stack || event.reason);
});
const SURFACE = ${JSON.stringify(surface)};
const FIXTURE_META = ${JSON.stringify(FIXTURES.map((block) => ({ id: block.id, type: block.type, probe: probeFor(block) })))};
${MEASURE}
// Fleet widgets (stats, chart, notes, task-list, ...) paint server HTML into a
// hole; the LiveView pushes Render.render_block/2 output, so paint exactly that.
const FLEET_PAINT = ${surface === "reader" ? "{}" : JSON.stringify(pages.fragments)};
function paintFleet() {
  for (const hole of document.querySelectorAll("bp-paper-canvas [data-bp-fleet-id] [data-bp-fleet-body]")) {
    const id = hole.closest("[data-bp-fleet-id]").getAttribute("data-bp-fleet-id");
    if (FLEET_PAINT[id] != null) hole.innerHTML = FLEET_PAINT[id];
  }
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
    "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars", "--allow-file-access-from-files",
    `--window-size=${scenario.width},${scenario.height}`,
    "--virtual-time-budget=5000", `--screenshot=${screenshot}`, "--dump-dom", `file://${file}`,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 128 * 1024 * 1024 });
  const marker = dom.match(/BP_PARITY_RESULT=(\{.*?\})<\/pre>/s);
  if (!marker) {
    const error = dom.match(/<pre id="parity-status">BP_PARITY_ERROR=(.*?)<\/pre>/s);
    throw new Error(`${scenario.name}/${surface} produced no measurement marker${error ? `: ${error[1]}` : ""}`);
  }
  return JSON.parse(marker[1].replaceAll("&quot;", '"').replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&"));
}

const fixtureIds = FIXTURES.map((block) => block.id);
const report = { generatedAt: new Date().toISOString(), chromium: CHROME, shellCss: SHELL_CSS, plant: PLANT || null, fixtures: FIXTURES.map(({ id, type }) => ({ id, type })), scenarios: {} };
const seen = new Set();
let total = 0, knownCount = 0, unexpectedCount = 0, compared = 0;

if (PLANT) console.log(`PLANT  ${PLANT}`);
for (const scenario of SCENARIOS) {
  const view = runPage("reader", scenario);
  const scenarioReport = {};
  for (const surface of EDIT_SURFACES) {
    const edit = runPage(surface, scenario);
    const result = diffSurface({ surface, fixtures: fixtureIds, view, edit });
    const { known, unexpected } = classify(result.differences, KNOWN, seen);
    compared += result.compared;
    total += result.differences.length;
    knownCount += known.length;
    unexpectedCount += unexpected.length;
    scenarioReport[surface] = { compared: result.compared, known, unexpected, editOwners: edit };
    console.log(`${unexpected.length ? "FAIL" : "PASS"}  ${scenario.name} ${surface}: ${result.differences.length} view/edit style divergences (known ${known.length}, unexpected ${unexpected.length}, ${result.compared} owner pairs compared)`);
    for (const d of unexpected) {
      console.log(`      ${d.fixture} [${d.text}] ${d.axis}: view=${d.view} (${d.viewTag || ""}), edit=${d.edit} (${d.editTag || ""}${d.editRole ? " " + d.editRole : ""})`);
    }
  }
  scenarioReport.viewOwners = view;
  report.scenarios[scenario.name] = scenarioReport;
}

const stale = staleEntries(KNOWN, seen);
for (const entry of stale) console.log(`STALE  known divergence no longer fires — delete it from view-edit-parity.known.json: ${entry.surface}|${entry.fixture}|${entry.text}|${entry.axis}`);
report.stale = stale;
console.log(`TOTAL view/edit style divergences: ${total} (known ${knownCount}, unexpected ${unexpectedCount}, stale ${stale.length}) over ${compared} owner pairs, ${fixtureIds.length} fixtures, ${SCENARIOS.length} scenarios`);

const reportFile = join(ARTIFACTS, "report.json");
writeFileSync(reportFile, JSON.stringify(report, null, 2) + "\n");
console.log(`Evidence: ${reportFile}`);

// A matrix that compared nothing measured nothing.
if (compared === 0) {
  console.log("FAIL  no owner pairs were compared — the matrix measured nothing");
  process.exitCode = 1;
} else if ((unexpectedCount || stale.length) && !REPORT_ONLY) process.exitCode = 1;

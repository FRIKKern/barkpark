// __picker_footer_render.mjs — the [[ / @ / # picker's footer stays on one line (contract 1.17.0).
//
// Barkever's J05 review saw `esc dismiss` wrap onto a second line at 1440 and 390 px. Line
// boxes are layout, so this is measured in headless Chromium, not argued from the stylesheet:
// the committed bundle and stylesheet (the files the job's freshness step proves are built from
// src), a real <bp-paper-canvas> with `[[pla` typed, at 280, 390 and 1440 px (or BP_PICKER_WIDTHS).
// Per width: the footer's text sits on one line, the default English words are not clipped,
// and the menu stays inside the viewport. A host's longer words (data-strings) still keep one line.
//
//   Run:  node src/canvas/__picker_footer_render.mjs
//   Env:  BP_CHROME=/path/to/chrome
// It needs no node_modules: the narrow-render job runs it without `npm ci`.
//
// No Chromium prints SKIP and exits 0, like __narrow_render.mjs; CI sets BP_REQUIRE_CHROME=1, where a SKIP exits 1.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exitRig, skip, tally } from "../__rig.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ASSETS = join(HERE, "../../../../priv/static/assets");
const WIDTHS = (process.env.BP_PICKER_WIDTHS || "280,390,1440").split(",").map(Number);

function findChrome() {
  if (process.env.BP_CHROME) return process.env.BP_CHROME;
  const cache = join(homedir(), ".cache/puppeteer");
  for (const kind of ["chrome-headless-shell", "chrome"]) {
    const root = join(cache, kind);
    if (!existsSync(root)) continue;
    const bin = kind === "chrome" ? "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" : kind;
    for (const build of readdirSync(root)) {
      for (const dir of [`${kind}-mac-arm64`, `${kind}-mac-x64`, `${kind}-linux64`]) {
        const p = join(root, build, dir, kind === "chrome" && dir.endsWith("linux64") ? "chrome" : bin);
        if (existsSync(p)) return p;
      }
    }
  }
  for (const p of ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"]) {
    if (existsSync(p)) return p;
  }
  return null;
}

const CHROME = findChrome();
if (!CHROME) {
  process.exit(skip("__picker_footer_render.mjs — no Chromium found. Set BP_CHROME or install chrome-headless-shell."));
}

const css = readFileSync(join(ASSETS, "bp-paper-editor.css"), "utf8");
const bundle = join(ASSETS, "bp-paper-editor.bundle.js");
const probe = `
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("editable", "");
  canvas.blocks = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "See " }] }];
  canvas.wikilinkSource = () => [{ title: "Plan", id: "n-1", type: "note" }, { title: "Planting season notes", id: "n-2", type: "note" }];
  document.body.appendChild(canvas);
  setTimeout(() => {
    const editor = canvas._editor;
    editor.commands.focus("end");
    editor.view.dispatch(editor.state.tr.insertText("[[pla"));
    setTimeout(() => {
      const el = document.querySelector(".bp-wikilink-menu");
      const foot = el.querySelector(".bp-wikilink-foot");
      const range = document.createRange();
      range.selectNodeContents(foot);
      const mids = [...range.getClientRects()].filter((r) => r.width > 0).map((r) => (r.top + r.bottom) / 2).sort((a, b) => a - b);
      const lines = mids.filter((m, i) => i === 0 || m - mids[i - 1] > 6).length;
      const box = el.getBoundingClientRect();
      document.getElementById("__out").textContent = "RESULT" + JSON.stringify({
        vw: window.innerWidth, lines, clipped: foot.scrollWidth > foot.clientWidth, need: foot.scrollWidth, room: foot.clientWidth,
        left: Math.round(box.left), right: Math.round(box.right), text: foot.textContent,
      });
    }, 300);
  }, 400);
`;

const TMP = mkdtempSync(join(tmpdir(), "bp-picker-foot-"));
function measure(width, strings) {
  const file = join(TMP, "case.html");
  const attr = JSON.stringify(strings).replace(/&/g, "&amp;").replace(/"/g, "&quot;");
  writeFileSync(file, `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><style>html,body{margin:0}${css}</style><script>window.BP_PAPER_EDITOR_NO_INJECT = true;</script></head><body data-strings="${attr}"><pre id="__out">pending</pre><script src="file://${bundle}"></script><script>${probe}</script></body></html>`);
  const dom = execFileSync(CHROME, [
    "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
    `--window-size=${width},900`, "--virtual-time-budget=5000", "--dump-dom", `file://${file}`,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 16 * 1024 * 1024 });
  const m = dom.match(/RESULT(\{.*?\})<\/pre>/s);
  if (!m) throw new Error("the page produced no RESULT marker");
  return JSON.parse(m[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">"));
}

const LONG = { "insert link": "sett inn lenke til notatet", navigate: "bla gjennom resultatene", dismiss: "lukk uten å velge noe" };
const rig = tally();
const check = (name, ok, got) => rig.record(name, ok, JSON.stringify(got));

for (const width of WIDTHS) {
  const r = measure(width, {});
  check(`the viewport is ${width} px`, r.vw === width, r);
  check(`the footer is one line at ${width} px`, r.lines === 1, r);
  check(`the footer's words are not clipped at ${width} px`, !r.clipped, r);
  check(`the picker stays inside a ${width} px viewport`, r.left >= 0 && r.right <= r.vw, r);
  const long = measure(width, LONG);
  check(`a host's longer words keep the footer on one line at ${width} px`, long.lines === 1, long);
}

console.log(rig.failures ? `\n${rig.failures} failing` : "\nall pass");
exitRig(rig.passes, rig.failures);

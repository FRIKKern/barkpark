import { drills } from "../drills/index.mjs";
import { createFakeHost } from "../fake-host.mjs";
import { referenceFold, serverFold } from "../fold.mjs";
import { lights } from "../traps.mjs";
import { paintHood } from "./hood.mjs";
import { lines, settle, visibility } from "./measure.mjs";
import { paintReader } from "./reader.mjs";
import { tallyWords, watchTally } from "./tally.mjs";

const $ = (selector) => document.querySelector(selector);
const json = (url) => fetch(url).then((r) => r.json());
const [build, samples, fragments] = await Promise.all([json("/build.json"), json("/pack/samples.json"), json("/pack/fragments.json")]);
await customElements.whenDefined("bp-paper-canvas");

const docs = new Map([
  ...drills.map((d) => [`drill:${d.id}`, { label: `${d.id} ${d.title}`, blocks: d.doc, drill: d }]),
  ...samples.map((s) => [`sample:${s.type}`, { label: s.type, blocks: [{ id: `s-${s.type}`, ...s.input }], golden: s.expectedHtml }]),
]);

const params = new URLSearchParams(location.search);
const state = { key: docs.has(params.get("doc")) ? params.get("doc") : "sample:paragraph", host: null, canvases: [], reload: null, shown: "", tally: { tries: 0, hits: 0 } };

const ui = {
  edit: $(".tg-edit"),
  read: $(".tg-read"),
  tab: $(".tg-tab"),
  dot: $(".tg-tab-dot"),
  drawer: $("#tg-drawer"),
  lights: $(".tg-lights"),
  doc: $(".tg-doc"),
  steps: $(".tg-steps"),
  tally: $(".tg-tally"),
  reader: $(".tg-reader"),
  phone: $(".tg-phone"),
  dark: $(".tg-dark"),
  hood: $('[data-section="hood"]'),
  hoodEl: { fold: $(".tg-fold"), batches: $(".tg-batches"), diff: $(".tg-diff"), json: $(".tg-json") },
};

function remember() {
  const next = new URLSearchParams({ doc: state.key });
  for (const name of ["reader", "phone", "dark"]) if (ui[name].checked) next.set(name, "1");
  history.replaceState(null, "", `?${next}`);
}

function paintFleet(root) {
  for (const hole of root.querySelectorAll("[data-bp-fleet-id] [data-bp-fleet-body]:not([data-tg-painted])")) {
    hole.setAttribute("data-tg-painted", "");
    const type = hole.closest("[data-bp-type]")?.getAttribute("data-bp-type");
    const html = fragments[type];
    if (hole.dispatchEvent(new CustomEvent("bp-fleet-paint", { detail: { html }, cancelable: true }))) hole.innerHTML = html;
  }
}

function mountCanvases() {
  for (const canvas of state.canvases) state.host.detach(canvas);
  const windows = docs.get(state.key).drill?.windows || 1;
  state.canvases = Array.from({ length: windows }, () => {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.setAttribute("editable", "true");
    if (windows > 1) canvas.liveRemote = true;
    state.host.attach(canvas);
    return canvas;
  });
  ui.edit.replaceChildren(...state.canvases.map((canvas) => {
    const shell = document.createElement("div");
    shell.className = "bp-paper-editor tg-window";
    const body = document.createElement("div");
    body.className = "bp-paper-edit-canvas";
    body.append(canvas);
    shell.append(body);
    return shell;
  }));
}

function paintTally() {
  const rule = docs.get(state.key).drill?.tally;
  ui.tally.hidden = !rule;
  ui.tally.textContent = tallyWords(state.tally);
  ui.tally.classList.toggle("tg-tally--red", state.tally.hits < state.tally.tries);
}

function openDoc(key) {
  if (key !== state.key) state.tally = { tries: 0, hits: 0 };
  state.key = key;
  state.reload = null;
  const doc = docs.get(key);
  state.host = createFakeHost({ fold: build.fold ? serverFold(build.fold) : referenceFold, blocks: doc.blocks, onChange: changed });
  mountCanvases();
  ui.steps.hidden = !doc.drill;
  const says = doc.drill ? doc.drill.steps.map((step) => (step.hands ? `${step.say} (by hand)` : step.say)) : [];
  if (doc.drill?.repeat) says.push(`Pick ${doc.drill.id} again and repeat, ${doc.drill.repeat} tries in all`);
  ui.steps.replaceChildren(...says.map((say) => Object.assign(document.createElement("li"), { textContent: say })));
  paintTally();
  remember();
  changed();
}

async function reload() {
  const [canvas] = state.canvases;
  await settle(canvas, state.host);
  const before = lines(canvas);
  mountCanvases();
  await new Promise((r) => setTimeout(r, 50));
  state.reload = { before, after: lines(state.canvases[0]) };
}

function changed() {
  const doc = docs.get(state.key);
  if (!ui.read.hidden) paintReader({ label: $(".tg-read-label"), body: $(".tg-read-body") }, { golden: doc.golden, start: doc.blocks, saved: state.host.saved });
  if (ui.hood.open) paintHood(ui.hoodEl, { host: state.host, start: doc.blocks });
}

function paintLights() {
  const [canvas] = state.canvases;
  const list = lights({
    visibility: visibility(canvas),
    believed: canvas.blocks,
    saved: state.host.saved,
    batches: state.host.batches,
    refusals: state.host.refusals,
    settled: !state.host.busy,
    reload: state.reload,
  });
  const shown = JSON.stringify(list);
  if (shown === state.shown) return;
  state.shown = shown;
  ui.lights.replaceChildren(...list.map(({ key, name, ok, words }) => {
    const li = document.createElement("li");
    li.className = `tg-light tg-light--${ok === null ? "wait" : ok ? "green" : "red"}`;
    li.dataset.trap = key;
    li.dataset.ok = String(ok);
    li.innerHTML = `<span class="tg-lamp" aria-hidden="true"></span><span><strong></strong> <span class="tg-words"></span></span>`;
    li.querySelector("strong").textContent = `${name}${ok === false ? " — red" : ""}`;
    li.querySelector(".tg-words").textContent = words;
    return li;
  }));
  ui.dot.hidden = list.every((l) => l.ok !== false);
}

function setDrawer(open) {
  ui.drawer.hidden = !open;
  ui.tab.setAttribute("aria-expanded", String(open));
  document.body.classList.toggle("tg-drawer-open", open);
}

ui.doc.replaceChildren(
  ...[["Drills", "drill:"], ["Block samples", "sample:"]].map(([label, prefix]) => {
    const group = document.createElement("optgroup");
    group.label = label;
    for (const [key, doc] of docs) if (key.startsWith(prefix)) group.append(new Option(doc.label, key));
    return group;
  }),
);
ui.doc.value = state.key;
ui.doc.addEventListener("change", () => openDoc(ui.doc.value));
ui.tab.addEventListener("click", () => setDrawer(ui.drawer.hidden));
$(".tg-close").addEventListener("click", () => setDrawer(false));
$(".tg-reload").addEventListener("click", reload);
ui.hood.addEventListener("toggle", changed);

new MutationObserver(() => paintFleet(ui.edit)).observe(ui.edit, { childList: true, subtree: true });
openDoc(state.key);

const views = {
  reader: (on) => { ui.read.hidden = !on; document.body.classList.toggle("tg-with-reader", on); changed(); },
  phone: (on) => document.body.classList.toggle("tg-phone", on),
  dark: (on) => { document.documentElement.dataset.theme = on ? "dark" : "light"; },
};
for (const [name, apply] of Object.entries(views)) {
  ui[name].checked = params.get(name) === "1";
  apply(ui[name].checked);
  ui[name].addEventListener("change", () => { apply(ui[name].checked); remember(); });
}

watchTally(ui.edit, () => {
  const rule = docs.get(state.key).drill?.tally;
  return rule && { rule, canvas: state.canvases[0], tally: state.tally, counted: paintTally };
});
$(".tg-build").textContent = `Editor build: ${build.label} at ${build.sha}`;
setInterval(paintLights, 200);
window.testingGround = { state, reload, openDoc, setDrawer, paintLights, settle: () => settle(state.canvases[0], state.host) };

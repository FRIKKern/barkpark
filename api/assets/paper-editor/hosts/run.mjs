import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launchChrome, navigate, evaluate, waitFor } from "./browser.mjs";
import { journeys } from "./journeys.mjs";
import { profiles } from "./profiles.mjs";
import { startHostServer } from "./server.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_OUTPUT = join(HERE, "artifacts");
const REPO = join(HERE, "../../../..");
const MAIN_ASSETS = join(REPO, "api/priv/static/assets");
const BUNDLE = "bp-paper-editor.bundle.js";

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

function usage(why) {
  throw new Error(`${why}\nusage: npm run hosts -- [--output=<directory>] [--baseline=<staged-build-directory>] [--candidate=<staged-build-directory>] [--allow-unavailable] [--host=<id>]`);
}

export function options(args) {
  const known = /^--(output=.+|baseline=.+|candidate=.+|host=[a-z0-9-]+|allow-unavailable)$/;
  const bad = args.find((arg) => !known.test(arg));
  if (bad) usage(`unknown or malformed option ${bad}`);
  const value = (name) => args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
  const duplicates = ["output", "baseline", "candidate", "host"].filter((name) => args.filter((arg) => arg.startsWith(`--${name}=`)).length > 1);
  if (args.filter((arg) => arg === "--allow-unavailable").length > 1) duplicates.push("allow-unavailable");
  if (duplicates.length) usage(`--${duplicates[0]} given twice`);
  const host = value("host");
  if (host && !profiles.some((entry) => entry.id === host)) usage(`unknown host ${host}`);
  return { output: resolve(value("output") || DEFAULT_OUTPUT), baseline: value("baseline") && resolve(value("baseline")), candidate: value("candidate") && resolve(value("candidate")), host, allowUnavailable: args.includes("--allow-unavailable") };
}

export function stagedBuild(dir, label = "candidate") {
  const sha = readFileSync(join(dir, "source-commit"), "utf8").trim();
  if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error(`candidate source-commit is not a full Git SHA: ${JSON.stringify(sha)}`);
  const sums = readFileSync(join(dir, "SHA256SUMS"), "utf8").trim().split("\n").map((line) => {
    const match = line.match(/^([0-9a-f]{64})  ([a-z0-9][a-z0-9.-]*)$/);
    if (!match) throw new Error(`malformed candidate SHA256SUMS line: ${JSON.stringify(line)}`);
    return { expected: match[1], name: match[2] };
  });
  for (const { expected, name } of sums) {
    const actual = sha256(readFileSync(join(dir, name)));
    if (actual !== expected) throw new Error(`candidate checksum mismatch for ${name}: wanted ${expected}, got ${actual}`);
  }
  for (const name of ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css"]) {
    if (!sums.some((entry) => entry.name === name)) throw new Error(`candidate SHA256SUMS does not cover ${name}`);
  }
  return { label, sha, dir, bundleSha256: sums.find(({ name }) => name === BUNDLE).expected };
}

export function baselineBuild() {
  const sha = execFileSync("git", ["log", "-1", "--format=%H", "--", `api/priv/static/assets/${BUNDLE}`], { cwd: REPO, encoding: "utf8" }).trim();
  return { label: "main", sha, dir: MAIN_ASSETS, bundleSha256: sha256(readFileSync(join(MAIN_ASSETS, BUNDLE))) };
}

export function distinctBuilds(baseline, candidate) {
  if (baseline.bundleSha256 === candidate.bundleSha256) throw new Error(`candidate bundle is byte-identical to baseline ${baseline.bundleSha256}; E12 needs two distinct clients`);
  return true;
}

export function upgradeBuilds(baselineDir, candidateDir) {
  const baseline = baselineDir ? stagedBuild(baselineDir, "baseline") : baselineBuild();
  const candidate = candidateDir && stagedBuild(candidateDir);
  if (candidate) distinctBuilds(baseline, candidate);
  return { baseline, candidate };
}

async function screenshot(cdp, path) {
  const { data } = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false, fromSurface: true });
  writeFileSync(path, Buffer.from(data, "base64"));
}

function quoteConcat(path) {
  return `'${path.replaceAll("'", "'\\''")}'`;
}

function gif(frames, path) {
  const ffmpeg = process.env.HOSTS_FFMPEG || "ffmpeg";
  const list = `${path}.frames.txt`;
  writeFileSync(list, frames.flatMap((frame) => [`file ${quoteConcat(frame)}`, "duration 0.7"]).join("\n") + `\nfile ${quoteConcat(frames.at(-1))}\n`);
  try {
    execFileSync(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-vf", "fps=8,scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", path]);
  } finally {
    unlinkSync(list);
  }
}

function ffmpegVersion() {
  const ffmpeg = process.env.HOSTS_FFMPEG || "ffmpeg";
  return execFileSync(ffmpeg, ["-version"], { encoding: "utf8" }).split("\n")[0];
}

async function viewport(cdp, width, height) {
  await cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: width <= 390 });
}

async function key(cdp, key, { code = key, modifiers = 0 } = {}) {
  await cdp.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code, modifiers });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key, code, modifiers });
}

async function mod(cdp, shift = false) {
  return (await evaluate(cdp, "navigator.platform.includes('Mac')")) ? 4 + (shift ? 8 : 0) : 2 + (shift ? 8 : 0);
}

async function focusText(cdp, text, canvas = 0, at = "end") {
  await evaluate(cdp, `(() => {
    const root = window.testingGround.state.canvases[${canvas}];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) if (node.data.includes(${JSON.stringify(text)})) break;
    if (!node) throw new Error(${JSON.stringify(`text not found: ${text}`)});
    const range = document.createRange(); range.setStart(node, ${at === "start" ? "0" : "node.data.length"}); range.collapse(true);
    const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    node.parentElement.focus(); return true;
  })()`);
}

async function focusLastParagraph(cdp) {
  await evaluate(cdp, `(() => {
    const p = document.querySelector('.ProseMirror p:last-of-type');
    if (!p) throw new Error('no editable paragraph');
    const range = document.createRange(); range.selectNodeContents(p); range.collapse(false);
    const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    p.focus(); return true;
  })()`);
}

async function settle(cdp) {
  await evaluate(cdp, "window.testingGround.settle()");
  await waitFor(cdp, "!window.testingGround.state.host.busy");
}

async function paste(cdp, { html = "", text = "" }) {
  await evaluate(cdp, `(() => {
    const data = new DataTransfer();
    data.setData('text/html', ${JSON.stringify(html)});
    data.setData('text/plain', ${JSON.stringify(text)});
    return document.activeElement.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
  })()`);
  await settle(cdp);
}

async function e01(cdp, root, host) {
  const before = join(root, "hosts", `${host}--desktop-light--before.png`);
  await screenshot(cdp, before);
  const marker = ` host-${host}-saved`;
  await evaluate(cdp, `(() => { const p = document.querySelector('.ProseMirror p'); const r = document.createRange(); r.selectNodeContents(p); r.collapse(false); const s = getSelection(); s.removeAllRanges(); s.addRange(r); p.focus(); return true; })()`);
  await cdp.send("Input.insertText", { text: marker });
  await waitFor(cdp, `window.testingGround.state.host.saved.some(b => JSON.stringify(b).includes(${JSON.stringify(marker)}))`);
  const after = join(root, "hosts", `${host}--desktop-light--after.png`);
  await screenshot(cdp, after);
  const output = join(root, "journeys", `${host}--E01.gif`);
  gif([before, after], output);
  return { id: "E01", state: "passed", artifacts: [before, after, output].map((path) => path.slice(root.length + 1)) };
}

async function e02(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=drill:D04`);
  await focusText(cdp, "Pack the stove and the tent.");
  const before = join(root, "journeys", `${host}--E02--before.png`);
  await screenshot(cdp, before);
  await key(cdp, "Enter");
  await cdp.send("Input.insertText", { text: "Split marker" });
  await settle(cdp);
  await waitFor(cdp, "window.testingGround.state.host.saved.length === 2");
  const split = join(root, "journeys", `${host}--E02--split.png`);
  await screenshot(cdp, split);
  await focusText(cdp, "Split marker", 0, "start");
  await key(cdp, "Backspace");
  await settle(cdp);
  await waitFor(cdp, "window.testingGround.state.host.saved.length === 1 && JSON.stringify(window.testingGround.state.host.saved).includes('Split marker')");
  const merged = join(root, "journeys", `${host}--E02--merged.png`);
  await screenshot(cdp, merged);
  const output = join(root, "journeys", `${host}--E02.gif`);
  gif([before, split, merged], output);
  return { id: "E02", state: "passed", artifacts: [before, split, merged, output].map((path) => path.slice(root.length + 1)) };
}

const markdownTable = "| Left | Center | Right |\n| :--- | :---: | ---: |\n| pipe \\| value | **bold** | [link](https://example.com) |";

async function e03(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=drill:D05`);
  await focusText(cdp, "Alpha");
  const before = join(root, "journeys", `${host}--E03--before.png`);
  await screenshot(cdp, before);
  await paste(cdp, { html: "<p><strong>Rich marker</strong> and text</p><table><tbody><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></tbody></table>", text: "Rich marker and text\nA\tB\n1\t2" });
  await waitFor(cdp, "JSON.stringify(window.testingGround.state.host.saved).includes('Rich marker') && window.testingGround.state.host.saved.some(b => b.type === 'table')");
  const rich = await evaluate(cdp, "window.testingGround.state.host.saved");
  if (!rich.some((block) => JSON.stringify(block).includes('"type":"strong"'))) throw new Error(`${host} E03: rich paste lost strong content: ${JSON.stringify(rich)}`);
  await navigate(cdp, `${baseUrl}?doc=sample:paragraph`);
  await focusLastParagraph(cdp);
  await paste(cdp, { text: markdownTable });
  await waitFor(cdp, "window.testingGround.state.host.saved.some(b => b.type === 'table' && JSON.stringify(b).includes('pipe | value') && JSON.stringify(b).includes('center') && JSON.stringify(b).includes('https://example.com'))");
  const after = join(root, "journeys", `${host}--E03--after.png`);
  await screenshot(cdp, after);
  return { id: "E03", state: "passed", assertions: ["rich strong content preserved", "HTML table preserved", "GFM alignment and link preserved"], artifacts: [before, after].map((path) => path.slice(root.length + 1)) };
}

async function e04(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=sample:paragraph`);
  await focusLastParagraph(cdp);
  const before = join(root, "journeys", `${host}--E04--before.png`);
  await screenshot(cdp, before);
  const initial = await evaluate(cdp, "JSON.stringify(window.testingGround.state.host.saved)");
  await paste(cdp, { text: markdownTable });
  const pasted = await evaluate(cdp, "JSON.stringify(window.testingGround.state.host.saved)");
  if (pasted === initial) throw new Error(`${host} E04: paste made no saved change`);
  const afterPaste = join(root, "journeys", `${host}--E04--paste.png`);
  await screenshot(cdp, afterPaste);
  await key(cdp, "z", { code: "KeyZ", modifiers: await mod(cdp) });
  await settle(cdp);
  await waitFor(cdp, `JSON.stringify(window.testingGround.state.host.saved) === ${JSON.stringify(initial)}`);
  const undone = join(root, "journeys", `${host}--E04--undo.png`);
  await screenshot(cdp, undone);
  await key(cdp, "z", { code: "KeyZ", modifiers: await mod(cdp, true) });
  await settle(cdp);
  await waitFor(cdp, `JSON.stringify(window.testingGround.state.host.saved) === ${JSON.stringify(pasted)}`);
  const redone = join(root, "journeys", `${host}--E04--redo.png`);
  await screenshot(cdp, redone);
  const output = join(root, "journeys", `${host}--E04.gif`);
  gif([before, afterPaste, undone, redone], output);
  return { id: "E04", state: "passed", artifacts: [before, afterPaste, undone, redone, output].map((path) => path.slice(root.length + 1)) };
}

async function e05(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=sample:paragraph`);
  await evaluate(cdp, `(() => {
    const canvas = window.testingGround.state.canvases[0];
    canvas.wikilinkSource = query => [{ title: 'Plan', id: 'n-plan', type: 'paper' }].filter(row => row.title.toLowerCase().includes(query.toLowerCase()));
    canvas.wikilinkResolve = id => id === 'n-plan' ? { title: 'Roadmap' } : null;
  })()`);
  await focusLastParagraph(cdp);
  const before = join(root, "journeys", `${host}--E05--before.png`);
  await screenshot(cdp, before);
  await cdp.send("Input.insertText", { text: " [[Plan]]" });
  await waitFor(cdp, "JSON.stringify(window.testingGround.state.host.saved).includes('n-plan') && document.querySelector('.bp-wikilink-label')?.textContent === 'Roadmap'");
  await paste(cdp, { text: " and [[plan|the plan]]" });
  await waitFor(cdp, "JSON.stringify(window.testingGround.state.host.saved).includes('the plan') && document.querySelectorAll('[data-wikilink]').length >= 2");
  const linked = join(root, "journeys", `${host}--E05--linked.png`);
  await screenshot(cdp, linked);
  await evaluate(cdp, `(() => {
    const canvas = window.testingGround.state.canvases[0];
    canvas.wikilinkResolve = id => id === 'n-plan' ? { title: 'Renamed roadmap' } : null;
    canvas.refreshWikilinks();
  })()`);
  await waitFor(cdp, "[...document.querySelectorAll('.bp-wikilink-label')].some(el => el.textContent === 'Renamed roadmap') && [...document.querySelectorAll('[data-wikilink]')].some(el => el.textContent.includes('the plan'))");
  const renamed = join(root, "journeys", `${host}--E05--renamed.png`);
  await screenshot(cdp, renamed);
  const output = join(root, "journeys", `${host}--E05.gif`);
  gif([before, linked, renamed], output);
  return { id: "E05", state: "passed", assertions: ["typed link resolved", "pasted alias preserved", "unaliased live title refreshed"], artifacts: [before, linked, renamed, output].map((path) => path.slice(root.length + 1)) };
}

async function openSlash(cdp) {
  await focusLastParagraph(cdp);
  await key(cdp, "Enter");
  await cdp.send("Input.insertText", { text: "/" });
  await waitFor(cdp, "document.querySelectorAll('.bp-slash-menu .bp-slash-item').length >= 40");
}

async function e06(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=sample:paragraph`);
  await openSlash(cdp);
  const rows = await evaluate(cdp, `[...document.querySelectorAll('.bp-slash-menu .bp-slash-item')].map((row, index) => ({ index, type: row.dataset.type, label: row.querySelector('.bp-slash-label').textContent }))`);
  if (rows.length < 40) throw new Error(`${host} E06: slash menu exposed ${rows.length} rows, wanted at least 40`);
  const inserted = [];
  for (const row of rows) {
    await evaluate(cdp, "window.testingGround.openDoc('sample:paragraph')");
    await waitFor(cdp, "Boolean(window.testingGround.state.canvases[0]?._editor)");
    const baseline = await evaluate(cdp, "window.testingGround.state.host.saved.map(block => block.id)");
    await openSlash(cdp);
    await evaluate(cdp, `document.querySelectorAll('.bp-slash-menu .bp-slash-item')[${row.index}].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }))`);
    await settle(cdp);
    const added = await evaluate(cdp, `window.testingGround.state.host.saved.filter(block => !${JSON.stringify(baseline)}.includes(block.id)).map(block => block.type)`);
    if (!added.length) throw new Error(`${host} E06: ${row.label} (${row.type}) inserted no saved block`);
    inserted.push({ ...row, savedTypes: added });
  }
  await viewport(cdp, 1600, 1200);
  await evaluate(cdp, `(() => {
    const results = ${JSON.stringify(inserted)};
    document.body.replaceChildren();
    const title = document.createElement('h1'); title.textContent = ${JSON.stringify(host)} + ' · E06 slash insertion sweep';
    const note = document.createElement('p'); note.textContent = results.length + ' menu rows inserted a saved block';
    const grid = document.createElement('div');
    Object.assign(document.body.style, { margin: '24px', font: '15px/1.4 system-ui', background: '#f6faf9', color: '#15231f' });
    Object.assign(grid.style, { display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '8px' });
    for (const result of results) {
      const cell = document.createElement('div');
      cell.textContent = '✓ ' + result.label + ' → ' + result.savedTypes.join(', ');
      Object.assign(cell.style, { padding: '8px 10px', border: '1px solid #c9d8d2', borderRadius: '6px', background: '#fff' });
      grid.append(cell);
    }
    document.body.append(title, note, grid);
  })()`);
  const grid = join(root, "journeys", `${host}--E06-grid.png`);
  await screenshot(cdp, grid);
  return { id: "E06", state: "passed", assertions: [`${rows.length} slash rows each inserted a saved block`], artifacts: [grid.slice(root.length + 1)] };
}

async function installGate(cdp) {
  await evaluate(cdp, `(() => {
    const host = window.testingGround.state.host;
    const online = host.fold;
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    let first = true;
    host.fold = { name: 'offline gate', apply: async (blocks, ops) => {
      if (first) { first = false; await gate; }
      return online.apply(blocks, ops);
    } };
    window.__hostsReconnect = release;
  })()`);
}

async function e07(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=drill:D06`);
  await installGate(cdp);
  const before = join(root, "journeys", `${host}--E07--before.png`);
  await screenshot(cdp, before);
  await focusText(cdp, "Window B edits here.", 1);
  await cdp.send("Input.insertText", { text: " remote-arrived" });
  await waitFor(cdp, "window.testingGround.state.host.busy");
  await focusText(cdp, "Window A types here.", 0);
  await cdp.send("Input.insertText", { text: " my-keys-win" });
  await evaluate(cdp, "window.__hostsReconnect()");
  await settle(cdp);
  await waitFor(cdp, "JSON.stringify(window.testingGround.state.host.saved).includes('remote-arrived') && JSON.stringify(window.testingGround.state.host.saved).includes('my-keys-win') && window.testingGround.state.canvases.every(c => JSON.stringify(c.blocks).includes('remote-arrived') && JSON.stringify(c.blocks).includes('my-keys-win'))");
  const after = join(root, "journeys", `${host}--E07--after.png`);
  await screenshot(cdp, after);
  const output = join(root, "journeys", `${host}--E07.gif`);
  gif([before, after], output);
  return { id: "E07", state: "passed", artifacts: [before, after, output].map((path) => path.slice(root.length + 1)) };
}

async function e08(cdp, root, host, baseUrl) {
  await navigate(cdp, `${baseUrl}?doc=sample:paragraph`);
  await installGate(cdp);
  await focusLastParagraph(cdp);
  const before = join(root, "journeys", `${host}--E08--before.png`);
  await screenshot(cdp, before);
  await cdp.send("Input.insertText", { text: " offline-pending" });
  await waitFor(cdp, "window.testingGround.state.host.busy && !JSON.stringify(window.testingGround.state.host.saved).includes('offline-pending')");
  const pending = join(root, "journeys", `${host}--E08--pending.png`);
  await screenshot(cdp, pending);
  await evaluate(cdp, "window.__hostsReconnect()");
  await settle(cdp);
  await waitFor(cdp, "JSON.stringify(window.testingGround.state.host.saved).includes('offline-pending')");
  const after = join(root, "journeys", `${host}--E08--after.png`);
  await screenshot(cdp, after);
  const log = join(root, "journeys", `${host}--E08-ops.json`);
  const batches = await evaluate(cdp, "window.testingGround.state.host.batches.map(({ at, ...batch }) => batch)");
  writeFileSync(log, JSON.stringify(batches, null, 2) + "\n");
  const output = join(root, "journeys", `${host}--E08.gif`);
  gif([before, pending, after], output);
  return { id: "E08", state: "passed", artifacts: [before, pending, after, log, output].map((path) => path.slice(root.length + 1)) };
}

async function e10(cdp, root, host, baseUrl) {
  const artifacts = [];
  for (const view of [
    { name: "desktop-light", width: 1280, height: 800, query: "" },
    { name: "desktop-dark", width: 1280, height: 800, query: "&dark=1" },
    { name: "phone-light", width: 390, height: 844, query: "&phone=1" },
    { name: "phone-dark", width: 390, height: 844, query: "&phone=1&dark=1" },
  ]) {
    await viewport(cdp, view.width, view.height);
    await navigate(cdp, `${baseUrl}?doc=sample:paragraph${view.query}`);
    const path = join(root, "hosts", `${host}--${view.name}.png`);
    await screenshot(cdp, path);
    artifacts.push(path.slice(root.length + 1));
  }
  return { id: "E10", state: "passed", artifacts };
}

async function e09(cdp, root, host, baseUrl) {
  await viewport(cdp, 1280, 800);
  await navigate(cdp, `${baseUrl}?doc=sample:callout`);
  await waitFor(cdp, `(() => { const light = document.querySelector('[data-trap="read-edit"]'); return Boolean(light && light.dataset.ok !== 'null'); })()`);
  const verdict = await evaluate(cdp, `(() => {
    const light = document.querySelector('[data-trap="read-edit"]');
    return { ok: light?.dataset.ok, words: light?.textContent.trim() };
  })()`);
  const expected = "Read ≠ Edit — red The reader and editor differ at block 1 (s-callout).";
  if (verdict.ok !== "false" || verdict.words !== expected) throw new Error(`${host} E09: expected the frozen known-red diagnostic ${JSON.stringify(expected)}, got ${JSON.stringify(verdict)}`);
  const artifact = join(root, "journeys", `${host}--E09--known-red.png`);
  await screenshot(cdp, artifact);
  return { id: "E09", state: "passed", kind: "diagnostic-negative", expected: "red", assertions: ["Read/Edit trap settled", "known callout mismatch was detected at s-callout"], artifacts: [artifact.slice(root.length + 1)] };
}

async function preparePickerCanvas(cdp) {
  await evaluate(cdp, `(() => {
    const canvas = window.testingGround.state.canvases[0];
    canvas.setAttribute('data-picker-browse', 'true');
    canvas.setAttribute('data-dataset', 'production');
    canvas.setAttribute('data-scope-prefix', '/w/hosts/p/journeys');
    canvas.applyServerBlocks(structuredClone(window.testingGround.state.host.saved));
  })()`);
}

async function pick(cdp, selector, value) {
  await waitFor(cdp, `Boolean(document.querySelector(${JSON.stringify(selector)}))`);
  await evaluate(cdp, `(() => {
    const picker = document.querySelector(${JSON.stringify(selector)});
    picker.value = ${JSON.stringify(value)};
    picker.dispatchEvent(new CustomEvent('bp-change', { bubbles: true, detail: { value: ${JSON.stringify(value)} } }));
  })()`);
  await settle(cdp);
  await waitFor(cdp, `JSON.stringify(window.testingGround.state.host.saved).includes(${JSON.stringify(value)})`);
}

async function e11(cdp, root, host, baseUrl, enabled) {
  if (!enabled) return { id: "E11", state: "not-applicable", reason: "picker journey applies to Studio hosts" };
  const frames = [];
  await viewport(cdp, 1280, 800);
  await navigate(cdp, `${baseUrl}?doc=sample:field-image`);
  await waitFor(cdp, "Boolean(customElements.get('bp-media-picker')) && Boolean(customElements.get('bp-reference-picker'))");
  await preparePickerCanvas(cdp);
  await pick(cdp, "bp-media-picker", "https://example.test/host-image.png");
  const image = join(root, "journeys", `${host}--E11--image.png`);
  await screenshot(cdp, image); frames.push(image);
  await navigate(cdp, `${baseUrl}?doc=sample:field-reference`);
  await preparePickerCanvas(cdp);
  await pick(cdp, "bp-reference-picker", "paper-host-reference");
  const reference = join(root, "journeys", `${host}--E11--reference.png`);
  await screenshot(cdp, reference); frames.push(reference);
  await navigate(cdp, `${baseUrl}?doc=sample:card`);
  await preparePickerCanvas(cdp);
  await pick(cdp, 'bp-media-picker[chrome="ghost"]', "https://example.test/card-media.png");
  const card = join(root, "journeys", `${host}--E11--card.png`);
  await screenshot(cdp, card); frames.push(card);
  const output = join(root, "journeys", `${host}--E11.gif`);
  gif(frames, output);
  return { id: "E11", state: "passed", assertions: ["real media picker saved image", "real reference picker saved document", "card ghost picker saved media"], artifacts: [...frames, output].map((path) => path.slice(root.length + 1)) };
}

async function observedBuild(cdp) {
  return await evaluate(cdp, `(async () => {
    const [metadataResponse, bundleResponse] = await Promise.all([fetch('/build.json'), fetch('/build/${BUNDLE}')]);
    if (!metadataResponse.ok || !bundleResponse.ok) throw new Error('build identity request failed');
    const metadata = await metadataResponse.json();
    const digest = await crypto.subtle.digest('SHA-256', await bundleResponse.arrayBuffer());
    return { ...metadata, bundleSha256: [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('') };
  })()`);
}

function verifyObservedBuild(expected, observed, leg) {
  if (observed.sha !== expected.sha) throw new Error(`${leg} loaded build ${observed.sha}, expected ${expected.sha}`);
  if (observed.bundleSha256 !== expected.bundleSha256) throw new Error(`${leg} loaded bundle ${observed.bundleSha256}, expected ${expected.bundleSha256}`);
}

async function replaySave(cdp, baseUrl, marker, screenshotPath, expectedBuild) {
  await viewport(cdp, 1280, 800);
  await navigate(cdp, `${baseUrl}?doc=sample:paragraph`);
  const build = await observedBuild(cdp);
  verifyObservedBuild(expectedBuild, build, expectedBuild.label);
  await focusLastParagraph(cdp);
  await cdp.send("Input.insertText", { text: marker });
  await settle(cdp);
  await waitFor(cdp, `JSON.stringify(window.testingGround.state.host.saved).includes(${JSON.stringify(marker)})`);
  await screenshot(cdp, screenshotPath);
  return { build, ops: await evaluate(cdp, "window.testingGround.state.host.batches.map(({ at, answer, ...batch }) => batch)") };
}

async function e12(cdp, root, host, mainUrl, candidateUrl, baselineBuild, candidate) {
  if (!candidateUrl) return { id: "E12", state: "unavailable", reason: "rerun with --candidate=<verified staged editor directory>" };
  const marker = " upgrade-replay-save";
  const baselineImage = join(root, "journeys", `${host}--E12--baseline.png`);
  const candidateImage = join(root, "journeys", `${host}--E12--candidate.png`);
  const baseline = await replaySave(cdp, mainUrl, marker, baselineImage, baselineBuild);
  const replayed = await replaySave(cdp, candidateUrl, marker, candidateImage, candidate);
  const compatible = JSON.stringify(baseline.ops) === JSON.stringify(replayed.ops);
  if (!compatible) throw new Error(`${host} E12: candidate save ops differ from baseline`);
  const report = join(root, "journeys", `${host}--E12-replay.json`);
  writeFileSync(report, JSON.stringify({
    baseline: { label: baselineBuild.label, sourceCommit: baselineBuild.sha, expectedBundleSha256: baselineBuild.bundleSha256, loaded: baseline.build, ops: baseline.ops },
    candidate: { label: candidate.label, sourceCommit: candidate.sha, expectedBundleSha256: candidate.bundleSha256, loaded: replayed.build, ops: replayed.ops },
    compatible,
  }, null, 2) + "\n");
  const output = join(root, "journeys", `${host}--E12.gif`);
  gif([baselineImage, candidateImage], output);
  return { id: "E12", state: "passed", assertions: ["browser-loaded baseline and candidate bundles match their recorded SHA-256 identities", "baseline and candidate bundle identities differ", "baseline client saved", "candidate client saved", "operation replay is byte-equal"], artifacts: [baselineImage, candidateImage, report, output].map((path) => path.slice(root.length + 1)) };
}

export async function run(args = process.argv.slice(2)) {
  const opts = options(args);
  mkdirSync(join(opts.output, "hosts"), { recursive: true });
  mkdirSync(join(opts.output, "journeys"), { recursive: true });
  const selected = opts.host ? profiles.filter((entry) => entry.id === opts.host) : profiles;
  let testingGround;
  let server;
  let browser;
  let candidateGround;
  let candidateServer;
  let cleaned = false;
  async function cleanup() {
    if (cleaned) return;
    cleaned = true;
    const closers = [browser, candidateServer, candidateGround, server, testingGround].filter(Boolean);
    const failures = [];
    for (const resource of closers) {
      try { await resource.close(); } catch (error) { failures.push(error); }
    }
    if (failures.length) throw failures[0];
  }
  const signals = new Map([["SIGINT", 130], ["SIGTERM", 143]]);
  const handlers = new Map([...signals].map(([signal, code]) => [signal, async () => {
    try { await cleanup(); } finally { process.exit(code); }
  }]));
  for (const [signal, handler] of handlers) process.once(signal, handler);
  const { baseline, candidate } = upgradeBuilds(opts.baseline, opts.candidate);
  const runtimeJourneys = journeys.map((journey) => {
    if (journey.id !== "E12") return journey;
    const { reason, ...rest } = journey;
    return candidate
      ? { ...rest, state: "available", sourceCommit: candidate.sha, bundleSha256: candidate.bundleSha256 }
      : { ...rest, state: "unavailable", reason };
  });
  const manifest = { schema: 1, tools: { chrome: null, ffmpeg: ffmpegVersion() }, hosts: [], journeys: runtimeJourneys };
  try {
    const { start } = await import("../src/testing-ground/server.mjs");
    testingGround = await start({ builds: [baseline] });
    server = await startHostServer({ testingGround });
    if (candidate) {
      candidateGround = await start({ builds: [candidate] });
      candidateServer = await startHostServer({ testingGround: candidateGround });
    }
    browser = await launchChrome();
    manifest.tools.chrome = { version: browser.chrome.version, words: browser.chrome.words };
    for (const host of selected) {
      const url = `${server.url}/hosts/${host.id}/`;
      await viewport(browser.cdp, 1280, 800);
      await navigate(browser.cdp, `${url}?doc=sample:paragraph`);
      const pageProfile = await evaluate(browser.cdp, "window.__BP_HOST_PROFILE__");
      if (pageProfile.id !== host.id) throw new Error(`${host.id}: page profile mismatch`);
      const results = [
        await e01(browser.cdp, opts.output, host.id),
        await e02(browser.cdp, opts.output, host.id, url),
        await e03(browser.cdp, opts.output, host.id, url),
        await e04(browser.cdp, opts.output, host.id, url),
        await e05(browser.cdp, opts.output, host.id, url),
        await e06(browser.cdp, opts.output, host.id, url),
        await e07(browser.cdp, opts.output, host.id, url),
        await e08(browser.cdp, opts.output, host.id, url),
        await e09(browser.cdp, opts.output, host.id, url),
        await e10(browser.cdp, opts.output, host.id, url),
        await e11(browser.cdp, opts.output, host.id, url, host.pickers),
        await e12(browser.cdp, opts.output, host.id, url, candidateServer && `${candidateServer.url}/hosts/${host.id}/`, baseline, candidate),
      ];
      manifest.hosts.push({ ...host, state: "passed", results });
      console.log(`${host.id}: E01-E08, E09 known-red diagnostic, E10${host.pickers ? "-E11" : ""}${candidate ? ", E12" : ""} passed`);
    }
  } finally {
    for (const [signal, handler] of handlers) process.removeListener(signal, handler);
    await cleanup();
  }
  const unavailable = runtimeJourneys.filter((journey) => journey.state === "unavailable");
  manifest.state = unavailable.length ? "incomplete" : "passed";
  const manifestPath = join(opts.output, "hosts", "manifest.json");
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  if (unavailable.length && !opts.allowUnavailable) throw new Error(`${unavailable.length} journeys unavailable: ${unavailable.map(({ id }) => id).join(", ")} (artifacts and ${manifestPath} were written; --allow-unavailable is for development capture only)`);
  return manifest;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  run().catch((error) => {
    console.error(`npm run hosts: ${error.message}`);
    process.exitCode = 1;
  });
}

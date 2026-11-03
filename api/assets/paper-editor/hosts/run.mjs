import { execFileSync } from "node:child_process";
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launchChrome, navigate, evaluate, waitFor } from "./browser.mjs";
import { journeys } from "./journeys.mjs";
import { profiles } from "./profiles.mjs";
import { startHostServer } from "./server.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_OUTPUT = join(HERE, "artifacts");

function usage(why) {
  throw new Error(`${why}\nusage: npm run hosts -- [--output=<directory>] [--allow-unavailable] [--host=<id>]`);
}

export function options(args) {
  const known = /^--(output=.+|host=[a-z0-9-]+|allow-unavailable)$/;
  const bad = args.find((arg) => !known.test(arg));
  if (bad) usage(`unknown or malformed option ${bad}`);
  const value = (name) => args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
  const duplicates = ["output", "host"].filter((name) => args.filter((arg) => arg.startsWith(`--${name}=`)).length > 1);
  if (args.filter((arg) => arg === "--allow-unavailable").length > 1) duplicates.push("allow-unavailable");
  if (duplicates.length) usage(`--${duplicates[0]} given twice`);
  const host = value("host");
  if (host && !profiles.some((entry) => entry.id === host)) usage(`unknown host ${host}`);
  return { output: resolve(value("output") || DEFAULT_OUTPUT), host, allowUnavailable: args.includes("--allow-unavailable") };
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

async function viewport(cdp, width, height) {
  await cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: width <= 390 });
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

export async function run(args = process.argv.slice(2)) {
  const opts = options(args);
  mkdirSync(join(opts.output, "hosts"), { recursive: true });
  mkdirSync(join(opts.output, "journeys"), { recursive: true });
  const selected = opts.host ? profiles.filter((entry) => entry.id === opts.host) : profiles;
  let testingGround;
  let server;
  let browser;
  const manifest = { schema: 1, chrome: null, hosts: [], journeys };
  try {
    const { start } = await import("../src/testing-ground/server.mjs");
    testingGround = await start();
    server = await startHostServer({ testingGround });
    browser = await launchChrome();
    manifest.chrome = { version: browser.chrome.version, words: browser.chrome.words };
    for (const host of selected) {
      const url = `${server.url}/hosts/${host.id}/`;
      await viewport(browser.cdp, 1280, 800);
      await navigate(browser.cdp, `${url}?doc=sample:paragraph`);
      const pageProfile = await evaluate(browser.cdp, "window.__BP_HOST_PROFILE__");
      if (pageProfile.id !== host.id) throw new Error(`${host.id}: page profile mismatch`);
      const results = [await e01(browser.cdp, opts.output, host.id), await e10(browser.cdp, opts.output, host.id, url)];
      manifest.hosts.push({ ...host, state: "passed", results });
      console.log(`${host.id}: E01, E10 passed`);
    }
  } finally {
    if (browser) await browser.close();
    if (server) await server.close();
    if (testingGround) await testingGround.close();
  }
  const unavailable = journeys.filter((journey) => journey.state === "unavailable");
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
